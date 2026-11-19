# 診断設定・VMログの段階移行

正本は [procedural-migration](procedural-migration/README.md) のPowerShell 7版です。診断設定とVM・VMSSのDCR関連付けを、新しい保存先へ段階的に切り替えます。旧設定は複製時に残し、確認後に別スクリプトで削除します。

**現在は開発検証中です。最終総合テストは開始していません。** 検証状況と実施したケースは [検証結果](test-results/REPORT.md) にまとめます。Azureの新規配置は停止しており、コードの完成報告と利用者レビューを先に行います。

|ファイル|実行する内容|
|---|---|
|[precheck.ps1](procedural-migration/precheck.ps1)|現在の旧診断設定・指定2DCRの関連を調べ、地域別Storage名の空き・ZRS対応、新診断名の重複・5枠上限、ポリシー割り当てを確認する。結果は`precheck_results.csv`へ出力。任意実行で、Azureへの書き込みや変更前記録の保存は行わない。|
|[step1_copy.ps1](procedural-migration/step1_copy.ps1)|Subごとに直前調査し、旧設定と変更予定をJSONへ保存する。Waiver、保存先、Event・Syslog用の新DCRとVM・VMSSへの関連、新診断設定を順に準備する。診断設定のログ・メトリックを引き継ぎ、CSVで選んだ宛先へ複製する。旧設定は残す。|
|[step2_verify.ps1](procedural-migration/step2_verify.ps1)|現在の旧設定を再調査し、記録後の追加・変更を検出する。保存先・Waiver・新DCR・新関連・新診断設定を実GETで記録と照合し、`verify_results.csv`へ出力する。NGがあれば全体を失敗とする。|
|[step3_delete.ps1](procedural-migration/step3_delete.ps1)|最初にstep2で全対象を確認し、成功した場合だけ旧DCR関連→旧診断設定の順に削除する。各削除の直前にも旧設定と必要な新設定を照合し、不一致・失敗があれば以降を停止する。保存先・新設定・Waiverは残す。|
|[rollback.ps1](procedural-migration/rollback.ps1)|記録から全体または指定Subを選び、現在値を事前照合する。旧DCR関連→旧診断設定を復元してから、新設定を変更前の値へ戻す。今回新設したWaiverは削除し、保存先・保存済みログ・今回新設したDCR本体は残す。|
|[common.ps1](procedural-migration/common.ps1)|各工程が読み込む共通ファイル。環境別の旧DCR・ポリシーと入力CSVを用意し、Azure API呼び出し、設定の照合、書き込み用本文の取り出し、変更前記録の読み込み、現在の対象調査を行う5関数を定義する。|

処理順、作成する設定、再実行時の扱い、出力ファイルは、[各ファイルの具体的な処理](procedural-migration/README.md#各ファイルの具体的な処理)を参照してください。

必要な環境はPowerShell 7とAzure CLIです。SubはCSVの順に処理し、診断設定の調査・複製だけを最大5件ずつ並列に処理します。

- [設定方法・実行順・再開と切り戻し](procedural-migration/README.md)
- [コードを上から読むための学習ガイド](procedural-migration/CODE_LEARNING.md)
- [テスト環境の作成と撤去](test-environment/README.md)
- [実施したテストと結果](test-results/REPORT.md)

`log_migration.ps1`と`log_migration_targets.csv`は原本として保持しています。通常の移行では正本フォルダのスクリプトと`targets.csv`を使用します。
