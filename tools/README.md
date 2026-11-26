# 管理グループから移行用CSVを作る

[create_targets.ps1](create_targets.ps1)は、指定した環境の管理グループ配下を調べ、その環境の移行用CSVを作ります。AzureへはGETだけを送り、リソースや設定は変更しません。

## 実行する

会社のAzureへログインし、リポジトリのルートからPowerShell 7で実行します。`-Environment`に開発は`dev`、検証は`stg`、本番は`prod`を指定します。次は開発の例です。

```powershell
az login
pwsh.exe -NoProfile -File .\tools\create_targets.ps1 -Environment dev
```

`migration/generated/`に、指定した環境のファイルだけを作ります。ほかの環境のリソースグループは調べず、そのCSVも変更しません。このフォルダはGitへ登録しません。

|`-Environment`|出力ファイル|管理グループIDの末尾|名前に使う環境名|
|---|---|---|---|
|`dev`|`targets-dev.csv`|`sandbox`|`dev`|
|`stg`|`targets-stg.csv`|`staging`|`stg`|
|`prod`|`targets-prod.csv`|`producrion`|`prod`|

管理グループのIDは、ご提示の値を設定しています。`producrion`の綴りも変更していません。開発の名前には`dev`を使い、管理グループIDの`sandbox`とは区別します。

Azure実機で確認した9ケースと後片付けの結果は、[検証結果](../test-results/REPORT.md)に記録しています。

## 略称を取り出して名前を作る

子管理グループの配下も含めてサブスクリプションを取得し、Azureで現在の状態が`Enabled`のものだけを対象にします。無効なサブスクリプションのリソースグループは調べず、CSVにも出しません。たとえば`rg-pay-prod-alert-01`があれば、略称は`pay`です。

|CSV列|生成する値|
|---|---|
|`SubscriptionName`|サブスクリプションID。表示名が重複しても識別できるようにする|
|`ResourceGroup`|`rg-pay-prod-monitor-01`|
|`StorageAccount`|`stpayprodarchjpe01`|
|`WorkspaceName`|`log-pay-prod-archive-01`|
|`LogDestination`|`Storage`|
|`VmLogDestination`|`Log`|

探すグループ名の末尾は`-<環境名>-alert-01`です。開発では`-dev-alert-01`と`-sand-alert-01`の両方を探し、どちらから取得しても、出力するRG・ストレージ・Log Analytics名には`dev`を使います。略称の英字は小文字にそろえます。送信先を変える場合は、先頭の`$logDestination`・`$vmLogDestination`、または生成後のCSVを編集します。

次の行は、警告とCSVを確認してください。

- 略称が見つからない、または異なる略称が複数ある：略称を`<サービス略称>`にします。開発で同じ略称のdev・sand両方のグループがある場合は、1候補として扱います。
- 生成したストレージ名が24文字を超える、記号が入る、`jpe`が2か所以上ある：略称を省略せず、その名前をCSVへ出して警告します。移行前に修正が必要です。
- 配下に有効なサブスクリプションがない：見出しだけのCSVを作ります。

一覧の取得に失敗した場合は、CSVを出力せずに停止します。選択した環境の有効なサブスクリプションを調べ終わってから書き出すため、取得失敗で前回のCSVを上書きしません。正常に取得できた場合は、その環境のファイルだけを作成・上書きします。

内容を確認し、作業する環境のCSVだけを`targets.csv`へコピーします。本番の例です。

```powershell
Copy-Item .\migration\generated\targets-prod.csv .\migration\targets.csv
```

続いて`common.ps1`の環境・移行元を指定し、[移行手順](../migration/README.md)に沿って事前確認します。保存先名が使用済みかどうかは、移行側の事前確認で調べます。このCSV作成スクリプトは、移行処理を開始しません。

## 移行先へ設定する値

ストレージの地域・保持期間・アクセス制御と、Log Analyticsの設定値は、[移行スクリプトの使い方](../migration/README.md#step1元の設定を残し新しい送信設定を作る)を参照してください。CSV作成スクリプトは名前と送信先の指定を作り、Azureの設定は変更しません。
