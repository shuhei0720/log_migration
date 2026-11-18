#Requires -Version 5.1
param(
    [string]$Repository = (Join-Path (Split-Path $PSScriptRoot -Parent) 'migration'),
    [string]$CommonPath = '',
    [string]$ShapesDirectory = (Join-Path $PSScriptRoot 'fixtures/baseline-shapes'),
    [string]$ReportPath = (Join-Path $PSScriptRoot 'baseline-smoke-result.json'),
    [switch]$PassThru
)
$ErrorActionPreference = 'Stop'
if (-not $CommonPath) { $CommonPath = Join-Path $Repository 'common.ps1' }
. $CommonPath
$script:assertionCount = 0
$script:caseResults = [System.Collections.Generic.List[object]]::new()
$shapeIndex = Get-Content -LiteralPath (Join-Path $ShapesDirectory 'index.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$script:shapeTexts = @{}
foreach ($entry in $shapeIndex.results) {
    if ($entry.httpStatus -eq 200) {
        $script:shapeTexts[$entry.resourceId] = Get-Content -LiteralPath (Join-Path $ShapesDirectory (Split-Path $entry.file -Leaf)) -Raw -Encoding UTF8
    }
}
$accountShape = Get-Content -LiteralPath (Join-Path $ShapesDirectory 'storage-account.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$workspaceShape = Get-Content -LiteralPath (Join-Path $ShapesDirectory 'workspace.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$dcrShape = Get-Content -LiteralPath (Join-Path $ShapesDirectory 'dcr.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$accountId = $accountShape.id
$workspaceId = $workspaceShape.id
$dcrId = $dcrShape.id
$blobId = "$accountId/blobServices/default"
$policyId = "$accountId/managementPolicies/default"
$groupId = $accountId.Substring(0, $accountId.IndexOf('/providers/'))
$subscriptionId = $accountId.Split('/')[2]
$vmId = "$groupId/providers/Microsoft.Compute/virtualMachines/offline-baseline-only"
$associationId = "$vmId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($dcrShape.name)"
$target = @{
    SubscriptionId = $subscriptionId; SubscriptionName = '実ARM応答のoffline再生'
    ResourceGroup = $groupId.Split('/')[-1]; WorkspaceName = $workspaceShape.name; WorkspaceId = $workspaceId
    Storages = @{ japaneast = @{ Id = $accountId; Name = $accountShape.name; Location = 'japaneast' } }
    Vms = @(@{ id = $vmId }); Collectors = @($vmId)
}

function Assert-Baseline {
    param([bool]$Condition, [string]$Message)
    $script:assertionCount++
    if (-not $Condition) { throw "baseline assertion failed: $Message" }
}
function Copy-TestValue {
    param([object]$Value)
    ConvertTo-Json -InputObject $Value -Depth 40 -Compress | ConvertFrom-Json
}
function Reset-BaselineFixture {
    $target.Collectors=@($vmId)
    $script:fixture = @{}
    foreach ($id in $script:shapeTexts.Keys) { $script:fixture[$id] = $script:shapeTexts[$id] | ConvertFrom-Json }
    foreach($rule in $script:fixture[$policyId].properties.policy.rules) {
        if($rule.name -eq 'log-append-365') {
            $rule.name='log-append-1095'
            $rule.definition.actions.baseBlob.delete.daysAfterModificationGreaterThan=1095
        }
    }
    # 保存済みの実応答ファイルは変えず、今回追加する完成値だけメモリへ設定します。
    foreach ($name in @('Event','Syslog')) {
        $script:fixture["$workspaceId/tables/$name"].properties | Add-Member totalRetentionInDays 1095 -Force
    }
    $script:fixture[$groupId] = Copy-TestValue @{ id = $groupId; location = 'japaneast' }
    $script:fixture[$associationId] = Copy-TestValue @{ properties = @{ dataCollectionRuleId = $dcrId } }
    foreach ($assignment in $policyAssignments) {
        $properties = @{ policyAssignmentId = $assignment.Id; exemptionCategory = 'Waiver'; assignmentScopeValidation = 'Default' }
        if ($assignment.ReferenceIds.Count -gt 0) { $properties.policyDefinitionReferenceIds = $assignment.ReferenceIds }
        $id = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
        $script:fixture[$id] = Copy-TestValue @{ properties = $properties }
    }
    $script:writes = [System.Collections.Generic.List[object]]::new()
    $script:skipMutationId = ''
    $script:transitionAssociationId='';$script:associationReadsToReady=0;$script:finalAssociationRule=''
    $script:tableProvisioningDelay=0;$script:pendingTableReads=@{};$script:tableReadPolls=0;$script:earlyDcrWrite=$false;$script:rejectTableRetentionWrite=$false
    $script:failures.Clear()
    $script:verificationResults.Clear()
}
function Merge-TestProperties {
    param([object]$Current, [object]$Changes)
    foreach ($property in $Changes.PSObject.Properties) {
        if ($property.Value -is [pscustomobject] -and $Current.($property.Name) -is [pscustomobject]) {
            Merge-TestProperties -Current $Current.($property.Name) -Changes $property.Value
        }
        else { $Current | Add-Member -NotePropertyName $property.Name -NotePropertyValue $property.Value -Force }
    }
}
# 状態遷移はGET回数で制御し、他のテストのsleep mockを引き継ぎません。
function Start-Sleep {param([int]$Seconds)}
# 以下の2関数で全外部通信を置き換えます。Azureへ接続する処理はありません。
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments[0] -ne 'provider' -or $Arguments[1] -ne 'show') { throw "許可していないCLI呼出し: $($Arguments -join ' ')" }
    [pscustomobject]@{ registrationState = 'Registered' }
}
function Invoke-ArmRequest {
    param([string]$ResourceId, [string]$Method = 'Get', [hashtable]$Body, [string]$ApiVersion)
    if ($Method -eq 'Get') {
        if (-not $script:fixture.ContainsKey($ResourceId)) { throw "ARM Get 失敗 (404): offline fixture missing / $ResourceId" }
        if($script:pendingTableReads.ContainsKey($ResourceId)) {
            $script:tableReadPolls++
            $script:pendingTableReads[$ResourceId]--
            if($script:pendingTableReads[$ResourceId] -le 0) {
                $script:fixture[$ResourceId].properties.provisioningState='Succeeded'
                $script:pendingTableReads.Remove($ResourceId)
            }
        }
        if($ResourceId -eq $script:transitionAssociationId -and $script:associationReadsToReady -gt 0) {
            $script:associationReadsToReady--
            if($script:associationReadsToReady -eq 0) {
                $script:fixture[$ResourceId].properties.provisioningState='Succeeded'
                $script:fixture[$ResourceId].properties.dataCollectionRuleId=$script:finalAssociationRule
            }
        }
        return $script:fixture[$ResourceId]
    }
    if ($Method -notin @('Put', 'Patch')) { throw "許可していないAPI呼出し: $Method" }
    if($ResourceId -match '/dataCollectionRules/[^/]+$' -and $script:pendingTableReads.Count -gt 0){$script:earlyDcrWrite=$true}
    $script:writes.Add([pscustomobject]@{ ResourceId = $ResourceId; Method = $Method; Body = Copy-TestValue $Body })
    if($script:rejectTableRetentionWrite -and $ResourceId -match '/tables/(Event|Syslog)$' -and
        $null -ne $Body.properties.totalRetentionInDays) {
        throw 'Table retention update rejected.'
    }
    if ($script:skipMutationId -ne $ResourceId) {
        $changes = Copy-TestValue $Body
        if ($ResourceId -match '/dataCollectionRules/[^/]+$') { $changes.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'Succeeded' -Force }
        if($ResourceId -match '/tables/(Event|Syslog)$') {
            if($null -ne $changes.properties.totalRetentionInDays) { $changes.properties | Add-Member totalRetentionInDaysAsDefault $false -Force }
            if($script:tableProvisioningDelay -gt 0) {
                $changes.properties | Add-Member provisioningState 'Updating' -Force
                $script:pendingTableReads[$ResourceId]=$script:tableProvisioningDelay
            } elseif($Method -eq 'Put') {
                $changes.properties | Add-Member provisioningState 'Succeeded' -Force
            }
        }
        if($ResourceId -eq $script:transitionAssociationId) {$changes.properties | Add-Member provisioningState 'Updating' -Force}
        if ($script:fixture.ContainsKey($ResourceId)) { Merge-TestProperties -Current $script:fixture[$ResourceId] -Changes $changes }
        else { $script:fixture[$ResourceId] = $changes }
    }
    $script:fixture[$ResourceId]
}
# 保存先の単体確認では、記録済み①の入力を用意して実際のcopy/verify本体へ通します。
function Invoke-DestinationStage {
    param([object]$Target,[switch]$VerifyOnly)
    # 探索・バックアップ読込み・レポートだけを置換し、実際の保存先処理をHTTP fixtureで確認します。
    $Target.DiagnosticPlans=[Collections.Generic.List[object]]::new()
    $Target.CurrentSettings=@{}
    if(-not $Target.StorageAccount){$Target.StorageAccount=@($Target.Storages.Values)[0].Name}
    if(-not $Target.LogDestination){$Target.LogDestination='Storage'}
    $body=Get-MigrationDcrBody -Target $Target
    $savedAssociations=@(foreach($collectorId in $Target.Collectors){
        $id="$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($dcrShape.name)"
        @{ResourceId=$id;Before=Get-RollbackBody $script:fixture[$id] -Association;After=@{properties=@{dataCollectionRuleId=$dcrId}}}
    })
    $Target.OldAssociations=@(foreach($collectorId in $Target.Collectors){
        $id="$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/offline-old"
        $before=@{properties=@{description='元の関連';dataCollectionRuleId=$oldDcrIds[0]}}
        $script:fixture[$id]=Copy-TestValue $before
        @{ResourceId=$id;ParentResourceId=$collectorId;Before=$before}
    })
    $routing=@{}
    foreach($key in @('SubscriptionName','ResourceGroup','StorageAccount','WorkspaceName','LogDestination')){$routing[$key]=$Target[$key]}
    $exemptions=@(foreach($assignment in $policyAssignments){
        @{ResourceId="/subscriptions/$($Target.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)";Existed=$true}
    })
    $script:destinationTarget=$Target
    $script:destinationBackup=@{
        Version=3;CreatedAtUtc=[DateTime]::UtcNow.ToString('o');Environment=$environment;TargetWorkspaceId=$targetWorkspaceId
        NewDiagnosticSettingName=$newDiagnosticSettingName;OldDcrIds=@($oldDcrIds)
        Targets=@(@{
            SubscriptionName=$Target.SubscriptionName;SubscriptionId=$Target.SubscriptionId;Routing=$routing
            Diagnostics=@();OldAssociations=@($Target.OldAssociations);Storages=@($Target.Storages.Values)
            Associations=$savedAssociations;Dcr=@{ResourceId=$dcrId;Before=$null;After=$body};Exemptions=$exemptions
        })
    }
    function Read-MigrationBackup {param($Path,[switch]$CheckCsv) $script:destinationBackup}
    function Get-MigrationTargets { $script:destinationTarget }
    function Get-MigrationPlan {param($Target) $true}
    function Complete-MigrationStep {
        param($Step,[switch]$IncludeChecks)
        if($script:failures.Count -gt 0){throw 'TEST_DESTINATION_RECORDED_FAILURE'}
    }
    # 本体の原子的JSON保存先も毎回の専用一時ディレクトリへ隔離します。
    $scratch=Join-Path ([IO.Path]::GetTempPath()) ('migration-destination-'+[guid]::NewGuid().ToString('N'))
    $null=New-Item -ItemType Directory -Path $scratch
    $migrationBackupPath=Join-Path $scratch 'before.json'
    ConvertTo-Json -InputObject $script:destinationBackup -Depth 40 | Set-Content -LiteralPath $migrationBackupPath -Encoding UTF8
    $script:storageNames.Clear()
    $entry=if($VerifyOnly){'step2_verify.ps1'}else{'step1_copy.ps1'}
    $entryText=Get-Content -LiteralPath (Join-Path $Repository $entry) -Raw -Encoding UTF8
    $entryBody=($entryText -split "`n" | Select-Object -Skip 2) -join "`n"
    try { Invoke-Expression $entryBody }
    catch {if($_.Exception.Message -ne 'TEST_DESTINATION_RECORDED_FAILURE'){throw}}
    finally {if(Test-Path -LiteralPath $scratch){Remove-Item -LiteralPath $scratch -Recurse -Force}}
    return ($script:failures.Count -eq 0)
}

function Invoke-BaselineCase {
    param([string]$Name, [scriptblock]$Test)
    Reset-BaselineFixture
    $before = $script:assertionCount
    & $Test
    $script:caseResults.Add([pscustomobject]@{ Case = $Name; Result = 'PASS'; Assertions = $script:assertionCount - $before; Writes = $script:writes.Count })
}

Invoke-BaselineCase '実ARM応答の全一致VerifyOnly' {
    $ready = Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline $ready '実応答を一致として扱う'
    Assert-Baseline ($script:writes.Count -eq 0) 'VerifyOnlyは書込0'
    Assert-Baseline ($script:failures.Count -eq 0) '全一致で失敗0'
    Assert-Baseline ($script:verificationResults.Count -ge 17) 'Policy/Storage/LA/VM全項目の確認記録'
    Assert-Baseline ($script:fixture[$dcrId].properties.destinations.logAnalytics[0].workspaceId -ne '') 'DCRの読取専用workspaceGUIDあり'
    Assert-Baseline ($script:fixture[$workspaceId].properties.features.legacy -eq 0) 'LAの既定featureを含む'
    Assert-Baseline ($script:fixture[$policyId].properties.policy.rules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 1095) 'Lifecycleの総保持1095を確認'
}
Invoke-BaselineCase '実ARM応答の全一致Copy再実行' {
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '設定済み再実行が成功'
    Assert-Baseline ($script:writes.Count -eq 0) '全一致で書込0'
    Assert-Baseline ($script:failures.Count -eq 0) '失敗0'
}
Invoke-BaselineCase 'Blob不足の読取専用検知と手動対応情報' {
    $script:fixture[$blobId].properties.isVersioningEnabled = $false
    $ready = Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready) '不足を検知'
    Assert-Baseline ($script:writes.Count -eq 0) '不足時もVerifyOnly書込0'
    Assert-Baseline ($script:failures.Count -eq 1) '不足項目のみ失敗'
    Assert-Baseline ($script:failures[0].ResourceId -eq $blobId) '手動対象ID'
    Assert-Baseline ($script:failures[0].Stage -eq 'Blobバージョン管理') '失敗段階'
    Assert-Baseline (($script:failures[0].ExpectedConfiguration | ConvertFrom-Json).properties.isVersioningEnabled -eq $true) '手動対応の期待値'
}
Invoke-BaselineCase 'Blob不足だけ補完し再実行を省略' {
    $script:fixture[$blobId].properties.isVersioningEnabled = $false
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '不足を補完'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $blobId) '不足Blobだけ1書込'
    $again = Invoke-DestinationStage -Target $target
    Assert-Baseline $again '再実行成功'
    Assert-Baseline ($script:writes.Count -eq 1) '再実行による追加書込0'
}
Invoke-BaselineCase '旧DCR関連のあるVMSSも同じ新DCRの確認・補完対象' {
    $vmssId = "$groupId/providers/Microsoft.Compute/virtualMachineScaleSets/offline-vmss"
    $vmssAssociationId = "$vmssId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($dcrShape.name)"
    $target.Collectors=@($vmId,$vmssId)
    $script:fixture[$vmssAssociationId]=Copy-TestValue @{properties=@{dataCollectionRuleId=$dcrId}}
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline $ready 'rootVMとVMSSの両方を確認'
    Assert-Baseline (@($script:verificationResults | Where-Object {$_.ResourceId -eq $vmssAssociationId -and $_.Result -eq 'OK'}).Count -eq 1) 'VMSSの確認記録'
    Assert-Baseline ($script:writes.Count -eq 0) 'VMSS一致時も書込み0'
    $script:fixture.Remove($vmssAssociationId);$script:failures.Clear();$script:verificationResults.Clear()
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready) 'VMSS新関連の欠損を検出'
    Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $vmssAssociationId).Count -eq 1) '欠損のVMSS完全IDを記録'
    Assert-Baseline ($script:writes.Count -eq 0) '欠損確認も書込み0'
    $script:failures.Clear();$script:verificationResults.Clear()
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '不足するVMSS関連だけを補完'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $vmssAssociationId) 'VMSS関連1件だけPUT'
    $again=Invoke-DestinationStage -Target $target
    Assert-Baseline ($again -and $script:writes.Count -eq 1) '再実行でVMSS関連を再PUTしない'
}
foreach($associationFinish in @('Expected','Foreign')) {
    Invoke-BaselineCase "関連付けPUTのUpdating完了後も参照先を再確認-${associationFinish}" {
        $script:fixture.Remove($associationId)
        $script:transitionAssociationId=$associationId;$script:associationReadsToReady=3
        $script:finalAssociationRule=if($associationFinish -eq 'Expected'){$dcrId}else{'/foreign-rule'}
        $ready=Invoke-DestinationStage -Target $target
        Assert-Baseline ($script:associationReadsToReady -eq 0) "Updatingを読み続け完了を確認 / remaining=$script:associationReadsToReady / $($script:failures.Reason -join '; ')"
        Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $associationId) '関連付け1件の作成だけ'
        if($associationFinish -eq 'Expected') {
            Assert-Baseline ($ready -and $script:failures.Count -eq 0) '完成形一致なら成功'
        } else {
            Assert-Baseline (-not $ready) 'Succeededでも別DCR参照なら未完了'
            Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $associationId).Count -eq 1) '誤参照の完全IDを手動一覧へ'
            Assert-Baseline (($script:failures[0].ExpectedConfiguration | ConvertFrom-Json).properties.dataCollectionRuleId -eq $dcrId) '手動一覧に正しい新DCRを保持'
        }
    }
}
Invoke-BaselineCase 'Storage基礎構成の不一致は上書きしない' {
    $script:fixture[$accountId].location = 'japanwest'
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline (-not $ready) '別リージョンを拒否'
    Assert-Baseline ($script:writes.Count -eq 0) '既存不一致を変更しない'
    Assert-Baseline ($script:fixture[$accountId].location -eq 'japanwest') '元の値を保持'
    Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $accountId).Count -eq 1) '失敗一覧に含む'
}
Invoke-BaselineCase '既存Policy除外の不一致は他の作業を開始しない' {
    $id = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($policyAssignments[0].Name)"
    $script:fixture[$id].properties.exemptionCategory = 'Mitigated'
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline (-not $ready) 'Policy範囲不一致を拒否'
    Assert-Baseline ($script:writes.Count -eq 0) 'Policyも後続も変更しない'
    Assert-Baseline ($script:fixture[$id].properties.exemptionCategory -eq 'Mitigated') '既存Policyを保持'
}
Invoke-BaselineCase 'LA保持期間だけ補完し他featureを保持' {
    $before = Copy-TestValue $script:fixture[$workspaceId].properties.features
    $script:fixture[$workspaceId].properties.retentionInDays = 30
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready 'LA保持期間補完成功'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $workspaceId -and $script:writes[0].Method -eq 'Patch') 'LAだけ1Patch'
    Assert-Baseline ($script:fixture[$workspaceId].properties.retentionInDays -eq 365) '保持期間365'
    Assert-Baseline ($script:fixture[$workspaceId].properties.features.legacy -eq $before.legacy -and $script:fixture[$workspaceId].properties.features.searchVersion -eq $before.searchVersion -and $script:fixture[$workspaceId].properties.features.enableLogAccessUsingOnlyResourcePermissions -eq $before.enableLogAccessUsingOnlyResourcePermissions) '他のfeatureを保持'
}
Invoke-BaselineCase 'Lifecycle自分のルールだけ補完し他ルール保持' {
    $script:fixture[$policyId].properties.policy.rules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan = 30
    $other = Copy-TestValue @{ name = 'keep-other-rule'; enabled = $false; type = 'Lifecycle'; definition = @{ filters = @{ blobTypes = @('blockBlob') } } }
    $script:fixture[$policyId].properties.policy.rules += @($other)
    $before = ConvertTo-Json -InputObject $other -Depth 10 -Compress
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '自分のルール補完成功'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $policyId) 'Lifecycleだけ1書込'
    $kept = @($script:fixture[$policyId].properties.policy.rules | Where-Object name -eq 'keep-other-rule')
    Assert-Baseline ($kept.Count -eq 1) '別名ルールを保持'
    Assert-Baseline ((ConvertTo-Json -InputObject $kept[0] -Depth 10 -Compress) -ceq $before) '別名ルールは内容も不変'
}
Invoke-BaselineCase 'Lifecycle未作成404から有効な1ルールだけ作成' {
    $script:fixture.Remove($policyId)
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '404の未作成ポリシーを補完'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $policyId) 'Lifecycleだけ1書込'
    $sentRules = @($script:writes[0].Body.properties.policy.rules)
    Assert-Baseline ($sentRules.Count -eq 1) '送信ルール数は1'
    Assert-Baseline (@($sentRules | Where-Object { $null -eq $_ }).Count -eq 0) 'nullルールを送信しない'
    Assert-Baseline ($sentRules[0].name -eq 'log-append-1095' -and $sentRules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 1095) '送信ルールの名前と保持日数'
    $again = Invoke-DestinationStage -Target $target
    Assert-Baseline $again '作成後の再実行成功'
    Assert-Baseline ($script:writes.Count -eq 1) '再実行で追加書込0'
}
Invoke-BaselineCase 'DCR不足だけ補完し再実行を省略' {
    $script:fixture.Remove($dcrId)
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready 'DCRだけ補完成功'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $dcrId) 'DCRだけ1書込'
    $again = Invoke-DestinationStage -Target $target
    Assert-Baseline $again 'DCR補完後の再実行成功'
    Assert-Baseline ($script:writes.Count -eq 1) 'DCR再実行の追加書込0'
}
Invoke-BaselineCase '読み戻しが一致しなければ失敗を返す' {
    $script:fixture[$blobId].properties.isVersioningEnabled = $false
    $script:skipMutationId = $blobId
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline (-not $ready) 'readback不一致は失敗'
    Assert-Baseline ($script:writes.Count -eq 1) '書込試行は1回だけ'
    Assert-Baseline ($script:failures.Count -eq 1) '失敗を記録'
    Assert-Baseline ($script:failures[0].Reason -match '読み戻し') '原因が手動対応可能'
}
Invoke-BaselineCase 'LA不足時もVerifyOnlyはVM後続項目を確認' {
    $script:fixture.Remove($workspaceId)
    $ready = Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready) 'LA不足を検知'
    Assert-Baseline ($script:writes.Count -eq 0) '不足時もVerifyOnly書込0'
    Assert-Baseline (@($script:verificationResults | Where-Object Stage -eq 'VMログテーブル').Count -eq 2) '後続テーブル2件を確認'
    Assert-Baseline (@($script:verificationResults | Where-Object Stage -eq 'DCR').Count -eq 1) '後続DCRを確認'
    Assert-Baseline (@($script:verificationResults | Where-Object Stage -eq 'DCR関連付け').Count -eq 1) '後続関連付けを確認'
}
foreach ($stateCase in @(
    @{ Name = 'Storage'; Id = $accountId; State = 'Creating' },
    @{ Name = 'LA'; Id = $workspaceId; State = 'Updating' },
    @{ Name = 'DCR'; Id = $dcrId; State = 'Updating' }
)) {
    foreach ($verifyMode in @($true, $false)) {
        $mode = if ($verifyMode) { 'VerifyOnly' } else { 'Copy' }
        Invoke-BaselineCase "$($stateCase.Name)の$($stateCase.State)は${mode}でも変更しない" {
            $script:fixture[$stateCase.Id].properties.provisioningState = $stateCase.State
            $ready = Invoke-DestinationStage -Target $target -VerifyOnly:$verifyMode
            Assert-Baseline (-not $ready) '作成更新中を成功と扱わない'
            Assert-Baseline ($script:writes.Count -eq 0) '作成更新中に変更を重ねない'
            Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $stateCase.Id).Count -eq 1) '未完了リソースを失敗一覧へ'
        }
    }
}
Invoke-BaselineCase 'Storage未設定の手動CSVへmutable期待値も出す' {
    $script:fixture[$accountId].properties.networkAcls.defaultAction = 'Allow'
    $script:fixture[$accountId].properties.allowSharedKeyAccess = $true
    $ready = Invoke-DestinationStage -Target $target -VerifyOnly
    $failure = @($script:failures | Where-Object ResourceId -eq $accountId)
    Assert-Baseline (-not $ready -and $script:writes.Count -eq 0) '未設定を変更せず検知'
    Assert-Baseline ($failure.Count -eq 1) '対象Storageを1件記録'
    $expected = $failure[0].ExpectedConfiguration | ConvertFrom-Json
    Assert-Baseline ($expected.properties.networkAcls.defaultAction -eq 'Deny') 'networkDenyの期待値'
    Assert-Baseline ($expected.properties.networkAcls.bypass -eq 'AzureServices') 'bypassの期待値'
    Assert-Baseline ($expected.properties.allowSharedKeyAccess -eq $false) 'sharedKeyの期待値'
    Assert-Baseline ($expected.properties.minimumTlsVersion -eq 'TLS1_2') 'TLSの期待値'
    Assert-Baseline ($expected.properties.supportsHttpsTrafficOnly -eq $true) 'HTTPSの期待値'
}
Invoke-BaselineCase 'Storagemutable補完でも個別ネットワーク規則を保持' {
    $script:fixture[$accountId].properties.networkAcls.defaultAction = 'Allow'
    $script:fixture[$accountId].properties.networkAcls.ipRules = @((Copy-TestValue @{ action = 'Allow'; value = '192.0.2.1' }))
    $script:fixture[$accountId].properties.networkAcls.ipv6Rules = @((Copy-TestValue @{ action = 'Allow'; value = '2001:db8::/32' }))
    $ready = Invoke-DestinationStage -Target $target
    Assert-Baseline $ready 'Storagemutableだけ補完成功'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $accountId) 'Storageだけ1Patch'
    Assert-Baseline ($script:fixture[$accountId].properties.networkAcls.ipRules[0].value -eq '192.0.2.1') 'IPv4規則保持'
    Assert-Baseline ($script:fixture[$accountId].properties.networkAcls.ipv6Rules[0].value -eq '2001:db8::/32') 'IPv6規則保持'
    Assert-Baseline ($script:fixture[$accountId].properties.networkAcls.defaultAction -eq 'Deny') 'DefaultDenyを補完'
}

