# 診断設定・VMログの段階移行

正本は [procedural-migration](procedural-migration/README.md) のPowerShell 7版です。診断設定とVM・VMSSのDCR関連付けを、新しい保存先へ段階的に切り替えます。旧設定は複製時に残し、確認後に別スクリプトで削除します。

**現在は開発検証中です。最終総合テストは開始していません。** 検証状況と実施したケースは [検証結果](test-results/REPORT.md) にまとめます。Azureの新規配置は停止しており、コードの完成報告と利用者レビューを先に行います。

|ファイル|役割|
|---|---|
|`precheck.ps1`|任意の事前確認。実行せずstep1から始められる|
|`step1_copy.ps1`|Subごとの直前確認・変更前記録・保存先・新設定の準備|
|`step2_verify.ps1`|旧設定の変化と、保存先・新設定の現在値を確認|
|`step3_delete.ps1`|全件確認後、旧DCR関連・旧診断設定を削除|
|`rollback.ps1`|全体または指定Subの送信設定を復元|
|`common.ps1`|設定値・CSV読込み・各工程で使う5関数|

必要な環境はPowerShell 7とAzure CLIです。SubはCSVの順に処理し、診断設定の調査・複製だけを最大5件ずつ並列に処理します。

- [設定方法・実行順・再開と切り戻し](procedural-migration/README.md)
- [コードを上から読むための学習ガイド](procedural-migration/CODE_LEARNING.md)
- [テスト環境の作成と撤去](test-environment/README.md)
- [実施したテストと結果](test-results/REPORT.md)

`log_migration.ps1`と`log_migration_targets.csv`は原本として保持しています。通常の移行では正本フォルダのスクリプトと`targets.csv`を使用します。
