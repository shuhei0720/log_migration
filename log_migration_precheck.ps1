#Requires -Version 5.1
. (Join-Path $PSScriptRoot "log_migration_common.ps1")

# 初回だけ実行します。同名ストレージ・同名診断設定はすべて事前停止します。
# この工程ではAzureの設定を変更しません。
if (Test-Path -LiteralPath $migrationBackupPath) {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message '既存のバックアップを上書きしません。再実行はcopyから行ってください。'
    Complete-MigrationStep -Step 'precheck'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target -Fresh }
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
