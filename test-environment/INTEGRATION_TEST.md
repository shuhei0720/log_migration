# 自社の2サブスクリプションで移行と切り戻しを試す

テスト用リソースは**1回だけ作成し、2回の移行に使います**。1回目で複製後の切り戻し、2回目で正常移行と旧設定削除後の切り戻しを確認します。終了時は旧設定へ戻し、今回作成したリソースを削除します。

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

Storageの4子サービス、SQL `master`、Foundry子プロジェクト、Web・Functions各スロットも確認します。**旧設定が0件の種類は、移行を試せたとは数えません。** VMSSは0台なので、実インスタンスへのログ取込は試験対象外です。

## 3. 2ケースの作業フォルダを作る

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

## 4. 実施するテストケース

|ID|開始時の状態|操作|合格条件・残す証拠|
|---|---|---|---|
|T01|会社の旧設定のみ。rb1のrecordsなし|rb1のprecheckと下の対象一覧取得|両SubがOK。旧診断・旧DCR関連付けが両方あり、変更してよいIDだけ。`precheck_results.csv`・`review-targets.csv`|
|T02|T01合格|rb1のstep1→step2|`verify_results.csv`のResult列が全件OK。旧設定は元の値で残り、新設定はCSVの指定先。旧設定比較CSV・records・`verify_results.csv`|
|T03|両Subに旧・新設定がある|rb1のrollbackをSub1指定|Sub1だけ旧設定へ戻り、Sub2には旧・新設定が残る。両Subの旧設定比較CSVと代表設定の画面|
|T04|T03合格|rb1のrollbackを引数なし|両Subの旧設定が元の値。今回追加した新診断・新関連付けは消える。保存先と新設DCR本体は残る|
|T05|T04後、rb1用保存先RG削除済み。旧設定のみ|n01のprecheck→step1→step2→step3→step2|全4工程成功。削除前は旧設定を保持、削除後は旧診断・旧関連付けが全件なし。旧DCR本体・新設定・保存先は残り、step2全件OK|
|T06|T05合格、旧設定削除済み|n01のrollbackを引数なし|両Subの旧設定が記録の値で復元され、新診断・新関連付けが消える。旧設定比較CSV・records・画面|

T02・T05では、新Log Analytics自身の診断設定も確認します。`allLogs`のみ有効、メトリック無効で、Logなら自身へ、Storageなら同地域のStorageへ送ります。旧診断のログ・メトリック・格納方式を引き継ぐこと、新規LAWの保持90日、Event・Syslogの合計保持1,095日、地域別Storageの地域・冗長性・公開ネットワークDisabledも確認します。診断・関連付けは種類別に数えます。旧DCR2本への関連付けは、新1本へまとめるためです。

### rb1：複製後の切り戻し

```powershell
$casePath = Join-Path $workRoot 'rb1'
& "$casePath/precheck.ps1"
Import-Csv "$casePath/precheck_results.csv" | Format-Table
```

両SubがOKなら、移行する旧設定の一覧を保存します。**既存リソースもここに出ます。** 内容を確認してからstep1へ進みます。n01でも、precheck後に同じブロックを実行します。

```powershell
. "$casePath/common.ps1"
$targetList = @(foreach ($target in $targets) {
    $migrationPlan = Get-MigrationPlan -Target $target
    foreach ($setting in $migrationPlan.OldSettings) {
        [pscustomobject]@{
            SubscriptionId = $target.SubscriptionId
            Kind = $setting.Kind
            Id = $setting.Id
        }
    }
})
$targetList | Export-Csv "$casePath/review-targets.csv" -NoTypeInformation -Encoding utf8BOM
$targetList | Group-Object SubscriptionId, Kind | Select-Object Name, Count
```

試したいStorage子サービス・SQL `master`・Foundry子プロジェクト・Web/FunctionsのスロットのIDが、旧設定を持つのにこの一覧に出なければ、該当種類は未検証として記録します。Captureで取得できただけでは移行成功としません。

```powershell
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
# 全件OKと、下の「旧設定の比較」で元の値を保持していることを確認。
& "$casePath/rollback.ps1" -SubscriptionIds $subscription1
# T03の両Subの状態を確認してから、全体を戻す。
& "$casePath/rollback.ps1"
```

