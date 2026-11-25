# 移行スクリプトの使い方

このフォルダが正本です。PowerShell 7と、対象サブスクリプション（以下Sub）のOwnerでログイン済みのAzure CLIを使います。Windows PowerShell 5.1は対象外です。[学習ガイド](CODE_LEARNING.md)ではコードを上から解説しています。

## 1. 環境とCSVを指定する

`common.ps1`先頭の6変数を確認します。旧DCR・管理グループ・ポリシー割り当ては既存のものを参照します。

|変数|指定する値|
|---|---|
|`$targetWorkspaceId`|移行元Log AnalyticsのリソースID。このID宛ての診断設定を探す|
|`$environment`|`prod` / `stg` / `dev`|
|`$newDiagnosticSettingName`|追加する診断設定の共通名。既定は`setByAzurePlatformTeam`|
|`$location`|新規RG・Log Analytics・新DCRの地域。既定は東日本`japaneast`|
|`$environmentSettings`|環境別の旧DCR2つ・管理グループ・割り当て3つ。提示値を設定済み|
|`$policyReferenceIds`|3件目の割り当てで除外する参照ID。提示の12件を設定済み|

Storageは診断対象の地域ごとに作ります。地域が空・`global`なら東日本とし、`$location`とは別に判定します。

入力例をコピーして記入します。

```powershell
Copy-Item .\procedural-migration\targets.example.csv .\procedural-migration\targets.csv
```

|CSV列|指定する値|
|---|---|
|`SubscriptionName`|Sub ID、または一意なSub名。1Subにつき1行|
|`ResourceGroup`|保存先RG名。必須|
|`StorageAccount`|`jpe`を1か所含む小文字英数字3～24文字。Storage宛てなら必須|
|`WorkspaceName`|保存先Log Analytics名。必須|
|`LogDestination`|診断側：`Storage` / `Log` / `None` / 空欄|
|`VmLogDestination`|VM側の新送信設定：`Log`なら作成、`None`・空欄なら作成しない。送信先はLog Analytics固定|

CSVは6列すべて必要です。列の欠落はエラーにし、値が空欄の指定とは区別します。

初回はCSV指定のRGが既にあれば、地域に関係なく停止します。同じ作業の再開では、記録にあるRGを使います。

`None`・空欄の側は新送信設定を作らず、step3で旧設定を外して送信を終了します。**保存先は準備します。** Log Analyticsは全行、Storageは名前がある行で作ります。Storageの対象地域が0件なら東日本に1つ作ります。

Storage名は`jpe`だけをAzure Naming Toolの地域略称へ置き換えます。取得先の`raw.githubusercontent.com`へ接続できる必要があります。変換後の名前・空き・ZRS対応を確認し、初回に同名Storageがあれば停止します。

## 2. 確認しながら実行する

リポジトリのルートから、PowerShell 7で実行します。

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

以下のJSON・結果CSVはこのフォルダへ出力します。copyはprecheckの結果を使わず、Subごとの作業直前に再調査します。

### precheck.ps1：任意の事前確認

1. CSVから対象Subを特定する。
2. Sub内のリソースを列挙し、旧ワークスペース宛ての診断設定を探す。Storageの子サービスとRedis子DBも調べ、旧2DCRの関連も取得する。
3. 指定3割り当ての適用と、3件目の12参照IDの存在を確認する。
4. 保存先RGの不存在、地域別Storage名・空き・ZRS対応、新診断名の重複と5枠上限を確認する。
5. SubごとのOK/NGを`precheck_results.csv`へ出し、NGがあればエラーで終了する。

Azureの変更・記録保存は行いません。再開用JSONも使わないため、同名RG・作成済みStorage名は使用済みとして停止します。

### step1_copy.ps1：記録を保存し、新送信設定を準備

CSVの1Subずつ、次の順に処理します。

