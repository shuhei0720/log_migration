#Requires -Version 7.0
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# targets.csvの各Subに対応するrecords/<環境>/<SubID>.jsonを読み、環境・移行元Workspace・CSVの対象情報が作成時と同じか確認する。
# Azureから再探索した移行対象の旧診断設定・旧DCR関連付けをJSONと照合し、記録にないIDや内容の差を検出する。
# 削除済みの旧設定は許可する。保存先・新設定も確認し、削除へ進める状態か判定する。Azureのリソースは変更しない。
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
        # JSONにある保存先・新診断設定・DCR関連・WaiverなどのIDでAzureを取得し、Bodyに保存した作成値と照合する。
        # Event/Syslogは、保持期間をテーブル単位で明示した状態かも確認する。
        # 不一致はそのIDと期待値を結果に加え、ほかの保存先・新設定の確認を続ける。
        # ---
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
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
# 全Subの確認結果と、手動で直す際に必要な期待値をverify_results.csvに出す。NGが1件でもあれば終了する。
# -PassThruの場合は全件OKのときだけ、旧設定のID・本体を含むJSONの内容をstep3_deleteへ返す。
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
