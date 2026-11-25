# ログの送信先を切り替える手順

現在のログ送信を続けたまま、新しい保存先への送信設定を追加します。設定値を確認してから、元の診断設定とVM・VMSSのDCR関連付けを削除します。保存済みのログは元の保存先に残ります。

実行には[元の正本](../../procedural-migration/README.md)を使います。このページのコマンドは、元のリポジトリのルートから実行してください。コードの説明は[学習ガイド](CODE_LEARNING.md)にあります。

## 作業の流れ

|ファイル|行うこと|次へ進む条件|
|---|---|---|
|`precheck.ps1`（任意）|作成先の名前や、診断設定の空き枠を事前に調べる|`precheck_results.csv`のResult列がすべてOK|
|`step1_copy.ps1`|元の設定を記録し、新しい保存先と送信設定を作る|エラーなく終了する|
|`step2_verify.ps1`|Azureの設定値と、作業記録の値を比べる|`verify_results.csv`のResult列がすべてOK|
|`step3_delete.ps1`|旧診断設定と旧DCR関連付けを削除する|削除前にもstep2を実行し、すべてOKなら削除を始める|
|`rollback.ps1`（必要時）|旧設定を戻してから、今回追加・変更した送信設定を元に戻す|エラーなく終了し、旧設定が記録の値に戻る|

データ収集ルール（DCR）は、VMから収集するログと送り先を決めます。DCR関連付けは、そのルールをVM・VMSSに結び付けます。**step3は関連付けを削除し、旧DCR本体は残します。**

## 1. 実行環境と入力を用意する

PowerShell 7とAzure CLIを使います。対象サブスクリプションのOwnerとして`az login`を済ませてください。Windows PowerShell 5.1では実行できません。

### common.ps1に移行元と環境を指定する

先頭の6変数を確認します。旧DCR・管理グループ・ポリシー割り当てには、既存のIDを指定します。

|変数|指定する内容|
|---|---|
|`$targetWorkspaceId`|現在のLog AnalyticsのリソースID。このワークスペース宛ての診断設定を移行する|
|`$environment`|今回作業する環境。`prod`・`stg`・`dev`のいずれか|
|`$newDiagnosticSettingName`|追加する診断設定の名前。全リソースで同じ名前を使う。既定値は`setByAzurePlatformTeam`|
|`$location`|新しいリソースグループ・Log Analytics・DCRを作る地域。既定値は東日本（`japaneast`）|
|`$environmentSettings`|各環境の旧DCR2本、管理グループ、ポリシー割り当て3件。指定された値を設定済み|
|`$policyReferenceIds`|3件目のポリシー割り当てから除外する12個の参照ID。指定された値を設定済み|

ストレージアカウントは診断設定を付けるリソースと同じ地域に作ります。地域が空欄・`global`なら東日本とし、`$location`とは別に決めます。

### CSVに作業先を指定する

```powershell
Copy-Item .\procedural-migration\targets.example.csv .\procedural-migration\targets.csv
```

`targets.csv`には、1サブスクリプションにつき1行を書きます。

|CSV列|指定する内容|
|---|---|
|`SubscriptionName`|サブスクリプションID、または一意に決まる名前|
|`ResourceGroup`|新しい保存先を入れるリソースグループ名。必須|
|`StorageAccount`|`jpe`を1か所含む、小文字英数字3～24文字の名前。診断ログの送り先が`Storage`なら必須|
|`WorkspaceName`|新しいLog Analyticsワークスペースの名前。必須|
|`LogDestination`|診断ログの送り先。`Storage`・`Log`・`None`・空欄から選ぶ|
|`VmLogDestination`|`Log`ならVMログ用の新DCRと関連付けを作る。`None`・空欄なら作らない。送信先はLog Analytics固定|

6列すべてが必要です。列の欠落はエラーにし、値を空欄にする指定と区別します。

`None`・空欄の側は新しい送信設定を作らず、step3で旧設定を外して送信を終了します。**保存先は作ります。** Log Analyticsはすべての行、ストレージアカウントは名前がある行で作ります。ストレージの配置先地域が0件なら、東日本に1つ作ります。

### 作成先の名前を確認する

初回は、CSVのリソースグループがすでにあれば停止します。同じ作業の再開では、作業記録にあるグループを使えます。

