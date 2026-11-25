#Requires -Version 7.0

# ---
# step2で全サブスクリプションの保存先・新設定を確認し、すべてOKなら削除に使う作業記録を受け取る。
# 全サブスクリプションの旧DCR関連付けを削除してから、旧診断設定を削除する。
# ---
$records = @(& (Join-Path $PSScriptRoot 'step2_verify.ps1') -PassThru)
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv
$resource = $null
try {
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($resource in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                # ---
                # 削除する旧設定を読み直し、作業記録と同じ値か確認する。削除済みなら次へ進む。
                # 値が変わっていたら、ほかのサブスクリプションも含めて以降の削除を止める。
                # ---
                $current = Invoke-ArmRequest -Resource $resource -Optional
                if (-not $current) {
                    continue
                }
                $currentBody = Get-WritableBody $current -Kind $kind
                if (-not (Test-Configuration $currentBody $resource.Body -Exact)) {
                    throw '削除直前に旧設定が変更されています。'
                }
                # ---
                # 送信を続ける場合は、同じリソースの新診断設定・新DCR関連付けが作業記録どおりか確認する。
                # None・空欄は送信終了の指定なので、新設定を確認せず旧設定を削除する。
                # ---
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
    }
}
catch {
    # ---
    # 削除できなかった旧設定のID・理由・記録した設定値をdelete_failures.csvへ保存する。
    # ほかのサブスクリプションも含め、残りの削除は実行しない。
    # ---
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $resource.Id
        Reason = $_.Exception.Message
        Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
    } | Export-Csv (Join-Path $PSScriptRoot 'delete_failures.csv') -Encoding utf8BOM
    throw
}
Write-Host '旧設定を削除しました。保存先と新設定は残しています。'
