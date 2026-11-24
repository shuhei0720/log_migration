# 移行スクリプトの使い方

このフォルダが正本です。PowerShell 7と、ログイン済みのAzure CLIを使用します。Windows PowerShell 5.1では実行できません。コードの読み方は [学習ガイド](CODE_LEARNING.md)、検証状況は [検証結果](../test-results/REPORT.md) を参照してください。

現行版の再生試験と、Azure実環境での最終総合テストを進めています。確認できた範囲と未完了の工程は、上記の検証結果に記録します。

## 1. 実行する環境とCSVを指定する

`common.ps1`先頭の次の値を設定します。旧DCR2つとポリシー割り当て3つは、提示された本番・検証・開発の値が設定済みです。

指定した管理グループとポリシー割り当ては、既存のものを参照します。各Subの作業では、その3割り当てに対するWaiverを用意します。

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

Storage名の`jpe`だけをMicrosoftのAzure Naming Toolで公開されている地域略称へ置き換えます。略称の取得には`raw.githubusercontent.com`への接続を使用します。名前の空き・変換後の形式・ZRS対応を事前に確認し、初回に同名Storageがあれば停止します。

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

|処理|主な処理と出力|
|---|---|
|任意precheck|旧設定・地域・予定名・追加枠・ポリシーを調査し、SubごとのOK/NGを`precheck_results.csv`へ出力|
|step1 copy|Subごとの直前調査→変更前JSON保存→Waiver→保存先→新DCR・関連→新診断設定。未完了は`copy_failures.csv`へ出力|
|step2 verify|現在の旧設定と、記録した保存先・新設定を照合。項目ごとのOK/NGを`verify_results.csv`へ出力|
|step3 delete|全Subのverify成功後、削除直前にも照合し、旧DCR関連→旧診断設定を削除。失敗は`delete_failures.csv`へ出力|

copyはprecheckの結果ファイルに依存しません。診断設定は移行元ワークスペース宛てのものを対象にし、ログ・メトリックの指定を引き継いで宛先を変更します。新診断名の重複や5枠の上限は書き込み前に確認します。DCR側は環境別の旧2DCRの関連を対象にし、旧関連があるVM・VMSSに新関連を設定します。

StorageはStorageV2・Standard_ZRSで、appendBlobを最終更新から1,095日後に削除する設定にします。Log Analyticsのワークスペース保持は365日、旧DCR関連の対象がある場合はEvent・Syslogの合計保持を1,095日に設定します。VM側の新設定を省略する行でも、この保存先の準備は行います。

作成・更新後のGETにprovisioningStateがある場合は、Succeededまで最大5分、3秒間隔で待ちます。Failed/Canceledは即座に失敗として扱います。

SubはCSVの順に処理します。診断設定の調査と新診断設定の複製だけを最大5件ずつ並列に実行し、適用除外・保存先・DCRは順に準備します。step3の削除とrollbackも順に処理し、失敗した時点で停止します。step3終了後もWaiverは残し、自動期限は設定しません。

### 各ファイルの具体的な処理

以下のJSONと結果CSVは、すべてこの`procedural-migration`フォルダ配下へ出力します。

#### precheck.ps1：作業前の任意確認

1. `common.ps1`でCSVを読み、対象Subを特定する。
2. Sub内のリソースを列挙し、`$targetWorkspaceId`へ送信している旧診断設定を探す。Storageは種類に応じたBlob／File／Queue／Tableの子サービス、RedisはAPIで取得した子DBも調べる。環境別に指定した旧2DCRから、このSubの関連付けも取得する。
3. 指定3ポリシーの適用状況と、3件目のイニシアティブに指定12参照IDが存在することを確認する。
4. Storageを作成する地域を決め、名前の`jpe`を地域略称へ置き換える。変換後の名前・Azure全体での名前の空き・Standard_ZRSの地域対応を確認する。
5. 新診断設定を作る側は、同名設定の重複と診断設定の5枠上限を確認する。
6. `precheck_results.csv`にSubごとのOK/NGと理由を書き、NGがあれば失敗として終了する。

