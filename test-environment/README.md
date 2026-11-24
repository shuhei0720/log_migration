# リソース網羅テストの環境

`resource_types_fixture.ps1`と`resource_types.arm.json`で、2サブスクリプションへ検証資源を分散配置します。PowerShell 7と、Ownerでログイン済みのAzure CLIを使います。少数の8リソース構成では、Plan→Deploy→Capture→Seed→Cleanupの5操作を実Azureで確認しました。51タイプ・追加NSG300件を含む全体構成は、配置の確認を進めています。検証範囲と結果は[検証結果](../test-results/REPORT.md)を参照してください。

## 指定する値

PS1先頭の`$SubscriptionIds`に2つのSub ID、同じ順番の`$ExistingVnetIds`に既存VNetのリソースID、`$Locations`に4つの配置リージョンを指定します。

既存VNetには次の5サブネットが必要です。IPアドレスはAzureから取得します。

|名前|サイズ|
|---|---|
|ProtectSubnet|/27|
|PrivateSubnet|/26|
|ApplicationGatewaySubnet|/24|
|VNetIntegrationSubnet|/26|
|AzureFirewallSubnet|/26|

VNet・サブネットの作成・更新、NSGやルートテーブルの関連付けはしません。ASEを選ぶ場合はA側ProtectSubnetの`Microsoft.Web/hostingEnvironments`委任、Container Apps環境を選ぶ場合はA側VNetIntegrationSubnetの`Microsoft.App/environments`委任を事前に用意します。不足は作成前に停止します。

## 操作の流れ

|Action|処理|
|---|---|
|Plan|対象と依存関係、作成先の正確なIDをファイルに出す。Azureへのアクセスはない|
|Deploy|元の状態と同名不存在を記録し、専用MG・RG・ポリシーと資源を作成する|
|Capture|実在資源・子スコープ・診断カテゴリを取得する|
|Seed|旧診断設定、旧DCR関連、対象外の設定を作り、実GETで照合する|
|Cleanup|今回作成した環境を撤去し、元の資源・所属・ネットワーク・認可設定と照合する|

PlanとDeployは同じパラメーターで実行します。`RunId`は英小文字・数字8～13文字とし、別の試験には別IDを使います。

```powershell
$run = 'sample261119'
$options = @{
    RunId = $run
    BudgetJPY = 6000
    IncludeConditional = $true
    IncludeAse = $true
    AdminSshPublicKey = '<SSH公開鍵>'
    LoadCount = 300
}
.\resource_types_fixture.ps1 -Action Plan @options
# plan.jsonの対象と予算を確認してから作成する。
.\resource_types_fixture.ps1 -Action Deploy @options
.\resource_types_fixture.ps1 -Action Capture -RunId $run
.\resource_types_fixture.ps1 -Action Seed -RunId $run
# 移行用スクリプトを検証し、送信設定を切り戻してから撤去する。
.\resource_types_fixture.ps1 -Action Cleanup -RunId $run
```

台帳は既定で`runs/<RunId>/`です。作成時のソース2ファイルと台帳を保管します。Capture・Seed・Cleanupはその台帳を使用するため、Beforeや台帳を書き換えないでください。SeedとCleanupは途中停止後も同じIDで再実行できます。Deployが途中で止まった場合は、同じ台帳でCapture・Cleanupを実行して撤去します。

`SkipTypes`で型を省略できます。必要な依存型も省略すると事前停止します。`IncludeConditional`は有料・配置条件のある資源、`IncludeAse`はASEも選びます。`LoadCount`は追加NSG数で、NSGをサブネットへ関連付けません。`BudgetJPY`は計画予算で、請求を止める上限ではありません。新規作成は開始から6時間で停止し、Cleanupは引き続き使えます。

## 対象と制約

提示された56型をARMの対応表で管理します。Storageの4サービス、Foundry子プロジェクト、SQL master、Web・Functionのslot、Redis子DBも別スコープで調べます。診断非対応、配置不可、失敗、未実施は成功に加算しません。ログの実着信、サブスクリプションActivity Log、権限の試験は対象外です。

Code Signing・Bing・ExpressRouteは契約・提供条件等により省略します。Databricksは必須のNSG関連付けが既存サブネットを変更しない条件と両立せず、旧Redisは新規作成の終了制限があるため、既定で省略します。Cosmos DBなどの地域容量不足は別リージョンの選択または`SkipTypes`で扱い、省略理由を試験記録へ残します。

## 未完了の確認

少数構成では5操作とNSGの`categoryGroup=allLogs`の実PUT/GETを確認済みです。全体構成の作成・撤去と、VM・VMSSを含む移行全工程・複合負荷ケースは引き続き確認を進めています。Cosmos DBは作成実績のある東日本へ配置し、SQL・StorageなどはCanada Centralに残して4地域を維持します。

ポリシーは4件作成し、うち移行対象の3件だけを`state.policyAssignmentIds`へ保存します。残る1件は新しいVNetを禁止するガードです。総合テストの実行側もこの3件を使う処理へ対応済みで、LOCAL確認に成功しています。実機での接続確認はこれから行います。

## 撤去時の扱い

新規4RGは今回の所有物として撤去します。Firewall・Public IP・Firewall Policyは参照VNetと同じ既存RGへ配置し、初期不存在と作成後の値を記録した3資源だけを削除します。既存VNetのRG全体は削除しません。

通常StorageはRG削除に任せます。今回新規作成したimmutable capability有効Storageは、送信設定を停止してからBlobを空にします。一時的なアクセス設定は元へ戻します。未知のACL変更、保持ポリシー、lease、holdは解除せず停止します。

全Subの資源、RG、ネットワーク、MG所属、RBAC、ポリシー割り当て、適用除外の復元を確認した後、最初に未登録を確認したプロバイダーだけ登録解除します。不明な差分があれば完了にしません。

このCleanupは検証環境を撤去します。移行用の`rollback.ps1`は送信設定を戻し、保存先と保存済みログを残します。
