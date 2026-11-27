# 自社の2サブスクリプションで実行する手順

実行するコマンドを順番に載せています。確認内容と合格条件は[テストケース](INTEGRATION_TEST_CASES.md)にまとめています。各ケースの判定欄へ結果を記入してから、次の手順へ進んでください。

テスト用リソースは**1回だけ作成し、2回の移行に使います**。終了時は旧設定へ戻し、今回作成したリソースを削除します。

## 1. 作業する場所と入力を決める

PowerShell 7とAzure CLIを使い、両サブスクリプションのOwnerでログインします。2つとも同じ環境（`prod`・`stg`・`dev`）として扱えること、Azure管理APIと`raw.githubusercontent.com`へ接続できることを確認します。

**移行対象はサブスクリプション全体です。テスト用リソースグループ（RG）には限定されません。** 既存リソースを含め、指定する旧Log Analytics宛ての診断設定と旧DCR2本への関連付けを変更します。会社の管理グループ・ポリシー・旧DCRは既存のものを使い、旧診断設定と関連付けは会社のポリシーで付けます。

リポジトリのルートで、以降は同じPowerShell 7セッションを使います。

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

`migration/common.ps1`先頭の[6変数](../migration/README.md#commonps1に移行元と環境を指定する)に、自社の旧Log Analytics・環境・旧DCR・ポリシーを指定します。後でケースごとにこの設定をコピーします。

`test-environment/resource_types_fixture.ps1`先頭の[作成先の3変数](README.md#1-作成先を指定する)を編集します。`$SubscriptionIds`と`$ExistingVnetIds`には、上のSub・VNetを同じ順序で転記します。セッション変数を入力しただけでは、ファイル内の値は変わりません。

`$Locations`の`A-R1`はVNet1、`B-R2`はVNet2の地域です。`A-R3`はStorage・SQL・Foundry、`B-R4`はWeb・Functionsを作れる地域にします。少なくとも2地域を使い、`A-R3`・`B-R4`を既存VNetの地域にまとめられます。Webの地域はVNetと無関係ですが、P0v3を利用できる地域にします。

両VNetに[指定の5サブネット](README.md#1-作成先を指定する)があることを確認します。この構成ではASE・Container Appsを作らないため、その委任は不要です。

既存VNet・サブネットの構成を変更せず、NSG・ルートテーブルも関連付けません。VMはVNet1のPrivateSubnet、VMSSはVNet2のProtectSubnetを使います。作成前に両VNetのアドレス空間と、各サブネットの範囲・委任・NSG・ルートテーブルの画面を保存します。

## 2. 作成する種類を絞り、Planを確認する

次の代表構成を使います。SQLはサーバーと自動作成される`master`だけとし、有料のユーザーデータベースを作りません。

|作るもの|確認する対象・費用が増える条件|
|---|---|
|Storage 1個|本体とBlob・File・Queue・Tableの4子サービス。データ量・操作・ログの保存で課金|
|SQLサーバー1個|`master`の診断設定。ユーザーデータベースは省略|
|Foundry 1個と子プロジェクト1個|親と子の診断設定。モデル配備・推論は行わない|
|Web・Functions各1個と各スロット|共通のApp Serviceプラン1台。**現行テンプレートはP0v3で、時間に応じた費用が発生**|
|VM 2台・VMSS 2基|VMはStandard_D2s_v4とOSディスクを課金。VMSSはインスタンス数0のまま、親への関連付けを確認|
|DCR 1本・Log Analytics 2個|取得・探索の対象。作成したDCRは会社指定の旧DCRとは別物。ログの取込・保持で課金|

以下で選んだ種類だけを作り、ASE・Firewallなどの常時稼働サービスやDatabricks・AKSは省略します。56種類すべての試験ではありません。作成対象と引数全体は[リソースの選択](README.md#2-作るリソースを選ぶ)を参照してください。

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

現行テンプレートでは、Planに18リソースが出ます。Storageの4子サービス、SQLの`master`、既存VNet2個、VMのOSディスクはこの18件とは別に確認します。予定外の種類があれば、Deploy前に入力を見直します。

**PlanはAzureへ接続せず、料金を計算しません。** 表のSKU・地域・台数・予定時間をAzure料金計算ツールへ入力して見積もります。`BudgetJPY`は作成記録へ残す計画額で、請求額や課金の停止上限ではありません。移行でも各SubにLog Analyticsを1個、Storageを指定したSubには地域ごとのStorageを作ります。ログを二重送信する時間を短くし、会社ポリシーの付与後に2ケースを続けて実行します。

Plan後はPS1・ARM・選択条件を変えず、**Deployは1回だけ**実行します。

```powershell
& $fixture -Action Deploy @options
# 会社ポリシーで旧設定が付いた後に実行する。
& $fixture -Action Capture -RunId $run -RunRoot $fixtureRunRoot
$ledgerPath = Join-Path $fixtureRunRoot "$run/run-ledger.json"
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json
$ledger.scopes | Group-Object actualStatus | Select-Object Name, Count
```

Captureの結果は[旧設定の確認](README.md#4-旧設定を確認して移行テストへ進む)に従って判定します。`diagnosticSettings.value`の`properties.workspaceId`が指定旧Log Analyticsになっていることを確認します。VM・VMSSの旧DCR関連付けはCaptureに含まれないため、Azure画面の「データ収集ルール」で別に確認します。

Storageの4子サービス、SQL `master`、Foundry子プロジェクト、Web・Functions各スロットも確認します。**旧設定が0件の種類は、移行を試せたとは数えません。** 旧DCR関連が0件のSubでは新DCR・新関連を作らないことを確認し、VMSSの旧関連がなければDCR移行は未検証と記録します。VMSSは0台なので、実インスタンスへのログ取込は試験対象外です。

## 3. 2つの作業フォルダを作る

`rb1`は複製後の切り戻し、`n01`は正常移行と削除後の切り戻しです。CSV・records・結果を分け、同じテスト用リソースを使います。診断ログの送り先を入れ替え、両SubでLogとStorageを確認します。VMログは両方ともLogです。

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

保存先RGは新規の名前です。テスト用RG・既存VNetのRGを指定しません。`Log`の行の`StorageAccount`は空欄にします。名前があれば、Logへ送る行でも不要なStorageを作るためです。**step1後はcommon設定・CSV・recordsを変更しません。**

各コマンドを1つずつ実行し、エラー・NGなら次へ進みません。`az`実行後も`$LASTEXITCODE`が0であることを確認します。step3・rollbackは開始前に全対象を確認し、そこでNGなら削除・復元を始めません。開始後の失敗はそのSubの残りを止め、ほかのSubを続けます。Subを並列には実行しません。

失敗時は結果CSVと画面のエラーを保存し、原因を直して同じcommon設定・CSV・recordsで再実行します。完了済みの設定は省略されます。詳しくは[作業の再開](../migration/README.md#3-途中で止まった作業を再開する)を参照してください。

## 4. 順番に実行する

最初に[コピーして実行する確認用コード](#check-code)を、同じPowerShellセッションで1回実行してから4-1へ戻ります。これで以下の`Save-TestBaseline`と`Save-TestCheckpoint`を呼び出せます。コードの読み込みだけではAzureを操作しません。

<a id="run-t01"></a>
### 4-1. rb1で事前確認する

```powershell
$casePath = Join-Path $workRoot 'rb1'
& "$casePath/precheck.ps1"
Save-TestBaseline
```

[CSVの表示方法](#check-results)で`precheck_results.csv`を開き、[T01](INTEGRATION_TEST_CASES.md#t01)を判定します。

<a id="run-t02"></a>
### 4-2. rb1で複製する

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
Copy-Item "$casePath/verify_results.csv" "$casePath/T02-verify.csv"
Save-TestCheckpoint -Name T02
```

[T02](INTEGRATION_TEST_CASES.md#t02)を判定します。

<a id="run-t03"></a>
### 4-3. Sub1だけを切り戻す

```powershell
& "$casePath/rollback.ps1" -SubscriptionIds $subscription1
Save-TestCheckpoint -Name T03 -RestoredSubscriptions $subscription1
```

[T03](INTEGRATION_TEST_CASES.md#t03)を判定します。

<a id="run-t04"></a>
### 4-4. 両Subを切り戻す

```powershell
& "$casePath/rollback.ps1"
Save-TestCheckpoint -Name T04 -RestoredSubscriptions $subscription1, $subscription2
```

[T04](INTEGRATION_TEST_CASES.md#t04)を判定したら、rb1用の新規保存先RGだけを削除します。テスト用RGは残します。

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-rb1-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-rb1-b" --yes
az group exists --subscription $subscription1 --name "rg-lm-$run-rb1-a"
az group exists --subscription $subscription2 --name "rg-lm-$run-rb1-b"
```

両方`false`になるまで次へ進みません。前の保存先に会社ポリシーが付ける旧設定を、次の移行へ混ぜないためです。

<a id="run-t05"></a>
### 4-5. n01で削除前まで実行する

```powershell
$casePath = Join-Path $workRoot 'n01'
& "$casePath/precheck.ps1"
Save-TestBaseline
```

[T05の事前確認](INTEGRATION_TEST_CASES.md#t05-precheck)を判定してから複製します。

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
Copy-Item "$casePath/verify_results.csv" "$casePath/T05-before-delete-verify.csv"
Save-TestCheckpoint -Name T05-before-delete
```

[T05の削除前](INTEGRATION_TEST_CASES.md#t05-before)を判定してから、次を実行します。

```powershell
& "$casePath/step3_delete.ps1"
& "$casePath/step2_verify.ps1"
Copy-Item "$casePath/verify_results.csv" "$casePath/T05-after-delete-verify.csv"
Save-TestCheckpoint -Name T05-after-delete
```

[T05の削除後](INTEGRATION_TEST_CASES.md#t05-after)を判定します。step3内部でもstep2が実行されます。

<a id="run-t06"></a>
### 4-6. 削除後の旧設定を切り戻す

```powershell
& "$casePath/rollback.ps1"
Save-TestCheckpoint -Name T06 -RestoredSubscriptions $subscription1, $subscription2
```

[T06](INTEGRATION_TEST_CASES.md#t06)を判定します。切り戻し後にstep2は実行しません。

## 5. 共通の確認方法

<a id="check-results"></a>
### 結果CSVを表示する

`$resultFile`を、その時点で保存した結果CSV名に変えます。`Result`・`Reason`列を表示します。結果CSVに出ないエラーは実行画面も保存します。

```powershell
$resultFile = 'precheck_results.csv'  # T02-verify.csvなどへ変更
Import-Csv "$casePath/$resultFile" | Format-Table SubscriptionId, ResourceId, Result, Reason -AutoSize
```

<a id="save-baseline"></a>
### 変更前の一覧を保存する

`Save-TestBaseline`は、各フォルダのprecheck直後・step1前に1回実行します。`review-targets.csv`に移行する旧設定の全ID、`baseline-dcr.json`に旧DCR2本の本体、`baseline-exemptions.json`にポリシー適用除外の変更前の有無・値を保存します。

<a id="check-old"></a>
### 旧設定を全件比較する

`Save-TestCheckpoint`が出す`<時点>-old.csv`を開きます。各行はrecordsの`OldSettings`にある1設定です。`Exists`は存在、`Matches`は記録した元の値との一致を表します。設定を削除した時点では`Matches`ではなく`Exists`を判定します。

<a id="check-state"></a>
### 新設定と保存先を全件比較する

`Save-TestCheckpoint`はAzureからGETして記録と比べ、設定は変更しません。`Save-TestBaseline`は移行前の確認も行うため、登録状態次第でサービスの利用登録を行うことがあります。

`<時点>-state.csv`はrecordsの`NewSettings`と`Destinations`の全IDを照合します。`ExpectedSource=Body`は複製した値、`Before`は作業前の値との比較です。新設DCR本体は切り戻し後も`Body`で確認します。`<時点>-actual.json`には同じ全IDの取得値を保存します。画面で代表1件を見ただけでは、全件OKとしません。

<a id="check-code"></a>
### コピーして実行する確認用コード

次のブロック全体を1回コピーして実行し、[実行順](#run-t01)へ戻ります。各時点の確認結果は`$casePath`のフォルダに出ます。

```powershell
function Save-TestBaseline {
    . "$casePath/common.ps1"
    $list = @(foreach ($target in $targets) {
        $plan = Get-MigrationPlan -Target $target
        foreach ($setting in $plan.OldSettings) {
            [pscustomobject]@{
                SubscriptionId = $target.SubscriptionId
                Kind = $setting.Kind
                Id = $setting.Id
            }
        }
    })
    $list | Export-Csv "$casePath/review-targets.csv" -NoTypeInformation -Encoding utf8BOM
    $baseline = @(foreach ($id in $oldDcrIds) {
        $actual = Invoke-ArmRequest -ResourceId $id -ApiVersion $apiVersions.Dcr
        @{
            Id = $id
            Body = Get-WritableBody $actual -Kind Dcr
        }
    })
    $baseline | ConvertTo-Json -Depth 40 | Set-Content "$casePath/baseline-dcr.json" -Encoding utf8
    $exemptions = @(foreach ($target in $targets) {
        foreach ($assignment in $policyAssignments) {
            $assignmentName = ($assignment.Id -split '/')[-1]
            $id = "/subscriptions/$($target.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
            $actual = Invoke-ArmRequest -ResourceId $id -ApiVersion $apiVersions.Exemption -Optional
            @{
                Id = $id
                Exists = [bool]$actual
                Body = Get-WritableBody $actual -Kind Exemption
            }
        }
    })
    $exemptions | ConvertTo-Json -Depth 40 | Set-Content "$casePath/baseline-exemptions.json" -Encoding utf8
}

function Save-TestCheckpoint {
    param([string]$Name, [string[]]$RestoredSubscriptions = @())
    . "$casePath/common.ps1" -SkipCsv
    $actuals = @()
    $checks = @(foreach ($file in Get-ChildItem $recordDirectory -Filter '*.json') {
        $record = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
        foreach ($collection in @('OldSettings', 'NewSettings', 'Destinations')) {
            foreach ($setting in $record.$collection) {
                $expected = $setting.Body
                $source = 'Body'
                $restored = $record.Target.SubscriptionId -in $RestoredSubscriptions
                if ($collection -eq 'NewSettings' -and $restored -and -not $setting.KeepOnRollback) {
                    $expected = $setting.Before
                    $source = 'Before'
                }
                if ($collection -eq 'Destinations' -and $setting.Kind -eq 'Group' -and -not $setting.Reuse) {
                    $expected = @{}
                }
                $actual = Invoke-ArmRequest -Resource $setting -Optional
                $exact = $source -eq 'Before' -and $setting.Kind -eq 'Exemption' -and $null -ne $expected
                $compare = if ($exact) { Get-WritableBody $actual -Kind Exemption } else { $actual }
                $matches = Test-Configuration $compare $expected -Kind $setting.Kind -Exact:$exact
                if ($setting.Kind -eq 'Table' -and -not $setting.Reuse -and $actual.properties.totalRetentionInDaysAsDefault) {
                    $matches = $false
                }
                $actuals += @{
                    Id = $setting.Id
                    Collection = $collection
                    Actual = $actual
                }
                [pscustomobject]@{
                    SubscriptionId = $record.Target.SubscriptionId
                    Collection = $collection
                    Kind = $setting.Kind
                    Id = $setting.Id
                    Exists = [bool]$actual
                    ExpectedSource = $source
                    Matches = $matches
                }
            }
        }
    })
    $checks | Where-Object Collection -eq OldSettings |
        Export-Csv "$casePath/$Name-old.csv" -NoTypeInformation -Encoding utf8BOM
    $checks | Where-Object Collection -ne OldSettings |
        Export-Csv "$casePath/$Name-state.csv" -NoTypeInformation -Encoding utf8BOM
    $actuals | ConvertTo-Json -Depth 40 | Set-Content "$casePath/$Name-actual.json" -Encoding utf8
    $dcrChecks = @(foreach ($saved in (Get-Content "$casePath/baseline-dcr.json" -Raw | ConvertFrom-Json -AsHashtable)) {
        $actual = Invoke-ArmRequest -ResourceId $saved.Id -ApiVersion $apiVersions.Dcr -Optional
        [pscustomobject]@{
            Id = $saved.Id
            Exists = [bool]$actual
            Matches = Test-Configuration $actual $saved.Body -Kind Dcr
        }
    })
    $dcrChecks | Export-Csv "$casePath/$Name-dcr.csv" -NoTypeInformation -Encoding utf8BOM
    $checks | Group-Object SubscriptionId, Collection, Kind, Exists, Matches | Select-Object Name, Count
}
```

`Save-TestCheckpoint -RestoredSubscriptions`は確認する期待値を選ぶだけです。切り戻しそのものは行いません。

<a id="check-dcr-vnet"></a>
### 旧DCR本体と既存VNetを確認する

旧DCR本体は`<時点>-dcr.csv`の2行を確認します。DCRの関連付けを削除しても、DCR本体は別に確認します。

既存VNetは、Azure画面のVNet「アドレス空間」「サブネット」を開き、作業前の画面と比較します。各サブネットの範囲・委任・NSG・ルートテーブルを見ます。VM・NICが加わるとAzure管理用の参照が増えるため、GETしたVNetのJSON全体は同一比較しません。

## 6. 任意の追加操作

<a id="optional-repeat"></a>
### 同じ入力で再実行する

実施する場合は、4-5の削除前判定の直後に次を実行し、[T07](INTEGRATION_TEST_CASES.md#t07)を判定してからstep3へ進みます。

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
Copy-Item "$casePath/verify_results.csv" "$casePath/T07-verify.csv"
Save-TestCheckpoint -Name T07
```

<a id="optional-off"></a>
### None・空欄で送信を終了する

実施する場合は、T06判定後にn01用保存先RGを削除します。テスト用RGは残し、`off`フォルダへ`migration/*.ps1`をコピーします。CSVは新規保存先名で作り、6列を残して次の値にします。既存フォルダのCSV・recordsは変更しません。

None・空欄の送信フラグでは新しい送信設定を作りませんが、LAW・テーブルは作ります。この例でStorageを作らない理由は、StorageAccount列が空欄だからです。

|列|Sub1の行|Sub2の行|
|---|---|---|
|LogDestination|`None`|空欄|
|VmLogDestination|`None`|空欄|
|StorageAccount|空欄|空欄|

次の名前で新しいフォルダとCSVを用意します。

```powershell
$casePath = Join-Path $workRoot 'off'
$null = New-Item $casePath -ItemType Directory
Copy-Item (Join-Path $repo 'migration/*.ps1') $casePath
@"
SubscriptionName,ResourceGroup,StorageAccount,WorkspaceName,LogDestination,VmLogDestination
$subscription1,rg-lm-$run-off-a,,log-$run-off-a,None,None
$subscription2,rg-lm-$run-off-b,,log-$run-off-b,,
"@ | Set-Content "$casePath/targets.csv" -Encoding utf8
```

precheck→`Save-TestBaseline`を実行し、[T08の事前確認](INTEGRATION_TEST_CASES.md#t08)を判定します。step1→step2→`Save-TestCheckpoint -Name T08-before-delete`を実行して複製後を判定し、その後step3→step2→`Save-TestCheckpoint -Name T08-after-delete`で削除後を判定します。最後にrollback→`Save-TestCheckpoint -Name T08-restored -RestoredSubscriptions $subscription1, $subscription2`を実行し、切り戻し後を判定します。

## 7. 片付ける

T06、任意試験を行った場合はT08まで判定してから、`n01`または`off`用の新規保存先RG2個と、`fx-$run-a`・`fx-$run-b`を削除します。各RGのIDを確認し、fixture側は`fixtureRun`タグが`$run`であることも確認します。削除コマンドは4-4と同じ`az group delete`でRG名だけを置き換えます。

既存VNetとそのRG、会社の旧DCR・旧Log Analytics・管理グループ・ポリシーは残します。Azureサービスの利用登録も解除しません。今回のRGがなくなったことを確認し、手元の作業フォルダは結果レビューまで保管します。

## 実行回数

|工程スクリプト|必須手順の起動回数|
|---|---:|
|作成側 Plan / Deploy / Capture|各1回、計3回|
|precheck / step1 / step2 / step3 / rollback|2 / 2 / 3 / 1 / 3、計11回|
|step3内部のstep2|上の11回とは別に1回|

手動起動は計14回、内部起動を含め15回です。確認関数・commonの読み込み・Azure CLIの後片付け・エラー後の再実行は含めません。任意のT07は2回、T08は6回（内部step2を含め7回）追加します。テスト用リソースの再作成は不要です。
