# 手続型の移行スクリプト

既存の `migration` と原本を残し、別に書き直した版です。Windows PowerShell 5.1と、ログイン済みのAzure CLIを使用します。実Windows PowerShell 5.1 DesktopとLinux PowerShell 7で、同じ版の67ケース・910判定が成功しました。外部CLI／APIの応答を再生する回帰試験です。

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
|Invoke-ArmRequest|各工程で使う認証・HTTP送信・必要な再試行|
|Test-Configuration|現在値と記録した設定値の比較|
|Get-WritableBody|GET応答から保存・復元用の本文を取り出す|
|Read-MigrationRecord|環境・入力の一致を確認して変更前記録を読む|
|Get-MigrationPlan|現在の旧設定を探索し、名前・追加枠・地域を調べる|

各入口には関数を置かず、処理順に記述しています。`step3_delete.ps1`は`step2_verify.ps1`の確認処理をそのまま実行するため、同じ確認コードを二重に持ちません。前日にprecheckを実行しても、copyは当日の状態を再調査します。

## 設定と実行

`common.ps1`先頭の移行元ワークスペースIDと環境を指定します。新しい診断設定名も同じ場所です。旧DCRとポリシー割り当ては提示された本番・検証・開発の値です。

入力例を`targets.csv`へコピーし、対象サブスクリプション・保存先名を記入します。

```powershell
Copy-Item .\procedural-migration\targets.example.csv .\procedural-migration\targets.csv
powershell.exe -NoProfile -File .\procedural-migration\precheck.ps1
powershell.exe -NoProfile -File .\procedural-migration\step1_copy.ps1
powershell.exe -NoProfile -File .\procedural-migration\step2_verify.ps1
# 確認結果を人が確認してから実行する。
powershell.exe -NoProfile -File .\procedural-migration\step3_delete.ps1
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

途中停止時は同じCSV・設定のままcopyを再実行します。最初のBeforeは上書きせず、新しい対象だけ追加します。既に一致する設定は書き込みません。失敗した対象と期待する値は`copy_failures.csv`、全件確認は`verify_results.csv`へ出します。

```powershell
# 全体の切り戻し
powershell.exe -NoProfile -File .\procedural-migration\rollback.ps1
# 指定Subだけを戻す場合は、PowerShellから呼ぶ。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'
```

切り戻しは保存先と保存済みログを残します。今回作成したDCR本体も残し、変更した既存DCR・関連付けはBeforeに戻します。新設の適用除外だけを解除し、元からある除外は残します。

## 文字数の比較

コメントを除いたコード・設定値・空白・改行を、既存版と同じ条件で数えます。PowerShell Parserで通常のコメントを取り除き、文字列中の`#`や実行指示の`#Requires`は残します。日本語の説明コメントはコード内に維持します。

|項目|既存版|手続型版|
|---|---:|---:|
|コメント以外の文字数|117,245|53,864|
|独自関数|25|5|
|1行に詰めたif・foreach・while|比較対象外|0|

コード部分は54.06％減です。**当初の10分の1という目標には未達です。** ユーザー確認により、機能と読みやすさを維持して可能な限り削減する方針です。変数名の短縮や1行への詰め込み、コードの別ファイルへの逃がしは行っていません。詳しい計測値は[文字数比較](../test-results/procedural-size.json)に記録しています。

[67ケースの一覧](../test-results/PROCEDURAL_CASES.md)と[Windows個別結果](../test-results/procedural-windows51.json)を保存しています。固定した主要6本＋テスト1本は実行前後でハッシュが一致し、構文エラーは0です。今回作った検証用Azure資源も[撤去済み](../test-results/procedural-cleanup.json)です。
