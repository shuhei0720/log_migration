# 現行136ケース一覧

2026-11-19 JST時点。対象は現在のcopy-first版マニフェスト `607e39695c328189aae8d39b1bc0dd9d258c8599d4e78d9b1be941a50cc53c7d` です。

|分類|正式ケース数|判定数|
|---|---:|---:|
|保存先・保持・再実行|33|163|
|Lifecycle送信本文|6|39|
|バックアップ・切戻し|50|326|
|旧DCR・VMSS切替|47|355|
|正式ケース合計|136|883|
|共通・入力・API／JSON・標準ジョブ・工程連携の基本判定|ケース数へ加算しない|275|
|4系統の接続判定|ケース数へ加算しない|4|
|全判定合計|136|1,162|

Linux PowerShell 7.5.4と実Windows PowerShell 5.1.20348.5773 Desktopで、同じ凍結版の136ケース・1,162判定が成功しています。Native報告は20ファイルの前後hash一致・Azure通信0を記録しています。この一覧はオフライン試験の一覧です。Azure実機の主要8条件・補助再開ケースは、別の実行結果として追加します。

## 判定根拠の読み方

- **個別JSON**：バックアップ50件とDCR47件は、保存済みLinux個別結果JSONの各PASS・個別判定数に基づきます。同じ版のNative総合PASSも確認しています。
- **総合＋ソース**：保存先33件とLifecycle6件は、個別結果JSONが保存されていません。凍結版ソースからケース名と繰り返し条件を厳密に取り出し、Native総合PASSと各系統の件数一致を根拠にしています。個別JSONを復元したものとは扱いません。CSVの個別判定数は空欄です。
- 種別は入力パターンを示すレビュー用の編集分類です。複合ケースは「正常・異常混合」等で示しています。
- **PASSは期待した動作を確認できたという意味です。異常入力で期待どおり停止し、未完了一覧を出せた場合もPASSです。**

[CSV](CURRENT_FORMAL_CASES.csv)には原典ケース名、判定根拠、証跡ファイル、SourceLineを記載しています。136件へ基本275判定や接続4判定をケースとして追加していません。旧版のケースCSVは変更していません。

分類のうち、不足・未設定・総保持不一致・入力欠損・外部変更などの検知は「異常」側へ整理しています。BASE-005は正常確認・VMSS関連の欠損検知・不足補完の3経路を実際に含むため、混合のままです。

## 保存先・保持・再実行

