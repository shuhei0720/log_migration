#Requires -Version 5.1

# --------------------------------------------------
# 実行する環境と移行元
# 移行元ワークスペースと環境を指定する。旧DCRは環境に応じた2本を使う。
# --------------------------------------------------
$targetWorkspaceId = "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01"
$environment = "dev" # prod / stg / dev
$oldDcrIdsByEnvironment = @{
    prod = @(
        "/subscriptions/7f043232-66a7-4d79-a660-fcb22d1644d0/resourceGroups/rg-hub-prod-resource-01/providers/Microsoft.Insights/dataCollectionRules/dcr-hub-prod-vmInsights-01"
        "/subscriptions/7f043232-66a7-4d79-a660-fcb22d1644d0/resourceGroups/rg-hub-prod-resource-01/providers/Microsoft.Insights/dataCollectionRules/logrule-hub-prod-vm-01"
    )
    stg = @(
        "/subscriptions/40c16c7d-02f5-4529-ba94-8b754ccdb03e/resourceGroups/rg-hub-stg-resource-01/providers/Microsoft.Insights/dataCollectionRules/dcr-hub-stg-vmInsights-01"
        "/subscriptions/40c16c7d-02f5-4529-ba94-8b754ccdb03e/resourceGroups/rg-hub-stg-resource-01/providers/Microsoft.Insights/dataCollectionRules/logrule-hub-stg-vm-01"
    )
    dev = @(
        "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourceGroups/rg-hub-sand-resource-01/providers/Microsoft.Insights/dataCollectionRules/dcr-hub-sand-vmInsights-01"
        "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourceGroups/rg-hub-sand-resource-01/providers/Microsoft.Insights/dataCollectionRules/logrule-hub-sand-vm-01"
    )
}

# --------------------------------------------------
# 通信と出力の初期化
# エラーで処理を止め、CLIのUTF-8出力とARM通信のTLS 1.2を設定する。
# --------------------------------------------------
$ErrorActionPreference = "Stop"
$script:stepTimer = [Diagnostics.Stopwatch]::StartNew()
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = "utf-8"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:armTokens = @{}
if ($targetWorkspaceId -notmatch '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.operationalinsights/workspaces/[^/]+$') {
    throw "targetWorkspaceIdには移行元のLog AnalyticsワークスペースのリソースIDを指定してください。"
}
# --------------------------------------------------
# 保存先の地域と診断設定名
# 新Log Analytics・DCRは東日本。Storageは対象の地域に合わせ、global・空欄は東日本とする。
# Storage名のjpeを地域略称で置き換え、新診断設定には共通の名前を使う。
# --------------------------------------------------
$location = "japaneast"

$globalResourceLocation = "japaneast"

$regionNamesUrl = "https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json"

$newDiagnosticSettingName = "storage-archive"

# --------------------------------------------------
# ポリシー適用除外の指定
# 環境ごとの3割り当てをWaiverで除外する。先頭2件は全体、3件目は下の12参照IDが対象。
# --------------------------------------------------
$policySettings = @{
    prod = @{
        ManagementGroup = "producrion"
        AssignmentNames = @("6d924f0fa7a04145a1a00741", "71c38b62acf0433eb459b65b", "8dbf4e4a9a164f62969dc0ec")
    }
    stg = @{
        ManagementGroup = "staging"
        AssignmentNames = @("c0ddff1ad793418fb57fa3eb", "4ad819eb50c447a8a80b6c90", "75e82ef79a3447c3acab3d83")
    }
    dev = @{
        ManagementGroup = "sandbox"
        AssignmentNames = @("f6f0b49f9bd34e8fbb2c0304", "17fb86c1d07349769ff9b1a4", "0073f42c7cba4eef8454e06e")
    }
}
$policyReferenceIds = @(
    "Linux 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1"
    "Windows 仮想マシンを構成してデータ収集ルールまたはデータ収集エンドポイントと関連付ける_1"
    "App Serviceに対して診断設定を有効化する必要がある_1"
    "Kubernetes サービスに対して診断設定を有効化する必要がある_1"
    "ストレージ アカウントに対して診断設定を有効化する必要がある_1"
    "ストレージ アカウントのサブリソースに対して診断設定を有効化する必要がある_1"
    "App Serviceの関数アプリに対して診断設定を有効化する必要がある_1"
    "VMSSの均一モードでのデプロイを監査する_1"
    "Table service の診断設定を監査する_1"
    "File service の診断設定を監査する_1"
    "Blob service の診断設定を監査する_1"
    "Queue service の診断設定を監査する_1"
)
if ($environment -notin @("prod", "stg", "dev")) { throw "environmentはprod、stg、devのいずれかを指定してください。" }
$environmentPolicy = $policySettings[$environment]
$oldDcrIds = @($oldDcrIdsByEnvironment[$environment] | ForEach-Object { ([string]$_).Trim() })
$policyAssignments = @(
    for ($index = 0; $index -lt $environmentPolicy.AssignmentNames.Count; $index++) {
        $assignmentName = $environmentPolicy.AssignmentNames[$index]
        @{
            Name = $assignmentName
            Id = "/providers/microsoft.management/managementgroups/$($environmentPolicy.ManagementGroup)/providers/microsoft.authorization/policyassignments/$assignmentName"
            ReferenceIds = @(if ($index -eq 2) { $policyReferenceIds })
        }
    }
)

# --------------------------------------------------
# 入力ファイルと結果の格納先
# 対象CSV・変更前記録のパスと、確認結果・失敗一覧を用意する。
# --------------------------------------------------
$inputCsvPath = Join-Path $PSScriptRoot "log_migration_targets_regional.csv"
$migrationBackupPath = Join-Path $PSScriptRoot "log_migration_backup_$environment.json"
$script:failures = [System.Collections.Generic.List[object]]::new()
$script:verificationResults = [System.Collections.Generic.List[object]]::new()
$script:regionNames = @()
$script:storageNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# --------------------------------------------------
# Azure CLIの実行
# 引数: Arguments=CLIに渡す引数。戻り値: JSONを変換したオブジェクト（配列は1件ずつ）。
# 警告はJSONと分けて扱い、終了コードが0以外なら例外。
# --------------------------------------------------
function Invoke-AzJson {
    param([string[]]$Arguments)

    $null = Get-Command az -ErrorAction Stop
    $errorFile = [System.IO.Path]::GetTempFileName()
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = "Continue"
        $exitCode = 1
        $output = & az @Arguments --only-show-errors --output json 2> $errorFile
        $exitCode = $LASTEXITCODE
        $ErrorActionPreference = $previousPreference
        $text = ($output | ForEach-Object { $_.ToString() }) -join "`n"
        $errorText = Get-Content -LiteralPath $errorFile -Raw
        if ($exitCode -ne 0) { throw "Azure CLI 失敗: $errorText`n$text" }
        if ($errorText) { Write-Warning $errorText.Trim() }
        if ($text) {
            foreach ($item in ($text | ConvertFrom-Json)) { $item }
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $errorFile -Force
    }
}

