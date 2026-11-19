# ---
# このファイルの読み方：Azureを変更する前の、任意の確認用スクリプト。
# 「どのSubを処理するか」はtargets.csv、「どの旧設定を探すか」はcommon.ps1から読む。
# ここでは調査結果をCSVへ出す。step1_copyで使う変更前記録は作らない。
# この確認を前日に行っても、step1_copyは実行時にもう一度調べる。
# 以下の#Requiresは説明ではなく、実行に必要なPowerShellのバージョン指定。
# ---
#Requires -Version 7.0
# ---
# 先頭の「. 」はドットソース：別ファイルの変数と関数を、この処理で使えるようにする。
# $PSScriptRootは「いまのps1が置かれたフォルダ」、Join-Pathはパスを組み立てる命令。
# common.ps1を読み終えると、CSV各行をまとめた$targetsと共通の5関数が使える。
# このファイルを上から読む場合は、最初にcommonの設定・CSV読込みだけ確認すればよい。
# ---
. (Join-Path $PSScriptRoot 'common.ps1')

# ---
# 現在の対象・名前・保存先を確認する
# 前回の記録は使わず、その時点のAzureを調べる。Azureの変更と記録の保存は行わない。
# ---
# ---
# $targetsの1行ずつを、今回処理する$targetへ入れて繰り返す。
# 例：$target.SubscriptionIdは対象SubのID、$target.StorageAccountはCSVのStorage名。
# foreach内で出力した結果行が、まとめて$resultsへ入る書き方になっている。
# ここで変わるのは調査先のSubで、複数Subを同時に変更する処理ではない。
# ---
$results = foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    # ---
    # try内で失敗が起きたら、このSubのcatchへ移る。
    # $null = ... は関数の戻り値を捨てる指定。ここでは計画の中身ではなく成否を使う。
    # Get-MigrationPlanは旧設定・地域・同名・追加枠・ポリシーなどを調べる共通処理。
    # -Targetは引数名、後ろの$targetは渡す値。スクリプト全体の設定値は変更しない。
    # ---
    try {
        $null = Get-MigrationPlan -Target $target
        # ---
        # @{}は「項目名と値」の組。ここではSub ID・結果・理由を1行にまとめる。
        # [pscustomobject]を付けると、その項目をCSVの列として扱いやすい形になる。
        # 下のオブジェクトは変数へ代入していないため、foreachの出力として$resultsへ入る。
        # ---
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'OK'
            Reason = '事前確認完了'
        }
    }
    # ---
    # 失敗したSubについても1行を残す。ほかのSubの確認は続ける。
    # catchの中の$_は「今回捕まえたエラー」。Exception.Messageがエラーの説明文。
    # 「NG」は調査に失敗したという記録で、設定の削除や切り戻しを行う指定ではない。
    # ---
    catch {
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Result = 'NG'
            Reason = $_.Exception.Message
        }
    }
}
# ---
# 「|」はパイプ：左側の結果行を、右側のCSV出力へ順に渡す。
# precheck_results.csvはこのps1と同じフォルダに作る。utf8BOMは日本語を含む保存形式。
# 画面表示だけで終わらせず、SubごとのOK/NGと理由を一覧で見られるようにする。
# ---
$results | Export-Csv (Join-Path $PSScriptRoot 'precheck_results.csv') -Encoding utf8BOM
# ---
# $results.Resultで全行の結果欄を取り出し、-containsでNGが含まれるか確認する。
# 1件でもNGならthrowでこのスクリプトを失敗として終了する。詳細は直前のCSVに残る。
# OKの場合もstep1へ自動で進む処理はない。利用者が次のスクリプトを別に実行する。
# ---
if ($results.Result -contains 'NG') {
    throw '事前確認に失敗しました。precheck_results.csvを確認してください。'
}