T04合格後、rb1用の新規保存先RGだけを削除します。残すと、会社ポリシーがそこへ付けた旧設定も、次回の探索に含まれる場合があります。テスト用RGは残します。

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-rb1-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-rb1-b" --yes
az group exists --subscription $subscription1 --name "rg-lm-$run-rb1-a"
az group exists --subscription $subscription2 --name "rg-lm-$run-rb1-b"
```

### n01：正常移行と削除後の切り戻し

両RGが`false`になったら進みます。各行の間でT05の条件を確認し、結果を保存します。step3冒頭でもstep2が実行されます。

```powershell
$casePath = Join-Path $workRoot 'n01'
& "$casePath/precheck.ps1"
Import-Csv "$casePath/precheck_results.csv" | Format-Table
# 両SubのOKを確認し、上の対象一覧取得をこのcasePathでも実行する。
& "$casePath/step1_copy.ps1"
& "$casePath/step2_verify.ps1"
# 全件OKと旧設定の保持を確認し、verify_results.csvを別名で保存する。
Copy-Item "$casePath/verify_results.csv" "$casePath/after-copy-verify.csv"
& "$casePath/step3_delete.ps1"
& "$casePath/step2_verify.ps1"
# 全件OKと旧設定の全件削除を確認し、T05の証拠を保存してからT06へ。
Copy-Item "$casePath/verify_results.csv" "$casePath/after-delete-verify.csv"
& "$casePath/rollback.ps1"
```

切り戻しでは、旧設定が元の値で戻ったこと、新診断・新関連付けが消えたことを確認します。新設DCR本体・保存先・保存済みログは残ります。既存DCRや適用除外の扱いは[切り戻し後の状態](../migration/README.md#4-旧設定へ切り戻す)で確認します。**切り戻し後の判定にstep2は使いません。** 新設定を削除したためNGになります。

### 旧設定の比較：T02～T06の各時点で使う

以下はAzureを変更しません。`$checkpoint`を毎回変えて保存します。複製後・切り戻し後は全件`Exists=True, Matches=True`、削除後は全件`Exists=False`が合格です。

```powershell
$checkpoint = 'after-copy'   # after-sub1-rollback / after-rollback / after-delete
. "$casePath/common.ps1" -SkipCsv
$oldCheck = @(foreach ($file in Get-ChildItem $recordDirectory -Filter '*.json') {
    $record = Get-Content $file.FullName -Raw | ConvertFrom-Json -AsHashtable
    foreach ($setting in $record.OldSettings) {
        $actual = Invoke-ArmRequest -Resource $setting -Optional
        $body = Get-WritableBody $actual -Kind $setting.Kind
        [pscustomobject]@{
            SubscriptionId = $record.Target.SubscriptionId
            Kind = $setting.Kind
            Id = $setting.Id
            Exists = [bool]$actual
            Matches = Test-Configuration $body $setting.Body -Exact
        }
    }
})
$oldCheck | Export-Csv "$casePath/$checkpoint-old.csv" -NoTypeInformation -Encoding utf8BOM
$oldCheck | Group-Object SubscriptionId, Kind, Exists, Matches | Select-Object Name, Count
```

step2は、既に削除された旧設定を許可します。そのため、複製直後の旧設定保持もこの比較で確認します。ログデータの到着を待つ試験ではなく、設定値と復元を確認する試験です。

## 5. 実行回数と、追加する場合の試験

|スクリプト|基本手順の実行回数|
|---|---:|
|作成側 Plan / Deploy / Capture|各1回、計3回|
|precheck / step1 / step2 / step3 / rollback|2 / 2 / 3 / 1 / 3、計11回|
|step3内部のstep2|上の11回とは別に1回|

上表の工程スクリプトの起動は計14回、step3内部の起動も含めると計15回です。対象一覧取得・旧設定比較と、それに使うcommonの読み込み、Captureの再取得、エラー後の再実行、`az`による後片付けはこの数に含めません。正常移行後を最終状態にすると、切り戻し後に3回目の複製が必要になるため、この手順は旧設定へ戻して終了します。

|追加試験|実施する時点・手順|期待値・追加回数|
|---|---|---|
|同じ入力でstep1を再実行|n01の複製後、削除前。同じcommon・CSV・recordsでstep1→step2|設定と旧設定が同じ。再実行時間帯の自分のAzureアクティビティログも確認し、作成・更新・削除がないこと。PS1追加2回|
|None・空欄による送信終了|T06後、n01用保存先RGを削除し、別フォルダ`off`・別保存先名・新しいrecordsを使う。Sub1は`LogDestination=None, VmLogDestination=None`、Sub2は両方空欄。StorageAccountは両方空欄。precheck→step1→step2→step3→step2→rollback|新診断・新DCR関連付けを作らず、step3で両側の旧設定を削除。LAWとEvent・Syslogは用意される。rollbackで旧設定を復元。追加6回、内部step2を含め7回|

追加試験でもテスト用リソースは作り直しません。None・空欄は送信終了なので、変更してよいサブスクリプションで実施します。基本2ケースのCSVを途中で書き換えて代用しません。

## 6. 元へ戻ったことを確認し、片付ける

T06合格後、`n01`用の新規保存先RG2個と、`fx-$run-a`・`fx-$run-b`だけを削除します。各RGのIDを確認し、fixture側は`fixtureRun`タグが`$run`であることも確認します。削除コマンドは、rb1と同じ`az group delete`でRG名だけを置き換えます。offを実施する場合は、先にn01用保存先RGだけを削除し、テスト用RGを残して試験します。off切り戻し合格後、off用保存先RGとテスト用RGを削除します。

この選択ではFirewall・AKS・監視アカウントを作らないため、それらの外部リソースや管理用RGの片付けはありません。**既存VNetとそのRG、会社の旧DCR・旧LAW・管理グループ・ポリシーは残します。** Azureサービスの利用登録も解除しません。

最後に、今回のRGがなくなったこと、既存VNetのサブネット構成が作業前と同じであること、旧設定・既存の適用除外が戻ったことを確認します。エラー・不一致があれば削除へ進まず、該当の`*_failures.csv`・画面・recordsを保存します。手元の2ケースとfixtureの記録は、結果レビューまで保管します。
