#Requires -Version 7.0
. (Join-Path $PSScriptRoot 'common.ps1')
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

# ---
# 旧ワークスペース宛ての診断設定と、旧データ収集ルール（DCR）への関連付けを調べる。
# 作成する設定値（Body）と旧設定を$planにまとめ、Azureの設定を変える前に作業記録へ保存する。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        # ---
        # 指定ポリシーの適用除外（Waiver）と、保存先のリソースグループ・Log Analyticsの設定値を用意する。
        # 新しい送信設定を作らない指定でも、保存先は作る。Log Analytics全体の保持期間は90日にする。
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
        # リソースの地域ごとに、ストレージアカウントとその保存・通信設定を用意する。
        # 最終更新から1,095日を超えたappendBlobを削除するルールも用意する。地域別のIDは診断設定の送信先に使う。
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
                        publicNetworkAccess = 'Disabled'
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
        # すべての新しいLog Analyticsで、Event・Syslogを合計1,095日保持にする。
        # 旧DCRの関連付けがない場合や、VMログの送信を省略する場合も設定する。
        # ---
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
        # ---
        # VmLogDestinationがLogで旧DCRへの関連付けがあれば、新しいDCRの設定値を用意する。
        # WindowsイベントとSyslogを新しいLog Analyticsへ送り、同じVM・VMSSへ新DCRを関連付ける。
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
                    # Securityの数値は、監査成功と監査失敗を選ぶ条件。Application・Systemは全レベルを収集する。
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
        # 旧診断設定のログ・メトリックをコピーし、同じ地域のストレージまたは新しいLog Analyticsへ送る設定値を作る。
        # LogDestinationがNone・空欄なら新診断設定は作らない。旧診断設定は、後で削除するため作業記録に残す。
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
        # 適用除外・新DCR・新しい関連付けの変更前の値をBeforeへ入れる。再実行では、最初に保存した値を使う。
        # 作成先にDCR・関連付けがすでにある場合は、今回変更しない項目も新しい設定値に残す。
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
                # 作成前に存在しなかったDCRには、切り戻しで削除しない印を付ける。
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
        # 作成先を決めるための一時情報を外し、復元や再実行に使う設定値だけを記録に残す。
        $plan.Remove('Discovery')

        # ---
        # 再実行では、旧設定と作成予定の設定値を前回の記録と比べる。違いや旧設定の削除があれば、このサブスクリプションを止める。
        # 新しく見つかった設定だけを記録に追加し、最初に保存した変更前の値（Before）は書き換えない。
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
        # 旧設定と作成する設定値を、サブスクリプションごとのJSONファイルへ保存する。
        # 一時ファイルへ書き終えてから正式な記録に置き換え、保存が終わってからAzureの設定を変える。
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
        # 作業記録の値で、適用除外→保存先→DCR・関連付けの順に作成する。現在の設定値が同じなら、作成を省く。
        # 失敗したサブスクリプションでは以降を実行せず、旧設定を残して次のサブスクリプションへ進む。
        # ---
        $providersReady = $false
        $resources = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
        $resources += @($record.Destinations)
        $resources += @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })
        foreach ($resource in $resources) {
            # ---
            # 保存先とDCRに必要なAzureサービスを利用登録し、登録完了（Registered）を待ってから作成へ進む。
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
            # 記録した作成先のリソースグループは、再開時に存在することだけを確認する。
            if ($resource.Kind -eq 'Group') {
                $expected = @{}
            }
            $matched = Test-Configuration $current $expected -Kind $resource.Kind
            # 既定値を引き継いでいるだけのテーブルは未設定とみなし、1,095日をテーブルに直接設定する。
            if ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault) {
                $matched = $false
            }
            if ($matched) {
                continue
            }
            if ($current -and $resource.Kind -eq 'Exemption') {
                throw '既存の適用除外が指定内容と異なります。'
            }
            # 更新が必要なDCR・関連付けは、現在値が変更前の記録（Before）と同じ場合だけ書き換える。
            if ($current -and $resource.Kind -in @('Dcr', 'Association')) {
                if (-not $resource.Before -or -not (Test-Configuration $currentBody $resource.Before -Exact)) {
                    throw "変更予定の設定が記録と異なります: $($resource.Id)"
                }
            }
            # 送信する設定値を別にコピーし、既存の項目を加えても作業記録のBodyが変わらないようにする。
            $body = ConvertTo-Json $resource.Body -Depth 40 | ConvertFrom-Json -AsHashtable
            $method = 'Put'

            # ---
            # ストレージの地域・SKU・暗号化・不変性が作業記録と違えば、書き換えずに止める。
            # networkAclsのIP・VNet規則は残し、defaultActionをDeny、bypassをAzureServicesにする。
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
            # Log Analyticsの地域が予定と違えば止める。更新では、他の機能設定を現在値から引き継ぐ。
            if ($current -and $resource.Kind -eq 'Workspace') {
                if (($current.location -replace '\s', '') -ne $location) {
                    throw '既存Log Analyticsの地域が予定と異なります。'
                }
                $method = 'Patch'
                $body.properties.features = $current.properties.features ?? @{}
                $body.properties.features.enableLogAccessUsingOnlyResourcePermissions = $true
            }
            # log-append-1095だけを入れ替え、他の名前のライフサイクルルールは残す。
            if ($resource.Kind -eq 'Lifecycle') {
                $body.properties.policy.rules = @($current.properties.policy.rules | Where-Object {
                    $null -ne $_ -and $_.name -ne 'log-append-1095'
                }) + @($resource.Body.properties.policy.rules)
            }
            # テーブルの列定義を変えないよう、合計保持期間だけをPATCHで更新する。
            if ($current -and $resource.Kind -eq 'Table') {
                $method = 'Patch'
                $body = @{ properties = @{ totalRetentionInDays = 1095 } }
            }
            # ---
            # DCRがEvent・Syslogの反映前で作成できない場合だけ、10秒待って同じ要求を送る。
            # それ以外のエラーはここで再送せず、このサブスクリプションの残りの処理を止める。
            # ---
            while ($true) {
                try {
                    $null = Invoke-ArmRequest -Resource $resource -Method $method -Body $body
                    break
                }
                catch {
                    $message = $_.Exception.Message + $_.ErrorDetails.Message
                    # エラー文からテーブル名を取り出し、Event・Syslogだけがまだ使えない状態なのかを調べる。
                    # 別のテーブル名や、名前を特定できないエラーでは、この待機を続けない。
                    $outputTables = @([regex]::Matches($message, '(?i)\b(?:output table|table|output stream)\s+\\?[''"](?<table>[^''"\\]+)\\?[''"]') | ForEach-Object { $_.Groups['table'].Value })
                    if ($resource.Kind -ne 'Dcr' -or $message -notmatch 'InvalidOutputTable' -or -not $outputTables -or
                        @($outputTables | Where-Object { $_ -notin @('Event', 'Syslog', 'Microsoft-Event', 'Microsoft-Syslog') }).Count) {
                        throw
                    }
                    Start-Sleep -Seconds 10
                }
            }
            # ---
            # 作成・更新した設定値をAzureから読み直し、作業記録の値と比べる。
            # Event・Syslogは、合計1,095日がテーブルごとに設定されていることも確認する。
            # ---
            $current = Invoke-ArmRequest -Resource $resource -Wait
            if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                throw "設定後の確認が一致しません: $($resource.Id)"
            }
        }

        # ---
        # 新しい診断設定を最大$parallelLimit件同時に作る。同じIDで設定値も同じなら、作成を省く。
        # 失敗した設定のID・理由・作成するはずだった値を集め、最後にcopy_failures.csvへ保存する。
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
                # 並列処理には共通関数が自動で渡らないため、common.ps1を読み込み、同じサブスクリプションの認証情報を使う。
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
# 失敗があれば理由と対象IDをcopy_failures.csvへ保存し、エラーで終了する。全件成功なら前回の失敗一覧を削除する。
# 旧診断設定・旧DCR関連付けは削除しない。新設定がそろったかの確認はstep2で行う。
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
