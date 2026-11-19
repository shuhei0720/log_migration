#Requires -Version 5.1
. (Join-Path $PSScriptRoot 'common.ps1')
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

# ---
# サブスクリプションごとに調査し、変更前の設定を保存する
# 再実行では最初のBeforeを保持し、新しく見つかった対象だけ追記する。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        # ---
        # 変更前のWaiverを記録し、全行で準備するRG・Log Analyticsを指定する。
        # ---
        foreach ($assignment in $policyAssignments) {
            $assignmentName = ($assignment.Id -split '/')[-1]
            $exemptionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
            $saved = @($Record.NewSettings | Where-Object { $_.Id -eq $exemptionId })
            $before = $null
            if ($saved.Count -gt 0) {
                $before = $saved[0].Before
            }
            else {
                $current = Invoke-ArmRequest -ResourceId $exemptionId -ApiVersion '2022-07-01-preview' -Optional
                $before = Get-WritableBody -Resource $current -Kind 'Exemption'
            }
            $plan.NewSettings += @{
                Id = $exemptionId
                Kind = 'Exemption'
                ApiVersion = '2022-07-01-preview'
                Before = $before
                Body = @{
                    properties = @{
                        policyAssignmentId = $assignment.Id
                        policyDefinitionReferenceIds = @($assignment.ReferenceIds)
                        exemptionCategory = 'Waiver'
                        assignmentScopeValidation = 'Default'
                        expiresOn = $null
                        resourceSelectors = @()
                    }
                }
            }
        }
        $plan.Destinations += @{
            Id = $resourceGroupId
            Kind = 'Group'
            ApiVersion = '2022-09-01'
            Body = @{ location = $location }
        }
        $plan.Destinations += @{
            Id = $Target.WorkspaceId
            Kind = 'Workspace'
            ApiVersion = '2023-09-01'
            Body = @{
                location = $location
                properties = @{
                    retentionInDays = 365
                    publicNetworkAccessForIngestion = 'Enabled'
                    publicNetworkAccessForQuery = 'Enabled'
                    features = @{ enableLogAccessUsingOnlyResourcePermissions = $true }
                }
            }
        }

        # ---
        # 調査した地域ごとにStorageの構成と1095日保持を指定する。
        # ---
        $storageIds = @{}
        foreach ($storage in $plan.Discovery.Storages) {
            $storageId = $storage.Id
            $storageLocation = $storage.Location
            $storageIds[$storageLocation] = $storageId
            $plan.Destinations += @{
                Id = $storageId
                Kind = 'Storage'
                ApiVersion = '2023-05-01'
                Body = @{
                    location = $storageLocation
                    kind = 'StorageV2'
                    sku = @{ name = 'Standard_ZRS' }
                    properties = @{
                        encryption = @{ requireInfrastructureEncryption = $true }
                        immutableStorageWithVersioning = @{ enabled = $true }
                        publicNetworkAccess = 'Enabled'
                        allowBlobPublicAccess = $false
                        allowSharedKeyAccess = $false
                        supportsHttpsTrafficOnly = $true
                        minimumTlsVersion = 'TLS1_2'
                        networkAcls = @{
                            defaultAction = 'Deny'
                            bypass = 'AzureServices'
                        }
                    }
                }
            }
            $plan.Destinations += @{
                Id = "$storageId/blobServices/default"
                Kind = 'Blob'
                ApiVersion = '2023-05-01'
                Body = @{ properties = @{ isVersioningEnabled = $true } }
            }
            $plan.Destinations += @{
                Id = "$storageId/managementPolicies/default"
                Kind = 'Lifecycle'
                ApiVersion = '2023-05-01'
                Body = @{
                    properties = @{
                        policy = @{
                            rules = @(@{
                                name = 'log-append-1095'
                                enabled = $true
                                type = 'Lifecycle'
                                definition = @{
                                    filters = @{ blobTypes = @('appendBlob') }
                                    actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = 1095 } } }
                                }
                            })
                        }
                    }
                }
            }
            $plan.Destinations += @{
                Id = "$storageId/providers/Microsoft.Security/defenderForStorageSettings/current"
                Kind = 'Defender'
                ApiVersion = '2025-01-01'
                Body = @{
                    properties = @{
                        isEnabled = $false
                        overrideSubscriptionLevelSettings = $true
                    }
                }
            }
        }

        # ---
        # 旧VM対象があればテーブルを準備し、VM送信を続ける場合だけ新DCRに関連付ける。
        # 既存DCR・関連付けは元のその他設定を残し、最初のBeforeから希望値を作る。
        # ---
        $oldAssociations = @($plan.OldSettings | Where-Object { $_.Kind -eq 'Association' })
        if ($oldAssociations.Count -gt 0) {
            foreach ($tableName in @('Event', 'Syslog')) {
                $plan.Destinations += @{
                    Id = "$($Target.WorkspaceId)/tables/$tableName"
                    Kind = 'Table'
                    ApiVersion = '2025-07-01'
                    Body = @{
                        properties = @{
                            schema = @{ name = $tableName }
                            totalRetentionInDays = 1095
                        }
                    }
                }
            }
        }
        if ($plan.Discovery.Dcr) {
            $dcrId = $plan.Discovery.Dcr.Id
            $saved = @($Record.NewSettings | Where-Object { $_.Id -eq $dcrId })
            $before = $null
            if ($saved.Count -gt 0) {
                $before = $saved[0].Before
            }
            else {
                $before = Get-WritableBody -Resource (Invoke-ArmRequest -ResourceId $dcrId -Optional) -Kind 'Dcr'
            }
            $dcrBody = Get-WritableBody -Resource $before -Kind 'Dcr'
            if (-not $dcrBody) {
                $dcrBody = @{ properties = @{} }
            }
            $dcrBody.location = $location
            $dcrBody.properties.dataSources = @{
                windowsEventLogs = @(@{
                    name = 'eventLogsDataSource'
                    streams = @('Microsoft-Event')
                    xPathQueries = @(
                        'Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]'
                        'Security!*[System[(band(Keywords,13510798882111488))]]'
                        'System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]'
                    )
                })
                syslog = @(@{
                    name = 'sysLogsDataSource'
                    streams = @('Microsoft-Syslog')
                    facilityNames = @(
                        'alert', 'audit', 'auth', 'authpriv', 'clock', 'cron', 'daemon', 'ftp', 'kern'
                        'local0', 'local1', 'local2', 'local3', 'local4', 'local5', 'local6', 'local7'
                        'lpr', 'mail', 'news', 'nopri', 'ntp', 'syslog', 'user', 'uucp'
                    )
                    logLevels = @('Debug', 'Info', 'Notice', 'Warning', 'Error', 'Critical', 'Alert', 'Emergency')
                })
            }
            $dcrBody.properties.destinations = @{
                logAnalytics = @(@{
                    name = 'new-workspace'
                    workspaceResourceId = $Target.WorkspaceId
                })
            }
            $dcrBody.properties.dataFlows = @(
                @{
                    streams = @('Microsoft-Event')
                    destinations = @('new-workspace')
                }
                @{
                    streams = @('Microsoft-Syslog')
                    destinations = @('new-workspace')
                }
            )
            $plan.NewSettings += @{
                Id = $dcrId
                Kind = 'Dcr'
                ApiVersion = '2024-03-11'
                Before = $before
                Body = $dcrBody
                KeepOnRollback = $null -eq $before
            }
            foreach ($association in $plan.Discovery.Associations) {
                $associationId = $association.Id
                $saved = @($Record.NewSettings | Where-Object { $_.Id -eq $associationId })
                $before = $null
                if ($saved.Count -gt 0) {
                    $before = $saved[0].Before
                }
                else {
                    $before = Get-WritableBody -Resource (Invoke-ArmRequest -ResourceId $associationId -Optional) -Kind 'Association'
                }
                $associationBody = Get-WritableBody -Resource $before -Kind 'Association'
                if (-not $associationBody) {
                    $associationBody = @{ properties = @{} }
                }
                $associationBody.properties.dataCollectionRuleId = $dcrId
                $plan.NewSettings += @{
                    Id = $associationId
                    Kind = 'Association'
                    ApiVersion = '2024-03-11'
                    Before = $before
                    Body = $associationBody
                }
            }
        }

        # ---
        # 旧診断のログ・メトリックを引き継ぎ、選択された宛先だけを設定する。
        # ---
        foreach ($diagnostic in $plan.Discovery.Diagnostics) {
            $original = @($plan.OldSettings | Where-Object Id -eq $diagnostic.OldId)[0]
            $source = $original.Body.properties
            $diagnosticBody = @{
                properties = @{
                    logs = @($source.logs | Where-Object { $null -ne $_ })
                    metrics = @($source.metrics | Where-Object { $null -ne $_ })
                }
            }
            if ($target.LogDestination -eq 'Storage') {
                $diagnosticBody.properties.storageAccountId = $storageIds[$diagnostic.Location]
            }
            else {
                $diagnosticBody.properties.workspaceId = $target.WorkspaceId
                $diagnosticBody.properties.logAnalyticsDestinationType = $source.logAnalyticsDestinationType
            }
            $plan.NewSettings += @{
                Id = $diagnostic.Id
                Kind = 'Diagnostic'
                ApiVersion = '2021-05-01-preview'
                Before = $null
                Body = $diagnosticBody
            }
        }
        $plan.Remove('Discovery')

        $recordChanged = -not $record
        if ($record) {
            foreach ($saved in $record.OldSettings) {
                $current = @($plan.OldSettings | Where-Object Id -eq $saved.Id)
                if ($current.Count -ne 1 -or -not (Test-Configuration $current[0].Body $saved.Body -Exact)) {
                    throw "記録した旧設定がないか、内容が変わっています: $($saved.Id)"
                }
            }
            foreach ($collection in @('Destinations', 'NewSettings', 'OldSettings')) {
                foreach ($planned in $plan.$collection) {
                    $saved = @($record.$collection | Where-Object Id -eq $planned.Id)
                    if (-not $saved.Count) {
                        $record.$collection += @($planned)
                        $recordChanged = $true
                    }
                    elseif (-not (Test-Configuration $planned.Body $saved[0].Body -Exact)) {
                        throw "保存済みの設定値が今回の計画と異なります: $($planned.Id)"
                    }
                }
            }
        }
        else {
            $record = $plan
        }
        if ($recordChanged) {
            $recordPath = Join-Path $recordDirectory "$subscriptionId.json"
            $temporaryPath = "$recordPath.tmp"
            [IO.File]::WriteAllText($temporaryPath, (ConvertTo-Json $record -Depth 40), [Text.Encoding]::UTF8)
            if (Test-Path $recordPath) {
                [IO.File]::Replace($temporaryPath, $recordPath, $null)
            }
            else {
                [IO.File]::Move($temporaryPath, $recordPath)
            }
        }

        # ---
        # 適用除外、保存先、新しい送信設定の順に準備する
        # 一致する設定は書き込まない。失敗したSubは以降の処理を中断し、旧設定を残す。
        # ---
        $providersReady = $false
        $resources = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
        $resources += @($record.Destinations)
        $resources += @($record.NewSettings | Where-Object Kind -ne 'Exemption')
        foreach ($resource in $resources) {
            if (-not $providersReady -and $resource.Kind -ne 'Exemption') {
                $namespaces = @('Microsoft.Insights', 'Microsoft.OperationalInsights')
                if (@($record.Destinations | Where-Object Kind -eq 'Storage').Count) {
                    $namespaces += @('Microsoft.Storage', 'Microsoft.Security')
                }
                foreach ($namespace in $namespaces) {
                    $providerId = "/subscriptions/$subscriptionId/providers/$namespace"
                    $provider = Invoke-ArmRequest $providerId -ApiVersion '2021-04-01'
                    if ($provider.registrationState -ne 'Registered') {
                        $null = Invoke-ArmRequest "$providerId/register" -Method Post -ApiVersion '2021-04-01'
                        $deadline = (Get-Date).AddMinutes(5)
                        do {
                            Start-Sleep -Seconds 3
                            $provider = Invoke-ArmRequest $providerId -ApiVersion '2021-04-01'
                            if ((Get-Date) -ge $deadline) {
                                throw "プロバイダー登録が完了しません: $namespace"
                            }
                        } while ($provider.registrationState -ne 'Registered')
                    }
                }
                $providersReady = $true
            }
            $current = Invoke-ArmRequest -Resource $resource -Optional
            $deadline = (Get-Date).AddMinutes(5)
            while ($current.properties.provisioningState -in @('Creating', 'Updating', 'Accepted')) {
                if ((Get-Date) -ge $deadline) {
                    throw "作成・更新が完了しません: $($resource.Id)"
                }
                Start-Sleep -Seconds 3
                $current = Invoke-ArmRequest -Resource $resource -Optional
            }
            $currentBody = Get-WritableBody $current -Kind $resource.Kind
            $expected = $resource.Body
            if ($resource.Kind -eq 'Group') {
                $expected = @{}
            }
            $matched = Test-Configuration $current $expected -Kind $resource.Kind
            if ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault) {
                $matched = $false
            }
            if ($matched) {
                continue
            }
            if ($current -and $resource.Kind -eq 'Exemption') {
                throw '既存の適用除外が指定内容と異なります。'
            }
            if ($current -and $resource.Kind -in @('Diagnostic', 'Dcr', 'Association')) {
                if (-not $resource.Before -or -not (Test-Configuration $currentBody $resource.Before -Exact)) {
                    throw "変更予定の設定が記録と異なります: $($resource.Id)"
                }
            }
            $body = ConvertTo-Json $resource.Body -Depth 40 | ConvertFrom-Json
            $method = 'Put'

            # ---
            # 既存の保存先で、変更対象以外の設定を残す
            # Storageの通信規則、LAのfeatures、他名のライフサイクルルールを保持する。
            # ---
            if ($current -and $resource.Kind -eq 'Storage') {
                $immutable = @{
                    location = $resource.Body.location
                    kind = $resource.Body.kind
                    sku = $resource.Body.sku
                    properties = @{
                        encryption = $resource.Body.properties.encryption
                        immutableStorageWithVersioning = $resource.Body.properties.immutableStorageWithVersioning
                    }
                }
                if (-not (Test-Configuration $current $immutable)) {
                    throw 'Storageの地域・SKU・暗号化・不変性が予定と異なります。'
                }
                $body.properties.networkAcls = $current.properties.networkAcls
                $body.properties.networkAcls.defaultAction = 'Deny'
                $body.properties.networkAcls.bypass = 'AzureServices'
            }
            if ($current -and $resource.Kind -eq 'Workspace') {
                if (($current.location -replace '\s', '') -ne $location) {
                    throw '既存Log Analyticsの地域が予定と異なります。'
                }
                $method = 'Patch'
                $features = @{}
                foreach ($property in $current.properties.features.PSObject.Properties) {
                    $features[$property.Name] = $property.Value
                }
                $features.enableLogAccessUsingOnlyResourcePermissions = $true
                $body.properties.features = $features
            }
            if ($resource.Kind -eq 'Lifecycle') {
                $body.properties.policy.rules = @($current.properties.policy.rules | Where-Object {
                    $null -ne $_ -and $_.name -notin @('log-append-365', 'log-append-1095')
                }) + @($resource.Body.properties.policy.rules)
            }
            if ($current -and $resource.Kind -eq 'Table') {
                $method = 'Patch'
                $body = @{ properties = @{ totalRetentionInDays = 1095 } }
            }
            # ---
            # DCRの宛先テーブルが未反映の場合だけ、5分の期限内で再送する。
            # ---
            while ($true) {
                try {
                    $null = Invoke-ArmRequest -Resource $resource -Method $method -Body $body
                    break
                }
                catch {
                    $message = $_.Exception.Message + $_.ErrorDetails.Message
                    if ($resource.Kind -ne 'Dcr' -or $message -notmatch 'InvalidOutputTable' -or
                        (Get-Date).AddSeconds(10) -ge $deadline) {
                        throw
                    }
                    Start-Sleep -Seconds 10
                }
            }
            do {
                $current = Invoke-ArmRequest -Resource $resource
                if ((Get-Date) -ge $deadline) {
                    throw "設定後の更新が完了しません: $($resource.Id)"
                }
                if ($current.properties.provisioningState -in @('Creating', 'Updating', 'Accepted')) {
                    Start-Sleep -Seconds 3
                }
            } while ($current.properties.provisioningState -in @('Creating', 'Updating', 'Accepted'))
            if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                throw "設定後の確認が一致しません: $($resource.Id)"
            }
        }
    }
    catch {
        $failures += [pscustomobject]@{
            SubscriptionId = $subscriptionId
            ResourceId = $resource.Id
            Reason = $_.Exception.Message
            Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
        }
    }
}
$failurePath = Join-Path $PSScriptRoot 'copy_failures.csv'
if ($failures.Count) {
    $failures | Export-Csv $failurePath -NoTypeInformation -Encoding UTF8
    throw "未完了のSubがあります。$failurePath を確認して再実行してください。"
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '旧設定を保持しました。step2で確認後、step3へ進んでください。'
