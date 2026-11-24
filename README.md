# 診断設定・VMログの段階移行

Azureの診断設定とVM・VMSSのログ送信先を移行するスクリプトです。正本は`procedural-migration`フォルダにあります。

**最終総合テストを実施中です。** 2サブスクリプション・4地域で追加NSG300件を含む確認を行い、高額なテスト構成は撤去しました。残る省略フラグ・境界ケースの確認と全環境の後片付けを続けています。結果と撤去状況は下記の検証結果へ記録します。

|資料|記載する内容|
|---|---|
|[移行スクリプトの使い方](procedural-migration/README.md)|必要な環境、変数・CSVの設定、実行順、各ファイルの処理、再実行・切り戻し|
|[コード学習ガイド](procedural-migration/CODE_LEARNING.md)|前提となる構文と、コードを上から読むための解説|
|[テスト環境の作成と撤去](test-environment/README.md)|テスト用リソースの構成、作成・撤去の手順と制約|
|[検証結果](test-results/REPORT.md)|実施したテスト、結果、未実施項目|

ルートの`log_migration.ps1`と`log_migration_targets.csv`は原本として保持しています。
