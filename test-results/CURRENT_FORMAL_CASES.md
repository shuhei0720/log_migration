# 旧Windows PowerShell 5.1版の185ケース一覧

この一覧は旧`migration`版の履歴です。正本のPowerShell 7版は[72ケースの一覧](PROCEDURAL_CASES.md)を参照してください。

送信先選択追加版の、実Windows PowerShell 5.1.20348.5773 Desktopで実行した個別ケースです。同じ凍結版をLinux PowerShell 7.5.4でも確認しました。両環境で185ケース・1,845判定が成功しています。

API／CLIの外部応答を再生し、CSV読込み・探索・作成・確認・削除・切り戻しは実際の工程コードを使います。Azureへ本スクリプトの設定を適用する通し試験の実績とは区別します。Azure通信は0です。

対象マニフェストSHA-256: `10b01d2a9d241d56d0773688ec6cd7796274454ddb1cb1aad576e417cd047516`。
[Windows個別結果](destination-selection-windows51.json) / [Linux結果](destination-selection-linux.json) / [CSV](CURRENT_FORMAL_CASES.csv)。

|分類|ケース数|判定数|
|---|---:|---:|
|保存先・保持・再実行|33|163|
|Lifecycle送信本文|6|39|
|バックアップ・切戻し|50|326|
|旧DCR・VMSS・送信先選択|96|1,038|
|正式ケース合計|185|1,566|
|共通・入力・API／JSON・標準ジョブの基本判定|ケース数へ加算しない|275|
|4系統の接続判定|ケース数へ加算しない|4|
|全判定合計|185|1,845|

旧136ケースを維持し、49ケースを追加しました。空欄・Noneの組合せ、保存先の常時準備、必須値不足、不正フラグ、同名設定と5件上限、途中失敗と再開、旧設定の削除、全体／個別切り戻し、非JPEのみの削除後再実行を含みます。

PASSは期待した動作の成功です。不正入力を拒否し、書込みや削除を止めたケースもPASSです。種別はレビュー用の分類です。Lifecycle6件の個別判定数は報告に含まれないためCSVは空欄とし、系統合計39判定で確認します。

## 保存先・保持・再実行

