# 移行スクリプトの再生試験：96ケース

自己診断と既存保存先の再利用を追加した`migration/`をPowerShell 7.5.4で実行し、96ケース・1,542判定が成功しました。Azureへの通信は試験用の応答に置き換えています。1,530判定が各ケースの確認で、残り12判定が構文と実行前後のコード不変の確認です。

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
|PROC-031|ZRS非対応の地域を事前停止する|2|PASS|
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
|PROC-063|登録前providerは記録保存後に登録する|4|PASS|
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

[全結果と実行コードのSHA](WORKSPACE_DIAGNOSTIC_REUSE.json) / [検証結果の概要](REPORT.md)
