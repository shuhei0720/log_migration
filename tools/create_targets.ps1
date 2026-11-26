#Requires -Version 7.0
param([string]$OutputDirectory = (Join-Path $PSScriptRoot '../procedural-migration/generated'))

# ---
# 管理グループと、リソース名に入れる環境名を指定する。
# 開発のリソース名にはdevを使い、管理グループIDのsandboxとは区別する。
# ---
$environmentSettings = [ordered]@{
    prod = @{ ManagementGroupId = '/providers/Microsoft.Management/managementGroups/producrion'; NamePart = 'prod' }
    stg = @{ ManagementGroupId = '/providers/Microsoft.Management/managementGroups/staging'; NamePart = 'stg' }
    dev = @{ ManagementGroupId = '/providers/Microsoft.Management/managementGroups/sandbox'; NamePart = 'dev' }
}
$logDestination = 'Storage'
$vmLogDestination = 'Log'

$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'
$armBase = 'https://management.azure.com'
$columns = @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')
$csvByEnvironment = [ordered]@{}

function Get-AzureList {
    <#
    .SYNOPSIS
    Azureから一覧を取得する。
    .DESCRIPTION
    Azure CLIのログインを使い、指定URLへGETする。
    次のページがあれば取得を続け、全ページのvalueの要素を返す。
    取得に失敗した場合はエラーにし、CSVを書き出す前に処理を止める。
    .PARAMETER Url
    一覧を取得するAzure管理APIのURL。
    .OUTPUTS
    一覧に含まれるオブジェクト。0件の場合は何も返さない。
    #>
    param([string]$Url)
    while ($Url) {
        $response = az rest --method get --url $Url --output json --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Azureの一覧を取得できません: $Url"
        }
        $page = $response | ConvertFrom-Json
        $page.value
        $Url = $page.nextLink
    }
}

# ---
# 子管理グループの配下も含めてサブスクリプションを探す。
# 環境ごとの全一覧を取得してからCSVを書くため、途中の取得失敗では既存CSVを上書きしない。
# ---
foreach ($environment in $environmentSettings.Keys) {
    $settings = $environmentSettings[$environment]
    $environmentName = $settings.NamePart
    $descendants = @(Get-AzureList "$armBase$($settings.ManagementGroupId)/descendants?api-version=2020-05-01")
    $subscriptions = @($descendants | Where-Object { $_.id -match '^/subscriptions/[^/]+$' } | Sort-Object id -Unique)
    $csvRows = @()
    foreach ($subscription in $subscriptions) {
        $subscriptionId = ($subscription.id -split '/')[-1]
        $resourceGroups = @(Get-AzureList "$armBase/subscriptions/$subscriptionId/resourcegroups?api-version=2022-09-01")

        # alert用グループの名前から略称を取り出す。候補が一つに決まらなければ、人が埋める欄にする。
        $pattern = '^rg-(?<Service>.+)-' + [regex]::Escape($environmentName) + '-alert-01$'
        $matchingGroups = @($resourceGroups | Where-Object { $_.name -match $pattern })
        $serviceAbbreviation = '<サービス略称>'
        if ($matchingGroups.Count -eq 1) {
            $null = $matchingGroups[0].name -match $pattern
            $serviceAbbreviation = $Matches.Service.ToLowerInvariant()
        }
        else {
            Write-Warning "$environment / $subscriptionId : alert用グループの候補が$($matchingGroups.Count)件です。CSVの<サービス略称>を置き換えてください。"
        }

        $storageAccountName = "st${serviceAbbreviation}${environmentName}archjpe01"
        # 略称を勝手に省略しない。生成名が移行スクリプトの条件に合わなければ、修正が必要な行を知らせる。
        if ($matchingGroups.Count -eq 1 -and ($storageAccountName -cnotmatch '^[a-z0-9]{3,24}$' -or
            [regex]::Matches($storageAccountName, 'jpe').Count -ne 1)) {
            Write-Warning "$environment / $subscriptionId : 生成したストレージ名は小文字英数字3～24文字・jpeが1か所という条件を満たしません: $storageAccountName"
        }
        $csvRows += [pscustomobject][ordered]@{
            SubscriptionName = $subscriptionId
            ResourceGroup = "rg-$serviceAbbreviation-$environmentName-monitor-01"
            StorageAccount = $storageAccountName
            WorkspaceName = "log-$serviceAbbreviation-$environmentName-archive-01"
            LogDestination = $logDestination
            VmLogDestination = $vmLogDestination
        }
    }
    $csvByEnvironment[$environment] = $csvRows
}

# ---
# 移行スクリプトと同じ6列を、環境ごとに出力する。targets.csvは直接上書きしない。
# サブスクリプションが0件の環境も、見出しだけのCSVを作る。
# ---
$null = New-Item $OutputDirectory -ItemType Directory -Force
foreach ($environment in $csvByEnvironment.Keys) {
    $path = Join-Path $OutputDirectory "targets-$environment.csv"
    $csvRows = $csvByEnvironment[$environment]
    if ($csvRows.Count) {
        $csvRows | Select-Object $columns | Export-Csv $path -NoTypeInformation -Encoding utf8BOM
    }
    else {
        $columns -join ',' | Set-Content $path -Encoding utf8BOM
        Write-Warning "$environment : 管理グループ配下にサブスクリプションがありません。"
    }
    Write-Host "$environment : $($csvRows.Count)件 -> $path"
}
