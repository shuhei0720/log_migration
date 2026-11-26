#Requires -Version 7.0
param([switch]$SkipCsv)


# ---
# 設定するべき変数（変数の切り替えで開発・検証・本番共通で使用できる。）
# locationはストレージ用RG・Log Analytics・DCRのリージョン
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'setByAzurePlatformTeam'
$location = 'japaneast'

# 環境ごとの旧DCRとポリシー割り当てを指定し、後で完全なIDへ組み立てる。
# policyReferenceIdsは、initiative-<環境名>イニシアティブで除外する参照IDを指定する。
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
# ---
# 指定した環境から旧DCR・ポリシーのIDと、作業記録の保存先を決める。
# 記録には環境・移行元・新診断名も残し、別の移行条件で再開することを防ぐ。
# ---
$settings = $environmentSettings[$environment]
if (-not $settings) {
    throw 'environmentはprod・stg・devから指定してください。'
}
$oldDcrIds = @(foreach ($name in $settings.DcrNames) {
    "/subscriptions/$($settings.HubSubscriptionId)/resourceGroups/$($settings.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$name"
})
# 適用除外を作る割り当てIDを組み立てる。1・2件目は割り当て全体、3件目は指定した参照IDだけを除外する。
$policyAssignments = @(for ($index = 0; $index -lt 3; $index++) {
    @{
        Id = "/providers/Microsoft.Management/managementGroups/$($settings.ManagementGroup)/providers/Microsoft.Authorization/policyAssignments/$($settings.Assignments[$index])"
        ReferenceIds = @(if ($index -eq 2) {
            $policyReferenceIds
        })
    }
})
# 今回の移行条件を、再実行時に作業記録と比べる値としてまとめる。
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

