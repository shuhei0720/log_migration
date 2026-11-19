# 正本のコードを上から読むための学習資料

各ファイルを開き、**指定行のコード→その直下の説明**の順で読んでください。行位置が変わった場合は、併記した式を検索できます。実行手順は[README](README.md)にあります。

Sub＝サブスクリプション、RG＝リソースグループ、DCR＝データ収集ルールです。`@{}`は項目名と値をまとめる辞書、`@()`は一覧です。`$x.Id`は変数`$x`のId項目を取り出し、`+=`は一覧へ追加します。`-eq`は等しい、`-ne`は等しくない、`$null`は値がない状態です。

説明中は、CSVの1行が `ResourceGroup=rg-log`、`StorageAccount=stjpearchive001`、`WorkspaceName=log-app`、`LogDestination=Storage`、`VmLogDestination=Log`の場合を追います。このSubに東日本の`nsg-app`の旧診断`old-setting`と、`vm-app`の旧DCR関連がある例を使います。

## 1. common.ps1を読む

[common.ps1](common.ps1)を上から読みます。`function ... {}`は処理の定義で、中身が動くのはその関数を呼んだときです。

### 1～95行：以降の処理で使う値を用意する

**1～28行｜`param([switch]$SkipCsv)`、`$apiVersions = @{`**

`#Requires`は必要なPowerShellの版、`SkipCsv`は付けると有効になる引数です。移行元ワークスペースと環境、新診断名、東日本、並列数5を変数に入れます。API版の辞書は、`Kind='Storage'`などの分類からAPI版を選ぶために使います。

**34～85行｜`$settings = $environmentSettings[$environment]`**

環境別の辞書から今回の1環境を取り出します。続く`foreach`は旧DCR名2つを完全なリソースIDへ変換します。`for`は`$index=0,1,2`で3割り当てを組み立て、3件目だけに12個の参照IDを付けます。最初の2件は参照IDの空配列で、割り当て全体を除外する指定です。

**86～95行｜`$migrationContext = @{`**

環境・移行元・旧DCR・新診断名をまとめます。記録を読む際に同じ組合せか確認します。記録先は`records/dev`などです。`ErrorActionPreference='Stop'`はPowerShellの処理エラーをcatchで扱えるようにし、続く設定は日本語を含む入出力の文字コードをそろえます。

### 103～168行：Invoke-ArmRequestの中を読む

Azureへの操作を行い、応答JSONを辞書にして呼出し元へ返す関数です。

**104～115行｜`if ($Resource)`、`$uri = $ResourceId`**

`-Resource`で記録の1項目を渡された場合は、そのIdとAPI版を取り出します。`??`は左がnullなら右を採用する書き方です。PUTなどで本文の明示指定がなければ、その項目の`Body`を使います。短いリソースIDにはARMのURLと`api-version`を付け、既に完全なURLならそのまま使います。

**116～125行｜`for ($attempt = 0; $attempt -lt 4; $attempt++)`**

通常は初回を含め最大4試行（再試行3回）に区切ります。認証情報がない・対象Subが変わった・有効期限が5分以内の場合だけAzure CLIでトークンを取得します。`$script:...`はスクリプト内で次の呼出しにも使う変数です。取得できなければここで停止します。

**126～148行｜`$request = @{`、`Invoke-WebRequest @request`**

URL・HTTP操作・認証ヘッダーなどを辞書へ入れます。`@request`は辞書の各項目を引数として渡す書き方です。本文がある場合はJSONへ変換して送ります。成功時は応答を返します。`-Wait`付きでまだCreatingなどなら、5分の期限を確認し、3秒待ち、`$attempt = -1`で試行数を戻してGETを続けます。

**150～167行｜`if ($status -eq 404 -and $Optional)`**

`-Optional`付きの404は「存在しない」としてnullを返します。401はトークンを捨てて取得し直し、429などの一時エラーは待って再試行します。それ以外、または試行を使い切った失敗は`throw`で呼出し元へ伝えます。

### 175～229行：Test-Configurationの中を読む

現在値`Actual`と期待値`Expected`を比べ、true/falseを返します。

**177～195行｜`if ($Kind -in @('Diagnostic', 'Dcr', 'Association'))`**

