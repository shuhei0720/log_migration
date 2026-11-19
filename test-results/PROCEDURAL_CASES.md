# 正本の再生試験：75ケース

Linux PowerShell 7.5.4とWindows PowerShell 7.6.10で、同じ75ケース・1,023判定が成功しました。最終総合テストは未開始です。

外部CLI・HTTP・時刻の応答を再生し、CSV、探索、変更前記録、copy、verify、delete、rollbackには正本6本を使います。実Azureへの設定適用を通した試験とは区別します。ケース内1,011判定に、構文と試験前後のソース不変12判定を加えています。

既存ケースIDは保持し、追加したRedisの3ケースをPROC-073〜075に割り当てました。異常ケースのPASSは、期待した停止と既存設定の維持を確認できたことを表します。

|ID|ケース|種別|判定数|Linux|Windows|
|---|---|---|---:|---|---|
|PROC-001|StorageとVM: 全工程・再実行・切戻し|再開・切戻し|90|PASS|PASS|
|PROC-002|LogとVM: 全工程・再実行・切戻し|再開・切戻し|90|PASS|PASS|
|PROC-003|Storageのみ: 全工程・再実行・切戻し|再開・切戻し|86|PASS|PASS|
|PROC-004|Logのみ: 全工程・再実行・切戻し|再開・切戻し|86|PASS|PASS|
|PROC-005|VMのみ: 全工程・再実行・切戻し|再開・切戻し|88|PASS|PASS|
|PROC-006|両方None: 全工程・再実行・切戻し|再開・切戻し|84|PASS|PASS|
|PROC-007|両方空欄: 全工程・再実行・切戻し|境界|84|PASS|PASS|
|PROC-008|旧CSVはVM列なしをLog扱いにする|境界|5|PASS|PASS|
|PROC-009|対象0件でも東日本StorageとLAWを準備する|境界|10|PASS|PASS|
|PROC-010|東日本・西日本・globalの地域別Storageへ送信する|正常|5|PASS|PASS|
|PROC-011|Canadaのみの旧設定を削除後もJPEを要求しない|正常|7|PASS|PASS|
|PROC-012|Storage kind=StorageV2 の子スコープを探索|正常|3|PASS|PASS|
|PROC-013|Storage kind=BlobStorage の子スコープを探索|正常|3|PASS|PASS|
|PROC-014|Storage kind=BlockBlobStorage の子スコープを探索|正常|3|PASS|PASS|
|PROC-015|Storage kind=FileStorage の子スコープを探索|正常|3|PASS|PASS|
|PROC-016|CSV入力拒否: 不正診断フラグ|異常・停止確認|2|PASS|PASS|
|PROC-017|CSV入力拒否: 不正VMフラグ|異常・停止確認|2|PASS|PASS|
|PROC-018|CSV入力拒否: 空RG|異常・停止確認|2|PASS|PASS|
|PROC-019|CSV入力拒否: 空Workspace|異常・停止確認|2|PASS|PASS|
|PROC-020|CSV入力拒否: 不正Storage名|異常・停止確認|2|PASS|PASS|
|PROC-021|CSV入力拒否: jpeが2か所|異常・停止確認|2|PASS|PASS|
|PROC-022|CSV入力拒否: Storage名25文字|境界|2|PASS|PASS|
|PROC-023|CSV入力拒否: 空Sub|異常・停止確認|2|PASS|PASS|
|PROC-024|初回の既存Storage名を事前停止する|異常・停止確認|2|PASS|PASS|
|PROC-025|ZRS非対応の地域を事前停止する|異常・停止確認|2|PASS|PASS|
|PROC-026|初回の同名新診断を再利用しない|異常・停止確認|2|PASS|PASS|
|PROC-027|新診断を追加する空き5枠上限を事前停止する|境界|2|PASS|PASS|
|PROC-028|両Noneは同名新診断と5件上限に触れない|正常|4|PASS|PASS|
|PROC-029|関係のないVM・VMSSには新関連を作らない|正常|2|PASS|PASS|
|PROC-030|Storage ACL・LAW features・分析保持・他ルールを維持する|正常|13|PASS|PASS|
|PROC-031|既存Storageの不変条件が違う場合は上書きしない|異常・停止確認|3|PASS|PASS|
|PROC-032|既存newDCRと関連は切戻しでBeforeへ復元する|再開・切戻し|9|PASS|PASS|
|PROC-033|copy途中失敗から未完了だけを再開する|再開・切戻し|10|PASS|PASS|
|PROC-034|記録保存に失敗したSubはAzure変更を始めない|異常・停止確認|2|PASS|PASS|
|PROC-035|作業途中CSV選択変更を拒否: copy|再開・切戻し|5|PASS|PASS|
|PROC-036|作業途中CSV選択変更を拒否: verify|再開・切戻し|5|PASS|PASS|
|PROC-037|作業途中CSV選択変更を拒否: delete|再開・切戻し|5|PASS|PASS|
|PROC-038|後続Subの未完了は全Subの旧DELETEを止める|異常・停止確認|7|PASS|PASS|
|PROC-039|旧削除の途中失敗は後続を止め再実行できる|再開・切戻し|9|PASS|PASS|
|PROC-040|copy後に増えた旧対象をverify/deleteが無視しない|異常・停止確認|4|PASS|PASS|
|PROC-041|削除直前に旧設定が変われば以降の削除を止める|異常・停止確認|3|PASS|PASS|
|PROC-042|指定Subだけを切り戻し、他Subはそのまま残す|再開・切戻し|9|PASS|PASS|
|PROC-043|不明Sub指定のrollbackは変更前に拒否する|異常・停止確認|3|PASS|PASS|
|PROC-044|旧復元失敗時は新診断設定を残す|再開・切戻し|6|PASS|PASS|
|PROC-045|切戻し対象が外部変更されたら上書きしない|再開・切戻し|3|PASS|PASS|
|PROC-046|保存先GET失敗を未存在と扱わず削除前に停止する|異常・停止確認|4|PASS|PASS|
|PROC-047|書込み後の期待値不一致を失敗一覧に出す|異常・停止確認|4|PASS|PASS|
|PROC-048|一時的な401は認証を更新して再試行する|正常|3|PASS|PASS|
|PROC-049|登録前providerは記録保存後に登録する|正常|3|PASS|PASS|
|PROC-050|旧診断名と新診断名が同じでもNone側は旧を削除・復元する|再開・切戻し|5|PASS|PASS|
|PROC-051|指定2DCRでも対象外Subの関連を変更しない|正常|5|PASS|PASS|
|PROC-052|未知の地域略称は事前確認で停止する|異常・停止確認|2|PASS|PASS|
|PROC-053|対応する既存Waiverは切戻しでも保持する|再開・切戻し|5|PASS|PASS|
|PROC-054|内容の違う既存Waiverを上書きしない|異常・停止確認|3|PASS|PASS|
|PROC-055|コピー途中の失敗状態から直接切り戻せる|再開・切戻し|11|PASS|PASS|
|PROC-056|コピー完了後は旧設定を書き直さず切り戻せる|再開・切戻し|7|PASS|PASS|
|PROC-057|旧設定を一部削除した失敗状態から直接切り戻せる|再開・切戻し|9|PASS|PASS|
|PROC-058|DCR更新中の応答を待って完了を確認する|正常|4|PASS|PASS|
|PROC-059|更新が完了しない保存先は期限で止め旧設定を残す|異常・停止確認|6|PASS|PASS|
|PROC-060|総保持が1095でも既定値フラグのままなら明示設定する|境界|7|PASS|PASS|
|PROC-061|変更前記録がなければ確認と削除を開始しない|異常・停止確認|3|PASS|PASS|
|PROC-062|通常一覧にある主要タイプと子IDを同じ診断処理へ通す|正常|13|PASS|PASS|
|PROC-063|DCRのInvalidOutputTableだけは反映を待って再試行する|正常|4|PASS|PASS|
|PROC-064|DCRの一般400は再試行せずそのSubを止める|異常・停止確認|5|PASS|PASS|
|PROC-065|新診断の余分なWorkspaceとEventHubを許容しない|異常・停止確認|9|PASS|PASS|
|PROC-066|既存DCRへの余分な収集源追加を許容せず切戻しも上書きしない|再開・切戻し|6|PASS|PASS|
|PROC-067|未選択Subの記録JSONが壊れていても指定Subだけを切り戻せる|再開・切戻し|7|PASS|PASS|
|PROC-068|実runspaceで5件以上の診断GETとPUTを処理する|正常・並列|15|PASS|PASS|
|PROC-069|並列worker1件の失敗を記録し再実行で欠落だけを補う|異常・再開|20|PASS|PASS|
|PROC-070|既存DCRのIdentity[SystemAssigned]を維持して全工程と切戻しを行う|境界・切戻し|12|PASS|PASS|
|PROC-071|既存DCRのIdentity[None]を維持して全工程と切戻しを行う|境界・切戻し|12|PASS|PASS|
|PROC-072|既存DCRのIdentity[SystemAssigned, UserAssigned]を維持して全工程と切戻しを行う|境界・切戻し|23|PASS|PASS|
|PROC-073|通常一覧にないRedis子DBを親地域のStorageへ移行・復元する|正常・切戻し|12|PASS|PASS|
|PROC-074|RedisのDB一覧が空なら存在しない子を調べない|境界|4|PASS|PASS|
|PROC-075|Redis子DBと通常一覧の次ページを両方移行・復元する|正常・切戻し|15|PASS|PASS|
