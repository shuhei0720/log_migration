#Requires -Version 7.0
param([switch]$SkipCsv)

# ---
# 移行元LAW・実行環境・追加する診断設定名を指定する。
# locationは新規RG・Log Analytics・DCRの配置先。Storageの地域は移行対象から決める。
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'setByAzurePlatformTeam'
$location = 'japaneast'

# ---
# 環境ごとの旧DCR2本とポリシー割り当て3件を指定し、後で完全なIDへ組み立てる。
# policyReferenceIdsは、3件目のイニシアティブで除外する参照IDを指定する。
# ---
$environmentSettings = @{
    prod = @{
        HubSubscriptionId = '7f043232-66a7-4d79-a660-fcb22d1644d0'
        ResourceGroup = 'rg-hub-prod-resource-01'
        DcrNames = @('dcr-hub-prod-vmInsights-01', 'logrule-hub-prod-vm-01')
        ManagementGroup = 'producrion'
        Assignments = @('6d924f0fa7a04145a1a00741', '71c38b62acf0433eb459b65b', '8dbf4e4a9a164f62969dc0ec')
    }
    stg = @{
        HubSubscriptionId = '40c16c7d-02f5-4529-ba94-8b754ccdb03e'
        ResourceGroup = 'rg-hub-stg-resource-01'
        DcrNames = @('dcr-hub-stg-vmInsights-01', 'logrule-hub-stg-vm-01')
        ManagementGroup = 'staging'
        Assignments = @('c0ddff1ad793418fb57fa3eb', '4ad819eb50c447a8a80b6c90', '75e82ef79a3447c3acab3d83')
    }
    dev = @{
        HubSubscriptionId = '43fc6c39-e53d-449d-9871-6d66f95ed2f3'
        ResourceGroup = 'rg-hub-sand-resource-01'
        DcrNames = @('dcr-hub-sand-vmInsights-01', 'logrule-hub-sand-vm-01')
        ManagementGroup = 'sandbox'
        Assignments = @('f6f0b49f9bd34e8fbb2c0304', '17fb86c1d07349769ff9b1a4', '0073f42c7cba4eef8454e06e')
    }
}
$policyReferenceIds = @(
    'Linux 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1'
    'Windows 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1'
    'App Serviceに対して診断設定を有効化する必要がある_1'
    'Kubernetes サービスに対して診断設定を有効化する必要がある_1'
    'ストレージ アカウントに対して診断設定を有効化する必要がある_1'
    'ストレージ アカウントのサブリソースに対して診断設定を有効化する必要がある_1'
    'App Serviceの関数アプリに対して診断設定を有効化する必要がある_1'
    'VMSSの均一モードでのデプロイを監査する_1'
    'Table service の診断設定を監査する_1'
    'File service の診断設定を監査する_1'
    'Blob service の診断設定を監査する_1'
    'Queue service の診断設定を監査する_1'
)

# ---
# 各工程で使う並列数・API版・リソースIDの接尾辞を用意する。
# 選んだ環境のDCR・ポリシーIDと、再開時の照合情報・JSON保存先もここで作る。
# ---
$parallelLimit = 5
$commonScript = $PSCommandPath
$diagnosticPath = '/providers/Microsoft.Insights/diagnosticSettings'
$associationPath = '/providers/Microsoft.Insights/dataCollectionRuleAssociations'
$apiVersions = @{
    Exemption = '2022-07-01-preview'
    Group = '2022-09-01'
    Workspace = '2023-09-01'
    Storage = '2023-05-01'
    Blob = '2023-05-01'
    Lifecycle = '2023-05-01'
    Defender = '2025-01-01'
    Table = '2025-07-01'
    Dcr = '2024-03-11'
    Association = '2024-03-11'
    Diagnostic = '2021-05-01-preview'
}
$settings = $environmentSettings[$environment]
if (-not $settings) {
    throw 'environmentはprod・stg・devから指定してください。'
}
$oldDcrIds = @(foreach ($name in $settings.DcrNames) {
    "/subscriptions/$($settings.HubSubscriptionId)/resourceGroups/$($settings.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$name"
})
$policyAssignments = @(for ($index = 0; $index -lt 3; $index++) {
    @{
        Id = "/providers/Microsoft.Management/managementGroups/$($settings.ManagementGroup)/providers/Microsoft.Authorization/policyAssignments/$($settings.Assignments[$index])"
        ReferenceIds = @(if ($index -eq 2) {
            $policyReferenceIds
        })
    }
})
$migrationContext = @{
    Environment = $environment
    SourceWorkspace = $targetWorkspaceId
    OldDcrIds = $oldDcrIds
    DiagnosticName = $newDiagnosticSettingName
}
$recordDirectory = Join-Path $PSScriptRoot "records/$environment"
$ErrorActionPreference = 'Stop'
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'

