#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Capture')][string]$Action = 'Plan',
    [Parameter(Mandatory)][ValidatePattern('^[a-z0-9]{8,13}$')][string]$RunId,
    [string]$RunRoot = (Join-Path $PSScriptRoot 'runs'),
    [decimal]$BudgetJPY = 0,
    [switch]$IncludeConditional,
    [switch]$IncludeAse,
    [string[]]$SkipTypes = @('microsoft.databricks/workspaces', 'microsoft.cache/redis'),
    [string]$AdminSshPublicKey = '',
    [string]$PublisherEmail = 'fixture@example.invalid',
    [ValidateRange(0, 1000)][int]$LoadCount = 0
)

# ---
# 準備：テストする2つのサブスクリプション、既存VNet、配置先の地域を指定する。
# VNetとサブネットの設定は変えない。NSGやルートテーブルも関連付けない。
# Databricksと旧Redisは、SkipTypesで除外している。
# ---
$SubscriptionIds = @('5f1b809c-f59f-4489-8211-4bef16a0463a', 'bfda36ec-1aed-4b0c-a907-4d4809c63888')
$ExistingVnetIds = @(
    '/subscriptions/5f1b809c-f59f-4489-8211-4bef16a0463a/resourceGroups/rg-finalps7-net-a/providers/Microsoft.Network/virtualNetworks/vnet-finalps7-a',
    '/subscriptions/bfda36ec-1aed-4b0c-a907-4d4809c63888/resourceGroups/rg-finalps7-net-b/providers/Microsoft.Network/virtualNetworks/vnet-finalps7-b'
)
$Locations = [ordered]@{'A-R1' = 'japaneast';'A-R3' = 'canadacentral';'B-R2' = 'japanwest';'B-R4' = 'westus2'}
$SubnetNames = [ordered]@{
    Protect = 'ProtectSubnet'
    Private = 'PrivateSubnet'
    ApplicationGateway = 'ApplicationGatewaySubnet'
    VNetIntegration = 'VNetIntegrationSubnet'
    AzureFirewall = 'AzureFirewallSubnet'
}
$SubnetPrefixLengths = @{Protect=27;Private=26;ApplicationGateway=24;VNetIntegration=26;AzureFirewall=26}
$MaximumHours = 6
$ErrorActionPreference = 'Stop'
$Utf8 = [Text.UTF8Encoding]::new($false)
$ArmBase = 'https://management.azure.com'
$TemplatePath = Join-Path $PSScriptRoot 'resource_types.arm.json'
$Template = Get-Content $TemplatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
$RunPath = Join-Path $RunRoot $RunId
$StatePath = Join-Path $RunPath 'run-ledger.json'
$state = $null
$accessToken = $null
$tokenExpiry = [DateTimeOffset]::MinValue

