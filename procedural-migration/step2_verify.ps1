#Requires -Version 7.0
# PassThruはstep3用。全件OKなら記録JSONの内容を返す。省略時は確認結果のCSVだけを出す。
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# CSVの各SubのJSONを読み、環境・移行元Workspace・CSVが作成時と同じか確認する。
# 旧設定を探し直して記録後の追加・変更を検出する。step3の再実行にも使うため、削除済みの旧設定は許可する。Azureは変更しない。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings) {
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        # ---
        # 保存先・新設定・WaiverをAzureから取得し、JSONの作成値と照合する。Event・Syslogは保持期間の個別指定も確認する。
        # 不一致のIDと期待値を結果に残し、ほかの対象も確認する。
        # ---
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                # RGは作成済みであることを確認する。
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
                # 日数の一致に加え、テーブルの保持期間が既定値の継承ではなく個別指定かも確認する。
                if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                    ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                    throw '必要な設定がないか、予定の値と異なります。'
                }
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'OK'
                    Reason = '一致'
                    Expected = ''
                }
            }
            catch {
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'NG'
                    Reason = $_.Exception.Message
                    Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
                }
            }
        }
        $records += $record
    }
    catch {
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = ''
            Result = 'NG'
            Reason = $_.Exception.Message
            Expected = ''
        }
    }
}
# ---
# 全Subの結果と修正用の期待値をverify_results.csvへ出す。NGがあればエラーにして、step3へ記録を返さない。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'verify_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '未完了の設定があります。verify_results.csvを確認してください。'
}
if ($PassThru) {
    $records
}
else {
    Write-Host '全件確認が完了しました。'
}
