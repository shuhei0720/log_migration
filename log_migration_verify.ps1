#Requires -Version 5.1
. (Join-Path $PSScriptRoot "log_migration_common.ps1")

# 前工程の成否ファイルは使わず、現在のAzure設定を全件確認します。
# この工程ではAzureの設定を変更しません。
try { $backup = Read-MigrationBackup -CheckCsv }
catch {
    Add-MigrationFailure -Stage 'バックアップ確認' -Message $_.Exception.Message
    Complete-MigrationStep -Step 'verify'
}
$targets = @(Get-MigrationTargets)
foreach ($target in $targets) {
    try { $null = Get-MigrationPlan -Target $target }
    catch { Add-MigrationFailure -Target $target -Stage '全件調査' -Message $_.Exception.Message }
}
try { Assert-MigrationBackup -Backup $backup -Targets $targets -AllowMissingOld }
catch { Add-MigrationFailure -Stage 'バックアップ照合' -Message $_.Exception.Message }
if ($script:failures.Count -gt 0) { Complete-MigrationStep -Step 'verify' -IncludeChecks }
foreach ($target in $targets) {
    try {
        $null = Set-MigrationBaseline -Target $target -VerifyOnly
        $savedTarget = @($backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
        Test-MigrationDiagnostics -Target $target -BackupTarget $savedTarget
    }
    catch { Add-MigrationFailure -Target $target -Stage '全件確認' -Message $_.Exception.Message }
}
Complete-MigrationStep -Step "verify" -IncludeChecks