function Invoke-Arm {
    <#
    .SYNOPSIS
    Azureへ操作を要求し、応答を返す。
    .DESCRIPTION
    呼出先URLと認証情報を用意してAzure APIへ要求する。一時的なHTTPエラーは初回を含め4回まで試す。
    一覧のデータが複数ページなら続きも取得し、応答のvalue（一覧の項目）へ全件をまとめる。
    GET・HEAD以外は、送信前に操作先をrun-ledger.jsonへ記録し、応答後に受付結果を残す。
    .PARAMETER Method
    取得はGET、作成・更新はPUT、利用登録はPOSTを渡す。
    .PARAMETER Id
    操作するリソースID、またはAzure管理APIのURL。
    .PARAMETER ApiVersion
    使用するAPIの版。IdのURLにapi-versionがあれば、その指定を使う。
    .PARAMETER Body
    作成・更新する設定値。省略した場合は、設定値を送らない。
    .PARAMETER Optional
    存在を調べるときに付ける。HTTP 404をエラーにせず、$nullを返す。
    .PARAMETER AllowError
    HTTPエラーも調べたいときに付ける。処理を止めず、error項目を持つ応答を返す。
    .OUTPUTS
    Azureの応答を持つ辞書。本文がない場合と、Optionalで404だった場合は$null。
    #>
    # ---
    # 接続先を組み立て、Azureを変更する要求は送信前に操作先を記録する。
    # ---
    param($Method, $Id, $ApiVersion, $Body = $null, [switch]$Optional, [switch]$AllowError)
    $uri = if ($Id.StartsWith('https://')){
        $Id
    }else{
        $ArmBase + $Id
    }
    # 認証情報を別のサーバーへ送らないよう、Azure管理APIのURLだけを受け付ける。
    if (([Uri]$uri).GetLeftPart([UriPartial]::Authority) -cne $ArmBase){
        throw 'Unexpected ARM host.'
    }
    if ($Method -notin @('GET', 'HEAD') -and ([Uri]$uri).AbsolutePath -match '/providers/Microsoft.Network/virtualNetworks/[^/]+(?:/subnets/[^/]+)?/?$'){
        throw 'VNet/subnet writes are prohibited.'
    }
    if ($uri -notmatch '[?&]api-version='){
        $uri+=$(if ($uri.Contains('?')){
                '&'
            }else{
                '?'
        }) + 'api-version=' + $ApiVersion
    }
    $operation = $null
    # 開始からMaximumHoursを過ぎたら、Azureへの変更を止める。
    # 状態を調べるGETとHEADは、その後も実行できる。
    if ($state -and $Method -notin @('GET', 'HEAD') -and [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$state.startedUtc).AddHours($MaximumHours)) {
        throw 'Run lifetime exceeded; delete the test resource groups.'
    }
    if ($state -and $Method -notin @('GET', 'HEAD')){
        $operation = @{
            method = $Method
            id = $Id
            apiVersion = $ApiVersion
            status = 'INTENT'
            startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        }
        $state.operations+=, $operation
        Save-State
    }
    # ---
    # 認証して要求を送り、一覧が複数ページに分かれていれば最後まで取得する。
    # ---
    $items = @()
    $page = $null
    $listStarted = $false
    do {
        # 有効期限が残り2分以内なら、通信前に認証トークンを取り直す。
        if ([DateTimeOffset]::UtcNow.AddMinutes(2) -ge $script:tokenExpiry){
            $login = az account get-access-token --subscription $SubscriptionIds[0] --resource ($ArmBase + '/') --output json --only-show-errors | ConvertFrom-Json -AsHashtable
            if ($LASTEXITCODE -ne 0 -or -not $login.accessToken){
                throw 'Azure CLI token acquisition failed.'
            }
            $script:accessToken = $login.accessToken
            $script:tokenExpiry = if ($login.expires_on){
                [DateTimeOffset]::FromUnixTimeSeconds([long]$login.expires_on)
            }else{
                [DateTimeOffset]::Parse($login.expiresOn)
            }
        }
        $request = @{
            Uri = $uri
            Method = $Method
            Headers = @{
                Authorization = ('Bearer ' + $script:accessToken)
                'Cache-Control' = 'no-cache'
            }
            SkipHttpErrorCheck = $true
            TimeoutSec = 300
        }
        if ($null -ne $Body){
            $request.ContentType = 'application/json; charset=utf-8'
            $request.Body = $Utf8.GetBytes(($Body | ConvertTo-Json -Depth 100))
        }
        # 混雑や一時的なサーバーエラーなら、待ってから同じ要求を送る。
        # 設定や権限のエラーは再送せず、呼出し元へ伝える。
        for ($attempt = 0;$attempt -lt 4;$attempt++){
            $response = Invoke-WebRequest @request
            if ([int]$response.StatusCode -notin @(408, 429, 500, 502, 503, 504) -or $attempt -eq 3){
                break
            }
            Start-Sleep -Seconds ([Math]::Min(30, [Math]::Pow(2, $attempt + 1)))
        }
        if ($Optional -and [int]$response.StatusCode -eq 404) {
            if ($operation) {
                $operation.status = 'ABSENT';
                Save-State
            }
            return $null
        }
        try {
            $page = if ($response.Content){
                $response.Content | ConvertFrom-Json -AsHashtable
            }else{
                $null
            }
        } catch {
            throw ('ARM returned non-JSON HTTP ' + $response.StatusCode)
        }
        if ([int]$response.StatusCode -ge 400){
            $page = @{ error = ($page.error ?? $page) }
            if ($operation){
                $operation.status = 'FAILED'
                $operation.errorCode = $page.error.code
                Save-State
            }
            if ($AllowError){
                return $page
            }
            throw ('ARM ' + $response.StatusCode + ' ' + $page.error.code + ' ' + $Id)
        }
        # 一覧の各ページにvalueがあることを確かめる。
        # 途中のページから欠けた場合は、全件取得できていないので止める。
        if ($page -and $page.ContainsKey('value')) {
            if ($page.value -isnot [array]) {
                throw 'ARM list response does not contain a value array.'
            }
            $listStarted = $true
            $items += @($page.value)
        } elseif ($listStarted -or $page.nextLink) {
            throw 'ARM list continuation omitted its value array.'
        }
        $uri = $page.nextLink
        if ($uri -and ([Uri]$uri).GetLeftPart([UriPartial]::Authority) -cne $ArmBase){
            throw 'Unexpected ARM nextLink.'
        }
    } while ($uri)
    # ---
    # Azureに要求が受け付けられたことを記録し、取得した応答を返す。
    # ---
    if ($operation){
        $operation.status = 'ACCEPTED'
        Save-State
    }
    if ($page -and $page.ContainsKey('value')){
        $page.value = $items
    }
    return $page
}

