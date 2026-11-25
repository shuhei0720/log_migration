#Requires -Version 7.0
param(
    [Parameter(Mandatory)][string]$Repository,
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'
$script:checks = 0
$script:azureRequests = 0
$script:regionRequests = 0
$results = [Collections.Generic.List[object]]::new()

function Assert-Contract {
    param([bool]$Condition, [string]$Message)
    $script:checks++
    if (-not $Condition) {
        throw "契約の確認に失敗しました: $Message"
    }
    $results.Add(@{ Check = $Message; Result = 'PASS' })
}

# ---
# 外部通信は禁止する。地域略称の取得だけ、固定の試験データを返す。
# ---
function az {
    $script:azureRequests++
    throw '試験中にAzure CLIが呼ばれました。'
}
function Invoke-WebRequest {
    $script:azureRequests++
    throw '試験中にAzure APIが呼ばれました。'
}
function Invoke-RestMethod {
    param($Uri)
    if ($Uri -ne 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json') {
        $script:azureRequests++
        throw "想定外の通信です: $Uri"
    }
    $script:regionRequests++
    # Invoke-RestMethodがJSON配列を一つの応答として返す形を再現する。
    return ,@(@{ name = 'japaneast'; shortName = 'jpe' }, @{ name = 'japanwest'; shortName = 'jpw' })
}
. (Join-Path $Repository 'common.ps1')
Assert-Contract ($script:azureRequests -eq 0 -and $script:regionRequests -eq 0) '共通定義の読込みでは外部通信しない'

# ---
# 旧診断設定を記録用に変換しても、受け取った調査結果は変更しない。
# ---
$diagnostics = @(@{
    ResourceId = '/subscriptions/source/resourceGroups/source/providers/Microsoft.Test/widgets/item'
    Location = 'global'
    Sources = @(@{
        name = 'old'
        properties = @{
            workspaceId = '/source-workspace'
            logs = @(@{ category = 'Audit'; enabled = $true })
            metrics = @(@{ category = 'AllMetrics'; enabled = $false })
        }
    })
})
$before = ConvertTo-Json $diagnostics -Depth 40 -Compress
$oldSettings = @(Get-OldDiagnosticSettings -Diagnostics $diagnostics)
Assert-Contract ((ConvertTo-Json $diagnostics -Depth 40 -Compress) -ceq $before) '旧診断設定の変換で入力の調査結果を変更しない'
Assert-Contract ($oldSettings.Count -eq 1 -and $oldSettings[0].Body.properties.workspaceId -eq '/source-workspace') '旧診断設定の送信先を記録に残す'
Assert-Contract ($oldSettings[0].Body.properties.logs[0].enabled -and -not $oldSettings[0].Body.properties.metrics[0].enabled) '旧診断設定のログとメトリックを記録に残す'

# ---
# 更新本文の作成では、現在値をそのまま残し、送信するコピーだけを変える。
# ---
$storage = @{
    Id = '/storage'
    Kind = 'Storage'
    Body = @{
        location = $location
        kind = 'StorageV2'
        sku = @{ name = 'Standard_ZRS' }
        properties = @{
            encryption = @{ requireInfrastructureEncryption = $true }
            immutableStorageWithVersioning = @{ enabled = $true }
            publicNetworkAccess = 'Disabled'
            networkAcls = @{ defaultAction = 'Deny'; bypass = 'AzureServices' }
        }
    }
}
$current = ConvertTo-Json $storage.Body -Depth 40 | ConvertFrom-Json -AsHashtable
$current.properties.networkAcls = @{
    defaultAction = 'Allow'
    bypass = 'None'
    ipRules = @(@{ value = '203.0.113.1' })
    virtualNetworkRules = @(@{ id = '/existing-subnet' })
}
$before = ConvertTo-Json @($storage, $current) -Depth 40 -Compress
$update = New-ResourceUpdate -Resource $storage -Current $current
Assert-Contract ((ConvertTo-Json @($storage, $current) -Depth 40 -Compress) -ceq $before) 'Storage更新本文の作成で現在値と予定値を変更しない'
Assert-Contract ($update.Body.properties.networkAcls.defaultAction -eq 'Deny' -and $update.Body.properties.networkAcls.bypass -eq 'AzureServices') '送信するStorage本文に通信制限を設定する'
Assert-Contract ($update.Body.properties.networkAcls.ipRules[0].value -eq '203.0.113.1' -and $update.Body.properties.networkAcls.virtualNetworkRules[0].id -eq '/existing-subnet') 'Storageの既存IP・VNet規則を引き継ぐ'

$workspace = @{
    Id = '/workspace'
    Kind = 'Workspace'
    Body = @{ location = $location; properties = @{ retentionInDays = 90; features = @{ enableLogAccessUsingOnlyResourcePermissions = $true } } }
}
$current = @{ location = $location; properties = @{ features = @{ enableLogAccessUsingOnlyResourcePermissions = $false; otherFeature = $true } } }
$before = ConvertTo-Json @($workspace, $current) -Depth 40 -Compress
$update = New-ResourceUpdate -Resource $workspace -Current $current
Assert-Contract ((ConvertTo-Json @($workspace, $current) -Depth 40 -Compress) -ceq $before) 'Log Analytics更新本文の作成で現在値と予定値を変更しない'
Assert-Contract ($update.Method -eq 'Patch' -and $update.Body.properties.features.enableLogAccessUsingOnlyResourcePermissions) 'Log Analyticsの更新方法と設定値を組み立てる'
Assert-Contract ($update.Body.properties.features.otherFeature) 'Log Analyticsの指定外のfeatureを引き継ぐ'

# ---
# DCRの既存値を引き継ぐ処理は、新設定と変更前の入力を変更しない。
# ---
$settings = @(
    @{ Id = '/existing-dcr'; Kind = 'Dcr'; Body = @{ location = $location; properties = @{ dataSources = @{ windowsEventLogs = @(@{ name = 'new-events' }) } } } },
    @{ Id = '/association'; Kind = 'Association'; Body = @{ properties = @{ dataCollectionRuleId = '/new-dcr' } } }
)
$beforeValues = @{
    '/existing-dcr' = @{
        location = $location
        identity = @{ type = 'UserAssigned'; userAssignedIdentities = @{ '/identity' = @{ principalId = 'azure-generated' } } }
        tags = @{ owner = 'existing-owner' }
        properties = @{ description = 'existing-description'; dataSources = @{ windowsEventLogs = @(@{ name = 'old-events' }) } }
    }
    '/association' = @{ properties = @{ description = 'existing-association'; dataCollectionRuleId = '/old-dcr'; dataCollectionEndpointId = '/existing-endpoint' } }
}
$before = ConvertTo-Json @($settings, $beforeValues) -Depth 40 -Compress
$mergedSettings = @(Merge-ExistingSettingValues -Settings $settings -BeforeValues $beforeValues)
Assert-Contract ((ConvertTo-Json @($settings, $beforeValues) -Depth 40 -Compress) -ceq $before) '既存値の引継ぎで新設定と変更前の入力を変更しない'
Assert-Contract ($mergedSettings[0].Body.identity.type -eq 'UserAssigned' -and $mergedSettings[0].Body.identity.userAssignedIdentities.Contains('/identity')) 'DCRの既存マネージドIDを引き継ぐ'
Assert-Contract ($mergedSettings[0].Body.tags.owner -eq 'existing-owner' -and $mergedSettings[0].Body.properties.description -eq 'existing-description') 'DCRのタグと指定外のプロパティを引き継ぐ'
Assert-Contract ($mergedSettings[0].Body.properties.dataSources.windowsEventLogs[0].name -eq 'new-events') 'DCRの変更対象は今回の本文を使う'
Assert-Contract ($mergedSettings[1].Body.properties.description -eq 'existing-association' -and $mergedSettings[1].Body.properties.dataCollectionEndpointId -eq '/existing-endpoint') '関連付けの指定外の値を引き継ぐ'
Assert-Contract ($mergedSettings[1].Body.properties.dataCollectionRuleId -eq '/new-dcr') '関連付けの参照先を今回のDCRへ変える'

# ---
# 作業記録を作っても元の一覧は変更せず、変更前と切り戻し方針は戻り値へ付ける。
# ---
$target = @{ SubscriptionId = '11111111-1111-1111-1111-111111111111'; ResourceGroup = 'rg-target'; WorkspaceId = '/workspace' }
$destinations = @(@{ Id = '/group'; Kind = 'Group'; Body = @{ location = $location } })
$newSettings = @($mergedSettings) + @(@{ Id = '/new-dcr'; Kind = 'Dcr'; Body = @{ location = $location; properties = @{} } })
$beforeValues['/new-dcr'] = $null
$before = ConvertTo-Json @($target, $oldSettings, $destinations, $newSettings, $beforeValues) -Depth 40 -Compress
$record = New-MigrationRecord -Target $target -OldSettings $oldSettings -Destinations $destinations -NewSettings $newSettings -BeforeValues $beforeValues
Assert-Contract ((ConvertTo-Json @($target, $oldSettings, $destinations, $newSettings, $beforeValues) -Depth 40 -Compress) -ceq $before) '記録の作成で対象・設定一覧・変更前の入力を変更しない'
Assert-Contract ($record.NewSettings[0].Before.identity.type -eq 'UserAssigned' -and -not $record.NewSettings[0].KeepOnRollback) '既存DCRの変更前を記録し切り戻しの復元対象にする'
Assert-Contract ($record.NewSettings[2].KeepOnRollback -and $null -eq $record.NewSettings[2].Before) '新設DCRは変更前なし・切り戻し時の保持対象として記録する'

# ---
# 再実行の記録統合は追加分を返し、前回の記録と最初のBeforeをそのまま残す。
# ---
$previous = @{
    Context = $migrationContext
    Target = $target
    OldSettings = @($oldSettings)
    Destinations = @($destinations)
    NewSettings = @(@{ Id = '/setting-one'; Kind = 'Diagnostic'; Body = @{ properties = @{ workspaceId = '/workspace' } }; Before = @{ marker = 'first-before' } })
}
$plan = @{
    Context = $migrationContext
    Target = $target
    OldSettings = @($oldSettings) + @(@{ Id = '/old-added'; Kind = 'Association'; Body = @{ properties = @{ dataCollectionRuleId = '/old-dcr' } } })
    Destinations = @($destinations)
    NewSettings = @(
        @{ Id = '/setting-one'; Kind = 'Diagnostic'; Body = @{ properties = @{ workspaceId = '/workspace' } }; Before = @{ marker = 'later-before' } },
        @{ Id = '/setting-two'; Kind = 'Diagnostic'; Body = @{ properties = @{ workspaceId = '/workspace' } }; Before = $null }
    )
}
$before = ConvertTo-Json @($previous, $plan) -Depth 40 -Compress
$merged = Merge-MigrationRecord -Plan $plan -Record $previous
Assert-Contract ((ConvertTo-Json @($previous, $plan) -Depth 40 -Compress) -ceq $before) '記録の統合で前回記録と今回計画を変更しない'
Assert-Contract ($merged.NewSettings.Count -eq 2 -and $merged.OldSettings.Count -eq 2) '記録の統合で新規対象を戻り値へ追加する'
Assert-Contract ($merged.NewSettings[0].Before.marker -eq 'first-before') '記録の統合で最初のBeforeを維持する'

# ---
# 地域略称は戻り値で受け取り、Azureの操作先Subも引数で明示する。
# ---
$script:regionNames = '変更しない値'
$abbreviations = @(Get-RegionAbbreviations -Targets @(@{ StorageAccount = '' }))
Assert-Contract ($abbreviations.Count -eq 0 -and $script:regionRequests -eq 0) 'Storage名がない場合は地域略称を取得しない'
$abbreviations = @(Get-RegionAbbreviations -Targets @(@{ StorageAccount = 'stjpeexample' }))
Assert-Contract ($abbreviations.Count -eq 2 -and $script:regionRequests -eq 1) 'Storage名がある場合に地域略称を返す'
Assert-Contract ($script:regionNames -ceq '変更しない値') '地域略称の取得で共有変数を書き換えない'

$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository 'common.ps1'), [ref]$tokens, [ref]$errors)
Assert-Contract ($errors.Count -eq 0) '共通定義の構文が正しい'
$armCalls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-ArmRequest' }, $true))
Assert-Contract ($armCalls.Count -gt 0) '明示的なSub指定を調べる通信呼出しが存在する'
foreach ($call in $armCalls) {
    $subscriptionParameter = @($call.CommandElements | Where-Object { $_ -is [Management.Automation.Language.CommandParameterAst] -and $_.ParameterName -eq 'SubscriptionId' })
    Assert-Contract ($subscriptionParameter.Count -eq 1) "Azure通信にSubを明示する: $($call.Extent.StartLineNumber)行"
}
$parameter = (Get-Command Invoke-ArmRequest).Parameters['SubscriptionId']
Assert-Contract (@($parameter.Attributes | Where-Object { $_ -is [Management.Automation.ParameterAttribute] -and $_.Mandatory }).Count -gt 0) 'Azure通信のSub引数は省略できない'
Assert-Contract ($script:azureRequests -eq 0) '契約試験中に実Azureへ通信しない'

$report = @{ Result = 'PASS'; Checks = $script:checks; Assertions = $results.ToArray(); AzureRequests = $script:azureRequests; MockRegionRequests = $script:regionRequests; PowerShellVersion = $PSVersionTable.PSVersion.ToString() }
if ($ReportPath) {
    $report | ConvertTo-Json -Depth 8 | Set-Content $ReportPath -Encoding utf8
}
"契約試験: $script:checks 判定成功、Azure通信0件。"
