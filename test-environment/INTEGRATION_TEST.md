# 自社2サブスクリプションでの総合テスト手順

PowerShell 7で実行します。テスト資源を一度作り、次の順に確認します。

|順序|試験|確認すること|
|---|---|---|
|1|切り戻し①：複製後・削除前|Sub1だけ戻し、続けて全体を戻せる|
|2|正常系|事前確認→複製→照合→旧設定削除が成功する|
|3|切り戻し②：旧設定削除後|正常系で削除した旧設定を、両Subへ復元できる|

正本は`procedural-migration`です。試験では正本の作業用コピーを2つ用意し、CSV・作業記録・保存先名を分けます。**途中で別ケースの記録を使わないでください。**

## 開始前に確認すること

- 対象2SubでOwnerとしてAzure CLIへログインする。2Subは同じ環境（prod／stg／dev）として実行できること。
- クライアントPCからAzure管理APIと、地域略称を取得する`raw.githubusercontent.com`へ接続できること。
- **移行範囲はテスト用RGに限定されません。** CSVのSub全体から、指定の旧ワークスペース宛て診断設定と旧2DCRの関連付けを探します。既存資源も含む対象一覧を確認してから進めます。
- 旧診断設定・VM／VMSSの旧DCR関連付けは、会社の既存ポリシーで作られる前提です。配布テストコードは作りません。
- 両Subに対象の旧診断設定があり、VM・VMSSが指定旧DCRへ関連付いていることを確認します。**対象0件でも処理が成功する場合があるため、成功表示だけでは合格にしません。**

リポジトリのルートを開き、以下を実際の値へ置き換えます。

```powershell
$ErrorActionPreference = 'Stop'
$repo = (Get-Location).Path
$subscription1 = '<Sub1のID>'
$subscription2 = '<Sub2のID>'
$run = 'int261126a'                 # 毎回変える。英小文字・数字8～13文字。
$workRoot = "C:\Work\log-migration-$run"
$fixtureRunRoot = Join-Path $workRoot 'fixture'
if (Test-Path $workRoot) {
    throw '未使用の作業フォルダ名にしてください。'
}
$null = New-Item $workRoot -ItemType Directory
az login
```

正本の`common.ps1`先頭で、`targetWorkspaceId`・`environment`・`newDiagnosticSettingName`・`location`・`environmentSettings`・`policyReferenceIds`を確認します。旧DCR・3ポリシー割り当ては会社の既存IDを使います。設定した正本を、後で2ケースの作業フォルダへコピーします。

各コマンドでエラーが出たら、その時点で止めます。`az`の実行後は`$LASTEXITCODE`が0であることも確認してください。

## テスト資源を作成する

`resource_types_fixture.ps1`先頭の次の値を設定します。上の`$subscription1`・`$subscription2`を入力しただけでは、ファイル内の設定は変わりません。

|設定|指定内容|
|---|---|
|`$SubscriptionIds`|上記Sub1・Sub2と同じID、同じ順序|
|`$ExistingVnetIds`|それぞれのSubの既存VNetリソースID|
|`$Locations`|4配置先。A-R1／B-R2は対応する既存VNetの地域に合わせる|

既存VNetにはProtectSubnet `/27`、PrivateSubnet `/26`、ApplicationGatewaySubnet `/24`、VNetIntegrationSubnet `/26`、AzureFirewallSubnet `/26`が必要です。ASE／Container Appsを作る場合の既存の委任も[環境作成の説明](README.md)で確認します。**既存VNet・サブネットの設定は変更せず、NSG・ルートテーブルも関連付けません。**