function Save-State {
    <#
    .SYNOPSIS
    作成計画と操作結果をrun-ledger.jsonへ保存する。
    .DESCRIPTION
    引数は使わず、作成計画や操作結果を持つ$stateを$StatePathへ保存する。
    一時ファイルへ書き終えてから置き換え、書込み途中の内容が作業記録として残るのを防ぐ。
    .OUTPUTS
    なし。
    #>
    [IO.File]::WriteAllText(($StatePath + '.pending'), ($state | ConvertTo-Json -Depth 100), $Utf8)
    Move-Item ($StatePath + '.pending') $StatePath -Force
}

function Wait-Resource {
    <#
    .SYNOPSIS
    リソースの作成状態を調べ、完了と判定した応答を返す。
    .DESCRIPTION
    10秒間隔で取得し直す。作成状態を返すリソースはSucceededになるまで待つ。
    作成状態を返さないリソースは、取得できたら完了と判定する。
    Failed・Canceledを受け取った場合や、90分以内に完了を確認できない場合はエラーにする。
    .PARAMETER Id
    作成完了を確認するリソースID。
    .PARAMETER ApiVersion
    状態の取得に使うAPIの版。
    .OUTPUTS
    完了と判定したAzureの応答を持つ辞書。
    #>
    param($Id, $ApiVersion)
    $limit = [DateTimeOffset]::UtcNow.AddMinutes(90)
    do {
        $current = Invoke-Arm GET $Id $ApiVersion -Optional
        if ($current) {
            if ($current.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw ('Provisioning failed: ' + $Id)
            }
            # 作成状態を返さないAPIでは、リソースが取得できれば完了とする。
            # 作成状態があるAPIでは、Succeededになるまで待つ。
            if (-not $current.properties -or -not $current.properties.ContainsKey('provisioningState') -or $current.properties.provisioningState -eq 'Succeeded') {
                return $current
            }
        }
        if ([DateTimeOffset]::UtcNow -ge $limit){
            throw ('Completion wait exceeded: ' + $Id)
        }
        Start-Sleep -Seconds 10
    } while ($true)
}