|CaseID|ケース|種別|根拠|SourceLine|
|---|---|---|---|---|
|BASE-001|実ARM応答の全一致VerifyOnly|正常|総合＋ソース|tests/baseline-smoke.ps1:205|
|BASE-002|実ARM応答の全一致Copy再実行|正常|総合＋ソース|tests/baseline-smoke.ps1:215|
|BASE-003|Blob不足の読取専用検知と手動対応情報|異常検知|総合＋ソース|tests/baseline-smoke.ps1:221|
|BASE-004|Blob不足だけ補完し再実行を省略|正常|総合＋ソース|tests/baseline-smoke.ps1:231|
|BASE-005|旧DCR関連のあるVMSSも同じ新DCRの確認・補完対象|正常・異常混合|総合＋ソース|tests/baseline-smoke.ps1:240|
|BASE-006|関連付けPUTのUpdating完了後も参照先を再確認-Expected|境界（非同期完了）|総合＋ソース|tests/baseline-smoke.ps1:262|
|BASE-007|関連付けPUTのUpdating完了後も参照先を再確認-Foreign|異常|総合＋ソース|tests/baseline-smoke.ps1:262|
|BASE-008|Storage基礎構成の不一致は上書きしない|異常|総合＋ソース|tests/baseline-smoke.ps1:278|
|BASE-009|既存Policy除外の不一致は他の作業を開始しない|異常|総合＋ソース|tests/baseline-smoke.ps1:286|
|BASE-010|LA保持期間だけ補完し他featureを保持|正常|総合＋ソース|tests/baseline-smoke.ps1:294|
|BASE-011|Lifecycle自分のルールだけ補完し他ルール保持|正常|総合＋ソース|tests/baseline-smoke.ps1:303|
|BASE-012|Lifecycle未作成404から有効な1ルールだけ作成|境界|総合＋ソース|tests/baseline-smoke.ps1:315|
|BASE-013|DCR不足だけ補完し再実行を省略|正常|総合＋ソース|tests/baseline-smoke.ps1:328|
|BASE-014|読み戻しが一致しなければ失敗を返す|異常|総合＋ソース|tests/baseline-smoke.ps1:337|
|BASE-015|LA不足時もVerifyOnlyはVM後続項目を確認|異常検知|総合＋ソース|tests/baseline-smoke.ps1:346|
|BASE-016|StorageのCreatingはVerifyOnlyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-017|StorageのCreatingはCopyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-018|LAのUpdatingはVerifyOnlyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-019|LAのUpdatingはCopyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-020|DCRのUpdatingはVerifyOnlyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-021|DCRのUpdatingはCopyでも変更しない|異常|総合＋ソース|tests/baseline-smoke.ps1:362|
|BASE-022|Storage未設定の手動CSVへmutable期待値も出す|異常検知|総合＋ソース|tests/baseline-smoke.ps1:371|
|BASE-023|Storagemutable補完でも個別ネットワーク規則を保持|正常|総合＋ソース|tests/baseline-smoke.ps1:385|
|BASE-024|EventとSyslogの総保持90だけを1095へ補完し他の設定を保持|正常|総合＋ソース|tests/baseline-smoke.ps1:398|
|BASE-025|分析保持365でも総保持が未指定なら確認NGと設定補完|正常・異常混合|総合＋ソース|tests/baseline-smoke.ps1:429|
|BASE-026|EventとSyslogの新規作成は総保持1095を指定し完了後にDCRを作成|境界（未作成・非同期）|総合＋ソース|tests/baseline-smoke.ps1:441|
|BASE-027|総保持PATCHの読み戻し不一致ではDCRと関連作成を開始しない|異常|総合＋ソース|tests/baseline-smoke.ps1:460|
|BASE-028|確認版はEventとSyslogの総保持90を変更せず全件NGにする|異常検知|総合＋ソース|tests/baseline-smoke.ps1:472|
|BASE-029|総保持1095のPATCHが拒否されても元の分析保持と設定を維持|異常|総合＋ソース|tests/baseline-smoke.ps1:482|
|BASE-030|継承した総保持365を明示1095へ変更し読取り専用フラグは送らない|正常・異常混合|総合＋ソース|tests/baseline-smoke.ps1:496|
|BASE-031|総保持1095でAsDefaultが省略またはnullなら変更せず確認できる|境界|総合＋ソース|tests/baseline-smoke.ps1:510|
|BASE-032|旧365管理ルールだけ1095へ置換し他名ルールの365設定を保持|正常|総合＋ソース|tests/baseline-smoke.ps1:520|
|BASE-033|正しい1095管理ルールがあっても併存する旧365管理ルールを除去|正常・異常混合|総合＋ソース|tests/baseline-smoke.ps1:539|

## Lifecycle送信本文

|CaseID|ケース|種別|根拠|SourceLine|
|---|---|---|---|---|
|LC-001|Lifecycleポリシー未作成404から有効な1095日ルールを作成|境界|総合＋ソース|tests/lifecycle-request-replay.ps1:64|
|LC-002|Lifecycleの空ルール一覧から有効な1095日ルールを作成|境界|総合＋ソース|tests/lifecycle-request-replay.ps1:64|
|LC-003|他名ルールを完全保持して1095日管理ルールを追加|正常|総合＋ソース|tests/lifecycle-request-replay.ps1:64|
|LC-004|不一致の1095日管理ルールを補完し他名ルールを完全保持|正常（補完・移行）|総合＋ソース|tests/lifecycle-request-replay.ps1:64|
|LC-005|旧365日管理ルールを除去して1095日へ置換・他名ルール保持|正常（補完・移行）|総合＋ソース|tests/lifecycle-request-replay.ps1:64|
|LC-006|正しい1095日管理ルールが存在しても併存する旧365日を除去|正常（補完・移行）|総合＋ソース|tests/lifecycle-request-replay.ps1:64|

## バックアップ・切戻し

