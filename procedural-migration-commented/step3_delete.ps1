#Requires -Version 7.0

# ---
# 全対象を確認してから、旧関連、旧診断設定の順に削除する
# 保存先・新設定に未完了があれば、verifyが停止するため削除へ進まない。
# 旧関連付けと旧診断設定だけを外す。VM・保存先・ログ・新設定は残す。
# ---
# ---
# step2を全Sub分再実行する。NGが1件でもあれば、以降の削除は開始しない。
# 人が先にstep2の結果を確認していても、実行時に確認し直す。
# ---
$records = @(& (Join-Path $PSScriptRoot 'step2_verify.ps1') -PassThru)
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv
$resource = $null
try {
    # ---
    # 全Subの旧DCR関連付けを先に外し、その後で全Subの旧診断設定を外す。
    # ---
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            foreach ($resource in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                # ---
                # 削除直前に現在値を取得する。削除済みなら省略し、途中からの再実行に対応する。
                # ---
                $current = Invoke-ArmRequest -Resource $resource -Optional
                if (-not $current) {
                    continue
                }
                # ---
                # 現在の旧Bodyが記録と完全一致しなければ、作業外の変更として削除を止める。
                # ---
                $currentBody = Get-WritableBody $current -Kind $kind
                if (-not (Test-Configuration $currentBody $resource.Body -Exact)) {
                    throw '削除直前に旧設定が変更されています。'
                }
                # ---
                # 対応する新設定のIDを求める。診断はStorage/Log、VM側はLogなら新設定が必要。
                # None・空欄の側は新送信を作らず旧送信も終了するため、新設定確認を省く。
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
                # ---
                # 新送信を使う側は、記録と現在値の一致を削除直前にも確認する。
                # 新設定がない・変わっている場合は、対応する旧設定を残して停止する。
                # ---
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
# ---
# 最初の失敗で削除を止め、対象・理由・旧Bodyをdelete_failures.csvへ出す。
# すでに完了した削除は自動で戻さない。必要ならrollbackを実行する。
# ---
catch {
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $resource.Id
        Reason = $_.Exception.Message
        Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
    } | Export-Csv (Join-Path $PSScriptRoot 'delete_failures.csv') -Encoding utf8BOM
    throw
}
Write-Host '旧設定を削除しました。保存先と新設定は残しています。'
