#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")

# 現在の設定が期待値と一致すれば返し、異なる場合は更新後に読み戻して照合する。
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

# CSVから対象サブスクリプションを読み、保存済みのバックアップを開く。初回は空のバックアップを用意する。
$targets = @(Get-MigrationTargets)
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step "copy" -IncludeChecks }
try {
    if (Test-Path -LiteralPath $migrationBackupPath) {
        $backup = Read-MigrationBackup
    }
    else {
        $backup = @{
            Version = 3; OldDcrIds = @($oldDcrIds); CreatedAtUtc = [DateTime]::UtcNow.ToString('o')
            TargetWorkspaceId = $targetWorkspaceId; Environment = $environment
            NewDiagnosticSettingName = $newDiagnosticSettingName; Targets = @()
        }
    }
}
catch {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step "copy" -IncludeChecks
}

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $preparationComplete = $false
    $failureCountBefore = $script:failures.Count
    $resourceId = ''
    $stage = '複製前の調査'
    $expected = $null
    try {
        # 旧診断設定・旧DCR関連と送信先を調べ、このサブスクリプションの複製計画を作る。
        $planReady = Get-MigrationPlan -Target $target
        if (-not $planReady -or $script:failures.Count -gt $failureCountBefore) { throw '対象の調査が完了していないため、このサブスクリプションは変更しません。' }
        $stage = 'バックアップ照合・保存'
        $saved = @($backup.Targets | Where-Object SubscriptionId -eq $subscriptionId)
        $routing = @{}
        foreach ($key in @('SubscriptionName','ResourceGroup','StorageAccount','WorkspaceName','LogDestination')) { $routing[$key] = $target[$key] }
        # 保存済みのサブスクリプションは、CSVの送信先情報が前回と同じか確認する。
        if ($saved.Count -gt 0) {
            foreach ($key in $routing.Keys) {
                if ([string]$saved[0].Routing.$key -ne [string]$routing[$key]) { throw "CSVの$key が保存済みの設定と一致しません。" }
            }
            # 保存済みのBeforeを保持し、旧診断設定の内容と旧DCR関連の参照先を照合する。
            $snapshot = ConvertTo-Json -InputObject $saved[0] -Depth 40 | ConvertFrom-Json
            foreach ($original in $snapshot.Diagnostics) {
                $current = @($target.DiagnosticPlans | Where-Object { $_.ResourceId -eq $original.ResourceId -and $_.SourceName -eq $original.OldName })
                if ($current.Count -ne 1 -or $current[0].SourceSignature -cne (Get-DiagnosticSignature $original.Before) -or
                    $current[0].NewSignature -cne (Get-DiagnosticSignature $original.After)) { throw "保存済みの旧診断設定が存在しないか、設定が変わっています: $($original.ResourceId)" }
            }
            foreach ($original in $snapshot.OldAssociations) {
                $current = @($target.OldAssociations | Where-Object ResourceId -eq $original.ResourceId)
                if ($current.Count -ne 1 -or $current[0].Before.properties.dataCollectionRuleId -ne $original.Before.properties.dataCollectionRuleId) { throw "保存済みの旧DCR関連が存在しないか、参照先が変わっています: $($original.ResourceId)" }
            }
        }
        else {
            $snapshot = @{
                SubscriptionName = $target.SubscriptionName; SubscriptionId = $subscriptionId; Routing = $routing
                Diagnostics = @(); Storages = @(); Dcr = $null; Associations = @(); OldAssociations = @(); Exemptions = @()
            }
        }
        $snapshotChanged = $saved.Count -eq 0
        # 未保存の旧診断設定をBefore、複製予定の収集条件と送信先をAfterに追記する。
        foreach ($plan in $target.DiagnosticPlans) {
            if (@($snapshot.Diagnostics | Where-Object ResourceId -eq $plan.ResourceId).Count -gt 0) { continue }
            if (@($plan.NewSettings).Count -gt 0) { throw "新しい診断設定名が既存設定と重複しています: $($plan.ResourceId)" }
            $before = @{}
            foreach ($key in @('logs','metrics','workspaceId','storageAccountId','eventHubAuthorizationRuleId','eventHubName','serviceBusRuleId','marketplacePartnerId','logAnalyticsDestinationType')) {
                if ($null -ne $plan.SourceSettings[0].$key) { $before[$key] = $plan.SourceSettings[0].$key }
            }
            $snapshot.Diagnostics += @(@{ ResourceId = $plan.ResourceId; OldName = $plan.SourceName; Before = $before; After = $plan.Expected })
            $snapshotChanged = $true
        }
        # 地域別のStorageをバックアップのID・名前・地域と照合し、未保存のものを集める。
        $newStorages = @()
        foreach ($storage in @($target.Storages.Values | Sort-Object Name)) {
            if (-not $script:storageNames.Add($storage.Name)) { throw "変換後のストレージ名が重複しています: $($storage.Name)" }
            $original = @($snapshot.Storages | Where-Object { $_.Location -eq $storage.Location -or $_.Name -eq $storage.Name })
            if ($original.Count -gt 0) {
                if ($original.Count -ne 1 -or $original[0].Id -ne $storage.Id -or $original[0].Name -ne $storage.Name -or $original[0].Location -ne $storage.Location) { throw "保存済みのストレージ計画と一致しません: $($storage.Name)" }
                continue
            }
            if (@($backup.Targets.Storages | Where-Object { $_.Name -eq $storage.Name -and $_.Id -ne $storage.Id }).Count -gt 0) { throw "別のサブスクリプションに同じストレージ名が保存されています: $($storage.Name)" }
            $newStorages += @($storage)
        }
        # 各地域でStandard_ZRSを使えるか、名前が空いているかを確認し、Storageの一覧に追記する。
        if ($newStorages.Count -gt 0) {
            $skus = @(Invoke-AzJson -Arguments @("storage", "sku", "list", "--subscription", $subscriptionId))
            foreach ($storage in $newStorages) {
                if (-not ($skus | Where-Object { $_.name -eq "Standard_ZRS" -and $_.kind -eq "StorageV2" -and $storage.Location -in $_.locations })) { throw "Standard_ZRSを利用できないリージョンです: $($storage.Location)" }
                $availability = Invoke-AzJson -Arguments @("storage", "account", "check-name", "--subscription", $subscriptionId, "--name", $storage.Name)
                if ($availability.nameAvailable -ne $true) { throw "名前を利用できません: $($storage.Name) / $($availability.reason) / $($availability.message)" }
                $snapshot.Storages += @($storage)
                $snapshotChanged = $true
                Add-MigrationCheck -Target $target -ResourceId $storage.Id -Stage 'ストレージ名の事前確認' -Success $true -Message '利用可能'
            }
        }
        # 未保存の旧DCR関連を個別取得し、参照先・説明・DCEをBeforeに保存する。
        $newOldAssociations = @($target.OldAssociations | Where-Object { $_.ResourceId -notin @($snapshot.OldAssociations.ResourceId) })
        foreach ($result in @(Invoke-DiagnosticBatch -Items $newOldAssociations -Action {
            param($old, $unused)
            Invoke-ArmRequest -ResourceId $old.ResourceId
        })) {
            if ($result.Error) { throw "旧DCR関連の取得失敗: $($result.Item.ResourceId) / $($result.Error)" }
            $before = Get-RollbackBody $result.Result -Association -RequireReady
            if ($before.properties.dataCollectionRuleId -ne $result.Item.Before.properties.dataCollectionRuleId) { throw "一覧取得後に旧DCR関連の参照先が変わっています: $($result.Item.ResourceId)" }
            $snapshot.OldAssociations += @(@{ ResourceId = $result.Item.ResourceId; Before = $before })
            $snapshotChanged = $true
        }
        # 新DCRと関連付けの既存状態をBefore、作成予定の内容をAfterに保存する。
        if ($target.Collectors.Count -gt 0) {
            $dcrName = $target.WorkspaceName -replace '^log','dcr'
            $dcrId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
            if (-not $snapshot.Dcr) {
                $before = Get-RollbackBody (Get-OptionalArmResource -ResourceId $dcrId) -RequireReady
                $snapshot.Dcr = @{ ResourceId = $dcrId; Before = $before; After = Get-MigrationDcrBody -Target $target }
                $snapshotChanged = $true
            }
            foreach ($collectorId in $target.Collectors) {
                $associationId = "$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
                if ($associationId -in @($snapshot.Associations.ResourceId)) { continue }
                $before = Get-RollbackBody (Get-OptionalArmResource -ResourceId $associationId) -Association -RequireReady
                if ($before.properties.dataCollectionRuleId -in $oldDcrIds) { throw "新関連と旧関連のIDが同じです: $associationId" }
                $snapshot.Associations += @(@{ ResourceId = $associationId; Before = $before; After = @{ properties = @{ dataCollectionRuleId = $dcrId } } })
                $snapshotChanged = $true
            }
        }
        # 初回だけ、各ポリシー適用除外が既に存在するかを切戻し用に記録する。
        if ($saved.Count -eq 0) {
            $snapshot.Exemptions = @(foreach ($assignment in $policyAssignments) {
                $id = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
                @{ ResourceId = $id; Existed = [bool](Get-OptionalArmResource -ResourceId $id -ApiVersion '2022-07-01-preview') }
            })
        }
        # Azureの設定を変える前に、追記したバックアップを一時ファイルへ書き、保存先を置き換える。
        if ($snapshotChanged) {
            $nextBackup = ConvertTo-Json -InputObject $backup -Depth 40 | ConvertFrom-Json
            $nextBackup.Targets = @($nextBackup.Targets | Where-Object SubscriptionId -ne $subscriptionId) + @($snapshot)
            $temporaryBackupPath = $migrationBackupPath + '.' + [guid]::NewGuid().ToString('N') + '.tmp'
            try {
                $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $nextBackup -Depth 40))
                $file = [IO.File]::Open($temporaryBackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
                try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
                if (Test-Path -LiteralPath $migrationBackupPath) { [IO.File]::Replace($temporaryBackupPath, $migrationBackupPath, [NullString]::Value) }
                else { [IO.File]::Move($temporaryBackupPath, $migrationBackupPath) }
                $backup = $nextBackup
            }
            finally { if (Test-Path -LiteralPath $temporaryBackupPath) { Remove-Item -LiteralPath $temporaryBackupPath -Force } }
        }
        Add-MigrationCheck -Target $target -ResourceId $migrationBackupPath -Stage '切戻し用バックアップ' -Success $true -Message '変更前の状態を保存済み'

        $groupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        $ready = $true
        # 指定されたポリシー割り当ての適用除外を作成し、既存なら対象・除外区分を照合する。
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
        # 適用除外に失敗したサブスクリプションは、保存先の作成に進まない。
        if (-not $ready) { throw '保存先の準備に失敗したため、このサブスクリプションの診断設定は複製しません。' }

        # LA・DCR用のプロバイダーを登録する。Storageを作る場合はStorage・Securityも登録する。
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

        # CSVで指定されたリソースグループを取得し、存在しなければ指定地域に作成する。
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

        # ログ送信元の地域ごとに、ZRS・インフラ暗号化・バージョン単位の不変性を有効にしたStorageを用意する。
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
                # 既存Storageの地域・SKU・暗号化・不変性などが計画と違う場合は、そのStorageの処理を止める。
                if (-not (Test-BaselineValues -Actual $storage -Expected $immutable)) {
                    throw "既存ストレージのID・リージョン・種類・SKU・インフラ暗号化・ALWが一致しません。上書きしません。"
                }
                # 既存のIP・仮想ネットワーク規則を残し、既定の拒否とAzureサービスの例外を設定する。
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

            # Blobサービスのバージョン管理を有効にする。
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

            # 最終更新から1095日を超えたappendBlobを削除するライフサイクルルールを設定する。
            $resourceId = "$($storagePlan.Id)/managementPolicies/default"
            $stage = "ライフサイクル"
            $expected = @{
                name = "log-append-1095"; enabled = $true; type = "Lifecycle"
                definition = @{
                    filters = @{ blobTypes = @("appendBlob") }
                    actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = 1095 } } }
                }
            }
            try {
                # log-append-365とlog-append-1095を取得し、1095日のルール1件にそろえる。
                $managedRuleNames = @($expected.name, "log-append-365")
                $policy = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-05-01"
                $rules = @($policy.properties.policy.rules | Where-Object { $_.name -in $managedRuleNames })
                if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) {
                    # 上記2つ以外の名前のルールを残して、1095日のルールを書き戻す。
                    $rules = @($policy.properties.policy.rules | Where-Object { $null -ne $_ -and $_.name -notin $managedRuleNames }) + @($expected)
                    $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2023-05-01" -Body @{ properties = @{ policy = @{ rules = $rules } } }
                    $policy = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-05-01"
                    $rules = @($policy.properties.policy.rules | Where-Object { $_.name -in $managedRuleNames })
                    if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) { throw "ライフサイクルの読み戻しが一致しません。" }
                }
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
            }
            catch {
                $ready = $false
                Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            }

            # このStorageでは、サブスクリプション共通の設定にかかわらずDefender for Storageを無効にする。
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

        # Log Analyticsを作成・更新し、保持365日、取込・検索アクセス、リソース権限でのログ参照を設定する。
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
        # VM・VMSSの収集対象がある場合は、Event・Syslogテーブルの総保持期間を1095日にする。
        if ($target.Collectors.Count -gt 0) {
            $tablesReady = $true
            foreach ($name in @("Event", "Syslog")) {
                $resourceId = "$($target.WorkspaceId)/tables/$name"
                $stage = "VMログテーブル"
                $expected = @{ properties = @{ schema = @{ name = $name }; totalRetentionInDays = 1095; provisioningState = "Succeeded" } }
                try {
                    $table = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2025-07-01"
                    $deadline = (Get-Date).AddMinutes(5)
                    # 作成・更新中のテーブルは、最大5分間、完了を待ってから保持期間を設定する。
                    while ($table -and $table.properties.provisioningState -ne "Succeeded") {
                        if ((Get-Date) -ge $deadline -or $table.properties.provisioningState -in @("Failed", "Canceled", "Deleting")) {
                            throw "VMログテーブルが利用できません: state=$($table.properties.provisioningState)"
                        }
                        Start-Sleep -Seconds 10
                        $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                    }
                    if (-not $table) {
                        $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2025-07-01" `
                            -Body @{ properties = @{ schema = @{ name = $name }; totalRetentionInDays = 1095 } }
                        $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                    }
                    elseif ($table.properties.totalRetentionInDays -ne 1095 -or
                        ($null -ne $table.properties.totalRetentionInDaysAsDefault -and $table.properties.totalRetentionInDaysAsDefault -ne $false)) {
                        # 既存テーブルには総保持期間だけをPATCHし、分析保持期間・スキーマ・プランは残す。
                        $null = Invoke-ArmRequest -Method Patch -ResourceId $resourceId -ApiVersion "2025-07-01" -Body @{ properties = @{ totalRetentionInDays = 1095 } }
                        $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                    }
                    while ($table.properties.provisioningState -ne "Succeeded") {
                        if ((Get-Date) -ge $deadline -or $table.properties.provisioningState -in @("Failed", "Canceled", "Deleting")) {
                            throw "VMログテーブルが利用できません: state=$($table.properties.provisioningState)"
                        }
                        Start-Sleep -Seconds 10
                        $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                    }
                    if (-not (Test-BaselineValues -Actual $table -Expected $expected) -or
                        ($null -ne $table.properties.totalRetentionInDaysAsDefault -and $table.properties.totalRetentionInDaysAsDefault -ne $false)) { throw "VMログテーブルの総保持期間が明示的な1095日と一致しません。" }
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
                }
                catch {
                    $ready = $false
                    $tablesReady = $false
                    Add-MigrationCheck -Target $target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
                }
            }

            # Event・Syslogを新LAへ送るDCRを作成・更新し、宛先テーブルの反映待ちなら再試行する。
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
            # 各収集対象に新DCRを関連付け、更新完了後の参照先が新DCRか確認する。
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
        # すべての保存先・DCRの準備が済んだサブスクリプションで、診断設定の複製を開始する。
        $preparationComplete = $true
        $resourceId = ''
        $stage = '複製処理'
        $expected = $null
        Invoke-DiagnosticBatch -Items $target.DiagnosticPlans.ToArray() -SettingName $newDiagnosticSettingName -Action {
            param($plan, $settingName)
            # 旧診断設定を読み直し、調査時の収集条件・送信先から変わっていないか確認する。
            $settings = @(Get-DiagnosticSettings -ResourceId $plan.ResourceId)
            $source = $plan.SourceSettings[0]
            $currentSource = @($settings | Where-Object { $_.name -eq $source.name })
            if ($currentSource.Count -ne 1 -or (Get-DiagnosticSignature -Setting $currentSource[0]) -cne $plan.SourceSignature) {
                throw "旧設定が調査後に変更されています。古い内容では複製しません。"
            }
            # 同名の新設定が計画と一致すればスキップし、異なればそのリソースの複製を止める。
            $existing = @($settings | Where-Object { $_.name -eq $settingName })
            if ($existing.Count -gt 0) {
                if ($existing.Count -ne 1 -or (Get-DiagnosticSignature -Setting $existing[0]) -cne $plan.NewSignature) {
                    throw "同名の新設定が期待値と一致しません。上書きせず手動対応用CSVに記録します。"
                }
                return "既存設定と一致・変更なし"
            }
            # 診断設定の件数上限を確認し、旧設定を残したまま新設定を作成して読み戻す。
            if ($settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定は残します。" }
            $newId = "$($plan.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($settingName))"
            $null = Invoke-ArmRequest -Method Put -ResourceId $newId -ApiVersion "2021-05-01-preview" -Body @{ properties = $plan.Expected }
            $created = Get-DiagnosticSettings -ResourceId $plan.ResourceId -Name $settingName
            if ((Get-DiagnosticSignature -Setting $created) -cne $plan.NewSignature) {
                throw "新設定の読み戻しで収集条件・送信先が一致しません。旧設定は残します。"
            }
            "複製・確認完了"
        } | ForEach-Object {
            # 各リソースの複製結果を、成功記録または手動対応用の失敗記録に追加する。
            if ($_.Error) {
                Add-MigrationFailure -Target $target -ResourceId $_.Item.ResourceId -Stage "診断設定の複製" -Message $_.Error -Expected $_.Item.Expected
            }
            else {
                Add-MigrationCheck -Target $target -ResourceId $_.Item.ResourceId -Stage "診断設定の複製" -Success $true -Message ([string]$_.Result) -Expected $_.Item.Expected
                Write-Host "$($_.Result): $($_.Item.ResourceId) / $newDiagnosticSettingName"
            }
        }
    }
    catch {
        # 準備項目で未記録の例外、または複製開始後の例外を失敗として記録する。
        if ($preparationComplete -or $script:failures.Count -eq $failureCountBefore) {
            Add-MigrationFailure -Target $target -ResourceId $resourceId -Stage $stage -Message $_.Exception.Message -Expected $expected
        }
        # 準備に失敗した場合は、一致する新設定が既にあるリソースを除き、複製未実施として記録する。
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
# 全サブスクリプションの確認結果・失敗を出力し、後続のverify・deleteの順序を表示する。
Complete-MigrationStep -Step "copy" -IncludeChecks
Write-Host "旧設定を保持しています。verifyで全件確認してから、deleteを実行してください。"
