#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# 旧ワークスペース宛ての診断設定と、旧データ収集ルール（DCR）への関連付けを探す。
# 保存先の名前・診断設定の空き枠・ポリシーを確認する。Azureの設定は変えない。
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
# サブスクリプションごとのOK/NGと理由をprecheck_results.csvへ保存する。NGの理由を直してからstep1へ進む。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