1. 旧診断・旧DCR関連・作成先・ポリシーを再調査する。再実行は既存JSONと環境・CSVが一致するかも確認する。
2. 旧本文、新しい作成値`Body`、Waiver・DCR・関連の変更前の値`Before`を`records/<環境>/<Sub ID>.json`へ保存する。再実行は最初の`Before`を保ち、新規対象だけ追記する。
3. 期限なしのWaiverを作る。最初の2割り当ては全体、3件目は12参照IDを除外する。必要なRPが未登録なら登録する。
4. 次の保存先を準備する。現在値が記録の`Body`と一致すれば書込みを省く。

|対象|設定内容|
|---|---|
|RG・Log Analytics|新規作成地域は`$location`。ワークスペース保持90日、取込・クエリのパブリックアクセスとリソース権限でのログ参照を有効化|
|地域別Storage|StorageV2・Standard_ZRS、インフラ暗号化・バージョン単位の不変性を有効化。共有キー・Blob匿名公開は無効。HTTPS／TLS 1.2、公開ネットワークは無効（`Disabled`）。通信規則は既定拒否・`AzureServices`例外|
|Storageの追加設定|Blobバージョン管理、appendBlobを最終更新の1,095日後に削除するライフサイクル、個別Defenderの無効化|
|Event・Syslog|旧DCR関連がある場合に準備し、合計保持を1,095日へ設定。VM側がNone・空欄でも対象|

5. 旧DCR関連がありVM側がLogなら、新DCRとVM・VMSSへの関連を準備する。収集条件は固定のWindowsイベント（Application・Security・System）とSyslog、宛先はCSVのLog Analytics。DCR名はワークスペース名の先頭`log`を`dcr`へ置換する。
6. 診断側がStorage／Logなら、旧診断のログ・メトリックを引き継いだ新診断を共通名で追加する。Storageは同地域へ、LogはCSVのワークスペースへ送り、旧格納方式も引き継ぐ。
7. 書込み後にGETで照合する。準備に失敗したSubは残りを飛ばして他Subへ進む。診断複製は各結果を集め、未完了を`copy_failures.csv`へ出してエラーで終了する。

更新対象外のStorageのIP規則・Log Analyticsのfeatures・他名のライフサイクル・既存DCRのidentityなどは引き継ぎます。旧診断・旧DCR関連は残します。

SubはCSV順です。1Sub内の診断調査・新診断作成は各最大5件を同時処理し、Waiver・保存先・DCRは順に準備します。RP登録と作成状態、DCR出力テーブルの反映は完了を待ちます。`Failed`／`Canceled`なら停止します。

接続断・通信タイムアウト・一時HTTPエラーは、初回を含め最大4回試します。1回の接続・応答ヘッダ待機は300秒（5分）、対応するPowerShellでは本文受信中の無応答も300秒（5分）です。作成・反映待ち全体に一律上限はありません。

### step2_verify.ps1：削除へ進めるか確認

1. CSVとJSONの環境・旧ワークスペース・対象を照合する。JSONがないSubはNG。
2. 現在の旧設定を再調査する。追加・改変はNG、既に不在の旧設定は許可する。
3. 記録した保存先・新設定をGETして各`Body`と照合する。RGは存在、Event・Syslogは合計保持の明示設定も確認する。
4. 対象IDごとのOK/NG・理由・NG時の期待本文を`verify_results.csv`へ出す。全Subを調べ、NGがあればエラーで終了する。

Azureの変更は行いません。手動対応後も同じ検査を使います。step3は`-PassThru`で呼び、全件OKのときだけ削除用のJSON記録を受け取ります。

### step3_delete.ps1：確認済みの旧設定を削除

1. step2で全Subを確認し、1件でもNGなら削除しない。
2. 全Subの旧DCR関連→全Subの旧診断の順に削除する。旧DCR本体は残す。
3. 各削除直前に旧本文と、対応する新設定を再照合する。None・空欄は新設定を確認せず、旧送信を終了する。
4. 削除済みは省略する。不一致・API失敗は`delete_failures.csv`へ出し、他Subも含め以降を停止する。

