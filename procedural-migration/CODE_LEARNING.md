# 正本のコードを上から読むための学習資料

各ファイルの**指定行→説明**の順に読み、情報の取得元・格納先・使い道を追います。場所は行番号か検索式で探してください。実行手順は[README](README.md)にあります。

Sub＝サブスクリプション、RG＝リソースグループ、DCR＝データ収集ルールです。

例として、CSVの1行を`ResourceGroup=rg-log`、`StorageAccount=stjpearchive001`、`WorkspaceName=log-app`、`LogDestination=Storage`、`VmLogDestination=Log`とします。このSubには、東日本の`nsg-app`に旧診断`old-setting`、`vm-app`に旧DCR関連があるものとします。

## コードを読む前に

正本に出てくる構文を先に確認します。

### 値を入れる・取り出す

```powershell
$environment = 'dev'
$subscriptionId = $target.SubscriptionId
```

`$`で始まる名前が変数です。1行目は環境へ文字列`dev`を入れ、2行目はCSVの1行から作った`$target`からSub IDを取り出します。

```powershell
$recordPath = Join-Path $recordDirectory "$subscriptionId.json"
```

二重引用符内の変数は値へ置き換わるため、ここでは`<Sub ID>.json`という名前になります。`"$($Target.WorkspaceId)/tables/$tableName"`のような項目の参照は`$(...)`で囲みます。単一引用符内では変数を展開しません。

### 配列とハッシュテーブル

```powershell
$targets = @()
$body = @{ properties = @{} }
```

`@()`は配列（一覧）、`@{}`はハッシュテーブル（辞書）です。`$targets.Count`は件数、`$Expected.Keys`は項目名の一覧を返します。2行目は、Azureへ送る`$body`の中に空の`properties`を用意しています。後で送信先や保持日数を入れます。

`+=`は一覧への追加です。`@(処理)`は結果を配列として受け取り、0件でも1件でも同じ書き方で扱えます。

### 条件で分ける・繰り返す

```powershell
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
}
```

`foreach`は一覧から1件ずつ取り出します。`if`は条件を満たす処理、`else`は満たさない処理です。`while ($resourcePage)`は次ページのURLがある間繰り返します。`continue`は次の件へ進み、`break`は繰り返しを抜けます。

|記号|正本での読み方|
|---|---|
|`-eq` / `-ne`|等しい / 等しくない|
|`-gt` / `-ge`|より大きい / 以上|
|`-in` / `-notin`|一覧に含まれる / 含まれない|
|`-and` / `-or` / `-not`|両方満たす / どちらか満たす / 条件を反転|
|`-like` / `-match`|ワイルドカード / 正規表現で照合|

文字列の比較は通常、大文字小文字を区別しません。`-ceq`や`-cnotmatch`の`c`を付けると区別します。`$true`・`$false`は真・偽です。

### パイプラインで一覧を絞る

```powershell
$listedSettings | Where-Object { $_.Sources.Count }
```

`|`は左の結果を右へ渡し、`$_`は処理中の1件を表します。この例の`Where-Object`は、Sourcesが1件以上あるものを残します。`ForEach-Object`は各件の処理、`Sort-Object`は並べ替えです。

### 引数を渡して関数を呼ぶ

```powershell
Invoke-ArmRequest -Resource $resource -Optional -Wait
```

先頭が関数名、`-Resource`が引数名、`$resource`が渡す値です。定義の`param(...)`が引数を受け取ります。`[switch]`は付ければ有効、省略すれば無効になる引数です。

`Optional`はこの関数独自の引数名です。未作成の保存先などが404でも、エラーにせずnullを返します。省略時の404はエラーです。`-Wait`は、作成途中の保存先を使わないよう`Succeeded`まで待ちます。省略すると最初の応答を返します。

`$current = Invoke-ArmRequest ...`と書くと戻り値が`$current`に入ります。`function`は定義しただけでは動かず、呼び出したときに動きます。

### 関数の説明を読む

関数内の`<# ... #>`は、`Get-Help`でも読める説明です。`.SYNOPSIS`は目的、`.DESCRIPTION`は処理の要点、`.PARAMETER`は各引数、`.OUTPUTS`は戻り値を説明します。

ルートで次を実行するとヘルプを読めます。`-SkipCsv`は設定と関数だけを読み込み、CSV・Sub一覧・地域略称の取得を省きます。