# ---
# 1. Plan・Deploy：作成するリソースを選び、名前・ID・配置先を決める。
# サブスクリプションごとに1つのグループを使う。配置先の一覧（bundles）は、サブスクリプションと地域の組。
# ---
if ($Action -in @('Plan', 'Deploy')){
    $keys = @()
    $skipped = @()
    foreach ($type in $Template.metadata.fixtureTypes){
        $reason = if ($type.skipReason){
            $type.skipReason
        }elseif ($type.resourceType -in $SkipTypes){
            'SkipTypesで省略'
        }elseif ($type.conditional -and -not $IncludeConditional){
            '条件付きリソースを省略'
        }elseif ($type.optionalSwitch -eq 'IncludeAse' -and -not $IncludeAse){
            'ASEの明示選択なし'
        }
        if ($reason){
            $skipped+=@{resourceType = $type.resourceType;reason = $reason}
        }else{
            $keys+=@($type.keys)
        }
    }
    # 選んだリソースを作るために必要なリソースも、作成一覧へ加える。
    # SkipTypesで除外した種類が必要になった場合は、作成せずに止める。
    do {
        $before = $keys.Count
        foreach ($resource in $Template.resources){
            if ($resource.metadata.fixture.key -in $keys){
                $keys+=@($resource.metadata.fixture.dependsOnKeys)
            }
        }
        $keys = @($keys | Where-Object {
                $_
            } | Sort-Object -Unique)
    } while ($keys.Count -ne $before)
    foreach ($type in $Template.metadata.fixtureTypes){
        if ($type.resourceType -in $SkipTypes -and @($type.keys | Where-Object {
                    $_ -in $keys
            }).Count){
            throw ('Skipped dependency is required: ' + $type.resourceType)
        }
    }
    # 既存VNetの参照と、A-R1など4組の配置先をまとめる。ここではAzureへ接続しない。
    $networks = @()
    $bundles = @()
    $resources = @()
    for ($index = 0;$index -lt 2;$index++){
        # VNetのIDに、別サブスクリプションのIDやサブネットのIDが入っていれば止める。
        if ($ExistingVnetIds[$index] -notmatch ('^(/subscriptions/' + [regex]::Escape($SubscriptionIds[$index]) + '/resourceGroups/[^/?#\s]+)/providers/Microsoft.Network/virtualNetworks/[^/?#\s]+$')){
            throw 'ExistingVnetIds must be exact IDs in the configured subscriptions.'
        }
        $networks+=@{role = @('A', 'B')[$index];subscriptionId = $SubscriptionIds[$index];vnetId = $ExistingVnetIds[$index];rgId = $Matches[1]}
    }
    foreach ($bundleKey in $Locations.Keys){
        $bundles+=@{
            key = $bundleKey
            subscriptionId = $SubscriptionIds[$(if ($bundleKey.StartsWith('A')){
                        0
                    }else{
                        1
            })]
            location = $Locations[$bundleKey]
            resourceGroup = ('fx-' + $RunId + '-' + $bundleKey.Substring(0, 1).ToLowerInvariant())
        }
    }
    foreach ($resource in $Template.resources){
        $meta = $resource.metadata.fixture
        if ($meta.key -notin $keys){
            continue
        }
        $bundle = @($bundles | Where-Object key -EQ $meta.bundle)[0]
        $group = '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
        $name = $meta.nameTemplate.Replace('{runId}', $RunId)
        $types = $resource.type.Split('/')
        $names = $name.Split('/')
        # 種類と名前の階層数が合わなければ止め、合っていれば親から順にIDを組み立てる。
        if ($names.Count -ne $types.Count - 1){
            throw 'ARM name metadata does not match its resource type.'
        }
        $id = $group + '/providers/' + $types[0]
        for ($part = 0;$part -lt $names.Count;$part++){
            $id+='/' + $types[$part + 1] + '/' + $names[$part]
        }
        $resources+=@{
            id = $id
            name = $name
            key = $meta.key
            bundle = $meta.bundle
            resourceType = $resource.type.ToLowerInvariant()
            apiVersion = $resource.apiVersion
            location = $(if ($resource.location -eq 'global'){
                    'global'
                }else{
                    $bundle.location
            })
            phase = ($meta.phase ?? 'resources')
            scopeSuffixes = @($meta.scopeSuffixes | Where-Object {
                    $_
            })
            childApiVersion = ($meta.childApiVersion ?? $resource.apiVersion)
            managedName = $meta.managedResourceGroupNameTemplate
        }
    }
    # 負荷テスト用のNSGを、2つのサブスクリプションへ交互に追加する。
    for ($number = 0; $number -lt $LoadCount; $number++) {
        $bundle = $bundles[$(if ($number % 2) {
                    2
                } else {
                    0
        })]
        $name = 'fx' + $RunId + '-load-' + $number.ToString('0000')
        $resources += @{
            id = ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup + '/providers/Microsoft.Network/networkSecurityGroups/' + $name)
            name = $name
            key = 'loadNsg'
            bundle = $bundle.key
            resourceType = 'microsoft.network/networksecuritygroups'
            apiVersion = '2025-01-01'
            location = $bundle.location
            phase = 'resources'
            scopeSuffixes = @()
            load = $true
        }
    }
    $plan = @{
        runId = $RunId
        subscriptionIds = $SubscriptionIds
        bundles = $bundles
        existingNetworks = $networks
        resources = $resources
        selectedKeys = $keys
        skipped = $skipped
        budgetJPY = $BudgetJPY
        maximumHours = $MaximumHours
        scriptSha256 = (Get-FileHash $PSCommandPath).Hash
        templateSha256 = (Get-FileHash $TemplatePath).Hash
    }
    if ($Action -eq 'Plan'){
        if (Test-Path (Join-Path $RunPath 'plan.json')){
            throw 'Plan already exists; use a new RunId.'
        }
        $null = New-Item $RunPath -ItemType Directory -Force
        $plan | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $RunPath 'plan.json') -Encoding utf8
        Write-Host ('LOCAL Plan: ' + $RunPath + '; Azure calls 0.')
        return
    }
    if ($BudgetJPY -le 0){
        throw 'Set the reviewed budget before Deploy. It is not a billing hard cap.'
    }
    if (Test-Path $StatePath){
        throw 'Run ledger already exists. Use Capture or another RunId.'
    }
    # Planの後に、作成するリソースやコードが変わっていないか確認する。
    # 変わっていれば、保存済みの計画では作成を始めない。
    $reviewed = Get-Content (Join-Path $RunPath 'plan.json') -Raw | ConvertFrom-Json -AsHashtable
    foreach ($field in @('scriptSha256', 'templateSha256')){
        if ($plan[$field] -cne $reviewed[$field]){
            throw 'Source changed after Plan.'
        }
    }
    if (($plan.resources.id -join '|') -cne ($reviewed.resources.id -join '|') -or ($plan.selectedKeys -join '|') -cne ($reviewed.selectedKeys -join '|')){
        throw 'Selection differs from the reviewed Plan.'
    }
    if (@($keys | Where-Object {
                $_ -in @('computeVm', 'computeVmss', 'aks')
        }).Count -and $AdminSshPublicKey -notmatch '^ssh-(rsa|ed25519) [A-Za-z0-9+/=]+'){
        throw 'An SSH public key is required for selected compute resources.'
    }
    $state = @{
        runId = $RunId
        startedUtc = [DateTimeOffset]::UtcNow.ToString('o')
        status = 'CREATING'
        plan = $plan
        resources = $resources
        existingNetworks = @()
        operations = @()
        deployments = @()
        inventory = @()
        managedGroups = @()
        ownedExternalRoles = @()
        scopes = @()
    }
    Save-State
}else{
    # 別の試験の記録を使わないよう、RunId・サブスクリプションID・コードを作成時の記録と比べる。
    $state = Get-Content $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($state.runId -cne $RunId -or ($state.plan.subscriptionIds -join ',') -cne ($SubscriptionIds -join ',')){
        throw 'Run/subscription identity differs from the ledger.'
    }
    if ($state.plan.scriptSha256 -cne (Get-FileHash $PSCommandPath).Hash -or $state.plan.templateSha256 -cne (Get-FileHash $TemplatePath).Hash){
        throw 'Use the exact source pair saved by this run.'
    }
}

