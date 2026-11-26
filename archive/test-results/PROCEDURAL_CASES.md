# 元の正本の再生試験：90ケース

この一覧は変更前の記録です。追加ケースを含む最新の結果は[正本の検証結果](../../test-results/REPORT.md)を参照してください。

元の正本6本をLinux PowerShell 7.5.4で実行し、90ケース・1,304判定が成功しました。この資料は、その試験記録の説明を書き直したものです。ストレージアカウントの公開ネットワーク無効、原本のアクセス制御、保持期間、初回の既存リソースグループでの停止、同じ作業記録からの再開を確認しています。

CLI・HTTPの応答と時刻を試験用データに置き換え、CSV読込みから複製・確認・削除・切り戻しまで、正本のコードを変えずに実行しました。Azureへの要求は0件です。1,304判定の内訳は、ケース内の1,292判定と、構文・実行前後のコードの確認12判定です。

異常ケースのPASSは、指定した条件で処理が止まり、既存設定を残せたことを表します。ケース名とIDは、元のCSV・試験ログを探せるよう、実行記録と同じ表記を残しています。

実機試験とWindowsでの過去の結果は[過去の検証記録](HISTORY.md)に分けています。この文章見直し後に、実機試験を再実施したものではありません。

|ID|ケース名|試験の種類|確認項目数|結果|
|---|---|---|---:|---|
|PROC-001|StorageとVM: 全工程・再実行・切戻し|再開・切戻し|108|PASS|
|PROC-002|LogとVM: 全工程・再実行・切戻し|再開・切戻し|108|PASS|
|PROC-003|Storageのみ: 全工程・再実行・切戻し|再開・切戻し|104|PASS|
|PROC-004|Logのみ: 全工程・再実行・切戻し|再開・切戻し|104|PASS|
|PROC-005|VMのみ: 全工程・再実行・切戻し|再開・切戻し|106|PASS|
|PROC-006|両方None: 全工程・再実行・切戻し|再開・切戻し|102|PASS|
|PROC-007|両方空欄: 全工程・再実行・切戻し|境界|102|PASS|
|PROC-008|Storage宛GETのLAW既定方式付加を許容して再実行・削除・復元できる|正常・再開・切戻し|14|PASS|
|PROC-009|LAW宛の格納方式変更は許容せず既存設定を保持する|異常・停止確認|10|PASS|
|PROC-010|CSV列欠落は空欄と区別して書込み前に停止する|異常|24|PASS|
|PROC-011|対象0件でも東日本StorageとLAWを準備する|境界|10|PASS|
|PROC-012|東日本・西日本・globalの地域別Storageへ送信する|正常|5|PASS|
|PROC-013|Canadaのみの旧設定を削除後もJPEを要求しない|正常|7|PASS|
|PROC-014|Storage kind=StorageV2 の子スコープを探索|正常|3|PASS|
|PROC-015|Storage kind=BlobStorage の子スコープを探索|正常|3|PASS|
|PROC-016|Storage kind=BlockBlobStorage の子スコープを探索|正常|3|PASS|
|PROC-017|Storage kind=FileStorage の子スコープを探索|正常|3|PASS|
|PROC-018|通常一覧にないRedis子DBを親地域のStorageへ移行・復元する|正常・切戻し|12|PASS|
|PROC-019|RedisのDB一覧が空なら存在しない子を調べない|境界|4|PASS|
|PROC-020|Redis子DBと通常一覧の次ページを両方移行・復元する|正常・切戻し|15|PASS|
|PROC-021|CSV入力拒否: 不正診断フラグ|異常・停止確認|2|PASS|
|PROC-022|CSV入力拒否: 不正VMフラグ|異常・停止確認|2|PASS|
|PROC-023|CSV入力拒否: 空RG|異常・停止確認|2|PASS|
|PROC-024|CSV入力拒否: 空Workspace|異常・停止確認|2|PASS|
|PROC-025|CSV入力拒否: 不正Storage名|異常・停止確認|2|PASS|
|PROC-026|CSV入力拒否: jpeが2か所|異常・停止確認|2|PASS|
|PROC-027|CSV入力拒否: Storage名25文字|境界|2|PASS|
|PROC-028|CSV入力拒否: 空Sub|異常・停止確認|2|PASS|
|PROC-029|初回の既存RGは同地域でも別地域でも変更前に停止する|異常|14|PASS|
|PROC-030|初回の既存Storage名を事前停止する|異常・停止確認|2|PASS|
|PROC-031|ZRS非対応の地域を事前停止する|異常・停止確認|2|PASS|
|PROC-032|初回の同名新診断を再利用しない|異常・停止確認|2|PASS|
|PROC-033|新診断を追加する空き5枠上限を事前停止する|境界|2|PASS|
|PROC-034|両Noneは同名新診断と5件上限に触れない|正常|4|PASS|
|PROC-035|関係のないVM・VMSSには新関連を作らない|正常|2|PASS|
|PROC-036|Storage ACL・LAW features・分析保持・他ルールを維持する|正常|13|PASS|
|PROC-037|既存Storageの不変条件が違う場合は上書きしない|異常・停止確認|3|PASS|
|PROC-038|既存newDCRと関連は切戻しでBeforeへ復元する|再開・切戻し|9|PASS|
|PROC-039|copy途中失敗から未完了だけを再開する|再開・切戻し|10|PASS|
|PROC-040|記録保存に失敗したSubはAzure変更を始めない|異常・停止確認|2|PASS|
|PROC-041|作業途中CSV選択変更を拒否: copy|再開・切戻し|5|PASS|
|PROC-042|作業途中CSV選択変更を拒否: verify|再開・切戻し|5|PASS|
|PROC-043|作業途中CSV選択変更を拒否: delete|再開・切戻し|5|PASS|
|PROC-044|後続Subの未完了は全Subの旧DELETEを止める|異常・停止確認|7|PASS|
|PROC-045|旧削除の途中失敗は後続を止め再実行できる|再開・切戻し|9|PASS|
|PROC-046|copy後に増えた旧対象をverify/deleteが無視しない|異常・停止確認|4|PASS|
|PROC-047|削除直前に旧設定が変われば以降の削除を止める|異常・停止確認|3|PASS|
|PROC-048|指定Subだけを切り戻し、他Subはそのまま残す|再開・切戻し|9|PASS|
|PROC-049|不明Sub指定のrollbackは変更前に拒否する|異常・停止確認|3|PASS|
|PROC-050|旧復元失敗時は新診断設定を残す|再開・切戻し|6|PASS|
|PROC-051|切戻し対象が外部変更されたら上書きしない|再開・切戻し|3|PASS|
|PROC-052|保存先GET失敗を未存在と扱わず削除前に停止する|異常・停止確認|4|PASS|
|PROC-053|書込み後の期待値不一致を失敗一覧に出す|異常・停止確認|4|PASS|
|PROC-054|接続断・本文切断・通信timeoutから同じ要求で復旧する|正常・再開|24|PASS|
|PROC-055|通信断が続けば最大4回で止まり旧設定を残す|異常・停止確認|4|PASS|
|PROC-056|TLS・明示中断・非通信IO・JSON不正を再試行しない|異常・停止確認|17|PASS|
|PROC-057|429・503はRetryAfterを守って従来どおり再試行する|正常・再試行|6|PASS|
|PROC-058|DELETE応答喪失後の404だけを削除済みとして継続する|正常・再実行|10|PASS|
|PROC-059|Wait付きPUTは1回だけ送信し以後はBody無しGETで待つ|正常・作成待ち|4|PASS|
|PROC-060|作成待ちのFailed・Canceledは即停止する|異常・停止確認|7|PASS|
|PROC-061|対応IWRだけ本文timeoutを設定し未対応環境へ余計なparameterを送らない|境界|2|PASS|
|PROC-062|一時的な401は認証を更新して再試行する|正常|3|PASS|
|PROC-063|登録前providerは記録保存後に登録する|正常|4|PASS|
|PROC-064|旧診断名と新診断名が同じでもNone側は旧を削除・復元する|再開・切戻し|5|PASS|
|PROC-065|指定2DCRでも対象外Subの関連を変更しない|正常|5|PASS|
|PROC-066|未知の地域略称は事前確認で停止する|異常・停止確認|2|PASS|
|PROC-067|対応する既存Waiverは切戻しでも保持する|再開・切戻し|5|PASS|
|PROC-068|内容の違う既存Waiverを上書きしない|異常・停止確認|3|PASS|
|PROC-069|コピー途中の失敗状態から直接切り戻せる|再開・切戻し|11|PASS|
|PROC-070|コピー完了後は旧設定を書き直さず切り戻せる|再開・切戻し|7|PASS|
|PROC-071|旧設定を一部削除した失敗状態から直接切り戻せる|再開・切戻し|9|PASS|
|PROC-072|DCR更新中の応答を待って完了を確認する|正常|4|PASS|
|PROC-073|StorageのResolvingDnsを待って設定を完了する|正常・作成待ち|6|PASS|
|PROC-074|LAWのProvisioningを待って設定を完了する|正常・作成待ち|6|PASS|
|PROC-075|保存先の作成待ちは5分を超えても成功までGETだけで待つ|正常・作成待ち|6|PASS|
|PROC-076|総保持が1095でも既定値フラグのままなら明示設定する|境界|7|PASS|
|PROC-077|変更前記録がなければ確認と削除を開始しない|異常・停止確認|3|PASS|
|PROC-078|通常一覧にある主要タイプと子IDを同じ診断処理へ通す|正常|13|PASS|
|PROC-079|DCRのInvalidOutputTableだけは反映を待って再試行する|正常|4|PASS|
|PROC-080|組み込みSyslogの反映遅延が5分を超えてもDCRを完了する|正常・反映待ち|3|PASS|
|PROC-081|custom tableのInvalidOutputTableを反映待ちと誤認しない|異常・停止確認|8|PASS|
|PROC-082|DCRの一般400は再試行せずそのSubを止める|異常・停止確認|5|PASS|
|PROC-083|新診断の余分なWorkspaceとEventHubを許容しない|異常・停止確認|9|PASS|
|PROC-084|既存DCRへの余分な収集源追加を許容せず切戻しも上書きしない|再開・切戻し|6|PASS|
|PROC-085|未選択Subの記録JSONが壊れていても指定Subだけを切り戻せる|再開・切戻し|7|PASS|
|PROC-086|実runspaceで5件以上の診断GETとPUTを処理する|正常・並列|15|PASS|
|PROC-087|並列worker1件の失敗を記録し再実行で欠落だけを補う|異常・再開|20|PASS|
|PROC-088|既存DCRのIdentity[SystemAssigned]を維持して全工程と切戻しを行う|境界・切戻し|12|PASS|
|PROC-089|既存DCRのIdentity[None]を維持して全工程と切戻しを行う|境界・切戻し|12|PASS|
|PROC-090|既存DCRのIdentity[SystemAssigned, UserAssigned]を維持して全工程と切戻しを行う|境界・切戻し|23|PASS|