# --------------------------------------------------
# ARM認証トークンの取得
# 引数なし。処理中のsubscriptionIdを参照し、accessToken・expires_onを持つオブジェクトを返す。
# トークンを保存して再利用し、期限まで5分以下なら再取得する。
# --------------------------------------------------
function Get-ArmToken {
    $token = $script:armTokens[$subscriptionId]
    if (-not $token -or [long]$token.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
        $token = Invoke-AzJson -Arguments @("account", "get-access-token", "--subscription", $subscriptionId, "--resource", "https://management.azure.com/")
        if (-not $token.accessToken -or -not $token.expires_on) { throw "ARMのアクセストークンを取得できません。" }
        $script:armTokens[$subscriptionId] = $token
    }
    $token
}

# --------------------------------------------------
# ARM APIの呼出し
# 引数: ResourceId=IDまたはARM URL、Method=HTTPメソッド、Body=送信内容、ApiVersion=API版。
# 戻り値: APIの応答。送信内容はUTF-8のJSONに変換する。
# 401は認証を更新し、一時エラーは最大3回再送する。解消しないエラーは例外。
# --------------------------------------------------
function Invoke-ArmRequest {
    param(
        [string]$ResourceId,
        [string]$Method = "Get",
        [object]$Body,
        [string]$ApiVersion = "2024-03-11"
    )

    $uri = if ($ResourceId.StartsWith("https://management.azure.com/")) { $ResourceId }
           else { "https://management.azure.com${ResourceId}?api-version=$ApiVersion" }
    for ($attempt = 0; $attempt -lt 4; $attempt++) {
        $token = Get-ArmToken
        $request = @{
            Uri = $uri; Method = $Method; TimeoutSec = 90
            Headers = @{ Authorization = "Bearer $($token.accessToken)" }
            ContentType = "application/json; charset=utf-8"
        }
        if ($null -ne $Body) {
            $request.Body = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json -InputObject $Body -Depth 30))
        }
        try { return Invoke-RestMethod @request }
        catch {
            $failure = $_
            $status = if ($failure.Exception.Response) { [int]$failure.Exception.Response.StatusCode } else { 0 }
            if ($status -eq 401 -and $attempt -lt 3) {
                $script:armTokens.Remove($subscriptionId)
                continue
            }
            if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
                $delay = [int][Math]::Pow(2, $attempt + 1)
                $retryAfter = [string]$failure.Exception.Response.Headers['Retry-After']
                if ($retryAfter -match '^\d+$') { $delay = [Math]::Max($delay, [int]$retryAfter) }
                Write-Host "ARM APIの一時エラー ($status)。$delay 秒後に再試行します。"
                Start-Sleep -Seconds $delay
                continue
            }
            $detail = $failure.ErrorDetails.Message
            if (-not $detail -and $failure.Exception.Response -is [Net.WebResponse]) {
                $reader = [IO.StreamReader]::new($failure.Exception.Response.GetResponseStream())
                try { $detail = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            if (-not $detail) { $detail = $failure.Exception.Message }
            throw "ARM $Method 失敗 ($status): $detail / $ResourceId"
        }
    }
}

