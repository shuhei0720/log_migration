#Requires -Version 7.0
# ---
# このスクリプトの役割：step1/step3の途中・終了後に、記録した送信設定を変更前へ戻す。
# 旧設定を先に全件復元し、その後で新設定を解除・復元する順番にする。
# 保存先と保存済みログ、および切り戻し時に残す指定の新DCR本体は削除しない。
# 設定値はstep1の変更前記録から読む。元のCSVは読み直さない。
# ---
# paramは引数の宣言。[string[]]は文字列の配列で、複数のサブスクリプションIDを受け取る。
# 例：./rollback.ps1 -SubscriptionIds 'ID1', 'ID2'
# 引数を省略すると、この環境の記録がある全サブスクリプションを対象にする。
param([string[]]$SubscriptionIds)
# $PSBoundParametersは、呼び出し時に明示された引数を持つ辞書。
# ContainsKeyで「引数を指定したか」を保存する。空の一覧を指定した場合と、
# 引数を省略した場合を区別するため。commonをドットソースする前に判定しておく。
$subscriptionFilterProvided = $PSBoundParameters.ContainsKey('SubscriptionIds')
# 「. 」はドットソースで、commonの設定・関数を今のスコープへ読み込む。
# $PSScriptRootはこのファイルのフォルダ。-SkipCsvなので対象CSVは読み込まない。
# commonで指定した環境に対応するrecords/<環境名>の記録を、この後で選ぶ。
. (Join-Path $PSScriptRoot 'common.ps1') -SkipCsv

