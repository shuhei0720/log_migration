# 正本のコードを上から読むための学習資料

各ファイルを開き、**指定行のコード→その直下の説明**の順で読んでください。行番号と検索式で場所を見つけ、「どこから何を読み、どの変数へ入れ、次に何へ使うか」を追います。実行手順は[README](README.md)にあります。

Sub＝サブスクリプション、RG＝リソースグループ、DCR＝データ収集ルールです。

説明中は、CSVの1行が `ResourceGroup=rg-log`、`StorageAccount=stjpearchive001`、`WorkspaceName=log-app`、`LogDestination=Storage`、`VmLogDestination=Log`の場合を追います。このSubに東日本の`nsg-app`の旧診断`old-setting`と、`vm-app`の旧DCR関連がある例を使います。

## コードを読む前に

まず、後の説明で使う書き方を確認します。例は正本から抜粋したもので、ここでは読むための例として使います。値の受渡しと繰り返しが分かると、各工程の流れを追いやすくなります。

### 値を入れる・取り出す

```powershell
$environment = 'dev'
$subscriptionId = $target.SubscriptionId
```

`$`で始まる名前が変数です。1行目は、環境を表す変数へ文字列`dev`を入れます。2行目の`$target`はCSVの1行から作ったデータで、そこに格納されたSub IDを取り出しています。

```powershell
$recordPath = Join-Path $recordDirectory "$subscriptionId.json"
```

二重引用符の中では変数が値に置き換わり、上の例では対象SubのIDに`.json`を付けたファイル名になります。`"$($Target.WorkspaceId)/tables/$tableName"`のように、項目の参照や式を入れる場合は`$(...)`で囲みます。単一引用符の中では変数を展開しません。

### 配列とハッシュテーブル

```powershell
$targets = @()
$body = @{ properties = @{} }
```

`@()`は複数の値を並べる配列（一覧）、`@{}`は項目名を使って値を取り出すハッシュテーブル（辞書）です。`$targets.Count`は対象の件数、`$Expected.Keys`は辞書の項目名一覧です。2行目は、Azureへ送る本文を入れる`$body`を用意し、その中に`properties`という空の辞書を作っています。後で、この中へ送信先IDや保持日数などを入れます。

`$plan.NewSettings += ...`の`+=`は一覧への追加です。`@(処理)`は処理結果を配列として受け取り、0件・1件・複数件を同じ書き方で扱うためにも使います。

### 条件で分ける・繰り返す

```powershell
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
}
```

`foreach`は一覧から1件ずつ取り出します。`if (条件) { ... }`は条件を満たすとき、`else`は満たさないときの処理です。`while ($resourcePage)`は次ページのURLがある間の繰り返しで、`continue`は今回の残りを飛ばし、`break`は繰り返しを抜けます。

|記号|正本での読み方|
|---|---|
|`-eq` / `-ne`|等しい / 等しくない|
|`-gt` / `-ge`|より大きい / 以上|
|`-in` / `-notin`|一覧に含まれる / 含まれない|
|`-and` / `-or` / `-not`|両方満たす / どちらか満たす / 条件を反転|
|`-like` / `-match`|ワイルドカード / 正規表現で照合|

文字列の比較は通常、大文字小文字を区別しません。`-ceq`や`-cnotmatch`の`c`は、区別して比較する指定です。`$true`・`$false`は真・偽を表します。

### パイプラインで一覧を絞る

```powershell
$listedSettings | Where-Object { $_.Sources.Count }
```

`|`は左の結果を右の処理へ渡します。`$_`は今処理している1件です。この例は、Sourcesの件数があるものだけを残します。件数0は条件を満たさないものとして扱います。`Where-Object`は絞込み、`ForEach-Object`は各件の処理、`Sort-Object`は並べ替えに使います。

### 引数を渡して関数を呼ぶ

```powershell
Invoke-ArmRequest -Resource $resource -Optional -Wait
```

先頭が関数名です。`-Resource`は引数名、その次の`$resource`が渡す値です。定義側の`param(...)`が受け取る引数を示します。`[switch]`の引数は、`-Optional`や`-Wait`のように付けるだけで有効になります。`$current = Invoke-ArmRequest ...`と書けば、関数から返った値を`$current`へ入れられます。関数は`function`で定義しただけでは動かず、呼び出したときに動きます。

### 関数の説明を読む

関数の直前にある`<#`から`#>`までは、PowerShellのヘルプとしても表示できる説明です。`.SYNOPSIS`で何をする関数か、`.DESCRIPTION`で処理の要点、`.PARAMETER 引数名`で渡す値、`.OUTPUTS`で返される値を確認します。その後、`function`内のコードを読むと、入力から結果までの流れを追えます。

リポジトリのルートで次を実行すると、関数を読み込んでヘルプを表示できます。`-SkipCsv`を付けるため、CSVの読み込みやAzureへの問い合わせは行いません。

```powershell
. .\procedural-migration\common.ps1 -SkipCsv
Get-Help Invoke-ArmRequest -Full
```

### 別ファイル・別の処理から値を使う

```powershell
. (Join-Path $PSScriptRoot 'common.ps1')
```

