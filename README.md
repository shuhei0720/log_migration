# 診断設定・VMログの段階移行

正本は、[procedural-migration の手続型PowerShell 7版](procedural-migration/README.md)です。主要6本をこのフォルダにまとめています。独自関数は5個で、診断設定の調査・複製を最大5件ずつ並列に処理します。

|ファイル|用途|
|---|---|
|precheck.ps1|任意の事前確認。実行せずstep1から始めてもよい|
|step1_copy.ps1|Subごとの直前確認・変更前記録・保存先・新設定の準備|
|step2_verify.ps1|全対象の現在値を確認|
|step3_delete.ps1|全件確認後、旧DCR関連・旧診断設定を削除|
|rollback.ps1|全体または指定Subの送信設定を復元|
|common.ps1|設定値と、各工程で使う5関数|

実行環境はPowerShell 7とAzure CLI 2.54以降です。Windows上のPowerShell 7.6.10 LTSで動作確認しています。

- [設定・実行手順・コードを読むための説明](procedural-migration/README.md)
- [正本を上から読むための学習ガイド](procedural-migration/CODE_LEARNING.md)
- [72ケース・992判定の一覧](test-results/PROCEDURAL_CASES.md)
- [実Azure 100リソースでの速度比較](procedural-migration/README.md#実azureでの速度比較)
- [検証環境の撤去結果](test-results/procedural-powershell7-cleanup.json)

`migration`は旧Windows PowerShell 5.1版、`log_migration.ps1`と原本CSVは最初の原本として保持しています。旧版の回帰試験・185ケースの記録も履歴として残し、正本の72ケースとは区別します。

[リソース網羅テスト用スクリプト](test-environment/README.md)は別に用意しています。最後の総合テストは、正本6本のレビュー後に実施します。今回の100リソースでの速度比較とは別の検証です。