未完了のリソースはfalseです。送信設定は次の`Get-WritableBody`で比較用の形へそろえ、厳密比較にします。`-Exact`はActual→ExpectedとExpected→Actualの両方向で再帰的に比較します。Lifecycleでは旧365日ルールの残存をNGにし、自分の1,095日ルールを取り出して比較します。

**197～215行｜`if ($Expected -is [array])`**

期待値が配列なら、現在値を`$remaining`という残り一覧へ入れます。件数が違えばfalse。期待する1件ごとに一致相手を探し、見つけたら`RemoveAt`で取り除きます。同じ相手を2回使わず、順不同でも重複数を確認します。見つからない件があればfalseです。

**217～228行｜`foreach ($key in $Expected.Keys)`**

nullは両方nullの場合だけ一致です。辞書なら期待値の各キーを取り出し、中の値もこの関数自身で比較します。これが「再帰」です。通常は必要な項目だけを調べるので、Actualが`@{A=1; B=2}`、Expectedが`@{A=1}`ならtrueです。`-Exact`なら逆向き比較でBの不足を検出しfalseになります。単純な値まで来たら`-eq`で比べます。

### 236～290行：Get-WritableBodyの中を読む

**237～260行｜`$body = @{ properties = @{} }`**

元のリソースがなければnull、作成途中ならエラーです。空の本文を作り、必要なpropertiesを移します。診断設定ならlogs・metrics・各送信先、関連付けならDCR/DCEのIDなどに絞ります。GET専用のprovisioningStateなどは書戻し本文へ入れません。DCRはコピーを作ってから加工し、取得した原本を変えないようにします。

**261～289行｜`$body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'`**

Log Analytics宛てで格納方式が省略されていたら、既定のAzureDiagnosticsを明示して比較時の表現をそろえます。DCRではlocation・tags・identityも引き継ぎますが、自動計算されたworkspaceIdやprincipalIdなどは除きます。最後の`return $body`で、保存・比較・復元に使える本文が呼出し元へ戻ります。

### 297～314行：Read-MigrationRecordの中を読む

**299～306行｜`$path = Join-Path $recordDirectory`**

対象Sub IDからJSONの場所を作ります。ファイルがなければ初回なのでnullを返します。あればJSONを辞書へ戻し、ContextとCSV由来のTargetが今回と同じか厳密比較します。違う場合は、別の移行の記録を使わないよう停止します。

**308～313行｜`foreach ($name in @('Destinations', 'NewSettings', 'OldSettings'))`**

3つの一覧が配列になっているか確認し、記録全体を返します。

### 320～367行：CSVを1行ずつ対象データへ変換する

**320～335行｜`if (-not $SkipCsv)`、`foreach ($row in Import-Csv`**

`$targets`は対象一覧、`$target`は現在の1行です。Sub一覧をCLIで取得し、CSV各行の文字列から前後の空白をTrimで除いて辞書へ移します。VM列がない旧CSVだけ既定のLogになります。列が存在して空欄なら、空欄のまま保持します。

**336～349行｜`$target.LogDestination -notin`**

診断側はStorage/Log/None/空欄、VM側はLog/None/空欄だけを許します。次に必須値とStorage名を確認します。`-cnotmatch`は大文字小文字も区別するパターン比較です。名前は小文字英数字3～24文字、`jpe`が1か所という条件です。

**350～359行｜`$matches = @($accounts | Where-Object`**

Sub名またはIDに一致する候補を選び、ちょうど1件か確認します。例の行にはここで`SubscriptionId`と、`rg-log`配下の`log-app`を指す`WorkspaceId`が追加されます。移行元と同じ保存先は拒否し、完成した1行を`$targets`へ追加します。

**361～366行｜`Group-Object`、`$regionNames = Invoke-RestMethod`**

CSVが空、または同じSubが複数行なら停止します。Storage名を指定した行があれば、MicrosoftのAzure Naming Toolの地域略称一覧を取得します。後で`jpe`を各地域のshortNameへ置き換えるためのデータです。

### 374～619行：Get-MigrationPlanの中を読む

**375～385行｜`$plan = @{`**

入力はCSVの1行`Target`、保存済みの`Record`、旧設定だけを調べる`OnlyOldSettings`です。ContextとTargetを入れ、Destinations・NewSettings・OldSettingsを空の一覧で始めます。調査結果を足して返します。

**390～417行｜`while ($resourcePage)`**

