# 実行の流れに沿ってコードを読む

まず[step1_copy.ps1](step1_copy.ps1)を開き、示した行のコードと解説を交互に読みます。関数を呼ぶ箇所では、必要に応じてリンク先の`DESCRIPTION`を参照してください。実行方法・CSVの書き方は[README](README.md)にあります。

## step1_copy.ps1：旧設定を残して、新しい送信先を準備する

**[1～4行](step1_copy.ps1#L1)｜`common.ps1`、`$failures = @()`**

2行目のドットで`common.ps1`を読み込み、設定値・共通関数・対象一覧`$targets`を使えるようにします。このとき[環境設定](common.ps1#L9)を組み立て、[CSV読込](common.ps1#L470)で6列を検査し、Sub名からIDを調べます。Storage名があれば地域略称も取得します。

続いて失敗一覧`$failures`を空にし、作業記録を保存するローカルフォルダを用意します。関数の本文は、後で呼び出したときに動きます。

**[10～16行](step1_copy.ps1#L10)｜`foreach ($target in $targets)`、`Read-MigrationRecord`、`Get-MigrationPlan`**

CSVの1行を`$target`として取り出し、そのSub（サブスクリプション）の処理を始めます。

- `Read-MigrationRecord`から、前回の作業記録を`$record`へ受け取ります。初回は`$null`です。[Read-MigrationRecordのDESCRIPTION](common.ps1#L431)。
- `Get-MigrationPlan`から、今回の計画を`$plan`へ受け取ります。取得済みの旧設定は`OldSettings`、本文の組立てに使うID・地域は`Discovery`に入ります。[Get-MigrationPlanのDESCRIPTION](common.ps1#L528)。

ここから下で、`$plan`へ作成する設定の本文を加えていきます。

**[21～56行](step1_copy.ps1#L21)｜`$plan.NewSettings += @{`、`$plan.Destinations += @{`**

ポリシー適用除外（Waiver）を`NewSettings`、RG（リソースグループ）とLog Analyticsを`Destinations`へ追加します。1項目の`Id`は操作先、`Kind`は種類、`Body`は作成したい設定です。ここでは一覧を組み立てるだけで、まだAzureへ書き込みません。

Waiverは3割り当て分で、最初の2件は空の参照ID配列で全体除外、3件目は12参照IDを指定します。Log Analytics全体の保持は90日です。新送信設定を作らない指定でも、保存先は用意します。

**[62～123行](step1_copy.ps1#L62)｜`$storageIds[$storageLocation] = $storageId`、`name = 'log-append-1095'`**

地域別StorageのIDを`$storageIds[地域]`へ入れます。後の診断設定が、リソースと同じ地域のStorageを選ぶための対応表です。

Storage本体・Blob設定・ライフサイクル・Defender設定を`Destinations`へ加えます。ライフサイクルは、最終更新から1,095日を超えたappendBlobを削除する設定です。公開ネットワークは`Disabled`で、通信規則は既定拒否・`AzureServices`例外です。CSVにStorage名がなければ、このループは0件になります。

**[129～143行](step1_copy.ps1#L129)｜`$oldAssociations.Count -gt 0`、`totalRetentionInDays = 1095`**

旧DCRの関連があれば、Event・Syslogテーブルの設定も`Destinations`へ追加します。テーブルの合計保持を1,095日にする本文で、ワークスペース全体の90日とは別の設定です。VM側が`None`・空欄でも準備します。

**[148～206行](step1_copy.ps1#L148)｜`$dcrBody.properties.dataSources`、`foreach ($association in $plan.Discovery.Associations)`**

`Discovery.Dcr`があれば、DCR（データ収集ルール）の本文を組み立てます。`dataSources`が収集内容、`destinations`が保存先、`dataFlows`が両者の結び付きです。WindowsイベントとSyslogの収集条件は固定値を使います。

続いて、対象ごとに新DCRへの関連付けを作る本文を用意します。DCR本体と関連付けは、ともに`NewSettings`へ入ります。`VmLogDestination`は送り先の切替ではなく、`Log`なら新DCRと関連付けを作る指定です。送り先はCSVのLog Analyticsで、`None`・空欄ならこのブロックを通りません。

**[212～234行](step1_copy.ps1#L212)｜`$diagnosticBody = @{`、`$storageIds[$diagnostic.Location]`**

`OldId`に対応する旧診断設定から、ログ・メトリックを新しい本文へコピーします。Storage宛ては先ほどの地域別ID、Log宛てはCSVのワークスペースIDを設定し、`NewSettings`へ加えます。

診断側が`None`・空欄なら`Discovery.Diagnostics`が空なので、新診断設定は0件です。

**[239～263行](step1_copy.ps1#L239)｜`$setting.Before =`、`$plan.Remove('Discovery')`**

Waiver・DCR・関連付けの現在値を`Before`へ保存します。不在なら`$null`で、切り戻し時に「元へ戻すか、今回の追加分を削除するか」を決める材料になります。再実行では最初の`Before`を使います。

既存DCRなどの指定外の値を引き継いだ後、組立て用の`Discovery`を外します。ここで、保存先・新設定・旧設定の一覧がそろいます。

**[269～306行](step1_copy.ps1#L269)｜`$recordChanged = -not $record`、`[IO.File]::WriteAllText`**

前回の記録があれば今回の計画と照合し、新しい対象だけを追記します。旧設定の消失・改変や、同じIDの作成値の違いは停止条件です。初回は`$plan`をそのまま記録にします。

変更があればJSONを一時ファイルへ書き、既存ファイルの置換または移動で保存します。これが成功してからAzureへの書き込みへ進みます。

**[312～337行](step1_copy.ps1#L312)｜`$resources = @($record.NewSettings`、`$providersReady`**

作業記録から、Waiver→保存先・保持設定→DCR・関連付けの順に`$resources`を作ります。新診断設定は最後の別ループで扱います。

保存先の準備に入る前に必要なサービスの利用登録を確認し、未登録なら登録完了を待ちます。`$providersReady`は、同じSubでこの確認を繰り返さないための印です。

**[338～364行](step1_copy.ps1#L338)｜`$currentBody = Get-WritableBody`、`$matched = Test-Configuration`**

各対象の現在値を読み、作成したい`Body`と比べます。一致済みなら`continue`で次の対象へ進みます。作業記録のRGは存在を確認し、テーブルは総保持が個別指定されているかも確認します。

通信は[Invoke-ArmRequestのDESCRIPTION](common.ps1#L109)、比較用の本文への加工は[Get-WritableBodyのDESCRIPTION](common.ps1#L343)、一致判定は[Test-ConfigurationのDESCRIPTION](common.ps1#L257)を参照します。

更新する場合は送信用の`$body`を別コピーにし、元の記録を変えずに後の加工へ渡します。

**[370～404行](step1_copy.ps1#L370)｜`$body.properties.networkAcls =`、`$method = 'Patch'`**

既存StorageのIP・VNet規則、Log Analyticsの他のfeaturesなどを送信本文へ引き継ぎます。ライフサイクルは今回の`log-append-1095`だけを入れ替え、他名のルールを残します。

既存Log Analyticsやテーブルは必要な値だけを`PATCH`します。テーブルの列定義などを、保持期間の変更で置き換えないためです。

**[409～434行](step1_copy.ps1#L409)｜`while ($true)`、`-Method $method -Body $body`**

ここで本文をPUT／PATCHし、Azureから読み直して記録の期待値と照合します。DCR作成がEvent・Syslogの反映待ちで失敗した場合だけ、10秒待って再送します。

その他の失敗は外側の`catch`へ進み、そのSubの残りを止めます。

**[440～478行](step1_copy.ps1#L440)｜`$diagnostics | ForEach-Object -Parallel`、`return $result`**

保存先の準備後、新診断設定を最大5件同時に処理します。各処理へ共通関数と対象Subの認証情報を用意し、現在値が一致すれば省略、不在なら作成して読み直します。同名で内容が違う場合は失敗にします。

各結果を`$copied`へ集め、失敗したID・理由・期待本文を`$failures`へ追加します。

**[480～501行](step1_copy.ps1#L480)｜`$failurePath = Join-Path $PSScriptRoot`、`Export-Csv`**

準備中に失敗したSubも、ここへ理由と対象を残します。未完了があれば`copy_failures.csv`へ出してエラー終了します。全件成功なら前回の失敗CSVを消します。

旧設定はここまで残っています。次はstep2で、新しい送信設定がそろったか確認します。

## step2_verify.ps1：新しい設定がそろったか確かめる

**[1～19行](step2_verify.ps1#L1)｜`Read-MigrationRecord`、`-OnlyOldSettings`**

commonを読み、CSVのSubごとに作業記録を取得します。記録がないSubはNGです。続いて旧設定を再調査し、`$currentPlan`へ受け取ります。

`-OnlyOldSettings`で作成前の名前チェックなどを省く動きは、[Get-MigrationPlanのDESCRIPTION](common.ps1#L528)を参照します。

**[20～25行](step2_verify.ps1#L20)｜`foreach ($current in $currentPlan.OldSettings)`**

現在見つかった旧設定を、記録のID・本文と照合します。記録後の追加・改変はNGです。削除を再開できるよう、既に不在の旧設定は許可します。

**[30～60行](step2_verify.ps1#L30)｜`@($record.Destinations) + @($record.NewSettings)`**

記録した保存先・新設定を1件ずつGETし、`Body`と比べます。判定結果を`$results`へ入れ、不一致でも他の対象の確認を続けます。NGには、手動対応に使う期待本文も残します。

**[61～85行](step2_verify.ps1#L61)｜`$records += $record`、`if ($PassThru)`**

全Subの結果を`verify_results.csv`へ出し、NGがあればエラーで終了します。`-PassThru`はstep3から使う指定で、全件OKの場合だけ記録を返します。Azureへの変更は行いません。

## step3_delete.ps1：確認後に旧送信設定を外す

**[7～14行](step3_delete.ps1#L7)｜`$records = @(& (Join-Path`、`-PassThru`**

まずstep2を実行します。全件OKで返された記録を`$records`へ受け取ってから、削除のループへ進みます。step2は別スクリプトとして動くため、削除側でもcommonを`-SkipCsv`で読み、設定・関数を用意します。

外側の`$kind`がDCR関連付け→診断設定の順なので、全Subの旧関連付けを外した後に、全Subの旧診断設定を外します。

**[18～50行](step3_delete.ps1#L18)｜`$current = Invoke-ArmRequest`、`$newId = ''`**

削除直前の旧本文を再確認し、記録と違えば停止します。送信を続ける側は旧IDから親リソースのIDを求め、同じ親の新設定も確認します。

`None`・空欄の側は送信終了の指定なので、新側の確認をせず旧設定を外す流れになります。

**[51～68行](step3_delete.ps1#L51)｜`-Method Delete`、`catch`**

確認した旧設定をDELETEします。失敗すると対象ID・理由・旧本文を`delete_failures.csv`へ出し、他Subも含む残りを停止します。保存先・ログ・新設定・Waiverは残します。

## 必要時：rollback.ps1で切り戻す

**[1～31行](rollback.ps1#L1)｜`$PSBoundParameters.ContainsKey`、`Read-MigrationRecord`**

CSVではなく`records/<環境>/`のJSONから対象を選びます。`-SubscriptionIds`がなければ全Sub、指定すればそのSubだけです。記録の読み方は[Read-MigrationRecordのDESCRIPTION](common.ps1#L431)を参照します。

**[37～50行](rollback.ps1#L37)｜`$matchesBody`、`$matchesBefore`**

旧設定と、切り戻す新設定の現在値を読み、記録の`Body`（記録した設定値）か`Before`（変更前）か、不在であることを確認します。どれとも違う変更があれば、書き込み前に止めます。残す新規DCR本体・元からあるWaiverは照合対象から外します。

**[56～111行](rollback.ps1#L56)｜`foreach ($phase in @('Old', 'New'))`、`$expectedBody = $setting.Body`**

`$phase`をOld→Newへ進め、全対象Subの旧設定を復元してから、新側を変更前へ戻します。旧側は`Body`、新側は`Before`が戻す値です。

一致済みは省略し、値があればPUT、不在に戻す場合はDELETEします。新設DCR本体や元からあるWaiverは残す対象なので省略します。保存先はこのループの対象に含めません。

**[117～131行](rollback.ps1#L117)｜`catch`、`Remove-Item $failurePath`**

失敗は`rollback_failures.csv`へ出して停止します。同じ記録で再実行すると、復元済みの設定を省略できます。成功時は前回の失敗CSVを削除します。

## 任意：precheck.ps1で事前確認する

**[1～16行](precheck.ps1#L1)｜`Get-MigrationPlan -Target $target`**

commonで用意した対象一覧を1Subずつ調べ、OKと理由を結果表へ入れます。作業記録を渡さないため、初回の作成前チェックとして動きます。[Get-MigrationPlanのDESCRIPTION](common.ps1#L528)を参照してください。

**[18～32行](precheck.ps1#L18)｜`catch`、`$results | Export-Csv`**

失敗したSubもNGとして集め、最後に`precheck_results.csv`へ出します。NGがあればエラー終了します。Azureの変更やJSON保存はなく、step1はこの結果CSVを使わず当日の状態を調べ直します。

## 補足：関数の説明とPowerShellの読み方

関数の説明だけを表示するには、リポジトリのルートで次を実行します。`-SkipCsv`はCSV・Sub一覧・地域略称の取得を省き、設定と関数を読み込みます。関数名を変えれば他の関数の説明も読めます。

```powershell
. .\procedural-migration\common.ps1 -SkipCsv
(Get-Help Get-MigrationPlan -Full).Description.Text
```

コードで迷ったときは、次の表を参照してください。

|書き方|読み方|
|---|---|
|`$target`・`$target.SubscriptionId`|変数と、その中の項目。`=`は右の値を左へ入れる|
|`@()`・`@{}`|一覧（配列）・項目名と値の組（辞書）|
|`+=`|一覧へ追加する|
|`foreach`・`if`・`else`|1件ずつ処理・条件を満たす場合・満たさない場合|
|`continue`・`break`|次の対象へ進む・繰り返しを抜ける|
|`-eq`・`-ne`・`-in`・`-notin`|等しい・異なる・一覧に含まれる・含まれない|
|`-and`・`-or`・`-not`|両方満たす・どちらか満たす・条件を反転|
|`$null`・`??`|値がない状態・左がnullなら右を使う。CSVの文字列`None`とは別|
|`\|`・`$_`|左の結果を右へ渡す・処理中の1件|
|先頭の`.`・`&`|別ファイルの定義を読み込む・別スクリプトを実行する|
|`$using:`|並列処理へ外側の値を渡す|
|`[型]::名前`|その型に用意された値や処理を使う|
|`try`・`catch`・`throw`|実行する処理・失敗時の処理・失敗を呼出し元へ伝える|

`param(...)`は受け取る引数です。`[switch]`の引数は、`-PassThru`のように付ければ有効、省略すれば無効になります。二重引用符の中では変数を展開し、`$($target.SubscriptionId)`のように項目の参照を括弧で囲みます。
