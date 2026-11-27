# 実施したテスト

**機能試験はPASSです。3SubのRG・リソースは0件で、元の管理構造・権限・ポリシーへ戻しました。利用登録37件のうち36件は復元済みで、Sub3のMicrosoft.Networkだけ解除完了を待っています。**

Azure実機では、製品スクリプトの起動と別処理によるGET確認を分けて数えています。期待した拒否の`exit1`は異常を正しく止めた結果であり、想定外の不具合とは区別します。ローカル試験の112ケースと追加step4の50ケースを、実機件数へ足していません。

# 実機で確認したケース

Source V3は`96763ee`、V4は`8867740`。V3の試験をV4で再実行した結果として扱わない。WindowsはPowerShell 7.5.4、guardsだけLinuxのPowerShell 7.5.4で実行した。

V3とV4で、`precheck.ps1`・`step2_verify.ps1`・`step3_delete.ps1`・`rollback.ps1`の4本はファイル全体のバイト列が同じ。`common.ps1`と`step1_copy.ps1`の2本は、新DCR自身の診断設定を追加するため変更した。各ファイルのSHAは[出荷確認](RELEASE_CHECKS.json)の版別記録に記載しています。

表の「期待どおり」は、失敗させる条件を作った試験も含む。`exit1`が期待値なら拒否できたことが成功であり、製品の想定外エラーとは区別する。変更要求数はAPI呼出しの数で、作成リソース数ではない。

## 完了した試験

|試験|確かめたこと|対象と実行単位|結果|
|---|---|---|---|
|V3 Core|中断、Subごとの停止、同じ記録での再実行|旧375設定・対象外35件。製品14起動＋独立確認14回|期待どおり|
|V4 Gap|事前確認後の対象追加、DCR自身の診断の不足と修復、追記後の切り戻し|旧375→376→377設定。製品8起動＋独立確認5回|期待どおり|
|V4 flagsA/B|診断側・VM側を作らない指定、空欄、保存先の作成、旧送信の終了|各回：旧25設定・保護404件。製品5起動＋独立確認3回|期待どおり|
|V4 reuse|既存保存先の値を維持し、DCR・関連付けを作業前の値へ戻す|旧25設定・保護404件・再利用37件。製品5起動＋独立確認3回|期待どおり|
|V4 guards|名前重複、地域違い、上限、作業記録不備を変更前に拒否|13起動。成功1件・拒否12件。Linuxで確認|期待どおり|
|V4 allLog|全件をLAWへ移行・旧削除・切り戻し。FirewallのDedicatedを維持|旧375設定・対象外35件。製品5起動＋独立確認3回|期待どおり|
|新規リソースの作成|新規作成からCaptureまで|親8件、Storage子を含む12対象。Deploy・Capture各1回|作成・取得・旧診断12件の準備を確認|
|最後の正常通し|新規作成から事前確認→複製→確認→旧設定削除まで|3Subの旧387件・対象外35件。製品4起動＋独立確認2回|PASS。旧387件の不在、新401件、保存先と付属設定40件を確認|
|追加step4|移行後の旧設定不在・新設定・保存先・適用除外を再確認|3Subの828行。製品1起動、Azure GET1503回|PASS。全行OK、書込み0、元と確認用コピーの既存ファイル不変|

旧375設定は診断368件＋DCR関連7件。代表ケースの旧25設定は診断18件＋DCR関連7件で、保護404件は元の診断368件・対象外35件・既知のKey Vault設定1件を指す。これらは別の試験データなので合算しない。最後の正常通しは、元の旧375件と新規12件の計387件を対象にしました。新401件は診断385件＋DCR関連5件＋DCR2件＋適用除外9件です。保存先と付属設定40件は、物理的なStorage7件・LAW3件のほかRGや子設定を含む記録件数です。

## リソースタイプ別の実施結果

以下は完了済みの試験だけの結果です。LogはLog Analytics宛て、Storageはストレージ宛ての診断設定を指します。Logは複製・旧設定削除・切り戻しまで、Storageは最後の正常通しで複製・確認・旧設定削除まで確認しました。メトリックだけの設定も含みます。