```powershell
# 後片付けで既存RGを消さないよう、作成前の一覧を保存する。
az group list --subscription $subscription1 --query '[].id' -o json > "$workRoot\groups-before-sub1.json"
if ($LASTEXITCODE -ne 0) {
    throw 'Sub1の作成前RG一覧を取得できませんでした。'
}
az group list --subscription $subscription2 --query '[].id' -o json > "$workRoot\groups-before-sub2.json"
if ($LASTEXITCODE -ne 0) {
    throw 'Sub2の作成前RG一覧を取得できませんでした。'
}
$fixture = Join-Path $repo 'test-environment\resource_types_fixture.ps1'
$options = @{
    RunId = $run
    RunRoot = $fixtureRunRoot
    BudgetJPY = 4000                # 自社で確保した計画予算に合わせる。課金の自動停止上限ではない。
    IncludeConditional = $true
    IncludeAse = $true
    AdminSshPublicKey = '<ssh-ed25519またはssh-rsaで始まる公開鍵>'
    LoadCount = 0                   # 負荷も確認する場合は、Plan前に300へ変更する。
}
& $fixture -Action Plan @options
```

`$fixtureRunRoot\$run\plan.json`の資源・地域・`skipped`を確認してから、**設定と選択条件を変えずに**実行します。Code Signing・Bing・ExpressRouteなどの省略理由も記録します。負荷300件を選ぶと、後続の探索・照合にも時間が加わります。

```powershell
& $fixture -Action Deploy @options
# 会社ポリシーが旧設定を付けた後で取得する。
& $fixture -Action Capture -RunId $run -RunRoot $fixtureRunRoot
$ledgerPath = Join-Path $fixtureRunRoot "$run\run-ledger.json"
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
$ledger.scopes | Group-Object actualStatus | Select-Object Name, Count
```

`FAILED`／`UNRESOLVED`は解消してから進めます。`EXPECTED_UNSUPPORTED`は診断非対応として記録します。`READ_ONLY_CAPTURED`は取得成功であり、旧設定の存在は`diagnosticSettings.value`の`workspaceId`で確認します。DCR関連はCaptureに含まれないため、VM・VMSSの「データ収集ルール」で別途確認します。

StorageのBlob／File／Queue／Table、Foundry子プロジェクト、SQL master、App Service・Functionsのスロット、AKSなどについて、**作成できた資源・旧設定がある資源・診断非対応の資源**を分けて記録してください。

## 2ケースの作業用コピーを用意する

rb1はSub1=Log／Sub2=Storage、n01は逆にします。VM側は両方Logです。これで両SubのStorage・Log Analytics経路を確認します。

```powershell
foreach ($scenario in @('rb1', 'n01')) {
    $casePath = Join-Path $workRoot $scenario
    $null = New-Item $casePath -ItemType Directory
    Copy-Item "$repo\procedural-migration\*.ps1" $casePath
    $destination1 = if ($scenario -eq 'rb1') { 'Log' } else { 'Storage' }
    $destination2 = if ($scenario -eq 'rb1') { 'Storage' } else { 'Log' }
    @"
SubscriptionName,ResourceGroup,StorageAccount,WorkspaceName,LogDestination,VmLogDestination
$subscription1,rg-lm-$run-$scenario-a,lm${run}jpe${scenario}a,log-$run-$scenario-a,$destination1,Log
$subscription2,rg-lm-$run-$scenario-b,lm${run}jpe${scenario}b,log-$run-$scenario-b,$destination2,Log
"@ | Set-Content (Join-Path $casePath 'targets.csv') -Encoding utf8
}
```

CSVのRGは**まだ存在しない新規の保存先RG**です。fixtureの作成済みRGを指定しません。コピー後は、各ケースのcommon設定・CSV・recordsを途中で変更しません。

## 切り戻し①：複製後・削除前

以降のコマンドは一つずつ実行し、期待状態を確認して次へ進みます。

```powershell
$casePath = Join-Path $workRoot 'rb1'
& "$casePath\precheck.ps1"
Import-Csv "$casePath\precheck_results.csv" | Format-Table
```

両SubがOKなら、付録Aで移行対象一覧を出し、想定資源が含まれることを確認します。

