#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")

# リソースの現在値と期待値を比較し、更新状態と照合結果を記録する。
function Confirm-MigrationResource {
    param([object]$Target, [string]$ResourceId, [string]$ApiVersion, [object]$Expected, [string]$Stage)
    try {
        $current = Get-OptionalArmResource -ResourceId $ResourceId -ApiVersion $ApiVersion
        if ($current -and $Expected.properties -and ($current.properties.provisioningState -in @('Creating','Updating','Accepted') -or
            ($Expected.properties.provisioningState -and $current.properties.provisioningState -ne $Expected.properties.provisioningState))) {
            throw "リソースの作成・更新が完了していません: state=$($current.properties.provisioningState)"
        }
        if (-not (Test-BaselineValues -Actual $current -Expected $Expected)) { throw '必要な設定が未作成、または期待値と一致しません。' }
        Add-MigrationCheck -Target $Target -ResourceId $ResourceId -Stage $Stage -Success $true -Message '一致' -Expected $Expected
    }
    catch { Add-MigrationFailure -Target $Target -ResourceId $ResourceId -Stage $Stage -Message $_.Exception.Message -Expected $Expected }
}


# step1_copyのバックアップを読み、CSVの対象・送信先と照合する。
try { $backup = Read-MigrationBackup -CheckCsv }
catch {
    Add-MigrationFailure -Stage 'Ⅰのバックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step 'verify'
}
# CSVの各対象から、現在の旧診断設定・旧DCR関連と移行先を調べる。
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target }
    catch { Add-MigrationFailure -Target $target -Stage '全件調査' -Message $_.Exception.Message }
}
# 調査した旧設定・旧DCR関連を、step1_copyで保存した内容と照合する。
try {
    if (@($targets | Where-Object { $_.SubscriptionId -notin $backup.Targets.SubscriptionId }).Count -gt 0) { throw 'サブスクリプションの実IDがバックアップにありません。' }
    foreach ($target in $targets) {
        $saved = @($backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
        $savedCollectors = @($saved.Associations | ForEach-Object { $_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','' } | Sort-Object)
        # 残っている旧診断設定の名前・収集条件・送信先をバックアップと比較する。
        foreach ($plan in $target.DiagnosticPlans) {
            $original = @($saved.Diagnostics | Where-Object { $_.ResourceId -eq $plan.ResourceId -and $_.OldName -eq $plan.SourceName })
            if ($original.Count -ne 1 -or $plan.SourceSignature -cne (Get-DiagnosticSignature $original[0].Before) -or
                $plan.NewSignature -cne (Get-DiagnosticSignature $original[0].After)) { throw "バックアップ外、または変更された旧診断設定です: $($plan.ResourceId)" }
        }
        # 残っている旧DCR関連のIDと参照先をバックアップと比較する。
        foreach ($association in $target.OldAssociations) {
            $original = @($saved.OldAssociations | Where-Object ResourceId -eq $association.ResourceId)
            if ($original.Count -ne 1 -or $original[0].Before.properties.dataCollectionRuleId -ne $association.Before.properties.dataCollectionRuleId) { throw "バックアップ外、または参照先が変わった旧DCR関連です: $($association.ResourceId)" }
        }
        # 削除済みの対象も確認できるよう、収集対象と保存先をバックアップから補う。
        $target.Collectors = $savedCollectors
        foreach ($storage in $saved.Storages) { $target.Storages[$storage.Location] = $storage }
    }
}
catch { Add-MigrationFailure -Stage 'Ⅰのバックアップ照合' -Message $_.Exception.Message }
# バックアップとの不一致があれば、リソースの確認に進まず終了する。
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step 'verify' -IncludeChecks }
foreach ($target in $targets) {
    try {
        $subscriptionId = $target.SubscriptionId
        $savedTarget = @($backup.Targets | Where-Object SubscriptionId -eq $subscriptionId)[0]
        $groupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"

        # 3件のポリシー適用除外について、対象範囲とWaiver指定を確認する。
        foreach ($assignment in $policyAssignments) {
            $resourceId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
            $expected = @{ policyAssignmentId = $assignment.Id; exemptionCategory = 'Waiver'; assignmentScopeValidation = 'Default' }
            if (@($assignment.ReferenceIds).Count -gt 0) { $expected.policyDefinitionReferenceIds = @($assignment.ReferenceIds) }
            try {
                $exemption = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion '2022-07-01-preview'
                Assert-PolicyExemption -Exemption $exemption -Assignment $assignment
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage 'ポリシー適用除外' -Success $true -Message '一致' -Expected $expected
            }
            catch { Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage 'ポリシー適用除外' -Message $_.Exception.Message -Expected $expected }
        }

        # 利用するリソースプロバイダーが登録済みか確認する。
        $namespaces = @('Microsoft.OperationalInsights', 'Microsoft.Insights')
        if ($target.Storages.Count -gt 0) { $namespaces += @('Microsoft.Storage', 'Microsoft.Security') }
        foreach ($namespace in $namespaces) {
            $resourceId = "/subscriptions/$subscriptionId/providers/$namespace"
            try {
                $provider = Invoke-AzJson -Arguments @('provider','show','--subscription',$subscriptionId,'--namespace',$namespace)
                if ($provider.registrationState -ne 'Registered') { throw "リソースプロバイダーが登録されていません: $namespace" }
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage 'プロバイダー登録' -Success $true -Message '登録済み'
            }
            catch { Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage 'プロバイダー登録' -Message $_.Exception.Message }
        }

        # 移行先のリソースグループが存在するか確認する。
        Confirm-MigrationResource -Target $target -ResourceId $groupId -ApiVersion '2022-09-01' -Expected @{} -Stage 'リソースグループ'

        foreach ($storagePlan in @($target.Storages.Values | Sort-Object Name)) {
            # 保存先の地域・ZRS・暗号化・不変ストレージ・ネットワーク設定を照合する。
            $expected = @{
                id = $storagePlan.Id; location = $storagePlan.Location; kind = 'StorageV2'; sku = @{ name = 'Standard_ZRS' }
                properties = @{
                    encryption = @{ requireInfrastructureEncryption = $true }
                    immutableStorageWithVersioning = @{ enabled = $true }
                    publicNetworkAccess = 'Enabled'; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
                    supportsHttpsTrafficOnly = $true; minimumTlsVersion = 'TLS1_2'
                    networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices' }; provisioningState = 'Succeeded'
                }
            }
            Confirm-MigrationResource -Target $target -ResourceId $storagePlan.Id -ApiVersion '2023-05-01' -Expected $expected -Stage 'ストレージアカウント'
            # Blobのバージョン管理が有効か確認する。
            $resourceId = "$($storagePlan.Id)/blobServices/default"
            Confirm-MigrationResource -Target $target -ResourceId $resourceId -ApiVersion '2023-05-01' -Expected @{ properties = @{ isVersioningEnabled = $true } } -Stage 'Blobバージョン管理'

            # appendBlobの削除条件が1095日で、旧365日ルールが残っていないか確認する。
            $resourceId = "$($storagePlan.Id)/managementPolicies/default"
            $expected = @{
                name = 'log-append-1095'; enabled = $true; type = 'Lifecycle'
                definition = @{
                    filters = @{ blobTypes = @('appendBlob') }
                    actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = 1095 } } }
                }
            }
            try {
                $managedRuleNames = @($expected.name, "log-append-365")
                $policy = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion '2023-05-01'
                $rules = @($policy.properties.policy.rules | Where-Object { $_.name -in $managedRuleNames })
                if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) { throw 'log-append-1095ルールが未設定、または期待値と一致しません。' }
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage 'ライフサイクル' -Success $true -Message '一致' -Expected $expected
            }
            catch { Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage 'ライフサイクル' -Message $_.Exception.Message -Expected $expected }

            # このStorageのDefender for Storageが無効で、サブスクリプション共通の設定より優先されるか確認する。
            $resourceId = "$($storagePlan.Id)/providers/Microsoft.Security/defenderForStorageSettings/current"
            $expected = @{ properties = @{ isEnabled = $false; overrideSubscriptionLevelSettings = $true } }
            Confirm-MigrationResource -Target $target -ResourceId $resourceId -ApiVersion '2025-01-01' -Expected $expected -Stage 'Defender for Storage'
        }

        # Log Analyticsの地域・保持期間365日・公開アクセス・権限設定を照合する。
        $expected = @{
            location = $location
            properties = @{
                retentionInDays = 365; publicNetworkAccessForIngestion = 'Enabled'; publicNetworkAccessForQuery = 'Enabled'
                features = @{ enableLogAccessUsingOnlyResourcePermissions = $true }; provisioningState = 'Succeeded'
            }
        }
        Confirm-MigrationResource -Target $target -ResourceId $target.WorkspaceId -ApiVersion '2023-09-01' -Expected $expected -Stage 'Log Analytics'

        if ($target.Collectors.Count -gt 0) {
            # Event・Syslogテーブルの総保持期間が1095日か確認する。
            foreach ($name in @('Event','Syslog')) {
                $resourceId = "$($target.WorkspaceId)/tables/$name"
                $expected = @{ properties = @{ schema = @{ name = $name }; provisioningState = 'Succeeded'; totalRetentionInDays = 1095 } }
                try {
                    $table = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion '2025-07-01'
                    # 総保持期間が継承値ではなく、明示設定か確認する。
                    if (-not (Test-BaselineValues -Actual $table -Expected $expected) -or
                        ($null -ne $table.properties.totalRetentionInDaysAsDefault -and $table.properties.totalRetentionInDaysAsDefault -ne $false)) {
                        throw 'テーブルが未作成、更新中、または総保持期間1095日の明示設定と一致しません。'
                    }
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage 'VMログテーブル' -Success $true -Message '総保持期間1095日を明示設定済み' -Expected $expected
                }
                catch { Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage 'VMログテーブル' -Message $_.Exception.Message -Expected $expected }
            }
            # 新DCRの収集条件・送信先・作成完了状態を照合する。
            $body = Get-MigrationDcrBody -Target $target
            $expected = @{ location = $body.location; properties = $body.properties.Clone() }
            $expected.properties.provisioningState = 'Succeeded'
            Confirm-MigrationResource -Target $target -ResourceId $savedTarget.Dcr.ResourceId -ApiVersion '2024-03-11' -Expected $expected -Stage 'DCR'
            # 保存済みの各VM・VMSSに、新DCRへの関連があるか確認する。
            foreach ($collectorId in $target.Collectors) {
                $dcrName = $target.WorkspaceName -replace '^log','dcr'
                $resourceId = "$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
                $expected = @{ properties = @{ dataCollectionRuleId = $savedTarget.Dcr.ResourceId } }
                try {
                    $association = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion '2024-03-11'
                    $association = Get-RollbackBody $association -Association -RequireReady
                    if (-not (Test-BaselineValues $association $expected)) { throw '新DCR関連が未設定、更新中、または完成形と一致しません。' }
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage 'DCR関連付け' -Success $true -Message '一致' -Expected $expected
                }
                catch { Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage 'DCR関連付け' -Message $_.Exception.Message -Expected $expected }
            }
        }

        # バックアップの全対象について、新診断設定の収集条件・送信先を照合する。
        foreach ($saved in $savedTarget.Diagnostics) {
            $settings = @($target.CurrentSettings[$saved.ResourceId] | Where-Object { $_.name -eq $newDiagnosticSettingName })
            $matched = $settings.Count -eq 1 -and (Get-DiagnosticSignature $settings[0]) -ceq (Get-DiagnosticSignature $saved.After)
            $message = if ($matched) { '新設定がバックアップの完成形と一致' } else { '新設定が存在しないか、収集条件・送信先が一致しません。旧設定は削除できません。' }
            Add-MigrationCheck -Target $target -ResourceId $saved.ResourceId -Stage '診断設定の全件確認' -Success $matched -Message $message -Expected $saved.After
        }
    }
    catch { Add-MigrationFailure -Target $target -Stage '全件確認' -Message $_.Exception.Message }
}
Complete-MigrationStep -Step "verify" -IncludeChecks
