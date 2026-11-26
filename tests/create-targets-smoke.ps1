#Requires -Version 7.0
param([string]$Generator = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/create_targets.ps1'))
$ErrorActionPreference = 'Stop'
$checks = 0
$scenarioCount = 7
$scenario = '正常'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('create-targets-' + [guid]::NewGuid().ToString('N'))
$null = New-Item $scratch -ItemType Directory
$columns = @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')
$ids = @(1..9 | ForEach-Object { '00000000-0000-0000-0000-{0:d12}' -f $_ })
[Text.Encoding]::RegisterProvider([Text.CodePagesEncodingProvider]::Instance)
$global:CsvGeneratorFixture = @{
    Scenario = '正常'
    Requests = @()
    Ids = $ids
    AsciiRequests = 0
    CmdSafeRequests = 0
    NameOverrides = @{}
    StateOverrides = @{}
    Cp932 = [Text.Encoding]::GetEncoding(932)
    TagValue = '表ソ費用\共有"引用符" 😀' + "`n2行目"
}

function Assert-CsvTest {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) {
        throw "$script:scenario / $Message"
    }
}

# Azure CLIを試験用の応答に置き換える。GET以外や想定外のURLは受け付けない。
function az {
    $arguments = @($args)
    $method = $arguments[[Array]::IndexOf($arguments, '--method') + 1]
    $url = $arguments[[Array]::IndexOf($arguments, '--url') + 1]
    if ($arguments[0] -ne 'rest' -or $method -ne 'get') {
        throw 'この試験ではAzureへのGET以外を禁止しています。'
    }
    $queryIndex = [Array]::IndexOf($arguments, '--query')
    $outputIndex = [Array]::IndexOf($arguments, '--output')
    $asciiMode = $queryIndex -ge 0 -and ($arguments[$queryIndex + 1] -replace '\s', '') -ceq 'to_string(@)' -and
        $outputIndex -ge 0 -and $arguments[$outputIndex + 1] -eq 'tsv'
    if ($asciiMode) {
        $global:CsvGeneratorFixture.AsciiRequests++
        if ($arguments[$queryIndex + 1] -match '\s') {
            $global:CsvGeneratorFixture.CmdSafeRequests++
        }
    }
    $global:CsvGeneratorFixture.Requests += $url
    $global:LASTEXITCODE = 0
    $uri = [uri]$url
    $path = $uri.AbsolutePath.ToLowerInvariant()
    if ($global:CsvGeneratorFixture.Scenario -eq '取得失敗' -and
        $path -eq "/subscriptions/$($global:CsvGeneratorFixture.Ids[0])/resourcegroups" -and $uri.Query -match 'page=2') {
        $global:LASTEXITCODE = 1
        return '{"error":{"message":"テスト用の取得失敗"}}'
    }
    if ($global:CsvGeneratorFixture.Scenario -eq '状態取得失敗' -and $path -eq '/subscriptions' -and $uri.Query -match 'page=2') {
        $global:LASTEXITCODE = 1
        return '{"error":{"message":"テスト用の状態一覧取得失敗"}}'
    }
    if ($global:CsvGeneratorFixture.Scenario -eq '空') {
        return '{"value":[]}'
    }
    $page = @{ value = @() }
    if ($path -eq '/subscriptions') {
        $stateIds = @($global:CsvGeneratorFixture.Ids)
        if ($global:CsvGeneratorFixture.Scenario -in @('状態ページング', '状態取得失敗')) {
            if ($uri.Query -match 'page=2') {
                $stateIds = @($global:CsvGeneratorFixture.Ids[4..8])
            }
            else {
                $stateIds = @($global:CsvGeneratorFixture.Ids[0..3])
                $page.nextLink = $url + '&page=2'
            }
        }
        $page.value = @(foreach ($id in $stateIds) {
            $state = 'Enabled'
            if ($global:CsvGeneratorFixture.StateOverrides.ContainsKey($id)) {
                $state = $global:CsvGeneratorFixture.StateOverrides[$id]
            }
            $item = @{ id = "/subscriptions/$id" }
            if ($null -ne $state) {
                $item.state = $state
            }
            $item
        })
    }
    elseif ($path -match '/managementgroups/(producrion|staging|sandbox)/descendants$') {
        $group = $Matches[1]
        $members = switch ($group) {
            producrion {
                if ($uri.Query -match 'page=2') {
                    @($global:CsvGeneratorFixture.Ids[0], $global:CsvGeneratorFixture.Ids[1]) + @($global:CsvGeneratorFixture.Ids[5..8])
                }
                else {
                    @($global:CsvGeneratorFixture.Ids[0])
                    $page.nextLink = $url + '&page=2'
                }
            }
            staging { @($global:CsvGeneratorFixture.Ids[2]) }
            sandbox { @($global:CsvGeneratorFixture.Ids[3], $global:CsvGeneratorFixture.Ids[4]) }
        }
        $page.value = @($members | ForEach-Object {
            @{ id = "/subscriptions/$_"; name = $_; type = 'Microsoft.Management/managementGroups/subscriptions' }
        })
        $page.value += @{ id = '/providers/Microsoft.Management/managementGroups/child'; name = 'child'; type = 'Microsoft.Management/managementGroups' }
    }
    elseif ($path -match '^/subscriptions/([^/]+)/resourcegroups$') {
        $subscriptionId = $Matches[1]
        $names = switch ($subscriptionId) {
            ($global:CsvGeneratorFixture.Ids[0]) {
                if ($uri.Query -match 'page=2') { @('rg-orders-prod-alert-01') }
                else {
                    @('rg-irrelevant-prod-monitor-01')
                    $page.nextLink = $url + '&page=2'
                }
            }
            ($global:CsvGeneratorFixture.Ids[1]) { @('rg-only-stg-alert-01') }
            ($global:CsvGeneratorFixture.Ids[2]) { @('rg-CATALOG-stg-alert-01', 'rg-other-prod-alert-01') }
            ($global:CsvGeneratorFixture.Ids[3]) { @('rg-payments-dev-alert-01', 'rg-other-prod-alert-01') }
            ($global:CsvGeneratorFixture.Ids[4]) { @('rg-one-dev-alert-01', 'rg-two-dev-alert-01') }
            ($global:CsvGeneratorFixture.Ids[5]) { @('rg-123456789-prod-alert-01') }
            ($global:CsvGeneratorFixture.Ids[6]) { @('rg-1234567890-prod-alert-01') }
            ($global:CsvGeneratorFixture.Ids[7]) { @('rg-ab-c-prod-alert-01') }
            ($global:CsvGeneratorFixture.Ids[8]) { @('rg-jpex-prod-alert-01') }
            default { throw "想定外のサブスクリプション: $subscriptionId" }
        }
        if ($global:CsvGeneratorFixture.NameOverrides.ContainsKey($subscriptionId)) {
            $names = $global:CsvGeneratorFixture.NameOverrides[$subscriptionId]
        }
        $page.value = @($names | ForEach-Object { @{ name = $_; tags = @{ cost_center = $global:CsvGeneratorFixture.TagValue } } })
    }
    else {
        throw "想定外のURL: $url"
    }
    if ($asciiMode) {
        $page | ConvertTo-Json -EscapeHandling EscapeNonAscii -Depth 6 -Compress
    }
    else {
        # CP932のCLI出力をUTF-8として受け取ると、日本語の一部がJSONの不正なエスケープに変わる。
        $json = $page | ConvertTo-Json -Depth 6 -Compress
        [Text.Encoding]::UTF8.GetString($global:CsvGeneratorFixture.Cp932.GetBytes($json))
    }
}