# ---
# 2. Deploy：作成先のグループ名と、既存VNet・サブネットの設定を確認する。
# 同名グループや必要なネットワーク設定の不足があれば、Azureを変更する前に止める。
# ---
$groups = @($state.plan.bundles | Group-Object subscriptionId | ForEach-Object { $_.Group[0] })
if ($Action -eq 'Deploy'){
    foreach ($bundle in $groups){
        if (Invoke-Arm GET ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' -Optional){
            throw 'A planned resource group already exists.'
        }
    }
    # 既存VNetの地域、サブネットの大きさ、サービスに必要な委任を確認する。
    # 足りない設定があっても、ここでは書き換えずに止める。
    foreach ($network in $state.plan.existingNetworks){
        $body = Invoke-Arm GET $network.vnetId '2024-05-01'
        $subnets = @{}
        if (($body.location -replace '\s', '') -ine $Locations[$(if ($network.role -eq 'A'){
                        'A-R1'
                    }else{
                        'B-R2'
        })]){
            throw 'VNet region differs from its consumer bundle.'
        }
        foreach ($role in $SubnetNames.Keys){
            $subnet = @($body.properties.subnets | Where-Object name -EQ $SubnetNames[$role])
            if ($subnet.Count -ne 1){
                throw ('Required subnet is missing: ' + $SubnetNames[$role])
            }
            $prefix = $subnet[0].properties.addressPrefix ?? @($subnet[0].properties.addressPrefixes | Where-Object { $_ -like '*.*/*' })[0]
            if ([int]$prefix.Split('/')[-1] -ne $SubnetPrefixLengths[$role]) {
                throw ('Unexpected subnet prefix size: ' + $subnet[0].name)
            }
            $expectedDelegation = if ($network.role -eq 'A' -and $role -eq 'Protect' -and 'ase' -in $keys) {
                'Microsoft.Web/hostingEnvironments'
            } elseif ($network.role -eq 'A' -and $role -eq 'VNetIntegration' -and 'containerEnvironment' -in $keys) {
                'Microsoft.App/environments'
            }
            if ($expectedDelegation -and $expectedDelegation -notin $subnet[0].properties.delegations.properties.serviceName) {
                throw ('Required pre-existing subnet delegation is missing: ' + $expectedDelegation)
            }
            $subnets[$role] = @{id = $subnet[0].id;name = $subnet[0].name}
        }
        $state.existingNetworks+=@{
            role = $network.role
            vnetId = $network.vnetId
            rgId = $network.rgId
            location = $body.location
            subnets = $subnets
        }
    }
    foreach ($resource in @($state.resources | Where-Object managedName)) {
        $groupId = '/subscriptions/' + $resource.id.Split('/')[2] + '/resourceGroups/' + $resource.managedName.Replace('{runId}', $RunId)
        if (Invoke-Arm GET $groupId '2022-09-01' -Optional) {
            throw 'A planned managed resource group already exists.'
        }
        $state.managedGroups += @{ id = $groupId;ownerId = $resource.id;beforeAbsent = $true }
    }
    # ---
    # 3. Deploy：必要なAzureサービスを利用登録し、テスト用リソースグループを作る。
    # ---
    foreach ($subscription in $SubscriptionIds){
        $needed = @('Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.Resources') + @($state.resources | Where-Object {
                $_.id.StartsWith('/subscriptions/' + $subscription + '/')
            } | ForEach-Object {
                $_.resourceType.Split('/')[0]
        })
        foreach ($provider in @($needed | Sort-Object -Unique)){
            $id = '/subscriptions/' + $subscription + '/providers/' + $provider
            $registered = Invoke-Arm GET $id '2021-04-01'
            if ($registered.registrationState -ne 'Registered'){
                $null = Invoke-Arm POST ($id + '/register') '2021-04-01'
                $limit = [DateTimeOffset]::UtcNow.AddMinutes(90)
                do {
                    Start-Sleep -Seconds 5
                    $registered = Invoke-Arm GET $id '2021-04-01'
                    if ([DateTimeOffset]::UtcNow -ge $limit) {
                        throw ('Provider registration wait exceeded: ' + $provider)
                    }
                } while ($registered.registrationState -ne 'Registered')
            }
        }
    }
    # 利用登録を待つ間に同名のリソースグループが作られた場合も、作成前に止める。
    foreach ($bundle in $groups){
        if (Invoke-Arm GET ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' -Optional) {
            throw 'Resource-group name collided before creation.'
        }
        $null = Invoke-Arm PUT ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' @{location = $bundle.location;tags = @{fixtureRun = $RunId}}
    }
    $state.sharedStorageId = (@($state.resources | Where-Object key -EQ 'storage')[0].id ?? '')
    $networkRefs = @{}
    foreach ($network in $state.existingNetworks){
        $networkRefs[$network.role] = @{vnetId = $network.vnetId;subnets = $network.subnets}
    }
    # VM・データベース用のパスワードを作る。作業記録には保存せず、送信後に変数を空にする。
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(32)
    try {
        $random.GetBytes($bytes)
    } finally {
        $random.Dispose()
    }
    $password = 'Az9!' + [Convert]::ToBase64String($bytes)
    # 日本語のサブスクリプション名を含んでも、文字コードの違いでJSONが壊れない形で受け取る。
    $account = az account show --subscription $SubscriptionIds[0] --query 'to_string(@)' --output tsv --only-show-errors | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure account lookup failed.'
    }
    $tenantId = $account.tenantId
    # ---
    # 4. Deploy：リソースを作り、Azureの作成完了を確認する。
    # AKS用マネージドIDとサブネットの利用権限を先に用意し、その後で残りを作る。
    # ---
    # 後半にも作成済みの定義を含め、テンプレートが依存先を参照できるようにする。
    foreach ($phase in @('foundation', 'resources')){
        $tickets = @()
        foreach ($bundle in $state.plan.bundles){
            $selected = @($state.resources | Where-Object {
                    $_.bundle -eq $bundle.key -and -not $_.load -and ($phase -eq 'resources' -or $_.phase -eq 'foundation')
            })
            if (-not $selected.Count) {
                continue
            }
            $group = '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
            $deploymentId = $group + '/providers/Microsoft.Resources/deployments/fx-' + $RunId + '-' + $bundle.key.ToLowerInvariant() + '-' + $phase
            $parameters = @{
                runId = $RunId
                bundle = $bundle.key
                location = $bundle.location
                enabledKeys = @($selected.key | Sort-Object -Unique)
                networkRefs = $networkRefs
                tenantId = $tenantId
                sharedStorageId = $state.sharedStorageId
                adminPassword = $password
                adminSshPublicKey = $AdminSshPublicKey
                publisherEmail = $PublisherEmail
            }
            $parameterValues = @{}
            foreach ($name in $parameters.Keys) {
                $parameterValues[$name] = @{value = $parameters[$name]}
            }
            $state.deployments += @{id = $deploymentId;resourceIds = @($selected.id);state = 'INTENT'}
            Save-State
            $null = Invoke-Arm PUT $deploymentId '2022-09-01' @{properties = @{mode = 'Incremental';template = $Template;parameters = $parameterValues}}
            $tickets += $deploymentId
        }
        if ($phase -eq 'resources') {
            foreach ($resource in @($state.resources | Where-Object load)) {
                $null = Invoke-Arm PUT $resource.id $resource.apiVersion @{location = $resource.location;tags = @{fixtureRunId = $RunId;fixtureBundle = $resource.bundle};properties = @{securityRules = @()}}
            }
        }
        foreach ($id in $tickets){
            $deployment = Wait-Resource $id '2022-09-01'
            @($state.deployments | Where-Object id -EQ $id)[0].state = $deployment.properties.provisioningState
            Save-State
        }
        if ($phase -eq 'foundation'){
            $identity = @($state.resources | Where-Object key -EQ 'aksIdentity')
            if ($identity.Count){
                # AKSで使うマネージドIDに、A側PrivateSubnetのNetwork Contributorを割り当てる。
                # これでAKSが既存サブネットを使えるようにする。
                $principal = (Invoke-Arm GET $identity[0].id $identity[0].apiVersion).properties.principalId
                $subnet = @($state.existingNetworks | Where-Object role -EQ 'A')[0].subnets.Private.id
                $roleId = $subnet + '/providers/Microsoft.Authorization/roleAssignments/' + [Guid]::NewGuid().ToString()
                $body = @{
                    properties = @{
                        principalId = $principal
                        principalType = 'ServicePrincipal'
                        roleDefinitionId = ('/subscriptions/' + $SubscriptionIds[0] + '/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7')
                    }
                }
                $state.ownedExternalRoles+=@{id = $roleId;beforeAbsent = $true;body = $body}
                Save-State
                $null = Invoke-Arm PUT $roleId '2022-04-01' $body
            }
        }
    }
    $password = $null
    $parameters = $null
    $parameterValues = $null
    $state.status = 'DEPLOYED'
    Save-State
}

