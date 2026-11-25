# 読みやすさを優先した再設計版

各ステップを上から読み、調査・確認・記録・設定の順序を追えるようにした版です。正本の`procedural-migration`と、前の比較版`readable-migration`は残しています。

## まずstep1を読む

[step1_copy.ps1](step1_copy.ps1)を開き、次の順に読みます。設定本文は、Azureへ渡す設定値をまとめた`Body`です。

1. **入力を読む。** `Read-MigrationTargets`でCSVを検査し、`Get-RegionAbbreviations`でStorage名に使う地域略称を取得する。別々の戻り値として受け取る。
2. **Subごとに調べて確認する。** 前回の記録を読み、RGの不存在、旧設定、ポリシー、地域別Storage、新設定の名前・空き枠を順に確認する。
3. **作成する本文を用意する。** 保存先・Waiver・DCR・関連付け・診断設定を組み立てる。この時点ではAzureを変更しない。
4. **変更前の値を記録する。** `Get-MigrationBeforeValues`で現在値を取得し、`Merge-ExistingSettingValues`でDCRなどの指定外の値を新本文へ引き継ぐ。どちらも入力データを変更しない。
5. **作業記録を保存する。** `New-MigrationRecord`で記録を作り、`Merge-MigrationRecord`で前回分と照合・統合する。`Save-MigrationRecord`の保存成功後に変更へ進む。
6. **Azureへ反映する。** Waiver→利用登録→保存先→DCR・関連付け→新診断設定の順で準備する。一致済みを省略し、失敗した対象はCSVへ出す。旧設定は残る。

引数が多い2箇所は、`$diagnosticValues`・`$recordValues`の辞書に項目を縦に並べています。`New-MigrationRecord @recordValues`は、その項目名と値を関数の引数としてまとめて渡す書き方です。

|変数|入っている情報|
|---|---|
|`$target`|今回処理するSubと、そのCSVの指定値|
|`$sources`|現在見つかった旧設定の本文と、診断設定・地域の調査結果|
|`$destinations`|作成するRG・Log Analytics・Storage・保持期間の設定|
|`$newSettings`|新送信設定とWaiverの作成値|
|`$beforeValues`|新設定のIDごとの、最初の変更前の値。元が不在ならnull|
|`$record`|保存・照合・再実行・切り戻しに使う作業記録|

## 続きの処理

|ファイル|処理の順序|
|---|---|
|[step2_verify.ps1](step2_verify.ps1)|記録を読む→旧設定を探し直す→記録後の変化を確認する→保存先・新設定を全件照合→結果CSV。Azureは変更しない|
|[step3_delete.ps1](step3_delete.ps1)|step2で全SubがOK→全Subの旧DCR関連付けを削除→全Subの旧診断設定を削除。削除直前にも再確認し、失敗で全体停止|
|[rollback.ps1](rollback.ps1)|対象Subの記録を選ぶ→全対象を事前確認→全Subの旧設定を復元→新側を変更前へ戻す。保存先・保存済みログ・新設DCR本体は残す|
|[precheck.ps1](precheck.ps1)|任意の事前確認。作成可否を調べて結果CSVを出す。step1は、この結果に依存せず当日の状態を確認する|
|[common.ps1](common.ps1)|利用者設定と共通関数。読み込むだけではCSV取得やAzure通信を行わない|

各関数の目的・処理・引数・戻り値は、関数内のコメントベースヘルプで確認できます。例えば記録保存の説明は次の操作で表示します。

```powershell
. .\clear-migration\common.ps1
(Get-Help Save-MigrationRecord -Full).Description.Text
```

## 前の比較版から整理したこと

- CSV読込みと地域略称の取得を分け、地域情報は戻り値と引数で渡す。
- 旧設定を取得する関数が、呼出し元の地域情報を書き換える処理をなくす。
- 変更前取得・既存値の引継ぎ・記録の構築・統合・保存を、それぞれの関数に分ける。
- Azure通信には対象Sub IDを必須引数で渡す。呼出し元の変数を暗黙に参照しない。
- 更新本文を作る際は、Storageの通信規則やLog Analyticsのfeaturesをコピーして加工する。

固定設定は`common.ps1`先頭に置いています。認証トークンとポリシー定義のキャッシュは、同じ取得を繰り返さないため共通関数内で再利用します。対象Subや調査結果の受け渡しとは分けています。

## 設定と実行

PowerShell 7と、Owner権限でログインしたAzure CLIを使います。`common.ps1`先頭の6変数を確認してください。CSVの6列・送信フラグ・作成値・再実行条件は[正本の仕様](../procedural-migration/README.md)を引き継いでいます。この版は次のパスで実行します。

```powershell
Copy-Item .\clear-migration\targets.example.csv .\clear-migration\targets.csv
az login

# 任意の事前確認。
pwsh.exe -NoProfile -File .\clear-migration\precheck.ps1

# 各工程の結果を確認してから、次を実行する。
pwsh.exe -NoProfile -File .\clear-migration\step1_copy.ps1
pwsh.exe -NoProfile -File .\clear-migration\step2_verify.ps1
pwsh.exe -NoProfile -File .\clear-migration\step3_delete.ps1

# 必要時の切り戻し。SubscriptionIdsを省略すると全Subが対象。
.\clear-migration\rollback.ps1 -SubscriptionIds '対象Sub ID'
```

CSV・作業記録・結果CSVはこのフォルダに保存します。一連の作業は、このフォルダのスクリプトと記録で進めます。

## テストの再実行

PowerShell 7.5.4で、既存90ケース・1,304判定と追加59判定が成功しています。42関数のヘルプ、全30箇所のAzure通信のSub指定も確認しました。初回に検出した地域略称の配列の返し方を修正し、全ケースを再実行した結果です。[検証記録](../test-results/evidence.json)の`clearRedesign`に保存しています。この版の実Azureでの再試験は行っていません。

リポジトリのルートから実行します。Azureへの通信は試験用の応答に置き換えます。

```powershell
# 既存の正常・異常・境界・再実行・切り戻し試験。
pwsh.exe -NoProfile -File .\tests\clear-smoke.ps1

# 入力を変更しないこと、値の受け渡し、対象Subの明示を確認する追加試験。
pwsh.exe -NoProfile -File .\tests\clear-contracts.ps1 -Repository .\clear-migration
```

`clear-smoke.ps1`は既存テストの直接API呼出し5箇所にSub ID引数だけを加え、一時ファイルで実行します。既存テストの判定式・試験用応答は変更しません。