先頭のドットと空白は、commonを読み込み、その変数や関数を呼出し元でも使えるようにする指定です。`& (...)`は別スクリプトを実行する呼出しで、この正本では返された記録を受け取る箇所に出てきます。

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

`$null`は値がない状態で、空文字`''`や数値0、CSVの文字列`None`とは区別します。`??`は左がnullの場合だけ右を採用する記号です。1行目では、個別のAPI版が指定されていなければ、種類に対応する版を辞書の`[キー]`で選びます。

`[int]`は整数への変換です。`[Text.Encoding]::UTF8`のような`[型]::名前`は、その型に用意された値や処理を使う書き方です。Azureの応答コードを数値にしたり、文字コードを指定したりする箇所で使います。

### 失敗を受け取る

`try { ... }`に処理を置き、失敗したときの処理を`catch { ... }`に書きます。`throw`は失敗を呼出し元へ伝えます。そこでcatchが受け取ればCSVへの記録などを行い、受け取るcatchがなければ実行を停止します。

正本の`$ErrorActionPreference = 'Stop'`は、PowerShellの処理エラーをcatchで受け取れるようにする設定です。「1件の失敗で何を止めるか」は、各工程のtry/catchの位置を見て確認します。

## 1. common.ps1を読む

[common.ps1](common.ps1)には、各工程が使う変数と5つの関数が入っています。上から、利用者が指定する値、Azureへの通信など4関数、CSVの読み込み、移行対象を調べる5つ目の関数の順に読みます。各工程の冒頭でこのファイルを読み込むと、変数が用意され、必要な関数を呼べるようになります。

### 1～100行：利用者の設定と、共通処理の準備

**1～11行｜`param([switch]$SkipCsv)`、`$targetWorkspaceId`から`$location`まで**

最初にPowerShell 7以上が必要だと宣言します。続く4変数で、移行対象を探すための旧ワークスペースID、実行する環境、新診断設定名、新しいRG・Log Analytics・DCRの配置地域を指定します。Storageの地域は後で対象リソースから決めます。`SkipCsv`は、並列処理やrollbackからcommonを読む際、後半のCSV読み込みを省く引数です。

**17～53行｜`$environmentSettings = @{`、`$policyReferenceIds = @(`**

環境ごとに、関連付けを探す旧DCR2つ、既存の管理グループ、除外するポリシー割り当て3つを指定します。`$policyReferenceIds`には、3件目の割り当てで除外する12個の参照IDを入れます。ここまでが利用者向けの6変数で、本番・検証・開発の提示値が入っています。

**59～90行｜`$parallelLimit`、`$apiVersions`、`$settings = $environmentSettings[$environment]`**

診断設定を同時に処理する数、リソースIDに付ける診断設定・DCR関連のパス、Azure APIの版番号を用意します。`$environmentSettings[$environment]`は、例えばdevならdevの欄を取り出す書き方です。その値から旧DCRとポリシー割り当ての完全なIDを作り、後のAzure調査に使います。除外する参照IDは最初の2割り当てでは空、3件目だけ12個を持たせます。

**91～100行｜`$migrationContext = @{`**

今回の環境・旧ワークスペースID・旧DCRのID・新診断設定名を、`$migrationContext`という辞書へまとめます。step1はこれをJSONの`Context`へ保存し、再実行時には今回の値と比べて別作業のJSONの使用を防ぎます。JSONの保存先は`records/dev`などに決め、日本語の入出力に使う文字コードもそろえます。

### 102～235行：Invoke-ArmRequestの中を読む

Azure APIへ要求を送り、その応答を受け取る関数です。GETは現在値の取得、PUTは本文を送って作成・更新、DELETEは削除を指します。例えば`$current = Invoke-ArmRequest -Resource $resource -Optional`は、そのIDの現在値を読み、応答の`properties`などを`$current`から取り出せる形で返します。値が期待どおりかの比較は、次の`Test-Configuration`が担当します。

**128～143行｜`if ($Resource)`、`$uri = $ResourceId`**

`-Resource`には、`Id`（操作先）、`Kind`（Storage・診断設定などの種類）、`Body`（作成する値）を持つ1項目を渡します。ここではその中からURL・API版を決め、PUTなどで本文を省略したときは`Body`も取り出します。`-ResourceId`でIDだけを渡す方法もあり、`/subscriptions/...`で始まるIDにはAzureの接続先とAPI版を付け、完全なURLならそのまま使います。

**144～157行｜`for ($attempt = 0; $attempt -lt 4; $attempt++)`**

呼出し元の`$subscriptionId`を使い、今回のSubで使える認証用トークンを確認します。未取得、Subの変更、有効期限間近の場合は、ログイン済みのAzure CLIから取り直して`$script:accessToken`へ入れます。後続のHTTP要求はこのトークンで認証します。取得できなければ例外を返し、要求の送信へ進みません。

**158～173行｜`$request = @{`、`Invoke-WebRequest @request`**

