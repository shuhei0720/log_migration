#Requires -Version 7.0

# ---
# step2で全Subの保存先・新設定を確認し、全件OKのときだけ記録JSONを$recordsで受け取る。
# 記録のIDを使い、全Subの旧DCR関連付け→旧診断設定の順に削除する。
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
                # 旧設定をAzureから読み直してJSONと照合する。削除済みはスキップし、変更されていれば全Subの残りを止める。
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
                # 送信を続ける側は、同じ親リソースの新診断設定・DCR関連付けもAzureから取得し、JSONと照合する。
                # 空欄・Noneの側は送信を終了するため、新設定の確認なしで旧設定を削除する。
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
    # 失敗した旧設定のID・理由・変更前の値をdelete_failures.csvへ出し、全Subの残りの削除を止める。
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