<#
.SYNOPSIS
リソースの取得・作成・更新・削除に使うAzure REST APIを呼び出す。
.DESCRIPTION
ResourceIdまたはResource.IdのAPIへMethod・Bodyを送り、JSON応答を各工程の作成・照合処理へ返す。
呼び出し側の$subscriptionIdでAzure CLIの認証情報を取得する。一時的な通信失敗・HTTPエラーは初回を含め最大4回試す。
.PARAMETER ResourceId
操作先のリソースID、またはAPI版を含む完全なURL。
.PARAMETER Method
Get・Put・Patch・Post・DeleteなどのHTTPメソッド。省略時はGet。
.PARAMETER Body
送信するpropertiesなどの本文。JSONへ変換して送る。Resource.Bodyより、明示したこの値を優先する。
.PARAMETER ApiVersion
Resourceを使わない場合に、リソースIDへ付けるAPI版。完全なURLではURL内の版を使う。
.PARAMETER Optional
指定したリソースがない場合の404を例外にせず、$nullを返す。
.PARAMETER Resource
Id・Kind・Bodyなどを持つ作業記録の1項目。操作先とAPI版はこの記録を優先し、Body未指定のPut・Patch・Postでは記録のBodyも使う。
.PARAMETER Wait
作成状態を持つ応答はprovisioningStateがSucceededになるまでGETで確認する。Failed・Canceledでは例外にする。
.OUTPUTS
System.Object
JSON応答を変換した辞書など。各工程はid・propertiesや一覧のvalue・nextLinkを取り出して使う。
本文がない場合やOptional指定時の404は$null。
#>
function Invoke-ArmRequest {
    param($ResourceId, $Method = 'Get', $Body, $ApiVersion = '2024-03-11', [switch]$Optional, $Resource, [switch]$Wait)
    # ---
    # Resourceに記録の1項目を渡した場合は、Id・API版・Bodyを取り出す。
    # ResourceIdだけの場合は、指定したIDとAPI版から接続先URLを作る。
    # ---
    if ($Resource) {
        $ResourceId = $Resource.Id
        $ApiVersion = $Resource.ApiVersion ?? $apiVersions[$Resource.Kind]
        if ($Method -in @('Put', 'Patch', 'Post') -and -not $PSBoundParameters.ContainsKey('Body')) {
            $Body = $Resource.Body
        }
    }
    $uri = $ResourceId
    if (-not $uri.StartsWith('https://')) {
        $uri = "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
    }
    $deleteResponseLost = $false
    # ---
    # 対象Subの認証情報が未取得・期限間近ならAzure CLIから取得し、要求を送る。
    # BodyがあればJSONへ変換し、Azureへ送信する本文にする。
    # ---
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        if (-not $script:accessToken -or $script:tokenSubscription -ne $subscriptionId -or
            [long]$script:accessToken.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
            $script:accessToken = az account get-access-token --subscription $subscriptionId --output json --only-show-errors | ConvertFrom-Json -AsHashtable
            if ($LASTEXITCODE -ne 0 -or -not $script:accessToken.accessToken) {
                throw 'Azureの認証情報を取得できません。az loginを確認してください。'
            }
            $script:tokenSubscription = $subscriptionId
        }
        $request = @{
            Uri = $uri
            Method = $Method
            Headers = @{ Authorization = "Bearer $($script:accessToken.accessToken)" }
            ContentType = 'application/json; charset=utf-8'
            TimeoutSec = 90
        }
        if ($null -ne $Body) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Body -Depth 40))
        }
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $request.OperationTimeoutSeconds = 90
        }
        try {
            $response = Invoke-WebRequest @request -SkipHttpErrorCheck
        }
        catch [System.Net.Http.HttpRequestException], [System.IO.IOException], [System.TimeoutException], [System.Threading.Tasks.TaskCanceledException] {
            # ---
            # HTTP応答が得られないエラーのうち、一時的な切断・タイムアウトなどを再試行する。
            # DELETEの応答だけ失った場合は、再試行時の404を削除済みとして扱う。
            # ---
            $transportError = $_.Exception
            $cause = $transportError.GetBaseException()
            $networkError = [string]$transportError.HttpRequestError
            $retryTransport = $transportError -is [System.TimeoutException] -or
                $transportError.InnerException -is [System.TimeoutException] -or
                $networkError -in @('ConnectionError', 'ResponseEnded', 'NameResolutionError') -or
                ($cause -is [System.Net.Sockets.SocketException] -and [string]$cause.SocketErrorCode -in @('ConnectionAborted', 'ConnectionReset', 'NetworkReset', 'TimedOut', 'HostNotFound', 'TryAgain', 'NoData')) -or
                ($transportError -is [System.Net.Http.HttpRequestException] -and $networkError -in @('', 'Unknown') -and $cause -is [System.IO.IOException])
            if ($transportError.StatusCode -or $transportError.Response -or
                ($transportError -is [System.Threading.Tasks.TaskCanceledException] -and $transportError.InnerException -isnot [System.TimeoutException]) -or
                -not $retryTransport -or $attempt -eq 3) {
                throw
            }
            if ($Method -eq 'Delete') {
                $deleteResponseLost = $true
            }
            Start-Sleep -Seconds 2
            continue
        }
        # ---
        # 成功応答のJSONを呼び出し元へ返す。Wait指定で作成途中ならGETを繰り返す。
        # 401は認証情報を更新し、一時HTTPエラーは待って再試行する。それ以外は例外にする。
        # ---
        $status = [int]$response.StatusCode
        if ($status -lt 400) {
            $result = $response.Content | ConvertFrom-Json -AsHashtable
            if ($Wait -and $result.properties.provisioningState -and $result.properties.provisioningState -ne 'Succeeded') {
                if ($result.properties.provisioningState -in @('Failed', 'Canceled')) {
                    throw "作成・更新に失敗しました: $ResourceId / $($result.properties.provisioningState)"
                }
                $Method = 'Get'
                $Body = $null
                Start-Sleep -Seconds 3
                $attempt = -1
                continue
            }
            return $result
        }
        if ($status -eq 404 -and ($Optional -or $deleteResponseLost)) {
            return $null
        }
        if ($status -eq 401 -and $attempt -lt 3) {
            $script:accessToken = $null
            continue
        }
        if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
            $delay = 2
            $retryAfter = [string]$response.Headers['Retry-After']
            if ($retryAfter -match '^\d+$') {
                $delay = [Math]::Max($delay, [int]$retryAfter)
            }
            Start-Sleep -Seconds $delay
            continue
        }
        throw "ARM $Method 失敗 ($status): $ResourceId / $($response.Content)"
    }
}

