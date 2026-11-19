#Requires -Version 7.0
# ---
# このスクリプトの役割：step1で作った保存先・新設定がそろったかを確認する。
# Azureの設定は変更せず、結果をverify_results.csvにまとめる。
# step3_delete.ps1からも呼ばれ、1件でもNGがあれば削除へ進ませない。
# common.ps1の設定とCSV、およびstep1が保存した変更前記録を使う。
# ---
# paramはスクリプトの引数の宣言。[switch]は、付けると有効になる引数。
# 通常は確認完了の表示だけを行う。-PassThruを付けると、全件OKの場合に
# 変更前記録を呼び出し元へ返す。step3はその記録を使って旧設定を削除する。
param([switch]$PassThru)
# ---
# 必要な設定と共通関数を、今のスクリプト内へ読み込む。
# 先頭の「. 」はドットソース。別スクリプトの変数・関数をここで使えるようにする。
# $PSScriptRootはこのファイルのフォルダ。Join-Pathでcommon.ps1のパスを組み立てる。
# -SkipCsvを付けていないので、common側でCSVを読み、$targetsに対象行を準備する。
# ---
. (Join-Path $PSScriptRoot 'common.ps1')
# @()は配列（複数の値を入れる一覧）。最初は空にし、後で「+=」で要素を追加する。
# $results：各確認のOK/NG行。$records：step1の記録をサブスクリプションごとに集める。
$results = @()
$records = @()

