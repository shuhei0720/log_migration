#Requires -Version 7.0
# PassThruを付けると、全件OKの作業記録をstep3へ返す。結果CSVはどちらでも保存する。
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# 1. 作業記録を読み、環境・移行元ワークスペース・CSVが今回と同じか確認する。
# 続けて、現在の旧診断設定・旧DCR関連付けを取得する。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        # ---
        # 2. 現在の旧設定を作業記録と比べ、記録にない追加や値の変更をNGにする。
        # ---
        # step3の再実行にも使うため、すでに削除した旧設定はNGにしない。
        foreach ($current in $currentPlan.OldSettings) {
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        # ---
        # 3. 保存先・新送信設定・適用除外をAzureから取得し、記録の設定値（Body）と比べる。
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
# 全サブスクリプションの結果と、NGになった設定へ指定する値をverify_results.csvへ保存する。
# NGが1件でもあればエラーにし、step3へ作業記録を返さない。
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