ストレージ名の`jpe`だけをAzure Naming Toolの地域略称へ置き換えます。取得先の`raw.githubusercontent.com`へ接続できる必要があります。置換後の名前・空き・Standard_ZRSの地域対応を調べ、使用済みなら作成前に停止します。

## 2. 結果を確認しながら実行する

各コマンドを一つずつ実行します。エラーやNGがあれば、次へ進みません。

```powershell
az login

# 任意。前日などに確認する。
pwsh.exe -NoProfile -File .\procedural-migration\precheck.ps1

# 旧設定を残して新設定を準備する。
pwsh.exe -NoProfile -File .\procedural-migration\step1_copy.ps1

# verify_results.csvを確認する。
pwsh.exe -NoProfile -File .\procedural-migration\step2_verify.ps1

# 確認後、旧設定を削除する。
pwsh.exe -NoProfile -File .\procedural-migration\step3_delete.ps1
```

### precheck：作成前の問題を見つける

各サブスクリプションで、旧診断設定と旧DCR関連付けを探します。ストレージの子サービスとRedisの子DBも調べます。指定ポリシー3件の適用と12参照ID、保存先の名前・空き・ZRS対応、新診断設定名の重複と上限5件を確認します。

結果は`precheck_results.csv`に出します。Azureの設定や作業記録は変えません。前日にも実行できますが、step1はこの結果を使わず、作業直前に調べ直します。作成後の名前は使用済みになるため、再開時はstep1を使います。

### step1：元の設定を残し、新しい送信設定を作る

CSVの順に、サブスクリプションごとに次を行います。

1. 旧設定・作成先・ポリシーを調べ直す。再実行では、作業記録と今回の入力も比べる。
2. 旧設定・作成値・変更前の値をJSONへ保存する。保存してからAzureを変更する。
3. ポリシーの適用除外（Waiver）を期限なしで作る。最初の2割り当ては全体、3件目は12参照IDを除外する。必要なAzureサービスが未登録なら利用登録する。
4. 保存先と保持期間を設定する。同じ値があれば書き込みを省く。
5. VM側がLogなら、旧2DCRに関連付いていたVM・VMSSへ新DCRを関連付ける。
6. 診断側がStorage・Logなら、旧診断設定のログ・メトリックを引き継いだ新診断設定を追加する。
7. Azureから値を読み直し、作業記録の作成値と比べる。

新DCRは固定のWindowsイベント（Application・Security・System）とSyslogを収集します。DCR名はワークスペース名の先頭`log`を`dcr`へ置き換えます。新診断設定は、旧設定のログの格納方式も引き継ぎます。

保存先に設定する値は次のとおりです。

|保存先|設定する値|
|---|---|
|リソースグループ・Log Analytics|地域は`$location`。ワークスペースの保持期間は90日。取込・クエリのパブリックアクセスを有効化し、リソースまたはワークスペースの権限でログを参照できるようにする|
|地域別ストレージアカウント|StorageV2・Standard_ZRS。インフラ暗号化と、バージョン単位の不変性のサポートを有効化。共有キー・Blobの匿名公開は無効。HTTPSとTLS 1.2を使用。公開ネットワークはDisabled、ネットワーク規則は既定拒否・AzureServices例外|
|Blobとストレージの追加設定|Blobバージョン管理を有効化。最終更新から1,095日を超えたappendBlobを削除するルールを追加。個別のDefenderを無効化|
|Event・Syslogテーブル|旧DCR関連付けがある場合に、合計保持期間を1,095日にする。`VmLogDestination`がNone・空欄でも設定する|

既存のIP・VNet規則、Log Analyticsのほかのfeatures、別名のライフサイクルルール、DCRのマネージドIDは残します。旧設定は削除しません。

サブスクリプションはCSV順に処理します。診断設定の調査と新規作成は、各サブスクリプション内で最大5件を同時に処理します。失敗したサブスクリプションの残りは止め、次へ進みます。未完了の設定は`copy_failures.csv`に出します。

接続切断・通信タイムアウト・一時HTTPエラーは、初回を含め最大4回試します。1回の接続・応答待ちは5分です。対応するPowerShellでは、本文受信中の無応答も5分で再試行します。作成やテーブル反映を待つ時間には全体の上限を設けず、Failed・Canceledなら停止します。

### step2：新しい設定の値を比べる

作業記録の`Body`とAzureの保存先・新設定を1件ずつ比べます。リソースグループは存在、Event・Syslogは合計保持期間の明示設定も確認します。記録がないサブスクリプションはNGです。

