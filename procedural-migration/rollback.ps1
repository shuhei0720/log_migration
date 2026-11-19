#Requires -Version 5.1
param([string[]]$SubscriptionIds)
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# 保存記録から、全体または指定したSubを選ぶ。
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
    $saved = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
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
    # 旧関連→旧診断を全件復元した後で、新側を変更前へ戻す。
    # 各書込みをGETで確認し、失敗した時点で以降の処理を止める。
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
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $setting.ApiVersion
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    if ($null -eq $expectedBody) {
                        $null = Invoke-ArmRequest -Resource $setting -Method Delete
                    }
                    else {
                        $null = Invoke-ArmRequest -Resource $setting -Method Put -Body $expectedBody
                    }
                    $deadline = (Get-Date).AddMinutes(5)
                    do {
                        $current = Invoke-ArmRequest -Resource $setting -Optional
                        if ($current.properties.provisioningState -notin @('Creating', 'Updating', 'Accepted')) {
                            break
                        }
                        Start-Sleep -Seconds 2
                    } while ((Get-Date) -lt $deadline)
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
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -NoTypeInformation -Encoding UTF8
    throw
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
