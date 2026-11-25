# リソース網羅テストの環境

移行テストで使うVM・Storage・App Serviceなどを、2つのサブスクリプションへ作成します。PowerShell 7と、Ownerでログイン済みのAzure CLIで実行します。

作成したリソースへの旧診断設定とDCR関連付けは、会社の既存ポリシーで設定される前提です。このスクリプトはMG・ポリシー・サブスクリプションの所属を変更しません。実施済みの構成と確認範囲は[検証結果](../test-results/REPORT.md)に記録しています。

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

|Action|実行する内容|確認するファイル|
|---|---|---|
|Plan|選択したリソースタイプと依存先から、作成する名前・ID・RG・リージョンを組み立てる。Azureへのアクセスはない|`runs/<RunId>/plan.json`の`resources`と`skipped`|
|Deploy|同名RGの不存在と既存サブネットの条件を確認し、必要な利用登録・専用RG・リソースを作る。続けて作成結果も取得する|`runs/<RunId>/run-ledger.json`の`deployments`・`inventory`・`managedGroups`|
|Capture|作成後のリソース、Storageの子サービスなど、診断カテゴリ、現在の診断設定をAzureから取得して台帳を更新する|同JSONの`scopes`|

リポジトリのルートから、次の順に実行します。`Plan`の内容を確認し、`Deploy`にも同じ変数を渡します。

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
# plan.jsonを確認してから、同じ設定で作成する。
.\resource_types_fixture.ps1 -Action Deploy @options
# 作成後、会社ポリシーによる診断設定を取得する。
.\resource_types_fixture.ps1 -Action Capture -RunId $run
```

`RunId`は英小文字・数字8～13文字です。台帳は`runs/<RunId>/run-ledger.json`へ保存します。旧設定を生成するSeedと撤去用のCleanupはありません。終了後は今回の専用RGと、残っていれば台帳に記録した管理RGを削除してください。AKS用に既存PrivateSubnetへ付与するNetwork ContributorのRBACはRG削除後も残ります。

DCR1本と、DCR・Application Insights用のLAWを作成しますが、このスクリプトから診断設定やDCR関連付けは作成しません。

`Capture`の結果は`run-ledger.json`の`scopes`で確認します。正常に取得した`diagnosticSettings.value`に実在する診断設定が入り、空配列なら取得時点では設定されていません。`actualStatus=READ_ONLY_CAPTURED`は取得成功を表します。`FAILED`や`UNRESOLVED`は`resourceId`と`actualErrorCode`を確認してください。

会社ポリシーが必要な診断設定・DCR関連付けを設定したことを確認してから、[移行スクリプト](../procedural-migration/README.md)でテストします。`Capture`はDCR関連付けを取得しないため、DCR側の対象は移行用の任意precheckなどで確認します。

## 対象と制約

提示された56型をARMの対応表で管理します。Storageの4サービス、Foundry子プロジェクト、SQL master、Web・Functionのslot、Redis子DBも別スコープで読み取ります。Code Signing・Bing・ExpressRouteは提供条件等により省略し、Databricksと旧Redisは既定で省略します。

`SkipTypes`で型を省略できます。必要な依存型まで省略すると停止します。`IncludeConditional`は有料・配置条件のある資源、`IncludeAse`はASEも選びます。`LoadCount`は追加NSG数で、サブネットへ関連付けません。`BudgetJPY`は計画予算です。開始から6時間を過ぎると新しい設定変更を開始しません。必要なRPの登録状態は戻しません。

途中停止後は作成した資源と台帳を確認し、再作成には別のRunIdを使います。過去版で作った環境には、その台帳と作成時のソース2ファイルを使用してください。旧Seed/Cleanup版の実行記録を、この版の結果として扱いません。
