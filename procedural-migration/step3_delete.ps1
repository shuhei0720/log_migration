#Requires -Version 7.0

# ---
# step2_verifyを呼び、全Subの保存先・新診断設定・DCR関連などをAzureで確認する。NGがあれば削除を開始しない。
# 全件OKなら、SubごとのJSONから旧診断設定・旧DCR関連付けのIDと本体を$recordsで受け取る。
# このIDを次のループで使い、全Subの旧DCR関連付けを削除してから、旧診断設定を削除する。
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
                # JSONのIDで旧設定を読み直し、送信先・ログ種別やDCRの関連先が保存値と同じか確認する。
                # 削除済みなら次へ進み、別の内容に変わっていれば以降の削除を止める。
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
                # 診断設定をStorage/Log、VM側をLogにした場合は、旧設定の親IDから新診断設定・新DCR関連付けのIDを求める。
                # そのIDをAzureから取得しJSONの作成値と照合する。空欄・Noneの側は新設定を作らないため、照合せず旧設定を削除する。
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
    # エラーになった旧設定のID・理由・変更前の値をdelete_failures.csvへ出す。
    # 例外を返し、ほかのSubを含む残りの削除を停止する。
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
