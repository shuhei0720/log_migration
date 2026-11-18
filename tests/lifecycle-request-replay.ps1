#Requires -Version 5.1
param(
    [string]$SourceCommon = (Join-Path (Split-Path -Parent $PSScriptRoot) 'log_migration_common.ps1'),
    [int]$MissingPolicyNullCount = 0,
    [string]$ResultPath,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
$tokens=$null; $errors=$null
$ast=[Management.Automation.Language.Parser]::ParseFile($SourceCommon,[ref]$tokens,[ref]$errors)
if ($errors.Count) { throw '構文エラーがあります。' }
$functions=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst]},$true))
foreach ($name in @('Get-OptionalArmResource','Test-BaselineValues')) {
    $node=$functions | Where-Object Name -eq $name
    Invoke-Expression $node.Extent.Text
}
$arm=$functions | Where-Object Name -eq 'Invoke-ArmRequest'
$script:actualArmRequest=[scriptblock]::Create($arm.Body.Extent.Text.Substring(1,$arm.Body.Extent.Text.Length-2))
$baseline=$functions | Where-Object Name -eq 'Set-MigrationBaseline'
$storageLoop=@($baseline.FindAll({param($n) $n -is [Management.Automation.Language.ForEachStatementAst] -and $n.Variable.VariablePath.UserPath -eq 'storagePlan'},$true))[0]
$statements=@($storageLoop.Body.Statements)
$index=-1
for ($i=0;$i -lt $statements.Count;$i++) { if ($statements[$i].Extent.Text -match '^\$stage = "ライフサイクル"$') { $index=$i;break } }
if ($index -lt 0) { throw '本体のライフサイクル処理を見つけられません。' }
$expectedCode=$statements[$index+1].Extent.Text
$tryCode=$statements[$index+2].Extent.Text
$script:capturedBody=$null
$script:capturedJson=''
$script:checks=0
$script:checkRecords=[System.Collections.Generic.List[object]]::new()
function Assert-Replay([bool]$Condition,[string]$Message) { if (-not $Condition) { throw $Message };$script:checks++ }
function Get-ArmToken { [pscustomobject]@{accessToken='OFFLINE_NOT_A_TOKEN'} }
function Add-MigrationCheck {
    param($Target,$ResourceId,$Stage,$Success,$Message,$Expected)
    $script:checkRecords.Add([pscustomobject]@{Success=$Success;Message=$Message})
}
# GETだけを保存済み状態で再現し、PUTは本体のUTF8シリアライズ処理まで通します。
function Invoke-ArmRequest {
    param([string]$ResourceId,[string]$Method='Get',[hashtable]$Body,[string]$ApiVersion='2024-03-11')
    if ($Method -eq 'Get' -and -not $script:capturedBody) {
        if ($script:caseName -eq 'Missing') { throw 'ARM Get 失敗 (404): ManagementPolicyNotFound' }
        return $script:initialPolicy
    }
    & $script:actualArmRequest @PSBoundParameters
}
# HTTP境界を置き換えます。外部通信はせず、送信されるBodyだけを捕捉します。
function Invoke-RestMethod {
    param($Uri,$Method,$TimeoutSec,$Headers,$ContentType,$Body)
    if ($Method -eq 'Put') {
        $script:capturedJson=[Text.Encoding]::UTF8.GetString($Body)
        $script:capturedBody=$script:capturedJson | ConvertFrom-Json
        if (@($script:capturedBody.properties.policy.rules | Where-Object {$null -eq $_}).Count -gt 0) {
            throw 'OFFLINE_SCHEMA_INVALID_NULL_RULE'
        }
    }
    $script:capturedBody
}
$resourceId='/subscriptions/offline/resourceGroups/offline/providers/Microsoft.Storage/storageAccounts/offline/managementPolicies/default'
$Target=@{SubscriptionName='offline';SubscriptionId='offline'}
$VerifyOnly=$false
$env:MIGRATION_ARM_TRACE=''
$results=@(foreach ($caseName in @('Missing','Empty','OtherRule','ReplaceOwnRule')) {
    $script:caseName=$caseName
    $script:capturedBody=$null; $script:capturedJson='';$script:checkRecords.Clear()
    $ready=$true
    Invoke-Expression $expectedCode
    $other=@{name='keep-other';enabled=$true;type='Lifecycle';definition=@{filters=@{blobTypes=@('blockBlob')};actions=@{baseBlob=@{delete=@{daysAfterModificationGreaterThan=99}}}}}
    $oldOwn=@{name='log-append-365';enabled=$false;type='Lifecycle';definition=@{filters=@{blobTypes=@('appendBlob')};actions=@{baseBlob=@{delete=@{daysAfterModificationGreaterThan=1}}}}}
    $initialRules=switch ($caseName) { 'Empty' {@()};'OtherRule' {@($other)};'ReplaceOwnRule' {@($oldOwn,$other)} }
    $script:initialPolicy=if ($caseName -eq 'Missing') {$null} else {[pscustomobject]@{properties=[pscustomobject]@{policy=[pscustomobject]@{rules=@($initialRules)}}}}
    if ($caseName -eq 'Missing') {
        $missingProbe=Get-OptionalArmResource -ResourceId $resourceId -ApiVersion '2023-05-01'
        Assert-Replay ($null -eq $missingProbe) '404を本当のnullとして再現できていません。'
    }
    Invoke-Expression $tryCode
    $rules=@($script:capturedBody.properties.policy.rules)
    $nullCount=@($rules | Where-Object {$null -eq $_}).Count
    $expectedNulls=if ($caseName -eq 'Missing') {$MissingPolicyNullCount} else {0}
    Assert-Replay ($nullCount -eq $expectedNulls) "$caseName : nullルールが混入しています。"
    $ownRules=@($rules | Where-Object {$_.name -eq 'log-append-365'})
    Assert-Replay ($ownRules.Count -eq 1 -and $ownRules[0].enabled -eq $true) "$caseName : 自分のルールが一意に設定されていません。"
    $wantedCount=if ($caseName -in @('OtherRule','ReplaceOwnRule')) {2} else {1+$expectedNulls}
    Assert-Replay ($rules.Count -eq $wantedCount) "$caseName : 送信するルール数が一致しません。"
    Assert-Replay ($script:checkRecords.Count -eq 1 -and $script:checkRecords[0].Success -eq ($expectedNulls -eq 0)) "$caseName : 成否が一致しません。"
    if ($caseName -in @('OtherRule','ReplaceOwnRule')) {
        $kept=@($rules | Where-Object {$_.name -eq 'keep-other'})
        Assert-Replay ($kept.Count -eq 1 -and $kept[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 99) "$caseName : 他ルールが変わっています。"
    }
    [pscustomobject]@{Case=$caseName;RulesCount=$rules.Count;NullCount=$nullCount;Success=$script:checkRecords[0].Success;RequestBody=$script:capturedJson}
})
$result=[pscustomobject]@{Result='PASS';Assertions=$script:checks;AzureRequests=0;SourceCommon=$SourceCommon;SourceHash=(Get-FileHash $SourceCommon -Algorithm SHA256).Hash;Cases=$results}
if ($ResultPath) { $result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ResultPath -Encoding UTF8 }
if ($PassThru) {$result} else {$result | ConvertTo-Json -Depth 30}
