# 移行スクリプトの使い方

このフォルダが正本です。PowerShell 7と、ログイン済みのAzure CLIを使用します。Windows PowerShell 5.1では実行できません。コードの読み方は [学習ガイド](CODE_LEARNING.md)、検証状況は [検証結果](../test-results/REPORT.md) を参照してください。

## 1. 実行する環境とCSVを指定する

`common.ps1`先頭の次の値を設定します。旧DCR2つとポリシー割り当て3つは、提示された本番・検証・開発の値が設定済みです。

|変数|指定する値|
|---|---|
|`$targetWorkspaceId`|移行対象となる旧診断設定のLog AnalyticsリソースID|
|`$environment`|今回実行する環境：`prod` / `stg` / `dev`|
|`$newDiagnosticSettingName`|追加する診断設定の共通名。既定は`storage-archive`|

新規作成するRG、Log Analytics、新DCRの地域は東日本です。Storageは診断設定の対象がある地域ごとに作成します。地域が空または`global`の対象は東日本として扱います。

入力例をコピーし、対象と保存先の名前を記入します。

```powershell
Copy-Item .\procedural-migration\targets.example.csv .\procedural-migration\targets.csv
```

|CSV列|指定する値|
|---|---|
|`SubscriptionName`|対象SubのID、または一意に特定できる名前。1Subにつき1行|
|`ResourceGroup`|保存先のRG名。必須|
|`StorageAccount`|`jpe`を1か所含む小文字英数字3～24文字の名前。Storage宛てにする行は必須|
|`WorkspaceName`|保存先Log Analytics名。必須|
|`LogDestination`|診断設定の宛先：`Storage` / `Log` / `None` / 空欄|
|`VmLogDestination`|新DCRと関連付け：`Log` / `None` / 空欄。列自体がない旧CSVは`Log`|

`None`と空欄は、その側の新しい送信設定を作成せず、最後のstep3で旧設定を外して送信を終了します。**保存先は作成します。** Log Analyticsは全行で準備し、Storageも名前が指定されていれば準備します。Storageの対象地域が0件の場合は東日本に1つ作成します。

Storage名の`jpe`だけをMicrosoftのAzure Naming Toolで公開されている地域略称へ置き換えます。名前の空き・変換後の形式・ZRS対応を事前に確認し、初回に同名Storageがあれば停止します。

## 2. 確認しながら実行する

リポジトリのルートを作業フォルダとして、PowerShell 7から実行します。Azureへは対象Subの所有者としてログインしている前提です。

```powershell
az login

# 任意。前日などに名前・地域・対象を確認する。
pwsh.exe -NoProfile -File .\procedural-migration\precheck.ps1

# 新設定を準備する。旧設定は残る。
pwsh.exe -NoProfile -File .\procedural-migration\step1_copy.ps1

# 現在値を確認し、verify_results.csvを人が確認する。
pwsh.exe -NoProfile -File .\procedural-migration\step2_verify.ps1

# 確認後に旧設定を削除する。冒頭でも全件確認する。
pwsh.exe -NoProfile -File .\procedural-migration\step3_delete.ps1
```

|処理|実行する内容|
|---|---|
|任意precheck|その時点のAzureを調査。Azureを変更せず、変更前記録も作らない|
|step1 copy|Subごとに再調査→必要な変更前記録を保存→Waiver→保存先→新DCR・関連→新診断設定|
|step2 verify|記録後に旧設定が増加・変更していないか、保存先・新設定が記録と一致するか確認|
|step3 delete|全対象のverify成功後、旧DCR関連→旧診断設定の順に削除。削除直前にも旧・新設定を照合|

copyはprecheckの結果ファイルに依存しません。診断設定は移行元ワークスペース宛てのものを対象にし、ログ・メトリックの指定を引き継いで宛先を変更します。新診断名の重複や5枠の上限は書き込み前に確認します。DCR側は環境別の旧2DCRの関連を対象にし、旧関連があるVM・VMSSに新関連を設定します。

StorageはStorageV2・Standard_ZRSで、appendBlobの削除を1,095日後に設定します。Log Analyticsのワークスペース保持は365日、旧DCR関連の対象がある場合はEvent・Syslogの合計保持を1,095日に設定します。VM側の新設定を省略する行でも、この保存先の準備は行います。

SubはCSVの順に処理します。診断設定の調査と新診断設定の複製だけを最大5件ずつ並列に実行し、適用除外・保存先・DCRは順に準備します。step3の削除とrollbackも順に処理し、失敗した時点で停止します。step3終了後もWaiverは残し、自動期限は設定しません。

## 3. 途中停止と再実行

step1は、Azureへの変更前に`records/<環境>/<Sub ID>.json`へ必要な設定値を保存します。保存するのは旧診断・旧DCR関連と、今回変更する新設定・適用除外のBefore、保存先の期待値です。サブスクリプション全体やログデータのバックアップは取りません。

途中で止まった場合は、**同じCSV・commonの設定・recordsを維持して**step1を再実行します。一致する設定はスキップし、最初のBeforeは上書きしません。再調査で見つかった新しい対象は記録に追記します。保存した旧設定が消失・変更している場合は停止します。

|結果ファイル|確認する内容|
|---|---|
|`precheck_results.csv`|任意事前確認のOK/NGと理由|
|`copy_failures.csv`|copyで未完了になった対象・理由・期待値|
|`verify_results.csv`|全件確認の結果。NGは理由と期待値を含む|
|`delete_failures.csv`|旧設定の削除で停止した対象と理由|
|`rollback_failures.csv`|切り戻しで停止した対象と理由|

copyで1Subが失敗しても他Subの処理は続け、最後に未完了を報告します。手動対応した場合もstep2で現在値を確認します。step3は全Subの確認が成功しなければ1件も削除しません。削除開始後の失敗では、それまでに削除した分は残り、以降の削除を停止します。

## 4. 全体または指定Subを切り戻す

copyの途中・終了後、またはdeleteの途中・終了後に同じ`rollback.ps1`を使用します。環境と移行元IDなどは記録を作成したときの値に合わせます。CSVは読み直さず、recordsから対象を選びます。

```powershell
# 全体を戻す。
pwsh.exe -NoProfile -File .\procedural-migration\rollback.ps1

# 指定したSubだけを戻す。PowerShell 7から実行する。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'

# 複数Subを指定する場合。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID 1', '対象Sub ID 2'
```

現在値を全件照合してから、旧DCR関連→旧診断設定を復元し、その後で新設定を変更前へ戻します。記録と異なる設定は上書きせず停止します。既に復元済みならスキップできます。

保存先と保存済みログ、新規作成したDCR本体は残します。元からあったDCR・関連付けはBeforeへ戻し、今回新設したWaiverだけを削除します。元からあったWaiverは残します。Azureポリシーの修復タスクは使用しません。

`targets.csv`・`records/`・結果CSVはGit管理の対象外です。切り戻しや再開に必要なので、作業が完了するまで同じ作業フォルダに保管してください。