リソース一覧を1ページずつ取得します。`$resourceLocations[リソースID]=地域`の辞書に入れ、Storageなら種類に応じたBlob/File/Queue/Tableの子IDも追加します。`$page.nextLink`があれば次ページへ進み、なくなったらwhileを抜けます。

**418～437行｜`$resourceLocations.Keys | ForEach-Object -Parallel`**

辞書のIDを最大5件ずつ調べます。`$_`は現在のリソースID、`$using:...`は外側から渡す値です。各処理の中でもcommonを読みますが、`-SkipCsv`でCSVの再読込みを省きます。全診断をSettingsへ、そのうち移行元ワークスペース宛てだけをSourcesへ入れ、1リソース分のresultを返します。

**438～458行｜`$diagnosticSources = @($listedSettings`**

結果件数の不足と調査失敗を先に確認します。診断非対応を表すResourceTypeNotSupported以外の失敗は停止します。Sourcesのあるリソースだけを選び、旧診断のId・Kind・BodyをOldSettingsへ追加します。例の`old-setting`の設定値がここに入り、地域が空/globalなら東日本にそろえます。

**464～490行｜`foreach ($oldDcrId in $oldDcrIds)`**

旧DCR2つの関連一覧をページごとに読みます。このSub以外の関連は`continue`で飛ばし、このSubのものは本体も取得して参照先が同じか確認します。例の`vm-app`の旧関連をKind=AssociationでOldSettingsへ足します。`OnlyOldSettings`付きなら、ここでplanを返して後半へ進みません。

**496～528行｜`atScope()`**

このSubへ適用される割り当てを集め、指定3件が含まれるか確認します。3件目のイニシアティブ定義を取得し、12参照IDが実際にあるか確認します。同じ定義は変数に保持して再取得を省きます。その後、作成先のID・地域などを入れるDiscoveryを空で作ります。

**533～551行｜`$storageLocations = @($diagnosticSources.Location`**

Storage名がある場合、旧診断対象の地域を重複なしで取り出します。対象がなければ東日本1つです。地域のshortNameで名前の`jpe`だけを置き換え、変換後の長さとZRS対応も確認します。例では東日本の`stjpearchive001`、西日本の対象もあれば`stjpwarchive001`を予定します。

**552～567行｜`if ($storageId -notin @($Record.Destinations.Id))`**

自分の記録にないStorageは、Azure全体の名前の空きを確認し、使用済みなら停止します。途中停止後の再実行では、記録に載っているIDだけこの初回チェックを省きます。Id・Name・LocationをDiscovery.Storagesへ追加します。

**573～592行｜`$Target.VmLogDestination -eq 'Log'`**

旧関連があり、VM送信を続ける場合だけ新DCRと新関連のIDを用意します。`-replace '^log', 'dcr'`で例のlog-appはdcr-appになります。旧関連IDからVM/VMSS IDを取り出し、重複を除いて親ごとに新関連を予定します。

**593～619行｜`if ($Target.LogDestination -in @('Storage', 'Log'))`**

診断送信を続ける場合だけ新診断のIDを用意します。対象旧診断が1リソースに複数ある場合、新旧同名、記録のない同名新設定、5枠満杯を拒否します。診断のId・対応するOldId・地域をDiscovery.Diagnosticsへ追加します。None/空欄ならこの一覧は空です。Discovery付きplanを返し、呼出し元へ戻ります。

## 2. precheck.ps1を読む

[precheck.ps1](precheck.ps1)は任意の確認用入口です。

**1～16行｜`. (Join-Path $PSScriptRoot 'common.ps1')`、`$results = foreach ($target in $targets)`**

ドットでcommonを読み込み、その変数と関数を使えるようにします。foreachでCSVの1行ずつGet-MigrationPlanへ渡し、成功すればOKのデータを1つ返します。planの戻り値は`$null =`で捨てます。

**18～29行｜`catch`、`$results | Export-Csv`**

失敗したSubはcatchでNGと理由を返し、次のSubへ進みます。foreachの全結果がresultsに入ります。それをCSVへ保存し、NGが1件でもあれば最後にエラーにします。設定変更と変更前記録の保存は行いません。

## 3. step1_copy.ps1を読む

[step1_copy.ps1](step1_copy.ps1)では、**10行目のforeachの中が1つのSub分**です。前半はデータの組立と記録、後半でAzureへ設定します。

