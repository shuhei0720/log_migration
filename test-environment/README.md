# リソース網羅テストの環境

VM・Storage・App Serviceなどを2つのSub（サブスクリプション）へ作成します。PowerShell 7と、Ownerでログイン済みのAzure CLIを使います。

旧診断・DCR関連は会社の既存ポリシーで設定する前提です。管理グループ・ポリシー・Sub所属は変更しません。確認済みの範囲は[検証結果](../test-results/REPORT.md)を参照してください。

自社2Subで正常系・複製後切り戻し・削除後切り戻しを確認する場合は、[総合テスト手順](INTEGRATION_TEST.md)を使います。

## 指定する値

PS1先頭の`$SubscriptionIds`にSub IDを2つ、同順の`$ExistingVnetIds`に既存VNet ID、`$Locations`に4地域を指定します。各Subの専用RG（`fx-<RunId>-a`／`-b`）へ作り、資源の地域を分けます。AKSなどの管理RGは別途台帳へ記録します。

既存VNetには次の5サブネットが必要です。IPは実際のVNetから取得します。

|名前|サイズ|
|---|---|
|ProtectSubnet|/27|
|PrivateSubnet|/26|
|ApplicationGatewaySubnet|/24|
|VNetIntegrationSubnet|/26|
|AzureFirewallSubnet|/26|

VNet・サブネットは更新せず、NSG・ルートテーブルも付けません。事前にA側のProtectSubnetを`Microsoft.Web/hostingEnvironments`へ、VNetIntegrationSubnetを`Microsoft.App/environments`へ委任します。

## 実行

|Action|処理|確認先|
|---|---|---|
|Plan|依存先を含む名前・ID・RG・地域を組み立てる。Azureへのアクセスなし|`runs/<RunId>/plan.json`の`resources`・`skipped`|
|Deploy|RGの不存在と既存サブネットを確認し、RP登録・RG・資源作成後に結果を取得する|`run-ledger.json`の`deployments`・`inventory`・`managedGroups`|
|Capture|資源・子スコープ・診断カテゴリ・現在の診断設定を読み取る|同台帳の`scopes`|

API通信の待機は300秒（5分）です。

ルートから次を実行します。Plan確認後、同じ設定でDeployします。

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

`RunId`は英小文字・数字8～13文字、台帳は`runs/<RunId>/run-ledger.json`です。旧設定の生成・撤去機能はありません。終了後は専用RGと残った管理RGを削除します。AKS用のPrivateSubnetのNetwork ContributorはRG削除後も残ります。

DCR1本と、DCR・Application Insights用のLog Analyticsを作ります。診断設定・DCR関連は作りません。

Captureの`diagnosticSettings.value`が空なら、その時点で診断設定がありません。`READ_ONLY_CAPTURED`は取得成功で、設定済みを意味しません。`FAILED`／`UNRESOLVED`は`resourceId`・`actualErrorCode`を確認します。DCR関連はCaptureの対象外です。

会社ポリシーで旧設定がそろったことを確認し、[移行スクリプト](../procedural-migration/README.md)でテストします。DCR側の対象は移行用precheckなどで確認できます。

## 対象と制約

提示56型の対応表を使い、Storageの4サービス・Foundry子プロジェクト・SQL master・Web／Function slot・Redis子DBも読み取ります。Code Signing・Bing・ExpressRouteは提供条件等で省略し、Databricks・旧Redisは既定で省略します。

|変数|用途|
|---|---|
|`SkipTypes`|省略する型。必要な依存型を省くと停止|
|`IncludeConditional`|有料・配置条件のある資源も選ぶ|
|`IncludeAse`|ASEも選ぶ|
|`LoadCount`|追加NSG数。サブネットへ関連付けない|
|`BudgetJPY`|計画予算|

開始6時間後は新規の変更を始めません。RP登録は戻しません。途中停止後は資源・台帳を確認し、再作成には別のRunIdを使います。過去版の環境は、その台帳と作成時のソース2ファイルで扱ってください。