# --------------------------------------------------
# 診断設定の一括処理
# 引数: Items=対象一覧、Action=1件ごとの処理、SettingName=処理に渡す設定名。
# 戻り値: Item・Result・Errorを持つ結果一覧。対象ごとの失敗はErrorに格納する。
# 最大5ジョブで分担し、0～1件ならこのPowerShell内で処理する。
# --------------------------------------------------
function Invoke-DiagnosticBatch {
    param([object[]]$Items, [scriptblock]$Action, [string]$SettingName)

    if ($Items.Count -le 1) {
        foreach ($item in $Items) {
            try {
                $result = & $Action $item $SettingName
                [pscustomobject]@{ Item = $item; Result = $result; Error = "" }
            }
            catch { [pscustomobject]@{ Item = $item; Result = $null; Error = $_.Exception.Message } }
        }
        return
    }

    # --------------------------------------------------
    # 子ジョブの準備と実行
    # 必要な関数・認証・設定値を渡し、対象件数が偏らないよう順番に振り分ける。
    # --------------------------------------------------
    $definitions = @{}
    foreach ($name in @("Invoke-AzJson", "Get-ArmToken", "Invoke-ArmRequest", "Get-DiagnosticSettings", "Get-DiagnosticSignature")) {
        $definitions[$name] = (Get-Item "function:$name").Definition
    }
    $definitionsJson = ConvertTo-Json -InputObject $definitions -Compress
    $tokenJson = ConvertTo-Json -InputObject (Get-ArmToken) -Compress
    $jobs = [System.Collections.Generic.List[object]]::new()
    $jobCount = [Math]::Min(5, $Items.Count)
    try {
        for ($index = 0; $index -lt $jobCount; $index++) {
            $batch = @(for ($itemIndex = $index; $itemIndex -lt $Items.Count; $itemIndex += $jobCount) { $Items[$itemIndex] })
            $itemsJson = ConvertTo-Json -InputObject $batch -Depth 40 -Compress
            $jobs.Add((Start-Job -ArgumentList $itemsJson, $Action.ToString(), $SettingName, $definitionsJson, $tokenJson, $subscriptionId -ScriptBlock {
                param($itemsJson, $actionText, $settingName, $definitionsJson, $tokenJson, $subscriptionId)
                $ErrorActionPreference = "Stop"
                $OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
                $env:PYTHONIOENCODING = "utf-8"
                [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
                $script:armTokens = @{}
                $script:armTokens[$subscriptionId] = $tokenJson | ConvertFrom-Json
                foreach ($definition in ($definitionsJson | ConvertFrom-Json).PSObject.Properties) {
                    Set-Item -Path "function:$($definition.Name)" -Value ([scriptblock]::Create($definition.Value))
                }
                $action = [scriptblock]::Create($actionText)
                foreach ($item in ($itemsJson | ConvertFrom-Json)) {
                    try {
                        $result = & $action $item $settingName
                        ConvertTo-Json -InputObject @{ Item = $item; Result = $result; Error = "" } -Depth 40 -Compress
                    }
                    catch {
                        ConvertTo-Json -InputObject @{ Item = $item; Result = $null; Error = $_.Exception.Message } -Depth 40 -Compress
                    }
                }
            }))
        }
        # --------------------------------------------------
        # 子ジョブの結果回収
        # JSONから設定オブジェクトへ戻す。終了時は起動したジョブを停止・削除する。
        # --------------------------------------------------
        Receive-Job -Job $jobs.ToArray() -Wait | ForEach-Object { $_ | ConvertFrom-Json }
    }
    finally {
        if ($jobs.Count -gt 0) {
            Stop-Job -Job $jobs.ToArray() -ErrorAction SilentlyContinue
            Remove-Job -Job $jobs.ToArray() -Force -ErrorAction SilentlyContinue
        }
    }
}

# --------------------------------------------------
# 診断設定の取得
# 引数: ResourceId=親リソースID、Name=設定名（省略時は全件）。
# 戻り値: 設定名nameを付けたpropertiesの一覧。取得エラーは呼出し元へ返す。
# --------------------------------------------------
function Get-DiagnosticSettings {
    param([string]$ResourceId, [string]$Name)

    $path = "$ResourceId/providers/Microsoft.Insights/diagnosticSettings"
    if ($Name) { $path += "/$([Uri]::EscapeDataString($Name))" }
    $response = Invoke-ArmRequest -ResourceId $path -ApiVersion "2021-05-01-preview"
    $items = if ($Name) { @($response) } else { @($response.value) }
    foreach ($item in $items) {
        $item.properties | Add-Member -NotePropertyName name -NotePropertyValue $item.name -PassThru
    }
}

# --------------------------------------------------
# 診断設定の比較用JSONを作成
# 引数: Setting=比較する診断設定。戻り値: ログ・メトリック・送信先のJSON文字列。
# ログ・メトリックの順序、送信先の大文字小文字、格納方式の省略値をそろえる。
# --------------------------------------------------
function Get-DiagnosticSignature {
    param([object]$Setting)

    $values = [ordered]@{}
    foreach ($key in @("logs", "metrics")) {
        $values[$key] = @(
            foreach ($item in @($Setting.$key | Sort-Object { [string]$_.category }, { [string]$_.categoryGroup })) {
                $entry = [ordered]@{
                    category = [string]$item.category
                    enabled = [bool]$item.enabled
                    retentionEnabled = [bool]$item.retentionPolicy.enabled
                    retentionDays = [int]$item.retentionPolicy.days
                }
                if ($key -eq "logs") { $entry.categoryGroup = [string]$item.categoryGroup }
                else { $entry.timeGrain = [string]$item.timeGrain }
                $entry
            }
        )
    }
    foreach ($key in @("workspaceId", "storageAccountId", "eventHubAuthorizationRuleId", "eventHubName", "serviceBusRuleId", "marketplacePartnerId")) {
        $values[$key] = ([string]$Setting.$key).ToLowerInvariant()
    }
    $values.logAnalyticsDestinationType = ""
    if ($Setting.workspaceId) {
        $values.logAnalyticsDestinationType = if ($Setting.logAnalyticsDestinationType) {
            ([string]$Setting.logAnalyticsDestinationType).ToLowerInvariant()
        } else { "azurediagnostics" }
    }
    ConvertTo-Json -InputObject $values -Depth 30 -Compress
}

# --------------------------------------------------
# リソースの取得
# 引数: ResourceId=対象ID、ApiVersion=取得に使うAPI版。
# 戻り値: 取得したリソース。404は値なし、それ以外の取得失敗は例外。
# --------------------------------------------------
function Get-OptionalArmResource {
    param([string]$ResourceId, [string]$ApiVersion = "2024-03-11")
    try { Invoke-ArmRequest -ResourceId $ResourceId -ApiVersion $ApiVersion }
    catch {
        if ($_.Exception.Message -notmatch '^ARM Get 失敗 \(404\):') { throw }
    }
}

# --------------------------------------------------
# 確認結果の記録
# 引数: Target=対象Sub、ResourceId=対象ID、Stage=区分、Success=成否、Message=理由、Expected=期待値。
# 戻り値なし。確認結果に追加し、NGは手動対応用の失敗一覧にも追加する。
# --------------------------------------------------
function Add-MigrationCheck {
    param([object]$Target, [string]$ResourceId, [string]$Stage, [bool]$Success, [string]$Message, [object]$Expected)

    $record = [pscustomobject][ordered]@{
        SubscriptionName = $Target.SubscriptionName
        SubscriptionId = $Target.SubscriptionId
        ResourceId = $ResourceId
        Stage = $Stage
        Result = if ($Success) { "OK" } else { "NG" }
        Reason = $Message
        NewDiagnosticSettingName = $newDiagnosticSettingName
        ExpectedWorkspaceId = [string]$Expected.workspaceId
        ExpectedStorageAccountId = [string]$Expected.storageAccountId
        ExpectedLogAnalyticsDestinationType = [string]$Expected.logAnalyticsDestinationType
        ExpectedLogs = ConvertTo-Json -InputObject @($Expected.logs | Where-Object { $null -ne $_ }) -Depth 40 -Compress
        ExpectedMetrics = ConvertTo-Json -InputObject @($Expected.metrics | Where-Object { $null -ne $_ }) -Depth 40 -Compress
        ExpectedConfiguration = if ($null -ne $Expected) { ConvertTo-Json -InputObject $Expected -Depth 40 -Compress } else { "" }
    }
    $script:verificationResults.Add($record)
    if (-not $Success) { $script:failures.Add($record) }
}

# --------------------------------------------------
# 失敗結果の記録
# 引数: Target・ResourceId=対象、Stage=区分、Message=理由、Expected=必要な設定値。
# 戻り値なし。Add-MigrationCheckを通じてNGを記録する。
# --------------------------------------------------
function Add-MigrationFailure {
    param([object]$Target, [string]$ResourceId, [string]$Stage, [string]$Message, [object]$Expected)
    Add-MigrationCheck -Target $Target -ResourceId $ResourceId -Stage $Stage -Success $false -Message $Message -Expected $Expected
}

# --------------------------------------------------
# 結果CSVの出力と工程終了
# 引数: Step=工程名、IncludeChecks=全確認結果もCSVへ出す指定。戻り値なし。
# 失敗があれば失敗CSVを出して例外、なければ前回の失敗CSVを削除して完了を表示する。
# --------------------------------------------------
function Complete-MigrationStep {
    param([string]$Step, [switch]$IncludeChecks)

    Write-Host "処理時間: $Step / $([Math]::Round($script:stepTimer.Elapsed.TotalSeconds, 1))秒"
    $failurePath = Join-Path $PSScriptRoot "log_migration_${Step}_failures.csv"
    if ($IncludeChecks) {
        $checkPath = Join-Path $PSScriptRoot "log_migration_${Step}_results.csv"
        $script:verificationResults | Export-Csv -LiteralPath $checkPath -NoTypeInformation -Encoding UTF8
        Write-Host "確認結果: $checkPath"
    }
    if ($script:failures.Count -gt 0) {
        $script:failures | Export-Csv -LiteralPath $failurePath -NoTypeInformation -Encoding UTF8
        $script:failures | Format-List
        throw "$Step に未完了の対象が $($script:failures.Count) 件あります。手動対応用CSV: $failurePath"
    }
    if (Test-Path -LiteralPath $failurePath) { Remove-Item -LiteralPath $failurePath -Force }
    Write-Host "$Step が完了しました。"
}

# --------------------------------------------------
# CSVから対象一覧を作成
# 引数なし。対象CSVと移行設定を参照し、列・名前・Subの重複を検査する。
# 戻り値: Sub IDと保存先情報を持つ対象一覧。入力不正はNGを記録する。
# --------------------------------------------------
function Get-MigrationTargets {
    try {
        if ([string]::IsNullOrWhiteSpace($newDiagnosticSettingName) -or
            $newDiagnosticSettingName.Length -gt 260 -or $newDiagnosticSettingName -match '[/\\?#%]' -or
            $newDiagnosticSettingName -ne $newDiagnosticSettingName.Trim()) {
            throw "新しい診断設定名には空白だけの名前やURLの区切り文字を使用できません。"
        }
        $rows = @(Import-Csv -LiteralPath $inputCsvPath -Encoding utf8)
        if ($rows.Count -eq 0) { throw "対象CSVにデータがありません: $inputCsvPath" }
        $columns = @("SubscriptionName", "ResourceGroup", "StorageAccount", "WorkspaceName", "LogDestination")
        foreach ($column in $columns) {
            if ($column -notin $rows[0].PSObject.Properties.Name) { throw "対象CSVに必要な列がありません: $column" }
        }
        $accounts = @(Invoke-AzJson -Arguments @("account", "list", "--all"))
        $subscriptionIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)
        $targets = [System.Collections.Generic.List[object]]::new()
        foreach ($row in $rows) {
            $target = @{}
            foreach ($column in $columns) { $target[$column] = ([string]$row.$column).Trim() }
            # --------------------------------------------------
            # 診断設定とVMログの作成対象を選択
            # 空欄・Noneは作成を省略する。VM用の列がない旧CSVは、従来どおりVMログを作成する。
            # 保存先は送信を止める場合も準備するため、リソースグループとワークスペース名を必須にする。
            # --------------------------------------------------
            $target.VmLogDestination = if ("VmLogDestination" -in $row.PSObject.Properties.Name) { ([string]$row.VmLogDestination).Trim() } else { "Log" }
            if ($target.LogDestination -notin @("Storage", "Log", "None", "")) { throw "LogDestinationはStorage、Log、Noneまたは空欄を指定してください。" }
            if ($target.VmLogDestination -notin @("Log", "None", "")) { throw "VmLogDestinationはLog、Noneまたは空欄を指定してください。" }
            $target.SkipDiagnostics = $target.LogDestination -in @("None", "")
            $target.SkipVm = $target.VmLogDestination -in @("None", "")
            $required = @("SubscriptionName", "ResourceGroup", "WorkspaceName")
            if ($target.LogDestination -eq "Storage") { $required += "StorageAccount" }
            foreach ($column in $required) {
                if ([string]::IsNullOrWhiteSpace($target[$column])) { throw "CSVの必須項目が空です: $column / $($target.SubscriptionName)" }
            }
            if ($target.StorageAccount -and
                ($target.StorageAccount -cnotmatch '^[a-z0-9]{3,24}$' -or [regex]::Matches($target.StorageAccount, 'jpe').Count -ne 1)) {
                throw "StorageAccountは小文字英数字3～24文字で、jpeを1箇所だけ含めてください: $($target.StorageAccount)"
            }
            $matches = @($accounts | Where-Object { $_.id -eq $target.SubscriptionName -or $_.name -eq $target.SubscriptionName })
            if ($matches.Count -ne 1) { throw "サブスクリプションを一意に特定できません。CSVにはIDを指定してください: $($target.SubscriptionName)" }
            $target.SubscriptionId = $matches[0].id
            if (-not $subscriptionIds.Add($target.SubscriptionId)) { throw "同じサブスクリプションをCSVの複数行に指定できません: $($target.SubscriptionId)" }
            $target.WorkspaceId = if ($target.WorkspaceName) { "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)" } else { "" }
            if ($target.LogDestination -eq "Log" -and $target.WorkspaceId -eq $targetWorkspaceId) {
                throw "Logの移行先ワークスペースが移行元と同じです。別の送信先を指定してください。"
            }
            $target.CurrentSettings = @{}
            $target.Storages = @{}
            $target.DiagnosticPlans = [System.Collections.Generic.List[object]]::new()
            $target.Collectors = @()
            $target.OldAssociations = @()
            $targets.Add($target)
        }
        # --------------------------------------------------
        # 地域略称の取得
        # Storage名を指定した行があれば、送信設定の作成・省略に関係なく地域名と略称を取得する。
        # --------------------------------------------------
        if (@($targets | Where-Object { $_.StorageAccount }).Count -gt 0) {
            $script:regionNames = Invoke-RestMethod -Uri $regionNamesUrl -TimeoutSec 30
            if ($script:regionNames.Count -eq 0) { throw "Azure Naming Toolのリージョン略称を取得できません。" }
        }
        $targets.ToArray()
    }
    catch { Add-MigrationFailure -Target $target -ResourceId $inputCsvPath -Stage "CSV・サブスクリプション確認" -Message $_.Exception.Message }
}