```powershell
& "$casePath\step1_copy.ps1"
& "$casePath\step2_verify.ps1"
Import-Csv "$casePath\verify_results.csv" | Group-Object Result | Select-Object Name, Count
```

付録Bを`after-copy`で実行し、旧設定も全件`Exists=true, Matches=true`であることを確認します。step2は旧設定の不在を許可するため、この確認とは分けます。

|確認箇所|期待状態|
|---|---|
|`verify_results.csv`|新設定・保存先の照合が全件OK|
|旧設定|付録Bで旧診断・旧DCR関連の保持を確認し、新設定と共存|
|新診断|旧ログ・メトリックを引き継ぎ、送り先はCSVどおり。Storage宛ては対象資源と同じ地域（空・globalは東日本）|
|保存先|LAW全体90日、対象のEvent／Syslog合計1,095日。Storageの公開ネットワークDisabled、appendBlobの1,095日ルール|

次にSub1だけ切り戻し、Sub2が変わらないことを確認してから全体を戻します。

```powershell
& "$casePath\rollback.ps1" -SubscriptionIds $subscription1
# 下の表でSub1とSub2を確認してから実行する。
& "$casePath\rollback.ps1"
```

|時点|Sub1|Sub2|
|---|---|---|
|Sub1限定切り戻し後|旧設定は元の値、新診断・新関連は解除|旧設定と新設定が共存したまま|
|全体切り戻し後|旧設定は元の値、新診断・新関連は解除|同左|

保存先・保存済みログ・新設DCR本体は残ります。既存DCRはBeforeへ戻り、元からあったWaiverは保持、今回作成したWaiverは解除されます。付録Bでも旧設定の復元を確認します。**切り戻し後の合否判定にstep2は使いません。撤去した新設定をNGと判定するためです。**

保存先が保持されたことを確認したら、次のケースに前回資源が混ざらないよう、rb1のテスト用保存先RGだけを削除します。作業記録は残します。

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-rb1-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-rb1-b" --yes
az group exists --subscription $subscription1 --name "rg-lm-$run-rb1-a"
az group exists --subscription $subscription2 --name "rg-lm-$run-rb1-b"
```

両方`false`になってから正常系へ進みます。

## 正常系：最後まで移行する

```powershell
$casePath = Join-Path $workRoot 'n01'
& "$casePath\precheck.ps1"
# 両SubがOKで、付録Aの対象一覧に問題がなければ続ける。
& "$casePath\step1_copy.ps1"
& "$casePath\step2_verify.ps1"
# verify_results.csvの全件OKと、付録Bで旧設定の保持を確認してから削除する。
& "$casePath\step3_delete.ps1"
& "$casePath\step2_verify.ps1"
```

|確認箇所|期待状態|
|---|---|
|旧診断・旧DCR関連|全件不在。付録Bで`Exists=false`を確認する。旧DCR本体は残る|
|新診断・新DCR関連・保存先|全件照合OK。指定外の診断設定・DCR関連は元のまま|
|診断の件数|旧診断1件に新診断1件。DCR関連は旧2本から新1本へまとめるため、旧・新の総件数は一致しない|

ここで正常系の結果CSV・recordsと、代表資源の画面を保存します。ログの実着信を待つ試験は含めません。

## 切り戻し②：旧設定削除後

正常系のn01と**同じ作業記録**を使います。

```powershell
& "$casePath\rollback.ps1"
```

旧診断・旧DCR関連が元の本文で復元され、新診断・新関連が解除されたことを確認します。付録Bは`Exists=true`・`Matches=true`が全件の期待値です。保存先・ログ・新設DCR本体は保持、既存DCRとWaiverの扱いは切り戻し①と同じです。

API失敗や不一致が出た場合は次へ進まず、該当の`*_failures.csv`・画面エラー・recordsを保存します。同じ設定と記録を維持して対応します。

## 終了後の片付け

切り戻し②が成功した後で、n01のテスト用保存先RGとfixtureの専用RGを削除します。**既存VNet・そのRGは対象に含めません。**

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-n01-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-n01-b" --yes
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
$fixtureGroups = @($ledger.plan.bundles | ForEach-Object {
    "/subscriptions/$($_.subscriptionId)/resourceGroups/$($_.resourceGroup)"
} | Sort-Object -Unique)
$fixtureGroups
```