URL、GETやPUTなどの操作、認証用トークンを`$request`へまとめます。送る本文があれば、辞書の`Body`をJSON文字列・UTF-8のバイト列へ変換して加え、`Invoke-WebRequest`で送信します。接続・応答ヘッダの待機は90秒です。`OperationTimeoutSeconds`を使えるPowerShellでは、本文受信中の無応答にも90秒を指定します。

**174～197行｜型を指定した`catch`、`$retryTransport`**

接続断・本文切断・通信タイムアウトなど、一時的な通信失敗を最大4回試します。証明書・TLSの問題や明示的な中断、JSON不正などはそのまま失敗にします。DELETEの応答だけを受け取れなかった場合は印を残し、同じ要求の再試行で404になれば削除済みとして扱います。

**202～234行｜`$status`、`$Wait`、`Retry-After`**

HTTPの成功応答をJSONから辞書へ変換して返します。`-Wait`付きで作成状態が途中なら、3秒ごとのGETで`Succeeded`まで待ち、`Failed`／`Canceled`なら例外にします。前の90秒は1回の通信の待機時間で、作成全体の所要時間には上限を置きません。401なら認証を更新し、一時HTTPエラーなら待機後に初回を含め最大4回試します。`-Optional`付きの404は、不在を表すnullを返します。

### 237～321行：Test-Configurationの中を読む

渡された2つの値を比べ、一致ならtrue、不一致ならfalseを返す関数です。例えば`Test-Configuration $current $resource.Body -Kind 'Diagnostic'`は、先にGETした現在値と、JSONに保存した診断設定のログ・メトリック・送信先を比較します。copyはtrueなら作成をスキップし、verifyはOK/NGを決めます。

**261～279行｜`if ($Kind -in @('Diagnostic', 'Dcr', 'Association'))`**

現在値の作成状態が未完了ならfalseを返します。診断設定・DCR・DCR関連では、後述の`Get-WritableBody`へ両方の値を渡し、書き込める項目にそろえてから比較します。`Exact`では左右を入れ替えてもう一度比較し、余分な項目も含めて差を調べます。ライフサイクルでは、管理対象の`log-append-1095`を比較し、旧`log-append-365`が残っていればfalseにします。

**285～303行｜`if ($Expected -is [array])`**

診断設定の`logs`など、値が配列なら件数を比べ、期待する各要素に対応する現在値を1つずつ探します。一致相手を見つけるたびに候補の一覧から外すため、同じ要素を二重に数えません。これにより並び順だけの差は許し、要素の不足や重複の差はfalseにできます。

**309～320行｜`foreach ($key in $Expected.Keys)`**

期待値が辞書なら、`properties`や`workspaceId`などの項目名で現在値を取り出し、同じ関数を呼んで中の値を比べます。通常は期待値の項目がそろえばtrueで、現在値の余分な項目は許します。`Exact`では逆向きにも比較するため、余分な項目も検出します。文字列・数値は`-eq`で比べ、片方だけnullならfalseにします。

### 323～407行：Get-WritableBodyの中を読む

**339～366行｜`$body = @{ properties = @{} }`**

引数で受け取ったGET応答から、PUTや比較に使う本文を作って返します。例えば`Get-WritableBody $source -Kind 'Diagnostic'`では、`$source.properties`のログ・メトリック・送信先を`$body.properties`へ取り出します。Azureが管理する作成状態などは除き、旧設定の保存・復元に使える本文にします。DCRは入れ子の項目も加工するため、先に応答のコピーを作ります。

**371～406行｜`$body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'`**

診断設定の`workspaceId`がある場合、省略された格納方式を既定の`AzureDiagnostics`で補います。Storage宛てなど`workspaceId`がない場合は、Azureが格納方式を返しても本文から除きます。これで格納方式の項目だけを理由に一致判定が変わるのを防ぎます。DCRでは地域・タグ・identity（認証に使うID設定）を残し、内部IDなどを除いて、再作成できる本文を返します。

### 409～443行：Read-MigrationRecordの中を読む

**424～435行｜`$path = Join-Path $recordDirectory`**

`$Target.SubscriptionId`から`records/<環境>/<Sub ID>.json`のパスを作り、ローカルファイルを読みます。なければ初回作業としてnullを返します。このJSONには旧設定だけでなく、新しく作る値`Body`と変更前の値`Before`も入っています。`Context`と`Target`を今回の環境・CSVの値と比べ、別作業のJSONなら停止します。

**437～442行｜`foreach ($name in @('Destinations', 'NewSettings', 'OldSettings'))`**

JSONの`Destinations`（RG・Storageなどの保存先）、`NewSettings`（新診断設定・DCRなど）、`OldSettings`（旧診断設定・旧DCR関連）が配列になっているか確認します。読んだ内容を辞書として返し、copyは再開、verifyは現在値との比較、rollbackは旧設定の復元に使います。

### 449～496行：CSVを1行ずつ対象データへ変換する

**449～464行｜`if (-not $SkipCsv)`、`foreach ($row in Import-Csv`**

Azure CLIからSubの名前とIDの一覧を取得し、CSVを1行ずつ読みます。保存先RG名・Storage名・Workspace名・送信先フラグの空白を除いて、1Sub分の辞書`$target`へ入れます。VM列がない旧CSVではLogを補いますが、列があって空欄なら「新送信を作らない」指定として空欄を残します。`-SkipCsv`で読み込んだ場合は、このCSV処理全体を飛ばします。