Azureへの書き込みと変更前記録の保存は行いません。以前の記録を再開判定に使わないため、作成済みのStorage名なども使用済みとして扱います。前日に実行してもよく、step1はこの結果を読み込まず、その時点のAzureを再調査します。

#### step1_copy.ps1：変更前記録を保存して新しい送信設定を準備

CSVの1Subずつ、次の順に処理します。

1. 現在の旧設定・地域・名前・追加枠・ポリシーを調べ直す。再実行の場合は、そのSubの既存JSONと環境・CSVの設定が一致することも確認する。
2. 旧診断設定・旧DCR関連、変更するWaiver・DCR・関連付けの変更前の値、保存先と新設定の予定値を`records/<環境>/<Sub ID>.json`へ保存する。再実行では最初の変更前の値を保持し、新しく見つかった対象だけ追記する。
3. 指定3ポリシーに期限なしのWaiverを準備する。最初の2件は割り当て全体、3件目は指定12参照IDを除外する。続けて、必要なリソースプロバイダーが未登録なら登録する。
4. 次の保存先を準備する。既に予定どおりの設定なら、その書き込みを省く。

|対象|設定する内容|
|---|---|
|RG・Log Analytics|新規作成時の地域は東日本。ワークスペース保持365日、取り込み・クエリのパブリックアクセス有効、リソース単位の権限によるログ参照を有効にする|
|地域別Storage|CSVに名前があれば、旧診断対象の地域ごとにStorageV2・Standard_ZRSを作る。インフラ暗号化とバージョン単位の不変性機能を有効にし、共有キーとBlobの匿名公開を無効にする。HTTPS／TLS 1.2を使用し、通信は既定拒否・AzureServicesを許可する|
|Storageの追加設定|Blobのバージョン管理を有効にする。appendBlobを最終更新から1,095日後に削除するライフサイクルルールを設定し、Storage個別のDefenderを無効にする|
|Event・Syslogテーブル|旧2DCRへの関連がある場合、送信先ワークスペースの両テーブルを用意し、合計保持を1,095日にする。VM側の新設定を省略する行も対象|

保存先の後は、次の送信設定を準備します。

5. 旧DCR関連があり、`VmLogDestination=Log`の場合、新DCRを準備する。WindowsイベントのApplication・Security・SystemとSyslogを、CSVのLog Analyticsへ送信する内容を設定し、旧関連があるVM・VMSSへ新関連を追加する。DCR名はワークスペース名の先頭`log`を`dcr`へ置き換えた名前にする。
6. `LogDestination=Storage`または`Log`の場合、旧診断設定のログ・メトリック指定を引き継いだ新診断設定を、共通名`$newDiagnosticSettingName`で追加する。Storageなら対象リソースと同じ地域のアカウント、LogならCSVのワークスペースへ送信する。Logの場合は旧設定の格納方式も引き継ぐ。
7. 作成・更新後の値をGETで照合する。保存先やDCRなどの準備に失敗したSubは以降を中断し、他Subへ進む。診断設定の複製では各対象の結果を集め、未完了を`copy_failures.csv`へ書いて最後に失敗として終了する。

既存設定を更新する場合、StorageのIP規則、Log Analyticsの他のfeatures、他名のライフサイクルルール、既存DCRのidentityなど、変更対象外の項目を引き継ぎます。旧診断設定・旧DCR関連はこの工程では削除しません。`None`・空欄の側は新しい送信設定の作成を省き、保存先は上記の条件で準備します。

#### step2_verify.ps1：削除へ進める状態か確認

1. CSVとSubごとのJSONを読み、作業の環境・移行元・対象が記録と一致することを確認する。記録がないSubはNGとする。
2. 旧診断設定と旧2DCRの関連を現在のAzureから再取得し、記録後に旧設定が増えた、または内容が変わった場合はNGとする。既に削除されている旧設定は許可する。
3. 記録にあるRG・保存先・保持設定・Waiver・新DCR・新関連・新診断設定をすべてGETし、予定値と照合する。RGは存在を確認し、Event・Syslogの合計保持は既定値任せではなく明示設定されていることも確認する。
4. `verify_results.csv`へOK/NG、理由、NG時の期待値を出力する。他Subも調べた後、NGが1件でもあれば失敗として終了する。

