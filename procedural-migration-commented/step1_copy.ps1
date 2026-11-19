#Requires -Version 7.0
# ---
# 学習用コピー：このファイルは「診断設定・VM側の送信設定を複製する」入口です。
# 大きな流れは、1サブスクリプションずつ「現在を調査 → 予定を組立 → 記録を保存
# → 適用除外 → 保存先 → DCR・関連付け → 診断設定」と進みます。
# この段階では旧設定を削除しません。結果の確認はstep2、旧設定の削除はstep3です。
#
# 先頭の#RequiresはPowerShell 7以上での実行を求めます。
# 次の「. パス」はドットソースです。common.ps1の変数と5つの関数を読み込み、
# このファイルでも使えるようにします。$PSScriptRootはこのファイルのあるフォルダ、
# Join-Pathはフォルダ名とファイル名をつなぐコマンドです。
# コメント拡充版から実行すると、そのフォルダ内のcommon.ps1が読み込まれます。
# ---
. (Join-Path $PSScriptRoot 'common.ps1')
# ---
# 実行全体で使う入れ物を準備します。
# $failuresは失敗の一覧です。@()は配列を表し、ここでは空の配列から始めます。
# New-Itemは記録先フォルダを準備し、-Forceはフォルダがあっても処理を続けます。
# 「$null = コマンド」は結果の表示を捨てる書き方です。失敗を無視する指定ではありません。
# $nullは「値がない」を表し、空文字列や$falseとは別の値です。
# ---
$failures = @()
$null = New-Item $recordDirectory -ItemType Directory -Force