**465～478行｜`$target.LogDestination -notin`**

今読んだ`$target`の送信先フラグと、Sub名・RG名・Workspace名の必須値を検査します。診断側はStorage・Log・None・空欄、VM側はLog・None・空欄を受け付けます。Storage名を指定した場合は、小文字英数字3～24文字で`jpe`を1か所含むことも確認します。後でこの`jpe`を地域略称に置き換えるためです。

**479～488行｜`$matches = @($accounts | Where-Object`**

CSVの`SubscriptionName`をCLIのSub名・IDの一覧と照合し、候補が1件ならそのIDを`$target.SubscriptionId`へ入れます。例の行では、さらに`rg-log`配下の`log-app`の完全なIDを`WorkspaceId`へ組み立てます。旧ワークスペースと同じIDでないことを確認し、完成した`$target`を一覧`$targets`へ追加します。

**490～495行｜`Group-Object`、`$regionNames = Invoke-RestMethod`**

完成した`$targets`が0件でないことと、同じSub IDの重複がないことを確認します。Storage名が1行でもあれば、MicrosoftのAzure Naming Toolから地域名と略称を取得して`$regionNames`へ入れます。次の関数がこの一覧を使い、Storage名の`jpe`を対象地域の略称へ置き換えます。

### 498～780行：Get-MigrationPlanの中を読む

**516～526行｜`$plan = @{`**

`$Target`のSubをAzureで調べ、旧設定と作成先の情報をまとめて返す関数です。まず`$plan`に環境・CSVの内容と空の3一覧を用意します。以降で旧設定のID・種類・本文を`OldSettings`へ、作成先ID・地域を`Discovery`へ入れます。Azureへ送る新しい本文は、呼出し元のstep1が`Destinations`と`NewSettings`へ組み立てます。

**532～556行｜`while ($resourcePage)`**

AzureのSub内リソース一覧APIを読み、`$resourceLocations[リソースID] = 地域`という対応表を作ります。これが後で診断設定を問い合わせるIDの一覧になります。通常一覧に出ないStorageの子サービスは、親の種類に応じたBlob・File・Queue・TableのIDを組み立てて追加し、親と同じ地域を入れます。

**560～572行｜`$resource.type -eq 'Microsoft.Cache/redisEnterprise'`**

Redis Enterpriseの場合は、親の`databases` APIから子DB一覧を取得し、各DBのIDと親の地域を同じ`$resourceLocations`へ加えます。子DB一覧に続きがあれば`$databases.nextLink`、Subのリソース一覧に続きがあれば`$page.nextLink`を読みます。両方を読み終えるまで繰り返し、診断設定を調べるIDをそろえます。

**577～596行｜`$resourceLocations.Keys | ForEach-Object -Parallel`**

集めた各IDの診断設定一覧APIを、最大5リソース分同時に読みます。リソースごとに、全診断設定を`Settings`へ、その中で旧ワークスペース宛てのものだけを`Sources`へ入れ、結果を`$listedSettings`へ集めます。並列処理ではcommonをCSVなしで読み込み、外側のSub IDと認証用トークンを受け取ってAzureへ接続します。

**597～617行｜`$diagnosticSources = @($listedSettings`**

全リソース分の結果が戻ったかと、取得エラーがないかを確認します。診断非対応の`ResourceTypeNotSupported`だけを対象外とし、その他の失敗は停止します。`Sources`があるものを選び、旧診断のIDと本文を`$plan.OldSettings`へ追加します。例の`nsg-app`の`old-setting`もここに入ります。対象の地域が空・globalなら東日本とし、後で同地域のStorageを選ぶために使います。

**623～649行｜`foreach ($oldDcrId in $oldDcrIds)`**

指定した旧DCR2つの関連一覧を取得し、IDが今回のSubに属する関連を選びます。各関連の本体を読み直し、参照先が同じ旧DCRであることを確認してID・本文を`OldSettings`へ追加します。例の`vm-app`は、この旧関連があるためVM側の移行対象になります。`-OnlyOldSettings`付きならここで`$plan`を返し、後半の名前やポリシーの確認を省きます。

**656～688行｜`atScope()`**

このSubに適用されるポリシー割り当て一覧を取得し、指定の3割り当てが含まれるか確認します。3件目のイニシアティブ（ポリシー群）の定義を読み、除外する12参照IDが実在するかも確かめます。同じ定義は変数へ保存して次のSubでも使います。続いて、Storage・DCR・関連付け・診断設定の作成先を入れる`$discovery`を用意します。

**694～712行｜`$storageLocations = @($diagnosticSources.Location`**

CSVにStorage名があれば、移行対象の旧診断がある地域を重複なしで取り出します。対象がなければ東日本1つにします。`$regionNames`から各地域の略称を選び、例の`stjpearchive001`なら西日本用を`stjpwarchive001`へ変換します。変換後の名前の書式と、AzureのSKU一覧でその地域がStandard_ZRSに対応することを確認し、Storage IDを組み立てます。

