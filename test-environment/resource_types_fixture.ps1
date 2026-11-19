#Requires -Version 5.1
[CmdletBinding()]
param(
    [ValidateSet('Plan','Deploy','Capture','Seed','Cleanup')][string]$Action = 'Plan',
    [string]$RunId = '',
    [decimal]$BudgetJPY = 0,
    [switch]$IncludeConditional,
    [switch]$IncludeAse,
    [string[]]$SkipTypes = @(),
    [string]$AdminSshPublicKey = '',
    [string]$PublisherEmail = 'fixture@example.invalid',
    # 既存VNetはリソースIDで指定します。RG名・VNet名と実サブネット情報はここから取得します。
    [string]$ExistingVnetIdA = '/subscriptions/5f1b809c-f59f-4489-8211-4bef16a0463a/resourceGroups/rg-fx-net261118a-a/providers/Microsoft.Network/virtualNetworks/vnet-fx-net261118a-a',
    [string]$ExistingVnetIdB = '/subscriptions/bfda36ec-1aed-4b0c-a907-4d4809c63888/resourceGroups/rg-fx-net261118a-b/providers/Microsoft.Network/virtualNetworks/vnet-fx-net261118a-b',
    [string]$RunRoot = ''
)

# 利用者設定。2 subscription に全型を複製せず、ARM の bundle へ分散します。
$SubscriptionIdA = '5f1b809c-f59f-4489-8211-4bef16a0463a'
$SubscriptionIdB = 'bfda36ec-1aed-4b0c-a907-4d4809c63888'
$PrimaryLocation = 'japaneast'
$SecondaryLocation = 'japanwest'
$ThirdLocation = 'canadacentral'
$FourthLocation = 'westus2'
$MaxLifetimeHours = 6
# override は依存 bundle 全体へ適用します。例: 'B-R2'=@{Location='eastus';Reason='RP 提供地域を確認済み'}
$BundleLocationOverrides = @{}
# 空なら2 subscription の共通の元親を使用。異なる親の場合は明示してください。
$ManagementGroupParentId = ''

# 利用する5サブネットは固定です。このスクリプトはVNet/サブネットを作成・更新しません。
$ExistingSubnetNames = [ordered]@{Protect='ProtectSubnet';Private='PrivateSubnet';ApplicationGateway='ApplicationGatewaySubnet';VNetIntegration='VNetIntegrationSubnet';AzureFirewall='AzureFirewallSubnet'}
$ExistingNetworkConfiguration = @()
# 以降の工程は作成時の台帳を使うため、入力IDの検証はPlan/Deployだけで行います。
if($Action -in @('Plan','Deploy')){
    foreach($network in @(@{role='A';subscriptionId=$SubscriptionIdA;id=$ExistingVnetIdA},@{role='B';subscriptionId=$SubscriptionIdB;id=$ExistingVnetIdB})){
        # 対象サブスクリプションのVNet本体IDだけを受け付けます。子リソースやURLは指定できません。
        $pattern='\A/subscriptions/'+[regex]::Escape($network.subscriptionId)+'/resourceGroups/([^/\\?#%\s]+)/providers/Microsoft\.Network/virtualNetworks/([^/\\?#%\s]+)\z'
        if($network.id -notmatch $pattern){throw ('ExistingVnetId'+$network.role+' must be an exact VNet resource ID in its configured subscription.')}
        $ExistingNetworkConfiguration += [pscustomobject]@{role=$network.role;subscriptionId=$network.subscriptionId;resourceGroupName=$Matches[1];vnetName=$Matches[2];vnetId=$network.id;subnetNames=$ExistingSubnetNames}
    }
}

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version 2.0
$script:Utf8 = New-Object System.Text.UTF8Encoding($false)
$script:TemplatePath = Join-Path $PSScriptRoot 'resource_types.arm.json'
$script:ScriptPath = $MyInvocation.MyCommand.Path
$script:Template = Get-Content -LiteralPath $script:TemplatePath -Raw -Encoding UTF8 | ConvertFrom-Json
$script:Ledger = $null
$script:LedgerPath = ''
$script:RunPath = ''
$script:RestBase = 'https://management.azure.com'
$script:CurrentSubscription = ''