# 総保持だけを1095日にする変更を、分析保持・スキーマ・他テーブルの変更と区別して確認します。
Invoke-BaselineCase 'EventとSyslogの総保持90だけを1095へ補完し他の設定を保持' {
    $workspaceBefore=ConvertTo-Json -InputObject $script:fixture[$workspaceId] -Depth 40 -Compress
    $otherTableId="$workspaceId/tables/Custom_CL"
    $otherTable=Copy-TestValue @{id=$otherTableId;properties=@{retentionInDays=7;totalRetentionInDays=14;plan='Analytics';schema=@{name='Custom_CL'};customSetting='keep'}}
    $script:fixture[$otherTableId]=$otherTable
    $otherBefore=ConvertTo-Json -InputObject $otherTable -Depth 40 -Compress
    $schemaBefore=@{}
    foreach($name in @('Event','Syslog')) {
        $table=$script:fixture["$workspaceId/tables/$name"]
        $table.properties.totalRetentionInDays=90
        $table.properties.retentionInDays=30
        $table.properties | Add-Member customSetting "keep-$name" -Force
        $schemaBefore[$name]=ConvertTo-Json -InputObject $table.properties.schema -Depth 40 -Compress
    }
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '総保持の補完が成功'
    Assert-Baseline ($script:writes.Count -eq 2) 'EventとSyslogだけ各1書込み'
    foreach($name in @('Event','Syslog')) {
        $tableId="$workspaceId/tables/$name"
        $write=@($script:writes | Where-Object ResourceId -eq $tableId)
        Assert-Baseline ($write.Count -eq 1 -and $write[0].Method -eq 'Patch') "$name は既存テーブルへPATCH"
        Assert-Baseline (($write[0].Body.properties.PSObject.Properties.Name -join ',') -ceq 'totalRetentionInDays') "$name の送信項目は総保持だけ"
        Assert-Baseline ($write[0].Body.properties.totalRetentionInDays -eq 1095 -and $script:fixture[$tableId].properties.totalRetentionInDays -eq 1095) "$name の総保持1095を読み戻す"
        Assert-Baseline ($script:fixture[$tableId].properties.retentionInDays -eq 30 -and $script:fixture[$tableId].properties.plan -eq 'Analytics') "$name の分析保持30とプランは維持"
        Assert-Baseline ((ConvertTo-Json -InputObject $script:fixture[$tableId].properties.schema -Depth 40 -Compress) -ceq $schemaBefore[$name] -and $script:fixture[$tableId].properties.customSetting -eq "keep-$name") "$name のスキーマと追加項目は維持"
    }
    Assert-Baseline ((ConvertTo-Json -InputObject $script:fixture[$workspaceId] -Depth 40 -Compress) -ceq $workspaceBefore) 'ワークスペースの設定は不変'
    Assert-Baseline ((ConvertTo-Json -InputObject $script:fixture[$otherTableId] -Depth 40 -Compress) -ceq $otherBefore) '対象外テーブルは不変'
    $again=Invoke-DestinationStage -Target $target
    Assert-Baseline ($again -and $script:writes.Count -eq 2) '1095設定済みの再実行は追加書込み0'
}
Invoke-BaselineCase '分析保持365でも総保持が未指定なら確認NGと設定補完' {
    $eventId="$workspaceId/tables/Event"
    $script:fixture[$eventId].properties.PSObject.Properties.Remove('totalRetentionInDays')
    $script:fixture[$eventId].properties.retentionInDays=365
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready -and $script:writes.Count -eq 0) '分析保持を総保持設定済みと誤認しない'
    Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $eventId).Count -eq 1) '総保持未指定のEventを記録'
    $script:failures.Clear();$script:verificationResults.Clear()
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline ($ready -and $script:writes.Count -eq 1 -and $script:writes[0].Method -eq 'Patch' -and $script:writes[0].ResourceId -eq $eventId) '未指定の総保持だけ1PATCH'
    Assert-Baseline ($script:fixture[$eventId].properties.totalRetentionInDays -eq 1095 -and $script:fixture[$eventId].properties.retentionInDays -eq 365) '総保持を追加し分析保持365を維持'
}
Invoke-BaselineCase 'EventとSyslogの新規作成は総保持1095を指定し完了後にDCRを作成' {
    foreach($name in @('Event','Syslog')){$script:fixture.Remove("$workspaceId/tables/$name")}
    $script:fixture.Remove($dcrId)
    $script:tableProvisioningDelay=3
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline $ready 'テーブルの更新完了を待ちDCR作成まで成功'
    $tableWrites=@($script:writes | Where-Object {$_.ResourceId -match '/tables/(Event|Syslog)$'})
    Assert-Baseline ($tableWrites.Count -eq 2) '新しい2テーブルだけ各1書込み'
    foreach($name in @('Event','Syslog')) {
        $tableId="$workspaceId/tables/$name"
        $write=@($tableWrites | Where-Object ResourceId -eq $tableId)
        Assert-Baseline ($write.Count -eq 1 -and $write[0].Method -eq 'Put') "$name は新規PUT"
        Assert-Baseline ($write[0].Body.properties.schema.name -eq $name -and $write[0].Body.properties.totalRetentionInDays -eq 1095) "$name の新規PUTにスキーマ名と総保持1095"
        Assert-Baseline ((@($write[0].Body.properties.PSObject.Properties.Name | Sort-Object) -join ',') -ceq 'schema,totalRetentionInDays') "$name の分析保持やプランを指定しない"
        Assert-Baseline ($script:fixture[$tableId].properties.provisioningState -eq 'Succeeded') "$name の完了を読み戻す"
    }
    Assert-Baseline ($script:tableReadPolls -ge 6 -and $script:pendingTableReads.Count -eq 0) '両テーブルのUpdatingを実GETで待つ'
    Assert-Baseline (-not $script:earlyDcrWrite -and @($script:writes | Where-Object ResourceId -eq $dcrId).Count -eq 1) '全テーブル完了後にだけDCRを作成'
}
Invoke-BaselineCase '総保持PATCHの読み戻し不一致ではDCRと関連作成を開始しない' {
    $eventId="$workspaceId/tables/Event"
    $script:fixture[$eventId].properties.totalRetentionInDays=90
    $script:skipMutationId=$eventId
    $script:fixture.Remove($dcrId)
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline (-not $ready) '総保持の読み戻し不一致は未完了'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $eventId) '総保持PATCH試行以外の書込み0'
    Assert-Baseline (-not $script:fixture.ContainsKey($dcrId)) 'DCRは未作成のまま'
    $failure=@($script:failures | Where-Object ResourceId -eq $eventId)
    Assert-Baseline ($failure.Count -eq 1 -and ($failure[0].ExpectedConfiguration | ConvertFrom-Json).properties.totalRetentionInDays -eq 1095) '手動対応一覧に正しい総保持1095を記録'
}
Invoke-BaselineCase '確認版はEventとSyslogの総保持90を変更せず全件NGにする' {
    foreach($name in @('Event','Syslog')){$script:fixture["$workspaceId/tables/$name"].properties.totalRetentionInDays=90}
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready -and $script:writes.Count -eq 0) '確認版は設定不一致でも書込み0'
    $failures=@($script:failures | Where-Object Stage -eq 'VMログテーブル')
    Assert-Baseline ($failures.Count -eq 2) '両テーブルの総保持不一致を確認'
    foreach($failure in $failures){Assert-Baseline (($failure.ExpectedConfiguration | ConvertFrom-Json).properties.totalRetentionInDays -eq 1095) '確認結果の完成値は総保持1095'}
}


