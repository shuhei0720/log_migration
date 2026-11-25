#Requires -Version 7.0
# SubscriptionIdsで戻すサブスクリプションを選ぶ。省略すると、この環境で記録した全サブスクリプションを戻す。
param([string[]]$SubscriptionIds)
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# 環境別JSONから、旧設定・新設定・変更前の値（Before）を読む。CSVは使わない。
# サブスクリプションIDとファイル名を比べ、環境・移行元の指定も作業記録と同じか確認する。
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
try {
    # ---
    # Azureの現在値を、作業記録の設定値（Body）・変更前の値（Before）と比べる。
    # どちらとも違う変更があれば、復元を始めずに止める。設定がない場合は続行する。
    # 残す新設DCR本体と元からある適用除外は、この確認から外す。
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
    # 全サブスクリプションの旧DCR関連付けと旧診断設定を戻してから、新設定を変更前へ戻す。
    # 旧設定の復元に失敗したら、新設定を残して止める。
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
                    # 旧設定は保存した設定値（Body）へ、新設定は変更前の値（Before）へ戻す。すでに同じなら書き換えない。
                    # ---
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
                    # ---
                    # 診断設定は1リソースにつき最大5件。復元する空きがなければ、ほかの設定を消さずに止める。
                    # ---
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    # ---
                    # 作業開始前に存在しなかった新設定は削除する。もともとあった設定は、記録した値で作成・更新する。
                    # Azureから読み直して戻すはずの値と比べ、違っていれば残りの切り戻しを止める。
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
    # 失敗したサブスクリプション・設定ID・理由をrollback_failures.csvへ保存する。再実行では、戻し終えた設定を省く。
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
