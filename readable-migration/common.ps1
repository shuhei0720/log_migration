#Requires -Version 7.0


# ---
# 設定するべき変数（変数の切り替えで開発・検証・本番共通で使用できる。）
# locationはストレージ用RG・Log Analytics・DCRのリージョン
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'setByAzurePlatformTeam'
$location = 'japaneast'

# ---
# 環境ごとの旧DCRとポリシー割り当てを指定し、後で完全なIDへ組み立てる。
# policyReferenceIdsは、initiative-<環境名>イニシアティブで除外する参照IDを指定する。
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
# 共通変数。基本変更しない。
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
# 割り当てのIDを組み立て、3件目だけ参照IDを付ける。最初の2件は割り当て全体を除外する。
$policyAssignments = @(for ($index = 0; $index -lt 3; $index++) {
    @{
        Id = "/providers/Microsoft.Management/managementGroups/$($settings.ManagementGroup)/providers/Microsoft.Authorization/policyAssignments/$($settings.Assignments[$index])"
        ReferenceIds = @(if ($index -eq 2) {
            $policyReferenceIds
        })
    }
})
# 別環境・別の移行条件の記録を再実行で使わないよう、照合に使う値をまとめる。
$migrationContext = @{
    Environment = $environment
    SourceWorkspace = $targetWorkspaceId
    OldDcrIds = $oldDcrIds
    DiagnosticName = $newDiagnosticSettingName
}
$recordDirectory = Join-Path $PSScriptRoot "records/$environment"
$ErrorActionPreference = 'Stop'
# Azure CLIとの間で日本語の設定名が文字化けしないよう、入出力をUTF-8にそろえる。
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = 'utf-8'

function Get-ArmAccessToken {
    <#
    .SYNOPSIS
    対象Subで使える認証トークンを返す。
    .DESCRIPTION
    トークンがない、対象Subが変わった、有効期限が近い場合だけAzure CLIで取得し直す。
    同じSubの通信では取得済みの値を使い、CLIの呼出しを繰り返さない。
    .PARAMETER SubscriptionId
    通信先のサブスクリプションID。
    .OUTPUTS
    System.String
    Azure APIの認証に使うトークン。
    #>
    param($SubscriptionId)
    # トークン未取得 or サブ切り替え後 or 期限切れ5分前でないか
    if (-not $script:accessToken -or $script:tokenSubscription -ne $SubscriptionId -or
        [long]$script:accessToken.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
        $script:accessToken = az account get-access-token --subscription $SubscriptionId --output json --only-show-errors | ConvertFrom-Json -AsHashtable
        if ($LASTEXITCODE -ne 0 -or -not $script:accessToken.accessToken) {
            throw 'Azureの認証情報を取得できません。az loginを確認してください。'
        }
        $script:tokenSubscription = $SubscriptionId
    }
    return $script:accessToken.accessToken
}

function New-ArmRequest {
    <#
    .SYNOPSIS
    Azureへの通信に使う引数を用意する。
    .DESCRIPTION
    URL・操作・認証情報をまとめ、設定本文があればUTF-8のJSONに変換する。
    1回の通信待機は300秒にし、本文受信の待機も対応するPowerShellで設定する。
    この関数では通信を行わない。
    .PARAMETER Uri
    接続先の完全なURL。
    .PARAMETER Method
    Get・Put・Patch・Delete・Postのいずれか。
    .PARAMETER Body
    送信する設定。取得・削除などで本文が不要なら$null。
    .PARAMETER AccessToken
    対象Subで取得した認証トークン。
    .OUTPUTS
    System.Collections.Hashtable
    Invoke-WebRequestへ渡す引数。
    #>
    param($Uri, $Method, $Body, $AccessToken)
    $request = @{
        Uri = $Uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $AccessToken" }
        ContentType = 'application/json; charset=utf-8'
        TimeoutSec = 300
    }
    if ($null -ne $Body) {
        $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Body -Depth 40))
    }
    # 本文受信の待機を設定できる環境でだけ指定し、非対応の引数で止まるのを避ける。
    if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
        $request.OperationTimeoutSeconds = 300
    }
    return $request
}

function Test-RetryableTransportError {
    <#
    .SYNOPSIS
    通信エラーが再送で回復し得る種類か判定する。
    .DESCRIPTION
    タイムアウト・接続切断・名前解決失敗を、例外の分類と内部原因から調べる。
    接続時と本文受信時では例外の形が違うため、両方を確認する。
    HTTP応答や利用者による中断の扱い、再送回数は呼出し元で判断する。
    .PARAMETER Exception
    Azureへの通信で発生した例外。
    .OUTPUTS
    System.Boolean
    再送候補なら$true、それ以外は$false。
    #>
    param($Exception)
    $cause = $Exception.GetBaseException()
    $networkError = [string]$Exception.HttpRequestError
    return $Exception -is [System.TimeoutException] -or
        $Exception.InnerException -is [System.TimeoutException] -or
        $networkError -in @('ConnectionError', 'ResponseEnded', 'NameResolutionError') -or
        ($cause -is [System.Net.Sockets.SocketException] -and [string]$cause.SocketErrorCode -in @('ConnectionAborted', 'ConnectionReset', 'NetworkReset', 'TimedOut', 'HostNotFound', 'TryAgain', 'NoData')) -or
        ($Exception -is [System.Net.Http.HttpRequestException] -and $networkError -in @('', 'Unknown') -and $cause -is [System.IO.IOException])
}

