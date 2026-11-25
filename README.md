# 診断設定・VMログの段階移行

Azureの診断設定とVM・VMSSのログ送信先を移行するスクリプトです。正本は`procedural-migration`フォルダにあります。

**現在の総合テストと試験資源の撤去は完了しました。** 両Subの資源・RG各0件と元の認可・MG所属を確認済みです。利用登録28件のうち、BのNetwork・Computeの2件は解除の反映待ちで、元状態への最終照合が残っています。最後の正常通し試験を行う方針は了承済みですが、追加予算の確認待ちで実行は未着手です。詳細は[検証結果](test-results/REPORT.md)に記載しています。

|資料|記載する内容|
|---|---|
|[移行スクリプトの使い方](procedural-migration/README.md)|必要な環境、変数・CSVの設定、実行順、各ファイルの処理、再実行・切り戻し|
|[コード学習ガイド](procedural-migration/CODE_LEARNING.md)|前提となる構文と、コードを上から読むための解説|
|[テスト環境の作成と撤去](test-environment/README.md)|テスト用リソースの構成、作成・撤去の手順と制約|
|[検証結果](test-results/REPORT.md)|実施したテスト、結果、未実施項目|

ルートの`log_migration.ps1`と`log_migration_targets.csv`は原本として保持しています。
