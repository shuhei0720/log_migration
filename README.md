# 診断設定・VMログの段階移行

Azureの診断設定とVM・VMSSのログ送信先を移行するスクリプトです。正本は`procedural-migration`フォルダにあります。

**総合テストと追加の正常通し試験が成功し、全試験資源を撤去しました。** 元の認可設定・MG所属との一致も確認しました。利用登録は28件中26件を復元し、サブスクリプション2のCompute・Networkの2件はAzure側で解除処理中です。構成・実測時間・配布用テストコードの確認範囲は[検証結果](test-results/REPORT.md)に記録しています。

|資料|記載する内容|
|---|---|
|[移行スクリプトの使い方](procedural-migration/README.md)|必要な環境、変数・CSVの設定、実行順、各ファイルの処理、再実行・切り戻し|
|[コード学習ガイド](procedural-migration/CODE_LEARNING.md)|前提となる構文と、コードを上から読むための解説|
|[テスト環境の作成](test-environment/README.md)|既存ポリシーを使う構成、各Subの専用RGへの作成手順と制約|
|[検証結果](test-results/REPORT.md)|実施したテスト、結果、未実施項目|

ルートの`log_migration.ps1`と`log_migration_targets.csv`は原本として保持しています。