**713～728行｜`if ($storageId -notin @($Record.Destinations.Id))`**

Storage名の利用可否APIを呼び、使用済みなら停止します。再実行で同じStorage IDがJSONの`Destinations`にある場合だけ、この空き確認を省きます。既に自分が作成した可能性があるためで、実際の構成は後のcopyが比較します。確認した`Id`・`Name`・`Location`を`Discovery.Storages`へ入れ、copyへ渡します。

**734～753行｜`$Target.VmLogDestination -eq 'Log'`**

旧DCR関連があり、`VmLogDestination=Log`なら、新DCRと関連付けのIDを組み立てます。例の`log-app`から`dcr-app`という名前を作り、旧関連の親IDを使って`vm-app`などの新関連IDを決めます。同じ親の旧関連が複数あれば新関連は1つにまとめます。新旧IDの一致を拒否し、結果を`Discovery.Dcr`と`Discovery.Associations`へ入れます。DCRの本文は後のcopyで作ります。

**754～780行｜`if ($Target.LogDestination -in @('Storage', 'Log'))`**

`LogDestination=Storage/Log`なら、各対象リソースに新診断名を付けてIDを作ります。対象の旧診断が複数、新旧同名、JSONにない同名設定、追加枠不足なら停止します。新旧IDと地域を`Discovery.Diagnostics`へ入れ、`OldSettings`とともに返します。None・空欄では新診断の項目を作らず、旧診断は最後の削除に備えて`OldSettings`へ残します。

## 2. precheck.ps1を読む

[precheck.ps1](precheck.ps1)は、CSVの対象に対して作業を始められるか、現在のAzureを調べる入口です。Azureを変更せず、step1で使う変更前記録も作りません。

**1～17行｜`. (Join-Path $PSScriptRoot 'common.ps1')`、`$results = foreach ($target in $targets)`**

commonで作った`$targets`から1Subずつ取り出し、`Get-MigrationPlan`へ渡します。例では`nsg-app`の旧診断と`vm-app`の旧DCR関連を探し、Storage名の空き・診断設定の追加枠・ポリシーを確認します。返された旧設定や作成先は`$null =`で受け流し、結果表にはSub ID・OK・理由だけを残します。

**19～34行｜`catch`、`$results | Export-Csv`**

調査が失敗したSubでは、例外のメッセージを理由としてNG行を作り、次のSubへ進みます。全Subの結果を`precheck_results.csv`へ出力し、NGが1件でもあればエラーで終了します。このCSVは人が事前確認するための結果表で、step1の入力ではありません。step1は実行当日のAzureを改めて調べます。

## 3. step1_copy.ps1を読む

[step1_copy.ps1](step1_copy.ps1)では、**11行目のforeachの中が1つのSub分**です。まずAzureの旧設定と作成先を調べ、これから書き込む本文も`$plan`へ加えます。これを再実行・切り戻し用の`$record`としてJSONへ保存してから、Azureへの書き込みを始めます。JSONには旧設定の本文、新しい作成値`Body`、変更前の値`Before`が入ります。

**1～17行｜`$record = Read-MigrationRecord -Target $target`、`$plan = Get-MigrationPlan -Target $target -Record $record`**

commonを読み込み、失敗を集める一覧とJSON用フォルダを用意します。CSVの1Sub分を`$target`へ取り出し、前回のJSONを`$record`へ読みます。初回はnullです。続く`Get-MigrationPlan`で現在のAzureを調べ、旧診断・旧DCR関連を`$plan.OldSettings`へ、作成先IDを`$plan.Discovery`へ受け取ります。precheckを実行したかどうかには依存しません。

**23～40行｜`$plan.NewSettings += @{`**

指定の3ポリシー割り当てについて、Sub配下の適用除外IDと本文を`$plan.NewSettings`へ追加します。期限なしのWaiverで、1・2件目は全体、3件目は指定の12参照IDを除外する本文です。後でこの適用除外を最初に作り、作業中にポリシーが旧設定を作り直すのを防ぎます。この時点では変数へ入れるだけです。

**41～58行｜`$plan.Destinations += @{`**

CSVの`rg-log`と`log-app`を、保存先の一覧`$plan.Destinations`へ追加します。各項目は`Id`・`Kind`・`Body`を持ち、後半のループがこれを読んでAzureへ送ります。RGの本文は配置地域、ワークスペースの本文は保持日数・アクセス設定などです。ここの365日はワークスペース全体の保持期間で、Event・Syslogの総保持1,095日は後のブロックで加えます。

**65～91行｜`$storageIds[$storageLocation] = $storageId`**

`Discovery.Storages`から地域別の作成先IDを読み、「東日本→stjpearchive001のID」のような対応を`$storageIds`へ入れます。後で診断設定の地域から送信先IDを選ぶためです。同時に、Storage本体の`Body`を組み立てて`Destinations`へ追加します。ZRS、二重暗号化、不変性、HTTPS・TLS、共有キー無効、通信の既定拒否などが、実際に送る値です。

**92～126行｜`Kind = 'Blob'`、`'Lifecycle'`、`'Defender'`**

