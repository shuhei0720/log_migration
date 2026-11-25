#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# CSVの各Subから旧診断設定・指定DCRの関連付けを探し、地域別Storage名の空き・診断設定枠・ポリシーを確認する。
# Azureの変更やJSON保存は行わない。step1はこの確認を省略しても実行できる。
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
# ---
# SubごとのOK/NGと理由をprecheck_results.csvへ出す。NGは解消してからstep1へ進む。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