**1～16行｜`$record = Read-MigrationRecord -Target $target`、`$plan = Get-MigrationPlan -Target $target -Record $record`**

commonを読み、失敗一覧と記録フォルダを用意します。例のCSV行をtargetとして取り出し、初回はrecord=null、planには調査した旧診断と旧関連が入ります。precheckとは独立して現在のAzureを調べます。

**20～37行｜`$plan.NewSettings += @{`**

割り当て3件を1件ずつ取り出し、Sub配下のWaiver IDと設定値を作ります。`($assignment.Id -split '/')[-1]`はIDを区切った最後の名前です。3つとも期限なしで、1・2件目は全体、3件目は指定参照だけを除外します。ここでは一覧を組み立てています。

**38～55行｜`$plan.Destinations += @{`**

保存先RGとLog Analyticsの2項目を追加します。例ではrg-logとlog-appです。各項目はId＝操作先、Kind＝用途、Body＝設定本文を持ちます。ワークスペースの保持365日とEvent/Syslogの総保持1,095日は別の設定で、テーブル側は後で足します。

**60～86行｜`$storageIds[$storageLocation] = $storageId`**

Discovery.Storagesを1地域ずつ読み、地域→Storage IDの対応を残します。後で診断送信先を選ぶためです。同時にStorage本体の構成をDestinationsへ追加します。ZRS、二重暗号化、不変性、HTTPS/TLS、共有キー無効、通信既定拒否などの設定値がBodyに入ります。

**87～121行｜`Kind = 'Blob'`、`'Lifecycle'`、`'Defender'`**

同じStorage IDの下へ、Blobのバージョン管理、appendBlobを1,095日で削除するルールを追加します。DefenderはこのStorageで無効にし、Subの既定設定よりこちらの指定を優先します。地域ごとに4項目を組み立てます。Storage名が未指定ならこのforeachは0回です。

**127～141行｜`if ($oldAssociations.Count -gt 0)`**

OldSettingsから旧DCR関連だけを選びます。1件以上あればlog-appのEvent/Syslogテーブルを予定し、totalRetentionInDays=1095を入れます。この条件にVM送信先フラグはないため、VMの新送信を省略しても、旧関連があればテーブルは準備します。

**142～189行｜`if ($plan.Discovery.Dcr)`、`$dcrBody.properties.dataSources = @{`**

新DCRを作る予定がある場合だけ進みます。dataSourcesにはWindowsイベントのXPathとSyslogのfacility・severityを、destinationsにはlog-appを入れます。dataFlowsのnew-workspaceは、直前のdestinationsで付けた名前を参照しています。Kind=DcrでNewSettingsへ追加します。

**190～199行｜`foreach ($association in $plan.Discovery.Associations)`**

例のvm-appなど、旧関連があった親の新関連を作ります。Bodyは`dataCollectionRuleId = $dcrId`です。VMそのものを作る処理ではありません。VMフラグがNone/空欄ならDiscovery.Dcrがないため、DCRとこの関連の両方を予定しません。

**204～226行｜`$original = @($plan.OldSettings`**

予定した新診断ごとに、対応する旧診断のBodyを探します。例ではold-settingのlogs/metricsを引き継ぎ、東日本用Storage IDをstorageAccountIdへ入れます。Log宛てならworkspaceIdと格納方式を入れます。新診断のBefore=nullは「元からなかった」ことを表します。診断フラグがNone/空欄ならこのループは0回です。

**231～241行｜`$setting.Before = $saved[0].Before`**

新診断以外について変更前を取得します。保存済みの同じIdがあれば、今回の現在値ではなく最初のBeforeを再利用します。初回ならGETして本文を取り出し、不在ならnullです。新規DCRだけKeepOnRollback=trueを付け、本体を切り戻し時に残す印にします。

**242～253行｜`$body.properties[$property] = $setting.Body.properties[$property]`**

元からあったDCR・関連は、Beforeの本文を土台に今回変えるpropertiesを上書きします。それ以外の項目を落とさないためです。新しい本文をsetting.Bodyへ戻し、組立用だけのDiscoveryをplanから除きます。

**255～278行｜`if ($record)`、`foreach ($collection in`**

初回は`$record = $plan`です。再実行なら、保存した旧設定が今回も同じ内容で見つかるか先に照合します。次に3一覧をIdで突き合わせ、新しく見つかった項目だけ追記します。同じIdの予定Bodyが変われば停止し、最初の変更前情報を保持します。

