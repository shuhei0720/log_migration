#Requires -Version 5.1
. (Join-Path $PSScriptRoot "log_migration_common.ps1")

# verifyの全件成功を人が確認してから実行します。
# 全CSV対象を現在値で再確認し、1件でも未完了なら削除を一切始めません。
try { $backup = Read-MigrationBackup -CheckCsv }
catch {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step 'delete'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target }
    catch { Add-MigrationFailure -Target $target -Stage '全件調査' -Message $_.Exception.Message }
}
try { Assert-MigrationBackup -Backup $backup -Targets $targets -AllowMissingOld }
catch { Add-MigrationFailure -Stage 'バックアップ照合' -Message $_.Exception.Message }
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step 'delete' -IncludeChecks }
foreach ($target in $targets) {
    try {
        $null = Set-MigrationBaseline -Target $target -VerifyOnly
        $savedTarget = @($backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
        Test-MigrationDiagnostics -Target $target -BackupTarget $savedTarget
    }
    catch { Add-MigrationFailure -Target $target -Stage '全件確認' -Message $_.Exception.Message }
}
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step 'delete' -IncludeChecks }

# ここからは逐次実行します。失敗時は後続の削除をすべて停止します。
# 旧2本への関連だけを解除します。既に解除済みなら、そのまま次へ進みます。
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $savedTarget = @($backup.Targets | Where-Object SubscriptionId -eq $subscriptionId)[0]
    $dcrName = $target.WorkspaceName -replace '^log','dcr'
    foreach ($saved in $savedTarget.OldAssociations) {
        try {
            $current = Get-RollbackBody (Get-OptionalArmResource -ResourceId $saved.ResourceId) -Association -RequireReady
            if (-not $current) { continue }
            if (-not ((Test-BaselineValues $current $saved.Before) -and (Test-BaselineValues $saved.Before $current))) { throw '旧DCR関連が事前確認時から変わっています。' }
            $parentId = $saved.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$',''
            $newId = "$parentId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
            $expected = @{ properties = @{ dataCollectionRuleId = $savedTarget.Dcr.ResourceId } }
            $new = Get-RollbackBody (Get-OptionalArmResource -ResourceId $newId) -Association -RequireReady
            if (-not (Test-BaselineValues $new $expected)) { throw '解除直前の新DCR関連が完成形と一致しません。' }
            $null = Invoke-ArmRequest -Method Delete -ResourceId $saved.ResourceId
            Write-Host "旧DCR関連解除OK: $($saved.ResourceId)"
        }
        catch {
            Add-MigrationFailure -Target $target -ResourceId $saved.ResourceId -Stage '旧DCR関連の解除' -Message $_.Exception.Message -Expected $saved.Before
            Complete-MigrationStep -Step 'delete' -IncludeChecks
        }
    }
}

foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    foreach ($plan in $target.DiagnosticPlans) {
        try {
            $settings = @(Get-DiagnosticSettings -ResourceId $plan.ResourceId)
            foreach ($check in @(
                @{ Name = $newDiagnosticSettingName; Signature = $plan.NewSignature },
                @{ Name = $plan.SourceName; Signature = $plan.SourceSignature }
            )) {
                $current = @($settings | Where-Object { $_.name -eq $check.Name })
                if ($current.Count -ne 1 -or (Get-DiagnosticSignature -Setting $current[0]) -cne $check.Signature) {
                    throw "削除直前に設定が変更されています。以降の削除を中止します: $($check.Name)"
                }
            }
            $oldId = "$($plan.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($plan.SourceName))"
            $null = Invoke-ArmRequest -Method Delete -ResourceId $oldId -ApiVersion "2021-05-01-preview"
            Write-Host "旧設定削除OK: $($plan.ResourceId) / $($plan.SourceName)"
        }
        catch {
            Add-MigrationFailure -Target $target -ResourceId $plan.ResourceId -Stage "旧診断設定の削除" -Message $_.Exception.Message -Expected $plan.Expected
            Complete-MigrationStep -Step "delete" -IncludeChecks
        }
    }
}
Complete-MigrationStep -Step "delete" -IncludeChecks