```powershell
. .\procedural-migration\common.ps1 -SkipCsv
Get-Help Invoke-ArmRequest -Full
```

### 別ファイル・別の処理から値を使う

```powershell
. (Join-Path $PSScriptRoot 'common.ps1')
```

先頭のドットと空白は、commonの変数・関数を呼出し元でも使う指定です。`& (...)`は別スクリプトを実行し、戻り値を受け取る箇所で使います。

|書き方|役割|
|---|---|
|`$PSScriptRoot`|実行しているスクリプトのあるフォルダ。作業フォルダとは別|
|`$script:accessToken`|同じスクリプト内の関数から共用する変数|
|`$using:subscriptionId`|並列処理の外側で用意した値を、その処理へ渡す指定|

### 値がない場合と、型の指定

```powershell
$ApiVersion = $Resource.ApiVersion ?? $apiVersions[$Resource.Kind]
$status = [int]$response.StatusCode
```

`$null`は値がない状態です。空文字`''`・数値0・CSVの文字列`None`とは区別します。`??`は左がnullなら右を採用します。ここでは個別のAPI版がなければ、辞書の`[キー]`で種類ごとの版を選びます。

`[int]`は整数への変換です。`[Text.Encoding]::UTF8`のような`[型]::名前`は、その型に用意された値や処理を使います。

### 失敗を受け取る

`try`に処理、`catch`に失敗時の処理を書きます。`throw`は失敗を呼出し元へ伝え、catchで受け取られなければ実行を止めます。

`$ErrorActionPreference = 'Stop'`は、PowerShellの処理エラーをcatchで受け取る設定です。失敗時にどこまで止まるかは、各工程のtry/catchの範囲で決まります。

## 1. common.ps1を読む

[common.ps1](common.ps1)は設定値と5関数を用意します。上から、設定値→通信・比較など4関数→CSV読み込み→対象調査の関数の順です。各工程の冒頭で読み込みます。

### 1～100行：利用者の設定と、共通処理の準備

**1～12行｜`param([switch]$SkipCsv)`、`$targetWorkspaceId`から`$location`まで**

PowerShell 7以上を要求し、旧ワークスペースID・環境・新診断名・新規RG／Log Analytics／DCRの地域を指定します。Storageの地域は対象リソースから決めます。`SkipCsv`は並列処理・delete・rollbackから読み込む際に、CSVなどの取得を省くための引数です。

**18～54行｜`$environmentSettings = @{`、`$policyReferenceIds = @(`**

環境別の旧DCR2つ・既存MG・ポリシー割り当て3つを指定します。`$policyReferenceIds`は3件目で除外する12参照IDです。ここまでの6変数には、提示された本番・検証・開発の値が入っています。

**59～90行｜`$parallelLimit`、`$apiVersions`、`$settings = $environmentSettings[$environment]`**

並列数・診断設定とDCR関連のパス・API版を用意します。`$environmentSettings[$environment]`で該当環境の欄を取り出し、旧DCRと割り当ての完全なIDを組み立てます。除外参照IDは最初の2割り当てでは空、3件目だけ12個です。

**91～100行｜`$migrationContext = @{`**

今回の環境・旧ワークスペース・旧DCR・新診断名を`$migrationContext`へまとめます。step1がJSONの`Context`へ保存し、再実行時に別作業の記録でないか照合します。JSONの保存先と日本語の文字コードもここで決めます。

### 102～238行：Invoke-ArmRequestの中を読む

Azure APIへ要求し、応答を返します。GETは取得、PUTは作成・更新、DELETEは削除です。`$current = Invoke-ArmRequest -Resource $resource -Optional`なら、指定IDの応答が`$current`に入ります。期待値との比較は次の関数で行います。

**133～147行｜`if ($Resource)`、`$uri = $ResourceId`**

`-Resource`は`Id`・`Kind`・`Body`を持つ記録1項目です。ここから操作先とAPI版、PUTなどの本文を取り出します。`-Body`を別に渡せばそちらを使います。`-ResourceId`でIDだけも渡せます。短いIDには接続先とAPI版を補い、完全なURLはそのまま使います。

**148～160行｜`for ($attempt = 0; $attempt -lt 4; $attempt++)`**

