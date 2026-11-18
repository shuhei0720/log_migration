#Requires -Version 5.1
param([string]$Repository=(Split-Path -Parent $PSScriptRoot),[string]$ReportPath,[switch]$PassThru)
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'log_migration_common.ps1')
$script:cutoverChecks=0
$script:cutoverCases=[Collections.Generic.List[object]]::new()
$script:sub1='11111111-1111-1111-1111-111111111111';$script:sub2='22222222-2222-2222-2222-222222222222';$script:outside='33333333-3333-3333-3333-333333333333'
$script:oldRules=@('/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/hub/providers/Microsoft.Insights/dataCollectionRules/old-linux','/subscriptions/44444444-4444-4444-4444-444444444444/resourceGroups/hub/providers/Microsoft.Insights/dataCollectionRules/old-windows')
$script:getterTargets=@(@{SubscriptionId=$script:sub1},@{SubscriptionId=$script:sub2})
$script:getterReads=[Collections.Generic.List[string]]::new()
function Assert-Cutover([bool]$Condition,[string]$Message) {if(-not $Condition){throw "DCRcutover検証失敗: $Message"};$script:cutoverChecks++}
function Copy-CutoverValue($Value) {ConvertTo-Json -InputObject $Value -Depth 40 | ConvertFrom-Json}
function New-OldAssociation([string]$Sub,[string]$Name,[string]$Rule,[string]$ParentType='Microsoft.Compute/virtualMachines') {
    [pscustomobject]@{id="/subscriptions/$Sub/resourceGroups/source/providers/$ParentType/$Name/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-$Name";name="old-$Name";properties=[pscustomobject]@{description="元設定-$Name";dataCollectionRuleId=$Rule;dataCollectionEndpointId='/old-dce';provisioningState='Succeeded';readOnlyExtra='discard'}}
}
function Reset-Getter {
    $script:getterReads.Clear()
    $a=New-OldAssociation $script:sub1 a $script:oldRules[0]
    $b=New-OldAssociation $script:sub2 b $script:oldRules[0] 'Microsoft.HybridCompute/machines'
    $c=New-OldAssociation $script:sub1 c $script:oldRules[0]
    $d=New-OldAssociation $script:sub2 d $script:oldRules[1]
    $out=New-OldAssociation $script:outside outside $script:oldRules[0]
    $script:next='https://management.azure.com/old-association-page2?api-version=2024-03-11&skiptoken=next'
    $script:pages=@{}
    $script:pages["$($script:oldRules[0])/associations"]=[pscustomobject]@{value=@($a,$b,$out);nextLink=$script:next}
    $script:pages[$script:next]=[pscustomobject]@{value=@($c)}
    $script:pages["$($script:oldRules[1])/associations"]=[pscustomobject]@{value=@($d)}
    $script:getterFailure=''
}
function Invoke-ArmRequest {
    param([string]$ResourceId,[string]$Method='Get',[object]$Body,[string]$ApiVersion)
    if($Method -ne 'Get'){throw 'Getterが書込みを実行しました。'}
    $script:getterReads.Add($ResourceId)
    if($ResourceId -eq $script:getterFailure){throw 'TEST_GET_FAILURE'}
    if(-not $script:pages.ContainsKey($ResourceId)){throw "想定外GET: $ResourceId"}
    $script:pages[$ResourceId]
}
function Invoke-GetterCase([string]$Name,[scriptblock]$Body) {
    Reset-Getter
    $before=$script:cutoverChecks
    & $Body
    $script:cutoverCases.Add([pscustomobject]@{Case=$Name;Result='PASS';Assertions=$script:cutoverChecks-$before})
}
function Assert-GetterRejected([string[]]$Ids=$script:oldRules,[object[]]$Targets=$script:getterTargets,[switch]$BeforeGet) {
    $failed=$false
    try{$null=@(Get-OldDcrAssociations -Targets $Targets -DcrIds $Ids)}catch{$failed=$true}
    Assert-Cutover $failed '不正な関連一覧を空扱いせず拒否'
    if($BeforeGet){Assert-Cutover ($script:getterReads.Count -eq 0) 'ID不正はAPI照会前に停止'}
}
Invoke-GetterCase '2本の一覧とnextLink・Subfilter・writableだけ保存' {
    $records=@(Get-OldDcrAssociations -Targets $script:getterTargets -DcrIds $script:oldRules)
    Assert-Cutover ($script:getterReads.Count -eq 3 -and $script:getterReads[1] -eq $script:next) '2本各1GETと2ページ目だけ取得'
    Assert-Cutover ($records.Count -eq 4) 'CSV対象2Subの4件だけ返却'
    Assert-Cutover (@($records | Where-Object SubscriptionId -eq $script:outside).Count -eq 0) 'CSV外Subを除外'
    Assert-Cutover (@($records | Where-Object {$_.ParentResourceId -match '/Microsoft.HybridCompute/machines/'}).Count -eq 1) 'VM以外も親IDを保持'
    foreach($record in $records){
        Assert-Cutover ($record.ResourceId -eq "$($record.ParentResourceId)/providers/Microsoft.Insights/dataCollectionRuleAssociations/$($record.ResourceId.Split('/')[-1])") '親と完全DCRA IDを保存'
        Assert-Cutover (@($record.Before.properties.Keys).Count -eq 3 -and $null -eq $record.After) 'description/DCR/DCE以外を保存しない'
    }
}
Invoke-GetterCase '2本とも空一覧なら0件' {
    foreach($id in $script:oldRules){$script:pages["$id/associations"]=[pscustomobject]@{value=@()}}
    $records=@(Get-OldDcrAssociations -Targets $script:getterTargets -DcrIds $script:oldRules)
    Assert-Cutover ($records.Count -eq 0 -and $script:getterReads.Count -eq 2) '正常な空一覧だけを0件扱い'
}
foreach($idCase in @(@{Name='1本';Ids=@($script:oldRules[0])},@{Name='3本';Ids=@($script:oldRules[0],$script:oldRules[1],$script:oldRules[0]+'x')},@{Name='大文字小文字重複';Ids=@($script:oldRules[0],$script:oldRules[0].ToUpperInvariant())},@{Name='余白除去後重複';Ids=@($script:oldRules[0],' '+$script:oldRules[0]+' ')},@{Name='不正ID';Ids=@('/wrong',$script:oldRules[1])})){
    Invoke-GetterCase "旧DCR $($idCase.Name)を拒否" {Assert-GetterRejected -Ids $idCase.Ids -BeforeGet}
}
Invoke-GetterCase 'CSV対象0件を拒否' {Assert-GetterRejected -Targets @() -BeforeGet}
foreach($badPage in @('NullPage','NullValue','NullItem','GetFailure','BadId','WrongRule','Duplicate')){
    Invoke-GetterCase "一覧${badPage}を拒否" {
        $url="$($script:oldRules[0])/associations"
        switch($badPage){
            'NullPage' {$script:pages[$url]=$null}
            'NullValue' {$script:pages[$url]=[pscustomobject]@{value=$null}}
            'NullItem' {$script:pages[$url]=[pscustomobject]@{value=@($null)}}
            'GetFailure' {$script:getterFailure=$script:next}
            'BadId' {$script:pages[$url].value[0].id='/not-a-dcra-id'}
            'WrongRule' {$script:pages[$url].value[0].properties.dataCollectionRuleId=$script:oldRules[1]}
            'Duplicate' {$script:pages[$script:next].value=@($script:pages[$url].value[0])}
        }
        Assert-GetterRejected
    }
}
Invoke-GetterCase '新旧DCR・関連ID衝突だけを停止' {
    $records=@(Get-OldDcrAssociations -Targets $script:getterTargets -DcrIds $script:oldRules)
    Assert-DcrCutoverIds -OldDcrIds $script:oldRules -NewDcrIds @('/new-dcr') -OldAssociations $records -NewAssociationIds @('/new-association')
    Assert-Cutover $true '別IDは許可'
    foreach($mode in @('Dcr','Association')){
        $failed=$false
        try{if($mode -eq 'Dcr'){Assert-DcrCutoverIds -OldDcrIds $script:oldRules -NewDcrIds @($script:oldRules[1].ToUpperInvariant())}else{Assert-DcrCutoverIds -OldAssociations $records -NewAssociationIds @($records[0].ResourceId.ToUpperInvariant())}}catch{$failed=$true}
        Assert-Cutover $failed '大文字小文字だけ異なる衝突も停止'
    }
}
# 既存560回帰の局所fixtureだけ再利用し、本結線前の旧関連barrierを確認します。
$oldTokens=$null;$oldErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'backup-rollback-smoke.ps1'),[ref]$oldTokens,[ref]$oldErrors)
$firstFunction=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})[0]
foreach($statement in $fixtureAst.EndBlock.Statements){
    if($statement.Extent.StartOffset -ge $firstFunction.Extent.StartOffset){break}
    Invoke-Expression $statement.Extent.Text
}
$baseArmNode=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-ArmRequest'})[0]
foreach($statement in $fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){Invoke-Expression $statement.Extent.Text}
$script:baseFixtureArm=[scriptblock]::Create($baseArmNode.Body.Extent.Text.Substring(1,$baseArmNode.Body.Extent.Text.Length-2))
$preTokens=$null;$preErrors=$null
$preAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'log_migration_precheck.ps1'),[ref]$preTokens,[ref]$preErrors)
$saveTry=@($preAst.FindAll({param($n) $n -is [Management.Automation.Language.TryStatementAst] -and $n.Body.Extent.Text -match 'FileMode\]::CreateNew'},$true))[0]
$script:saveBackupCode=$saveTry.Body.Extent.Text.Substring(1,$saveTry.Body.Extent.Text.Length-2)
$script:oldCutoverRecords=@();$script:oldReadVerified=[Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
function Invoke-ArmRequest {
    param([string]$ResourceId,[string]$Method='Get',[object]$Body,[string]$ApiVersion)
    $record=@($script:oldCutoverRecords | Where-Object ResourceId -eq $ResourceId)
    if($Method -ne 'Get' -and $script:oldCutoverRecords.Count -gt 0 -and $record.Count -eq 0 -and $script:oldReadVerified.Count -ne $script:oldCutoverRecords.Count){$script:earlyNewSideWrite=$true}
    $result=& $script:baseFixtureArm @PSBoundParameters
    if($Method -eq 'Put' -and $ResourceId -eq $script:oldReadbackFailure){$script:resources[$ResourceId].properties.dataCollectionRuleId='/foreign-rule'}
    if($Method -eq 'Put' -and $ResourceId -eq $script:oldUpdatingId){$script:resources[$ResourceId].properties | Add-Member provisioningState 'Updating' -Force}
    if($Method -eq 'Get' -and $record.Count -eq 1 -and $result -and (-not $result.properties.provisioningState -or $result.properties.provisioningState -eq 'Succeeded')){
        $body=Get-RollbackBody $result -Association
        if((Test-BaselineValues $body $record[0].Before) -and (Test-BaselineValues $record[0].Before $body)){$null=$script:oldReadVerified.Add($ResourceId)}
    }
    $result
}
function Prepare-OldCutover {
    Save-TestBackup;Seed-AfterMigration
    $script:oldCutoverRecords=@($script:savedBackup.Targets.OldAssociations)
    $script:thirdRuleIds=@()
    foreach($record in $script:oldCutoverRecords) {
        $script:resources.Remove($record.ResourceId)
        $parent=$record.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$',''
        $third="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/keep-third-rule"
        $script:resources[$third]=Copy-TestValue @{properties=@{description='触らない';dataCollectionRuleId='/third-rule'}}
        $script:thirdRuleIds+=@($third)
    }
    Reset-Observation
    $script:oldReadVerified.Clear();$script:earlyNewSideWrite=$false;$script:oldReadbackFailure='';$script:oldUpdatingId=''
}
function Assert-ThirdRuleUnchanged {
    foreach($id in $script:thirdRuleIds){Assert-Cutover ($script:resources[$id].properties.dataCollectionRuleId -eq '/third-rule' -and @($script:writes | Where-Object ResourceId -eq $id).Count -eq 0) '指定外Ruleの関連を変更しない'}
}
# 本結線の検証では、旧関連のあるVMSSと診断設定の対象を分けて用意します。
function Prepare-WiredCutover {
    foreach($target in $script:targets){foreach($old in $target.OldAssociations){$script:resources.Remove($old.ResourceId)}}
    $script:oldCutoverRecords=@();$script:thirdRuleIds=@()
    $script:fixtureVmssId="/subscriptions/$($script:subs[1])/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/scale-set"
    foreach($index in 0..1) {
        $target=$script:targets[$index]
        $parent=if($index -eq 0){$target.Vms[0].id}else{$script:fixtureVmssId}
        $record=[pscustomobject]@{
            SubscriptionId=$target.SubscriptionId;ParentResourceId=$parent
            ResourceId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-collector"
            Before=@{properties=@{description="元の関連-$index";dataCollectionRuleId=$script:oldRules[$index]}};After=$null
        }
        $target.OldAssociations=@($record)
        $target.Collectors=@($parent)
        $script:resources[$record.ResourceId]=Copy-TestValue $record.Before
        $script:oldCutoverRecords+=@($record)
        $third="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/keep-third-rule"
        $script:resources[$third]=Copy-TestValue @{properties=@{description='触らない';dataCollectionRuleId='/third-rule'}}
        $script:thirdRuleIds+=@($third)
    }
    $script:outsideCutoverId="/subscriptions/$script:outside/resourceGroups/source/providers/Microsoft.Compute/virtualMachines/outside/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-collector"
    $script:resources[$script:outsideCutoverId]=Copy-TestValue @{properties=@{description='CSV外';dataCollectionRuleId=$script:oldRules[0]}}
    Save-TestBackup
    $script:oldReadVerified.Clear();$script:earlyNewSideWrite=$false;$script:oldReadbackFailure='';$script:oldUpdatingId=''
}
function Invoke-WiredCase([string]$Name,[scriptblock]$Body) {
    $before=$script:checks+$script:cutoverChecks
    Invoke-TestCase $Name {
        Prepare-WiredCutover
        & $Body
    }
    $script:cutoverCases.Add([pscustomobject]@{Case=$Name;Result='PASS';Assertions=$script:checks+$script:cutoverChecks-$before})
}
function Assert-WiredProtected {
    Assert-ThirdRuleUnchanged
    Assert-Cutover ($script:resources[$script:outsideCutoverId].properties.dataCollectionRuleId -eq $script:oldRules[0]) 'CSV外の旧DCR関連を保持'
    Assert-Cutover (@($script:writes | Where-Object ResourceId -eq $script:outsideCutoverId).Count -eq 0) 'CSV外の関連への書込み0'
}
try{
    foreach($mode in @('Success','PutFailure','ReadbackFailure','ForeignBefore','UpdatingThenReady')){
        $before=$script:checks+$script:cutoverChecks
        Invoke-TestCase "旧関連barrier-$mode" {
            Prepare-OldCutover
            switch($mode){
                'PutFailure' {$script:failedPut=$script:oldCutoverRecords[1].ResourceId}
                'ReadbackFailure' {$script:oldReadbackFailure=$script:oldCutoverRecords[0].ResourceId}
                'ForeignBefore' {$script:resources[$script:oldCutoverRecords[1].ResourceId]=Copy-TestValue @{properties=@{dataCollectionRuleId='/foreign-rule'}}}
                'UpdatingThenReady' {$script:oldUpdatingId=$script:oldCutoverRecords[0].ResourceId;$script:transitionDcrId=$script:oldUpdatingId;$script:readyAfterReads=3}
            }
            $fail=$mode -in @('PutFailure','ReadbackFailure','ForeignBefore')
            Invoke-Entry rollback -ExpectFailure $fail
            Assert-Cutover (-not $script:earlyNewSideWrite) '全旧関連の復元readback前にnewside書込み0'
            if($fail){
                Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -notin $script:oldCutoverRecords.ResourceId}).Count -eq 0) '旧関連失敗時はnewDCR/newDCRA/newdiagを変更しない'
                Assert-NewSettingsRetained
            }else{
                Assert-Cutover ($script:oldReadVerified.Count -eq $script:oldCutoverRecords.Count) '全selected旧関連を復元・読み戻す'
                foreach($record in $script:oldCutoverRecords){Assert-Cutover ($script:resources[$record.ResourceId].properties.dataCollectionRuleId -eq $record.Before.properties.dataCollectionRuleId) '指定した旧Ruleへ復元'}
            }
            Assert-ThirdRuleUnchanged
            if($mode -eq 'PutFailure'){
                Reset-Observation;$script:oldReadVerified.Clear();$script:earlyNewSideWrite=$false
                Invoke-Entry rollback
                Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Put' -and $_.ResourceId -eq $script:oldCutoverRecords[0].ResourceId}).Count -eq 0) '再実行は復元済の旧関連をskip'
                Assert-Cutover (-not $script:earlyNewSideWrite) '再実行も旧2件のreadback後にnewsideを変更'
            }
        }
        $script:cutoverCases.Add([pscustomobject]@{Case="旧関連barrier-$mode";Result='PASS';Assertions=$script:checks+$script:cutoverChecks-$before})
    }
    Invoke-WiredCase '実discoveryは旧関連のないVMとVMSSを収集対象へ加えない' {
        $sub=$script:subs[0];$relatedVm=$script:targets[0].Vms[0].id;$unrelatedVm=$script:targets[0].Vms[1].id
        $relatedVmss="/subscriptions/$sub/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/related"
        $unrelatedVmss="/subscriptions/$sub/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/unrelated"
        $oldVmss=[pscustomobject]@{ResourceId="$relatedVmss/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-vmss";ParentResourceId=$relatedVmss;SubscriptionId=$sub;Before=@{properties=@{dataCollectionRuleId=$script:oldRules[1]}}}
        $script:actualDiscoveryResources=@(
            @{id=$relatedVm;type='Microsoft.Compute/virtualMachines';location='japaneast'},
            @{id=$unrelatedVm;type='Microsoft.Compute/virtualMachines';location='japaneast'},
            @{id=$relatedVmss;type='Microsoft.Compute/virtualMachineScaleSets';location='japaneast'},
            @{id=$unrelatedVmss;type='Microsoft.Compute/virtualMachineScaleSets';location='japaneast'}
        )
        foreach($resource in $script:actualDiscoveryResources){$script:diagnostics[$resource.id]=@{}}
        Add-Setting $unrelatedVm 'old' $script:savedBackup.Targets[0].Diagnostics[0].Before
        $actualTarget=@{
            SubscriptionId=$sub;SubscriptionName=$sub;ResourceGroup='rg-target';WorkspaceName='log-new1';WorkspaceId=$script:targets[0].WorkspaceId
            LogDestination='Log';Storages=@{};OldAssociations=@($script:oldCutoverRecords[0],$oldVmss);Collectors=@()
            DiagnosticPlans=[Collections.Generic.List[object]]::new();CurrentSettings=@{}
        }
        $tokens=$null;$parseErrors=$null
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'log_migration_common.ps1'),[ref]$tokens,[ref]$parseErrors)
        $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MigrationPlan'},$true))[0]
        $productionPlan=[scriptblock]::Create($node.Body.Extent.Text.Substring(1,$node.Body.Extent.Text.Length-2))
        Reset-Observation
        & {
            function Invoke-AzJson {
                param([string[]]$Arguments)
                if($Arguments[0] -ne 'resource' -or $Arguments[1] -ne 'list'){throw '実discovery fixtureの想定外CLI'}
                $script:actualDiscoveryResources
            }
            $ready=& $productionPlan -Target $actualTarget
            Assert-Cutover ($ready -and $script:failures.Count -eq 0) '実GetPlanが対象を確定'
            Assert-Cutover ($actualTarget.Collectors.Count -eq 2 -and $relatedVm -in $actualTarget.Collectors -and $relatedVmss -in $actualTarget.Collectors) '旧関連VMとVMSSだけが収集対象'
            Assert-Cutover ($unrelatedVm -notin $actualTarget.Collectors -and $unrelatedVmss -notin $actualTarget.Collectors) '無関係VM・VMSSを除外'
            Assert-Cutover ($actualTarget.DiagnosticPlans.Count -eq 1 -and $actualTarget.DiagnosticPlans[0].ResourceId -eq $unrelatedVm) '無関係VMの旧診断設定は別条件で対象'
            $actualTarget.OldAssociations=@()
            $ready=& $productionPlan -Target $actualTarget
            Assert-Cutover ($ready -and $actualTarget.Collectors.Count -eq 0) '旧関連0ならmachine一覧があっても収集対象0'
            Assert-Cutover ($actualTarget.DiagnosticPlans.Count -eq 1) '旧DCR関連の有無は診断対象へ影響しない'
        }
        Assert-NoAzureWrites
        Assert-WiredProtected
    }
    Invoke-WiredCase 'Version2は旧2本・VMSS旧関連を最小保存する' {
        $backup=Read-MigrationBackup -CheckCsv
        Assert-Cutover ($backup.Version -eq 2 -and @($backup.OldDcrIds).Count -eq 2) 'Version2と旧2本のID'
        Assert-Cutover (@($backup.Targets.OldAssociations).Count -eq 2) '旧関連2件だけを保存'
        $vmss=@($backup.Targets[1].Associations | Where-Object {$_.ResourceId.StartsWith($script:fixtureVmssId+'/')})
        Assert-Cutover ($vmss.Count -eq 1) 'VMSSの新関連も保存'
        Assert-Cutover ($script:diagReads -eq 0 -and @($script:reads | Where-Object {$_ -in $script:oldCutoverRecords.ResourceId}).Count -eq $script:oldCutoverRecords.Count) '診断は再GETせず選択した旧関連だけを詳細取得'
        Assert-Cutover (@($backup.Targets.OldAssociations | Where-Object {$_.PSObject.Properties.Name -contains 'ParentResourceId'}).Count -eq 0) '旧関連の永続化はIDとBeforeだけ'
        Assert-WiredProtected
    }
    Invoke-WiredCase 'Rule一覧が参照IDだけでも完全GETの説明とDCEを保存・復元する' {
        Remove-Item -LiteralPath $migrationBackupPath
        $script:oldListPartial=$true
        foreach($target in $script:targets) {
            foreach($old in $target.OldAssociations) {
                $script:resources[$old.ResourceId].properties.description='元の説明-日本語'
                $script:resources[$old.ResourceId].properties | Add-Member dataCollectionEndpointId '/original-dce' -Force
                $old.Before=@{properties=@{dataCollectionRuleId=$script:resources[$old.ResourceId].properties.dataCollectionRuleId}}
            }
        }
        Reset-Observation
        Save-TestBackup
        $backup=Read-MigrationBackup -CheckCsv
        $script:oldCutoverRecords=@($backup.Targets.OldAssociations)
        foreach($saved in $backup.Targets.OldAssociations) {
            Assert-Cutover ($saved.Before.properties.description -eq '元の説明-日本語') '完全GETの日本語説明を保存'
            Assert-Cutover ($saved.Before.properties.dataCollectionEndpointId -eq '/original-dce') '完全GETのDCE参照を保存'
        }
        Assert-Cutover (@($script:reads | Where-Object {$_ -in $script:oldCutoverRecords.ResourceId}).Count -eq 2) '選択した旧2件だけを完全GET'
        Seed-AfterMigration -KeepOld
        Reset-Observation
        Invoke-Entry copy
        Assert-NoAzureWrites
        Assert-Cutover (@($script:targets.OldAssociations | Where-Object {$null -ne $_.Before.properties.description}).Count -eq 0) '後続の一覧は引き続き部分形'
        Reset-Observation
        Invoke-Entry delete
        Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -in $script:oldCutoverRecords.ResourceId}).Count -eq 2) '完全GET比較で正常削除'
        Reset-Observation
        Invoke-Entry rollback
        foreach($saved in $backup.Targets.OldAssociations) {
            Assert-Cutover ($script:resources[$saved.ResourceId].properties.description -eq '元の説明-日本語') '切戻しで説明を復元'
            Assert-Cutover ($script:resources[$saved.ResourceId].properties.dataCollectionEndpointId -eq '/original-dce') '切戻しでDCEを復元'
        }
        Assert-WiredProtected
    }
    Invoke-WiredCase '選択した旧関連の完全GET失敗はバックアップを作らず停止する' {
        Remove-Item -LiteralPath $migrationBackupPath
        $script:resources.Remove($script:oldCutoverRecords[1].ResourceId)
        Reset-Observation
        $failed=$false
        try{Save-TestBackup}catch{$failed=$true}
        Assert-Cutover $failed '旧一覧にあっても完全GET失敗を無視しない'
        Assert-Cutover (-not (Test-Path -LiteralPath $migrationBackupPath)) '不完全なBeforeのバックアップを保存しない'
        Assert-NoAzureWrites
        Assert-WiredProtected
    }
    Invoke-WiredCase '複製の再実行は旧DCR関連を解除しない' {
        Seed-AfterMigration -KeepOld
        Reset-Observation
        Invoke-Entry copy
        Assert-Cutover ($script:writes.Count -eq 0) '既存一致copyの書込み0'
        foreach($record in $script:oldCutoverRecords){Assert-Cutover ($script:resources.ContainsKey($record.ResourceId)) '旧関連を保持'}
        Assert-Cutover ($script:fixtureVmssId -in $script:targets[1].Collectors) 'VMSSを新DCRの対象へ追加'
        Assert-WiredProtected
    }
    Invoke-WiredCase '旧DCR関連のないVMは診断設定だけ複製し関連付けを作らない' {
        $unrelatedVm=$script:targets[0].Vms[1].id
        $model=$script:savedBackup.Targets[0].Diagnostics[0]
        Add-Setting $unrelatedVm 'old' $model.Before
        Add-Setting $unrelatedVm 'keep-unrelated' @{workspaceId='/other-workspace';logs=@();metrics=@()}
        Remove-Item -LiteralPath $migrationBackupPath
        foreach($target in $script:targets){$null=Get-MigrationPlan -Target $target}
        Save-TestBackup;Seed-AfterMigration -KeepOld
        $script:diagnostics[$unrelatedVm].Remove($newDiagnosticSettingName)
        Reset-Observation
        Invoke-Entry copy
        Assert-Cutover ($script:diagnostics[$unrelatedVm].ContainsKey($newDiagnosticSettingName)) '旧workspace宛の診断設定は複製'
        Assert-Cutover ($unrelatedVm -notin $script:targets[0].Collectors) '旧DCR関連のないVMをcollectorへ追加しない'
        Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -like "$unrelatedVm/providers/Microsoft.Insights/dataCollectionRuleAssociations/*"}).Count -eq 0) '無関係VMのDCRA PUT0'
        Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -eq "$unrelatedVm/providers/Microsoft.Insights/diagnosticSettings/$newDiagnosticSettingName" -and $_.Method -eq 'Put'}).Count -eq 1) '診断設定だけ1PUT'
        Assert-WiredProtected
    }
    Invoke-WiredCase '旧関連消失後もVMSS新関連を全件確認対象へ残す' {
        Seed-AfterMigration
        foreach($old in $script:oldCutoverRecords){$script:resources.Remove($old.ResourceId)}
        Reset-Observation
        Invoke-Entry verify
        Assert-Cutover ($script:fixtureVmssId -in $script:targets[1].Collectors) 'backupからVMSS親を復元'
        Assert-Cutover ($script:fixtureVmssId -in $script:baselineModes[1].Collectors) '全件基礎確認へVMSSを渡す'
        Assert-NoAzureWrites
        Assert-WiredProtected
    }
    foreach($newFailure in @('Missing','WrongRule','Updating')) {
        Invoke-WiredCase "後続VMSSの新関連${newFailure}は旧削除全体を止める" {
            Seed-AfterMigration -KeepOld
            $id=@($script:savedBackup.Targets[1].Associations | Where-Object {$_.ResourceId.StartsWith($script:fixtureVmssId+'/')})[0].ResourceId
            switch($newFailure) {
                'Missing' {$script:resources.Remove($id)}
                'WrongRule' {$script:resources[$id].properties.dataCollectionRuleId='/foreign-rule'}
                'Updating' {$script:resources[$id].properties | Add-Member provisioningState 'Updating' -Force}
            }
            Reset-Observation
            Invoke-Entry delete -ExpectFailure $true
            Assert-NoAzureWrites
            foreach($record in $script:oldCutoverRecords){Assert-Cutover ($script:resources.ContainsKey($record.ResourceId)) '全ての旧関連を保持'}
            foreach($target in $script:savedBackup.Targets){foreach($diagnostic in $target.Diagnostics){Assert-Cutover ($script:diagnostics[$diagnostic.ResourceId].ContainsKey($diagnostic.OldName)) '全旧診断を保持'}}
            Assert-WiredProtected
        }
    }
    Invoke-WiredCase '旧2本の関連だけを解除し削除済み再実行は変更0' {
        Seed-AfterMigration -KeepOld
        Reset-Observation
        Invoke-Entry delete
        Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -in $script:oldCutoverRecords.ResourceId}).Count -eq 2) '旧2本の関連だけDELETE'
        Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -match '/diagnosticSettings/old$'}).Count -eq 4) '旧診断だけ4件DELETE'
        Assert-Cutover (@($script:writes | Where-Object {$_.Method -ne 'Delete'}).Count -eq 0) '削除工程はPUTしない'
        foreach($target in $script:savedBackup.Targets){foreach($association in $target.Associations){Assert-Cutover ($script:resources.ContainsKey($association.ResourceId)) '新関連を保持'}}
        Assert-WiredProtected
        Reset-Observation
        Invoke-Entry delete
        Assert-NoAzureWrites
        Assert-Cutover ($script:fixtureVmssId -in $script:targets[1].Collectors) '再実行時もVMSSを検証対象へ残す'
    }
    foreach($failureIndex in 0..1) {
        Invoke-WiredCase "旧関連${failureIndex}のDELETE失敗は後続と全旧診断を停止" {
            Seed-AfterMigration -KeepOld
            Reset-Observation
            $script:failedDelete=$script:oldCutoverRecords[$failureIndex].ResourceId
            Invoke-Entry delete -ExpectFailure $true
            Assert-Cutover ($script:writes.Count -eq $failureIndex+1) '失敗後のDELETEを始めない'
            Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -match '/diagnosticSettings/'}).Count -eq 0) '全旧診断のDELETE0'
            Assert-NewSettingsRetained
            Assert-WiredProtected
            Reset-Observation
            Invoke-Entry delete
            Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -in $script:oldCutoverRecords.ResourceId}).Count -eq 2-$failureIndex) '再実行で未削除の旧関連だけを解除'
        }
    }
    Invoke-WiredCase '旧関連の内容変更は上書き・削除しない' {
        Seed-AfterMigration -KeepOld
        $id=$script:oldCutoverRecords[0].ResourceId
        $script:resources[$id].properties.description='外部で変更'
        Reset-Observation
        Invoke-Entry delete -ExpectFailure $true
        Assert-NoAzureWrites
        Assert-Cutover ($script:resources[$id].properties.description -eq '外部で変更') '変更された旧関連を保持'
    }
    Invoke-WiredCase 'backup後に追加された旧関連を処理前に拒否する' {
        Seed-AfterMigration -KeepOld
        $parent=$script:targets[0].Vms[1].id
        $id="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/added-later"
        $script:resources[$id]=Copy-TestValue @{properties=@{dataCollectionRuleId=$script:oldRules[0]}}
        Reset-Observation
        Invoke-Entry copy -ExpectFailure $true
        Assert-NoAzureWrites
        Reset-Observation
        Invoke-Entry delete -ExpectFailure $true
        Assert-NoAzureWrites
    }
    Invoke-WiredCase '指定Subの削除は集中DCRの他Sub関連を残す' {
        Seed-AfterMigration -KeepOld
        $rows=@(Import-Csv $inputCsvPath);@($rows[0]) | Export-Csv $inputCsvPath -NoTypeInformation -Encoding UTF8
        Reset-Observation
        Invoke-Entry delete
        Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -notlike "/subscriptions/$($script:subs[0])/*"}).Count -eq 0) 'CSV部分集合外への書込み0'
        Assert-Cutover ($script:resources.ContainsKey($script:oldCutoverRecords[1].ResourceId)) '他SubのVMSS旧関連を保持'
        Assert-WiredProtected
    }
    Invoke-WiredCase '指定Subの切戻しは他Subの旧・新関連を保持する' {
        Seed-AfterMigration
        foreach($old in $script:oldCutoverRecords){$script:resources.Remove($old.ResourceId)}
        Reset-Observation
        Invoke-Entry rollback -SelectedSubscriptions @($script:subs[1])
        Assert-Cutover ($script:resources.ContainsKey($script:oldCutoverRecords[1].ResourceId)) '選択したVMSS旧関連を復元'
        Assert-Cutover (-not $script:resources.ContainsKey($script:oldCutoverRecords[0].ResourceId)) '選択外旧関連を復元しない'
        Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -notlike "/subscriptions/$($script:subs[1])/*"}).Count -eq 0) '選択外への書込み0'
        Assert-WiredProtected
    }
    foreach($badBackup in @('Version1','OldDcrIds','OldAssociationsNull','ForeignOldDcr','MissingNewParent','DuplicateOld','SameOldNewAssociation')) {
        Invoke-WiredCase "Version2の${badBackup}不正をAzure照会前に拒否" {
            $value=Copy-TestValue $script:savedBackup
            switch($badBackup) {
                'Version1' {$value.Version=1}
                'OldDcrIds' {$value.OldDcrIds=@($script:oldRules[0],$script:oldRules[0])}
                'OldAssociationsNull' {$value.Targets[1].OldAssociations=$null}
                'ForeignOldDcr' {$value.Targets[0].OldAssociations[0].Before.properties.dataCollectionRuleId='/foreign-rule'}
                'MissingNewParent' {$value.Targets[1].Associations=@($value.Targets[1].Associations | Where-Object {-not $_.ResourceId.StartsWith($script:fixtureVmssId+'/')})}
                'DuplicateOld' {$value.Targets[0].OldAssociations+=@($value.Targets[0].OldAssociations[0])}
                'SameOldNewAssociation' {$value.Targets[0].OldAssociations[0].ResourceId=$value.Targets[0].Associations[0].ResourceId}
            }
            Reset-Observation
            Assert-LocalBackupRejected $value
        }
    }
}finally{if(Test-Path -LiteralPath $script:scratch){Remove-Item -LiteralPath $script:scratch -Recurse -Force}}
$result=[pscustomobject]@{Result='PASS';Checks=$script:cutoverChecks+$script:checks;CaseCount=$script:cutoverCases.Count;Cases=$script:cutoverCases;AzureRequests=0;CommonHash=(Get-FileHash (Join-Path $Repository 'log_migration_common.ps1')).Hash;RollbackHash=(Get-FileHash (Join-Path $Repository 'log_migration_rollback.ps1')).Hash}
if($ReportPath){$result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
if($PassThru){$result}else{$result|ConvertTo-Json -Depth 20}
