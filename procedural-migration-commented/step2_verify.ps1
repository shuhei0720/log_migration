#Requires -Version 7.0
# ---
# 保存先・新設定がそろったか、変更前記録と現在のAzureを照合する。Azureは変更しない。
# 全結果をCSVへ出し、NGがあれば停止する。PassThru時だけ、全件OKの記録を返す。
# step3もこの確認を実行し、成功した記録だけを削除対象に使う。
# ---
param([switch]$PassThru)
. (Join-Path $PSScriptRoot 'common.ps1')
$results = @()
$records = @()

# ---
# 記録後に増えた旧設定や、変更された旧設定を確認する
# 削除済みの旧設定は許可し、保存先・新設定は記録した全対象を確認する。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        # ---
        # 現在のCSVと対応するSubの変更前記録を読む。記録がなければ確認できないためNG。
        # ---
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        # ---
        # 旧設定だけ再調査し、記録後に増えた対象や内容変更を検出する。
        # 削除済みの旧設定は許容する。step3途中からの再実行にも同じ確認を使うため。
        # ---
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings) {
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        # ---
        # 保存先と新設定を全件確認し、1件の失敗で残りの確認を打ち切らず結果を集める。
        # 保存先の検証は、送信作成をNoneにした場合も省かない。
        # ---
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                # ---
                # 既存RGは場所を強制せず存在を確認する。他の種類は記録の予定値と照合する。
                # ---
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
                # ---
                # 種類別に内容を照合する。Tableは合計保持期間が既定値任せでないことも確認する。
                # ---
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
            # ---
            # 失敗理由と予定BodyをNG行へ残し、調査や手動設定に使えるようにする。
            # ---
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
    # ---
    # 記録読込や旧設定探索の失敗は、Sub全体のNGとして残す。
    # ---
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
# 全件の結果をverify_results.csvへ保存してから、NGが1件でもあれば停止する。
# NG時は記録をstep3へ返さないため、旧設定の削除には進まない。
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
