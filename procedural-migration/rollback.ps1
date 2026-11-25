#Requires -Version 7.0
param([string[]]$SubscriptionIds)
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# CSVは読まず、records/<環境>/<SubID>.jsonから旧設定の本体と、新設定の作成値・変更前のBeforeを取得する。
# -SubscriptionIdsを指定すればそのSubだけ、未指定なら保存済みJSONの全Subを切り戻す。
# ファイル名とJSON内のSubID、JSONと今回の実行環境が一致するかも確認する。
# ---
$recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
if ($subscriptionFilterProvided) {
    $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
    if ($SubscriptionIds.Count -eq 0 -or $unknownIds.Count -gt 0 -or
        @($SubscriptionIds | Sort-Object -Unique).Count -ne $SubscriptionIds.Count) {
        throw '記録にあるSub IDを重複なく指定してください。'
    }
    $recordFiles = @($recordFiles | Where-Object { $_.BaseName -in $SubscriptionIds })
}
$records = @(foreach ($file in $recordFiles) {
    $saved = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    if ($saved.Target.SubscriptionId -ne $file.BaseName) {
        throw '記録のSub IDとファイル名が一致しません。'
    }
    Read-MigrationRecord -Target $saved.Target
})
if (-not $records.Count) {
    throw '切り戻す記録がありません。'
}
$failurePath = Join-Path $PSScriptRoot 'rollback_failures.csv'
try {
    # ---
    # JSONのIDで旧設定・新設定をAzureから取得し、Body（旧設定の本体／新設定の作成値）かBefore（変更前の値）と照合する。
    # どちらとも異なる値は上書きせず、全Subの切り戻しを開始前に止める。
    # 新規DCR本体ともともと存在したWaiverは残すため、照合からも除外する。
    # ---
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        foreach ($setting in @($record.OldSettings) + @($record.NewSettings)) {
            if ($setting.KeepOnRollback -or ($setting.Kind -eq 'Exemption' -and $setting.Before)) {
                continue
            }
            $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $setting.Kind
            $matchesBody = Test-Configuration $current $setting.Body -Exact
            $matchesBefore = Test-Configuration $current $setting.Before -Exact
            if ($current -and -not ($matchesBody -or $matchesBefore)) {
                throw "保存した値と異なる設定です: $($setting.Id)"
            }
        }
    }

    # ---
    # 全Subの旧DCR関連付け→旧診断設定をJSONのBodyで復元し、完了してから新設定をBeforeへ戻す。
    # 今回追加した診断設定・関連付け・Waiverは削除し、元からあったDCR・関連付けは変更前の値に戻す。
    # 保存先と保存済みログ、新規DCR本体、もともと存在したWaiverは残す。
    # ---
    foreach ($phase in @('Old', 'New')) {
        $kinds = @('Association', 'Diagnostic')
        if ($phase -eq 'New') {
            $kinds = @('Dcr', 'Association', 'Diagnostic', 'Exemption')
        }
        foreach ($kind in $kinds) {
            foreach ($record in $records) {
                $subscriptionId = $record.Target.SubscriptionId
                $settings = $record.OldSettings
                if ($phase -eq 'New') {
                    $settings = $record.NewSettings
                }
                foreach ($setting in @($settings | Where-Object Kind -eq $kind)) {
                    if ($setting.KeepOnRollback -or ($kind -eq 'Exemption' -and $setting.Before)) {
                        continue
                    }
                    # ---
                    # 戻す値は旧設定ならBody、新設定ならBeforeから選ぶ。Azureがすでにその値なら書き込まず次へ進む。
                    # 事前の照合後に別の値へ変わっていた場合も、その値を上書きせず停止する。
                    # ---
                    $expectedBody = $setting.Body
                    if ($phase -eq 'New') {
                        $expectedBody = $setting.Before
                    }
                    $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $kind
                    if (Test-Configuration $current $expectedBody -Exact) {
                        continue
                    }
                    if ($current -and ($phase -eq 'Old' -or
                        -not (Test-Configuration $current $setting.Body -Exact))) {
                        throw "切り戻し直前に設定が変わっています: $($setting.Id)"
                    }
                    # ---
                    # 削除済みの旧診断設定を戻す前に、親リソースの診断設定一覧を取得する。
                    # 上限5件に達していれば、ほかの診断設定を消さずに停止する。
                    # ---
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    # ---
                    # 戻す値がnullなら今回追加した設定をDELETEし、値があればその本体をPUTする。
                    # 同じIDをGETし直して復元値と照合し、一致しなければほかのSubを含む残りの処理を停止する。
                    # ---
                    if ($null -eq $expectedBody) {
                        $null = Invoke-ArmRequest -Resource $setting -Method Delete
                    }
                    else {
                        $null = Invoke-ArmRequest -Resource $setting -Method Put -Body $expectedBody
                    }
                    $current = Invoke-ArmRequest -Resource $setting -Optional -Wait
                    $current = Get-WritableBody $current $kind
                    if (-not (Test-Configuration $current $expectedBody -Exact)) {
                        throw "復元後の値を確認できません: $($setting.Id)"
                    }
                }
            }
        }
    }
}
catch {
    # ---
    # 停止したSub・設定ID・理由をrollback_failures.csvへ出し、例外を返す。
    # それ以前に復元できた設定は、再実行時に一致を確認してスキップする。
    # ---
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -Encoding utf8BOM
    throw
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