旧設定も探し直し、記録にない追加や値の変更をNGにします。削除の再開にも使うため、すでに削除された旧設定は許可します。

Azureは変更せず、結果を`verify_results.csv`へ出します。Result列がすべてOKならstep3へ進めます。NGはReason列とExpected列で原因を調べます。

### step3：旧送信設定を削除する

最初にstep2で全サブスクリプションを確認し、1件でもNGなら削除を始めません。

全サブスクリプションの旧DCR関連付け、その後に旧診断設定を削除します。各削除の直前にも、旧設定と新設定が作業記録どおりか確認します。`None`・空欄の側は新設定を確認せず、旧設定を外して送信を終了します。

値の不一致やAPIエラーは`delete_failures.csv`に記録し、ほかのサブスクリプションも含めて残りを止めます。保存先・ログ・新設定・適用除外は残します。再実行では削除済みを省略します。

## 3. 途中で止まった作業を再開する

**common設定・CSV・recordsを変えずに**、止まった工程を再実行します。step1は設定済みを省略し、新たに見つかった旧設定を記録へ追加します。最初に記録した変更前の値は残し、記録済みの旧設定が消失・変更していれば停止します。

作業記録は`records/<環境>/<サブスクリプションID>.json`です。設定値だけを保存し、サブスクリプション全体やログデータは保存しません。

|記録の項目|入っている情報|
|---|---|
|`Context`・`Target`|移行元ワークスペース・環境・旧DCR・新診断名と、その行のCSV値|
|`OldSettings`|旧診断設定と旧DCR関連付けのID・種類・復元する設定値|
|`Destinations`|保存先・保持期間の設定IDと、設定する値|
|`NewSettings`|新診断設定・DCR・関連付け・適用除外の作成値`Body`と変更前の値`Before`|

`Before=null`は、その設定が作業前には存在しなかったことを表します。

|結果ファイル|確認する内容|
|---|---|
|`precheck_results.csv`|サブスクリプションごとのOK／NGと理由|
|`copy_failures.csv`|作成できなかった設定のID・理由・作成予定の値|
|`verify_results.csv`|設定IDごとのOK／NG。NGなら理由と予定値も記録|
|`delete_failures.csv`|削除を止めた設定のID・理由・元の値|
|`rollback_failures.csv`|切り戻しを止めた設定のIDと理由|

入力エラーは結果CSVより先に画面へ出る場合があります。step3冒頭の失敗は`verify_results.csv`を見ます。`delete_failures.csv`は成功後も過去分が残るため、更新日時も確認してください。

## 4. 旧設定へ切り戻す

step1・step3の途中でも完了後でも、同じ`rollback.ps1`を使います。common設定は記録作成時と同じ値にし、CSVは使いません。

```powershell
# 全体を戻す。
pwsh.exe -NoProfile -File .\procedural-migration\rollback.ps1

# 指定Subだけを戻す。PowerShell 7から実行する。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'

# 複数Subを戻す。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID 1', '対象Sub ID 2'
```

切り戻す設定の現在値を作業記録と比べ、記録にない変更があれば書き込み前に停止します。旧DCR関連付け、旧診断設定の順に全対象へ復元してから、新しい設定を戻します。

|設定|切り戻し後の状態|
|---|---|
|旧診断設定・旧DCR関連付け|作業記録の内容で復元する。すでに同じ値なら変更しない|
|今回追加した新診断設定・新DCR関連付け|削除する|
|移行時に変更した既存DCR・関連付け|変更前の値`Before`へ戻す|
|今回作成したDCR本体|残す|
|ポリシー適用除外|今回作成したものは削除する。元からあったものは残す|
|保存先・保存済みログ|残す|

旧診断設定を戻す空き枠がなければ、ほかの設定を消さずに停止します。復元後もAzureの値を比べます。失敗は`rollback_failures.csv`に記録して全体を停止し、再実行では復元済みを省略します。ポリシー修復タスクは使いません。

`targets.csv`・`records/`・結果CSVはGit管理外です。作業が終わるまで、同じフォルダに保管してください。

## common.ps1の役割

利用者設定と5つの共通関数を読み込みます。通常はCSV検査・サブスクリプション名のID解決・地域略称の取得も行い、`-SkipCsv`付きなら省きます。関数の処理と引数は各ヘルプ、呼び出し後の流れは[学習ガイド](CODE_LEARNING.md)を参照してください。
