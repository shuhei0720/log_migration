#Requires -Version 7.0
# PassThruを付けると、全件OKの作業記録をstep3へ返す。結果CSVはどちらでも保存する。
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# 作業記録の環境・移行元ワークスペース・CSVが、今回の指定と同じか確認する。
# 現在の旧診断設定・旧DCR関連付けを取得し、記録にない追加や設定値の変更があればNGにする。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        # step3の再実行にも使うため、削除済みの旧設定はNGにしない。
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings) {
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        # ---
        # 保存先・送信設定・ポリシーの適用除外をAzureから取得し、作業記録に保存した設定値（Body）と比べる。
        # 値の違いや取得失敗はNGとして残し、ほかの設定の確認は続ける。
        # ---
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                # リソースグループは、記録したIDで存在することを確認する。
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
                # 合計保持日数が同じでも、ワークスペースの既定値を使っているだけならNGにする。
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
# 全サブスクリプションの結果と、NGの設定に指定するはずの値をverify_results.csvへ保存する。
# NGが1件でもあれば、step3へ作業記録を返さずに止める。
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
