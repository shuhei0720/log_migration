#Requires -Version 7.0
# SkipCsvは定義だけ読み込み、CSV・サブスクリプション・リージョン略称の取得を省く。
param([switch]$SkipCsv)

# ---
# 実行する環境に合わせて変更する変数。
# locationは保存先RG・Log Analytics・DCRを作るリージョン。
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'setByAzurePlatformTeam'
$location = 'japaneast'

# ---
# 環境ごとの旧DCR・ポリシー割り当て。IDは下で組み立てる。
# policyReferenceIdsは3件目のイニシアティブで除外する参照ID。
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
# 以下は各スクリプトで使う共通設定。
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

function Invoke-ArmRequest {
    <#
    .SYNOPSIS
    Azureのリソースを取得・作成・更新・削除する。
    .DESCRIPTION
    呼び出し元の$subscriptionIdで認証し、指定したAPIへ要求を送る。
    一時的な通信・HTTPエラーは最大4回試す（初回を含む）。
    .PARAMETER ResourceId
    一覧取得などで直接操作するリソースID、またはAPI版を含む完全なURL。
    Resourceを指定する場合は不要。
    .PARAMETER Method
    Get＝取得、Put＝作成・更新、Patch＝更新、Delete＝削除、Post＝個別操作。省略時はGet。
    .PARAMETER Body
    作成・更新する設定の本文。切り戻しなどでResource.Bodyと異なる値を送るときに指定する。
    未指定のPut・Patch・PostではResource.Bodyを使う。
    .PARAMETER ApiVersion
    操作に使うAzure APIの版。ResourceIdに付ける。省略時は2024-03-11。
    Resource指定時はその項目から選び、完全なURLではURL内の版を使う。
    .PARAMETER Optional
    作成前・削除済みのリソースの存在確認に使う。
    404は未存在として$nullを返す。省略時はエラー。
    .PARAMETER Resource
    作業記録の1項目（Id・Kind・Body）をまとめて渡すときに使う。
    指定時はResourceId・ApiVersionより、この項目のID・API版を優先する。
    .PARAMETER Wait
    作成中の保存先を使わないよう、SucceededまでGETで待つ。Failed・Canceledはエラー。
    省略時は待たずに応答を返す。
    .OUTPUTS
    System.Object
    JSON応答を変換した辞書など。本文なし・Optional指定の404は$null。
    #>
    param($ResourceId, $Method = 'Get', $Body, $ApiVersion = '2024-03-11', [switch]$Optional, $Resource, [switch]$Wait)
    # ---
    # 作業項目からID・API版・本文を取り出すか、直接指定したIDからURLを作る。
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
    # 対象Subの認証情報を取得・更新し、本文があればJSONにして要求を送る。
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
            # 一時的な切断・タイムアウトは再試行する。
            # DELETEの応答を失った後の404は、削除済みとして扱う。
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
        # 成功したJSONを返す。Wait指定で作成途中ならGETを繰り返す。
        # 401は認証し直し、一時HTTPエラーは待って再試行する。
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

function Test-Configuration {
    <#
    .SYNOPSIS
    現在の設定が期待値と一致するか調べる。
    .DESCRIPTION
    作成済み設定のスキップ、移行後の確認、切り戻し前の確認に使う。
    Azureが追加した項目は通常無視し、配列の順番は区別しない。
    .PARAMETER Actual
    Azureの現在値、または作業記録から読み込んだ値。
    .PARAMETER Expected
    一致させたい保存先ID・保持期間・ログ設定など。
    .PARAMETER Kind
    Azureの応答を比較する形にそろえるために指定する。省略時は値だけを比べる。
    Diagnostic・Dcr・Associationは書き込み本文、Lifecycleは管理対象の保持ルールを比べる。
    .PARAMETER Exact
    他の変更を上書き・削除しないよう、余分な設定値も比べる。省略時はExpectedの項目を比べる。
    Diagnostic・Dcr・Associationでは自動的に有効。
    .OUTPUTS
    System.Boolean
    一致すれば$true、不足・相違があれば$false。
    #>
    param($Actual, $Expected, $Kind, [switch]$Exact)
    # ---
    # 作成中は不一致とし、送信設定は書き込み用の項目にそろえる。
    # Exactは双方の値を、Lifecycleは今回管理する保持ルールを比べる。
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
    # 配列は順番を問わず1件ずつ照合する。
    # 一致した要素を候補から除き、同じ要素を二重に数えない。
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
    # 辞書はExpectedの各項目を同じ関数で比べ、最後に文字列・数値などの単一値を比べる。
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

function Get-WritableBody {
    <#
    .SYNOPSIS
    取得した設定から、書き込み・比較に使う本文を作る。
    .DESCRIPTION
    Azureが返す内部IDなどを除き、旧設定の保存や作成・復元に使う。
    作成・更新が未完了ならエラーにする。
    .PARAMETER Resource
    Azureから取得した設定、または作業記録の本文。値がなければ$nullを返す。
    .PARAMETER Kind
    種類ごとに書き込める項目が違うため指定する。
    Diagnostic・Dcr・Associationは専用の項目を選び、その他はpropertiesから読み取り専用項目を除く。
    .OUTPUTS
    System.Collections.Hashtable
    書き込み可能なpropertiesなどを持つ本文。入力がなければ$null。
    #>
    param($Resource, $Kind)
    if (-not $Resource) {
        return $null
    }
    if ($Resource.properties.provisioningState -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw 'リソースの作成・更新が完了していません。'
    }
    # ---
    # propertiesから書き込む項目を取り出す。
    # DCRは元の値を変えないようコピーしてから、内部IDなどを除く。
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
    # LAW宛てだけ格納方式を含める。Storage宛てにもAzureが返すため、送信先に応じて除く。
    # ---
    if ($Kind -eq 'Diagnostic' -and $body.properties.workspaceId -and -not $body.properties.logAnalyticsDestinationType) {
        $body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'
    }
    if ($Kind -eq 'Diagnostic' -and -not $body.properties.workspaceId) {
        $body.properties.Remove('logAnalyticsDestinationType')
    }
    # ---
    # DCRのリージョン・タグ・マネージドIDを引き継ぎ、Azureが付けた内部IDなどは除く。
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

function Read-MigrationRecord {
    <#
    .SYNOPSIS
    サブスクリプションの作業記録を読み、今回の作業に使えるか調べる。
    .DESCRIPTION
    records/<環境>/<SubscriptionId>.jsonを読む。
    環境・移行元・CSVが一致しない記録は、誤って再利用しないようエラーにする。
    .PARAMETER Target
    対象Sub・保存先名・送信先フラグ（CSVまたは保存済み記録から取得）。
    SubscriptionIdで記録を選び、他の値も記録と一致するか調べる。
    .OUTPUTS
    System.Collections.Hashtable
    保存先・新設定・旧設定などの作業記録。ファイルがなければ$null。
    #>
    param($Target)
    $path = Join-Path $recordDirectory "$($Target.SubscriptionId).json"
    if (-not (Test-Path $path)) {
        return $null
    }
    $record = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    # ---
    # 記録の環境・CSVが今回と一致し、3種類の設定一覧があることを確認する。
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
# CSVから対象Sub・保存先名・送信先フラグを読み、IDを補ってtargetsへまとめる。
# Storage名をリージョン別に変換するため、地域略称も取得する。
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

function Get-MigrationPlan {
    <#
    .SYNOPSIS
    旧設定を調べ、保存先・新設定の作成前に必要な確認を行う。
    .DESCRIPTION
    指定したワークスペース宛ての診断設定と、旧2DCRへの関連付けを集める。
    保存先名・地域・新設定の追加枠・ポリシーも調べる。Azureの設定は変更しない。
    .PARAMETER Target
    対象Sub・保存先名・送信先フラグを持つCSVの1行分。
    調査する範囲と作成する保存先・新設定を決めるために使う。
    .PARAMETER Record
    中断後の再開で、自分が作成したIDを名前の重複とみなさないために使う。
    省略時は初回として、同名のStorage・新診断設定があれば停止する。
    .PARAMETER OnlyOldSettings
    作成後の確認・削除で、旧設定の追加・変更を調べるために指定する。
    作成済みの名前を調べ直さず、旧設定の収集で返す。省略時は作成前の確認も行う。
    .OUTPUTS
    System.Collections.Hashtable
    旧設定のID・本文と、保存先・新設定の予定。OnlyOldSettings指定時は作成予定を含まない。
    #>
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
    # Azureのリソース一覧から診断設定を調べるID・リージョンを集める。
    # 一覧にないStorageの各サービスとRedisの子DBも対象に加える。
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
            # Redis Enterpriseの子DBを取得し、親のリージョンを付ける。
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
    # 各リソースの診断設定から、移行元LAW宛てのものを選ぶ。
    # ID・本文をOldSettingsへ記録し、リージョンは後でStorageを選ぶために残す。
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
    # 旧2DCRの関連一覧から対象Subの関連付けを選び、ID・本文をOldSettingsへ追加する。
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
    # 指定した3ポリシー割り当てが対象Subに適用され、除外する参照IDが定義にあるか確認する。
    # 同じイニシアティブ定義は再取得せず、次のSubでも使う。
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
    # 診断設定があるリージョンごとにStorage名を作り、ZRS対応と名前の空きを調べる。
    # 作成するID・名前・リージョンをDiscovery.Storagesへまとめる。
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
    # 新DCR・関連付け・診断設定のIDを作り、名前の重複と追加枠を調べる。
    # IDをDiscoveryへまとめ、本文と変更前の値はstep1_copyで組み立てる。
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
