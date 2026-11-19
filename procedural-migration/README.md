# 手続型の移行スクリプト

このフォルダが移行スクリプトの正本です。既存の `migration` と原本は比較用に残しています。このフォルダはPowerShell 7と、ログイン済みのAzure CLI 2.54以降を使用します。Windows PowerShell 5.1では実行できません。Windowsでの推奨版はPowerShell 7.6 LTSです。

コードを上から読み進めるための説明は、[学習ガイド](CODE_LEARNING.md)にまとめています。

## 読む順番

|ファイル|役割|
|---|---|
|common.ps1|設定値、CSVの読込み、複数工程で繰り返す5つの処理|
|precheck.ps1|任意の事前確認。Azureを変更せず、変更前記録も作らない|
|step1_copy.ps1|Subごとの直前調査→変更前記録→適用除外→保存先→新送信設定|
|step2_verify.ps1|現在の旧設定と、記録した保存先・新設定を全件確認|
|step3_delete.ps1|確認版を実行し、全件成功後に旧関連→旧診断設定を削除|
|rollback.ps1|旧設定を先に復元し、新送信設定を戻す。保存先とログは保持|

共通の5関数は次の用途に限定します。

|関数|共通にする理由|
|---|---|
|Invoke-ArmRequest|各工程で使う認証・HTTP送信・必要な再試行・更新完了待ち|
|Test-Configuration|現在値と記録した設定値の比較|
|Get-WritableBody|GET応答から保存・復元用の本文を取り出す|
|Read-MigrationRecord|環境・入力の一致を確認して変更前記録を読む|
|Get-MigrationPlan|現在の旧設定を探索し、名前・追加枠・地域を調べる|

各入口には関数を置かず、処理順に記述しています。`step3_delete.ps1`は`step2_verify.ps1`の確認処理をそのまま実行するため、同じ確認コードを二重に持ちません。前日にprecheckを実行しても、copyは当日の状態を再調査します。

## 並列にする処理

サブスクリプションはCSVの順に処理します。各Subで、リソースごとの診断設定の調査と、新しい診断設定の複製だけを最大5件ずつ並列に実行します。PowerShell 7の`ForEach-Object -Parallel`を使い、別プロセスの起動やジョブの管理は行いません。

変更前記録の保存、適用除外、保存先、新DCR・関連付けは順番に処理します。全準備が成功してから診断設定を複製します。並列処理は全件の結果が戻ったことも確認し、失敗した対象を親の処理でCSVにまとめます。削除と切り戻しも順次処理し、途中の失敗で停止します。

## 設定と実行

`common.ps1`先頭の移行元ワークスペースIDと環境を指定します。新しい診断設定名も同じ場所です。API版・URLの対応表は内部の固定値なので変更不要です。旧DCRとポリシー割り当ては提示された本番・検証・開発の値です。

入力例を`targets.csv`へコピーし、対象サブスクリプション・保存先名を記入します。

```powershell
Copy-Item .\procedural-migration\targets.example.csv .\procedural-migration\targets.csv
pwsh.exe -NoProfile -File .\procedural-migration\precheck.ps1
pwsh.exe -NoProfile -File .\procedural-migration\step1_copy.ps1
pwsh.exe -NoProfile -File .\procedural-migration\step2_verify.ps1
# 確認結果を人が確認してから実行する。
pwsh.exe -NoProfile -File .\procedural-migration\step3_delete.ps1
```

|列|指定内容|
|---|---|
|SubscriptionName|対象SubのID、または一意の名前|
|ResourceGroup|保存先のRG名。全行で必須|
|StorageAccount|`jpe`を1か所含む小文字英数字3〜24文字。Storage宛ては必須|
|WorkspaceName|準備するLog Analytics名。全行で必須|
|LogDestination|新診断設定：Storage / Log / None / 空欄|
|VmLogDestination|新DCR・VM/VMSS関連付け：Log / None / 空欄。列がない旧CSVはLog|

**None・空欄は新設定を作らず、最後に旧設定を外して送信を終了する指定です。** 保存先は省略しません。Storage名があれば地域別に作成し、旧診断対象がなければ東日本に1つ準備します。Event/Syslogの総保持とStorageのappendBlob削除は1,095日です。

## 記録と再実行

必要な変更前情報と確認する設定を、`records/<環境>/<Sub ID>.json`へ保存します。新しい形式なので、既存`migration`のバックアップとは混在させません。ログデータは記録しません。

記録は`Destinations`（保存先）、`NewSettings`（新送信設定・適用除外）、`OldSettings`（旧送信設定）の3一覧です。それぞれの項目を同じ形で扱うことで、サービスごとのコピー・削除処理を増やさずに済みます。