トークンが未取得・期限間近、またはSubが変わったとき、ログイン済みCLIから取得して`$script:accessToken`へ保存します。後のHTTP要求はこれで認証します。取得失敗なら送信へ進みません。

**161～176行｜`$request = @{`、`Invoke-WebRequest @request`**

URL・操作・トークンを`$request`へまとめ、本文があればJSON・UTF-8バイト列にして送ります。接続・応答ヘッダは90秒待ちます。対応するPowerShellでは、本文受信中の無応答も90秒です。

**177～200行｜型を指定した`catch`、`$retryTransport`**

接続断や通信タイムアウトは、初回を含め最大4回試します。証明書・TLSの問題、中断、JSON不正は再試行しません。DELETEの応答を失った場合は、再試行で404なら削除済みと扱います。

**205～237行｜`$status`、`$Wait`、`Retry-After`**

成功応答をJSONから辞書へ変換します。`-Wait`付きで作成中なら3秒ごとにGETし、`Succeeded`で返し、`Failed`／`Canceled`なら停止します。作成全体に一律上限はありません。401は認証更新、一時HTTPエラーは待機後に再試行します。`-Optional`付きの404はnullを返します。

### 240～325行：Test-Configurationの中を読む

現在値と期待値を比較してtrue／falseを返します。例の`Test-Configuration $current $resource.Body -Kind 'Diagnostic'`は、GET結果と記録したログ・メトリック・送信先を比べます。copyは一致なら省略、verifyはOKとします。Azureへの通信は行いません。

**266～284行｜`if ($Kind -in @('Diagnostic', 'Dcr', 'Association'))`**

作成未完了ならfalseです。診断設定・DCR・関連付けは`Get-WritableBody`で比較用の形へそろえ、両方向に比べます。Lifecycleは`log-append-1095`だけを照合し、旧`log-append-365`が残っていればfalseにします。

**290～308行｜`if ($Expected -is [array])`**

配列は件数を比べ、期待する各要素に合う現在値を1つずつ探します。使った候補は除くため二重に数えず、並び順の差は許し、不足や重複の差を検出できます。

**313～324行｜`foreach ($key in $Expected.Keys)`**

辞書は項目名で値を取り出し、中身も同じ関数で比べます。通常は期待値側の項目だけを調べます。`-Exact`は逆方向にも比べ、他作業で加わった値も検出するための指定です。文字列・数値は`-eq`、片側だけnullならfalseです。

### 327～409行：Get-WritableBodyの中を読む

**343～370行｜`$body = @{ properties = @{} }`**

ここでの`Resource`はAzureのGET応答で、前の関数の「記録1項目」とは異なります。`-Kind`で種類に応じた書込み項目を取り出します。診断設定ならログ・メトリック・送信先、Waiverなどなら`properties`を基に本文を作ります。読取専用項目を除き、保存・復元・比較に使います。

**374～408行｜`$body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'`**

診断設定に`workspaceId`があれば、未指定の格納方式を`AzureDiagnostics`で補います。なければ返された格納方式を除き、Storage宛ての誤判定を防ぎます。DCRは地域・タグ・identityを残し、内部IDなどを除いて復元できる本文にします。

### 411～444行：Read-MigrationRecordの中を読む

**426～436行｜`$path = Join-Path $recordDirectory`**

`$Target.SubscriptionId`でローカルの`records/<環境>/<Sub ID>.json`を読み、不在ならnullを返します。JSONの`Context`・`Target`を今回の環境・CSVと照合し、別作業の記録なら停止します。

**438～443行｜`foreach ($name in @('Destinations', 'NewSettings', 'OldSettings'))`**

`Destinations`（保存先）・`NewSettings`（新設定）・`OldSettings`（旧設定）が配列か確認して返します。copyは再開、verifyは照合、rollbackは復元に使います。

### 450～497行：CSVを1行ずつ対象データへ変換する

**450～465行｜`if (-not $SkipCsv)`、`foreach ($row in Import-Csv`**

CLIからSub名とIDを取得し、CSV各行の前後の空白を除いて`$target`へ入れます。VM列がなければLogを補い、列があって空欄なら新送信を作らない指定として残します。`SkipCsv`付きならこの節全体を飛ばします。

**466～479行｜`$target.LogDestination -notin`**

