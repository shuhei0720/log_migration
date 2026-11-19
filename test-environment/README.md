# 56 resourceTypes テスト環境候補

配布コードは `resource_types_fixture.ps1` と `resource_types.arm.json` の2ファイルです。
現在は[正本とテストコードの開発検証中で、最終総合テストは未開始です](../test-results/FINAL_TEST_PROGRESS.md)。本体は既存VNet・サブネットを参照し、NSG・ルートテーブル・委任を追加しません。Databricksは専用NSG必須条件のため今回は明示省略します。
初回の管理グループ反映待ちなどを修正し、現在は2サブスクリプションに型別の開発検証環境を配置しています。旧診断66スコープ・旧DCR関連8件を実PUT/GETで確認しました。環境作成コードは、読みやすい手続型へ整理中です。
主要6本の正本は [procedural-migrationのPowerShell 7版](../procedural-migration/README.md)です。正本のユーザーレビュー後に、最後のリソース網羅テストへ進みます。旧原本と原本CSVは変更していません。

## 設定と費用

PS1先頭の2変数で対象subscriptionを指定します。既存VNetは、先頭の2変数または同名引数でリソースIDを指定します。

```powershell
$SubscriptionIdA = '5f1b809c-f59f-4489-8211-4bef16a0463a'
$SubscriptionIdB = 'bfda36ec-1aed-4b0c-a907-4d4809c63888'

$network = @{
    ExistingVnetIdA = '/subscriptions/5f1b809c-f59f-4489-8211-4bef16a0463a/resourceGroups/rg-fx-net261118a-a/providers/Microsoft.Network/virtualNetworks/vnet-fx-net261118a-a'
    ExistingVnetIdB = '/subscriptions/bfda36ec-1aed-4b0c-a907-4d4809c63888/resourceGroups/rg-fx-net261118a-b/providers/Microsoft.Network/virtualNetworks/vnet-fx-net261118a-b'
}
```

VNet IDからRG名・VNet名を取得し、サブネットのIDと実際のIP範囲はAzureから取得します。VNet・サブネットの作成、更新、削除は行いません。
Plan/Deployで指定したIDは台帳へ保存し、Capture/Seed/Cleanupでは保存済みのIDを使います。
既存リージョン、下表のサイズ、必要な委任・NSGを作成前に検証します。IPアドレスの基部は固定しません。

| サブネット名 | サイズ | Aでの用途 | Bでの用途 |
|---|---|---|---|
| ProtectSubnet | /27 | ASE専用 | VMSS・Private Endpoint・NIC・内部LB |
| PrivateSubnet | /26 | VM・AKS Overlay | Databricks専用 |
| ApplicationGatewaySubnet | /24 | 未使用 | Application Gateway専用 |
| VNetIntegrationSubnet | /26 | Container Apps環境専用 | Databricks専用 |
| AzureFirewallSubnet | /26 | 未使用 | Firewall Standard専用 |

配置候補はA/Japan East、A/Canada Central、B/Japan West、B/West US 2です。
Web・Function・各slotは、作成実績のあるB/West US 2のLinux S1を共有します。
VMとAKSはA/Japan EastのD2s_v4とし、2 VM＋2 nodeで8 vCPUを使用します。
依存を共有し、2 subscription×4 regionへ全型を複製しません。
region overrideは先頭のbundle設定へ理由付きで指定します。

費用は [BUDGET_ESTIMATE.md](./BUDGET_ESTIMATE.md) を確認してください。
53型（ASE含む）の予算6,000円はユーザー承認済みです。旧テストリソースは撤去済みです。
Networkの利用登録は次のテストで再利用し、記録した元の未登録状態への最終復元は全テストの撤去後に実施します。
有料リソースの保持は4時間目標・6時間の計画枠で、見積は約4,192円／約5,355円です。8時間案は予算超過のため未承認です。
`BudgetJPY` は予算記録・実行前条件であり、請求を止めるhard capではありません。
作成/削除待ち、従量料金、地域差、税・為替によって実額は変わります。

## 実行順序