同じStorage配下のIDで、Blobのバージョン管理、appendBlobを最終更新から1,095日経過後に削除するルール、Defender無効化の3項目を`Destinations`へ追加します。DefenderはSubの既定値よりStorage個別の指定を優先させます。Storage本体と合わせ地域ごとに4項目です。CSVにStorage名があれば送信先フラグに関係なく準備し、名前がなければこの繰り返しは0件になります。

**132～146行｜`if ($oldAssociations.Count -gt 0)`**

`OldSettings`から`Kind=Association`の旧DCR関連を取り出します。1件でもあれば、`log-app`のEvent・SyslogテーブルのIDと、総保持1,095日の本文を`Destinations`へ加えます。条件は旧関連の有無なので、VMの新送信をNone・空欄にした場合も、旧関連があればテーブルの保持期間を設定します。

**151～198行｜`if ($plan.Discovery.Dcr)`、`$dcrBody.properties.dataSources = @{`**

`Discovery.Dcr`がある場合、新DCRの本文を作ります。`dataSources`へコード内の固定値でWindowsイベントの取得条件・Syslogの種類と重大度、`destinations`へ`log-app`のIDを入れます。`dataFlows`は収集したログを`new-workspace`という送信先名へ結び付けます。本文を`NewSettings`へ追加します。旧DCR関連は対象VM・VMSSを選ぶために使い、収集条件はここに書いた値を使います。

**199～208行｜`foreach ($association in $plan.Discovery.Associations)`**

`Discovery.Associations`のIDごとに、`dataCollectionRuleId=新DCRのID`という本文を作り、`NewSettings`へ加えます。これをAzureへ送ると、`vm-app`など旧関連があったVM・VMSSが新DCRへ結び付きます。VM本体を作る処理はありません。VM送信先がNone・空欄なら`Discovery.Dcr`がなく、DCRと関連付けの両方を省略します。

**215～237行｜`$original = @($plan.OldSettings`**

`Discovery.Diagnostics`の`OldId`で旧診断を探し、`Body.properties.logs`と`metrics`を新しい本文へコピーします。Storage宛てなら、対象の地域を`$storageIds`で引いて送信先IDを入れます。Log宛てなら`log-app`のIDと旧設定の格納方式を入れます。新診断を`Before=null`として`NewSettings`へ加えます。診断送信先がNone・空欄なら、この繰り返しは0件です。

**243～253行｜`$setting.Before = $saved[0].Before`**

Waiver・DCR・関連付けの各IDをAzureで取得し、書き込み可能な本文を`Before`へ入れます。不在ならnullで、rollbackはこれを見て復元か削除かを決めます。再実行ではJSON内の最初の`Before`を引き継ぎ、現在値で置き換えません。新設するDCR本体には`KeepOnRollback=true`を付け、切り戻しでも残す対象にします。

**254～265行｜`$body.properties[$property] = $setting.Body.properties[$property]`**

DCR・関連付けの`Before`があれば、その本文を土台に今回の`Body.properties`の項目を差し替えます。例えば`dataSources`は中身ごと更新し、今回指定していない項目は元の本文から引き継ぎます。これを最終的な`Body`にします。必要なIDと本文が3一覧へそろったため、組み立て用だった`Discovery`を`$plan`から取り除きます。

**272～295行｜`if ($record)`、`foreach ($collection in`**

再実行では、JSONの`OldSettings`と今回調べた旧設定をID・本文で比較し、消失・変更があれば停止します。次に保存先・新設定・旧設定の3一覧をIDで照合し、新しく見つかった項目だけを`$record`へ追記します。同じIDの`Body`が前回と違う場合も停止します。初回は組み立てた`$plan`をそのまま`$record`にし、JSONへ保存する準備が整います。

**300～310行｜`WriteAllText`、`Replace`、`Move`**

初回または追記があれば、`$record`をJSONに変換して`.tmp`ファイルへ書きます。書き出し後、既存JSONならReplaceで差し替え、初回ならMoveで正式名`<Sub ID>.json`にします。これで旧設定の本文、今回の作成値、Waiver・DCR・関連付けの`Before`がローカルに残り、以降の再実行・確認・切り戻しで読み直せます。保存後にAzureへの書き込みへ進みます。

**317～321行｜`$resources = @($record.NewSettings`**

`$record.NewSettings`と`Destinations`から、Waiver→RG・保存先・保持設定→DCR・関連付けの順に`$resources`を作ります。これを1件ずつ`$resource`へ取り出し、同じループで現在値の取得・比較・書き込みを行います。新診断設定は保存先などの準備完了後に別処理するため、この一覧から除きます。

**326～344行｜`if (-not $providersReady`**

Waiverの処理後、最初の保存先に進む前に、必要なリソースプロバイダーの登録状態をAzureで読みます。Microsoft.Insightsなどが未登録なら登録APIを呼び、3秒ごとのGETでRegisteredまで待ちます。すべて確認できたら`$providersReady=true`にして、同じSubの後続項目では登録確認を省きます。

**345～366行｜`$matched = Test-Configuration`**

