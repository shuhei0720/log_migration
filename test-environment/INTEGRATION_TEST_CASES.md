# 2サブスクリプションのテストケース

実行するコマンドと共通の確認コードは[実行手順](INTEGRATION_TEST.md)にあります。各時点の判定を「未実施」から「OK」「NG」「対象なし」へ変えます。対象なしの場合は、その項目と理由も残します。

`rb1`はSub1をLog、Sub2をStorageへ送ります。`n01`は逆です。VMログは両方ともLogです。T01～T06を順に行い、同じテスト用リソースを使います。T05は削除前と削除後を別々に判定します。

各時点の`<時点>-state.csv`は、**両Subの全行がMatches=True**であることを判定の共通条件にします。取得値は同名の`<時点>-actual.json`で確認します。既存DCRがない場合でも、新設DCRの保持・新関連付けの削除など、該当する確認は行います。

DCRは、指定旧DCRへの関連付けがあるSubで移行を確認します。旧関連が0件のSubでは、新DCR・新関連付けも0件が正解です。会社ポリシーがVMSSへ旧関連を付けなければ、VMSSのDCR移行は未検証と記録します。

<a id="t01"></a>

## T01：移行前の確認

[T01の実行手順](INTEGRATION_TEST.md#run-t01)。開始時は会社の旧設定があり、rb1の作業記録はありません。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T01-01|[事前確認CSV](INTEGRATION_TEST.md#check-results)の両SubのResult列を見る|2行ともOK。NGがない|`precheck_results.csv`|未実施|
|T01-02|[対象一覧](INTEGRATION_TEST.md#save-baseline)のIDとKind列を確認する|両Subに旧診断が各1件以上あり、変更してよいIDだけ。旧DCR関連はSub別に件数を記録する。0件でもNGにしない|`review-targets.csv`・Sub別件数|未実施|
|T01-03|Captureと対象一覧を、作成した子リソースのIDで照合する|Storageの4子サービス、SQL master、Foundry子プロジェクト、Web・Functionsの各スロットについて、移行対象か、非対応・旧設定なし・探索対象外かを記録した|`run-ledger.json`・対象一覧・種類別結果|未実施|
|T01-04|[変更前の値](INTEGRATION_TEST.md#save-baseline)を保存する|旧DCR2本の設定値と、既存ポリシー適用除外の有無・値を取得できた|`baseline-dcr.json`・`baseline-exemptions.json`|未実施|
|T01-05|[既存VNetの構成](INTEGRATION_TEST.md#check-dcr-vnet)を作成前の画面と比べる|アドレス空間、サブネット範囲・委任・NSG・ルートテーブルが変わっていない|両VNetの比較画面|未実施|

旧設定がない種類や、Captureだけ成功して対象一覧に出ない種類は、移行を確認した種類に数えません。

<a id="t02"></a>

## T02：旧設定を残したまま複製する

[T02の実行手順](INTEGRATION_TEST.md#run-t02)。T01合格後、rb1のstep1・step2を実行した状態で確認します。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T02-01|[step2の結果](INTEGRATION_TEST.md#check-results)を見る|Result列がすべてOK|`T02-verify.csv`|未実施|
|T02-02|[旧設定全件の比較](INTEGRATION_TEST.md#check-old)を行う|旧診断・旧DCR関連付けの全件がExists=True、Matches=True|`T02-old.csv`|未実施|
|T02-03|[新診断の取得JSON](INTEGRATION_TEST.md#check-state)を旧設定・CSVと比べる|ログ・メトリックは旧設定と同じ。Sub1はCSVのLAW、Sub2は対象と同地域のStorage宛て。Log宛ての格納方式は旧値を継承し、未指定ならAzureDiagnostics|`T02-state.csv`・`T02-actual.json`・records|未実施|
|T02-04|[移行先LAW自身の新診断](INTEGRATION_TEST.md#check-state)を見る|allLogsのみ有効。audit・メトリックが返る場合は無効。記録との比較はMatches=True。Sub1は自身、Sub2はLAWと同地域のStorage宛て|`T02-state.csv`・`T02-actual.json`|未実施|
|T02-05|[新DCR・関連付け](INTEGRATION_TEST.md#check-state)の収集条件・宛先・親IDを確認する|旧関連があるSubでは、新DCRがApplication・Security・SystemとSyslogをCSVのLAWへ送る。新関連数は旧関連の親IDの重複を除いた数（旧7件・親5件なら新5件）。旧関連0のSubでは新DCR・新関連とも0件|`T02-state.csv`・関連付けID一覧・records|未実施|
|T02-06|[新規LAWとテーブル](INTEGRATION_TEST.md#check-state)を見る|[保存先詳細D01～D06](#destination-details)のT02欄がすべてOK|`T02-state.csv`・`T02-actual.json`|未実施|
|T02-07|[地域別Storageと子設定](INTEGRATION_TEST.md#check-state)を見る|[保存先詳細D07～D22](#destination-details)のT02欄がすべてOK|`T02-state.csv`・`T02-actual.json`|未実施|
|T02-08|[ポリシー適用除外](INTEGRATION_TEST.md#check-state)を見る|両Subに各3件のWaiverがある。期限なし。1・2件目は割り当て全体、3件目は指定12参照IDを除外|`T02-state.csv`・`T02-actual.json`|未実施|
|T02-09|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本はExists=True、Matches=True。VNetの構成は作成前と同じ|`T02-dcr.csv`・両VNetの比較画面|未実施|

新診断の全件数には移行先LAW自身の診断も含まれます。旧診断・旧関連付けと新設定の総件数を同数として判定しません。

<a id="t03"></a>

## T03：Sub1だけ切り戻す

[T03の実行手順](INTEGRATION_TEST.md#run-t03)。T02合格後、Sub1を指定したrollbackを実行した状態で確認します。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T03-01|[両Subの旧設定](INTEGRATION_TEST.md#check-old)を比べる|両Subの旧診断・旧関連付けが全件Exists=True、Matches=True|`T03-old.csv`|未実施|
|T03-02|[Sub1の新設定](INTEGRATION_TEST.md#check-state)を切り戻し後の期待値と比べる|今回追加した新診断・新関連付けは消える。変更した既存DCR・関連付けはBeforeの値。新設DCR本体は残る|`T03-state.csv`・`T03-actual.json`・records|未実施|
|T03-03|[Sub1の適用除外](INTEGRATION_TEST.md#check-state)を変更前と比べる|今回作ったものは消える。元からあったものは存在と元の値を保持する|`T03-state.csv`・`baseline-exemptions.json`|未実施|
|T03-04|[Sub2の新設定・適用除外](INTEGRATION_TEST.md#check-state)を複製時のBodyと比べる|Sub2は切り戻されず、新診断・新関連付け・DCR・適用除外がT02の値で残る|`T03-state.csv`・`T03-actual.json`|未実施|
|T03-05|[両Subの保存先](INTEGRATION_TEST.md#check-state)を確認する|両SubのLAW・テーブル・Storage・子設定が残り、複製後の値と一致する|`T03-state.csv`・`T03-actual.json`|未実施|
|T03-06|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本の存在・値と、VNetの構成が変更前と同じ|`T03-dcr.csv`・両VNetの比較画面|未実施|

<a id="t04"></a>

## T04：削除前に両Subを切り戻す

[T04の実行手順](INTEGRATION_TEST.md#run-t04)。T03合格後、対象指定なしのrollbackを実行した状態で確認します。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T04-01|[両Subの旧設定](INTEGRATION_TEST.md#check-old)を比べる|旧診断・旧関連付けが全件Exists=True、Matches=True|`T04-old.csv`|未実施|
|T04-02|[両Subの新設定](INTEGRATION_TEST.md#check-state)を切り戻し後の期待値と比べる|新診断・新関連付けは消える。変更した既存DCR・関連付けはBeforeの値。新設DCR本体は残る。先に戻したSub1も同じ状態|`T04-state.csv`・`T04-actual.json`・records|未実施|
|T04-03|[適用除外](INTEGRATION_TEST.md#check-state)を変更前と比べる|今回作ったものは消える。元からあったものは存在と元の値を保持する|`T04-state.csv`・`baseline-exemptions.json`|未実施|
|T04-04|[保存先](INTEGRATION_TEST.md#check-state)を見る|両SubのLAW・テーブル・Storage・子設定が残り、複製後の値と一致する|`T04-state.csv`・`T04-actual.json`|未実施|
|T04-05|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本の存在・値と、VNetの構成が変更前と同じ|`T04-dcr.csv`・両VNetの比較画面|未実施|

<a id="t05"></a>

## T05：複製・照合・旧設定削除を完了する

[T05の実行手順](INTEGRATION_TEST.md#run-t05)。T04合格とrb1用保存先RGの削除後、n01を使います。Sub1はStorage、Sub2はLogです。

<a id="t05-precheck"></a>

### 事前確認：step1の前

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T05-01|step1前に[precheckの結果](INTEGRATION_TEST.md#check-results)を見る|両SubのResult列がOK|`precheck_results.csv`|未実施|
|T05-02|step1前に[対象一覧・変更前の値](INTEGRATION_TEST.md#save-baseline)を保存する|変更してよい旧設定だけ。旧DCR2本と既存適用除外の有無・値を保存した|`review-targets.csv`・`baseline-dcr.json`・`baseline-exemptions.json`|未実施|

<a id="t05-before"></a>

### 削除前：step1・step2の後

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T05-03|複製後に[step2の結果](INTEGRATION_TEST.md#check-results)を見る|Result列がすべてOK|`T05-before-delete-verify.csv`|未実施|
|T05-04|[旧設定](INTEGRATION_TEST.md#check-old)を比べる|旧診断・旧関連付けが全件Exists=True、Matches=True|`T05-before-delete-old.csv`|未実施|
|T05-05|[新診断の取得JSON](INTEGRATION_TEST.md#check-state)を旧設定・CSVと比べる|ログ・メトリックは旧値。Sub1は同地域のStorage、Sub2はCSVのLAW宛て。Log宛ての格納方式は旧値を継承し、未指定ならAzureDiagnostics|`T05-before-delete-state.csv`・`T05-before-delete-actual.json`・records|未実施|
|T05-06|[移行先LAW自身の新診断](INTEGRATION_TEST.md#check-state)を見る|allLogsのみ有効。audit・メトリックが返る場合は無効。記録との比較はMatches=True。Sub1は同地域のStorage、Sub2は自身宛て|`T05-before-delete-state.csv`・`T05-before-delete-actual.json`|未実施|
|T05-07|[新DCR・関連付け](INTEGRATION_TEST.md#check-state)を見る|旧関連があるSubでは、新DCRがApplication・Security・SystemとSyslogをCSVのLAWへ送る。新関連数は旧関連の親IDの重複を除いた数。旧関連0のSubでは新DCR・新関連とも0件|`T05-before-delete-state.csv`・関連付けID一覧・records|未実施|
|T05-08|[新規LAW・Event・Syslog](INTEGRATION_TEST.md#check-state)を見る|[保存先詳細D01～D06](#destination-details)のT05削除前欄がすべてOK|`T05-before-delete-state.csv`・`T05-before-delete-actual.json`|未実施|
|T05-09|[地域別Storageと子設定](INTEGRATION_TEST.md#check-state)を見る|[保存先詳細D07～D22](#destination-details)のT05削除前欄がすべてOK|`T05-before-delete-state.csv`・`T05-before-delete-actual.json`|未実施|
|T05-10|[適用除外](INTEGRATION_TEST.md#check-state)を見る|各Subの3件は期限なしWaiver。1・2件目は割り当て全体、3件目は指定12参照IDを除外|`T05-before-delete-state.csv`・`T05-before-delete-actual.json`|未実施|
|T05-11|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本の存在・値と、VNetの構成が変更前と同じ|`T05-before-delete-dcr.csv`・両VNetの比較画面|未実施|

<a id="t05-after"></a>

### 削除後：step3・step2の後

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T05-12|[step2の結果](INTEGRATION_TEST.md#check-results)を見る|Result列が全件OK|`T05-after-delete-verify.csv`|未実施|
|T05-13|[旧設定全件](INTEGRATION_TEST.md#check-old)を取得する|旧診断・旧関連付けが全件Exists=False|`T05-after-delete-old.csv`|未実施|
|T05-14|[新設定・保存先・適用除外](INTEGRATION_TEST.md#check-state)を比べる|すべて残り、削除前のBodyと一致する。新診断の宛先・新DCRの参照先も同じ|`T05-after-delete-state.csv`・`T05-after-delete-actual.json`|未実施|
|T05-15|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|削除したのは旧関連付けであり、旧DCR2本は存在・値が変更前と同じ。VNetの構成も同じ|`T05-after-delete-dcr.csv`・両VNetの比較画面|未実施|

<a id="t06"></a>

## T06：削除した旧設定を復元する

[T06の実行手順](INTEGRATION_TEST.md#run-t06)。T05の削除後判定が合格したら、n01のrollbackを対象指定なしで実行します。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T06-01|[旧設定全件](INTEGRATION_TEST.md#check-old)を比べる|削除した旧診断・旧関連付けがすべて復元され、Exists=True、Matches=True|`T06-old.csv`|未実施|
|T06-02|[新設定](INTEGRATION_TEST.md#check-state)を切り戻し後の期待値と比べる|今回追加した新診断・新関連付けは消える。変更した既存DCR・関連付けはBeforeの値。新設DCR本体は残る|`T06-state.csv`・`T06-actual.json`・records|未実施|
|T06-03|[適用除外](INTEGRATION_TEST.md#check-state)を変更前と比べる|今回作ったものは消える。元からあったものは存在と元の値を保持する|`T06-state.csv`・`baseline-exemptions.json`|未実施|
|T06-04|[保存先](INTEGRATION_TEST.md#check-state)を見る|両SubのLAW・テーブル・Storage・子設定が残り、複製後の値と一致する|`T06-state.csv`・`T06-actual.json`|未実施|
|T06-05|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本の存在・値と、VNetの構成が変更前と同じ|`T06-dcr.csv`・両VNetの比較画面|未実施|

切り戻し後にstep2を実行して合否を判定しません。新設定が消えているため、step2はNGになります。既存DCR・既存適用除外がなければ、その部分だけ「対象なし」とし、同じ行の新規設定は判定します。

<a id="destination-details"></a>

## 保存先詳細：T02・T05削除前で判定する

[状態確認](INTEGRATION_TEST.md#check-state)の`T02-actual.json`・`T05-before-delete-actual.json`から該当IDの値を確認します。この表は新規保存先用です。`Reuse=True`の既存保存先がある場合は、変更前の設定を保持することを判定し、新規設計値は「対象なし」とします。

|項目ID|確認項目|合格となる値|T02判定|T05削除前判定|
|---|---|---|---|---|
|D01|LAWの配置地域|common.ps1の`$location`と同じ|未実施|未実施|
|D02|LAWの保持期間|`retentionInDays=90`|未実施|未実施|
|D03|LAWのパブリック取込|`publicNetworkAccessForIngestion=Enabled`|未実施|未実施|
|D04|LAWのパブリッククエリ|`publicNetworkAccessForQuery=Enabled`|未実施|未実施|
|D05|LAWのログ参照権限|`features.enableLogAccessUsingOnlyResourcePermissions=True`。リソースまたはLAWの権限で参照する設定|未実施|未実施|
|D06|Event・Syslogの合計保持期間|両方`totalRetentionInDays=1095`、`totalRetentionInDaysAsDefault=False`で明示設定|未実施|未実施|
|D07|Storageの配置地域|送信元と同地域。送信元の地域が空欄・globalならjapaneast|未実施|未実施|
|D08|Storageの冗長性|ZRSを優先し、非対応地域はLRS。`sku.name`がrecordsに保存した`Standard_ZRS`または`Standard_LRS`と同じ|未実施|未実施|
|D09|Storageの種類|`kind=StorageV2`|未実施|未実施|
|D10|Storageの基盤暗号化|`encryption.requireInfrastructureEncryption=True`|未実施|未実施|
|D11|版単位の不変性サポート|`immutableStorageWithVersioning.enabled=True`|未実施|未実施|
|D12|HTTPSの必須化|`supportsHttpsTrafficOnly=True`|未実施|未実施|
|D13|最低TLS版|`minimumTlsVersion=TLS1_2`|未実施|未実施|
|D14|共有キーの利用|`allowSharedKeyAccess=False`|未実施|未実施|
|D15|Blobの匿名公開|`allowBlobPublicAccess=False`|未実施|未実施|
|D16|パブリックネットワーク|`publicNetworkAccess=Disabled`|未実施|未実施|
|D17|ネットワークの既定規則|`networkAcls.defaultAction=Deny`|未実施|未実施|
|D18|ネットワークの例外|`networkAcls.bypass=AzureServices`|未実施|未実施|
|D19|Blobの版管理|Blobサービスの`isVersioningEnabled=True`|未実施|未実施|
|D20|Blobの削除ルール|`log-append-1095`が有効。対象はappendBlob、最終更新から1,095日を超えるBlobを削除|未実施|未実施|
|D21|個別のDefender設定|`isEnabled=False`|未実施|未実施|
|D22|Defenderの上位設定の上書き|`overrideSubscriptionLevelSettings=True`|未実施|未実施|

<a id="t07"></a>

## T07：同じ入力で再実行する（任意）

[任意試験の実行手順](INTEGRATION_TEST.md#optional-repeat)。T05の削除前判定後に、同じ入力でstep1・step2を再実行します。基本手順への追加は2回です。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T07-01|[step2と設定値](INTEGRATION_TEST.md#check-results)を確認する|全件OK。旧設定は残り、新設定・保存先の値が再実行前と同じ|`T07-verify.csv`・`T07-old.csv`・`T07-state.csv`・`T07-actual.json`|未実施|
|T07-02|再実行時間帯・実行者のAzureアクティビティログを見る|今回の実行による作成・更新・削除がない|時間帯・実行者を絞ったアクティビティログ|未実施|
|T07-03|[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|旧DCR2本の存在・値と、VNetの構成が変更前と同じ|`T07-dcr.csv`・両VNetの比較画面|未実施|

<a id="t08"></a>

## T08：None・空欄で送信を終了する（任意）

[任意試験の実行手順](INTEGRATION_TEST.md#optional-off)。T06後、n01用保存先を削除し、off用の別CSV・保存先名・recordsを使います。基本手順への追加は6回、step3内部のstep2を含め7回です。

|項目ID|確認項目・方法|合格条件|残す証拠|判定|
|---|---|---|---|---|
|T08-01|CSVと[事前確認結果](INTEGRATION_TEST.md#check-results)を見る|Sub1はLogDestination・VmLogDestinationがNone、Sub2は両方空欄。StorageAccountは両方空欄。両SubがOK|offのCSV・`precheck_results.csv`|未実施|
|T08-02|複製後の[新設定・保存先](INTEGRATION_TEST.md#check-state)を見る|StorageAccountが空欄なのでStorageを作らない。None/空欄の送信フラグにより新診断・新DCR関連付けを作らない。LAW・Event・Syslogは作る。旧設定は全件Exists=True、Matches=True|`T08-before-delete-old.csv`・`T08-before-delete-state.csv`・`T08-before-delete-actual.json`・records|未実施|
|T08-03|削除後の[旧設定](INTEGRATION_TEST.md#check-old)とstep2を見る|旧診断・旧関連付けが全件Exists=False。step2全件OK。旧DCR本体は残る|`T08-after-delete-old.csv`・`verify_results.csv`・`T08-after-delete-dcr.csv`|未実施|
|T08-04|切り戻し後の[旧設定](INTEGRATION_TEST.md#check-old)と[残る設定](INTEGRATION_TEST.md#check-state)を見る|旧設定が全件Exists=True、Matches=True。LAW・テーブルは残り、適用除外は変更前の有無・値になる|`T08-restored-old.csv`・`T08-restored-state.csv`・`T08-restored-actual.json`|未実施|
|T08-05|各時点の[旧DCR本体・既存VNet](INTEGRATION_TEST.md#check-dcr-vnet)を比べる|複製後・削除後・切り戻し後のすべてで、旧DCR2本の存在・値とVNetの構成が変更前と同じ|各時点の`<時点>-dcr.csv`・両VNetの比較画面|未実施|
