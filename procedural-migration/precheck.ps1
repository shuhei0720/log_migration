#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# targets.csvの各Subについて、移行元Workspace宛ての旧診断設定と、指定した2つのDCRの旧関連付けをAzureから取得する。
# 対象のリージョンからStorage名を決め、名前の空き・新診断設定の追加枠・適用中のポリシーを確認する。
# Azureは変更せず、copyで使うJSONも保存しない。copyはこの確認を実行しなくても開始できる。
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
# SubごとのOK/NGと理由をprecheck_results.csvに出す。
# NGがあればエラーで終了するため、理由を確認してからcopyへ進む。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
