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
# 利用者設定。2つのサブスクリプションと既存VNet ID、配置リージョンを指定する。
# VNet・サブネットの作成/更新と、NSG・ルートテーブルの関連付けはしない。
# Databricksと旧Redisは既定で省略する。
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

# ---
# ARM要求を送る。Optionalは明示404だけnull、AllowErrorはAPIのerrorオブジェクトを返す。
# GET一覧のnextLinkはここで全件取得する。
# 変更前に操作先を台帳へ記録する。要求本文や認証情報は保存しない。
# ---
function Invoke-Arm {
    param($Method, $Id, $ApiVersion, $Body = $null, [switch]$Optional, [switch]$AllowError)
    $uri = if ($Id.StartsWith('https://')){
        $Id
    }else{
        $ArmBase + $Id
    }
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
    $items = @()
    $page = $null
    $listStarted = $false
    do {
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
            TimeoutSec = 120
        }
        if ($null -ne $Body){
            $request.ContentType = 'application/json; charset=utf-8'
            $request.Body = $Utf8.GetBytes(($Body | ConvertTo-Json -Depth 100))
        }
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
    if ($operation){
        $operation.status = 'ACCEPTED'
        Save-State
    }
    if ($page -and $page.ContainsKey('value')){
        $page.value = $items
    }
    return $page
}

# ---
# 作成したIDと操作結果を一時ファイルへ保存し、完成してから台帳を置き換える。
# ---
function Save-State {
    [IO.File]::WriteAllText(($StatePath + '.pending'), ($state | ConvertTo-Json -Depth 100), $Utf8)
    Move-Item ($StatePath + '.pending') $StatePath -Force
}

# ---
# 作成完了を待つ。Failed/Canceledはその時点で止める。
# ---
function Wait-Resource {
    param($Id, $ApiVersion)
    $limit = [DateTimeOffset]::UtcNow.AddMinutes(90)
    do {
        $current = Invoke-Arm GET $Id $ApiVersion -Optional
        if ($current) {
            if ($current.properties.provisioningState -in @('Failed', 'Canceled')) {
                throw ('Provisioning failed: ' + $Id)
            }
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
# Plan: 56型から対象と依存を選び、配置先とリソースIDを組み立てる。
# 各Subで1つの専用RGを使い、4つのbundleで資源のリージョンを分ける。
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
    $networks = @()
    $bundles = @()
    $resources = @()
    for ($index = 0;$index -lt 2;$index++){
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
    $state = Get-Content $StatePath -Raw -Encoding utf8 | ConvertFrom-Json -AsHashtable
    if ($state.runId -cne $RunId -or ($state.plan.subscriptionIds -join ',') -cne ($SubscriptionIds -join ',')){
        throw 'Run/subscription identity differs from the ledger.'
    }
    if ($state.plan.scriptSha256 -cne (Get-FileHash $PSCommandPath).Hash -or $state.plan.templateSha256 -cne (Get-FileHash $TemplatePath).Hash){
        throw 'Use the exact source pair saved by this run.'
    }
}

# ---
# Deploy: 同名RGの不存在と既存サブネットを確認し、各Subの専用RGへ資源を作る。
# ---
$groups = @($state.plan.bundles | Group-Object subscriptionId | ForEach-Object { $_.Group[0] })
if ($Action -eq 'Deploy'){
    foreach ($bundle in $groups){
        if (Invoke-Arm GET ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' -Optional){
            throw 'A planned resource group already exists.'
        }
    }
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
    $random = [Security.Cryptography.RandomNumberGenerator]::Create()
    $bytes = [byte[]]::new(32)
    try {
        $random.GetBytes($bytes)
    } finally {
        $random.Dispose()
    }
    $password = 'Az9!' + [Convert]::ToBase64String($bytes)
    $account = az account show --subscription $SubscriptionIds[0] --output json --only-show-errors | ConvertFrom-Json -AsHashtable
    if ($LASTEXITCODE -ne 0) {
        throw 'Azure account lookup failed.'
    }
    $tenantId = $account.tenantId
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
# Capture: 各Subの専用RGの実在庫と、サービスが作った管理用RGのIDを記録する。
# ---
if ($Action -in @('Deploy', 'Capture')) {
    foreach ($bundle in $groups) {
        $groupId = '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
        $group = Invoke-Arm GET $groupId '2022-09-01' -Optional
        if (-not $group) {
            continue
        }
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
# Capture: 親・既知の子・既存VNetのカテゴリと現在の診断設定を読み取る。
# 旧設定の作成は既存ポリシーに任せる。カテゴリ取得成功を設定作成成功と扱わない。
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
