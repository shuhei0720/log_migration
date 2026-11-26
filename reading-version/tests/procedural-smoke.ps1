#Requires -Version 7.0
param(
    [string]$Repository = (Join-Path (Split-Path -Parent $PSScriptRoot) 'procedural-migration'),
    [string]$ReportPath,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$sourceFiles = @('common.ps1', 'precheck.ps1', 'step1_copy.ps1', 'step2_verify.ps1', 'step3_delete.ps1', 'rollback.ps1')
$sourceHashes = @{}
foreach ($name in $sourceFiles) {
    $sourceHashes[$name] = (Get-FileHash (Join-Path $Repository $name) -Algorithm SHA256).Hash
}
$checks = 0
$cases = [Collections.Generic.List[object]]::new()
$scratch = Join-Path ([IO.Path]::GetTempPath()) ('procedural-migration-' + [guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $scratch
if (-not ('ProceduralReplay.SharedFixture' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Collections.Generic;
namespace ProceduralReplay {
    public static class SharedFixture {
        public static object State;
        public static readonly object SyncRoot = new object();
    }
    public class Response {
        public int StatusCode;
        public Dictionary<string,string> Headers = new Dictionary<string,string>();
    }
    public class NetworkIOException : System.IO.IOException {
        public string HttpRequestError { get; private set; }
        public NetworkIOException(string error) : base("TEST_NETWORK_FAILURE") { HttpRequestError = error; }
    }
    public class HttpFailure : Exception {
        public Response Response;
        public HttpFailure(int status, string message) : base(message) {
            Response = new Response();
            Response.StatusCode = status;
            Response.Headers["Retry-After"] = "0";
        }
    }
}
'@
}
$global:ProceduralFixture = @{}
[ProceduralReplay.SharedFixture]::State = $global:ProceduralFixture
$mainRunspaceId = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
$parallelRunspaceIds = [Collections.Generic.HashSet[string]]::new()
$parallelRequestCount = 0

function Assert-Replay {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) {
        throw "手続型版の検証失敗: $script:activeCase / $Message"
    }
}
function Copy-FixtureValue {
    param($Value)
    ConvertTo-Json -InputObject $Value -Depth 50 | ConvertFrom-Json
}
function Set-FixtureProperty {
    param($Object, [string]$Name, $Value)
    $Object | Add-Member -NotePropertyName $Name -NotePropertyValue $Value -Force
}
function Merge-FixtureBody {
    param($Current, $Update)
    $result = Copy-FixtureValue $Current
    if (-not $result) {
        return Copy-FixtureValue $Update
    }
    foreach ($property in $Update.PSObject.Properties) {
        $value = $property.Value
        if ($value -is [pscustomobject] -and $result.($property.Name) -is [pscustomobject]) {
            $value = Merge-FixtureBody $result.($property.Name) $value
        }
        Set-FixtureProperty $result $property.Name $value
    }
    return $result
}
function Get-FixtureIds {
    param([string]$SubscriptionId)
    $group = "/subscriptions/$SubscriptionId/resourceGroups/rg-target"
    [pscustomobject]@{
        Group = $group
        Workspace = "$group/providers/Microsoft.OperationalInsights/workspaces/log-new"
        Dcr = "$group/providers/Microsoft.Insights/dataCollectionRules/dcr-new"
        Storage = "$group/providers/Microsoft.Storage/storageAccounts/stjpe$($SubscriptionId.Substring(0, 4))"
    }
}
function az {
    $global:ProceduralFixture = [ProceduralReplay.SharedFixture]::State
    [Threading.Monitor]::Enter([ProceduralReplay.SharedFixture]::SyncRoot)
    try {
        $arguments = @($args)
        $global:LASTEXITCODE = 0
        if (($arguments[0..1] -join '/') -eq 'account/list') {
            ConvertTo-Json -InputObject @($global:ProceduralFixture.Subscriptions | ForEach-Object {
                @{ id = $_; name = $_ }
            }) -Compress
            return
        }
        if (($arguments[0..1] -join '/') -eq 'account/get-access-token') {
            $subscriptionIndex = [Array]::IndexOf($arguments, '--subscription')
            if ($subscriptionIndex -lt 0 -or $arguments[$subscriptionIndex + 1] -notin $global:ProceduralFixture.Subscriptions) {
                throw 'TEST_WORKER_SUBSCRIPTION_MISSING'
            }
            $global:ProceduralFixture.TokenReads++
            if ($global:ProceduralFixture.FailToken) {
                $global:LASTEXITCODE = 1
                return
            }
            ConvertTo-Json @{ accessToken = 'offline-test-token'; expires_on = 4102444800 } -Compress
            return
        }
        throw "想定外CLI: $($arguments -join ' ')"
    }
    finally {
        [Threading.Monitor]::Exit([ProceduralReplay.SharedFixture]::SyncRoot)
    }
}
function Start-Sleep {
    param([int]$Seconds, [int]$Milliseconds)
    $global:ProceduralFixture = [ProceduralReplay.SharedFixture]::State
    [Threading.Monitor]::Enter([ProceduralReplay.SharedFixture]::SyncRoot)
    try {
        $global:ProceduralFixture.SleepCalls++
        $global:ProceduralFixture.SleepSeconds.Add($Seconds)
        $global:ProceduralFixture.ClockOffset += $global:ProceduralFixture.ClockStep
    }
    finally {
        [Threading.Monitor]::Exit([ProceduralReplay.SharedFixture]::SyncRoot)
    }
}
function Get-Date {
    param([string]$Format)
    $global:ProceduralFixture = [ProceduralReplay.SharedFixture]::State
    [Threading.Monitor]::Enter([ProceduralReplay.SharedFixture]::SyncRoot)
    try {
        $date = [DateTime]::Now.AddSeconds($global:ProceduralFixture.ClockOffset)
        if ($Format) {
            return $date.ToString($Format)
        }
        return $date
    }
    finally {
        [Threading.Monitor]::Exit([ProceduralReplay.SharedFixture]::SyncRoot)
    }
}
function Invoke-RestMethod {
    param($Uri, $Method = 'Get', $Headers, $ContentType, $TimeoutSec, $Body)
    $global:ProceduralFixture = [ProceduralReplay.SharedFixture]::State
    [Threading.Monitor]::Enter([ProceduralReplay.SharedFixture]::SyncRoot)
    try {
        $fixture = $global:ProceduralFixture
        if ([string]$Uri -like 'https://raw.githubusercontent.com/*') {
            $fixture.RegionReads++
            $regions = @(
                [pscustomobject]@{ name = 'japaneast'; shortName = 'jpe' },
                [pscustomobject]@{ name = 'japanwest'; shortName = 'jpw' },
                [pscustomobject]@{ name = 'canadacentral'; shortName = 'cac' }
            )
            return ,$regions
        }
        $address = [uri]$Uri
        if ($address.Host -ne 'management.azure.com') {
            throw "外部通信を禁止しています: $Uri"
        }
        $path = [uri]::UnescapeDataString($address.AbsolutePath).TrimEnd('/')
        $methodName = ([string]$Method).ToUpperInvariant()
        $fixture.Reads.Add($path)
        $runspaceId = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
        if ($runspaceId -ne $fixture.MainRunspaceId) {
            $fixture.WorkerRequestCount++
            $null = $fixture.WorkerRunspaceIds.Add($runspaceId)
        }
        $fixture.Requests.Add([pscustomobject]@{
            Method = $methodName
            Id = $path
            RunspaceId = [Management.Automation.Runspaces.Runspace]::DefaultRunspace.InstanceId.ToString()
            ThreadId = [Threading.Thread]::CurrentThread.ManagedThreadId
            HasBody = ($null -ne $Body)
        })
        $key = "$methodName $path"
        if ($fixture.TransportFailures.ContainsKey($key) -and $fixture.TransportFailures[$key].Remaining -gt 0) {
            $failure = $fixture.TransportFailures[$key]
            $failure.Remaining--
            switch ($failure.Type) {
                Disconnect { throw [System.Net.Http.HttpRequestException]::new('TEST_CONNECTION_LOST', [System.IO.IOException]::new('TEST_SOCKET_ENDED')) }
                BodyEnded { throw [ProceduralReplay.NetworkIOException]::new('ResponseEnded') }
                Dns { throw [ProceduralReplay.NetworkIOException]::new('NameResolutionError') }
                LegacyDns { throw [System.Net.Http.HttpRequestException]::new('TEST_DNS_FAILURE', [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::HostNotFound)) }
                Timeout { throw [System.Threading.Tasks.TaskCanceledException]::new('TEST_TIMEOUT', [System.TimeoutException]::new('TEST_CONNECTION_TIMEOUT')) }
                OperationTimeout { throw [System.TimeoutException]::new('TEST_BODY_TIMEOUT') }
                Tls { throw [System.Net.Http.HttpRequestException]::new('TEST_TLS', [System.Security.Authentication.AuthenticationException]::new('TEST_CERTIFICATE')) }
                Cancel { throw [System.Threading.Tasks.TaskCanceledException]::new('TEST_USER_CANCEL') }
                CancelSocket { throw [System.Threading.Tasks.TaskCanceledException]::new('TEST_USER_CANCEL', [System.Net.Sockets.SocketException]::new([int][System.Net.Sockets.SocketError]::ConnectionReset)) }
                OperationCancel { throw [System.OperationCanceledException]::new('TEST_USER_CANCEL') }
                OtherIo { throw [System.IO.IOException]::new('TEST_NOT_NETWORK_IO') }
            }
        }
        if ($fixture.HttpFailures.ContainsKey($key) -and $fixture.HttpFailures[$key].Remaining -gt 0) {
            $failure = $fixture.HttpFailures[$key]
            $failure.Remaining--
            $httpFailure = New-Object ProceduralReplay.HttpFailure $failure.Status, $failure.Code
            if ($failure.RetryAfter) { $httpFailure.Response.Headers['Retry-After'] = [string]$failure.RetryAfter }
            throw $httpFailure
        }
        if ($fixture.Failures.ContainsKey($key) -and $fixture.Failures[$key] -gt 0) {
            $fixture.Failures[$key]--
            throw (New-Object ProceduralReplay.HttpFailure 500, "TEST_FAILURE: $key")
        }
        if ($fixture.UnauthorizedReads -gt 0) {
            $fixture.UnauthorizedReads--
            throw (New-Object ProceduralReplay.HttpFailure 401, 'TEST_EXPIRED_TOKEN')
        }
        if ($methodName -eq 'POST' -and $path -like '*/Microsoft.Storage/checkNameAvailability') {
            $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
            $existingNames = @($fixture.Resources.Keys | Where-Object { $_ -match '/Microsoft.Storage/storageAccounts/[^/]+$' } | ForEach-Object { ($_ -split '/')[-1] })
            $available = $payload.name -notin @($fixture.UnavailableNames) + $existingNames
            return [pscustomobject]@{ nameAvailable = $available }
        }
        if ($methodName -eq 'GET') {
            if ($fixture.Pages.ContainsKey([string]$Uri)) {
                return Copy-FixtureValue $fixture.Pages[[string]$Uri]
            }
            if ($path -match '^/subscriptions/([^/]+)/resources$') {
                $subscription = $Matches[1]
                $inventory = @($fixture.Inventory | Where-Object { $_.id -like "/subscriptions/$subscription/*" })
                return [pscustomobject]@{ value = $inventory }
            }
            if ($path -like '*/Microsoft.Storage/skus') {
                return [pscustomobject]@{ value = @(
                    [pscustomobject]@{ name = 'Standard_ZRS'; kind = 'StorageV2'; locations = @($fixture.ZrsLocations) }
                ) }
            }
            if ($path -like '*/dataCollectionRules/*/associations') {
                $ruleId = $path.Substring(0, $path.Length - '/associations'.Length)
                $associations = @(foreach ($id in $fixture.Resources.Keys) {
                    $resource = $fixture.Resources[$id]
                    if ($id -like '*/dataCollectionRuleAssociations/*' -and $resource.properties.dataCollectionRuleId -eq $ruleId) {
                        [pscustomobject]@{ id = $id; properties = @{ dataCollectionRuleId = $ruleId } }
                    }
                })
                return [pscustomobject]@{ value = $associations }
            }
            if ($path -like '*/diagnosticSettings') {
                $parent = $path.Substring(0, $path.Length - '/providers/Microsoft.Insights/diagnosticSettings'.Length)
                $settings = @(foreach ($id in $fixture.Resources.Keys) {
                    if ($id -like "$parent/providers/Microsoft.Insights/diagnosticSettings/*") {
                        Copy-FixtureValue $fixture.Resources[$id]
                    }
                })
                return [pscustomobject]@{ value = $settings }
            }
            if ($path -match '^/subscriptions/[^/]+/providers/(Microsoft\.(Insights|OperationalInsights|Storage|Security))$') {
                $state = 'Registered'
                if ($fixture.UnregisteredProviders.ContainsKey($path)) {
                    $state = $fixture.UnregisteredProviders[$path]
                }
                if ($state -eq 'Registering' -and $fixture.ProviderPendingReads.ContainsKey($path)) {
                    if ($fixture.ProviderPendingReads[$path] -gt 0) { $fixture.ProviderPendingReads[$path]-- }
                    else { $state = 'Registered'; $fixture.UnregisteredProviders[$path] = $state }
                }
                return [pscustomobject]@{ registrationState = $state }
            }
            if ($path -like '*/policyAssignments') {
                return [pscustomobject]@{ value = @($fixture.Assignments | ForEach-Object {
                    [pscustomobject]@{ id = $_.Id; properties = @{ policyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/offline' } }
                }) }
            }
            if ($path -like '*/policyAssignments/*') {
                return [pscustomobject]@{ id = $path; properties = @{ policyDefinitionId = '/providers/Microsoft.Authorization/policySetDefinitions/offline' } }
            }
            if ($path -like '*/policySetDefinitions/*') {
                return [pscustomobject]@{ properties = @{ policyDefinitions = @($fixture.ReferenceIds | ForEach-Object {
                    [pscustomobject]@{ policyDefinitionReferenceId = $_ }
                }) } }
            }
            if ($fixture.Resources.ContainsKey($path)) {
                $value = Copy-FixtureValue $fixture.Resources[$path]
                if ($fixture.PendingReads.ContainsKey($path) -and $fixture.PendingReads[$path] -gt 0) {
                    $fixture.PendingReads[$path]--
                    $pendingState = $fixture.PendingStates[$path] ?? 'Updating'
                    Set-FixtureProperty $value.properties 'provisioningState' $pendingState
                }
                return $value
            }
            throw (New-Object ProceduralReplay.HttpFailure 404, "TEST_NOT_FOUND: $path")
        }
        if ($methodName -notin @('PUT', 'PATCH', 'DELETE', 'POST')) {
            throw "想定外メソッド: $methodName"
        }
        $subscription = ($path -split '/')[2]
        $recordPath = Join-Path $fixture.Repository "records/dev/$subscription.json"
        if (-not (Test-Path $recordPath)) {
            $fixture.WriteBeforeBackup = $true
            throw 'TEST_WRITE_BEFORE_BACKUP'
        }
        $fixture.BackupWitnesses.Add((Get-Content $recordPath -Raw -Encoding UTF8 | ConvertFrom-Json))
        if ($methodName -eq 'DELETE' -and $path -like "*/diagnosticSettings/$($fixture.DiagnosticName)") {
            $activeRecords = @(Get-ChildItem (Join-Path $fixture.Repository 'records/dev') -Filter '*.json' | Where-Object {
                -not $fixture.RollbackSubscriptions -or $_.BaseName -in $fixture.RollbackSubscriptions
            } | ForEach-Object {
                Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
            })
            $ownedNew = @($activeRecords.NewSettings | Where-Object { $_.Id -eq $path -and $_.Kind -eq 'Diagnostic' })
            foreach ($record in @($activeRecords | Where-Object { $ownedNew.Count -gt 0 })) {
                foreach ($old in $record.OldSettings) {
                    if (-not $fixture.Resources.ContainsKey($old.Id)) {
                        $fixture.UnsafeNewDelete = $true
                    }
                }
            }
        }
        $payload = $null
        if ($null -ne $Body) {
            $payload = [Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
        }
        if ($path -like '*/managementPolicies/*' -and $payload -and @($payload.properties.policy.rules | Where-Object { $null -eq $_ }).Count -gt 0) {
            throw (New-Object ProceduralReplay.HttpFailure 400, 'TEST_INVALID_LIFECYCLE_NULL_RULE')
        }
        if ($methodName -eq 'DELETE' -and -not $fixture.Resources.ContainsKey($path)) {
            throw (New-Object ProceduralReplay.HttpFailure 404, "TEST_NOT_FOUND: $path")
        }
        $fixture.Writes.Add([pscustomobject]@{ Method = $methodName; Id = $path; Body = $payload })
        if ($methodName -eq 'DELETE') {
            if ($path -match '/(storageAccounts|workspaces)/[^/]+$') {
                throw 'TEST_DESTINATION_DELETION'
            }
            $fixture.Resources.Remove($path)
            if ($path -eq $fixture.LoseDeleteResponseId) {
                $fixture.LoseDeleteResponseId = ''
                throw [System.Net.Http.HttpRequestException]::new('TEST_DELETE_RESPONSE_LOST', [System.IO.IOException]::new('TEST_SOCKET_ENDED'))
            }
            return $null
        }
        if ($methodName -eq 'POST' -and $path -like '*/register') {
            $providerPath = $path.Substring(0, $path.Length - '/register'.Length)
            $fixture.UnregisteredProviders[$providerPath] = if ($fixture.ProviderPendingReads.ContainsKey($providerPath)) { 'Registering' } else { 'Registered' }
            return [pscustomobject]@{ registrationState = 'Registered' }
        }
        $current = $fixture.Resources[$path]
        $value = Merge-FixtureBody $current $payload
        if ($methodName -eq 'PUT' -and $path -match '/Microsoft.Insights/(dataCollectionRules|dataCollectionRuleAssociations)/') {
            $value = Copy-FixtureValue $payload
        }
        Set-FixtureProperty $value 'id' $path
        Set-FixtureProperty $value 'name' (($path -split '/')[-1])
        if (-not $value.properties) {
            Set-FixtureProperty $value 'properties' ([pscustomobject]@{})
        }
        if ($path -notlike '*/diagnosticSettings/*') {
            Set-FixtureProperty $value.properties 'provisioningState' 'Succeeded'
        }
        if ($path -like '*/tables/*' -and $payload.properties.PSObject.Properties.Name -contains 'totalRetentionInDays') {
            Set-FixtureProperty $value.properties 'totalRetentionInDaysAsDefault' $false
        }
        if ($path -eq $fixture.BadReadbackId) {
            Set-FixtureProperty $value.properties 'retentionInDays' 7
        }
        $fixture.Resources[$path] = $value
        $response = Copy-FixtureValue $value
        if ($fixture.PendingWriteStates.ContainsKey($path)) { Set-FixtureProperty $response.properties 'provisioningState' $fixture.PendingWriteStates[$path] }
        return $response
    }
    finally {
        [Threading.Monitor]::Exit([ProceduralReplay.SharedFixture]::SyncRoot)
    }
}
function Invoke-WebRequest {
    param($Uri, $Method = 'Get', $Headers, $ContentType, $TimeoutSec, $Body, [switch]$SkipHttpErrorCheck, $OperationTimeoutSeconds)
    $global:ProceduralFixture = [ProceduralReplay.SharedFixture]::State
    try {
        $global:ProceduralFixture.OperationTimeoutValues.Add([int]$OperationTimeoutSeconds)
        $value = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -ContentType $ContentType -TimeoutSec $TimeoutSec -Body $Body
        $key = ([string]$Method).ToUpperInvariant() + ' ' + ([uri]$Uri).AbsolutePath
        if ($key -in $global:ProceduralFixture.InvalidJsonKeys) { return [pscustomobject]@{ StatusCode = 200; Headers = @{}; Content = '{invalid-json' } }
        return [pscustomobject]@{
            StatusCode = 200
            Headers = @{}
            Content = ConvertTo-Json -InputObject $value -Depth 50 -Compress
        }
    }
    catch [ProceduralReplay.HttpFailure] {
        return [pscustomobject]@{
            StatusCode = $_.Exception.Response.StatusCode
            Headers = $_.Exception.Response.Headers
            Content = ConvertTo-Json @{ error = @{ code = $_.Exception.Message; message = $_.Exception.Message } } -Compress
        }
    }
}
function Add-FixtureResource {
    param([string]$Id, $Body)
    $value = Copy-FixtureValue $Body
    Set-FixtureProperty $value 'id' $Id
    Set-FixtureProperty $value 'name' (($Id -split '/')[-1])
    $global:ProceduralFixture.Resources[$Id] = $value
}
function Add-FixtureDiagnostic {
    param([string]$ParentId, [string]$Name = 'old', [string]$Workspace = $global:ProceduralFixture.SourceWorkspace)
    $body = @{
        properties = @{
            workspaceId = $Workspace
            logs = @(@{ category = '日本語ログ'; enabled = $true; retentionPolicy = @{ enabled = $false; days = 0 } })
            metrics = @(@{ category = 'AllMetrics'; enabled = $true; timeGrain = 'PT1M'; retentionPolicy = @{ enabled = $false; days = 0 } })
        }
    }
    Add-FixtureResource "$ParentId/providers/Microsoft.Insights/diagnosticSettings/$Name" $body
}
function Write-FixtureCsv {
    param([string]$OmitColumn)
    $rows = @($global:ProceduralFixture.Rows)
    if ($OmitColumn) {
        $rows = @($rows | Select-Object -Property * -ExcludeProperty $OmitColumn)
    }
    $rows | Export-Csv (Join-Path $global:ProceduralFixture.Repository 'targets.csv') -NoTypeInformation -Encoding UTF8
}
function Reset-Fixture {
    param([string]$Diagnostic = 'Storage', [string]$Vm = 'Log', [switch]$NoSources)
    $root = Join-Path $scratch ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory $root
    foreach ($file in $sourceFiles) {
        Copy-Item (Join-Path $Repository $file) (Join-Path $root $file)
    }
    $commonPath = Join-Path $root 'common.ps1'
    $externalMocks = @('Copy-FixtureValue', 'Set-FixtureProperty', 'Merge-FixtureBody', 'az', 'Start-Sleep', 'Get-Date', 'Invoke-RestMethod', 'Invoke-WebRequest')
    $mockDefinitions = foreach ($name in $externalMocks) {
        'function ' + $name + ' {' + (Get-Item ('function:' + $name)).Definition + '}'
    }
    [IO.File]::AppendAllText($commonPath, "`n# External transport replay for tests only.`n" + ($mockDefinitions -join "`n"), [Text.Encoding]::UTF8)
    $global:ProceduralFixture = @{
        Repository = $root
        MainRunspaceId = $script:mainRunspaceId
        WorkerRunspaceIds = [Collections.Generic.HashSet[string]]::new()
        WorkerRequestCount = 0
        Subscriptions = @('11111111-1111-1111-1111-111111111111', '22222222-2222-2222-2222-222222222222')
        Inventory = @()
        Pages = @{}
        Resources = @{}
        Rows = @()
        Failures = @{}
        HttpFailures = @{}
        TransportFailures = @{}
        InvalidJsonKeys = @()
        LoseDeleteResponseId = ''
        PendingWriteStates = @{}
        ProviderPendingReads = @{}
        OperationTimeoutValues = [Collections.Concurrent.ConcurrentBag[int]]::new()
        PendingReads = @{}
        PendingStates = @{}
        UnregisteredProviders = @{}
        UnavailableNames = @()
        ZrsLocations = @('japaneast', 'japanwest', 'canadacentral')
        Reads = [Collections.Generic.List[string]]::new()
        Requests = [Collections.Generic.List[object]]::new()
        Writes = [Collections.Generic.List[object]]::new()
        BackupWitnesses = [Collections.Generic.List[object]]::new()
        RegionReads = 0
        TokenReads = 0
        UnauthorizedReads = 0
        FailToken = $false
        BadReadbackId = ''
        RollbackSubscriptions = @()
        WriteBeforeBackup = $false
        UnsafeNewDelete = $false
        SleepCalls = 0
        SleepSeconds = [Collections.Generic.List[int]]::new()
        ClockOffset = 0
        ClockStep = 0
    }
    [ProceduralReplay.SharedFixture]::State = $global:ProceduralFixture
    $configuration = & {
        . (Join-Path $root 'common.ps1') -SkipCsv
        @{
            SourceWorkspace = $targetWorkspaceId
            DiagnosticName = $newDiagnosticSettingName
            OldDcrIds = @($oldDcrIds)
            ReferenceIds = @($policyReferenceIds)
            Assignments = @($policyAssignments)
        }
    }
    $global:ProceduralFixture.SourceWorkspace = $configuration.SourceWorkspace
    $global:ProceduralFixture.DiagnosticName = $configuration.DiagnosticName
    $global:ProceduralFixture.OldDcrIds = $configuration.OldDcrIds
    $global:ProceduralFixture.ReferenceIds = $configuration.ReferenceIds
    $global:ProceduralFixture.Assignments = $configuration.Assignments
    foreach ($subscription in $global:ProceduralFixture.Subscriptions) {
        $ids = Get-FixtureIds $subscription
        $global:ProceduralFixture.Rows += [pscustomobject][ordered]@{
            SubscriptionName = $subscription
            ResourceGroup = 'rg-target'
            StorageAccount = "stjpe$($subscription.Substring(0, 4))"
            WorkspaceName = 'log-new'
            LogDestination = $Diagnostic
            VmLogDestination = $Vm
        }
        if ($NoSources) {
            continue
        }
        $sourceGroup = "/subscriptions/$subscription/resourceGroups/rg-source"
        $resourceId = "$sourceGroup/providers/Microsoft.Test/widgets/source"
        $machineType = 'virtualMachines'
        if ($subscription -eq $global:ProceduralFixture.Subscriptions[1]) {
            $machineType = 'virtualMachineScaleSets'
        }
        $machineId = "$sourceGroup/providers/Microsoft.Compute/$machineType/old-related"
        $global:ProceduralFixture.Inventory += [pscustomobject]@{
            id = $resourceId
            type = 'Microsoft.Test/widgets'
            location = 'japaneast'
        }
        $global:ProceduralFixture.Inventory += [pscustomobject]@{
            id = $machineId
            type = "Microsoft.Compute/$machineType"
            location = 'japaneast'
        }
        Add-FixtureDiagnostic $resourceId
        Add-FixtureDiagnostic $resourceId 'unrelated' '/unrelated-workspace'
        Add-FixtureResource "$machineId/providers/Microsoft.Insights/dataCollectionRuleAssociations/old" @{
            properties = @{
                description = '元の関連付け'
                dataCollectionRuleId = $configuration.OldDcrIds[0]
                dataCollectionEndpointId = '/old-endpoint'
                provisioningState = 'Succeeded'
            }
        }
    }
    $global:ProceduralFixture.OriginalResources = Copy-FixtureValue $global:ProceduralFixture.Resources
    Write-FixtureCsv
}
function Invoke-ReplayStep {
    param([string]$Step, [switch]$ExpectFailure, [string[]]$SubscriptionIds)
    $file = @{
        precheck = 'precheck.ps1'
        copy = 'step1_copy.ps1'
        verify = 'step2_verify.ps1'
        delete = 'step3_delete.ps1'
        rollback = 'rollback.ps1'
    }[$Step]
    $failed = $false
    $global:ProceduralFixture.RollbackSubscriptions = @()
    if ($Step -eq 'rollback' -and $PSBoundParameters.ContainsKey('SubscriptionIds')) {
        $global:ProceduralFixture.RollbackSubscriptions = @($SubscriptionIds)
    }
    try {
        if ($PSBoundParameters.ContainsKey('SubscriptionIds')) {
            $null = & (Join-Path $global:ProceduralFixture.Repository $file) -SubscriptionIds $SubscriptionIds
        }
        else {
            $null = & (Join-Path $global:ProceduralFixture.Repository $file)
        }
    }
    catch {
        $failed = $true
        $global:ProceduralFixture.LastError = $_
        if (-not $ExpectFailure) {
            throw
        }
    }
    Assert-Replay ($failed -eq [bool]$ExpectFailure) "$Step の成否が期待どおり"
}
function Get-FixtureRecords {
    @(Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev') -Filter '*.json' | ForEach-Object {
        Get-Content $_.FullName -Raw -Encoding UTF8 | ConvertFrom-Json
    })
}
function Reset-Observation {
    $global:ProceduralFixture.Reads.Clear()
    $global:ProceduralFixture.Requests.Clear()
    $global:ProceduralFixture.Writes.Clear()
    $global:ProceduralFixture.BackupWitnesses.Clear()
    $global:ProceduralFixture.LastError = $null
}
function Invoke-ReplayCase {
    param([string]$Name, [scriptblock]$Body, [string]$Diagnostic = 'Storage', [string]$Vm = 'Log', [switch]$NoSources)
    $script:activeCase = $Name
    Write-Host ('CASE: ' + $Name)
    Reset-Fixture -Diagnostic $Diagnostic -Vm $Vm -NoSources:$NoSources
    $before = $script:checks
    & $Body
    $script:parallelRequestCount += $global:ProceduralFixture.WorkerRequestCount
    foreach ($runspaceId in $global:ProceduralFixture.WorkerRunspaceIds) {
        $null = $script:parallelRunspaceIds.Add($runspaceId)
    }
    $script:cases.Add([pscustomobject]@{
        Case = $Name
        Result = 'PASS'
        Assertions = $script:checks - $before
    })
}
try {
    # --------------------------------------------------
    # 診断ログとVMログの作成指定を変え、複製から切り戻しまでの流れを確かめる。
    # --------------------------------------------------
    foreach ($mode in @(
        @{ Name = 'StorageとVM'; Diagnostic = 'Storage'; Vm = 'Log' },
        @{ Name = 'LogとVM'; Diagnostic = 'Log'; Vm = 'Log' },
        @{ Name = 'Storageのみ'; Diagnostic = 'Storage'; Vm = 'None' },
        @{ Name = 'Logのみ'; Diagnostic = 'Log'; Vm = 'None' },
        @{ Name = 'VMのみ'; Diagnostic = 'None'; Vm = 'Log' },
        @{ Name = '両方None'; Diagnostic = 'None'; Vm = 'None' },
        @{ Name = '両方空欄'; Diagnostic = ''; Vm = '' }
    )) {
        Invoke-ReplayCase "$($mode.Name): 全工程・再実行・切戻し" -Diagnostic $mode.Diagnostic -Vm $mode.Vm -Body {
            Invoke-ReplayStep precheck
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'precheckは書込み0'
            Assert-Replay (-not (Test-Path (Join-Path $global:ProceduralFixture.Repository 'records'))) 'precheckは記録を作らない'
            Invoke-ReplayStep copy
            $records = @(Get-FixtureRecords)
            Assert-Replay ($records.Count -eq 2) '2Subの記録を保存'
            foreach ($record in $records) {
                Assert-Replay ($record.OldSettings.Count -eq 2) '省略側も旧診断と旧関連を保存'
                Assert-Replay ('Discovery' -notin $record.PSObject.Properties.Name) '探索用の一時情報を変更前記録へ保存しない'
                Assert-Replay (@($record.Destinations | Where-Object Kind -eq 'Storage').Count -eq 1) '全フラグで指定Storageを準備'
                Assert-Replay (@($record.Destinations | Where-Object Kind -eq 'Workspace').Count -eq 1) '全フラグでLAWを準備'
                Assert-Replay (@($record.Destinations | Where-Object Kind -eq 'Table').Count -eq 2) 'VMを止める場合もEvent/Syslogを準備'
                $storage = @($record.Destinations | Where-Object Kind -eq 'Storage')[0]
                $storageProperties = $global:ProceduralFixture.Resources[$storage.Id].properties
                Assert-Replay ($storageProperties.publicNetworkAccess -eq 'Disabled') '原本どおりStorage公開アクセス無効'
                Assert-Replay ($storageProperties.networkAcls.defaultAction -eq 'Deny' -and $storageProperties.networkAcls.bypass -eq 'AzureServices') '原本どおり既定拒否とAzureServices例外'
                Assert-Replay ($storageProperties.allowBlobPublicAccess -eq $false -and $storageProperties.allowSharedKeyAccess -eq $false) 'Blob匿名公開と共有キーを無効化'
                $workspace = @($record.Destinations | Where-Object Kind -eq 'Workspace')[0]
                $workspaceProperties = $global:ProceduralFixture.Resources[$workspace.Id].properties
                Assert-Replay ($workspaceProperties.publicNetworkAccessForIngestion -eq 'Enabled' -and $workspaceProperties.publicNetworkAccessForQuery -eq 'Enabled') '原本どおりLAWの取込とクエリの公開アクセス有効'
                Assert-Replay ($workspaceProperties.retentionInDays -eq 90) '指定どおりLAW全体を90日保持'
                $exemptions = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
                Assert-Replay ($exemptions.Count -eq 3) '環境別3割り当ての除外を準備'
                for ($index = 0; $index -lt 3; $index++) {
                    $assignment = $global:ProceduralFixture.Assignments[$index]
                    $exemption = @($exemptions | Where-Object { $_.Body.properties.policyAssignmentId -eq $assignment.Id })[0]
                    $sent = @($global:ProceduralFixture.Writes | Where-Object { $_.Id -eq $exemption.Id -and $_.Method -eq 'PUT' })[0].Body.properties
                    if ($index -lt 2) {
                        Assert-Replay ('policyDefinitionReferenceIds' -in $sent.PSObject.Properties.Name -and @($sent.policyDefinitionReferenceIds).Count -eq 0) '最初の2割り当ては空参照IDで全体除外'
                    }
                    else {
                        Assert-Replay (@($sent.policyDefinitionReferenceIds).Count -eq 12 -and (($sent.policyDefinitionReferenceIds | Sort-Object) -join '|') -ceq (($global:ProceduralFixture.ReferenceIds | Sort-Object) -join '|')) '3件目だけ指定12参照IDを除外'
                    }
                }
                $diagnosticCount = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic').Count
                $associationCount = @($record.NewSettings | Where-Object Kind -eq 'Association').Count
                Assert-Replay (($diagnosticCount -eq 1) -eq ($mode.Diagnostic -in @('Storage', 'Log'))) '新診断は選択した側だけ'
                Assert-Replay (($associationCount -eq 1) -eq ($mode.Vm -eq 'Log')) '新DCR関連は選択した側だけ'
                foreach ($destination in $record.Destinations) {
                    Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($destination.Id)) '保存先の存在を確認'
                }
                foreach ($old in $record.OldSettings) {
                    Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) 'copyは旧を残す'
                }
            }
            Assert-Replay (-not $global:ProceduralFixture.WriteBeforeBackup) 'すべての変更前に記録がある'
            $hashes = @{}
            foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
                $hashes[$file.Name] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
            }
            Reset-Observation
            Invoke-ReplayStep copy
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '一致済みcopyは書込み0'
            foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
                Assert-Replay ($hashes[$file.Name] -eq (Get-FileHash $file.FullName -Algorithm SHA256).Hash) '記録のBeforeを変更しない'
            }
            Invoke-ReplayStep verify
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'verifyは読取りのみ'
            Invoke-ReplayStep delete
            foreach ($old in $records.OldSettings) {
                Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($old.Id)) 'None側も旧設定を削除'
            }
            Reset-Observation
            Invoke-ReplayStep delete
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '削除済みの再実行は変更0'
            Invoke-ReplayStep verify
            Invoke-ReplayStep rollback
            foreach ($old in $records.OldSettings) {
                Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '旧設定を復元'
            }
            foreach ($record in $records) {
                foreach ($destination in $record.Destinations) {
                    Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($destination.Id)) '切戻しでも保存先を残す'
                }
                foreach ($setting in $record.NewSettings) {
                    if ($setting.KeepOnRollback) {
                        Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($setting.Id)) '新規DCR本体は残す'
                    }
                    elseif (-not $setting.Before) {
                        Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($setting.Id)) '今回追加した送信設定とWaiverだけ除去'
                    }
                }
            }
            Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '旧全復元より前に新診断を削除しない'
            Reset-Observation
            Invoke-ReplayStep rollback
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '切戻し再実行は変更0'
        }
    }
    Invoke-ReplayCase 'Storage宛GETのLAW既定方式付加を許容して再実行・削除・復元できる' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        foreach ($setting in @($records.NewSettings | Where-Object Kind -eq 'Diagnostic')) {
            $actual = $global:ProceduralFixture.Resources[$setting.Id]
            Set-FixtureProperty $actual.properties 'logAnalyticsDestinationType' 'AzureDiagnostics'
        }
        Reset-Observation
        Invoke-ReplayStep copy
        Invoke-ReplayStep verify
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'Storage宛の無関係なLAW既定方式だけでは再書込みしない'
        Invoke-ReplayStep delete
        foreach ($old in $records.OldSettings) {
            Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($old.Id)) 'GETの方式付加があっても旧設定を削除できる'
        }
        Invoke-ReplayStep rollback
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '切り戻しで旧設定を復元する'
        }
    }
    Invoke-ReplayCase 'LAW宛の格納方式変更は許容せず既存設定を保持する' -Diagnostic 'Log' -Body {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $setting = @($records.NewSettings | Where-Object Kind -eq 'Diagnostic')[0]
        $actual = $global:ProceduralFixture.Resources[$setting.Id]
        Set-FixtureProperty $actual.properties 'logAnalyticsDestinationType' 'Dedicated'
        Reset-Observation
        Invoke-ReplayStep copy -ExpectFailure
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'LAW宛の方式違いを上書きせず旧設定も削除しない'
        Assert-Replay ($actual.properties.logAnalyticsDestinationType -eq 'Dedicated') '変更された格納方式を保持'
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '方式不一致なら全旧設定を保持'
        }
    }
    Invoke-ReplayCase 'CSV列欠落は空欄と区別して書込み前に停止する' {
        foreach ($column in @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')) {
            Write-FixtureCsv -OmitColumn $column
            Invoke-ReplayStep copy -ExpectFailure
            Assert-Replay ($global:ProceduralFixture.LastError.Exception.Message -match [regex]::Escape($column)) '不足列を理由に停止'
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '列欠落でAzure変更なし'
            Assert-Replay (-not (Test-Path (Join-Path $global:ProceduralFixture.Repository 'records'))) '列欠落で作業記録を作らない'
        }
    }
    Invoke-ReplayCase '対象0件でも東日本StorageとLAWを準備する' -NoSources -Diagnostic 'None' -Vm 'None' -Body {
        Invoke-ReplayStep copy
        foreach ($record in Get-FixtureRecords) {
            Assert-Replay ($record.OldSettings.Count -eq 0) '旧対象は空配列'
            $storage = @($record.Destinations | Where-Object Kind -eq 'Storage')
            Assert-Replay ($storage.Count -eq 1 -and $storage[0].Body.location -eq 'japaneast') '東日本の保存先1つ'
            Assert-Replay (@($record.NewSettings | Where-Object Kind -eq 'Diagnostic').Count -eq 0) '旧対象のない新診断を作らない'
        }
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
    }
    Invoke-ReplayCase '旧DCR関連なしでもEvent・Syslogは1095日保持し、新DCRは作らない' -NoSources -Diagnostic 'None' -Vm 'None' -Body {
        $global:ProceduralFixture.Rows[1].VmLogDestination = ''
        Write-FixtureCsv
        Invoke-ReplayStep copy
        foreach ($record in Get-FixtureRecords) {
            Assert-Replay ($record.OldSettings.Count -eq 0) '旧診断設定と旧DCR関連付けは0件'
            $tables = @($record.Destinations | Where-Object Kind -eq 'Table')
            Assert-Replay ($tables.Count -eq 2) '両Subでテーブルを2つ作成'
            foreach ($tableName in @('Event', 'Syslog')) {
                $tableId = "$($record.Target.WorkspaceId)/tables/$tableName"
                $saved = @($tables | Where-Object Id -eq $tableId)
                $actual = $global:ProceduralFixture.Resources[$tableId]
                Assert-Replay ($saved.Count -eq 1 -and $saved[0].Body.properties.totalRetentionInDays -eq 1095) "$tableName の1095日設定を記録"
                Assert-Replay ($actual.properties.totalRetentionInDays -eq 1095 -and -not $actual.properties.totalRetentionInDaysAsDefault) "$tableName をテーブル単位で1095日に設定"
            }
            Assert-Replay (@($record.NewSettings | Where-Object Kind -in @('Dcr', 'Association')).Count -eq 0) 'None・空欄では新DCRと関連付けを作らない'
        }
        Reset-Observation
        Invoke-ReplayStep copy
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '同じ設定で再実行しても書き直さない'
        Invoke-ReplayStep verify

        # 各テーブルの日数変更をNGにし、複製の再実行で1095日へ戻せることも確認する。
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        foreach ($tableName in @('Event', 'Syslog')) {
            $tableId = "$($ids.Workspace)/tables/$tableName"
            $global:ProceduralFixture.Resources[$tableId].properties.totalRetentionInDays = 365
            Reset-Observation
            Invoke-ReplayStep verify -ExpectFailure
            $results = Import-Csv (Join-Path $global:ProceduralFixture.Repository 'verify_results.csv')
            Assert-Replay (@($results | Where-Object { $_.ResourceId -eq $tableId -and $_.Result -eq 'NG' }).Count -eq 1) "$tableName の日数変更をNGにする"
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '確認中は設定を変更しない'
            Invoke-ReplayStep copy
            Invoke-ReplayStep verify
        }
        # VM送信をLogにしても、旧関連付けがなければDCRは作らず、両テーブルだけを設定する。
        Reset-Fixture -NoSources -Diagnostic 'None' -Vm 'Log'
        Invoke-ReplayStep copy
        foreach ($record in Get-FixtureRecords) {
            Assert-Replay ($record.OldSettings.Count -eq 0 -and $record.Target.VmLogDestination -eq 'Log') '旧関連付けなしでVM送信Logを指定'
            Assert-Replay (@($record.NewSettings | Where-Object Kind -in @('Dcr', 'Association')).Count -eq 0) '旧関連付けがなければ新DCRと関連付けを作らない'
            Assert-Replay (@($record.Destinations | Where-Object Kind -eq 'Table').Count -eq 2) 'VM送信Logでも両テーブルを設定'
        }
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -match '/Microsoft.Insights/dataCollection(Rules|RuleAssociations)/' }).Count -eq 0) 'DCRと関連付けへの書込み0'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '東日本・西日本・globalの地域別Storageへ送信する' {
        $first = $global:ProceduralFixture.Subscriptions[0]
        foreach ($region in @('japanwest', 'global')) {
            $parent = "/subscriptions/$first/resourceGroups/rg-source/providers/Microsoft.Test/widgets/$region"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Test/widgets'; location = $region }
            Add-FixtureDiagnostic $parent
        }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $first })[0]
        Assert-Replay (@($record.Destinations | Where-Object Kind -eq 'Storage').Count -eq 2) 'globalは東日本と共用'
        foreach ($setting in @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')) {
            if ($setting.Id -like '*/japanwest/*') {
                Assert-Replay ($setting.Body.properties.storageAccountId -like '*/stjpw*') '西日本送信先の略称'
            }
            else {
                Assert-Replay ($setting.Body.properties.storageAccountId -like '*/stjpe*') '東日本またはglobalの送信先'
            }
        }
    }
    Invoke-ReplayCase 'Canadaのみの旧設定を削除後もJPEを要求しない' {
        foreach ($item in $global:ProceduralFixture.Inventory) {
            $item.location = 'canadacentral'
        }
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        Reset-Observation
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Assert-Replay (@($global:ProceduralFixture.Reads | Where-Object { $_ -like '*/storageAccounts/stjpe*' }).Count -eq 0) 'JPEへの不要なGETなし'
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '削除後再確認は変更0'
        Invoke-ReplayStep rollback
    }
    foreach ($kind in @('StorageV2', 'BlobStorage', 'BlockBlobStorage', 'FileStorage')) {
        Invoke-ReplayCase "Storage kind=$kind の子スコープを探索" -Vm 'None' -Body {
            $subscription = $global:ProceduralFixture.Subscriptions[0]
            $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Storage/storageAccounts/sourceaccount"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Storage/storageAccounts'; kind = $kind; location = 'japaneast' }
            $services = @('blobServices', 'fileServices', 'queueServices', 'tableServices')
            if ($kind -in @('BlobStorage', 'BlockBlobStorage')) {
                $services = @('blobServices')
            }
            if ($kind -eq 'FileStorage') {
                $services = @('fileServices')
            }
            foreach ($service in $services) {
                Add-FixtureDiagnostic "$parent/$service/default"
            }
            Invoke-ReplayStep copy
            $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
            Assert-Replay (@($record.OldSettings | Where-Object { $_.Id -like "$parent/*" }).Count -eq $services.Count) 'kindに合う子スコープを保存'
            Assert-Replay (@($record.NewSettings | Where-Object { $_.Kind -eq 'Diagnostic' -and $_.Id -like "$parent/*" }).Count -eq $services.Count) '子スコープにも新診断を追加'
        }
    }
    Invoke-ReplayCase '通常一覧にないRedis子DBを親地域のStorageへ移行・復元する' -Vm 'None' -NoSources -Body {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Cache/redisEnterprise/source"
        $database = "$parent/databases/default"
        $global:ProceduralFixture.Inventory += [pscustomobject]@{
            id = $parent
            type = 'Microsoft.Cache/redisEnterprise'
            location = 'canadacentral'
        }
        # 子DBの応答にlocationがない場合でも、親のリージョンで保存先を選べるか試す。
        $global:ProceduralFixture.Pages["https://management.azure.com$parent/databases?api-version=2025-04-01"] = @{
            value = @(@{ id = $database; name = 'default'; type = 'Microsoft.Cache/redisEnterprise/databases'; properties = @{ provisioningState = 'Succeeded' } })
        }
        Add-FixtureDiagnostic $database
        $oldId = "$database/providers/Microsoft.Insights/diagnosticSettings/old"
        $newId = "$database/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"

        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        $old = @($record.OldSettings | Where-Object Kind -eq 'Diagnostic')
        $new = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        Assert-Replay ($old.Count -eq 1 -and $old[0].Id -eq $oldId) '通常一覧にない実在の子診断を保存'
        Assert-Replay ($new.Count -eq 1 -and $new[0].Id -eq $newId) '子DBへ新診断を追加'
        $storageId = "/subscriptions/$subscription/resourceGroups/rg-target/providers/Microsoft.Storage/storageAccounts/stcac1111"
        Assert-Replay ($new[0].Body.properties.storageAccountId -eq $storageId) 'locationのない子も親のCanada宛て'
        Assert-Replay ($global:ProceduralFixture.Resources[$storageId].location -eq 'canadacentral') '親地域にStorageを作成'
        Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($oldId)) 'copyでは子の旧設定を維持'
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($oldId)) '子の旧設定を削除'
        Invoke-ReplayStep rollback
        Assert-Replay ($global:ProceduralFixture.Resources[$oldId].properties.workspaceId -eq $global:ProceduralFixture.SourceWorkspace) '子の旧送信先を復元'
        Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($newId)) '子の新設定を解除'
    }
    Invoke-ReplayCase 'RedisのDB一覧が空なら存在しない子を調べない' -Vm 'None' -NoSources -Body {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Cache/redisEnterprise/empty"
        $global:ProceduralFixture.Inventory += [pscustomobject]@{
            id = $parent
            type = 'Microsoft.Cache/redisEnterprise'
            location = 'japaneast'
        }
        $global:ProceduralFixture.Pages["https://management.azure.com$parent/databases?api-version=2025-04-01"] = @{ value = @() }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        Assert-Replay ($record.OldSettings.Count -eq 0) '空のDB一覧から旧設定を捏造しない'
        Assert-Replay (@($record.NewSettings | Where-Object Kind -eq 'Diagnostic').Count -eq 0) '対象のない新診断を作らない'
        Assert-Replay (@($global:ProceduralFixture.Reads | Where-Object { $_ -like "$parent/databases/*/providers/Microsoft.Insights/diagnosticSettings" }).Count -eq 0) '存在しない子への照会なし'
    }
    Invoke-ReplayCase 'Redis子DBと通常一覧の次ページを両方移行・復元する' -Vm 'None' -NoSources -Body {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Cache/redisEnterprise/paged"
        $archive = "$parent/databases/archive"
        $second = "$parent/databases/second"
        $other = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Network/networkSecurityGroups/next-page"
        $resourcesPage = "https://management.azure.com/subscriptions/$subscription/resources?api-version=2021-04-01"
        $databasesPage = "https://management.azure.com$parent/databases?api-version=2025-04-01"
        $nextResources = $resourcesPage + '&$skiptoken=resources'
        $nextDatabases = $databasesPage + '&$skiptoken=databases'
        $global:ProceduralFixture.Pages[$resourcesPage] = @{
            value = @(@{ id = $parent; type = 'Microsoft.Cache/redisEnterprise'; location = 'canadacentral' })
            nextLink = $nextResources
        }
        $global:ProceduralFixture.Pages[$databasesPage] = @{
            value = @(@{ id = $archive; name = 'archive'; type = 'Microsoft.Cache/redisEnterprise/databases' })
            nextLink = $nextDatabases
        }
        $global:ProceduralFixture.Pages[$nextDatabases] = @{
            value = @(@{ id = $second; name = 'second'; type = 'Microsoft.Cache/redisEnterprise/databases' })
        }
        $global:ProceduralFixture.Pages[$nextResources] = @{
            value = @(@{ id = $other; type = 'Microsoft.Network/networkSecurityGroups'; location = 'japanwest' })
        }
        foreach ($resourceId in @($archive, $second, $other)) {
            Add-FixtureDiagnostic $resourceId
        }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        Assert-Replay (@($record.OldSettings | Where-Object Kind -eq 'Diagnostic').Count -eq 3) 'DB両ページと通常の次ページを保存'
        Assert-Replay (@($record.NewSettings | Where-Object Kind -eq 'Diagnostic').Count -eq 3) '3対象すべてへ新診断を追加'
        foreach ($resourceId in @($archive, $second, $other)) {
            $new = @($record.NewSettings | Where-Object Id -eq "$resourceId/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)")[0]
            $storageName = 'stcac1111'
            if ($resourceId -eq $other) {
                $storageName = 'stjpw1111'
            }
            Assert-Replay ($new.Body.properties.storageAccountId -like "*/storageAccounts/$storageName") 'DBは親の地域、通常資源は自身の地域へ送信'
        }
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        foreach ($resourceId in @($archive, $second, $other)) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey("$resourceId/providers/Microsoft.Insights/diagnosticSettings/old")) '次ページの旧設定も復元'
            Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey("$resourceId/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)")) '次ページの新設定も解除'
        }
    }
    foreach ($invalid in @(
        @{ Name = '不正診断フラグ'; Field = 'LogDestination'; Value = 'EventHub' },
        @{ Name = '不正VMフラグ'; Field = 'VmLogDestination'; Value = 'Storage' },
        @{ Name = '空RG'; Field = 'ResourceGroup'; Value = '' },
        @{ Name = '空Workspace'; Field = 'WorkspaceName'; Value = '' },
        @{ Name = '不正Storage名'; Field = 'StorageAccount'; Value = 'BAD-NAME' },
        @{ Name = 'jpeが2か所'; Field = 'StorageAccount'; Value = 'jpejpe' },
        @{ Name = 'Storage名25文字'; Field = 'StorageAccount'; Value = ('jpe' + ('a' * 22)) },
        @{ Name = '空Sub'; Field = 'SubscriptionName'; Value = '' }
    )) {
        Invoke-ReplayCase "CSV入力拒否: $($invalid.Name)" {
            $global:ProceduralFixture.Rows[0].($invalid.Field) = $invalid.Value
            Write-FixtureCsv
            Invoke-ReplayStep copy -ExpectFailure
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '入力異常は変更前に停止'
        }
    }
    Invoke-ReplayCase '初回の既存RGは同地域でも別地域でも変更前に停止する' {
        $configuration = & {
            . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
            $location
        }
        $otherLocation = if ($configuration -eq 'japaneast') { 'japanwest' } else { 'japaneast' }
        foreach ($existingLocation in @($configuration, $otherLocation)) {
            $beforeGroups = @{}
            foreach ($subscription in $global:ProceduralFixture.Subscriptions) {
                $ids = Get-FixtureIds $subscription
                Add-FixtureResource $ids.Group @{ location = $existingLocation; properties = @{} }
                $beforeGroups[$ids.Group] = ConvertTo-Json $global:ProceduralFixture.Resources[$ids.Group] -Depth 20
            }
            Invoke-ReplayStep precheck -ExpectFailure
            Invoke-ReplayStep copy -ExpectFailure
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '両Subとも既存RGへ書込みなし'
            Assert-Replay (@(Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev') -Filter '*.json' -ErrorAction SilentlyContinue).Count -eq 0) '既存RGで作業記録を保存しない'
            $failures = @(Import-Csv (Join-Path $global:ProceduralFixture.Repository 'copy_failures.csv'))
            Assert-Replay ($failures.Count -eq 2 -and @($failures | Where-Object { $_.Reason -notmatch 'リソースグループ' }).Count -eq 0) '両SubのRG衝突を報告'
            foreach ($id in $beforeGroups.Keys) {
                Assert-Replay ($beforeGroups[$id] -ceq (ConvertTo-Json $global:ProceduralFixture.Resources[$id] -Depth 20)) '既存RGの本文を保持'
            }
        }
    }
    Invoke-ReplayCase '初回の既存Storage名を事前停止する' {
        $global:ProceduralFixture.UnavailableNames = @('stjpe1111')
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '名前衝突の変更0'
    }
    Invoke-ReplayCase 'ZRS非対応の地域を事前停止する' {
        $global:ProceduralFixture.ZrsLocations = @('canadacentral')
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'SKU非対応の変更0'
    }
    Invoke-ReplayCase '初回の同名新診断を再利用しない' {
        $parent = $global:ProceduralFixture.Inventory[0].id
        Add-FixtureDiagnostic $parent $global:ProceduralFixture.DiagnosticName '/unrelated-workspace'
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '診断名衝突の変更0'
    }
    Invoke-ReplayCase '新診断を追加する空き5枠上限を事前停止する' {
        $parent = $global:ProceduralFixture.Inventory[0].id
        foreach ($name in @('keep-2', 'keep-3', 'keep-4')) {
            Add-FixtureDiagnostic $parent $name '/unrelated-workspace'
        }
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '5件満杯の変更0'
    }
    Invoke-ReplayCase '両Noneは同名新診断と5件上限に触れない' -Diagnostic 'None' -Vm 'None' -Body {
        $parent = $global:ProceduralFixture.Inventory[0].id
        foreach ($name in @($global:ProceduralFixture.DiagnosticName, 'keep-2', 'keep-3')) {
            Add-FixtureDiagnostic $parent $name '/unrelated-workspace'
        }
        $before = ConvertTo-Json $global:ProceduralFixture.Resources["$parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"] -Depth 50
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        $after = ConvertTo-Json $global:ProceduralFixture.Resources["$parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"] -Depth 50
        Assert-Replay ($before -ceq $after) '無関係の同名設定を完全保持'
    }
    Invoke-ReplayCase '関係のないVM・VMSSには新関連を作らない' {
        foreach ($subscription in $global:ProceduralFixture.Subscriptions) {
            $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Compute/virtualMachines/no-old"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Compute/virtualMachines'; location = 'japaneast' }
        }
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like '*/no-old/*' }).Count -eq 0) '旧関連なしVMへの書込み0'
    }
    # --------------------------------------------------
    # 保存先を作成・更新しても、既存のIP規則や、今回変更しないテーブル設定が残ることを確かめる。
    # --------------------------------------------------
    Invoke-ReplayCase 'Storage ACL・LAW features・分析保持・他ルールを維持する' {
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords)[0]
        $storage = @($record.Destinations | Where-Object Kind -eq 'Storage')[0]
        $workspace = @($record.Destinations | Where-Object Kind -eq 'Workspace')[0]
        $lifecycle = @($record.Destinations | Where-Object Kind -eq 'Lifecycle')[0]
        $table = @($record.Destinations | Where-Object Kind -eq 'Table')[0]
        $actualStorage = $global:ProceduralFixture.Resources[$storage.Id]
        Set-FixtureProperty $actualStorage.properties.networkAcls 'ipRules' @([pscustomobject]@{ value = '192.0.2.1'; action = 'Allow' })
        Set-FixtureProperty $actualStorage.properties.networkAcls 'virtualNetworkRules' @([pscustomobject]@{ id = '/existing-subnet'; action = 'Allow' })
        $actualStorage.properties.networkAcls.defaultAction = 'Allow'
        $actualWorkspace = $global:ProceduralFixture.Resources[$workspace.Id]
        Set-FixtureProperty $actualWorkspace.properties.features 'preserveMe' $true
        $actualWorkspace.properties.features.enableLogAccessUsingOnlyResourcePermissions = $false
        $actualTable = $global:ProceduralFixture.Resources[$table.Id]
        Set-FixtureProperty $actualTable.properties 'retentionInDays' 30
        Set-FixtureProperty $actualTable.properties 'plan' 'Analytics'
        Set-FixtureProperty $actualTable.properties.schema 'columns' @([pscustomobject]@{ name = 'KeepColumn'; type = 'string' })
        $actualTable.properties.totalRetentionInDays = 365
        Set-FixtureProperty $actualTable.properties 'totalRetentionInDaysAsDefault' $true
        $actualLifecycle = $global:ProceduralFixture.Resources[$lifecycle.Id]
        $otherRule = Copy-FixtureValue @($actualLifecycle.properties.policy.rules | Where-Object name -eq 'log-append-1095')[0]
        $otherRule.name = 'keep-other-rule'
        $otherRule.definition.actions.baseBlob.delete.daysAfterModificationGreaterThan = 7
        $actualLifecycle.properties.policy.rules = @($otherRule)
        Reset-Observation
        Invoke-ReplayStep copy
        Assert-Replay ($global:ProceduralFixture.Resources[$storage.Id].properties.networkAcls.ipRules[0].value -eq '192.0.2.1') 'IP規則保持'
        Assert-Replay ($global:ProceduralFixture.Resources[$storage.Id].properties.networkAcls.virtualNetworkRules[0].id -eq '/existing-subnet') '既存VNet規則保持'
        Assert-Replay ($global:ProceduralFixture.Resources[$workspace.Id].properties.features.preserveMe) '他のWorkspace feature保持'
        $afterTable = $global:ProceduralFixture.Resources[$table.Id]
        Assert-Replay ($afterTable.properties.retentionInDays -eq 30 -and $afterTable.properties.plan -eq 'Analytics') '分析保持とplan保持'
        Assert-Replay ($afterTable.properties.schema.columns[0].name -eq 'KeepColumn') 'schema保持'
        Assert-Replay ($afterTable.properties.totalRetentionInDays -eq 1095 -and -not $afterTable.properties.totalRetentionInDaysAsDefault) '総保持だけ1095に明示設定'
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -eq $table.Id -and $_.Method -eq 'PATCH' }).Count -eq 1) '既存TableはPATCH'
        $rules = @($global:ProceduralFixture.Resources[$lifecycle.Id].properties.policy.rules)
        Assert-Replay (@($rules | Where-Object name -eq 'keep-other-rule')[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 7) '他名ライフルールの設定値保持'
        Assert-Replay (@($rules | Where-Object name -eq 'log-append-1095').Count -eq 1) '1095管理ルール1つ'
        Assert-Replay (@($rules | Where-Object name -eq 'keep-other-rule').Count -eq 1) '他名ライフルール保持'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '既存Storageの不変条件が違う場合は上書きしない' {
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords)[0]
        $storage = @($record.Destinations | Where-Object Kind -eq 'Storage')[0]
        $global:ProceduralFixture.Resources[$storage.Id].sku.name = 'Standard_LRS'
        Reset-Observation
        Invoke-ReplayStep copy -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Id -eq $storage.Id).Count -eq 0) 'SKU不一致を変更しない'
    }
    Invoke-ReplayCase '既存newDCRと関連は切戻しでBeforeへ復元する' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $ids = Get-FixtureIds $subscription
        Add-FixtureResource $ids.Dcr @{
            location = 'japaneast'
            kind = 'Windows'
            tags = @{ keep = 'before' }
            properties = @{
                description = '元のDCR'
                dataSources = @{ windowsEventLogs = @(@{ name = 'before'; streams = @('Microsoft-Event'); xPathQueries = @('Application!*') }) }
                destinations = @{ logAnalytics = @(@{ name = 'before'; workspaceResourceId = '/old-workspace'; workspaceId = 'readonly-guid' }) }
                dataFlows = @(@{ streams = @('Microsoft-Event'); destinations = @('before') })
                immutableId = 'readonly'
                provisioningState = 'Succeeded'
            }
        }
        $machine = @($global:ProceduralFixture.Inventory | Where-Object { $_.id -like "/subscriptions/$subscription/*/old-related" })[0].id
        $association = "$machine/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new"
        Add-FixtureResource $association @{
            properties = @{ description = '元の新側関連'; dataCollectionRuleId = '/legacy-other-dcr'; dataCollectionEndpointId = '/legacy-dce'; provisioningState = 'Succeeded' }
        }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        $dcrEntry = @($record.NewSettings | Where-Object Kind -eq 'Dcr')[0]
        Assert-Replay ($dcrEntry.Before.properties.description -eq '元のDCR') '元DCRのdescription保存'
        Assert-Replay (-not ($dcrEntry.Before.properties.PSObject.Properties.Name -contains 'immutableId')) '読取専用項目を除いて保存'
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        Assert-Replay ($global:ProceduralFixture.Resources[$ids.Dcr].properties.description -eq '元のDCR') 'DCRの元description復元'
        Assert-Replay ($global:ProceduralFixture.Resources[$ids.Dcr].properties.destinations.logAnalytics[0].workspaceResourceId -eq '/old-workspace') 'DCRの元宛先復元'
        Assert-Replay ($global:ProceduralFixture.Resources[$association].properties.dataCollectionRuleId -eq '/legacy-other-dcr') '元の新側関連を復元'
        Assert-Replay ($global:ProceduralFixture.Resources[$association].properties.dataCollectionEndpointId -eq '/legacy-dce') '元DCEも保持'
    }
    Invoke-ReplayCase 'copy途中失敗から未完了だけを再開する' {
        $firstParent = $global:ProceduralFixture.Inventory[0].id
        $id = "$firstParent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"
        $global:ProceduralFixture.Failures["PUT $id"] = 4
        Invoke-ReplayStep copy -ExpectFailure
        $hashes = @{}
        foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
            $hashes[$file.Name] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
        }
        $records = @(Get-FixtureRecords)
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) 'copy失敗中は旧を保持'
        }
        Reset-Observation
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Method -eq 'PUT').Count -eq 1) '不足した新診断だけPUT'
        foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
            Assert-Replay ($hashes[$file.Name] -eq (Get-FileHash $file.FullName -Algorithm SHA256).Hash) '再開でもBefore固定'
        }
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '記録保存に失敗したSubはAzure変更を始めない' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $directory = Join-Path $global:ProceduralFixture.Repository 'records/dev'
        $null = New-Item -ItemType Directory $directory -Force
        $null = New-Item -ItemType Directory (Join-Path $directory "$subscription.json.tmp")
        Invoke-ReplayStep copy -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like "/subscriptions/$subscription/*" }).Count -eq 0) '保存失敗Subの変更0'
    }
    foreach ($step in @('copy', 'verify', 'delete')) {
        Invoke-ReplayCase "作業途中CSV選択変更を拒否: $step" {
            Invoke-ReplayStep copy
            $hashes = @{}
            foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
                $hashes[$file.Name] = (Get-FileHash $file.FullName -Algorithm SHA256).Hash
            }
            $global:ProceduralFixture.Rows[1].VmLogDestination = 'None'
            Write-FixtureCsv
            Reset-Observation
            Invoke-ReplayStep $step -ExpectFailure
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '選択変更後の変更0'
            foreach ($file in Get-ChildItem (Join-Path $global:ProceduralFixture.Repository 'records/dev')) {
                Assert-Replay ($hashes[$file.Name] -eq (Get-FileHash $file.FullName -Algorithm SHA256).Hash) '記録の不変'
            }
        }
    }
    Invoke-ReplayCase '後続Subの未完了は全Subの旧DELETEを止める' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $second = $global:ProceduralFixture.Subscriptions[1]
        $record = @($records | Where-Object { $_.Target.SubscriptionId -eq $second })[0]
        $missing = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')[0]
        $global:ProceduralFixture.Resources.Remove($missing.Id)
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '最初のDELETEも実行しない'
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '全Subの旧を保持'
        }
    }
    Invoke-ReplayCase '旧削除の途中失敗は後続を止め再実行できる' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $firstOld = @($records.OldSettings | Where-Object Kind -eq 'Association')[0]
        $global:ProceduralFixture.Failures["DELETE $($firstOld.Id)"] = 4
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Method -eq 'DELETE').Count -eq 0) '最初の削除失敗後はDELETEなし'
        Reset-Observation
        Invoke-ReplayStep delete
        foreach ($old in $records.OldSettings) {
            Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($old.Id)) '再開後は旧を全削除'
        }
        Invoke-ReplayStep rollback
    }
    Invoke-ReplayCase 'copy後に増えた旧対象をverify/deleteが無視しない' {
        Invoke-ReplayStep copy
        $subscription = $global:ProceduralFixture.Subscriptions[1]
        $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Test/widgets/added-later"
        $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Test/widgets'; location = 'japaneast' }
        Add-FixtureDiagnostic $parent
        Reset-Observation
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '未保存の旧対象では変更0'
    }
    Invoke-ReplayCase '削除直前に旧設定が変われば以降の削除を止める' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $first = @($records.OldSettings | Where-Object Kind -eq 'Association')[0]
        $global:ProceduralFixture.Resources[$first.Id].properties.dataCollectionRuleId = '/externally-changed-rule'
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '別の旧関連も削除しない'
    }
    Invoke-ReplayCase '指定Subだけを切り戻し、他Subはそのまま残す' {
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        $records = @(Get-FixtureRecords)
        $selected = $global:ProceduralFixture.Subscriptions[0]
        $outside = $global:ProceduralFixture.Subscriptions[1]
        Reset-Observation
        Invoke-ReplayStep rollback -SubscriptionIds @($selected)
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like "/subscriptions/$outside/*" }).Count -eq 0) '対象外Subへの変更0'
        foreach ($old in @($records | Where-Object { $_.Target.SubscriptionId -eq $selected }).OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '指定Subの旧を復元'
        }
        foreach ($old in @($records | Where-Object { $_.Target.SubscriptionId -eq $outside }).OldSettings) {
            Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($old.Id)) '対象外Subは削除後状態を保持'
        }
        Invoke-ReplayStep rollback -SubscriptionIds @($outside)
    }
    Invoke-ReplayCase '不明Sub指定のrollbackは変更前に拒否する' {
        Invoke-ReplayStep copy
        Reset-Observation
        Invoke-ReplayStep rollback -SubscriptionIds @('33333333-3333-3333-3333-333333333333') -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '不明Subで変更0'
    }
    Invoke-ReplayCase '旧復元失敗時は新診断設定を残す' {
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        $old = @((Get-FixtureRecords).OldSettings | Where-Object Kind -eq 'Association')[0]
        $global:ProceduralFixture.Failures["PUT $($old.Id)"] = 4
        Reset-Observation
        Invoke-ReplayStep rollback -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Method -eq 'DELETE' -and $_.Id -like "*/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)" }).Count -eq 0) '旧復元失敗で新診断DELETE0'
        Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '旧未復元の新設定は保持'
        Invoke-ReplayStep rollback
    }
    Invoke-ReplayCase '切戻し対象が外部変更されたら上書きしない' {
        Invoke-ReplayStep copy
        $new = @((Get-FixtureRecords).NewSettings | Where-Object Kind -eq 'Diagnostic')[0]
        $global:ProceduralFixture.Resources[$new.Id].properties.logs[0].enabled = $false
        Reset-Observation
        Invoke-ReplayStep rollback -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '外部変更時は復元も削除も開始しない'
    }
    Invoke-ReplayCase '保存先GET失敗を未存在と扱わず削除前に停止する' {
        Invoke-ReplayStep copy
        $workspace = @((Get-FixtureRecords).Destinations | Where-Object Kind -eq 'Workspace')[0]
        $global:ProceduralFixture.Failures["GET $($workspace.Id)"] = 8
        Reset-Observation
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) 'GET失敗で変更0'
    }
    Invoke-ReplayCase '書込み後の期待値不一致を失敗一覧に出す' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.BadReadbackId = $ids.Workspace
        Invoke-ReplayStep copy -ExpectFailure
        $report = Import-Csv (Join-Path $global:ProceduralFixture.Repository 'copy_failures.csv') -Encoding UTF8
        Assert-Replay (@($report | Where-Object ResourceId -eq $ids.Workspace).Count -eq 1) '失敗IDを手動対応CSVへ記録'
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '読戻し不一致のまま旧を削除しない'
    }
    # ---
    # 通信が一時的に失敗した場合だけ再送し、証明書エラーや利用者の中断では止める。
    # ---
    Invoke-ReplayCase '接続断・本文切断・通信timeoutから同じ要求で復旧する' {
        $path = "/subscriptions/$($global:ProceduralFixture.Subscriptions[0])/resources"
        foreach ($type in @('Disconnect', 'BodyEnded', 'Dns', 'LegacyDns', 'Timeout', 'OperationTimeout')) {
            $global:ProceduralFixture.TransportFailures["GET $path"] = @{ Type = $type; Remaining = 1 }
            $beforeSleep = $global:ProceduralFixture.SleepCalls
            Reset-Observation
            Invoke-ReplayStep precheck
            Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object Id -eq $path).Count -eq 2) '失われた通信だけ再試行'
            Assert-Replay ($global:ProceduralFixture.SleepCalls -eq $beforeSleep + 1) '再試行前に待機'
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '接続回復でも資源変更なし'
        }
    }
    Invoke-ReplayCase '通信断が続けば最大4回で止まり旧設定を残す' {
        $path = "/subscriptions/$($global:ProceduralFixture.Subscriptions[0])/resources"
        $global:ProceduralFixture.TransportFailures["GET $path"] = @{ Type = 'Disconnect'; Remaining = 10 }
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object Id -eq $path).Count -eq 4) '通信再試行は4回まで'
        Assert-Replay ($global:ProceduralFixture.SleepCalls -eq 3) '失敗した最後の試行後は待機しない'
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '通信失敗で書込みなし'
    }
    Invoke-ReplayCase 'TLS・明示中断・非通信IO・JSON不正を再試行しない' {
        $path = "/subscriptions/$($global:ProceduralFixture.Subscriptions[0])/resources"
        foreach ($type in @('Tls', 'Cancel', 'CancelSocket', 'OperationCancel', 'OtherIo')) {
            $global:ProceduralFixture.TransportFailures["GET $path"] = @{ Type = $type; Remaining = 10 }
            Reset-Observation
            Invoke-ReplayStep precheck -ExpectFailure
            Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object Id -eq $path).Count -eq 1) '通信回復対象外は再送しない'
            Assert-Replay ($global:ProceduralFixture.SleepCalls -eq 0) '中断や恒久失敗は待機しない'
        }
        $global:ProceduralFixture.TransportFailures.Clear()
        $global:ProceduralFixture.InvalidJsonKeys = @("GET $path")
        Reset-Observation
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object Id -eq $path).Count -eq 1) 'JSON不正はIWRの外で失敗し再送しない'
    }
    Invoke-ReplayCase '429・503はRetryAfterを守って従来どおり再試行する' {
        $path = "/subscriptions/$($global:ProceduralFixture.Subscriptions[0])/resources"
        foreach ($status in @(429, 503)) {
            $global:ProceduralFixture.HttpFailures["GET $path"] = @{ Status = $status; Code = 'TEST_TRANSIENT'; Remaining = 1; RetryAfter = 3 }
            Reset-Observation
            Invoke-ReplayStep precheck
            Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object Id -eq $path).Count -eq 2) '一時HTTPだけ再試行'
            Assert-Replay ($global:ProceduralFixture.SleepSeconds[-1] -eq 3) '指定されたRetryAfter秒待つ'
        }
    }
    Invoke-ReplayCase 'DELETE応答喪失後の404だけを削除済みとして継続する' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $deleted = @($records.OldSettings | Where-Object Kind -eq 'Association')[0]
        $global:ProceduralFixture.LoseDeleteResponseId = $deleted.Id
        Reset-Observation
        Invoke-ReplayStep delete
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object { $_.Method -eq 'DELETE' -and $_.Id -eq $deleted.Id }).Count -eq 2) '削除実行後の応答喪失と404再確認'
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Method -eq 'DELETE' -and $_.Id -eq $deleted.Id }).Count -eq 1) '実体の削除は1回だけ'
        foreach ($old in $records.OldSettings) { Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($old.Id)) '全旧設定を削除済み' }
        . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
        $subscriptionId = $global:ProceduralFixture.Subscriptions[0]
        $failed = $false
        try { $null = Invoke-ArmRequest -Resource $deleted -Method Delete } catch { $failed = $true }
        Assert-Replay $failed '初回404を一律成功にはしない'
        $failed = $false
        try { $null = Invoke-ArmRequest -Resource $deleted } catch { $failed = $true }
        Assert-Replay $failed '非DELETEの404へ喪失フラグを引き継がない'
    }
    Invoke-ReplayCase 'Wait付きPUTは1回だけ送信し以後はBody無しGETで待つ' {
        Invoke-ReplayStep copy
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.PendingWriteStates[$ids.Workspace] = 'Updating'
        $global:ProceduralFixture.PendingReads[$ids.Workspace] = 6
        $global:ProceduralFixture.ClockStep = 60
        Reset-Observation
        . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
        $subscriptionId = $global:ProceduralFixture.Subscriptions[0]
        $null = Invoke-ArmRequest $ids.Workspace -Method Put -ApiVersion '2023-09-01' -Body @{ location = 'japaneast'; properties = @{ retentionInDays = 90 } } -Wait
        $requests = @($global:ProceduralFixture.Requests | Where-Object Id -eq $ids.Workspace)
        Assert-Replay (@($requests | Where-Object Method -eq 'PUT').Count -eq 1) 'PUTを繰り返して作成を再開始しない'
        Assert-Replay (@($requests | Where-Object Method -eq 'GET').Count -eq 7) '5分後もSucceededまでGETを続ける'
        Assert-Replay (@($requests | Where-Object { $_.Method -eq 'GET' -and $_.HasBody }).Count -eq 0) 'GETへ書込み本文を持ち越さない'
    }
    Invoke-ReplayCase '作成待ちのFailed・Canceledは即停止する' {
        Invoke-ReplayStep copy
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        foreach ($state in @('Failed', 'Canceled')) {
            $global:ProceduralFixture.PendingReads[$ids.Workspace] = 1
            $global:ProceduralFixture.PendingStates[$ids.Workspace] = $state
            Reset-Observation
            Invoke-ReplayStep copy -ExpectFailure
            Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '終端失敗状態には追加書込みしない'
            Assert-Replay ($global:ProceduralFixture.SleepCalls -eq 0) '終端失敗は待ち続けない'
        }
    }
    Invoke-ReplayCase '対応IWRだけ本文timeoutを設定し未対応環境へ余計なparameterを送らない' {
        . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
        $subscriptionId = $global:ProceduralFixture.Subscriptions[0]
        $id = $global:ProceduralFixture.Inventory[0].id + '/providers/Microsoft.Insights/diagnosticSettings/old'
        $null = Invoke-ArmRequest $id -ApiVersion '2021-05-01-preview'
        Assert-Replay (@($global:ProceduralFixture.OperationTimeoutValues | Where-Object { $_ -eq 300 }).Count -eq 1) '対応IWRには本文timeout300秒を渡す'
        function Get-Command { param($Name) [pscustomobject]@{ Parameters = @{} } }
        $null = Invoke-ArmRequest $id -ApiVersion '2021-05-01-preview'
        Assert-Replay (@($global:ProceduralFixture.OperationTimeoutValues | Where-Object { $_ -eq 0 }).Count -eq 1) '未対応IWRへ新しいparameterを渡さない'
    }
    Invoke-ReplayCase '一時的な401は認証を更新して再試行する' {
        $global:ProceduralFixture.UnauthorizedReads = 1
        Invoke-ReplayStep precheck
        Assert-Replay ($global:ProceduralFixture.TokenReads -ge 2) '401でtoken再取得'
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '認証更新は設定変更なし'
    }
    Invoke-ReplayCase '登録前providerは記録保存後に登録する' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $provider = "/subscriptions/$subscription/providers/Microsoft.Storage"
        $global:ProceduralFixture.UnregisteredProviders[$provider] = 'NotRegistered'
        $global:ProceduralFixture.ProviderPendingReads[$provider] = 6
        $global:ProceduralFixture.ClockStep = 60
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -eq "$provider/register" }).Count -eq 1) '必要providerを1回登録'
        Assert-Replay (-not $global:ProceduralFixture.WriteBeforeBackup) '登録より前に記録保存'
        Assert-Replay ($global:ProceduralFixture.ProviderPendingReads[$provider] -eq 0) '5分を超えてもRegisteredまで状態確認'
    }
    Invoke-ReplayCase '旧診断名と新診断名が同じでもNone側は旧を削除・復元する' -Diagnostic 'None' -Vm 'None' -Body {
        $parent = $global:ProceduralFixture.Inventory[0].id
        $oldId = "$parent/providers/Microsoft.Insights/diagnosticSettings/old"
        $old = $global:ProceduralFixture.Resources[$oldId]
        $global:ProceduralFixture.Resources.Remove($oldId)
        Add-FixtureResource "$parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)" $old
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey("$parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)")) '同名でも対象旧設定は削除'
        Invoke-ReplayStep rollback
        Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey("$parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)")) '元の同名旧設定を復元'
    }
    Invoke-ReplayCase '指定2DCRでも対象外Subの関連を変更しない' {
        $outside = '/subscriptions/33333333-3333-3333-3333-333333333333/resourceGroups/source/providers/Microsoft.Compute/virtualMachines/outside/providers/Microsoft.Insights/dataCollectionRuleAssociations/old'
        Add-FixtureResource $outside @{
            properties = @{ dataCollectionRuleId = $global:ProceduralFixture.OldDcrIds[0]; description = '対象外'; provisioningState = 'Succeeded' }
        }
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Id -eq $outside).Count -eq 0) '対象外Subの変更0'
        Assert-Replay ($global:ProceduralFixture.Resources[$outside].properties.description -eq '対象外') '対象外の設定保持'
    }
    Invoke-ReplayCase '未知の地域略称は事前確認で停止する' {
        $global:ProceduralFixture.Inventory[0].location = 'unknown-region'
        Invoke-ReplayStep precheck -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '未知地域の変更0'
    }
    Invoke-ReplayCase '対応する既存Waiverは切戻しでも保持する' {
        $configuration = & {
            . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
            @($policyAssignments)
        }
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $assignment = $configuration[0]
        $name = ($assignment.Id -split '/')[-1]
        $id = "/subscriptions/$subscription/providers/Microsoft.Authorization/policyExemptions/log-migration-dev-$name"
        Add-FixtureResource $id @{
            properties = @{
                policyAssignmentId = $assignment.Id
                policyDefinitionReferenceIds = @($assignment.ReferenceIds)
                exemptionCategory = 'Waiver'
                assignmentScopeValidation = 'Default'
                expiresOn = $null
                resourceSelectors = @()
            }
        }
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($id)) 'もともとあったWaiverを残す'
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Id -eq $id).Count -eq 0) '既存一致Waiverへの書込み0'
    }
    Invoke-ReplayCase '内容の違う既存Waiverを上書きしない' {
        $configuration = & {
            . (Join-Path $global:ProceduralFixture.Repository 'common.ps1') -SkipCsv
            @($policyAssignments)
        }
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $name = ($configuration[0].Id -split '/')[-1]
        $id = "/subscriptions/$subscription/providers/Microsoft.Authorization/policyExemptions/log-migration-dev-$name"
        Add-FixtureResource $id @{ properties = @{ policyAssignmentId = '/other-assignment'; exemptionCategory = 'Mitigated' } }
        Invoke-ReplayStep copy -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like "/subscriptions/$subscription/*" }).Count -eq 0) '不一致WaiverのSubは準備を止める'
        Assert-Replay ($global:ProceduralFixture.Resources[$id].properties.policyAssignmentId -eq '/other-assignment') '既存値は保持'
    }
    Invoke-ReplayCase 'コピー途中の失敗状態から直接切り戻せる' {
        $parent = $global:ProceduralFixture.Inventory[0].id
        $global:ProceduralFixture.Failures["PUT $parent/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"] = 4
        Invoke-ReplayStep copy -ExpectFailure
        $records = @(Get-FixtureRecords)
        Reset-Observation
        Invoke-ReplayStep rollback
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '元の旧設定を保持'
        }
        foreach ($setting in @($records.NewSettings | Where-Object Kind -in @('Diagnostic', 'Association'))) {
            Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($setting.Id)) '途中で追加された送信設定だけを除去'
        }
        Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '途中copyの切戻しでも旧を先に確認'
    }
    Invoke-ReplayCase 'コピー完了後は旧設定を書き直さず切り戻せる' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        Reset-Observation
        Invoke-ReplayStep rollback
        foreach ($old in $records.OldSettings) {
            Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Id -eq $old.Id).Count -eq 0) '残っている旧設定に不要PUTなし'
        }
        Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '旧保持を確認してから新を除去'
    }
    Invoke-ReplayCase '旧設定を一部削除した失敗状態から直接切り戻せる' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $second = @($records.OldSettings | Where-Object Kind -eq 'Association')[1]
        $global:ProceduralFixture.Failures["DELETE $($second.Id)"] = 4
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object Method -eq 'DELETE').Count -eq 1) '最初の旧関連だけ削除して停止'
        Invoke-ReplayStep rollback
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '一部削除した旧設定を全て戻す'
        }
        Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '全旧復元前の新削除なし'
    }
    Invoke-ReplayCase 'DCR更新中の応答を待って完了を確認する' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.PendingReads[$ids.Dcr] = 2
        Invoke-ReplayStep copy
        Assert-Replay ($global:ProceduralFixture.SleepCalls -ge 2) 'Updatingの間は待機'
        Assert-Replay ($global:ProceduralFixture.PendingReads[$ids.Dcr] -eq 0) 'Succeededの読戻しまで取得'
        Invoke-ReplayStep verify
    }
    foreach ($pending in @(
        @{ Name = 'StorageのResolvingDnsを待って設定を完了する'; Kind = 'Storage'; State = 'ResolvingDns' },
        @{ Name = 'LAWのProvisioningを待って設定を完了する'; Kind = 'Workspace'; State = 'Provisioning' }
    )) {
        Invoke-ReplayCase $pending.Name -Vm 'None' -NoSources -Body {
            $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
            $id = $ids.($pending.Kind)
            $global:ProceduralFixture.PendingReads[$id] = 2
            $global:ProceduralFixture.PendingStates[$id] = $pending.State
            Invoke-ReplayStep copy
            Assert-Replay ($global:ProceduralFixture.PendingReads[$id] -eq 0) '途中状態を通過してから完了を確認'
            Assert-Replay ($global:ProceduralFixture.SleepCalls -ge 2) '作成中は間隔を空けて待機'
            Assert-Replay ($global:ProceduralFixture.Resources[$id].properties.provisioningState -eq 'Succeeded') '保存先がSucceeded'
            Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -eq $id -and $_.Method -eq 'PUT' }).Count -eq 1) '作成中の保存先へPUTを重ねない'
            Invoke-ReplayStep verify
        }
    }
    Invoke-ReplayCase '保存先の作成待ちは5分を超えても成功までGETだけで待つ' {
        Invoke-ReplayStep copy
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.PendingReads[$ids.Workspace] = 100
        $global:ProceduralFixture.ClockStep = 60
        Reset-Observation
        Invoke-ReplayStep copy
        Assert-Replay ($global:ProceduralFixture.SleepCalls -ge 100) '固定5分を超えても状態を確認する'
        Assert-Replay ($global:ProceduralFixture.PendingReads[$ids.Workspace] -eq 0) '成功の読戻しまで待機'
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '待機中は保存先を書き直さない'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '総保持が1095でも既定値フラグのままなら明示設定する' {
        Invoke-ReplayStep copy
        $table = @((Get-FixtureRecords).Destinations | Where-Object Kind -eq 'Table')[0]
        Set-FixtureProperty $global:ProceduralFixture.Resources[$table.Id].properties 'totalRetentionInDaysAsDefault' $true
        Reset-Observation
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '明示設定前の旧削除なし'
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -eq $table.Id -and $_.Method -eq 'PATCH' }).Count -eq 1) '総保持を明示するPATCH1回'
        Assert-Replay (-not $global:ProceduralFixture.Resources[$table.Id].properties.totalRetentionInDaysAsDefault) '既定値フラグ解除'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '変更前記録がなければ確認と削除を開始しない' {
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '記録なしの変更0'
    }
    Invoke-ReplayCase '通常一覧にある主要タイプと子IDを同じ診断処理へ通す' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $paths = @(
            'Microsoft.Web/sites/app',
            'Microsoft.Web/sites/function',
            'Microsoft.Web/sites/app/slots/slot',
            'Microsoft.ContainerService/managedClusters/aks',
            'Microsoft.Sql/servers/sql/databases/master',
            'Microsoft.CognitiveServices/accounts/foundry/projects/project',
            'Microsoft.KeyVault/vaults/vault',
            'Microsoft.ServiceBus/namespaces/bus'
        )
        foreach ($path in $paths) {
            $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/$path"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = $path; location = 'japaneast' }
            Add-FixtureDiagnostic $parent
        }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        Assert-Replay (@($record.OldSettings | Where-Object Kind -eq 'Diagnostic').Count -eq $paths.Count + 1) '一覧にある旧診断を全て保存'
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        foreach ($path in $paths) {
            $id = "/subscriptions/$subscription/resourceGroups/rg-source/providers/$path/providers/Microsoft.Insights/diagnosticSettings/old"
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($id)) '同じ汎用処理で元の診断へ復元'
        }
    }
    Invoke-ReplayCase 'DCRのInvalidOutputTableだけは反映を待って再試行する' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.HttpFailures["PUT $($ids.Dcr)"] = @{
            Status = 400
            Code = 'InvalidOutputTable: OUTPUT TABLE "Event" is not ready'
            Remaining = 1
        }
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $ids.Dcr }).Count -eq 2) '一時的なDCRエラーの後だけ再PUT'
        Assert-Replay ($global:ProceduralFixture.SleepCalls -ge 1) '出力Tableの反映を待つ'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '組み込みSyslogの反映遅延が5分を超えてもDCRを完了する' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        $global:ProceduralFixture.HttpFailures["PUT $($ids.Dcr)"] = @{ Status = 400; Code = 'InvalidOutputTable: The table for the output stream "Microsoft-Syslog" is not available'; Remaining = 40 }
        $global:ProceduralFixture.ClockStep = 10
        Invoke-ReplayStep copy
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $ids.Dcr }).Count -eq 41) '既知のテーブル反映だけ期限で打ち切らない'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase 'custom tableのInvalidOutputTableを反映待ちと誤認しない' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        foreach ($message in @('InvalidOutputTable: Custom_CL is invalid', 'InvalidOutputTable: output table "Custom_CL" is invalid; collected stream "Microsoft-Event"', 'InvalidOutputTable: collected stream "Microsoft-Event" is invalid', 'InvalidOutputTable: output stream "Microsoft-Event" uses table "Custom_CL" which is invalid')) {
            Reset-Observation
            $global:ProceduralFixture.HttpFailures["PUT $($ids.Dcr)"] = @{ Status = 400; Code = $message; Remaining = 10 }
            Invoke-ReplayStep copy -ExpectFailure
            Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $ids.Dcr }).Count -eq 1) 'custom tableや収集streamの言及だけでは再試行しない'
        }
    }
    Invoke-ReplayCase 'DCRの一般400は再試行せずそのSubを止める' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        $ids = Get-FixtureIds $subscription
        $global:ProceduralFixture.HttpFailures["PUT $($ids.Dcr)"] = @{
            Status = 400
            Code = 'InvalidRequest: permanent error'
            Remaining = 10
        }
        Invoke-ReplayStep copy -ExpectFailure
        Assert-Replay (@($global:ProceduralFixture.Requests | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $ids.Dcr }).Count -eq 1) '一般400を何度も送信しない'
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like "/subscriptions/$subscription/*/dataCollectionRuleAssociations/dcr-new" }).Count -eq 0) '失敗DCRへの新関連付けを開始しない'
        foreach ($old in @((Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription }).OldSettings)) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '一般400失敗時は旧設定保持'
        }
    }
    Invoke-ReplayCase '新診断の余分なWorkspaceとEventHubを許容しない' {
        Invoke-ReplayStep copy
        $records = @(Get-FixtureRecords)
        $setting = @($records.NewSettings | Where-Object Kind -eq 'Diagnostic')[0]
        $actual = $global:ProceduralFixture.Resources[$setting.Id]
        Set-FixtureProperty $actual.properties 'workspaceId' '/unexpected-workspace'
        Set-FixtureProperty $actual.properties 'eventHubAuthorizationRuleId' '/unexpected-eventhub-rule'
        Set-FixtureProperty $actual.properties 'eventHubName' 'unexpected-hub'
        Reset-Observation
        Invoke-ReplayStep copy -ExpectFailure
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '宛先追加を上書きせず旧も削除しない'
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '全旧設定を保持'
        }
    }
    Invoke-ReplayCase '既存DCRへの余分な収集源追加を許容せず切戻しも上書きしない' {
        $ids = Get-FixtureIds $global:ProceduralFixture.Subscriptions[0]
        Add-FixtureResource $ids.Dcr @{
            location = 'japaneast'
            properties = @{
                description = '元のDCR'
                dataSources = @{ windowsEventLogs = @(@{ name = 'before'; streams = @('Microsoft-Event'); xPathQueries = @('Application!*') }) }
                destinations = @{ logAnalytics = @(@{ name = 'before'; workspaceResourceId = '/old-workspace' }) }
                dataFlows = @(@{ streams = @('Microsoft-Event'); destinations = @('before') })
                provisioningState = 'Succeeded'
            }
        }
        Invoke-ReplayStep copy
        $actual = $global:ProceduralFixture.Resources[$ids.Dcr]
        Set-FixtureProperty $actual.properties.dataSources 'performanceCounters' @([pscustomobject]@{
            name = 'externally-added'
            streams = @('Microsoft-Perf')
            samplingFrequencyInSeconds = 60
            counterSpecifiers = @('\Processor(_Total)\% Processor Time')
        })
        Reset-Observation
        Invoke-ReplayStep verify -ExpectFailure
        Invoke-ReplayStep delete -ExpectFailure
        Invoke-ReplayStep rollback -ExpectFailure
        Assert-Replay ($global:ProceduralFixture.Writes.Count -eq 0) '余分な収集源があるDCRも旧設定も上書きしない'
        Assert-Replay ($global:ProceduralFixture.Resources[$ids.Dcr].properties.dataSources.performanceCounters[0].name -eq 'externally-added') '外部変更は保持'
    }
    Invoke-ReplayCase '未選択Subの記録JSONが壊れていても指定Subだけを切り戻せる' {
        Invoke-ReplayStep copy
        Invoke-ReplayStep delete
        $records = @(Get-FixtureRecords)
        $selected = $global:ProceduralFixture.Subscriptions[0]
        $outside = $global:ProceduralFixture.Subscriptions[1]
        $outsidePath = Join-Path $global:ProceduralFixture.Repository "records/dev/$outside.json"
        [IO.File]::WriteAllText($outsidePath, '{invalid-json', [Text.Encoding]::UTF8)
        $beforeHash = (Get-FileHash $outsidePath -Algorithm SHA256).Hash
        Reset-Observation
        Invoke-ReplayStep rollback -SubscriptionIds @($selected)
        Assert-Replay (@($global:ProceduralFixture.Writes | Where-Object { $_.Id -like "/subscriptions/$outside/*" }).Count -eq 0) '壊れた未選択Subへの変更0'
        Assert-Replay ($beforeHash -eq (Get-FileHash $outsidePath -Algorithm SHA256).Hash) '未選択のJSONもそのまま残す'
        foreach ($old in @($records | Where-Object { $_.Target.SubscriptionId -eq $selected }).OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '指定Subは正常に旧設定へ復元'
        }
    }
    Invoke-ReplayCase '実runspaceで5件以上の診断GETとPUTを処理する' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        foreach ($number in 1..8) {
            $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Test/widgets/parallel-$number"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Test/widgets'; location = 'japaneast' }
            Add-FixtureDiagnostic $parent
        }
        Invoke-ReplayStep copy
        $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
        $diagnostics = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        Assert-Replay ($diagnostics.Count -eq 9) '全9診断の新設定を記録'
        foreach ($setting in $diagnostics) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($setting.Id)) '並列処理に欠落なし'
        }
        $workers = @($global:ProceduralFixture.Requests | Where-Object { $_.RunspaceId -ne $script:mainRunspaceId })
        Assert-Replay (@($workers | Where-Object { $_.Method -eq 'GET' -and $_.Id -like '*/diagnosticSettings' }).Count -ge 5) '別runspaceから診断GET5件以上'
        Assert-Replay (@($workers | Where-Object { $_.Method -eq 'PUT' -and $_.Id -like "*/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)" }).Count -ge 5) '別runspaceから診断PUT5件以上'
        Assert-Replay ($global:ProceduralFixture.WorkerRunspaceIds.Count -ge 2) '複数の実runspaceを使用'
        Invoke-ReplayStep verify
    }
    Invoke-ReplayCase '並列worker1件の失敗を記録し再実行で欠落だけを補う' {
        $subscription = $global:ProceduralFixture.Subscriptions[0]
        foreach ($number in 1..8) {
            $parent = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Test/widgets/parallel-$number"
            $global:ProceduralFixture.Inventory += [pscustomobject]@{ id = $parent; type = 'Microsoft.Test/widgets'; location = 'japaneast' }
            Add-FixtureDiagnostic $parent
        }
        $failedId = "/subscriptions/$subscription/resourceGroups/rg-source/providers/Microsoft.Test/widgets/parallel-3/providers/Microsoft.Insights/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)"
        $global:ProceduralFixture.Failures["PUT $failedId"] = 4
        Invoke-ReplayStep copy -ExpectFailure
        Assert-Replay (-not $global:ProceduralFixture.Resources.ContainsKey($failedId)) '失敗workerだけが未完了'
        $records = @(Get-FixtureRecords)
        foreach ($old in $records.OldSettings) {
            Assert-Replay ($global:ProceduralFixture.Resources.ContainsKey($old.Id)) '並列失敗中も旧設定を保持'
        }
        Reset-Observation
        Invoke-ReplayStep copy
        $puts = @($global:ProceduralFixture.Writes | Where-Object { $_.Method -eq 'PUT' -and $_.Id -like "*/diagnosticSettings/$($global:ProceduralFixture.DiagnosticName)" })
        Assert-Replay ($puts.Count -eq 1 -and $puts[0].Id -eq $failedId) '再実行は失敗1件だけPUT'
        Invoke-ReplayStep verify
        Invoke-ReplayStep delete
        Invoke-ReplayStep rollback
        Assert-Replay (-not $global:ProceduralFixture.UnsafeNewDelete) '並列後も旧復元順序を維持'
    }
    foreach ($identityType in @('SystemAssigned', 'None', 'SystemAssigned, UserAssigned')) {
        Invoke-ReplayCase "既存DCRのIdentity[$identityType]を維持して全工程と切戻しを行う" {
            $subscription = $global:ProceduralFixture.Subscriptions[0]
            $ids = Get-FixtureIds $subscription
            $identity = @{
                type = $identityType
                principalId = 'readonly-system-principal'
                tenantId = 'readonly-tenant'
            }
            $identityIds = @()
            if ($identityType -like '*UserAssigned*') {
                $identityIds = @(
                    "/subscriptions/$subscription/resourceGroups/identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/first",
                    "/subscriptions/$subscription/resourceGroups/identity/providers/Microsoft.ManagedIdentity/userAssignedIdentities/second"
                )
                $identity.userAssignedIdentities = @{}
                foreach ($identityId in $identityIds) {
                    $identity.userAssignedIdentities[$identityId] = @{ principalId = 'readonly-user-principal'; clientId = 'readonly-user-client' }
                }
            }
            Add-FixtureResource $ids.Dcr @{
                location = 'japaneast'
                identity = $identity
                properties = @{
                    description = 'Identity確認用の既存DCR'
                    dataSources = @{ windowsEventLogs = @(@{ name = 'before'; streams = @('Microsoft-Event'); xPathQueries = @('Application!*') }) }
                    destinations = @{ logAnalytics = @(@{ name = 'before'; workspaceResourceId = '/old-workspace' }) }
                    dataFlows = @(@{ streams = @('Microsoft-Event'); destinations = @('before') })
                    provisioningState = 'Succeeded'
                }
            }
            Invoke-ReplayStep copy
            $record = @(Get-FixtureRecords | Where-Object { $_.Target.SubscriptionId -eq $subscription })[0]
            $saved = @($record.NewSettings | Where-Object Kind -eq 'Dcr')[0]
            Assert-Replay ($saved.Before.identity.type -ceq $identityType) '変更前のidentity.typeを保存'
            Assert-Replay ('principalId' -notin $saved.Before.identity.PSObject.Properties.Name -and 'tenantId' -notin $saved.Before.identity.PSObject.Properties.Name) 'Beforeから読取り専用のシステムIDを除去'
            if ($identityIds.Count) {
                Assert-Replay (@($saved.Before.identity.userAssignedIdentities.PSObject.Properties).Count -eq 2) '複数のUserAssignedキーを保存'
                foreach ($identityId in $identityIds) {
                    Assert-Replay ($identityId -in $saved.Before.identity.userAssignedIdentities.PSObject.Properties.Name) 'UserAssignedのリソースIDを保持'
                    Assert-Replay (@($saved.Before.identity.userAssignedIdentities.$identityId.PSObject.Properties).Count -eq 0) 'UserAssignedの採番済みID値を除去'
                }
            }
            else {
                Assert-Replay (-not $saved.Before.identity.userAssignedIdentities) 'UserAssignedなしでも余分なキーを作らない'
            }
            Invoke-ReplayStep verify
            Invoke-ReplayStep delete
            Invoke-ReplayStep rollback
            $restored = $global:ProceduralFixture.Resources[$ids.Dcr].identity
            Assert-Replay ($restored.type -ceq $identityType) '切戻し後もidentity.typeを維持'
            if ($identityIds.Count) {
                Assert-Replay (@($restored.userAssignedIdentities.PSObject.Properties).Count -eq 2) '切戻しでUserAssignedキーを欠落させない'
                foreach ($identityId in $identityIds) {
                    Assert-Replay ($identityId -in $restored.userAssignedIdentities.PSObject.Properties.Name) '切戻し後も元のUserAssignedリソースID'
                }
            }
            foreach ($write in @($global:ProceduralFixture.Writes | Where-Object { $_.Method -eq 'PUT' -and $_.Id -eq $ids.Dcr })) {
                Assert-Replay ($write.Body.identity.type -ceq $identityType) '作成・復元のPUTともidentity.typeを維持'
                Assert-Replay ('principalId' -notin $write.Body.identity.PSObject.Properties.Name -and 'tenantId' -notin $write.Body.identity.PSObject.Properties.Name) 'PUTへ読取り専用のシステムIDを送らない'
                foreach ($identityId in $identityIds) {
                    Assert-Replay (@($write.Body.identity.userAssignedIdentities.$identityId.PSObject.Properties).Count -eq 0) 'PUTへUserAssignedの読取り専用値を送らない'
                }
            }
        }
    }
    # --------------------------------------------------
    # 全ファイルの構文と、試験の前後でコードが変わっていないことを確かめる。
    # 実行したケースと判定数を、結果ファイルへまとめる。
    # --------------------------------------------------
    foreach ($name in $sourceFiles) {
        $tokens = $null
        $errors = $null
        $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository $name), [ref]$tokens, [ref]$errors)
        Assert-Replay ($errors.Count -eq 0) "$name の構文"
        Assert-Replay ($sourceHashes[$name] -eq (Get-FileHash (Join-Path $Repository $name) -Algorithm SHA256).Hash) "$name の検証前後不変"
    }
    $result = [pscustomobject]@{
        Result = 'PASS'
        Cases = $cases.ToArray()
        CaseCount = $cases.Count
        Checks = $checks
        AzureRequests = 0
        PowerShellVersion = $PSVersionTable.PSVersion.ToString()
        Hashes = $sourceHashes
        RealParallelRunspaces = $parallelRunspaceIds.Count
        RequestsFromParallelRunspaces = $parallelRequestCount
    }
    if ($ReportPath) {
        $result | ConvertTo-Json -Depth 20 | Set-Content $ReportPath -Encoding UTF8
    }
    if ($PassThru) {
        $result
    }
    else {
        $result | ConvertTo-Json -Depth 20
    }
}
catch {
    if ($ReportPath) {
        [pscustomobject]@{
            Case = $script:activeCase
            Error = $_.Exception.Message
            Position = $_.InvocationInfo.PositionMessage
            Writes = @($global:ProceduralFixture.Writes)
        } | ConvertTo-Json -Depth 30 | Set-Content ($ReportPath + '.failure.json') -Encoding UTF8
    }
    throw
}
finally {
    if (Test-Path $scratch) {
        Remove-Item $scratch -Recurse -Force
    }
    $global:ProceduralFixture = $null
    [ProceduralReplay.SharedFixture]::State = $null
}
