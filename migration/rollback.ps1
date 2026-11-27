#Requires -Version 7.0
# SubscriptionIdsで戻すサブスクリプションを選ぶ。省略すると、この環境で記録した全サブスクリプションを戻す。
param([string[]]$SubscriptionIds)
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# 1. 切り戻すサブスクリプションの作業記録をJSONから読み込む。CSVは使わない。
# 記録のサブスクリプションIDとファイル名を比べ、環境と移行元も今回の指定と同じか確認する。
# ---
$recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
if ($subscriptionFilterProvided) {
    $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
    # 指定したIDが空・重複・記録にない場合は止める。誤って別のサブスクリプションを戻さないため。
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
$failures = @()
$failedSubscriptions = @()
try {
    # ---
    # 2. 切り戻す設定の現在値を調べ、記録後に別の変更が入っていないか確認する。
    # 保存した設定値（Body）・作業前の値（Before）のどちらとも違えば、Azureへ書き込む前に止める。
    # ---
    # 設定がない場合も許可する。今回作成したDCR本体と元からある適用除外は、残すため比較しない。
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
    # 3. 全対象の旧DCR関連付けと旧診断設定を復元してから、新設定を作業前の状態へ戻す。
    # 旧設定の復元に失敗したSubは新設定を残して止め、ほかのSubは続ける。保存先と保存済みログも残す。
    # ---
    foreach ($phase in @('Old', 'New')) {
        $kinds = @('Association', 'Diagnostic')
        if ($phase -eq 'New') {
            $kinds = @('Dcr', 'Association', 'Diagnostic', 'Exemption')
        }
        foreach ($kind in $kinds) {
            foreach ($record in $records) {
                $subscriptionId = $record.Target.SubscriptionId
                if ($subscriptionId -in $failedSubscriptions) {
                    continue
                }
                $setting = $null
                try {
                    $settings = $record.OldSettings
                    if ($phase -eq 'New') {
                        $settings = $record.NewSettings
                    }
                    foreach ($setting in @($settings | Where-Object Kind -eq $kind)) {
                        if ($setting.KeepOnRollback -or ($kind -eq 'Exemption' -and $setting.Before)) {
                            continue
                        }
                        # 旧設定は削除前のBody、新設定は作業前のBeforeへ戻す。すでに同じ値なら変更しない。
                        $expectedBody = $setting.Body
                        if ($phase -eq 'New') {
                            $expectedBody = $setting.Before
                        }
                        $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $kind
                        if (Test-Configuration $current $expectedBody -Exact) {
                            continue
                        }
                        # 旧設定が別の値に変わっていたら止める。新設定も、今回作成した値と同じ場合だけ戻す。
                        if ($current -and ($phase -eq 'Old' -or
                            -not (Test-Configuration $current $setting.Body -Exact))) {
                            throw "切り戻し直前に設定が変わっています: $($setting.Id)"
                        }
                        # 診断設定が上限5件に達していたら、ほかの設定を消さずに止める。旧設定を追加できないため。
                        if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                            $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                            $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                            if (@($existing.value).Count -ge 5) {
                                throw "旧設定を戻す空きがありません: $($setting.Id)"
                            }
                        }
                        # 作業開始前に存在しなかった新設定は削除する。もともとあった設定は、記録した値で作成・更新する。
                        # Azureから読み直して戻すはずの値と比べ、違っていればこのSubの残りの切り戻しを止める。
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
                catch {
                    # このSubの残りの復元と新設定の処理を止め、ほかのSubへ進む。
                    $failures += [pscustomobject]@{
                        SubscriptionId = $subscriptionId
                        ResourceId = $setting.Id
                        Reason = $_.Exception.Message
                    }
                    $failedSubscriptions += $subscriptionId
                }
            }
        }
    }
}
catch {
    # 復元を止めたサブスクリプション・設定ID・理由をrollback_failures.csvへ保存する。
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -Encoding utf8BOM
    throw
}
if ($failures.Count) {
    $failures | Export-Csv $failurePath -Encoding utf8BOM
    throw "未完了のSubがあります。$failurePath を確認して再実行してください。"
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