送信先フラグと必須値を検査します。診断側はStorage・Log・None・空欄、VM側はLog・None・空欄です。Storage名は小文字英数字3～24文字で、後で置換する`jpe`が1か所必要です。

**480～489行｜`$matches = @($accounts | Where-Object`**

`SubscriptionName`をCLIのSub名・IDと照合し、一意なIDを`$target.SubscriptionId`へ入れます。例では`rg-log`の`log-app`のIDも`WorkspaceId`へ組み立てます。旧ワークスペースと同じでないことを確認し、`$targets`へ追加します。

**491～496行｜`Group-Object`、`$regionNames = Invoke-RestMethod`**

対象0件・Sub ID重複を検出します。Storage名があればAzure Naming Toolから地域略称を`$regionNames`へ取得し、後でStorage名の`jpe`の置換に使います。

### 499～781行：Get-MigrationPlanの中を読む

**519～529行｜`$plan = @{`**

Subを調べ、旧設定を`OldSettings`、作成先ID・地域を`Discovery`へ返します。新しい本文は後のstep1が`Destinations`・`NewSettings`へ組み立てます。まず環境・CSVと空の3一覧を`$plan`へ入れます。

**535～559行｜`while ($resourcePage)`**

Sub内リソース一覧から`$resourceLocations[ID] = 地域`の対応表を作ります。通常一覧に出ないStorageのBlob・File・Queue・Tableも、親の種類に応じてIDと地域を追加します。後でこの全IDへ診断設定を問い合わせます。

**563～575行｜`$resource.type -eq 'Microsoft.Cache/redisEnterprise'`**

Redis Enterpriseは`databases` APIから子DBのIDを取得し、親の地域とともに追加します。子DB・Sub一覧のどちらも`nextLink`をたどり、全ページを読みます。

**580～599行｜`$resourceLocations.Keys | ForEach-Object -Parallel`**

各IDの診断設定を最大5リソース同時に読みます。全設定を`Settings`、旧ワークスペース宛てだけを`Sources`にして`$listedSettings`へ集めます。並列処理はcommonを`SkipCsv`で読み、外側のSub ID・トークンを受け取ります。

**600～620行｜`$diagnosticSources = @($listedSettings`**

全件の結果とエラーを確認します。診断非対応の`ResourceTypeNotSupported`だけを除き、その他の失敗は停止します。旧診断のID・本文を`OldSettings`へ入れます。地域が空・globalなら東日本とし、Storage選択に使います。

**625～651行｜`foreach ($oldDcrId in $oldDcrIds)`**

旧DCR2つの関連から、このSubの関連を選びます。本体を再取得して参照先を確認し、ID・本文を`OldSettings`へ加えます。`vm-app`もここで対象になります。`OnlyOldSettings`付きならここで返し、作成後には不要な空き名・ポリシー確認を省きます。

**657～689行｜`atScope()`**

このSubに指定3割り当てが適用され、3件目のイニシアティブに12参照IDがあるか確認します。定義は次のSubでも再利用します。続いて`$discovery`に保存先・新設定の作成先を用意します。

**695～713行｜`$storageLocations = @($diagnosticSources.Location`**

CSVにStorage名があれば、旧診断の地域を重複なしで取り出します。0件なら東日本です。地域略称で`jpe`を置換し、西日本なら`stjpwarchive001`にします。名前の形式とStandard_ZRS対応を確認してIDを組み立てます。

**714～729行｜`if ($storageId -notin @($Record.Destinations.Id))`**

名前の利用可否APIで使用済みなら停止します。再実行で同じIDがJSONの`Destinations`にある場合だけ省き、構成はcopyで確認します。ID・名前・地域を`Discovery.Storages`へ渡します。

**735～754行｜`$Target.VmLogDestination -eq 'Log'`**

旧関連がありVM側がLogなら、`log-app`から`dcr-app`のIDを作り、旧関連の親VM・VMSSに新関連のIDを作ります。同じ親の旧関連が複数でも新関連は1つです。新旧同一IDは拒否し、`Discovery.Dcr`・`Associations`へ入れます。

**755～781行｜`if ($Target.LogDestination -in @('Storage', 'Log'))`**

診断側がStorage／Logなら各親に新診断のIDを作ります。対象の旧診断が複数、新旧同名、記録外の同名設定、枠不足なら停止します。新旧ID・地域を`Discovery.Diagnostics`へ入れます。None・空欄は旧診断だけを削除用に残します。