# ---
# サブスクリプションごとに調査し、変更前の設定を保存する
# 再実行では最初のBeforeを保持し、新しく見つかった対象だけ追記する。
# $targetsにはcommon.ps1が読み取ったCSVの各行と、解決済みのIDが入っています。
# foreachは配列を1件ずつ処理します。1周分のCSV行が$targetです。
# この外側のループは順番に実行されます。サブスクリプション同士の並列処理ではありません。
# ---
foreach ($target in $targets) {
    $subscriptionId = $target.SubscriptionId
    $resource = $null
    # ---
    # tryの中で停止するエラーが起きると、下部のcatchへ移ります。
    # catchは失敗を記録して次のサブスクリプションへ進むためのものです。
    # $resourceは現在扱っている設定です。まだ設定を選んでいない段階のエラーに備え、
    # 各サブスクリプションの開始時に$nullへ戻しています。
    # ---
    try {
        # ---
        # 保存済みの変更前記録を読み、その時点のAzureを調べて今回の$planを作ります。
        # precheckの出力は入力にしません。copyだけでも最新の対象調査と事前確認を行います。
        # Get-MigrationPlanは対象の旧診断設定・指定の旧DCRとの関連付けなどを調べ、
        # 名前の衝突などの確認も行います。ここではまだAzureへ設定を書き込みません。
        #
        # $planは複数の一覧を持つ辞書です。以後は次の区分へ必要な情報を追加します。
        # Destinations：RG・保存先・保持期間など。切り戻しでも保存先は残す区分です。
        # NewSettings：適用除外・新DCR・新しい関連付け・新診断設定です。
        # OldSettings：今回置き換える旧診断設定・旧DCR関連付けと、戻すための内容です。
        # Discovery：この実行で予定を組み立てるための調査情報です。記録保存前に取り除きます。
        # $()は文字列の中で式を評価する記法です。ここではCSVのResourceGroupを埋め込みます。
        # ---
        $record = Read-MigrationRecord -Target $target
        $plan = Get-MigrationPlan -Target $target -Record $record
        $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($target.ResourceGroup)"
        # ---
        # Waiverと、全行で準備するRG・Log Analyticsの設定値を指定する。
        # 環境ごとのポリシー割り当てから、サブスクリプション単位の適用除外を予定へ加えます。
        # -split '/'はIDを「/」で分け、[-1]は最後の要素、つまり割り当て名を取り出します。
        # この名前を固定の接頭辞と組み合わせ、再実行でも同じ除外IDを使います。
        # 参照IDの指定なしは割り当て全体、指定ありは列挙した参照IDを除外します。
        # Waiverを使い、有効期限は設けません。通常の移行完了時に自動削除もしません。
        # ---
        foreach ($assignment in $policyAssignments) {
            $assignmentName = ($assignment.Id -split '/')[-1]
            $exemptionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
            # ---
            # @{ キー = 値 }は辞書（ハッシュテーブル）です。+=は一覧の末尾へ追加します。
            # このスクリプト内の設定は、種類によらず主に次の共通項目で受け渡します。
            # Id：Azure上の設定を一意に表すリソースID。
            # Kind：Group、Workspace、Diagnosticなど、処理方法を選ぶための分類名。
            # Body：Azure APIへ送る予定の設定値。propertiesの内側に具体的な値を入れます。
            # Before：その設定を変更する前の値。後で取得し、切り戻しに使います。
            # KeepOnRollback：切り戻しで新DCRを残すかどうか。DCRの箇所で後から追加します。
            # Bodyを作って一覧に追加するだけではAzureは変更されません。書込みは記録保存後です。
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
        # 送信先のRGとLog AnalyticsワークスペースはCSVの全行で準備します。
        # 新しい送信設定を作るかどうかのフラグと、保存先を準備するかどうかは別です。
        # LogDestinationやVmLogDestinationがNone・空欄でも、これらの保存先は予定に入ります。
        # $Targetと$targetは同じ変数です。PowerShellの変数名は大文字・小文字を区別しません。
        # ---
        $plan.Destinations += @{
            Id = $resourceGroupId
            Kind = 'Group'
            Body = @{ location = $location }
        }
        # ---
        # ワークスペース全体の既定の保持期間は365日です。
        # EventとSyslogについては、後のテーブル設定で「合計保持期間」を1095日にします。
        # そのため、下の365を1095へ変える処理ではありません。
        # publicNetworkAccessは取込み・検索の公開ネットワーク利用を許可する設定です。
        # enableLogAccessUsingOnlyResourcePermissionsはリソース単位のアクセス権での参照を有効にします。
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
        # $storageIdsは「リージョン名 → ストレージのID」を引くための辞書です。
        # 例として$storageIds['japaneast']から東日本の保存先IDを取り出せます。
        # リージョンごとの名前はGet-MigrationPlanでCSVのjpe部分を略称に置換して決めています。
        # 診断設定の対象地域を使い、global・地域なしは東日本として扱います。
        # CSVにストレージ名を指定した場合は、送信フラグがNoneでも保存先を準備します。
        # 該当する旧診断設定がない場合の保存先地域も東日本です。
        # ---
        $storageIds = @{}
        foreach ($storage in $plan.Discovery.Storages) {
            $storageId = $storage.Id
            $storageLocation = $storage.Location
            $storageIds[$storageLocation] = $storageId
            # ---
            # リージョン1つにつき、Storage本体と、その子の設定を順番に予定へ追加します。
            # StorageV2・Standard_ZRS、基盤側暗号化、バージョン対応の不変ストレージを指定します。
            # これは下のライフサイクルの「1095日経過後に削除」とは別の設定項目です。
            # publicNetworkAccessがEnabledでも、networkAclsの既定はDenyです。
            # AzureServicesの例外を使い、匿名公開・共有キー認証を無効化してHTTPS/TLS1.2を要求します。
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
            # /blobServices/defaultはストレージ本体とは別の設定先です。
            # ここでBlobのバージョン管理を有効にします。Kindに応じたAPIは共通関数が選びます。
            # ---
            $plan.Destinations += @{
                Id = "$storageId/blobServices/default"
                Kind = 'Blob'
                Body = @{ properties = @{ isVersioningEnabled = $true } }
            }
            # ---
            # ライフサイクルはappendBlobを対象に、最終変更から1095日経過後の削除を指定します。
            # ここでいう3年は365×3＝1095日です。うるう年を数える暦年の指定ではありません。
            # 後の書込み処理では、移行用の旧365日ルールを置き換え、別名の既存ルールは残します。
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
            # このストレージではDefender for Storageを無効化する値を予定に加えます。
            # overrideSubscriptionLevelSettingsにより、サブスクリプション側の設定よりこちらを優先します。
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
        # |は前の結果を次のコマンドへ渡す記号、Where-Objectは条件に合う要素を選ぶコマンドです。
        # $_は渡されてきた1要素を表し、ここではKindがAssociationの旧設定だけを取り出します。
        # @(...)で囲むと0件・1件でも配列になり、.Countで件数を扱えます。-gt 0は「0より大きい」です。
        # 対象はcommon.ps1に指定した環境ごとの旧2DCRに関連付くVM・VMSSなどです。
        # 旧関連付けがなければ、VM側のテーブル準備や新DCR準備の対象にはなりません。
        # ---
        $oldAssociations = @($plan.OldSettings | Where-Object { $_.Kind -eq 'Association' })
        if ($oldAssociations.Count -gt 0) {
            # ---
            # EventとSyslogを同じ手順で処理し、テーブル単位の合計保持期間を1095日にします。
            # 合計とは通常の分析可能期間と長期保持を合わせた値です。
            # 旧DCR関連付けがあれば、新VM送信をNoneにした場合でもテーブルは準備します。
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
        # Discovery.Dcrは「旧DCR関連の対象があり、VmLogDestinationがLog」の場合に設定されます。
        # 値がなければこのifの中は実行せず、新DCRも新関連付けも作りません。
        # None・空欄の側も旧関連付けは記録されるため、最後のstep3では旧送信を終了できます。
        # ここで作るのは収集ルールと関連付けであり、VMやVMSSのリソース本体ではありません。
        # ---
        if ($plan.Discovery.Dcr) {
            $dcrId = $plan.Discovery.Dcr.Id
            $dcrBody = @{
                location = $location
                properties = @{}
            }
            # ---
            # DCRは「何を集めるか」「どこへ送るか」「両者をどう結ぶか」を持つ収集ルールです。
            # まずdataSourcesで、原本と同じWindowsイベントとSyslogの収集条件を指定します。
            # 旧DCRの全収集条件を複製する処理ではありません。
            # WindowsのxPathQueriesはApplication・Security・Systemのイベント選択式、
            # SyslogのfacilityNamesは分類、logLevelsは重要度の選択です。
            # streamsの名前は、後のdataFlowsでも同じ値を使います。
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
            # destinationsは保存先の定義です。new-workspaceはDCR内部だけで使う宛先名で、
            # workspaceResourceIdにはCSVから求めた実際のワークスペースIDを入れます。
            # dataFlowsで各streamをこの名前へ接続し、EventとSyslogを同じワークスペースへ送ります。
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
            # 調査で見つけた各VM・VMSS側の新しい関連付けを予定へ加えます。
            # 関連付けのdataCollectionRuleIdを新DCRに向け、収集ルールと対象を結びます。
            # 既存の同名関連付けがある場合の変更前内容は、後のBefore取得で確認・保存します。
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
        # Discovery.Diagnosticsには、旧診断設定が移行対象で、新診断設定を作るものだけが入ります。
        # LogDestinationがNone・空欄の行はこの一覧に入りませんが、旧設定はOldSettingsに残ります。
        # Where-Object Id -eq ...は条件の短い書き方、[0]は抽出された配列の先頭です。
        # 旧設定は指定した移行元ワークスペース宛てのものが対象です。
        # 移行対象外の別の診断設定を、このループで複製・変更することはありません。
        # ---
        foreach ($diagnostic in $plan.Discovery.Diagnostics) {
            $original = @($plan.OldSettings | Where-Object Id -eq $diagnostic.OldId)[0]
            $source = $original.Body.properties
            # ---
            # 旧設定のlogsとmetricsを、各要素の中身を作り直さず新しいBodyへ入れます。
            # そのため有効・無効、カテゴリ、カテゴリグループ、保持設定なども引き継ぎます。
            # Where-Objectの条件は$null要素を除くためのもので、enabled=falseを除く条件ではありません。
            # ---
            $diagnosticBody = @{
                properties = @{
                    logs = @($source.logs | Where-Object { $null -ne $_ })
                    metrics = @($source.metrics | Where-Object { $null -ne $_ })
                }
            }
            # ---
            # Storageなら診断対象と同じ地域のIDを$storageIdsから引きます。
            # LogならCSVのワークスペースIDと旧logAnalyticsDestinationTypeを設定します。
            # 新しいBodyには選択した保存先だけを入れ、旧設定にあった他の送信先は引き継ぎません。
            # ---
            if ($target.LogDestination -eq 'Storage') {
                $diagnosticBody.properties.storageAccountId = $storageIds[$diagnostic.Location]
            }
            else {
                $diagnosticBody.properties.workspaceId = $target.WorkspaceId
                $diagnosticBody.properties.logAnalyticsDestinationType = $source.logAnalyticsDestinationType
            }
            # ---
            # 新診断設定は同名の無関係な設定を上書きする用途ではないため、Beforeは$nullです。
            # 初回の同名衝突は事前調査で停止し、再実行では記録と一致する自分の設定だけをスキップします。
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
        # 変更前情報をそろえる段階です。診断設定以外のNewSettingsを1件ずつ確認します。
        # 保存先を残す方針なので、このループはDestinationsの変更前値を保存するものではありません。
        # 保存済みの記録に同じIDがあれば、最初に保存したBeforeをそのまま採用します。
        # Beforeが$nullでも「記録に項目がある」ことを優先します。初回作成後に再実行しても、
        # 現在の新設定を誤って「もともとあった設定」として記録し直さないためです。
        # ---
        foreach ($setting in @($plan.NewSettings | Where-Object Kind -ne 'Diagnostic')) {
            $saved = @($record.NewSettings | Where-Object Id -eq $setting.Id)
            if ($saved.Count) {
                $setting.Before = $saved[0].Before
            }
            else {
                # ---
                # 初めて記録する設定だけAzureの現状を取得します。-Optionalは存在しない場合を許容します。
                # Get-WritableBodyでID・状態などの読取り専用項目を除き、復元に使える設定値にします。
                # 存在しなかった場合のBeforeは$null、存在した場合はその変更前の内容になります。
                # ---
                $setting.Before = Get-WritableBody (Invoke-ArmRequest -Resource $setting -Optional) -Kind $setting.Kind
            }
            # ---
            # KeepOnRollbackがtrueになるのは、初回のBeforeが$nullだった新規DCRです。
            # 切り戻しでも収集ルール本体は残し、新しい関連付けを外して送信を戻す方針を表します。
            # 移行前から存在したDCRならfalseとなり、切り戻しではBeforeの内容を戻します。
            # ---
            if ($setting.Kind -eq 'Dcr') {
                $setting.KeepOnRollback = $null -eq $setting.Before
            }
            # ---
            # 既存DCR・関連付けを使う場合は、変更前のBodyを土台にし、今回指定したpropertiesだけを上書きします。
            # .Keysは辞書のキー一覧です。この内側のforeachで各設定項目を1つずつ置き換えます。
            # DCRのタグ・マネージドIDを含む書込み可能な属性、関連付けの説明やDCE参照など、
            # 今回の変更対象でない項目も土台に残します。DCRのlocationは所定の地域を指定します。
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
        # ---
        # 予定が完成したので、一時的な調査情報Discoveryを取り除きます。
        # 以降に保存する記録には、復元や再実行で使う対象ID・設定値を残します。
        # ---
        $plan.Remove('Discovery')

        # ---
        # 記録があれば今回の予定と突き合わせ、初回なら予定全体を新しい記録にします。
        # -notは真偽を反転します。記録がないと$recordChangedがtrueになります。
        # -Exactの比較は、保存した内容と今回の内容が一致するかを厳密に調べるための指定です。
        # まず記録済みの旧設定が今も同じかを確認し、途中で変わっていたら変更を進めず停止します。
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
            # 3つの一覧を同じ手順で照合します。$plan.$collectionは、変数に入った名前の一覧を選ぶ書き方です。
            # 前回以降に見つかった新しい対象は記録へ追記し、既存の記録を別の設定値へ置き換えません。
            # 同じIDなのに予定値が異なればthrowで停止します。記録を別の移行計画へ流用しないためです。
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
        # Azureへ変更を始める前に、変更前情報と予定値をサブスクリプションID.jsonへ保存します。
        # JSONは辞書や配列をファイルで保存できる文字列の形式です。-Depth 40で深い階層も出力します。
        # まず.tmpへ全体を書き、完成後にReplaceまたはMoveで本来の名前へ切り替えます。
        # これにより、既存の記録を直接書き換える途中で不完全なJSONになる事態を避けます。
        # このファイル更新とAzureの設定変更が一つの取引になるわけではありません。
        # records内の記録は、再実行・確認・削除・切り戻しで使うため保管してください。
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
        # ここからAzureへの書込みを行います。先に並べた$resourcesの順で1件ずつ進めます。
        # 順番は適用除外 → 保存先 → DCRと関連付けです。診断設定は後の並列処理に分けます。
        # 準備中のエラーは外側catchへ移り、そのサブスクリプションの残りを中断します。
        # 前に成功した書込みをここで自動的に戻す処理はないため、記録を基に再実行・切り戻しを行います。
        # ---
        $providersReady = $false
        $resources = @($record.NewSettings | Where-Object Kind -eq 'Exemption')
        $resources += @($record.Destinations)
        $resources += @($record.NewSettings | Where-Object { $_.Kind -notin @('Exemption', 'Diagnostic') })
        foreach ($resource in $resources) {
            # ---
            # 最初の適用除外以外の設定に進む直前に、必要なリソースプロバイダーを確認します。
            # プロバイダーはAzureのサービスを使うための利用登録で、例はMicrosoft.Storageです。
            # 未登録ならregisterを送り、3秒おきに最大5分の期限まで登録状態を確認します。
            # do...whileは、少なくとも1回処理してから継続条件を判定するループです。
            # $providersReadyがtrueになれば、この確認を設定1件ごとには繰り返しません。
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
            # 現在値を取得し、予定と同じならcontinueで次の設定へ進み、書込みを省きます。
            # -Optionalは未作成を許容し、-Waitは作成中・更新中なら完了状態を待つ指定です。
            # $currentはAzureからの応答、$currentBodyは書込み可能な形、$expectedは照合したい予定値です。
            # Groupは存在の確認を目的に$expectedを空の辞書にします。
            # Tableは値が1095でも「既定値に追随」のままなら一致扱いせず、明示指定へ更新します。
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
            # 予定と異なる既存設定を無条件に上書きしないための確認です。
            # 適用除外は同名で内容が異なれば停止します。
            # 既存DCR・関連付けを変更する場合も、現在の内容が記録したBeforeと一致することを求めます。
            # 既に今回の予定値と一致していれば、この手前でスキップされるため再実行できます。
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
            # 予定のBodyをJSONへ変換してから辞書へ戻し、書込み用の別コピーを作ります。
            # 単なる「$body = $resource.Body」だと同じ辞書を参照し、以下の調整が保存済み予定へ影響します。
            # -AsHashtableはJSONをPowerShellの辞書として読み取る指定です。
            # Putはリソースを作成・設定するAPI操作名です。既存の一部更新では後でPatchへ切り替えます。
            # ---
            $body = ConvertTo-Json $resource.Body -Depth 40 | ConvertFrom-Json -AsHashtable
            $method = 'Put'

            # ---
            # 既存の保存先で、変更対象以外の設定を残す
            # Storageの通信規則、LAのfeatures、他名のライフサイクルルールを保持する。
            # 既存ストレージを処理する際は、地域・SKU・暗号化・不変性が予定に合うかを先に確認します。
            # これらが違う保存先をこの処理で作り替えることはしません。
            # 通信規則は現状を土台にして既定動作とAzureServices例外だけを指定し、
            # 既存のIP規則・仮想ネットワーク規則などを残します。
            # 初回に同名ストレージがある場合は事前調査で停止するため、主に記録のある再実行で通る箇所です。
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
            # 既存ワークスペースは地域が合うことを確認し、Patchで指定項目を更新します。
            # 「A ?? B」はAが$nullならBを使うPowerShell 7の書き方です。
            # featuresが存在しなければ空の辞書を用意し、存在すれば元の機能設定を引き継ぎ、
            # 今回必要なenableLogAccessUsingOnlyResourcePermissionsだけをtrueへ設定します。
            # -replace '\s', ''は空白を除去し、Azureが返す地域表記を照合しやすくしています。
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
            # ライフサイクルのルールは配列です。現状から自分の365日・1095日ルールだけを除き、
            # 今回の1095日ルールを追加します。「+」はここでは配列を連結します。
            # そのほかの名前のルールは残し、自分のルールが再実行のたびに増えないようにします。
            # ---
            if ($resource.Kind -eq 'Lifecycle') {
                $body.properties.policy.rules = @($current.properties.policy.rules | Where-Object {
                    $null -ne $_ -and $_.name -notin @('log-append-365', 'log-append-1095')
                }) + @($resource.Body.properties.policy.rules)
            }
            # ---
            # 既存テーブルには合計保持期間だけをPatchします。
            # 最初に予定を作ったときのschemaなどを丸ごと送り直さず、分析用の保持期間・スキーマ・
            # プランといった既存の他項目を変更しないための書込み内容です。
            # ---
            if ($current -and $resource.Kind -eq 'Table') {
                $method = 'Patch'
                $body = @{ properties = @{ totalRetentionInDays = 1095 } }
            }
            # ---
            # DCRの宛先テーブルが未反映の場合だけ、5分の期限内で再送する。
            # DCRでは、直前に準備した宛先テーブルの情報がAPIへ反映するまで時間がかかる場合があります。
            # このwhileはDCRのInvalidOutputTableだけを10秒待って再試行します。
            # その他のエラーや期限超過はthrowで上へ渡し、際限なく繰り返しません。
            # while($true)自体は継続条件が常にtrueですが、成功時のbreakでループを抜けます。
            # API共通の一時エラーの再試行とは別の、このDCR向けの待機です。
            # ---
            $deadline = (Get-Date).AddMinutes(5)
            while ($true) {
                try {
                    $null = Invoke-ArmRequest -Resource $resource -Method $method -Body $body
                    break
                }
                catch {
                    # ---
                    # catchの中の$_は、処理対象リソースではなく発生したエラーを表します。
                    # Exception.MessageとErrorDetails.MessageからAzureのエラー内容を調べます。
                    # 引数なしのthrowは、捕まえた元のエラーを外側のcatchへ投げ直します。
                    # ---
                    $message = $_.Exception.Message + $_.ErrorDetails.Message
                    if ($resource.Kind -ne 'Dcr' -or $message -notmatch 'InvalidOutputTable' -or
                        (Get-Date).AddSeconds(10) -ge $deadline) {
                        throw
                    }
                    Start-Sleep -Seconds 10
                }
            }
            # ---
            # 書込みの受付だけで成功にせず、Azureから再取得した値が予定と合うかを確認します。
            # 一致しなければエラーとし、後続の新診断設定の作成へ進みません。
            # ここで確認するのは設定値であり、実際のログ到着の確認ではありません。
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
        # 必要な保存先などが整った後、新診断設定だけを並列に複製します。
        # ForEach-Object -Parallelは入力1件ごとの処理を別の実行領域で動かすPowerShell 7の機能です。
        # -ThrottleLimit $parallelLimitが同時実行数を制限します。既定値は5で、common.ps1で指定します。
        # @(...)で各処理の戻り値を$copied配列に集めます。戻る順番は入力順とは限りません。
        # ここで共有するのは準備済みの設定情報で、各並列処理は記録ファイルを書き換えません。
        # ---
        $accessToken = $script:accessToken
        $diagnostics = @($record.NewSettings | Where-Object Kind -eq 'Diagnostic')
        $copied = @($diagnostics | ForEach-Object -Parallel {
            # ---
            # この$_は並列処理へ渡された診断設定1件です。$resourceに名前を付けて扱います。
            # [pscustomobject]は名前付きの項目を持つ1行分の結果を作ります。
            # Reasonが空なら作成済み確認または今回の作成が成功、失敗時には理由と予定値を入れます。
            # 成功・失敗どちらも1件の結果を返し、後で件数不足も調べられる形にします。
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
                # 並列の実行領域には、親で読み込んだ関数がそのまま使えるとは限りません。
                # 同じcommon.ps1を-SkipCsv付きで読み、CSVを重ねて読むことなく関数などを用意します。
                # $using:名前は親の変数を並列処理へ渡す記法です。
                # $script:名前はその実行領域のスクリプトスコープにある変数を指します。
                # ここでは親のサブスクリプションIDと認証トークンを渡し、共通API関数の認証に使います。
                # トークン文字列自体を結果CSVへ出す処理ではありません。
                # ---
                . $using:commonScript -SkipCsv
                $subscriptionId = $using:subscriptionId
                $script:accessToken = $using:accessToken
                $script:tokenSubscription = $subscriptionId
                # ---
                # 診断設定も最初に現在値を見ます。記録の予定値と一致していれば結果を返して終了します。
                # このreturnはこの1件の並列処理から戻るもので、全サブスクリプションを終了しません。
                # 同名設定があるのに内容が違う場合は停止し、異なる設定を上書きしません。
                # 存在しない場合だけPutし、再取得して予定値との一致を確認します。
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
            # 1件の失敗はこのcatchで結果へ入れ、ほかの診断設定の処理は続けます。
            # Expectedは手動確認・設定に使う予定値です。-CompressはJSONを1行へまとめます。
            # 成功時も失敗時も末尾の$resultが親へ返る値になります。
            # ---
            catch {
                $result.Reason = $_.Exception.Message
                $result.Expected = ConvertTo-Json $resource.Body -Depth 40 -Compress
            }
            $result
        } -ThrottleLimit $parallelLimit)
        # ---
        # 入力件数と結果件数を比較し、結果が返らなかった設定があれば成功扱いしません。
        # Where-Object ReasonはReasonに値が入った結果を取り出す短い書き方です。
        # 成功結果は今回の結果配列にあり、失敗だけを全体の$failuresへ集めます。
        # ---
        if ($copied.Count -ne $diagnostics.Count) {
            throw '診断設定の複製結果が不足しています。'
        }
        $failures += @($copied | Where-Object Reason)
    }
    # ---
    # 外側のcatchは事前調査・記録保存・保存先準備などのエラーを拾います。
    # 理由と、分かる範囲で処理中のID・予定値を残し、このサブスクリプションの処理を終えます。
    # 調査中の失敗などで対象設定を選ぶ前なら、ResourceIdやExpectedに具体値がない場合もあります。
    # 外側foreach自体は続くため、後続のサブスクリプションも処理されます。
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
# 全サブスクリプションを処理し終えたら、未完了の結果をcopy_failures.csvへ出します。
# CSVはSubscriptionId・ResourceId・Reason・Expectedを持ち、utf8BOMで日本語も保存します。
# 失敗が1件でもあればファイル保存後にthrowで終了します。旧設定の削除は行いません。
# 成功した行だけのCSVは作りません。変更前記録と次のstep2による再確認を使います。
# ---
$failurePath = Join-Path $PSScriptRoot 'copy_failures.csv'
if ($failures.Count) {
    $failures | Export-Csv $failurePath -Encoding utf8BOM
    throw "未完了のSubがあります。$failurePath を確認して再実行してください。"
}
# ---
# 失敗がなければ、過去の実行で残った失敗CSVを消して、今回の結果と混同しないようにします。
# 最後の案内が出ても旧設定は残っています。step2で全体を確認してからstep3へ進みます。
# ---
if (Test-Path $failurePath) {
    Remove-Item $failurePath
}
Write-Host '旧設定を保持しました。step2で確認後、step3へ進んでください。'
