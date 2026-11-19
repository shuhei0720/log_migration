#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# 現在の対象・名前・保存先を確認する
# 前回の記録は使わず、その時点のAzureを調べる。Azureの変更と記録の保存は行わない。
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
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -NoTypeInformation -Encoding UTF8
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
