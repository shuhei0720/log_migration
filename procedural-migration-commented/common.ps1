#Requires -Version 7.0
# ---
# 共通の設定と5関数を、各実行用スクリプトへ読み込むファイル。
# SkipCsvはCSV読込みを省く指定。並列workerとrollbackでも同じ関数を使う。
# このファイル単独では作業せず、実行用スクリプトからドットソースで読み込む。
# ---
param([switch]$SkipCsv)

# ---
# 利用者が指定する値
# 移行元のワークスペースと、今回作業する環境を指定する。
#
# targetWorkspaceIdは移行元のLAW。CSVで指定する新しい保存先とは別。
# environmentで環境を選び、parallelLimitで診断設定の同時処理数を決める。
# newDiagnosticSettingNameは全リソース共通の新設定名、locationは共通の作成地域。
# ---
$targetWorkspaceId = '/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01'
$environment = 'dev'
$newDiagnosticSettingName = 'storage-archive'
$location = 'japaneast'
$parallelLimit = 5
# ---
# 並列workerから読み込む自分のパスと、種類別のARM APIバージョンを用意する。
# Kindはこのコード内の分類で、APIの要求・応答形式を選ぶために使う。
# APIバージョンはAzure側の形式で、PowerShellのバージョンとは別。
# ---
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
# 環境ごとの旧DCRとポリシー割り当て
# 同じ環境の情報を一か所に並べ、リソースIDを組み立てる。
#
# 旧DCRの関連からVM・VMSSの対象を探す。Assignmentsは割り当てIDの末尾。
# prodのManagementGroup名も、指定されたproducrionという綴りを使う。
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
# ---
# 3件目の割り当てだけ、以下12個の参照IDを除外する。
# 1・2件目は割り当て全体を除外する。表示名による検索ではない。
# ---
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
$settings = $environmentSettings[$environment]
if (-not $settings) {
    throw 'environmentはprod・stg・devから指定してください。'
}
# ---
# 選んだ環境の名前から、旧DCRと3件のポリシー割り当ての完全なIDを作る。
# ReferenceIdsが空なら全体除外、3件目だけ上の12件を指定する。
# ---
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
# ---
# 環境・移行元・旧DCR・新設定名を記録のContextへまとめ、再実行時の取り違えを防ぐ。
# 記録先はrecords/環境名。エラーは停止として扱い、文字コードをUTF-8へそろえる。
# ---
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