<#
.SYNOPSIS
Azureの現在値や作業記録を、期待する項目・値と比較する。
.DESCRIPTION
ActualとExpectedを比較し、copyのスキップやverifyのOK・NG、rollbackの復元判断に使う。
診断設定・DCR・DCR関連付けは書き込み用本文にそろえて比較する。配列の並び順は区別しない。
.PARAMETER Actual
照合元の値。AzureのGET応答、作業記録やその中の項目を渡す。
.PARAMETER Expected
期待する保存先ID・保持期間・ログやメトリックなどの項目と値。
.PARAMETER Kind
リソースの種類。Diagnostic・Dcr・Associationは書き込み項目を比較し、Lifecycleは新1095日ルールと旧365日ルールの残存を確認する。
.PARAMETER Exact
ActualとExpectedを双方向に比較する。Diagnostic・Dcr・Associationでは自動的に有効になる。
.OUTPUTS
System.Boolean
一致すれば$true、不足・相違があれば$false。各工程はこの結果でスキップ・NG・停止を判断する。
#>
function Test-Configuration {
    param($Actual, $Expected, $Kind, [switch]$Exact)
    # ---
    # Azureの作成状態を確認し、送信設定はGET応答とJSONの期待値を同じ項目にそろえる。
    # Exactなら双方を入れ替えて比較する。Lifecycleは管理対象の保持ルールだけを照合する。
    # ---
    if ($Kind -and $Actual.properties.provisioningState -and $Actual.properties.provisioningState -ne 'Succeeded') {
        return $false
    }
    if ($Kind -in @('Diagnostic', 'Dcr', 'Association')) {
        $Actual = Get-WritableBody $Actual -Kind $Kind
        $Expected = Get-WritableBody $Expected -Kind $Kind
        $Kind = $null
        $Exact = $true
    }
    if ($Exact) {
        return (Test-Configuration $Actual $Expected -Kind $Kind) -and
            (Test-Configuration $Expected $Actual -Kind $Kind)
    }
    if ($Kind -eq 'Lifecycle') {
        if (@($Actual.properties.policy.rules | Where-Object name -eq 'log-append-365').Count) {
            return $false
        }
        $Actual = @($Actual.properties.policy.rules | Where-Object name -eq 'log-append-1095')
        $Expected = @($Expected.properties.policy.rules)
    }
    # ---
    # ActualとExpectedの要素を1件ずつ対応させ、配列の並び順だけでは不一致にしない。
    # 対応した要素は候補から外し、同じ要素を二重に一致と数えない。
    # ---
    if ($Expected -is [array]) {
        [Collections.ArrayList]$remaining = @($Actual | Where-Object { $null -ne $_ })
        if ($remaining.Count -ne $Expected.Count) {
            return $false
        }
        foreach ($item in $Expected) {
            $matched = $false
            for ($index = 0; $index -lt $remaining.Count; $index++) {
                if (Test-Configuration $remaining[$index] $item) {
                    $remaining.RemoveAt($index)
                    $matched = $true
                    break
                }
            }
            if (-not $matched) {
                return $false
            }
        }
        return $true
    }
    # ---
    # 辞書はExpectedにある項目ごとにActualの値を取り出し、同じ関数で比較する。
    # 値なしの場合と、文字列・数値などの単一値もここで判定する。
    # ---
    if ($null -eq $Actual -or $null -eq $Expected) {
        return $null -eq $Actual -and $null -eq $Expected
    }
    if ($Expected -is [Collections.IDictionary]) {
        foreach ($key in $Expected.Keys) {
            if (-not (Test-Configuration $Actual.$key $Expected.$key)) {
                return $false
            }
        }
        return $true
    }
    return $Actual -eq $Expected
}

