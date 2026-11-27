# 実行の流れに沿ってコードを読む

[step1_copy.ps1](step1_copy.ps1)とこの資料を並べ、コードを上から読みます。変数に入る情報と、その使い道を順に説明します。関数の詳しい処理は、リンク先の`DESCRIPTION`で確認できます。

実行方法とCSVの書き方は[README](README.md)を参照してください。step1の番号付きブロックコメントは、READMEに書かれた5段階と対応しています。

## step1_copy.ps1：旧設定を残して、新しい保存先と送信設定を作る

**[1～4行](step1_copy.ps1#L1)｜`common.ps1`、`$failures = @()`**

2行目の`.`で`common.ps1`を読み込みます。[環境の指定](common.ps1#L9)と[CSVの読込み](common.ps1#L475)が実行され、移行するサブスクリプションの一覧が`$targets`に入ります。CSVの6列を検査し、サブスクリプション名からIDを調べます。ストレージ名があれば、地域略称も取得します。

失敗をためる`$failures`と、作業記録の保存フォルダも作ります。関数の中の処理は、呼び出すまで動きません。

**[10～16行](step1_copy.ps1#L10)｜`foreach ($target in $targets)`、`Read-MigrationRecord`、`Get-MigrationPlan`**

CSVの1行を`$target`へ取り出し、そのサブスクリプションの作業を始めます。

- `Read-MigrationRecord`で前回の作業記録を読み、`$record`へ入れます。初回は記録がないため`$null`です。[Read-MigrationRecordのDESCRIPTION](common.ps1#L433)
- `Get-MigrationPlan`で現在の旧設定と作成先を調べます。`$plan.OldSettings`には旧診断設定・旧DCR関連付けのIDと設定値、`Discovery`には新設定の作成先IDと地域が入ります。[Get-MigrationPlanのDESCRIPTION](common.ps1#L535)

名前確認に必要な`Microsoft.Storage`が未登録なら、この呼び出しで登録して完了を待ちます。

以降のコードで、この調査結果に「Azureへ渡す設定値」を加えます。

**[21～56行](step1_copy.ps1#L21)｜`$plan.NewSettings += @{`、`$plan.Destinations += @{`**

ポリシーの適用除外（Waiver）を`NewSettings`へ、リソースグループとLog Analyticsを`Destinations`へ追加します。各項目の`Id`は作成先、`Kind`は設定の種類、`Body`はAzureへ送る設定値です。ここでは設定値を組み立てるだけで、Azureへは書き込みません。

適用除外は3つ作ります。先頭2つはポリシー割り当て全体、3つ目は指定した12個の参照IDを除外します。Log Analyticsの保持期間は90日です。新しい送信設定を作らない指定でも、保存先は作成します。

**[60～121行](step1_copy.ps1#L60)｜`$storageIds[$storageLocation] = $storageId`、`name = 'log-append-1095'`**

`$storageIds`に、地域とストレージアカウントのIDを組にして入れます。後で診断設定を作るときに、この辞書から同じ地域の送り先を選びます。`LogDestination=Storage`なら、移行先のLog Analytics自身の送り先も必要なため、`$location`のストレージも含みます。

`$storage.SkuName`をアカウントの`sku.name`へ入れます。新設時は同じ地域のZRSを優先し、非対応ならLRSを使います。再実行では記録した冗長性を使います。

`Destinations`には、アカウント本体、Blobのバージョン管理、Defenderの無効化、ログの削除ルールを加えます。削除するのは、最終更新から1,095日を超えたappendBlobです。CSVにストレージ名がなければ、この繰り返しは実行しません。

**[125～136行](step1_copy.ps1#L125)｜`foreach ($tableName in @('Event', 'Syslog'))`、`totalRetentionInDays = 1095`**

Event・Syslogテーブルを合計1,095日保持にする値を`Destinations`へ追加します。旧DCRの関連付けがなくても、`VmLogDestination`が`None`・空欄でも用意します。作業前からあるLog Analyticsのテーブルを変更しないよう、この後の処理で作成済みテーブルを対象から外します。

**[139～197行](step1_copy.ps1#L139)｜`$dcrBody.properties.dataSources`、`foreach ($association in $plan.Discovery.Associations)`**

DCR（データ収集ルール）は、VM・VMSSから集めるログと保存先を指定します。`Discovery.Dcr`があれば、`dataSources`に収集内容、`destinations`に保存先、`dataFlows`にログと送り先の対応を書きます。WindowsイベントとSyslogの収集条件は固定値です。

旧DCRにつながっていたVM・VMSSと、新DCRとの関連付けも作り、`NewSettings`へ入れます。`VmLogDestination=Log`ならCSVのLog Analyticsへ送る設定を作ります。`None`・空欄ならDCRも新しい関連付けも作りません。

**[201～213行](step1_copy.ps1#L201)｜`$reusedParents`、`$destination.Reuse = $true`**

`Discovery.ReusedDestinations`には、作業前から存在し、IDと地域が一致する保存先が入っています。その親リソースには`Reuse=true`を付け、`Body`を地域だけにします。後の作成処理では、存在と地域を確認して書き込みを省きます。

既存ストレージの子設定と、既存Log Analyticsの作成済みEvent・Syslogテーブルは、一覧から外して変更しません。未作成のテーブルだけを残します。このスクリプトが前回作成した保存先は再利用扱いにせず、引き続き作成時の設定値で確認します。

**[218～270行](step1_copy.ps1#L218)｜`$diagnosticBody = @{`、`$storageIds[$diagnostic.Location]`**

`OldId`がある対象では、旧診断設定のログとメトリックをコピーします。移行先のLog AnalyticsとDCR自身は`OldId`が空で、`allLogs`だけを有効にする設定値を作ります。Log AnalyticsはAzureが返す無効の`audit`も指定します。DCRは`audit`に対応しないため指定しません。どちらも`AllMetrics`は無効です。

`Storage`なら同じ地域のストレージID、`Log`なら移行先のLog AnalyticsのIDを指定します。後者では、Log Analytics自身もDCR自身も新しいLog Analyticsへ送信します。旧設定からコピーする場合は格納方式も引き継ぎます。どちらも`NewSettings`へ加えるため、後の確認と切り戻しの対象になります。

`LogDestination`が`None`・空欄なら、`Discovery.Diagnostics`は空です。新しい診断設定は作りません。

**[273～297行](step1_copy.ps1#L273)｜`$setting.Before =`、`$plan.Remove('Discovery')`**

適用除外・DCR・関連付けの現在値を、切り戻し用の`Before`へ入れます。まだ存在しなければ`$null`です。再実行しても最初の値を残します。

変更前の値があれば、DCRのタグや関連付けの説明など、今回変更しない項目を新設定にも残します。作成先を決めるために使った`Discovery`は、計画から外します。

**[303～339行](step1_copy.ps1#L303)｜`$recordChanged = -not $record`、`[IO.File]::WriteAllText`**

前回の記録と、今回調べたID・設定値を比べます。記録した旧設定が消えた、または値が変わった場合は、そのサブスクリプションの作業を止めます。同じIDに作成する設定値が前回と違う場合も止め、新しく見つかったIDだけを追記します。初回は`$plan`をそのまま記録にします。

JSONを一時ファイルに書き終えてから、作業記録のファイルと置き換えます。書込みに失敗しても前回の記録を残すためです。保存後に適用除外や保存先の変更へ進みます。

**[345～368行](step1_copy.ps1#L345)｜`$resources = @($record.NewSettings`、`$providersReady`**

`$resources`へ、適用除外、保存先と保持期間、DCRと関連付けの順に設定を並べます。適用除外3件を作成・照合してから保存先へ進みます。新診断設定は、この一覧の処理後に作成します。

保存先とDCRに必要なサービスの登録状態を確認します。Storage以外の未登録サービスは、この段階で登録して完了を待ちます。`$providersReady`は、同じサブスクリプションでこの確認を繰り返さないための印です。

**[369～401行](step1_copy.ps1#L369)｜`$currentBody = Get-WritableBody`、`$matched = Test-Configuration`**

`Reuse=true`なら存在と地域だけを確認し、書き込まず次へ進みます。それ以外は、Azureの現在値を作業記録の`Body`と比べます。同じなら`continue`で次へ進みます。今回作成したリソースグループは存在を、テーブルは日数とテーブル単位での保持期間指定を確認します。

通信は[Invoke-ArmRequestのDESCRIPTION](common.ps1#L111)、Azureの応答から比較する項目を取り出す処理は[Get-WritableBodyのDESCRIPTION](common.ps1#L345)、値の比較は[Test-ConfigurationのDESCRIPTION](common.ps1#L258)を参照します。

更新が必要なら、`Body`をコピーして`$body`へ入れます。送信するコピーを加工し、作業記録の値は変えません。

**[405～441行](step1_copy.ps1#L405)｜`$body.properties.networkAcls =`、`$method = 'Patch'`**

このスクリプトが作成した保存先を再実行で補修する際は、IP・VNetの許可規則やLog Analyticsの他の`features`を残します。ストレージの冗長性が記録と違えば、変更せず停止します。ログ削除ルールは`log-append-1095`だけを入れ替え、他のルールは残します。

既存のLog Analyticsとテーブルには、変更する項目だけを送る`PATCH`を使います。保持期間の変更で、テーブルの列定義まで置き換えないためです。

**[444～468行](step1_copy.ps1#L444)｜`while ($true)`、`-Method $method -Body $body`**

設定値を`PUT`または`PATCH`で送り、Azureから読み直して作業記録の値と比べます。Event・Syslogテーブルの反映待ちでDCRを作れない場合は、10秒待って再送します。

このループが待つのは、その反映遅れだけです。他の失敗は外側の`catch`へ渡し、そのサブスクリプションの残りの処理を止めます。

**[474～512行](step1_copy.ps1#L474)｜`$diagnostics | ForEach-Object -Parallel`、`return $result`**

保存先を作成した後、新診断設定を最大5件同時に作ります。同じID・設定値なら作成を省き、設定がなければ作って読み直します。同名で値が異なる設定は変更せず、失敗として扱います。

並列処理へは共通ファイルと認証情報を渡します。結果を`$copied`へ集め、失敗したID・理由・作成したい設定値を`$failures`へ加えます。

**[514～536行](step1_copy.ps1#L514)｜`$failurePath = Join-Path $PSScriptRoot`、`Export-Csv`**

調査や記録の保存で止まった理由も`$failures`へ加えます。失敗があれば`copy_failures.csv`へ出してエラーで終了し、すべて成功すれば前回の失敗CSVを削除します。

このスクリプトでは旧診断設定と旧DCR関連付けを削除しません。次のstep2で、新しい設定が作業記録どおりかを確認します。

## step2_verify.ps1：作業記録どおりに設定できたか確かめる

**[1～19行](step2_verify.ps1#L1)｜`Read-MigrationRecord`、`-OnlyOldSettings`**

`common.ps1`を読み、CSVの各サブスクリプションの作業記録を取得します。記録がなければNGです。続いて現在の旧診断設定・旧DCR関連付けを調べ、`$currentPlan`へ入れます。

`-OnlyOldSettings`は、作成前の検査や利用登録をせず、旧設定だけを調べる指定です。[Get-MigrationPlanのDESCRIPTION](common.ps1#L535)

**[24～29行](step2_verify.ps1#L24)｜`foreach ($current in $currentPlan.OldSettings)`**

現在の旧設定を、作業記録のID・設定値と比べます。記録にない設定や、値が変わった設定があればNGです。削除後の再実行にも使うため、旧設定が消えているだけではNGにしません。

**[34～64行](step2_verify.ps1#L34)｜`@($record.Destinations) + @($record.NewSettings)`**

作業記録にある保存先と新設定をAzureから取得し、`Body`と比べます。再利用する保存先の`Body`は地域だけなので、既存の保持期間やセキュリティ設定は比較しません。結果は`$results`へ入れ、NGがあっても残りを確認します。NGの結果には、手動で設定するときに使う作成値も残します。

**[65～90行](step2_verify.ps1#L65)｜`$records += $record`、`if ($PassThru)`**

すべての結果を`verify_results.csv`へ出し、NGがあればエラーで終了します。`-PassThru`を付けた場合は、全件OKのときだけ作業記録を返します。step3はこの記録を受け取って削除します。step2はAzureの設定を変更しません。

## step3_delete.ps1：旧診断設定と旧DCR関連付けを削除する

**[7～22行](step3_delete.ps1#L7)｜`$records = @(& (Join-Path`、`-PassThru`**

step2が全件OKの場合だけ、作業記録を`$records`へ受け取って削除へ進みます。削除側でも`common.ps1`から設定値と関数を読み、`-SkipCsv`でCSVの再読込みは省きます。

外側の`$kind`が削除順を決めています。全サブスクリプションの旧DCR関連付けを削除した後で、全サブスクリプションの旧診断設定を削除します。

**[25～55行](step3_delete.ps1#L25)｜`$current = Invoke-ArmRequest`、`$newId = ''`**

削除直前に旧設定を読み直し、作業記録と値が違えば停止します。送信を続ける指定なら、旧設定が付いているリソースのIDから新設定のIDを作り、その設定値も確認します。

`None`・空欄は送信を終了する指定です。新設定の存在は確認せず、旧設定を削除します。

**[56～78行](step3_delete.ps1#L56)｜`-Method Delete`、`catch`**

旧設定を`DELETE`します。失敗した場合はID・理由・元の設定値を`delete_failures.csv`へ出し、そのサブスクリプションの残りの削除を止めます。他のサブスクリプションは順次処理を続け、全対象の処理後にエラーで終了します。保存先・保存済みログ・新設定・適用除外は残します。全件の削除に成功した場合は、前回の失敗CSVを削除します。

## 必要時：rollback.ps1で切り戻す

**[1～31行](rollback.ps1#L1)｜`$PSBoundParameters.ContainsKey`、`Read-MigrationRecord`**

`records/<環境>/`のJSONから、切り戻すサブスクリプションを選びます。`-SubscriptionIds`を省略すると全件、指定するとそのIDの記録だけを使います。CSVは読みません。[Read-MigrationRecordのDESCRIPTION](common.ps1#L433)

**[40～53行](rollback.ps1#L40)｜`$matchesBody`、`$matchesBefore`**

旧設定の`Body`は削除前の値です。新設定では、`Body`が今回の作成値、`Before`が作業開始前の値です。現在値が`Body`・`Before`のどちらとも違えば、復元前に止めます。設定が消えている場合は、後で作り直せるため許可します。

今回作成したDCR本体と、元からあった適用除外は切り戻しでも残すため、この比較から外します。サービスの利用登録も解除しません。

**[59～128行](rollback.ps1#L59)｜`foreach ($phase in @('Old', 'New'))`、`$expectedBody = $setting.Body`**

`$phase`はOld→Newの順です。全対象の旧診断設定・旧DCR関連付けを`Body`で復元してから、新設定を`Before`へ戻します。失敗したSubは`$failedSubscriptions`へ入れて残りを止め、ほかのSubは続けます。旧設定の復元で失敗したSubは、新設定の削除へ進みません。

すでに戻っている設定は変更しません。戻す値があれば`PUT`し、元は設定がなかった場合は`DELETE`します。今回作成したDCR本体、元からある適用除外、保存先は残します。

**[130～146行](rollback.ps1#L130)｜`catch`、`Remove-Item $failurePath`**

書き込み前の全件確認で失敗した場合は、そのIDと理由を`rollback_failures.csv`へ出して全体を止めます。作業中の失敗はSubごとに集め、ほかのSubの処理を終えてから同じCSVへまとめ、エラーを返します。同じ記録でもう一度実行すると、すでに戻っている設定は変更せず、残りを戻せます。すべて成功した場合は、前回の失敗CSVを削除します。

## 任意：precheck.ps1で事前確認する

**[1～17行](precheck.ps1#L1)｜`Get-MigrationPlan -Target $target`**

CSVに書いたサブスクリプションごとに、旧設定と新設定の作成先を調べます。名前確認に必要な`Microsoft.Storage`が未登録なら登録して待ちます。既存の保存先は地域が一致すれば利用できます。ただし作業記録を渡さないため、同名の新診断設定があれば、今回作成したものでもNGにします。作業の再開にはstep1を使います。[Get-MigrationPlanのDESCRIPTION](common.ps1#L535)

**[19～34行](precheck.ps1#L19)｜`catch`、`$results | Export-Csv`**

調べられなかったサブスクリプションも理由付きでNGにし、`precheck_results.csv`へ出します。NGでも利用登録は解除しません。保存先・送信設定の作成や作業記録の保存はせず、step1は実行時点のAzureを調べ直します。step2・step3・rollbackでは利用登録を行いません。

## 補足：関数の説明とPowerShellの読み方

リポジトリのルートから次を実行すると、関数の説明を表示できます。`-SkipCsv`でCSVやAzureの一覧取得を省き、設定値と関数だけを読み込みます。関数名を変えると、他の関数の説明も表示できます。

```powershell
. .\migration\common.ps1 -SkipCsv
(Get-Help Get-MigrationPlan -Full).Description.Text
```

コードで迷ったときは、次の表を参照してください。

|書き方|読み方|
|---|---|
|`$target`・`$target.SubscriptionId`|変数と、その中の項目。`=`は右の値を左の変数へ入れる|
|`@()`・`@{}`|値を並べた配列・項目名と値を組にした辞書|
|`+=`|今ある一覧へ追加する|
|`foreach`・`if`・`else`|1件ずつ繰り返す・条件を満たすときの処理・満たさないときの処理|
|`continue`・`break`|今の1件を終えて次へ進む・繰り返し全体から抜ける|
|`-eq`・`-ne`・`-in`・`-notin`|等しい・異なる・一覧に含まれる・含まれない|
|`-and`・`-or`・`-not`|両方満たす・どちらか満たす・条件を反転|
|`$null`・`??`|値がない状態・左が`$null`なら右の値を使う。CSVの文字列`None`とは別|
|`\|`・`$_`|左の結果を右へ渡す・処理中の1件|
|先頭の`.`・`&`|別ファイルの変数・関数を今の場所で使えるようにする・別スクリプトを実行する|
|`$using:`|並列処理へ外側の値を渡す|
|`[型]::名前`|その型に用意されている値や処理を使う|
|`try`・`catch`・`throw`|実行する処理・失敗したときの処理・エラーとして処理を止める|

`param(...)`は、受け取る引数を宣言する部分です。`[switch]`は、`-PassThru`のように付けたときに有効になる引数です。二重引用符の中では変数の値が文字列に入ります。変数内の項目を使うときは、`$($target.SubscriptionId)`のように囲みます。