fixture controller自体はWindows PowerShell 5.1以降に対応するコードです。正本6本を含む一連の検証はPowerShell 7（pwsh.exe）＋Azure CLIで実行します。Storage cleanupだけCLI同梱Python/SDKを使用します。
別Python/SDK導入・pip・外部PowerShell module・Bicepは不要です。Deploy前にSDKをLOCAL preflightします。
scriptは `az login` を実行しません。既存の許可済みsessionを使用します。
利用登録解除の完了値は `NotRegistered` と `Unregistered` の両方を受理し、実際の応答値を台帳へ残します。
資産撤去の完了を台帳へ保存した後は、Cleanupの再実行でもサービスAPIを呼ばず、利用登録の復元だけを再開します。`Unregistering` には解除要求を再送しません。

1. **Plan**：LOCAL JSON生成だけです。既定actionもPlanです。

```powershell
$run = 'trial261118f'
.\resource_types_fixture.ps1 -Action Plan -RunId $run -IncludeConditional -IncludeAse @network
```

`runs/<runId>/plan.json` と見積をreviewします。選択、region、コードhashを固定します。
同じrunIdのPlan再作成は拒否します。変更時は新しいrunIdでreviewしてください。

2. **Deploy**：既存VNetの事前準備と実行計画の確認後に実行します。
以下は承認予算6,000円の例です。

```powershell
$publicKey = Get-Content "$env:USERPROFILE\.ssh\id_ed25519.pub" -Raw
.\resource_types_fixture.ps1 -Action Deploy -RunId $run -BudgetJPY 6000 `
  -IncludeConditional -IncludeAse -AdminSshPublicKey $publicKey @network