# --------------------------------------------------
# 現在の移行対象を調査
# 引数: Target=対象Sub情報。戻り値: 調査成否。Targetに対象一覧と新しい設定値を格納する。
# 移行元ワークスペース宛ての診断設定と、指定旧2DCRの関連を調べる。
# 診断設定ごとの調査失敗はNGに記録し、それ以外の取得エラーは呼出し元へ返す。
# --------------------------------------------------
function Get-MigrationPlan {
    param([object]$Target)

    $subscriptionId = $Target.SubscriptionId
    $Target.CurrentSettings = @{}
    $Target.Storages = @{}
    $Target.DiagnosticPlans.Clear()
    $ready = $true
    # --------------------------------------------------
    # 旧DCRと収集対象の調査
    # 旧関連は削除・切戻し用にすべて調べる。VM側を省略した場合、新しい関連の対象は空にする。
    # --------------------------------------------------
    $Target.OldAssociations = @(Get-OldDcrAssociations -Targets @($Target) -DcrIds $oldDcrIds)
    $resources = @(Invoke-AzJson -Arguments @("resource", "list", "--subscription", $subscriptionId))
    $Target.Collectors = @(if (-not $Target.SkipVm) { $Target.OldAssociations.ParentResourceId | Where-Object { $_ } | Sort-Object -Unique })
    $dcrName = $Target.WorkspaceName -replace '^log','dcr'
    $dcrId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $newAssociationIds = @($Target.Collectors | ForEach-Object { "$_/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName" })
    Assert-DcrCutoverIds -OldDcrIds $oldDcrIds -NewDcrIds @(if ($Target.Collectors.Count -gt 0) { $dcrId }) -OldAssociations $Target.OldAssociations -NewAssociationIds $newAssociationIds
    # --------------------------------------------------
    # 診断設定の取得
    # 通常のリソース一覧にStorageのBlob・File・Queue・Tableを加え、診断設定を取得する。
    # --------------------------------------------------
    $diagnosticResources = @{}
    foreach ($resource in $resources) {
        $diagnosticResources[$resource.id] = $resource.location
        if ($resource.type -eq "Microsoft.Storage/storageAccounts") {
            $services = switch ($resource.kind) {
                "BlobStorage"      { "blobServices" }
                "BlockBlobStorage" { "blobServices" }
                "FileStorage"      { "fileServices" }
                default            { "blobServices"; "queueServices"; "tableServices"; "fileServices" }
            }
            foreach ($service in $services) { $diagnosticResources["$($resource.id)/$service/default"] = $resource.location }
        }
    }
    $discovered = @(Invoke-DiagnosticBatch -Items @($diagnosticResources.Keys) -Action {
        param($resourceId, $settingName)
        [pscustomobject]@{ Settings = @(Get-DiagnosticSettings -ResourceId $resourceId) }
    })
    # --------------------------------------------------
    # 新しい診断設定と地域別Storageの計画
    # 旧ワークスペース宛ての設定を選び、CSVに従って新しい送信先または送信終了を計画する。
    # Storage名があれば地域別の保存先を計画し、新診断を作る場合だけ診断設定名と追加枠も確認する。
    # --------------------------------------------------
    foreach ($result in @($discovered | Sort-Object Item)) {
        $resourceId = $result.Item
        $expected = $null
        try {
            if ($result.Error) {
                if ($result.Error -match '\bResourceTypeNotSupported\b') { continue }
                throw $result.Error
            }
            $settings = @($result.Result.Settings)
            $Target.CurrentSettings[$resourceId] = @($settings | Where-Object { $_.name -eq $newDiagnosticSettingName })
            $sources = @($settings | Where-Object { $_.workspaceId -eq $targetWorkspaceId })
            if ($sources.Count -eq 0) { continue }
            if ($sources.Count -gt 1) { throw "対象の旧設定が複数あります。統合や上書きは行いません。" }
            $source = $sources[0]
            if (-not $Target.SkipDiagnostics -and $source.name -eq $newDiagnosticSettingName) { throw "旧設定名と新しい診断設定名が同じです。" }
            $region = ""
            # --------------------------------------------------
            # 新診断設定の送信先を選択
            # 作成する場合だけ旧設定のログ・メトリックを引き継ぐ。省略時はExpectedをnullのまま残す。
            # 省略しても旧設定の名前とBeforeを保存するため、最後の削除と切戻しの対象に残す。
            # --------------------------------------------------
            if (-not $Target.SkipDiagnostics) {
                $expected = @{ logs = @($source.logs | Where-Object { $null -ne $_ }); metrics = @($source.metrics | Where-Object { $null -ne $_ }) }
            }
            if ($Target.StorageAccount) {
                $region = ([string]$diagnosticResources[$resourceId] -replace '\s', '').ToLowerInvariant()
                if (-not $region -or $region -eq "global") { $region = $globalResourceLocation }
                $regionName = @($script:regionNames | Where-Object { ($_.name -replace '\s', '') -eq $region })
                if ($regionName.Count -ne 1 -or $regionName[0].shortName -cnotmatch '^[a-z0-9]+$') { throw "Azure Naming Toolの略称を一意に取得できません: $region" }
                $storageName = $Target.StorageAccount.Replace("jpe", [string]$regionName[0].shortName)
                if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') { throw "変換後のストレージ名が不正です: $storageName" }
                $storageId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$storageName"
                $Target.Storages[$region] = @{ Name = $storageName; Id = $storageId; Location = $region }
                if ($Target.LogDestination -eq "Storage") { $expected.storageAccountId = $storageId }
            }
            if ($Target.LogDestination -eq "Log") {
                $expected.workspaceId = $Target.WorkspaceId
                if ($source.logAnalyticsDestinationType) { $expected.logAnalyticsDestinationType = $source.logAnalyticsDestinationType }
            }
            $newSettings = @(if (-not $Target.SkipDiagnostics) { $settings | Where-Object { $_.name -eq $newDiagnosticSettingName } })
            if (-not $Target.SkipDiagnostics -and $newSettings.Count -eq 0 -and $settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定を残して追加する余地がありません。" }
            $Target.DiagnosticPlans.Add([pscustomobject]@{
                ResourceId = $resourceId
                Region = $region
                SourceSettings = @($source)
                SourceName = $source.name
                SourceSignature = Get-DiagnosticSignature -Setting $source
                Expected = $expected
                NewSignature = Get-DiagnosticSignature -Setting $expected
                NewSettings = $newSettings
            })
        }
        catch {
            Add-MigrationFailure -Target $Target -ResourceId $resourceId -Stage "診断設定の調査" -Message $_.Exception.Message -Expected $expected
            $ready = $false
        }
    }

    # --------------------------------------------------
    # 診断設定の対象がない場合のStorage準備
    # CSVにStorage名があれば、送信設定の対象が0件でも東日本に保存先を用意する。
    # --------------------------------------------------
    if ($Target.StorageAccount -and $Target.Storages.Count -eq 0) {
        $storageName = $Target.StorageAccount
        $Target.Storages['japaneast'] = @{ Name = $storageName; Location = 'japaneast'
            Id = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$storageName" }
    }
    Write-Host "調査完了: $($Target.SubscriptionName) / 対象診断設定=$($Target.DiagnosticPlans.Count) / ストレージ=$($Target.Storages.Count) / 旧DCR関連=$($Target.OldAssociations.Count) / 収集対象=$($Target.Collectors.Count)"
    $ready
}


# --------------------------------------------------
# 設定値の比較
# 引数: Actual=現在値、Expected=必要な項目と期待値。戻り値: 一致ならtrue。
# Expectedの項目を比較し、配列は順序を無視して件数と要素を照合する。
# --------------------------------------------------
function Test-BaselineValues {
    param([object]$Actual, [object]$Expected)

    if ($null -eq $Expected) { return $null -eq $Actual }
    if ($null -eq $Actual) { return $false }
    if ($Expected -is [pscustomobject]) {
        foreach ($property in $Expected.PSObject.Properties) {
            if (-not (Test-BaselineValues -Actual $Actual.($property.Name) -Expected $property.Value)) { return $false }
        }
        return $true
    }
    if ($Expected -is [System.Collections.IDictionary]) {
        foreach ($key in $Expected.Keys) {
            if (-not (Test-BaselineValues -Actual $Actual.$key -Expected $Expected[$key])) { return $false }
        }
        return $true
    }
    if ($Expected -is [array]) {
        $remaining = [System.Collections.Generic.List[object]]::new()
        foreach ($item in @($Actual)) { $remaining.Add($item) }
        if ($remaining.Count -ne $Expected.Count) { return $false }
        foreach ($item in $Expected) {
            $match = -1
            for ($index = 0; $index -lt $remaining.Count; $index++) {
                if (Test-BaselineValues -Actual $remaining[$index] -Expected $item) { $match = $index; break }
            }
            if ($match -lt 0) { return $false }
            $remaining.RemoveAt($match)
        }
        return $true
    }
    if ($Expected -is [bool] -and $Actual -isnot [bool]) { return $false }
    return $Actual -eq $Expected
}


# --------------------------------------------------
# ポリシー適用除外の照合
# 引数: Exemption=現在の除外、Assignment=割り当てIDと参照IDの指定値。戻り値なし。
# 割り当て・Waiver・期限なし・参照ID等が一致しなければ例外。
# --------------------------------------------------
function Assert-PolicyExemption {
    param([object]$Exemption, [hashtable]$Assignment)

    if (-not $Exemption -or $Exemption.properties.policyAssignmentId -ne $Assignment.Id -or
        $Exemption.properties.exemptionCategory -ne "Waiver" -or $Exemption.properties.expiresOn -or
        @($Exemption.properties.resourceSelectors | Where-Object { $null -ne $_ }).Count -gt 0 -or
        ($Exemption.properties.assignmentScopeValidation -and $Exemption.properties.assignmentScopeValidation -ne "Default")) {
        throw "適用除外の内容が一致しません。既存の除外は変更しません: $($Assignment.Id)"
    }
    $actual = @($Exemption.properties.policyDefinitionReferenceIds | Sort-Object) -join "`n"
    $expected = @($Assignment.ReferenceIds | Sort-Object) -join "`n"
    if ($actual -cne $expected) { throw "適用除外の参照IDが一致しません。既存の除外は変更しません。" }
}


# --------------------------------------------------
# 新DCRの設定値を作成
# 引数: Target=新しいWorkspaceIdを含む対象Sub情報。戻り値: DCRの送信内容。
# WindowsのApplication・Security・SystemとSyslogを、新ワークスペースへ送る。
# --------------------------------------------------
function Get-MigrationDcrBody {
    param([object]$Target)
    $body = @{
        location = $location
        properties = @{
            dataSources = @{
                windowsEventLogs = @(@{
                    name = "eventLogsDataSource"; streams = @("Microsoft-Event")
                    xPathQueries = @(
                        "Application!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                        "Security!*[System[(band(Keywords,13510798882111488))]]"
                        "System!*[System[(Level=1 or Level=2 or Level=3 or Level=4 or Level=0 or Level=5)]]"
                    )
                })
                syslog = @(@{
                    name = "sysLogsDataSource"; streams = @("Microsoft-Syslog")
                    facilityNames = @(
                        "alert", "audit", "auth", "authpriv", "clock", "cron", "daemon", "ftp", "kern",
                        "local0", "local1", "local2", "local3", "local4", "local5", "local6", "local7",
                        "lpr", "mail", "news", "nopri", "ntp", "syslog", "user", "uucp"
                    )
                    logLevels = @("Debug", "Info", "Notice", "Warning", "Error", "Critical", "Alert", "Emergency")
                })
            }
            destinations = @{ logAnalytics = @(@{ name = "new-workspace"; workspaceResourceId = $Target.WorkspaceId }) }
            dataFlows = @(
                @{ streams = @("Microsoft-Event"); destinations = @("new-workspace") }
                @{ streams = @("Microsoft-Syslog"); destinations = @("new-workspace") }
            )
        }
    }
    $body
}

# --------------------------------------------------
# 復元用のDCR設定値を抽出
# 引数: Resource=GET応答、Association=関連付けの指定、RequireReady=完了状態の確認指定。
# 戻り値: 読み取り専用項目を除いたPUT用設定。Resourceなしなら値なし。
# RequireReady指定時は作成・更新の完了状態を確認し、未完了なら例外。
# --------------------------------------------------
function Get-RollbackBody {
    param([object]$Resource, [switch]$Association, [switch]$RequireReady)
    if (-not $Resource) { return $null }
    if ($RequireReady -and (-not $Association -or $Resource.properties.provisioningState) -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw "DCR・関連付けの作成・更新が完了していません: state=$($Resource.properties.provisioningState)"
    }
    $copy = ConvertTo-Json -InputObject $Resource -Depth 40 | ConvertFrom-Json
    if ($Association) {
        $properties = @{}
        foreach ($key in @('description','dataCollectionRuleId','dataCollectionEndpointId')) {
            if ($null -ne $copy.properties.$key) { $properties[$key] = $copy.properties.$key }
        }
        return @{ properties = $properties }
    }
    foreach ($key in @('immutableId','provisioningState','endpoints','metadata','ingestionQuotas')) { $copy.properties.PSObject.Properties.Remove($key) }
    foreach ($destination in $copy.properties.destinations.logAnalytics) { $destination.PSObject.Properties.Remove('workspaceId') }
    foreach ($destination in $copy.properties.destinations.monitoringAccounts) { $destination.PSObject.Properties.Remove('accountId') }
    foreach ($destination in $copy.properties.destinations.azureDataExplorer) { $destination.PSObject.Properties.Remove('ingestionUri') }
    $body = @{ properties = $copy.properties }
    foreach ($key in @('location','kind','tags','identity')) {
        if ($null -ne $copy.$key) { $body[$key] = $copy.$key }
    }
    if ($body.identity) {
        foreach ($key in @('principalId','tenantId')) { $body.identity.PSObject.Properties.Remove($key) }
        foreach ($identity in $body.identity.userAssignedIdentities.PSObject.Properties) { $identity.Value = [pscustomobject]@{} }
    }
    $body
}


# --------------------------------------------------
# 変更前記録の読込みと照合
# 引数: Path=JSONパス（省略時は環境別の既定ファイル）、CheckCsv=CSV照合の指定。
# 戻り値: バックアップ全体。版・環境・移行元・設定名・保存内容が不正なら例外。
# --------------------------------------------------
function Read-MigrationBackup {
    param([string]$Path = $migrationBackupPath, [switch]$CheckCsv)
    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backup.Version -ne 3 -or -not $backup.CreatedAtUtc -or $backup.TargetWorkspaceId -ne $targetWorkspaceId -or
        $backup.Environment -ne $environment -or $backup.NewDiagnosticSettingName -ne $newDiagnosticSettingName -or
        $backup.Targets -isnot [array] -or $backup.Targets.Count -eq 0) { throw '①で作成したバックアップの版・環境・移行元・新設定名が今回の設定と一致しません。' }
    if ($backup.OldDcrIds -isnot [array] -or $backup.OldDcrIds.Count -ne 2 -or $backup.OldDcrIds[0] -eq $backup.OldDcrIds[1] -or
        @($backup.OldDcrIds | Where-Object { $_ -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.Insights/dataCollectionRules/[^/]+$' }).Count -gt 0 -or
        (@($backup.OldDcrIds | Sort-Object) -join ',') -ne (@($oldDcrIds | Sort-Object) -join ',')) { throw 'バックアップの旧DCR 2本が今回の設定と一致しません。' }
    # --------------------------------------------------
    # 保存内容の検査
    # 対象IDの重複、Before/After、DCRと関連の対応を確認する。省略する診断はAfter=nullであることも確認する。
    # --------------------------------------------------
    $ids = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($target in $backup.Targets) {
        $parsedId = [guid]::Empty
        if (-not [guid]::TryParse([string]$target.SubscriptionId, [ref]$parsedId) -or -not $ids.Add($target.SubscriptionId)) { throw 'バックアップのサブスクリプションIDが不正、または重複しています。' }
        foreach ($key in @('Routing','Diagnostics','Storages','Dcr','Associations','OldAssociations','Exemptions')) {
            if ($key -notin $target.PSObject.Properties.Name) { throw "バックアップの$key が欠けています。" }
        }
        foreach ($key in @('Diagnostics','Storages','Associations','OldAssociations','Exemptions')) {
            if ($target.$key -isnot [array]) { throw "バックアップの$key は配列で保存してください。" }
        }
        $vmDestination = if ('VmLogDestination' -in $target.Routing.PSObject.Properties.Name) { [string]$target.Routing.VmLogDestination } else { 'Log' }
        $skipDiagnostics = $target.Routing.LogDestination -in @('None','')
        $skipVm = $vmDestination -in @('None','')
        if ($target.Routing.LogDestination -notin @('Storage','Log','None','') -or $vmDestination -notin @('Log','None','') -or
            -not $target.Routing.ResourceGroup -or -not $target.Routing.WorkspaceName -or
            ($skipVm -and ($target.Dcr -or $target.Associations.Count -gt 0))) { throw 'バックアップのCSV情報と作成対象が一致しません。' }
        $prefix = "/subscriptions/$($target.SubscriptionId)/"
        $resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($saved in $target.Diagnostics) {
            if (-not ([string]$saved.ResourceId).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
                -not $resources.Add($saved.ResourceId) -or $saved.OldName -isnot [string] -or [string]::IsNullOrWhiteSpace($saved.OldName) -or
                (-not $skipDiagnostics -and $saved.OldName -eq $newDiagnosticSettingName) -or $saved.Before.workspaceId -ne $targetWorkspaceId -or
                ('After' -notin $saved.PSObject.Properties.Name) -or ($skipDiagnostics -and $null -ne $saved.After) -or
                (-not $skipDiagnostics -and -not ($saved.After.workspaceId -or $saved.After.storageAccountId))) { throw 'バックアップの診断設定の対象・名前・送信先が不正、または重複しています。' }
        }
        $resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($saved in @($target.Storages) + @($target.Dcr | Where-Object { $null -ne $_ }) + @($target.Associations) + @($target.OldAssociations) + @($target.Exemptions)) {
            $id = if ($saved.ResourceId) { $saved.ResourceId } else { $saved.Id }
            if (-not ([string]$id).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not $resources.Add($id)) { throw 'バックアップに別サブスクリプション、または重複したリソースが含まれています。' }
        }
        $dcrName = $target.Routing.WorkspaceName -replace '^log','dcr'
        $dcrId = "${prefix}resourceGroups/$($target.Routing.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
        if ($target.Dcr -and ('Before' -notin $target.Dcr.PSObject.Properties.Name -or $target.Dcr.ResourceId -ne $dcrId -or -not $target.Dcr.After.location -or
            $null -eq $target.Dcr.After.properties -or ($null -ne $target.Dcr.Before -and (-not $target.Dcr.Before.location -or $null -eq $target.Dcr.Before.properties)))) { throw 'バックアップのDCR情報が不正です。' }
        $oldParents = @($target.OldAssociations | ForEach-Object { $_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','' })
        foreach ($saved in $target.Associations) {
            if ('Before' -notin $saved.PSObject.Properties.Name -or -not $target.Dcr -or $saved.ResourceId -notmatch '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$' -or
                ($saved.ResourceId -split '/')[-1] -ne $dcrName -or $saved.After.properties.dataCollectionRuleId -ne $dcrId -or
                $saved.Before.properties.dataCollectionRuleId -in $backup.OldDcrIds -or
                ($null -ne $saved.Before -and -not ($saved.Before.properties.dataCollectionRuleId -or $saved.Before.properties.dataCollectionEndpointId))) { throw 'バックアップのDCR関連付け情報が不正です。' }
            $parentId = $saved.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$',''
            if ($parentId -notin $oldParents) { throw '新DCR関連の親リソースが旧DCRの対象にありません。' }
        }
        foreach ($saved in $target.OldAssociations) {
            if (-not $saved.Before.properties.dataCollectionRuleId -or $saved.Before.properties.dataCollectionRuleId -notin $backup.OldDcrIds -or
                $saved.ResourceId -notmatch '^(.+)/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$') { throw 'バックアップの旧DCR関連付けが不正です。' }
            $parentId = $Matches[1]
            if (-not $skipVm -and @($target.Associations | Where-Object { ($_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','') -eq $parentId }).Count -ne 1) { throw '旧DCR関連の親リソースに、新DCR関連の保存情報がありません。' }
        }
        Assert-DcrCutoverIds -OldDcrIds $backup.OldDcrIds -NewDcrIds @(if ($target.Dcr) { $dcrId }) -OldAssociations $target.OldAssociations -NewAssociationIds @($target.Associations.ResourceId)
        $ownExemptions = @(foreach ($assignment in $policyAssignments) { "/subscriptions/$($target.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)" })
        if ((@($target.Exemptions.ResourceId | Sort-Object) -join ',') -ne (@($ownExemptions | Sort-Object) -join ',') -or
            @($target.Exemptions | Where-Object { $_.Existed -isnot [bool] }).Count -gt 0) { throw 'バックアップの適用除外情報が不正です。' }
    }
    # --------------------------------------------------
    # CSVとの照合
    # 作業途中で送信先や省略指定が変わっていないか照合する。VM用の列がない旧CSV・旧記録はLogとして読む。
    # --------------------------------------------------
    if ($CheckCsv) {
        $rows = @(Import-Csv -LiteralPath $inputCsvPath -Encoding UTF8)
        if ($rows.Count -eq 0) { throw '対象CSVが空です。' }
        foreach ($row in $rows) {
            $saved = @($backup.Targets | Where-Object { $_.SubscriptionName -eq ([string]$row.SubscriptionName).Trim() })
            if ($saved.Count -ne 1) { throw 'CSVにバックアップ外のサブスクリプションがあります。' }
            foreach ($key in @('SubscriptionName','ResourceGroup','StorageAccount','WorkspaceName','LogDestination','VmLogDestination')) {
                $currentValue = if ($key -eq 'VmLogDestination' -and $key -notin $row.PSObject.Properties.Name) { 'Log' } else { ([string]$row.$key).Trim() }
                $savedValue = if ($key -eq 'VmLogDestination' -and $key -notin $saved[0].Routing.PSObject.Properties.Name) { 'Log' } else { [string]$saved[0].Routing.$key }
                if ($currentValue -ne $savedValue) { throw "CSVの$key がバックアップと一致しません。" }
            }
        }
    }
    $backup
}


# --------------------------------------------------
# 旧DCR関連の取得
# 引数: Targets=対象Sub一覧、DcrIds=異なる旧DCRのID2本。
# 戻り値: 対象Subの関連ID・親ID・復元用設定の一覧。nextLinkがあれば続きも取得する。
# --------------------------------------------------
function Get-OldDcrAssociations {
    param([object[]]$Targets, [string[]]$DcrIds)
    $ids = @($DcrIds | ForEach-Object { ([string]$_).Trim() })
    if ($Targets.Count -eq 0 -or $ids.Count -ne 2 -or @($ids | ForEach-Object { $_.ToLowerInvariant() } | Select-Object -Unique).Count -ne 2 -or
        @($ids | Where-Object { $_ -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.Insights/dataCollectionRules/[^/]+$' }).Count -gt 0) { throw '対象Subと、異なる旧DCRのリソースIDを2本指定してください。' }
    $subscriptionId = $Targets[0].SubscriptionId
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($dcrId in $ids) {
        $url = "$dcrId/associations"
        do {
            $page = Invoke-ArmRequest -ResourceId $url -ApiVersion '2024-03-11'
            if ($null -eq $page.value) { throw "旧DCR関連の一覧を取得できません: $dcrId" }
            foreach ($association in $page.value) {
                if ($association.id -notmatch '^(/subscriptions/([^/]+)/.+)/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$') { throw '旧DCR関連のリソースIDが不正です。' }
                $parentId = $Matches[1]; $associationSubscriptionId = $Matches[2]
                if ($associationSubscriptionId -notin $Targets.SubscriptionId) { continue }
                if ($association.properties.dataCollectionRuleId -ne $dcrId -or -not $seen.Add($association.id)) { throw '旧DCR関連の参照先が異なるか、重複しています。' }
                [pscustomobject]@{ SubscriptionId = $associationSubscriptionId; ResourceId = $association.id; ParentResourceId = $parentId
                    Before = Get-RollbackBody $association -Association; After = $null }
            }
            $url = $page.nextLink
        } while ($url)
    }
}

# --------------------------------------------------
# 新旧IDの重複確認
# 引数: OldDcrIds・NewDcrIds=DCRのID一覧、OldAssociations・NewAssociationIds=関連の一覧。
# 戻り値なし。新旧のDCRまたは関連IDが重なる場合は例外。
# --------------------------------------------------
function Assert-DcrCutoverIds {
    param([string[]]$OldDcrIds, [string[]]$NewDcrIds, [object[]]$OldAssociations, [string[]]$NewAssociationIds)
    if (@($OldDcrIds | Where-Object { $_ -in $NewDcrIds }).Count -gt 0) { throw '旧DCRと新DCRのIDが同じです。' }
    if (@($OldAssociations | Where-Object { $_.ResourceId -in $NewAssociationIds }).Count -gt 0) { throw '旧関連と新関連のIDが同じです。既存経路を上書きしません。' }
}


