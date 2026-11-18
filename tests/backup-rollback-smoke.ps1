#Requires -Version 5.1
param(
    [string]$Repository = (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration'),
    [string]$ReportPath,
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
. (Join-Path $Repository 'common.ps1')
$armTokens=$null;$armErrors=$null
$commonAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'common.ps1'),[ref]$armTokens,[ref]$armErrors)
$armNode=@($commonAst.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Invoke-ArmRequest'},$true))[0]
$script:productionArm=[scriptblock]::Create($armNode.Body.Extent.Text.Substring(1,$armNode.Body.Extent.Text.Length-2))
$script:checks = 0
$script:cases = [System.Collections.Generic.List[object]]::new()
$script:scratch = Join-Path ([IO.Path]::GetTempPath()) ('migration-rollback-'+[guid]::NewGuid().ToString('N'))
$null = New-Item -ItemType Directory -Path $script:scratch
$migrationBackupPath = Join-Path $script:scratch 'log_migration_backup.json'
$inputCsvPath = Join-Path $script:scratch 'targets.csv'
$script:subs = @('11111111-1111-1111-1111-111111111111','22222222-2222-2222-2222-222222222222')
$script:oldDcrIds = @('/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/hub/providers/Microsoft.Insights/dataCollectionRules/old-linux','/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/hub/providers/Microsoft.Insights/dataCollectionRules/old-windows')
$script:diagnostics = @{}
$script:resources = @{}
$script:writes = [System.Collections.Generic.List[object]]::new()
$script:reads = [System.Collections.Generic.List[string]]::new()
$script:diagReads = 0
$script:targetReads = 0
$script:failedPut = ''
$script:failedDelete = ''
$script:badReadback = ''
$script:dcrWriteState = 'Succeeded'
$script:transitionDcrId = ''
$script:readyAfterReads = 0
$script:providerReads = [System.Collections.Generic.List[object]]::new()
$script:unsafeNewDelete = $false
$script:selected = $script:subs

function Assert-Rollback([bool]$Condition,[string]$Message) {
    $script:checks++
    if (-not $Condition) { throw "backup/rollback検証失敗: $script:activeCase / $Message" }
}
function Copy-TestValue([object]$Value) { ConvertTo-Json -InputObject $Value -Depth 50 -Compress | ConvertFrom-Json }
function Add-Setting([string]$ResourceId,[string]$Name,[object]$Properties) {
    if (-not $script:diagnostics.ContainsKey($ResourceId)) { $script:diagnostics[$ResourceId] = @{} }
    $setting = Copy-TestValue $Properties
    $setting | Add-Member -NotePropertyName name -NotePropertyValue $Name -Force
    $script:diagnostics[$ResourceId][$Name] = $setting
}
function Write-TestCsv {
    @($script:targets | ForEach-Object { [pscustomobject][ordered]@{
        SubscriptionName=$_.SubscriptionName;ResourceGroup=$_.ResourceGroup;StorageAccount=$_.StorageAccount
        WorkspaceName=$_.WorkspaceName;LogDestination=$_.LogDestination
    } }) | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
}
function New-TestFixture {
    $script:diagnostics = @{}; $script:resources = @{}; $script:targets = @();$script:oldListPartial=$false
    foreach ($index in 0..1) {
        $sub=$script:subs[$index]; $number=$index+1
        $groupId="/subscriptions/$sub/resourceGroups/rg-target"
        $workspaceId="$groupId/providers/Microsoft.OperationalInsights/workspaces/log-new$number"
        $storageId="$groupId/providers/Microsoft.Storage/storageAccounts/stjpetest$number"
        $dcrId="$groupId/providers/Microsoft.Insights/dataCollectionRules/dcr-new$number"
        $vmCount=if ($index -eq 0) {2} else {1}
        $target=@{
            SubscriptionName=$sub;SubscriptionId=$sub;ResourceGroup='rg-target';StorageAccount="stjpetest$number"
            WorkspaceName="log-new$number";LogDestination='Storage';WorkspaceId=$workspaceId
            Storages=@{japaneast=@{Name="stjpetest$number";Id=$storageId;Location='japaneast'}}
            DiagnosticPlans=[System.Collections.Generic.List[object]]::new();Vms=@();Collectors=@();OldAssociations=@();CurrentSettings=@{}
        }
        foreach ($vmNumber in 1..$vmCount) { $target.Vms += @([pscustomobject]@{id="$groupId/providers/Microsoft.Compute/virtualMachines/vm-$vmNumber"}) }
        # 既定fixtureの各machineは指定した旧2本のいずれかへ関連済みです。
        foreach($vmIndex in 0..($target.Vms.Count-1)) {
            $parent=$target.Vms[$vmIndex].id
            $old=@{ResourceId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-$vmIndex";ParentResourceId=$parent;SubscriptionId=$sub
                   Before=@{properties=@{description="旧関連-$number-$vmIndex";dataCollectionRuleId=$oldDcrIds[($index+$vmIndex)%2]}};After=$null}
            $target.OldAssociations+=@($old)
            $script:resources[$old.ResourceId]=Copy-TestValue $old.Before
        }
        $target.Collectors=@($target.OldAssociations.ParentResourceId)
        foreach ($suffix in @('a','b')) {
            $resourceId="/subscriptions/$sub/resourceGroups/source/providers/Microsoft.Test/widgets/$suffix"
            $before=@{
                workspaceId=$targetWorkspaceId;eventHubAuthorizationRuleId='/subscriptions/old/resourceGroups/old/providers/Microsoft.EventHub/namespaces/old/authorizationRules/old'
                eventHubName='old-event-hub';logAnalyticsDestinationType='Dedicated'
                logs=@(@{category='日本語';enabled=$false;retentionPolicy=@{enabled=$true;days=17}})
                metrics=@(@{category='AllMetrics';enabled=$true;timeGrain='PT1M';retentionPolicy=@{enabled=$false;days=0}})
            }
            $after=@{storageAccountId=$storageId;logs=$before.logs;metrics=$before.metrics}
            Add-Setting $resourceId 'old' $before
            Add-Setting $resourceId 'keep-unrelated' @{workspaceId='/other-workspace';logs=@();metrics=@()}
            $target.DiagnosticPlans.Add([pscustomobject]@{
                ResourceId=$resourceId;Region='japaneast';SourceName='old';SourceSettings=@($script:diagnostics[$resourceId].old)
                SourceSignature=(Get-DiagnosticSignature $before);Expected=$after;NewSignature=(Get-DiagnosticSignature $after);NewSettings=@()
            })
            $target.CurrentSettings[$resourceId]=@($script:diagnostics[$resourceId].Values)
        }
        if ($index -eq 0) {
            $script:resources[$dcrId]=Copy-TestValue @{
                id=$dcrId;name="dcr-new$number";location='japaneast';kind='Windows';tags=@{restore='before'}
                identity=@{type='SystemAssigned, UserAssigned';principalId='readonly-principal';tenantId='readonly-tenant';userAssignedIdentities=@{'/subscriptions/old/resourceGroups/old/providers/Microsoft.ManagedIdentity/userAssignedIdentities/old'=@{principalId='readonly-user-principal';clientId='readonly-user-client'}}}
                properties=@{
                    description='before-description';dataCollectionEndpointId='/subscriptions/old/resourceGroups/old/providers/Microsoft.Insights/dataCollectionEndpoints/old'
                    dataSources=@{windowsEventLogs=@(@{name='before';streams=@('Microsoft-Event');xPathQueries=@('Application!*')})}
                    destinations=@{logAnalytics=@(@{name='before';workspaceResourceId=$targetWorkspaceId;workspaceId='readonly-workspace-guid'});monitoringAccounts=@(@{name='monitor';accountResourceId='/subscriptions/old/resourceGroups/old/providers/Microsoft.Monitor/accounts/old';accountId='readonly-monitor-guid'});azureDataExplorer=@(@{name='adx';resourceId='/subscriptions/old/resourceGroups/old/providers/Microsoft.Kusto/clusters/old';databaseName='before-db';ingestionUri='readonly-ingestion-uri'})}
                    dataFlows=@(@{streams=@('Microsoft-Event');destinations=@('before')})
                    streamDeclarations=@{'Custom-Before'= @{columns=@(@{name='TimeGenerated';type='datetime'})}}
                    immutableId='readonly-immutable';provisioningState='Succeeded';endpoints=@{logsIngestion='readonly-endpoint'};metadata=@{provisionedBy='readonly-agent'};ingestionQuotas=@{dailyQuota=1}
                }
            }
            $associationId="$($target.Vms[0].id)/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new$number"
            $script:resources[$associationId]=Copy-TestValue @{id=$associationId;properties=@{
                description='before-association';dataCollectionRuleId="$groupId/providers/Microsoft.Insights/dataCollectionRules/legacy-rule"
                dataCollectionEndpointId='/subscriptions/old/resourceGroups/old/providers/Microsoft.Insights/dataCollectionEndpoints/old'
            }}
            $assignment=$policyAssignments[0]
            $exemptionId="/subscriptions/$sub/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
            $script:resources[$exemptionId]=Copy-TestValue @{properties=@{
                policyAssignmentId=$assignment.Id;exemptionCategory='Waiver';assignmentScopeValidation='Default'
            }}
        }
        # 旧テストの基礎設定mockは使わず、保存済みの実ARM応答で各工程のGETを通します。
        $script:resources[$groupId]=Copy-TestValue @{id=$groupId;location='japaneast';properties=@{provisioningState='Succeeded'}}
        foreach ($shape in @(
            @{Name='storage-account';Id=$storageId},
            @{Name='storage-blob';Id="$storageId/blobServices/default"},
            @{Name='storage-lifecycle';Id="$storageId/managementPolicies/default"},
            @{Name='storage-defender';Id="$storageId/providers/Microsoft.Security/defenderForStorageSettings/current"},
            @{Name='workspace';Id=$workspaceId},
            @{Name='table-Event';Id="$workspaceId/tables/Event"},
            @{Name='table-Syslog';Id="$workspaceId/tables/Syslog"}
        )) {
            $shapePath=Join-Path $PSScriptRoot ('fixtures/baseline-shapes/'+$shape.Name+'.json')
            $resource=Get-Content -LiteralPath $shapePath -Raw -Encoding UTF8 | ConvertFrom-Json
            $resource.id=$shape.Id
            $script:resources[$shape.Id]=$resource
        }
        $script:targets += @($target)
    }
    Write-TestCsv
    $script:beforeResources=Copy-TestValue $script:resources
    $script:originalDiagnostics=@{}
    foreach ($id in $script:diagnostics.Keys) { $script:originalDiagnostics[$id]=Get-DiagnosticSignature $script:diagnostics[$id].old }
}
function Reset-Observation {
    $script:writes.Clear();$script:reads.Clear();$script:diagReads=0;$script:targetReads=0;$script:providerReads.Clear()
    $script:failedPut='';$script:failedDelete='';$script:badReadback='';$script:dcrWriteState='Succeeded';$script:transitionDcrId='';$script:readyAfterReads=0;$script:unsafeNewDelete=$false
    $script:failures.Clear();$script:verificationResults.Clear()
}
# 全外部接続をメモリ内状態へ置き換えます。想定外のCLIは即停止します。
function Start-Sleep {param([int]$Seconds,[int]$Milliseconds)}
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments.Count -eq 6 -and $Arguments[0] -eq 'provider' -and $Arguments[1] -eq 'show' -and
        $Arguments[2] -eq '--subscription' -and $Arguments[3] -in $script:subs -and $Arguments[4] -eq '--namespace' -and
        $Arguments[5] -in @('Microsoft.OperationalInsights','Microsoft.Insights','Microsoft.Storage','Microsoft.Security')) {
        $script:providerReads.Add([pscustomobject]@{SubscriptionId=$Arguments[3];Namespace=$Arguments[5]})
        return [pscustomobject]@{registrationState='Registered'}
    }
    throw "想定外CLI: $($Arguments -join ' ')"
}
function Get-DiagnosticSettings {
    param([string]$ResourceId,[string]$Name)
    $script:diagReads++
    if (-not $script:diagnostics.ContainsKey($ResourceId)) { throw "ARM Get 失敗 (404): diagnostic resource missing" }
    if ($Name) {
        if (-not $script:diagnostics[$ResourceId].ContainsKey($Name)) { throw "ARM Get 失敗 (404): diagnostic setting missing" }
        Copy-TestValue $script:diagnostics[$ResourceId][$Name]
    } else { foreach ($value in $script:diagnostics[$ResourceId].Values) { Copy-TestValue $value } }
}
function Invoke-ArmRequest {
    param([string]$ResourceId,[string]$Method='Get',[object]$Body,[string]$ApiVersion)
    if ($Method -eq 'Get') {
        $script:reads.Add($ResourceId)
        if (-not $script:resources.ContainsKey($ResourceId)) { throw "ARM Get 失敗 (404): offline resource missing / $ResourceId" }
        if ($ResourceId -eq $script:transitionDcrId -and $script:resources[$ResourceId].properties.provisioningState -eq 'Updating' -and $script:readyAfterReads -gt 0) {
            $script:readyAfterReads--
            if ($script:readyAfterReads -eq 0) {$script:resources[$ResourceId].properties.provisioningState='Succeeded'}
        }
        return Copy-TestValue $script:resources[$ResourceId]
    }
    $script:writes.Add([pscustomobject]@{ResourceId=$ResourceId;Method=$Method;Body=(Copy-TestValue $Body)})
    if ($Method -eq 'Put' -and $ResourceId -eq $script:failedPut) { throw 'TEST_PUT_FAILURE' }
    if ($Method -eq 'Delete' -and $ResourceId -eq $script:failedDelete) { throw 'TEST_DELETE_FAILURE' }
    if ($ResourceId -match '^(.*)/providers/Microsoft.Insights/diagnosticSettings/([^/]+)$') {
        $parentId=$Matches[1];$name=[Uri]::UnescapeDataString($Matches[2])
        if ($Method -eq 'Put') {
            if (-not $script:diagnostics[$parentId].ContainsKey($name) -and $script:diagnostics[$parentId].Count -ge 5) { throw 'TEST_DIAGNOSTIC_LIMIT' }
            Add-Setting $parentId $name $Body.properties
            if ($ResourceId -eq $script:badReadback) { $script:diagnostics[$parentId][$name].logs[0].enabled = -not $script:diagnostics[$parentId][$name].logs[0].enabled }
        } elseif ($Method -eq 'Delete') {
            if ($name -eq $newDiagnosticSettingName -and -not (Test-OldStateReady)) { $script:unsafeNewDelete=$true }
            $script:diagnostics[$parentId].Remove($name)
        } else { throw "想定外の診断API: $Method" }
        return
    }
    if ($ResourceId -notmatch '/(dataCollectionRules|dataCollectionRuleAssociations|policyExemptions)/[^/]+$') { throw "対象外resourceへの変更: $Method $ResourceId" }
    if ($Method -eq 'Delete') { $script:resources.Remove($ResourceId);return }
    if ($Method -ne 'Put') { throw "想定外の変更: $Method $ResourceId" }
    $resource=Copy-TestValue $Body
    $resource | Add-Member id $ResourceId -Force
    if ($ResourceId -match '/dataCollectionRules/') { $resource.properties | Add-Member provisioningState $script:dcrWriteState -Force }
    $script:resources[$ResourceId]=$resource
    Copy-TestValue $resource
}
# batch輸送自体は既存343回帰で確認済みです。状態mockでは同じrecordを直列で返します。
function Invoke-DiagnosticBatch {
    param([object[]]$Items,[scriptblock]$Action,[string]$SettingName)
    foreach ($item in $Items) {
        try { $result=& $Action $item $SettingName;[pscustomobject]@{Item=$item;Result=$result;Error=''} }
        catch { [pscustomobject]@{Item=$item;Result=$null;Error=$_.Exception.Message} }
    }
}
function Complete-MigrationStep {
    param([string]$Step,[switch]$IncludeChecks)
    if ($script:failures.Count -gt 0) { throw "TEST_STEP_NG:$Step" }
}
function Get-MigrationTargets {
    $script:targetReads++
    $names=@((Import-Csv -LiteralPath $inputCsvPath).SubscriptionName)
    foreach ($target in $script:targets) {if ($target.SubscriptionName -in $names) {$target}}
}
function Get-MigrationPlan {
    param([object]$Target,[switch]$Fresh)
    $Target.DiagnosticPlans.Clear();$Target.CurrentSettings=@{};$Target.Storages=@{}
    foreach ($id in $script:diagnostics.Keys | Sort-Object) {
        if (-not $id.StartsWith("/subscriptions/$($Target.SubscriptionId)/")) { continue }
        $settings=@($script:diagnostics[$id].Values);$Target.CurrentSettings[$id]=$settings
        $sources=@($settings | Where-Object {$_.workspaceId -eq $targetWorkspaceId})
        if ($sources.Count -eq 0) { continue }
        $source=$sources[0]
        $storageId="/subscriptions/$($Target.SubscriptionId)/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$($Target.StorageAccount)"
        $expected=@{storageAccountId=$storageId;logs=$source.logs;metrics=$source.metrics}
        $Target.Storages.japaneast=@{Name=$Target.StorageAccount;Id=$storageId;Location='japaneast'}
        $Target.DiagnosticPlans.Add([pscustomobject]@{
            ResourceId=$id;Region='japaneast';SourceName=$source.name;SourceSettings=@($source)
            SourceSignature=(Get-DiagnosticSignature $source);Expected=$expected;NewSignature=(Get-DiagnosticSignature $expected)
            NewSettings=@($settings | Where-Object {$_.name -eq $newDiagnosticSettingName})
        })
    }
    # ListByRuleの取得結果と同じく、現在も旧2本へ向く関連だけを返します。
    $Target.OldAssociations=@(foreach($id in @($script:resources.Keys | Sort-Object)) {
        if($id.StartsWith("/subscriptions/$($Target.SubscriptionId)/") -and $id -match '^(.*)/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$' -and
           $script:resources[$id].properties.dataCollectionRuleId -in $oldDcrIds) {
            $before=if($script:oldListPartial){@{properties=@{dataCollectionRuleId=$script:resources[$id].properties.dataCollectionRuleId}}}else{Get-RollbackBody $script:resources[$id] -Association}
            [pscustomobject]@{SubscriptionId=$Target.SubscriptionId;ResourceId=$id;ParentResourceId=$Matches[1];Before=$before;After=$null}
        }
    })
    $Target.Collectors=@($Target.OldAssociations.ParentResourceId | Where-Object {$_} | Sort-Object -Unique)
    $true
}
function Invoke-Entry {
    param([string]$Step,[string[]]$SelectedSubscriptions,[bool]$ExpectFailure=$false)
    $BackupPath=$migrationBackupPath;$SubscriptionIds=$SelectedSubscriptions
    $script:selected=if ($SelectedSubscriptions.Count -gt 0) {$SelectedSubscriptions} else {$script:subs}
    $tokens=$null;$errors=$null
    $entry=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository (@{ precheck='step1_precheck.ps1'; copy='step2_copy.ps1'; verify='step3_verify.ps1'; delete='step4_delete.ps1'; rollback='rollback.ps1' }[$Step])),[ref]$tokens,[ref]$errors)
    if ($errors.Count) { throw "構文エラー: $Step" }
    $body=@($entry.EndBlock.Statements | Where-Object {$_.Extent.Text -notmatch '^\.\s+\(Join-Path.*common\.ps1'} | ForEach-Object {$_.Extent.Text}) -join "`n"
    $parameterText=if ($entry.ParamBlock) {$entry.ParamBlock.Extent.Text} else {''}
    $runner=[scriptblock]::Create($parameterText+"`n"+$body)
    $arguments=@{}
    if ($Step -eq 'rollback') {
        $arguments.BackupPath=$migrationBackupPath
        if ($PSBoundParameters.ContainsKey('SelectedSubscriptions')) {$arguments.SubscriptionIds=$SelectedSubscriptions}
    }
    $failed=$false;$reason=''
    try { & $runner @arguments } catch { $failed=$true;$reason=$_.Exception.Message }
    Assert-Rollback ($failed -eq $ExpectFailure) "$Step の成否 / $reason / $($script:failures.Reason -join ' | ')"
}
function Write-BackupValue([object]$Value) { ConvertTo-Json -InputObject $Value -Depth 50 | Set-Content -LiteralPath $migrationBackupPath -Encoding UTF8 }
function Invoke-TestCase([string]$Name,[scriptblock]$Action) {
    $script:activeCase=$Name
    New-TestFixture
    if (Test-Path -LiteralPath $migrationBackupPath) { Remove-Item -LiteralPath $migrationBackupPath -Force }
    Reset-Observation
    $before=$script:checks
    & $Action
    $script:cases.Add([pscustomobject]@{Case=$Name;Result='PASS';Assertions=$script:checks-$before;Writes=$script:writes.Count})
}