## 2. precheck.ps1を読む

[precheck.ps1](precheck.ps1)は、現在のAzureで名前・地域・対象を確認します。Azureの変更や記録保存は行いません。

**1～16行｜`. (Join-Path $PSScriptRoot 'common.ps1')`、`$results = foreach ($target in $targets)`**

`$targets`から1Subずつ`Get-MigrationPlan`へ渡し、旧設定・保存先名・追加枠・ポリシーを確認します。返された計画は`$null =`で捨て、結果表にはSub ID・OK・理由を残します。

**18～32行｜`catch`、`$results | Export-Csv`**

失敗したSubはNGと理由を残し、次へ進みます。全結果を`precheck_results.csv`へ出し、NGがあればエラーで終了します。step1はこのCSVを読まず、当日のAzureを再調査します。

## 3. step1_copy.ps1を読む

[step1_copy.ps1](step1_copy.ps1)の**10行目のforeachが1Sub分**です。Azureを調べ、作成する本文を`$plan`へ加えます。旧本文・新しい`Body`・変更前の`Before`をJSONへ保存してから書き込みます。

**1～16行｜`$record = Read-MigrationRecord -Target $target`、`$plan = Get-MigrationPlan -Target $target -Record $record`**

commonと失敗一覧・記録フォルダを用意します。CSVの1Subを`$target`、前回の記録を`$record`へ入れます（初回はnull）。Azureを再調査し、旧設定を`$plan.OldSettings`、作成先を`$plan.Discovery`へ受け取ります。

**21～38行｜`$plan.NewSettings += @{`**

3割り当てに対するWaiverのID・本文を`NewSettings`へ加えます。期限なしで、最初の2件は全体、3件目は12参照IDを除外します。後で最初に作り、作業中にポリシーが旧設定を再作成するのを防ぎます。

**39～56行｜`$plan.Destinations += @{`**

`rg-log`と`log-app`の`Id`・`Kind`・`Body`を`Destinations`へ加えます。RGは地域、Log Analyticsは保持・アクセス設定を本文にします。365日はワークスペースの保持日数で、Event・Syslogの総保持1,095日は後で加えます。

**62～88行｜`$storageIds[$storageLocation] = $storageId`**

地域別IDを`$storageIds`へ入れ、後の診断設定が同地域のStorageを選べるようにします。Storage本体のZRS・暗号化・不変性・HTTPS／TLS・共有キー無効・既定拒否も`Body`にして`Destinations`へ加えます。

**89～123行｜`Kind = 'Blob'`、`'Lifecycle'`、`'Defender'`**

Blobバージョン管理・appendBlobの1,095日後削除・Storage個別のDefender無効化を追加します。Storage本体を含め地域ごとに4項目です。CSVにStorage名があれば送信先フラグに関係なく準備します。

**129～143行｜`if ($oldAssociations.Count -gt 0)`**

旧DCR関連があれば、`log-app`のEvent・Syslogと総保持1,095日の本文を`Destinations`へ加えます。条件は旧関連の有無なので、VM側がNone・空欄でも対象です。

**148～195行｜`if ($plan.Discovery.Dcr)`、`$dcrBody.properties.dataSources = @{`**

`Discovery.Dcr`があれば本文を作ります。`dataSources`に固定のWindowsイベント・Syslog条件、`destinations`に`log-app`のID、`dataFlows`に両者の結び付きを入れ、`NewSettings`へ加えます。旧DCRは対象VMを選ぶために使い、収集条件は複製しません。

**196～205行｜`foreach ($association in $plan.Discovery.Associations)`**

新関連のIDごとに`dataCollectionRuleId=新DCRのID`の本文を作り、`NewSettings`へ加えます。これで旧関連のあるVM・VMSSを新DCRへ結び付けます。VM側がNone・空欄ならDCRと関連付けを作りません。

**211～233行｜`$original = @($plan.OldSettings`**

`OldId`で旧診断を探し、ログ・メトリック指定をコピーします。Storageなら`$storageIds`から同地域のID、Logなら`log-app`のIDと旧格納方式を設定します。新診断は`Before=null`で記録します。診断側がNone・空欄なら0件です。

**238～248行｜`$setting.Before = $saved[0].Before`**

