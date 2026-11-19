#Requires -Version 7.0
# ---
# Subごとに、現在の調査→計画→変更前記録の保存→保存先と新設定の作成を行う。
# 旧設定は残す。失敗はCSVへ出し、step2で全件確認してから別のstep3で削除する。
# commonを読み込むと、設定・CSVの対象・5関数が使える。
# ---
. (Join-Path $PSScriptRoot 'common.ps1')
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

# ---
# サブスクリプションごとに調査し、変更前の設定を保存する
# 再実行では最初のBeforeを保持し、新しく見つかった対象だけ追記する。
# SubはCSVの順に処理する。診断設定の取得と複製だけ、後述の上限付き並列を使う。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    try {
        # ---
        # precheckには依存せず、現在のAzureから計画を作る。
        # 記録があれば再実行として照合し、初回のBeforeを保持する。
        # OldSettingsは旧値、Destinationsは保存先、NewSettingsは新送信設定と適用除外。
        # 現時点の対象に追加があれば、再実行でも後の記録照合で追記できる。
        # ---
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        # ---
        # Waiverと、全行で準備するRG・Log Analyticsの設定値を指定する。
        # 環境別の3割り当てに、Sub単位のWaiverを計画する。期限なしで自動削除しない。
        # ---
        foreach ($assignment in $policyAssignments) {
            $assignmentName = ($assignment.Id -split '/')[-1]
            $exemptionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
            # ---
            # Idは操作先、Kindは処理種類、Bodyは予定値、Beforeは変更前の復元値。
            # ---
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
        # ---
        # RGとLAWは、None・空欄を含む全行で準備する。
        # すでに一致する保存先は後でスキップする。送信作成のフラグとは分けて扱う。
        # ---
        $plan.Destinations += @{
            Id = $resourceGroupId
            Kind = 'Group'
            Body = @{ location = $location }
        }
        # ---
        # LAW全体の既定保持は365日。Event・Syslogの合計保持は後で1095日に設定する。
        # 既存LAWは後で地域を確認し、指定した項目だけ更新する。
        # ---
        $plan.Destinations += @{
            Id = $Target.WorkspaceId
            Kind = 'Workspace'
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
        # 地域から保存先IDを引けるようにし、診断設定の複製時に使う。
        # ---
        $storageIds = @{}
        foreach ($storage in $plan.Discovery.Storages) {
            $storageId = $storage.Id
            $storageLocation = $storage.Location
            $storageIds[$storageLocation] = $storageId
            # ---
            # 地域ごとにStorageV2・Standard_ZRSの保存先を計画する。
            # TLS1.2、共有キー不可、公開Blob不可、基盤側暗号化とバージョン不変性を指定する。
            # ネットワークは既定拒否とし、AzureServicesの例外を指定する。
            # ---
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
            # ---
            # Storage本体とは別のBlob設定で、バージョン管理を有効にする。
            # ---
            $plan.Destinations += @{
                Id = "$storageId/blobServices/default"
                Kind = 'Blob'
                Body = @{ properties = @{ isVersioningEnabled = $true } }
            }
            # ---
            # appendBlobを最終変更から1095日後に削除する。3年は365×3として扱う。
            # 既存の他ルールを残す合成は、実際に書き込む段階で行う。
            # ---
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
            # ---
            # このStorageではDefenderを無効にし、Sub側の設定より個別設定を優先する。
            # ---
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
        # 旧VM対象があればテーブルを準備し、VM送信を続ける場合だけ新DCRに関連付ける。
        # 既存DCR・関連付けのその他の設定は、下のBefore取得で引き継ぐ。
        # 旧DCR関連がある場合は、VM側がNoneでもEvent・Syslogの保存先を準備する。
        # ---
        $oldAssociations = @($plan.OldSettings | Where-Object { $_.Kind -eq 'Association' })
        if ($oldAssociations.Count -gt 0) {
            # ---
            # EventとSyslogだけ、分析期間と長期保持を合わせた合計保持期間を1095日にする。
            # 既存の分析期間・スキーマ・プランは維持し、未作成テーブルは既定スキーマで準備する。
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
        }
        # ---
        # 旧関連がありVM側がLogの場合だけ、新DCRと関連付けを計画する。
        # VM・VMSS自体やエージェントを作る処理ではない。
        # ---
        if ($plan.Discovery.Dcr) {
            $dcrId = $plan.Discovery.Dcr.Id
            $dcrBody = @{
                location = $location
                properties = @{}
            }
            # ---
            # 原本と同じWindowsイベント・Syslogの収集条件を持つDCRを作る。
            # VM側の旧DCRを複製する方式ではなく、下の固定条件を使う。
            # ---
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
            # ---
            # DCR内部のnew-workspaceという宛先名に、CSVの新LAWを結び付ける。
            # dataFlowsが収集するストリームと、この宛先名を対応させる。
            # ---
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
            # ---
            # 調査対象だったVM・VMSSだけ、新DCRへの関連付けを計画する。
            # ---
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
        # 旧診断のログ・メトリックを引き継ぎ、選択された宛先だけを設定する。
        # None・空欄の行は新設定を作らず、OldSettingsには旧設定を残してstep3で外す。
        # ---
        foreach ($diagnostic in $plan.Discovery.Diagnostics) {
            $original = @($plan.OldSettings | Where-Object Id -eq $diagnostic.OldId)[0]
            $source = $original.Body.properties
            # ---
            # 旧診断設定のlogs・metricsは、無効項目やカテゴリ・保持設定も含めて引き継ぐ。
            # この後で新しい保存先だけを指定し、旧設定の他の宛先は追加しない。
            # 対象の旧LAWとは関係のない診断設定を、複製・削除の対象にはしない。
            # ---
            $diagnosticBody = @{
                properties = @{
                    logs = @($source.logs | Where-Object { $null -ne $_ })
                    metrics = @($source.metrics | Where-Object { $null -ne $_ })
                }
            }
            # ---
            # Storageは診断対象と同じ地域、LogはCSVのLAWを使う。
            # Logの場合は旧設定の格納方式も引き継ぐ。
            # ---
            if ($target.LogDestination -eq 'Storage') {
                $diagnosticBody.properties.storageAccountId = $storageIds[$diagnostic.Location]
            }
            else {
                $diagnosticBody.properties.workspaceId = $target.WorkspaceId
                $diagnosticBody.properties.logAnalyticsDestinationType = $source.logAnalyticsDestinationType
            }
            # ---
            # 新診断設定のBeforeはnull。同名の既存設定を流用する計画にはしない。
            # 再実行では記録済みの自分の設定だけ、内容一致を確認してスキップする。
            # ---
            $plan.NewSettings += @{
                Id = $diagnostic.Id
                Kind = 'Diagnostic'
                Before = $null
                Body = $diagnosticBody
            }
        }
        # ---
        # Waiver・DCR・関連付けの変更前情報をまとめて取得する。
        # 再実行は記録したBeforeを使い、DCR・関連の変更対象以外の項目も引き継ぐ。
        # 新設定側のBeforeをそろえる。保存先は切り戻しでも残すため、この取得対象に含めない。
        # ---
        foreach ($setting in @($plan.NewSettings | Where-Object Kind -ne 'Diagnostic')) {
            $saved = @($record.NewSettings | Where-Object Id -eq $setting.Id)
            if ($saved.Count) {
                $setting.Before = $saved[0].Before
            }
            else {
                # ---
                # 初めて扱う設定だけ現在値をGETし、復元できる本文としてBeforeに保存する。
                # 再実行では保存済みBeforeを使い、途中で作った値を変更前として取り直さない。
                # 元から存在しなければBeforeはnullとなり、切り戻しでは新規分だと判断できる。
                # ---
                $setting.Before = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) -Kind $setting.Kind
            }
            # ---
            # 新規DCR本体にはKeepOnRollbackを付け、切り戻しでも残す。
            # 送信は関連付けを外して戻す。既存DCRには変更前の復元値を残す。
            # ---
            if ($setting.Kind -eq 'Dcr') {
                $setting.KeepOnRollback = $null -eq $setting.Before
            }
            # ---
            # 既存DCR・関連付けはBeforeを土台に、今回指定するpropertiesだけを置き換える。
            # 指定外の元の項目を失わないための合成で、復元用Before自体は変えない。
            # ---
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
        $plan.Remove('Discovery')

        # ---
        # 一時的なDiscoveryを除き、保存済み記録と今回の計画を照合する。
        # Destinations・NewSettings・OldSettingsの各一覧で、新しい対象だけ追記する。
        # ---
        $recordChanged = -not $record
        if ($record) {
            foreach ($saved in $record.OldSettings) {
                $current = @($plan.OldSettings | Where-Object Id -eq $saved.Id)
                if ($current.Count -ne 1 -or -not (Test-Configuration $current[0].Body $saved.Body -Exact)) {
                    throw "記録した旧設定がないか、内容が変わっています: $($saved.Id)"
                }
            }
            # ---
            # 記録済みの同じIDは予定値が一致する必要がある。別内容への差し替えは停止する。
            # ---
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
        # Azureへ変更する前に、旧値・Before・予定値をSub IDのJSONへ保存する。
        # 一時ファイルから置換し、保存失敗なら書込みへ進まない。再実行でも最初のBeforeを保つ。
        # この記録はログのコピーではなく、送信設定を戻すための設定値の控え。
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
        # 適用除外、保存先、新しい送信設定の順に準備する
        # 一致する設定は書き込まない。失敗したSubは以降の処理を中断し、旧設定を残す。
        # 適用除外→保存先→DCRと関連付けの順に設定する。診断設定は後の並列処理へ分ける。
        # ---
        $providersReady = $false
        $resources = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
        $resources += @($record.Destinations)
        $resources += @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })
        foreach ($resource in $resources) {
            # ---
            # 適用除外が整った後、必要なリソースプロバイダーの利用登録を確認する。
            # 未登録なら登録を要求して完了を待つ。すでに登録済みならそのまま進む。
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
            # ---
            # 現在値が予定どおりなら書込みを省く。作成・更新中なら完了を待って確認する。
            # Tableは合計保持期間が既定値任せになっていないことも確かめる。
            # ---
            $current = Invoke-ArmRequest -Resource $resource -Optional -Wait
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
            # ---
            # 同名で内容が異なるWaiverは変更しない。DCR・関連付けはBeforeとの一致も必要。
            # 作業外の変更が入っていれば、上書きせず停止する。
            # ---
            if ($current -and $resource.Kind -eq 'Exemption') {
                throw '既存の適用除外が指定内容と異なります。'
            }
            if ($current -and $resource.Kind -in @('Dcr', 'Association')) {
                if (-not $resource.Before -or -not (Test-Configuration $currentBody $resource.Before -Exact)) {
                    throw "変更予定の設定が記録と異なります: $($resource.Id)"
                }
            }
            # ---
            # 予定Bodyを深い階層まで複製し、実際の書込み用に調整する。
            # 以降の変更が、記録へ保存した予定値へ影響しないようにする。
            # 記録自体を書き換えて、外部変更との比較条件を緩める処理ではない。
            # ---
            $body = ConvertTo-Json $resource.Body -Depth 40 | ConvertFrom-Json -AsHashtable
            $method = 'Put'

            # ---
            # 既存の保存先で、変更対象以外の設定を残す
            # Storageの通信規則、LAのfeatures、他名のライフサイクルルールを保持する。
            # 既存Storageは重要な構成を照合し、合うものだけを利用する。
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
            # ---
            # 既存LAWは地域を確認し、指定保持期間とリソース権限によるアクセスをPatchする。
            # ---
            if ($current -and $resource.Kind -eq 'Workspace') {
                if (($current.location -replace '\s', '') -ne $location) {
                    throw '既存Log Analyticsの地域が予定と異なります。'
                }
                $method = 'Patch'
                $body.properties.features = $current.properties.features ?? @{}
                $body.properties.features.enableLogAccessUsingOnlyResourcePermissions = $true
            }
            # ---
            # 自分の旧365日・現1095日ルールだけ入れ替え、他のライフサイクルルールは残す。
            # ---
            if ($resource.Kind -eq 'Lifecycle') {
                $body.properties.policy.rules = @($current.properties.policy.rules | Where-Object {
                    $null -ne $_ -and $_.name -notin @('log-append-365', 'log-append-1095')
                }) + @($resource.Body.properties.policy.rules)
            }
            # ---
            # 既存テーブルには合計保持期間だけをPatchし、スキーマや分析期間を変更しない。
            # ---
            if ($current -and $resource.Kind -eq 'Table') {
                $method = 'Patch'
                $body = @{ properties = @{ totalRetentionInDays = 1095 } }
            }
            # ---
            # DCRの宛先テーブルが未反映の場合だけ、5分の期限内で再送する。
            # DCRのInvalidOutputTableだけ、テーブル反映を待って再試行する。他の失敗は止める。
            # ---
            $deadline = (Get-Date).AddMinutes(5)
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
            # ---
            # 書込み後にGETし、予定値と一致して初めて完了とする。ログ到着の確認は行わない。
            # ---
            $current = Invoke-ArmRequest -Resource $resource -Wait
            if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
                ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
                throw "設定後の確認が一致しません: $($resource.Id)"
            }
        }

        # ---
        # 保存先が準備できたら、診断設定を最大5件ずつ複製する。
        # 一致する設定はスキップし、全件の結果を親へ返して失敗だけCSVにまとめる。
        # 保存先が整ってから新診断設定を並列複製する。workerは記録ファイルを書き換えない。
        # ---
        $accessToken = $script:accessToken
        $diagnostics = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        $copied = @($diagnostics | ForEach-Object -Parallel {
            # ---
            # 1件につき1結果を返す。Reasonが空なら成功、失敗時は理由と手動設定用の予定値を残す。
            # ---
            $resource = $_
            $result = [pscustomobject]@{
                SubscriptionId = $using:subscriptionId
                ResourceId = $resource.Id
                Reason = ''
                Expected = ''
            }
            try {
                # ---
                # 並列workerはcommonをSkipCsvで読み直す。usingで親のSubとトークンを受け取る。
                # script変数はworkerの実行領域で使うため、通常のローカル変数と区別する。
                # 同時実行数はcommonのparallelLimitで制限する。サブスクリプションは並列化しない。
                # ---
                . $using:commonScript -SkipCsv
                $subscriptionId = $using:subscriptionId
                $script:accessToken = $using:accessToken
                $script:tokenSubscription = $subscriptionId
                # ---
                # 既存の自分の新設定は内容一致なら省略し、異なれば上書きしない。
                # 未作成だけPUTして再取得・照合する。このreturnは今のworker1件だけを終える。
                # ---
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
            # ---
            # 1件の失敗を結果に入れ、他の診断設定の複製は続ける。
            # ---
            catch {
                $result.Reason = $_.Exception.Message
                $result.Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
            }
            $result
        } -ThrottleLimit $parallelLimit)
        # ---
        # 結果件数の不足も失敗とし、各結果のReasonがあるものを失敗一覧へ集める。
        # ---
        if ($copied.Count -ne $diagnostics.Count) {
            throw '診断設定の複製結果が不足しています。'
        }
        $failures += @($copied | Where-Object Reason)
    }
    # ---
    # 調査・保存先準備などで失敗したSubは理由を記録し、次のSubを処理する。
    # ここまでに完了した作成を自動で戻す処理はない。旧設定は残っている。
    # ---
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
# 失敗があればcopy_failures.csvへ対象・理由・予定値を出して終了する。
# 旧設定は削除しない。再実行か手動設定後、step2で全件を確認する。
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