# ---
# 記録後に増えた旧設定や、変更された旧設定を確認する
# 削除済みの旧設定は許可し、保存先・新設定は記録した全対象を確認する。
# ---
# foreachは一覧から1件ずつ取り出す繰り返し。$targetはCSVの1行に相当する。
# try内でthrowやAPIエラーが発生すると、対応するcatchへ移る。
# ここでは外側のcatchでサブスクリプション単位のNGを残し、次の対象も確認する。
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    try {
        # ---
        # このサブスクリプションの変更前記録を読み、実行条件との一致も確認する。
        # 記録の主な項目はTarget（対象と送信先）、OldSettings（旧設定）、
        # Destinations（保存先）、NewSettings（新設定）。各設定にはId・Kind・Bodyがある。
        # IdはAzure上の識別子、Kindは処理用の種類、Bodyは設定する内容を表す。
        # 記録がない場合は、確認基準がないためthrowでこの対象の確認を中断する。
        # ---
        $record = Read-MigrationRecord -Target $target
        if (-not $record) {
            throw 'step1の変更前記録がありません。'
        }
        # ---
        # Azureを再調査し、現在残っている旧診断設定・旧DCR関連付けだけを取り出す。
        # -OnlyOldSettingsなので、ここでは新設定の計画を組み直さず、旧設定の変化を調べる。
        # 記録後に対象が増えたり、旧設定の内容が変わったりしていればNGにする。
        # すでに削除済みの旧設定は一覧に出ないため許可する。step3の再実行にも必要な扱い。
        # ---
        $currentPlan = Get-MigrationPlan -Target $target -Record $record -OnlyOldSettings
        foreach ($current in $currentPlan.OldSettings) {
            # 「|」は左の結果を右の処理へ渡すパイプ。
            # Where-Object Id -eq ...は、Idが右辺と等しい要素だけを残す絞り込み。
            # @()で結果を配列にし、0件や1件でも.Count（件数）で扱えるようにする。
            # -neは「等しくない」、-orは「または」、-notは条件の反転。
            # 保存記録がちょうど1件で、Bodyが-Exact（両方向の比較）で一致することが必要。
            $saved = @($record.OldSettings | Where-Object Id -eq $current.Id)
            if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
                throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
            }
        }
        # ---
        # 保存先と新設定を1つの一覧として、記録された全件を確認する。
        # 「配列 + 配列」は一覧の連結。$resourceは今確認している1件の記録。
        # 内側のtry/catchで1件のNGを記録し、同じサブスクリプションの残りも確認する。
        # ---
        foreach ($resource in @($record.Destinations) + @($record.NewSettings)) {
            try {
                # GETでAzureの現在値を取得する。-Methodを省略したときの共通関数の動作はGET。
                # -Optionalは「存在しない」という404応答だけを$null（値なし）として扱う。
                # それ以外のAPI失敗まで成功扱いにする指定ではない。
                $current = Invoke-ArmRequest -Resource $resource -Optional
                $expected = $resource.Body
                # Bodyが期待値。リソースグループは既存のものを使う場合もあるので、
                # 空の辞書@{}を期待値にして存在を確認し、作成済みグループの場所などは強制しない。
                # @{ 名前 = 値 }は辞書（ハッシュテーブル）。@()の配列とは用途が異なる。
                if ($resource.Kind -eq 'Group') {
                    $expected = @{}
                }
                # ---
                # 種類に応じて必要な設定値を照合する。存在しない場合も一致にはならない。
                # 診断設定・DCR・関連付けは書き込める項目へそろえて一致を調べる。
                # ライフサイクルなどは共通関数の種類別ルールで確認する。
                # Tableでは合計保持期間が既定値任せになっていないことも、追加で確認する。
                # 不一致ならthrowし、下のcatchでこのリソースのNG行を作る。
                # ---
                if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                    ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                    throw '必要な設定がないか、予定の値と異なります。'
                }
                # 1行分の結果を、名前付き項目を持つオブジェクトにして配列へ追加する。
                # [pscustomobject]@{...}の各項目名が、最後に出力するCSVの列名になる。
                # OKの行はReasonを「一致」とし、手動設定用のExpectedは空欄にする。
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'OK'
                    Reason = '一致'
                    Expected = ''
                }
            }
            # ---
            # このリソースの取得・照合に失敗した場合の記録。
            # catch内の$_は、今捕まえたエラー。$_.Exception.Messageで理由の文字列を取り出す。
            # Expectedには予定のBodyをJSON文字列で残し、原因調査や手動設定の参考にする。
            # -Depth 40で深い階層も含め、-CompressでCSVのセルへ入れやすい1行のJSONにする。
            # ---
            catch {
                $results += [pscustomobject]@{
                    SubscriptionId = $subscriptionId
                    ResourceId = $resource.Id
                    Result = 'NG'
                    Reason = $_.Exception.Message
                    Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
                }
            }
        }
        # 変更前記録も集める。途中にNGがあった場合は、最後にthrowするため、
        # この一覧がstep3へ渡されるのは全体の確認にNGがない場合だけ。
        $records += $record
    }
    # 記録の読み込みや旧設定の再調査など、サブスクリプション全体の確認に失敗した場合。
    # 特定の保存先1件の問題ではないため、ResourceIdは空欄のNG行を作る。
    catch {
        $results += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = ''
            Result = 'NG'
            Reason = $_.Exception.Message
            Expected = ''
        }
    }
}
# ---
# 全確認の結果を、このスクリプトと同じフォルダのCSVへ出力する。
# パイプで各結果行をExport-Csvへ渡す。utf8BOMは日本語を扱いやすい文字コード。
# -containsは配列に指定値が含まれるかの判定。NGが1つでもあればthrowで停止する。
# CSVの出力後に停止するため、失敗理由と期待値はファイルで確認できる。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'verify_results.csv') -Encoding utf8BOM
if ($results.Result -contains 'NG') {
    throw '未完了の設定があります。verify_results.csvを確認してください。'
}
# ---
# ここまで来たら全件OK。-PassThruの有無で、呼び出し元への返し方を切り替える。
# PowerShellでは「$records」とだけ書くと、配列の要素が実行結果として出力される。
# 通常実行ではWrite-Hostで確認完了を画面に表示する。
# ---
if ($PassThru) {
    $records
}
else {
    Write-Host '全件確認が完了しました。'
}
