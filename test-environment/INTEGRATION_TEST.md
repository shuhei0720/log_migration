# 自社の2サブスクリプションで移行と切り戻しを試す

テスト用リソースを一度作り、2回の複製で次の3項目を確認します。

|順序|試験|成功したときの状態|
|---|---|---|
|1|複製後・削除前の切り戻し|Sub1だけを戻した後、両方のサブスクリプションを戻せる|
|2|正常系|事前確認・複製・値の確認・旧設定の削除がすべて成功する|
|3|旧設定削除後の切り戻し|削除した旧設定を、両方のサブスクリプションへ復元できる|

この手順では、2つのサブスクリプションをSub1・Sub2と呼びます。実行には`migration`を使います。コマンドはリポジトリのルートから始めてください。

## 作業を始める条件

- PowerShell 7とAzure CLIを使い、両方のサブスクリプションでOwnerとしてログインする。
- 2つとも、同じ環境（prod・stg・dev）の設定で実行できる。
- クライアントPCからAzure管理APIと`raw.githubusercontent.com`へ接続できる。
- 会社のポリシーにより、両方に旧診断設定が付き、VM・VMSSが旧データ収集ルール（DCR）に関連付いている。

**移行スクリプトはサブスクリプション全体を調べます。テスト用リソースグループだけには絞りません。** 旧ワークスペース宛ての診断設定と、指定旧DCR2本の関連付けが対象です。付録Aで、既存リソースを含めた一覧を確認してから複製します。

旧設定が0件でもスクリプトが成功する場合があります。試したいリソースに旧設定が付いていなければ、そのリソースは検証できたと数えません。

## 1. 入力と作業場所を用意する

以下のサブスクリプションIDと作業フォルダを、実際の値へ置き換えます。

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