try {
    # 環境を一つずつ大文字で指定する。ほかの管理グループを読まず、ほかの環境のCSVを変更しないことも確認する。
    foreach ($environment in @('prod', 'stg', 'dev')) {
        "previous-$environment" | Set-Content (Join-Path $scratch "targets-$environment.csv")
    }
    $managementGroups = @{ prod = 'producrion'; stg = 'staging'; dev = 'sandbox' }
    $membersByEnvironment = @{ prod = @($ids[0], $ids[1]) + @($ids[5..8]); stg = @($ids[2]); dev = @($ids[3], $ids[4]) }
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $otherHashes = @{}
        foreach ($other in @('prod', 'stg', 'dev') | Where-Object { $_ -ne $environment }) {
            $otherHashes[$other] = (Get-FileHash (Join-Path $scratch "targets-$other.csv")).Hash
        }
        $requestStart = $global:CsvGeneratorFixture.Requests.Count
        & $Generator -Environment ($environment.ToUpperInvariant()) -OutputDirectory $scratch *> (Join-Path $scratch "normal-$environment.log")
        $foreignRequests = @($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart | Where-Object {
            $requestPath = ([uri]$_).AbsolutePath
            if ($requestPath -eq '/subscriptions') {
                $false
            }
            elseif ($requestPath -match '/managementGroups/([^/]+)/descendants$') {
                $Matches[1] -ne $managementGroups[$environment]
            }
            elseif ($requestPath -match '^/subscriptions/([^/]+)/resourcegroups$') {
                $Matches[1] -notin $membersByEnvironment[$environment]
            }
            else { $true }
        })
        Assert-CsvTest ($foreignRequests.Count -eq 0) "$environment / ほかの環境の管理グループかリソースグループを読んでいます。"
        foreach ($other in $otherHashes.Keys) {
            Assert-CsvTest ((Get-FileHash (Join-Path $scratch "targets-$other.csv")).Hash -ceq $otherHashes[$other]) "$environment / $other のCSVを書き換えています。"
        }
    }
    $prod = @(Import-Csv (Join-Path $scratch 'targets-prod.csv'))
    $stg = @(Import-Csv (Join-Path $scratch 'targets-stg.csv'))
    $dev = @(Import-Csv (Join-Path $scratch 'targets-dev.csv'))
    Assert-CsvTest ($prod.Count -eq 6 -and $stg.Count -eq 1 -and $dev.Count -eq 2) '環境別件数か、同じサブスクリプションの除外が違います。'
    $all = @($prod) + @($stg) + @($dev)
    Assert-CsvTest (($all[0].PSObject.Properties.Name -join ',') -ceq ($columns -join ',')) '移行スクリプトが読む6列と違います。'
    Assert-CsvTest (@($all | Where-Object { $_.LogDestination -ne 'Storage' -or $_.VmLogDestination -ne 'Log' }).Count -eq 0) '送信先の既定値が違います。'
    $orders = $prod | Where-Object SubscriptionName -eq $ids[0]
    Assert-CsvTest ($orders.ResourceGroup -ceq 'rg-orders-prod-monitor-01') '後のページにあるalertグループを使えていません。'
    Assert-CsvTest ($orders.StorageAccount -ceq 'stordersprodarchjpe01') 'ストレージ名が命名規則と違います。'
    Assert-CsvTest ($orders.WorkspaceName -ceq 'log-orders-prod-archive-01') 'Log Analytics名が命名規則と違います。'
    Assert-CsvTest ($stg[0].StorageAccount -ceq 'stcatalogstgarchjpe01') '取得した略称を小文字へそろえていません。'
    $payments = $dev | Where-Object SubscriptionName -eq $ids[3]
    Assert-CsvTest ($payments.ResourceGroup -ceq 'rg-payments-dev-monitor-01') '開発の名前にdevを使えていません。'
    $missing = $prod | Where-Object SubscriptionName -eq $ids[1]
    $multiple = $dev | Where-Object SubscriptionName -eq $ids[4]
    Assert-CsvTest ($missing.ResourceGroup -ceq 'rg-<サービス略称>-prod-monitor-01') 'alertグループがない場合のプレースホルダーが違います。'
    Assert-CsvTest ($multiple.ResourceGroup -ceq 'rg-<サービス略称>-dev-monitor-01') '候補が複数ある場合に略称を決めてしまっています。'
    Assert-CsvTest (@($global:CsvGeneratorFixture.Requests | Where-Object { $_ -match 'page=2' }).Count -eq 2) '管理グループとリソースグループのページングを確認できません。'
    $bytes = [IO.File]::ReadAllBytes((Join-Path $scratch 'targets-prod.csv'))
    Assert-CsvTest (($bytes[0..2] -join ',') -eq '239,187,191') 'CSVがUTF-8 BOM付きではありません。'
    $limit = $prod | Where-Object SubscriptionName -eq $ids[5]
    $over = $prod | Where-Object SubscriptionName -eq $ids[6]
    $symbol = $prod | Where-Object SubscriptionName -eq $ids[7]
    $repeated = $prod | Where-Object SubscriptionName -eq $ids[8]
    Assert-CsvTest ($limit.StorageAccount -ceq 'st123456789prodarchjpe01' -and $limit.StorageAccount.Length -eq 24) '24文字の境界名が違います。'
    Assert-CsvTest ($over.StorageAccount -ceq 'st1234567890prodarchjpe01' -and $over.StorageAccount.Length -eq 25) '25文字の名前を勝手に縮めています。'
    Assert-CsvTest ($symbol.StorageAccount -ceq 'stab-cprodarchjpe01') '略称内の記号を勝手に消しています。'
    Assert-CsvTest ($repeated.StorageAccount -ceq 'stjpexprodarchjpe01') '略称に含まれるjpeを書き換えています。'
    $warnings = Get-Content (Join-Path $scratch 'normal-prod.log') -Raw
    Assert-CsvTest ([regex]::Matches($warnings, '条件を満たしません').Count -eq 3) '25文字・記号・jpe重複の3件を警告していません。'

    # 開発の既存名はdev・sandの両方から略称を取り、出力名はdevへそろえる。
    # 略称が複数なら選ばず、他環境のsandや名前の途中にある文字列は環境名として扱わない。
    $namingCases = @(
        @{ Name = 'sandのみ'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-payments-sand-alert-01'); Service = 'payments' }
        @{ Name = 'devとsandで同じ略称'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-PAY-sand-alert-01', 'rg-pay-dev-alert-01'); Service = 'pay' }
        @{ Name = 'devとsandで異なる略称'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-one-dev-alert-01', 'rg-two-sand-alert-01'); Service = '<サービス略称>' }
        @{ Name = '環境名とalert末尾の不一致'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-pay-sandbox-alert-01', 'rg-pay-devops-alert-01', 'rg-pay-sand-alert-02', 'rg-pay-dev-alert-01-extra', 'rg-pay-sand-monitor-01'); Service = '<サービス略称>' }
        @{ Name = '略称内のsandを保持'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-sand-dev-alert-01'); Service = 'sand' }
        @{ Name = '略称内のdevを保持'; Environment = 'dev'; Subscription = $ids[3]; Groups = @('rg-devteam-sand-alert-01'); Service = 'devteam' }
        @{ Name = '検証ではsandとdevを無視'; Environment = 'stg'; Subscription = $ids[2]; Groups = @('rg-pay-sand-alert-01', 'rg-pay-dev-alert-01'); Service = '<サービス略称>' }
        @{ Name = '本番ではsandとdevを無視'; Environment = 'prod'; Subscription = $ids[0]; Groups = @('rg-pay-sand-alert-01', 'rg-pay-dev-alert-01'); Service = '<サービス略称>' }
    )
    $namingDirectory = Join-Path $scratch 'naming'
    $null = New-Item $namingDirectory -ItemType Directory
    foreach ($environment in @('prod', 'stg', 'dev')) {
        "previous-$environment" | Set-Content (Join-Path $namingDirectory "targets-$environment.csv")
    }
    foreach ($case in $namingCases) {
        $scenario = $case.Name
        $global:CsvGeneratorFixture.NameOverrides = @{}
        $global:CsvGeneratorFixture.NameOverrides[$case.Subscription] = $case.Groups
        $otherHashes = @{}
        foreach ($other in @('prod', 'stg', 'dev') | Where-Object { $_ -ne $case.Environment }) {
            $otherHashes[$other] = (Get-FileHash (Join-Path $namingDirectory "targets-$other.csv")).Hash
        }
        $requestStart = $global:CsvGeneratorFixture.Requests.Count
        & $Generator -Environment $case.Environment -OutputDirectory $namingDirectory *> (Join-Path $scratch 'naming.log')
        $row = @(Import-Csv (Join-Path $namingDirectory "targets-$($case.Environment).csv") | Where-Object SubscriptionName -eq $case.Subscription)[0]
        Assert-CsvTest ($row.ResourceGroup -ceq "rg-$($case.Service)-$($case.Environment)-monitor-01") '保存先RGの略称または環境名が違います。'
        Assert-CsvTest ($row.StorageAccount -ceq "st$($case.Service)$($case.Environment)archjpe01") 'ストレージ名の略称または環境名が違います。'
        Assert-CsvTest ($row.WorkspaceName -ceq "log-$($case.Service)-$($case.Environment)-archive-01") 'Log Analytics名の略称または環境名が違います。'
        $groupRequests = @($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart | Where-Object { $_ -match '/managementGroups/' })
        Assert-CsvTest ($groupRequests.Count -gt 0 -and @($groupRequests | Where-Object { $_ -notmatch "/managementGroups/$($managementGroups[$case.Environment])/descendants" }).Count -eq 0) '検索する管理グループが違います。'
        foreach ($other in $otherHashes.Keys) {
            Assert-CsvTest ((Get-FileHash (Join-Path $namingDirectory "targets-$other.csv")).Hash -ceq $otherHashes[$other]) "$other のCSVを書き換えています。"
        }
    }
    $global:CsvGeneratorFixture.NameOverrides = @{}
    $scenarioCount += $namingCases.Count

    # 有効以外の状態はCSVに含めず、リソースグループの一覧も取得しない。
    $scenario = '有効・無効状態の混在'
    $scenarioCount++
    $global:CsvGeneratorFixture.StateOverrides = @{
        $ids[1] = 'Disabled'
        $ids[5] = 'Warned'
        $ids[6] = 'PastDue'
        $ids[7] = 'Deleted'
        $ids[8] = $null
    }
    $requestStart = $global:CsvGeneratorFixture.Requests.Count
    $otherHashes = @{}
    foreach ($other in @('stg', 'dev')) {
        $otherHashes[$other] = (Get-FileHash (Join-Path $namingDirectory "targets-$other.csv")).Hash
    }
    & $Generator -Environment prod -OutputDirectory $namingDirectory *> (Join-Path $scratch 'states.log')
    $enabledRows = @(Import-Csv (Join-Path $namingDirectory 'targets-prod.csv'))
    Assert-CsvTest ($enabledRows.Count -eq 1 -and $enabledRows[0].SubscriptionName -eq $ids[0]) 'Enabled以外、または状態のないサブスクリプションをCSVへ含めています。'
    $stateRequests = @($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart)
    $resourceRequests = @($stateRequests | Where-Object { $_ -match '/resourcegroups\?' })
    Assert-CsvTest ($resourceRequests.Count -eq 2 -and @($resourceRequests | Where-Object { $_ -notmatch "/subscriptions/$($ids[0])/resourcegroups" }).Count -eq 0) '無効なサブスクリプションのリソースグループを取得しています。'
    Assert-CsvTest (@($stateRequests | Where-Object { ([uri]$_).AbsolutePath -eq '/subscriptions' }).Count -eq 1) '状態をサブスクリプションごとに問い合わせています。'
    foreach ($other in $otherHashes.Keys) {
        Assert-CsvTest ((Get-FileHash (Join-Path $namingDirectory "targets-$other.csv")).Hash -ceq $otherHashes[$other]) "$other のCSVを書き換えています。"
    }

    # 全件無効でもエラーにせず、見出しだけを出力する。
    $scenario = '全件無効'
    $scenarioCount++
    foreach ($id in $ids) {
        $global:CsvGeneratorFixture.StateOverrides[$id] = 'Disabled'
    }
    $requestStart = $global:CsvGeneratorFixture.Requests.Count
    & $Generator -Environment dev -OutputDirectory $namingDirectory *> (Join-Path $scratch 'disabled.log')
    $disabledPath = Join-Path $namingDirectory 'targets-dev.csv'
    Assert-CsvTest (@(Import-Csv $disabledPath).Count -eq 0) '全件無効の環境にCSVのデータ行があります。'
    Assert-CsvTest (((Get-Content $disabledPath -TotalCount 1) -replace '"', '') -ceq ($columns -join ',')) '全件無効のCSVに6列の見出しがありません。'
    Assert-CsvTest (@($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart | Where-Object { $_ -match '/resourcegroups\?' }).Count -eq 0) '全件無効でもリソースグループを取得しています。'
    $global:CsvGeneratorFixture.StateOverrides = @{}

    # 状態一覧の次ページにある有効サブスクリプションも取得する。
    $scenario = '状態一覧のページング'
    $scenarioCount++
    $global:CsvGeneratorFixture.Scenario = '状態ページング'
    $requestStart = $global:CsvGeneratorFixture.Requests.Count
    & $Generator -Environment dev -OutputDirectory $namingDirectory *> (Join-Path $scratch 'state-pages.log')
    $enabledRows = @(Import-Csv (Join-Path $namingDirectory 'targets-dev.csv'))
    Assert-CsvTest ($enabledRows.Count -eq 2 -and $ids[3] -in $enabledRows.SubscriptionName -and $ids[4] -in $enabledRows.SubscriptionName) '状態一覧の次ページにある有効サブスクリプションを取りこぼしています。'
    Assert-CsvTest (@($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart | Where-Object { ([uri]$_).AbsolutePath -eq '/subscriptions' }).Count -eq 2) '状態一覧の次ページを取得していません。'

    # 状態一覧の途中で失敗したら、リソースグループを読まず、既存CSVも残す。
    $scenario = '状態一覧の取得失敗'
    $scenarioCount++
    $global:CsvGeneratorFixture.Scenario = '状態取得失敗'
    $before = @{}
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $before[$environment] = (Get-FileHash (Join-Path $namingDirectory "targets-$environment.csv")).Hash
    }
    $requestStart = $global:CsvGeneratorFixture.Requests.Count
    $failed = $false
    try { & $Generator -Environment dev -OutputDirectory $namingDirectory *> (Join-Path $scratch 'state-failure.log') }
    catch { $failed = $true }
    Assert-CsvTest $failed '状態一覧の取得失敗を成功として扱っています。'
    Assert-CsvTest (@($global:CsvGeneratorFixture.Requests | Select-Object -Skip $requestStart | Where-Object { $_ -match '/resourcegroups\?' }).Count -eq 0) '状態一覧を取得し終わる前にリソースグループを読んでいます。'
    foreach ($environment in @('prod', 'stg', 'dev')) {
        Assert-CsvTest ((Get-FileHash (Join-Path $namingDirectory "targets-$environment.csv")).Hash -ceq $before[$environment]) "$environment のCSVを取得失敗時に上書きしています。"
    }
    $global:CsvGeneratorFixture.Scenario = '正常'

    # 関数定義だけを読み、CSVには使わない日本語タグも元の文字列で返ることを確認する。
    $scenario = '日本語タグ'
    $generatorTokens = $null
    $generatorErrors = $null
    $generatorAst = [Management.Automation.Language.Parser]::ParseFile($Generator, [ref]$generatorTokens, [ref]$generatorErrors)
    $definition = $generatorAst.Find({ param($node)
        $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Get-AzureList'
    }, $true)
    . ([scriptblock]::Create($definition.Extent.Text))
    $decodedGroups = @(Get-AzureList "https://management.azure.com/subscriptions/$($ids[2])/resourcegroups?api-version=2022-09-01")
    Assert-CsvTest ($decodedGroups[0].tags.cost_center -ceq $global:CsvGeneratorFixture.TagValue) '日本語・引用符・逆斜線・改行・絵文字を含むタグが元の値と違います。'

    # 配布時と同じ配置を一時フォルダに作り、出力先を省略したときの保存先を確かめる。
    $scenario = '既定の出力先'
    $temporaryRepository = Join-Path $scratch 'default-output'
    $temporaryTools = Join-Path $temporaryRepository 'tools'
    $null = New-Item $temporaryTools -ItemType Directory -Force
    $temporaryGenerator = Join-Path $temporaryTools 'create_targets.ps1'
    Copy-Item $Generator $temporaryGenerator
    & $temporaryGenerator -Environment stg *> (Join-Path $scratch 'default-output.log')
    $defaultDirectory = Join-Path $temporaryRepository 'migration/generated'
    $defaultCsv = Join-Path $defaultDirectory 'targets-stg.csv'
    Assert-CsvTest (Test-Path $defaultCsv) '既定の出力先がmigration/generatedではありません。'
    Assert-CsvTest (@(Get-ChildItem $defaultDirectory -Filter '*.csv').Count -eq 1) '既定出力でほかの環境のCSVも作っています。'
    Assert-CsvTest ((Get-FileHash $defaultCsv).Hash -ceq (Get-FileHash (Join-Path $scratch 'targets-stg.csv')).Hash) '既定出力と明示出力でCSVの内容が違います。'
    Assert-CsvTest (-not (Test-Path (Join-Path $temporaryRepository 'procedural-migration'))) '旧フォルダへ出力しています。'

    # 空の環境では、指定した環境のCSVだけを新規作成し、6列の見出しを残す。
    $scenario = '空'
    $global:CsvGeneratorFixture.Scenario = $scenario
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $emptyDirectory = Join-Path $scratch "empty-$environment"
        $requestStart = $global:CsvGeneratorFixture.Requests.Count
        & $Generator -Environment $environment -OutputDirectory $emptyDirectory *> (Join-Path $scratch "empty-$environment.log")
        $path = Join-Path $emptyDirectory "targets-$environment.csv"
        Assert-CsvTest (@(Import-Csv $path).Count -eq 0) "$environment / 空のCSVにデータ行があります。"
        $header = Get-Content $path -TotalCount 1
        Assert-CsvTest (($header -replace '"', '') -ceq ($columns -join ',')) "$environment / 空のCSVに6列の見出しがありません。"
        Assert-CsvTest (@(Get-ChildItem $emptyDirectory -Filter '*.csv').Count -eq 1) "$environment / ほかの環境のCSVも作成しています。"
        Assert-CsvTest (($global:CsvGeneratorFixture.Requests.Count - $requestStart) -eq 1) "$environment / 空の一覧以外にもAzureへ要求しています。"
    }

    # 選んだ環境でリソースグループの2ページ目を取得できない場合、既存CSVをどれも上書きしない。
    $scenario = '取得失敗'
    $global:CsvGeneratorFixture.Scenario = $scenario
    $before = @{}
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $path = Join-Path $scratch "targets-$environment.csv"
        $before[$environment] = (Get-FileHash $path).Hash
    }
    $failed = $false
    try { & $Generator -Environment prod -OutputDirectory $scratch *> (Join-Path $scratch 'failure.log') }
    catch { $failed = $true }
    Assert-CsvTest $failed 'Azure取得失敗を成功として扱っています。'
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $path = Join-Path $scratch "targets-$environment.csv"
        Assert-CsvTest ((Get-FileHash $path).Hash -ceq $before[$environment]) "$environment / 取得失敗時に既存CSVを上書きしています。"
    }
    # 無効な環境名と空の指定は、Azureを読まず、出力フォルダも作らずに拒否する。
    $scenario = '引数の拒否'
    foreach ($invalidEnvironment in @('all', $null)) {
        $invalidDirectory = Join-Path $scratch 'invalid'
        $requestStart = $global:CsvGeneratorFixture.Requests.Count
        $failed = $false
        try { & $Generator -Environment $invalidEnvironment -OutputDirectory $invalidDirectory *> (Join-Path $scratch 'invalid.log') }
        catch { $failed = $true }
        Assert-CsvTest $failed '無効または空の環境指定を受け入れています。'
        Assert-CsvTest ($global:CsvGeneratorFixture.Requests.Count -eq $requestStart) '引数のエラーでもAzureを読んでいます。'
        Assert-CsvTest (-not (Test-Path $invalidDirectory)) '引数のエラーでも出力先を作っています。'
    }
    Assert-CsvTest ($global:CsvGeneratorFixture.AsciiRequests -eq $global:CsvGeneratorFixture.Requests.Count) 'JSONをASCII文字で受け取るquery・tsv指定がないCLI要求があります。'
    Assert-CsvTest ($global:CsvGeneratorFixture.CmdSafeRequests -eq $global:CsvGeneratorFixture.Requests.Count) 'Windowsのaz.cmdへ括弧を保護して渡すための空白がqueryにありません。'
    "PASS: $scenarioCount シナリオ、$checks 判定。Azureへの通信は0件。"
}
finally {
    Remove-Item $scratch -Recurse -Force
    Remove-Variable CsvGeneratorFixture -Scope Global
}
