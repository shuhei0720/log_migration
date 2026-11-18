#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")

# 同じ設定への書込みを省き、不足する設定だけを作成・更新します。
function Set-BaselineResource {
    param(
        [string]$ResourceId, [string]$ApiVersion, [hashtable]$Body,
        [hashtable]$Expected, [string]$Method = "Put"
    )

    if (-not $Expected) { $Expected = $Body }
    $current = Get-OptionalArmResource -ResourceId $ResourceId -ApiVersion $ApiVersion
    if ($current -and ($current.properties.provisioningState -in @('Creating','Updating','Accepted') -or
        ($Expected.properties.provisioningState -and $current.properties.provisioningState -ne $Expected.properties.provisioningState))) {
        throw "リソースの作成・更新が完了していません: state=$($current.properties.provisioningState)"
    }
    if (Test-BaselineValues -Actual $current -Expected $Expected) { return $current }
    $null = Invoke-ArmRequest -Method $Method -ResourceId $ResourceId -ApiVersion $ApiVersion -Body $Body
    $current = Invoke-ArmRequest -ResourceId $ResourceId -ApiVersion $ApiVersion
    if (-not (Test-BaselineValues -Actual $current -Expected $Expected)) {
        throw "設定後の読み戻しで期待値と一致しません。再実行前に現在の設定を確認してください。"
    }
    $current
}