**279～289行｜`WriteAllText`、`Replace`、`Move`**

記録に変更があればJSONを`.tmp`へ書き、既存記録はReplace、初回はMoveで正式名にします。この保存が済んでからAzureの設定へ進みます。ここまでで、例の旧old-settingのBody、新storage-archiveのBodyとBefore=null、保存先の構成が1つのrecordにそろいました。

**295～299行｜`$resources = @($record.NewSettings`**

実際に設定する一覧を、Waiver→Destinations→DCR・関連の順に連結します。診断設定はここには入れず後回しです。resourceは一覧の現在の1項目です。

**300～322行｜`if (-not $providersReady`**

Waiverの後、最初の保存先へ進む際に必要なプロバイダーの登録状態を確認します。未登録なら登録し、3秒ずつ待って完了を確認します。providersReady=trueにした後は、同じSubの後続項目で繰り返しません。

**323～348行｜`$matched = Test-Configuration`**

GETしたcurrentと記録のBodyを比べ、一致ならcontinueで次へ進みます。RGは存在を確認し、テーブルは総保持が既定値任せなら不一致にします。異なる既存Waiverは上書きしません。DCR・関連も記録したBeforeと違えば停止します。更新してよい場合にだけBodyのコピーを作ります。

**350～374行｜`if ($current -and $resource.Kind -eq 'Storage')`**

既存Storageは地域・SKU・暗号化・不変性が予定と同じか確認します。通信規則全体は現在値を引き継ぎ、今回指定するdefaultAction/bypassだけを変えます。既存Log Analyticsもfeaturesを引き継ぎ、必要項目を追加してPATCHに切り替えます。`?? @{}`はfeaturesがなければ空辞書を使う指定です。

**375～383行｜`$_.name -notin`**

Lifecycleでは他名のルールを残し、自分の旧365日・現1,095日ルールだけを新しい1,095日ルールに置き換えます。既存テーブルは総保持だけのPATCHにし、分析保持期間などを送信本文へ混ぜません。

**387～407行｜`while ($true)`、`-Method $method -Body $body`**

ここで初めて各項目の本文を書き込みます。成功すればbreakでループを抜けます。DCRのInvalidOutputTableだけは、テーブル反映待ちとして期限内で10秒後に再試行します。他の失敗は上へ伝えます。書込み後はGETし直して、期待する設定になったことを確認します。

**413～427行｜`$diagnostics | ForEach-Object -Parallel`**

準備済みのSubで、新診断を最大5件ずつ並列処理します。各処理のresultにはSub ID・対象ID・空のReason/Expectedを用意します。commonをCSVなしで読み、外側のSub IDとトークンを受け取ります。

**428～450行｜`return $result`**

既に予定どおりなら成功結果を返し、この1件を終えます。異なる同名設定があれば上書きせず失敗です。不在ならPUT→GET→比較します。catchはReasonと期待Bodyをresultへ入れます。全結果がcopiedへ戻ったら件数を確認し、Reasonのある件をfailuresへ足します。

**452～469行｜外側の`catch`、`$failurePath = Join-Path $PSScriptRoot`**

保存先準備などで失敗したSubもfailuresへ追加し、そのSubの残りを飛ばして次のSubへ進みます。全Sub終了後、失敗があればCSVを出してエラーにします。成功なら前回の失敗CSVを消します。どの経路でも旧設定を削除する処理はありません。

## 4. step2_verify.ps1を読む

[step2_verify.ps1](step2_verify.ps1)は、保存した記録と実際のAzureを照合します。

**1～18行｜`param([switch]$PassThru)`、`Read-MigrationRecord`**

commonを読んでresults/recordsを空で始めます。各Subの記録を読み、記録がなければ失敗です。Get-MigrationPlanをOnlyOldSettings付きで呼び、名前の空き確認や保存先の計画を繰り返さず、現在の旧設定を調べます。

**19～24行｜`foreach ($current in $currentPlan.OldSettings)`**

今見つかった旧設定ごとに、記録の同じIdを探します。記録にない追加対象やBodyの変更があれば失敗です。記録側の旧設定を全件必須にするループではないため、既に削除された旧設定はここで失敗にしません。削除の再実行にも使う確認だからです。

**25～53行｜`@($record.Destinations) + @($record.NewSettings)`**

