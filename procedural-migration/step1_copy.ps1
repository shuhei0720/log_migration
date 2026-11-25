#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

# ---
# CSVのSubごとにAzureから旧診断設定・DCR関連付けを取得し、新しい保存先・送信設定とともに$planへまとめる。
# Azureの変更前にJSONへ保存する。再実行でも最初の変更前の値を残す。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        # ---
        # 環境別ポリシーのSub単位Waiverと、CSVのリソースグループ・Log Analyticsを作成対象に加える。
        # Log Analytics全体は90日保持する。送信がNone・空欄でも保存先は作る。
        # ---
        foreach ($assignment in $policyAssignments) {
            $assignmentName = ($assignment.Id -split '/')[-1]
            $exemptionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
            $plan.NewSettings += @{
                Id = $exemptionId
                Kind = 'Exemption'
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
            Body = @{ location = $location }
        }
        $plan.Destinations += @{
            Id = $Target.WorkspaceId
            Kind = 'Workspace'
            Body = @{
                location = $location
                properties = @{
                    retentionInDays = 90
                    publicNetworkAccessForIngestion = 'Enabled'
                    publicNetworkAccessForQuery = 'Enabled'
                    features = @{ enableLogAccessUsingOnlyResourcePermissions = $true }
                }
            }
        }

        # ---
        # 地域別StorageのZRS・暗号化・通信制限・Blobバージョン管理・Defender無効化を準備する。
        # 最終更新から1095日を超えたappendBlobを削除するルールを加え、地域別IDを診断設定用の$storageIdsに残す。
        # ---
        $storageIds = @{}
        foreach ($storage in $plan.Discovery.Storages) {
            $storageId = $storage.Id
            $storageLocation = $storage.Location
            $storageIds[$storageLocation] = $storageId
            $plan.Destinations += @{
                Id = $storageId
                Kind = 'Storage'
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
                Body = @{ properties = @{ isVersioningEnabled = $true } }
            }
            $plan.Destinations += @{
                Id = "$storageId/managementPolicies/default"
                Kind = 'Lifecycle'
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
                Body = @{
                    properties = @{
                        isEnabled = $false
                        overrideSubscriptionLevelSettings = $true
                    }
                }
            }
        }

        # ---
        # 旧DCRに関連付いたVM・VMSSがあれば、新Log AnalyticsのEvent・Syslogを合計1095日保持にする。
        # VM側の送信を省略する場合も、このテーブル設定は行う。
        # ---
        $oldAssociations = @($plan.OldSettings | Where-Object { $_.Kind -eq 'Association' })
        if ($oldAssociations.Count -gt 0) {
            foreach ($tableName in @('Event', 'Syslog')) {
                $plan.Destinations += @{
                    Id = "$($Target.WorkspaceId)/tables/$tableName"
                    Kind = 'Table'
                    Body = @{
                        properties = @{
                            schema = @{ name = $tableName }
                            totalRetentionInDays = 1095
                        }
                    }
                }
            }
        }
        # ---
        # VmLogDestinationがLogなら、Windowsイベント・Syslogを新Log Analyticsへ送るDCRを用意する。
        # 旧DCRに関連付いたVM・VMSSと新DCRの関連付けも、作成対象に加える。
        # ---
        if ($plan.Discovery.Dcr) {
            $dcrId = $plan.Discovery.Dcr.Id
            $dcrBody = @{
                location = $location
                properties = @{}
            }
            $dcrBody.properties.dataSources = @{
                windowsEventLogs = @(@{
                    name = 'eventLogsDataSource'
                    streams = @('Microsoft-Event')
                    # Securityの数値は監査成功・失敗を選ぶ指定で、Application・Systemは全レベルを収集する。
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
                Body = $dcrBody
            }
            foreach ($association in $plan.Discovery.Associations) {
                $associationId = $association.Id
                $associationBody = @{ properties = @{ dataCollectionRuleId = $dcrId } }
                $plan.NewSettings += @{
                    Id = $associationId
                    Kind = 'Association'
                    Body = $associationBody
                }
            }
        }

        # ---
        # 旧診断設定のログ・メトリックを引き継ぎ、送信先を同じ地域のStorageまたは新Log Analyticsへ変える。
        # None・空欄のときは調査結果が空なので、新診断設定を作らない。
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
                Before = $null
                Body = $diagnosticBody
            }
        }
        # ---
        # Waiver・DCR・関連付けの現在値を復元用のBeforeに保存する。再実行では最初のBeforeを使う。
        # 既存DCR・関連付けは今回の変更項目だけ置き換え、ほかの値を引き継ぐ。
        # ---
        foreach ($setting in @($plan.NewSettings | Where-Object Kind -ne 'Diagnostic')) {
            $saved = @($record.NewSettings | Where-Object Id -eq $setting.Id)
            if ($saved.Count) {
                $setting.Before = $saved[0].Before
            }
            else {
                $setting.Before = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) -Kind $setting.Kind
            }
            if ($setting.Kind -eq 'Dcr') {
                # 今回新しく作るDCRは切り戻しでも残すため、作成前に存在しない場合だけ保持対象にする。
                $setting.KeepOnRollback = $null -eq $setting.Before
            }
            if ($setting.Before -and $setting.Kind -in @('Dcr', 'Association')) {
                $body = Get-WritableBody $setting.Before -Kind $setting.Kind
                foreach ($property in $setting.Body.properties.Keys) {
                    $body.properties[$property] = $setting.Body.properties[$property]
                }
                if ($setting.Kind -eq 'Dcr') {
                    $body.location = $location
                }
                $setting.Body = $body
            }
        }
        # 作成先を決めるための調査用情報は、再開・切り戻しに不要なので記録から外す。
        $plan.Remove('Discovery')

        # ---
        # 前回のJSONと今回の調査を照合する。旧設定の変更・消失や、同じIDの作成値の違いがあればSubの作業を止める。
        # 新しく見つかった対象だけを加え、保存済みのBeforeは残す。
        # ---
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
        # ---
        # 旧設定と作成内容をSub別JSONへ保存する。一時ファイルからの置き換えが成功してからAzureを変更する。
        # ---
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
        # JSONからWaiver→保存先→DCR・関連付けの順に作成する。現在値が一致していれば書き込まない。
        # 失敗したSubの残りは止め、旧設定を残して次のSubへ進む。
        # ---
        $providersReady = $false
        $resources = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
        $resources += @($record.Destinations)
        $resources += @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })
        foreach ($resource in $resources) {
            # ---
            # 保存先・DCRに必要なAzureサービスを利用登録し、Registeredになってから作成へ進む。
            # ---
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
                        do {
                            Start-Sleep -Seconds 3
                            $provider = Invoke-ArmRequest $providerId -ApiVersion '2021-04-01'
                        } while ($provider.registrationState -ne 'Registered')
                    }
                }
                $providersReady = $true
            }
            $current = Invoke-ArmRequest -Resource $resource -Optional -Wait
            $currentBody = Get-WritableBody $current -Kind $resource.Kind
            $expected = $resource.Body
            # RGは存在すれば再利用するため、地域は一致条件に含めない。
            if ($resource.Kind -eq 'Group') {
                $expected = @{}
            }
            $matched = Test-Configuration $current $expected -Kind $resource.Kind
            # 日数が同じでも、ワークスペース既定値の継承ではテーブル個別の設定済みとみなさない。
            if ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault) {
                $matched = $false
            }
            if ($matched) {
                continue
            }
            if ($current -and $resource.Kind -eq 'Exemption') {
                throw '既存の適用除外が指定内容と異なります。'
            }
            # DCR・関連付けは保存した変更前のままなら更新し、別の変更があれば上書きしない。
            if ($current -and $resource.Kind -in @('Dcr', 'Association')) {
                if (-not $resource.Before -or -not (Test-Configuration $currentBody $resource.Before -Exact)) {
                    throw "変更予定の設定が記録と異なります: $($resource.Id)"
                }
            }
            # 既存値を引き継ぐための変更は送信本文のコピーに加え、記録のBodyは変えない。
            $body = ConvertTo-Json $resource.Body -Depth 40 | ConvertFrom-Json -AsHashtable
            $method = 'Put'

            # ---
            # 既存StorageのIP・VNet規則、Log Analyticsの他のfeatures、他名のライフサイクルルールを残す。
            # Storageの地域・SKU・暗号化・不変性、Log Analyticsの地域が予定と違えば停止する。
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
                $body.properties.features = $current.properties.features ?? @{}
                $body.properties.features.enableLogAccessUsingOnlyResourcePermissions = $true
            }
            if ($resource.Kind -eq 'Lifecycle') {
                $body.properties.policy.rules = @($current.properties.policy.rules | Where-Object {
                    $null -ne $_ -and $_.name -notin @('log-append-365', 'log-append-1095')
                }) + @($resource.Body.properties.policy.rules)
            }
            # 既存テーブルの列定義などを保つため、保持期間だけをPATCHで更新する。
            if ($current -and $resource.Kind -eq 'Table') {
                $method = 'Patch'
                $body = @{ properties = @{ totalRetentionInDays = 1095 } }
            }
            # ---
            # Event・Syslogテーブルの反映待ちでDCR作成に失敗した場合は、10秒後に再送する。
            # それ以外はここで再試行せず、Subの失敗として扱う。
            # ---
            while ($true) {
                try {
                    $null = Invoke-ArmRequest -Resource $resource -Method $method -Body $body
                    break
                }
                catch {
                    $message = $_.Exception.Message + $_.ErrorDetails.Message
                    # Azureのエラー文から不足した出力先を拾い、Event・Syslogだけの反映遅れか調べる。
                    # 別テーブルや出力先が不明なエラーを、反映待ちとして再送し続けないために区別する。
                    $outputTables = @([regex]::Matches($message, '(?i)\b(?:output table|table|output stream)\s+\\?[''"](?<table>[^''"\\]+)\\?[''"]') | ForEach-Object { $_.Groups['table'].Value })
                    if ($resource.Kind -ne 'Dcr' -or $message -notmatch 'InvalidOutputTable' -or -not $outputTables -or
                        @($outputTables | Where-Object { $_ -notin @('Event', 'Syslog', 'Microsoft-Event', 'Microsoft-Syslog') }).Count) {
                        throw
                    }
                    Start-Sleep -Seconds 10
                }
            }
            # ---
            # 作成後の値をAzureから取得し、JSONと照合する。テーブルは1095日が個別指定されていることも確認する。
            # ---
            $current = Invoke-ArmRequest -Resource $resource -Wait
            if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                throw "設定後の確認が一致しません: $($resource.Id)"
            }
        }

        # ---
        # 新診断設定を最大$parallelLimit件ずつ並列に作成する。同じIDで内容も一致していればスキップする。
        # 失敗したID・理由・設定値を集め、最後にcopy_failures.csvへ出す。
        # ---
        $accessToken = $script:accessToken
        $diagnostics = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        $copied = @($diagnostics | ForEach-Object -Parallel {
            $resource = $_
            $result = [pscustomobject]@{
                SubscriptionId = $using:subscriptionId
                ResourceId = $resource.Id
                Reason = ''
                Expected = ''
            }
            try {
                # 並列処理には外側の関数が引き継がれないため、共通定義と対象Subの認証情報を用意する。
                . $using:commonScript -SkipCsv
                $subscriptionId = $using:subscriptionId
                $script:accessToken = $using:accessToken
                $script:tokenSubscription = $subscriptionId
                $current = Invoke-ArmRequest -Resource $resource -Optional
                if (Test-Configuration $current $resource.Body -Kind 'Diagnostic') {
                    return $result
                }
                if ($current) {
                    throw '同名の診断設定が記録と異なります。'
                }
                $null = Invoke-ArmRequest -Resource $resource -Method Put
                $current = Invoke-ArmRequest -Resource $resource
                if (-not (Test-Configuration $current $resource.Body -Kind 'Diagnostic')) {
                    throw '複製後の診断設定が一致しません。'
                }
            }
            catch {
                $result.Reason = $_.Exception.Message
                $result.Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
            }
            $result
        } -ThrottleLimit $parallelLimit)
        if ($copied.Count -ne $diagnostics.Count) {
            throw '診断設定の複製結果が不足しています。'
        }
        $failures += @($copied | Where-Object Reason)
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
# ---
# 失敗はcopy_failures.csvへ出してエラーで終了する。全件成功なら前回の失敗CSVを消す。
# 旧設定は残したまま、step2で新設定を確認する。
# ---
$failurePath = Join-Path $PSScriptRoot 'copy_failures.csv'
if ($failures.Count) {
    $failures | Export-Csv $failurePath -Encoding utf8BOM
    throw "未完了のSubがあります。$failurePath を確認して再実行してください。"
}
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '旧設定を保持しました。step2で確認後、step3へ進んでください。'