# ---
# 5. Deploy・Capture：実在するリソースのIDと、後片付けに必要な管理用グループを記録する。
# ---
if ($Action -in @('Deploy', 'Capture')) {
    foreach ($bundle in $groups) {
        $groupId = '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
        $group = Invoke-Arm GET $groupId '2022-09-01' -Optional
        if (-not $group) {
            continue
        }
        # 別の作業のグループを読み取らないよう、作成時のRunIdとタグを比べる。
        if ($group.tags.fixtureRun -cne $RunId) {
            throw ('Owned resource-group tag changed: ' + $groupId)
        }
        $actual = Invoke-Arm GET ($groupId + '/resources') '2021-04-01'
        foreach ($item in $actual.value) {
            if ($item.id -notin $state.inventory.id) {
                $state.inventory += $item
            }
        }
    }
    # Azure Monitorの管理用グループは、既定DCRのIDから読み取る。
    foreach ($resource in @($state.resources | Where-Object {
                $_.managedName -or $_.resourceType -eq 'microsoft.monitor/accounts'
    })) {
        $actual = Invoke-Arm GET $resource.id $resource.apiVersion -Optional
        if (-not $actual) {
            continue
        }
        $groupId = if ($resource.managedName) {
            '/subscriptions/' + ($resource.id.Split('/')[2]) + '/resourceGroups/' + $resource.managedName.Replace('{runId}', $RunId)
        } else {
            ($actual.properties.defaultIngestionSettings.dataCollectionRuleResourceId -split '/providers/')[0]
        }
        if (-not $groupId) {
            throw 'Managed resource-group ID was not returned.'
        }
        if ($groupId -notin $state.managedGroups.id) {
            $state.managedGroups += @{ id = $groupId; ownerId = $resource.id; beforeAbsent = $true }
        }
    }
    Save-State
}

