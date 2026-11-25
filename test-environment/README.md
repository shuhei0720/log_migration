# リソース網羅テストの環境

PowerShell 7と、Ownerでログイン済みのAzure CLIで実行します。会社の既存ポリシーが旧診断設定とDCR関連付けを付与する前提です。MG・ポリシー・サブスクリプションの所属は変更しません。移行スクリプトの実行結果と、各版の確認範囲は[検証結果](../test-results/REPORT.md)を参照してください。

## 指定する値

PS1先頭の`$SubscriptionIds`に2つのSub ID、同じ順番の`$ExistingVnetIds`に既存VNet ID、`$Locations`に4つの配置リージョンを指定します。資源は各Subで1つの専用RG（`fx-<RunId>-a`／`fx-<RunId>-b`）へまとめ、資源ごとのリージョンは分けます。AKSなどが自動で作る管理RGは別に記録します。

既存VNetには次の5サブネットが必要です。IPアドレスは実際のVNetから取得します。

|名前|サイズ|
|---|---|
|ProtectSubnet|/27|
|PrivateSubnet|/26|
|ApplicationGatewaySubnet|/24|
|VNetIntegrationSubnet|/26|
|AzureFirewallSubnet|/26|

VNet・サブネットを作成・更新したり、NSG・ルートテーブルを関連付けたりしません。ASEにはA側ProtectSubnetの`Microsoft.Web/hostingEnvironments`委任、Container Apps環境にはA側VNetIntegrationSubnetの`Microsoft.App/environments`委任を事前に用意します。

## 実行

|Action|処理|
|---|---|
|Plan|型と依存関係、作成する正確なID・RG・リージョンをファイルへ出す。Azureへのアクセスはない|
|Deploy|同名RGと既存サブネットを確認し、必要な利用登録・専用RG・資源を作成する|
|Capture|実在資源、既知の子スコープ、診断カテゴリと現在の診断設定を読み取る|

```powershell
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
# plan.jsonを確認してから、同じ設定で作成する。
.\resource_types_fixture.ps1 -Action Deploy @options
# 会社ポリシーによる設定を確認したい時に実行する。
.\resource_types_fixture.ps1 -Action Capture -RunId $run
```

`RunId`は英小文字・数字8～13文字です。台帳は`runs/<RunId>/run-ledger.json`へ保存します。旧設定を生成するSeedと撤去用のCleanupはありません。終了後は今回の専用RGと、残っていれば台帳に記録した管理RGを削除してください。AKS用に既存PrivateSubnetへ付与するNetwork ContributorのRBACはRG削除後も残ります。

DCR1本と、DCR・Application Insights用のLAWを作成しますが、このスクリプトから診断設定やDCR関連付けは作成しません。`Capture`のカテゴリ取得成功は、診断設定の作成成功を意味しません。実際に付与された設定は`diagnosticSettings`を確認してください。

## 対象と制約

提示された56型をARMの対応表で管理します。Storageの4サービス、Foundry子プロジェクト、SQL master、Web・Functionのslot、Redis子DBも別スコープで読み取ります。Code Signing・Bing・ExpressRouteは提供条件等により省略し、Databricksと旧Redisは既定で省略します。

`SkipTypes`で型を省略できます。必要な依存型まで省略すると停止します。`IncludeConditional`は有料・配置条件のある資源、`IncludeAse`はASEも選びます。`LoadCount`は追加NSG数で、サブネットへ関連付けません。`BudgetJPY`は計画予算です。開始から6時間を過ぎると新しい設定変更を開始しません。必要なRPの登録状態は戻しません。

途中停止後は作成した資源と台帳を確認し、再作成には別のRunIdを使います。過去版で作った環境には、その台帳と作成時のソース2ファイルを使用してください。旧Seed/Cleanup版の実行記録を、この版の結果として扱いません。
