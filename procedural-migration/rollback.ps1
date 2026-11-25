#Requires -Version 7.0
# SubscriptionIdsで切り戻すSubを選ぶ。省略時は保存済みJSONの全Subが対象。
param([string[]]$SubscriptionIds)
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# records/<環境>/<SubID>.jsonから旧設定・新設定と変更前のBeforeを読む。CSVは使わない。
# JSONのSubIDとファイル名、記録した環境と実行環境が一致するか確認する。
# ---
$recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
if ($subscriptionFilterProvided) {
    $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
    # 空指定・記録にないID・重複は停止し、指定したSubだけを確実に戻す。
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
    # 旧設定・新設定をAzureから取得し、JSONのBody（設定値）かBefore（変更前）と照合する。どちらとも違えば全Subの開始を止める。
    # 残しておく新規DCR本体と既存Waiverは、照合しない。
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
    # 全Subの旧DCR関連付け→旧診断設定をBodyで復元してから、新設定をBeforeへ戻す。Beforeがなければ削除する。
    # 保存先・保存済みログ・新規DCR本体・既存Waiverは残す。
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
                    # 旧設定はBody、新設定はBeforeへ戻す。一致済みはスキップし、事前確認後に変わっていれば停止する。
                    # ---
                    $expectedBody = $setting.Body
                    if ($phase -eq 'New') {
                        $expectedBody = $setting.Before
                    }
                    $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $kind
                    if (Test-Configuration $current $expectedBody -Exact) {
                        continue
                    }
                    # 復元値と違う旧設定は上書きしない。新設定も今回の作成値と一致する場合だけ戻す。
                    if ($current -and ($phase -eq 'Old' -or
                        -not (Test-Configuration $current $setting.Body -Exact))) {
                        throw "切り戻し直前に設定が変わっています: $($setting.Id)"
                    }
                    # ---
                    # 診断設定を戻す空き枠を確認する。上限5件なら、ほかの設定を消さずに停止する。
                    # ---
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    # ---
                    # 戻す値がnullならDELETE、値があればPUTする。再取得して復元値と照合し、不一致なら全Subの残りを止める。
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
    # 停止したSub・設定ID・理由をrollback_failures.csvへ出す。再実行では復元済みの設定をスキップする。
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
