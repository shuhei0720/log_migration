#Requires -Version 7.0

# ---
# 全対象を確認してから、旧関連、旧診断設定の順に削除する
# 保存先・新設定に未完了があれば、verifyが停止するため削除へ進まない。
# このスクリプトの役割：保存先・新設定を確認したうえで、記録した旧設定だけを外す。
# 対象は旧DCR関連付け（Association）と旧診断設定（Diagnostic）。VM自体は削除しない。
# 旧設定を外した後も、保存先・保存済みログ・新設定は残す。
# この実行前にstep2の結果と新設定を人が確認する、という作業手順を想定している。
# ---
# 「&」はパスで指定したスクリプトを実行する呼び出し演算子。
# ドットソースと違い、呼び出したスクリプト内の変数をこちらへ直接読み込まない。
# -PassThruでstep2から変更前記録を返してもらい、@()で配列にまとめる。
# step2がNGでthrowした場合、この代入が完了せず、旧設定の削除へは進まない。
$records = @(& (Join-Path $PSScriptRoot 'step2_verify.ps1') -PassThru)
# 共通設定・関数は「. 」で今のスコープへ読み込む（ドットソース）。
# 対象はstep2から受け取った記録で決まっているため、-SkipCsvでCSVの再読込を省く。
# $PSScriptRootはこのファイルのフォルダ。Join-Pathで同じ場所のcommon.ps1を指定する。
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv
# エラー時に報告する対象を初期化する。$nullは「値なし」。
# try内で失敗するとcatchへ移り、失敗箇所をCSVに出して再びthrowで停止する。
$resource = $null
try {
    # ---
    # foreachで、種類→サブスクリプション→旧設定の順に繰り返す。
    # 先に全対象の旧DCR関連付けを外し、その後で全対象の旧診断設定を外す。
    # @('Association', 'Diagnostic')は順番を持つ2件の配列。
    # ---
    foreach ($kind in @('Association', 'Diagnostic')) {
        foreach ($record in $records) {
            $subscriptionId = $record.Target.SubscriptionId
            # OldSettingsはstep1が保存した旧設定の一覧。新設定や無関係な設定はここに含めない。
            # 「|」で一覧をWhere-Objectへ渡し、Kindが今の種類と等しい（-eq）ものだけを取り出す。
            # @()で結果を配列にするので、0件ならこの繰り返しは実行されない。
            foreach ($resource in @($record.OldSettings | Where-Object Kind -eq $kind)) {
                # ---
                # 削除する直前にAzureの現在値をGETする。
                # -Optionalは404（存在しない）だけを$nullにする。ほかの失敗はエラーになる。
                # すでに削除済みならcontinueで次の旧設定へ進むので、途中からの再実行ができる。
                # ---
                $current = Invoke-ArmRequest -Resource $resource -Optional
                if (-not $current) {
                    continue
                }
                # GET応答には読み取り専用の項目もあるので、書き込める設定本文だけへそろえる。
                # 保存した旧Bodyと-Exactで比較し、step2の確認後に変更されていても削除を止める。
                # throwはその場で通常の処理を中断し、末尾のcatchへエラーを渡す。
                $currentBody = Get-WritableBody $current -Kind $kind
                if (-not (Test-Configuration $currentBody $resource.Body -Exact)) {
                    throw '削除直前に旧設定が変更されています。'
                }
                # ---
                # この旧設定に対応する新設定のIDを求める。送信を止める指定なら空欄のままにする。
                # -andは「かつ」、-inは「右の配列に含まれるか」。
                # LogDestinationがStorage/Logなら新診断設定が必要。
                # VmLogDestinationがLogなら、新DCRへの関連付けが必要。
                # None/空欄の側は新送信を作らず旧送信も終了するので、新設定の存在確認を省く。
                # ---
                $newId = ''
                if ($kind -eq 'Diagnostic' -and $record.Target.LogDestination -in @('Storage', 'Log')) {
                    # -replaceは文字列の置き換え。ここでは正規表現を使い、ID末尾の旧設定名を除く。
                    # 親リソースのIDへ、共通の新診断設定名を付け直して新設定のIDを組み立てる。
                    # EscapeDataStringは、設定名をURLの一部分として使える表記にする処理。
                    $parentId = $resource.Id -replace "$diagnosticPath/[^/]+$", ''
                    $settingName = [Uri]::EscapeDataString($newDiagnosticSettingName)
                    $newId = "$parentId$diagnosticPath/$settingName"
                }
                if ($kind -eq 'Association' -and $record.Target.VmLogDestination -eq 'Log') {
                    # VM/VMSS側も同じ考え方で、新DCR関連付けのIDを組み立てる。
                    # -replace '^log', 'dcr'は、ワークスペース名の先頭logをdcrへ替える命名規則。
                    $parentId = $resource.Id -replace "$associationPath/[^/]+$", ''
                    $dcrName = $record.Target.WorkspaceName -replace '^log', 'dcr'
                    $newId = "$parentId$associationPath/$dcrName"
                }
                # ---
                # 新送信を使う側では、削除直前に対応する新設定も再確認する。
                # 記録からId一致の設定を探し、ちょうど1件あること、Azure上の内容が一致することが必要。
                # $replacement[0]は配列の先頭。PowerShellの添字は0から始まる。
                # 記録がない・消えている・設定が違う場合は、旧設定を削除せず停止する。
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
                # 直前の照合を通った、この旧設定1件だけをDELETEする。
                # $null = ...は戻り値を捨てる書き方で、API呼び出し自体は実行する。
                $null = Invoke-ArmRequest -Resource $resource -Method Delete
            }
        }
    }
}
# ---
# 失敗した対象と理由をdelete_failures.csvへ出力し、以降の削除を止める。
# catch内の$_は今発生したエラー。$_.Exception.Messageが人向けの理由になる。
# Expectedには削除対象だった旧BodyをJSONとして残す。
# [pscustomobject]@{...}はCSVの1行分。項目名が列名になる。
# 「|」でExport-Csvへ渡し、日本語を扱えるUTF-8 BOM付きで保存する。
# 末尾のthrowは同じエラーを呼び出し元へ伝える。先に完了した削除は自動では戻さない。
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
# ここへ来るのは、記録された旧設定の削除または削除済みの確認を終えた場合。
Write-Host '旧設定を削除しました。保存先と新設定は残しています。'