Azureの設定変更は行いません。手動で不足分を設定した場合も、同じstep2を再実行して確認します。step3は内部で`-PassThru`付きで呼び、全件成功した場合だけ、この確認で読み込んだ記録を受け取ります。

#### step3_delete.ps1：確認済みの旧送信設定を削除

1. 冒頭でstep2を実行する。全Subの確認が成功しなければ、削除へ進まない。
2. 全Subの旧DCR関連を削除した後、全Subの旧診断設定を削除する。旧DCR本体は削除しない。
3. 1件ごとの削除直前に旧設定を再取得し、変更前記録と一致することを確認する。送信を続ける側は、対応する新関連・新診断設定も記録と照合する。`None`・空欄の側は新設定を作っていないため、旧設定を外して送信を終了する。
4. 既に存在しない旧設定はスキップする。不一致やAPIの失敗があれば、`delete_failures.csv`へ対象・理由・期待値を書き、以降の削除を全体で停止する。

保存先、保存済みログ、新DCR・新関連・新診断設定、Waiverは残します。途中で止まった場合も、それまでに削除した分を自動復元せず、記録を使って再実行またはrollbackします。

#### rollback.ps1：旧送信設定を復元し、新設定を変更前へ戻す

1. `records/<環境>/`のJSONから全Sub、または`-SubscriptionIds`で指定したSubを選ぶ。CSVは読み直さない。指定ID・記録の内容・作業環境が一致しなければ、変更前に停止する。
2. 選択した全Subの旧・新設定をGETし、現在値が記録した値・変更前の値と一致するか、既に不在であることを確認する。第三者が異なる設定へ変更したものは上書きせず停止する。
3. 選択した全Subの旧DCR関連→旧診断設定を先に復元する。既に元どおりなら書き込まない。旧診断を再作成する際は、5枠の空きも確認する。
4. その後、新側をDCR本体→関連付け→診断設定→Waiverの順に処理する。もともとあったDCR・関連付けは記録の変更前の値へ戻し、今回追加した関連・診断設定・Waiverは削除する。今回新設したDCR本体と、もともとあったWaiverは保持する。
5. 変更後の値をGETで照合する。失敗時は`rollback_failures.csv`へ対象と理由を書き、以降を全体で停止する。

保存先のRG・Log Analytics・Storage、保存済みログは残します。Azureポリシーの修復タスクは使用しません。指定Subだけ戻す場合、選択しなかったSubの設定は変更しません。

#### common.ps1：設定値と、各工程から呼ぶ処理

各スクリプトが最初に読み込むファイルです。`$environment`から旧2DCR・3ポリシー・12参照IDを用意し、通常は`targets.csv`の必須値・送信先フラグ・Storage名・Subの重複を確認します。Sub名をIDへ解決し、地域略称も取得します。rollbackや並列処理からの読み込みでは`-SkipCsv`を付け、CSVの読み直しを省きます。

共通関数は、Azure APIの呼び出し、現在値と期待値の照合、書き込み・復元に使う本文の取り出し、変更前JSONの読み込み、旧設定・地域・予定名の調査の5つです。Azureへの実際の作成・削除は、各工程がこれらの関数を呼んだときに行われます。通常の作業では、このファイルの先頭で必要な値を指定してから各工程を実行します。

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

CSV読み込みや環境・記録の初期検査で停止した場合は、結果CSVの出力前にPowerShell上へエラーを表示することがあります。step3冒頭の確認で止まった場合は`verify_results.csv`を確認します。`delete_failures.csv`は削除ループ中の失敗を記録するファイルで、成功時に過去の同ファイルを自動削除しないため、更新日時も合わせて確認してください。

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