function Invoke-ArmRequest {
    <#
    .SYNOPSIS
    Azureへリソースの取得・作成・更新・削除を要求する。
    .DESCRIPTION
    リソースIDまたはURLと、取得・作成・更新・削除の操作を受け取り、Azure APIへ送る。
    作成・更新では、Bodyに渡した設定値をJSONにする。認証には$subscriptionIdのトークンを使う。
    一時的な通信・HTTPエラーは最大4回試す。
    Waitを付けると、Azureが作成・更新中の状態を返す間はGETで確認し、完了した結果を返す。
    応答のJSONを項目名と値の組で返し、本文がない場合は$nullを返す。
    再試行できないエラー、4回目でも解消しないエラー、作成の失敗・中止は呼び出し元へ伝える。
    .PARAMETER ResourceId
    操作するリソースID、またはAPIの版を含む完全なURL。
    Resourceを指定する場合は省略できる。
    .PARAMETER Method
    Getは取得、Putは作成・更新、Patchは一部更新、Deleteは削除、Postは個別操作。
    省略するとGetを使う。
    .PARAMETER Body
    作成・更新する設定値。Resourceにも作成値がある場合は、この引数の値を優先する。
    .PARAMETER ApiVersion
    リソースIDからURLを作るときに使うAPIの版。省略すると2024-03-11を使う。
    Resourceを渡す場合は、記録のAPI版か種類から選ぶ。完全なURLならURL内の版を使う。
    .PARAMETER Optional
    リソースの有無を調べるときに付ける。
    見つからない応答（HTTP 404）をエラーにせず、$nullで返す。省略時はエラーになる。
    .PARAMETER Resource
    作業記録の設定1件。Idは操作先、Kindは設定の種類、Bodyは作成する設定値を表す。
    IdとKindから接続先とAPIの版を選び、Body引数のないPut・Patch・Postでは記録の作成値を送る。
    .PARAMETER Wait
    作成・更新が完了するまで待つときに付ける。
    処理状態がSucceededになるまでGETし、Failed・Canceledならエラーにする。
    .OUTPUTS
    System.Object
    JSON応答を変換した辞書。本文がない場合と、Optionalを付けた404では$null。
    #>
    param($ResourceId, $Method = 'Get', $Body, $ApiVersion = '2024-03-11', [switch]$Optional, $Resource, [switch]$Wait)
    # ---
    # 1. 操作先のURLと、Azureへ送る設定値を決める。
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
    # 2. 操作するサブスクリプションで認証し、Azureへ要求を送る。
    # 通信失敗や一時的なHTTPエラーでは、この繰り返しで最大4回試す。
    # ---
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        # トークン未取得 or サブ切り替え後 or 期限切れ5分前でないか
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
            TimeoutSec = 300
        }
        if ($null -ne $Body) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $Body -Depth 40))
        }
        # 本文受信の待機時間は、その引数に対応するPowerShellでだけ設定する。
        if ((Get-Command Invoke-WebRequest).Parameters.ContainsKey('OperationTimeoutSeconds')) {
            $request.OperationTimeoutSeconds = 300
        }
        try {
            $response = Invoke-WebRequest @request -SkipHttpErrorCheck
        }
        catch [System.Net.Http.HttpRequestException], [System.IO.IOException], [System.TimeoutException], [System.Threading.Tasks.TaskCanceledException] {
            # 応答を受け取れなかった場合に、通信エラーの原因から再送できるか判断する。
            # DELETEの応答だけを失った場合は、再送時の404を削除完了として扱う。
            $transportError = $_.Exception
            $cause = $transportError.GetBaseException()
            $networkError = [string]$transportError.HttpRequestError
            # タイムアウト・接続切断・名前解決失敗を再送の候補にする。
            # 同じ通信障害でも例外の形が違うため、例外の分類と内部の原因を調べる。
            $retryTransport = $transportError -is [System.TimeoutException] -or
                $transportError.InnerException -is [System.TimeoutException] -or
                $networkError -in @('ConnectionError', 'ResponseEnded', 'NameResolutionError') -or
                ($cause -is [System.Net.Sockets.SocketException] -and [string]$cause.SocketErrorCode -in @('ConnectionAborted', 'ConnectionReset', 'NetworkReset', 'TimedOut', 'HostNotFound', 'TryAgain', 'NoData')) -or
                ($transportError -is [System.Net.Http.HttpRequestException] -and $networkError -in @('', 'Unknown') -and $cause -is [System.IO.IOException])
            # HTTP応答がある場合、利用者が中断した場合、再送対象でない場合、4回目の失敗では再送しない。
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
        # 3. Azureの応答から、結果を返すか、待って再確認するかを決める。
        # 作成中はGETで待ち、401は認証し直し、一時的なHTTPエラーは再送する。
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
                # 作成中の応答は通信失敗に数えない。回数を戻し、完了まで確認を続ける。
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
    二つの設定値を比べ、一致するか調べる。
    .DESCRIPTION
    比べる値をActual、正しいとする値をExpectedで受け取り、一致すれば$trueを返す。
    通常はExpectedにある項目を一つずつ調べ、Actualの同名項目が同じ値か確認する。
    Exactを付けると、ActualにExpected以外の項目が追加されていないことも確認する。
    診断設定・DCR・DCR関連付けは、Azureへ書き込める項目にそろえてから、余分な項目も含めて比べる。
    一覧は並び順を問わず中身と件数を比べる。ライフサイクルは今回のlog-append-1095ルールだけを調べる。
    Kindでリソースの種類を指定した場合は、作成・更新が完了していない応答を不一致にする。
    比較する項目や値が違う場合も$falseを返す。
    .PARAMETER Actual
    Azureから取得した設定値、または作業記録から読み込んだ値。
    .PARAMETER Expected
    正しいとする設定値。作成したい値や、切り戻し先の値を渡す。
    .PARAMETER Kind
    比べる設定の種類。Diagnosticは診断設定、DcrはDCR、AssociationはDCR関連付け。
    Lifecycleは今回の保持ルールを選ぶ。省略すると、渡された値をそのまま比べる。
    .PARAMETER Exact
    期待する項目の一致に加え、余分な項目がないことも確認するときに付ける。
    診断設定・DCR・DCR関連付けでは、指定しなくても有効になる。
    .OUTPUTS
    System.Boolean
    一致すれば$true。項目の不足や値の違いがあれば$false。
    #>
    param($Actual, $Expected, $Kind, [switch]$Exact)
    # ---
    # 1. 比較する項目を決める。作成中なら不一致とし、診断設定・DCR・関連付けは書込み項目にそろえる。
    # Exactでは両方向に比べ、Actualにだけ増えた項目も検出する。
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
    # 2. 値の形に合わせて比べる。一覧は順番を問わず、項目名のある値は項目ごとに調べる。
    # 一覧では一致した値を候補から外し、同じ値が重複していても件数を比べる。
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
    # 項目名がある値は、この関数で各項目を比べる。文字列・数値は最後に直接比べる。
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
    取得した設定から、保存・再作成・比較に使う設定値を取り出す。
    .DESCRIPTION
    Azureから取得した設定を受け取り、Azureへ送り直すための設定値を取り出す。
    診断設定ではログ・メトリック・送信先、DCR関連付けでは関連付けるDCRや収集エンドポイントのIDを残す。
    DCRでは収集条件・送信先・地域・タグ・マネージドIDを残し、Azureが付けた管理用の値を取り除く。
    診断設定のログ格納方式は、Log Analyticsへ送る設定にだけ含める。
    戻り値は作業記録への保存、設定の比較、切り戻しに使う。入力がなければ$nullを返す。
    作成・更新中の不完全な値を記録しないよう、完了していないリソースはエラーにする。
    .PARAMETER Resource
    Azureから取得した設定、または作業記録の設定値。$nullも渡せる。
    .PARAMETER Kind
    設定の種類。Diagnostic・Dcr・Associationでは、その種類で書き込める項目を取り出す。
    その他の種類では、propertiesから読み取り専用の項目を除く。
    .OUTPUTS
    System.Collections.Hashtable
    取り出した設定値を持つ辞書。入力がなければ$null。
    #>
    param($Resource, $Kind)
    # ---
    # 1. 取得が完了した設定から、Azureへ書き込める項目を取り出す。
    # ---
    if (-not $Resource) {
        return $null
    }
    if ($Resource.properties.provisioningState -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw 'リソースの作成・更新が完了していません。'
    }
    # DCRは複製したデータから管理用の値を取り除き、受け取ったデータを変えない。
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
    # 2. 診断設定とDCRで、作り直すときに必要な項目をそろえる。
    # Log Analyticsの格納方式は、そこへ送信する診断設定だけに残す。
    # ---
    if ($Kind -eq 'Diagnostic' -and $body.properties.workspaceId -and -not $body.properties.logAnalyticsDestinationType) {
        $body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'
    }
    if ($Kind -eq 'Diagnostic' -and -not $body.properties.workspaceId) {
        $body.properties.Remove('logAnalyticsDestinationType')
    }
    # DCRの地域・タグ・マネージドIDは残し、Azureが付けた管理用のIDだけを除く。
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
                    # ユーザー割り当てマネージドIDは、参照先のリソースIDだけを残して再送する。
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
    前回の作業記録を読み、今回も同じ条件で実行しているか確かめる。
    .DESCRIPTION
    対象サブスクリプションのIDから、records/<環境>/<Sub ID>.jsonを選んで読む。
    保存時の環境・移行元・保存先・送信方法を今回の指定と比べ、別の作業記録を使っていないか確認する。
    保存先・新設定・旧設定の一覧がそろっていれば記録を返し、条件の違いや一覧の不足はエラーにする。
    ファイルがまだなければ、初回実行として処理できるよう$nullを返す。
    .PARAMETER Target
    サブスクリプションID・保存先・送信方法を持つCSVの1行分、または記録済みのTarget。
    SubscriptionIdでファイルを選び、ほかの項目も記録の値と比べる。
    .OUTPUTS
    System.Collections.Hashtable
    読み込んだ作業記録。ファイルがなければ$null。
    #>
    param($Target)
    # ---
    # 1. 対象サブスクリプションの作業記録を読む。まだなければ初回として返す。
    # ---
    $path = Join-Path $recordDirectory "$($Target.SubscriptionId).json"
    if (-not (Test-Path $path)) {
        return $null
    }
    $record = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
    # ---
    # 2. 保存時の環境・CSVと今回の指定を比べ、設定一覧がそろっていることを確認する。
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
# CSVの各行を検査し、サブスクリプションIDと保存先IDを補った対象一覧targetsを作る。
# ストレージ名のjpeを置き換えるために、Azureの地域略称も取得する。
# ---
$targets = @()
$regionNames = @()
if (-not $SkipCsv) {
    $requiredColumns = @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination', 'VmLogDestination')
    $csvRows = @(Import-Csv (Join-Path $PSScriptRoot 'targets.csv') -Encoding UTF8)
    if (-not $csvRows.Count) {
        throw 'CSVに対象がありません。'
    }
    # 必須の列がない場合は止める。送信を終了するための空欄とは区別する。
    $missingColumns = @($requiredColumns | Where-Object { $_ -notin $csvRows[0].PSObject.Properties.Name })
    if ($missingColumns.Count) {
        throw "CSVに必要な列がありません: $($missingColumns -join ', ')"
    }
    # 日本語のサブスクリプション名もエスケープ表記で受け取り、JSON読込み時に元の文字へ戻す。
    # 式の空白は、PowerShellからaz.cmdへ引用符付きで渡し、括弧の誤解釈を防ぐために必要。
    $accounts = az account list --all --query 'to_string( @ )' --output tsv --only-show-errors | ConvertFrom-Json
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
        # ストレージへ送る行はアカウント名を必須にする。地域略称へ置き換えるjpeは1か所だけにする。
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
        $regionNames = Invoke-RestMethod 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json'
    }
}

