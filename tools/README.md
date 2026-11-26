# 管理グループから移行用CSVを作る

[create_targets.ps1](create_targets.ps1)は、指定した環境の管理グループ配下を調べ、その環境の移行用CSVを作ります。AzureへはGETだけを送り、リソースや設定は変更しません。

## 実行する

会社のAzureへログインし、リポジトリのルートからPowerShell 7で実行します。`-Environment`に開発は`dev`、検証は`stg`、本番は`prod`を指定します。次は開発の例です。

```powershell
az login
pwsh.exe -NoProfile -File .\tools\create_targets.ps1 -Environment dev
```

`procedural-migration/generated/`に、指定した環境のファイルだけを作ります。ほかの環境は調べず、そのCSVも変更しません。このフォルダはGitへ登録しません。

|`-Environment`|出力ファイル|管理グループIDの末尾|名前に使う環境名|
|---|---|---|---|
|`dev`|`targets-dev.csv`|`sandbox`|`dev`|
|`stg`|`targets-stg.csv`|`staging`|`stg`|
|`prod`|`targets-prod.csv`|`producrion`|`prod`|

管理グループのIDは、ご提示の値を設定しています。`producrion`の綴りも変更していません。開発の名前には`dev`を使い、管理グループIDの`sandbox`とは区別します。

## 略称を取り出して名前を作る

子管理グループの配下も含めてサブスクリプションを取得し、それぞれのリソースグループを調べます。たとえば`rg-pay-prod-alert-01`があれば、略称は`pay`です。

|CSV列|生成する値|
|---|---|
|`SubscriptionName`|サブスクリプションID。表示名が重複しても識別できるようにする|
|`ResourceGroup`|`rg-pay-prod-monitor-01`|
|`StorageAccount`|`stpayprodarchjpe01`|
|`WorkspaceName`|`log-pay-prod-archive-01`|
|`LogDestination`|`Storage`|
|`VmLogDestination`|`Log`|

探すグループ名の末尾は`-<環境名>-alert-01`です。略称の英字は小文字にそろえます。送信先を変える場合は、先頭の`$logDestination`・`$vmLogDestination`、または生成後のCSVを編集します。

次の行は、警告とCSVを確認してください。

- グループがない、または複数ある：略称を`<サービス略称>`にします。候補を勝手に選ばず、名前の3列を人が埋めます。
- 生成したストレージ名が24文字を超える、記号が入る、`jpe`が2か所以上ある：略称を省略せず、その名前をCSVへ出して警告します。移行前に修正が必要です。
- 配下にサブスクリプションがない：見出しだけのCSVを作ります。

一覧の取得に失敗した場合は、CSVを出力せずに停止します。選択した環境の全サブスクリプションを調べ終わってから書き出すため、取得失敗で前回のCSVを上書きしません。正常に取得できた場合は、その環境のファイルだけを作成・上書きします。

内容を確認し、作業する環境のCSVだけを`targets.csv`へコピーします。本番の例です。

```powershell
Copy-Item .\procedural-migration\generated\targets-prod.csv .\procedural-migration\targets.csv
```

続いて`common.ps1`の環境・移行元を指定し、[移行手順](../procedural-migration/README.md)に沿って事前確認します。保存先名が使用済みかどうかは、移行側の事前確認で調べます。このCSV作成スクリプトは、移行処理を開始しません。

## 提示された設計と、現在の移行コードの比較

以下はコードに設定された値の比較です。会社のAzureにある実設定を確認した結果ではありません。Event・Syslogは、旧DCRの有無に関係なく設定するように変更しました。保持期間は、ご確認いただいた1,095日を使います。

|項目|現在の移行コード|今回の設計との比較|
|---|---|---|
|ストレージの公開ネットワーク|無効（`Disabled`）|一致|
|Blobのバージョン管理・不変性のサポート|有効。不変期間やロックは設定しない|一致|
|ライフサイクル|最終更新から1,095日を超えたappendBlobを削除。アクセス層は変更しない|一致|
|Defender for Storage|アカウント単位で無効。サブスクリプションの設定を上書きする|一致|
|Blobの匿名公開・共有キー|どちらも無効|一致|
|安全な転送・TLS|HTTPS必須、TLS 1.2|一致|
|インフラ暗号化・冗長性|有効、Standard_ZRS|一致|
|ストレージの地域|診断対象のリソースと同じ地域。地域が空・global、または対象がなければ東日本|**今回の東日本固定と異なる。以前の地域別作成の指示を維持**|
|Log Analyticsの公開アクセス|取込・クエリとも有効|一致|
|ワークスペースの保持期間|90日|一致|
|Event・Syslogの合計保持期間|すべての新Log Analyticsで1,095日。旧DCRやVM送信の指定によらず設定|一致|
|アクセス制御モード|リソースまたはワークスペースのアクセス許可を使用|一致|
|Log Analyticsの地域|東日本（`$location`の既定値）|一致|
|保存先の名前|今回追加したスクリプトで命名規則に沿って生成|CSVの確認後に使用|

「365日以内の削除を禁止するポリシー」の作成と、ADX用マネージドプライベートエンドポイントの設定は、現在の移行スクリプトには含まれません。会社の既存ポリシーがこの条件を満たすかは未確認です。
