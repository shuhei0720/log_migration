#Requires -Version 5.1
. (Join-Path $PSScriptRoot "common.ps1")

# 初回だけ実行します。同名ストレージ・同名診断設定はすべて事前停止します。
# この工程ではAzureの設定を変更しません。
if (Test-Path -LiteralPath $migrationBackupPath) {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message '既存のバックアップを上書きしません。再実行はcopyから行ってください。'
    Complete-MigrationStep -Step 'precheck'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        # 指定環境のポリシーと参照IDを先に確認します。
        $assignmentUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
        $assignments = @()
        do {
            $page = Invoke-ArmRequest -ResourceId $assignmentUrl
            $assignments += @($page.value)
            $assignmentUrl = $page.nextLink
        } while ($assignmentUrl)
        foreach ($assignment in $policyAssignments) {
            if ($assignment.Id -notin $assignments.id) { throw "指定環境の割り当てが適用されていません: $($assignment.Id)" }
        }
        $assignment = $assignments | Where-Object { $_.id -eq $policyAssignments[2].Id } | Select-Object -First 1
        $definitionId = $assignment.properties.policyDefinitionId
        if (-not $definitionId -or $definitionId -notmatch '/policySetDefinitions/') { throw "3件目の割り当てからイニシアティブの定義IDを取得できません。" }
        if (-not $script:initiativeDefinition) { $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion "2023-04-01" }
        foreach ($referenceId in $policyReferenceIds) {
            if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) { throw "指定の参照IDがイニシアティブに存在しません: $referenceId" }
        }
        # 対象の旧設定とリージョン別の保存先を調べ、名前の重複を確認します。
        $null = Get-MigrationPlan -Target $target -Fresh
        if ($target.Storages.Count -gt 0) {
            $skus = @(Invoke-AzJson -Arguments @("storage", "sku", "list", "--subscription", $subscriptionId))
            foreach ($storage in @($Target.Storages.Values | Sort-Object Name)) {
                try {
                    if (-not $script:storageNames.Add($storage.Name)) { throw "変換後のストレージ名が重複しています: $($storage.Name)" }
                    if (-not ($skus | Where-Object { $_.name -eq "Standard_ZRS" -and $_.kind -eq "StorageV2" -and $storage.Location -in $_.locations })) { throw "Standard_ZRSを利用できないリージョンです: $($storage.Location)" }
                    $availability = Invoke-AzJson -Arguments @("storage", "account", "check-name", "--subscription", $subscriptionId, "--name", $storage.Name)
                    if ($availability.nameAvailable -ne $true) { throw "名前を利用できません: $($storage.Name) / $($availability.reason) / $($availability.message)" }
                    Add-MigrationCheck -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Success $true -Message "利用可能"
                }
                catch {
                    Add-MigrationFailure -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Message $_.Exception.Message
                }
            }
        }
    }
    catch { Add-MigrationFailure -Target $target -Stage "事前チェック" -Message $_.Exception.Message }
}
if ($script:failures.Count -eq 0) {
    # 取得済みの旧診断設定を使い、追加GETは適用除外・DCR・関連付けだけに限定します。
    try {
        $savedTargets = @(foreach ($target in $Targets) {
            $subscriptionId = $target.SubscriptionId
            $routing = @{}
            foreach ($key in @('SubscriptionName','ResourceGroup','StorageAccount','WorkspaceName','LogDestination')) { $routing[$key] = $target[$key] }
            $diagnostics = @(foreach ($plan in $target.DiagnosticPlans) {
                $before = @{}
                foreach ($key in @('logs','metrics','workspaceId','storageAccountId','eventHubAuthorizationRuleId','eventHubName','serviceBusRuleId','marketplacePartnerId','logAnalyticsDestinationType')) {
                    if ($null -ne $plan.SourceSettings[0].$key) { $before[$key] = $plan.SourceSettings[0].$key }
                }
                @{ ResourceId = $plan.ResourceId; OldName = $plan.SourceName; Before = $before; After = $plan.Expected }
            })
            # 一覧ではdescription等が省略されるため、選択した旧関連だけを個別取得します。
            $oldAssociations = @(foreach ($result in @(Invoke-DiagnosticBatch -Items @($target.OldAssociations) -Action {
                param($old, $unused)
                Invoke-ArmRequest -ResourceId $old.ResourceId
            })) {
                if ($result.Error) { throw "旧DCR関連の取得失敗: $($result.Item.ResourceId) / $($result.Error)" }
                $before = Get-RollbackBody $result.Result -Association -RequireReady
                if ($before.properties.dataCollectionRuleId -ne $result.Item.Before.properties.dataCollectionRuleId) { throw "一覧取得後に旧DCR関連の参照先が変わっています: $($result.Item.ResourceId)" }
                @{ ResourceId = $result.Item.ResourceId; Before = $before }
            })
            $exemptions = @(foreach ($assignment in $policyAssignments) {
                $id = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
                @{ ResourceId = $id; Existed = [bool](Get-OptionalArmResource -ResourceId $id -ApiVersion '2022-07-01-preview') }
            })
            $dcr = $null; $associations = @()
            if ($target.Collectors.Count -gt 0) {
                $dcrName = $target.WorkspaceName -replace '^log','dcr'
                $id = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
                $dcr = @{ ResourceId = $id; Before = Get-RollbackBody (Get-OptionalArmResource -ResourceId $id); After = Get-MigrationDcrBody -Target $target }
                $associations = @(foreach ($collectorId in $target.Collectors) {
                    $associationId = "$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
                    $before = Get-RollbackBody (Get-OptionalArmResource -ResourceId $associationId) -Association
                    if ($before.properties.dataCollectionRuleId -in $oldDcrIds) { throw "新関連と旧関連のIDが同じです: $associationId" }
                    @{ ResourceId = $associationId; Before = $before; After = @{ properties = @{ dataCollectionRuleId = $id } } }
                })
            }
            @{ SubscriptionName = $target.SubscriptionName; SubscriptionId = $subscriptionId; Routing = $routing
               Diagnostics = $diagnostics; Storages = @($target.Storages.Values); Dcr = $dcr; Associations = $associations; OldAssociations = $oldAssociations; Exemptions = $exemptions }
        })
        $backup = @{ Version = 2; OldDcrIds = @($oldDcrIds); CreatedAtUtc = [DateTime]::UtcNow.ToString('o'); TargetWorkspaceId = $targetWorkspaceId
                     Environment = $environment; NewDiagnosticSettingName = $newDiagnosticSettingName; Targets = $savedTargets }
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $backup -Depth 40))
        $file = [IO.File]::Open($migrationBackupPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write)
        try { $file.Write($bytes, 0, $bytes.Length); $file.Flush($true) } finally { $file.Dispose() }
        Write-Host "切戻し用バックアップ: $migrationBackupPath"
    }
    catch { Add-MigrationFailure -Stage 'バックアップ保存' -Message $_.Exception.Message }
}
Complete-MigrationStep -Step "precheck"