function Write-JsonFile {
    param([string]$Path, $Value)
    $text = ConvertTo-Json -InputObject $Value -Depth 100
    $temporary = $Path + '.pending'
    [IO.File]::WriteAllText($temporary, $text, $script:Utf8)
    Move-Item -LiteralPath $temporary -Destination $Path -Force
}
function Save-Ledger {
    Write-JsonFile -Path $script:LedgerPath -Value $script:Ledger
}
function Add-Operation {
    param([string]$Method,[string]$Id,[string]$ApiVersion,[string]$Purpose)
    $entry = [pscustomobject]@{ 
        sequence=@($script:Ledger.operations).Count
        method=$Method
        id=$Id
        apiVersion=$ApiVersion
        purpose=$Purpose
        status='INTENT'
        startedUtc=[DateTime]::UtcNow.ToString('o')
        finishedUtc=$null
        errorCode=$null 
    }
    $script:Ledger.operations = @($script:Ledger.operations) + @($entry)
    Save-Ledger
    return $entry
}
function Invoke-AzJson {
    param([string[]]$Arguments,[switch]$MayFail)
    # トークン、本文、ネイティブ stderr は表示・保存しません。失敗はコードだけを保持します。
    $previousPreference=$ErrorActionPreference
    $errorPath=New-PrivateJsonFile -Value @{}
    $stderr=''
    try {
        $ErrorActionPreference='Continue'
        $capture = @(& az @Arguments --only-show-errors --output json 2>$errorPath)
        $exitCode = $LASTEXITCODE
        $stderr=Get-Content -LiteralPath $errorPath -Raw -ErrorAction SilentlyContinue
    } finally {$ErrorActionPreference=$previousPreference
    Remove-Item -LiteralPath $errorPath -Force -ErrorAction SilentlyContinue}
    $raw = ($capture | ForEach-Object { $_.ToString() }) -join "`n"
    if ($exitCode -ne 0) {
        $errorCode = 'CLI_FAILED'
        $knownCodes=@('ResourceNotFound','ResourceGroupNotFound','ManagementGroupNotFound','NotFound',
            'RoleAssignmentNotFound','DiagnosticSettingNotFound','PolicyDefinitionNotFound',
            'PolicySetDefinitionNotFound','PolicyAssignmentNotFound','ResourceTypeNotSupported',
            'UnsupportedResourceType','DiagnosticSettingsNotSupported','AuthorizationFailed',
            'AuthenticationFailed','InvalidAuthenticationToken','MissingSubscriptionRegistration',
            'NoRegisteredProviderFound','InvalidApiVersionParameter','InvalidResourceLocation',
            'InvalidRequest','BadRequest','Conflict','OperationNotAllowed','ServiceUnavailable',
            'InternalServerError','TooManyRequests','RequestDisallowedByPolicy')
        # 本文内のNotFoundや任意のcode文字列をabsence/出力値として採用しません。
        if($stderr -match '(?m)^[ \t]*(?:ERROR:[ \t]*)?(?:HTTP(?:/[0-9.]+)?\s+|Status(?: Code)?\s*:\s*)([1-5][0-9]{2})\b') {
            $errorCode=if($Matches[1] -eq '403'){'AuthorizationFailed'}elseif($Matches[1] -eq '401'){'AuthenticationFailed'}else{'CLI_FAILED'}
        } elseif($stderr -match '(?m)^[ \t]*ERROR:[ \t]*\(([A-Za-z][A-Za-z0-9_.]*)\)(?:[ \t]|$)') {
            if($knownCodes -ccontains $Matches[1]){$errorCode=$Matches[1]}
        } elseif($stderr -cmatch '\A[ \t]*ERROR:[ \t]*Not Found\((\{[\s\S]*\})\)[ \t\r\n]*\z') {
            # CLIの完全な応答形式だけを解析し、本文のmessageは判定に使いません。
            try {
                $cliError=ConvertFrom-Json -InputObject $Matches[1] -ErrorAction Stop
                if($cliError.error.code -is [string] -and $knownCodes -ccontains $cliError.error.code){$errorCode=$cliError.error.code}
            } catch {}
        }
        if (-not $MayFail) { throw ('Azure CLI failed: ' + $errorCode) }
        return [pscustomobject]@{ ok=$false
         code=$errorCode
         value=$null }
    }
    $value = $null
    if (-not [string]::IsNullOrWhiteSpace($raw)) { $value = ConvertFrom-Json -InputObject $raw }
    return [pscustomobject]@{ ok=$true
     code=$null
     value=$value }
}
function New-PrivateJsonFile {
    param($Value)
    # 秘密値を書き込む前に owner-only ACL を設定。Windows PS5.1 で継承を切ります。
    $path = Join-Path $script:RunPath ([Guid]::NewGuid().ToString('N') + '.private.json')
    $null = New-Item -ItemType File -Path $path
    try {
        if ($env:OS -eq 'Windows_NT') {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent().User
            $acl = New-Object Security.AccessControl.FileSecurity
            $acl.SetOwner($identity)
            $acl.SetAccessRuleProtection($true,$false)
            $rule = New-Object Security.AccessControl.FileSystemAccessRule($identity,'FullControl','Allow')
            $acl.AddAccessRule($rule)
            Set-Acl -LiteralPath $path -AclObject $acl
        } else {
            & chmod 600 $path
            if ($LASTEXITCODE -ne 0) { throw 'Private file permission failed.' }
        }
        [IO.File]::WriteAllText($path,(ConvertTo-Json -InputObject $Value -Depth 100),$script:Utf8)
        return $path
    } catch { Remove-Item -LiteralPath $path -Force -ErrorAction SilentlyContinue
     throw }
}
function Invoke-Api {
    param([string]$Method,[string]$Id,[string]$ApiVersion,$Body=$null,[switch]$MayFail,[string]$Purpose='')
    if($Method -notin @('GET','HEAD') -and $Id -match '/providers/Microsoft.Network/virtualNetworks/[^/?]+(?:/subnets/[^/?]+)?/?(?:\?.*)?$'){throw 'VNet/subnet create, update, and delete are prohibited.'}
    $url = if ($Id.StartsWith('https://management.azure.com/')) { $Id } else { $script:RestBase + $Id }
    if ($url -notmatch '\?') { $url += '?api-version=' + $ApiVersion }
    $arguments = @('rest','--method',$Method,'--url',$url,'--resource',($script:RestBase+'/'))
    if ($script:CurrentSubscription) { $arguments += @('--subscription',$script:CurrentSubscription) }
    $privatePath = $null
    $entry = $null
    try {
        if ($Method -notin @('GET','HEAD') -and $Purpose -ne 'READ_ONLY_QUERY') {
            $entry = Add-Operation -Method $Method -Id $Id -ApiVersion $ApiVersion -Purpose $Purpose
        }
        if ($null -ne $Body) {
            $privatePath = New-PrivateJsonFile -Value $Body
            $arguments += @('--body',('@' + $privatePath),'--headers','Content-Type=application/json')
        }
        $result = Invoke-AzJson -Arguments $arguments -MayFail
        if ($entry) { $entry.status = if($result.ok){'ACCEPTED'}else{'FAILED'}
         $entry.errorCode=$result.code
         $entry.finishedUtc=[DateTime]::UtcNow.ToString('o')
         Save-Ledger }
        if (-not $result.ok -and -not $MayFail) { throw ('ARM request failed: ' + $result.code) }
        return $result
    } finally { if ($privatePath) { Remove-Item -LiteralPath $privatePath -Force -ErrorAction SilentlyContinue } }
}
function Get-ApiPages {
    param([string]$Id,[string]$ApiVersion,[string]$Method='GET')
    $items = @()
     $next=$Id
    while ($next) {
        $response = (Invoke-Api -Method $Method -Id $next -ApiVersion $ApiVersion -Purpose 'READ_ONLY_QUERY').value
        if ($null -ne $response.PSObject.Properties['value']) { $items += @($response.value) } else { $items += @($response) }
        $next = if ($null -ne $response.PSObject.Properties['nextLink']) { [string]$response.nextLink } else { '' }
        if ($next -and -not $next.StartsWith('https://management.azure.com/')) { throw 'Unexpected nextLink origin.' }
    }
    return $items
}
function Assert-RunWindow {
    $age = [DateTime]::UtcNow - [DateTime]::Parse($script:Ledger.startedUtc).ToUniversalTime()
    if ($age.TotalHours -ge $MaxLifetimeHours) { throw 'Run lifetime exceeded; use Cleanup. This is not a billing hard cap.' }
}
function Assert-SpendApproval {
    if ($BudgetJPY -le 0) {
        throw 'Deploy/Seed requires positive BudgetJPY after the user reviews the estimate and this script. No Azure call was made. Budget is not a billing hard cap.'
    }
}
function Wait-ResourceGone {
    param([string]$Id,[string]$ApiVersion,[int]$MaximumMinutes=90)
    $limit = [DateTime]::UtcNow.AddMinutes($MaximumMinutes)
    do {
        $response = Invoke-Api -Method GET -Id $Id -ApiVersion $ApiVersion -MayFail
        if (-not $response.ok -and $response.code -in @('ResourceNotFound','ResourceGroupNotFound','ManagementGroupNotFound','NotFound','RoleAssignmentNotFound')) { return }
        if (-not $response.ok) { throw ('Deletion verification unresolved: ' + $response.code) }
        if ([DateTime]::UtcNow -gt $limit) { throw ('Deletion wait timed out: ' + $Id) }
        Start-Sleep -Seconds 15
    } while ($true)
}
function Get-PropertyValue {
    param($Object,[string]$Name,$Default=$null)
    if ($null -ne $Object -and $null -ne $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $Default
}
# 既存ネットワーク専用。所有資源inventoryへ混ぜず、Beforeは初回GETのまま保持します。
function Get-ExternalNetworkRaw {
    param([string]$Id,[string]$ApiVersion='2025-01-01')
    $script:CurrentSubscription=($Id -split '/')[2]
    $response=Invoke-Api -Method GET -Id $Id -ApiVersion $ApiVersion -MayFail
    if(-not $response.ok){throw ('Existing network GET unresolved: '+$Id+' / '+$response.code)}
    return $response.value
}
function Copy-ExternalNetworkValue {
    param($Value)
    return (ConvertTo-Json -InputObject $Value -Depth 100 | ConvertFrom-Json)
}
function Convert-ExternalNetworkConfig {
    param($Value,[ValidateSet('Vnet','Subnet','Nsg','Rule','ResourceGroup')][string]$Kind)
    if($null -eq $Value){return $null}
    $copy=Copy-ExternalNetworkValue $Value
    # 明示したserver返却項目だけ。tags/未知の設定/address/delegation/NSG等は除去しません。
    $copy.PSObject.Properties.Remove('etag')
    $properties=Get-PropertyValue $copy 'properties'
    if($properties){$properties.PSObject.Properties.Remove('provisioningState')}
    if($Kind -eq 'Subnet'){
        foreach($name in @('ipConfigurations','ipConfigurationProfiles','privateEndpoints','serviceAssociationLinks','resourceNavigationLinks','purpose')){
            $properties.PSObject.Properties.Remove($name)
        }
        foreach($delegation in @(Get-PropertyValue $properties 'delegations' @())){
            $delegation.PSObject.Properties.Remove('etag')
            $delegationProperties=Get-PropertyValue $delegation 'properties'
            if($delegationProperties){$delegationProperties.PSObject.Properties.Remove('provisioningState')}
        }
    }
    if($Kind -eq 'Vnet'){
        $copy.properties.subnets=@(foreach($subnet in @(Get-PropertyValue $properties 'subnets' @())){Convert-ExternalNetworkConfig $subnet 'Subnet'})
    }
    if($Kind -eq 'Nsg'){
        foreach($name in @('networkInterfaces','subnets')){$properties.PSObject.Properties.Remove($name)}
        foreach($name in @('securityRules','defaultSecurityRules')){
            if($properties.PSObject.Properties[$name]){
                $properties.$name=@(foreach($rule in @($properties.$name | Sort-Object name)){Convert-ExternalNetworkConfig $rule 'Rule'})
            }
        }
    }
    return $copy
}
function Convert-ExternalNetworkOrdered {
    param($Value)
    if($null -eq $Value){return $null}
    if($Value -is [System.Collections.IDictionary]){
        $ordered=[ordered]@{}
        foreach($name in @($Value.Keys | Sort-Object -CaseSensitive)){$ordered[$name]=Convert-ExternalNetworkOrdered $Value[$name]}
        return $ordered
    }
    if($Value -is [System.Management.Automation.PSCustomObject]){
        $ordered=[ordered]@{}
        foreach($name in @($Value.PSObject.Properties | ForEach-Object {$_.Name} | Sort-Object -CaseSensitive)){$ordered[$name]=Convert-ExternalNetworkOrdered $Value.$name}
        return $ordered
    }
    if($Value -is [System.Collections.IEnumerable] -and $Value -isnot [string]){
        return ,@(foreach($item in $Value){Convert-ExternalNetworkOrdered $item})
    }
    return $Value
}
function Get-ExternalNetworkSignature {
    param($Value,[string]$Kind='')
    if($Kind){$Value=Convert-ExternalNetworkConfig $Value $Kind}
    return (ConvertTo-Json -InputObject (Convert-ExternalNetworkOrdered $Value) -Compress -Depth 100)
}
function Test-ExternalJsonEqual {
    param($Left,$Right)
    return (Get-ExternalNetworkSignature $Left) -ceq (Get-ExternalNetworkSignature $Right)
}
function Get-ExternalDiagnosticSnapshot {
    param([string]$VnetId)
    $script:CurrentSubscription=($VnetId -split '/')[2]
    $response=Invoke-Api -Method GET -Id ($VnetId+'/providers/Microsoft.Insights/diagnosticSettings') -ApiVersion '2021-05-01-preview' -MayFail
    if($response.ok){
        if($null -eq $response.value -or $null -eq $response.value.PSObject.Properties['value']){throw 'Malformed existing network diagnostics list.'}
        return [pscustomobject]@{supported=$true;body=$response.value}
    }
    if($response.code -in @('ResourceTypeNotSupported','UnsupportedResourceType','DiagnosticSettingsNotSupported')){
        return [pscustomobject]@{supported=$false;code=$response.code;body=$null}
    }
    throw ('Existing diagnostic Before unresolved: '+$response.code)
}
function Assert-ExternalDiagnosticSnapshot {
    param($Network,$Current,[switch]$OriginalOnly)
    $before=$Network.diagnosticsBefore
    if(-not $before.supported){
        if($Current.supported -or $Current.code -cne $before.code){throw 'Existing diagnostic unsupported state changed; not PASS.'}
        return
    }
    if(-not $Current.supported){throw 'Previously supported existing diagnostics now unresolved.'}
    $actual=@($Current.body.value)
    $names=@($actual | ForEach-Object {$_.name.ToLowerInvariant()})
    if(@($names | Sort-Object -Unique).Count -ne $names.Count){throw 'Duplicate external diagnostic names.'}
    foreach($original in @($before.body.value)){
        $found=@($actual | Where-Object {$_.id -ieq $original.id})
        if($found.Count -ne 1 -or (Get-ExternalNetworkSignature $found[0]) -cne (Get-ExternalNetworkSignature $original)){
            throw ('Original external diagnostic changed/missing: '+$original.id)
        }
    }
    foreach($setting in $actual){
        if(@($before.body.value | Where-Object {$_.id -ieq $setting.id}).Count -gt 0){continue}
        $created=@(Get-PropertyValue $script:Ledger 'createdExternalDiagnostics' @() | Where-Object {$_.id -ieq $setting.id})
        if($OriginalOnly -or $created.Count -ne 1 -or $created[0].beforeAbsent -ne $true -or
            (Get-ExternalNetworkSignature $setting.properties) -cne (Get-ExternalNetworkSignature $created[0].afterFullProperties)){
            throw ('Untracked/changed external diagnostic preserved: '+$setting.id)
        }
    }
}
function Test-DocumentedDbrNetworkRule {
    param($Rule,[string]$NsgId)
    $prefix='Microsoft.Databricks-workspaces_UseOnly_'
    if(-not $Rule.name.StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or $Rule.name -match '[/\\?#]') {return $false}
    if($Rule.id -ine ($NsgId+'/securityRules/'+$Rule.name)){return $false}
    foreach($field in @($Rule.PSObject.Properties | ForEach-Object {$_.Name})){if($field -notin @('id','name','type','etag','properties')){return $false}}
    $p=$Rule.properties
    $known=@('description','protocol','sourcePortRange','sourcePortRanges','destinationPortRange','destinationPortRanges',
        'sourceAddressPrefix','sourceAddressPrefixes','destinationAddressPrefix','destinationAddressPrefixes','access','priority','direction',
        'provisioningState','sourceApplicationSecurityGroups','destinationApplicationSecurityGroups')
    foreach($field in @($p.PSObject.Properties | ForEach-Object {$_.Name})){if($field -notin $known){return $false}}
    if(@(Get-PropertyValue $p 'sourceApplicationSecurityGroups' @()).Count -or @(Get-PropertyValue $p 'destinationApplicationSecurityGroups' @()).Count){return $false}
    $priority=Get-PropertyValue $p 'priority'
    if(($priority -isnot [int] -and $priority -isnot [long]) -or $priority -lt 100 -or $priority -gt 4096){return $false}
    $parts=@()
    foreach($pair in @(@('sourceAddressPrefix','sourceAddressPrefixes'),@('sourcePortRange','sourcePortRanges'),
        @('destinationAddressPrefix','destinationAddressPrefixes'),@('destinationPortRange','destinationPortRanges'))){
        $items=@(@(Get-PropertyValue $p $pair[0])+@(Get-PropertyValue $p $pair[1] @()) | Where-Object {$null -ne $_ -and [string]$_ -ne ''} | ForEach-Object {[string]$_} | Sort-Object -Unique)
        $parts += (($items -join ',').ToLowerInvariant())
    }
    $tuple=(([string]$p.direction).ToLowerInvariant()+'|'+([string]$p.protocol).ToLowerInvariant()+'|'+($parts -join '|')+'|'+([string]$p.access).ToLowerInvariant())
    # SCC=trueの公式6組だけ。22/5557 inboundや未知security設定を取り込みません。
    return $tuple -cin @('inbound|*|virtualnetwork|*|virtualnetwork|*|allow',
        'outbound|tcp|virtualnetwork|*|azuredatabricks|3306,443,8443-8451|allow',
        'outbound|tcp|virtualnetwork|*|storage|443|allow','outbound|*|virtualnetwork|*|virtualnetwork|*|allow',
        'outbound|tcp|virtualnetwork|*|eventhub|9093|allow','outbound|tcp|virtualnetwork|*|sql|3306|allow')
}
function Update-ValidatedDbrNetworkAfter {
    param($Network,$Before,$Current)
    $beforeConfig=Convert-ExternalNetworkConfig $Before 'Nsg'
    $currentConfig=Convert-ExternalNetworkConfig $Current 'Nsg'
    if((Get-ExternalNetworkSignature $beforeConfig) -ceq (Get-ExternalNetworkSignature $currentConfig)){return}
    $stored=@($Network.validatedNsgAfter | Where-Object {$_.id -ieq $Before.id})
    if($stored.Count -gt 0){
        if($stored.Count -ne 1){throw 'Duplicate validated Databricks NSG snapshot.'}
        $progress=Get-PropertyValue $stored[0] 'restoreProgress'
        if($progress){
            $matchesAfter=(Get-ExternalNetworkSignature $progress.after 'Nsg') -ceq (Get-ExternalNetworkSignature $Current 'Nsg')
            $matchesPendingBefore=$progress.status -eq 'PENDING' -and (Get-ExternalNetworkSignature $progress.before 'Nsg') -ceq (Get-ExternalNetworkSignature $Current 'Nsg')
            if($progress.status -eq 'RESTORED' -or (-not $matchesAfter -and -not $matchesPendingBefore)){throw 'NSG changed outside the single recorded restore checkpoint; preserved.'}
        }elseif((Get-ExternalNetworkSignature $stored[0].after 'Nsg') -cne (Get-ExternalNetworkSignature $Current 'Nsg')){throw 'NSG changed after validated Databricks snapshot; preserved.'}
        return
    }
    $beforeRules=@(Get-PropertyValue $beforeConfig.properties 'securityRules' @())
    $currentRules=@(Get-PropertyValue $currentConfig.properties 'securityRules' @())
    $beforeConfig.properties.PSObject.Properties.Remove('securityRules')
    $currentConfig.properties.PSObject.Properties.Remove('securityRules')
    if((Get-ExternalNetworkSignature $beforeConfig) -cne (Get-ExternalNetworkSignature $currentConfig)){throw 'Unrelated NSG properties changed; preserved.'}
    foreach($original in $beforeRules){
        $found=@($currentRules | Where-Object {$_.name -ieq $original.name})
        if($found.Count -ne 1 -or (Get-ExternalNetworkSignature $found[0]) -cne (Get-ExternalNetworkSignature $original)){throw 'Before NSG rule changed/missing; preserved.'}
    }
    $added=@($Current.properties.securityRules | Where-Object {$rule=$_;@($beforeRules | Where-Object {$_.name -ieq $rule.name}).Count -eq 0})
    if($added.Count -eq 0){throw 'NSG delta has no proven Databricks additions.'}
    foreach($rule in $added){if(-not (Test-DocumentedDbrNetworkRule $rule $Before.id)){throw 'Unknown Databricks NSG rule delta; preserved.'}}
    $Network.validatedNsgAfter += [pscustomobject]@{id=$Before.id;after=(Copy-ExternalNetworkValue $Current)}
    Save-Ledger
}
function Read-ExistingNetworks {
    param([switch]$CaptureBefore)
    $configs=@($script:Ledger.plan.existingNetworks)
    if($configs.Count -ne 2 -or (@($configs.role | Sort-Object -Unique) -join ',') -cne 'A,B'){throw 'Exactly two existing-network name/RG configurations are required.'}
    $roles=@('Protect','Private','ApplicationGateway','VNetIntegration','AzureFirewall')
    $names=@('ProtectSubnet','PrivateSubnet','ApplicationGatewaySubnet','VNetIntegrationSubnet','AzureFirewallSubnet')
    $lengths=@(27,26,24,26,26)
    $captured=@();$existing=@(Get-PropertyValue $script:Ledger 'existingNetworks' @())
    foreach($config in $configs){
        $subscription=if($config.role -eq 'A'){$SubscriptionIdA}else{$SubscriptionIdB}
        $location=if($config.role -eq 'A'){$PrimaryLocation}else{$SecondaryLocation}
        $rg='/subscriptions/'+$subscription+'/resourceGroups/'+$config.resourceGroupName
        $vnetId=$rg+'/providers/Microsoft.Network/virtualNetworks/'+$config.vnetName
        if($config.subscriptionId -ine $subscription -or $config.vnetId -ine $vnetId -or $config.resourceGroupName -match '[/\\?#]' -or $config.vnetName -match '[/\\?#]'){throw 'Existing VNet name/RG/derived identity mismatch.'}
        foreach($bundle in $script:Ledger.plan.bundles){if($rg -ieq ('/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup)){throw 'Existing network RG overlaps a fixture-owned RG.'}}
        $network=Get-ExternalNetworkRaw $vnetId
        $group=Get-ExternalNetworkRaw $rg '2022-09-01'
        if($network.id -ine $vnetId -or ($network.location -replace '\s','') -ine ($location -replace '\s','')){throw 'Existing network identity/location mismatch.'}
        $bundleKey=if($config.role -eq 'A'){'A-R1'}else{'B-R2'}
        $consumer=@($script:Ledger.plan.bundles | Where-Object {$_.key -ceq $bundleKey})
        if($consumer.Count -ne 1 -or ($consumer[0].location -replace '\s','') -ine ($network.location -replace '\s','')){throw 'Existing network does not match its coupled consumer bundle location.'}
        $rawSubnets=@($network.properties.subnets)
        if($rawSubnets.Count -ne 5){throw 'Existing VNet must have the five approved subnet names only.'}
        $subnets=[ordered]@{};$needed=@()
        for($i=0;$i -lt $roles.Count;$i++){
            $role=$roles[$i];$name=$names[$i]
            if($config.subnetNames.$role -cne $name){throw 'Existing subnet name map differs from approved five names.'}
            $found=@($rawSubnets | Where-Object {$_.name -ceq $name})
            if($found.Count -ne 1 -or $found[0].id -ine ($vnetId+'/subnets/'+$name)){throw 'Missing/mismatched existing subnet.'}
            $raw=$found[0];$p=$raw.properties
            $prefixes=@(@(Get-PropertyValue $p 'addressPrefix')+@(Get-PropertyValue $p 'addressPrefixes' @()) | Where-Object {$_})
            if($prefixes.Count -ne 1 -or $prefixes[0] -notmatch ('^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/'+$lengths[$i]+'$')){throw ('Existing subnet prefix must be actual IPv4 /'+$lengths[$i]+': '+$name)}
            $delegations=@(Get-PropertyValue $p 'delegations' @() | ForEach-Object {$_.properties.serviceName})
            # 選択したサービスが使う専用サブネットだけ、必要な委任を確認します。
            $keys=$script:Ledger.plan.selectedKeys
            $expected=if($keys -contains 'ase' -and $config.role -eq 'A' -and $role -eq 'Protect'){'Microsoft.Web/hostingEnvironments'}elseif($keys -contains 'containerEnvironment' -and $config.role -eq 'A' -and $role -eq 'VNetIntegration'){'Microsoft.App/environments'}elseif($keys -contains 'databricks' -and $config.role -eq 'B' -and $role -in @('Private','VNetIntegration')){'Microsoft.Databricks/workspaces'}else{''}
            if($expected -and ($delegations.Count -ne 1 -or $delegations[0] -ine $expected)){throw ('Unexpected existing subnet delegation: '+$name)}
            if($CaptureBefore -and $existing.Count -eq 0 -and $expected){
                foreach($field in @('ipConfigurations','ipConfigurationProfiles','privateEndpoints','serviceAssociationLinks','resourceNavigationLinks')){if(@(Get-PropertyValue $p $field @()).Count){throw ('Dedicated existing subnet is in use: '+$name)}}
            }
            $subnets[$role]=[pscustomobject]@{id=$raw.id;name=$raw.name;addressPrefix=$prefixes[0];properties=(Copy-ExternalNetworkValue $p);raw=(Copy-ExternalNetworkValue $raw)}
            if($keys -contains 'databricks' -and $config.role -eq 'B' -and $role -in @('Private','VNetIntegration')){
                $nsgId=Get-PropertyValue (Get-PropertyValue $p 'networkSecurityGroup') 'id'
                if(-not $nsgId -or $nsgId -notmatch ('^/subscriptions/'+[regex]::Escape($subscription)+'/resourceGroups/[^/]+/providers/Microsoft.Network/networkSecurityGroups/[^/]+$')){throw 'Dedicated DBR subnet requires an exact same-subscription NSG.'}
                $nsg=Get-ExternalNetworkRaw $nsgId
                $links=@(Get-PropertyValue $nsg.properties 'subnets' @() | ForEach-Object {$_.id})
                if($nsg.id -ine $nsgId -or $links.Count -ne 1 -or $links[0] -ine $raw.id -or @(Get-PropertyValue $nsg.properties 'networkInterfaces' @()).Count){throw 'DBR NSG is not dedicated to this subnet.'}
                if(@($needed | Where-Object {$_.id -ieq $nsgId}).Count){throw 'The two DBR subnets require distinct dedicated NSGs.'}
                $needed += [pscustomobject]@{id=$nsgId;before=(Copy-ExternalNetworkValue $nsg)}
            }
        }
        $diagnostics=Get-ExternalDiagnosticSnapshot $vnetId
        $stored=@($existing | Where-Object {$_.role -ceq $config.role -and $_.vnetId -ieq $vnetId})
        if($existing.Count -eq 0){
            if(-not $CaptureBefore){throw 'Immutable existing-network Before has not been captured.'}
            $captured += [pscustomobject]@{role=$config.role;vnetId=$vnetId;rgId=$rg;networkBefore=(Copy-ExternalNetworkValue $network);resourceGroupBefore=(Copy-ExternalNetworkValue $group);subnets=[pscustomobject]$subnets;diagnosticsBefore=(Copy-ExternalNetworkValue $diagnostics);neededNsgBefore=$needed;validatedNsgAfter=@()}
        }else{
            if($existing.Count -ne 2 -or $stored.Count -ne 1){throw 'Existing-network Before identity/count changed.'}
            $before=$stored[0]
            # AppGWが追加した参照だけを比較用コピーから除く。Beforeと実ネットワークは変更しません。
            $comparisonNetwork=Copy-ExternalNetworkValue $network
            foreach($subnet in @($comparisonNetwork.properties.subnets)){
                $originalSubnet=@($before.networkBefore.properties.subnets | Where-Object {$_.id -ieq $subnet.id})
                if($originalSubnet.Count -ne 1){throw 'Existing subnet identity changed.'}
                $originalLinks=@(Get-PropertyValue $originalSubnet[0].properties 'applicationGatewayIPConfigurations' @())
                $currentLinks=@(Get-PropertyValue $subnet.properties 'applicationGatewayIPConfigurations' @())
                if(@($currentLinks | ForEach-Object {$_.id.ToLowerInvariant()} | Sort-Object -Unique).Count -ne $currentLinks.Count){throw 'Duplicate AppGW subnet references.'}
                $keptLinks=@()
                foreach($link in $currentLinks){
                    if(@($originalLinks | Where-Object {$_.id -ieq $link.id}).Count){$keptLinks+=@($link);continue}
                    if(@($link.PSObject.Properties | Where-Object {$_.Name -ne 'id'}).Count){throw 'Unknown field in new AppGW subnet reference.'}
                    $owned=@($script:Ledger.resources | Where-Object {$_.resourceType -ieq 'microsoft.network/applicationgateways' -and $link.id.StartsWith($_.id+'/gatewayIPConfigurations/',[StringComparison]::OrdinalIgnoreCase)})
                    if($owned.Count -ne 1){throw 'Unowned AppGW subnet reference.'}
                    $initial=@($script:Ledger.initialState | Where-Object {$_.subscriptionId -ieq (($owned[0].id -split '/')[2])})
                    if($initial.Count -ne 1 -or @($initial[0].resourceIds | Where-Object {$_ -ieq $owned[0].id}).Count){throw 'AppGW absence before this run is unproven.'}
                    $actual=(Invoke-Api -Method GET -Id $owned[0].id -ApiVersion $owned[0].apiVersion).value
                    if($actual.id -ine $owned[0].id -or (Get-PropertyValue (Get-PropertyValue $actual 'tags') 'fixtureRunId') -cne $RunId -or $actual.properties.provisioningState -ne 'Succeeded'){throw 'AppGW owner/state differs from this run.'}
                    $configuration=@($actual.properties.gatewayIPConfigurations | Where-Object {$_.id -ieq $link.id})
                    if($configuration.Count -ne 1 -or $configuration[0].properties.subnet.id -ine $subnet.id){throw 'AppGW reverse subnet reference differs.'}
                }
                if($originalSubnet[0].properties.PSObject.Properties['applicationGatewayIPConfigurations']){
                    $subnet.properties | Add-Member -MemberType NoteProperty -Name applicationGatewayIPConfigurations -Value $keptLinks -Force
                }else{
                    $subnet.properties.PSObject.Properties.Remove('applicationGatewayIPConfigurations')
                }
            }
            if((Get-ExternalNetworkSignature $before.networkBefore 'Vnet') -cne (Get-ExternalNetworkSignature $comparisonNetwork 'Vnet') -or (Get-ExternalNetworkSignature $before.resourceGroupBefore 'ResourceGroup') -cne (Get-ExternalNetworkSignature $group 'ResourceGroup')){throw 'Existing VNet/subnet/RG writable configuration changed; preserved.'}
            Assert-ExternalDiagnosticSnapshot $before $diagnostics
            foreach($nsg in $needed){$baseline=@($before.neededNsgBefore | Where-Object {$_.id -ieq $nsg.id});if($baseline.Count -ne 1){throw 'Existing dedicated NSG identity changed.'};Update-ValidatedDbrNetworkAfter $before $baseline[0].before $nsg.before}
        }
    }
    if($captured.Count){$script:Ledger.existingNetworks=$captured;Save-Ledger}
}
function Complete-ExternalNsgRuleRestore {
    param($Saved,$OriginalBefore)
    # 1 rule分の書込前/後を先に保存済み。再開時はそのどちらかだけを認めます。
    $progress=$Saved.restoreProgress
    $rule=@($Saved.after.properties.securityRules | Where-Object {$_.id -ieq $progress.ruleId})
    if($progress.status -ne 'PENDING' -or $rule.Count -ne 1 -or -not (Test-DocumentedDbrNetworkRule $rule[0] $Saved.id)){throw 'Invalid pending DBR rule restore checkpoint.'}
    $deleteSent=$false
    for($attempt=0;$attempt -lt 20;$attempt++){
        $current=Get-ExternalNetworkRaw $Saved.id
        if(Test-ExternalJsonEqual (Convert-ExternalNetworkConfig $current 'Nsg') (Convert-ExternalNetworkConfig $OriginalBefore 'Nsg')){
            $progress.status='RESTORED';Save-Ledger;return
        }
        if(Test-ExternalJsonEqual (Convert-ExternalNetworkConfig $current 'Nsg') (Convert-ExternalNetworkConfig $progress.after 'Nsg')){
            $progress.status='VERIFIED';Save-Ledger;return
        }
        if(-not (Test-ExternalJsonEqual (Convert-ExternalNetworkConfig $current 'Nsg') (Convert-ExternalNetworkConfig $progress.before 'Nsg'))){throw 'NSG drift during exact pending rule restore; preserved.'}
        if(-not $deleteSent){
            $script:CurrentSubscription=($Saved.id -split '/')[2]
            $response=Invoke-Api -Method DELETE -Id $progress.ruleId -ApiVersion '2025-01-01' -MayFail
            if(-not $response.ok -and $response.code -notin @('NotFound','ResourceNotFound')){throw 'Exact DBR rule DELETE failed; checkpoint retained.'}
            $deleteSent=$true
            continue
        }
        if($attempt -lt 19){Start-Sleep -Seconds 5}
    }
    throw 'DBR rule readback still pending after bounded GETs; durable checkpoint retained.'
}
function Restore-ExistingNetworkChanges {
    # 全fixture資源/AKS/DBR managedRGが消えてから呼びます。既存VNet/subnet/RGはDELETEしません。
    Read-ExistingNetworks
    foreach($network in @($script:Ledger.existingNetworks)){
        foreach($created in @(Get-PropertyValue $script:Ledger 'createdExternalDiagnostics' @() | Where-Object {$_.id.StartsWith($network.vnetId+'/providers/Microsoft.Insights/diagnosticSettings/',[StringComparison]::OrdinalIgnoreCase)})){
            if($created.beforeAbsent -ne $true -or @($network.diagnosticsBefore.body.value | Where-Object {$_.id -ieq $created.id}).Count){throw 'Cannot delete a pre-existing external diagnostic.'}
            $current=Get-ExternalDiagnosticSnapshot $network.vnetId
            Assert-ExternalDiagnosticSnapshot $network $current
            $found=@($current.body.value | Where-Object {$_.id -ieq $created.id})
            if($found.Count){
                if($found.Count -ne 1 -or (Get-ExternalNetworkSignature $found[0].properties) -cne (Get-ExternalNetworkSignature $created.afterFullProperties)){throw 'Owned external diagnostic changed; preserved.'}
                $script:CurrentSubscription=($created.id -split '/')[2]
                $response=Invoke-Api -Method DELETE -Id $created.id -ApiVersion '2021-05-01-preview' -MayFail
                if(-not $response.ok -and $response.code -notin @('NotFound','ResourceNotFound','DiagnosticSettingNotFound')){throw 'Owned external diagnostic DELETE failed.'}
            }
        }
        Assert-ExternalDiagnosticSnapshot $network (Get-ExternalDiagnosticSnapshot $network.vnetId) -OriginalOnly
        foreach($saved in @($network.validatedNsgAfter)){
            $before=@($network.neededNsgBefore | Where-Object {$_.id -ieq $saved.id})[0].before
            $current=Get-ExternalNetworkRaw $saved.id
            $progress=Get-PropertyValue $saved 'restoreProgress'
            if((Get-ExternalNetworkSignature $current 'Nsg') -ceq (Get-ExternalNetworkSignature $before 'Nsg')){
                if($progress){$progress.status='RESTORED';Save-Ledger};continue
            }
            if($progress -and $progress.status -eq 'PENDING'){Complete-ExternalNsgRuleRestore $saved $before;$progress=$saved.restoreProgress}
            if($progress -and $progress.status -eq 'RESTORED'){continue}
            $expected=if($progress){Copy-ExternalNetworkValue $progress.after}else{Copy-ExternalNetworkValue $saved.after}
            if((Get-ExternalNetworkSignature (Get-ExternalNetworkRaw $saved.id) 'Nsg') -cne (Get-ExternalNetworkSignature $expected 'Nsg')){throw 'NSG changed since validated After/checkpoint; preserved.'}
            $added=@($expected.properties.securityRules | Where-Object {$rule=$_;@($before.properties.securityRules | Where-Object {$_.name -ieq $rule.name}).Count -eq 0})
            foreach($rule in $added){
                if(-not (Test-DocumentedDbrNetworkRule $rule $saved.id)){throw 'Unproven DBR rule deletion refused.'}
                $current=Get-ExternalNetworkRaw $saved.id
                if((Get-ExternalNetworkSignature $current 'Nsg') -cne (Get-ExternalNetworkSignature $expected 'Nsg')){throw 'NSG drift during guarded rule cleanup; preserved.'}
                $after=Copy-ExternalNetworkValue $expected;$after.properties.securityRules=@($after.properties.securityRules | Where-Object {$_.name -ine $rule.name})
                $saved | Add-Member -MemberType NoteProperty -Name restoreProgress -Value ([pscustomobject]@{ruleId=$rule.id;before=(Copy-ExternalNetworkValue $expected);after=$after;status='PENDING'}) -Force
                Save-Ledger
                Complete-ExternalNsgRuleRestore $saved $before
                if($saved.restoreProgress.status -eq 'RESTORED'){break}
                $expected=Copy-ExternalNetworkValue $saved.restoreProgress.after
            }
            if((Get-ExternalNetworkSignature (Get-ExternalNetworkRaw $saved.id) 'Nsg') -cne (Get-ExternalNetworkSignature $before 'Nsg')){throw 'Original NSG configuration not restored.'}
        }
    }
    Read-ExistingNetworks
}

function Build-Plan {
    $keys = @()
     $skipped=@()
    foreach ($type in @($script:Template.metadata.fixtureTypes)) {
        if ((Get-PropertyValue $type 'optionalSwitch') -eq 'IncludeAse' -and -not $IncludeAse) { $skipped += [pscustomobject]@{resourceType=$type.resourceType
        reason='ASE optional: explicit IncludeAse required after price review'}
        continue }
        if ($type.feasibility -eq 'skip-proposed') { $skipped += [pscustomobject]@{resourceType=$type.resourceType
        reason=$type.reason}
         continue }
        if ($SkipTypes -contains $type.resourceType) { $skipped += [pscustomobject]@{resourceType=$type.resourceType
        reason='Explicit SkipTypes user setting'}
         continue }
        if ($type.feasibility -eq 'conditional' -and -not $IncludeConditional) { $skipped += [pscustomobject]@{resourceType=$type.resourceType
        reason='Conditional: opt-in and reviewed cost/availability required'}
        continue }
        $keys += @($type.keys)
    }
    # 依存閉包は metadata から得ます。SkipTypes と矛盾する親を黙って有効化しません。
    do {
        $before=@($keys | Sort-Object -Unique).Count
        foreach ($resource in @($script:Template.resources)) {
            $fixture=Get-PropertyValue $resource.metadata 'fixture'
            if ($fixture -and $keys -contains $fixture.key) {
                foreach ($dependency in @($fixture.dependsOnKeys)) { $keys += $dependency }
            }
        }
        $keys=@($keys | Sort-Object -Unique)
    } while ($keys.Count -gt $before)
    foreach ($type in @($script:Template.metadata.fixtureTypes)) {
        if ($SkipTypes -contains $type.resourceType -and @($type.keys | Where-Object {$keys -contains $_}).Count -gt 0) { throw ('Skipped type required by dependency: '+$type.resourceType) }
    }
    $bundles=@()
    foreach ($bundle in @(@{key='A-R1'
    sub=$SubscriptionIdA
    location=$PrimaryLocation},@{key='A-R3'
    sub=$SubscriptionIdA
    location=$ThirdLocation},@{key='B-R2'
    sub=$SubscriptionIdB
    location=$SecondaryLocation},@{key='B-R4'
    sub=$SubscriptionIdB
    location=$FourthLocation})) {
        $reason='Proposed design region; live SKU/quota/region validation pending'
        if ($BundleLocationOverrides.ContainsKey($bundle.key)) {
            $override=$BundleLocationOverrides[$bundle.key]
            if (-not $override.Location -or -not $override.Reason) { throw 'Each region override needs Location and Reason.' }
            $bundle.location=$override.Location
             $reason=$override.Reason
        }
        $bundleKeys=@($script:Template.resources | Where-Object {$_.metadata.fixture.bundle -eq $bundle.key -and $keys -contains $_.metadata.fixture.key} | ForEach-Object {$_.metadata.fixture.key} | Sort-Object -Unique)
        if($keys -contains 'networkVnet' -and $bundle.key -in @('A-R1','B-R2')){$bundleKeys += 'networkVnet'}
        $bundles += [pscustomobject]@{
            key=$bundle.key
            subscriptionId=$bundle.sub
            location=$bundle.location
            regionReason=$reason
            resourceGroup=('fx-'+$RunId+'-'+$bundle.key.ToLowerInvariant())
            keys=@($bundleKeys | Sort-Object -Unique)
        }
    }
    return [pscustomobject]@{
        schemaVersion=1
        runId=$RunId
        templateSha256=(Get-FileHash -LiteralPath $script:TemplatePath -Algorithm SHA256).Hash
        scriptSha256=(Get-FileHash -LiteralPath $script:ScriptPath -Algorithm SHA256).Hash
        subscriptionIds=@($SubscriptionIdA,$SubscriptionIdB)
        budgetJPY=$BudgetJPY
        maxLifetimeHours=$MaxLifetimeHours
        includeConditional=[bool]$IncludeConditional
        includeAse=[bool]$IncludeAse
        selectedKeys=$keys
        existingNetworks=@($ExistingNetworkConfiguration)
        skipped=$skipped
        bundles=$bundles
        resourceTypeCount=@($script:Template.metadata.fixtureTypes).Count
        azureActionsPerformed=$false
        status='LOCAL_PLAN_ONLY'
        limitations=@('SKU/region/quota and conditional creation are unverified until live deployment.','No billing hard cap.','Generic6 F1/F2/rollback orchestration is separate; expected scopes are never product input.')
    }
}
function Capture-InitialState {
    $parents=Get-ApiPages -Id '/providers/Microsoft.Management/getEntities' -ApiVersion '2020-05-01' -Method POST
    foreach ($sub in @($SubscriptionIdA,$SubscriptionIdB)) {
        $script:CurrentSubscription=$sub
        $entity=@($parents | Where-Object {$_.name -eq $sub -or $_.id -eq ('/subscriptions/'+$sub)})
        if ($entity.Count -ne 1 -or -not $entity[0].properties.parent.id) { throw ('Cannot capture original management-group parent: '+$sub) }
        $script:Ledger.subscriptionParents += [pscustomobject]@{subscriptionId=$sub
        parentId=$entity[0].properties.parent.id
        restoreStatus='NOT_MOVED'}
        $providers=Get-ApiPages -Id ('/subscriptions/'+$sub+'/providers') -ApiVersion '2021-04-01'
        $groups=Get-ApiPages -Id ('/subscriptions/'+$sub+'/resourcegroups') -ApiVersion '2022-09-01'
        $resources=Get-ApiPages -Id ('/subscriptions/'+$sub+'/resources') -ApiVersion '2021-04-01'
        $exemptions=Get-ApiPages -Id ('/subscriptions/'+$sub+'/providers/Microsoft.Authorization/policyExemptions') -ApiVersion '2022-07-01-preview'
        $assignments=Get-ApiPages -Id ('/subscriptions/'+$sub+'/providers/Microsoft.Authorization/policyAssignments') -ApiVersion '2022-06-01'
        $roles=Get-ApiPages -Id ('/subscriptions/'+$sub+'/providers/Microsoft.Authorization/roleAssignments') -ApiVersion '2022-04-01'
        $script:Ledger.initialState += [pscustomobject]@{
            subscriptionId=$sub
            providers=@($providers | Select-Object namespace,registrationState)
            groupIds=@($groups | ForEach-Object {$_.id})
            resourceIds=@($resources | ForEach-Object {$_.id})
            policyExemptionIds=@($exemptions | ForEach-Object {$_.id})
            policyAssignmentIds=@($assignments | ForEach-Object {$_.id})
            roleAssignmentIds=@($roles | ForEach-Object {$_.id})
        }
        Save-Ledger
    }
    $uniqueParents=@($script:Ledger.subscriptionParents | ForEach-Object {$_.parentId} | Sort-Object -Unique)
    if (-not $ManagementGroupParentId) {
        if ($uniqueParents.Count -ne 1) { throw 'Subscriptions have different parents. Set ManagementGroupParentId explicitly.' }
        $script:Ledger.managementGroupParentId=$uniqueParents[0]
    } else { $script:Ledger.managementGroupParentId=$ManagementGroupParentId }
    $null=Invoke-Api -Method GET -Id $script:Ledger.managementGroupParentId -ApiVersion '2020-05-01'
    # 作成前に同名RG/MGなしを確認。元資源を再利用しません。
    foreach ($bundle in $script:Ledger.plan.bundles) {
        $initial=@($script:Ledger.initialState | Where-Object {$_.subscriptionId -eq $bundle.subscriptionId})[0]
        $id='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup
        if (@($initial.groupIds | Where-Object {$_ -ieq $id}).Count -gt 0) { throw ('Existing resource group collision: '+$id) }
        foreach($resource in @($script:Template.resources | Where-Object {$_.metadata.fixture.bundle -eq $bundle.key -and $bundle.keys -contains $_.metadata.fixture.key})) {
            $managedName=Get-PropertyValue $resource.metadata.fixture 'managedResourceGroupNameTemplate' ''
            if($managedName) {
                $managedId='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$managedName.Replace('{runId}',$RunId)
                if(@($initial.groupIds | Where-Object {$_ -ieq $managedId}).Count -gt 0){throw ('Existing managed RG collision: '+$managedId)}
            }
        }
    }
    $existing=Invoke-Api -Method GET -Id $script:Ledger.managementGroupId -ApiVersion '2020-05-01' -MayFail
    if ($existing.ok -or $existing.code -notin @('ManagementGroupNotFound','ResourceNotFound','NotFound')) { throw 'Management-group name unavailable or existence unresolved.' }
    Read-ExistingNetworks -CaptureBefore
    $script:Ledger.initialCaptureComplete=$true
     Save-Ledger
}
function Get-PlanFingerprint {
    param($Plan)
    return (ConvertTo-Json -InputObject ([ordered]@{
        runId=$Plan.runId
        templateSha256=$Plan.templateSha256
        scriptSha256=$Plan.scriptSha256
        subscriptionIds=$Plan.subscriptionIds
        maxLifetimeHours=$Plan.maxLifetimeHours
        includeConditional=$Plan.includeConditional
        includeAse=$Plan.includeAse
        selectedKeys=$Plan.selectedKeys
        skipped=$Plan.skipped
        bundles=$Plan.bundles
        existingNetworks=$Plan.existingNetworks
    }) -Depth 100 -Compress)
}
function Build-ExpectedResources {
    param($Plan)
    $expected=@()
    foreach($resource in $script:Template.resources) {
        $fixture=$resource.metadata.fixture
        $bundle=@($Plan.bundles | Where-Object {$_.key -eq $fixture.bundle})[0]
        if($bundle.keys -notcontains $fixture.key){continue}
        $name=$fixture.nameTemplate.Replace('{runId}',$RunId)
        $segments=$resource.type -split '/'
        $names=$name -split '/'
        if($names.Count -ne $segments.Count-1){throw 'Template exact-name metadata does not match resource type.'}
        $id='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup+'/providers/'+$segments[0]
        for($i=0;$i -lt $names.Count;$i++){$id+='/'+$segments[$i+1]+'/'+$names[$i]}
        $location=if((Get-PropertyValue $resource 'location') -eq 'global'){'global'}else{$bundle.location}
        $expected += [pscustomobject]@{
            id=$id
            key=$fixture.key
            resourceType=$resource.type.ToLowerInvariant()
            apiVersion=$resource.apiVersion
            childApiVersion=$fixture.childApiVersion
            location=$location
            role=$fixture.role
            managedResourceGroupNameTemplate=(Get-PropertyValue $fixture 'managedResourceGroupNameTemplate' '')
            scopeSuffixes=@($fixture.scopeSuffixes)
            seedSourceDiagnostic=$fixture.seedSourceDiagnostic
            cleanupEarly=[bool](Get-PropertyValue $fixture 'cleanupEarly' $false)
        }
    }
    return $expected
}
function Register-RequiredProviders {
    foreach ($sub in @($SubscriptionIdA,$SubscriptionIdB)) {
        $script:CurrentSubscription=$sub
        $needed=@('Microsoft.Insights','Microsoft.OperationalInsights','Microsoft.Resources')
        foreach ($bundle in @($script:Ledger.plan.bundles | Where-Object {$_.subscriptionId -eq $sub})) {
            $needed += @($script:Template.resources | Where-Object {$bundle.keys -contains $_.metadata.fixture.key} | ForEach-Object {($_.type -split '/')[0]})
        }
        $baseline=@($script:Ledger.initialState | Where-Object {$_.subscriptionId -eq $sub})[0]
        foreach ($namespace in @($needed | Sort-Object -Unique)) {
            $old=@($baseline.providers | Where-Object {$_.namespace -ieq $namespace})
            if ($old.Count -ne 1) { throw ('Provider baseline missing: '+$namespace) }
            if ($old[0].registrationState -eq 'Registered') { continue }
            $id='/subscriptions/'+$sub+'/providers/'+$namespace
            $null=Invoke-Api -Method POST -Id ($id+'/register') -ApiVersion '2021-04-01' -Body @{} -Purpose 'Register required RP'
            $deadline=[DateTime]::UtcNow.AddMinutes(20)
            do {
                $state=(Invoke-Api -Method GET -Id $id -ApiVersion '2021-04-01').value.registrationState
                if ($state -eq 'Registered') { break }
                if ([DateTime]::UtcNow -gt $deadline) { throw ('Provider registration timeout: '+$namespace) }
                Start-Sleep -Seconds 10
            } while ($true)
        }
    }
}
function Invoke-ManagementFixtureRequest {
    param([string]$Id,[string]$ApiVersion,$Body,[string]$Purpose)
    # 新規MG・ポリシーの反映待ち。既知の未反映だけを5秒間隔・最大60回再試行します。
    $notReady=@('NotFound','ResourceNotFound','ManagementGroupNotFound','PolicyDefinitionNotFound','PolicySetDefinitionNotFound','PolicyAssignmentNotFound')
    $accepted=$false
    for($attempt=0;$attempt -lt 60;$attempt++){
        if(-not $accepted){
            $response=Invoke-Api -Method PUT -Id $Id -ApiVersion $ApiVersion -Body $Body -Purpose $Purpose -MayFail
            if(-not $response.ok -and $response.code -notin $notReady){throw ('Management fixture PUT failed: '+$response.code)}
            $accepted=$response.ok
        }
        if($accepted){
            $response=Invoke-Api -Method GET -Id $Id -ApiVersion $ApiVersion -MayFail
            if($response.ok){
                if($null -eq $response.value){throw 'Malformed management fixture GET response.'}
                return
            }
            if($response.code -notin $notReady){throw ('Management fixture GET failed: '+$response.code)}
        }
        if($attempt -lt 59){Start-Sleep -Seconds 5}
    }
    throw ('Management fixture propagation timed out: '+$Id+' / '+$response.code)
}
function Create-ManagementFixture {
    $mg=$script:Ledger.managementGroupId
    $before=Invoke-Api -Method GET -Id $mg -ApiVersion '2020-05-01' -MayFail
    if($before.ok -or $before.code -notin @('ManagementGroupNotFound','ResourceNotFound','NotFound')){throw 'MG creation collision or unresolved existence.'}
    Invoke-ManagementFixtureRequest -Id $mg -ApiVersion '2020-05-01' -Body @{properties=@{displayName=('Fixture '+$RunId)
    details=@{parent=@{id=$script:Ledger.managementGroupParentId}}}} -Purpose 'Create run MG'
    foreach ($parent in $script:Ledger.subscriptionParents) {
        $parent.restoreStatus='MOVE_INTENT'
        Save-Ledger
        Invoke-ManagementFixtureRequest -Id ($mg+'/subscriptions/'+$parent.subscriptionId) -ApiVersion '2020-05-01' -Body @{} -Purpose 'Move subscription to run MG'
        $parent.restoreStatus='RESTORE_REQUIRED'
        Save-Ledger
    }
    $definition=$mg+'/providers/Microsoft.Authorization/policyDefinitions/fx-audit'
    $initiative=$mg+'/providers/Microsoft.Authorization/policySetDefinitions/fx-initiative'
    Invoke-ManagementFixtureRequest -Id $definition -ApiVersion '2023-04-01' -Body @{
        properties=@{displayName='Fixture audit'
    policyType='Custom'
    mode='All'
    policyRule=@{if=@{field='type'
    equals='Microsoft.Storage/storageAccounts'}
    then=@{effect='audit'}}}
    } -Purpose 'Create harmless policy definition'
    $definitions=@($script:Template.metadata.policyReferenceIds | ForEach-Object {@{policyDefinitionId=$definition
    policyDefinitionReferenceId=$_}})
    Invoke-ManagementFixtureRequest -Id $initiative -ApiVersion '2023-04-01' -Body @{properties=@{displayName='Fixture references'
    policyType='Custom'
    policyDefinitions=$definitions}} -Purpose 'Create initiative'
    $assignmentIndex=0
    foreach ($name in $script:Template.metadata.policyAssignmentNames) {
        $definitionId=if($assignmentIndex -eq 2){$initiative}else{$definition}
        Invoke-ManagementFixtureRequest -Id ($mg+'/providers/Microsoft.Authorization/policyAssignments/'+$name) -ApiVersion '2022-06-01' -Body @{properties=@{displayName='Fixture shared assignment'
        policyDefinitionId=$definitionId
        enforcementMode='DoNotEnforce'}} -Purpose 'Create shared policy assignment'
        $assignmentIndex++
    }
}
function New-RandomPassword {
    $bytes=New-Object byte[] 32
    $rng=[Security.Cryptography.RandomNumberGenerator]::Create()
    try {$rng.GetBytes($bytes)} finally {$rng.Dispose()}
    return ('Az9!'+[Convert]::ToBase64String($bytes))
}
function Invoke-BundleDeployment {
    param($Bundle,[string[]]$Keys,[string]$Phase,[switch]$NoWait)
    Assert-RunWindow
    if ($Keys.Count -eq 0) { return }
    $script:CurrentSubscription=$Bundle.subscriptionId
    foreach($resource in @($script:Template.resources | Where-Object {$_.metadata.fixture.bundle -eq $Bundle.key -and $Keys -contains $_.metadata.fixture.key})) {
        $managedName=Get-PropertyValue $resource.metadata.fixture 'managedResourceGroupNameTemplate' ''
        if($managedName) {
            $managedId='/subscriptions/'+$Bundle.subscriptionId+'/resourceGroups/'+$managedName.Replace('{runId}',$RunId)
            $before=Invoke-Api -Method GET -Id $managedId -ApiVersion '2022-09-01' -MayFail
            if($before.ok -or $before.code -notin @('ResourceGroupNotFound','ResourceNotFound','NotFound')){throw 'Managed RG collision or unresolved existence before root deployment.'}
        }
    }
    $networkRefs=@{}
    foreach($network in $script:Ledger.existingNetworks){
        $subnetRefs=@{}
        foreach($role in $ExistingSubnetNames.Keys){$subnetRefs[$role]=@{id=$network.subnets.$role.id;name=$network.subnets.$role.name}}
        $networkRefs[$network.role]=@{vnetId=$network.vnetId;subnets=$subnetRefs}
    }
    $parameters=@{
        networkRefs=@{value=$networkRefs}
        runId=@{value=$RunId}
        bundle=@{value=$Bundle.key}
        location=@{value=$Bundle.location}
        tenantId=@{value=$script:Ledger.tenantId}
        enabledKeys=@{value=@($Keys)}
        sourceWorkspaceId=@{value=$script:Ledger.sourceWorkspaceId}
        sharedStorageId=@{value=$script:Ledger.sharedStorageId}
        adminPassword=@{value=(New-RandomPassword)}
        adminSshPublicKey=@{value=$AdminSshPublicKey}
        publisherEmail=@{value=$PublisherEmail}
    }
    foreach ($parameter in $script:Template.parameters.PSObject.Properties) {
        if (-not $parameters.ContainsKey($parameter.Name) -and $null -eq $parameter.Value.PSObject.Properties['defaultValue']) { throw ('Required template parameter not supplied: '+$parameter.Name) }
    }
    $file=New-PrivateJsonFile -Value $parameters
    $deploymentName='fx-'+$RunId+'-'+$Phase
    $id='/subscriptions/'+$Bundle.subscriptionId+'/resourceGroups/'+$Bundle.resourceGroup+'/providers/Microsoft.Resources/deployments/'+$deploymentName
    $entry=Add-Operation -Method PUT -Id $id -ApiVersion '2022-09-01' -Purpose ('ARM '+$Bundle.key+' '+$Phase)
    try {
        # 秘密paramsのhash/本文は成果物にしません。templateと非秘密planのみhashを保持。
        $arguments=@('deployment','group','create','--subscription',$Bundle.subscriptionId,'--resource-group',$Bundle.resourceGroup,'--name',$deploymentName,'--mode','Incremental','--template-file',$script:TemplatePath,'--parameters',('@'+$file))
        if($NoWait){$arguments += '--no-wait'}
        $result=Invoke-AzJson -Arguments $arguments -MayFail
        if (-not $result.ok) { $entry.status='FAILED'
        $entry.errorCode=$result.code
        Save-Ledger
        throw ('ARM deployment failed: '+$result.code) }
        $ticket=[pscustomobject]@{
            id=$id
            subscriptionId=$Bundle.subscriptionId
            operationSequence=$entry.sequence
            state=if($NoWait){'SUBMITTED'}else{$result.value.properties.provisioningState}
        }
        $script:Ledger.deployments += $ticket
        $entry.status=if($NoWait){'SUBMITTED'}else{'ACCEPTED'}
        Save-Ledger
        if($NoWait){return $ticket}
        Complete-BundleDeployment -Ticket $ticket -Deployment $result.value
        if($ticket.state -ne 'Succeeded'){throw 'ARM provisioning state is not Succeeded.'}
    } finally { Remove-Item -LiteralPath $file -Force -ErrorAction SilentlyContinue
     $parameters=$null }
}
function Complete-BundleDeployment {
    param($Ticket,$Deployment)
    $Ticket.state=$Deployment.properties.provisioningState
    $entry=$script:Ledger.operations[$Ticket.operationSequence]
    $entry.status=if($Ticket.state -eq 'Succeeded'){'SUCCEEDED'}else{'FAILED'}
    $entry.finishedUtc=[DateTime]::UtcNow.ToString('o')
    Save-Ledger
    if($Ticket.state -eq 'Succeeded') {
        foreach($row in @($Deployment.properties.outputs.fixtureResources.value | Where-Object {$null -ne $_})) {
            if(@($script:Ledger.resources | Where-Object {$_.id -ieq $row.id}).Count -eq 0){$script:Ledger.resources += $row}
            if($row.role -eq 'source-workspace'){$script:Ledger.sourceWorkspaceId=$row.id}
            if($row.key -eq 'storage'){$script:Ledger.sharedStorageId=$row.id}
        }
    }
    $script:CurrentSubscription=$Ticket.subscriptionId
    # request/response本文を保存せず、成功・部分失敗どちらもoperationのexactIDを回収します。
    foreach($operation in @(Get-ApiPages -Id ($Ticket.id+'/operations') -ApiVersion '2022-09-01')) {
        $target=Get-PropertyValue $operation.properties 'targetResource'
        if($target -and $target.id){$script:Ledger.observedWriteIds += $target.id}
    }
    Save-Ledger
}
function Wait-BundleDeployments {
    param([object[]]$Tickets)
    # 独立した3bundleを投入済みの状態で、exact deployment IDを順番にpollします。
    do {
        $pending=@($Tickets | Where-Object {$_.state -notin @('Succeeded','Failed','Canceled')})
        if($pending.Count -eq 0){break}
        foreach($ticket in $pending) {
            $script:CurrentSubscription=$ticket.subscriptionId
            $deployment=(Invoke-Api -Method GET -Id $ticket.id -ApiVersion '2022-09-01').value
            $ticket.state=$deployment.properties.provisioningState
            if($ticket.state -in @('Succeeded','Failed','Canceled')){Complete-BundleDeployment -Ticket $ticket -Deployment $deployment}
        }
        Save-Ledger
        if(@($Tickets | Where-Object {$_.state -notin @('Succeeded','Failed','Canceled')}).Count -gt 0){Start-Sleep -Seconds 15}
        Assert-RunWindow
    }while($true)
    if(@($Tickets | Where-Object {$_.state -ne 'Succeeded'}).Count -gt 0){throw 'One or more exact ARM deployments failed; inspect run ledger and use Cleanup.'}
}
function Capture-OwnedInventory {
    param([switch]$ForCleanup)
    $script:Ledger.unexpectedVnetDifferences=@()
    # サービスのmanaged RGを含め、顧客サブスクリプションのVNetが増えていないことを確認します。
    foreach($initial in $script:Ledger.initialState){
        $script:CurrentSubscription=$initial.subscriptionId
        $now=@(Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resources') -ApiVersion '2021-04-01' | Where-Object {$_.type -ieq 'Microsoft.Network/virtualNetworks'} | ForEach-Object {$_.id} | Sort-Object -Unique)
        $before=@($initial.resourceIds | Where-Object {$_ -match '/providers/Microsoft.Network/virtualNetworks/[^/]+$'} | Sort-Object -Unique)
        if(($now -join "`n") -ine ($before -join "`n")){$script:Ledger.unexpectedVnetDifferences += [pscustomobject]@{subscriptionId=$initial.subscriptionId;before=$before;current=$now};Save-Ledger;if(-not $ForCleanup){throw 'Virtual network inventory changed; existing networks are preserved.'}}
    }
    # 完了・失敗どちらでも、専用RGとmanagedRGの実在庫をexactID台帳へ結合。
    foreach ($bundle in $script:Ledger.plan.bundles) {
        $script:CurrentSubscription=$bundle.subscriptionId
        $groupId='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup
        $group=Invoke-Api -Method GET -Id $groupId -ApiVersion '2022-09-01' -MayFail
        if (-not $group.ok -and $group.code -in @('ResourceGroupNotFound','ResourceNotFound','NotFound')) { continue }
        if (-not $group.ok) { throw ('RG inventory unresolved: '+$group.code) }
        if ((Get-PropertyValue (Get-PropertyValue $group.value 'tags') 'fixtureRun') -cne $RunId) { throw ('RG ownership mismatch: '+$groupId) }
        $inventory=Get-ApiPages -Id ($groupId+'/resources') -ApiVersion '2021-04-01'
        foreach ($item in $inventory) {
            if (@($script:Ledger.inventory | Where-Object {$_.id -ieq $item.id}).Count -eq 0) {
                $script:Ledger.inventory += [pscustomobject]@{
                    id=$item.id
                    type=$item.type
                    name=$item.name
                    location=(Get-PropertyValue $item 'location' 'global')
                    ownership='EXCLUSIVE_NEW_RUN_RG'
                    status='OBSERVED'
                }
            }
        }
    }
    foreach ($root in @($script:Ledger.resources | Where-Object {$_.resourceType -in @('microsoft.containerservice/managedclusters','microsoft.databricks/workspaces','microsoft.monitor/accounts','microsoft.compute/virtualmachines','microsoft.network/privateendpoints')})) {
        $script:CurrentSubscription=($root.id -split '/')[2]
        $response=Invoke-Api -Method GET -Id $root.id -ApiVersion $root.apiVersion -MayFail
        if (-not $response.ok -and $response.code -in @('ResourceGroupNotFound','ResourceNotFound','NotFound')) { continue }
        if (-not $response.ok) { throw ('Root inventory unresolved: '+$response.code) }
        $properties=$response.value.properties
        $managedIds=@()
        $nodeRg=Get-PropertyValue $properties 'nodeResourceGroup'
        $managedRg=Get-PropertyValue $properties 'managedResourceGroupId'
        $defaultIngestion=Get-PropertyValue $properties 'defaultIngestionSettings'
        $monitorDcr=Get-PropertyValue $defaultIngestion 'dataCollectionRuleResourceId'
        $monitorDce=Get-PropertyValue $defaultIngestion 'dataCollectionEndpointResourceId'
        $monitorRg=Get-PropertyValue $defaultIngestion 'resourceGroup'
        foreach($monitorChild in @($monitorDcr,$monitorDce)) {
            if($monitorChild -match '^(/subscriptions/[^/]+/resourceGroups/[^/]+)/') {$managedIds += $Matches[1]}
        }
        if ($nodeRg) {$managedIds += '/subscriptions/'+(($root.id -split '/')[2])+'/resourceGroups/'+$nodeRg}
        if ($managedRg) {$managedIds += $managedRg}
        if ($monitorRg) {$managedIds += $monitorRg}
        foreach ($managedId in @($managedIds | Sort-Object -Unique)) {
            if (-not $managedId.StartsWith('/subscriptions/')) { $managedId='/subscriptions/'+(($root.id -split '/')[2])+'/resourceGroups/'+$managedId }
            $baseline=@($script:Ledger.initialState | Where-Object {$_.subscriptionId -eq (($root.id -split '/')[2])})[0]
            if (@($baseline.groupIds | Where-Object {$_ -ieq $managedId}).Count -gt 0) { throw 'Managed RG collided with an existing group.' }
            if (@($script:Ledger.managedGroups | Where-Object {$_.id -ieq $managedId}).Count -eq 0) { $script:Ledger.managedGroups += [pscustomobject]@{id=$managedId
            parentId=$root.id
            parentApiVersion=$root.apiVersion
            status='PARENT_OWNED'} }
            $managedInventory=Get-ApiPages -Id ($managedId+'/resources') -ApiVersion '2021-04-01'
            foreach ($item in $managedInventory) { $script:Ledger.observedWriteIds += $item.id }
        }
        # VM OS disk/PE NICをproviderから実測し記録。親削除後に exactID の消失を確認します。
        $storage=Get-PropertyValue $properties 'storageProfile'
        $osDisk=Get-PropertyValue $storage 'osDisk'
        $managedDisk=Get-PropertyValue $osDisk 'managedDisk'
        $osId=Get-PropertyValue $managedDisk 'id'
        if ($osId) {$script:Ledger.autoChildIds += [pscustomobject]@{id=$osId
        apiVersion='2024-03-02'
        kind='VM_OS_DISK'
        parentId=$root.id}}
        foreach ($nic in @(Get-PropertyValue $properties 'networkInterfaces' @())) { if($nic.id){$script:Ledger.autoChildIds += [pscustomobject]@{id=$nic.id
        apiVersion='2024-05-01'
        kind='PE_NIC'
        parentId=$root.id}} }
    }
    $script:Ledger.observedWriteIds=@($script:Ledger.observedWriteIds | Sort-Object -Unique)
    Save-Ledger
}
function Capture-Scopes {
    $scopes=@()
    $external=@()
    if($script:Ledger.plan.selectedKeys -contains 'networkVnet'){
        foreach($network in $script:Ledger.existingNetworks){$external += [pscustomobject]@{id=$network.vnetId;resourceType='microsoft.network/virtualNetworks';location=$network.networkBefore.location;apiVersion='2024-05-01';childApiVersion='2024-05-01';scopeSuffixes=@();seedSourceDiagnostic=$true;ownership='EXTERNAL_EXISTING_NETWORK'}}
    }
    foreach ($resource in @($script:Ledger.resources)+$external) {
        foreach ($suffix in @('')+@($resource.scopeSuffixes)) {
            $id=$resource.id+$suffix
            if (@($scopes | Where-Object {$_.resourceId -ieq $id}).Count -gt 0) {continue}
            $script:CurrentSubscription=($id -split '/')[2]
            $api=if($suffix -eq ''){$resource.apiVersion}else{$resource.childApiVersion}
            $exists=Invoke-Api -Method GET -Id $id -ApiVersion $api -MayFail
            $scope=[pscustomobject]@{
                resourceId=$id
                ownership=(Get-PropertyValue $resource 'ownership' 'EXCLUSIVE_NEW_RUN_RG')
                parentType=$resource.resourceType
                actualLocation=$resource.location
                provenance=if($suffix){'KNOWN_CHILD_SCOPE'}else{'INDEPENDENT_PLANNED_EXACT_ID'}
                exists=$exists.ok
                existenceErrorCode=$exists.code
                apiVersion=$api
                categoryResponse=$null
                attemptedBody=$null
                actualStatus='UNRESOLVED'
                actualErrorCode=$null
                sourceSeeded=$false
                excludedReason=$null
                sourceBefore=$null
                seedSourceDiagnostic=$resource.seedSourceDiagnostic
                destinationModeCapability='UNMEASURED'
                storageDestinationCapability='UNMEASURED'
            }
            if ($exists.ok) {
                $categories=Invoke-Api -Method GET -Id ($id+'/providers/Microsoft.Insights/diagnosticSettingsCategories') -ApiVersion '2021-05-01-preview' -MayFail
                $scope.categoryResponse=$categories.value
                $scope.actualErrorCode=$categories.code
                if ($categories.ok) {$scope.actualStatus='CATEGORIES_ONLY'}
                elseif ($categories.code -in @('ResourceTypeNotSupported','UnsupportedResourceType','DiagnosticSettingsNotSupported')) {$scope.actualStatus='EXPECTED_UNSUPPORTED'
                $scope.excludedReason='Explicit diagnostic API unsupported code; no migration PASS'}
            }
            $scopes += $scope
        }
    }
    Write-JsonFile -Path (Join-Path $script:RunPath 'expected-scopes.json') -Value $scopes
    $script:Ledger.scopes=$scopes
     Save-Ledger
    return $scopes
}
function Capture-OwnedExtensions {
    $script:Ledger.externalDifferences=@()
    $ownedGroupIds=@($script:Ledger.plan.bundles | ForEach-Object {'/subscriptions/'+$_.subscriptionId+'/resourceGroups/'+$_.resourceGroup})+@($script:Ledger.managedGroups | ForEach-Object {$_.id})
    $ownedIds=@($script:Ledger.inventory | ForEach-Object {$_.id})+@($script:Ledger.scopes | Where-Object {$_.exists -and $_.ownership -ne 'EXTERNAL_EXISTING_NETWORK'} | ForEach-Object {$_.resourceId})
    foreach($resourceId in @($ownedIds | Sort-Object -Unique)) {
        $script:CurrentSubscription=($resourceId -split '/')[2]
        $list=Invoke-Api -Method GET -Id ($resourceId+'/providers/Microsoft.Insights/diagnosticSettings') -ApiVersion '2021-05-01-preview' -MayFail
        if($list.ok) {
            foreach($setting in @(Get-PropertyValue $list.value 'value' @())) {
                if(@($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $setting.id}).Count -eq 0) {$script:Ledger.extensionInventory += [pscustomobject]@{id=$setting.id
                apiVersion='2021-05-01-preview'
                kind='DIAGNOSTIC'
                ownership='EXCLUSIVE_NEW_RUN_RG'}}
            }
        } elseif($list.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound','ResourceTypeNotSupported','UnsupportedResourceType','DiagnosticSettingsNotSupported')) {
            throw ('Diagnostic inventory unresolved: '+$list.code)
        }
        if($resourceId -match '/providers/Microsoft.Compute/(virtualMachines|virtualMachineScaleSets)/[^/]+$') {
            $associations=Get-ApiPages -Id ($resourceId+'/providers/Microsoft.Insights/dataCollectionRuleAssociations') -ApiVersion '2023-03-11'
            foreach($association in $associations) {
                if(@($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $association.id}).Count -eq 0) {$script:Ledger.extensionInventory += [pscustomobject]@{id=$association.id
                apiVersion='2023-03-11'
                kind='DCRA'
                ownership='EXCLUSIVE_NEW_RUN_RG'}}
            }
        }

    }
    foreach($initial in $script:Ledger.initialState) {
        $script:CurrentSubscription=$initial.subscriptionId
        $exemptions=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/providers/Microsoft.Authorization/policyExemptions') -ApiVersion '2022-07-01-preview'
        foreach($exemption in $exemptions) {
            if($exemption.properties.policyAssignmentId.StartsWith($script:Ledger.managementGroupId+'/providers/Microsoft.Authorization/policyAssignments/') -and $initial.policyExemptionIds -notcontains $exemption.id) {
                if(@($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $exemption.id}).Count -eq 0) {$script:Ledger.extensionInventory += [pscustomobject]@{id=$exemption.id
                apiVersion='2022-07-01-preview'
                kind='POLICY_EXEMPTION'
                ownership='NEW_RUN_MG_ASSIGNMENT'}}
            }
        }
        # 専用RG外の新資源/roleは推測削除しません。自動生成・並行作業の区別を残存として出します。
        $now=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resources') -ApiVersion '2021-04-01'
        $foreignNetwork=@()
        foreach($networkItem in @($now | Where-Object {$_.type -like 'Microsoft.Network/*' -and $_.type -ine 'Microsoft.Network/networkWatchers'})) {
            if(@($ownedGroupIds | Where-Object {$networkItem.id.StartsWith($_+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -eq 0){$foreignNetwork += $networkItem.id}
        }
        $roles=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/providers/Microsoft.Authorization/roleAssignments') -ApiVersion '2022-04-01'
        $assignments=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/providers/Microsoft.Authorization/policyAssignments') -ApiVersion '2022-06-01'
        foreach($assignment in $assignments) {
            if($initial.policyAssignmentIds -contains $assignment.id){continue}
            $exactSecurityId='/subscriptions/'+$initial.subscriptionId+'/providers/Microsoft.Authorization/policyAssignments/SecurityCenterBuiltIn'
            $fresh=Invoke-Api -Method GET -Id $assignment.id -ApiVersion '2022-06-01'
            $properties=$fresh.value.properties
            $metadata=Get-PropertyValue $properties 'metadata'
            $systemData=Get-PropertyValue $fresh.value 'systemData'
            $created=Get-PropertyValue $systemData 'createdAt' ''
            $modified=Get-PropertyValue $systemData 'lastModifiedAt' ''
            $parameters=Get-PropertyValue $properties 'parameters'
            $parametersEmpty=$null -eq $parameters -or @($parameters.PSObject.Properties).Count -eq 0
            $initialSecurity=@($initial.providers | Where-Object {$_.namespace -ieq 'Microsoft.Security'})
            $autoOwned=$assignment.id -ieq $exactSecurityId -and
                $initialSecurity.Count -eq 1 -and
                $initialSecurity[0].registrationState -in @('NotRegistered','Unregistered') -and
                (Get-PropertyValue $metadata 'assignedBy') -eq 'Security Center' -and
                $properties.policyDefinitionId -ieq '/providers/Microsoft.Authorization/policySetDefinitions/1f3afdf9-d0c9-4c3d-847f-89da613e70a8' -and
                $properties.scope -ieq ('/subscriptions/'+$initial.subscriptionId) -and
                $parametersEmpty -and $created -and $modified -and
                [DateTime]::Parse($modified).ToUniversalTime() -eq [DateTime]::Parse($created).ToUniversalTime() -and
                [DateTime]::Parse($created).ToUniversalTime() -ge [DateTime]::Parse($script:Ledger.startedUtc).ToUniversalTime()
            if($autoOwned) {
                if(@($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $assignment.id}).Count -eq 0){$script:Ledger.extensionInventory += [pscustomobject]@{
                    id=$assignment.id
                    apiVersion='2022-06-01'
                    kind='AUTO_SECURITY_ASSIGNMENT'
                    ownership='ABSENT_BASELINE_AND_SECURITY_ONBOARDING_TIMESTAMP'
                    snapshot=$fresh.value
                }}
            }else{$script:Ledger.externalDifferences += [pscustomobject]@{id=$assignment.id
            type='Microsoft.Authorization/policyAssignments'
            status='UNPROVEN_EXTERNAL_NEW_PRESERVED'}}
        }
        foreach($item in $now) {
            $owned=@($script:Ledger.plan.bundles | Where-Object {$item.id.StartsWith(('/subscriptions/'+$_.subscriptionId+'/resourceGroups/'+$_.resourceGroup+'/'),[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0 -or @($script:Ledger.managedGroups | Where-Object {$item.id.StartsWith($_.id+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
            if(-not $owned -and $item.type -ieq 'Microsoft.Network/networkWatchers' -and $initial.resourceIds -notcontains $item.id) {
                $location=Get-PropertyValue $item 'location' ''
                $watcherGroup='/subscriptions/'+$initial.subscriptionId+'/resourceGroups/NetworkWatcherRG'
                $expectedId=$watcherGroup+'/providers/Microsoft.Network/networkWatchers/NetworkWatcher_'+$location
                $ownVnet=@($script:Ledger.inventory | Where-Object {$_.type -ieq 'Microsoft.Network/virtualNetworks' -and ($_.id -split '/')[2] -ieq $initial.subscriptionId -and $_.location -ieq $location}).Count -gt 0
                $existing=@($script:Ledger.autoWatchers | Where-Object {$_.id -ieq $item.id})
                if($ownVnet -and $item.id -ieq $expectedId -and $foreignNetwork.Count -eq 0) {
                    if($existing.Count -eq 0) {
                        $script:Ledger.autoWatchers += [pscustomobject]@{
                            id=$item.id
                            apiVersion='2024-05-01'
                            location=$location
                            groupId=$watcherGroup
                            deleteGroupIfEmpty=($initial.groupIds -notcontains $watcherGroup)
                            status='OWNED_AUTO_SIDE_EFFECT'
                        }
                    }
                    $owned=$true
                }elseif($existing.Count -gt 0){$existing[0].status='AMBIGUOUS_PRESERVE'}
            }
            if(-not $owned -and $initial.resourceIds -notcontains $item.id) {$script:Ledger.externalDifferences += [pscustomobject]@{id=$item.id
            type=$item.type
            status='UNPROVEN_EXTERNAL_NEW_PRESERVED'}}
        }
        foreach($role in $roles) {
            if($initial.roleAssignmentIds -contains $role.id){continue}
            $scope=Get-PropertyValue $role.properties 'scope' ''
            $owned=@($script:Ledger.managedGroups | Where-Object {$scope -ieq $_.id -or $scope.StartsWith($_.id+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0 -or @($script:Ledger.plan.bundles | Where-Object {$scope -ieq ('/subscriptions/'+$_.subscriptionId+'/resourceGroups/'+$_.resourceGroup) -or $scope.StartsWith(('/subscriptions/'+$_.subscriptionId+'/resourceGroups/'+$_.resourceGroup+'/'),[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0
            $externalRole=@($script:Ledger.ownedExternalRoles | Where-Object {$_.id -ieq $role.id})
            if($externalRole.Count -eq 1 -and $externalRole[0].afterFullProperties -and (Test-ExternalJsonEqual $role.properties $externalRole[0].afterFullProperties)){$owned=$true}
            if($owned) {
                if(@($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $role.id}).Count -eq 0){$script:Ledger.extensionInventory += [pscustomobject]@{id=$role.id
                apiVersion='2022-04-01'
                kind='ROLE_ASSIGNMENT'
                ownership=if($externalRole.Count -eq 1){'EXACT_NEW_EXISTING_SUBNET_ROLE'}else{'EXCLUSIVE_NEW_RUN_RG'}}}
            }else{$script:Ledger.externalDifferences += [pscustomobject]@{id=$role.id
            type='Microsoft.Authorization/roleAssignments'
            status='UNPROVEN_EXTERNAL_NEW_PRESERVED'}}
        }
    }
    $mg=Invoke-Api -Method GET -Id $script:Ledger.managementGroupId -ApiVersion '2020-05-01' -MayFail
    if($mg.ok) {
        $roles=Get-ApiPages -Id ($script:Ledger.managementGroupId+'/providers/Microsoft.Authorization/roleAssignments') -ApiVersion '2022-04-01'
        foreach($role in $roles) {
            if($role.properties.scope -ieq $script:Ledger.managementGroupId -and @($script:Ledger.extensionInventory | Where-Object {$_.id -ieq $role.id}).Count -eq 0){$script:Ledger.extensionInventory += [pscustomobject]@{id=$role.id
            apiVersion='2022-04-01'
            kind='MG_ROLE_ASSIGNMENT'
            ownership='EXCLUSIVE_NEW_RUN_MG'}}
        }
    }elseif($mg.code -notin @('ManagementGroupNotFound','ResourceNotFound','NotFound')){throw ('MG role inventory unresolved: '+$mg.code)}
    Save-Ledger
    Write-JsonFile -Path (Join-Path $script:RunPath 'external-differences.json') -Value $script:Ledger.externalDifferences
}
function Seed-SourceDiagnostics {
    Assert-RunWindow
    if (-not $script:Ledger.sourceWorkspaceId) {throw 'Source workspace unavailable.'}
    $index=0
    foreach ($scope in $script:Ledger.scopes) {
        $index++
        $scope.sourceSeeded=$false
        if($null -ne $scope.PSObject.Properties['destinationModeCapability']){$scope.destinationModeCapability='UNMEASURED'}
        $external=$scope.ownership -eq 'EXTERNAL_EXISTING_NETWORK'
        $network=$null
        if($external){
            $network=@($script:Ledger.existingNetworks | Where-Object {$_.vnetId -ieq $scope.resourceId})[0]
            if(-not $network.diagnosticsBefore.supported){$scope.actualStatus=if($scope.actualStatus -eq 'CATEGORIES_ONLY'){'UNRESOLVED'}else{'EXPECTED_UNSUPPORTED'};$scope.excludedReason='Existing diagnostic list unsupported; a category/list disagreement remains unresolved, never absence or migration PASS';continue}
        }
        if (-not $scope.seedSourceDiagnostic) {$scope.actualStatus='UNTARGETED_OLD_ONLY_COLLECTOR'
        $scope.excludedReason='Intentional collector with no source diagnostic'
        continue}
        if (-not $scope.exists -or $scope.actualStatus -eq 'EXPECTED_UNSUPPORTED') {continue}
        $logs=@()
        $metrics=@()
        foreach ($category in @(Get-PropertyValue $scope.categoryResponse 'value' @())) {
            $kind=Get-PropertyValue $category.properties 'categoryType'
            if ($kind -eq 'Logs') {$logs += @{category=$category.name
            enabled=$true}}
            if ($kind -eq 'Metrics') {$metrics += @{category=$category.name
            enabled=$true}}
        }
        if ($logs.Count+$metrics.Count -eq 0) {$scope.actualStatus='UNRESOLVED'
        $scope.excludedReason='No actual diagnostic categories; no unsupported inference'
        continue}
        # categories の実値だけを使用。source LA≠AppInsights base LA をARM側で保証。
        if($logs.Count -gt 1 -and $index%3 -eq 1){$logs[$logs.Count-1].enabled=$false}
        if($logs.Count -gt 0 -and $index%5 -eq 1){$metrics=@()}
        elseif($metrics.Count -gt 0 -and $index%5 -eq 2){$logs=@()}
        $properties=@{workspaceId=$script:Ledger.sourceWorkspaceId
        logs=$logs
        metrics=$metrics}
        $diagId=$scope.resourceId+'/providers/Microsoft.Insights/diagnosticSettings/fx-source-'+$RunId
        $script:CurrentSubscription=($scope.resourceId -split '/')[2]
        $before=Invoke-Api -Method GET -Id $diagId -ApiVersion '2021-05-01-preview' -MayFail
        if($external){
            if(@($network.diagnosticsBefore.body.value | Where-Object {$_.id -ieq $diagId}).Count){throw 'Existing external source setting name collides with the run.'}
            $owned=@($script:Ledger.createdExternalDiagnostics | Where-Object {$_.id -ieq $diagId})
            if($before.ok -and ($owned.Count -ne 1 -or -not (Test-ExternalJsonEqual $before.value.properties $owned[0].afterFullProperties))){throw 'External source setting is unowned or changed; preserved.'}
        }
        if ($before.ok) {
            $scope.sourceBefore=$before.value
            if (@($script:Ledger.operations | Where-Object {$_.id -ieq $diagId -and $_.method -eq 'PUT'}).Count -eq 0) {throw 'Existing diagnostic setting is not owned by this run.'}
        } elseif($before.code -notin @('ResourceNotFound','NotFound','DiagnosticSettingNotFound')) {$scope.actualStatus='FAILED'
        $scope.actualErrorCode=$before.code
        continue}
        $scope.attemptedBody=$properties
        $put=Invoke-Api -Method PUT -Id $diagId -ApiVersion '2021-05-01-preview' -Body @{properties=$properties} -Purpose 'Seed source diagnostic' -MayFail
        if (-not $put.ok) {
            $scope.actualErrorCode=$put.code
            $scope.actualStatus=if($put.code -in @('ResourceTypeNotSupported','UnsupportedResourceType','DiagnosticSettingsNotSupported')){'EXPECTED_UNSUPPORTED'}else{'FAILED'}
            Save-Ledger
            continue
        }
        $read=Invoke-Api -Method GET -Id $diagId -ApiVersion '2021-05-01-preview' -MayFail
        if (-not $read.ok -or $read.value.properties.workspaceId -ine $script:Ledger.sourceWorkspaceId) {$scope.actualStatus='FAILED'
        $scope.actualErrorCode=if($read.ok){'READBACK_MISMATCH'}else{$read.code}
        continue}
        # APIが返したenabledカテゴリーが要求と一致することを独立に照合。
        $want=@(@($logs | ForEach-Object {'L:'+ $_.category+':'+[string]$_.enabled})+@($metrics | ForEach-Object {'M:'+ $_.category+':'+[string]$_.enabled}) | Sort-Object)
        $got=@(@(@(Get-PropertyValue $read.value.properties 'logs' @()) | ForEach-Object {'L:'+ $_.category+':'+[string]$_.enabled})+@(@(Get-PropertyValue $read.value.properties 'metrics' @()) | ForEach-Object {'M:'+ $_.category+':'+[string]$_.enabled}) | Sort-Object)
        if (($want -join '|') -cne ($got -join '|')) {$scope.actualStatus='FAILED'
        $scope.actualErrorCode='CATEGORY_READBACK_MISMATCH'
        continue}
        if($external){
            $owned=@($script:Ledger.createdExternalDiagnostics | Where-Object {$_.id -ieq $diagId})
            if($owned.Count -eq 0){$script:Ledger.createdExternalDiagnostics += [pscustomobject]@{id=$diagId;beforeAbsent=$true;afterFullProperties=$read.value.properties}}
            elseif($owned.Count -eq 1){$owned[0].afterFullProperties=$read.value.properties}
            else{throw 'Duplicate external diagnostic ownership record.'}
        }
        $scope.actualStatus='POSITIVE_SEEDED'
        $scope.sourceSeeded=$true
        $scope.sourceBefore=$read.value
        $scope.destinationModeCapability='LOG_PUT_GET_SUCCEEDED'
        Save-Ledger
    }
    Write-JsonFile -Path (Join-Path $script:RunPath 'scope-capabilities.json') -Value $script:Ledger.scopes
    Write-JsonFile -Path (Join-Path $script:RunPath 'source-diag-put-success-scopes.json') -Value @($script:Ledger.scopes | Where-Object {$_.actualStatus -eq 'POSITIVE_SEEDED'} | ForEach-Object {$_.resourceId})
    # expected は比較用成果物です。generic6へ渡す入力にはしません。
    Write-JsonFile -Path (Join-Path $script:RunPath 'positive-expected-scopes.json') -Value @($script:Ledger.scopes | Where-Object {$_.actualStatus -eq 'POSITIVE_SEEDED'} | ForEach-Object {$_.resourceId})
    # 代表1scopeに別LA宛sentinelを置き、製品操作の対象外設定が不変か独立照合できます。
    $positive=@($script:Ledger.scopes | Where-Object {$_.sourceSeeded -and $_.ownership -ne 'EXTERNAL_EXISTING_NETWORK'})
    $aux=@($script:Ledger.resources | Where-Object {$_.role -eq 'untargeted-aux-workspace'})
    if($positive.Count -gt 0 -and $aux.Count -eq 1) {
        $scope=$positive[0]
        $id=$scope.resourceId+'/providers/Microsoft.Insights/diagnosticSettings/fx-untargeted-'+$RunId
        $script:CurrentSubscription=($scope.resourceId -split '/')[2]
        $before=Invoke-Api -Method GET -Id $id -ApiVersion '2021-05-01-preview' -MayFail
        if($before.ok -and @($script:Ledger.operations | Where-Object {$_.id -ieq $id -and $_.method -eq 'PUT'}).Count -eq 0){throw 'Untargeted setting name collision.'}
        if(-not $before.ok -and $before.code -notin @('ResourceNotFound','NotFound','DiagnosticSettingNotFound')){throw ('Untargeted baseline unresolved: '+$before.code)}
        $properties=@{workspaceId=$aux[0].id
        logs=$scope.attemptedBody.logs
        metrics=$scope.attemptedBody.metrics}
        $null=Invoke-Api -Method PUT -Id $id -ApiVersion '2021-05-01-preview' -Body @{properties=$properties} -Purpose 'Create untargeted diagnostic sentinel'
        $read=Invoke-Api -Method GET -Id $id -ApiVersion '2021-05-01-preview'
        if($read.value.properties.workspaceId -ine $aux[0].id){throw 'Untargeted diagnostic destination readback mismatch.'}
        Write-JsonFile -Path (Join-Path $script:RunPath 'untargeted-diagnostic-baseline.json') -Value $read.value
    }
    Save-Ledger
}
function Create-CollectorAssociations {
    $dcrs=@($script:Ledger.resources | Where-Object {$_.role -in @('old-dcr-1','old-dcr-2','untargeted-sentinel-dcr')})
    $collectors=@($script:Ledger.resources | Where-Object {$_.resourceType -in @('microsoft.compute/virtualmachines','microsoft.compute/virtualmachinescalesets')})
    foreach ($collector in $collectors) {
        $script:CurrentSubscription=($collector.id -split '/')[2]
        foreach ($dcr in $dcrs) {
            $id=$collector.id+'/providers/Microsoft.Insights/dataCollectionRuleAssociations/fx-'+$dcr.role
            $put=Invoke-Api -Method PUT -Id $id -ApiVersion '2023-03-11' -Body @{properties=@{dataCollectionRuleId=$dcr.id}} -Purpose 'Create old/sentinel DCRA' -MayFail
            $read=if($put.ok){Invoke-Api -Method GET -Id $id -ApiVersion '2023-03-11' -MayFail}else{$put}
            $ok=$read.ok -and $read.value.properties.dataCollectionRuleId -ieq $dcr.id
            $script:Ledger.collectorAssociations += [pscustomobject]@{
                id=$id
                collectorId=$collector.id
                dcrId=$dcr.id
                role=$dcr.role
                status=if($ok){'PUT_GET_SUCCEEDED'}else{'FAILED'}
                errorCode=if($ok){$null}else{if($read.code){$read.code}else{'READBACK_MISMATCH'}}
            }
            Save-Ledger
        }
    }
}
# LOCAL候補: Azure CLI同梱Python/SDKを使う版。別Python/pip/追加SDKは使いません。
# 現行CLIのblob deleteはversion-id引数がなく、blob-urlのversionidもSDK変換時に失われます。
# 単一の同梱SDK processでlistKeys→metadata列挙→exact version/snapshot削除を完結します。
function Get-CliBundledPython {
    $stderrFile = New-PrivateJsonFile -Value @{}
    $previousPreference = $ErrorActionPreference
    $previousVersionCheck = $env:AZURE_CORE_CHECK_VERSION
    try {
        $env:AZURE_CORE_CHECK_VERSION = 'no'
        $ErrorActionPreference = 'Continue'
        $version = @(& az --version 2>$stderrFile) -join "`n"
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        if ($null -eq $previousVersionCheck) { Remove-Item Env:AZURE_CORE_CHECK_VERSION -ErrorAction SilentlyContinue }
        else { $env:AZURE_CORE_CHECK_VERSION = $previousVersionCheck }
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
    }
    if ($exitCode -ne 0 -or $version -notmatch '(?m)^[ \t]*Python location [''"]([^''"\r\n]+)[''"][ \t]*$') {
        throw 'Azure CLI did not identify its bundled Python; no unrelated Python is used.'
    }
    $python = $Matches[1]
    if (-not [IO.Path]::IsPathRooted($python) -or -not (Test-Path -LiteralPath $python -PathType Leaf)) {
        throw 'Azure CLI bundled Python path is not a local executable.'
    }
    return $python
}

function Assert-StorageSdkLocal {
    # Deploy前のLOCAL preflight。import/metadata constructionのみで認証・通信しません。
    $python = Get-CliBundledPython
    $source = @'
import json, logging, sys
logging.disable(logging.CRITICAL)
result = {"ok": False, "code": "CLI_STORAGE_SDK_UNAVAILABLE"}
try:
    from azure.cli.core._profile import Profile
    from azure.core import MatchConditions
    from azure.mgmt.storage import StorageManagementClient
    from azure.storage.blob import BlobServiceClient
    service = BlobServiceClient('https://localpreflight.blob.core.windows.net', api_version='2023-11-03')
    container = service.get_container_client('fixture')
    version = container.get_blob_client('probe', version_id='2000-01-01T00:00:00.0000000Z')
    snapshot = container.get_blob_client('probe', snapshot='2000-01-01T00:00:00.0000000Z')
    if version.version_id != '2000-01-01T00:00:00.0000000Z' or not snapshot.snapshot:
        raise ValueError('VersionSnapshotUnavailable')
    if not callable(container.list_blobs) or not callable(version.delete_blob):
        raise ValueError('VersionOperationsUnavailable')
    service.close()
    result = {"ok": True, "code": "LOCAL_STORAGE_SDK_PREFLIGHT_OK"}
except Exception:
    pass
print(json.dumps(result, separators=(',', ':')))
sys.exit(0 if result['ok'] else 1)
'@
    $stderrFile = New-PrivateJsonFile -Value @{}
    $codeFile = $null
    $previousPreference = $ErrorActionPreference
    try {
        # owner-only ACLを確保してから、秘密を含まないSDK preflight codeだけを書きます。
        $codeFile = New-PrivateJsonFile -Value @{}
        [IO.File]::WriteAllText($codeFile, $source, $script:Utf8)
        $ErrorActionPreference = 'Continue'
        $raw = @(& $python -I $codeFile 2>$stderrFile)
        $exitCode = $LASTEXITCODE
    } finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue
        if ($codeFile) { Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue }
    }
    try { $result = ConvertFrom-Json -InputObject ($raw -join "`n") -ErrorAction Stop }
    catch { throw 'Azure CLI bundled Storage SDK local preflight failed.' }
    if ($exitCode -ne 0 -or -not $result.ok -or $result.code -cne 'LOCAL_STORAGE_SDK_PREFLIGHT_OK') {
        throw 'Azure CLI bundled Storage SDK local preflight failed; install a supported Azure CLI before deployment.'
    }
}

function Remove-OwnedStorageContainers {
    param([string]$AccountId)
    if (-not $script:Ledger.initialCaptureComplete -or $script:Ledger.runId -cne $RunId) {
        throw 'Storage cleanup requires the original completed run snapshot.'
    }
    if ($AccountId -notmatch '^/subscriptions/([0-9a-fA-F-]{36})/resourceGroups/([^/]+)/providers/Microsoft\.Storage/storageAccounts/([a-z0-9]{3,24})$') {
        throw 'Storage cleanup requires an exact Storage account ARM ID.'
    }
    $subscriptionId = $Matches[1]
    $resourceGroup = $Matches[2]
    $accountName = $Matches[3]
    $script:CurrentSubscription = $subscriptionId
    $bundle = @($script:Ledger.plan.bundles | Where-Object {
        $_.subscriptionId -ieq $subscriptionId -and $_.resourceGroup -ieq $resourceGroup
    })
    $initial = @($script:Ledger.initialState | Where-Object { $_.subscriptionId -ieq $subscriptionId })
    $groupId = '/subscriptions/' + $subscriptionId + '/resourceGroups/' + $resourceGroup
    $inventory = @($script:Ledger.inventory | Where-Object {
        $_.id -ieq $AccountId -and $_.type -ieq 'Microsoft.Storage/storageAccounts' -and
        $_.ownership -eq 'EXCLUSIVE_NEW_RUN_RG'
    })
    if ($bundle.Count -ne 1 -or $initial.Count -ne 1 -or $inventory.Count -ne 1 -or
        $initial[0].resourceIds -contains $AccountId -or $initial[0].groupIds -contains $groupId) {
        throw 'Storage cleanup ownership/baseline proof failed.'
    }
    $group = Invoke-Api -Method GET -Id $groupId -ApiVersion '2022-09-01'
    if ((Get-PropertyValue (Get-PropertyValue $group.value 'tags') 'fixtureRun') -cne $RunId) {
        throw 'Storage cleanup resource-group run tag differs.'
    }
    $account = Invoke-Api -Method GET -Id $AccountId -ApiVersion '2023-05-01' -MayFail
    if (-not $account.ok -and $account.code -in @('ResourceNotFound','ResourceGroupNotFound','NotFound')) { return }
    if (-not $account.ok) { throw ('Storage cleanup account GET failed: ' + $account.code) }
    if ($account.value.kind -eq 'FileStorage') { return }
    $expectedBlobEndpoint = 'https://' + $accountName + '.blob.core.windows.net/'
    if ($account.value.properties.primaryEndpoints.blob -cne $expectedBlobEndpoint) {
        throw 'Storage cleanup only supports the exact public-Azure blob endpoint.'
    }
    $containers = @(Get-ApiPages -Id ($AccountId + '/blobServices/default/containers') -ApiVersion '2023-05-01')
    $previousCleanup = @(Get-PropertyValue $script:Ledger 'storageCleanup' @() | Where-Object { $_.id -ieq $AccountId })
    if ($containers.Count -eq 0 -and $previousCleanup.Count -eq 0) { return }
    $containerNames = @()
    if ($null -eq $script:Ledger.PSObject.Properties['storageCleanup']) {
        $script:Ledger | Add-Member -NotePropertyName storageCleanup -NotePropertyValue @()
    }
    $existing = @($script:Ledger.storageCleanup | Where-Object { $_.id -ieq $AccountId })
    if ($existing.Count -gt 1) { throw 'Duplicate Storage cleanup ledger entry.' }
    if ($existing.Count -eq 1) {
        $entry = $existing[0]
        $prior = $entry.originalAccess
    } else {
        $prior = [pscustomobject]@{
            allowSharedKeyAccess = Get-PropertyValue $account.value.properties 'allowSharedKeyAccess'
            publicNetworkAccess = Get-PropertyValue $account.value.properties 'publicNetworkAccess'
            networkAcls = Get-PropertyValue $account.value.properties 'networkAcls'
        }
        $entry = [pscustomobject]@{
            id = $AccountId
            originalAccess = $prior
            status = 'ACCESS_CHANGE_INTENT'
            containers = $containerNames
            metadataResult = $null
            sdkResult = $null
            restoreStatus = 'NOT_ATTEMPTED'
        }
        $script:Ledger.storageCleanup = @($script:Ledger.storageCleanup) + @($entry)
        Save-Ledger
    }
    if ($null -eq $entry.PSObject.Properties['sdkResult']) {
        $entry | Add-Member -NotePropertyName sdkResult -NotePropertyValue $null
    }
    # ACL全体を保持。defaultAction以外のIP/VNet/resourceAccessRules/bypassを変えません。
    $opened = ConvertFrom-Json (ConvertTo-Json $prior -Depth 100)
    $opened.allowSharedKeyAccess = $true
    $opened.publicNetworkAccess = 'Enabled'
    if ($null -eq $opened.networkAcls) { throw 'Storage network ACL snapshot is missing.' }
    $opened.networkAcls.defaultAction = 'Allow'
    $currentAccess = [pscustomobject]@{
        allowSharedKeyAccess = Get-PropertyValue $account.value.properties 'allowSharedKeyAccess'
        publicNetworkAccess = Get-PropertyValue $account.value.properties 'publicNetworkAccess'
        networkAcls = Get-PropertyValue $account.value.properties 'networkAcls'
    }
    $currentJson = ConvertTo-Json $currentAccess -Depth 100 -Compress
    if ($currentJson -cne (ConvertTo-Json $prior -Depth 100 -Compress) -and
        $currentJson -cne (ConvertTo-Json $opened -Depth 100 -Compress)) {
        throw 'Storage access settings changed since the saved snapshot; no overwrite performed.'
    }
    $source = @'
import base64, json, logging, sys, time
logging.disable(logging.CRITICAL)
result = {"ok": False, "code": "STORAGE_SDK_FAILED", "containers": [], "operations": [],
          "storageHttpStatus": None, "storageErrorCode": None, "exceptionType": None, "failedStage": None}
credential = management = service = None
secret = keys = None
stage = 'sdk-import'
def status_only(response):
    status = getattr(response.http_response, 'status_code', None)
    if stage in ('current-base-head', 'current-base-delete', 'exact-current-delete', 'exact-current-absence-head'):
        result['operations'].append({'operation': stage, 'httpStatus': status if type(status) is int and 100 <= status <= 599 else None})
try:
    from azure.cli.core import get_default_cli
    from azure.cli.core._profile import Profile
    from azure.core import MatchConditions
    from azure.mgmt.storage import StorageManagementClient
    from azure.storage.blob import BlobServiceClient
    account_id, names_json = sys.argv[1:3]
    parts = account_id.split('/')
    subscription, resource_group, account_name = parts[2], parts[4], parts[8]
    payload = json.loads(base64.b64decode(names_json).decode('utf-8'))
    names, current_guards = payload['containers'], payload['currentGuards']
    stage = 'profile'
    credential, selected_subscription, _ = Profile(cli_ctx=get_default_cli()).get_login_credentials(subscription_id=subscription, resource='https://management.azure.com/')
    if selected_subscription.lower() != subscription.lower():
        raise ValueError('SubscriptionMismatch')
    management = StorageManagementClient(credential, subscription)
    # Azure CLIのkey authと同じlistKeys経路。キーはこのprocessだけに保持します。
    stage = 'list-keys'
    keys = management.storage_accounts.list_keys(resource_group, account_name, logging_enable=False)
    key_data = keys.as_dict()
    values = key_data.get('keys') or key_data.get('keys_property') or []
    secret = next(item['value'] for item in values if item.get('permissions', 'FULL').upper() == 'FULL')
    key_data = keys = values = None
    service = BlobServiceClient('https://' + account_name + '.blob.core.windows.net', credential=secret,
                               api_version='2023-11-03', logging_enable=False)
    for name in names:
        container = service.get_container_client(name)
        deleted_count = 0
        stage = 'container-head'
        for readiness in range(4):
            try:
                container.get_container_properties(timeout=20, connection_timeout=10, read_timeout=20,
                                                   retry_total=0, permit_redirects=False, logging_enable=False)
                break
            except Exception as error:
                if getattr(error, 'status_code', None) == 403 and str(getattr(error, 'error_code', '')) in (
                        'AuthorizationFailure', 'KeyBasedAuthenticationNotPermitted') and readiness < 3:
                    time.sleep(10)
                    continue
                raise
        for attempt in range(3):
            # 取得するのは名前/version/snapshot等のmetadataだけ。content downloadはありません。
            stage = 'list-versions'
            blobs = list(container.list_blobs(include=['versions', 'snapshots'], timeout=20,
                                             connection_timeout=10, read_timeout=20, retry_total=0, logging_enable=False))
            if not blobs:
                break
            if all(not getattr(blob, 'snapshot', None) and not getattr(blob, 'version_id', None) and
                   getattr(blob, 'has_versions_only', None) is True for blob in blobs):
                break
            blobs.sort(key=lambda blob: (0 if getattr(blob, 'snapshot', None) else
                                         1 if getattr(blob, 'version_id', None) and not getattr(blob, 'is_current_version', False)
                                         else 2, blob.name))
            for blob in blobs:
                snapshot = getattr(blob, 'snapshot', None)
                version = None if snapshot else getattr(blob, 'version_id', None)
                is_current = not snapshot and getattr(blob, 'is_current_version', None) is True
                if is_current and (not isinstance(version, str) or not version):
                    result['code'] = 'ROOT_BLOB_ID_UNRESOLVED'
                    raise ValueError('ListedCurrentVersionMissing')
                if not snapshot and not version:
                    # SDK仕様上has_versions_only=Trueだけが削除済rootの明示的な証拠です。
                    # AppendBlobや未知のno-ID rowをplaceholderと推測して削除/成功扱いしません。
                    if getattr(blob, 'has_versions_only', None) is True:
                        continue
                    try:
                        stage = 'root-head'
                        properties = container.get_blob_client(blob.name).get_blob_properties(
                            timeout=20, connection_timeout=10, read_timeout=20, retry_total=0,
                            permit_redirects=False, logging_enable=False)
                        version = getattr(properties, 'version_id', None)
                    except Exception:
                        result['code'] = 'ROOT_BLOB_ID_UNRESOLVED'
                        raise ValueError('RootMetadataUnresolved')
                    if not isinstance(version, str) or not version:
                        result['code'] = 'ROOT_BLOB_ID_UNRESOLVED'
                        raise ValueError('RootVersionUnresolved')
                client = container.get_blob_client(blob.name, snapshot=snapshot, version_id=version)
                if is_current:
                    if current_guards.get('versioningEnabled') is not True or current_guards.get('softDeleteEnabled') is not False:
                        result['code'] = 'CURRENT_VERSION_POLICY_GUARD_FAILED'
                        raise ValueError('CurrentPolicyGuardFailed')
                    # CURRENT=Trueだけ、fresh BASE HEADとETagで同じcurrent versionを固定します。
                    base = container.get_blob_client(blob.name)
                    stage = 'current-base-head'
                    properties = base.get_blob_properties(timeout=20, connection_timeout=10, read_timeout=20,
                        retry_total=0, permit_redirects=False, logging_enable=False, raw_response_hook=status_only)
                    etag = getattr(properties, 'etag', None)
                    if getattr(properties, 'version_id', None) != version or not isinstance(etag, str) or not etag.strip():
                        result['code'] = 'CURRENT_VERSION_CHANGED_OR_ETAG_MISSING'
                        raise ValueError('CurrentIdentityGuardFailed')
                    # optional retention/holdがnullでも不存在とは解釈せず、通常のserver保護に従います。
                    # BASE deleteへversion/snapshot/permanent_delete/delete_snapshotsは指定しません。
                    stage = 'current-base-delete'
                    base.delete_blob(etag=etag, match_condition=MatchConditions.IfNotModified, timeout=20,
                        connection_timeout=10, read_timeout=20, retry_total=0, permit_redirects=False,
                        logging_enable=False, raw_response_hook=status_only)
                stage = 'exact-current-delete' if is_current else 'exact-delete'
                try:
                    client.delete_blob(timeout=20, connection_timeout=10, read_timeout=20,
                        retry_total=0, permit_redirects=False, logging_enable=False,
                        raw_response_hook=status_only if is_current else None)
                except Exception as error:
                    if getattr(error, 'status_code', None) != 404 or str(getattr(error, 'error_code', '')) not in (
                            'BlobNotFound', 'ResourceNotFound'):
                        raise
                if is_current:
                    stage = 'exact-current-absence-head'
                    try:
                        client.get_blob_properties(timeout=20, connection_timeout=10, read_timeout=20,
                            retry_total=0, permit_redirects=False, logging_enable=False, raw_response_hook=status_only)
                    except Exception as error:
                        if getattr(error, 'status_code', None) != 404 or str(getattr(error, 'error_code', '')) != 'BlobNotFound':
                            raise
                    else:
                        result['code'] = 'CURRENT_VERSION_ABSENCE_NOT_PROVEN'
                        raise ValueError('ExactCurrentVersionStillExists')
                deleted_count += 1
        stage = 'remaining-list'
        remaining = list(container.list_blobs(include=['versions', 'snapshots'], timeout=20,
                                             connection_timeout=10, read_timeout=20, retry_total=0, logging_enable=False))
        # 全exact version/snapshotが消え、明示的な削除済rootだけならcontainer ARM削除へ。
        unresolved = [blob for blob in remaining if getattr(blob, 'snapshot', None) or
                      getattr(blob, 'version_id', None) or getattr(blob, 'has_versions_only', None) is not True]
        if unresolved:
            result['code'] = 'BLOB_VERSIONS_REMAIN'
            raise ValueError('BlobVersionsRemain')
        result['containers'].append({'name': name, 'deletedCount': deleted_count, 'remainingCount': 0,
                                     'deletedRootPlaceholderCount': len(remaining)})
    result['ok'] = True
    result['code'] = None
except Exception as error:
    status = getattr(error, 'status_code', None)
    code = str(getattr(error, 'error_code', ''))
    known_sdk_codes = ('AuthorizationFailure', 'KeyBasedAuthenticationNotPermitted', 'AuthenticationFailed',
        'AuthorizationPermissionMismatch', 'OperationNotAllowedOnRootBlob', 'ConditionNotMet',
        'BlobImmutableDueToPolicy', 'BlobImmutableDueToLegalHold', 'BlobProtectedByImmutabilityPolicy',
        'ContainerHasLegalHold', 'BlobHasLegalHold', 'LeaseIdMissing', 'LeaseIdMismatchWithBlobOperation',
        'BlobNotFound', 'ResourceNotFound', 'ContainerNotFound', 'SnapshotsPresent', 'ServerBusy', 'InternalError')
    known_types = ('HttpResponseError', 'ResourceNotFoundError', 'ResourceExistsError', 'ServiceRequestError',
                   'ServiceResponseError', 'ClientAuthenticationError', 'ValueError', 'ImportError', 'ModuleNotFoundError')
    result['storageHttpStatus'] = status if type(status) is int and 100 <= status <= 599 else None
    result['storageErrorCode'] = code if code in known_sdk_codes else None
    result['exceptionType'] = type(error).__name__ if type(error).__name__ in known_types else 'OTHER_EXCEPTION'
    result['failedStage'] = stage
    if status in (401, 403):
        result['code'] = 'STORAGE_DATA_ACCESS_DENIED'
    elif code in ('BlobImmutableDueToPolicy', 'BlobProtectedByImmutabilityPolicy', 'ContainerHasLegalHold',
                  'BlobHasLegalHold', 'LeaseIdMissing', 'LeaseIdMismatchWithBlobOperation'):
        result['code'] = 'STORAGE_RETENTION_OR_LEASE_BLOCK'
    # raw exception、credentials、keys、tokensは出力しません。
finally:
    secret = keys = None
    for client in (service, management):
        try:
            if client:
                client.close()
        except Exception:
            pass
print(json.dumps(result, ensure_ascii=True, separators=(',', ':')))
sys.exit(0 if result['ok'] else 1)
'@
    $stderrFile = $null
    $codeFile = $null
    try {
        foreach ($container in $containers) {
            $expectedId = $AccountId + '/blobServices/default/containers/' + $container.name
            if ($container.id -ine $expectedId -or $container.name -match '/') {
                throw 'Unexpected Storage container ID; no data-plane delete performed.'
            }
            $legalHold = Get-PropertyValue $container.properties 'hasLegalHold'
            $immutable = Get-PropertyValue $container.properties 'hasImmutabilityPolicy'
            if ($legalHold -isnot [bool] -or $immutable -isnot [bool] -or $legalHold -or $immutable) {
                throw 'Storage retention/legal hold is enabled or unknown; no data deletion or weakening is performed.'
            }
            $containerNames += $container.name
        }
        $entry.containers = $containerNames
        Save-Ledger
        # 実行系が見つからない場合、アクセスを開ける前に停止。再開時はfinallyで原本へ戻します。
        $python = Get-CliBundledPython
        $serviceProperties = Invoke-Api -Method GET -Id ($AccountId + '/blobServices/default') -ApiVersion '2023-05-01' -MayFail
        $currentGuards = [pscustomobject]@{versioningEnabled=$null;softDeleteEnabled=$null}
        if ($serviceProperties.ok) {
            $currentGuards.versioningEnabled = Get-PropertyValue $serviceProperties.value.properties 'isVersioningEnabled'
            $currentGuards.softDeleteEnabled = Get-PropertyValue (Get-PropertyValue $serviceProperties.value.properties 'deleteRetentionPolicy') 'enabled'
        }
        $null = Invoke-Api -Method PATCH -Id $AccountId -ApiVersion '2023-05-01' -Body @{properties=$opened} -Purpose 'Temporarily open owned Storage cleanup access'
        $effective = (Invoke-Api -Method GET -Id $AccountId -ApiVersion '2023-05-01').value.properties
        $actual = [pscustomobject]@{
            allowSharedKeyAccess = Get-PropertyValue $effective 'allowSharedKeyAccess'
            publicNetworkAccess = Get-PropertyValue $effective 'publicNetworkAccess'
            networkAcls = Get-PropertyValue $effective 'networkAcls'
        }
        if ((ConvertTo-Json $actual -Depth 100 -Compress) -cne (ConvertTo-Json $opened -Depth 100 -Compress)) {
            throw 'Storage cleanup access flags did not take effect.'
        }
        # account単位でeffective open GETの後、最初のwriteより最低30秒待ちます。
        Start-Sleep -Seconds 30
        $operation = Add-Operation -Method 'DELETE_BLOB_VERSIONS' -Id $AccountId -ApiVersion '2023-11-03' -Purpose 'Empty exact owned containers, versions and snapshots with CLI bundled SDK'
        $stderrFile = New-PrivateJsonFile -Value @{}
        # code-only fileです。キー/トークンはPython子processのmemoryだけに存在します。
        $codeFile = New-PrivateJsonFile -Value @{}
        [IO.File]::WriteAllText($codeFile, $source, $script:Utf8)
        $previousPreference = $ErrorActionPreference
        try {
            $ErrorActionPreference = 'Continue'
            $payload = [pscustomobject]@{containers=@($containerNames);currentGuards=$currentGuards}
            $namesEncoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $payload -Depth 10 -Compress)))
            $native = @(& $python -I $codeFile $AccountId $namesEncoded 2>$stderrFile)
            $exitCode = $LASTEXITCODE
        } finally { $ErrorActionPreference = $previousPreference }
        # 同梱processは固定JSONだけを返す。起動/parse失敗のnative本文は表示しません。
        try { $result = ConvertFrom-Json -InputObject ($native -join "`n") -ErrorAction Stop }
        catch { throw 'CLI bundled Storage SDK returned no valid safe result.' }
        $safeCodes = @('STORAGE_SDK_FAILED','BLOB_VERSIONS_REMAIN','ROOT_BLOB_ID_UNRESOLVED','STORAGE_DATA_ACCESS_DENIED','STORAGE_RETENTION_OR_LEASE_BLOCK',
            'CURRENT_VERSION_POLICY_GUARD_FAILED','CURRENT_VERSION_CHANGED_OR_ETAG_MISSING','CURRENT_VERSION_ABSENCE_NOT_PROVEN')
        $entry.metadataResult = $result.containers
        $entry.sdkResult = [pscustomobject]@{
            storageHttpStatus = $result.storageHttpStatus
            storageErrorCode = $result.storageErrorCode
            exceptionType = $result.exceptionType
            failedStage = $result.failedStage
            operations = $result.operations
        }
        if ($exitCode -ne 0 -or -not $result.ok) {
            $operation.status = 'FAILED'
            $operation.errorCode = if ($safeCodes -ccontains $result.code) {$result.code} else {'STORAGE_SDK_FAILED'}
            $entry.status = 'DATA_DELETE_FAILED'
            Save-Ledger
            throw ('Owned Storage content cleanup failed: ' + $operation.errorCode)
        }
        $operation.status = 'SUCCEEDED'
        $operation.finishedUtc = [DateTime]::UtcNow.ToString('o')
        $entry.status = 'BLOB_VERSIONS_EMPTY'
        Save-Ledger
        foreach ($container in $containers) {
            $deleted = Invoke-Api -Method DELETE -Id $container.id -ApiVersion '2023-05-01' -Purpose 'Delete empty exact owned Storage container' -MayFail
            if (-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {
                throw ('Owned Storage container DELETE failed: ' + $deleted.code)
            }
        }
        foreach ($container in $containers) {
            Wait-ResourceGone -Id $container.id -ApiVersion '2023-05-01' -MaximumMinutes 10
        }
        $entry.status = 'CONTAINERS_GONE'
        Save-Ledger
    } finally {
        if ($stderrFile) { Remove-Item -LiteralPath $stderrFile -Force -ErrorAction SilentlyContinue }
        if ($codeFile) { Remove-Item -LiteralPath $codeFile -Force -ErrorAction SilentlyContinue }
        # 原本snapshotを必ず使って復元。データ削除失敗/途中停止の再実行も同じ原本を使用。
        $remaining = $null
        try { $remaining = Invoke-Api -Method GET -Id $AccountId -ApiVersion '2023-05-01' -MayFail } catch {}
        if ($remaining -and -not $remaining.ok -and $remaining.code -in @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {
            $entry.restoreStatus = 'ACCOUNT_ALREADY_GONE'
        } else {
            # 最初のGETが失敗しても、保存済み原本を使う復元PATCH自体は試みます。
            $restored = $verified = $null
            try { $restored = Invoke-Api -Method PATCH -Id $AccountId -ApiVersion '2023-05-01' -Body @{properties=$prior} -Purpose 'Restore owned Storage cleanup access snapshot' -MayFail } catch {}
            try { $verified = Invoke-Api -Method GET -Id $AccountId -ApiVersion '2023-05-01' -MayFail } catch {}
            $actual = if ($verified -and $verified.ok) {[pscustomobject]@{
                allowSharedKeyAccess = Get-PropertyValue $verified.value.properties 'allowSharedKeyAccess'
                publicNetworkAccess = Get-PropertyValue $verified.value.properties 'publicNetworkAccess'
                networkAcls = Get-PropertyValue $verified.value.properties 'networkAcls'
            }} else {$null}
            if ($verified -and -not $verified.ok -and $verified.code -in @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {
                $entry.restoreStatus = 'ACCOUNT_ALREADY_GONE'
            } elseif (-not $restored -or -not $restored.ok -or -not $verified -or -not $verified.ok -or
                (ConvertTo-Json $actual -Depth 100 -Compress) -cne (ConvertTo-Json $prior -Depth 100 -Compress)) {
                $entry.restoreStatus = 'RESTORE_FAILED_OR_UNRESOLVED'
                Save-Ledger
                throw 'Storage cleanup access settings were not fully restored; exact account remains in ledger.'
            } else {
                $entry.restoreStatus = 'RESTORED_AND_GET_VERIFIED'
            }
        }
        Save-Ledger
    }
}

function Cleanup-Run {
    # Cleanupに予算承認は不要。作成前の完全snapshotを欠くrunは書込せず止めます。
    if (-not $script:Ledger.initialCaptureComplete) {throw 'Initial snapshot incomplete; no automatic cleanup writes are safe.'}
    $resourcesComplete=Get-PropertyValue $script:Ledger 'resourceCleanupComplete' $false
    # RP解除の再開時は、解除済みサービスを再登録し得るサービスAPIを呼びません。
    if(-not $resourcesComplete) {
    # 中断された非同期deploymentが削除後に資源を作り直さないよう、既知exactIDを先に停止。
    $activeDeployments=@()
    foreach($operation in @($script:Ledger.operations | Where-Object {$_.method -eq 'PUT' -and $_.id -match '/providers/Microsoft.Resources/deployments/'})) {
        $script:CurrentSubscription=($operation.id -split '/')[2]
        $current=Invoke-Api -Method GET -Id $operation.id -ApiVersion '2022-09-01' -MayFail
        if(-not $current.ok -and $current.code -in @('ResourceNotFound','ResourceGroupNotFound','NotFound')){continue}
        if(-not $current.ok){throw ('Deployment state unresolved: '+$current.code)}
        if($current.value.properties.provisioningState -notin @('Succeeded','Failed','Canceled')) {
            $null=Invoke-Api -Method POST -Id ($operation.id+'/cancel') -ApiVersion '2022-09-01' -Purpose 'Cancel pending owned deployment'
            $activeDeployments += $operation.id
        }
    }
    foreach($deploymentId in $activeDeployments) {
        $script:CurrentSubscription=($deploymentId -split '/')[2]
        $limit=[DateTime]::UtcNow.AddMinutes(20)
        do {
            $state=(Invoke-Api -Method GET -Id $deploymentId -ApiVersion '2022-09-01').value.properties.provisioningState
            if($state -in @('Succeeded','Failed','Canceled')){break}
            if([DateTime]::UtcNow -ge $limit){throw 'Owned deployment cancellation is still pending; deletion has not started.'}
            Start-Sleep -Seconds 10
        }while($true)
    }
    Capture-OwnedInventory -ForCleanup
    Capture-OwnedExtensions
    foreach($extension in @($script:Ledger.extensionInventory | Where-Object {$_.kind -notin @('ROLE_ASSIGNMENT','MG_ROLE_ASSIGNMENT','AUTO_SECURITY_ASSIGNMENT')})) {
        $script:CurrentSubscription=($extension.id -split '/')[2]
        $deleted=Invoke-Api -Method DELETE -Id $extension.id -ApiVersion $extension.apiVersion -Purpose 'Cleanup captured owned extension' -MayFail
        if(-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound')){throw ('Extension cleanup failed: '+$deleted.code)}
    }
    foreach ($op in @($script:Ledger.operations | Where-Object {$operation=$_;$external=@($script:Ledger.existingNetworks | Where-Object {$operation.id.StartsWith($_.vnetId+'/',[StringComparison]::OrdinalIgnoreCase)}).Count -gt 0;$operation.method -eq 'PUT' -and $operation.id -match '/(diagnosticSettings|dataCollectionRuleAssociations|policyExemptions)/' -and -not $external} | Sort-Object sequence -Descending)) {
        $script:CurrentSubscription=if($op.id -match '^/subscriptions/'){($op.id -split '/')[2]}else{$SubscriptionIdA}
        $deleted=Invoke-Api -Method DELETE -Id $op.id -ApiVersion $op.apiVersion -Purpose 'Cleanup owned extension' -MayFail
        if (-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {throw ('Extension cleanup failed: '+$deleted.code)}
    }
    # 有料rootとmanaged serviceを全て先にDELETE開始。1サービスの待ち時間を他へ直列化しません。
    $earlyRoots=@($script:Ledger.resources | Where-Object {$_.cleanupEarly -or $_.resourceType -in @('microsoft.containerservice/managedclusters','microsoft.databricks/workspaces','microsoft.monitor/accounts')})
    foreach ($root in $earlyRoots) {
        $script:CurrentSubscription=($root.id -split '/')[2]
        $null=Invoke-Api -Method DELETE -Id $root.id -ApiVersion $root.apiVersion -Purpose 'Start early paid/managed root deletion' -MayFail
    }
    if($script:Ledger.unexpectedVnetDifferences.Count){throw 'Virtual network inventory changed; paid root deletion started, inspect networks before RG cleanup.'}
    # ALW/immutable-versioning accountは空にしてからRG削除。Helperは所有exactIDだけを扱います。
    foreach($storage in @($script:Ledger.inventory | Where-Object {$_.type -ieq 'Microsoft.Storage/storageAccounts'})) {
        try {Remove-OwnedStorageContainers -AccountId $storage.id}
        catch {
            # 1 accountのretention/lockで、他RGの削除開始を止めません。失敗は台帳と最終GETへ残します。
            $script:Ledger.cleanupStartFailures += [pscustomobject]@{id=$storage.id;code='STORAGE_DRAIN_FAILED'}
            Save-Ledger
        }
    }
    # LAはforce deleteでsoft-deleteを残さないよう個別処理（全てrun専用exactID）。
    foreach ($workspace in @($script:Ledger.inventory | Where-Object {$_.type -ieq 'Microsoft.OperationalInsights/workspaces'})) {
        $parts=$workspace.id -split '/'
        $entry=Add-Operation -Method DELETE -Id $workspace.id -ApiVersion '2023-09-01' -Purpose 'Force-delete owned workspace'
        $result=Invoke-AzJson -Arguments @('monitor','log-analytics','workspace','delete','--subscription',$parts[2],'--resource-group',$parts[4],'--workspace-name',$parts[-1],'--force','true','--yes','--no-wait') -MayFail
        $entry.status=if($result.ok){'ACCEPTED'}else{'FAILED'}
        $entry.errorCode=$result.code
        Save-Ledger
        if(-not $result.ok -and $result.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound')) {
            $script:Ledger.cleanupStartFailures += [pscustomobject]@{id=$workspace.id;code=$result.code}
            Save-Ledger
        }
    }
    # AKSとnode RGが消えるまでUAMIを残し、その後に新規サブネット権限だけを戻します。
    if($script:Ledger.ownedExternalRoles.Count -gt 0){
        foreach($aks in @($script:Ledger.resources | Where-Object {$_.resourceType -eq 'microsoft.containerservice/managedclusters'})){
            $script:CurrentSubscription=($aks.id -split '/')[2]
            Wait-ResourceGone -Id $aks.id -ApiVersion $aks.apiVersion
            if($aks.managedResourceGroupNameTemplate){$declaredNodeGroup='/subscriptions/'+(($aks.id -split '/')[2])+'/resourceGroups/'+$aks.managedResourceGroupNameTemplate.Replace('{runId}',$RunId);Wait-ResourceGone -Id $declaredNodeGroup -ApiVersion '2022-09-01'}
            foreach($managed in @($script:Ledger.managedGroups | Where-Object {$_.parentId -ieq $aks.id})){Wait-ResourceGone -Id $managed.id -ApiVersion '2022-09-01';$managed.status='GONE';Save-Ledger}
        }
    }
    foreach($role in $script:Ledger.ownedExternalRoles){
        $network=@($script:Ledger.existingNetworks | Where-Object {$_.role -eq 'A'})[0]
        $definition='/subscriptions/'+$SubscriptionIdA+'/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
        if($role.scope -ine $network.subnets.Private.id -or $role.roleDefinitionId -ine $definition -or $role.beforeAbsent -ne $true){throw 'Existing-subnet role ownership was not verified; preserved.'}
        $script:CurrentSubscription=$SubscriptionIdA
        $fresh=Invoke-Api -Method GET -Id $role.id -ApiVersion '2022-04-01' -MayFail
        if(-not $fresh.ok -and $fresh.code -in @('ResourceNotFound','NotFound','RoleAssignmentNotFound')){continue}
        if(-not $fresh.ok -or -not $role.afterFullProperties -or $fresh.value.id -ine $role.id -or -not (Test-ExternalJsonEqual $fresh.value.properties $role.afterFullProperties) -or $fresh.value.properties.principalId -ine $role.principalId -or $fresh.value.properties.scope -ine $role.scope){throw 'Existing-subnet role changed; no deletion performed.'}
        $plannedIdentity=@($script:Ledger.resources | Where-Object {$_.role -eq 'aks-subnet-identity' -and $_.id -ieq $role.ownerIdentityId})
        if($plannedIdentity.Count -ne 1){throw 'Existing-subnet role identity is not the planned new AKS identity.'}
        $identity=(Invoke-Api -Method GET -Id $plannedIdentity[0].id -ApiVersion $plannedIdentity[0].apiVersion).value
        if($identity.properties.principalId -ine $role.principalId){throw 'Existing-subnet role principal differs from its new identity.'}
        $null=Invoke-Api -Method DELETE -Id $role.id -ApiVersion '2022-04-01' -Purpose 'Remove exact new AKS subnet role'
        Wait-ResourceGone -Id $role.id -ApiVersion '2022-04-01' -MaximumMinutes 5
    }
    $deleteGroups=@()
    foreach ($bundle in $script:Ledger.plan.bundles) {
        $script:CurrentSubscription=$bundle.subscriptionId
        $id='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup
        $found=Invoke-Api -Method GET -Id $id -ApiVersion '2022-09-01' -MayFail
        if (-not $found.ok -and $found.code -in @('ResourceGroupNotFound','ResourceNotFound','NotFound')) {continue}
        if (-not $found.ok -or (Get-PropertyValue (Get-PropertyValue $found.value 'tags') 'fixtureRun') -cne $RunId) {throw 'Resource group ownership cannot be proven.'}
        $deleted=Invoke-Api -Method DELETE -Id $id -ApiVersion '2022-09-01' -Purpose 'Start exclusive run RG deletion' -MayFail
        $deleteGroups += [pscustomobject]@{id=$id;accepted=$deleted.ok;errorCode=$deleted.code}
    }
    # 全RGにDELETEを投入してから待つため、1RGのWORM/長時間RPが別RGの課金停止を妨げません。
    foreach($group in $deleteGroups) {
        $script:CurrentSubscription=($group.id -split '/')[2]
        Wait-ResourceGone -Id $group.id -ApiVersion '2022-09-01'
    }
    foreach($root in $earlyRoots) {
        $script:CurrentSubscription=($root.id -split '/')[2]
        Wait-ResourceGone -Id $root.id -ApiVersion $root.apiVersion
    }
    foreach($managed in $script:Ledger.managedGroups) {
        $script:CurrentSubscription=($managed.id -split '/')[2]
        Wait-ResourceGone -Id $managed.id -ApiVersion '2022-09-01'
        $managed.status='GONE'
        Save-Ledger
    }
    foreach($role in @($script:Ledger.extensionInventory | Where-Object {$entry=$_;$entry.kind -eq 'ROLE_ASSIGNMENT' -and @($script:Ledger.ownedExternalRoles | Where-Object {$_.id -ieq $entry.id}).Count -eq 0})) {
        $script:CurrentSubscription=($role.id -split '/')[2]
        $deleted=Invoke-Api -Method DELETE -Id $role.id -ApiVersion $role.apiVersion -Purpose 'Cleanup remaining owned role assignment' -MayFail
        if(-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound','RoleAssignmentNotFound')){throw ('Owned role cleanup failed: '+$deleted.code)}
    }
    # VNetが自動作成したexact watcherだけを、全owned network回収後に削除します。
    foreach($initial in $script:Ledger.initialState) {
        $script:CurrentSubscription=$initial.subscriptionId
        $remaining=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resources') -ApiVersion '2021-04-01'
        $foreignNetwork=@($remaining | Where-Object {$_.type -like 'Microsoft.Network/*' -and $_.type -ine 'Microsoft.Network/networkWatchers'})
        foreach($watcher in @($script:Ledger.autoWatchers | Where-Object {($_.id -split '/')[2] -ieq $initial.subscriptionId -and $_.status -ne 'AMBIGUOUS_PRESERVE'})) {
            if($foreignNetwork.Count -gt 0) {
                $watcher.status='AMBIGUOUS_PRESERVE'
                $script:Ledger.externalDifferences += [pscustomobject]@{id=$watcher.id;type='Microsoft.Network/networkWatchers';status='FOREIGN_NETWORK_PRESENT_PRESERVED'}
                continue
            }
            $deleted=Invoke-Api -Method DELETE -Id $watcher.id -ApiVersion $watcher.apiVersion -Purpose 'Cleanup proven automatic NetworkWatcher' -MayFail
            if(-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','ResourceGroupNotFound','NotFound')){throw ('Automatic NetworkWatcher deletion failed: '+$deleted.code)}
            Wait-ResourceGone -Id $watcher.id -ApiVersion $watcher.apiVersion
            $watcher.status='GONE'
            if($watcher.deleteGroupIfEmpty) {
                $group=Invoke-Api -Method GET -Id $watcher.groupId -ApiVersion '2022-09-01' -MayFail
                if($group.ok) {
                    $contents=@(Get-ApiPages -Id ($watcher.groupId+'/resources') -ApiVersion '2021-04-01')
                    if($contents.Count -eq 0) {
                        $null=Invoke-Api -Method DELETE -Id $watcher.groupId -ApiVersion '2022-09-01' -Purpose 'Cleanup initially absent empty NetworkWatcherRG'
                        Wait-ResourceGone -Id $watcher.groupId -ApiVersion '2022-09-01'
                    }
                }elseif($group.code -notin @('ResourceGroupNotFound','ResourceNotFound','NotFound')){throw ('Automatic NetworkWatcherRG state unresolved: '+$group.code)}
            }
            Save-Ledger
        }
    }
    foreach ($child in $script:Ledger.autoChildIds) { $script:CurrentSubscription=($child.id -split '/')[2]
    Wait-ResourceGone -Id $child.id -ApiVersion $child.apiVersion -MaximumMinutes 15 }
    # KV/Cognitiveのrecoverable資源はactive資源とは別に結果を残します。
    $script:Ledger.softDeleteResults=@()
    foreach ($item in @($script:Ledger.inventory | Where-Object {$_.type -in @('Microsoft.KeyVault/vaults','Microsoft.CognitiveServices/accounts')})) {
        $parts=$item.id -split '/'
        $script:CurrentSubscription=$parts[2]
        if($item.type -ieq 'Microsoft.KeyVault/vaults') {
            $result=Invoke-AzJson -Arguments @('keyvault','purge','--subscription',$parts[2],'--name',$parts[-1],'--location',$item.location) -MayFail
        } else {
            $result=Invoke-AzJson -Arguments @('cognitiveservices','account','purge','--subscription',$parts[2],'--resource-group',$parts[4],'--name',$parts[-1],'--location',$item.location) -MayFail
        }
        $deletedId=if($item.type -ieq 'Microsoft.KeyVault/vaults'){'/subscriptions/'+$parts[2]+'/providers/Microsoft.KeyVault/locations/'+$item.location+'/deletedVaults/'+$parts[-1]}else{'/subscriptions/'+$parts[2]+'/providers/Microsoft.CognitiveServices/locations/'+$item.location+'/resourceGroups/'+$parts[4]+'/deletedAccounts/'+$parts[-1]}
        $deletedApi=if($item.type -ieq 'Microsoft.KeyVault/vaults'){'2023-07-01'}else{@($script:Template.resources | Where-Object {$_.type -ieq 'Microsoft.CognitiveServices/accounts'})[0].apiVersion}
        $status='RESIDUAL_OR_UNRESOLVED'
        $code=$result.code
        try {Wait-ResourceGone -Id $deletedId -ApiVersion $deletedApi -MaximumMinutes 10
        $status='RECOVERABLE_GONE'
        $code=$null}catch{}
        $script:Ledger.softDeleteResults += [pscustomobject]@{
            id=$item.id
            deletedId=$deletedId
            purgeAccepted=$result.ok
            errorCode=$code
            status=$status
        }
        Save-Ledger
    }
    Restore-ExistingNetworkChanges
    # 課金root回収後にsubscription側副作用を戻します。保護guard失敗で有料rootを保持しません。
    foreach($extension in @($script:Ledger.extensionInventory | Where-Object {$_.kind -eq 'AUTO_SECURITY_ASSIGNMENT'})) {
        $script:CurrentSubscription=($extension.id -split '/')[2]
        $fresh=Invoke-Api -Method GET -Id $extension.id -ApiVersion $extension.apiVersion -MayFail
        if(-not $fresh.ok -and $fresh.code -in @('ResourceNotFound','NotFound')){continue}
        if(-not $fresh.ok -or (ConvertTo-Json $fresh.value -Depth 100 -Compress) -cne (ConvertTo-Json $extension.snapshot -Depth 100 -Compress)){throw 'Auto Security assignment changed or is unreadable; no DELETE performed.'}
        $null=Invoke-Api -Method DELETE -Id $extension.id -ApiVersion $extension.apiVersion -Purpose 'Cleanup exact unmodified automatic Security assignment'
    }
    $mg=$script:Ledger.managementGroupId
    foreach($pattern in @('/policyAssignments/','/policySetDefinitions/','/policyDefinitions/')) {
        foreach($op in @($script:Ledger.operations | Where-Object {$_.method -eq 'PUT' -and $_.id.StartsWith($mg+'/providers/Microsoft.Authorization/') -and $_.id.Contains($pattern)} | Sort-Object sequence -Descending)) {
            $null=Invoke-Api -Method DELETE -Id $op.id -ApiVersion $op.apiVersion -Purpose 'Cleanup run policy' -MayFail
        }
    }
    foreach($parent in $script:Ledger.subscriptionParents) {
        # PUT元parent/subscriptionで元の所属へ戻し、実GETで確認してからMGを削除。
        if($parent.restoreStatus -in @('MOVE_INTENT','RESTORE_REQUIRED')) {
            $null=Invoke-Api -Method PUT -Id ($parent.parentId+'/subscriptions/'+$parent.subscriptionId) -ApiVersion '2020-05-01' -Body @{} -Purpose 'Restore original subscription parent'
            $restored=Invoke-Api -Method GET -Id ($parent.parentId+'/subscriptions/'+$parent.subscriptionId) -ApiVersion '2020-05-01'
            if(-not $restored.ok) {throw 'Parent restore GET failed.'}
            $parent.restoreStatus='RESTORED'
            Save-Ledger
        }
    }
    foreach($role in @($script:Ledger.extensionInventory | Where-Object {$_.kind -eq 'MG_ROLE_ASSIGNMENT'})) {
        $script:CurrentSubscription=$SubscriptionIdA
        $deleted=Invoke-Api -Method DELETE -Id $role.id -ApiVersion $role.apiVersion -Purpose 'Cleanup run MG automatic role' -MayFail
        if(-not $deleted.ok -and $deleted.code -notin @('ResourceNotFound','NotFound','RoleAssignmentNotFound')){throw ('MG role cleanup failed: '+$deleted.code)}
    }
    $null=Invoke-Api -Method DELETE -Id $mg -ApiVersion '2020-05-01' -Purpose 'Cleanup run MG' -MayFail
    Wait-ResourceGone -Id $mg -ApiVersion '2020-05-01' -MaximumMinutes 15
    # 既知exactIDを再GET。RG list空だけで子scopeの削除を合格にしません。
    $script:Ledger.residualChecks=@()
    $checks=@($script:Ledger.extensionInventory)+@($script:Ledger.autoChildIds)+@($script:Ledger.autoWatchers)
    foreach($resource in $script:Ledger.resources) {
        $checks += [pscustomobject]@{id=$resource.id
        apiVersion=$resource.apiVersion}
        foreach($suffix in $resource.scopeSuffixes){$checks += [pscustomobject]@{id=($resource.id+$suffix)
        apiVersion=$resource.childApiVersion}}
    }
    foreach($check in @($checks | Sort-Object id -Unique)) {
        $script:CurrentSubscription=if($check.id.StartsWith('/subscriptions/')){($check.id -split '/')[2]}else{$SubscriptionIdA}
        $probe=Invoke-Api -Method GET -Id $check.id -ApiVersion $check.apiVersion -MayFail
        $gone=-not $probe.ok -and $probe.code -in @('ResourceNotFound','ResourceGroupNotFound','NotFound','RoleAssignmentNotFound','DiagnosticSettingNotFound')
        $script:Ledger.residualChecks += [pscustomobject]@{id=$check.id
        status=if($gone){'EXACT_ID_GONE'}else{'ACTIVE_OR_UNRESOLVED'}
        errorCode=$probe.code}
    }
    foreach($initial in $script:Ledger.initialState) {
        $script:CurrentSubscription=$initial.subscriptionId
        $deletedWorkspaces=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/providers/Microsoft.OperationalInsights/deletedWorkspaces') -ApiVersion '2023-09-01'
        foreach($workspace in @($script:Ledger.inventory | Where-Object {$_.type -ieq 'Microsoft.OperationalInsights/workspaces' -and ($_.id -split '/')[2] -ieq $initial.subscriptionId})) {
            $residual=@($deletedWorkspaces | Where-Object {$_.id -ieq $workspace.id -or (Get-PropertyValue $_.properties 'originalResourceId' '') -ieq $workspace.id}).Count -gt 0
            $script:Ledger.softDeleteResults += [pscustomobject]@{
                id=$workspace.id
                deletedId=$workspace.id
                purgeAccepted=$null
                errorCode=$null
                status=if($residual){'RECOVERABLE_LA_RESIDUAL'}else{'RECOVERABLE_GONE'}
            }
        }
    }
    }
    # この一覧はMicrosoft.ResourcesのAPI。RP解除後の再実行でも安全に残存を確認します。
    foreach($initial in $script:Ledger.initialState) {
        $script:CurrentSubscription=$initial.subscriptionId
        $resources=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resources') -ApiVersion '2021-04-01'
        $groups=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resourcegroups') -ApiVersion '2022-09-01'
        if((@($resources | ForEach-Object {$_.id} | Sort-Object -Unique) -join "`n") -ine (@($initial.resourceIds | Sort-Object -Unique) -join "`n") -or
            (@($groups | ForEach-Object {$_.id} | Sort-Object -Unique) -join "`n") -ine (@($initial.groupIds | Sort-Object -Unique) -join "`n")) {throw 'Resource or resource-group differences remain; provider restoration has not started.'}
    }
    $storageRestoreIssues=@(Get-PropertyValue $script:Ledger 'storageCleanup' @() | Where-Object {$_.restoreStatus -notin @('RESTORED_AND_GET_VERIFIED','ACCOUNT_ALREADY_GONE')}).Count
    $storageDrainIssues=@(Get-PropertyValue $script:Ledger 'storageCleanup' @() | Where-Object {$_.status -ne 'CONTAINERS_GONE'}).Count
    $resourceProblems=$storageRestoreIssues+$storageDrainIssues+@($script:Ledger.cleanupStartFailures).Count+@($script:Ledger.residualChecks | Where-Object {$_.status -ne 'EXACT_ID_GONE'}).Count+@($script:Ledger.softDeleteResults | Where-Object {$_.status -ne 'RECOVERABLE_GONE'}).Count+@($script:Ledger.externalDifferences).Count+@($script:Ledger.managedGroups | Where-Object {$_.status -ne 'GONE'}).Count+@($script:Ledger.subscriptionParents | Where-Object {$_.restoreStatus -notin @('NOT_MOVED','RESTORED')}).Count
    if($resourceProblems -gt 0){throw 'Resource cleanup is incomplete; provider restoration has not started.'}
    if(-not $resourcesComplete) {
        $script:Ledger | Add-Member -MemberType NoteProperty -Name resourceCleanupComplete -Value $true -Force
        Save-Ledger
    }
    # 初期全provider状態とのdiff。外部資源があるRPや初期遷移状態をunregisterしません。
    $script:Ledger.providerRestoreResults=@()
    foreach($initial in $script:Ledger.initialState) {
        $script:CurrentSubscription=$initial.subscriptionId
        $current=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/providers') -ApiVersion '2021-04-01'
        $remaining=Get-ApiPages -Id ('/subscriptions/'+$initial.subscriptionId+'/resources') -ApiVersion '2021-04-01'
        foreach($before in $initial.providers) {
            $after=@($current | Where-Object {$_.namespace -ieq $before.namespace})
            if($after.Count -ne 1 -or $after[0].registrationState -eq $before.registrationState){continue}
            $state=$after[0].registrationState
            $reason='Initial transitional state or foreign resources: preserved; provider delta remains'
            $registerId='/subscriptions/'+$initial.subscriptionId+'/providers/'+$before.namespace+'/register'
            $ownedRegistration=@($script:Ledger.operations | Where-Object {$_.id -ieq $registerId -and $_.method -eq 'POST' -and $_.status -eq 'ACCEPTED'}).Count -gt 0
            if($before.namespace -ieq 'Microsoft.Security' -and @($script:Ledger.extensionInventory | Where-Object {$_.kind -eq 'AUTO_SECURITY_ASSIGNMENT' -and $_.id.StartsWith('/subscriptions/'+$initial.subscriptionId+'/')}).Count -gt 0){$ownedRegistration=$true}
            # 未登録には2通りの応答値があります。実際の値をobservedに残します。
            if($before.registrationState -in @('NotRegistered','Unregistered') -and $state -in @('NotRegistered','Unregistered')) {
                $reason='RESTORED_NOT_REGISTERED'
            }elseif($ownedRegistration -and $before.registrationState -in @('NotRegistered','Unregistered') -and $state -in @('Registered','Unregistering') -and @($remaining | Where-Object {($_.type -split '/')[0] -ieq $before.namespace}).Count -eq 0) {
                $id='/subscriptions/'+$initial.subscriptionId+'/providers/'+$before.namespace+'/unregister'
                $unregisterAccepted=$state -eq 'Unregistering'
                if($state -eq 'Registered') {
                    $restore=Invoke-Api -Method POST -Id $id -ApiVersion '2021-04-01' -Body @{} -Purpose 'Restore initially unregistered RP' -MayFail
                    $unregisterAccepted=$restore.ok
                    if(-not $restore.ok){$reason='UNREGISTER_FAILED_'+$restore.code}
                }
                if($unregisterAccepted) {
                    $until=[DateTime]::UtcNow.AddMinutes(20)
                    do {
                        $state=(Invoke-Api -Method GET -Id ('/subscriptions/'+$initial.subscriptionId+'/providers/'+$before.namespace) -ApiVersion '2021-04-01').value.registrationState
                        if($state -in @('NotRegistered','Unregistered') -or [DateTime]::UtcNow -ge $until){break}
                        Start-Sleep -Seconds 10
                    }while($true)
                    $reason=if($state -in @('NotRegistered','Unregistered')){'RESTORED_NOT_REGISTERED'}else{'UNREGISTER_NOT_COMPLETED'}
                }
            }
            $script:Ledger.providerRestoreResults += [pscustomobject]@{
                subscriptionId=$initial.subscriptionId
                namespace=$before.namespace
                initial=$before.registrationState
                observed=$state
                result=$reason
            }
        }
    }
    $problems=$resourceProblems+@($script:Ledger.providerRestoreResults | Where-Object {$_.result -ne 'RESTORED_NOT_REGISTERED'}).Count
    $script:Ledger.status=if($problems -eq 0){'CLEANUP_VERIFIED'}else{'CLEANUP_INCOMPLETE_RESIDUALS_REPORTED'}
    Save-Ledger
    Write-JsonFile -Path (Join-Path $script:RunPath 'cleanup-result.json') -Value @{
        status=$script:Ledger.status
        exactIdChecks=$script:Ledger.residualChecks
        softDelete=$script:Ledger.softDeleteResults
        providerRestoration=$script:Ledger.providerRestoreResults
        externalDifferences=$script:Ledger.externalDifferences
        managedGroups=$script:Ledger.managedGroups
        subscriptionParents=$script:Ledger.subscriptionParents
        storageCleanup=(Get-PropertyValue $script:Ledger 'storageCleanup' @())
        cleanupStartFailures=$script:Ledger.cleanupStartFailures
    }
    Write-Host ('Cleanup: '+$script:Ledger.status+'; details in cleanup-result.json')
}

# ここから上から順に実行します。Plan の経路にはAzure CLI呼び出しがありません。
foreach ($id in @($SubscriptionIdA,$SubscriptionIdB)) { if($id -notmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$'){throw 'Invalid subscription ID.'} }
if($SubscriptionIdA -ieq $SubscriptionIdB){throw 'Two distinct subscriptions are required.'}
if(-not $RunId){$RunId=[DateTime]::UtcNow.ToString('yyMMddHHmm')+([Guid]::NewGuid().ToString('N').Substring(0,3))}
if($RunId -notmatch '^[a-z0-9]{8,13}$'){throw 'RunId must be 8–13 lowercase letters/digits.'}
if(-not $RunRoot){$RunRoot=Join-Path $PSScriptRoot 'runs'}
$script:RunPath=Join-Path $RunRoot $RunId
$script:LedgerPath=Join-Path $script:RunPath 'run-ledger.json'
$plan=Build-Plan
if($Action -eq 'Plan'){
    if(Test-Path -LiteralPath (Join-Path $script:RunPath 'plan.json')){throw 'RunId plan exists; choose another RunId.'}
    $null=New-Item -ItemType Directory -Path $script:RunPath -Force
    Write-JsonFile -Path (Join-Path $script:RunPath 'plan.json') -Value $plan
    Write-Host ('LOCAL plan: '+(Join-Path $script:RunPath 'plan.json'))
    Write-Host ('56-type catalog; selected keys: '+$plan.selectedKeys.Count+'; budget undecided until user review. Azure calls: 0.')
    return
}
if($Action -in @('Deploy','Seed')){Assert-SpendApproval}
if(-not (Get-Command az -ErrorAction SilentlyContinue)){throw 'Azure CLI required. Script never runs az login.'}
if($Action -eq 'Deploy'){
    if(Test-Path -LiteralPath $script:LedgerPath){throw 'Deploy ledger already exists. Cleanup is resumable; new Deploy must use a new RunId.'}
    $frozenPath=Join-Path $script:RunPath 'plan.json'
    if(-not (Test-Path -LiteralPath $frozenPath)){throw 'Run Plan first and review its concrete resources before Deploy.'}
    $frozen=Get-Content -LiteralPath $frozenPath -Raw -Encoding UTF8 | ConvertFrom-Json
    if((Get-PlanFingerprint $frozen) -cne (Get-PlanFingerprint $plan)){throw 'Reviewed Plan differs from Deploy selection/template/regions. Create and review a new RunId plan.'}
    if(@($plan.selectedKeys | Where-Object {$_ -in @('computeVm','computeVmss','aks')}).Count -gt 0 -and $AdminSshPublicKey -notmatch '^ssh-(rsa|ed25519) [A-Za-z0-9+/=]+'){throw 'Supply an SSH public key for selected compute resources.'}
    $null=New-Item -ItemType Directory -Path $script:RunPath -Force
    # CLI同梱SDKのLOCAL能力確認を、最初の認証/サービスAPIより前に実施します。
    Assert-StorageSdkLocal
    $account=(Invoke-AzJson -Arguments @('account','show','--subscription',$SubscriptionIdA)).value
    $other=(Invoke-AzJson -Arguments @('account','show','--subscription',$SubscriptionIdB)).value
    if($account.tenantId -ine $other.tenantId){throw 'Subscriptions must belong to the same tenant.'}
    $script:Ledger=[pscustomobject]@{
        schemaVersion=1
        runId=$RunId
        startedUtc=[DateTime]::UtcNow.ToString('o')
        status='CAPTURING'
        tenantId=$account.tenantId
        plan=$plan
        initialCaptureComplete=$false
        existingNetworks=@()
        createdExternalDiagnostics=@()
        ownedExternalRoles=@()
        unexpectedVnetDifferences=@()
        resourceCleanupComplete=$false
        initialState=@()
        subscriptionParents=@()
        managementGroupId=('/providers/Microsoft.Management/managementGroups/fx-'+$RunId)
        managementGroupParentId=''
        sourceWorkspaceId=''
        sharedStorageId=''
        operations=@()
        deployments=@()
        cleanupStartFailures=@()
        storageCleanup=@()
        resources=@(Build-ExpectedResources -Plan $plan)
        inventory=@()
        observedWriteIds=@()
        managedGroups=@()
        autoWatchers=@()
        autoChildIds=@()
        scopes=@()
        collectorAssociations=@()
        extensionInventory=@()
        externalDifferences=@()
        softDeleteResults=@()
        providerRestoreResults=@()
        residualChecks=@()
    }
    Save-Ledger
    try {
        Capture-InitialState
        Register-RequiredProviders
        Create-ManagementFixture
        foreach($bundle in $plan.bundles){
            $script:CurrentSubscription=$bundle.subscriptionId
            $id='/subscriptions/'+$bundle.subscriptionId+'/resourceGroups/'+$bundle.resourceGroup
            $before=Invoke-Api -Method GET -Id $id -ApiVersion '2022-09-01' -MayFail
            if($before.ok -or $before.code -notin @('ResourceGroupNotFound','ResourceNotFound','NotFound')){throw 'RG creation collision or unresolved existence.'}
            $null=Invoke-Api -Method PUT -Id $id -ApiVersion '2022-09-01' -Body @{location=$bundle.location
            tags=@{fixtureRun=$RunId}} -Purpose 'Create exclusive run RG'
        }
        # 共通LA/Storageを先行。型別分岐をPSへ増やさずmetadataのphaseを使います。
        foreach($bundle in $plan.bundles){
            $foundation=@($script:Template.resources | Where-Object {$_.metadata.fixture.bundle -eq $bundle.key -and $_.metadata.fixture.phase -eq 'foundation' -and $bundle.keys -contains $_.metadata.fixture.key} | ForEach-Object {$_.metadata.fixture.key} | Sort-Object -Unique)
            Invoke-BundleDeployment -Bundle $bundle -Keys $foundation -Phase 'foundation'
        }
        # 既存サブネットへのAKS接続に必要な権限だけを、新規UAMIへ付与します。
        $aksIdentity=@($script:Ledger.resources | Where-Object {$_.role -eq 'aks-subnet-identity'})
        if($aksIdentity.Count -gt 1){throw 'AKS subnet identity is not unique.'}
        if($aksIdentity.Count -eq 1){
            $network=@($script:Ledger.existingNetworks | Where-Object {$_.role -eq 'A'})[0]
            $scopeId=$network.subnets.Private.id
            $script:CurrentSubscription=$SubscriptionIdA
            $identity=(Invoke-Api -Method GET -Id $aksIdentity[0].id -ApiVersion $aksIdentity[0].apiVersion).value
            $principal=$identity.properties.principalId
            if(-not $principal){throw 'New AKS identity principal is unavailable.'}
            $roleDefinition='/subscriptions/'+$SubscriptionIdA+'/providers/Microsoft.Authorization/roleDefinitions/4d97b98b-1d4f-4787-a291-c67834d212e7'
            $roleId=$scopeId+'/providers/Microsoft.Authorization/roleAssignments/'+[Guid]::NewGuid().ToString('D')
            $before=Invoke-Api -Method GET -Id $roleId -ApiVersion '2022-04-01' -MayFail
            if($before.ok -or $before.code -notin @('NotFound','ResourceNotFound','RoleAssignmentNotFound')){throw 'Existing-subnet role name collided or existence is unresolved.'}
            $record=[pscustomobject]@{id=$roleId;before=$null;beforeAbsent=$true;afterFullProperties=$null;ownerIdentityId=$aksIdentity[0].id;principalId=$principal;scope=$scopeId;roleDefinitionId=$roleDefinition}
            $script:Ledger.ownedExternalRoles += $record
            Save-Ledger
            $null=Invoke-Api -Method PUT -Id $roleId -ApiVersion '2022-04-01' -Body @{properties=@{roleDefinitionId=$roleDefinition;principalId=$principal;principalType='ServicePrincipal';description=('Fixture '+$RunId+' AKS existing subnet')}} -Purpose 'Assign new AKS identity to exact existing subnet'
            $after=(Invoke-Api -Method GET -Id $roleId -ApiVersion '2022-04-01').value
            if($after.id -ine $roleId -or $after.properties.principalId -ine $principal -or $after.properties.scope -ine $scopeId -or $after.properties.roleDefinitionId -ine $roleDefinition){throw 'New existing-subnet role readback differs.'}
            $record.afterFullProperties=$after.properties
            Save-Ledger
        }
        $tickets=@()
        $startFailures=@()
        foreach($bundle in $plan.bundles) {
            try {$tickets += Invoke-BundleDeployment -Bundle $bundle -Keys @($bundle.keys) -Phase 'resources' -NoWait}
            catch {$startFailures += $bundle.key}
        }
        Wait-BundleDeployments -Tickets $tickets
        if($startFailures.Count -gt 0){throw 'One or more resource bundle submissions failed; inspect run ledger and use Cleanup.'}
        Capture-OwnedInventory
        Read-ExistingNetworks
        Create-CollectorAssociations
        $null=Capture-Scopes
        $script:Ledger.status='DEPLOYED_CAPABILITIES_PENDING_SEED'
        Save-Ledger
        Write-Host ('Fixture deployment finished; independent candidates: '+(Join-Path $script:RunPath 'expected-scopes.json'))
    } catch {
        $script:Ledger.status='FAILED_CLEANUP_REQUIRED'
        Save-Ledger
        # コマンド応答に秘密値が含まれる可能性があるため、例外本文を成果物へ書きません。
        try {Capture-OwnedInventory} catch {}
        throw
    }
    return
}
if(-not (Test-Path -LiteralPath $script:LedgerPath)){throw 'Run ledger required. No prefix-based cleanup is supported.'}
$script:Ledger=Get-Content -LiteralPath $script:LedgerPath -Raw -Encoding UTF8 | ConvertFrom-Json
if($script:Ledger.runId -cne $RunId -or @($script:Ledger.plan.subscriptionIds).Count -ne 2 -or $script:Ledger.plan.subscriptionIds[0] -ine $SubscriptionIdA -or $script:Ledger.plan.subscriptionIds[1] -ine $SubscriptionIdB){throw 'Run ledger/subscription identity mismatch.'}
if($script:Ledger.plan.templateSha256 -cne (Get-FileHash -LiteralPath $script:TemplatePath -Algorithm SHA256).Hash){throw 'Template changed after run plan. Use the original reviewed template.'}
switch($Action){
    'Capture' {Read-ExistingNetworks
    Capture-OwnedInventory
    if(@($script:Ledger.scopes).Count -eq 0){$null=Capture-Scopes}
    Capture-OwnedExtensions
    Write-Host 'Owned inventory/extensions captured; existing SourceDiag evidence preserved.'}
    'Seed' {Read-ExistingNetworks
    Seed-SourceDiagnostics
    Write-Host 'SourceDiag capabilities written. UNRESOLVED/FAILED/skipped scopes are not PASS.'}
    'Cleanup' {
        try {Cleanup-Run}
        catch {
            $script:Ledger.status='CLEANUP_INCOMPLETE_ABORTED'
            Save-Ledger
            Write-JsonFile -Path (Join-Path $script:RunPath 'cleanup-result.json') -Value @{
                status=$script:Ledger.status
                errorCode='CLEANUP_ABORTED'
                storageCleanup=(Get-PropertyValue $script:Ledger 'storageCleanup' @())
                cleanupStartFailures=$script:Ledger.cleanupStartFailures
            }
            throw
        }
    }
}
