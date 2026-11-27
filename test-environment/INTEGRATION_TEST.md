# 2サブスクリプションで実行する手順

上から順に実行し、[テストケース](INTEGRATION_TEST_CASES.md)の判定欄へ結果を記入します。テスト用リソースは1回作り、2回の移行に使います。最後は元の設定へ戻します。

## 1. 入力を用意する

PowerShell 7とAzure CLIを使い、両サブスクリプションのOwnerでログインします。2つとも同じ環境（prod・stg・dev）で使えることを確認します。

**移行はサブスクリプション全体が対象です。テスト用リソースグループだけには絞りません。** 会社の既存ポリシーが付けた旧診断設定と旧DCR関連付けを使います。

リポジトリのルートで、実際のIDと未使用の作業フォルダを指定します。以降は同じPowerShellセッションを使います。

```powershell
$ErrorActionPreference = 'Stop'
$repo = (Get-Location).Path
$subscription1 = '<サブスクリプション1のID>'
$subscription2 = '<サブスクリプション2のID>'
$vnet1 = '<サブスクリプション1の既存VNetリソースID>'
$vnet2 = '<サブスクリプション2の既存VNetリソースID>'
$run = 'int261127a'                   # 未使用の英小文字・数字。名前に余裕を持たせ8～10文字を推奨
$workRoot = "C:\Work\log-migration-$run"
if (Test-Path $workRoot) { throw '未使用の作業フォルダ名にしてください。' }
$null = New-Item $workRoot -ItemType Directory
$fixtureRunRoot = Join-Path $workRoot 'fixture'
az login
if ($LASTEXITCODE -ne 0) { throw 'Azureへログインできませんでした。' }
```

