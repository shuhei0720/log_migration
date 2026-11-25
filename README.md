# 診断設定・VMログの段階移行

Azureの診断設定とVM・VMSSのログ送信先を移行します。正本は`procedural-migration`です。

|資料|内容|
|---|---|
|[使い方](procedural-migration/README.md)|環境・CSV・実行順・各ファイルの処理・再実行・切り戻し|
|[コード学習ガイド](procedural-migration/CODE_LEARNING.md)|step1からコードを上から読むための解説と、構文の補足|
|[関数分割の比較版](readable-migration/README.md)|役割ごとの関数へ分け、各ステップで作業順序を読めるようにした版|
|[テスト環境の作成](test-environment/README.md)|既存VNet・会社ポリシーを使うテスト資源の作成手順|
|[検証結果](test-results/REPORT.md)|実施内容・結果・実測時間・未実施項目|

総合テスト・追加の正常通し試験は成功し、試験資源は撤去済みです。認可設定・MG所属も元に戻っています。利用登録は28件中26件を復元し、Sub2のCompute・NetworkはAzure側で解除処理中です。詳細は検証結果を参照してください。

ルートの`log_migration.ps1`と`log_migration_targets.csv`は原本です。