表示された2RGが今回作成したRGで、`fixtureRun`タグが`$run`と一致することを確認してから実行します。

```powershell
foreach ($groupId in $fixtureGroups) {
    $parts = $groupId.Split('/')
    az group delete --subscription $parts[2] --name $parts[4] --yes
    if ($LASTEXITCODE -ne 0) {
        throw 'テスト用RGの削除に失敗しました。残りを止めます。'
    }
}
$ledger.managedGroups | Format-Table id, ownerId
$ledger.ownedExternalRoles | Format-Table id
```

親資源の削除後も管理RGが残った場合は、作成前のRG一覧に存在せず、今回の親資源専用だったものだけ削除します。既存・共有の管理RGは残します。AKS用の外部ロールも、必要なら`ownedExternalRoles`に記録された完全IDだけを`az role assignment delete --ids '<ID>'`で削除します。利用登録はこの手順では解除しません。

最後に、今回のRGの不在、既存VNet・サブネットの保持、ポリシー適用除外が試験前の状態であることを確認します。手元の結果とrecordsはレビュー完了まで残します。

## 付録A：変更前に移行対象を一覧で確認する

事前確認がOKになったケースで実行します。正本の調査関数を使う読取処理で、Azureの設定は変更しません。

```powershell
. "$casePath\common.ps1"
$targetList = @(foreach ($target in $targets) {
    $plan = Get-MigrationPlan -Target $target
    foreach ($setting in $plan.OldSettings) {
        [pscustomobject]@{
            SubscriptionId = $target.SubscriptionId
            Kind = $setting.Kind
            Id = $setting.Id
        }
    }
})
$targetList | Export-Csv "$casePath\review-targets.csv" -NoTypeInformation -Encoding utf8BOM
$targetList | Group-Object SubscriptionId, Kind | Select-Object Name, Count
```

`review-targets.csv`で、両Subの旧診断とVM／VMSS関連、対象に含めたい子資源、指定外資源の混入がないことを確認します。ポリシーで未設定の種類は、移行済み・検証済みとして数えません。

## 付録B：記録した旧設定の現在値を一括確認する

複製後・削除後・切り戻し後に、対象ケースの`$casePath`で実行します。`$checkpoint`は結果を残すたびに変えます。

```powershell
$checkpoint = 'after-rollback'       # 例：after-copy / after-delete / after-rollback
. "$casePath\common.ps1" -SkipCsv
$oldCheck = @(foreach ($file in Get-ChildItem $recordDirectory -Filter '*.json') {
    $record = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    $subscriptionId = $record.Target.SubscriptionId
    foreach ($setting in $record.OldSettings) {
        $actual = Invoke-ArmRequest -Resource $setting -Optional
        $body = Get-WritableBody $actual -Kind $setting.Kind
        [pscustomobject]@{
            SubscriptionId = $subscriptionId
            Kind = $setting.Kind
            Id = $setting.Id
            Exists = [bool]$actual
            Matches = Test-Configuration $body $setting.Body -Exact
        }
    }
})
$oldCheck | Export-Csv "$casePath\$checkpoint-old.csv" -NoTypeInformation -Encoding utf8BOM
$oldCheck | Group-Object Kind, Exists, Matches | Select-Object Name, Count
```

複製後・切り戻し後は全件`Exists=true, Matches=true`、正常削除後は全件`Exists=false`です。これは旧設定の確認です。新設定は複製・削除後のstep2、切り戻し時の復元後GET照合と代表資源の画面で確認します。