# ---
# 保存記録から、全体または指定したSubを選ぶ。
# まずJSONの「ファイル一覧」から対象を選ぶ。まだ記録の中身は読まない。
# Get-ChildItemはフォルダ内の列挙。-Filterで変更前記録のJSONだけに絞る。
# @()で、0件/1件でも件数や添字を扱える配列にする。
# 記録ファイル名は<サブスクリプションID>.jsonで、BaseNameは拡張子を除いた名前。
# ---
$recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
if ($subscriptionFilterProvided) {
    # 「|」は左の値を右へ渡すパイプ。Where-Object {条件}で必要な要素だけを残す。
    # ここでの$_は、一覧から渡された今の1件のサブスクリプションID。
    # -notinは「一覧に含まれない」。記録のないIDを$unknownIdsへ集める。
    # 引数が空、未知のIDがある、同じIDが重複する、のいずれもthrowで開始前に止める。
    # -eqは「等しい」、-gtは「より大きい」、-neは「等しくない」、-orは「または」。
    # Sort-Object -Uniqueで重複を除き、元の件数と比べて重複指定を見つける。
    $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
    if ($SubscriptionIds.Count -eq 0 -or $unknownIds.Count -gt 0 -or
        @($SubscriptionIds | Sort-Object -Unique).Count -ne $SubscriptionIds.Count) {
        throw '記録にあるSub IDを重複なく指定してください。'
    }
    # 検証済みの指定IDに合うファイルだけを残す。-inは「右の一覧に含まれるか」。
    # 中身を読む前に絞るため、対象外の記録に不備があっても指定対象の読み込みを妨げない。
    $recordFiles = @($recordFiles | Where-Object { $_.BaseName -in $SubscriptionIds })
}
# ---
# 選んだ記録を1件ずつ読み込む。@(...)の中のforeachが出力した記録を配列へ集める。
# Get-Content -Rawはファイル全体を1つの文字列にする。
# ConvertFrom-Json -AsHashtableでJSONを辞書へ戻し、$saved.Targetなどで値を読めるようにする。
# ファイル名と内部のSubscriptionIdが違う場合は、対象を取り違えないよう停止する。
# Read-MigrationRecordは環境・移行元・記録形式の整合性も確認して、記録を返す。
# ---
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
# 以後のAPI操作で失敗した対象を残すCSVの出力先。
# try内のエラーは末尾のcatchへ移り、記録を出して停止する。
# ここまでの対象指定・記録読込のエラーは、このtryの外なのでそのまま停止する。
$failurePath = Join-Path $PSScriptRoot 'rollback_failures.csv'
try {
    # ---
    # 外部で変わった同名設定を上書きしないよう、先に全件照合する。
    # 新規DCR本体と、もともとあったWaiverは変更しない。
    # 書き込みを始める前に、選んだ全サブスクリプションの旧設定・新設定を確認する。
    # OldSettingsは移行前の設定（Body）、NewSettingsは移行で適用した設定（Body）と
    # 適用前の状態（Before）を持つ。Before=$nullは「元は存在しなかった」を表す。
    # Destinations（ストレージやワークスペースなど）はこの一覧に含めず、切り戻しで触らない。
    # ---
    foreach ($record in $records) {
        $subscriptionId = $record.Target.SubscriptionId
        foreach ($setting in @($record.OldSettings) + @($record.NewSettings)) {
            # KeepOnRollbackが有効な設定は残す。新規作成したDCR本体などが該当する。
            # Exemptionはポリシー適用除外（Waiver）。Beforeがあれば元々あった除外なので触らない。
            # continueは、現在の設定の残りの処理を飛ばして次の設定へ進む命令。
            if ($setting.KeepOnRollback -or ($setting.Kind -eq 'Exemption' -and $setting.Before)) {
                continue
            }
            # GETして、比較できる書き込み用の本文へそろえる。
            # -Optionalは404だけを$nullへ変える。ほかのAPI失敗を無視する指定ではない。
            # Get-WritableBodyの第1引数はGET応答、第2引数はKind（設定の種類）。
            # 現在値がBodyかBeforeのどちらとも違う場合、外部で変更された可能性があるため止める。
            # すでに存在しない場合はこの照合を通し、後の復元処理で必要な状態へ戻す。
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
    # 切り戻しは2段階。配列の順にOldを最後まで終えてから、Newへ進む。
    # Old：選んだ全対象の旧DCR関連付け→旧診断設定を復元する。
    # New：新DCR→新関連付け→新診断設定→新規の適用除外を、必要に応じて変更前へ戻す。
    # New段階でもKeepOnRollbackや既存の適用除外は除外する。
    # 旧送信を戻す途中で失敗した場合は停止し、新送信の解除段階へ進まない。
    # ---
    foreach ($phase in @('Old', 'New')) {
        $kinds = @('Association', 'Diagnostic')
        if ($phase -eq 'New') {
            $kinds = @('Dcr', 'Association', 'Diagnostic', 'Exemption')
        }
        foreach ($kind in $kinds) {
            foreach ($record in $records) {
                $subscriptionId = $record.Target.SubscriptionId
                # phase（段階）に合わせ、今回処理する記録の一覧を選ぶ。
                # さらに下のWhere-ObjectでKindを絞り、種類ごとに全サブスクリプションを処理する。
                $settings = $record.OldSettings
                if ($phase -eq 'New') {
                    $settings = $record.NewSettings
                }
                # 「Where-Object Kind -eq $kind」は、Kindが今の種類と一致する設定を取り出す短い書き方。
                # この中の$settingは、これから切り戻す1件。KindとIdで操作先が決まる。
                foreach ($setting in @($settings | Where-Object Kind -eq $kind)) {
                    if ($setting.KeepOnRollback -or ($kind -eq 'Exemption' -and $setting.Before)) {
                        continue
                    }
                    # ---
                    # この設定が最後になるべき状態を選ぶ。
                    # OldではBody（移行前の旧設定）へ復元する。
                    # NewではBefore（新設定を適用する前の状態）へ戻す。
                    # Before=$nullなら元はなかったので、新規に追加した設定を削除することになる。
                    # ---
                    $expectedBody = $setting.Body
                    if ($phase -eq 'New') {
                        $expectedBody = $setting.Before
                    }
                    # 操作の直前にも現在値を再取得する。事前確認からの間に変わる可能性があるため。
                    # すでに期待値と一致していればcontinueで省略する。再実行で同じ処理を繰り返さない。
                    # -Exactは設定値を両方向に照合する共通関数の指定。
                    $current = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) $kind
                    if (Test-Configuration $current $expectedBody -Exact) {
                        continue
                    }
                    # ---
                    # 現在存在する設定を、確認せずに上書き・削除しないための条件。
                    # Oldで元の値と違うものがある場合は上書きしない。
                    # Newでは、変更前の値とは違っていても移行で適用したBodyと一致するなら切り戻せる。
                    # それ以外の値へ変わっていたらthrowで停止する。
                    # ---
                    if ($current -and ($phase -eq 'Old' -or
                        -not (Test-Configuration $current $setting.Body -Exact))) {
                        throw "切り戻し直前に設定が変わっています: $($setting.Id)"
                    }
                    # ---
                    # 存在しない診断設定を復元する場合は、診断設定数の上限も直前に確認する。
                    # -replaceでID末尾の設定名を除き、同じ親リソースの診断設定一覧をGETする。
                    # 既存設定が5件以上（-ge 5）なら空きがないので停止する。
                    # 空きを作るために無関係な診断設定を削除することはしない。
                    # ---
                    if ($kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
                        $listId = $setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
                        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
                        if (@($existing.value).Count -ge 5) {
                            throw "旧設定を戻す空きがありません: $($setting.Id)"
                        }
                    }
                    # ---
                    # 期待値が$nullならDELETE、値があればPUT（設定の作成・更新）を実行する。
                    # $null = ...はAPIの戻り値を画面などへ流さないための代入。操作は実行される。
                    # この1件が終わるたびにGETし直して、復元後の値を確認する。
                    # -Waitは作成・更新中の状態ならGETで完了を待つ共通関数の指定。
                    # -Optionalも付けるので、削除した場合は404→$nullを期待値と照合できる。
                    # 期待通りと確認できなければthrowし、以降の切り戻しを停止する。
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
# ---
# API操作・照合で失敗した場合は、サブスクリプションID、設定ID、理由をCSVへ保存する。
# catch内の$_は、直前に発生したエラー。パイプ内の「今の要素」とは文脈が違う。
# [pscustomobject]@{...}で1行分を作り、パイプでExport-Csvに渡す。
# utf8BOMは日本語を扱いやすい文字コード。末尾のthrowで同じエラーを外へ伝える。
# 完了済みの復元を自動で取り消す処理はない。記録を残したまま原因を確認する。
# ---
catch {
    [pscustomobject]@{
        SubscriptionId = $subscriptionId
        ResourceId = $setting.Id
        Reason = $_.Exception.Message
    } | Export-Csv $failurePath -Encoding utf8BOM
    throw
}
# ---
# 全件完了した場合だけ、前回の失敗CSVがあれば消す。
# 旧送信を復元し、新側を変更前へ戻した状態になる。元はなかった新送信・適用除外は解除する。
# 保存先と保存済みログは残る。KeepOnRollbackで残した新DCR本体もここでは削除しない。
# ---
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '切り戻しが完了しました。保存先と保存済みログは残しています。'