|CaseID|ケース|種別|根拠|SourceLine|
|---|---|---|---|---|
|BACKUP-001|①が実際の書込みより前に元の最小バックアップを保存|正常|個別JSON|tests/backup-rollback-smoke.ps1:444|
|BACKUP-002|HashtableとPSCustomObjectの旧関連を保存して同じ内容で読める|正常|個別JSON|tests/backup-rollback-smoke.ps1:464|
|BACKUP-003|PSCustomObject前値を実ARM serializerへ渡せる|正常|個別JSON|tests/backup-rollback-smoke.ps1:487|
|BACKUP-004|DCR自体が診断対象でもsnapshotとの併用を許可|正常|個別JSON|tests/backup-rollback-smoke.ps1:502|
|BACKUP-005|事前チェックは既存の①バックアップを読まず独立して確認する|正常|個別JSON|tests/backup-rollback-smoke.ps1:519|
|BACKUP-006|①の再実行は保存済みBeforeとファイルを変更しない|正常|個別JSON|tests/backup-rollback-smoke.ps1:530|
|BACKUP-007|VM・診断対象0のbackupは空配列を維持|境界|個別JSON|tests/backup-rollback-smoke.ps1:539|
|BACKUP-008|①はバックアップが無い初回にも変更前保存から開始する|正常|個別JSON|tests/backup-rollback-smoke.ps1:552|
|BACKUP-009|backup無しのdelete は変更前に停止|異常（入力不足）|個別JSON|tests/backup-rollback-smoke.ps1:559|
|BACKUP-010|backup無しのverify は変更前に停止|異常（入力不足）|個別JSON|tests/backup-rollback-smoke.ps1:559|
|BACKUP-011|backup不正Version はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-012|backup不正Environment はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-013|backup不正TargetWorkspaceId はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-014|backup不正NewDiagnosticSettingName はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-015|backup不正DuplicateTarget はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-016|backup不正DuplicateDiagnostic はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-017|backup不正WrongSubResource はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-018|backup不正EmptyAfter はlocalで拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:566|
|BACKUP-019|壊れたJSONとCSV宛先差分を拒否|異常|個別JSON|tests/backup-rollback-smoke.ps1:583|
|BACKUP-020|CSVの正しいSub部分集合を許可しアクセス対象外Subは拒否|正常・異常混合|個別JSON|tests/backup-rollback-smoke.ps1:595|
|BACKUP-021|未実施状態のrollbackは全てskip|境界|個別JSON|tests/backup-rollback-smoke.ps1:610|
|BACKUP-022|全削除後のrollbackは旧全復元後だけ新を削除|正常|個別JSON|tests/backup-rollback-smoke.ps1:617|
|BACKUP-023|複製途中のrollbackは存在する新設定だけ除去|境界・復旧|個別JSON|tests/backup-rollback-smoke.ps1:636|
|BACKUP-024|サブスクリプション部分選択で他Subを保持|正常|個別JSON|tests/backup-rollback-smoke.ps1:645|
|BACKUP-025|存在しないSub指定は変更0|異常（対象外指定）|個別JSON|tests/backup-rollback-smoke.ps1:652|
|BACKUP-026|明示empty-arrayのSub指定は全体へ広げない|境界・異常|個別JSON|tests/backup-rollback-smoke.ps1:660|
|BACKUP-027|明示nullのSub指定は全体へ広げない|境界・異常|個別JSON|tests/backup-rollback-smoke.ps1:660|
|BACKUP-028|明示empty-stringのSub指定は全体へ広げない|境界・異常|個別JSON|tests/backup-rollback-smoke.ps1:660|
|BACKUP-029|明示whitespaceのSub指定は全体へ広げない|境界・異常|個別JSON|tests/backup-rollback-smoke.ps1:660|
|BACKUP-030|後続Sub/設定のOld 不一致は全復元前に停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:669|
|BACKUP-031|後続Sub/設定のNew 不一致は全復元前に停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:669|
|BACKUP-032|後続Sub/設定のDcr 不一致は全復元前に停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:669|
|BACKUP-033|後続Sub/設定のAssociation 不一致は全復元前に停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:669|
|BACKUP-034|旧復元用の空きが無ければ新を消さず停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:684|
|BACKUP-035|復元OldPut 失敗時は新診断DELETE0|異常|個別JSON|tests/backup-rollback-smoke.ps1:694|
|BACKUP-036|復元Readback 失敗時は新診断DELETE0|異常|個別JSON|tests/backup-rollback-smoke.ps1:694|
|BACKUP-037|復元DcrPut 失敗時は新診断DELETE0|異常|個別JSON|tests/backup-rollback-smoke.ps1:694|
|BACKUP-038|復元AssociationPut 失敗時は新診断DELETE0|異常|個別JSON|tests/backup-rollback-smoke.ps1:694|
|BACKUP-039|DCR復元がUpdatingなら新診断を削除しない|異常|個別JSON|tests/backup-rollback-smoke.ps1:708|
|BACKUP-040|自分のDCR PUTがUpdatingからSucceededなら待って完了|境界（非同期完了）|個別JSON|tests/backup-rollback-smoke.ps1:722|
|BACKUP-041|DCRAにUpdatingが返る場合も新診断を削除しない|異常|個別JSON|tests/backup-rollback-smoke.ps1:733|
|BACKUP-042|新削除途中の失敗は後続停止し再実行できる|正常・異常混合|個別JSON|tests/backup-rollback-smoke.ps1:742|
|BACKUP-043|旧削除済scopeの新欠損もverify/delete全体を停止|異常|個別JSON|tests/backup-rollback-smoke.ps1:754|
|BACKUP-044|旧全消済リージョンのStorage基礎確認を維持|正常|個別JSON|tests/backup-rollback-smoke.ps1:769|
|BACKUP-045|backup後に増えた無関係VMを関連付け対象へ広げない|正常|個別JSON|tests/backup-rollback-smoke.ps1:776|
|BACKUP-046|①の対象Subバックアップ保存に失敗したら設定書込みを始めない|異常|個別JSON|tests/backup-rollback-smoke.ps1:786|
|BACKUP-047|①の途中停止から再開し既存Beforeを維持して未保存Subだけを追加する|境界・復旧|個別JSON|tests/backup-rollback-smoke.ps1:797|
|BACKUP-048|後続Subの総保持90では旧設定を全件削除しない|異常検知|個別JSON|tests/backup-rollback-smoke.ps1:821|
|BACKUP-049|後続Subの継承総保持365（要求1095）では旧設定を全件削除しない|異常検知|個別JSON|tests/backup-rollback-smoke.ps1:821|
|BACKUP-050|3年ルールが正しくても後続Subに旧365日ルールが残る場合は削除しない|異常検知|個別JSON|tests/backup-rollback-smoke.ps1:838|

