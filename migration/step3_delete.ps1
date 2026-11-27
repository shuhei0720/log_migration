#Requires -Version 7.0

# ---
# 1. step2で全サブスクリプションの保存先と新設定を確認する。
# すべてOKの場合だけ、削除に使う作業記録を受け取る。
# ---
$records = @(& (Join-Path $PSScriptRoot 'step2_verify.ps1') -PassThru)
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv
$resource = $null
$failures = @()
# ---
# 2. 全サブスクリプションの旧DCR関連付けを削除し、その後に旧診断設定を削除する。
# 各設定の削除直前にも、旧設定と新設定が作業記録の値と同じか確認する。
# ---
foreach ($kind in @('Association', 'Diagnostic')) {
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        if ($subscriptionId -in $failures.SubscriptionId) {
            continue
        }
        try {
            foreach ($resource in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                # 削除する旧設定を読み直し、作業記録と同じ値か確認する。削除済みなら次へ進む。
                # 値が変わっていたら、このサブスクリプションの残りの削除を止める。
                $current = Invoke-ArmRequest -Resource $resource -Optional
                if (-not $current) {
                    continue
                }
                $currentBody = Get-WritableBody $current -Kind $kind
                if (-not (Test-Configuration $currentBody $resource.Body -Exact)) {
                    throw '削除直前に旧設定が変更されています。'
                }
                # 送信を続ける場合は、同じリソースの新診断設定・新DCR関連付けが作業記録どおりか確認する。
                # None・空欄は送信終了の指定なので、新設定を確認せず旧設定を削除する。
                $newId = ''
                if ($kind -eq 'Diagnostic' -and $record.Target.LogDestination -in @('Storage', 'Log')) {
                    $parentId = $resource.Id -replace "$diagnosticPath/[^/]+$", ''
                    $settingName = [Uri]::EscapeDataString($newDiagnosticSettingName)
                    $newId = "$parentId$diagnosticPath/$settingName"
                }
                if ($kind -eq 'Association' -and $record.Target.VmLogDestination -eq 'Log') {
                    $parentId = $resource.Id -replace "$associationPath/[^/]+$", ''
                    $dcrName = $record.Target.WorkspaceName -replace '^log', 'dcr'
                    $newId = "$parentId$associationPath/$dcrName"
                }
                if ($newId) {
                    $replacement = @($record.NewSettings | Where-Object Id -eq $newId)
                    if ($replacement.Count -ne 1) {
                        throw '新設定の記録がありません。'
                    }
                    $currentNew = Invoke-ArmRequest -Resource $replacement[0] -Optional
                    if (-not (Test-Configuration $currentNew $replacement[0].Body -Kind $kind)) {
                        throw '削除直前の新設定が記録と一致しません。'
                    }
                }
                $null = Invoke-ArmRequest -Resource $resource -Method Delete
            }
        }
        catch {
            # 失敗したSubの残りを止め、ほかのSubの削除は続ける。
            # 削除を止めた旧設定のID・理由・保存した設定値をdelete_failures.csvへ残す。
            $failures += [pscustomobject]@{
                SubscriptionId = $subscriptionId
                ResourceId = $resource.Id
                Reason = $_.Exception.Message
                Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
            }
            $failures | Export-Csv (Join-Path $PSScriptRoot 'delete_failures.csv') -Encoding utf8BOM
        }
    }
}
if ($failures.Count -gt 0) {
    throw '旧設定を削除できなかったサブスクリプションがあります。delete_failures.csvを確認してください。'
}
if (Test-Path (Join-Path $PSScriptRoot 'delete_failures.csv')) {
    Remove-Item (Join-Path $PSScriptRoot 'delete_failures.csv')
}
Write-Host '旧設定を削除しました。保存先と新設定は残しています。'