正本の`common.ps1`先頭の[6変数](../migration/README.md#commonps1に移行元と環境を指定する)に、移行元ワークスペース・環境・既存の旧DCRとポリシーを指定します。設定後のファイルを、後でケースごとにコピーします。

各コマンドは一つずつ実行します。エラーが出たら次へ進みません。`az`の実行後は、`$LASTEXITCODE`が0であることも確認してください。

## 2. テスト用リソースを作る

`resource_types_fixture.ps1`先頭に、次の値を設定します。上の変数へIDを入れるだけでは、ファイル内の設定は変わりません。

|変数|指定する値|
|---|---|
|`$SubscriptionIds`|Sub1・Sub2のID。同じ順序で指定する|
|`$ExistingVnetIds`|それぞれのサブスクリプションにあるVNetのリソースID|
|`$Locations`|4つの配置先地域。A-R1とB-R2は対応するVNetの地域に合わせる|

必要な5サブネットとASE・Container Apps用の委任は、[作成先の指定](README.md#1-作成先を指定する)で確認してください。スクリプトは既存VNet・サブネットを変更せず、NSG・ルートテーブルも関連付けません。

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

`$fixtureRunRoot\$run\plan.json`を開き、作成するリソースと地域、`skipped`にある省略理由を確認します。負荷テストも行う場合は、Plan前に`LoadCount`を300にします。300件を追加すると、後の探索・値の確認にも時間が加わります。

Planを確認したら、設定と選択条件を変えずに実行します。

```powershell
& $fixture -Action Deploy @options
# 会社ポリシーが旧設定を付けた後で取得する。
& $fixture -Action Capture -RunId $run -RunRoot $fixtureRunRoot
$ledgerPath = Join-Path $fixtureRunRoot "$run\run-ledger.json"
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
$ledger.scopes | Group-Object actualStatus | Select-Object Name, Count
```

会社のポリシーが旧設定を付けるまで待ち、Captureの結果を確認します。

|結果|進む前に確認すること|
|---|---|
|`READ_ONLY_CAPTURED`|取得は成功。`diagnosticSettings.value`に、旧ワークスペースの`workspaceId`を持つ設定があること|
|`EXPECTED_UNSUPPORTED`|診断設定に対応しないリソースとして記録する|
|`FAILED`・`UNRESOLVED`|取得エラーや未確認の内容を解消する|

DCR関連付けはCaptureに含まれません。VM・VMSSの「データ収集ルール」で、指定した旧DCRとの関連付けを確認します。配布テストコードは旧診断設定・旧DCR関連付けを作りません。

ストレージのBlob・File・Queue・Table、Foundry子プロジェクト、SQL master、Web・Functionsのスロット、AKSも確認します。種類ごとに「作成できた」「旧設定が付いている」「診断設定に非対応」を記録してください。

## 3. ケースごとのコピーと保存先名を用意する

`rb1`は複製後の切り戻し、`n01`は正常系と削除後の切り戻しに使います。**CSV・作業記録・保存先名を分けます。**

rb1ではSub1をLog Analytics、Sub2をストレージへ送ります。n01では逆にします。VMログは両方ともLog Analyticsへ送り、両サブスクリプションで2種類の診断ログ送信先を試します。

```powershell
foreach ($scenario in @('rb1', 'n01')) {
    $casePath = Join-Path $workRoot $scenario
    $null = New-Item $casePath -ItemType Directory
    Copy-Item "$repo\migration\*.ps1" $casePath
    $destination1 = if ($scenario -eq 'rb1') { 'Log' } else { 'Storage' }
    $destination2 = if ($scenario -eq 'rb1') { 'Storage' } else { 'Log' }
    @"
SubscriptionName,ResourceGroup,StorageAccount,WorkspaceName,LogDestination,VmLogDestination
$subscription1,rg-lm-$run-$scenario-a,lm${run}jpe${scenario}a,log-$run-$scenario-a,$destination1,Log
$subscription2,rg-lm-$run-$scenario-b,lm${run}jpe${scenario}b,log-$run-$scenario-b,$destination2,Log
"@ | Set-Content (Join-Path $casePath 'targets.csv') -Encoding utf8
}
```

CSVに書く保存先リソースグループは、まだ存在しない名前にします。テスト用リソースを作ったグループは指定しません。コピー後は、各ケースのcommon設定・CSV・recordsを変更しません。

## 4. 切り戻し①：複製後、Sub1だけ戻してから全体を戻す

まずrb1で事前確認します。

```powershell
$casePath = Join-Path $workRoot 'rb1'
& "$casePath\precheck.ps1"
Import-Csv "$casePath\precheck_results.csv" | Format-Table
```

両方がOKなら、付録Aの一覧で移行するリソースを確認してから複製します。

```powershell
& "$casePath\step1_copy.ps1"
& "$casePath\step2_verify.ps1"
Import-Csv "$casePath\verify_results.csv" | Group-Object Result | Select-Object Name, Count
```

`verify_results.csv`のResult列がすべてOKであることを確認します。続いて付録Bを`after-copy`として実行し、旧設定がすべて`Exists=true, Matches=true`で残っていることも確かめます。step2は削除済みの旧設定を許可するため、この確認が必要です。

|確認する設定|複製後の状態|
|---|---|
|旧診断設定・旧DCR関連付け|元の値のまま残る|
|新診断設定|旧ログ・メトリック設定を引き継ぎ、CSVの送り先になっている|
|Log Analytics自身の新診断設定|allLogsだけが有効。Storageなら同地域のストレージ、Logなら自身へ送る。メトリックは無効|
|地域別ストレージ|診断を付けるリソースと同じ地域。空欄・globalは東日本。新設はZRSを優先し、非対応地域はLRS|
|新規保存先の保持期間と通信設定|Log Analytics全体90日、Event・Syslogは合計1,095日。ストレージの公開ネットワークはDisabled、appendBlobは最終更新から1,095日を超えると削除する設定|
|作業前からある保存先|指定地域と一致し、元の保持期間・セキュリティ設定が変わっていない。既存LAWの未作成テーブルだけは合計1,095日で用意する|

次のコマンドを一つずつ実行し、間に状態を確認します。

```powershell
& "$casePath\rollback.ps1" -SubscriptionIds $subscription1
# 下の表でSub1とSub2を確認してから実行する。
& "$casePath\rollback.ps1"
```

|時点|Sub1の状態|Sub2の状態|
|---|---|---|
|Sub1だけを戻した後|旧設定は元の値。新診断設定・新DCR関連付けは削除済み|旧設定と新設定がどちらも残る|
|全体を戻した後|旧設定は元の値。新診断設定・新DCR関連付けは削除済み|Sub1と同じ|

付録Bでも、旧設定が元の値に戻ったことを確認します。保存先・保存済みログ・今回作成したDCR本体は残ります。移行時に変更した既存DCRはBeforeへ戻ります。元からあったポリシー適用除外は残り、今回作成した適用除外は削除されます。

**切り戻し後の判定にstep2は使いません。** 新設定を削除したため、step2ではNGになります。

保存先が残ることを確認したら、rb1のテスト用保存先リソースグループだけを削除します。次のケースに前回のリソースが混ざるのを防ぐためです。手元の作業記録は残します。

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-rb1-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-rb1-b" --yes
az group exists --subscription $subscription1 --name "rg-lm-$run-rb1-a"
az group exists --subscription $subscription2 --name "rg-lm-$run-rb1-b"
```

両方`false`になってから、正常系へ進みます。

## 5. 正常系：旧設定の削除まで実行する

n01のファイルを使います。各段階の結果を確認し、コメントに書いた条件を満たしてから次のコマンドへ進んでください。

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

|確認するもの|合格となる状態|
|---|---|
|旧診断設定・旧DCR関連付け|付録Bで、すべて`Exists=false`。旧DCR本体は残る|
|新診断設定・新DCR関連付け・保存先|step2の結果がすべてOK|
|今回移行しない診断設定・DCR関連付け|作業前と同じ状態|

診断設定は旧設定のあるリソースごとに新1件を作り、新Log Analytics自身にも1件作ります。同じリソースなら重複させません。DCR関連付けは旧2本から新1本へまとめるため、旧設定と新設定の総件数は同じになりません。種類別に数えます。

結果CSV・recordsと代表リソースの画面を保存します。ログデータが実際に届くまで待つ試験は行いません。

## 6. 切り戻し②：削除した旧設定を復元する

正常系のn01と、同じ作業記録を使います。

```powershell
& "$casePath\rollback.ps1"
```

付録Bですべて`Exists=true, Matches=true`になれば、旧診断設定・旧DCR関連付けは記録した値に戻っています。新診断設定・新DCR関連付けの削除と、保存先・ログ・新設DCR本体が残ることも確認します。既存DCRとポリシー適用除外の扱いは、切り戻し①と同じです。

エラーや値の不一致があれば、片付けに進みません。該当の`*_failures.csv`・画面のエラー・recordsを保存し、設定と記録を変えずに対応します。

## 7. 今回作ったリソースを片付ける

切り戻し②の成功後、n01用に新規作成した保存先グループと、テスト用リソースを作ったグループを削除します。**作業前からある保存先グループ、既存VNetとそのグループは削除しません。**

```powershell
az group delete --subscription $subscription1 --name "rg-lm-$run-n01-a" --yes
az group delete --subscription $subscription2 --name "rg-lm-$run-n01-b" --yes
$ledger = Get-Content $ledgerPath -Raw | ConvertFrom-Json -AsHashtable
$fixtureGroups = @($ledger.plan.bundles | ForEach-Object {
    "/subscriptions/$($_.subscriptionId)/resourceGroups/$($_.resourceGroup)"
} | Sort-Object -Unique)
$fixtureGroups
```

表示された2グループについて、今回作成した名前であり、`fixtureRun`タグが`$run`と一致することを確認してから削除します。

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

管理用リソースグループが残っていたら、作成前に保存した一覧と比べます。今回の親リソース専用で、作成前の一覧になかったグループだけを削除します。既存・共有のグループは残します。

AKSで使うマネージドIDのPrivateSubnetのNetwork Contributorロールを削除する場合は、`ownedExternalRoles`に記録された完全IDだけを`az role assignment delete --ids '<ID>'`へ渡します。Azureサービスの利用登録は、この手順では解除しません。

最後に、今回のグループがなくなり、既存VNet・サブネットとポリシー適用除外が作業前の状態に戻っていることを確認します。手元の結果とrecordsは、レビューが終わるまで保管します。

## 付録A：変更前に、移行する設定の一覧を出す

事前確認がOKになったケースの`$casePath`で実行します。Azureの設定は変えず、旧設定のIDを`review-targets.csv`へ出します。

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

両方のサブスクリプションで、試したい旧診断設定・VM／VMSSの関連付け・子リソースが含まれているかを確認します。変更してはいけないリソースが含まれていたら、複製を始めません。

## 付録B：旧設定が残っているか、元の値と同じかを調べる

複製後・削除後・切り戻し後に、対象ケースの`$casePath`で実行します。結果を上書きしないよう、`$checkpoint`は実行するたびに変えます。

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

|確認した時点|旧設定の期待値|
|---|---|
|複製後・切り戻し後|すべて`Exists=true, Matches=true`|
|旧設定の削除後|すべて`Exists=false`|

付録Bは旧設定だけを調べます。新設定は、複製・削除後のstep2で確認します。切り戻し後はrollbackが行う復元後の値の比較と、代表リソースの画面で確認します。
