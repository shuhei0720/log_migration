#Requires -Version 7.0
[CmdletBinding()]
param(
    [ValidateSet('Plan', 'Deploy', 'Capture', 'Seed', 'Cleanup')][string]$Action = 'Plan',
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
# 利用者設定。2つのsubscriptionと既存VNet ID、配置regionを指定する。
# VNet・subnet・NSG・route tableの作成/更新はしない。DBRと旧Redisは既定で省略する。
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
$NewDiagnosticSettingName = 'storage-archive'
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
# QueryはlistKeys/getEntities等の読取POST。GET一覧のnextLinkはここで全件取得する。
# 変更のintentを先に保存し、本文・token・storage keyは台帳へ記録しない。
# ---
function Invoke-Arm {
    param($Method, $Id, $ApiVersion, $Body = $null, [switch]$Optional, [switch]$AllowError, [switch]$Query)
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
    if ($state -and $Action -ne 'Cleanup' -and $Method -notin @('GET', 'HEAD') -and -not $Query -and [DateTimeOffset]::UtcNow -ge ([DateTimeOffset]$state.startedUtc).AddHours($MaximumHours)) {
        throw 'Run lifetime exceeded; use Cleanup.'
    }
    if ($state -and $Method -notin @('GET', 'HEAD') -and -not $Query){
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
            Headers = @{Authorization = ('Bearer ' + $script:accessToken)}
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
# 1つの台帳をatomicに保存する。途中停止時も最初のBeforeを上書きしない。
# ---
function Save-State {
    [IO.File]::WriteAllText(($StatePath + '.pending'), ($state | ConvertTo-Json -Depth 100), $Utf8)
    Move-Item ($StatePath + '.pending') $StatePath -Force
}

# ---
# 作成完了または不存在を待つ。失敗状態はその時点で止める。
# ---
function Wait-Resource {
    param($Id, $ApiVersion, [switch]$Gone)
    $limit = [DateTimeOffset]::UtcNow.AddMinutes(90)
    do {
        $current = Invoke-Arm GET $Id $ApiVersion -Optional
        if ($Gone -and -not $current){
            return
        }
        if (-not $Gone -and $current) {
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
# GET結果から比較用コピーを作る。readonlyな参照以外の設定は残す。
# 比較のために実リソース・保存Before/Afterを変更しない。
# ---
function Get-ComparableConfig {
    param($Value, $Before = $null, [switch]$Nested)
    if ($Nested) {
        if ($Value -is [Collections.IDictionary]) {
            $ordered = [ordered]@{}
            foreach ($key in @($Value.Keys | Sort-Object -CaseSensitive)) {
                $ordered[$key] = Get-ComparableConfig $Value[$key] -Nested
            }
            return $ordered
        }
        if ($Value -is [array]) {
            return , @(foreach ($item in $Value) {
                    Get-ComparableConfig $item -Nested
            })
        }
        return $Value
    }
    $copy = $Value | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
    foreach ($entry in @($copy) + @($copy.properties.subnets) + @($copy.properties.subnets.properties.delegations)){
        if ($entry){
            $entry.Remove('etag')
            $entry.Remove('systemData')
            if ($entry.properties){
                $entry.properties.Remove('provisioningState')
            }
        }
    }
    if ($copy.type -ieq 'Microsoft.Network/virtualNetworks'){
        foreach ($subnet in @($copy.properties.subnets)){
            if ($Before) {
                $original = @($Before.properties.subnets | Where-Object id -EQ $subnet.id)[0]
                $originalLinks = @($original.properties.applicationGatewayIPConfigurations)
                $keptLinks = @()
                foreach ($link in @($subnet.properties.applicationGatewayIPConfigurations)) {
                    if (-not $link) {
                        continue
                    }
                    if ($link.id -in $originalLinks.id) {
                        $keptLinks += $link
                        continue
                    }
                    if (@($link.Keys | Where-Object { $_ -ne 'id' }).Count) {
                        throw 'Unknown field in new AppGW subnet reference.'
                    }
                    $owner = @($state.resources | Where-Object {
                            $_.resourceType -eq 'microsoft.network/applicationgateways' -and $link.id.StartsWith($_.id + '/gatewayIPConfigurations/', [StringComparison]::OrdinalIgnoreCase)
                    })
                    if ($owner.Count -ne 1 -or $owner[0].id -in $state.initialState.resourceIds) {
                        throw 'Unowned AppGW subnet reference.'
                    }
                    $actual = Invoke-Arm GET $owner[0].id $owner[0].apiVersion
                    $reverse = @($actual.properties.gatewayIPConfigurations | Where-Object id -EQ $link.id)
                    if ($actual.tags.fixtureRunId -cne $RunId -or $actual.properties.provisioningState -ne 'Succeeded' -or $reverse.Count -ne 1 -or $reverse[0].properties.subnet.id -ine $subnet.id) {
                        throw 'AppGW reverse subnet reference differs.'
                    }
                }
                if ($original.properties.ContainsKey('applicationGatewayIPConfigurations')) {
                    $subnet.properties.applicationGatewayIPConfigurations = $keptLinks
                }
                else {
                    $subnet.properties.Remove('applicationGatewayIPConfigurations')
                }
            }
            foreach ($name in @('ipConfigurations', 'ipConfigurationProfiles', 'privateEndpoints', 'serviceAssociationLinks', 'resourceNavigationLinks', 'purpose')){
                $subnet.properties.Remove($name)
            }
        }
    }
    $ownedFirewalls = @($state.resources | Where-Object {
            $_.external -and $_.resourceType -eq 'microsoft.network/azurefirewalls'
        } | ForEach-Object id)
    if ($copy.type -ieq 'Microsoft.Network/publicIPAddresses'){
        $link = $copy.properties.ipConfiguration.id
        if ($link -and @($ownedFirewalls | Where-Object {
                    $link.StartsWith($_ + '/', [StringComparison]::OrdinalIgnoreCase)
            }).Count -ne 1) {
            throw 'PIP has an unowned attachment.'
        }
        $copy.properties.Remove('ipConfiguration')
    }
    if ($copy.type -ieq 'Microsoft.Network/firewallPolicies'){
        if (@($copy.properties.firewalls | Where-Object {
                    $_.id -notin $ownedFirewalls
            }).Count) {
            throw 'Policy is shared with an unowned firewall.'
        }
        $copy.properties.Remove('firewalls')
    }
    return ((Get-ComparableConfig $copy -Nested) | ConvertTo-Json -Depth 100 -Compress)
}

# ---
# Blob RESTをShared Keyで呼ぶ。account名と鍵は対象accountの処理中だけ設定する。
# GET/HEAD/DELETE専用。AllowNotFoundは明示的404だけを値なしにする。
# ---
function Invoke-Blob {
    param(
        [ValidateSet('GET','HEAD','DELETE')][string]$Method,
        [string]$Container,
        [string]$Blob='',
        [hashtable]$Query=@{},
        [hashtable]$Headers=@{},
        [switch]$AllowNotFound
    )
    $Method=$Method.ToUpperInvariant()
    if($script:BlobAccountName -cnotmatch '^[a-z0-9]{3,24}$'){
        throw 'Storage account name is invalid.'
    }
    $parts=@($Container)+@($Blob -split '/')
    if($parts -contains '.' -or $parts -contains '..'){
        throw 'Dot path segments cannot be sent without URI normalization.'
    }
    $path='/'+[Uri]::EscapeDataString($Container)
    if($Blob){
        $path+='/'+(@($Blob -split '/' | ForEach-Object {[Uri]::EscapeDataString($_)}) -join '/')
    }
    $names=[string[]]@($Query.Keys | ForEach-Object {$_.ToLowerInvariant()})
    [array]::Sort($names,[StringComparer]::Ordinal)
    $queryParts=@()
    $resource='/'+$script:BlobAccountName+$path
    foreach($name in $names){
        $values=[string[]]@($Query[$name])
        [array]::Sort($values,[StringComparer]::Ordinal)
        foreach($value in $values){
            $queryParts+=([Uri]::EscapeDataString($name)+'='+[Uri]::EscapeDataString($value))
        }
        $resource+="`n${name}:"+($values -join ',')
    }
    $headers=$Headers.Clone()
    $headers['x-ms-date']=[DateTime]::UtcNow.ToString('R',[Globalization.CultureInfo]::InvariantCulture)
    $headers['x-ms-version']='2023-11-03'
    $headerNames=[string[]]@($headers.Keys | Where-Object {$_ -like 'x-ms-*'} | ForEach-Object {$_.ToLowerInvariant()})
    [array]::Sort($headerNames,[StringComparer]::Ordinal)
    $canonicalHeaders=(@($headerNames | ForEach-Object {
        $_+':'+([string]$headers[$_] -replace '\s+',' ').Trim()+"`n"
    }) -join '')
    # 0-byteのContent-LengthとDateは空欄。Dateの代わりにx-ms-dateを署名する。
    $standard=@($Method,'','','','','','',$headers['If-Modified-Since'],$headers['If-Match'],
        $headers['If-None-Match'],$headers['If-Unmodified-Since'],$headers['Range'])
    $hmac=[Security.Cryptography.HMACSHA256]::new([Convert]::FromBase64String($script:BlobAccountKey))
    try{
        $signature=[Convert]::ToBase64String($hmac.ComputeHash(
            [Text.Encoding]::UTF8.GetBytes(($standard -join "`n")+"`n"+$canonicalHeaders+$resource)
        ))
    }finally{
        $hmac.Dispose()
    }
    $headers.Authorization='SharedKey '+$script:BlobAccountName+':'+$signature
    $uri='https://'+$script:BlobAccountName+'.blob.core.windows.net'+$path
    if($queryParts.Count){
        $uri+='?'+($queryParts -join '&')
    }
    $response=Invoke-WebRequest -Uri $uri -Method $Method -Headers $headers -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 30
    if($AllowNotFound -and [int]$response.StatusCode -eq 404 -and
        ([string]$response.Headers['x-ms-error-code']) -in @('BlobNotFound','ResourceNotFound')){
        return $null
    }
    if([int]$response.StatusCode -lt 200 -or [int]$response.StatusCode -ge 300){
        throw ('Blob REST failed: '+[int]$response.StatusCode+'/'+[string]$response.Headers['x-ms-error-code'])
    }
    return $response
}


# ---
# Plan: 56型から対象と依存を選び、exact IDと配置先を一度だけ組み立てる。
# Firewall3rootはVNet BのRGへ、他は新規専用RGへ配置する。
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
            resourceGroup = ('fx-' + $RunId + '-' + $bundleKey.ToLowerInvariant())
        }
    }
    foreach ($resource in $Template.resources){
        $meta = $resource.metadata.fixture
        if ($meta.key -notin $keys){
            continue
        }
        $bundle = @($bundles | Where-Object key -EQ $meta.bundle)[0]
        $group = '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
        if ($meta.deploymentNetworkRole){
            $group = @($networks | Where-Object role -EQ $meta.deploymentNetworkRole)[0].rgId
        }
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
            role = $meta.role
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
            seedSourceDiagnostic = ($meta.seedSourceDiagnostic -ne $false)
            external = [bool]$meta.deploymentNetworkRole
            cleanupOrder = ($meta.cleanupOrder ?? 0)
            managedName = $meta.managedResourceGroupNameTemplate
            cleanupEarly = [bool]$meta.cleanupEarly
        }
    }
    foreach ($family in $resources | Group-Object {
            $_.bundle + '|' + $_.key
    }){
        if (@($family.Group | ForEach-Object {
                    ($_.id -split '/providers/')[0]
                } | Sort-Object -Unique).Count -ne 1){
            throw 'One key cannot mix deployment resource groups.'
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
            seedSourceDiagnostic = $true
            external = $false
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
        throw 'Run ledger already exists. Use Capture/Cleanup or another RunId.'
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
        status = 'CAPTURING'
        plan = $plan
        resources = $resources
        initialState = @()
        subscriptionParents = @()
        existingNetworks = @()
        operations = @()
        deployments = @()
        inventory = @()
        managedGroups = @()
        ownedExternalResources = @()
        ownedExternalRoles = @()
        sourceSettings = @()
        scopes = @()
        collectorAssociations = @()
        cleanup = @()
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
# Deploy: 初期状態と同名不存在を先に記録し、MG→専用RG→共有基盤→各資源の順で作る。
# ---
if ($Action -eq 'Deploy'){
    $entities = Invoke-Arm POST '/providers/Microsoft.Management/getEntities' '2020-05-01' -Query
    foreach ($subscription in $SubscriptionIds){
        $parent = @($entities.value | Where-Object {
                $_.name -eq $subscription -or $_.id -eq ('/subscriptions/' + $subscription)
        })[0].properties.parent.id
        if (-not $parent){
            throw 'Original management-group parent was not returned.'
        }
        $state.subscriptionParents+=@{subscriptionId = $subscription;parentId = $parent}
        $currentResources = Invoke-Arm GET ('/subscriptions/' + $subscription + '/resources') '2021-04-01'
        $currentGroups = Invoke-Arm GET ('/subscriptions/' + $subscription + '/resourceGroups') '2022-09-01'
        $providers = Invoke-Arm GET ('/subscriptions/' + $subscription + '/providers') '2021-04-01'
        $state.initialState+=@{
            subscriptionId = $subscription
            resourceIds = @($currentResources.value.id)
            groupIds = @($currentGroups.value.id)
            roleIds = @((Invoke-Arm GET ('/subscriptions/' + $subscription + '/providers/Microsoft.Authorization/roleAssignments') '2022-04-01').value.id)
            assignmentIds = @((Invoke-Arm GET ('/subscriptions/' + $subscription + '/providers/Microsoft.Authorization/policyAssignments') '2022-06-01').value.id)
            exemptionIds = @((Invoke-Arm GET ('/subscriptions/' + $subscription + '/providers/Microsoft.Authorization/policyExemptions') '2022-07-01-preview').value.id)
            providers = @($providers.value | ForEach-Object {
                    @{namespace = $_.namespace;registrationState = $_.registrationState}
            })
        }
    }
    foreach ($bundle in $state.plan.bundles){
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
        $diagnostics = Invoke-Arm GET ($network.vnetId + '/providers/Microsoft.Insights/diagnosticSettings') '2021-05-01-preview'
        if (-not $diagnostics -or -not $diagnostics.ContainsKey('value') -or $diagnostics.value -isnot [array]) {
            throw 'Existing VNet diagnostic settings did not return a value array.'
        }
        $state.existingNetworks+=@{
            role = $network.role
            vnetId = $network.vnetId
            rgId = $network.rgId
            networkBefore = $body
            configuration = (Get-ComparableConfig $body)
            subnets = $subnets
            diagnosticsBefore = @{ supported = $true; body = $diagnostics }
        }
    }
    foreach ($root in @($state.resources | Where-Object external)){
        if (Invoke-Arm GET $root.id $root.apiVersion -Optional){
            throw ('Existing external root: ' + $root.id)
        }
        $state.ownedExternalResources+=@{
            id = $root.id
            apiVersion = $root.apiVersion
            cleanupOrder = $root.cleanupOrder
            beforeAbsent = $true
            intent = $false
            after = $null
        }
    }
    foreach ($resource in @($state.resources | Where-Object managedName)) {
        $groupId = '/subscriptions/' + $resource.id.Split('/')[2] + '/resourceGroups/' + $resource.managedName.Replace('{runId}', $RunId)
        if ($groupId -in $state.initialState.groupIds) {
            throw 'A planned managed resource group already exists.'
        }
        $state.managedGroups += @{ id = $groupId;ownerId = $resource.id;beforeAbsent = $true }
    }
    $external = @($state.resources | Where-Object external)
    if ($external.Count) {
        $state.externalDeploymentId = ($external[0].id -split '/providers/')[0] + '/providers/Microsoft.Resources/deployments/fx-' + $RunId + '-resources-network-b'
        if (Invoke-Arm GET $state.externalDeploymentId '2022-09-01' -Optional) {
            throw 'The external deployment name already exists.'
        }
    }
    $state.managementGroupId = '/providers/Microsoft.Management/managementGroups/fx-' + $RunId
    if (Invoke-Arm GET $state.managementGroupId '2020-05-01' -Optional){
        throw 'The run management group already exists.'
    }
    $state.initialCaptureComplete = $true
    Save-State
    foreach ($initial in $state.initialState){
        $needed = @('Microsoft.Insights', 'Microsoft.OperationalInsights', 'Microsoft.Resources') + @($state.resources | Where-Object {
                $_.id.StartsWith('/subscriptions/' + $initial.subscriptionId + '/')
            } | ForEach-Object {
                $_.resourceType.Split('/')[0]
        })
        foreach ($provider in @($needed | Sort-Object -Unique)){
            $id = '/subscriptions/' + $initial.subscriptionId + '/providers/' + $provider
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
    if (Invoke-Arm GET $state.managementGroupId '2020-05-01' -Optional) {
        throw 'Management-group name collided before creation.'
    }
    $null = Invoke-Arm PUT $state.managementGroupId '2020-05-01' @{properties = @{displayName = ('Fixture ' + $RunId);details = @{parent = @{id = $state.subscriptionParents[0].parentId}}}}
    $null = Wait-Resource $state.managementGroupId '2020-05-01'
    foreach ($subscription in $SubscriptionIds) {
        $limit = [DateTimeOffset]::UtcNow.AddMinutes(5)
        do {
            $moved = Invoke-Arm PUT ($state.managementGroupId + '/subscriptions/' + $subscription) '2020-05-01' -AllowError
            if (-not $moved.error) {
                break
            }
            if ($moved.error.code -notin @('ManagementGroupNotFound', 'ResourceNotFound', 'NotFound') -or [DateTimeOffset]::UtcNow -ge $limit) {
                throw ('Subscription move failed: ' + $moved.error.code)
            }
            Start-Sleep -Seconds 5
        } while ($true)
    }
    $definition = $state.managementGroupId + '/providers/Microsoft.Authorization/policyDefinitions/fx-audit'
    $initiative = $state.managementGroupId + '/providers/Microsoft.Authorization/policySetDefinitions/fx-initiative'
    $null = Invoke-Arm PUT $definition '2023-04-01' @{properties = @{policyType = 'Custom';mode = 'All';policyRule = @{if = @{field = 'type';equals = 'Microsoft.Storage/storageAccounts'};then = @{effect = 'audit'}}}}
    $references = @($Template.metadata.policyReferenceIds | ForEach-Object {
            @{policyDefinitionId = $definition;policyDefinitionReferenceId = $_}
    })
    $null = Invoke-Arm PUT $initiative '2023-04-01' @{properties = @{policyType = 'Custom';policyDefinitions = $references}}
    $state.policyAssignmentIds = @()
    foreach ($name in $Template.metadata.policyAssignmentNames){
        $id = $state.managementGroupId + '/providers/Microsoft.Authorization/policyAssignments/' + $name
        $null = Invoke-Arm PUT $id '2022-06-01' @{properties = @{policyDefinitionId = $(if ($state.policyAssignmentIds.Count -eq 2){
                        $initiative
                    }else{
                        $definition
                });enforcementMode = 'DoNotEnforce'}}
        $state.policyAssignmentIds+=, $id
        Save-State
    }
    # 新しいVNetを作るサービスを拒否する。元からあるVNetの設定は変更しない。
    $guard = $state.managementGroupId + '/providers/Microsoft.Authorization/policyDefinitions/fx-no-new-vnet'
    $vnetIds = @($state.initialState.resourceIds | Where-Object {
            $_ -match '/providers/Microsoft.Network/virtualNetworks/[^/]+$'
    })
    $null = Invoke-Arm PUT $guard '2023-04-01' @{
        properties = @{
            policyType = 'Custom'
            mode = 'All'
            policyRule = @{if = @{allOf = @(@{field = 'type';equals = 'Microsoft.Network/virtualNetworks'}, @{field = 'id';notIn = $vnetIds})};then = @{effect = 'deny'}}
        }
    }
    $null = Invoke-Arm PUT ($state.managementGroupId + '/providers/Microsoft.Authorization/policyAssignments/fx-no-new-vnet') '2022-06-01' @{properties = @{policyDefinitionId = $guard;enforcementMode = 'Default'}}
    foreach ($subscription in $SubscriptionIds) {
        $limit = [DateTimeOffset]::UtcNow.AddMinutes(5)
        do {
            $assignments = Invoke-Arm GET ('/subscriptions/' + $subscription + '/providers/Microsoft.Authorization/policyAssignments?$filter=atScope()') '2022-06-01'
            $missing = @($state.policyAssignmentIds + @($state.managementGroupId + '/providers/Microsoft.Authorization/policyAssignments/fx-no-new-vnet') | Where-Object {
                    $_ -notin $assignments.value.id
            })
            if (-not $missing.Count) {
                break
            }
            if ([DateTimeOffset]::UtcNow -ge $limit) {
                throw 'Subscription policy-assignment propagation wait exceeded.'
            }
            Start-Sleep -Seconds 5
        } while ($true)
    }
    foreach ($bundle in $state.plan.bundles){
        if (Invoke-Arm GET ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' -Optional) {
            throw 'Resource-group name collided before creation.'
        }
        $null = Invoke-Arm PUT ('/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup) '2022-09-01' @{location = $bundle.location;tags = @{fixtureRun = $RunId}}
    }
    $state.sourceWorkspaceId = @($state.resources | Where-Object role -EQ 'source-workspace')[0].id
    $state.auxWorkspaceId = @($state.resources | Where-Object role -EQ 'untargeted-aux-workspace')[0].id
    $state.sharedStorageId = @($state.resources | Where-Object key -EQ 'storage')[0].id
    $state.oldDcrIds = @($state.resources | Where-Object {
            $_.role -in @('old-dcr-1', 'old-dcr-2')
        } | ForEach-Object id)
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
            foreach ($external in @($false, $true)){
                $rows = @($selected | Where-Object external -EQ $external)
                if (-not $rows.Count){
                    continue
                }
                $group = if ($external){
                    ($rows[0].id -split '/providers/')[0]
                }else{
                    '/subscriptions/' + $bundle.subscriptionId + '/resourceGroups/' + $bundle.resourceGroup
                }
                $deploymentId = $group + '/providers/Microsoft.Resources/deployments/fx-' + $RunId + '-' + $phase + $(if ($external){
                        '-network-b'
                })
                if ($external){
                    if (Invoke-Arm GET $deploymentId '2022-09-01' -Optional){
                        throw 'Existing external deployment name.'
                    }
                    foreach ($root in $state.ownedExternalResources){
                        $root.intent = $true
                    }
                    Save-State
                }
                $parameters = @{
                    runId = $RunId
                    bundle = $bundle.key
                    location = $bundle.location
                    enabledKeys = @($rows.key | Sort-Object -Unique)
                    networkRefs = $networkRefs
                    tenantId = $tenantId
                    sourceWorkspaceId = $state.sourceWorkspaceId
                    sharedStorageId = $state.sharedStorageId
                    adminPassword = $password
                    adminSshPublicKey = $AdminSshPublicKey
                    publisherEmail = $PublisherEmail
                }
                $parameterValues = @{}
                foreach ($name in $parameters.Keys){
                    $parameterValues[$name] = @{value = $parameters[$name]}
                }
                $state.deployments+=@{id = $deploymentId;external = $external;resourceIds = @($rows.id);state = 'INTENT'}
                Save-State
                $null = Invoke-Arm PUT $deploymentId '2022-09-01' @{properties = @{mode = 'Incremental';template = $Template;parameters = $parameterValues}}
                $tickets+=, $deploymentId
            }
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
            $identity = @($state.resources | Where-Object role -EQ 'aks-subnet-identity')
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
# Capture: 新規専用RGの実在庫と、既存RG内の所有3rootだけを回収する。
# providerが作ったmanaged RGも、元不存在かつ所有rootの管理先だけを対象にする。
# ---
if ($Action -in @('Deploy', 'Capture', 'Seed', 'Cleanup') -and -not $state.resourceCleanupComplete) {
    foreach ($bundle in $state.plan.bundles) {
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
    foreach ($record in $state.ownedExternalResources) {
        $actual = Invoke-Arm GET $record.id $record.apiVersion -Optional
        if (-not $actual) {
            continue
        }
        if (-not $record.beforeAbsent -or -not $record.intent -or $actual.tags.fixtureRunId -cne $RunId -or $actual.id -ine $record.id) {
            throw 'External root ownership is unproven.'
        }
        $configuration = Get-ComparableConfig $actual
        if ($record.after -and $record.after -cne $configuration) {
            throw ('External root changed after its first After: ' + $record.id)
        }
        if (-not $record.after) {
            $operations = Invoke-Arm GET ($state.externalDeploymentId + '/operations') '2022-09-01'
            if ($record.id -notin $operations.value.properties.targetResource.id) {
                throw 'External resource is absent from its deployment operations.'
            }
            $record.after = $configuration
        }
        if ($actual.id -notin $state.inventory.id) {
            $state.inventory += $actual
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
        if (-not $groupId -or $groupId -in $state.initialState.groupIds) {
            throw 'Managed resource-group ownership is unproven.'
        }
        if ($groupId -notin $state.managedGroups.id) {
            $state.managedGroups += @{ id = $groupId; ownerId = $resource.id; beforeAbsent = $true }
        }
    }
    Save-State
}

# ---
# Capture/Seed: 親・既知の子・既存VNetを別scopeで調査する。
# Category取得成功を送信設定成功と扱わず、Seed後の最初のGET結果は保持する。
# ---
if ($Action -in @('Deploy', 'Capture', 'Seed')) {
    $candidates = @($state.resources)
    foreach ($network in @($state.existingNetworks | Where-Object { 'networkVnet' -in $state.plan.selectedKeys })) {
        $candidates += @{
            id = $network.vnetId
            resourceType = 'microsoft.network/virtualnetworks'
            apiVersion = '2024-05-01'
            location = $network.networkBefore.location
            scopeSuffixes = @()
            seedSourceDiagnostic = $true
            existing = $true
        }
    }
    foreach ($resource in $candidates) {
        foreach ($suffix in @('') + @($resource.scopeSuffixes)) {
            $id = $resource.id + $suffix
            $previous = @($state.scopes | Where-Object resourceId -EQ $id)[0]
            if ($previous.sourceSeeded) {
                continue
            }
            if ($previous) {
                $state.scopes = @($state.scopes | Where-Object resourceId -NE $id)
            }
            $api = if ($suffix) {
                $resource.childApiVersion
            } else {
                $resource.apiVersion
            }
            $body = Invoke-Arm GET $id $api -Optional
            $categories = if ($body) {
                Invoke-Arm GET ($id + '/providers/Microsoft.Insights/diagnosticSettingsCategories') '2021-05-01-preview' -AllowError
            }
            $status = if (-not $body) {
                'UNRESOLVED'
            } elseif ($categories.error.code -in @('ResourceTypeNotSupported', 'UnsupportedResourceType', 'DiagnosticSettingsNotSupported')) {
                'EXPECTED_UNSUPPORTED'
            } elseif ($categories.error) {
                'FAILED'
            } elseif (-not $categories.value.Count) {
                'UNRESOLVED'
            } else {
                'CATEGORIES_ONLY'
            }
            if (-not $resource.seedSourceDiagnostic) {
                $status = 'UNTARGETED_OLD_ONLY_COLLECTOR'
            }
            $state.scopes += @{
                resourceId = $id
                parentType = $resource.resourceType
                apiVersion = $api
                exists = [bool]$body
                actualLocation = ($body.location ?? $resource.location)
                categoryResponse = $categories
                actualStatus = $status
                actualErrorCode = $categories.error.code
                seedSourceDiagnostic = $resource.seedSourceDiagnostic
                sourceSeeded = $false
                sourceBefore = $null
                existing = [bool]$resource.existing
            }
        }
    }
    Save-State
}

# ---
# Seed: 実categoryから元の診断設定を作り、PUT直後のGETで照合する。
# 同名の未所有設定は上書きしない。VM/VMSSは診断設定の有無に関係なく旧2DCRへ関連付ける。
# ---
if ($Action -eq 'Seed') {
    $index = 0
    foreach ($scope in $state.scopes) {
        $index++
        if (-not $scope.seedSourceDiagnostic -or $scope.actualStatus -eq 'EXPECTED_UNSUPPORTED' -or -not $scope.exists) {
            continue
        }
        $id = $scope.resourceId + '/providers/Microsoft.Insights/diagnosticSettings/fx-source-' + $RunId
        $record = @($state.sourceSettings | Where-Object id -EQ $id)[0]
        # 保存済みの送信設定を再利用し、一覧の順番が変わっても同じ値で照合する。
        $body = $record.requestedBody
        if (-not $body -and $record.after) {
            $body = @{ properties = $record.after.properties }
        }
        if (-not $body) {
            $logs = @()
            $metrics = @()
            foreach ($category in $scope.categoryResponse.value) {
                $setting = @{ category = $category.name; enabled = $true }
                if ($category.properties.categoryType -eq 'Logs') {
                    $logs += $setting
                }
                if ($category.properties.categoryType -eq 'Metrics') {
                    $metrics += $setting
                }
            }
            if (-not ($logs.Count + $metrics.Count)) {
                continue
            }
            if ($logs.Count -gt 1 -and $index % 3 -eq 1) {
                $logs[-1].enabled = $false
            }
            if ($logs.Count -and $index % 5 -eq 1) {
                $metrics = @()
            } elseif ($metrics.Count -and $index % 5 -eq 2) {
                $logs = @()
            }
            # 代表NSGだけログ群を使い、他scopeでは個別categoryの変種も残す。
            if ($scope.parentType -eq 'microsoft.network/networksecuritygroups' -and $scope.resourceId -like '*-nsg' -and
                'allLogs' -in $scope.categoryResponse.value.properties.categoryGroups) {
                $logs = @(@{ categoryGroup = 'allLogs'; enabled = $true })
            }
            $body = @{ properties = @{ workspaceId = $state.sourceWorkspaceId; logs = $logs; metrics = $metrics } }
        }
        $logs = $body.properties.logs
        $metrics = $body.properties.metrics
        $current = Invoke-Arm GET $id '2021-05-01-preview' -Optional -AllowError
        if ($current.error) {
            $scope.actualStatus = if ($current.error.code -in @('ResourceTypeNotSupported','UnsupportedResourceType','DiagnosticSettingsNotSupported')) {
                'EXPECTED_UNSUPPORTED'
            } else {
                'FAILED'
            }
            $scope.actualErrorCode = $current.error.code
            Save-State
            continue
        }
        if (-not $record) {
            if ($current) {
                throw ('Unowned diagnostic name collision: ' + $id)
            }
            $record = @{
                id = $id
                apiVersion = '2021-05-01-preview'
                kind = 'Diagnostic'
                beforeAbsent = $true
                requestedBody = ($body | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)
                after = $null
            }
            $state.sourceSettings += $record
            Save-State
        }
        if ($record.after -and $current -and (Get-ComparableConfig $current) -cne (Get-ComparableConfig $record.after)) {
            throw 'Seeded source configuration changed; the first After is preserved.'
        }
        if (-not $current) {
            $result = Invoke-Arm PUT $id '2021-05-01-preview' $body -AllowError
            if ($result.error) {
                $scope.actualStatus = if ($result.error.code -in @('ResourceTypeNotSupported', 'UnsupportedResourceType', 'DiagnosticSettingsNotSupported')) {
                    'EXPECTED_UNSUPPORTED'
                } else {
                    'FAILED'
                }
                $scope.actualErrorCode = $result.error.code
                Save-State
                continue
            }
            $current = Invoke-Arm GET $id '2021-05-01-preview'
        }
        # Azureが補完したdisabled項目は許容し、実際に有効な全項目とworkspaceを照合する。
        $wanted = @(
            $logs | Where-Object enabled -EQ $true | ForEach-Object {
                'L:' + $(if ($_.categoryGroup) {
                    'Group:' + $_.categoryGroup
                } else {
                    'Category:' + $_.category
                })
            }
            $metrics | Where-Object enabled -EQ $true | ForEach-Object { 'M:' + $_.category }
        )
        $observed = @(
            $current.properties.logs | Where-Object enabled -EQ $true | ForEach-Object {
                'L:' + $(if ($_.categoryGroup) {
                    'Group:' + $_.categoryGroup
                } else {
                    'Category:' + $_.category
                })
            }
            $current.properties.metrics | Where-Object enabled -EQ $true | ForEach-Object { 'M:' + $_.category }
        )
        if ($current.properties.workspaceId -ine $state.sourceWorkspaceId -or (($wanted | Sort-Object) -join '|') -cne (($observed | Sort-Object) -join '|')) {
            throw 'Source diagnostic PUT/GET differs.'
        }
        $record.after ??= $current
        $scope.sourceBefore ??= $current
        $scope.sourceSeeded = $true
        $scope.actualStatus = 'POSITIVE_SEEDED'
        Save-State
    }
    $dcrs = @($state.resources | Where-Object {
            $_.role -in @('old-dcr-1', 'old-dcr-2', 'untargeted-sentinel-dcr')
    })
    foreach ($collector in @($state.resources | Where-Object {
                $_.resourceType -in @('microsoft.compute/virtualmachines', 'microsoft.compute/virtualmachinescalesets')
    })) {
        foreach ($dcr in $dcrs) {
            $id = $collector.id + '/providers/Microsoft.Insights/dataCollectionRuleAssociations/fx-' + $dcr.role
            $body = @{ properties = @{ dataCollectionRuleId = $dcr.id } }
            $record = @($state.sourceSettings | Where-Object id -EQ $id)[0]
            $current = Invoke-Arm GET $id '2024-03-11' -Optional
            if (-not $record) {
                if ($current) {
                    throw 'Unowned DCR association name collision.'
                }
                $record = @{
                    id = $id
                    apiVersion = '2024-03-11'
                    kind = 'Association'
                    beforeAbsent = $true
                    after = $null
                }
                $state.sourceSettings += $record
                Save-State
            }
            if (-not $current) {
                $null = Invoke-Arm PUT $id '2024-03-11' $body
                $current = Invoke-Arm GET $id '2024-03-11'
            }
            if ($current.properties.dataCollectionRuleId -ine $dcr.id) {
                throw 'DCR association PUT/GET differs.'
            }
            $record.after ??= $current
            if ($id -notin $state.collectorAssociations.id) {
                $state.collectorAssociations += @{
                    id = $id
                    collectorId = $collector.id
                    dcrId = $dcr.id
                    role = $dcr.role
                    status = 'PUT_GET_SUCCEEDED'
                }
            }
            Save-State
        }
    }
    # 対象外設定の不変確認用に、所有scopeへ別workspace宛の診断設定を1つ置く。
    $representative = @($state.scopes | Where-Object { $_.sourceSeeded -and -not $_.existing })[0]
    if ($representative) {
        $id = $representative.resourceId + '/providers/Microsoft.Insights/diagnosticSettings/fx-untargeted-' + $RunId
        $record = @($state.sourceSettings | Where-Object id -EQ $id)[0]
        $current = Invoke-Arm GET $id '2021-05-01-preview' -Optional
        if (-not $record) {
            if ($current) {
                throw 'Unowned auxiliary diagnostic name collision.'
            }
            $record = @{ id=$id;apiVersion='2021-05-01-preview';kind='Diagnostic';beforeAbsent=$true;after=$null }
            $state.sourceSettings += $record
            Save-State
        }
        if (-not $current) {
            $body = @{ properties=@{workspaceId=$state.auxWorkspaceId;logs=$representative.sourceBefore.properties.logs;metrics=$representative.sourceBefore.properties.metrics} }
            $null = Invoke-Arm PUT $id '2021-05-01-preview' $body
            $current = Invoke-Arm GET $id '2021-05-01-preview'
        }
        if ($current.properties.workspaceId -ine $state.auxWorkspaceId -or ($record.after -and (Get-ComparableConfig $record.after) -cne (Get-ComparableConfig $current))) {
            throw 'Auxiliary diagnostic readback differs.'
        }
        $record.after ??= $current
        $current | ConvertTo-Json -Depth 100 | Set-Content (Join-Path $RunPath 'untargeted-diagnostic-baseline.json') -Encoding utf8
        Save-State
    }
    $positive = @($state.scopes | Where-Object sourceSeeded)
    @($positive.resourceId) | ConvertTo-Json -AsArray | Set-Content (Join-Path $RunPath 'positive-expected-scopes.json') -Encoding utf8
    @($positive.resourceId) | ConvertTo-Json -AsArray | Set-Content (Join-Path $RunPath 'source-diag-put-success-scopes.json') -Encoding utf8
    $state.scopes | ConvertTo-Json -Depth 100 -AsArray | Set-Content (Join-Path $RunPath 'scope-capabilities.json') -Encoding utf8
    $unresolved = @($state.scopes | Where-Object { $_.actualStatus -in @('FAILED', 'UNRESOLVED') })
    if ($unresolved.Count) {
        throw ('Source settings remain unresolved: ' + ($unresolved.resourceId -join ', '))
    }
    $state.status = 'SEEDED'
    Save-State
}

# ---
# Cleanup: 非同期deploymentを先に止め、送信設定を外してから所有資源を撤去する。
# 新規4RGは丸ごと所有、既存VNet RGは記録した3rootだけを削除する。
# ---
if ($Action -eq 'Cleanup' -and -not $state.resourceCleanupComplete) {
    if (-not $state.initialCaptureComplete) {
        throw 'Initial snapshot is incomplete; no automatic cleanup writes are safe.'
    }
    foreach ($deployment in $state.deployments) {
        $current = Invoke-Arm GET $deployment.id '2022-09-01' -Optional
        if ($current -and $current.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled')) {
            $null = Invoke-Arm POST ($deployment.id + '/cancel') '2022-09-01'
            $limit = [DateTimeOffset]::UtcNow.AddMinutes(20)
            do {
                Start-Sleep -Seconds 5
                $current = Invoke-Arm GET $deployment.id '2022-09-01'
                if ([DateTimeOffset]::UtcNow -ge $limit) {
                    throw 'Deployment cancellation is still pending; roots have not been deleted.'
                }
            } while ($current.properties.provisioningState -notin @('Succeeded', 'Failed', 'Canceled'))
        }
    }
    # 既存VNetは元の設定を保持。既知のSourceと、所有保存先へ送る指定名だけを外す。
    foreach ($network in $state.existingNetworks) {
        $current = Invoke-Arm GET ($network.vnetId + '/providers/Microsoft.Insights/diagnosticSettings') '2021-05-01-preview'
        if (-not $current -or -not $current.ContainsKey('value') -or $current.value -isnot [array]) {
            throw 'Existing VNet diagnostic settings did not return a value array.'
        }
        foreach ($setting in $current.value) {
            if ($setting.id -in $network.diagnosticsBefore.body.value.id) {
                continue
            }
            $source = @($state.sourceSettings | Where-Object id -EQ $setting.id)[0]
            $destination = $setting.properties.storageAccountId ?? $setting.properties.workspaceId
            $ownedDestination = @($state.plan.bundles | Where-Object {
                    $destination -like ('/subscriptions/' + $_.subscriptionId + '/resourceGroups/' + $_.resourceGroup + '/*')
            })
            if (-not $source -and ($setting.name -cne $NewDiagnosticSettingName -or $ownedDestination.Count -ne 1)) {
                throw 'Unknown new diagnostic on an existing VNet; restore it with the migration rollback first.'
            }
            $null = Invoke-Arm DELETE $setting.id '2021-05-01-preview' -Optional
        }
    }
    $scopeIds = @($state.inventory.id) + @($state.scopes | Where-Object {
            -not $_.existing
        } | ForEach-Object resourceId)
    foreach ($scopeId in @($scopeIds | Sort-Object -Unique)) {
        $settings = Invoke-Arm GET ($scopeId + '/providers/Microsoft.Insights/diagnosticSettings') '2021-05-01-preview' -AllowError
        if ($settings.error -and $settings.error.code -notin @('ResourceNotFound', 'ResourceGroupNotFound', 'NotFound', 'ResourceTypeNotSupported', 'UnsupportedResourceType', 'DiagnosticSettingsNotSupported')) {
            throw ('Diagnostic shutdown is unresolved: ' + $settings.error.code)
        }
        foreach ($setting in $settings.value) {
            $null = Invoke-Arm DELETE $setting.id '2021-05-01-preview' -Optional
        }
    }
    foreach ($association in @($state.sourceSettings | Where-Object kind -EQ 'Association')) {
        $null = Invoke-Arm DELETE $association.id $association.apiVersion -Optional
    }
    $earlyRoots = @($state.resources | Where-Object {
            ($_.cleanupEarly -or $_.resourceType -in @('microsoft.containerservice/managedclusters','microsoft.monitor/accounts','microsoft.databricks/workspaces')) -and -not $_.external
    })
    foreach ($root in $earlyRoots) {
        $null = Invoke-Arm DELETE $root.id $root.apiVersion -Optional
    }
    foreach ($record in @($state.ownedExternalResources | Sort-Object cleanupOrder)) {
        $current = Invoke-Arm GET $record.id $record.apiVersion -Optional
        if (-not $current) {
            continue
        }
        if (-not $record.after -or (Get-ComparableConfig $current) -cne $record.after) {
            throw 'External root changed immediately before deletion.'
        }
        $null = Invoke-Arm DELETE $record.id $record.apiVersion
        Wait-Resource $record.id $record.apiVersion -Gone
    }
    if ($state.externalDeploymentId) {
        $null = Invoke-Arm DELETE $state.externalDeploymentId '2022-09-01' -Optional
    }

    # 新規immutable accountだけを空にする。通常accountは中身を変更せずRG削除へ任せる。
    $state.storageAccess ??= @{}
    foreach ($item in @($state.inventory | Where-Object type -EQ 'Microsoft.Storage/storageAccounts')) {
        $account = Invoke-Arm GET $item.id '2023-05-01' -Optional
        if (-not $account -or -not $account.properties.immutableStorageWithVersioning.enabled) {
            continue
        }
        $groupId = ($item.id -split '/providers/')[0]
        if ($groupId -in $state.initialState.groupIds -or $item.id -in $state.initialState.resourceIds -or (Invoke-Arm GET $groupId '2022-09-01').tags.fixtureRun -cne $RunId) {
            throw 'Storage drain requires a newly created, owned fixture account.'
        }
        $script:BlobAccountName = $account.name
        if ($account.properties.primaryEndpoints.blob -cne ('https://' + $script:BlobAccountName + '.blob.core.windows.net/')) {
            throw 'Unexpected Blob endpoint.'
        }
        # ---
        # 最初のアクセス設定と一時開放値を別々に保存する。再実行でもBeforeは置き換えない。
        # この断片の前に、対象accountが今回新規作成した所有資源であることを確認する。
        # ---
        $accessFields = @('allowSharedKeyAccess', 'publicNetworkAccess', 'networkAcls')
        $current = Invoke-Arm GET $item.id '2023-05-01'
        $currentAccess = @{}
        foreach ($field in $accessFields) {
            $currentAccess[$field] = $current.properties[$field]
        }
        if (-not $state.storageAccess.ContainsKey($item.id)) {
            $before = $currentAccess | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $temporary = $before | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
            $temporary.allowSharedKeyAccess = $true
            $temporary.publicNetworkAccess = 'Enabled'
            $temporary.networkAcls.defaultAction = 'Allow'
            $state.storageAccess[$item.id] = @{
                Before = $before
                Temporary = $temporary
                OpenIntent = $false
                TemporaryOpened = $null
            }
            Save-State
        }
        $access = $state.storageAccess[$item.id]
        $beforeConfiguration = Get-ComparableConfig $access.Before
        $temporaryConfiguration = Get-ComparableConfig $access.Temporary
        try {
            # ---
            # 元の値か、開放前に意図を保存した一時値だけを変更する。未知のACLは上書きしない。
            # PATCH直後に中断しても、保存済みTemporaryとOpenIntentで再開できる。
            # ---
            $current = Invoke-Arm GET $item.id '2023-05-01'
            $currentAccess = @{}
            foreach ($field in $accessFields) {
                $currentAccess[$field] = $current.properties[$field]
            }
            $configuration = Get-ComparableConfig $currentAccess
            if ($configuration -cne $beforeConfiguration -and
                -not ($access.OpenIntent -and $configuration -ceq $temporaryConfiguration)) {
                throw 'Storage access changed outside this run; no opening PATCH was sent.'
            }
            $access.OpenIntent = $true
            Save-State
            if ($configuration -cne $temporaryConfiguration) {
                $opened = $access.Temporary | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
                $null = Invoke-Arm PATCH $item.id '2023-05-01' @{ properties = $opened }
            }
            $effective = Invoke-Arm GET $item.id '2023-05-01'
            $openedAccess = @{}
            foreach ($field in $accessFields) {
                $openedAccess[$field] = $effective.properties[$field]
            }
            if ((Get-ComparableConfig $openedAccess) -cne $temporaryConfiguration) {
                throw 'Storage access opening did not match its saved temporary configuration.'
            }
            $access.TemporaryOpened ??= ($openedAccess | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable)
            Save-State

            Start-Sleep -Seconds 30
            $keys = Invoke-Arm POST ($item.id + '/listKeys') '2023-05-01' -Query
            $script:BlobAccountKey = $keys.keys[0].value
            $containers = Invoke-Arm GET ($item.id + '/blobServices/default/containers') '2023-05-01'
            foreach ($container in $containers.value) {
                $containerName = $container.name
                # ---
                # 呼出元がaccount所有・送信設定停止・access開放・listKeys取得を確認してから実行する。
                # containerNameの内容だけを空にし、成功後のcontainer削除は呼出元がARMで行う。
                # immutable/lease/hold解除とpermanent deleteは送らず、server保護エラーで停止する。
                # ---
                $containerEmpty=$false
                for($pass=0;$pass -le 3;$pass++){
                    $rows=@()
                    $marker=''
                    $seenMarkers=[Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
                    do{
                        $query=@{restype='container';comp='list';include='versions,snapshots,deletedwithversions'}
                        if($marker){
                            $query.marker=$marker
                        }
                        [xml]$listing=([string](Invoke-Blob GET $containerName -Query $query).Content).TrimStart([char]0xFEFF)
                        if($listing.DocumentElement.Name -cne 'EnumerationResults' -or
                            $null -eq $listing.SelectSingleNode('/EnumerationResults/Blobs') -or
                            $null -eq $listing.SelectSingleNode('/EnumerationResults/NextMarker')){
                            throw 'Unexpected List Blobs response; empty content is unproven.'
                        }
                        $rows+=@($listing.EnumerationResults.Blobs.Blob | Where-Object {$_})
                        $marker=[string]$listing.EnumerationResults.NextMarker
                        if($marker -and -not $seenMarkers.Add($marker)){
                            throw 'List Blobs continuation marker repeated.'
                        }
                    }while($marker)
                    $live=@($rows | Where-Object {
                        -not ([string]$_.HasVersionsOnly -eq 'true' -and -not $_.VersionId -and -not $_.Snapshot)
                    })
                    if(-not $live.Count){
                        $containerEmpty=$true
                        break
                    }
                    if($pass -eq 3){
                        throw 'Blob content remains after three drain passes.'
                    }
                    # Snapshot→previous→current/versionlessの順。base DELETEへsnapshot一括削除は指定しない。
                    foreach($row in @($live | Sort-Object @{Expression={
                        if($_.Snapshot){
                            0
                        }elseif($_.VersionId -and [string]$_.IsCurrentVersion -ne 'true'){
                            1
                        }else{
                            2
                        }
                    }},Name)){
                        $nameElement=$row.SelectSingleNode('Name')
                        $blobName=$nameElement.InnerText
                        if($nameElement.GetAttribute('Encoded') -eq 'true'){
                            $blobName=[Uri]::UnescapeDataString($blobName)
                        }
                        $snapshot=[string]$row.Snapshot
                        $version=[string]$row.VersionId
                        if([string]$row.Deleted -eq 'true'){
                            throw 'Soft-deleted content remains; permanent deletion is not enabled by this script.'
                        }
                        if($snapshot){
                            $null=Invoke-Blob DELETE $containerName $blobName -Query @{snapshot=$snapshot} -AllowNotFound
                            continue
                        }
                        if($version -and [string]$row.IsCurrentVersion -ne 'true'){
                            $null=Invoke-Blob DELETE $containerName $blobName -Query @{versionid=$version} -AllowNotFound
                            continue
                        }
                        $head=Invoke-Blob HEAD $containerName $blobName -AllowNotFound
                        if(-not $head){
                            if($version){
                                $null=Invoke-Blob DELETE $containerName $blobName -Query @{versionid=$version} -AllowNotFound
                            }
                            continue
                        }
                        $etag=[string]$head.Headers.ETag
                        $currentVersion=[string]$head.Headers['x-ms-version-id']
                        $listedEtag=([string]$row.Properties.Etag).Trim('"')
                        if(-not $etag -or ($listedEtag -and $listedEtag -cne $etag.Trim('"')) -or
                            $currentVersion -cne $version){
                            throw 'Blob identity changed between LIST and HEAD; no base DELETE sent.'
                        }
                        $null=Invoke-Blob DELETE $containerName $blobName -Headers @{'If-Match'=$etag}
                        if($version){
                            # BASE削除でpreviousになった同じversionを明示削除し、そのIDの不存在を確認する。
                            $null=Invoke-Blob DELETE $containerName $blobName -Query @{versionid=$version} -AllowNotFound
                            if(Invoke-Blob HEAD $containerName $blobName -Query @{versionid=$version} -AllowNotFound){
                                throw 'The exact current version remains after deletion.'
                            }
                        }elseif(Invoke-Blob HEAD $containerName $blobName -AllowNotFound){
                            throw 'The exact versionless base remains after deletion.'
                        }
                    }
                }
                if(-not $containerEmpty){
                    throw 'Blob drain did not prove an empty container.'
                }
                $null = Invoke-Arm DELETE $container.id '2023-05-01'
                Wait-Resource $container.id '2023-05-01' -Gone
            }
        } finally {
            $script:BlobAccountKey = $null
            $keys = $null
            try {
                # ---
                # drainの成否にかかわらず復元する。未知の変更は保持して停止する。
                # PATCHするのは保存した3項目だけ。他のaccount設定には触れない。
                # ---
                $remaining = Invoke-Arm GET $item.id '2023-05-01' -Optional
                if ($remaining) {
                    $remainingAccess = @{}
                    foreach ($field in $accessFields) {
                        $remainingAccess[$field] = $remaining.properties[$field]
                    }
                    $configuration = Get-ComparableConfig $remainingAccess
                    if ($configuration -cne $beforeConfiguration -and
                        -not ($access.OpenIntent -and $configuration -ceq $temporaryConfiguration)) {
                        throw 'Storage access changed outside this run; unknown settings were preserved.'
                    }
                    if ($configuration -cne $beforeConfiguration) {
                        $restore = $access.Before | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
                        $null = Invoke-Arm PATCH $item.id '2023-05-01' @{ properties = $restore }
                    }
                    $restored = Invoke-Arm GET $item.id '2023-05-01'
                    $restoredAccess = @{}
                    foreach ($field in $accessFields) {
                        $restoredAccess[$field] = $restored.properties[$field]
                    }
                    if ((Get-ComparableConfig $restoredAccess) -cne $beforeConfiguration) {
                        throw 'Storage access settings were not restored.'
                    }
                }
            } finally {
                $script:BlobAccountName = $null
            }
        }
    }
    foreach ($workspace in @($state.inventory | Where-Object type -EQ 'Microsoft.OperationalInsights/workspaces')) {
        $null = Invoke-Arm DELETE ($workspace.id + '?force=true') '2023-09-01' -Optional
    }
    foreach ($root in $earlyRoots) {
        Wait-Resource $root.id $root.apiVersion -Gone
    }
    foreach ($role in $state.ownedExternalRoles) {
        $current = Invoke-Arm GET $role.id '2022-04-01' -Optional
        if ($current -and ($current.properties.principalId -ine $role.body.properties.principalId -or $current.properties.roleDefinitionId -ine $role.body.properties.roleDefinitionId)) {
            throw 'Existing-subnet role assignment changed.'
        }
        $null = Invoke-Arm DELETE $role.id '2022-04-01' -Optional
    }
    # 所有RGを先に全てDELETE開始し、その後に待つ。既存VNet RGは含めない。
    $groupIds = @(
        $state.plan.bundles | ForEach-Object {
            '/subscriptions/' + $_.subscriptionId + '/resourceGroups/' + $_.resourceGroup
        }
        $state.managedGroups | ForEach-Object id
    ) | Sort-Object -Unique
    foreach ($groupId in $groupIds) {
        $null = Invoke-Arm DELETE $groupId '2022-09-01' -Optional
    }
    foreach ($groupId in $groupIds) {
        Wait-Resource $groupId '2022-09-01' -Gone
    }
    foreach ($item in @($state.inventory | Where-Object {
                $_.type -in @('Microsoft.KeyVault/vaults', 'Microsoft.CognitiveServices/accounts')
    })) {
        $parts = $item.id.Split('/')
        if ($item.type -eq 'Microsoft.KeyVault/vaults') {
            $deletedId = '/subscriptions/' + $parts[2] + '/providers/Microsoft.KeyVault/locations/' + $item.location + '/deletedVaults/' + $parts[-1]
            if (Invoke-Arm GET $deletedId '2023-07-01' -Optional) {
                $null = Invoke-Arm POST ($deletedId + '/purge') '2023-07-01'
            }
            Wait-Resource $deletedId '2023-07-01' -Gone
        } else {
            $deletedId = '/subscriptions/' + $parts[2] + '/providers/Microsoft.CognitiveServices/locations/' + $item.location + '/resourceGroups/' + $parts[4] + '/deletedAccounts/' + $parts[-1]
            if (Invoke-Arm GET $deletedId '2025-06-01' -Optional) {
                $null = Invoke-Arm DELETE $deletedId '2025-06-01'
            }
            Wait-Resource $deletedId '2025-06-01' -Gone
        }
    }
    foreach ($initial in $state.initialState) {
        $deleted = Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/providers/Microsoft.OperationalInsights/deletedWorkspaces') '2023-09-01'
        $ownedWorkspaces = @($state.inventory | Where-Object { $_.type -eq 'Microsoft.OperationalInsights/workspaces' -and $_.id.StartsWith('/subscriptions/' + $initial.subscriptionId + '/', [StringComparison]::OrdinalIgnoreCase) } | ForEach-Object id)
        if (@($deleted.value | Where-Object { $_.id -in $ownedWorkspaces -or $_.properties.originalResourceId -in $ownedWorkspaces }).Count) {
            throw 'Recoverable owned Log Analytics workspace remains; resource cleanup is incomplete.'
        }
    }
    foreach ($initial in $state.initialState) {
        $exemptions = Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/providers/Microsoft.Authorization/policyExemptions') '2022-07-01-preview'
        foreach ($exemption in @($exemptions.value | Where-Object { $_.id -notin $initial.exemptionIds })) {
            if ($exemption.properties.policyAssignmentId -notin $state.policyAssignmentIds -or
                $exemption.properties.exemptionCategory -ne 'Waiver' -or
                $exemption.id -notmatch ('^/subscriptions/' + [regex]::Escape($initial.subscriptionId) + '/providers/Microsoft.Authorization/policyExemptions/[^/]+$')) {
                throw 'Unknown policy exemption remains; it was preserved.'
            }
            $null = Invoke-Arm DELETE $exemption.id '2022-07-01-preview'
            Wait-Resource $exemption.id '2022-07-01-preview' -Gone
        }
    }
    $entities = Invoke-Arm POST '/providers/Microsoft.Management/getEntities' '2020-05-01' -Query
    foreach ($parent in $state.subscriptionParents) {
        $currentParent = @($entities.value | Where-Object { $_.name -eq $parent.subscriptionId -or $_.id -eq ('/subscriptions/' + $parent.subscriptionId) })[0].properties.parent.id
        if ($currentParent -ieq $state.managementGroupId) {
            $null = Invoke-Arm PUT ($parent.parentId + '/subscriptions/' + $parent.subscriptionId) '2020-05-01'
        } elseif ($currentParent -ine $parent.parentId) {
            throw 'Subscription parent changed outside this run.'
        }
    }
    $limit = [DateTimeOffset]::UtcNow.AddMinutes(5)
    do {
        $entities = Invoke-Arm POST '/providers/Microsoft.Management/getEntities' '2020-05-01' -Query
        $pendingParents = @($state.subscriptionParents | Where-Object {
            $parent = $_
            $actualParent = @($entities.value | Where-Object { $_.name -eq $parent.subscriptionId -or $_.id -eq ('/subscriptions/' + $parent.subscriptionId) })[0].properties.parent.id
            $actualParent -ine $parent.parentId
        })
        if (-not $pendingParents.Count) {
            break
        }
        if ([DateTimeOffset]::UtcNow -ge $limit) {
            throw 'Subscription parent restoration has not been confirmed.'
        }
        Start-Sleep -Seconds 5
    } while ($true)
    if (Invoke-Arm GET $state.managementGroupId '2020-05-01' -Optional) {
        foreach ($collection in @('policyAssignments','policySetDefinitions','policyDefinitions','roleAssignments')) {
            $api = if ($collection -eq 'roleAssignments') {
                '2022-04-01'
            } elseif ($collection -eq 'policyAssignments') {
                '2022-06-01'
            } else {
                '2023-04-01'
            }
            $prefix = $state.managementGroupId + '/providers/Microsoft.Authorization/' + $collection + '/'
            $entries = Invoke-Arm GET ($state.managementGroupId + '/providers/Microsoft.Authorization/' + $collection) $api
            foreach ($entry in @($entries.value | Where-Object { $_.id.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) })) {
                $null = Invoke-Arm DELETE $entry.id $api -Optional
            }
        }
        $null = Invoke-Arm DELETE $state.managementGroupId '2020-05-01' -Optional
        Wait-Resource $state.managementGroupId '2020-05-01' -Gone
    }
    foreach ($network in $state.existingNetworks) {
        $actual = Invoke-Arm GET $network.vnetId '2024-05-01'
        if ((Get-ComparableConfig $actual $network.networkBefore) -cne $network.configuration) {
            throw 'Existing VNet/subnet configuration differs from Before.'
        }
        $diagnostics = Invoke-Arm GET ($network.vnetId + '/providers/Microsoft.Insights/diagnosticSettings') '2021-05-01-preview'
        if (-not $diagnostics -or -not $diagnostics.ContainsKey('value') -or $diagnostics.value -isnot [array]) {
            throw 'Existing VNet diagnostic settings did not return a value array.'
        }
        if ((Get-ComparableConfig $diagnostics.value) -cne (Get-ComparableConfig $network.diagnosticsBefore.body.value)) {
            throw 'Existing VNet diagnostic settings differ from Before.'
        }
    }
    Save-State
}

# ---
# 最後にMicrosoft.Resourcesの一覧で残存を照合し、元未登録を確認できたRPだけ戻す。
# cleanup再実行時にサービスAPIを呼び直して、復元済みRPを再登録しない。
# ---
if ($Action -eq 'Cleanup') {
    foreach ($initial in $state.initialState) {
        $resourceIds = @((Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/resources') '2021-04-01').value.id | Sort-Object)
        $groupIds = @((Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/resourceGroups') '2022-09-01').value.id | Sort-Object)
        if (($resourceIds -join '|') -cne (($initial.resourceIds | Sort-Object) -join '|') -or ($groupIds -join '|') -cne (($initial.groupIds | Sort-Object) -join '|')) {
            throw 'Resource differences remain; provider restoration has not started.'
        }
    }
    foreach ($initial in $state.initialState) {
        foreach ($collection in @(
            @{ name = 'roleAssignments'; api = '2022-04-01'; before = $initial.roleIds },
            @{ name = 'policyAssignments'; api = '2022-06-01'; before = $initial.assignmentIds },
            @{ name = 'policyExemptions'; api = '2022-07-01-preview'; before = $initial.exemptionIds }
        )) {
            $actual = Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/providers/Microsoft.Authorization/' + $collection.name) $collection.api
            if ((@($actual.value.id | Sort-Object) -join '|') -cne (@($collection.before | Sort-Object) -join '|')) {
                throw ('Authorization differences remain: ' + $initial.subscriptionId + '/' + $collection.name)
            }
        }
    }
    if (-not $state.resourceCleanupComplete) {
        $state.resourceCleanupComplete = $true
        Save-State
    }
    foreach ($initial in $state.initialState) {
        $currentProviders = (Invoke-Arm GET ('/subscriptions/' + $initial.subscriptionId + '/providers') '2021-04-01').value
        foreach ($provider in @($initial.providers | Where-Object { $_.registrationState -in @('NotRegistered','Unregistered') })) {
            $current = @($currentProviders | Where-Object namespace -EQ $provider.namespace)[0]
            if ($current.registrationState -in @('NotRegistered','Unregistered')) {
                continue
            }
            $id = '/subscriptions/' + $initial.subscriptionId + '/providers/' + $provider.namespace
            if ($current.registrationState -eq 'Registered') {
                $null = Invoke-Arm POST ($id + '/unregister') '2021-04-01'
            }
            $limit = [DateTimeOffset]::UtcNow.AddMinutes(90)
            while ($current.registrationState -notin @('NotRegistered','Unregistered')) {
                if ([DateTimeOffset]::UtcNow -ge $limit) {
                    throw ('Provider unregister wait exceeded: ' + $provider.namespace)
                }
                Start-Sleep -Seconds 10
                $current = Invoke-Arm GET $id '2021-04-01'
            }
        }
    }
    $state.status = 'CLEANED'
    Save-State
    Write-Host 'Owned test resources removed; existing networks preserved.'
}
