# ---
# 任意の事前確認。調査結果だけを出し、Azureの変更も変更前記録の保存も行わない。
# step1は現在のAzureを調べ直すため、precheckを前日に行っても依存しない。
# ---
#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# 現在の対象・名前・保存先を確認する
# 前回の記録は使わず、その時点のAzureを調べる。Azureの変更と記録の保存は行わない。
# ---
# ---
# CSVのSubを順番に調べ、結果を1行ずつ集める。
# ---
$results = foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    # ---
    # 旧設定・地域・同名・追加枠・ポリシーなどを調べ、設定計画を作れるか確認する。
    # ここでは計画の本文を使わず、成功・失敗だけを結果に残す。
    # ---
    try {
        $null = Get-MigrationPlan -Target $target
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'OK'
            Reason = '事前確認完了'
        }
    }
    # ---
    # 失敗したSubは理由を残し、他のSubの調査を続ける。
    # ---
    catch {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'NG'
            Reason = $_.Exception.Message
        }
    }
}
# ---
# SubごとのOK/NGをprecheck_results.csvへ保存する。
# NGが1件でもあれば停止する。成功してもstep1を自動実行する処理はない。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