`$resource.Id`をGETし、`Test-Configuration`で`$resource.Body`と比べます。一致なら次へ進み、不在・不一致なら書き込みを準備します。RGは存在すればよく、Event・Syslogの総保持が既定値任せなら更新が必要です。既存Waiverが不一致なら停止します。DCR・関連付けは、現在値が保存済みの`Before`と一致するときだけ更新を許します。

**373～397行｜`if ($current -and $resource.Kind -eq 'Storage')`**

Storageが既にあれば、地域・SKU・暗号化・不変性が`Body`と合うか確認します。通信規則はGETした現在のIP規則などを本文へ引き継ぎ、既定拒否とAzureサービスの例外だけを更新します。既存Log Analyticsでは地域を確認し、現在の`features`を残してリソース権限によるログアクセスを加えます。Log Analyticsの更新は、指定項目だけを送るPATCHに切り替えます。

**398～406行｜`$_.name -notin`**

ライフサイクルは現在のルール一覧から、このスクリプトの`log-append-365`と`log-append-1095`だけを除き、新しい1,095日ルールを加えた本文にします。他名のルールは残ります。Event・Syslogが既にあれば、本文を`totalRetentionInDays=1095`だけに絞ってPATCHにし、分析用保持期間などの既存項目を引き継ぎます。

**411～435行｜`while ($true)`、`-Method $method -Body $body`**

用意した`$body`を、PUTまたはPATCHで`$resource.Id`へ送ります。DCRの`InvalidOutputTable`が指定の組み込み出力だけの反映待ちなら、10秒待って再試行します。それ以外は例外を返します。成功後は同じIDをGETし直し、JSONの`Body`と比べて一致したら次の項目へ進みます。APIが成功しただけで完了とせず、保存先・保持設定などの実際の値を確認します。

**442～456行｜`$diagnostics | ForEach-Object -Parallel`**

保存先とDCRなどの準備が終わったら、`NewSettings`から新診断設定を取り出して最大5件同時に処理します。各処理はSub ID・診断設定ID・失敗理由・期待する本文を返す`$result`を用意します。commonをCSVなしで読み、外側のSub IDと認証用トークンを受け取ってAzureへ接続します。この並列化は1Sub内の新診断設定が対象です。

**457～479行｜`return $result`**

新診断設定のIDをGETし、`Body`と一致するなら書き込まず成功結果を返します。同名でも内容が違えば失敗にし、不在ならPUTで作ってGETでログ・メトリック・送信先を照合します。例外は`$result.Reason`と`Expected`へ入れて返します。全件分を`$copied`へ集め、件数を確認してから失敗した結果だけを`$failures`へ追加します。

**481～502行｜外側の`catch`、`$failurePath = Join-Path $PSScriptRoot`**

保存先などの処理中に例外が出たSubは、対象ID・理由・本文を`$failures`へ追加し、そのSubの残りを飛ばして次へ進みます。全Subの後、失敗があれば`copy_failures.csv`へ出してエラーで終了し、なければ前回の失敗CSVを削除します。ここまで旧診断・旧DCR関連は残るので、step2で新しい送信先まで確認してからstep3で旧側を外します。

## 4. step2_verify.ps1を読む

[step2_verify.ps1](step2_verify.ps1)は、step1のJSONにあるIDと本文を使ってAzureを読み、保存先・新送信設定がそろっているか確認します。人が実行結果を確認した後、step3へ進みます。step3も冒頭で同じ確認を行い、NGなら削除を始めません。

**1～19行｜`param([switch]$PassThru)`、`Read-MigrationRecord`**

CSVのSubごとにJSONを読み、なければNGにします。続いて`Get-MigrationPlan -OnlyOldSettings`で、今も旧ワークスペース宛ての診断設定と、旧2DCRの関連を再取得します。結果の`OldSettings`を次の比較に使います。名前の空き確認・新設定のID作成・ポリシー確認は、この引数で省きます。

**20～25行｜`foreach ($current in $currentPlan.OldSettings)`**

現在の旧設定のIDでJSONの`OldSettings`を探し、本文を1件ずつ比べます。`old-setting`のログ種別が変わった、JSONにない旧設定が増えた場合はNGです。一方、Azureに既にない旧設定はこのループへ来ないため許可します。step3が途中まで削除した後でも、残りを再確認できる仕組みです。

**31～59行｜`@($record.Destinations) + @($record.NewSettings)`**

JSONの`Destinations`と`NewSettings`のIDをGETし、各`Body`と比較します。例ではStorageや新診断`setByAzurePlatformTeam`が対象です。RGは存在を、Event・Syslogは総保持1,095日がテーブル単位で明示されていることも確認します。不在・不一致ならID・理由・期待する本文をNG行へ入れ、次の対象も確認します。この本文は手動修正時に使えます。

**60～85行｜`$records += $record`、`if ($PassThru)`**

JSONの読み込みや旧設定の探索に失敗したSubは、NG行を残して次のSubへ進みます。全結果を`verify_results.csv`へ出し、NGがあれば例外で終了します。全件OKのとき、通常実行は完了を表示し、`-PassThru`付きではJSONから読んだ`$records`を返します。step3はこの中の`OldSettings`を削除対象に使います。