`migration/common.ps1`の[6変数](../migration/README.md#commonps1に移行元と環境を指定する)に、自社の移行元・環境・旧DCR・ポリシーを指定します。

`resource_types_fixture.ps1`先頭の`$SubscriptionIds`と`$ExistingVnetIds`にも、上のIDを同じ順で転記します。`$Locations`は、A-R1をVNet1、B-R2をVNet2の地域に合わせます。A-R3・B-R4も、サービスを作れる既存VNetの地域にまとめられます。

両VNetに[指定の5サブネット](README.md#1-作成先を指定する)が必要です。この構成ではASE・Container Apps用の委任は不要です。作成前に、旧DCR2本、既存のポリシー適用除外、VNetのサブネット設定を画面で保存します。

## 2. テスト用リソースを1回作る

次は、Storageと4子サービス、SQL master、Foundryと子プロジェクト、Web・Functionsと各スロット、VM・VMSS、DCRを選ぶ設定です。ASE・Firewall・AKSなどは作りません。

```powershell
$fixture = Join-Path $repo 'test-environment/resource_types_fixture.ps1'
$arm = Get-Content (Join-Path $repo 'test-environment/resource_types.arm.json') -Raw |
    ConvertFrom-Json
$includeTypes = @(
    'microsoft.storage/storageaccounts'
    'microsoft.sql/servers'
    'microsoft.cognitiveservices/accounts'
    'microsoft.cognitiveservices/accounts/projects'
    'microsoft.web/serverfarms'
    'microsoft.web/sites'
    'microsoft.web/sites/slots'
    'microsoft.compute/virtualmachines'
    'microsoft.compute/virtualmachinescalesets'
    'microsoft.insights/datacollectionrules'
    'microsoft.operationalinsights/workspaces'
    'microsoft.network/virtualnetworks'  # 既存VNetを参照する。新規作成はしない。
)
$skipTypes = @($arm.metadata.fixtureTypes.resourceType |
    Where-Object { $_ -notin $includeTypes })
$options = @{
    RunId = $run
    RunRoot = $fixtureRunRoot
    BudgetJPY = [decimal](Read-Host 'この試験の計画予算（円、正の数）')
    IncludeConditional = $true       # VMを選ぶために必要
    IncludeAse = $false
    SkipTypes = $skipTypes
    AdminSshPublicKey = '<ssh-ed25519またはssh-rsaで始まるSSH公開鍵>'
    LoadCount = 0
}
& $fixture -Action Plan @options
$planPath = Join-Path $fixtureRunRoot "$run/plan.json"
$plan = Get-Content $planPath -Raw | ConvertFrom-Json
$plan.resources | Sort-Object bundle, resourceType |
    Format-Table bundle, location, resourceType, name -AutoSize
$plan.skipped | Format-Table resourceType, reason -AutoSize
```

作成予定は18リソースです。Planの一覧と地域を確認します。Planは料金を計算しません。VM2台（Standard_D2s_v4）とApp Serviceプラン1台（P0v3）は時間で課金されるため、予定時間をAzure料金計算ツールで見積もります。VMSSの台数は0です。`BudgetJPY`は計画額で、課金の停止上限ではありません。

Plan後は設定を変えず、Deployを1回実行します。会社ポリシーが旧設定を付けた後にCaptureを実行します。

```powershell
& $fixture -Action Deploy @options
# 会社ポリシーで旧設定が付いた後に実行する。
& $fixture -Action Capture -RunId $run -RunRoot $fixtureRunRoot
$ledgerPath = Join-Path $fixtureRunRoot "$run/run-ledger.json"
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json
$ledger.scopes | Group-Object actualStatus | Select-Object Name, Count
```

[Captureの結果](README.md#4-旧設定を確認して移行テストへ進む)を確認します。旧設定がない種類は未検証と記録します。VM・VMSSの旧DCR関連付けは、Azure画面の「データ収集ルール」でも確認します。旧関連が0件のSubでは、新DCR・新関連を作らないことが正解です。

## 3. 作業フォルダを2つ用意する

rb1とn01で保存先の名前を分けます。rb1はSub1をLog、Sub2をStorageへ送り、n01は逆にします。VMログは両方ともLogです。

```powershell
foreach ($scenario in @('rb1', 'n01')) {
    $casePath = Join-Path $workRoot $scenario
    $null = New-Item $casePath -ItemType Directory
    Copy-Item (Join-Path $repo 'migration/*.ps1') $casePath
    $diagnostic1 = if ($scenario -eq 'rb1') { 'Log' } else { 'Storage' }
    $diagnostic2 = if ($scenario -eq 'rb1') { 'Storage' } else { 'Log' }
    $storage1 = if ($diagnostic1 -eq 'Storage') { "lm${run}jpe${scenario}a" } else { '' }
    $storage2 = if ($diagnostic2 -eq 'Storage') { "lm${run}jpe${scenario}b" } else { '' }
    @"
SubscriptionName,ResourceGroup,StorageAccount,WorkspaceName,LogDestination,VmLogDestination
$subscription1,rg-lm-$run-$scenario-a,$storage1,log-$run-$scenario-a,$diagnostic1,Log
$subscription2,rg-lm-$run-$scenario-b,$storage2,log-$run-$scenario-b,$diagnostic2,Log
"@ | Set-Content (Join-Path $casePath 'targets.csv') -Encoding utf8
}
```

Logへ送る行のStorageAccountは空欄です。不要なStorageを作らないためです。実行後はcommon設定・CSV・作業記録を変更しません。

## 4. 順番に実行する

エラー・NGが出たら次へ進みません。原因を直し、同じ設定と作業記録で同じ工程を再実行します。完了済みの設定は省略されます。

<a id="run-t01"></a>
### T01：移行前の確認

```powershell
$casePath = Join-Path $workRoot 'rb1'
& "$casePath/precheck.ps1"
Import-Csv "$casePath/precheck_results.csv" | Format-Table
```

[対象一覧](#check-targets)を表示して、[T01](INTEGRATION_TEST_CASES.md#t01)を判定します。

<a id="run-t02"></a>
### T02：複製する

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
Import-Csv "$casePath/verify_results.csv" | Format-Table
```

[旧設定の確認](#check-old)を実行し、[T02](INTEGRATION_TEST_CASES.md#t02)を判定します。

<a id="run-t03"></a>
### T03：Sub1だけ戻す

```powershell
& "$casePath/rollback.ps1" -SubscriptionIds $subscription1
```

[旧設定の確認](#check-old)と[画面の確認](#check-portal)を行い、[T03](INTEGRATION_TEST_CASES.md#t03)を判定します。

<a id="run-t04"></a>
### T04：両Subを戻す

```powershell
& "$casePath/rollback.ps1"
```

同じ確認を行い、[T04](INTEGRATION_TEST_CASES.md#t04)を判定します。その後、rb1用の保存先グループだけを削除します。テスト用リソースは残します。

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-rb1-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-rb1-b" --yes
az group exists --subscription $subscription1 --name "rg-lm-$run-rb1-a"
az group exists --subscription $subscription2 --name "rg-lm-$run-rb1-b"
```

両方`false`になってから次へ進みます。Azure CLIの各実行後は`$LASTEXITCODE`が0であることも確認します。

<a id="run-t05"></a>
### T05：正常移行する

```powershell
$casePath = Join-Path $workRoot 'n01'
& "$casePath/precheck.ps1"
Import-Csv "$casePath/precheck_results.csv" | Format-Table
```

[対象一覧](#check-targets)を表示し、[T05の事前確認](INTEGRATION_TEST_CASES.md#t05-precheck)を判定します。

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
Import-Csv "$casePath/verify_results.csv" | Format-Table
```

[旧設定の確認](#check-old)を実行し、[T05の削除前](INTEGRATION_TEST_CASES.md#t05-before)を判定してから削除します。

```powershell
& "$casePath/step3_delete.ps1"
& "$casePath/step4_final_check.ps1"
Import-Csv "$casePath/final_check_results.csv" | Format-Table
```

最終確認のCSVとAzure画面で、[T05の移行後](INTEGRATION_TEST_CASES.md#t05-after)を判定します。

<a id="run-t06"></a>
### T06：削除した旧設定を戻す

```powershell
& "$casePath/rollback.ps1"
```

[旧設定の確認](#check-old)と[画面の確認](#check-portal)を行い、[T06](INTEGRATION_TEST_CASES.md#t06)を判定します。切り戻し後はstep2・step4を実行しません。

## 5. 確認に使う操作

<a id="check-results"></a>
結果CSVは各実行手順で表示します。`Result`列が全件OKかを見ます。NGの理由は`Reason`列で確認します。

<a id="check-targets"></a>
### 対象一覧を見る

precheck直後・step1前に、次を実行します。テスト用以外のリソースも含め、変更してよいIDだけか確認します。

```powershell
. "$casePath/common.ps1"
foreach ($target in $targets) {
    (Get-MigrationPlan -Target $target).OldSettings | Select-Object Id
}
```

<a id="check-old"></a>
### 旧設定が残っているかを見る

各手順から案内された時に、次を実行します。「記録との比較」は、診断設定のログカテゴリ・ログとメトリックの有効／無効・送信先ID・格納方式、DCR関連付けの参照先DCR IDを、保存した移行前の値と照合します。設定IDにはVM・VMSSのIDと関連名も含まれます。削除後は「存在」列だけを見ます。

```powershell
. "$casePath/common.ps1" -SkipCsv
$oldCheck = @(foreach ($file in Get-ChildItem $recordDirectory -Filter '*.json') {
    $record = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    $subscriptionId = $record.Target.SubscriptionId
    foreach ($setting in $record.OldSettings) {
        $actual = Invoke-ArmRequest -Resource $setting -Optional
        [pscustomobject]@{
            サブスクリプション = $record.Target.SubscriptionId
            設定ID = $setting.Id
            存在 = if ($actual) { 'あり' } else { 'なし' }
            記録との比較 = if (Test-Configuration $actual $setting.Body -Kind $setting.Kind) { '同じ' } else { '違う' }
        }
    }
})
$oldCheck | Format-Table サブスクリプション, 存在, 記録との比較, 設定ID -Wrap
```

<a id="check-portal"></a>
### Azure画面で確認する

診断設定は各リソースの「診断設定」、VM・VMSSの関連付けは「データ収集ルール」、適用除外は「ポリシー > 適用除外」で確認します。対象IDは作業フォルダの`records`に記録されています。削除前はstep2、移行後はstep4で設定を照合します。切り戻し時は、エラーなく終了したことと、ケース表の項目を確認します。

保存先はLog Analyticsの「プロパティ」「テーブル」、Storageの「構成」「ネットワーク」「データ保護」「ライフサイクル管理」で確認します。画面にない項目はリソースの「JSONビュー」で確認します。旧DCRは「データソース」「送信先」、VNetは「アドレス空間」「サブネット」を作業前に保存した画面と比べます。

## 6. 片付ける

T06がOKになったら、n01用保存先グループ2個と、テスト用の`fx-$run-a`・`fx-$run-b`を削除します。グループ名と、テスト用グループの`fixtureRun`タグが今回の`$run`かを確認します。削除はT04と同じコマンドで名前を置き換えます。

既存VNetとそのグループ、会社の旧DCR・旧Log Analytics・管理グループ・ポリシーは残します。

工程スクリプトの起動は、作成3回＋移行11回で計14回です。step3内部のstep2を含めると15回です。確認操作とAzure CLIの後片付けは含めません。