# 初回の事前チェック後に実行します。途中で止まった場合は、この工程から再実行できます。
# 既に一致する設定は変更せず、不足する設定だけ補います。旧診断設定は削除しません。
try { $backup = Read-MigrationBackup -CheckCsv }
catch {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step 'copy'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target }
    catch { Add-MigrationFailure -Target $target -Stage "複製前の調査" -Message $_.Exception.Message }
}
try {
    if (@($targets | Where-Object { $_.SubscriptionId -notin $backup.Targets.SubscriptionId }).Count -gt 0) { throw 'サブスクリプションの実IDがバックアップにありません。' }
    foreach ($target in $targets) {
        $saved = @($backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
        $savedCollectors = @($saved.Associations | ForEach-Object { $_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','' } | Sort-Object)
        if ($target.DiagnosticPlans.Count -ne @($saved.Diagnostics).Count) { throw '旧診断設定の対象数がバックアップから変わっています。' }
        foreach ($plan in $target.DiagnosticPlans) {
            $original = @($saved.Diagnostics | Where-Object { $_.ResourceId -eq $plan.ResourceId -and $_.OldName -eq $plan.SourceName })
            if ($original.Count -ne 1 -or $plan.SourceSignature -cne (Get-DiagnosticSignature $original[0].Before) -or
                $plan.NewSignature -cne (Get-DiagnosticSignature $original[0].After)) { throw "バックアップ外、または変更された旧診断設定です: $($plan.ResourceId)" }
        }
        if ($target.OldAssociations.Count -ne $saved.OldAssociations.Count) { throw '旧DCR関連の対象数がバックアップから変わっています。' }
        foreach ($association in $target.OldAssociations) {
            $original = @($saved.OldAssociations | Where-Object ResourceId -eq $association.ResourceId)
            # 一覧が返す参照先だけを照合し、削除直前は保存した全内容と比較します。
            if ($original.Count -ne 1 -or $original[0].Before.properties.dataCollectionRuleId -ne $association.Before.properties.dataCollectionRuleId) { throw "バックアップ外、または参照先が変わった旧DCR関連です: $($association.ResourceId)" }
        }
        # ④で旧関連が消えた親リソースも、新関連の全件確認から落としません。
        $target.Collectors = $savedCollectors
        foreach ($storage in $saved.Storages) { $target.Storages[$storage.Location] = $storage }
    }
}
catch { Add-MigrationFailure -Stage 'バックアップ照合' -Message $_.Exception.Message }
# 入力・対象調査に失敗した場合は、作成・更新を始めません。
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step "copy" }

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $preparationComplete = $false
    $failureCountBefore = $script:failures.Count
    $resourceId = ''
    $stage = '保存先の準備'
    $expected = $null
    try {
        $groupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        $ready = $true
        foreach ($assignment in $policyAssignments) {
            $resourceId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
            $stage = "ポリシー適用除外"
            $expected = @{ policyAssignmentId = $assignment.Id; exemptionCategory = "Waiver"; assignmentScopeValidation = "Default" }
            if (@($assignment.ReferenceIds).Count -gt 0) { $expected.policyDefinitionReferenceIds = @($assignment.ReferenceIds) }
            try {
                $exemption = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2022-07-01-preview"
                if (-not $exemption) {
                    $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2022-07-01-preview" -Body @{ properties = $expected }
                    $exemption = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2022-07-01-preview"
                }
                Assert-PolicyExemption -Exemption $exemption -Assignment $assignment
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }
        }
        # 適用除外を確認できない場合は、他の作成・変更を開始しません。
        if (-not $ready) { throw '保存先の準備に失敗したため、このサブスクリプションの診断設定は複製しません。' }

        $namespaces = @("Microsoft.OperationalInsights", "Microsoft.Insights")
        if ($target.Storages.Count -gt 0) { $namespaces += @("Microsoft.Storage", "Microsoft.Security") }
        foreach ($namespace in $namespaces) {
            $resourceId = "/subscriptions/$subscriptionId/providers/$namespace"
            $stage = "プロバイダー登録"
            try {
                $provider = Invoke-AzJson -Arguments @("provider", "show", "--subscription", $subscriptionId, "--namespace", $namespace)
                if ($provider.registrationState -ne "Registered") {
                    $null = Invoke-AzJson -Arguments @("provider", "register", "--subscription", $subscriptionId, "--namespace", $namespace, "--wait")
                    $provider = Invoke-AzJson -Arguments @("provider", "show", "--subscription", $subscriptionId, "--namespace", $namespace)
                    if ($provider.registrationState -ne "Registered") { throw "リソースプロバイダーの登録が完了していません: $namespace" }
                }
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "登録済み"
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message
            }
        }
        if (-not $ready) { throw '保存先の準備に失敗したため、このサブスクリプションの診断設定は複製しません。' }

        $resourceId = $groupId
        $stage = "リソースグループ"
        try {
            $group = Get-OptionalArmResource -ResourceId $groupId -ApiVersion "2022-09-01"
            if (-not $group) {
                $null = Invoke-ArmRequest -Method Put -ResourceId $groupId -ApiVersion "2022-09-01" -Body @{ location = $location }
                $group = Invoke-ArmRequest -ResourceId $groupId -ApiVersion "2022-09-01"
            }
            if (-not $group) { throw "リソースグループを確認できません。" }
            Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "存在確認済み"
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message
            throw
        }

        foreach ($storagePlan in @($target.Storages.Values | Sort-Object Name)) {
            $resourceId = $storagePlan.Id
            $stage = "ストレージアカウント"
            $immutable = @{
                id = $storagePlan.Id; location = $storagePlan.Location; kind = "StorageV2"; sku = @{ name = "Standard_ZRS" }
                properties = @{
                    encryption = @{ requireInfrastructureEncryption = $true }
                    immutableStorageWithVersioning = @{ enabled = $true }
                }
            }
            $properties = @{
                publicNetworkAccess = "Enabled"; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
                supportsHttpsTrafficOnly = $true; minimumTlsVersion = "TLS1_2"
                networkAcls = @{ defaultAction = "Deny"; bypass = "AzureServices" }
            }
            $expected = $immutable.Clone()
            $expected.properties = $immutable.properties.Clone()
            foreach ($key in $properties.Keys) { $expected.properties[$key] = $properties[$key] }
            $expected.properties.provisioningState = "Succeeded"
            try {
                $storage = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-05-01"
                if (-not $storage) {
                    $null = Invoke-AzJson -Arguments @(
                        "storage", "account", "create", "--subscription", $subscriptionId,
                        "--resource-group", $target.ResourceGroup, "--name", $storagePlan.Name,
                        "--location", $storagePlan.Location, "--kind", "StorageV2", "--sku", "Standard_ZRS",
                        "--public-network-access", "Enabled", "--default-action", "Deny", "--bypass", "AzureServices",
                        "--allow-blob-public-access", "false", "--allow-shared-key-access", "false",
                        "--https-only", "true", "--min-tls-version", "TLS1_2",
                        "--require-infrastructure-encryption", "true", "--enable-alw", "true"
                    )
                    $storage = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-05-01"
                }
                # リージョンや暗号化などの基礎構成が異なる既存アカウントは変更しません。
                if (-not (Test-BaselineValues -Actual $storage -Expected $immutable)) {
                    throw "既存ストレージのID・リージョン・種類・SKU・インフラ暗号化・ALWが一致しません。上書きしません。"
                }
                # 個別に追加されたネットワーク規則は保持します。
                $networkAcls = @{}
                foreach ($property in $storage.properties.networkAcls.PSObject.Properties) { $networkAcls[$property.Name] = $property.Value }
                $networkAcls.defaultAction = "Deny"
                $networkAcls.bypass = "AzureServices"
                $bodyProperties = $properties.Clone()
                $bodyProperties.networkAcls = $networkAcls
                $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-05-01" -Method Patch `
                    -Body @{ properties = $bodyProperties } -Expected $expected
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
                continue
            }

            $resourceId = "$($storagePlan.Id)/blobServices/default"
            $stage = "Blobバージョン管理"
            $expected = @{ properties = @{ isVersioningEnabled = $true } }
            try {
                $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-05-01" -Body $expected
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }

            $resourceId = "$($storagePlan.Id)/managementPolicies/default"
            $stage = "ライフサイクル"
            $expected = @{
                name = "log-append-365"; enabled = $true; type = "Lifecycle"
                definition = @{
                    filters = @{ blobTypes = @("appendBlob") }
                    actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = 365 } } }
                }
            }
            try {
                $policy = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-05-01"
                $rules = @($policy.properties.policy.rules | Where-Object { $_.name -eq $expected.name })
                if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) {
                    # このスクリプトのルールだけ補完し、別名のルールは保持します。
                    $rules = @($policy.properties.policy.rules | Where-Object { $null -ne $_ -and $_.name -ne $expected.name }) + @($expected)
                    $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2023-05-01" -Body @{ properties = @{ policy = @{ rules = $rules } } }
                    $policy = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-05-01"
                    $rules = @($policy.properties.policy.rules | Where-Object { $_.name -eq $expected.name })
                    if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) { throw "ライフサイクルの読み戻しが一致しません。" }
                }
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }

            $resourceId = "$($storagePlan.Id)/providers/Microsoft.Security/defenderForStorageSettings/current"
            $stage = "Defender for Storage"
            $expected = @{ properties = @{ isEnabled = $false; overrideSubscriptionLevelSettings = $true } }
            try {
                $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2025-01-01" -Body $expected
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }
        }

        $resourceId = $target.WorkspaceId
        $stage = "Log Analytics"
        $expected = @{
            location = $location
            properties = @{
                retentionInDays = 365; publicNetworkAccessForIngestion = "Enabled"; publicNetworkAccessForQuery = "Enabled"
                features = @{ enableLogAccessUsingOnlyResourcePermissions = $true }
                provisioningState = "Succeeded"
            }
        }
        try {
            $workspace = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-09-01"
            if (-not $workspace) {
                $null = Invoke-AzJson -Arguments @(
                    "monitor", "log-analytics", "workspace", "create", "--subscription", $subscriptionId,
                    "--resource-group", $target.ResourceGroup, "--workspace-name", $target.WorkspaceName,
                    "--location", $location, "--retention-time", "365", "--ingestion-access", "Enabled", "--query-access", "Enabled"
                )
                $workspace = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-09-01"
            }
            if (($workspace.location -replace '\s', '') -ne $location) { throw "既存ワークスペースのリージョンが一致しません。変更しません。" }
            $features = @{}
            foreach ($property in $workspace.properties.features.PSObject.Properties) { $features[$property.Name] = $property.Value }
            $features.enableLogAccessUsingOnlyResourcePermissions = $true
            $bodyProperties = $expected.properties.Clone()
            $bodyProperties.Remove("provisioningState")
            $bodyProperties.features = $features
            $workspace = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-09-01" -Method Patch `
                -Body @{ properties = $bodyProperties } -Expected $expected
            Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            throw
        }
        if ($target.Collectors.Count -gt 0) {
            $tablesReady = $true
            foreach ($name in @("Event", "Syslog")) {
                $resourceId = "$($target.WorkspaceId)/tables/$name"
                $stage = "VMログテーブル"
                $expected = @{ properties = @{ schema = @{ name = $name }; provisioningState = "Succeeded" } }
                try {
                    $table = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2025-07-01"
                    if (-not (Test-BaselineValues -Actual $table -Expected $expected)) {
                        if (-not $table) {
                            $table = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2025-07-01" -Body @{ properties = @{ schema = @{ name = $name } } }
                        }
                        $deadline = (Get-Date).AddMinutes(5)
                        while ($table.properties.provisioningState -ne "Succeeded") {
                            if ((Get-Date) -ge $deadline -or $table.properties.provisioningState -in @("Failed", "Canceled", "Deleting")) {
                                throw "VMログテーブルが利用できません: state=$($table.properties.provisioningState)"
                            }
                            Start-Sleep -Seconds 10
                            $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                        }
                        if (-not (Test-BaselineValues -Actual $table -Expected $expected)) { throw "VMログテーブルの設定が一致しません。" }
                    }
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
                }
                catch {
                    $ready = $false
                $tablesReady = $false
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
                }
            }

            $dcrName = $target.WorkspaceName -replace '^log', 'dcr'
            $dcrId = "$groupId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
            $body = Get-MigrationDcrBody -Target $target
            $expected = @{ location = $body.location; properties = $body.properties.Clone() }
            $expected.properties.provisioningState = "Succeeded"
            $resourceId = $dcrId
            $stage = "DCR"
            $dcrReady = $false
            try {
                if (-not $tablesReady) { throw "テーブルの準備に失敗したため、DCR作成を開始していません。" }
                $deadline = (Get-Date).AddMinutes(5)
                while ($true) {
                    try {
                        $null = Set-BaselineResource -ResourceId $dcrId -ApiVersion "2024-03-11" -Body $body -Expected $expected
                        break
                    }
                    catch {
                        if ($_.Exception.Message -notmatch '\bInvalidOutputTable\b' -or (Get-Date) -ge $deadline) { throw }
                        Write-Host "DCR宛先テーブルの反映を待っています: $($target.WorkspaceName)"
                        Start-Sleep -Seconds 10
                    }
                }
                $dcrReady = $true
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }
            foreach ($collectorId in $target.Collectors) {
                $resourceId = "$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
                $stage = "DCR関連付け"
                $expected = @{ properties = @{ dataCollectionRuleId = $dcrId } }
                try {
                    if (-not $dcrReady) { throw "DCRの準備に失敗したため、関連付けを開始していません。" }
                    $association = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2024-03-11" -Body $expected
                    if ($association.properties.provisioningState -in @('Creating','Updating','Accepted')) {
                        for ($attempt = 0; $attempt -lt 15; $attempt++) {
                            $association = Get-OptionalArmResource -ResourceId $resourceId
                            if ($association -and $association.properties.provisioningState -notin @('Creating','Updating','Accepted')) { break }
                            Start-Sleep -Seconds 2
                        }
                        $association = Get-RollbackBody $association -Association -RequireReady
                    }
                    else { $association = Get-RollbackBody $association -Association -RequireReady }
                    if (-not (Test-BaselineValues $association $expected)) { throw '更新完了後のDCR関連が完成形と一致しません。' }
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
                }
                catch {
                    $ready = $false
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
                }
            }
        }
        if (-not $ready) { throw '保存先の準備に失敗したため、このサブスクリプションの診断設定は複製しません。' }
        $preparationComplete = $true
        $resourceId = ''
        $stage = '複製処理'
        $expected = $null
        Invoke-DiagnosticBatch -Items $target.DiagnosticPlans.ToArray() -SettingName $newDiagnosticSettingName -Action {
            param($plan, $settingName)
            $settings = @(Get-DiagnosticSettings -ResourceId $plan.ResourceId)
            $source = $plan.SourceSettings[0]
            $currentSource = @($settings | Where-Object { $_.name -eq $source.name })
            if ($currentSource.Count -ne 1 -or (Get-DiagnosticSignature -Setting $currentSource[0]) -cne $plan.SourceSignature) {
                throw "旧設定が調査後に変更されています。古い内容では複製しません。"
            }
            $existing = @($settings | Where-Object { $_.name -eq $settingName })
            if ($existing.Count -gt 0) {
                if ($existing.Count -ne 1 -or (Get-DiagnosticSignature -Setting $existing[0]) -cne $plan.NewSignature) {
                    throw "同名の新設定が期待値と一致しません。上書きせず手動対応用CSVに記録します。"
                }
                return "既存設定と一致・変更なし"
            }
            if ($settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定は残します。" }
            $newId = "$($plan.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($settingName))"
            $null = Invoke-ArmRequest -Method Put -ResourceId $newId -ApiVersion "2021-05-01-preview" -Body @{ properties = $plan.Expected }
            $created = Get-DiagnosticSettings -ResourceId $plan.ResourceId -Name $settingName
            if ((Get-DiagnosticSignature -Setting $created) -cne $plan.NewSignature) {
                throw "新設定の読み戻しで収集条件・送信先が一致しません。旧設定は残します。"
            }
            "複製・確認完了"
        } | ForEach-Object {
            if ($_.Error) {
                Add-MigrationFailure -Target $target -ResourceId $_.Item.ResourceId -Stage "診断設定の複製" -Message $_.Error -Expected $_.Item.Expected
            }
            else { Write-Host "$($_.Result): $($_.Item.ResourceId) / $newDiagnosticSettingName" }
        }
    }
    catch {
        # 各準備項目で記録済みの失敗は重複出力しません。
        if ($preparationComplete -or $script:failures.Count -eq $failureCountBefore) {
            Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage $stage -Message $_.Exception.Message -Expected $expected
        }
        if (-not $preparationComplete) {
            foreach ($plan in $target.DiagnosticPlans) {
                if (@($plan.NewSettings).Count -eq 1 -and
                    (Get-DiagnosticSignature -Setting $plan.NewSettings[0]) -ceq $plan.NewSignature) { continue }
                Add-MigrationFailure -Target $target -ResourceId $plan.ResourceId -Stage "診断設定の複製未実施" `
                    -Message "保存先などの準備に失敗したため、このサブスクリプションの複製は開始していません。" -Expected $plan.Expected
            }
        }
    }
}
Complete-MigrationStep -Step "copy"
Write-Host "旧設定を保持しています。verifyで全件確認してから、deleteを実行してください。"
