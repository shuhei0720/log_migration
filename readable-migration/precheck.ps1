#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$targets = @(Read-MigrationTargets)

# ---
# 旧設定・ポリシー・保存先名・診断設定の空き枠をSubごとに確認する。Azureの変更や作業記録の保存は行わない。
# ---
$results = foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $null = Get-MigrationPlan -Target $target
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'OK'
            Reason = '事前確認完了'
        }
    }
    catch {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'NG'
            Reason = $_.Exception.Message
        }
    }
}
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