Waiver・DCR・関連の現在値を`Before`へ保存します。不在はnullで、rollbackが復元か削除かを決めます。再実行は最初の`Before`を維持します。新設DCRには`KeepOnRollback=true`を付けて残します。

**249～260行｜`$body.properties[$property] = $setting.Body.properties[$property]`**

既存DCR・関連の`Before`を土台に、今回指定する`Body.properties`を差し替えます。未指定項目は引き継ぎます。3一覧にID・本文がそろったら、組立て用の`Discovery`を除きます。

**266～289行｜`if ($record)`、`foreach ($collection in`**

記録済みの旧設定に消失・変更があれば停止します。3一覧をIDで照合し、新規の項目だけ`$record`へ追記します。同じIDの`Body`が前回と違っても停止します。初回は`$plan`をそのまま記録にします。

**293～303行｜`WriteAllText`、`Replace`、`Move`**

`$record`をJSONにして`.tmp`へ書き、既存記録ならReplace、初回ならMoveで`<Sub ID>.json`にします。保存完了後にAzureへの書込みへ進みます。

**309～313行｜`$resources = @($record.NewSettings`**

Waiver→RG・保存先・保持設定→DCR・関連の順に`$resources`を作り、各項目を同じループで取得・比較・書込みします。新診断は準備完了後の別処理です。

**317～335行｜`if (-not $providersReady`**

Waiverの後、最初の保存先の前に必要なRPを確認します。未登録なら登録し、3秒ごとにRegisteredまで待ちます。`$providersReady=true`で同じSub内の再確認を省きます。

**336～357行｜`$matched = Test-Configuration`**

`Invoke-ArmRequest -Optional -Wait`で現在値を読み、未作成ならnull、作成中なら完了を待ちます。`Body`と一致なら省略します。RGは存在だけ、テーブルは総保持の明示設定も確認します。既存Waiverの不一致は停止し、DCR・関連は`Before`と一致する場合だけ更新します。

**363～387行｜`if ($current -and $resource.Kind -eq 'Storage')`**

既存Storageの地域・SKU・暗号化・不変性を確認します。IP規則を残し、既定拒否とAzureサービス例外を更新します。既存Log Analyticsは地域を確認し、他のfeaturesを残してログ参照権限を加え、PATCHで更新します。

**388～396行｜`$_.name -notin`**

管理対象の旧365日・1,095日ルールを除き、新しい1,095日ルールを加えます。他名のルールは残します。既存テーブルは`totalRetentionInDays=1095`だけをPATCHし、分析用保持などを保ちます。

**401～424行｜`while ($true)`、`-Method $method -Body $body`**

本文をPUT／PATCHし、GETで`Body`と照合します。DCRの`InvalidOutputTable`が指定の組込み出力の反映待ちなら、10秒後に再試行します。その他のエラーや作成値の不一致は停止します。

**430～444行｜`$diagnostics | ForEach-Object -Parallel`**

準備後、新診断を最大5件同時に作成します。各処理はSub ID・対象ID・理由・期待本文を`$result`へ入れます。commonを`SkipCsv`で読み、外側のSub ID・トークンを受け取ります。

**445～467行｜`return $result`**

新診断をGETし、`Body`と一致なら省略、不一致なら失敗、不在ならPUTします。作成後もGETで照合します。結果を`$copied`へ集め、全件戻ったことを確認し、失敗分を`$failures`へ追加します。

**469～490行｜外側の`catch`、`$failurePath = Join-Path $PSScriptRoot`**

準備中に失敗したSubは残りを飛ばし、他Subへ進みます。最後に`copy_failures.csv`を出してエラーにし、成功なら過去の失敗CSVを削除します。旧設定は残し、step2の確認後にstep3で外します。

## 4. step2_verify.ps1を読む

[step2_verify.ps1](step2_verify.ps1)は記録したIDの現在値を読み、保存先・新設定を確認します。結果を人が確認してからstep3へ進みます。step3も冒頭で同じ検査を行います。

**1～19行｜`param([switch]$PassThru)`、`Read-MigrationRecord`**

SubごとのJSONを読み、不在ならNGです。`-OnlyOldSettings`で旧診断・旧DCR関連を再取得します。新しい保存先は既に作成済みなので、初回の空き名・ポリシー確認を省きます。