function Get-MigrationPlan {
    <#
    .SYNOPSIS
    移行する旧設定を集め、新しい設定を作成できるか調べる。
    .DESCRIPTION
    CSVの1行を受け取り、そのサブスクリプションの旧設定と、新しい保存先・送信設定の作成場所を調べる。
    旧ワークスペース宛ての診断設定と旧2本のDCRへの関連付けを取得し、削除・復元に使う設定の一覧（OldSettings）へ入れる。
    既存の保存先は指定地域と一致するか確認し、新規のストレージは名前の空きとStandard_ZRSへの対応を調べる。
    新診断設定は、作業記録にない同名設定がある場合や、追加後に1リソース当たり5件を超える場合は作成できない。
    指定ポリシーが適用されていない場合も、エラーで止める。
    作成先のID・名前・地域は、一時的な項目（Discovery）にまとめて返す。
    step1_copyはDiscoveryからAzureへ送る設定値を作り、JSONへ保存する前にDiscoveryを除く。
    OnlyOldSettingsを付けた場合は旧設定だけを集め、名前やポリシーなど作成前の確認は省く。Azureの設定は変えない。
    .PARAMETER Target
    サブスクリプション・保存先名・送信方法を持つCSVの1行分。
    .PARAMETER Record
    中断後の再開に使う前回の作業記録。
    記録にある新診断設定は、今回作成したものとして再利用できる。
    .PARAMETER OnlyOldSettings
    step2・step3で、現在の旧設定だけを取得するときに付ける。
    リソースグループ・名前・ポリシーの作成前確認は行わない。
    .OUTPUTS
    System.Collections.Hashtable
    OldSettings（削除・復元する旧設定のIDと値）と、Discovery（新設定の作成先ID・名前・地域）を含む辞書。
    OnlyOldSettingsを付けた場合は、作成先を調べないためDiscoveryを含まない。
    #>
    param($Target, $Record, [switch]$OnlyOldSettings)

    # ---
    # 1. 対象と保存先を決め、既存のリソースグループは指定した地域と一致するか確認する。
    # ---
    $subscriptionId = $Target.SubscriptionId
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $plan = @{
        Context = $migrationContext
        Target = $Target
        Destinations = @()
        NewSettings = @()
        OldSettings = @()
    }

    # リソースグループは既存でも利用する。地域が違う場合は、設定を変更する前に止める。
    if (-not $OnlyOldSettings) {
        $existingGroup = Invoke-ArmRequest $resourceGroupId -ApiVersion $apiVersions.Group -Optional -Wait
        if ($existingGroup -and ($existingGroup.location -replace '\s', '') -ne $location) {
            throw "既存リソースグループの地域が予定と異なります: $resourceGroupId"
        }
        $existingWorkspace = Invoke-ArmRequest $Target.WorkspaceId -ApiVersion $apiVersions.Workspace -Optional -Wait
        if ($existingWorkspace -and ($existingWorkspace.location -replace '\s', '') -ne $location) {
            throw "既存Log Analyticsの地域が予定と異なります: $($Target.WorkspaceId)"
        }
    }

    # ---
    # 2. 診断設定を調べるリソースのIDと地域を集める。
    # 通常の一覧に出ないストレージの子サービスとRedisの子データベースも加える。
    # ---
    $resourceLocations = @{}
    $resourcePage = "https://management.azure.com/subscriptions/$subscriptionId/resources?api-version=2021-04-01"
    while ($resourcePage) {
        $page = Invoke-ArmRequest -ResourceId $resourcePage
        foreach ($resource in $page.value) {
            $resourceLocations[$resource.id] = $resource.location
            if ($resource.type -eq 'Microsoft.Storage/storageAccounts') {
                # アカウントの種類に合わせ、存在するBlob・File・Queue・Tableサービスだけを加える。
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
            # Redis Enterpriseの子データベースも列挙し、親と同じ地域を記録する。
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
    # 3. 旧ワークスペース宛ての診断設定と、旧DCRへの関連付けを集める。
    # 削除・復元する旧設定の一覧OldSettingsに、IDと設定値を入れる。
    # ---
    $accessToken = $script:accessToken
    $sourceWorkspace = $targetWorkspaceId
    $listedSettings = @($resourceLocations.Keys | ForEach-Object -Parallel {
        $result = @{ ResourceId = $_; Sources = @(); Settings = @(); Error = '' }
        try {
            # 並列処理でもAPIを呼べるよう、共通関数とこのサブスクリプションのトークンを用意する。
            . $using:commonScript -SkipCsv
            $subscriptionId = $using:subscriptionId
            $script:accessToken = $using:accessToken
            $script:tokenSubscription = $subscriptionId
            $response = Invoke-ArmRequest -ResourceId "$($_)$diagnosticPath" -ApiVersion '2021-05-01-preview'
            $result.Settings = @($response.value)
            $result.Sources = @($response.value | Where-Object { $_.properties.workspaceId -eq $using:sourceWorkspace })
        }
        catch {
            # 診断非対応のリソースは飛ばす。それ以外の取得失敗は記録し、調査後に処理を止める。
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

    # 旧2本のDCRの関連付けから、このサブスクリプションのものを選ぶ。
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
    # 4. 適用除外を作る3件のポリシー割り当てが、このサブスクリプションに適用されているか確認する。
    # 3件目は、まとめて割り当てたポリシーの中に、除外する12個の参照IDがあることも確認する。
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
    # 同じポリシーの組を次のサブスクリプションでも使うため、定義を取得済みなら読み直さない。
    if ($script:initiativeDefinitionId -ne $definitionId) {
        $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion '2023-04-01'
        $script:initiativeDefinitionId = $definitionId
    }
    foreach ($referenceId in $policyAssignments[2].ReferenceIds) {
        if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) {
            throw "イニシアティブに参照IDがありません: $referenceId"
        }
    }

    # 作成先のID・名前・地域をまとめる一時項目。Azureへ送る設定値はstep1_copyで作る。
    $discovery = @{
        Storages = @()
        Dcr = $null
        Associations = @()
        Diagnostics = @()
        ReusedDestinations = @()
    }
    # 作業前からある保存先だけ再利用する。前回このスクリプトが作ったものは、引き続き指定値で確認する。
    $createdIds = @($Record.Destinations | Where-Object { -not $_.Reuse } | ForEach-Object Id)
    if ($existingGroup -and $resourceGroupId -notin $createdIds) {
        $discovery.ReusedDestinations += $resourceGroupId
    }
    if ($existingWorkspace -and $Target.WorkspaceId -notin $createdIds) {
        $discovery.ReusedDestinations += $Target.WorkspaceId
    }

    # ---
    # 5. 地域別のストレージ名を作り、名前が未使用か、その地域でStandard_ZRSを使えるか確認する。
    # CSVにストレージ名がある場合だけ行う。新LAW自身もStorageへ送る場合は、その地域を加える。
    # ---
    if ($Target.StorageAccount) {
        $storageLocations = @($diagnosticSources.Location | Sort-Object -Unique)
        if ($Target.LogDestination -eq 'Storage') {
            $storageLocations = @(@($storageLocations) + $location | Sort-Object -Unique)
        }
        if ($storageLocations.Count -eq 0) {
            $storageLocations = @('japaneast')
        }
        $skus = $null
        foreach ($storageLocation in $storageLocations) {
            $region = @($regionNames | Where-Object { ($_.name -replace '\s', '') -eq $storageLocation })
            if ($region.Count -ne 1 -or $region[0].shortName -cnotmatch '^[a-z0-9]+$') {
                throw "地域の略称を取得できません: $storageLocation"
            }
            $storageName = $Target.StorageAccount.Replace('jpe', [string]$region[0].shortName)
            if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') {
                throw "変換後のStorage名が不正です: $storageName"
            }
            $storageId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/$storageName"
            $existingStorage = Invoke-ArmRequest $storageId -ApiVersion $apiVersions.Storage -Optional -Wait
            if ($existingStorage -and ($existingStorage.location -replace '\s', '') -ne $storageLocation) {
                throw "既存Storageの地域が予定と異なります: $storageId"
            }
            if ($existingStorage -and $storageId -notin $createdIds) {
                $discovery.ReusedDestinations += $storageId
            }
            if (-not $existingStorage) {
                if (-not $skus) {
                    $skus = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus" -ApiVersion '2023-05-01'
                }
                if (-not ($skus.value | Where-Object { $_.name -eq 'Standard_ZRS' -and $_.kind -eq 'StorageV2' -and $storageLocation -in $_.locations })) {
                    throw "Standard_ZRSを利用できません: $storageLocation"
                }
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
    # 6. 新DCR・関連付け・診断設定の作成先IDを決める。
    # 作業記録にない同名の新診断設定がある場合や、追加後に1リソース当たり5件を超える場合は止める。
    # ---
    # 旧DCRの関連付けがあり、VM送信先がLogの場合だけ、新DCRと関連付けのIDを作る。
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
    # 診断ログの送信を続ける行だけ、新診断設定のID・元の設定ID・送信先の地域を決める。
    # 新LAW自身も対象に加える。再実行で既に存在する場合は、調査済みの全診断設定で名前と件数を確認する。
    if ($Target.LogDestination -in @('Storage', 'Log')) {
        $diagnosticTargets = @($diagnosticSources)
        if ($Target.WorkspaceId -notin $diagnosticTargets.ResourceId) {
            $workspaceSettings = @($listedSettings | Where-Object ResourceId -eq $Target.WorkspaceId)
            $diagnosticTargets += @{
                ResourceId = $Target.WorkspaceId
                Settings = @($workspaceSettings.Settings)
                Sources = @()
                Location = $location
            }
        }
        foreach ($diagnostic in $diagnosticTargets) {
            if ($diagnostic.ResourceId -ne $Target.WorkspaceId -and $diagnostic.Sources.Count -ne 1) {
                throw "対象の旧診断設定が複数あります: $($diagnostic.ResourceId)"
            }
            # 保存先として再利用するStorage自身のログは、同じStorageへ送れない。
            if ($Target.LogDestination -eq 'Storage') {
                $destination = @($discovery.Storages | Where-Object Location -eq $diagnostic.Location)[0]
                if ($diagnostic.ResourceId -eq $destination.Id -or $diagnostic.ResourceId -like "$($destination.Id)/*") {
                    throw "Storage自身の診断ログを同じStorageへ送信できません: $($diagnostic.ResourceId)"
                }
            }
            $newId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($newDiagnosticSettingName))"
            if ($newId -in $plan.OldSettings.Id) {
                throw "新旧診断設定の名前が同じです: $newId"
            }
            $existing = @($diagnostic.Settings | Where-Object name -eq $newDiagnosticSettingName)
            # 再開では記録済みの診断設定を使える。記録にない同名設定があれば、上書きせず止める。
            if ($existing.Count -gt 0 -and $newId -notin @($Record.NewSettings.Id)) {
                throw "新しい診断設定名が使用済みです: $newId"
            }
            # 診断設定は1リソースにつき最大5件。新しく1件追加できるか、今の件数で判断する。
            if ($existing.Count -eq 0 -and $diagnostic.Settings.Count -ge 5) {
                throw "診断設定を追加する空き枠がありません: $($diagnostic.ResourceId)"
            }
            # 新LAW自身は旧設定をコピーせず、allLogsを有効にする。OldIdは複製元がある対象だけに入れる。
            $oldId = $null
            if ($diagnostic.ResourceId -ne $Target.WorkspaceId) {
                $oldId = "$($diagnostic.ResourceId)$diagnosticPath/$([Uri]::EscapeDataString($diagnostic.Sources[0].name))"
            }
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
