# 診断設定・VMログの段階移行

Azureの診断設定とVM・VMSSのログ送信先を移行します。実行するスクリプトは`migration/`にまとめています。PowerShell 7とAzure CLIを使います。

|資料・フォルダ|用途|
|---|---|
|[移行スクリプトの使い方](migration/README.md)|設定する変数・CSV・実行順・再開・切り戻し|
|[コード学習ガイド](migration/CODE_LEARNING.md)|コードを上から読み、各部分の処理を理解する|
|[環境別CSVの作成](tools/README.md)|管理グループとalert用リソースグループから、移行先の名前を作る|
|[テスト環境の作成](test-environment/README.md)|既存VNetと会社ポリシーを使い、移行テスト用のリソースを作る|
|[2サブスクリプションでの総合テスト手順](test-environment/INTEGRATION_TEST.md)|正常系と、複製後・旧設定削除後の切り戻しを確認する|
|[検証結果](test-results/REPORT.md)|テストケース・結果・確認できていない範囲|
|`tests/`|Azureへの通信を試験用の応答に置き換えて、コードを検証する|
|`archive/`|改修前の原本と、過去の検証記録を参照用に保存する|

原本の[log_migration.ps1](archive/original/log_migration.ps1)と[入力CSV](archive/original/log_migration_targets.csv)は、内容を変えずに保管しています。