**20～25行｜`foreach ($current in $currentPlan.OldSettings)`**

現在の旧設定をJSONと比較し、追加・改変があればNGです。既に不在の旧設定は許可するため、step3が途中まで削除した後も再確認できます。

**30～58行｜`@($record.Destinations) + @($record.NewSettings)`**

保存先と新設定をGETし、各`Body`と比べます。RGは存在、Event・Syslogは総保持1,095日の明示設定も確認します。NGにはID・理由・手動修正用の期待本文を残し、次へ進みます。

**59～83行｜`$records += $record`、`if ($PassThru)`**

Subの読込み・調査失敗もNGにし、全結果を`verify_results.csv`へ出します。NGなら例外で終了します。`-PassThru`は全件OKのときだけ、結果行ではなく読み込んだJSON記録を返す指定です。step3が削除対象を受け取るために使います。

## 5. step3_delete.ps1を読む

[step3_delete.ps1](step3_delete.ps1)は、全Subのstep2成功後に記録した旧設定を削除します。削除直前にも旧設定と対応する新設定を照合します。

**7～14行｜`$records = @(& (Join-Path`**

`&`でstep2を`-PassThru`付きで実行し、記録を`$records`へ受け取ります。NGなら削除に進みません。commonを`SkipCsv`で読み、全Subの旧DCR関連→全Subの旧診断の順に処理します。

**18～25行｜`if (-not $current)`**

旧設定をGETし、不在なら省略します。存在すれば書込み用本文を取り出して記録と両方向に照合し、step2後の変更も検出して削除を止めます。

**30～50行｜`$newId = ''`、`if ($newId)`**

旧設定の親IDから新設定IDを求め、`NewSettings`の本文と現在値を比べます。不在・不一致なら停止します。None・空欄は送信終了の指定なので、新側の照合を省いて旧設定を削除します。

**51～68行｜`-Method Delete`、`catch`**

旧設定をDELETEします。失敗は`delete_failures.csv`へ残し、他Subも含め以降の削除を止めます。削除済みの分は自動復元しません。保存先・新設定は残し、再実行かrollbackで対応します。

## 6. rollback.ps1を読む

[rollback.ps1](rollback.ps1)は、旧設定の`Body`と新設定の`Before`で送信設定を戻します。copy・deleteの途中でも完了後でも使えます。旧送信を全件戻してから、新側を変更前へ戻します。

**1～19行｜`$PSBoundParameters.ContainsKey('SubscriptionIds')`**

CSVを使わず、`records/<環境>/`から対象を選びます。`-SubscriptionIds`省略時は全Sub、指定時は該当IDの記録だけです。空・重複・記録にないIDなら停止します。

**20～30行｜`$records = @(foreach ($file in $recordFiles)`**

ファイル名と`Target.SubscriptionId`を照合し、保存済みTargetで`Read-MigrationRecord`を呼びます。今回の環境・旧ワークスペースなどと一致しなければ、書込み前に停止します。

**36～49行｜`$matchesBody`、`$matchesBefore`**

全対象の現在値が`Body`・`Before`・不在のいずれかを確認し、他の変更があれば停止します。保存先、新設DCR本体、元からあるWaiverは戻す対象から除きます。

**55～70行｜`foreach ($phase in @('Old', 'New'))`**

`$phase`をOld→Newに切り替えます。全Subの旧DCR関連→旧診断を`Body`から復元後、新DCR→新関連→新診断→Waiverを`Before`へ戻します。

**74～85行｜`$expectedBody = $setting.Body`**

Oldは`Body`、Newは`Before`を`$expectedBody`へ入れます。再取得して一致済みなら省略し、最初の確認後に別の変更があれば停止します。

**89～109行｜`if ($null -eq $expectedBody)`**

旧診断を再作成する前に5枠の空きを確認します。復元値があればPUT、nullなら今回追加した設定をDELETEし、GETで照合します。例では旧`old-setting`を戻した後、新`setByAzurePlatformTeam`を消します。

**115～129行｜`catch`、`Remove-Item $failurePath`**

失敗は`rollback_failures.csv`へ出して停止し、成功なら過去の失敗CSVを消します。再実行は復元済みを省略できます。保存先・保存済みログ・新設DCR・既存Waiverは残し、今回新設したWaiverは削除します。