<#
.SYNOPSIS
AzureのGET応答から、照合・作成・復元に使える本文を取り出す。
.DESCRIPTION
propertiesからログ・メトリックや参照先DCRなどの書き込み項目を取り出す。
DCRはlocation・identityなども残し、Azureが返した内部IDやエンドポイントを除く。作成・更新が未完了なら例外にする。
.PARAMETER Resource
propertiesを持つAzureのGET応答、または作業記録のBody。値がなければ$nullを返す。
.PARAMETER Kind
Diagnostic（診断設定）・Dcr（収集ルール）・Association（DCR関連付け）に応じて取り出す項目を選ぶ。
.OUTPUTS
System.Collections.Hashtable
propertiesに書き込み可能な値を持つ本文。DCRではlocation・kind・tags・identityも含む。
旧設定の保存や、各工程のPUT・照合に使う。Resourceがなければ$null。
#>
function Get-WritableBody {
    param($Resource, $Kind)
    if (-not $Resource) {
        return $null
    }
    if ($Resource.properties.provisioningState -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw 'リソースの作成・更新が完了していません。'
    }
    # ---
    # GET応答のpropertiesから、PUTする項目をbody.propertiesへ取り出す。
    # DCRは入れ子のIDを削除するため、元のGET応答をコピーして使う。
    # ---
    $copy = $Resource
    if ($Kind -eq 'Dcr') {
        $copy = ConvertTo-Json $Resource -Depth 40 | ConvertFrom-Json -AsHashtable
    }
    $body = @{ properties = @{} }
    $keys = @($copy.properties.Keys)
    if ($Kind -eq 'Diagnostic') {
        $keys = @('logs', 'metrics', 'workspaceId', 'storageAccountId', 'eventHubAuthorizationRuleId', 'eventHubName', 'serviceBusRuleId', 'marketplacePartnerId', 'logAnalyticsDestinationType')
    }
    if ($Kind -eq 'Association') {
        $keys = @('description', 'dataCollectionRuleId', 'dataCollectionEndpointId')
    }
    foreach ($key in $keys) {
        if ($null -ne $copy.properties.$key -and $key -notin @('immutableId', 'provisioningState', 'endpoints', 'metadata', 'ingestionQuotas')) {
            $body.properties[$key] = $copy.properties.$key
        }
    }
    # ---
    # workspaceIdがある診断設定だけ、Log Analyticsの格納方式を本文に含める。
    # Storage宛てにAzureが返す格納方式は、比較・再送信する本文から除く。
    # ---
    if ($Kind -eq 'Diagnostic' -and $body.properties.workspaceId -and -not $body.properties.logAnalyticsDestinationType) {
        $body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'
    }
    if ($Kind -eq 'Diagnostic' -and -not $body.properties.workspaceId) {
        $body.properties.Remove('logAnalyticsDestinationType')
    }
    # ---
    # DCRのlocation・kind・tags・identityをPUT本文へ引き継ぐ。
    # 再作成時に指定できない内部IDやエンドポイントは除く。
    # ---
    if ($Kind -eq 'Dcr') {
        foreach ($key in @('location', 'kind', 'tags', 'identity')) {
            if ($null -ne $copy.$key) {
                $body[$key] = $copy.$key
            }
        }
        foreach ($destination in $body.properties.destinations.logAnalytics) {
            $destination.Remove('workspaceId')
        }
        foreach ($destination in $body.properties.destinations.monitoringAccounts) {
            $destination.Remove('accountId')
        }
        foreach ($destination in $body.properties.destinations.azureDataExplorer) {
            $destination.Remove('ingestionUri')
        }
        if ($body.identity) {
            $body.identity.Remove('principalId')
            $body.identity.Remove('tenantId')
            if ($body.identity.userAssignedIdentities) {
                foreach ($identityId in @($body.identity.userAssignedIdentities.Keys)) {
                    $body.identity.userAssignedIdentities[$identityId] = @{}
                }
            }
        }
    }
    return $body
}