# ---
# ARM APIを呼び出す
# ResourceId、またはId・Kind・Bodyを持つResourceを渡し、JSON応答を辞書で返す。
# Optional時の404は値なし。認証更新と一時エラーの再試行だけを共通で処理する。
# Waitは作成・更新の完了を最大5分待つ。既存記録のAPI版も引き続き利用できる。
#
# 入力：ResourceIdとMethod・Body、またはId・Kind・Bodyを持つResource。
# 返却：応答JSONの辞書。Optional時の404だけnull、その他の失敗は例外。
# 前提：呼出し元のsubscriptionIdを使う。Waitは処理中の応答を完了まで再確認する。
# MethodはGET/PUT/PATCH/DELETE/POST。API版は個別指定かResourceのKindから選ぶ。
# ---
function Invoke-ArmRequest {
    param($ResourceId, $Method = 'Get', $Body, $ApiVersion = '2024-03-11', [switch]$Optional, $Resource, [switch]$Wait)
    # ---
    # Resource指定ならId・API版・本文を取り出す。
    # 明示されたBodyはnull指定を含めて優先し、Resource.Bodyで上書きしない。
    # ---
    if ($Resource) {
        $ResourceId = $Resource.Id
        $ApiVersion = $Resource.ApiVersion ?? $apiVersions[$Resource.Kind]
        if ($Method -in @('Put', 'Patch', 'Post') -and -not $PSBoundParameters.ContainsKey('Body')) {
            $Body = $Resource.Body
        }
    }
    # ---
    # リソースIDにはARMのURLとAPI版を付ける。nextLinkの完全URLはそのまま使う。
    # Waitの期限は5分で、1回の通信の90秒とは別に管理する。
    # ---
    $uri = $ResourceId
    if (-not $uri.StartsWith('https://')) {
        $uri = "https://management.azure.com${ResourceId}?api-version=$ApiVersion"
    }
    $deadline = (Get-Date).AddMinutes(5)
    # ---
    # HTTP失敗に対する要求は最大4回。Sub変更・未取得・期限間近の場合だけトークンを取る。
    # 認証情報はこの実行領域で使い回す。az login済みの情報を使い、対話ログインはしない。
    # 並列worker間で、このキャッシュの変数を直接共有する仕組みではない。
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
        # ---
        # 認証ヘッダーと本文を付けてHTTP要求を送る。本文は深い階層もJSONへ変換する。
        # HTTPエラーは下で判定する。応答前の通信障害は例外として呼出し元へ伝わる。
        # ---
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
        $response = Invoke-WebRequest @request -SkipHttpErrorCheck
        $status = [int]$response.StatusCode
        # ---
        # 成功応答を辞書で返す。Wait指定で処理中なら3秒後に確認し直す。
        # この待機はHTTPエラーの試行回数を消費せず、5分の期限で止まる。
        # ---
        if ($status -lt 400) {
            $result = $response.Content | ConvertFrom-Json -AsHashtable
            if ($Wait -and $result.properties.provisioningState -in @('Creating', 'Updating', 'Accepted')) {
                if ((Get-Date) -ge $deadline) {
                    throw "作成・更新が完了しません: $ResourceId"
                }
                Start-Sleep -Seconds 3
                $attempt = -1
                continue
            }
            return $result
        }
        # ---
        # Optionalの404だけnull。401では認証を取り直し、一時的なHTTP失敗は待って再送する。
        # 対象外のエラー、または最大回数まで失敗した場合は例外で止める。
        # 再送対象は408・429・500・502・503・504で、Retry-Afterの秒指定も考慮する。
        # ---
        if ($status -eq 404 -and $Optional) {
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

# ---
# 現在値と期待値を比較する
# Expectedの項目がそろえばtrue。Exactは余分な項目も確認し、配列は順不同で比較する。
# 送信設定は正規化して全項目を照合し、Lifecycleは管理ルールと旧365日の残存を確認する。
#
# 入力：現在値Actual、期待値Expected、比較用のKind、完全一致を求めるExact。
# 返却：true/false。通常は期待した項目だけを確認する。
# 例：Actual={a=1;b=2}、Expected={a=1}は通常true、Exactではfalse。
# Kindで診断設定・DCR・関連付け・ライフサイクルの照合方法を選ぶ。
# ---
function Test-Configuration {
    param($Actual, $Expected, $Kind, [switch]$Exact)
    # ---
    # 作成・更新中なら未完了。診断設定・DCR・関連付けは書込み用の本文へそろえる。
    # この3種類は、余分な送信先なども見落とさないよう完全一致で比べる。
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
    # ---
    # Exactは両方向の比較。期待項目の不足だけでなく、余分な項目も不一致にする。
    # ---
    if ($Exact) {
        return (Test-Configuration $Actual $Expected -Kind $Kind) -and
            (Test-Configuration $Expected $Actual -Kind $Kind)
    }
    # ---
    # ライフサイクルは自分の1095日ルールを照合し、旧365日ルールの残存も確認する。
    # 他の名前のルールは比較対象に含めない。
    # ---
    if ($Kind -eq 'Lifecycle') {
        if (@($Actual.properties.policy.rules | Where-Object name -eq 'log-append-365').Count) {
            return $false
        }
        $Actual = @($Actual.properties.policy.rules | Where-Object name -eq 'log-append-1095')
        $Expected = @($Expected.properties.policy.rules)
    }
    # ---
    # 配列は順不同で照合する。一致した要素を候補から外し、重複も件数どおりに調べる。
    # 一方にだけ要素がある場合や、同じ要素の個数が違う場合も不一致にする。
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
    # nullは両方nullなら一致。辞書は期待した各項目を再帰的に比較する。
    # 最後に文字列や数値を比較する。文字列の大小文字は通常のPowerShellの比較に従う。
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

# ---
# GET応答から保存・復元に使う本文を取り出す
# ResourceとKindを渡し、PUT用のHashtableを返す。値なしならnull。
# DCRの読み取り専用項目を除き、診断設定の省略された格納方式をそろえる。
#
# 入力：取得したResourceとKind。返却：書込み用本文の辞書、対象がなければnull。
# 作成・更新中は例外。診断設定・DCR・関連付けの照合と復元にも同じ本文を使う。
# GET応答のIDや状態をそのままPUTせず、種類に応じて再設定できる項目を採用する。
# ---
function Get-WritableBody {
    param($Resource, $Kind)
    if (-not $Resource) {
        return $null
    }
    if ($Resource.properties.provisioningState -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw 'リソースの作成・更新が完了していません。'
    }
    # ---
    # DCRは内部の項目も除くため、元のGET応答を変えないよう深い階層まで複製する。
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
    # ---
    # 種類ごとの対象項目から、値があり、Azure管理の読取り専用項目でないものを採用する。
    # LAW宛てで格納方式が省略された診断設定はAzureDiagnosticsとしてそろえる。
    # ---
    foreach ($key in $keys) {
        if ($null -ne $copy.properties.$key -and $key -notin @('immutableId', 'provisioningState', 'endpoints', 'metadata', 'ingestionQuotas')) {
            $body.properties[$key] = $copy.properties.$key
        }
    }
    if ($Kind -eq 'Diagnostic' -and $body.properties.workspaceId -and -not $body.properties.logAnalyticsDestinationType) {
        $body.properties.logAnalyticsDestinationType = 'AzureDiagnostics'
    }
    if ($Kind -eq 'Dcr') {
        # ---
        # DCRは地域・種類・タグ・ID設定も残し、送信先内部の読取り専用値を除く。
        # ---
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
        # ---
        # マネージドIDの種類とユーザー割り当てIDの参照先は残す。
        # Azureが発行するprincipalId・tenantIdなどは、再設定する本文から外す。
        # ---
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

# ---
# サブスクリプションの変更前記録を読む
# Targetに対応するJSONを返す。まだ保存していなければnull。
# 別環境・別の移行元・作業途中のCSV変更は、この時点で停止する。
#
# 入力：Target。返却：そのSubの記録、未保存ならnull。不整合は例外で停止する。
# step1・step2は現在のCSVから作ったTargetを渡す。
# rollbackは保存済みTargetを渡すため現在のCSVは読まず、共通のContextだけ再確認する。
# ---
function Read-MigrationRecord {
    param($Target)
    $path = Join-Path $recordDirectory "$($Target.SubscriptionId).json"
    if (-not (Test-Path $path)) {
        return $null
    }
    # ---
    # JSON内のContextと渡されたTargetを完全一致で確認し、別条件の記録を混ぜない。
    # 3つの設定一覧が配列で保存されていることも確認する。
    # ---
    $record = Get-Content $path -Raw -Encoding UTF8 | ConvertFrom-Json -AsHashtable
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
# CSVを読み、サブスクリプションを一意に特定する
# 送信を止める行でも保存先を準備する。VM用の列がない旧CSVだけLogを既定値にする。
#
# ここからは関数の外の処理。読み込み時に実行し、SkipCsv指定時は省略する。
# ---
$targets = @()
$regionNames = @()
if (-not $SkipCsv) {
    $accounts = az account list --all --output json --only-show-errors | ConvertFrom-Json
    if ($LASTEXITCODE -ne 0) {
        throw 'サブスクリプション一覧を取得できません。'
    }
    # ---
    # CSV各行の前後の空白を除き、作業用のTargetを作る。
    # VmLogDestination列がない旧CSVだけLogを既定値にし、列がある場合の空欄は維持する。
    # 1行は1Sub。両方の送信先を止める場合も、その行を削除せずNoneか空欄を指定する。
    # ---
    foreach ($row in Import-Csv (Join-Path $PSScriptRoot 'targets.csv') -Encoding UTF8) {
        $target = [ordered]@{}
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'StorageAccount', 'WorkspaceName', 'LogDestination')) {
            $target[$name] = ([string]$row.$name).Trim()
        }
        $target.VmLogDestination = 'Log'
        if ('VmLogDestination' -in $row.PSObject.Properties.Name) {
            $target.VmLogDestination = ([string]$row.VmLogDestination).Trim()
        }
        # ---
        # 診断設定はStorage/Log/None/空欄、VM側はLog/None/空欄を受け付ける。
        # 送信を作らない行でも保存先を準備するので、RGとLAWの名前は必須。
        # ---
        if ($target.LogDestination -notin @('Storage', 'Log', 'None', '') -or
            $target.VmLogDestination -notin @('Log', 'None', '')) {
            throw "CSVの送信先が不正です: $($target.SubscriptionName)"
        }
        foreach ($name in @('SubscriptionName', 'ResourceGroup', 'WorkspaceName')) {
            if (-not $target[$name]) {
                throw "CSVの必須値が空欄です: $name"
            }
        }
        # ---
        # Storage宛てなら名前が必須。指定があればフラグに関係なく名前の形式を検査する。
        # 小文字英数字3～24文字、地域置換用のjpeが1か所だけ必要。
        # ---
        if (($target.LogDestination -eq 'Storage' -and -not $target.StorageAccount) -or
            ($target.StorageAccount -and ($target.StorageAccount -cnotmatch '^[a-z0-9]{3,24}$' -or
            [regex]::Matches($target.StorageAccount, 'jpe').Count -ne 1))) {
            throw 'StorageAccountは小文字英数字3～24文字でjpeを1か所含む名前を指定してください。'
        }
        # ---
        # CSVのSub名またはIDをAzureの一覧と照合し、1件に確定する。
        # 新LAWの完全なIDを作り、移行元と同じ保存先なら停止する。
        # ---
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
    # ---
    # 空CSVとSub重複を拒否する。Storage指定があればMicrosoft公開の地域略称を取得する。
    # 略称はAzureNamingToolの公開データから取り、社内の対応表を持たない。
    # ---
    if (-not $targets.Count -or @($targets | Group-Object { $_.SubscriptionId } | Where-Object Count -gt 1).Count) {
        throw 'CSVが空か、同じサブスクリプションが重複しています。'
    }
    if (@($targets | Where-Object StorageAccount).Count) {
        $regionNames = Invoke-RestMethod 'https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json'
    }
}

# ---
# 現在の旧設定、地域、作成予定名と追加枠を調べる。
# TargetはCSVの1行、Recordは保存済み記録。OnlyOldSettingsは旧設定だけを返す。
# 通常はcopy用の軽いDiscoveryも返す。設定内容の組立やAzureの変更は行わない。
#
# 入力：Target、再実行なら保存済みRecord。返却：旧設定と作成予定IDを持つ計画。
# OnlyOldSettingsでは旧設定の探索だけで返す。step2が変更の検出に使う。
# Azureへ書き込まず、不明な地域・名前衝突・調査失敗などは例外で止める。
# 返すDiscoveryは作成先を組み立てる一時情報で、復元用の記録とは別。
# ---
function Get-MigrationPlan {
    param($Target, $Record, [switch]$OnlyOldSettings)

    # ---
    # このSubの計画を空から作る。前回の計画をそのまま使わず、現在のAzureを調べ直す。
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

    # ---
    # 通常のリソース一覧にStorageの子サービスを加え、旧診断設定を探す。
    # 通常一覧はnextLinkも読み、Storageの種別に応じた子サービスIDを補う。
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
        }
        $resourcePage = $page.nextLink
    }
    # ---
    # 診断設定の取得を上限付きで並列実行する。Subの処理自体は順番に進める。
    # 各workerはcommonをSkipCsvで読み、usingで受け取ったSubとトークンを設定する。
    # workerが返した結果を親側でまとめ、取得漏れと取得失敗を確認する。
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
            # ---
            # 全設定は同名・上限の確認用、指定の旧LAW宛てだけが移行対象。
            # ---
            $result.Settings = @($response.value)
            $result.Sources = @($response.value | Where-Object { $_.properties.workspaceId -eq $using:sourceWorkspace })
        }
        # ---
        # 診断設定非対応のResourceTypeNotSupportedだけを対象外とし、他の取得失敗は報告する。
        # ---
        catch {
            if (($_.Exception.Message + $_.ErrorDetails.Message) -notmatch 'ResourceTypeNotSupported') {
                $result.Error = $_.Exception.Message
            }
        }
        $result
    } -ThrottleLimit $parallelLimit)
    # ---
    # 件数不足や取得失敗があれば調査完了にしない。対象の旧Bodyを記録へ集める。
    # 地域が空・globalの診断対象は東日本として扱う。
    # ---
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
    # 旧2DCRの関連から、このSubの元の関連付けを保存する。
    # 一覧だけでは省略される項目があるため、各関連の本体も取得する。
    # 他Subの関連は除き、各関連をGETして旧DCRを今も参照していることを確かめる。
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
    # ---
    # 旧設定だけの再調査ならここで返す。保存先・新設定・ポリシーの計画は作らない。
    # ---
    if ($OnlyOldSettings) {
        return $plan
    }

    # ---
    # このSubに適用される3割り当てと、指定した参照IDを確認する。
    # 同じイニシアティブの定義は、処理中に1回だけ取得する。
    # atScope()で取得し、継承を含めた適用先から指定の3割り当てを確認する。
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
    # ---
    # 3件目がイニシアティブで、指定の12参照IDを含むことを確認する。
    # 同じ定義は使い回すが、参照IDは大小文字も含めて照合する。
    # ---
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

    # ---
    # Discoveryには作成先のIDと地域だけをまとめる。設定本文はstep1側で組み立てる。
    # Storagesは地域ごとの保存先、Dcr・Associations・Diagnosticsは新設定の操作先。
    # ---
    $discovery = @{
        Storages = @()
        Dcr = $null
        Associations = @()
        Diagnostics = @()
    }

    # ---
    # 保存先Storageの地域・名前・ZRS対応を調べる。
    # 診断対象がある地域ごとに保存先を準備し、対象が0件なら東日本を使う。
    # ---
    if ($Target.StorageAccount) {
        $storageLocations = @($diagnosticSources.Location | Sort-Object -Unique)
        if ($storageLocations.Count -eq 0) {
            $storageLocations = @('japaneast')
        }
        $skus = Invoke-ArmRequest "/subscriptions/$subscriptionId/providers/Microsoft.Storage/skus" -ApiVersion '2023-05-01'
        foreach ($storageLocation in $storageLocations) {
            # ---
            # 地域略称へjpe部分だけを置換し、変換後も3～24文字とZRS対応を確認する。
            # 略称を一意に取得できない場合は推測せず停止する。
            # ---
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
            # ---
            # 初回はAzure全体のStorage名の空きを確認し、使用済みなら停止する。
            # 記録にある自分の保存先だけ再実行で許容し、実際の構成はstep1で再確認する。
            # 初回の同名Storageは、同じSubや同じ構成であっても流用しない。
            # ---
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
    # 作成するDCR・関連付け・診断設定のIDと追加枠を確認する。
    # 設定内容とBeforeは、変更を行うcopy側で組み立てる。
    # 旧関連がありVM側がLogのときだけ新DCRを計画する。None・空欄は作らない。
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
        # ---
        # 旧関連からVM・VMSSの親IDを取り出し、新DCR名の関連IDを作る。
        # 同じ対象の重複はまとめ、新旧の関連IDが重なる場合は停止する。
        # ---
        $parentIds = @($oldAssociations.Id | ForEach-Object { $_ -replace "$associationPath/[^/]+$", '' } | Sort-Object -Unique)
        foreach ($parentId in $parentIds) {
            $associationId = "$parentId$associationPath/$dcrName"
            if ($associationId -in $oldAssociations.Id) {
                throw "新旧DCR関連のIDが同じです: $associationId"
            }
            $discovery.Associations += @{ Id = $associationId }
        }
    }
    # ---
    # 診断設定側がStorage/Logの場合だけ新設定を計画する。
    # 旧設定複数・新旧同名・無関係な同名・上限5件を、書込み前に検査する。
    # None・空欄では新設定を作らないが、旧設定は削除・復元用に記録へ残す。
    # ---
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
