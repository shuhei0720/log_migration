#Requires -Version 5.1
param([string]$Repository=(Join-Path (Split-Path -Parent $PSScriptRoot) 'migration'),[string]$ReportPath,[switch]$PassThru)
$ErrorActionPreference='Stop'
. (Join-Path $Repository 'common.ps1')
$script:selectionProductionTargets=(Get-Item function:Get-MigrationTargets).ScriptBlock
$script:selectionProductionPlan=(Get-Item function:Get-MigrationPlan).ScriptBlock
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
# --------------------------------------------------
# CSVの作成対象選択を実際の読込関数で確認する
# Azure CLIは対象Sub一覧、HTTPは地域略称だけを返し、設定変更の呼出しを許可しない。
# --------------------------------------------------
& {
    $inputCsvPath=Join-Path ([IO.Path]::GetTempPath()) ('migration-selection-'+[guid]::NewGuid().ToString('N')+'.csv')
    $productionGetTargets=(Get-Item function:Get-MigrationTargets).ScriptBlock
    function Invoke-AzJson {
        param([string[]]$Arguments)
        if(($Arguments -join '/') -ne 'account/list/--all'){throw 'CSV選択試験で想定外のCLI呼出し'}
        foreach($sub in @($script:sub1,$script:sub2)){[pscustomobject]@{id=$sub;name=$sub}}
    }
    function Invoke-RestMethod {
        param([string]$Uri,[int]$TimeoutSec)
        if($Uri -ne $regionNamesUrl){throw 'CSV選択試験で想定外のHTTP呼出し'}
        $script:selectionRegionReads++
        Write-Output -NoEnumerate @([pscustomobject]@{name='japaneast';shortName='jpe'})
    }
    try {
        foreach($diagnosticDestination in @('Storage','Log','None','')) {
            foreach($vmDestination in @('Log','None','')) {
                Invoke-GetterCase "CSV選択 診断[$diagnosticDestination] VM[$vmDestination]" {
                    $script:failures.Clear();$script:verificationResults.Clear();$script:selectionRegionReads=0
                    [pscustomobject][ordered]@{
                        SubscriptionName=$script:sub1;ResourceGroup='rg-target';StorageAccount='stjpetest1'
                        WorkspaceName='log-new1';LogDestination=$diagnosticDestination;VmLogDestination=$vmDestination
                    } | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
                    $parsed=@(& $productionGetTargets)
                    Assert-Cutover ($parsed.Count -eq 1 -and $script:failures.Count -eq 0) '選択値を含むCSVの1行を取得'
                    Assert-Cutover ($parsed[0].SkipDiagnostics -eq ($diagnosticDestination -in @('None',''))) '診断設定の省略指定'
                    Assert-Cutover ($parsed[0].SkipVm -eq ($vmDestination -in @('None',''))) 'VMログの省略指定'
                    Assert-Cutover ($parsed[0].LogDestination -ceq $diagnosticDestination -and $parsed[0].VmLogDestination -ceq $vmDestination) '空欄とNoneを入力どおり保持'
                    Assert-Cutover ($parsed[0].DiagnosticPlans.Count -eq 0 -and $parsed[0].Collectors.Count -eq 0 -and $parsed[0].OldAssociations.Count -eq 0) '対象一覧の初期値は0件'
                    Assert-Cutover ($script:selectionRegionReads -eq 1) 'Storage名があれば送信指定にかかわらず地域略称を取得'
                }
            }
        }
        foreach($legacyDestination in @('Storage','Log','None')) {
            Invoke-GetterCase "旧5列CSV [$legacyDestination]はVMログを有効にする" {
                $script:failures.Clear();$script:verificationResults.Clear();$script:selectionRegionReads=0
                [pscustomobject][ordered]@{
                    SubscriptionName=$script:sub1;ResourceGroup='rg-target';StorageAccount='stjpetest1'
                    WorkspaceName='log-new1';LogDestination=$legacyDestination
                } | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
                $parsed=@(& $productionGetTargets)
                Assert-Cutover ($parsed.Count -eq 1 -and $script:failures.Count -eq 0) '旧CSVをそのまま読める'
                Assert-Cutover (-not $parsed[0].SkipVm -and $parsed[0].VmLogDestination -ceq 'Log') '列省略時はVMログを有効にする'
            }
        }
        foreach($valid in @(
            @{Name='前後空白と大小文字';Destination=' lOg ';Vm=' nOnE ';Group=' rg-target ';Storage='';Workspace=' log-new1 ';SkipDiagnostics=$false;SkipVm=$true},
            @{Name='StorageのみでもWorkspaceを指定';Destination='Storage';Vm='None';Group='rg-target';Storage='stjpetest1';Workspace='log-new1';SkipDiagnostics=$false;SkipVm=$true},
            @{Name='LogのみではStorage不要';Destination='Log';Vm='';Group='rg-target';Storage='';Workspace='log-new1';SkipDiagnostics=$false;SkipVm=$true},
            @{Name='VMのみでも指定Storage名を保持';Destination='None';Vm='Log';Group='rg-target';Storage='stjpetest1';Workspace='log-new1';SkipDiagnostics=$true;SkipVm=$false},
            @{Name='両方省略でも保存先を指定';Destination='';Vm='None';Group='rg-target';Storage='stjpetest1';Workspace='log-new1';SkipDiagnostics=$true;SkipVm=$true}
        )) {
            Invoke-GetterCase "CSV選択 $($valid.Name)" {
                $script:failures.Clear();$script:verificationResults.Clear();$script:selectionRegionReads=0
                [pscustomobject][ordered]@{
                    SubscriptionName=$script:sub1;ResourceGroup=$valid.Group;StorageAccount=$valid.Storage
                    WorkspaceName=$valid.Workspace;LogDestination=$valid.Destination;VmLogDestination=$valid.Vm
                } | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
                $parsed=@(& $productionGetTargets)
                Assert-Cutover ($parsed.Count -eq 1 -and $script:failures.Count -eq 0) '保存先を指定したCSVを受け付ける'
                Assert-Cutover ($parsed[0].SkipDiagnostics -eq $valid.SkipDiagnostics -and $parsed[0].SkipVm -eq $valid.SkipVm) '空白除去後の選択結果'
                Assert-Cutover ($parsed[0].LogDestination -ceq $valid.Destination.Trim() -and $parsed[0].VmLogDestination -ceq $valid.Vm.Trim()) '入力文字列は前後空白だけを除去'
                Assert-Cutover (($script:selectionRegionReads -eq 1) -eq [bool]$valid.Storage) 'Storage欄に名前がある場合だけ地域略称を取得'
            }
        }
        foreach($invalid in @(
            @{Name='不正な診断宛先';Destination='EventHub';Vm='Log';Group='rg-target';Storage='stjpetest1';Workspace='log-new1';Sub=$script:sub1;Reason='LogDestination'},
            @{Name='VMのStorage指定';Destination='Log';Vm='Storage';Group='rg-target';Storage='';Workspace='log-new1';Sub=$script:sub1;Reason='VmLogDestination'},
            @{Name='VMの不正フラグ';Destination='None';Vm='false';Group='rg-target';Storage='';Workspace='log-new1';Sub=$script:sub1;Reason='VmLogDestination'},
            @{Name='Sub空欄';Destination='None';Vm='None';Group='';Storage='';Workspace='';Sub=' ';Reason='SubscriptionName'},
            @{Name='有効側のRG空欄';Destination='None';Vm='Log';Group='';Storage='';Workspace='log-new1';Sub=$script:sub1;Reason='ResourceGroup'},
            @{Name='VM用Workspace空欄';Destination='None';Vm='Log';Group='rg-target';Storage='';Workspace='';Sub=$script:sub1;Reason='WorkspaceName'},
            @{Name='Log診断用Workspace空欄';Destination='Log';Vm='None';Group='rg-target';Storage='';Workspace='';Sub=$script:sub1;Reason='WorkspaceName'},
            @{Name='Storage診断用名前空欄';Destination='Storage';Vm='None';Group='rg-target';Storage='';Workspace='log-new1';Sub=$script:sub1;Reason='StorageAccount'},
            @{Name='両方省略のRG空欄';Destination='None';Vm='None';Group='';Storage='';Workspace='log-new1';Sub=$script:sub1;Reason='ResourceGroup'},
            @{Name='両方省略のWorkspace空欄';Destination='None';Vm='None';Group='rg-target';Storage='';Workspace='';Sub=$script:sub1;Reason='WorkspaceName'},
            @{Name='省略側の不正Storage名';Destination='None';Vm='None';Group='rg-target';Storage='INVALID-NAME';Workspace='log-new1';Sub=$script:sub1;Reason='StorageAccount'},
            @{Name='Log側の不正Storage名';Destination='Log';Vm='Log';Group='rg-target';Storage='INVALID-NAME';Workspace='log-new1';Sub=$script:sub1;Reason='StorageAccount'}
        )) {
            Invoke-GetterCase "CSV選択 $($invalid.Name)を拒否" {
                $script:failures.Clear();$script:verificationResults.Clear();$script:selectionRegionReads=0
                [pscustomobject][ordered]@{
                    SubscriptionName=$invalid.Sub;ResourceGroup=$invalid.Group;StorageAccount=$invalid.Storage
                    WorkspaceName=$invalid.Workspace;LogDestination=$invalid.Destination;VmLogDestination=$invalid.Vm
                } | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
                $parsed=@(& $productionGetTargets)
                Assert-Cutover ($parsed.Count -eq 0 -and $script:failures.Count -eq 1) '入力不正は対象を返さずNGにする'
                Assert-Cutover ($script:failures[0].Reason -match [regex]::Escape($invalid.Reason)) '問題の入力列をNG理由に含める'
                Assert-Cutover ($script:selectionRegionReads -eq 0) '入力不正では地域略称を取得しない'
            }
        }
    }
    finally {
        $script:failures.Clear();$script:verificationResults.Clear()
        if(Test-Path -LiteralPath $inputCsvPath){Remove-Item -LiteralPath $inputCsvPath -Force}
    }
}

