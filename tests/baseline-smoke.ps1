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
    $script:writes.Add([pscustomobject]@{ ResourceId = $ResourceId; Method = $Method; Body = Copy-TestValue $Body })
    if ($script:skipMutationId -ne $ResourceId) {
        $changes = Copy-TestValue $Body
        if ($ResourceId -match '/dataCollectionRules/[^/]+$') { $changes.properties | Add-Member -NotePropertyName provisioningState -NotePropertyValue 'Succeeded' -Force }
        if($ResourceId -eq $script:transitionAssociationId) {$changes.properties | Add-Member provisioningState 'Updating' -Force}
        if ($script:fixture.ContainsKey($ResourceId)) { Merge-TestProperties -Current $script:fixture[$ResourceId] -Changes $changes }
        else { $script:fixture[$ResourceId] = $changes }
    }
    $script:fixture[$ResourceId]
}
# 共通の旧ラッパーを再現せず、現在のcopy/verify本体をそのままfixtureへ通します。
function Invoke-DestinationStage {
    param([object]$Target,[switch]$VerifyOnly)
    # 対象探索・バックアップI/Oだけを置き換え、作成/確認の処理とHTTP mockは実際に通します。
    $Target.DiagnosticPlans=[Collections.Generic.List[object]]::new()
    $Target.CurrentSettings=@{}
    $Target.OldAssociations=@()
    $body=Get-MigrationDcrBody -Target $Target
    $savedAssociations=@(foreach($collectorId in $Target.Collectors){
        @{ResourceId="$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($dcrShape.name)";Before=$null;After=@{properties=@{dataCollectionRuleId=$dcrId}}}
    })
    $script:destinationTarget=$Target
    $script:destinationBackup=@{Targets=@(@{SubscriptionId=$Target.SubscriptionId;Diagnostics=@();OldAssociations=@();Storages=@($Target.Storages.Values);Associations=$savedAssociations;Dcr=@{ResourceId=$dcrId;Before=$null;After=$body}})}
    function Read-MigrationBackup {param($Path,[switch]$CheckCsv) $script:destinationBackup}
    function Get-MigrationTargets { $script:destinationTarget }
    function Get-MigrationPlan {param($Target,[switch]$Fresh) $true}
    function Complete-MigrationStep {
        param($Step,[switch]$IncludeChecks)
        if($script:failures.Count -gt 0){throw 'TEST_DESTINATION_RECORDED_FAILURE'}
    }
    $entry=if($VerifyOnly){'step3_verify.ps1'}else{'step2_copy.ps1'}
    $entryText=Get-Content -LiteralPath (Join-Path $Repository $entry) -Raw -Encoding UTF8
    $entryBody=($entryText -split "`n" | Select-Object -Skip 2) -join "`n"
    try { Invoke-Expression $entryBody }
    catch {if($_.Exception.Message -ne 'TEST_DESTINATION_RECORDED_FAILURE'){throw}}
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
    Assert-Baseline ($script:fixture[$policyId].properties.policy.rules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 365) 'Lifecycleの365.0を保持'
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
    Assert-Baseline ($sentRules[0].name -eq 'log-append-365' -and $sentRules[0].definition.actions.baseBlob.delete.daysAfterModificationGreaterThan -eq 365) '送信ルールの名前と保持日数'
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
$report = [pscustomobject]@{
    Result = 'PASS'; CaseCount = $script:caseResults.Count; AssertionCount = $script:assertionCount; Checks = $script:assertionCount
    PowerShellVersion = $PSVersionTable.PSVersion.ToString(); CommonHash = (Get-FileHash -LiteralPath $CommonPath -Algorithm SHA256).Hash; StageHashes = @(foreach($name in @('precheck','copy','verify')){ @{Name=$name;Hash=(Get-FileHash -LiteralPath (Join-Path $Repository (@{ precheck='step1_precheck.ps1'; copy='step2_copy.ps1'; verify='step3_verify.ps1' }[$name])) -Algorithm SHA256).Hash} })
    ActualShapeCount = $script:shapeTexts.Count; AzureRequests = 0; Cases = $script:caseResults.ToArray()
}
$report | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $ReportPath -Encoding UTF8
if ($PassThru) { $report } else { $report | ConvertTo-Json -Depth 10 }