<!-- RESOURCE_TYPE_RESULTS: 閉鎖済みLog試験と最後のStorage正常通しを基準とする -->
|型|実施|結果|省略理由|
|---|---|---|---|
|`microsoft.apimanagement/service`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.app/containerapps`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.app/jobs`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.app/managedenvironments`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.app/sessionpools`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.automation/automationaccounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.bing/accounts`|未作成|未確認|サービス退役により新規検証不可|
|`microsoft.botservice/botservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.cache/redis`|未作成|未確認|新規作成の終了制限|
|`microsoft.cache/redisenterprise`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.codesigning/codesigningaccounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.cognitiveservices/accounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.cognitiveservices/accounts/projects`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.communication/communicationservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.compute/disks`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.compute/virtualmachines`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.compute/virtualmachinescalesets`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.containerregistry/registries`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.containerservice/managedclusters`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.databricks/workspaces`|未作成|未確認|必要なNSG関連付けが既存サブネットを変更しない条件と両立しない|
|`microsoft.dbforpostgresql/flexibleservers`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.documentdb/databaseaccounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.eventgrid/systemtopics`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.insights/components`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.insights/datacollectionrules`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.keyvault/vaults`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.kusto/clusters`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.logic/workflows`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.machinelearningservices/workspaces`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.monitor/accounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/applicationgateways`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/azurefirewalls`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/dnsresolverpolicies`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/dnszones`|Azure実機|診断設定の非対応を確認|診断設定を作らず対象外として扱う|
|`microsoft.network/expressroutecircuits`|未作成|未確認|回線契約・プロバイダー料金・撤去条件が未確認|
|`microsoft.network/loadbalancers`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/natgateways`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/networkinterfaces`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/networksecuritygroups`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/privatednszones`|Azure実機|診断設定の非対応を確認|診断設定を作らず対象外として扱う|
|`microsoft.network/privateendpoints`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/publicipaddresses`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.network/virtualnetworks`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.operationalinsights/workspaces`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.recoveryservices/vaults`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.relay/namespaces`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.search/searchservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.servicebus/namespaces`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.sql/servers`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.sql/servers/databases`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.storage/storageaccounts`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.web/connections`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.web/hostingenvironments`|今回未実施|今回の移行は未確認|利用者の指示で再試験省略。過去の成功は今回へ加算しない|
|`microsoft.web/serverfarms`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.web/sites`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.web/sites/slots`|Azure実機|Log確認／Storage複製確認|—|

### 要求56タイプとは別に確認した子5タイプ