# ---
# 6. Deploy・Capture：各リソース・子リソース・既存VNetの診断設定と、出力できるログ項目を取得する。
# 旧設定は会社ポリシーが作る。取得成功は、旧診断設定が付いていることを意味しない。
# ---
if ($Action -in @('Deploy', 'Capture')) {
    $candidates = @($state.resources)
    foreach ($network in @($state.existingNetworks | Where-Object { 'networkVnet' -in $state.plan.selectedKeys })) {
        $candidates += @{
            id = $network.vnetId
            resourceType = 'microsoft.network/virtualnetworks'
            apiVersion = '2024-05-01'
            location = $network.location
            scopeSuffixes = @()
            existing = $true
        }
    }
    $state.scopes = @()
    foreach ($resource in $candidates) {
        foreach ($suffix in @('') + @($resource.scopeSuffixes)) {
            $id = $resource.id + $suffix
            $api = if ($suffix) {
                $resource.childApiVersion
            } else {
                $resource.apiVersion
            }
            $body = Invoke-Arm GET $id $api -Optional
            $categories = if ($body) {
                Invoke-Arm GET ($id + '/providers/Microsoft.Insights/diagnosticSettingsCategories') '2021-05-01-preview' -AllowError
            }
            $settings = if ($body) {
                Invoke-Arm GET ($id + '/providers/Microsoft.Insights/diagnosticSettings') '2021-05-01-preview' -AllowError
            }
            $status = if (-not $body) {
                'UNRESOLVED'
            } elseif (@($categories.error.code, $settings.error.code) | Where-Object { $_ -in @('ResourceTypeNotSupported', 'UnsupportedResourceType', 'DiagnosticSettingsNotSupported') }) {
                'EXPECTED_UNSUPPORTED'
            } elseif ($categories.error -or $settings.error) {
                'FAILED'
            } elseif ($categories.value -isnot [array] -or $settings.value -isnot [array]) {
                'UNRESOLVED'
            } elseif (-not $categories.value.Count) {
                'NO_EXPORTABLE_CATEGORIES'
            } else {
                'READ_ONLY_CAPTURED'
            }
            $state.scopes += @{
                resourceId = $id
                parentType = $resource.resourceType
                apiVersion = $api
                exists = [bool]$body
                actualLocation = ($body.location ?? $resource.location)
                categoryResponse = $categories
                diagnosticSettings = $settings
                actualStatus = $status
                actualErrorCode = ($categories.error.code ?? $settings.error.code)
                existing = [bool]$resource.existing
            }
        }
    }
    Save-State
}