|CaseID|ケース|種別|結果|コード|
|---|---|---|---|---|
|BASE-001|実ARM応答の全一致VerifyOnly|正常|PASS|[205行](../tests/baseline-smoke.ps1#L205)|
|BASE-002|実ARM応答の全一致Copy再実行|正常|PASS|[215行](../tests/baseline-smoke.ps1#L215)|
|BASE-003|Blob不足の読取専用検知と手動対応情報|異常検知|PASS|[221行](../tests/baseline-smoke.ps1#L221)|
|BASE-004|Blob不足だけ補完し再実行を省略|正常|PASS|[231行](../tests/baseline-smoke.ps1#L231)|
|BASE-005|旧DCR関連のあるVMSSも同じ新DCRの確認・補完対象|正常・異常混合|PASS|[240行](../tests/baseline-smoke.ps1#L240)|
|BASE-006|関連付けPUTのUpdating完了後も参照先を再確認-Expected|境界（非同期完了）|PASS|[262行](../tests/baseline-smoke.ps1#L262)|
|BASE-007|関連付けPUTのUpdating完了後も参照先を再確認-Foreign|異常|PASS|[262行](../tests/baseline-smoke.ps1#L262)|
|BASE-008|Storage基礎構成の不一致は上書きしない|異常|PASS|[278行](../tests/baseline-smoke.ps1#L278)|
|BASE-009|既存Policy除外の不一致は他の作業を開始しない|異常|PASS|[286行](../tests/baseline-smoke.ps1#L286)|
|BASE-010|LA保持期間だけ補完し他featureを保持|正常|PASS|[294行](../tests/baseline-smoke.ps1#L294)|
|BASE-011|Lifecycle自分のルールだけ補完し他ルール保持|正常|PASS|[303行](../tests/baseline-smoke.ps1#L303)|
|BASE-012|Lifecycle未作成404から有効な1ルールだけ作成|境界|PASS|[315行](../tests/baseline-smoke.ps1#L315)|
|BASE-013|DCR不足だけ補完し再実行を省略|正常|PASS|[328行](../tests/baseline-smoke.ps1#L328)|
|BASE-014|読み戻しが一致しなければ失敗を返す|異常|PASS|[337行](../tests/baseline-smoke.ps1#L337)|
|BASE-015|LA不足時もVerifyOnlyはVM後続項目を確認|異常検知|PASS|[346行](../tests/baseline-smoke.ps1#L346)|
|BASE-016|StorageのCreatingはVerifyOnlyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-017|StorageのCreatingはCopyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-018|LAのUpdatingはVerifyOnlyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-019|LAのUpdatingはCopyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-020|DCRのUpdatingはVerifyOnlyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-021|DCRのUpdatingはCopyでも変更しない|異常|PASS|[362行](../tests/baseline-smoke.ps1#L362)|
|BASE-022|Storage未設定の手動CSVへmutable期待値も出す|正常|PASS|[371行](../tests/baseline-smoke.ps1#L371)|
|BASE-023|Storagemutable補完でも個別ネットワーク規則を保持|正常|PASS|[385行](../tests/baseline-smoke.ps1#L385)|
|BASE-024|EventとSyslogの総保持90だけを1095へ補完し他の設定を保持|正常|PASS|[398行](../tests/baseline-smoke.ps1#L398)|
|BASE-025|分析保持365でも総保持が未指定なら確認NGと設定補完|正常・異常混合|PASS|[429行](../tests/baseline-smoke.ps1#L429)|
|BASE-026|EventとSyslogの新規作成は総保持1095を指定し完了後にDCRを作成|正常|PASS|[441行](../tests/baseline-smoke.ps1#L441)|
|BASE-027|総保持PATCHの読み戻し不一致ではDCRと関連作成を開始しない|異常|PASS|[460行](../tests/baseline-smoke.ps1#L460)|
|BASE-028|確認版はEventとSyslogの総保持90を変更せず全件NGにする|正常|PASS|[472行](../tests/baseline-smoke.ps1#L472)|
|BASE-029|総保持1095のPATCHが拒否されても元の分析保持と設定を維持|異常|PASS|[482行](../tests/baseline-smoke.ps1#L482)|
|BASE-030|継承した総保持365を明示1095へ変更し読取り専用フラグは送らない|正常・異常混合|PASS|[496行](../tests/baseline-smoke.ps1#L496)|
|BASE-031|総保持1095でAsDefaultが省略またはnullなら変更せず確認できる|境界|PASS|[510行](../tests/baseline-smoke.ps1#L510)|
|BASE-032|旧365管理ルールだけ1095へ置換し他名ルールの365設定を保持|正常|PASS|[520行](../tests/baseline-smoke.ps1#L520)|
|BASE-033|正しい1095管理ルールがあっても併存する旧365管理ルールを除去|正常・異常混合|PASS|[539行](../tests/baseline-smoke.ps1#L539)|

## Lifecycle送信本文

|CaseID|ケース|種別|結果|コード|
|---|---|---|---|---|
|LC-001|Missing|境界|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|
|LC-002|Empty|境界|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|
|LC-003|OtherRule|正常|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|
|LC-004|ReplaceOwnRule|正常（補完・移行）|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|
|LC-005|Legacy365Only|正常（補完・移行）|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|
|LC-006|Desired1095AlreadyCorrectPlusLegacy365|正常（補完・移行）|PASS|[64行](../tests/lifecycle-request-replay.ps1#L64)|

## バックアップ・切戻し

|CaseID|ケース|種別|結果|コード|
|---|---|---|---|---|
|BACKUP-001|①が実際の書込みより前に元の最小バックアップを保存|正常|PASS|[444行](../tests/backup-rollback-smoke.ps1#L444)|
|BACKUP-002|HashtableとPSCustomObjectの旧関連を保存して同じ内容で読める|正常|PASS|[464行](../tests/backup-rollback-smoke.ps1#L464)|
|BACKUP-003|PSCustomObject前値を実ARM serializerへ渡せる|正常|PASS|[487行](../tests/backup-rollback-smoke.ps1#L487)|
|BACKUP-004|DCR自体が診断対象でもsnapshotとの併用を許可|正常|PASS|[502行](../tests/backup-rollback-smoke.ps1#L502)|
|BACKUP-005|事前チェックは既存の①バックアップを読まず独立して確認する|正常|PASS|[519行](../tests/backup-rollback-smoke.ps1#L519)|
|BACKUP-006|①の再実行は保存済みBeforeとファイルを変更しない|正常|PASS|[530行](../tests/backup-rollback-smoke.ps1#L530)|
|BACKUP-007|VM・診断対象0のbackupは空配列を維持|境界|PASS|[539行](../tests/backup-rollback-smoke.ps1#L539)|
|BACKUP-008|①はバックアップが無い初回にも変更前保存から開始する|正常|PASS|[552行](../tests/backup-rollback-smoke.ps1#L552)|
|BACKUP-009|backup無しのdelete は変更前に停止|正常|PASS|[559行](../tests/backup-rollback-smoke.ps1#L559)|
|BACKUP-010|backup無しのverify は変更前に停止|正常|PASS|[559行](../tests/backup-rollback-smoke.ps1#L559)|
|BACKUP-011|backup不正Version はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-012|backup不正Environment はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-013|backup不正TargetWorkspaceId はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-014|backup不正NewDiagnosticSettingName はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-015|backup不正DuplicateTarget はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-016|backup不正DuplicateDiagnostic はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-017|backup不正WrongSubResource はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-018|backup不正EmptyAfter はlocalで拒否|異常|PASS|[566行](../tests/backup-rollback-smoke.ps1#L566)|
|BACKUP-019|壊れたJSONとCSV宛先差分を拒否|異常|PASS|[583行](../tests/backup-rollback-smoke.ps1#L583)|
|BACKUP-020|CSVの正しいSub部分集合を許可しアクセス対象外Subは拒否|異常|PASS|[595行](../tests/backup-rollback-smoke.ps1#L595)|
|BACKUP-021|未実施状態のrollbackは全てskip|境界|PASS|[610行](../tests/backup-rollback-smoke.ps1#L610)|
|BACKUP-022|全削除後のrollbackは旧全復元後だけ新を削除|境界・互換|PASS|[617行](../tests/backup-rollback-smoke.ps1#L617)|
|BACKUP-023|複製途中のrollbackは存在する新設定だけ除去|境界・復旧|PASS|[636行](../tests/backup-rollback-smoke.ps1#L636)|
|BACKUP-024|サブスクリプション部分選択で他Subを保持|正常|PASS|[645行](../tests/backup-rollback-smoke.ps1#L645)|
|BACKUP-025|存在しないSub指定は変更0|正常|PASS|[652行](../tests/backup-rollback-smoke.ps1#L652)|
|BACKUP-026|明示empty-arrayのSub指定は全体へ広げない|正常|PASS|[660行](../tests/backup-rollback-smoke.ps1#L660)|
|BACKUP-027|明示nullのSub指定は全体へ広げない|境界|PASS|[660行](../tests/backup-rollback-smoke.ps1#L660)|
|BACKUP-028|明示empty-stringのSub指定は全体へ広げない|正常|PASS|[660行](../tests/backup-rollback-smoke.ps1#L660)|
|BACKUP-029|明示whitespaceのSub指定は全体へ広げない|正常|PASS|[660行](../tests/backup-rollback-smoke.ps1#L660)|
|BACKUP-030|後続Sub/設定のOld 不一致は全復元前に停止|異常|PASS|[669行](../tests/backup-rollback-smoke.ps1#L669)|
|BACKUP-031|後続Sub/設定のNew 不一致は全復元前に停止|異常|PASS|[669行](../tests/backup-rollback-smoke.ps1#L669)|
|BACKUP-032|後続Sub/設定のDcr 不一致は全復元前に停止|異常|PASS|[669行](../tests/backup-rollback-smoke.ps1#L669)|
|BACKUP-033|後続Sub/設定のAssociation 不一致は全復元前に停止|異常|PASS|[669行](../tests/backup-rollback-smoke.ps1#L669)|
|BACKUP-034|旧復元用の空きが無ければ新を消さず停止|異常|PASS|[684行](../tests/backup-rollback-smoke.ps1#L684)|
|BACKUP-035|復元OldPut 失敗時は新診断DELETE0|異常|PASS|[694行](../tests/backup-rollback-smoke.ps1#L694)|
|BACKUP-036|復元Readback 失敗時は新診断DELETE0|異常|PASS|[694行](../tests/backup-rollback-smoke.ps1#L694)|
|BACKUP-037|復元DcrPut 失敗時は新診断DELETE0|異常|PASS|[694行](../tests/backup-rollback-smoke.ps1#L694)|
|BACKUP-038|復元AssociationPut 失敗時は新診断DELETE0|異常|PASS|[694行](../tests/backup-rollback-smoke.ps1#L694)|
|BACKUP-039|DCR復元がUpdatingなら新診断を削除しない|異常|PASS|[708行](../tests/backup-rollback-smoke.ps1#L708)|
|BACKUP-040|自分のDCR PUTがUpdatingからSucceededなら待って完了|境界（非同期完了）|PASS|[722行](../tests/backup-rollback-smoke.ps1#L722)|
|BACKUP-041|DCRAにUpdatingが返る場合も新診断を削除しない|異常|PASS|[733行](../tests/backup-rollback-smoke.ps1#L733)|
|BACKUP-042|新削除途中の失敗は後続停止し再実行できる|異常|PASS|[742行](../tests/backup-rollback-smoke.ps1#L742)|
|BACKUP-043|旧削除済scopeの新欠損もverify/delete全体を停止|異常|PASS|[754行](../tests/backup-rollback-smoke.ps1#L754)|
|BACKUP-044|旧全消済リージョンのStorage基礎確認を維持|正常|PASS|[769行](../tests/backup-rollback-smoke.ps1#L769)|
|BACKUP-045|backup後に増えた無関係VMを関連付け対象へ広げない|正常|PASS|[776行](../tests/backup-rollback-smoke.ps1#L776)|
|BACKUP-046|①の対象Subバックアップ保存に失敗したら設定書込みを始めない|異常|PASS|[786行](../tests/backup-rollback-smoke.ps1#L786)|
|BACKUP-047|①の途中停止から再開し既存Beforeを維持して未保存Subだけを追加する|境界・復旧|PASS|[797行](../tests/backup-rollback-smoke.ps1#L797)|
|BACKUP-048|後続Subの総保持90では旧設定を全件削除しない|正常|PASS|[821行](../tests/backup-rollback-smoke.ps1#L821)|
|BACKUP-049|後続Subの継承総保持365（要求1095）では旧設定を全件削除しない|正常・異常混合|PASS|[821行](../tests/backup-rollback-smoke.ps1#L821)|
|BACKUP-050|3年ルールが正しくても後続Subに旧365日ルールが残る場合は削除しない|境界・復旧|PASS|[838行](../tests/backup-rollback-smoke.ps1#L838)|

## 旧DCR・VMSS・送信先選択

|CaseID|ケース|種別|結果|コード|
|---|---|---|---|---|
|DCR-001|2本の一覧とnextLink・Subfilter・writableだけ保存|正常|PASS|[52行](../tests/dcr-cutover-smoke.ps1#L52)|
|DCR-002|2本とも空一覧なら0件|境界|PASS|[63行](../tests/dcr-cutover-smoke.ps1#L63)|
|DCR-003|旧DCR 1本を拒否|異常|PASS|[69行](../tests/dcr-cutover-smoke.ps1#L69)|
|DCR-004|旧DCR 3本を拒否|異常|PASS|[69行](../tests/dcr-cutover-smoke.ps1#L69)|
|DCR-005|旧DCR 大文字小文字重複を拒否|異常|PASS|[69行](../tests/dcr-cutover-smoke.ps1#L69)|
|DCR-006|旧DCR 余白除去後重複を拒否|異常|PASS|[69行](../tests/dcr-cutover-smoke.ps1#L69)|
|DCR-007|旧DCR 不正IDを拒否|異常|PASS|[69行](../tests/dcr-cutover-smoke.ps1#L69)|
|DCR-008|CSV対象0件を拒否|境界|PASS|[71行](../tests/dcr-cutover-smoke.ps1#L71)|
|DCR-009|一覧NullPageを拒否|境界|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-010|一覧NullValueを拒否|境界|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-011|一覧NullItemを拒否|境界|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-012|一覧GetFailureを拒否|異常|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-013|一覧BadIdを拒否|異常|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-014|一覧WrongRuleを拒否|異常|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-015|一覧Duplicateを拒否|異常|PASS|[73行](../tests/dcr-cutover-smoke.ps1#L73)|
|DCR-016|新旧DCR・関連ID衝突だけを停止|境界・復旧|PASS|[87行](../tests/dcr-cutover-smoke.ps1#L87)|
|DCR-017|CSV選択 診断[Storage] VM[Log]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-018|CSV選択 診断[Storage] VM[None]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-019|CSV選択 診断[Storage] VM[]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-020|CSV選択 診断[Log] VM[Log]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-021|CSV選択 診断[Log] VM[None]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-022|CSV選択 診断[Log] VM[]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-023|CSV選択 診断[None] VM[Log]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-024|CSV選択 診断[None] VM[None]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-025|CSV選択 診断[None] VM[]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-026|CSV選択 診断[] VM[Log]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-027|CSV選択 診断[] VM[None]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-028|CSV選択 診断[] VM[]|正常|PASS|[118行](../tests/dcr-cutover-smoke.ps1#L118)|
|DCR-029|旧5列CSV [Storage]はVMログを有効にする|境界・互換|PASS|[135行](../tests/dcr-cutover-smoke.ps1#L135)|
|DCR-030|旧5列CSV [Log]はVMログを有効にする|境界・互換|PASS|[135行](../tests/dcr-cutover-smoke.ps1#L135)|
|DCR-031|旧5列CSV [None]はVMログを有効にする|境界・互換|PASS|[135行](../tests/dcr-cutover-smoke.ps1#L135)|
|DCR-032|CSV選択 前後空白と大小文字|正常|PASS|[153行](../tests/dcr-cutover-smoke.ps1#L153)|
|DCR-033|CSV選択 StorageのみでもWorkspaceを指定|正常|PASS|[153行](../tests/dcr-cutover-smoke.ps1#L153)|
|DCR-034|CSV選択 LogのみではStorage不要|正常|PASS|[153行](../tests/dcr-cutover-smoke.ps1#L153)|
|DCR-035|CSV選択 VMのみでも指定Storage名を保持|正常|PASS|[153行](../tests/dcr-cutover-smoke.ps1#L153)|
|DCR-036|CSV選択 両方省略でも保存先を指定|正常|PASS|[153行](../tests/dcr-cutover-smoke.ps1#L153)|
|DCR-037|CSV選択 不正な診断宛先を拒否|異常|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-038|CSV選択 VMのStorage指定を拒否|異常|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-039|CSV選択 VMの不正フラグを拒否|異常|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-040|CSV選択 Sub空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-041|CSV選択 有効側のRG空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-042|CSV選択 VM用Workspace空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-043|CSV選択 Log診断用Workspace空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-044|CSV選択 Storage診断用名前空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-045|CSV選択 両方省略のRG空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-046|CSV選択 両方省略のWorkspace空欄を拒否|異常（境界）|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-047|CSV選択 省略側の不正Storage名を拒否|異常|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-048|CSV選択 Log側の不正Storage名を拒否|異常|PASS|[180行](../tests/dcr-cutover-smoke.ps1#L180)|
|DCR-049|旧関連barrier-Success|正常|PASS|[288行](../tests/dcr-cutover-smoke.ps1#L288)|
|DCR-050|旧関連barrier-PutFailure|正常|PASS|[288行](../tests/dcr-cutover-smoke.ps1#L288)|
|DCR-051|旧関連barrier-ReadbackFailure|正常|PASS|[288行](../tests/dcr-cutover-smoke.ps1#L288)|
|DCR-052|旧関連barrier-ForeignBefore|異常|PASS|[288行](../tests/dcr-cutover-smoke.ps1#L288)|
|DCR-053|旧関連barrier-UpdatingThenReady|境界（非同期完了）|PASS|[288行](../tests/dcr-cutover-smoke.ps1#L288)|
|DCR-054|実discoveryは旧関連のないVMとVMSSを収集対象へ加えない|正常|PASS|[316行](../tests/dcr-cutover-smoke.ps1#L316)|
|DCR-055|Version3は旧2本・VMSS旧関連を最小保存する|正常|PASS|[367行](../tests/dcr-cutover-smoke.ps1#L367)|
|DCR-056|Rule一覧が参照IDだけでも完全GETの説明とDCEを保存・復元する|正常|PASS|[378行](../tests/dcr-cutover-smoke.ps1#L378)|
|DCR-057|後続Subの旧関連GET失敗ではそのSubを保存・変更しない|異常|PASS|[414行](../tests/dcr-cutover-smoke.ps1#L414)|
|DCR-058|複製の再実行は旧DCR関連を解除しない|正常|PASS|[429行](../tests/dcr-cutover-smoke.ps1#L429)|
|DCR-059|旧DCR関連のないVMは診断設定だけ複製し関連付けを作らない|正常|PASS|[438行](../tests/dcr-cutover-smoke.ps1#L438)|
|DCR-060|旧関連消失後もVMSS新関連を全件確認対象へ残す|正常|PASS|[456行](../tests/dcr-cutover-smoke.ps1#L456)|
|DCR-061|後続VMSSの新関連Missingは旧削除全体を止める|正常|PASS|[468行](../tests/dcr-cutover-smoke.ps1#L468)|
|DCR-062|後続VMSSの新関連WrongRuleは旧削除全体を止める|異常|PASS|[468行](../tests/dcr-cutover-smoke.ps1#L468)|
|DCR-063|後続VMSSの新関連Updatingは旧削除全体を止める|異常|PASS|[468行](../tests/dcr-cutover-smoke.ps1#L468)|
|DCR-064|旧2本の関連だけを解除し削除済み再実行は変更0|正常|PASS|[484行](../tests/dcr-cutover-smoke.ps1#L484)|
|DCR-065|旧関連0のDELETE失敗は後続と全旧診断を停止|異常|PASS|[499行](../tests/dcr-cutover-smoke.ps1#L499)|
|DCR-066|旧関連1のDELETE失敗は後続と全旧診断を停止|異常|PASS|[499行](../tests/dcr-cutover-smoke.ps1#L499)|
|DCR-067|旧関連の内容変更は上書き・削除しない|正常|PASS|[513行](../tests/dcr-cutover-smoke.ps1#L513)|
|DCR-068|①再実行は追加旧VMSS関連のBeforeを保存し元のBeforeは維持する|正常|PASS|[522行](../tests/dcr-cutover-smoke.ps1#L522)|
|DCR-069|指定Subの削除は集中DCRの他Sub関連を残す|正常|PASS|[562行](../tests/dcr-cutover-smoke.ps1#L562)|
|DCR-070|指定Subの切戻しは他Subの旧・新関連を保持する|正常|PASS|[571行](../tests/dcr-cutover-smoke.ps1#L571)|
|DCR-071|Version3のVersion1不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-072|Version3のOldDcrIds不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-073|Version3のOldAssociationsNull不正をAzure照会前に拒否|境界|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-074|Version3のForeignOldDcr不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-075|Version3のMissingNewParent不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-076|Version3のDuplicateOld不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-077|Version3のSameOldNewAssociation不正をAzure照会前に拒否|異常|PASS|[582行](../tests/dcr-cutover-smoke.ps1#L582)|
|DCR-078|事前チェック後に増えた旧VMSS関連を①が直前に調査して保存する|境界・復旧|PASS|[599行](../tests/dcr-cutover-smoke.ps1#L599)|
|DCR-079|後から収集対象になったSubのDCRは最初に変更する直前のBeforeを保存する|境界・復旧|PASS|[622行](../tests/dcr-cutover-smoke.ps1#L622)|
|DCR-080|送信先選択 StorageとVMの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-081|送信先選択 LogとVMの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-082|送信先選択 Storageのみの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-083|送信先選択 Logのみの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-084|送信先選択 VMのみの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-085|送信先選択 両方Noneの全工程と再実行|正常|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-086|送信先選択 両方空欄の全工程と再実行|境界・互換|PASS|[800行](../tests/dcr-cutover-smoke.ps1#L800)|
|DCR-087|Canadaのみの旧設定を全削除しても確認と削除再実行でJPEを要求しない|正常|PASS|[866行](../tests/dcr-cutover-smoke.ps1#L866)|
|DCR-088|旧診断対象0件でも指定Storageを東日本へ準備する|境界|PASS|[897行](../tests/dcr-cutover-smoke.ps1#L897)|
|DCR-089|両方省略は同名新診断と5件上限に触れず旧設定だけを削除・復元する|境界・互換|PASS|[914行](../tests/dcr-cutover-smoke.ps1#L914)|
|DCR-090|両方省略なら旧診断名が新診断名と同じでも旧設定として削除・復元する|正常|PASS|[929行](../tests/dcr-cutover-smoke.ps1#L929)|
|DCR-091|作業途中のVM選択変更はcopyの変更前に停止|境界・復旧|PASS|[949行](../tests/dcr-cutover-smoke.ps1#L949)|
|DCR-092|作業途中のVM選択変更はverifyの変更前に停止|境界・復旧|PASS|[949行](../tests/dcr-cutover-smoke.ps1#L949)|
|DCR-093|作業途中のVM選択変更はdeleteの変更前に停止|境界・復旧|PASS|[949行](../tests/dcr-cutover-smoke.ps1#L949)|
|DCR-094|別選択のコピー途中失敗から有効側の不足だけを再開する|異常|PASS|[958行](../tests/dcr-cutover-smoke.ps1#L958)|
|DCR-095|両方省略の旧関連削除失敗を再実行し元へ戻せる|異常|PASS|[977行](../tests/dcr-cutover-smoke.ps1#L977)|
|DCR-096|2Subの別選択と指定Subの切戻しは交差しない|正常|PASS|[990行](../tests/dcr-cutover-smoke.ps1#L990)|
