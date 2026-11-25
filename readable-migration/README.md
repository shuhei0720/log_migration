# 関数を役割ごとに分けた比較版

正本の`procedural-migration`を、各ステップだけで作業の順序を読めるように分けた版です。設定値・移行対象・確認条件は引き継いでいます。正本はそのまま残しています。

## 読む順序

まず[step1_copy.ps1](step1_copy.ps1)を上から読みます。関数名が「何をするか」、引数が「何を渡すか」を表します。通信や設定本文の詳細を調べるときだけ、[common.ps1](common.ps1)の該当関数を参照してください。

step1の流れは次のとおりです。

1. `Read-MigrationTargets`でCSVを読み、Subを特定する。
2. `Read-MigrationRecord`と`Get-MigrationPlan`で、前回の記録と当日の旧設定・作成先を調べる。
3. `New-...Settings`・`New-...Destinations`で、作成する本文を用意する。この段階ではAzureを変更しない。
4. `Set-MigrationBeforeValues`で変更前の値を加え、`Save-MigrationPlan`で記録を保存する。
5. Waiver、利用登録、保存先、DCR・関連付けの順に準備する。
6. `Copy-MigrationDiagnostics`で新診断設定を作り、失敗した対象をCSVへ出す。

`Get-...`は取得、`New-...`は本文の組立て、`Assert-...`は不備があれば停止する確認です。`Set-...`・`Remove-...`・`Restore-...`は指定した対象への反映を表します。`Set-MigrationBeforeValues`はAzureではなく、メモリ上の計画を更新します。

|ファイル|読み取れる処理|
|---|---|
|[step1_copy.ps1](step1_copy.ps1)|調査→本文の準備→変更前の記録→保存先・新送信設定の作成→結果出力|
|[step2_verify.ps1](step2_verify.ps1)|記録を読む→旧設定の変化を調べる→保存先・新設定を全件確認→結果出力|
|[step3_delete.ps1](step3_delete.ps1)|全Subの確認→全Subの旧DCR関連付けを削除→全Subの旧診断設定を削除|
|[rollback.ps1](rollback.ps1)|戻すSubを選ぶ→全対象を事前確認→旧設定を復元→新側を変更前へ戻す|
|[precheck.ps1](precheck.ps1)|任意の事前確認。旧設定・ポリシー・作成先・名前・空き枠を調べる|
|[common.ps1](common.ps1)|利用者設定と、上記の処理を支える関数。読み込むだけではCSV取得やAzure通信を行わない|

## 設定と実行

PowerShell 7とAzure CLIを使います。`common.ps1`先頭の6変数を確認し、このフォルダのCSVを用意します。CSVの意味・作成値・再実行条件は[正本の仕様](../procedural-migration/README.md)と同じです。

```powershell
Copy-Item .\readable-migration\targets.example.csv .\readable-migration\targets.csv
az login

# 任意の事前確認。
pwsh.exe -NoProfile -File .\readable-migration\precheck.ps1

# 各結果を確認して次へ進む。
pwsh.exe -NoProfile -File .\readable-migration\step1_copy.ps1
pwsh.exe -NoProfile -File .\readable-migration\step2_verify.ps1
pwsh.exe -NoProfile -File .\readable-migration\step3_delete.ps1

# 必要な場合に切り戻す。SubscriptionIdsを省略すると全Subが対象。
.\readable-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'
```

CSV・作業記録・結果CSVはこのフォルダに保存します。一連の作業は同じフォルダのスクリプトと記録で進めます。

関数の目的・処理・引数・戻り値はコメントベースのヘルプに記載しています。次の操作で説明だけを表示できます。

```powershell
. .\readable-migration\common.ps1
(Get-Help Save-MigrationPlan -Full).Description.Text
```

## 確認方法

PowerShell 7.5.4の再生試験で、90ケース・1,304判定がすべて成功しています。正本とケースごとの結果・判定数も一致しました。関数38個のヘルプと、commonの読込みだけでは外部通信が発生しないことも確認済みです。[検証記録](../test-results/evidence.json)の`readableRefactor`に保存しています。この版の実Azureでの再試験は行っていません。

正本と共通の[再生試験](../tests/procedural-smoke.ps1)を、対象フォルダを指定して実行できます。Azureへの通信を試験用の応答に置き換え、正常・異常・境界条件、再実行、切り戻しを確認します。

```powershell
pwsh.exe -NoProfile -File .\tests\procedural-smoke.ps1 -Repository .\readable-migration
```