```

作成前snapshot、RP登録、新MG/policy、専用RG、共有基盤の後、4独立resource bundleを非同期投入します。
exact deployment IDをpollし、全bundleの成功後にDCRAと全scopeを調べます。
VNetは既存資源として参照し、その他の作成先で同名資源があれば停止します。失敗したrunは記録を確認してCleanupへ進みます。
AKS用の新規IDへ必要なサブネット権限だけを付け、AKS・node RGの消失後にその割り当てだけを削除します。

3. **Capture / Seed**：実在scopeと実categoryを調べ、SourceDiagを作ります。

```powershell
.\resource_types_fixture.ps1 -Action Capture -RunId $run
.\resource_types_fixture.ps1 -Action Seed -RunId $run -BudgetJPY 6000
```

SourceDiagは実GETしたlogs/metricsから構成し、PUT後にGETで照合します。
old-only VM/VMSSにはSourceDiagを作りません。auxLA宛の非対象設定も保持します。
既存VNetでは元の診断設定を記録し、同名を上書きせず、実PUT・GETできた新規設定だけを所有台帳へ記録します。
空category、汎用404、auth失敗、作成省略をPASS/安全skipへ変換しません。
Storage宛PUTの可否はSourceLA宛成功とは別に検証してください。

4. **正本6本を別実行**：[procedural-migration](../procedural-migration/README.md)の6本を作業用フォルダへコピーし、common.ps1の設定値とtargets.csvへラボの値を与えて、pwsh.exeから実行します。
F1/F2とrollbackのorchestratorはこのfixtureに含めません。製品のgeneric処理は変更しません。
実行後はCaptureをもう一度行い、製品が作った専用RG内資産と拡張設定を台帳へ含めます。

5. **Cleanup**：同じrun台帳を使い、途中再開できます。

```powershell
.\resource_types_fixture.ps1 -Action Capture -RunId $run
.\resource_types_fixture.ps1 -Action Cleanup -RunId $run
```

runIdとexact IDだけを対象にします。SourceDiag/DCRA停止後、有料/managed rootを全て先にDELETE開始します。
所有Storageのversion/snapshotを回収し、全RGのDELETE投入後に待ちます。managedRGは親削除で回収します。
Storageはaccess有効GET後30秒待ち、metadata/exact IDで削除し、3 access設定とfull ACLをfinallyで復元・GET確認します。
current版はfresh version/ETag一致時だけIf-Match BASE解除→同ID削除→404確認し、変更/途中失敗はincompleteです。
元MG parentとsoft-deleteを確認し、最後にproviderを復元します。実VNetregionの自動Watcherも初期不存在の場合だけ回収します。
帰属不明の外部新規資産は保持・報告し、残存があればcleanup不完全です。
既存VNet・サブネット・所属RGは保持します。追加した診断設定とAKS用割り当てだけを撤去し、検証済みのDatabricks管理NSGルール差分だけを元に戻します。

## 成果物と独立比較

すべて `runs/<runId>/` に保存します。

| 成果物 | 内容 |
|---|---|
| `run-ledger.json` | 初期snapshot、write intent/結果、exact ID、deployment poll、元MG parent、cleanup状態 |
| 同上 `sourceWorkspaceId` | SourceLAの実ID |
| 同上 `resources` | `role=old-dcr-1` / `old-dcr-2` の旧DCR ID、aux/base LA等 |
| 同上 `managementGroupId` / `operations` | 新MGと3 policy assignmentの実PUT ID |
| `expected-scopes.json` | 独立予定ID、存在GET、category応答 |
| `source-diag-put-success-scopes.json` | SourceDiag PUT/GET成功scopeだけ |
| `positive-expected-scopes.json` | 正本copyの探索結果との独立期待集合 |
| `scope-capabilities.json` | 成功、非対応、失敗、未解決、Storage宛未実測の区別 |
| `untargeted-diagnostic-baseline.json` | auxLA宛設定の不変比較用原本 |
| `external-differences.json` / `cleanup-result.json` | 外部差分と最終残存結果 |

precheckは記録を作りません。正本のstep1_copy実行後、作業用フォルダの `records/<環境>/<Sub ID>.json` を読みます。
`OldSettings` の `Kind=Diagnostic` だけを選び、`Id` 末尾の `/providers/Microsoft.Insights/diagnosticSettings/設定名` を外してリソースscopeへ戻します。
その集合と独立positive集合をcase-insensitiveで重複排除し、**双方向完全一致**を確認します。この期待IDを製品入力へ注入してはいけません。
SQLmaster/Redis default DB等でSourceDiag成功なのにdiscoveryへ出なければ `DISCOVERY_GAP` です。
型別分岐、manual IDs、SourceDiagの無言削除で通しません。

## coverageと未検証事項

56 exact typeをmetadataに保持し、最大53型を対象にします。67 ARM定義・57キーと、既存VNet2件を使用します。
VNetは新規作成件数へ含めず、既存資源への診断設定の対象として記録します。
F1/F2のLA4本＋fixture LA3本＝7本、DCRは新4本＋fixture3本＋Monitor自動分最大1本＝最大8本です。
存在だけの固定料金はなく、ingestion予備枠は全体0.1GBのままです。
ASEは `IncludeConditional` に加えて `IncludeAse` の明示選択です。
Bing廃止、Code Signing全月額/paid offer条件、ExpressRoute契約条件の3型は理由付き省略案です。
Web/Functionと各slotはS1を共有します。Functionは空code・停止状態で、host動作は未検証です。

LOCAL証跡は [resource-types-local.json](../test-results/resource-types-local.json) にまとめています。
PowerShell38項目＋保持時間/async21＋Watcher8＋Storage fake33、JSON94項目をLOCAL確認済みです。
実WinPS5.1が手元にないため、PS7 AST＋明示的な5.1構文制約の確認までです。
本改修版の実WinPS5.1、サービスのARM deployment、診断/Storage宛PUT、最終cleanupは未実行です。
リージョン/API一覧・東日本D2s_v4のクォータと、既存ネットワーク・新規VNet拒否ポリシーは実確認済みです。

現行版Blobの履歴化後削除は、旧テスト環境の1バージョンで実証しました。本候補による53タイプ環境の作成・移行・全撤去はこれから検証します。

## 総合テストの予定

| パターン | Sub A / Sub B | 確認する流れ |
|---|---|---|
| F1 | Storage / Log | 複製途中の実停止→再開→変更0の再実行→全件確認→旧設定の全件削除→全体切り戻し |
| F2 | Log / Storage | 複製途中の実停止→Aだけ切り戻し→再開・再実行→全件確認→旧設定削除途中の実停止→全体切り戻し |

複製前に、実際に旧設定の作成・読み戻しが成功した対象と、移行スクリプトの検出対象が双方向で一致することを確認します。対象外設定、指定外サブスクリプション、旧DCR関連付けの復元順序も照合します。前回確認済みの8条件と889判定は再利用し、新しいリソースで必要な差分を確認します。

作成不可・診断設定非対応・失敗・未解決は理由付きで記録し、成功件数へ含めません。ログの到着待ち・意図的なデータ生成は行いません。