<#
.SYNOPSIS
対象SubのJSONを読み、再開に使える変更前記録か確認する。
.DESCRIPTION
records/<環境>/<SubscriptionId>.jsonから、旧設定・保存先・新設定などの情報を読み込む。
JSON内のContextとTargetを今回の環境・移行元・CSVと比べ、別作業のJSONを再開に使うことを防ぐ。
.PARAMETER Target
CSVから作った対象Sub・保存先名・送信先フラグなどの情報。SubscriptionIdでJSONを選び、JSON内のTargetと比べる。
.OUTPUTS
System.Collections.Hashtable
Context・Target・Destinations・NewSettings・OldSettingsなどを持つ変更前記録。
各工程が作成結果の確認、旧設定の削除・復元に使う。初回でJSONがなければ$null。
#>
function Read-MigrationRecord {
    param($Target)
    $path = Join-Path $recordDirectory "$($Target.SubscriptionId).json"
    if (-not (Test-Path $path)) {
        return $null
    }
    $record = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    # ---
    # JSON内のContext・Targetと、今回の環境・CSVを照合する。
    # 保存先・新設定・旧設定の一覧がそろう場合だけ、後続の工程へ返す。
    # ---
    if (-not (Test-Configuration $record.Context $migrationContext -Exact) -or
        -not (Test-Configuration $record.Target $Target -Exact)) {
        throw "変更前記録と環境・CSVが一致しません: $path"
    }
    foreach ($name in @('Destinations', 'NewSettings', 'OldSettings')) {
        if ($record.$name -isnot [array]) {
            throw "変更前記録の一覧が不正です: $path / $name"
        }
    }
    return $record
}

# ---
# CSVの対象Sub・保存先名・送信先フラグを読み、Sub ID・Workspace IDを補ったtargets一覧を作る。
# Storage名があれば地域略称を取得し、後続のStorage名の変換に使う。
# ---
$targets = @()
$regionNames = @()
if (-not $SkipCsv) {
    $accounts = az account list --all --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'サブスクリプション一覧を取得できません。'
    }
    foreach ($row in Import-Csv (Join-Path $PSScriptRoot 'targets.csv') -Encoding UTF8) {
        $target = [ordered]@{}
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination')) {
            $target[$name] = ([string]$row.$name).Trim()
        }
        $target.VmLogDestination = 'Log'
        if ('VmLogDestination' -in $row.PSObject.Properties.Name) {
            $target.VmLogDestination = ([string]$row.VmLogDestination).Trim()
        }
        if ($target.LogDestination -notin @('Storage', 'Log', 'None', '') -or
            $target.VmLogDestination -notin @('Log', 'None', '')) {
            throw "CSVの送信先が不正です: $($target.SubscriptionName)"
        }
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'WorkspaceName')) {
            if (-not $target[$name]) {
                throw "CSVの必須値が空欄です: $name"
            }
        }
        if (($target.LogDestination -eq 'Storage' -and -not $target.StorageAccount) -or
            ($target.StorageAccount -and ($target.StorageAccount -cnotmatch '^[a-z0-9]{3,24}$' -or
            [regex]::Matches($target.StorageAccount, 'jpe').Count -ne 1))) {
            throw 'StorageAccountは小文字英数字3～24文字でjpeを1か所含む名前を指定してください。'
        }
        $matches = @($accounts | Where-Object { $_.id -eq $target.SubscriptionName -or $_.name -eq $target.SubscriptionName })
        if ($matches.Count -ne 1) {
            throw "サブスクリプションを一意に特定できません: $($target.SubscriptionName)"
        }
        $target.SubscriptionId = $matches[0].id
        $target.WorkspaceId = "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
        if ($target.WorkspaceId -eq $targetWorkspaceId) {
            throw '移行元と新しいワークスペースは別に指定してください。'
        }
        $targets += $target
    }
    if (-not $targets.Count -or @($targets | Group-Object { $_.SubscriptionId } | Where-Object Count -gt 1).Count) {
        throw 'CSVが空か、同じサブスクリプションが重複しています。'
    }
    if (@($targets | Where-Object StorageAccount).Count) {
        $regionNames = Invoke-RestMethod 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json'
    }
}