|項目|意味|
|---|---|
|Id|操作するAzureリソースID|
|Kind|診断設定・DCR・Storageなど、このコード内の用途。API版はcommonの対応表で選ぶ|
|Body|設定・照合・復元に使う値|
|Before|変更前の値。元からなければnull。再実行でも最初の値を保持|
|KeepOnRollback|新規DCR本体を切り戻し時も残す指定|

途中停止時は同じCSV・設定のままcopyを再実行します。最初のBeforeは上書きせず、新しい対象だけ追加します。既に一致する設定は書き込みません。失敗した対象と期待する値は`copy_failures.csv`、全件確認は`verify_results.csv`へ出します。

初回の同名Storage・同名診断設定は事前に停止します。途中からの再実行では、自分の変更前記録に載っている対象だけを再開に使います。

```powershell
# 全体の切り戻し
pwsh.exe -NoProfile -File .\procedural-migration\rollback.ps1
# 指定Subだけを戻す場合は、PowerShellから呼ぶ。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'
```

指定Subの例はPowerShell 7のコンソールから実行します。

切り戻しは保存先と保存済みログを残します。今回作成したDCR本体も残し、変更した既存DCR・関連付けはBeforeに戻します。新設の適用除外だけを解除し、元からある除外は残します。

## 文字数の比較

コメントを除いたコード・設定値・空白・改行を、既存版と同じ条件で数えます。PowerShell Parserで通常のコメントを取り除き、文字列中の`#`や実行指示の`#Requires`は残します。日本語の説明コメントはコード内に維持します。

|項目|既存版|前回の手続型版|PowerShell 7版|
|---|---:|---:|---:|
|コメント以外の文字数|117,245|53,864|53,646|
|独自関数|25|5|5|
|1行に詰めたif・foreach・while|比較対象外|0|0|

コード部分は既存版から54.24％減です。前回からは218文字（0.40％）減で、並列処理と結果の件数確認を追加した分も含みます。**当初の10分の1という目標には未達です。** ユーザー確認により、機能と読みやすさを維持して可能な限り削減する方針です。変数名の短縮や1行への詰め込み、コードの別ファイルへの逃がしは行っていません。詳しい計測値は[文字数比較](../test-results/procedural-size.json)に記録しています。

[PowerShell 7版の72ケース・992判定](../test-results/PROCEDURAL_CASES.md)はLinuxと[Windows上のPowerShell 7.6.10](../test-results/procedural-windows7.json)で成功しました。実際の並列runspaceから外部API応答を再生し、一部失敗後の再実行も確認しています。固定した7ファイルの前後ハッシュが一致し、構文エラーは0です。実Azureでの比較結果は以下のとおりです。今回作った検証用Azureリソースはすべて撤去し、両サブスクリプションのリソース・RG・回復可能なLAWが元の0件へ戻ったことを[確認済みです](../test-results/procedural-powershell7-cleanup.json)。

## 実Azureでの速度比較

Windows上のPowerShell 7.6.10から、同じ100個のNSGを使って比べました。逐次側は通常のforeach、並列側は製品の最大5件の処理を使い、共通ファイルを各workerで読む時間も含めています。

|100件の処理|逐次|最大5件の並列|計測|
|---|---:|---:|---|
|診断設定の調査|68.9秒|20.0秒|各3回の中央値|
|初回複製と読み戻し|356.0秒|74.3秒|各1回の参考値|
|再実行（一致してスキップ）|105.6秒|9.8秒|各1回の参考値|

初回は各方式でGET 200回・PUT 100回、再実行はGET 100回・PUT 0回です。有効な計測中の再試行は0回で、元の100設定が変わっていないことも確認しました。

これは診断設定の処理部分の比較です。リソース一覧の取得、保存先・適用除外・DCRの準備、変更前記録、全体確認・削除は含みません。クライアントPCの通信条件や対象種類も異なるため、全サブスクリプションの所要時間へは換算しません。

最初の計測環境は同じ送信先への複製が409で拒否されたため、その複製結果を除外しました。調査24試行の成功データを保全し、製品と同じく送信先を別ワークスペースにして複製を測り直しています。比較用の逐次設定だけを照合後に削除し、並列側も同じ初期状態・同じ移行先で計測しました。削除や準備の時間は表に含めていません。

[計測の個別結果](../test-results/procedural-powershell7-performance.json)に、実行別の証跡と範囲を記録しています。[従来のWindows 5.1試験](../test-results/procedural-windows51.json)は変更前の版の記録です。