|型|実施|結果|省略理由|
|---|---|---|---|
|`microsoft.cache/redisenterprise/databases`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.storage/storageaccounts/blobservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.storage/storageaccounts/fileservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.storage/storageaccounts/queueservices`|Azure実機|Log確認／Storage複製確認|—|
|`microsoft.storage/storageaccounts/tableservices`|Azure実機|Log確認／Storage複製確認|—|

Foundry project・SQLユーザーDB/master・Web/Function slotは要求56タイプの中に含めています。親だけで済ませず子IDも確認しましたが、タイプ数へ重ねて足していません。型別の件数・子スコープのID・根拠SHAは[出荷確認](RELEASE_CHECKS.json)に記録しています。

## 中断・再実行・Subごとの停止（V3）

削除前の全件照合がNGなら、どのSubも削除しない。削除開始後に異常が起きた場合は、そのSubの残りを止め、正常なSubを続けることを確認した。

|ID|行うこと|期待|実結果|
|---|---|---|---|
|C3-02|保存済み記録を引き継ぎ、3Subへ複製する|exit0。旧375件を残して複製|exit0、変更要求385|
|C3-04|3Subの新設定を確認する|exit0、変更要求0|exit0、変更要求0|
|C3-05|旧設定の収集項目を変え、削除前の確認で止まることを確かめる|exit1。全Subの削除0|exit1、変更要求0|
|C3-06|旧設定の収集項目を変え、切り戻し前の確認で止まることを確かめる|exit1。全Subの変更0|exit1、変更要求0|
|C3-07|旧設定を消す前にSub2だけ切り戻す|exit0。Sub2復元、他2Subは維持|exit0、変更要求5|
|C3-10|同じ記録で複製し直し、Sub2だけ再設定する|exit0。Sub2だけ再設定|exit0、変更要求5|
|C3-12|旧診断設定1件の削除完了後に、試験側からプロセスを止める|試験側が中断。旧設定の一部は削除済み|試験側から中断、変更要求8|
|C3-14|Sub1の旧設定を変え、Sub1を止めてSub2・Sub3の削除を続ける|exit1。Sub1停止、他2Subは削除を完了|exit1、変更要求170|
|C3-17|原因を元に戻し、同じ記録で未完了の削除だけ再実行する|exit0。未完了の197件だけ削除|exit0、変更要求197|
|C3-19|削除済みの同じ記録を再実行する|exit0、変更要求0|exit0、変更要求0|
|C3-20|診断設定を5件に埋め、Sub1だけの切り戻しを試す|exit1。Sub1の新設定を残す|exit1、変更要求68|
|C3-23|同じ上限エラーを残して全Subを切り戻す|exit1。Sub1を保護し、他2Subは完了|exit1、変更要求353|
|C3-26|追加した5件目を外し、同じ記録で切り戻し直す|exit0。旧375件が復元される|exit0、変更要求339|
|C3-28|切り戻し済みの同じ記録を再実行する|exit0、変更要求0|exit0、変更要求0|

中断・再実行を通した旧設定DELETEの成功IDは375件で、重複・対象外削除は0件。失敗したSubの新設定を残したこと、正常Subの旧設定を復元・読戻ししてから新設定を外したことも独立に確認した。最後は旧375設定と対象外35件を確認した。

## 対象の追加・DCR自身の診断設定（V4 Gap）

|ID|行うこと|実結果|
|---|---|---|
|G4-02|追加対象の旧設定がない時点で事前確認する|exit0、変更要求0|
|G4-03|事前確認後に追加した旧設定1件を、複製時に見つける|exit0、変更要求420|
|G4-05|追加1件を含む複製結果を確認する|exit0、変更要求0|
|G4-06|旧設定をもう1件追加し、新DCR自身の診断設定も外して確認する|exit1、変更要求0|
|G4-07|同じ2つの不足を残し、削除が変更0件で止まることを確認する|exit1、変更要求0|
|G4-08|同じ記録で旧対象を1件追記し、欠けたDCR自身の診断設定を修復する|exit0、変更要求2|
|G4-10|旧対象2件を追記・修復した結果を確認する|exit0、変更要求0|
|G4-11|追記した2件を含めて切り戻す|exit0、変更要求389|

2つの拒否では「記録後に増えた旧設定」と「別SubのDCR自身の診断不足」の両方がCSVへ出た。再複製のPUTは、追加対象の新診断と欠けたDCR自身の診断の2件だけ。追記前のBody・Before・Storage SKUを維持し、切り戻し後は追加した旧設定2件も除去した。

## 送信フラグ・再利用・LAW宛て全件移行（V4）

次の4回は、それぞれ事前確認→複製→確認→旧削除→切り戻しを実行した。複製後・削除後・切り戻し後は、別のGET処理で記録と比較した。

|試験|条件|確認できた結果|
|---|---|---|
|flagsA|Sub1：診断Storage・VM側なし。Sub2：両方None。Sub3：診断なし・VM側Log|作らない側の新送信設定を作らず、保存先を用意し、旧設定を最後に削除。切り戻しも完了|
|flagsB|Sub1：両方空欄。Sub2：診断Log・VM側なし。Sub3：両方None|空欄・Noneを含む指定どおりに処理。保護404件は不変|
|reuse|既存LAW30日、Event合計365日、Syslog継承30日、既存LRS・セキュリティ・Lifecycle2000日|再利用37件の値を維持。SystemAssignedのDCRと、準備時のDCR関連付けを作業前の値へ復元|
|allLog|旧375設定をすべてLAWへ移行。Firewallの旧診断だけを一時的にDedicatedへ変更|新診断373件・関連付け5件を照合し、旧375件を削除・復元。最後はFirewallを元のAzureDiagnosticsへ戻した|

allLogでは既知のKey Vault設定1件も別のBefore/Afterで保護した。旧375設定・対象外35件の確認へ、その1件を黙って含めたとは扱わない。

## 作業前に止める条件（V4 guards、Linux）

|ID|条件|期待と実結果|
|---|---|---|
|B4-01|既存診断4件：新設定を追加できる|exit0、変更要求0|
|B4-02|新診断設定と同じ名前がある|exit1、指定理由で拒否、変更要求0|
|B4-03|診断設定がすでに5件ある|exit1、指定理由で拒否、変更要求0|
|B4-04|作成予定のStorage名が他の場所で使用済み|exit1、指定理由で拒否、変更要求0|
|B4-05|既存RGの地域が指定と違う|exit1、指定理由で拒否、変更要求0|
|B4-06|既存LAWの地域が指定と違う|exit1、指定理由で拒否、変更要求0|
|B4-07|既存Storageの地域が指定と違う|exit1、指定理由で拒否、変更要求0|
|B4-08|Storage自身の診断を同じStorageへ送ろうとする|exit1、指定理由で拒否、変更要求0|
|B4-09|作業記録なしで確認を実行する|exit1、指定理由で拒否、変更要求0|
|B4-10|作業記録なしで削除を実行する|exit1、指定理由で拒否、変更要求0|
|B4-11|作業記録と環境設定が違う|exit1、指定理由で拒否、変更要求0|
|B4-12|作業記録とCSVが違う|exit1、指定理由で拒否、変更要求0|
|B4-13|変更前の作業記録を保存できない|exit1、指定理由で拒否、変更要求0|

名前確認のPOST 5回は読取り用APIで、リソースの変更要求とは分けて記録した。条件作成に使った診断設定3件は復旧済み。準備用のRG3件・SA2件・地域違いのLAW1件も、後片付けで削除済み。

## 切り戻し2パターンの実証

|開始時点|実機証拠|結果|
|---|---|---|
|旧設定を削除する前|V4 Gap：複製・不足修復後にRollback。Deleteの拒否時は変更要求0|旧設定を維持し、新設定を作業前へ戻した。追加した旧設定2件も除去|
|旧設定をすべて削除した後|V4 allLog：旧375件の不在をGETで確認してからRollback|旧375件を復元。保存先を残し、新送信設定を作業前へ戻した|

V3 Coreは削除中断→削除再開→全削除後の切り戻しである。「削除途中から直ちにRollbackした」とは記載しない。旧V2の途中削除・切り戻し記録は別版の履歴として保持している。

## 最後の正常通し

同じ3Subに対して、リソース作成から旧設定削除まで順に実行しました。既存の試験対象375件に新規12件を加え、別名の既存診断には触れていません。

|順序|確認したこと|実結果|
|---|---|---|
|1. リソースを作成|6タイプ・親8件、Storage子を含む12対象を作成・取得|Deploy/Capture各1回で成功。作成前の親8件とRG2件は不在を確認|
|2. 事前確認|Storageが未登録のSub2を含め、名前・リージョン等を確認|PASS。Sub2の登録要求は1回、名前確認成功。後のCopyでは登録要求0回|
|3. 複製|旧387件の項目を引き継ぎ、新設定と保存先を用意|PASS。独立GETでも新401件と保存先・付属設定40件を確認|
|4. 確認|削除する前に新旧の設定値を照合|PASS。旧設定は残したまま新設定の一致を確認|
|5. 旧設定を削除|旧387件だけを削除|PASS。独立GETで387件すべて不在、対象外35件と既知Key Vault設定1件の保持を確認|

4本の製品スクリプトと2回の独立GET確認がすべて成功しました。最後の正常通しでは切り戻しを実行せず、移行後の状態を追加step4で確認しました。

## 追加step4の実機確認

正常移行後の作業フォルダを別フォルダへコピーし、追加step4を1回実行しました。旧設定387件の不在、新設定401件、保存先と付属設定40件の計828行がすべてOKでした。

Azure呼出しはGET1503回のみで、書込みは0件です。元のフォルダと確認用コピーの既存13ファイルが不変で、そのうち正本6本・CSV・作業記録など11ファイルを保護対象としても照合しました。480.287秒には、フォルダのコピーと結果CSV・ハッシュの照合を含みます。

## 失敗表示の扱い

- 想定した拒否は、V3で5起動、V4 Gapで2起動、guardsで12起動。いずれも期待した`exit1`。
- V3の強制中断1回は試験操作であり、製品の想定外停止へ数えない。
- Fresh factoryはWindows PS7のDeploy/Capture本体がexit0。その後の私有PS5コントローラーが非対応構文でexit1となった原記録を保持した。回収だけを復旧し、Deploy/Captureをやり直したことにはしていない。
- 追加step4の初回起動要求は、VMの管理コマンド上限で拒否された。製品の実行は0回で、所有する過去の管理情報1件だけを削除してから実行した。製品コードや起動コードは変更していない。
- 過去版の失敗やローカルの合成検証を、この一覧の実機成功へ加算していない。

## まだ完了していないもの

|対象|現在の扱い|
|---|---|
|環境全撤去|3SubともRG・リソース0件、元の管理構造・権限・ポリシーは復元済み。利用登録は36/37件完了で、Sub3のMicrosoft.NetworkだけUnregistering|

## 実機ケースの裏付け

実行レコードのファイル名、期待/実exit、summaryのSHA、実測秒数は[出荷確認](RELEASE_CHECKS.json)に記録します。製品の試験起動、独立GET確認、factory作成・取得は分けて数えています。異なるケース数やリソース数として合算しません。Delete内部の確認はDeleteの起動に含みます。性能比較や本番100Subへの換算はしていません。

各完了receiptと独立確認のSHAも[出荷確認](RELEASE_CHECKS.json)に記載します。

## 正本V4のローカル試験：112ケース

PowerShell 7.5.4で、112ケース・2,024判定が成功しました。下表の合計は2,012判定で、残り12判定は構文と実行前後のコード不変の確認です。Azureへの通信は0件です。失敗を与えるケースのPASSは、その失敗を検出して誤った上書き・削除を防いだことを表します。

|確認した処理|判定数|結果|
|---|---:|---|
|StorageとVM: 全工程・再実行・切戻し|137|PASS|
|LogとVM: 全工程・再実行・切戻し|137|PASS|
|Storageのみ: 全工程・再実行・切戻し|121|PASS|
|Logのみ: 全工程・再実行・切戻し|121|PASS|
|VMのみ: 全工程・再実行・切戻し|111|PASS|
|診断空欄とVM: 全工程・再実行・切戻し|111|PASS|
|両方None: 全工程・再実行・切戻し|107|PASS|
|両方空欄: 全工程・再実行・切戻し|107|PASS|
|Storage宛GETのLog Analytics既定方式付加を許容して再実行・削除・復元できる|14|PASS|
|Log Analytics宛の格納方式変更は許容せず既存設定を保持する|10|PASS|
|CSV列欠落は空欄と区別して書込み前に停止する|24|PASS|
|対象0件でも東日本StorageとLog Analyticsを準備する|10|PASS|
|旧DCR関連なしでもEvent・Syslogは1095日保持し、新DCRは作らない|39|PASS|
|東日本・西日本・globalの地域別Storageへ送信する|7|PASS|
|Canadaの旧設定と新Log Analytics自身を地域別Storageへ送り、削除後も確認する|7|PASS|
|Storage kind=StorageV2 の子スコープを探索|3|PASS|
|Storage kind=BlobStorage の子スコープを探索|3|PASS|
|Storage kind=BlockBlobStorage の子スコープを探索|3|PASS|
|Storage kind=FileStorage の子スコープを探索|3|PASS|
|通常一覧にないRedis子DBを親地域のStorageへ移行・復元する|12|PASS|
|RedisのDB一覧が空なら存在しない子を調べない|4|PASS|
|Redis子DBと通常一覧の次ページを両方移行・復元する|15|PASS|
|CSV入力拒否: 不正診断フラグ|2|PASS|
|CSV入力拒否: 不正VMフラグ|2|PASS|
|CSV入力拒否: 空RG|2|PASS|
|CSV入力拒否: 空Workspace|2|PASS|
|CSV入力拒否: 不正Storage名|2|PASS|
|CSV入力拒否: jpeが2か所|2|PASS|
|CSV入力拒否: Storage名25文字|2|PASS|
|CSV入力拒否: 空Sub|2|PASS|
|作業前からある同地域の保存先は、設定値を変更せず全工程で再利用する|51|PASS|
|別スコープで使われているStorage名は事前停止する|2|PASS|
|ZRS・LRSの両方が非対応の地域を事前停止する|2|PASS|
|初回の同名新診断を再利用しない|2|PASS|
|新診断を追加する空き5枠上限を事前停止する|2|PASS|
|両Noneは同名新診断と5件上限に触れない|4|PASS|
|関係のないVM・VMSSには新関連を作らない|2|PASS|
|Storage ACL・Log Analytics features・分析保持・他ルールを維持する|13|PASS|
|既存Storageの不変条件が違う場合は上書きしない|3|PASS|
|既存newDCRと関連は切戻しでBeforeへ復元する|9|PASS|
|copy途中失敗から未完了だけを再開する|10|PASS|
|記録保存に失敗したSubはAzure変更を始めない|2|PASS|
|作業途中CSV選択変更を拒否: copy|5|PASS|
|作業途中CSV選択変更を拒否: verify|5|PASS|
|作業途中CSV選択変更を拒否: delete|5|PASS|
|後続Subの未完了は全Subの旧DELETEを止める|8|PASS|
|旧削除の途中失敗は失敗Subの後続だけを止め再実行できる|26|PASS|
|診断削除の失敗では同じSubの後続を止め、ほかのSubの診断は削除する|10|PASS|
|複数Subで削除が失敗しても各Subを一度だけ記録し、残りの診断は削除しない|9|PASS|
|全件確認を通過した直後の旧設定変更でも失敗Subの残りだけを止める|8|PASS|
|全件確認を通過した直後の新設定欠落でも失敗Subの旧設定を保持する|8|PASS|
|copy後に増えた旧対象をverify/deleteが無視しない|4|PASS|
|削除直前に旧設定が変われば以降の削除を止める|6|PASS|
|指定Subだけを切り戻し、他Subはそのまま残す|9|PASS|
|不明Sub指定のrollbackは変更前に拒否する|3|PASS|
|旧Association 復元失敗はそのSubの新設定を残し、他Sub完了後に再実行できる|34|PASS|
|旧Diagnostic 復元失敗はそのSubの新設定を残し、他Sub完了後に再実行できる|37|PASS|
|新設定の取消失敗はそのSubだけ停止し、他Sub完了後に未完了だけ再実行する|20|PASS|
|既存DCRのBefore復元失敗後も他Subを戻し、再実行で元のDCRと関連へ戻る|16|PASS|
|複数Subの復元失敗を全件CSVへ記録し、原因解消後に再実行できる|12|PASS|
|切戻し対象が外部変更されたら上書きしない|3|PASS|
|保存先GET失敗を未存在と扱わず削除前に停止する|4|PASS|
|書込み後の期待値不一致を失敗一覧に出す|4|PASS|
|接続断・本文切断・通信timeoutから同じ要求で復旧する|24|PASS|
|通信断が続けば最大4回で止まり旧設定を残す|4|PASS|
|TLS・明示中断・非通信IO・JSON不正を再試行しない|17|PASS|
|429・503はRetryAfterを守って従来どおり再試行する|6|PASS|
|DELETE応答喪失後の404だけを削除済みとして継続する|10|PASS|
|Wait付きPUTは1回だけ送信し以後はBody無しGETで待つ|4|PASS|
|作成待ちのFailed・Canceledは即停止する|7|PASS|
|対応IWRだけ本文timeoutを設定し未対応環境へ余計なparameterを送らない|2|PASS|
|一時的な401は認証を更新して再試行する|3|PASS|
|Storage以外の未登録providerは記録保存後に登録する|4|PASS|
|旧診断名と新診断名が同じでもNone側は旧を削除・復元する|5|PASS|
|指定2DCRでも対象外Subの関連を変更しない|5|PASS|
|未知の地域略称は事前確認で停止する|2|PASS|
|対応する既存Waiverは切戻しでも保持する|5|PASS|
|内容の違う既存Waiverを上書きしない|3|PASS|
|コピー途中の失敗状態から直接切り戻せる|15|PASS|
|コピー完了後は旧設定を書き直さず切り戻せる|7|PASS|
|旧設定を一部削除した失敗状態から直接切り戻せる|9|PASS|
|DCR更新中の応答を待って完了を確認する|4|PASS|
|StorageのResolvingDnsを待って設定を完了する|6|PASS|
|Log AnalyticsのProvisioningを待って設定を完了する|6|PASS|
|保存先の作成待ちは5分を超えても成功までGETだけで待つ|6|PASS|
|総保持が1095でも既定値フラグのままなら明示設定する|7|PASS|
|変更前記録がなければ確認と削除を開始しない|3|PASS|
|通常一覧にある主要タイプと子IDを同じ診断処理へ通す|13|PASS|
|DCRのInvalidOutputTableだけは反映を待って再試行する|4|PASS|
|組み込みSyslogの反映遅延が5分を超えてもDCRを完了する|3|PASS|
|custom tableのInvalidOutputTableを反映待ちと誤認しない|8|PASS|
|DCRの一般400は再試行せずそのSubを止める|5|PASS|
|新診断の余分なWorkspaceとEventHubを許容しない|9|PASS|
|既存DCRへの余分な収集源追加を許容せず切戻しも上書きしない|6|PASS|
|未選択Subの記録JSONが壊れていても指定Subだけを切り戻せる|7|PASS|
|実runspaceで5件以上の診断GETとPUTを処理する|17|PASS|
|並列worker1件の失敗を記録し再実行で欠落だけを補う|20|PASS|
|既存DCRのIdentity[SystemAssigned]を維持して全工程と切戻しを行う|12|PASS|
|既存DCRのIdentity[None]を維持して全工程と切戻しを行う|12|PASS|
|既存DCRのIdentity[SystemAssigned, UserAssigned]を維持して全工程と切戻しを行う|23|PASS|
|西日本だけに旧設定があっても、新Log Analytics自身用の東日本Storageを事前確認して作る|27|PASS|
|Log Analytics 自身の診断の欠落は再開で補い、値の違いは削除前に停止する|33|PASS|
|DCR 自身の診断の欠落は再開で補い、値の違いは削除前に停止する|33|PASS|
|Log Analytics に旧ポリシーの診断が追加されても、自身の新診断を二重に作らない|18|PASS|
|DCR に旧ポリシーの診断が追加されても、自身の新診断を二重に作らない|18|PASS|
|既存RG・Log Analytics・Storageの地域が違う場合は、Azure変更前に停止する|15|PASS|
|再利用Storage本体と子サービスの診断を同じStorage自身へ送る指定は事前停止する|8|PASS|
|Storageの事前登録は名前確認より前に行い、後段NGでも登録を保持する|29|PASS|
|Storageの事前登録が進行中なら再要求せず完了を待つ|7|PASS|
|Storageの事前登録に失敗した場合と不明な登録状態は名前確認へ進まない|20|PASS|
|Storageの事前登録は保存先不要と既存再利用の場合には行わない|13|PASS|
|ZRS非対応のwestusはLRSを使い、再実行でも記録した冗長性を変えない|28|PASS|

この一覧は今回のローカル試験の実結果から作成したものです。以前の101ケース・1,639判定の結果は当時の記録として保持し、今回の件数へ加算しません。実行した正本のSHAと結果JSONのSHAは[出荷確認](RELEASE_CHECKS.json)を参照してください。

## 追加step4のローカル試験：50ケース

`step4_final_check.ps1`は、既存6本を変えずに追加した確認用スクリプトです。commitは`c1c9dc892646fce64a842bc369174ffb7dc34448`、SHA256は`077df80783991048bb7f9fba55304838dff959e10a67ceec160a720dcf45924b`です。

LinuxのPowerShell 7.5.4で50ケース・560判定が成功しました。通信と旧設定の探索だけを試験用に置き換え、設定値の比較と作業記録の検査には実際のcommon.ps1を使いました。試験用の通信1,772件はすべてGETで、作業記録のバイト列も変わっていません。Azureへの通信は0件です。

この50ケースを既存6本の112ケースに足して、実機での実施件数とは数えません。最後の正常移行後のWindows・Azure実機確認は、上記の別結果として記録しています。

## 以前の再生試験：101ケース

以下は2026-11-26時点の結果です。現在版の112ケースとは別の記録であり、件数を合算しません。当時の本文を変更せず残しています。

<details>
<summary>当時のケース一覧を開く</summary>

# 移行スクリプトの再生試験：101ケース

Storageの事前登録と地域別ZRS・LRS選択を追加した`migration/`をPowerShell 7.5.4で実行し、101ケース・1,639判定が成功しました。Azureへの通信は試験用の応答に置き換えています。1,627判定が各ケースの確認で、残り12判定が構文と実行前後のコード不変の確認です。

異常ケースのPASSは、指定した異常を検出し、削除や上書きを止められたことを表します。既存ケースのIDを引き継ぎ、追加ケースを末尾に載せています。実行順を示す番号ではありません。

|ID|ケース|判定数|結果|
|---|---|---:|---|
|PROC-001|StorageとVM: 全工程・再実行・切戻し|122|PASS|
|PROC-002|LogとVM: 全工程・再実行・切戻し|122|PASS|
|PROC-003|Storageのみ: 全工程・再実行・切戻し|118|PASS|
|PROC-004|Logのみ: 全工程・再実行・切戻し|118|PASS|
|PROC-005|VMのみ: 全工程・再実行・切戻し|108|PASS|
|PROC-006|両方None: 全工程・再実行・切戻し|104|PASS|
|PROC-007|両方空欄: 全工程・再実行・切戻し|104|PASS|
|PROC-008|Storage宛GETのLAW既定方式付加を許容して再実行・削除・復元できる|14|PASS|
|PROC-009|LAW宛の格納方式変更は許容せず既存設定を保持する|10|PASS|
|PROC-010|CSV列欠落は空欄と区別して書込み前に停止する|24|PASS|
|PROC-011|対象0件でも東日本StorageとLAWを準備する|10|PASS|
|PROC-012|東日本・西日本・globalの地域別Storageへ送信する|6|PASS|
|PROC-013|Canadaの旧設定と新LAW自身を地域別Storageへ送り、削除後も確認する|7|PASS|
|PROC-014|Storage kind=StorageV2 の子スコープを探索|3|PASS|
|PROC-015|Storage kind=BlobStorage の子スコープを探索|3|PASS|
|PROC-016|Storage kind=BlockBlobStorage の子スコープを探索|3|PASS|
|PROC-017|Storage kind=FileStorage の子スコープを探索|3|PASS|
|PROC-018|通常一覧にないRedis子DBを親地域のStorageへ移行・復元する|12|PASS|
|PROC-019|RedisのDB一覧が空なら存在しない子を調べない|4|PASS|
|PROC-020|Redis子DBと通常一覧の次ページを両方移行・復元する|15|PASS|
|PROC-021|CSV入力拒否: 不正診断フラグ|2|PASS|
|PROC-022|CSV入力拒否: 不正VMフラグ|2|PASS|
|PROC-023|CSV入力拒否: 空RG|2|PASS|
|PROC-024|CSV入力拒否: 空Workspace|2|PASS|
|PROC-025|CSV入力拒否: 不正Storage名|2|PASS|
|PROC-026|CSV入力拒否: jpeが2か所|2|PASS|
|PROC-027|CSV入力拒否: Storage名25文字|2|PASS|
|PROC-028|CSV入力拒否: 空Sub|2|PASS|
|PROC-029|作業前からある同地域の保存先は、設定値を変更せず全工程で再利用する|51|PASS|
|PROC-030|別スコープで使われているStorage名は事前停止する|2|PASS|
|PROC-031|ZRS・LRSの両方が非対応の地域を事前停止する|2|PASS|
|PROC-032|初回の同名新診断を再利用しない|2|PASS|
|PROC-033|新診断を追加する空き5枠上限を事前停止する|2|PASS|
|PROC-034|両Noneは同名新診断と5件上限に触れない|4|PASS|
|PROC-035|関係のないVM・VMSSには新関連を作らない|2|PASS|
|PROC-036|Storage ACL・LAW features・分析保持・他ルールを維持する|13|PASS|
|PROC-037|既存Storageの不変条件が違う場合は上書きしない|3|PASS|
|PROC-038|既存newDCRと関連は切戻しでBeforeへ復元する|9|PASS|
|PROC-039|copy途中失敗から未完了だけを再開する|10|PASS|
|PROC-040|記録保存に失敗したSubはAzure変更を始めない|2|PASS|
|PROC-041|作業途中CSV選択変更を拒否: copy|5|PASS|
|PROC-042|作業途中CSV選択変更を拒否: verify|5|PASS|
|PROC-043|作業途中CSV選択変更を拒否: delete|5|PASS|
|PROC-044|後続Subの未完了は全Subの旧DELETEを止める|7|PASS|
|PROC-045|旧削除の途中失敗は後続を止め再実行できる|9|PASS|
|PROC-046|copy後に増えた旧対象をverify/deleteが無視しない|4|PASS|
|PROC-047|削除直前に旧設定が変われば以降の削除を止める|3|PASS|
|PROC-048|指定Subだけを切り戻し、他Subはそのまま残す|9|PASS|
|PROC-049|不明Sub指定のrollbackは変更前に拒否する|3|PASS|
|PROC-050|旧復元失敗時は新診断設定を残す|6|PASS|
|PROC-051|切戻し対象が外部変更されたら上書きしない|3|PASS|
|PROC-052|保存先GET失敗を未存在と扱わず削除前に停止する|4|PASS|
|PROC-053|書込み後の期待値不一致を失敗一覧に出す|4|PASS|
|PROC-054|接続断・本文切断・通信timeoutから同じ要求で復旧する|24|PASS|
|PROC-055|通信断が続けば最大4回で止まり旧設定を残す|4|PASS|
|PROC-056|TLS・明示中断・非通信IO・JSON不正を再試行しない|17|PASS|
|PROC-057|429・503はRetryAfterを守って従来どおり再試行する|6|PASS|
|PROC-058|DELETE応答喪失後の404だけを削除済みとして継続する|10|PASS|
|PROC-059|Wait付きPUTは1回だけ送信し以後はBody無しGETで待つ|4|PASS|
|PROC-060|作成待ちのFailed・Canceledは即停止する|7|PASS|
|PROC-061|対応IWRだけ本文timeoutを設定し未対応環境へ余計なparameterを送らない|2|PASS|
|PROC-062|一時的な401は認証を更新して再試行する|3|PASS|
|PROC-063|Storage以外の未登録providerは記録保存後に登録する|4|PASS|
|PROC-064|旧診断名と新診断名が同じでもNone側は旧を削除・復元する|5|PASS|
|PROC-065|指定2DCRでも対象外Subの関連を変更しない|5|PASS|
|PROC-066|未知の地域略称は事前確認で停止する|2|PASS|
|PROC-067|対応する既存Waiverは切戻しでも保持する|5|PASS|
|PROC-068|内容の違う既存Waiverを上書きしない|3|PASS|
|PROC-069|コピー途中の失敗状態から直接切り戻せる|13|PASS|
|PROC-070|コピー完了後は旧設定を書き直さず切り戻せる|7|PASS|
|PROC-071|旧設定を一部削除した失敗状態から直接切り戻せる|9|PASS|
|PROC-072|DCR更新中の応答を待って完了を確認する|4|PASS|
|PROC-073|StorageのResolvingDnsを待って設定を完了する|6|PASS|
|PROC-074|LAWのProvisioningを待って設定を完了する|6|PASS|
|PROC-075|保存先の作成待ちは5分を超えても成功までGETだけで待つ|6|PASS|
|PROC-076|総保持が1095でも既定値フラグのままなら明示設定する|7|PASS|
|PROC-077|変更前記録がなければ確認と削除を開始しない|3|PASS|
|PROC-078|通常一覧にある主要タイプと子IDを同じ診断処理へ通す|13|PASS|
|PROC-079|DCRのInvalidOutputTableだけは反映を待って再試行する|4|PASS|
|PROC-080|組み込みSyslogの反映遅延が5分を超えてもDCRを完了する|3|PASS|
|PROC-081|custom tableのInvalidOutputTableを反映待ちと誤認しない|8|PASS|
|PROC-082|DCRの一般400は再試行せずそのSubを止める|5|PASS|
|PROC-083|新診断の余分なWorkspaceとEventHubを許容しない|9|PASS|
|PROC-084|既存DCRへの余分な収集源追加を許容せず切戻しも上書きしない|6|PASS|
|PROC-085|未選択Subの記録JSONが壊れていても指定Subだけを切り戻せる|7|PASS|
|PROC-086|実runspaceで5件以上の診断GETとPUTを処理する|16|PASS|
|PROC-087|並列worker1件の失敗を記録し再実行で欠落だけを補う|20|PASS|
|PROC-088|既存DCRのIdentity[SystemAssigned]を維持して全工程と切戻しを行う|12|PASS|
|PROC-089|既存DCRのIdentity[None]を維持して全工程と切戻しを行う|12|PASS|
|PROC-090|既存DCRのIdentity[SystemAssigned, UserAssigned]を維持して全工程と切戻しを行う|23|PASS|
|PROC-091|旧DCR関連なしでもEvent・Syslogは1095日保持し、新DCRは作らない|37|PASS|
|PROC-092|西日本だけに旧設定があっても、新LAW自身用の東日本Storageを事前確認して作る|27|PASS|
|PROC-093|新LAW自身の診断の欠落は再開で補い、値の違いは削除前に停止する|33|PASS|
|PROC-094|新LAWに旧ポリシーの診断が追加されても、自身の新診断を二重に作らない|15|PASS|
|PROC-095|既存RG・LAW・Storageの地域が違う場合は、Azure変更前に停止する|15|PASS|
|PROC-096|再利用Storage本体と子サービスの診断を同じStorage自身へ送る指定は事前停止する|8|PASS|
|PROC-097|Storageの事前登録は名前確認より前に行い、後段NGでも登録を保持する|29|PASS|
|PROC-098|Storageの事前登録が進行中なら再要求せず完了を待つ|7|PASS|
|PROC-099|Storageの事前登録に失敗した場合と不明な登録状態は名前確認へ進まない|20|PASS|
|PROC-100|Storageの事前登録は保存先不要と既存再利用の場合には行わない|13|PASS|
|PROC-101|ZRS非対応のwestusはLRSを使い、再実行でも記録した冗長性を変えない|28|PASS|

[全結果と実行コードのSHA](STORAGE_REGISTRATION_REDUNDANCY.json) / [検証結果の概要](REPORT.md)

</details>