## 旧DCR・VMSS切替

|CaseID|ケース|種別|根拠|SourceLine|
|---|---|---|---|---|
|DCR-001|2本の一覧とnextLink・Subfilter・writableだけ保存|正常|個別JSON|tests/dcr-cutover-smoke.ps1:50|
|DCR-002|2本とも空一覧なら0件|境界|個別JSON|tests/dcr-cutover-smoke.ps1:61|
|DCR-003|旧DCR 1本を拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:67|
|DCR-004|旧DCR 3本を拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:67|
|DCR-005|旧DCR 大文字小文字重複を拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:67|
|DCR-006|旧DCR 余白除去後重複を拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:67|
|DCR-007|旧DCR 不正IDを拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:67|
|DCR-008|CSV対象0件を拒否|境界・異常|個別JSON|tests/dcr-cutover-smoke.ps1:69|
|DCR-009|一覧NullPageを拒否|異常（応答欠損）|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-010|一覧NullValueを拒否|異常（応答欠損）|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-011|一覧NullItemを拒否|異常（応答欠損）|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-012|一覧GetFailureを拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-013|一覧BadIdを拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-014|一覧WrongRuleを拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-015|一覧Duplicateを拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:71|
|DCR-016|新旧DCR・関連ID衝突だけを停止|正常・異常混合|個別JSON|tests/dcr-cutover-smoke.ps1:85|
|DCR-017|旧関連barrier-Success|正常|個別JSON|tests/dcr-cutover-smoke.ps1:184|
|DCR-018|旧関連barrier-PutFailure|異常（書込み失敗）|個別JSON|tests/dcr-cutover-smoke.ps1:184|
|DCR-019|旧関連barrier-ReadbackFailure|異常（読戻し失敗）|個別JSON|tests/dcr-cutover-smoke.ps1:184|
|DCR-020|旧関連barrier-ForeignBefore|異常|個別JSON|tests/dcr-cutover-smoke.ps1:184|
|DCR-021|旧関連barrier-UpdatingThenReady|境界（非同期完了）|個別JSON|tests/dcr-cutover-smoke.ps1:184|
|DCR-022|実discoveryは旧関連のないVMとVMSSを収集対象へ加えない|正常|個別JSON|tests/dcr-cutover-smoke.ps1:212|
|DCR-023|Version3は旧2本・VMSS旧関連を最小保存する|正常|個別JSON|tests/dcr-cutover-smoke.ps1:263|
|DCR-024|Rule一覧が参照IDだけでも完全GETの説明とDCEを保存・復元する|正常|個別JSON|tests/dcr-cutover-smoke.ps1:274|
|DCR-025|後続Subの旧関連GET失敗ではそのSubを保存・変更しない|異常|個別JSON|tests/dcr-cutover-smoke.ps1:310|
|DCR-026|複製の再実行は旧DCR関連を解除しない|正常|個別JSON|tests/dcr-cutover-smoke.ps1:325|
|DCR-027|旧DCR関連のないVMは診断設定だけ複製し関連付けを作らない|正常|個別JSON|tests/dcr-cutover-smoke.ps1:334|
|DCR-028|旧関連消失後もVMSS新関連を全件確認対象へ残す|正常|個別JSON|tests/dcr-cutover-smoke.ps1:352|
|DCR-029|後続VMSSの新関連Missingは旧削除全体を止める|異常（関連欠損）|個別JSON|tests/dcr-cutover-smoke.ps1:364|
|DCR-030|後続VMSSの新関連WrongRuleは旧削除全体を止める|異常|個別JSON|tests/dcr-cutover-smoke.ps1:364|
|DCR-031|後続VMSSの新関連Updatingは旧削除全体を止める|異常|個別JSON|tests/dcr-cutover-smoke.ps1:364|
|DCR-032|旧2本の関連だけを解除し削除済み再実行は変更0|正常|個別JSON|tests/dcr-cutover-smoke.ps1:380|
|DCR-033|旧関連0のDELETE失敗は後続と全旧診断を停止|異常|個別JSON|tests/dcr-cutover-smoke.ps1:395|
|DCR-034|旧関連1のDELETE失敗は後続と全旧診断を停止|異常|個別JSON|tests/dcr-cutover-smoke.ps1:395|
|DCR-035|旧関連の内容変更は上書き・削除しない|異常（外部変更）|個別JSON|tests/dcr-cutover-smoke.ps1:409|
|DCR-036|①再実行は追加旧VMSS関連のBeforeを保存し元のBeforeは維持する|正常|個別JSON|tests/dcr-cutover-smoke.ps1:418|
|DCR-037|指定Subの削除は集中DCRの他Sub関連を残す|正常|個別JSON|tests/dcr-cutover-smoke.ps1:458|
|DCR-038|指定Subの切戻しは他Subの旧・新関連を保持する|正常|個別JSON|tests/dcr-cutover-smoke.ps1:467|
|DCR-039|Version3のVersion1不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-040|Version3のOldDcrIds不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-041|Version3のOldAssociationsNull不正をAzure照会前に拒否|異常（バックアップ欠損）|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-042|Version3のForeignOldDcr不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-043|Version3のMissingNewParent不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-044|Version3のDuplicateOld不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-045|Version3のSameOldNewAssociation不正をAzure照会前に拒否|異常|個別JSON|tests/dcr-cutover-smoke.ps1:478|
|DCR-046|事前チェック後に増えた旧VMSS関連を①が直前に調査して保存する|境界・復旧|個別JSON|tests/dcr-cutover-smoke.ps1:495|
|DCR-047|後から収集対象になったSubのDCRは最初に変更する直前のBeforeを保存する|境界・復旧|個別JSON|tests/dcr-cutover-smoke.ps1:518|

## 生成方法と証跡

種別は生成後に入力パターンに合わせて編集確認しています。ケース名・結果・証跡・件数は変更していません。

`generate_case_list.py` は凍結20ファイル・Native報告・Linux報告・個別結果JSONの整合を確認し、PowerShell ParserのASTから名前と行番号を読みます。テストや本体の再実行、Azure通信は行っていません。動的なケース名は、確認した固定ループ値だけを展開し、未対応の式や名前／行の不一致があれば生成を停止します。

[生成証跡](catalog-proof.json) / [抽出したソース定義](source-case-definitions.json)。リポジトリ内のファイルは変更していません。
