#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# 1. サブスクリプションごとに旧設定を探し、作成前の条件を確認する。
# 保存先の名前、診断設定の上限5件、指定ポリシーの適用を調べる。Azureは変更しない。
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
# 2. 各サブスクリプションのOK/NGと理由をprecheck_results.csvへ保存する。
# NGが一つでもあれば止める。理由を直してからstep1を実行する。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