# 単発の保存処理はprecheckに置かれているため、実際の保存try本文をそのまま再利用します。
$preTokens=$null;$preErrors=$null
$preAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'step1_precheck.ps1'),[ref]$preTokens,[ref]$preErrors)
$saveTry=@($preAst.FindAll({param($node) $node -is [Management.Automation.Language.TryStatementAst] -and $node.Body.Extent.Text -match 'FileMode\]::CreateNew'},$true))
if ($saveTry.Count -ne 1) {throw 'precheckのバックアップ保存本文を一意に取得できません。'}
$script:saveBackupCode=$saveTry[0].Body.Extent.Text.Substring(1,$saveTry[0].Body.Extent.Text.Length-2)
function Save-MigrationBackup {
    param([object[]]$Targets)
    Invoke-Expression $script:saveBackupCode
}
function Save-TestBackup {
    $null=Save-MigrationBackup -Targets $script:targets
    $script:savedBackup=Get-Content -LiteralPath $migrationBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
}
function Seed-AfterMigration([switch]$KeepOld) {
    foreach ($target in $script:savedBackup.Targets) {
        foreach ($diagnostic in $target.Diagnostics) {
            if (-not $KeepOld) { $script:diagnostics[$diagnostic.ResourceId].Remove($diagnostic.OldName) }
            Add-Setting $diagnostic.ResourceId $newDiagnosticSettingName $diagnostic.After
        }
        if ($target.Dcr) {
            $body=Copy-TestValue $target.Dcr.After
            $body | Add-Member id $target.Dcr.ResourceId -Force
            $body.properties | Add-Member provisioningState 'Succeeded' -Force
            $script:resources[$target.Dcr.ResourceId]=$body
        }
        foreach ($association in $target.Associations) {
            $body=Copy-TestValue $association.After
            $body | Add-Member id $association.ResourceId -Force
            $script:resources[$association.ResourceId]=$body
        }
        foreach($oldAssociation in $target.OldAssociations) {
            $script:resources[$oldAssociation.ResourceId]=Copy-TestValue $oldAssociation.Before
        }
        foreach ($exemption in $target.Exemptions) {
            $assignment=@($policyAssignments | Where-Object {$exemption.ResourceId -like "*-$($_.Name)"})[0]
            $properties=@{policyAssignmentId=$assignment.Id;exemptionCategory='Waiver';assignmentScopeValidation='Default'}
            if ($assignment.ReferenceIds.Count -gt 0) {$properties.policyDefinitionReferenceIds=$assignment.ReferenceIds}
            $script:resources[$exemption.ResourceId]=Copy-TestValue @{properties=$properties}
        }
    }
}
function Test-OldStateReady {
    foreach ($target in @($script:savedBackup.Targets | Where-Object {$_.SubscriptionId -in $script:selected})) {
        foreach ($diagnostic in $target.Diagnostics) {
            $old=$script:diagnostics[$diagnostic.ResourceId][$diagnostic.OldName]
            if (-not $old -or (Get-DiagnosticSignature $old) -cne (Get-DiagnosticSignature $diagnostic.Before)) {return $false}
        }
        foreach($saved in $target.OldAssociations) {
            $current=Get-RollbackBody -Resource $script:resources[$saved.ResourceId] -Association
            if(-not ((Test-BaselineValues $current $saved.Before) -and (Test-BaselineValues $saved.Before $current))) {return $false}
        }
        foreach ($saved in @($target.Dcr | Where-Object {$null -ne $_ -and $null -ne $_.Before})+@($target.Associations)) {
            $association=$saved.ResourceId -match '/dataCollectionRuleAssociations/'
            $current=Get-RollbackBody -Resource $script:resources[$saved.ResourceId] -Association:$association
            if (-not (Test-BaselineValues $current $saved.Before) -or -not (Test-BaselineValues $saved.Before $current)) {return $false}
        }
    }
    $true
}
function Assert-NewSettingsRetained {
    foreach ($target in $script:savedBackup.Targets) { foreach ($diagnostic in $target.Diagnostics) {
        Assert-Rollback ($script:diagnostics[$diagnostic.ResourceId].ContainsKey($newDiagnosticSettingName)) '失敗時に新設定を保持'
    } }
}
function Assert-NoAzureWrites { Assert-Rollback ($script:writes.Count -eq 0) '事前失敗時にAzure書込み0' }
function Assert-LocalBackupRejected([object]$Value) {
    Write-BackupValue $Value
    $failed=$false
    try {$null=Read-MigrationBackup -Path $migrationBackupPath -CheckCsv} catch {$failed=$true}
    Assert-Rollback $failed '不正バックアップを拒否'
    Assert-NoAzureWrites
    Assert-Rollback ($script:reads.Count -eq 0 -and $script:diagReads -eq 0) '不正バックアップ判定は外部照会0'
}
try {
    Invoke-TestCase '既存GET結果から最小バックアップを作成' {
        Save-TestBackup
        Assert-Rollback ($script:diagReads -eq 0) '診断設定を再取得しない'
        Assert-Rollback ($script:reads.Count -eq 14) '追加GETはWaiver6+DCR2+新関連3+選択旧関連3だけ'
        Assert-NoAzureWrites
        $backup=Read-MigrationBackup -CheckCsv
        Assert-Rollback ($backup.Version -eq 2 -and @($backup.Targets).Count -eq 2) '版とSub数'
        Assert-Rollback (@($backup.Targets.Diagnostics).Count -eq 4) '全旧診断設定を保存'
        $before=$backup.Targets[0].Dcr.Before
        Assert-Rollback ($before.kind -eq 'Windows' -and $before.tags.restore -eq 'before') '既存DCRのkind/tags'
        Assert-Rollback ($before.properties.description -eq 'before-description' -and $before.properties.streamDeclarations.'Custom-Before') 'DCRの未指定writableを保存'
        Assert-Rollback ($before.properties.PSObject.Properties.Name -notcontains 'immutableId' -and $before.properties.PSObject.Properties.Name -notcontains 'provisioningState' -and $before.properties.PSObject.Properties.Name -notcontains 'endpoints') 'DCRのreadonly項目を除く'
        Assert-Rollback ($before.identity.type -match 'SystemAssigned' -and $before.identity.PSObject.Properties.Name -notcontains 'principalId' -and $before.identity.PSObject.Properties.Name -notcontains 'tenantId') 'identityはwritableのみ'
        Assert-Rollback ($before.properties.PSObject.Properties.Name -notcontains 'metadata' -and $before.properties.PSObject.Properties.Name -notcontains 'ingestionQuotas') 'DCR readonly metadata/quota除去'
        Assert-Rollback ($before.properties.destinations.logAnalytics[0].PSObject.Properties.Name -notcontains 'workspaceId' -and $before.properties.destinations.monitoringAccounts[0].PSObject.Properties.Name -notcontains 'accountId' -and $before.properties.destinations.azureDataExplorer[0].PSObject.Properties.Name -notcontains 'ingestionUri') '宛先のreadonly応答項目を除去'
        Assert-Rollback (@(@($before.identity.userAssignedIdentities.PSObject.Properties)[0].Value.PSObject.Properties).Count -eq 0) 'UserAssigned identityは参照だけ保存'
        Assert-Rollback ($backup.Targets[0].Associations[0].Before.properties.description -eq 'before-association') '既存関連付けのdescription保存'
        Assert-Rollback ($backup.Targets[0].Diagnostics[0].Before.eventHubName -eq 'old-event-hub') '旧診断の他宛先も保存'
        Assert-Rollback (@($backup.Targets.Exemptions | Where-Object Existed).Count -eq 1) '既存除外の有無だけ保存'
    }
    Invoke-TestCase 'HashtableとPSCustomObjectの旧関連を保存して同じ内容で読める' {
        foreach($sourceType in @('Hashtable','PSCustomObject')) {
            if($sourceType -eq 'PSCustomObject') {
                foreach($target in $script:targets) {$target.OldAssociations=@($target.OldAssociations | ForEach-Object {Copy-TestValue $_})}
            }
            if(Test-Path -LiteralPath $migrationBackupPath) {Remove-Item -LiteralPath $migrationBackupPath}
            Save-TestBackup
            $backup=Read-MigrationBackup -CheckCsv
            Assert-Rollback (@($backup.Targets.OldAssociations).Count -eq 3) "$sourceType の旧関連3件を保持"
            foreach($target in $script:targets) {
                $saved=@($backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
                foreach($old in $target.OldAssociations) {
                    $record=@($saved.OldAssociations | Where-Object ResourceId -eq $old.ResourceId)
                    Assert-Rollback ($record.Count -eq 1 -and $record[0].ResourceId -eq $old.ResourceId) "$sourceType の完全な関連IDを保持"
                    Assert-Rollback ((Test-BaselineValues $record[0].Before $old.Before) -and (Test-BaselineValues $old.Before $record[0].Before)) "$sourceType のBeforeを保持"
                }
            }
        }
    }
    Invoke-TestCase 'PSCustomObject前値を実ARM serializerへ渡せる' {
        & {
            function Get-ArmToken {[pscustomobject]@{accessToken='OFFLINE_NOT_A_TOKEN'}}
            function Invoke-RestMethod {
                param($Uri,$Method,$TimeoutSec,$Headers,$ContentType,$Body)
                $script:serializedBefore=[Text.Encoding]::UTF8.GetString($Body) | ConvertFrom-Json
                [pscustomobject]@{ok=$true}
            }
            $body=Copy-TestValue @{location='japaneast';kind='Windows';tags=@{restore='before'};properties=@{description='元の設定'}}
            $null=& $script:productionArm -ResourceId '/subscriptions/offline/resources/offline' -Method Put -Body $body
        }
        Assert-Rollback ($script:serializedBefore.kind -eq 'Windows' -and $script:serializedBefore.tags.restore -eq 'before') 'PSCustom前値の全writableをserialize'
        Assert-Rollback ($script:serializedBefore.properties.description -eq '元の設定') '日本語propertiesを保持'
        Assert-NoAzureWrites
    }
    Invoke-TestCase 'DCR自体が診断対象でもsnapshotとの併用を許可' {
        $target=$script:targets[0]
        $id="/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/dcr-new1"
        $model=$target.DiagnosticPlans[0]
        Add-Setting $id 'old' $model.SourceSettings[0]
        Add-Setting $id 'keep-unrelated' @{workspaceId='/other-workspace';logs=@();metrics=@()}
        $target.DiagnosticPlans.Add([pscustomobject]@{ResourceId=$id;Region='japaneast';SourceName='old';SourceSettings=@($script:diagnostics[$id].old);SourceSignature=(Get-DiagnosticSignature $script:diagnostics[$id].old);Expected=$model.Expected;NewSignature=$model.NewSignature;NewSettings=@()})
        Save-TestBackup
        $backup=Read-MigrationBackup -CheckCsv
        Assert-Rollback (@($backup.Targets[0].Diagnostics | Where-Object ResourceId -eq $id).Count -eq 1) '同じDCRが診断対象として1件'
        Assert-Rollback ($backup.Targets[0].Dcr.ResourceId -eq $id) '同じDCRの前値snapshotも保存'
        Seed-AfterMigration
        Reset-Observation
        Invoke-Entry rollback
        Assert-Rollback (Test-OldStateReady) 'DCR診断とDCR本体の両方を復元'
        Assert-Rollback (-not $script:unsafeNewDelete) '両復元後だけ新診断を削除'
    }
    Invoke-TestCase 'バックアップ既存時は上書きせずprecheck前に停止' {
        Save-TestBackup
        $before=[IO.File]::ReadAllBytes($migrationBackupPath)
        Reset-Observation
        Invoke-Entry precheck -ExpectFailure $true
        Assert-Rollback ($script:targetReads -eq 0 -and $script:reads.Count -eq 0 -and $script:diagReads -eq 0) '既存ファイルはAzure照会より前に停止'
        Assert-Rollback ([Convert]::ToBase64String($before) -eq [Convert]::ToBase64String([IO.File]::ReadAllBytes($migrationBackupPath))) '既存ファイルのbyte不変'
        Assert-NoAzureWrites
    }
    Invoke-TestCase 'CreateNewの直接衝突でも既存byteを上書きしない' {
        Save-TestBackup
        $before=[Convert]::ToBase64String([IO.File]::ReadAllBytes($migrationBackupPath))
        Reset-Observation
        $failed=$false
        try {$null=Save-MigrationBackup -Targets $script:targets} catch {$failed=$true}
        Assert-Rollback $failed '保存try単体のCreateNewが既存fileを拒否'
        Assert-Rollback ([Convert]::ToBase64String([IO.File]::ReadAllBytes($migrationBackupPath)) -eq $before) 'CreateNew衝突後もbyte不変'
        Assert-NoAzureWrites
    }
    Invoke-TestCase 'VM・診断対象0のbackupは空配列を維持' {
        foreach ($target in $script:targets) {$target.Vms=@();$target.Collectors=@();$target.OldAssociations=@();$target.DiagnosticPlans.Clear();$target.Storages=@{};$target.CurrentSettings=@{}}
        foreach($id in @($script:resources.Keys | Where-Object {$script:resources[$_].properties.dataCollectionRuleId -in $oldDcrIds})) {$script:resources.Remove($id)}
        $script:diagnostics=@{}
        Save-TestBackup
        Assert-Rollback ($script:reads.Count -eq 6 -and $script:diagReads -eq 0) 'VM無しの追加GETはWaiverだけ'
        $backup=Read-MigrationBackup -CheckCsv
        Assert-Rollback (@($backup.Targets | Where-Object {@($_.Diagnostics).Count -ne 0 -or @($_.Associations).Count -ne 0}).Count -eq 0) '診断・関連付けの空配列を保存'
        Assert-Rollback ($null -eq $backup.Targets[0].Dcr -and $null -eq $backup.Targets[1].Dcr) 'DCR snapshotはnull'
        Reset-Observation
        Invoke-Entry rollback
        Assert-NoAzureWrites
    }
    foreach ($step in @('copy','delete','verify')) {
        Invoke-TestCase "backup無しの$step は変更前に停止" {
            Invoke-Entry $step -ExpectFailure $true
            Assert-NoAzureWrites
            Assert-Rollback ($script:targetReads -eq 0) 'backup無しはAzure対象調査前に停止'
        }
    }
    foreach ($invalid in @('Version','Environment','TargetWorkspaceId','NewDiagnosticSettingName','DuplicateTarget','DuplicateDiagnostic','WrongSubResource','EmptyAfter')) {
        Invoke-TestCase "backup不正$invalid はlocalで拒否" {
            Save-TestBackup
            $value=Copy-TestValue $script:savedBackup
            switch ($invalid) {
                'Version' {$value.Version=99}
                'Environment' {$value.Environment='prod'}
                'TargetWorkspaceId' {$value.TargetWorkspaceId='/wrong'}
                'NewDiagnosticSettingName' {$value.NewDiagnosticSettingName='foreign'}
                'DuplicateTarget' {$value.Targets += @($value.Targets[0])}
                'DuplicateDiagnostic' {$value.Targets[0].Diagnostics += @($value.Targets[0].Diagnostics[0])}
                'WrongSubResource' {$value.Targets[0].Diagnostics[0].ResourceId=$value.Targets[1].Diagnostics[0].ResourceId}
                'EmptyAfter' {$value.Targets[0].Diagnostics[0].After=$null}
            }
            Reset-Observation
            Assert-LocalBackupRejected $value
        }
    }
    Invoke-TestCase '壊れたJSONとCSV宛先差分を拒否' {
        Set-Content -LiteralPath $migrationBackupPath -Value '{broken' -Encoding UTF8
        $failed=$false;try {$null=Read-MigrationBackup -CheckCsv} catch {$failed=$true}
        Assert-Rollback $failed '壊れたJSONを拒否'
        Remove-Item -LiteralPath $migrationBackupPath
        Save-TestBackup
        $rows=@(Import-Csv $inputCsvPath);$rows[1].StorageAccount='foreignstorage';$rows | Export-Csv $inputCsvPath -NoTypeInformation -Encoding UTF8
        Reset-Observation
        Invoke-Entry copy -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Rollback ($script:targetReads -eq 0) 'CSV差分はAzure照会前に拒否'
    }
    Invoke-TestCase 'CSVの正しいSub部分集合を許可し未知Subは拒否' {
        Save-TestBackup;Seed-AfterMigration
        $rows=@(Import-Csv $inputCsvPath)
        @($rows[0]) | Export-Csv $inputCsvPath -NoTypeInformation -Encoding UTF8
        Reset-Observation
        Invoke-Entry verify
        Assert-NoAzureWrites
        Assert-Rollback ($script:reads.Count -gt 0 -and @($script:reads | Where-Object { $_ -notlike "/subscriptions/$($script:subs[0])/*" }).Count -eq 0 -and $script:providerReads.Count -eq 4 -and @($script:providerReads | Where-Object SubscriptionId -ne $script:subs[0]).Count -eq 0) 'CSV部分集合だけverify'
        $rows[0].SubscriptionName='33333333-3333-3333-3333-333333333333'
        @($rows[0]) | Export-Csv $inputCsvPath -NoTypeInformation -Encoding UTF8
        Reset-Observation
        Invoke-Entry copy -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Rollback ($script:targetReads -eq 0) '未知CSV Subは照会前に拒否'
    }
    Invoke-TestCase '未実施状態のrollbackは全てskip' {
        Save-TestBackup
        Reset-Observation
        Invoke-Entry rollback
        Assert-NoAzureWrites
        Assert-Rollback (Test-OldStateReady) '前値がそのまま存在'
    }
    Invoke-TestCase '全削除後のrollbackは旧全復元後だけ新を削除' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        Invoke-Entry rollback
        Assert-Rollback (Test-OldStateReady) '旧診断・旧DCR・旧関連付けを全復元'
        Assert-Rollback (-not $script:unsafeNewDelete) '復元barrier以前の新設定DELETE0'
        foreach ($target in $script:savedBackup.Targets) {
            foreach ($diagnostic in $target.Diagnostics) {
                Assert-Rollback (-not $script:diagnostics[$diagnostic.ResourceId].ContainsKey($newDiagnosticSettingName)) '新診断設定を削除'
                Assert-Rollback ($script:diagnostics[$diagnostic.ResourceId].ContainsKey('keep-unrelated')) '指定外診断を保持'
            }
            foreach ($exemption in $target.Exemptions) {Assert-Rollback ($script:resources.ContainsKey($exemption.ResourceId) -eq [bool]$exemption.Existed) '既存Waiver維持/新規Waiverだけ削除'}
        }
        Assert-Rollback ($script:resources.ContainsKey($script:savedBackup.Targets[1].Dcr.ResourceId)) '新DCRは削除しない'
        Assert-Rollback (@($script:writes | Where-Object {$_.ResourceId -match '/(storageAccounts|workspaces|tables|resourceGroups|providers)/[^/]+$'}).Count -eq 0) 'Storage/LA/テーブル/RP/RGを変更しない'
        Reset-Observation
        Invoke-Entry rollback
        Assert-NoAzureWrites
    }
    Invoke-TestCase '複製途中のrollbackは存在する新設定だけ除去' {
        Save-TestBackup;Seed-AfterMigration -KeepOld
        $id=$script:savedBackup.Targets[1].Diagnostics[1].ResourceId
        $script:diagnostics[$id].Remove($newDiagnosticSettingName)
        Reset-Observation
        Invoke-Entry rollback
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Put' -and $_.ResourceId -match '/diagnosticSettings/old$'}).Count -eq 0) '既存旧診断を再作成しない'
        Assert-Rollback (-not $script:unsafeNewDelete) '旧全確認後だけ新を除去'
    }
    Invoke-TestCase 'サブスクリプション部分選択で他Subを保持' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        Invoke-Entry rollback -SelectedSubscriptions @($script:subs[0])
        Assert-Rollback (@($script:writes | Where-Object {$_.ResourceId -notlike "/subscriptions/$($script:subs[0])/*"}).Count -eq 0) '選択外Subへの書込0'
        foreach ($diagnostic in $script:savedBackup.Targets[1].Diagnostics) {Assert-Rollback ($script:diagnostics[$diagnostic.ResourceId].ContainsKey($newDiagnosticSettingName) -and -not $script:diagnostics[$diagnostic.ResourceId].ContainsKey('old')) '選択外Subの診断不変'}
    }
    Invoke-TestCase '存在しないSub指定は変更0' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        Invoke-Entry rollback -SelectedSubscriptions @('33333333-3333-3333-3333-333333333333') -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Rollback ($script:reads.Count -eq 0 -and $script:diagReads -eq 0) '誤SubはAzure照会前に拒否'
    }
    foreach ($emptyIds in @(@{Name='empty-array';Value=@()},@{Name='null';Value=$null},@{Name='empty-string';Value=@('')},@{Name='whitespace';Value=@(' ')})) {
        Invoke-TestCase "明示$($emptyIds.Name)のSub指定は全体へ広げない" {
            Save-TestBackup;Seed-AfterMigration
            Reset-Observation
            Invoke-Entry rollback -SelectedSubscriptions $emptyIds.Value -ExpectFailure $true
            Assert-NoAzureWrites
            Assert-Rollback ($script:reads.Count -eq 0 -and $script:diagReads -eq 0) '空指定はAzure照会前に拒否'
        }
    }
    foreach ($collision in @('Old','New','Dcr','Association')) {
        Invoke-TestCase "後続Sub/設定の$collision 不一致は全復元前に停止" {
            Save-TestBackup;Seed-AfterMigration
            $diagnostic=$script:savedBackup.Targets[1].Diagnostics[0]
            switch ($collision) {
                'Old' {$body=Copy-TestValue $diagnostic.Before;$body.logs[0].enabled=$true;Add-Setting $diagnostic.ResourceId $diagnostic.OldName $body}
                'New' {$script:diagnostics[$diagnostic.ResourceId][$newDiagnosticSettingName].logs[0].enabled=$true}
                'Dcr' {$script:resources[$script:savedBackup.Targets[0].Dcr.ResourceId].properties.dataFlows[0].destinations=@('foreign')}
                'Association' {$script:resources[$script:savedBackup.Targets[1].Associations[0].ResourceId].properties.dataCollectionRuleId='/foreign'}
            }
            Reset-Observation
            Invoke-Entry rollback -ExpectFailure $true
            Assert-NoAzureWrites
            Assert-NewSettingsRetained
        }
    }
    Invoke-TestCase '旧復元用の空きが無ければ新を消さず停止' {
        Save-TestBackup;Seed-AfterMigration
        $diagnostic=$script:savedBackup.Targets[1].Diagnostics[0]
        foreach ($number in 1..3) {Add-Setting $diagnostic.ResourceId "extra-$number" @{workspaceId="/extra-$number";logs=@();metrics=@()}}
        Reset-Observation
        Invoke-Entry rollback -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-NewSettingsRetained
    }
    foreach ($failure in @('OldPut','Readback','DcrPut','AssociationPut')) {
        Invoke-TestCase "復元$failure 失敗時は新診断DELETE0" {
            Save-TestBackup;Seed-AfterMigration
            Reset-Observation
            switch ($failure) {
                'OldPut' {$script:failedPut="$($script:savedBackup.Targets[1].Diagnostics[0].ResourceId)/providers/Microsoft.Insights/diagnosticSettings/old"}
                'Readback' {$script:badReadback="$($script:savedBackup.Targets[1].Diagnostics[0].ResourceId)/providers/Microsoft.Insights/diagnosticSettings/old"}
                'DcrPut' {$script:failedPut=$script:savedBackup.Targets[0].Dcr.ResourceId}
                'AssociationPut' {$script:failedPut=$script:savedBackup.Targets[0].Associations[0].ResourceId}
            }
            Invoke-Entry rollback -ExpectFailure $true
            Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 0) '復元失敗時は全新診断DELETE0'
            Assert-NewSettingsRetained
        }
    }
    Invoke-TestCase 'DCR復元がUpdatingなら新診断を削除しない' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        $script:dcrWriteState='Updating'
        Invoke-Entry rollback -ExpectFailure $true
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 0) '旧DCR未完了なら新診断DELETE0'
        Assert-NewSettingsRetained
        $existingDcrId=$script:savedBackup.Targets[0].Dcr.ResourceId
        $script:resources[$existingDcrId].properties.provisioningState='Succeeded'
        Reset-Observation
        Invoke-Entry rollback
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Put' -and $_.ResourceId -eq $existingDcrId}).Count -eq 0) 'Succeeded後は復元済DCRを再PUTしない'
        Assert-Rollback (-not $script:unsafeNewDelete) 'Succeededと旧全設定を確認して新削除'
    }
    Invoke-TestCase '自分のDCR PUTがUpdatingからSucceededなら待って完了' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        $script:dcrWriteState='Updating'
        $script:transitionDcrId=$script:savedBackup.Targets[0].Dcr.ResourceId
        $script:readyAfterReads=3
        Invoke-Entry rollback
        Assert-Rollback ($script:readyAfterReads -eq 0 -and $script:resources[$script:transitionDcrId].properties.provisioningState -eq 'Succeeded') '自分のPUTの完了までGETで確認'
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 4) 'Succeededと全旧設定確認後に新全件削除'
        Assert-Rollback (-not $script:unsafeNewDelete) '完了前の新DELETE0'
    }
    Invoke-TestCase 'DCRAにUpdatingが返る場合も新診断を削除しない' {
        Save-TestBackup;Seed-AfterMigration
        $id=$script:savedBackup.Targets[0].Associations[0].ResourceId
        $script:resources[$id].properties | Add-Member provisioningState 'Updating' -Force
        Reset-Observation
        Invoke-Entry rollback -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-NewSettingsRetained
    }
    Invoke-TestCase '新削除途中の失敗は後続停止し再実行できる' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        $script:failedDelete="$($script:savedBackup.Targets[0].Diagnostics[1].ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$newDiagnosticSettingName"
        Invoke-Entry rollback -ExpectFailure $true
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 2) '2件目失敗後は後続削除0'
        Assert-Rollback ($script:diagnostics[$script:savedBackup.Targets[1].Diagnostics[0].ResourceId].ContainsKey($newDiagnosticSettingName)) '後続Subの新設定を保持'
        Reset-Observation
        Invoke-Entry rollback
        Assert-Rollback (Test-OldStateReady) '再実行後も旧全件が一致'
        Assert-Rollback (@($script:writes | Where-Object {$_.Method -eq 'Put'}).Count -eq 0) '再実行で復元済のPUT0'
    }
    Invoke-TestCase '旧削除済scopeの新欠損もverify/delete全体を停止' {
        Save-TestBackup;Seed-AfterMigration
        $first=$script:savedBackup.Targets[0].Diagnostics[0]
        $script:diagnostics[$first.ResourceId].Remove($newDiagnosticSettingName)
        $remaining=$script:savedBackup.Targets[1].Diagnostics[0]
        Add-Setting $remaining.ResourceId $remaining.OldName $remaining.Before
        Reset-Observation
        Invoke-Entry verify -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Rollback (@($script:failures | Where-Object ResourceId -eq $first.ResourceId).Count -ge 1) '旧消済scopeの新欠損を一覧へ'
        Reset-Observation
        Invoke-Entry delete -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Rollback ($script:diagnostics[$remaining.ResourceId].ContainsKey('old')) '他scopeの旧設定も削除しない'
    }
    Invoke-TestCase '旧全消済リージョンのStorage基礎確認を維持' {
        Save-TestBackup;Seed-AfterMigration
        Reset-Observation
        Invoke-Entry verify
        Assert-Rollback (@($script:reads | Where-Object { $_ -match '/storageAccounts/[^/]+$' } | Sort-Object -Unique).Count -eq 2 -and @($script:savedBackup.Targets.Storages | Where-Object { $_.Id -notin $script:reads }).Count -eq 0) 'backup地域のStorageを全てverify'
        Assert-NoAzureWrites
    }
    Invoke-TestCase 'backup後に増えた無関係VMを関連付け対象へ広げない' {
        Save-TestBackup;Seed-AfterMigration -KeepOld
        $unrelatedVm="/subscriptions/$($script:subs[1])/resourceGroups/source/providers/Microsoft.Compute/virtualMachines/new-vm"
        $script:targets[1].Vms += @([pscustomobject]@{id=$unrelatedVm})
        Reset-Observation
        Invoke-Entry copy
        Assert-NoAzureWrites
        Assert-Rollback ($unrelatedVm -notin $script:targets[1].Collectors) '旧DCR関連のないVMを追加しない'
        Assert-Rollback (@($script:reads | Where-Object { $_ -eq $unrelatedVm -or $_.StartsWith($unrelatedVm+'/') }).Count -eq 0) '無関係VMを基礎設定対象に渡さない'
    }
    $result=[pscustomobject]@{Result='PASS';Cases=$script:cases;CaseCount=$script:cases.Count;Checks=$script:checks;AzureRequests=0;CommonHash=(Get-FileHash (Join-Path $Repository 'common.ps1') -Algorithm SHA256).Hash;RollbackHash=(Get-FileHash (Join-Path $Repository 'rollback.ps1') -Algorithm SHA256).Hash}
    if ($ReportPath) {$result | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $ReportPath -Encoding UTF8}
    if ($PassThru) {$result} else {$result | ConvertTo-Json -Depth 30}
}
finally { if (Test-Path -LiteralPath $script:scratch) { Remove-Item -LiteralPath $script:scratch -Recurse -Force } }
