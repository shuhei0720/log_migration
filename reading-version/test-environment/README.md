# 移行テスト用のリソースを作る

VM、ストレージアカウント、App Serviceなどを2つのサブスクリプションへ作ります。作成後の移行・切り戻しは、[総合テスト手順](INTEGRATION_TEST.md)で試します。

**旧診断設定と旧DCR関連付けは、会社の既存ポリシーで付けます。** このスクリプトは旧設定を作らず、管理グループ・ポリシー・サブスクリプションの所属も変更しません。

## 1. 作成先を指定する

PowerShell 7と、Ownerとしてログイン済みのAzure CLIを使います。VM・VMSS・AKSの作成にはSSH公開鍵も必要です。

`resource_types_fixture.ps1`先頭に指定します。

|変数|指定する内容|
|---|---|
|`$SubscriptionIds`|2つのサブスクリプションID|
|`$ExistingVnetIds`|同じ順序で、それぞれの既存VNetのリソースID|
|`$Locations`|4つの配置先地域。A-R1とB-R2は対応するVNetの地域|

1つ目のサブスクリプションに`fx-<RunId>-a`、2つ目に`fx-<RunId>-b`を作り、リソースを4地域に分けて配置します。AKSなどの管理用リソースグループは別に記録します。

各VNetには次のサブネットが必要です。IPアドレスは実際のVNetから取得します。

|サブネット名|サイズ|
|---|---|
|ProtectSubnet|/27|
|PrivateSubnet|/26|
|ApplicationGatewaySubnet|/24|
|VNetIntegrationSubnet|/26|
|AzureFirewallSubnet|/26|

ASE用にA側のProtectSubnetを`Microsoft.Web/hostingEnvironments`へ、Container Apps用にA側のVNetIntegrationSubnetを`Microsoft.App/environments`へ委任しておきます。スクリプトは既存VNet・サブネットを変更せず、NSGやルートテーブルも関連付けません。

## 2. 作るリソースを選ぶ

提示された56種類から選びます。ストレージの4子サービス、Foundry子プロジェクト、SQL master、Web・Functionsのスロット、Redis子DBも取得します。

Code Signing・Bing・ExpressRouteは提供条件により省略します。Databricks・旧Redisも既定では作りません。実際の作成一覧と省略理由は、Planが出す`plan.json`で確認します。

|引数|指定する内容|
|---|---|
|`SkipTypes`|作らない種類。作成に必要な依存先を省くと停止する|
|`IncludeConditional`|有料・配置条件のあるリソースも含める|
|`IncludeAse`|App Service Environment（ASE）を含める|
|`LoadCount`|負荷テスト用NSGの追加数。サブネットには関連付けない|
|`BudgetJPY`|計画予算。課金を止める上限ではない|

## 3. 計画を確認して作成する

元のリポジトリのルートから実行します。`RunId`は英小文字・数字8～13文字で、毎回違う値にします。

```powershell
Set-Location .\test-environment
$run = 'sample261119'
$options = @{
    RunId = $run
    BudgetJPY = 10000
    IncludeConditional = $true
    IncludeAse = $true
    AdminSshPublicKey = '<SSH公開鍵>'
    LoadCount = 0
}
.\resource_types_fixture.ps1 -Action Plan @options
# plan.jsonを確認する。
.\resource_types_fixture.ps1 -Action Deploy @options
# 会社ポリシーによる診断設定を取得する。
.\resource_types_fixture.ps1 -Action Capture -RunId $run
```

|Action|実行すること|結果を見る場所|
|---|---|---|
|Plan|名前・ID・地域を組み立てる。Azureへは接続しない|`runs/<RunId>/plan.json`の`resources`・`skipped`|
|Deploy|作成先グループの不存在と既存サブネットを確認し、利用登録・リソース作成を行う|`run-ledger.json`の`deployments`・`inventory`・`managedGroups`|
|Capture|リソース・子リソース・ログ項目・診断設定を取得する|同じ記録の`scopes`|

PlanとDeployは、同じ設定・PS1・ARMテンプレートで実行します。作成記録は`runs/<RunId>/run-ledger.json`へ出ます。

## 4. 旧設定を確認して移行テストへ進む

Captureの結果を読み、会社ポリシーで旧診断設定が付いたことを確かめます。

|結果|意味と確認する内容|
|---|---|
|`READ_ONLY_CAPTURED`|取得成功。`diagnosticSettings.value`に旧ワークスペースの`workspaceId`を持つ設定があるか確かめる|
|`EXPECTED_UNSUPPORTED`|そのリソースは診断設定に非対応|
|`NO_EXPORTABLE_CATEGORIES`|取得した一覧にログ・メトリックの項目がない|
|`FAILED`・`UNRESOLVED`|取得失敗か未確認。`resourceId`と`actualErrorCode`を調べる|

`diagnosticSettings.value`が空なら、取得時点で診断設定はありません。DCR関連付けはCaptureに含まれないため、VM・VMSS側で別に確認します。スクリプトはDCR1本と、DCR・Application Insights用Log Analyticsを作りますが、このDCRが移行元の旧DCRとは限りません。

## 途中で失敗した場合と後片付け

API通信は1回につき最大5分待ちます。作成開始から6時間後は新しい変更を始めません。途中で止まったらリソースと作成記録を確認し、再作成には別のRunIdを使います。

削除用スクリプトはありません。終了後に専用リソースグループと、残った管理用グループを削除します。AKSで使うマネージドIDへ付けたPrivateSubnetのNetwork Contributorロールは、グループ削除後も残ります。

Azureサービスの利用登録は戻しません。過去版で作った環境は、その作成記録とPS1・ARMテンプレートで扱います。確認済みの範囲は[検証結果](../test-results/REPORT.md)を参照してください。
