# テストケース

[実行手順](INTEGRATION_TEST.md)の順に進め、判定を「未実施」から「OK」「NG」「対象なし」へ変えます。対象なしの場合は理由を残します。recordsは、使用中のrb1／n01内の`records/<環境>/<Sub ID>.json`です。

診断設定名は`setByAzurePlatformTeam`と表記します。common.ps1の`$newDiagnosticSettingName`を変更した場合は、その名前に読み替えます。`<run>`は手順の`$run`です。

新DCR名は、CSVのWorkspaceNameの先頭`log`を`dcr`へ置き換えた名前です。rb1は`dcr-<run>-rb1-a`（Sub1）・`dcr-<run>-rb1-b`（Sub2）、n01は`dcr-<run>-n01-a`・`dcr-<run>-n01-b`です。旧DCR関連付けが0件のSubでは新DCR・新関連付けも0件が正解です。旧関連のないVMSSは未検証と記録します。DCR本体・新関連付けを作成しなかった場合は、その部分だけ対象なしとし、診断設定と適用除外は判定します。

適用除外はrecordsに保存された3つのIDを確認します。名前は`log-migration-<環境>-<割り当てIDの末尾>`です。

<a id="t01"></a>
## T01：移行前に確認する

[実行手順](INTEGRATION_TEST.md#run-t01)

|確認項目|合格条件|判定|
|---|---|---|
|事前確認の結果CSV|両SubのResult列がOK|未実施|
|[移行する旧設定](INTEGRATION_TEST.md#check-targets)|両Subに旧診断が各1件以上あり、一覧の各リソースIDは変更してよい対象|未実施|
|子リソースの対象有無|Storageの4子サービス、SQL master、Foundry子プロジェクト、Web・Functions各スロットのIDが一覧にある。非対応・旧設定なし・一覧にない種類は未検証と記録する|未実施|
|作業前の画面|旧DCR2本のID・収集条件・送信先ID、既存の適用除外の名前・対象・期限、VNetのアドレス空間・サブネット範囲・委任・NSG・ルートテーブルを保存した|未実施|

<a id="t02"></a>
## T02：旧設定を残して複製する

[実行手順](INTEGRATION_TEST.md#run-t02)。rb1ではSub1をLog Analytics、Sub2をStorageへ送ります。

|確認項目|合格条件|判定|
|---|---|---|
|step2の結果CSV|Result列がすべてOK|未実施|
|[旧診断設定](INTEGRATION_TEST.md#check-old)|記録した各旧設定IDが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行前の値と一致する|未実施|
|[旧DCR関連付け](INTEGRATION_TEST.md#check-old)|各VM・VMSSのID、関連付け名、参照先DCR IDがrecordsの移行前の値と一致する|未実施|
|setByAzurePlatformTeam|各対象リソースに存在し、ログカテゴリ、ログ・メトリックの有効／無効は旧診断と一致する。Sub1はCSVのWorkspaceNameのLog Analytics ID、Sub2は同地域のStorage IDへ送る。Log Analyticsの格納方式は旧値、未指定ならAzureDiagnostics|未実施|
|移行先Log AnalyticsのsetByAzurePlatformTeam|CSVのWorkspaceNameのLog Analyticsに存在し、allLogsだけ有効、メトリックは無効。Sub1は自身のID、Sub2は同地域のStorage IDへ送る|未実施|
|rb1の新DCR・関連付け|旧関連があるSubでは、上記rb1のDCR IDを各VM・VMSSが参照し、Application・Security・SystemとSyslogをCSVのLog Analytics IDへ送る。同じVM・VMSSへの旧関連は1つにまとめる（旧7件・対象5つなら新5件）|未実施|
|保存先と適用除外|[保存先の表](#destination-details)がすべてOK。指定の適用除外3件が存在し期限なし。最初の2件は割り当て全体、3件目は指定12項目が対象|未実施|

<a id="t03"></a>
## T03：Sub1だけ切り戻す

[実行手順](INTEGRATION_TEST.md#run-t03)

|確認項目|合格条件|判定|
|---|---|---|
|[両Subの旧診断設定](INTEGRATION_TEST.md#check-old)|各旧設定IDが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行前の値と一致する|未実施|
|[両Subの旧DCR関連付け](INTEGRATION_TEST.md#check-old)|各VM・VMSSのID、関連付け名、参照先DCR IDがrecordsの移行前の値と一致する|未実施|
|Sub1の診断設定|各対象リソースとCSVのLog Analyticsの診断設定一覧にsetByAzurePlatformTeamが存在しない|未実施|
|Sub1の新DCR関連付け|VM・VMSSに`dcr-<run>-rb1-a`を参照する関連付けが存在しない|未実施|
|Sub1の新DCR本体|作成した`dcr-<run>-rb1-a`がCSVのResourceGroup内に存在する|未実施|
|Sub1の適用除外|今回作った指定名の適用除外が存在しない。作業前からあったものは適用先ID・除外ポリシー・期限が作業前の画面と一致する|未実施|
|Sub2の診断設定|各対象のsetByAzurePlatformTeamが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行後の値と一致する|未実施|
|Sub2のLog Analytics自身の診断設定|setByAzurePlatformTeamが存在し、allLogsだけ有効、メトリックは無効。同地域のStorage IDへ送る|未実施|
|Sub2の新DCRと関連付け|作成した`dcr-<run>-rb1-b`がCSVのResourceGroup内に存在し、そのIDを各VM・VMSSが参照する|未実施|
|Sub2の適用除外|recordsにある3つの適用除外IDが存在し、適用先ID・除外ポリシー・期限がrecordsの移行後の値と一致する|未実施|
|両Subの保存先|CSVのResourceGroup内にWorkspaceNameのLog Analyticsが存在し、Event・Syslogテーブルも存在する。地域別のStorageAccount名が存在する|未実施|

<a id="t04"></a>
## T04：削除前に両Subを切り戻す

[実行手順](INTEGRATION_TEST.md#run-t04)

|確認項目|合格条件|判定|
|---|---|---|
|[旧診断設定](INTEGRATION_TEST.md#check-old)|各旧設定IDが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行前の値と一致する|未実施|
|[旧DCR関連付け](INTEGRATION_TEST.md#check-old)|各VM・VMSSのID、関連付け名、参照先DCR IDがrecordsの移行前の値と一致する|未実施|
|追加した診断設定|両Subの各対象リソースとCSVのLog AnalyticsにsetByAzurePlatformTeamが存在しない|未実施|
|追加したDCR関連付け|VM・VMSSに`dcr-<run>-rb1-a`・`dcr-<run>-rb1-b`を参照する関連付けが存在しない|未実施|
|作成したDCR本体|作成した`dcr-<run>-rb1-a`・`dcr-<run>-rb1-b`がCSVのResourceGroup内に存在する|未実施|
|適用除外|今回作った指定名の適用除外が存在しない。作業前からあったものは適用先ID・除外ポリシー・期限が作業前の画面と一致する|未実施|
|保存先|CSVのResourceGroup内にWorkspaceNameのLog Analytics、Event・Syslogテーブル、地域別のStorageAccount名が存在する|未実施|

<a id="t05"></a>
## T05：正常に移行し、旧設定を削除する

[実行手順](INTEGRATION_TEST.md#run-t05)。n01ではSub1をStorage、Sub2をLog Analyticsへ送ります。

<a id="t05-precheck"></a>
### 事前確認

|確認項目|合格条件|判定|
|---|---|---|
|事前確認の結果CSVと対象|両SubのResult列がOK。一覧の各リソースIDは変更してよい対象|未実施|

<a id="t05-before"></a>
### 削除前

|確認項目|合格条件|判定|
|---|---|---|
|step2の結果CSV|Result列がすべてOK|未実施|
|[旧診断設定](INTEGRATION_TEST.md#check-old)|各旧設定IDが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行前の値と一致する|未実施|
|[旧DCR関連付け](INTEGRATION_TEST.md#check-old)|各VM・VMSSのID、関連付け名、参照先DCR IDがrecordsの移行前の値と一致する|未実施|
|setByAzurePlatformTeam|各対象リソースに存在し、ログカテゴリ、ログ・メトリックの有効／無効は旧診断と一致する。Sub1は同地域のStorage ID、Sub2はCSVのWorkspaceNameのLog Analytics IDへ送る。Log Analyticsの格納方式は旧値、未指定ならAzureDiagnostics|未実施|
|移行先Log AnalyticsのsetByAzurePlatformTeam|CSVのWorkspaceNameのLog Analyticsに存在し、allLogsだけ有効、メトリックは無効。Sub1は同地域のStorage ID、Sub2は自身のIDへ送る|未実施|
|n01の新DCR・関連付け|旧関連があるSubでは、上記n01のDCR IDを各VM・VMSSが参照し、Application・Security・SystemとSyslogをCSVのLog Analytics IDへ送る。同じVM・VMSSへの関連は1件。旧関連0件のSubは新DCR・新関連も0件|未実施|
|保存先と適用除外|[保存先の表](#destination-details)をもう1枚使い、すべてOK。指定の適用除外3件が存在し期限なし。最初の2件は割り当て全体、3件目は指定12項目が対象|未実施|

<a id="t05-after"></a>
### 削除後

|確認項目|合格条件|判定|
|---|---|---|
|step2の結果CSV|Result列がすべてOK|未実施|
|[削除した旧設定](INTEGRATION_TEST.md#check-old)|recordsに記録した旧診断設定IDと旧DCR関連付けIDが、すべて存在しない|未実施|
|移行後の診断設定・DCR関連付け|各対象とCSVのLog AnalyticsにsetByAzurePlatformTeamが存在する。送信先はSub1が同地域のStorage ID、Sub2がCSVのLog Analytics ID。作成した`dcr-<run>-n01-a`・`dcr-<run>-n01-b`を各VM・VMSSが参照する|未実施|
|保存先と適用除外|CSVのLog Analytics、Event・Syslog、地域別Storage、指定名の適用除外3件が存在する|未実施|
|旧DCR本体|指定した2本のIDが存在し、収集条件と送信先IDが作業前の画面と一致する|未実施|

<a id="t06"></a>
## T06：削除した旧設定を復元する

[実行手順](INTEGRATION_TEST.md#run-t06)

|確認項目|合格条件|判定|
|---|---|---|
|[旧診断設定](INTEGRATION_TEST.md#check-old)|各旧設定IDが存在し、ログカテゴリ、ログ・メトリックの有効／無効、送信先ID、格納方式がrecordsの移行前の値と一致する|未実施|
|[旧DCR関連付け](INTEGRATION_TEST.md#check-old)|各VM・VMSSのID、関連付け名、参照先DCR IDがrecordsの移行前の値と一致する|未実施|
|追加した診断設定|各対象リソースとCSVのLog Analyticsの診断設定一覧にsetByAzurePlatformTeamが存在しない|未実施|
|追加したDCR関連付け|VM・VMSSに`dcr-<run>-n01-a`・`dcr-<run>-n01-b`を参照する関連付けが存在しない|未実施|
|作成したDCR本体|作成した`dcr-<run>-n01-a`・`dcr-<run>-n01-b`が、CSVのResourceGroup内に存在する。作成しなかったSubは対象なし|未実施|
|適用除外|今回作った指定名の適用除外が存在しない。作業前からあったものは適用先ID・除外ポリシー・期限が作業前の画面と一致する|未実施|
|保存先と旧DCR本体|CSVのLog Analytics、Event・Syslog、地域別Storageが存在する。旧DCR2本のID・収集条件・送信先IDが作業前の画面と一致する|未実施|
|既存VNetとサブネット|アドレス空間・サブネット範囲・委任・NSG・ルートテーブルが作業前の画面と一致する|未実施|

<a id="destination-details"></a>
## 保存先の確認

T02とT05の削除前に、それぞれこの表を複写して判定します。[Azure画面の確認場所](INTEGRATION_TEST.md#check-portal)を使います。各SubのCSVにあるResourceGroup内で、WorkspaceNameのLog Analyticsを確認します。StorageはStorageAccountの`jpe`を地域略称へ置き換えた実名で、recordsに保存されたIDが存在することを確認します。

|確認項目|合格条件|判定|
|---|---|---|
|Log Analyticsの地域|common.ps1に指定した作成地域と一致する|未実施|
|Log Analyticsの保持期間|90日|未実施|
|Log Analyticsのパブリック取込|有効|未実施|
|Log Analyticsのパブリッククエリ|有効|未実施|
|Log Analyticsのアクセス権|リソースまたはワークスペースの権限で参照する設定|未実施|
|Event・Syslogの合計保持期間|両方1,095日。既定値の継承ではなく、テーブルへ直接設定|未実施|
|Storageの地域|送信元と同地域。送信元の地域が空欄・globalなら東日本|未実施|
|Storageの冗長性|ZRSを優先し、非対応地域はLRS。recordsの該当Storage IDに保存した冗長性と一致する|未実施|
|Storageの種類|StorageV2|未実施|
|基盤側の暗号化|有効|未実施|
|版単位の不変性サポート|有効|未実施|
|HTTPSの必須化|有効|未実施|
|最低TLSバージョン|TLS 1.2|未実施|
|共有キーの利用|無効|未実施|
|Blobの匿名公開|無効|未実施|
|Storageのパブリックネットワーク|無効|未実施|
|ネットワークの既定規則|拒否|未実施|
|ネットワークの例外|信頼されたAzureサービスを許可|未実施|
|Blobのバージョン管理|有効|未実施|
|Blobの削除ルール|log-append-1095が有効。appendBlobを最終更新から1,095日超で削除|未実施|
|StorageのDefender|無効|未実施|
|Defenderの上位設定の上書き|サブスクリプションの設定より、このStorageの設定を優先|未実施|