## 5. step3_delete.ps1を読む

[step3_delete.ps1](step3_delete.ps1)は、step2をもう一度実行してから、JSONの`OldSettings`にある旧設定を削除します。例の`old-setting`を外す工程です。削除の開始前に全Subを確認し、各設定の削除直前にも旧設定・対応する新設定の本文を確かめます。

**8～15行｜`$records = @(& (Join-Path`**

`&`でstep2を`-PassThru`付きで呼び、全件OKなら返されたJSONの内容を`$records`へ受け取ります。NGなら例外となり、削除のループへ入りません。commonをCSVなしで読み、`Kind`をAssociation→Diagnosticの順に切り替えて、全Subの旧DCR関連を先に、旧診断設定を後に処理します。

**20～27行｜`if (-not $current)`**

`OldSettings`のIDをGETし、不在なら削除済みとして次へ進みます。存在すれば`Get-WritableBody`で本文を取り出し、JSONの`Body`と完全一致するか比較します。ログ種別や参照先DCRなどが変わっていれば、step2成功後の変更として削除全体を止めます。

**32～52行｜`$newId = ''`、`if ($newId)`**

旧設定の親IDから新診断・新DCR関連のIDを求め、JSONの`NewSettings`で本文を探してAzureの現在値と比較します。例では`nsg-app`の`setByAzurePlatformTeam`です。新設定が不在・不一致なら削除全体を止めます。None・空欄は旧送信も終了する指定なので、その側の新設定の確認を省いて旧設定の削除へ進みます。

**53～71行｜`-Method Delete`、`catch`**

確認できた旧設定のIDへDELETEを送り、次へ進みます。途中で失敗すればSub ID・対象ID・理由・旧本文を`delete_failures.csv`へ出し、ほかのSubも含め残りの削除を停止します。削除済みの分は自動復元せず、再実行またはrollbackで対応します。保存先・新送信設定は残り、None・空欄の側はここで旧送信が終了します。

## 6. rollback.ps1を読む

[rollback.ps1](rollback.ps1)は、step1のJSONから旧設定の`Body`と新設定の`Before`を読み、元の送信設定へ戻します。step1の途中・終了後、step3の途中・終了後のいずれも同じスクリプトです。旧送信を全件復元してから、新しい送信設定を変更前へ戻します。

**1～19行｜`$PSBoundParameters.ContainsKey('SubscriptionIds')`**

commonを`-SkipCsv`で読み、`records/<環境>/`のJSONファイル一覧を取得します。`-SubscriptionIds`がなければ全ファイル、あればファイル名のSub IDが一致するものだけを選びます。存在しないID・重複・空の指定は停止します。対象SubはJSONから選ぶため、CSVは読みません。

**20～30行｜`$records = @(foreach ($file in $recordFiles)`**

各JSONを読み、ファイル名と`Target.SubscriptionId`が同じか確かめます。さらに`Read-MigrationRecord`へ保存済みの`Target`を渡し、`Context`が今回の環境・旧ワークスペース・新診断名などと一致するか確認します。確認した内容を`$records`へ集めます。不正なJSONや対象0件なら、Azureへの書き込み前に停止します。

**37～50行｜`$matchesBody`、`$matchesBefore`**

選んだ全Subの旧・新設定をGETし、本文がJSONの`Body`か`Before`と一致する、または不在であることを確認します。第三者が別の値へ変えていれば、書き込む前に全体を停止します。保存先はこの対象一覧に入れず、新設DCR本体・元からあるWaiverも残す指定として除外します。

**57～72行｜`foreach ($phase in @('Old', 'New'))`**

`$phase`をOld→Newの順に切り替えます。Oldでは全対象Subの旧DCR関連、次に旧診断設定を`Body`から復元します。それが全部終わってから、NewでDCR→関連付け→診断設定→Waiverを`Before`へ戻します。これにより、選んだSubすべての旧送信を戻してから新送信を外せます。

**77～88行｜`$expectedBody = $setting.Body`**

Oldでは旧設定の`Body`、Newでは新設定の`Before`を`$expectedBody`へ入れ、戻す値を決めます。同じIDをGETし直して既に一致していればスキップします。初めの確認後に別の値へ変更されていた場合も、ここで検出して上書きを止めます。

**93～114行｜`if ($null -eq $expectedBody)`**

不在の旧診断を戻す前に、親リソースの診断設定一覧を読み、上限5件に空きがあるか確認します。`$expectedBody`に値があればPUTし、nullなら今回追加した設定をDELETEします。GETし直して復元値と比較し、不一致なら停止します。例ではOldで`old-setting`を復元した後、Newで`setByAzurePlatformTeam`を削除します。

**120～135行｜`catch`、`Remove-Item $failurePath`**

失敗したらSub ID・対象ID・理由を`rollback_failures.csv`へ出して停止し、全件成功なら前回の失敗CSVを削除します。再実行では復元済みの項目を比較してスキップできます。保存先・保存済みログ、新設DCR本体、元からあるWaiverは残ります。新設Waiverは`Before=null`なので、新診断・新関連と同じく削除されます。
