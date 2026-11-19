#Requires -Version 7.0
# ---
# step1・step3の途中または終了後に、送信設定を変更前へ戻す。
# 旧設定を全件戻してから新設定を解除する。保存先・ログ・新規DCR本体は残す。
# SubscriptionIds省略は全記録、指定時はそのSubだけ。現在のCSVは読まない。
# ---
param([string[]]$SubscriptionIds)
# ---
# 引数を省略した場合と、誤って空の一覧を指定した場合を区別する。
# ---
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# 保存記録から、全体または指定したSubを選ぶ。
# 中身を読む前にファイル名で選び、対象外の壊れたJSONに影響されないようにする。
# ---
$recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
if ($subscriptionFilterProvided) {
    # ---
    # 指定IDが記録にあるか確認し、空指定・未知のID・重複は作業前に止める。
    # ---
    $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
    if ($SubscriptionIds.Count -eq 0 -or $unknownIds.Count -gt 0 -or
        @($SubscriptionIds | Sort-Object -Unique).Count -ne $SubscriptionIds.Count) {
        throw '記録にあるSub IDを重複なく指定してください。'
    }
    $recordFiles = @($recordFiles | Where-Object { $_.BaseName -in $SubscriptionIds })
}
# ---
# 選択した記録だけを読み、ファイル名のSub IDと内容を照合する。
# 保存済みTargetでRead-MigrationRecordを呼び、環境などのContextも確認する。
# ---
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
    # 外部で変わった同名設定を上書きしないよう、先に全件照合する。
    # 新規DCR本体と、もともとあったWaiverは変更しない。
    # Bodyが今回の適用値、Beforeが変更前。どちらにも合わない現在値は作業外の変更とする。
    # ---
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        foreach ($setting in @($record.OldSettings) + @($record.NewSettings)) {
            # ---
            # 新規DCR本体と元からあったWaiverは残し、切り戻しの変更対象から外す。
            # ---
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
    # 旧関連→旧診断を全件復元した後で、新側を変更前へ戻す。
    # 各書込みをGETで確認し、失敗した時点で以降の処理を止める。
    # 旧設定の復元がどこかで失敗したらNew段階へ進まず、新送信を残す。
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
                    # Oldは旧Bodyを復元し、NewはBeforeへ戻す。Beforeがnullなら新規分なので削除する。
                    # ---
                    $expectedBody = $setting.Body
                    if ($phase -eq 'New') {
                        $expectedBody = $setting.Before
                    }
                    # ---
                    # 直前にも再取得し、すでに期待値どおりなら省略する。途中からの再実行でも同じ扱い。
                    # ---
                    $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $kind
                    if (Test-Configuration $current $expectedBody -Exact) {
                        continue
                    }
                    # ---
                    # 外部で変わった現在値は上書きせず停止する。New側は今回適用したBodyとの一致も必要。
                    # ---
                    if ($current -and ($phase -eq 'Old' -or
                        -not (Test-Configuration $current $setting.Body -Exact))) {
                        throw "切り戻し直前に設定が変わっています: $($setting.Id)"
                    }
                    # ---
                    # 旧診断設定が消えている場合は、復元先の上限5件に空きがあるか直前にも確認する。
                    # ---
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    # ---
                    # BeforeがnullならDELETE、値があればPUTし、GETで復元結果を確認する。
                    # この1件の確認に失敗すれば停止し、後続やNew段階へは進めない。
                    # 復元後の照合もBeforeまたは旧Bodyとの完全一致で行う。
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
# ---
# 失敗した対象と理由をrollback_failures.csvへ保存し、その時点で停止する。
# ---
catch {
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -Encoding utf8BOM
    throw
}
# ---
# 全件完了した場合だけ過去の失敗CSVを消す。保存先と保存済みログは保持する。
# ---
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
