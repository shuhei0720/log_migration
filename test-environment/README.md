# リソース網羅テストの環境

`resource_types_fixture.ps1`と`resource_types.arm.json`で、2サブスクリプションに検証用リソースを分散配置します。現在はコードの簡素化と開発検証中です。**最終総合テストは未開始**です。[検証状況](../test-results/REPORT.md)を参照してください。

## 指定する値

PS1先頭で対象Subと配置リージョンを指定します。現在の公開版は`$SubscriptionIdA`・`$SubscriptionIdB`、既存VNetは`$ExistingVnetIdA`・`$ExistingVnetIdB`です。VNetは名前ではなく、次の形式のリソースIDで指定します。

```text
/subscriptions/<Sub ID>/resourceGroups/<RG名>/providers/Microsoft.Network/virtualNetworks/<VNet名>
```

既存VNetに次の5サブネットがある前提です。実際のアドレス範囲とIDをAzureから取得します。

|名前|サイズ|
|---|---|
|ProtectSubnet|/27|
|PrivateSubnet|/26|
|ApplicationGatewaySubnet|/24|
|VNetIntegrationSubnet|/26|
|AzureFirewallSubnet|/26|

VNet・サブネットの作成や設定変更、NSG・ルートテーブルの関連付けは行いません。必要な委任などがない場合は作成前に停止します。Firewallは参照するVNetと同じRGに配置し、その新規3資源だけを個別に追跡します。

## 操作の流れ

|Action|処理|
|---|---|
|Plan|対象・依存関係・正確な作成先IDを組み立てる。Azureは変更しない|
|Deploy|元の状態を記録し、専用MG・ポリシー・RG・検証資源を作成する|
|Capture|実在する資源と子スコープ、診断カテゴリを取得する|
|Seed|旧診断設定と旧DCR関連、対象外の設定を作成し、実GETで照合する|
|Cleanup|今回の資源を撤去し、元の所属先・設定と照合する|

利用者はOwnerとしてログインしている前提です。初期状態と操作は`runs/<RunId>/`に保存します。同じ実行の台帳やBeforeを削除・書き換えずに使用してください。

承認済みの計画予算は2Sub合計6,000円、保持4時間目標・6時間計画枠です。料金の強制上限ではありません。無料リソースの負荷試験はNSGを使い、有料リソースの保持は短くします。

## 対象と制約

提示された56型のうち、今回の開発環境では50型を新規配置し、VNet1型を既存参照しています。StorageのBlob/File/Queue/Table、Foundryの子プロジェクト、SQL master、Web/Functionのslot、Redis子DBも別途調べます。

|省略する型|理由|
|---|---|
|Code Signing|契約・利用条件により省略|
|Bing|作成条件・提供状況により省略|
|ExpressRoute circuit|接続・料金の制約により省略|
|Databricks|必須のNSG関連付けが、既存サブネットを変更しない条件と両立しない|
|旧Redis|新規作成がサービス終了に伴う制限で拒否される|

作成不可、診断非対応、失敗、未実施を成功に加算しません。実ログの到着確認、サブスクリプションActivity Logの設定、権限テストは行いません。

## 撤去

製品の結果を回収し、送信設定を切り戻してから、テストで作成した保存先と資源を撤去します。既存VNetのRG全体を削除せず、そこに作った所有資源だけを削除します。元のポリシー・RBAC・MG所属と資源一覧を照合し、元の未登録を確認できたプロバイダーだけ登録解除します。

この検証用Cleanupは、移行スクリプトの`rollback.ps1`とは目的が異なります。移行の切り戻しは保存先とログを残し、検証用Cleanupは今回のテスト環境を撤去します。
