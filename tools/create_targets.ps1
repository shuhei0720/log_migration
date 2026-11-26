#Requires -Version 7.0
param(
    [Parameter(Mandatory)][ValidateSet('dev', 'stg', 'prod')][string]$Environment,
    [string]$OutputDirectory = (Join-Path $PSScriptRoot '../migration/generated')
)

# ---
# 準備：管理グループと、リソース名に入れる環境名を指定する。
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
$Environment = $Environment.ToLowerInvariant()

function Get-AzureList {
    <#
    .SYNOPSIS
    Azureから一覧を取得する。
    .DESCRIPTION
    Azure CLIのログインを使い、指定URLへGETする。
    応答のvalueに入っている一覧の項目を返す。
    続きの取得先URL（nextLink）があればそこへGETし、残りの項目も返す。
    取得に失敗した場合はエラーにし、CSVを書き出す前に処理を止める。
    .PARAMETER Url
    一覧を取得するAzure管理APIのURL。
    .OUTPUTS
    一覧に含まれるオブジェクト。0件の場合は何も返さない。
    #>
    param([string]$Url)
    while ($Url) {
        # WindowsのバッチにURLを渡すときは、nextLink内の&などがコマンドの区切りにならないよう保護する。
        $requestUrl = $Url
        if ($IsWindows -and (Get-Command az).Source -match '\.(cmd|bat)$') {
            $requestUrl = '"' + $Url + '"'
        }
        # 日本語を英数字のエスケープ表記で受け取り、Windowsの文字コードでJSONが壊れるのを防ぐ。
        # tsvはJSON文字列をそのまま出力させるために指定し、ConvertFrom-Jsonで元の値へ戻す。
        # 式の空白は、PowerShellからaz.cmdへ引用符付きで渡し、括弧の誤解釈を防ぐために必要。
        $response = az rest --method get --url $requestUrl --query 'to_string( @ )' --output tsv --only-show-errors
        if ($LASTEXITCODE -ne 0) {
            throw "Azureの一覧を取得できません: $Url"
        }
        $page = $response | ConvertFrom-Json
        $page.value
        $Url = $page.nextLink
    }
}

# ---
# 1. 指定した環境のサブスクリプションを取得する。子管理グループの配下も含める。
# ---
$settings = $environmentSettings[$Environment]
$environmentName = $settings.NamePart
$descendants = @(Get-AzureList "$armBase$($settings.ManagementGroupId)/descendants?api-version=2020-05-01")
$subscriptions = @($descendants | Where-Object { $_.id -match '^/subscriptions/[^/]+$' } | Sort-Object id -Unique)
# ---
# 2. 各サブスクリプションのalert用グループから略称を取り出し、CSVの保存先名を作る。
# ---
$csvRows = @()
foreach ($subscription in $subscriptions) {
    $subscriptionId = ($subscription.id -split '/')[-1]
    $resourceGroups = @(Get-AzureList "$armBase/subscriptions/$subscriptionId/resourcegroups?api-version=2022-09-01")

    # 候補が0件・複数件なら略称を決めず、CSVに人が埋める欄を残す。
    $pattern = '^rg-(?<Service>.+)-' + [regex]::Escape($environmentName) + '-alert-01$'
    $matchingGroups = @($resourceGroups | Where-Object { $_.name -match $pattern })
    $serviceAbbreviation = '<サービス略称>'
    if ($matchingGroups.Count -eq 1) {
        $null = $matchingGroups[0].name -match $pattern
        $serviceAbbreviation = $Matches.Service.ToLowerInvariant()
    }
    else {
        Write-Warning "$Environment / $subscriptionId : alert用グループの候補が$($matchingGroups.Count)件です。CSVの<サービス略称>を置き換えてください。"
    }

    $storageAccountName = "st${serviceAbbreviation}${environmentName}archjpe01"
    # 小文字英数字3～24文字・jpeが1か所という条件を満たさなければ警告し、略称は勝手に変えない。
    if ($matchingGroups.Count -eq 1 -and ($storageAccountName -cnotmatch '^[a-z0-9]{3,24}$' -or
        [regex]::Matches($storageAccountName, 'jpe').Count -ne 1)) {
        Write-Warning "$Environment / $subscriptionId : 生成したストレージ名は小文字英数字3～24文字・jpeが1か所という条件を満たしません: $storageAccountName"
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

# ---
# 3. すべて取得できたら、指定した環境のCSVだけを出力する。
# 取得に失敗した場合はここへ進まないため、前回のCSVを残せる。
# ---
$null = New-Item $OutputDirectory -ItemType Directory -Force
$path = Join-Path $OutputDirectory "targets-$Environment.csv"
if ($csvRows.Count) {
    $csvRows | Select-Object $columns | Export-Csv $path -NoTypeInformation -Encoding utf8BOM
}
else {
    # サブスクリプションが0件でも、6列の見出しを残す。
    $columns -join ',' | Set-Content $path -Encoding utf8BOM
    Write-Warning "$Environment : 管理グループ配下にサブスクリプションがありません。"
}
Write-Host "$Environment : $($csvRows.Count)件 -> $path"
