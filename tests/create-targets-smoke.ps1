#Requires -Version 7.0
param([string]$Generator = (Join-Path (Split-Path $PSScriptRoot -Parent) 'tools/create_targets.ps1'))
$ErrorActionPreference = 'Stop'
$checks = 0
$scenario = '正常'
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('create-targets-' + [guid]::NewGuid().ToString('N'))
$null = New-Item $scratch -ItemType Directory
$columns = @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')
$ids = @(1..9 | ForEach-Object { '00000000-0000-0000-0000-{0:d12}' -f $_ })
$global:CsvGeneratorFixture = @{ Scenario = '正常'; Requests = @(); Ids = $ids }

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
    $global:CsvGeneratorFixture.Requests += $url
    $global:LASTEXITCODE = 0
    $uri = [uri]$url
    $path = $uri.AbsolutePath.ToLowerInvariant()
    if ($global:CsvGeneratorFixture.Scenario -eq '取得失敗' -and $path -match '/managementgroups/sandbox/descendants$') {
        $global:LASTEXITCODE = 1
        return '{"error":{"message":"テスト用の取得失敗"}}'
    }
    if ($global:CsvGeneratorFixture.Scenario -eq '空') {
        return '{"value":[]}'
    }
    $page = @{ value = @() }
    if ($path -match '/managementgroups/(producrion|staging|sandbox)/descendants$') {
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
        $page.value = @($names | ForEach-Object { @{ name = $_ } })
    }
    else {
        throw "想定外のURL: $url"
    }
    $page | ConvertTo-Json -Depth 6 -Compress
}

try {
    # 3環境の名前、子管理グループ、ページング、重複除去、略称を決められない行をまとめて確認する。
    & $Generator -OutputDirectory $scratch *> (Join-Path $scratch 'normal.log')
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
    $warnings = Get-Content (Join-Path $scratch 'normal.log') -Raw
    Assert-CsvTest ([regex]::Matches($warnings, '条件を満たしません').Count -eq 3) '25文字・記号・jpe重複の3件を警告していません。'


    # サブスクリプションがない環境でも、架空の行を作らず6列の見出しを残す。
    $scenario = '空'
    $global:CsvGeneratorFixture.Scenario = $scenario
    & $Generator -OutputDirectory $scratch *> (Join-Path $scratch 'empty.log')
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $path = Join-Path $scratch "targets-$environment.csv"
        Assert-CsvTest (@(Import-Csv $path).Count -eq 0) "$environment / 空のCSVにデータ行があります。"
        $header = Get-Content $path -TotalCount 1
        Assert-CsvTest (($header -replace '"', '') -ceq ($columns -join ',')) "$environment / 空のCSVに6列の見出しがありません。"
    }

    # 最後の環境の取得が失敗した場合、前回作った3ファイルをどれも上書きしない。
    $scenario = '取得失敗'
    $global:CsvGeneratorFixture.Scenario = $scenario
    $before = @{}
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $path = Join-Path $scratch "targets-$environment.csv"
        $before[$environment] = (Get-FileHash $path).Hash
    }
    $failed = $false
    try { & $Generator -OutputDirectory $scratch *> (Join-Path $scratch 'failure.log') }
    catch { $failed = $true }
    Assert-CsvTest $failed 'Azure取得失敗を成功として扱っています。'
    foreach ($environment in @('prod', 'stg', 'dev')) {
        $path = Join-Path $scratch "targets-$environment.csv"
        Assert-CsvTest ((Get-FileHash $path).Hash -ceq $before[$environment]) "$environment / 取得失敗時に既存CSVを上書きしています。"
    }
    "PASS: 3シナリオ、$checks 判定。Azureへの通信は0件。"
}
finally {
    Remove-Item $scratch -Recurse -Force
    Remove-Variable CsvGeneratorFixture -Scope Global
}