# 切り戻しの状態fixtureを再利用し、旧関連の復元順序を確認します。
$oldTokens=$null;$oldErrors=$null
$fixtureAst=[Management.Automation.Language.Parser]::ParseFile((Join-Path $PSScriptRoot 'backup-rollback-smoke.ps1'),[ref]$oldTokens,[ref]$oldErrors)
$firstFunction=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]})[0]
foreach($statement in $fixtureAst.EndBlock.Statements){
    if($statement.Extent.StartOffset -ge $firstFunction.Extent.StartOffset){break}
    Invoke-Expression $statement.Extent.Text
}
$baseArmNode=@($fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst] -and $_.Name -eq 'Invoke-ArmRequest'})[0]
# ASTから読み込むfixture関数にも、このテストのfixtureディレクトリを渡します。
$script:cutoverFixtureRoot=$PSScriptRoot
foreach($statement in $fixtureAst.EndBlock.Statements | Where-Object {$_ -is [Management.Automation.Language.FunctionDefinitionAst]}){
    $fixtureFunction=$statement.Extent.Text.Replace('$PSScriptRoot','$script:cutoverFixtureRoot')
    Invoke-Expression $fixtureFunction
}
$script:baseFixtureArm=[scriptblock]::Create($baseArmNode.Body.Extent.Text.Substring(1,$baseArmNode.Body.Extent.Text.Length-2))
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
        $ast=[Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'common.ps1'),[ref]$tokens,[ref]$parseErrors)
        $node=@($ast.FindAll({param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-MigrationPlan'},$true))[0]
        $productionPlan=[scriptblock]::Create($node.Body.Extent.Text.Substring(1,$node.Body.Extent.Text.Length-2))
        Reset-Observation
        & {
            $script:actualDiscoveryAssociations=@($script:oldCutoverRecords[0],$oldVmss)
            $script:actualAssociationReads=0
            function Get-OldDcrAssociations {
                param([object[]]$Targets,[string[]]$DcrIds)
                if($Targets.Count -ne 1 -or $Targets[0].SubscriptionId -ne $sub){throw '実discoveryは現在のSubだけを調査します。'}
                $script:actualAssociationReads++
                $script:actualDiscoveryAssociations
            }
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
            $script:actualDiscoveryAssociations=@()
            $ready=& $productionPlan -Target $actualTarget
            Assert-Cutover ($ready -and $actualTarget.Collectors.Count -eq 0) '旧関連0ならmachine一覧があっても収集対象0'
            Assert-Cutover ($actualTarget.DiagnosticPlans.Count -eq 1) '旧DCR関連の有無は診断対象へ影響しない'
            Assert-Cutover ($script:actualAssociationReads -eq 2) 'GetPlanごとに現在Subの旧関連を取り直す'
        }
        Assert-NoAzureWrites
        Assert-WiredProtected
    }
    Invoke-WiredCase 'Version3は旧2本・VMSS旧関連を最小保存する' {
        $backup=Read-MigrationBackup -CheckCsv
        Assert-Cutover ($backup.Version -eq 3 -and @($backup.OldDcrIds).Count -eq 2) 'Version3と旧2本のID'
        Assert-Cutover (@($backup.Targets.OldAssociations).Count -eq 2) '旧関連2件だけを保存'
        $vmss=@($backup.Targets[1].Associations | Where-Object {$_.ResourceId.StartsWith($script:fixtureVmssId+'/')})
        Assert-Cutover ($vmss.Count -eq 1) 'VMSSの新関連も保存'
        Assert-Cutover (@($script:lastSetupEvidence.Reads | Where-Object {$_ -in $script:oldCutoverRecords.ResourceId}).Count -eq $script:oldCutoverRecords.Count) '旧関連の詳細GETは選択した各IDだけ1回'
        Assert-Cutover ($script:lastSetupEvidence.BackupWitnesses.Count -eq $script:lastSetupEvidence.Writes.Count -and $script:lastSetupEvidence.Writes.Count -gt 0) '①の全変更より前に実際のBefore保存を確認'
        Assert-Cutover (@($backup.Targets.OldAssociations | Where-Object {$_.PSObject.Properties.Name -contains 'ParentResourceId'}).Count -eq 0) '旧関連の永続化はIDとBeforeだけ'
        Assert-WiredProtected
    }
    Invoke-WiredCase 'Rule一覧が参照IDだけでも完全GETの説明とDCEを保存・復元する' {
        Remove-Item -LiteralPath $migrationBackupPath
        foreach($storage in $script:savedBackup.Targets.Storages){$script:resources.Remove($storage.Id)}
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
        Assert-Cutover (@($script:lastSetupEvidence.Reads | Where-Object {$_ -in $script:oldCutoverRecords.ResourceId}).Count -eq 2) '選択した旧2件だけを完全GET'
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
    Invoke-WiredCase '後続Subの旧関連GET失敗ではそのSubを保存・変更しない' {
        Remove-Item -LiteralPath $migrationBackupPath
        foreach($storage in $script:savedBackup.Targets.Storages){$script:resources.Remove($storage.Id)}
        $missing=$script:oldCutoverRecords[1]
        $script:listedOldAssociationExtras=@($missing)
        $script:resources.Remove($missing.ResourceId)
        Reset-Observation
        $failed=$false
        try{Save-TestBackup}catch{$failed=$true}
        Assert-Cutover $failed '旧一覧にあっても完全GET失敗を無視しない'
        $partial=Read-MigrationBackup
        Assert-Cutover ($partial.Targets.Count -eq 1 -and $partial.Targets[0].SubscriptionId -eq $script:subs[0]) '先行Subの保存を残し、不完全な後続SubのBeforeを保存しない'
        Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -like "/subscriptions/$($script:subs[1])/*"}).Count -eq 0) '失敗した後続Subへの書込み0'
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
        foreach($storage in $script:savedBackup.Targets.Storages){$script:resources.Remove($storage.Id)}
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
        $newVmssAssociation=@($script:savedBackup.Targets[1].Associations | Where-Object {$_.ResourceId.StartsWith($script:fixtureVmssId+'/')})[0].ResourceId
        Assert-Cutover ($newVmssAssociation -in $script:reads) '全件確認でVMSSの新関連を実際にGETする'
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
    Invoke-WiredCase '①再実行は追加旧VMSS関連のBeforeを保存し元のBeforeは維持する' {
        Seed-AfterMigration -KeepOld
        $before=Copy-TestValue $script:savedBackup
        $parent="/subscriptions/$($script:subs[0])/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/added-later"
        $id="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/added-later"
        $oldBody=@{properties=@{description='後から追加した旧関連';dataCollectionRuleId=$script:oldRules[0];dataCollectionEndpointId='/later-dce'}}
        $script:resources[$id]=Copy-TestValue $oldBody
        # ①で追加対象を保存する前の③は、知らない旧関連を削除しません。
        Reset-Observation
        Invoke-Entry delete -ExpectFailure $true
        Assert-NoAzureWrites
        Reset-Observation
        Invoke-Entry copy
        $after=Read-MigrationBackup -CheckCsv
        $continuedTarget=@($after.Targets | Where-Object SubscriptionId -eq $script:subs[0])[0]
        $old=@($continuedTarget.OldAssociations | Where-Object ResourceId -eq $id)
        Assert-Cutover ($old.Count -eq 1 -and (Test-BaselineValues $old[0].Before $oldBody) -and (Test-BaselineValues $oldBody $old[0].Before)) '追加された旧VMSS関連の完全Beforeを保存'
        $newId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new1"
        $association=@($continuedTarget.Associations | Where-Object ResourceId -eq $newId)
        Assert-Cutover ($association.Count -eq 1 -and $null -eq $association[0].Before) '追加VMSSの新関連は作成前の不在を保存'
        Assert-Cutover ($script:resources.ContainsKey($newId) -and @($script:writes | Where-Object {$_.ResourceId -eq $newId -and $_.Method -eq 'Put'}).Count -eq 1) '追加VMSSの新関連だけ作成'
        Assert-Cutover ($script:resources.ContainsKey($id)) '追加元の旧関連を保持'
        Assert-Cutover ($script:writes.Count -eq 1) '保存済み対象を変更せず追加した新VMSS関連の1PUTだけ'
        Assert-Cutover ($after.CreatedAtUtc -ceq $before.CreatedAtUtc) '最初の保存日時を維持'
        foreach($savedTarget in $before.Targets) {
            $continued=@($after.Targets | Where-Object SubscriptionId -eq $savedTarget.SubscriptionId)[0]
            foreach($key in @('Diagnostics','Associations','OldAssociations')) {
                foreach($saved in $savedTarget.$key) {
                    $current=@($continued.$key | Where-Object ResourceId -eq $saved.ResourceId)
                    Assert-Cutover ($current.Count -eq 1 -and (Test-BaselineValues $current[0].Before $saved.Before) -and (Test-BaselineValues $saved.Before $current[0].Before)) "元からある$key のBeforeを変更しない"
                }
            }
            Assert-Cutover ((Test-BaselineValues $continued.Dcr.Before $savedTarget.Dcr.Before) -and (Test-BaselineValues $savedTarget.Dcr.Before $continued.Dcr.Before)) '元のDCRのBeforeを維持'
            foreach($saved in $savedTarget.Exemptions) {
                $current=@($continued.Exemptions | Where-Object ResourceId -eq $saved.ResourceId)
                Assert-Cutover ($current.Count -eq 1 -and $current[0].Existed -ceq $saved.Existed) '既存・新規の適用除外の区別を維持'
            }
        }
        Assert-WiredProtected
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
        Invoke-WiredCase "Version3の${badBackup}不正をAzure照会前に拒否" {
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

    $before=$script:checks+$script:cutoverChecks
    Invoke-TestCase '事前チェック後に増えた旧VMSS関連を①が直前に調査して保存する' {
        $script:oldCutoverRecords=@()
        Invoke-Entry precheck
        Assert-Cutover (-not (Test-Path -LiteralPath $migrationBackupPath)) '事前チェックはBeforeファイルを作らない'
        Assert-NoAzureWrites
        $parent="/subscriptions/$($script:subs[1])/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/created-after-precheck"
        $oldId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-after-precheck"
        $oldBody=@{properties=@{description='事前確認後の旧関連';dataCollectionRuleId=$script:oldRules[1];dataCollectionEndpointId='/after-precheck-dce'}}
        $script:resources[$oldId]=Copy-TestValue $oldBody
        Reset-Observation
        Invoke-Entry copy
        $backup=Read-MigrationBackup -CheckCsv
        $savedTarget=@($backup.Targets | Where-Object SubscriptionId -eq $script:subs[1])[0]
        $saved=@($savedTarget.OldAssociations | Where-Object ResourceId -eq $oldId)
        Assert-Cutover ($backup.Version -eq 3 -and $saved.Count -eq 1) '①自身の再調査で追加した旧VMSS関連を保存'
        Assert-Cutover ((Test-BaselineValues $saved[0].Before $oldBody) -and (Test-BaselineValues $oldBody $saved[0].Before)) '当日の完全な旧関連をBeforeとして保存'
        $newId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new2"
        Assert-Cutover ($script:resources.ContainsKey($newId) -and $script:resources[$newId].properties.dataCollectionRuleId -eq $savedTarget.Dcr.ResourceId) '追加VMSSを新DCRへ関連付ける'
        Assert-Cutover ($script:resources.ContainsKey($oldId)) '当日の旧関連も削除しない'
    }
    $script:cutoverCases.Add([pscustomobject]@{Case='事前チェック後に増えた旧VMSS関連を①が直前に調査して保存する';Result='PASS';Assertions=$script:checks+$script:cutoverChecks-$before})

    $before=$script:checks+$script:cutoverChecks
    Invoke-TestCase '後から収集対象になったSubのDCRは最初に変更する直前のBeforeを保存する' {
        $script:oldCutoverRecords=@()
        $firstSub=$script:subs[0]
        foreach($id in @($script:resources.Keys)) {
            if($id.StartsWith("/subscriptions/$firstSub/") -and $id -match '/dataCollectionRuleAssociations/[^/]+$' -and
                $script:resources[$id].properties.dataCollectionRuleId -in $script:oldRules){$script:resources.Remove($id)}
        }
        $dcrId="/subscriptions/$firstSub/resourceGroups/rg-target/providers/Microsoft.Insights/dataCollectionRules/dcr-new1"
        $initialDcr=Get-RollbackBody $script:resources[$dcrId]
        Invoke-Entry copy
        $first=Read-MigrationBackup -CheckCsv
        $firstTarget=@($first.Targets | Where-Object SubscriptionId -eq $firstSub)[0]
        Assert-Cutover ($null -eq $firstTarget.Dcr -and $firstTarget.Associations.Count -eq 0) '旧関連のない初回はDCRと新関連を保存対象にしない'
        Assert-Cutover (@($script:writes | Where-Object ResourceId -eq $dcrId).Count -eq 0 -and
            (Test-BaselineValues (Get-RollbackBody $script:resources[$dcrId]) $initialDcr) -and
            (Test-BaselineValues $initialDcr (Get-RollbackBody $script:resources[$dcrId]))) '初回は同名の既存DCRを変更しない'
        $script:resources[$dcrId] | Add-Member tags ([pscustomobject]@{owner='first-touch-current'}) -Force
        $firstTouchBefore=Get-RollbackBody $script:resources[$dcrId]
        $parent="/subscriptions/$firstSub/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/newly-eligible"
        $oldId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-newly-eligible"
        $script:resources[$oldId]=Copy-TestValue @{properties=@{description='後から対象になった関連';dataCollectionRuleId=$script:oldRules[0]}}
        Reset-Observation
        Invoke-Entry copy
        $second=Read-MigrationBackup -CheckCsv
        $saved=@($second.Targets | Where-Object SubscriptionId -eq $firstSub)[0]
        Assert-Cutover ($saved.Dcr.ResourceId -eq $dcrId -and (Test-BaselineValues $saved.Dcr.Before $firstTouchBefore) -and (Test-BaselineValues $firstTouchBefore $saved.Dcr.Before)) '対象になる前の古い状態ではなく、初めて変更する時点のDCR全体を保存'
        Assert-Cutover ($saved.Dcr.Before.tags.owner -eq 'first-touch-current') '初回①より後の変更もBeforeに含める'
        $newId="$parent/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new1"
        Assert-Cutover (@($saved.Associations | Where-Object {$_.ResourceId -eq $newId -and $null -eq $_.Before}).Count -eq 1 -and $script:resources.ContainsKey($newId)) '新しい収集対象だけ新関連の不在Beforeを保存して作成'
        foreach($diagnostic in $firstTarget.Diagnostics) {
            $continued=@($saved.Diagnostics | Where-Object ResourceId -eq $diagnostic.ResourceId)[0]
            Assert-Cutover ((Get-DiagnosticSignature $continued.Before) -ceq (Get-DiagnosticSignature $diagnostic.Before)) '最初から保存した旧診断のBeforeは維持'
        }
        $savedDcrBefore=Copy-TestValue $saved.Dcr.Before
        Reset-Observation
        Invoke-Entry copy
        $third=Read-MigrationBackup -CheckCsv
        $thirdTarget=@($third.Targets | Where-Object SubscriptionId -eq $firstSub)[0]
        Assert-Cutover ((Test-BaselineValues $thirdTarget.Dcr.Before $savedDcrBefore) -and (Test-BaselineValues $savedDcrBefore $thirdTarget.Dcr.Before)) '次の再実行でも最初のDCR Beforeを上書きしない'
        Assert-NoAzureWrites
    }
    $script:cutoverCases.Add([pscustomobject]@{Case='後から収集対象になったSubのDCRは最初に変更する直前のBeforeを保存する';Result='PASS';Assertions=$script:checks+$script:cutoverChecks-$before})
    # --------------------------------------------------
    # CSVの選択を実際の探索と各工程へ通す
    # 外部通信だけを状態fixtureへ置き換え、作成・確認・削除・切戻しは本体を実行する。
    # --------------------------------------------------
    & {
        $script:selectionFixtureCli=(Get-Item function:Invoke-AzJson).ScriptBlock
        $script:selectionFixtureArm=(Get-Item function:Invoke-ArmRequest).ScriptBlock
        function Invoke-AzJson {
            param([string[]]$Arguments)
            if(($Arguments -join '/') -eq 'account/list/--all') {
                foreach($sub in $script:subs){[pscustomobject]@{id=$sub;name=$sub}}
                return
            }
            if($Arguments[0] -eq 'resource' -and $Arguments[1] -eq 'list') {
                $sub=$Arguments[[array]::IndexOf($Arguments,'--subscription')+1]
                foreach($id in @($script:diagnostics.Keys | Sort-Object)) {
                    if($id.StartsWith("/subscriptions/$sub/")){[pscustomobject]@{id=$id;type='Microsoft.Test/widgets';location=$script:selectionResourceLocation}}
                }
                return
            }
            if(($Arguments[0..2] -join '/') -eq 'storage/sku/list') {
                return [pscustomobject]@{name='Standard_ZRS';kind='StorageV2';locations=@('japaneast','japanwest','canadacentral')}
            }
            if(($Arguments[0..3] -join '/') -eq 'monitor/log-analytics/workspace/create') {
                $sub=$Arguments[[array]::IndexOf($Arguments,'--subscription')+1]
                $group=$Arguments[[array]::IndexOf($Arguments,'--resource-group')+1]
                $name=$Arguments[[array]::IndexOf($Arguments,'--workspace-name')+1]
                $resourceId="/subscriptions/$sub/resourceGroups/$group/providers/Microsoft.OperationalInsights/workspaces/$name"
                if(-not $script:selectionDestinationTemplates.ContainsKey($resourceId)){throw "未知のLA作成: $resourceId"}
                $script:writes.Add([pscustomobject]@{ResourceId=$resourceId;Method='Create';Body=$null})
                Assert-BackupBeforeWrite -ResourceId $resourceId
                $script:resources[$resourceId]=Copy-TestValue $script:selectionDestinationTemplates[$resourceId]
                return Copy-TestValue $script:resources[$resourceId]
            }
            & $script:selectionFixtureCli @PSBoundParameters
        }
        function Invoke-RestMethod {
            param([string]$Uri,[int]$TimeoutSec)
            if($Uri -ne $regionNamesUrl){throw '選択工程試験で想定外のHTTP呼出し'}
            Write-Output -NoEnumerate @([pscustomobject]@{name='japaneast';shortName='jpe'},[pscustomobject]@{name='canadacentral';shortName='cac'})
        }
        function Invoke-ArmRequest {
            param([string]$ResourceId,[string]$Method='Get',[object]$Body,[string]$ApiVersion)
            if($Method -eq 'Get' -and $ResourceId -match '^(.+/dataCollectionRules/[^/]+)/associations$') {
                $ruleId=$Matches[1];$script:reads.Add($ResourceId)
                return [pscustomobject]@{value=@(
                    foreach($id in @($script:resources.Keys | Sort-Object)) {
                        if($id -match '/dataCollectionRuleAssociations/[^/]+$' -and $script:resources[$id].properties.dataCollectionRuleId -eq $ruleId) {
                            [pscustomobject]@{id=$id;properties=(Copy-TestValue $script:resources[$id].properties)}
                        }
                    }
                )}
            }
            if($Method -ne 'Get' -and $script:selectionDestinationTemplates.ContainsKey($ResourceId)) {
                if($Method -notin @('Put','Patch')){throw '保存先の削除は許可しない'}
                $script:writes.Add([pscustomobject]@{ResourceId=$ResourceId;Method=$Method;Body=(Copy-TestValue $Body)})
                Assert-BackupBeforeWrite -ResourceId $ResourceId
                $resource=if($script:resources.ContainsKey($ResourceId)){Copy-TestValue $script:resources[$ResourceId]}else{Copy-TestValue $script:selectionDestinationTemplates[$ResourceId]}
                $bodyCopy=Copy-TestValue $Body
                foreach($property in $bodyCopy.PSObject.Properties) {
                    if($property.Name -eq 'properties') {
                        foreach($value in $property.Value.PSObject.Properties){$resource.properties | Add-Member $value.Name $value.Value -Force}
                    } else {$resource | Add-Member $property.Name $property.Value -Force}
                }
                if($ResourceId -match '/tables/[^/]+$'){$resource.properties | Add-Member provisioningState 'Succeeded' -Force}
                $script:resources[$ResourceId]=$resource
                return Copy-TestValue $resource
            }
            if($Method -ne 'Get' -and $ResourceId -in $script:selectionProtectedVmBefore.Keys){$script:selectionProtectedVmWrites.Add($ResourceId)}
            & $script:selectionFixtureArm @PSBoundParameters
        }
        function Get-MigrationTargets {
            $script:targetReads++
            & $script:selectionProductionTargets
        }
        function Get-MigrationPlan {
            param([object]$Target)
            # 変更直前のfixture状態は、既存のBefore保存監視へ渡すためだけに記録する。
            $beforeResources=@{};$beforeDiagnostics=@{}
            foreach($id in $script:resources.Keys){$beforeResources[$id]=Copy-TestValue $script:resources[$id]}
            foreach($id in $script:diagnostics.Keys){$beforeDiagnostics[$id]=@{};foreach($name in $script:diagnostics[$id].Keys){$beforeDiagnostics[$id][$name]=Copy-TestValue $script:diagnostics[$id][$name]}}
            $script:beforePlanState[$Target.SubscriptionId]=@{Resources=$beforeResources;Diagnostics=$beforeDiagnostics}
            & $script:selectionProductionPlan -Target $Target
        }
        function Invoke-SelectionCopy {
            param([bool]$ExpectFailure=$false)
            Invoke-Entry copy -ExpectFailure $ExpectFailure
            # DELETE時の復元順序監視にも、このケースで保存したBeforeを使う。
            $script:savedBackup=Read-MigrationBackup -Path $migrationBackupPath
        }
        function Write-SelectionCsv {
            $script:selectionRows | Export-Csv -LiteralPath $inputCsvPath -NoTypeInformation -Encoding UTF8
        }
        function Invoke-SelectionCase {
            param([string]$Name,[scriptblock]$Body)
            $before=$script:checks+$script:cutoverChecks
            Invoke-TestCase $Name {
                $script:oldCutoverRecords=@()
                $script:selectionResourceLocation='japaneast'
                # 2つ目のSubはVMSSとし、VMとVMSSを同じ選択で処理する。
                foreach($id in @($script:resources.Keys)) {
                    if($id.StartsWith("/subscriptions/$($script:subs[1])/") -and $id -match '/dataCollectionRuleAssociations/[^/]+$' -and $script:resources[$id].properties.dataCollectionRuleId -in $oldDcrIds){$script:resources.Remove($id)}
                }
                $vmssId="/subscriptions/$($script:subs[1])/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/selected-vmss"
                $script:resources["$vmssId/providers/Microsoft.Insights/dataCollectionRuleAssociations/old-vmss"]=Copy-TestValue @{properties=@{description='VMSSの旧関連';dataCollectionRuleId=$oldDcrIds[1]}}
                $script:selectionOldAssociationIds=@($script:resources.Keys | Where-Object {$_ -match '/dataCollectionRuleAssociations/[^/]+$' -and $script:resources[$_].properties.dataCollectionRuleId -in $oldDcrIds})
                $script:selectionDestinationTemplates=@{}
                foreach($id in $script:resources.Keys) {
                    if($id -match '/providers/Microsoft.OperationalInsights/workspaces/[^/]+(/tables/(Event|Syslog))?$') {
                        $script:selectionDestinationTemplates[$id]=Copy-TestValue $script:resources[$id]
                    }
                }
                $script:selectionProtectedVmBefore=@{}
                $script:selectionProtectedVmWrites=[Collections.Generic.List[string]]::new()
                foreach($id in $script:resources.Keys) {
                    if($id -match '/(dataCollectionRules|dataCollectionRuleAssociations)/[^/]+$' -and $id -notin $script:selectionOldAssociationIds) {
                        $script:selectionProtectedVmBefore[$id]=ConvertTo-Json -InputObject $script:resources[$id] -Depth 40 -Compress
                    }
                }
                $script:selectionRows=@(foreach($target in $script:targets){[pscustomobject][ordered]@{
                    SubscriptionName=$target.SubscriptionName;ResourceGroup=$target.ResourceGroup;StorageAccount=$target.StorageAccount
                    WorkspaceName=$target.WorkspaceName;LogDestination='Storage';VmLogDestination='Log'
                }})
                & $Body
            }
            $script:cutoverCases.Add([pscustomobject]@{Case=$Name;Result='PASS';Assertions=$script:checks+$script:cutoverChecks-$before})
        }
        foreach($mode in @(
            @{Name='StorageとVM';Diagnostic='Storage';Vm='Log'},
            @{Name='LogとVM';Diagnostic='Log';Vm='Log'},
            @{Name='Storageのみ';Diagnostic='Storage';Vm='None'},
            @{Name='Logのみ';Diagnostic='Log';Vm=''},
            @{Name='VMのみ';Diagnostic='None';Vm='Log'},
            @{Name='両方None';Diagnostic='None';Vm='None'},
            @{Name='両方空欄';Diagnostic='';Vm=''}
        )) {
            Invoke-SelectionCase "送信先選択 $($mode.Name)の全工程と再実行" {
                $skipDiagnostics=$mode.Diagnostic -in @('None','');$skipVm=$mode.Vm -in @('None','')
                foreach($row in $script:selectionRows) {
                    $row.LogDestination=$mode.Diagnostic;$row.VmLogDestination=$mode.Vm
                }
                foreach($target in $script:targets) {
                    $script:resources.Remove($target.WorkspaceId)
                    foreach($table in @('Event','Syslog')){$script:resources.Remove("$($target.WorkspaceId)/tables/$table")}
                }
                Write-SelectionCsv
                Invoke-SelectionCopy
                $saved=Read-MigrationBackup -CheckCsv
                Assert-Cutover ($saved.Targets.Count -eq 2 -and @($saved.Targets.Diagnostics).Count -eq 4) '省略側も旧診断設定のBeforeを保存'
                Assert-Cutover (@($saved.Targets.OldAssociations).Count -eq $script:selectionOldAssociationIds.Count) '省略側も旧VM・VMSS関連のBeforeを保存'
                foreach($target in $saved.Targets) {
                    Assert-Cutover ($target.Routing.VmLogDestination -ceq $mode.Vm) 'VM側の選択をRoutingへ保存'
                    $savedGroupId="/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.Routing.ResourceGroup)"
                    Assert-Cutover ($script:reads.Contains($savedGroupId)) '送信指定にかかわらず保存先RGを確認'
                    Assert-Cutover ($target.Storages.Count -eq 1 -and $script:resources.ContainsKey($target.Storages[0].Id)) '送信指定にかかわらず指定Storageを準備'
                    $savedWorkspaceId="/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.Routing.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.Routing.WorkspaceName)"
                    Assert-Cutover ($script:resources.ContainsKey($savedWorkspaceId)) '送信指定にかかわらず未作成LAを準備'
                    foreach($table in @('Event','Syslog')) {
                        Assert-Cutover ($script:resources["$savedWorkspaceId/tables/$table"].properties.totalRetentionInDays -eq 1095) '旧VM対象の送信を省略してもログテーブルと3年保持を準備'
                    }
                    Assert-Cutover (@($target.Diagnostics | Where-Object {$null -ne $_.After}).Count -eq $(if($skipDiagnostics){0}else{2})) '診断設定の作成予定は有効側だけ'
                    Assert-Cutover (($null -eq $target.Dcr) -eq $skipVm) '新DCRの作成予定は有効側だけ'
                    Assert-Cutover ($target.Associations.Count -eq $(if($skipVm){0}else{@($target.OldAssociations | ForEach-Object {$_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$',''} | Select-Object -Unique).Count})) '新関連の作成予定は有効側だけ'
                }
                $newDiagnosticCount=@(foreach($id in $script:diagnostics.Keys){if($script:diagnostics[$id].ContainsKey($newDiagnosticSettingName)){$id}}).Count
                Assert-Cutover ($newDiagnosticCount -eq $(if($skipDiagnostics){0}else{4})) '新診断設定を有効側だけに作成'
                if($skipVm){Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -match '/(dataCollectionRules|dataCollectionRuleAssociations)/'}).Count -eq 0) 'VM省略時は新DCR・関連を書き込まない'}
                Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Create' -and $_.ResourceId -match '/storageAccounts/'}).Count -eq 2) '省略側を含む2Subの指定Storageを作成'
                Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Create' -and $_.ResourceId -match '/workspaces/[^/]+$'}).Count -eq 2) '省略側を含む2Subの未作成LAを作成'
                Assert-Cutover (@($script:providerReads | Where-Object Namespace -eq 'Microsoft.OperationalInsights').Count -ge 2) '全送信指定で保存先のプロバイダーを確認'
                $beforeHash=(Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash
                Reset-Observation;Invoke-SelectionCopy
                Assert-NoAzureWrites
                Assert-Cutover ((Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash -ceq $beforeHash) 'コピー再実行でもBeforeファイル不変'
                Reset-Observation;Invoke-Entry verify
                Assert-NoAzureWrites
                Reset-Observation;Invoke-Entry delete
                foreach($id in $script:diagnostics.Keys){Assert-Cutover (-not $script:diagnostics[$id].ContainsKey('old')) '新規作成を省略した側も旧診断設定を削除'}
                foreach($id in $script:selectionOldAssociationIds){Assert-Cutover (-not $script:resources.ContainsKey($id)) '新規作成を省略したVM・VMSSの旧関連も削除'}
                Reset-Observation;Invoke-Entry verify
                Assert-NoAzureWrites
                Reset-Observation;Invoke-Entry delete
                Assert-NoAzureWrites
                Reset-Observation;Invoke-Entry rollback
                foreach($id in $script:diagnostics.Keys){Assert-Cutover ((Get-DiagnosticSignature $script:diagnostics[$id].old) -ceq $script:originalDiagnostics[$id]) '旧診断設定を元の収集条件・全送信先へ復元'}
                foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) '旧VM・VMSS関連を復元'}
                Assert-Cutover (-not $script:unsafeNewDelete) '旧復元完了前に新設定を削除しない'
                foreach($target in $saved.Targets) {
                    Assert-Cutover ($script:resources.ContainsKey($target.Storages[0].Id)) '切戻しでも準備したStorageを保持'
                    $savedWorkspaceId="/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.Routing.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.Routing.WorkspaceName)"
                    Assert-Cutover ($script:resources.ContainsKey($savedWorkspaceId)) '切戻しでも準備したLAを保持'
                }
                if($skipVm) {
                    Assert-Cutover ($script:selectionProtectedVmWrites.Count -eq 0) '全工程で同名DCR・新関連への変更試行0'
                    foreach($id in $script:selectionProtectedVmBefore.Keys) {
                        Assert-Cutover ((ConvertTo-Json -InputObject $script:resources[$id] -Depth 40 -Compress) -ceq $script:selectionProtectedVmBefore[$id]) 'VM省略時は既存DCR・同名新関連の内容を全工程で保持'
                    }
                }
                Reset-Observation;Invoke-Entry rollback
                Assert-NoAzureWrites
            }
        }
        Invoke-SelectionCase 'Canadaのみの旧設定を全削除しても確認と削除再実行でJPEを要求しない' {
            $script:selectionResourceLocation='canadacentral'
            foreach($row in $script:selectionRows){$row.VmLogDestination='None'}
            foreach($row in $script:selectionRows) {
                $oldName=$row.StorageAccount;$newName=$oldName.Replace('jpe','cac')
                $oldId="/subscriptions/$($row.SubscriptionName)/resourceGroups/$($row.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$oldName"
                $newId=$oldId.Replace($oldName,$newName)
                $template=Copy-TestValue $script:storageTemplatesByName[$oldName]
                $template.id=$newId;$template.location='canadacentral'
                $script:storageTemplatesByName[$newName]=$template
                foreach($id in @($script:resources.Keys | Where-Object {$_.StartsWith($oldId+'/')})) {
                    $resource=Copy-TestValue $script:resources[$id]
                    $newChildId=$id.Replace($oldId,$newId)
                    if($resource.id){$resource.id=$newChildId}
                    $script:resources[$newChildId]=$resource
                    $script:resources.Remove($id)
                }
            }
            Write-SelectionCsv;Invoke-SelectionCopy
            $saved=Read-MigrationBackup -CheckCsv
            foreach($target in $saved.Targets){Assert-Cutover ($target.Storages.Count -eq 1 -and $target.Storages[0].Location -eq 'canadacentral') '初回の保存先はCanadaだけ'}
            Reset-Observation;Invoke-Entry delete
            foreach($id in $script:diagnostics.Keys){Assert-Cutover (-not $script:diagnostics[$id].ContainsKey('old')) '旧診断設定は全て削除済み'}
            foreach($step in @('verify','delete')) {
                Reset-Observation;Invoke-Entry $step
                Assert-NoAzureWrites
                Assert-Cutover (@($script:reads | Where-Object {$_ -match '/storageAccounts/stjpetest[12](/|$)'}).Count -eq 0) '削除後の確認は記録済みCanadaだけを使いJPEへ照会しない'
            }
            Reset-Observation;Invoke-Entry rollback
            foreach($id in $script:diagnostics.Keys){Assert-Cutover ((Get-DiagnosticSignature $script:diagnostics[$id].old) -ceq $script:originalDiagnostics[$id]) 'Canadaの旧診断を元どおり復元'}
        }
        Invoke-SelectionCase '旧診断対象0件でも指定Storageを東日本へ準備する' {
            foreach($row in $script:selectionRows){$row.LogDestination='None';$row.VmLogDestination='None'}
            $script:diagnostics.Clear()
            Write-SelectionCsv;Invoke-SelectionCopy
            $saved=Read-MigrationBackup -CheckCsv
            foreach($target in $saved.Targets) {
                Assert-Cutover ($target.Diagnostics.Count -eq 0 -and $target.Storages.Count -eq 1 -and $target.Storages[0].Location -eq 'japaneast') '旧診断0件でも東日本の指定Storageを保存・準備'
                Assert-Cutover ($script:resources.ContainsKey($target.Storages[0].Id)) '指定したStorageを実際に作成'
            }
            Reset-Observation;Invoke-Entry verify
            Assert-NoAzureWrites
            Reset-Observation;Invoke-Entry delete
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover (-not $script:resources.ContainsKey($id)) '旧VM関連は通常どおり削除'}
            Reset-Observation;Invoke-Entry rollback
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) '旧VM関連は通常どおり復元'}
            foreach($target in $saved.Targets){Assert-Cutover ($script:resources.ContainsKey($target.Storages[0].Id)) '切戻しでも保存先は保持'}
        }
        Invoke-SelectionCase '両方省略は同名新診断と5件上限に触れず旧設定だけを削除・復元する' {
            foreach($row in $script:selectionRows){$row.LogDestination='None';$row.VmLogDestination='None'}
            foreach($id in @($script:diagnostics.Keys)) {
                foreach($name in @($newDiagnosticSettingName,'keep-2','keep-3')){Add-Setting $id $name @{workspaceId='/unrelated-workspace';logs=@();metrics=@()}}
            }
            Write-SelectionCsv
            Invoke-Entry precheck
            Assert-NoAzureWrites
            Invoke-SelectionCopy
            foreach($step in @('verify','delete','rollback')){Reset-Observation;Invoke-Entry $step}
            foreach($id in $script:diagnostics.Keys) {
                Assert-Cutover ($script:diagnostics[$id].Count -eq 5 -and $script:diagnostics[$id][$newDiagnosticSettingName].workspaceId -eq '/unrelated-workspace') '同名新設定を含む指定外4設定を保持'
            }
            Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 0) 'After=nullの同名新設定は切戻しでも削除しない'
        }
        Invoke-SelectionCase '両方省略なら旧診断名が新診断名と同じでも旧設定として削除・復元する' {
            foreach($row in $script:selectionRows){$row.LogDestination='None';$row.VmLogDestination='None'}
            foreach($id in @($script:diagnostics.Keys)) {
                Add-Setting $id $newDiagnosticSettingName $script:diagnostics[$id].old
                $script:diagnostics[$id].Remove('old')
            }
            Write-SelectionCsv
            Invoke-Entry precheck
            Assert-NoAzureWrites
            Invoke-SelectionCopy
            foreach($saved in $script:savedBackup.Targets.Diagnostics){Assert-Cutover ($saved.OldName -ceq $newDiagnosticSettingName -and $null -eq $saved.After) '同名設定を旧設定のBeforeとして保存し新設定を計画しない'}
            Reset-Observation;Invoke-Entry verify
            Assert-NoAzureWrites
            Reset-Observation;Invoke-Entry delete
            foreach($id in $script:diagnostics.Keys){Assert-Cutover (-not $script:diagnostics[$id].ContainsKey($newDiagnosticSettingName)) '旧設定と判定した同名診断を削除'}
            Reset-Observation;Invoke-Entry rollback
            foreach($id in $script:diagnostics.Keys){Assert-Cutover ((Get-DiagnosticSignature $script:diagnostics[$id][$newDiagnosticSettingName]) -ceq $script:originalDiagnostics[$id]) '切戻しで同名の旧診断を完全復元'}
            Assert-Cutover (@($script:writes | Where-Object {$_.Method -eq 'Delete' -and $_.ResourceId -like "*/diagnosticSettings/$newDiagnosticSettingName"}).Count -eq 0) '復元した旧診断を新設定扱いで再削除しない'
        }
        foreach($changedStep in @('copy','verify','delete')) {
            Invoke-SelectionCase "作業途中のVM選択変更は${changedStep}の変更前に停止" {
                Write-SelectionCsv;Invoke-SelectionCopy
                $beforeHash=(Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash
                $script:selectionRows[1].VmLogDestination='None';Write-SelectionCsv
                Reset-Observation;Invoke-Entry $changedStep -ExpectFailure $true
                Assert-NoAzureWrites
                Assert-Cutover ((Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash -ceq $beforeHash) '選択変更を拒否した際も元Beforeを保持'
            }
        }
        Invoke-SelectionCase '別選択のコピー途中失敗から有効側の不足だけを再開する' {
            $script:selectionRows[0].VmLogDestination='None'
            $script:selectionRows[1].LogDestination='None';$script:selectionRows[1].StorageAccount=''
            Write-SelectionCsv
            $newId="/subscriptions/$($script:subs[1])/resourceGroups/source/providers/Microsoft.Compute/virtualMachineScaleSets/selected-vmss/providers/Microsoft.Insights/dataCollectionRuleAssociations/dcr-new2"
            $script:failedPut=$newId
            Invoke-SelectionCopy -ExpectFailure $true
            $beforeHash=(Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash
            foreach($id in $script:diagnostics.Keys){Assert-Cutover ($script:diagnostics[$id].ContainsKey('old')) 'コピー途中失敗では旧診断を全て保持'}
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) 'コピー途中失敗では旧関連を全て保持'}
            Reset-Observation;Invoke-SelectionCopy
            Assert-Cutover ($script:writes.Count -eq 1 -and $script:writes[0].ResourceId -eq $newId) '不足する新VMSS関連だけを補完'
            Assert-Cutover ((Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash -ceq $beforeHash) '再開でも最初のBeforeを維持'
            Reset-Observation;Invoke-Entry verify
            Assert-NoAzureWrites
            Reset-Observation;Invoke-Entry delete
            Reset-Observation;Invoke-Entry rollback
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) '再開後の削除・切戻しで旧関連を復元'}
        }
        Invoke-SelectionCase '両方省略の旧関連削除失敗を再実行し元へ戻せる' {
            foreach($row in $script:selectionRows){$row.LogDestination='None';$row.VmLogDestination='None'}
            Write-SelectionCsv;Invoke-SelectionCopy
            Reset-Observation;$script:failedDelete=$script:selectionOldAssociationIds[1]
            Invoke-Entry delete -ExpectFailure $true
            foreach($id in $script:diagnostics.Keys){Assert-Cutover ($script:diagnostics[$id].ContainsKey('old')) '旧関連の削除失敗では旧診断を全て保持'}
            Reset-Observation;Invoke-Entry delete
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover (-not $script:resources.ContainsKey($id)) '再実行で残りの旧関連を削除'}
            foreach($id in $script:diagnostics.Keys){Assert-Cutover (-not $script:diagnostics[$id].ContainsKey('old')) '再実行で旧診断も削除'}
            Reset-Observation;Invoke-Entry rollback
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) '省略側の削除途中からも旧関連を復元'}
            foreach($id in $script:diagnostics.Keys){Assert-Cutover ((Get-DiagnosticSignature $script:diagnostics[$id].old) -ceq $script:originalDiagnostics[$id]) '省略側の削除途中からも旧診断を完全復元'}
        }
        Invoke-SelectionCase '2Subの別選択と指定Subの切戻しは交差しない' {
            $script:selectionRows[0].VmLogDestination='None'
            $script:selectionRows[1].LogDestination='None';$script:selectionRows[1].StorageAccount=''
            Write-SelectionCsv;Invoke-SelectionCopy
            $saved=Read-MigrationBackup -CheckCsv
            $first=@($saved.Targets | Where-Object SubscriptionId -eq $script:subs[0])[0]
            $second=@($saved.Targets | Where-Object SubscriptionId -eq $script:subs[1])[0]
            Assert-Cutover ($first.Associations.Count -eq 0 -and @($first.Diagnostics | Where-Object {$null -ne $_.After}).Count -eq 2) '先行Subは診断設定だけを作成'
            Assert-Cutover ($second.Associations.Count -eq 1 -and @($second.Diagnostics | Where-Object {$null -ne $_.After}).Count -eq 0) '後続SubはVMSS関連だけを作成'
            Reset-Observation;Invoke-Entry delete
            Reset-Observation;Invoke-Entry rollback -SelectedSubscriptions @($script:subs[0])
            foreach($id in $script:diagnostics.Keys | Where-Object {$_.StartsWith("/subscriptions/$($script:subs[0])/")}){Assert-Cutover ($script:diagnostics[$id].ContainsKey('old') -and -not $script:diagnostics[$id].ContainsKey($newDiagnosticSettingName)) '指定Subの旧診断だけを復元'}
            foreach($id in $script:diagnostics.Keys | Where-Object {$_.StartsWith("/subscriptions/$($script:subs[1])/")}){Assert-Cutover (-not $script:diagnostics[$id].ContainsKey('old')) '指定外Subの旧診断は復元しない'}
            Assert-Cutover ($script:resources.ContainsKey($second.Associations[0].ResourceId)) '指定外Subの新VMSS関連を保持'
            Assert-Cutover (@($script:writes | Where-Object {$_.ResourceId.StartsWith("/subscriptions/$($script:subs[1])/")}).Count -eq 0) '指定外Subへの書込み0'
            Reset-Observation;Invoke-Entry rollback -SelectedSubscriptions @($script:subs[1])
            foreach($id in $script:selectionOldAssociationIds){Assert-Cutover ($script:resources.ContainsKey($id)) '残りSubの旧関連も復元できる'}
        }
    }
}finally{if(Test-Path -LiteralPath $script:scratch){Remove-Item -LiteralPath $script:scratch -Recurse -Force}}
$result=[pscustomobject]@{Result='PASS';Checks=$script:cutoverChecks+$script:checks;CaseCount=$script:cutoverCases.Count;Cases=$script:cutoverCases;AzureRequests=0;CommonHash=(Get-FileHash (Join-Path $Repository 'common.ps1')).Hash;RollbackHash=(Get-FileHash (Join-Path $Repository 'rollback.ps1')).Hash}
if($ReportPath){$result|ConvertTo-Json -Depth 20|Set-Content -LiteralPath $ReportPath -Encoding UTF8}
if($PassThru){$result}else{$result|ConvertTo-Json -Depth 20}