function Invoke-ArmRequest {
    <#
    .SYNOPSIS
    Azureのリソースを取得・作成・更新・削除する。
    .DESCRIPTION
    作業記録または直接指定された値から、接続先URLとJSON形式の送信本文を用意する。
    呼び出し元の$subscriptionIdで認証し、指定したAPIへ要求を送る。
    一時的な通信・HTTPエラーは最大4回試す。
    成功したJSON応答を辞書へ変換して返す。本文がない応答や、存在確認で許可した404は$nullを返す。
    作成状態が返される場合は、待機指定に従いGETでSucceededになるまで確認し、Failed・Canceledならエラーにする。
    再試行の対象外のエラーや、試行を使い切った失敗は呼び出し元へ伝える。
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
        $accessToken = Get-ArmAccessToken -SubscriptionId $subscriptionId
        $request = New-ArmRequest -Uri $uri -Method $Method -Body $Body -AccessToken $accessToken
        try {
            $response = Invoke-WebRequest @request -SkipHttpErrorCheck
        }
        catch [System.Net.Http.HttpRequestException], [System.IO.IOException], [System.TimeoutException], [System.Threading.Tasks.TaskCanceledException] {
            # ---
            # 一時的な切断・タイムアウトは再試行する。
            # DELETEの応答を失った後の404は、削除済みとして扱う。
            # ---
            $transportError = $_.Exception
            $retryTransport = Test-RetryableTransportError -Exception $transportError
            # HTTP応答付きのエラー・利用者の中断・再送対象外・4回目の失敗は、そのまま呼出し元へ返す。
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
                # 作成中という正常応答は通信失敗の回数に数えず、完了まで確認を続けるため試行数を戻す。
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
    Azureから取得した現在値や作業記録の値を、今回の期待値と比較する。
    診断設定・DCR・関連付けは書き込み用の本文にそろえ、Lifecycleは今回の保持ルールだけを調べる。
    辞書は項目ごとに値を比較し、配列は順番を問わず件数と要素を照合する。
    一致すれば$true、不足や相違があれば$falseを返し、一致済み設定の作成省略や削除・切り戻し前の判断に使う。
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
    # 送信設定は書き込み用の項目にそろえ、Lifecycleは今回の保持ルールを比べる。作成中は不一致とする。
    # Exactでは比較方向を入れ替えて2回照合し、期待値にない余分な項目も検出する。
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
    Azureから取得した設定を、作業記録への保存・再作成・比較に使う本文へ組み直す。
    診断設定のログ・メトリック・送信先や、DCR関連付けの参照先を取り出し、読み取り専用の値は除く。
    DCRは元データをコピーし、リージョン・タグ・マネージドIDを残したまま、Azureが付けた内部IDなどを取り除く。
    診断設定の格納方式はLog Analytics宛てかどうかに応じて補完・除去し、比較や再送信で使う本文を返す。
    入力がなければ$nullを返し、作成・更新が未完了ならエラーにする。
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
                    # ユーザー割当IDのリソースIDはキーとして残し、Azureが採番した内部値だけを除いて再PUTできる形にする。
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
    対象SubのIDに対応するrecords/<環境>/<Sub ID>.jsonを読み込む。
    環境・移行元などの作業条件と、対象Sub・保存先・送信先フラグが今回の指定と一致するか照合する。
    保存先・新設定・旧設定の3種類の一覧があることも確かめ、不一致や不足があれば記録を使わずエラーにする。
    確認した記録を返し、再実行・設定確認・削除・切り戻しで使う。ファイルがまだなければ、初回作業として扱えるよう$nullを返す。
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

function Read-MigrationTargets {
    <#
    .SYNOPSIS
    CSVを検査し、処理するサブスクリプション一覧を返す。
    .DESCRIPTION
    targets.csvの6列・必須値・送信先フラグ・名前を確認し、Sub名からIDを調べる。
    保存先ワークスペースのIDを補い、同じSubの重複や移行元との一致はエラーにする。
    Storage名があれば、地域別の名前に使うAzureの略称をregionNamesへ読み込む。
    .OUTPUTS
    System.Collections.IDictionary
    CSVの値にSubscriptionIdとWorkspaceIdを加えた対象一覧。
    #>
    $targets = @()
    $script:regionNames = @()
    $requiredColumns = @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')
    $csvRows = @(Import-Csv (Join-Path $PSScriptRoot 'targets.csv') -Encoding UTF8)
    if (-not $csvRows.Count) {
        throw 'CSVに対象がありません。'
    }
    # 列の欠落を入力ミスとして止め、送信終了を意味する意図的な空欄と区別する。
    $missingColumns = @($requiredColumns | Where-Object { $_ -notin $csvRows[0].PSObject.Properties.Name })
    if ($missingColumns.Count) {
        throw "CSVに必要な列がありません: $($missingColumns -join ', ')"
    }
    $accounts = az account list --all --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'サブスクリプション一覧を取得できません。'
    }
    foreach ($row in $csvRows) {
        $target = [ordered]@{}
        foreach ($name in $requiredColumns) {
            $target[$name] = ([string]$row.$name).Trim()
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
        # Storage宛ては名前を必須にし、指定された名前には地域置換用のjpeが1か所だけあることを確認する。
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
    if (@($targets | Group-Object { $_.SubscriptionId } | Where-Object Count -gt 1).Count) {
        throw '同じサブスクリプションが重複しています。'
    }
    if (@($targets | Where-Object StorageAccount).Count) {
        $script:regionNames = Invoke-RestMethod 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json'
    }
    return $targets
}

# ---
# 作成前の調査。対象の旧設定と、新設定の作成先を集める。
# ---
function Assert-NewResourceGroup {
    <#
    .SYNOPSIS
    保存先RGを今回の作業で使えるか確認する。
    .DESCRIPTION
    初回はCSV指定のRGが既にあれば停止する。
    中断後の再開では、同じ作業記録にあるRGだけを許可する。
    .PARAMETER Target
    対象Subと保存先RGを持つCSVの1行分。
    .PARAMETER Record
    再開時の作業記録。初回は指定しない。
    .OUTPUTS
    None
    使用できない場合はエラーにする。
    #>
    param($Target, $Record)

    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $existingGroup = Invoke-ArmRequest $resourceGroupId -ApiVersion $apiVersions.Group -Optional
    $recordedGroup = @($Record.Destinations | Where-Object { $_.Kind -eq 'Group' -and $_.Id -eq $resourceGroupId })
    if ($existingGroup -and $recordedGroup.Count -ne 1) {
        throw "CSVで指定したリソースグループは既に存在します: $resourceGroupId"
    }
}

function Get-MigrationResourceLocations {
    <#
    .SYNOPSIS
    診断設定を調べるリソースIDとリージョンを集める。
    .DESCRIPTION
    Subの全ページを読み、通常一覧にないStorageの各サービスとRedis Enterpriseの子DBを加える。
    子リソースには親のリージョンを付け、後のStorage選択に使う。
    .PARAMETER SubscriptionId
    調査するSubのID。
    .OUTPUTS
    System.Collections.Hashtable
    リソースIDをキー、リージョンを値にした辞書。
    #>
    param($SubscriptionId)

    $resourceLocations = @{}
    $resourcePage = "https://management.azure.com/subscriptions/$SubscriptionId/resources?api-version=2021-04-01"
    while ($resourcePage) {
        $page = Invoke-ArmRequest -ResourceId $resourcePage
        foreach ($resource in $page.value) {
            $resourceLocations[$resource.id] = $resource.location
            if ($resource.type -eq 'Microsoft.Storage/storageAccounts') {
                # 種別ごとに存在する子サービスだけを追加し、未対応サービスへの問合せを避ける。
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
    return $resourceLocations
}

function Get-ResourceDiagnosticSettings {
    <#
    .SYNOPSIS
    各リソースの診断設定と、移行元宛ての設定を調べる。
    .DESCRIPTION
    診断設定一覧を最大5件同時に取得し、全設定と移行元ワークスペース宛てを分ける。
    診断非対応だけは対象外とし、通信失敗などで調査できなければ停止する。
    .PARAMETER ResourceLocations
    調べるリソースIDとリージョンの辞書。
    .PARAMETER SubscriptionId
    認証に使う対象SubのID。
    .OUTPUTS
    System.Collections.Hashtable
    リソースごとのID、診断設定一覧、移行元宛ての設定。
    #>
    param($ResourceLocations, $SubscriptionId)

    $accessToken = $script:accessToken
    $sourceWorkspace = $targetWorkspaceId
    $listedSettings = @($ResourceLocations.Keys | ForEach-Object -Parallel {
        $result = @{ ResourceId = $_; Sources = @(); Settings = @(); Error = '' }
        try {
            # 並列処理は別の実行環境なので、共通定義と対象Subの認証情報を渡す。
            . $using:commonScript
            $subscriptionId = $using:SubscriptionId
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
    if ($listedSettings.Count -ne $ResourceLocations.Count) {
        throw '診断設定の調査結果が不足しています。'
    }
    foreach ($failed in @($listedSettings | Where-Object Error)) {
        throw "診断設定を調査できません: $($failed.ResourceId) / $($failed.Error)"
    }
    return $listedSettings
}

function Get-OldDiagnosticSettings {
    <#
    .SYNOPSIS
    旧診断設定を、復元できる本文で記録対象にする。
    .DESCRIPTION
    移行元宛ての診断設定からIDと書き込み可能な本文を取り出す。
    調査結果にも地域を補い、地域が空・globalなら東日本としてStorage選択に使う。
    .PARAMETER Diagnostics
    移行元宛ての診断設定を持つ調査結果。
    .PARAMETER ResourceLocations
    リソースIDとリージョンの辞書。
    .OUTPUTS
    System.Collections.Hashtable
    旧診断設定のId・Kind・Body。
    #>
    param($Diagnostics, $ResourceLocations)

    foreach ($diagnostic in $Diagnostics) {
        foreach ($source in $diagnostic.Sources) {
            @{
                Id = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($source.name))"
                Kind = 'Diagnostic'
                Body = Get-WritableBody -Resource $source -Kind 'Diagnostic'
            }
        }
        $resourceLocation = ([string]$ResourceLocations[$diagnostic.ResourceId] -replace '\s', '').ToLowerInvariant()
        if (-not $resourceLocation -or $resourceLocation -eq 'global') {
            $resourceLocation = 'japaneast'
        }
        $diagnostic.Location = $resourceLocation
    }
}

function Get-OldDcrAssociations {
    <#
    .SYNOPSIS
    指定した旧DCRに結び付く、対象Subの関連付けを集める。
    .DESCRIPTION
    旧2DCRの関連一覧を全ページ読み、対象Subの関連付けだけを取得する。
    参照先が調査中に変わっていないことを確認し、復元用の本文とともに返す。
    .PARAMETER SubscriptionId
    調査するSubのID。
    .OUTPUTS
    System.Collections.Hashtable
    旧関連付けのId・Kind・Body。
    #>
    param($SubscriptionId)

    foreach ($oldDcrId in $oldDcrIds) {
        $associationPage = "$oldDcrId/associations"
        while ($associationPage) {
            $page = Invoke-ArmRequest -ResourceId $associationPage
            if ($null -eq $page.value) {
                throw "旧DCRの関連一覧を取得できません: $oldDcrId"
            }
            foreach ($association in $page.value) {
                if ($association.id -notlike "/subscriptions/$SubscriptionId/*") {
                    continue
                }
                $current = Invoke-ArmRequest -ResourceId $association.id
                if ($current.properties.dataCollectionRuleId -ne $oldDcrId) {
                    throw "旧DCR関連の参照先が調査中に変わりました: $($association.id)"
                }
                @{
                    Id = $association.id
                    Kind = 'Association'
                    Body = Get-WritableBody -Resource $current -Kind 'Association'
                }
            }
            $associationPage = $page.nextLink
        }
    }
}

function Assert-PolicyAssignments {
    <#
    .SYNOPSIS
    適用除外に使う割り当てと参照IDが存在するか確認する。
    .DESCRIPTION
    対象Subに指定3割り当てが適用され、3件目に指定参照IDがあることを調べる。
    同じイニシアティブの定義は再取得せず、次のSubでも使う。
    .PARAMETER SubscriptionId
    調査するSubのID。
    .OUTPUTS
    None
    割り当てや参照IDが不足していればエラーにする。
    #>
    param($SubscriptionId)

    $assignments = @()
    $assignmentPage = "https://management.azure.com/subscriptions/$SubscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
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
}

function Get-StorageTargets {
    <#
    .SYNOPSIS
    地域別Storageの作成先を決め、名前とZRS対応を確認する。
    .DESCRIPTION
    診断対象の地域ごとにCSV名のjpeを置き換え、名前の形式・空き・ZRS対応を調べる。
    診断対象が0件なら東日本に作り、同じ記録での再開では記録済みIDの名前確認を省く。
    .PARAMETER Target
    対象Subと保存先名を持つCSVの1行分。
    .PARAMETER Diagnostics
    地域を補った旧診断設定の調査結果。
    .PARAMETER Record
    再開時の作業記録。
    .OUTPUTS
    System.Collections.Hashtable
    StorageごとのId・Name・Location。CSVにStorage名がなければ0件。
    #>
    param($Target, $Diagnostics, $Record)

    if (-not $Target.StorageAccount) {
        return
    }
    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $storageLocations = @($Diagnostics.Location | Sort-Object -Unique)
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
        @{
            Id = $storageId
            Name = $storageName
            Location = $storageLocation
        }
    }
}

function Get-DcrTargets {
    <#
    .SYNOPSIS
    新DCRと関連付けの作成先IDを決める。
    .DESCRIPTION
    旧関連がありVM側をLogにする場合に、保存先RG内の新DCRと各親リソースの関連IDを組み立てる。
    新旧IDが同じなら停止し、本文の組立てに使う作成先を返す。
    .PARAMETER Target
    対象Sub・保存先・VM送信フラグを持つCSVの1行分。
    .PARAMETER OldSettings
    調査した旧診断設定と旧DCR関連付け。
    .OUTPUTS
    System.Collections.Hashtable
    DcrのId・Nameと、AssociationsのID一覧。作成しない場合は空。
    #>
    param($Target, $OldSettings)

    $targets = @{ Dcr = $null; Associations = @() }
    $oldAssociations = @($OldSettings | Where-Object Kind -eq 'Association')
    if ($oldAssociations.Count -eq 0 -or $Target.VmLogDestination -ne 'Log') {
        return $targets
    }
    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $dcrName = $Target.WorkspaceName -replace '^log', 'dcr'
    $dcrId = "$resourceGroupId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    if ($dcrId -in $oldDcrIds) {
        throw "新旧DCRのIDが同じです: $dcrId"
    }
    $targets.Dcr = @{ Id = $dcrId; Name = $dcrName }
    $parentIds = @($oldAssociations.Id | ForEach-Object { $_ -replace "$associationPath/[^/]+$", '' } | Sort-Object -Unique)
    foreach ($parentId in $parentIds) {
        $associationId = "$parentId$associationPath/$dcrName"
        if ($associationId -in $oldAssociations.Id) {
            throw "新旧DCR関連のIDが同じです: $associationId"
        }
        $targets.Associations += @{ Id = $associationId }
    }
    return $targets
}

function Get-DiagnosticTargets {
    <#
    .SYNOPSIS
    新診断設定の作成先IDを決め、重複名と空き枠を確認する。
    .DESCRIPTION
    Storage・Log指定の場合だけ、旧設定に対応する新IDと送信先の地域を返す。
    旧設定が複数、新旧同名、記録外の同名設定、5枠使用済みなら作成前に停止する。
    .PARAMETER Target
    診断送信フラグを持つCSVの1行分。
    .PARAMETER Diagnostics
    地域を補った旧診断設定の調査結果。
    .PARAMETER OldSettings
    調査した旧設定。新旧IDの照合に使う。
    .PARAMETER Record
    再開時の作業記録。
    .OUTPUTS
    System.Collections.Hashtable
    新診断設定のId・OldId・Location。作成しない指定なら0件。
    #>
    param($Target, $Diagnostics, $OldSettings, $Record)

    if ($Target.LogDestination -notin @('Storage', 'Log')) {
        return
    }
    foreach ($diagnostic in $Diagnostics) {
        if ($diagnostic.Sources.Count -ne 1) {
            throw "対象の旧診断設定が複数あります: $($diagnostic.ResourceId)"
        }
        $newId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($newDiagnosticSettingName))"
        if ($newId -in $OldSettings.Id) {
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
        @{
            Id = $newId
            OldId = $oldId
            Location = $diagnostic.Location
        }
    }
}

function Get-MigrationPlan {
    <#
    .SYNOPSIS
    旧設定と新設定の作成先を調べ、作業計画にまとめる。
    .DESCRIPTION
    RGの確認、リソースと旧設定の調査、ポリシー・名前・空き枠の確認を順に呼び出す。
    旧設定の復元用本文と、新設定の本文を組み立てるためのID・地域を返す。Azureの設定は変更しない。
    .PARAMETER Target
    対象Sub・保存先・送信フラグを持つCSVの1行分。
    .PARAMETER Record
    再開時の作業記録。記録済みIDを初回の名前重複と区別する。
    .PARAMETER OnlyOldSettings
    確認・削除用に旧設定だけを調べ、作成前の検査を省く。
    .OUTPUTS
    System.Collections.Hashtable
    Context・Target・OldSettingsと、本文組立て用のDiscovery。設定本文の一覧は空で返す。
    #>
    param($Target, $Record, [switch]$OnlyOldSettings)

    $subscriptionId = $Target.SubscriptionId
    $plan = @{
        Context = $migrationContext
        Target = $Target
        Destinations = @()
        NewSettings = @()
        OldSettings = @()
    }
    if (-not $OnlyOldSettings) {
        Assert-NewResourceGroup -Target $Target -Record $Record
    }

    $resourceLocations = Get-MigrationResourceLocations -SubscriptionId $subscriptionId
    $listedSettings = @(Get-ResourceDiagnosticSettings -ResourceLocations $resourceLocations -SubscriptionId $subscriptionId)
    $diagnosticSources = @($listedSettings | Where-Object { $_.Sources.Count })
    $plan.OldSettings = @(Get-OldDiagnosticSettings -Diagnostics $diagnosticSources -ResourceLocations $resourceLocations)
    $plan.OldSettings += @(Get-OldDcrAssociations -SubscriptionId $subscriptionId)
    if ($OnlyOldSettings) {
        return $plan
    }

    Assert-PolicyAssignments -SubscriptionId $subscriptionId
    $discovery = @{
        Storages = @(Get-StorageTargets -Target $Target -Diagnostics $diagnosticSources -Record $Record)
        Dcr = $null
        Associations = @()
        Diagnostics = @()
    }
    $dcrTargets = Get-DcrTargets -Target $Target -OldSettings $plan.OldSettings
    $discovery.Dcr = $dcrTargets.Dcr
    $discovery.Associations = @($dcrTargets.Associations)
    $discovery.Diagnostics = @(Get-DiagnosticTargets -Target $Target -Diagnostics $diagnosticSources -OldSettings $plan.OldSettings -Record $Record)
    $plan.Discovery = $discovery
    return $plan
}

# ---
# 複製。作成する本文・変更前の値・作業記録を用意し、設定を反映する。
# ---
function New-PolicyExemptionSettings {
    <#
    .SYNOPSIS
    対象Subのポリシー適用除外の本文を作る。
    .DESCRIPTION
    環境別の3割り当てから、期限のないWaiverを組み立てる。
    最初の2件は全体、3件目は指定参照IDを除外する。Azureは変更しない。
    .PARAMETER SubscriptionId
    適用除外を作る対象SubのID。
    .OUTPUTS
    System.Collections.Hashtable
    適用除外のId・Kind・Body。
    #>
    param($SubscriptionId)
    foreach ($assignment in $policyAssignments) {
        $assignmentName = ($assignment.Id -split '/')[-1]
        $exemptionId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$assignmentName"
        @{
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
}

function New-LogAnalyticsDestinations {
    <#
    .SYNOPSIS
    保存先RGとLog Analyticsの本文を作る。
    .DESCRIPTION
    CSVの保存先IDを使い、指定地域のRGと保持90日のワークスペースを組み立てる。
    新送信を作らない指定でも準備対象にする。Azureは変更しない。
    .PARAMETER Target
    保存先RG名・ワークスペースIDを持つCSVの1行分。
    .OUTPUTS
    System.Collections.Hashtable
    RGとLog AnalyticsのId・Kind・Body。
    #>
    param($Target)
    $resourceGroupId = "/subscriptions/$($Target.SubscriptionId)/resourceGroups/$($Target.ResourceGroup)"
    @{
        Id = $resourceGroupId
        Kind = 'Group'
        Body = @{ location = $location }
    }
    @{
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
}

function New-StorageDestinations {
    <#
    .SYNOPSIS
    地域別Storageと付随設定の本文を作る。
    .DESCRIPTION
    調査済みの各Storage IDへ、ZRS・通信制限・Blobバージョン管理を設定する本文を作る。
    appendBlobの1095日ルールとDefender無効化も含める。Azureは変更しない。
    .PARAMETER Storages
    地域ごとのStorage ID・リージョンの一覧。
    .OUTPUTS
    System.Collections.Hashtable
    Storage・Blob・ライフサイクル・DefenderのId・Kind・Body。
    #>
    param($Storages)
    foreach ($storage in $Storages) {
        $storageId = $storage.Id
        $storageLocation = $storage.Location
        @{
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
        @{
            Id = "$storageId/blobServices/default"
            Kind = 'Blob'
            Body = @{ properties = @{ isVersioningEnabled = $true } }
        }
        @{
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
        @{
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
}

function New-VmLogTableSettings {
    <#
    .SYNOPSIS
    VMログの合計保持期間の本文を作る。
    .DESCRIPTION
    旧DCR関連付けがある場合だけ、Event・Syslogを合計1095日保持にする本文を作る。
    VM側の新送信を省略する指定でも対象にする。Azureは変更しない。
    .PARAMETER Target
    保存先ワークスペースIDを持つCSVの1行分。
    .PARAMETER OldSettings
    対象Subの旧診断設定・旧DCR関連付け。
    .OUTPUTS
    System.Collections.Hashtable
    Event・SyslogテーブルのId・Kind・Body。対象がなければ何も返さない。
    #>
    param($Target, $OldSettings)
    $oldAssociations = @($OldSettings | Where-Object { $_.Kind -eq 'Association' })
    if ($oldAssociations.Count -gt 0) {
        foreach ($tableName in @('Event', 'Syslog')) {
            @{
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
}

function New-DcrSettings {
    <#
    .SYNOPSIS
    新DCRと関連付けの本文を作る。
    .DESCRIPTION
    調査で新DCRの作成が決まった場合に、固定のWindowsイベント・Syslog収集条件を組み立てる。
    旧DCRに関連付いた対象から、新DCRへ送る関連付けも用意する。Azureは変更しない。
    .PARAMETER Target
    保存先ワークスペースIDを持つCSVの1行分。
    .PARAMETER Discovery
    新DCRのIDと関連付け先を持つ調査結果。
    .OUTPUTS
    System.Collections.Hashtable
    新DCR・関連付けのId・Kind・Body。作成しない場合は何も返さない。
    #>
    param($Target, $Discovery)
    if ($Discovery.Dcr) {
        $dcrId = $Discovery.Dcr.Id
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
        @{
            Id = $dcrId
            Kind = 'Dcr'
            Body = $dcrBody
        }
        foreach ($association in $Discovery.Associations) {
            $associationId = $association.Id
            $associationBody = @{ properties = @{ dataCollectionRuleId = $dcrId } }
            @{
                Id = $associationId
                Kind = 'Association'
                Body = $associationBody
            }
        }
    }
}

function New-DiagnosticSettings {
    <#
    .SYNOPSIS
    旧診断設定を引き継いだ新設定の本文を作る。
    .DESCRIPTION
    旧設定のログ・メトリックをコピーし、送信先だけをCSVの指定へ変える。
    Storageは対象のリージョンで選び、LogはワークスペースIDと旧格納方式を設定する。Azureは変更しない。
    .PARAMETER Target
    診断の送信先フラグ・ワークスペースIDを持つCSVの1行分。
    .PARAMETER Plan
    旧設定と、地域別Storage・新診断IDを持つ計画。
    .OUTPUTS
    System.Collections.Hashtable
    新診断設定のId・Kind・Before・Body。作成対象がなければ何も返さない。
    #>
    param($Target, $Plan)
    $storageIds = @{}
    foreach ($storage in $Plan.Discovery.Storages) {
        $storageIds[$storage.Location] = $storage.Id
    }
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
        @{
            Id = $diagnostic.Id
            Kind = 'Diagnostic'
            Before = $null
            Body = $diagnosticBody
        }
    }
}

function Set-MigrationBeforeValues {
    <#
    .SYNOPSIS
    切り戻しに使う変更前の値を計画へ加える。
    .DESCRIPTION
    Waiver・DCR・関連付けを取得し、計画のBeforeへ保存する。再実行では最初のBeforeを保つ。
    既存DCR・関連付けの変更しない値を引き継ぎ、新設DCRは切り戻しで残す印を付ける。
    .PARAMETER Plan
    Beforeと復元方針を加える計画。直接更新する。
    .PARAMETER Record
    前回の作業記録。初回はnull。
    .OUTPUTS
    なし。Planを更新する。
    #>
    param($Plan, $Record)
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
}

function Save-MigrationPlan {
    <#
    .SYNOPSIS
    照合した作業計画をSub別JSONへ保存する。
    .DESCRIPTION
    再実行では旧設定の変更・消失と、保存済みの作成値との差異を調べ、新規対象だけ追記する。
    変更があれば一時ファイルを置き換えて保存し、その記録を返す。Azure変更前に呼ぶ。
    .PARAMETER Plan
    今回調査した旧設定と、作成する設定の本文。
    .PARAMETER Record
    前回の作業記録。初回はnull。
    .PARAMETER SubscriptionId
    JSONファイル名に使う対象SubのID。
    .OUTPUTS
    System.Collections.Hashtable
    保存済みの作業記録。
    #>
    param($Plan, $Record, $SubscriptionId)
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
    return $record
}

function Register-MigrationProviders {
    <#
    .SYNOPSIS
    保存先とDCRに必要なサービスを利用登録する。
    .DESCRIPTION
    Insights・Log Analyticsと、Storageを作る場合のStorage・Securityの登録状態を調べる。
    未登録なら登録要求を送り、Registeredになるまで確認する。
    .PARAMETER Record
    Storageを作るか判定するための作業記録。
    .PARAMETER SubscriptionId
    利用登録する対象SubのID。
    .OUTPUTS
    なし。未登録サービスの利用登録を行う。
    #>
    param($Record, $SubscriptionId)
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
}

function New-ResourceUpdate {
    <#
    .SYNOPSIS
    既存値を保った更新要求の本文を作る。
    .DESCRIPTION
    作業記録の本文をコピーし、StorageのIP・VNet規則など、変更対象外の値を引き継ぐ。
    変更できない値の相違はエラーにし、既存ワークスペースとテーブルはPATCHを選ぶ。
    .PARAMETER Resource
    Id・Kind・Bodyを持つ作業記録の1項目。
    .PARAMETER Current
    現在のAzure応答。まだ存在しない場合はnull。
    .OUTPUTS
    System.Collections.Hashtable
    更新方法Methodと送信本文Body。
    #>
    param($Resource, $Current)
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
            $null -ne $_ -and $_.name -ne 'log-append-1095'
        }) + @($resource.Body.properties.policy.rules)
    }
    # 既存テーブルの列定義などを保つため、保持期間だけをPATCHで更新する。
    if ($current -and $resource.Kind -eq 'Table') {
        $method = 'Patch'
        $body = @{ properties = @{ totalRetentionInDays = 1095 } }
    }
    return @{ Method = $method; Body = $body }
}

function Invoke-ResourceUpdate {
    <#
    .SYNOPSIS
    1件の作成・更新要求をAzureへ送る。
    .DESCRIPTION
    更新要求を送り、DCRがEvent・Syslogの反映待ちで失敗した場合だけ10秒後に再送する。
    別の出力先の不足や、他のエラーは呼出し元へ伝える。
    .PARAMETER Resource
    操作先ID・種類を持つ作業記録の1項目。
    .PARAMETER Update
    作成・更新に使うMethodとBody。
    .OUTPUTS
    なし。指定した設定を作成・更新する。
    #>
    param($Resource, $Update)
    while ($true) {
        try {
            $null = Invoke-ArmRequest -Resource $resource -Method $Update.Method -Body $Update.Body
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
}

function Set-MigrationResource {
    <#
    .SYNOPSIS
    作業記録の1項目を設定し、結果を照合する。
    .DESCRIPTION
    現在値が期待値と一致していれば省略する。DCR・関連付けの外部変更や、不一致の既存Waiverは上書きしない。
    必要な設定だけを書き込み、作成完了を待ってGETで照合する。
    .PARAMETER Resource
    操作先Id・Kind・Body・Beforeを持つ作業記録の1項目。
    .OUTPUTS
    なし。不一致や作成失敗はエラーにする。
    #>
    param($Resource)
    $current = Invoke-ArmRequest -Resource $resource -Optional -Wait
    $currentBody = Get-WritableBody $current -Kind $resource.Kind
    $expected = $resource.Body
    # 作業記録にある作成済みRGは、再開時に存在だけを確認して使う。
    if ($resource.Kind -eq 'Group') {
        $expected = @{}
    }
    $matched = Test-Configuration $current $expected -Kind $resource.Kind
    # 日数が同じでも、ワークスペース既定値の継承ではテーブル個別の設定済みとみなさない。
    if ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault) {
        $matched = $false
    }
    if ($matched) {
        return
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
    $update = New-ResourceUpdate -Resource $Resource -Current $current
    Invoke-ResourceUpdate -Resource $Resource -Update $update
    $current = Invoke-ArmRequest -Resource $resource -Wait
    if (-not (Test-Configuration $current $expected -Kind $resource.Kind) -or
        ($resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
        throw "設定後の確認が一致しません: $($resource.Id)"
    }
}

function Copy-MigrationDiagnostics {
    <#
    .SYNOPSIS
    新診断設定を並列に作成し、結果を集める。
    .DESCRIPTION
    最大parallelLimit件を同時に処理し、一致済みは省略、不在は作成してGETで照合する。
    同名の別内容は変更せず、成功と失敗を1対象1件の結果にまとめる。
    .PARAMETER Settings
    作成する新診断設定のId・Kind・Body一覧。
    .PARAMETER SubscriptionId
    処理対象SubのID。並列処理の認証にも使う。
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    対象ID・失敗理由・失敗時の期待本文。成功時のReasonは空。
    #>
    param($Settings, $SubscriptionId)
    $accessToken = $script:accessToken
    $diagnostics = @($Settings)
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
            . $using:commonScript
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
    return $copied
}

# ---
# 確認・削除・切り戻し。記録と現在値を照合してから操作する。
# ---
function Assert-OldSettingsUnchanged {
    <#
    .SYNOPSIS
    記録後に旧設定が追加・変更されていないことを確認する。
    .DESCRIPTION
    現在見つかった旧設定を作業記録のID・本文と照合し、不一致なら停止する。
    削除の再開にも使うため、記録にだけ残る削除済みの旧設定は許可する。
    .PARAMETER Record
    step1で保存した作業記録。
    .PARAMETER CurrentSettings
    Azureから今回取得した旧診断設定・旧DCR関連付け。
    .OUTPUTS
    なし。不一致はエラー。
    #>
    param($Record, $CurrentSettings)
    foreach ($current in $CurrentSettings) {
        $saved = @($Record.OldSettings | Where-Object Id -eq $current.Id)
        if ($saved.Count -ne 1 -or -not (Test-Configuration $current.Body $saved[0].Body -Exact)) {
            throw "記録後に増えた旧設定か、変更された旧設定です: $($current.Id)"
        }
    }
}

function Test-MigrationResource {
    <#
    .SYNOPSIS
    保存先・新設定1件を確認し、CSV出力用の判定結果を返す。
    .DESCRIPTION
    現在値をGETして記録した作成値と照合する。RGは存在、テーブルは合計保持の個別指定も確認する。
    不一致や取得失敗もNGの結果として返し、呼出し元が残りの確認を続けられるようにする。
    .PARAMETER Resource
    確認する作業記録の1項目。
    .PARAMETER SubscriptionId
    接続先と判定結果に使う対象Sub ID。
    .OUTPUTS
    System.Management.Automation.PSCustomObject
    Sub・対象ID・OK/NG・理由・NG時の期待本文。
    #>
    param($Resource, $SubscriptionId)
    $result = [pscustomobject]@{
        SubscriptionId = $SubscriptionId
        ResourceId = $Resource.Id
        Result = 'OK'
        Reason = '一致'
        Expected = ''
    }
    try {
        $current = Invoke-ArmRequest -Resource $Resource -Optional
        $expected = $Resource.Body
        if ($Resource.Kind -eq 'Group') {
            $expected = @{}
        }
        if (-not (Test-Configuration $current $expected -Kind $Resource.Kind) -or
            ($Resource.Kind -eq 'Table' -and $current.properties.totalRetentionInDaysAsDefault)) {
            throw '必要な設定がないか、予定の値と異なります。'
        }
    }
    catch {
        $result.Result = 'NG'
        $result.Reason = $_.Exception.Message
        $result.Expected = ConvertTo-Json $Resource.Body -Depth 40 -Compress
    }
    return $result
}

function Get-ReplacementSetting {
    <#
    .SYNOPSIS
    旧送信設定に対応する新送信設定を作業記録から選ぶ。
    .DESCRIPTION
    旧IDから親リソースのIDを求め、新診断名または新DCR名で対応する記録を選ぶ。
    None・空欄は送信終了の指定なので、対応する新設定を返さない。
    .PARAMETER Record
    CSVの指定と新設定一覧を持つ作業記録。
    .PARAMETER OldSetting
    削除する旧診断設定または旧DCR関連付け。
    .OUTPUTS
    System.Collections.Hashtable
    対応する新設定。送信終了なら$null。必要な記録がなければエラー。
    #>
    param($Record, $OldSetting)
    $newId = ''
    if ($OldSetting.Kind -eq 'Diagnostic' -and $Record.Target.LogDestination -in @('Storage', 'Log')) {
        $parentId = $OldSetting.Id -replace "$diagnosticPath/[^/]+$", ''
        $settingName = [Uri]::EscapeDataString($newDiagnosticSettingName)
        $newId = "$parentId$diagnosticPath/$settingName"
    }
    if ($OldSetting.Kind -eq 'Association' -and $Record.Target.VmLogDestination -eq 'Log') {
        $parentId = $OldSetting.Id -replace "$associationPath/[^/]+$", ''
        $dcrName = $Record.Target.WorkspaceName -replace '^log', 'dcr'
        $newId = "$parentId$associationPath/$dcrName"
    }
    if (-not $newId) {
        return $null
    }
    $replacement = @($Record.NewSettings | Where-Object Id -eq $newId)
    if ($replacement.Count -ne 1) {
        throw '新設定の記録がありません。'
    }
    return $replacement[0]
}

function Remove-OldSetting {
    <#
    .SYNOPSIS
    削除直前に旧・新設定を照合し、旧設定1件を削除する。
    .DESCRIPTION
    旧設定が記録の本文と同じか確認し、送信を続ける側は対応する新設定も確認してからDELETEする。
    削除済みは省略する。変更・不足・API失敗は呼出し元へ伝え、以降の削除を止める。
    .PARAMETER Record
    対象Subと新設定一覧を持つ作業記録。
    .PARAMETER Setting
    削除する旧診断設定または旧DCR関連付けの記録。
    .OUTPUTS
    なし。
    #>
    param($Record, $Setting)
    $subscriptionId = $Record.Target.SubscriptionId
    $current = Invoke-ArmRequest -Resource $Setting -Optional
    if (-not $current) {
        return
    }
    $currentBody = Get-WritableBody $current -Kind $Setting.Kind
    if (-not (Test-Configuration $currentBody $Setting.Body -Exact)) {
        throw '削除直前に旧設定が変更されています。'
    }
    $replacement = Get-ReplacementSetting -Record $Record -OldSetting $Setting
    if ($replacement) {
        $currentNew = Invoke-ArmRequest -Resource $replacement -Optional
        if (-not (Test-Configuration $currentNew $replacement.Body -Kind $Setting.Kind)) {
            throw '削除直前の新設定が記録と一致しません。'
        }
    }
    $null = Invoke-ArmRequest -Resource $Setting -Method Delete
}

function Get-RollbackRecords {
    <#
    .SYNOPSIS
    切り戻すSubの作業記録を選び、実行条件を確認して返す。
    .DESCRIPTION
    records/<環境>/のJSONから全Subまたは指定Subを選ぶ。CSVは使わない。
    空指定・重複・未知のIDを拒否し、ファイル名と記録のSub ID、環境などの作業条件を照合する。
    .PARAMETER SubscriptionIds
    切り戻すSub IDの一覧。
    .PARAMETER FilterProvided
    利用者がSubscriptionIdsを指定した場合に付ける。未指定なら全記録を選ぶ。
    .OUTPUTS
    System.Collections.Hashtable
    選択した各Subの作業記録。対象なし・記録不一致はエラー。
    #>
    param($SubscriptionIds, [switch]$FilterProvided)
    $recordFiles = @(Get-ChildItem $recordDirectory -Filter '*.json')
    if ($FilterProvided) {
        $unknownIds = @($SubscriptionIds | Where-Object { $_ -notin $recordFiles.BaseName })
        if ($SubscriptionIds.Count -eq 0 -or $unknownIds.Count -gt 0 -or
            @($SubscriptionIds | Sort-Object -Unique).Count -ne $SubscriptionIds.Count) {
            throw '記録にあるSub IDを重複なく指定してください。'
        }
        $recordFiles = @($recordFiles | Where-Object { $_.BaseName -in $SubscriptionIds })
    }
    $records = @(foreach ($file in $recordFiles) {
        $saved = Get-Content $file.FullName -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
        if ($saved.Target.SubscriptionId -ne $file.BaseName) {
            throw '記録のSub IDとファイル名が一致しません。'
        }
        Read-MigrationRecord -Target $saved.Target
    })
    if (-not $records.Count) {
        throw '切り戻す記録がありません。'
    }
    return $records
}

function Assert-RollbackSetting {
    <#
    .SYNOPSIS
    切り戻す設定1件に、記録外の変更がないことを確認する。
    .DESCRIPTION
    現在値が記録のBody・Before・不在のいずれかであることを確認し、異なる変更はエラーにする。
    切り戻しでも残す新規DCR本体と元からあるWaiverは、取得・照合を省く。
    .PARAMETER Setting
    旧設定または新設定の作業記録。
    .OUTPUTS
    なし。不一致はエラー。
    #>
    param($Setting)
    if ($Setting.KeepOnRollback -or ($Setting.Kind -eq 'Exemption' -and $Setting.Before)) {
        return
    }
    $current = Get-WritableBody (Invoke-ArmRequest -Resource $Setting -Optional) $Setting.Kind
    $matchesBody = Test-Configuration $current $Setting.Body -Exact
    $matchesBefore = Test-Configuration $current $Setting.Before -Exact
    if ($current -and -not ($matchesBody -or $matchesBefore)) {
        throw "保存した値と異なる設定です: $($Setting.Id)"
    }
}

function Restore-MigrationSetting {
    <#
    .SYNOPSIS
    設定1件を旧本文または変更前の値へ戻す。
    .DESCRIPTION
    旧設定はBody、新設定はBeforeを復元値とし、一致済みを省く。復元直前の記録外の変更は上書きしない。
    診断設定の再作成には5枠の空きを確認し、値があればPUT、元が不在ならDELETEしてGETで照合する。
    保存対象の新規DCR本体・既存Waiverは変更しない。
    .PARAMETER Setting
    復元する旧設定または新設定の記録。
    .PARAMETER RestoreOld
    旧設定のBodyへ戻す場合に付ける。省略時は新設定をBeforeへ戻す。
    .OUTPUTS
    なし。
    #>
    param($Setting, [switch]$RestoreOld)
    if ($Setting.KeepOnRollback -or ($Setting.Kind -eq 'Exemption' -and $Setting.Before)) {
        return
    }
    $expectedBody = $Setting.Before
    if ($RestoreOld) {
        $expectedBody = $Setting.Body
    }
    $current = Get-WritableBody (Invoke-ArmRequest -Resource $Setting -Optional) $Setting.Kind
    if (Test-Configuration $current $expectedBody -Exact) {
        return
    }
    if ($current -and ($RestoreOld -or -not (Test-Configuration $current $Setting.Body -Exact))) {
        throw "切り戻し直前に設定が変わっています: $($Setting.Id)"
    }
    # 診断設定は最大5件。他の設定を削除して空きを作る処理は行わない。
    if ($Setting.Kind -eq 'Diagnostic' -and $expectedBody -and -not $current) {
        $listId = $Setting.Id -replace '/diagnosticSettings/[^/]+$', '/diagnosticSettings'
        $existing = Invoke-ArmRequest -ResourceId $listId -ApiVersion $apiVersions.Diagnostic
        if (@($existing.value).Count -ge 5) {
            throw "旧設定を戻す空きがありません: $($Setting.Id)"
        }
    }
    if ($null -eq $expectedBody) {
        $null = Invoke-ArmRequest -Resource $Setting -Method Delete
    }
    else {
        $null = Invoke-ArmRequest -Resource $Setting -Method Put -Body $expectedBody
    }
    $current = Invoke-ArmRequest -Resource $Setting -Optional -Wait
    $current = Get-WritableBody $current $Setting.Kind
    if (-not (Test-Configuration $current $expectedBody -Exact)) {
        throw "復元後の値を確認できません: $($Setting.Id)"
    }
}