Invoke-BaselineCase '総保持1095のPATCHが拒否されても元の分析保持と設定を維持' {
    $eventId="$workspaceId/tables/Event"
    $script:fixture[$eventId].properties.retentionInDays=30
    $script:fixture[$eventId].properties.totalRetentionInDays=90
    $script:rejectTableRetentionWrite=$true
    $script:fixture.Remove($dcrId)
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline (-not $ready) '総保持更新のAPI拒否は未完了'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $eventId) '対象テーブル以外の書込みを開始しない'
    Assert-Baseline ($script:fixture[$eventId].properties.retentionInDays -eq 30 -and $script:fixture[$eventId].properties.totalRetentionInDays -eq 90) 'API拒否後も元の保持設定を維持'
    Assert-Baseline (-not $script:fixture.ContainsKey($dcrId)) '後続DCRを作成しない'
    Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $eventId).Count -eq 1) '手動対応対象のテーブルを記録'
}

Invoke-BaselineCase '継承した総保持365を明示1095へ変更し読取り専用フラグは送らない' {
    $eventId="$workspaceId/tables/Event"
    $script:fixture[$eventId].properties.totalRetentionInDays=365
    $script:fixture[$eventId].properties | Add-Member totalRetentionInDaysAsDefault $true -Force
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready -and $script:writes.Count -eq 0) '継承した365は要求する明示1095ではない'
    $script:failures.Clear();$script:verificationResults.Clear()
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline ($ready -and $script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $eventId -and $script:writes[0].Method -eq 'Patch') '継承中のEventだけ総保持をPATCH'
    Assert-Baseline (($script:writes[0].Body.properties.PSObject.Properties.Name -join ',') -ceq 'totalRetentionInDays') '読み取り専用AsDefaultは書込み本文に含めない'
    Assert-Baseline ($script:fixture[$eventId].properties.totalRetentionInDays -eq 1095 -and $script:fixture[$eventId].properties.totalRetentionInDaysAsDefault -eq $false) '明示設定1095を読み戻す'
    $again=Invoke-DestinationStage -Target $target
    Assert-Baseline ($again -and $script:writes.Count -eq 1) '明示設定後の再実行は追加書込み0'
}
Invoke-BaselineCase '総保持1095でAsDefaultが省略またはnullなら変更せず確認できる' {
    $script:fixture["$workspaceId/tables/Event"].properties.PSObject.Properties.Remove('totalRetentionInDaysAsDefault')
    $script:fixture["$workspaceId/tables/Syslog"].properties | Add-Member totalRetentionInDaysAsDefault $null -Force
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline ($ready -and $script:writes.Count -eq 0) '任意フラグの省略とnullを許容'
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline ($ready -and $script:writes.Count -eq 0) '総保持1095なら再設定せずスキップ'
}