<#
.SYNOPSIS
Azureから旧診断設定・旧DCR関連を取得し、作成前の確認情報をまとめる。
.DESCRIPTION
targetWorkspaceIdのLAW宛ての診断設定と指定した旧2DCRの関連を取得し、IDと本文をOldSettingsへまとめる。
通常は保存先の地域・予定名・追加枠・適用ポリシーも確認し、copyで使う情報をDiscoveryへまとめる。Azureの設定は変更しない。
.PARAMETER Target
CSVの1行から作った、対象Sub ID・保存先名・診断設定とVMの送信先フラグなどの情報。
.PARAMETER Record
Read-MigrationRecordで読んだ変更前記録。Destinations・NewSettings内のIDを、再開時の名前重複判定に使う。
.PARAMETER OnlyOldSettings
OldSettingsの収集で終了し、保存先名・新設定の追加枠・ポリシーの確認を省く。verify・deleteが旧設定の増加や改変の確認に使う。
.OUTPUTS
System.Collections.Hashtable
OldSettings（旧設定のId・Kind・Body）を含む計画。通常はDiscovery（保存先や新設定のID・地域）も含む。
precheck・copy・verify・deleteが、作成前の確認や現在値との照合に使う。
#>
function Get-MigrationPlan {
    param($Target, $Record, [switch]$OnlyOldSettings)

    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $plan = @{
        Context = $migrationContext
        Target = $Target
        Destinations = @()
        NewSettings = @()
        OldSettings = @()
    }

    # ---
    # Azureのリソース一覧からID・地域を集め、診断設定を調べる対象IDを作る。
    # Storageの各サービスとRedisの子DBも対象に加える。
    # ---
    $resourceLocations = @{}
    $resourcePage = "https://management.azure.com/subscriptions/$subscriptionId/resources?api-version=2021-04-01"
    while ($resourcePage) {
        $page = Invoke-ArmRequest -ResourceId $resourcePage
        foreach ($resource in $page.value) {
            $resourceLocations[$resource.id] = $resource.location
            if ($resource.type -eq 'Microsoft.Storage/storageAccounts') {
                $services = switch ($resource.kind) {
                    'BlobStorage' {
                        'blobServices'
                    }
                    'BlockBlobStorage' {
                        'blobServices'
                    }
                    'FileStorage' {
                        'fileServices'
                    }
                    default {
                        @('blobServices', 'fileServices', 'queueServices', 'tableServices')
                    }
                }
                foreach ($service in $services) {
                    $resourceLocations["$($resource.id)/$service/default"] = $resource.location
                }
            }
            # ---
            # Redis Enterpriseのdatabase一覧から子DBのIDを集め、親のリージョンを付ける。
            # ---
            if ($resource.type -eq 'Microsoft.Cache/redisEnterprise') {
                $databasePage = "https://management.azure.com$($resource.id)/databases?api-version=2025-04-01"
                while ($databasePage) {
                    $databases = Invoke-ArmRequest -ResourceId $databasePage
                    foreach ($database in $databases.value) {
                        $resourceLocations[$database.id] = $resource.location
                    }
                    $databasePage = $databases.nextLink
                }
            }
        }
        $resourcePage = $page.nextLink
    }
    # ---
    # 各リソースの診断設定をAzureから取得し、targetWorkspaceIdのLAWへ送るものを選ぶ。
    # 設定IDとログ・メトリック等の本文をOldSettingsへ、地域を診断対象のLocationへ格納する。
    # ---
    $accessToken = $script:accessToken
    $sourceWorkspace = $targetWorkspaceId
    $listedSettings = @($resourceLocations.Keys | ForEach-Object -Parallel {
        $result = @{ ResourceId = $_; Sources = @(); Settings = @(); Error = '' }
        try {
            . $using:commonScript -SkipCsv
            $subscriptionId = $using:subscriptionId
            $script:accessToken = $using:accessToken
            $script:tokenSubscription = $subscriptionId
            $response = Invoke-ArmRequest -ResourceId "$($_)$diagnosticPath" -ApiVersion '2021-05-01-preview'
            $result.Settings = @($response.value)
            $result.Sources = @($response.value | Where-Object { $_.properties.workspaceId -eq $using:sourceWorkspace })
        }
        catch {
            if (($_.Exception.Message + $_.ErrorDetails.Message) -notmatch 'ResourceTypeNotSupported') {
                $result.Error = $_.Exception.Message
            }
        }
        $result
    } -ThrottleLimit $parallelLimit)
    if ($listedSettings.Count -ne $resourceLocations.Count) {
        throw '診断設定の調査結果が不足しています。'
    }
    foreach ($failed in @($listedSettings | Where-Object Error)) {
        throw "診断設定を調査できません: $($failed.ResourceId) / $($failed.Error)"
    }
    $diagnosticSources = @($listedSettings | Where-Object { $_.Sources.Count })
    foreach ($diagnostic in $diagnosticSources) {
        foreach ($source in $diagnostic.Sources) {
            $plan.OldSettings += @{
                Id = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($source.name))"
                Kind = 'Diagnostic'
                Body = Get-WritableBody -Resource $source -Kind 'Diagnostic'
            }
        }
        $resourceLocation = ([string]$resourceLocations[$diagnostic.ResourceId] -replace '\s', '').ToLowerInvariant()
        if (-not $resourceLocation -or $resourceLocation -eq 'global') {
            $resourceLocation = 'japaneast'
        }
        $diagnostic.Location = $resourceLocation
    }

    # ---
    # 旧2DCRの関連一覧から、このサブスクリプションのDCR関連付けを選ぶ。
    # 各関連の本体を取得し、IDと参照先DCR等の本文をOldSettingsへ追加する。
    # ---
    foreach ($oldDcrId in $oldDcrIds) {
        $associationPage = "$oldDcrId/associations"
        while ($associationPage) {
            $page = Invoke-ArmRequest -ResourceId $associationPage
            if ($null -eq $page.value) {
                throw "旧DCRの関連一覧を取得できません: $oldDcrId"
            }
            foreach ($association in $page.value) {
                if ($association.id -notlike "/subscriptions/$subscriptionId/*") {
                    continue
                }
                $current = Invoke-ArmRequest -ResourceId $association.id
                if ($current.properties.dataCollectionRuleId -ne $oldDcrId) {
                    throw "旧DCR関連の参照先が調査中に変わりました: $($association.id)"
                }
                $plan.OldSettings += @{
                    Id = $association.id
                    Kind = 'Association'
                    Body = Get-WritableBody -Resource $current -Kind 'Association'
                }
            }
            $associationPage = $page.nextLink
        }
    }
    if ($OnlyOldSettings) {
        return $plan
    }

    # ---
    # 対象Subに適用される割り当てを取得し、指定した3割り当てのIDが含まれるか確認する。
    # 3件目のイニシアティブ定義を読み、指定した参照IDが存在するか確認する。
    # 同じ定義は一度だけ取得し、次のSubでも使う。
    # ---
    $assignments = @()
    $assignmentPage = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
    while ($assignmentPage) {
        $page = Invoke-ArmRequest -ResourceId $assignmentPage
        $assignments += @($page.value)
        $assignmentPage = $page.nextLink
    }
    foreach ($assignment in $policyAssignments) {
        if ($assignment.Id -notin $assignments.id) {
            throw "ポリシー割り当てが適用されていません: $($assignment.Id)"
        }
    }
    $initiative = @($assignments | Where-Object { $_.id -eq $policyAssignments[2].Id })[0]
    $definitionId = $initiative.properties.policyDefinitionId
    if ($definitionId -notmatch '/policySetDefinitions/') {
        throw '3件目の割り当てがイニシアティブではありません。'
    }
    if ($script:initiativeDefinitionId -ne $definitionId) {
        $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion '2023-04-01'
        $script:initiativeDefinitionId = $definitionId
    }
    foreach ($referenceId in $policyAssignments[2].ReferenceIds) {
        if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) {
            throw "イニシアティブに参照IDがありません: $referenceId"
        }
    }

    $discovery = @{
        Storages = @()
        Dcr = $null
        Associations = @()
        Diagnostics = @()
    }

    # ---
    # 移行対象の診断設定がある地域ごとにStorage名とIDを作り、ZRS対応と名前の空きを調べる。
    # 作成するStorageのId・Name・LocationをDiscovery.Storagesへまとめる。
    # ---
    if ($Target.StorageAccount) {
        $storageLocations = @($diagnosticSources.Location | Sort-Object -Unique)
        if ($storageLocations.Count -eq 0) {
            $storageLocations = @('japaneast')
        }
        $skus = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus" -ApiVersion '2023-05-01'
        foreach ($storageLocation in $storageLocations) {
            $region = @($regionNames | Where-Object { ($_.name -replace '\s', '') -eq $storageLocation })
            if ($region.Count -ne 1 -or $region[0].shortName -cnotmatch '^[a-z0-9]+$') {
                throw "地域の略称を取得できません: $storageLocation"
            }
            $storageName = $Target.StorageAccount.Replace('jpe', [string]$region[0].shortName)
            if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') {
                throw "変換後のStorage名が不正です: $storageName"
            }
            if (-not ($skus.value | Where-Object { $_.name -eq 'Standard_ZRS' -and $_.kind -eq 'StorageV2' -and $storageLocation -in $_.locations })) {
                throw "Standard_ZRSを利用できません: $storageLocation"
            }
            $storageId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/$storageName"
            if ($storageId -notin @($Record.Destinations.Id)) {
                $availability = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/checkNameAvailability" -Method Post -ApiVersion '2023-05-01' -Body @{
                    name = $storageName
                    type = 'Microsoft.Storage/storageAccounts'
                }
                if (-not $availability.nameAvailable) {
                    throw "Storage名が使用済みです: $storageName"
                }
            }
            $discovery.Storages += @{
                Id = $storageId
                Name = $storageName
                Location = $storageLocation
            }
        }
    }

    # ---
    # 追加するDCR・DCR関連付け・新診断設定のIDを作り、新旧IDや診断設定名の重複・追加枠を確認する。
    # 各IDをDiscoveryへ渡す。送信する本文と変更前のBeforeはstep1_copyで組み立てる。
    # ---
    $oldAssociations = @($plan.OldSettings | Where-Object Kind -eq 'Association')
    if ($oldAssociations.Count -gt 0 -and $Target.VmLogDestination -eq 'Log') {
        $dcrName = $Target.WorkspaceName -replace '^log', 'dcr'
        $dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
        if ($dcrId -in $oldDcrIds) {
            throw "新旧DCRのIDが同じです: $dcrId"
        }
        $discovery.Dcr = @{
            Id = $dcrId
            Name = $dcrName
        }
        $parentIds = @($oldAssociations.Id | ForEach-Object { $_ -replace "$associationPath/[^/]+$", '' } | Sort-Object -Unique)
        foreach ($parentId in $parentIds) {
            $associationId = "$parentId$associationPath/$dcrName"
            if ($associationId -in $oldAssociations.Id) {
                throw "新旧DCR関連のIDが同じです: $associationId"
            }
            $discovery.Associations += @{ Id = $associationId }
        }
    }
    if ($Target.LogDestination -in @('Storage', 'Log')) {
        foreach ($diagnostic in $diagnosticSources) {
            if ($diagnostic.Sources.Count -ne 1) {
                throw "対象の旧診断設定が複数あります: $($diagnostic.ResourceId)"
            }
            $newId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($newDiagnosticSettingName))"
            if ($newId -in $plan.OldSettings.Id) {
                throw "新旧診断設定の名前が同じです: $newId"
            }
            $existing = @($diagnostic.Settings | Where-Object name -eq $newDiagnosticSettingName)
            if ($existing.Count -gt 0 -and $newId -notin @($Record.NewSettings.Id)) {
                throw "新しい診断設定名が使用済みです: $newId"
            }
            if ($existing.Count -eq 0 -and $diagnostic.Settings.Count -ge 5) {
                throw "診断設定を追加する空き枠がありません: $($diagnostic.ResourceId)"
            }
            $oldId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($diagnostic.Sources[0].name))"
            $discovery.Diagnostics += @{
                Id = $newId
                OldId = $oldId
                Location = $diagnostic.Location
            }
        }
    }
    $plan.Discovery = $discovery
    return $plan
}