保存先と新設定を全件GETし、記録Bodyと比較します。存在しない・違う・テーブル総保持が既定のままならNGです。内側のcatchで失敗をresultsへ残し、他の対象も調べます。Expected欄には手動確認に使う期待Bodyを入れます。

**54～75行｜`$records += $record`、`if ($PassThru)`**

外側のcatchはSub単位の調査失敗をNGとして追加します。全結果をCSVへ出し、NGが1つでもあればthrowします。全部成功し、PassThru付きなら確認済みrecordsを返します。省略時は完了メッセージです。

## 5. step3_delete.ps1を読む

[step3_delete.ps1](step3_delete.ps1)は先頭の確認が成功してから削除へ進みます。

**7～14行｜`$records = @(& (Join-Path`**

`&`で確認版を実行し、成功した記録を受け取ります。確認版がthrowすると、この行で止まり削除へ進みません。次にcommonをCSVなしで読み、外側ループのkindをAssociation→Diagnosticの順にします。全Subの旧関連を処理した後、全Subの旧診断へ進む順序です。

**15～22行｜`if (-not $current)`**

旧設定をGETし、既に消えていればスキップします。残っていれば本文を取り出し、記録した旧Bodyと厳密比較します。確認版の後に誰かが変えた場合も、削除直前に停止できます。

**23～43行｜`$newId = ''`、`if ($newId)`**

送信を続ける指定なら、同じ親の新診断または新DCR関連のIDを組み立てます。例ではnsg-appのstorage-archiveです。記録と実際の新設定が一致するか再確認します。None/空欄の側はnewIdが空のため、新送信の存在を要求せず次へ進みます。

**44～58行｜`-Method Delete`、`catch`**

条件を満たした旧設定だけをDELETEします。途中の失敗は対象・理由・期待旧BodyをCSVへ出して停止します。保存先と新設定は残します。None/空欄の側は、新送信を作っていない状態で旧設定を外すので、ここで送信終了になります。

## 6. rollback.ps1を読む

[rollback.ps1](rollback.ps1)は、記録を使って元の送信設定へ戻します。

**1～17行｜`$PSBoundParameters.ContainsKey('SubscriptionIds')`**

引数を省略した場合と、空の一覧を明示した場合を分けます。CSVは読まず、記録フォルダのJSON一覧を取得します。Sub指定があれば存在・重複・空指定を調べ、指定した記録へ絞ります。省略なら全記録が対象です。

**18～28行｜`$records = @(foreach ($file in $recordFiles)`**

各JSONを読み、ファイル名のSub IDと中のTargetが同じか確認します。さらにRead-MigrationRecordで環境なども照合します。対象が0件なら停止します。

**34～47行｜`$matchesBody`、`$matchesBefore`**

旧・新設定の現在値を先に全件調べます。BodyまたはBeforeと一致するか、既に不在かを確認し、未知の変更があれば書込み前に止めます。KeepOnRollback付きの新規DCR本体と、Beforeのある元からのWaiverは残します。

**53～68行｜`foreach ($phase in @('Old', 'New'))`**

Old段階では旧関連→旧診断を、選択した全Subで処理します。それが全部済んでからNew段階へ進み、DCR→関連→診断→Waiverの順で処理します。kindとrecordのループをこの順に重ねることで、Sub Aだけ旧を戻してすぐ新を消す流れにはなりません。

**69～80行｜`$expectedBody = $setting.Body`**

Old段階の復元先は保存した旧Body、New段階は変更前のBeforeです。現在値が既に復元先ならスキップします。復元直前にも現在値を照合し、事前確認の後で変わった設定を上書きしないようにします。

**81～98行｜`if ($null -eq $expectedBody)`**

診断を新たに戻す場合は、5枠制限も確認します。復元先がnullなら今回追加した設定なのでDELETE、それ以外は保存本文をPUTします。その後GETで一致を確認します。例のold-settingは旧Bodyで復元し、その全件確認後にBefore=nullのstorage-archiveを削除します。

**104～115行｜`catch`、`Remove-Item $failurePath`**

失敗はCSVへ出して停止し、全件成功時だけ前回の失敗CSVを消します。Destinationsは復元ループに含まれないため保存先と保存済みログが残り、新規DCR本体もKeepOnRollbackで残ります。今回新設したWaiverはBefore=nullなので解除し、元からあったWaiverは保持します。