Invoke-BaselineCase '旧365管理ルールだけ1095へ置換し他名ルールの365設定を保持' {
    $owned=@($script:fixture[$policyId].properties.policy.rules | Where-Object name -eq 'log-append-1095')[0]
    $owned.name='log-append-365'
    $owned.definition.actions.baseBlob.delete.daysAfterModificationGreaterThan=365
    $other=Copy-TestValue @{name='keep-custom-365';enabled=$true;type='Lifecycle';definition=@{filters=@{blobTypes=@('blockBlob');prefixMatch=@('残す/')};actions=@{baseBlob=@{delete=@{daysAfterModificationGreaterThan=365}}}}}
    $script:fixture[$policyId].properties.policy.rules+=@($other)
    $otherBefore=ConvertTo-Json -InputObject $other -Depth 40 -Compress
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline $ready '旧管理ルールの置換が成功'
    Assert-Baseline ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $policyId -and $script:writes[0].Method -eq 'Put') 'Lifecycleだけ1PUT'
    $rules=@($script:fixture[$policyId].properties.policy.rules)
    $new=@($rules | Where-Object name -eq 'log-append-1095')
    Assert-Baseline ($rules.Count -eq 2 -and $new.Count -eq 1 -and $new[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 1095) '新管理ルールは1095で一意'
    Assert-Baseline (@($rules | Where-Object name -eq 'log-append-365').Count -eq 0) '365で先に削除する旧管理ルールを残さない'
    $kept=@($rules | Where-Object name -eq 'keep-custom-365')[0]
    Assert-Baseline ((ConvertTo-Json -InputObject $kept -Depth 40 -Compress) -ceq $otherBefore) '他名ルールは365という名前・日数・日本語条件を含め完全保持'
    $again=Invoke-DestinationStage -Target $target
    Assert-Baseline ($again -and $script:writes.Count -eq 1) '置換後の再実行は追加書込み0'
}
Invoke-BaselineCase '正しい1095管理ルールがあっても併存する旧365管理ルールを除去' {
    $legacy=Copy-TestValue @($script:fixture[$policyId].properties.policy.rules | Where-Object name -eq 'log-append-1095')[0]
    $legacy.name='log-append-365'
    $legacy.definition.actions.baseBlob.delete.daysAfterModificationGreaterThan=365
    $script:fixture[$policyId].properties.policy.rules+=@($legacy)
    $ready=Invoke-DestinationStage -Target $target -VerifyOnly
    Assert-Baseline (-not $ready -and $script:writes.Count -eq 0) '新1095が正しくても旧365が残る間は確認NG'
    Assert-Baseline (@($script:failures | Where-Object ResourceId -eq $policyId).Count -eq 1) '旧管理ルールが残るポリシーを一覧へ記録'
    $script:failures.Clear();$script:verificationResults.Clear()
    $ready=Invoke-DestinationStage -Target $target
    Assert-Baseline ($ready -and $script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $policyId) '既存1095が一致していても旧365を除去'
    $rules=@($script:fixture[$policyId].properties.policy.rules)
    Assert-Baseline ($rules.Count -eq 1 -and $rules[0].name -eq 'log-append-1095' -and $rules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 1095) '自分のルールは1095だけを1件残す'
}

$report = [pscustomobject]@{
    Result = 'PASS'; CaseCount = $script:caseResults.Count; AssertionCount = $script:assertionCount; Checks = $script:assertionCount
    PowerShellVersion = $PSVersionTable.PSVersion.ToString(); CommonHash = (Get-FileHash -LiteralPath $CommonPath -Algorithm SHA256).Hash; StageHashes = @(foreach($name in @('precheck','copy','verify')){ @{Name=$name;Hash=(Get-FileHash -LiteralPath (Join-Path $Repository (@{ precheck='precheck.ps1'; copy='step1_copy.ps1'; verify='step2_verify.ps1' }[$name])) -Algorithm SHA256).Hash} })
    ActualShapeCount = $script:shapeTexts.Count; AzureRequests = 0; Cases = $script:caseResults.ToArray()
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if ($PassThru) { $report } else { $report | ConvertTo-Json -Depth 10 }