保存先・ログ・新設定・Waiverは残します。途中までの削除は自動復元せず、再実行かrollbackで対応します。Waiverに自動期限はありません。

### rollback.ps1：旧送信を復元し、新側を変更前へ戻す

1. 環境別JSONから全Sub、または`-SubscriptionIds`の対象を選ぶ。CSVは使わず、環境と記録を照合する。
2. 全対象の現在値が`Body`・`Before`・不在のいずれかを確認する。他の変更があれば書込み前に停止する。
3. 全対象Subの旧DCR関連→旧診断を`OldSettings.Body`から復元する。一致済みは省略し、旧診断の再作成前には5枠の空きを確認する。
4. 新側をDCR→関連→診断→Waiverの順に`Before`へ戻す。nullなら今回の追加分を削除するが、新設DCR本体と元からあるWaiverは残す。
5. GETで照合し、失敗は`rollback_failures.csv`へ出して全体を停止する。

保存先・保存済みログと、選択しなかったSubは変更しません。ポリシー修復タスクは使いません。

### common.ps1：設定と共通処理

各工程が読み込む設定ファイルです。環境設定を組み立て、通常はCSV検査・Sub名のID解決・地域略称取得を行います。`-SkipCsv`付きならこれらを省き、設定・関数だけを読み込みます。

|関数|処理|
|---|---|
|`Invoke-ArmRequest`|Azure APIへ要求し、応答を返す|
|`Test-Configuration`|現在値と期待値を比較する|
|`Get-WritableBody`|GET応答から保存・復元・比較用の本文を作る|
|`Read-MigrationRecord`|SubのJSONを読み、作業条件を照合する|
|`Get-MigrationPlan`|旧設定と、新設定の作成先ID・地域を調べる|

引数の説明は各関数のヘルプ、使われ方は[学習ガイド](CODE_LEARNING.md)を参照してください。

## 3. 途中停止と再実行

step1はAzure変更前に、次のJSONを保存します。

|項目|内容|
|---|---|
|`Context`・`Target`|環境・旧ワークスペース・新診断名などと、そのSubのCSV値|
|`OldSettings`|旧診断・旧DCR関連のID・種類・`Body`|
|`Destinations`|保存先・保持設定のID・`Body`|
|`NewSettings`|新診断・DCR・関連・WaiverのID・`Body`・変更前の`Before`|

`Before=null`は元の設定がなかった意味です。サブスクリプション全体やログデータは保存しません。

**同じCSV・common設定・recordsを維持して**step1を再実行します。一致済みを省略し、新規対象を追記します。記録済みの旧設定が消失・変更していれば停止します。

|結果ファイル|内容|
|---|---|
|`precheck_results.csv`|Subごとの事前確認OK/NG・理由|
|`copy_failures.csv`|未完了のSub・対象ID・理由・作成本文|
|`verify_results.csv`|対象ごとのOK/NG。NGは理由・期待本文|
|`delete_failures.csv`|削除で停止したSub・対象ID・理由・旧本文|
|`rollback_failures.csv`|切り戻しで停止した対象・理由|

初期検査の失敗はCSV出力前に画面へ表示する場合があります。step3冒頭の失敗は`verify_results.csv`を確認します。`delete_failures.csv`は成功時も過去分を消さないため、更新日時も確認してください。

## 4. 全体または指定Subを切り戻す

copy・deleteの途中でも完了後でも同じスクリプトを使います。commonの環境・移行元などは記録作成時と合わせます。

```powershell
# 全体を戻す。
pwsh.exe -NoProfile -File .\procedural-migration\rollback.ps1

# 指定Subだけを戻す。PowerShell 7から実行する。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'

# 複数Subを戻す。
.\procedural-migration\rollback.ps1 -SubscriptionIds '対象Sub ID 1', '対象Sub ID 2'
```

`targets.csv`・`records/`・結果CSVはGit管理外です。再開・切り戻しに使うため、作業完了まで同じフォルダに保管してください。
