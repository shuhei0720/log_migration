#Requires -Version 5.1

# ------------------------------------------------------------
# 変更する設定：移行元ワークスペース、環境、環境ごとの旧DCR 2本
# ------------------------------------------------------------
# 移行対象は、この Log Analytics を宛先とする既存の診断設定です。
$targetWorkspaceId = "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01"
# CSVには、今回指定する環境のサブスクリプションだけを記載してください。
$environment = "dev" # prod / stg / dev
# ④で関連付けを解除する旧DCRです。DCR本体は削除しません。
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

# ------------------------------------------------------------
# ここから下は通常変更不要です。
# ------------------------------------------------------------
$ErrorActionPreference = "Stop"
$script:stepTimer = [Diagnostics.Stopwatch]::StartNew()
# Windows PowerShell 5.1でも日本語とHTTPS通信を扱えるようにします。
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = "utf-8"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:armTokens = @{}
if ($targetWorkspaceId -notmatch '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.operationalinsights/workspaces/[^/]+$') {
    throw "targetWorkspaceIdには移行元のLog AnalyticsワークスペースのリソースIDを指定してください。"
}
$location = "japaneast"

# global または所在地のないリソースの保存先。リージョンを持つリソースには使用しません。
$globalResourceLocation = "japaneast"

# Microsoft公開のAzure Naming Toolから略称を取得します。独自の対応表は持ちません。
$regionNamesUrl = "https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json"

# 全リソース共通の新しい診断設定名。既存設定とは異なる名前を指定してください。
$newDiagnosticSettingName = "storage-archive"

# 環境ごとの割り当てID。3件目だけ、下記の参照IDを指定して除外します。
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

# 同じCSVを各工程で読み、成功・失敗ファイルを次の工程の入力にはしません。
$inputCsvPath = Join-Path $PSScriptRoot "log_migration_targets_regional.csv"
$migrationBackupPath = Join-Path $PSScriptRoot "log_migration_backup_$environment.json"
$script:failures = [System.Collections.Generic.List[object]]::new()
$script:verificationResults = [System.Collections.Generic.List[object]]::new()
$script:regionNames = @()
$script:initiativeDefinition = $null
$script:storageNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

function Invoke-AzJson {
    param([string[]]$Arguments)

    $null = Get-Command az -ErrorAction Stop
    # 5.1では標準エラーへの警告も例外になるため、終了コードで成否を判断します。
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
            # 5.1ではJSON配列がひとかたまりで返るため、要素を順に返します。
            foreach ($item in ($text | ConvertFrom-Json)) { $item }
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $errorFile -Force
    }
}

# トークンはサブスクリプションごとに保持し、有効期限の5分前に更新します。
function Get-ArmToken {
    $token = $script:armTokens[$subscriptionId]
    if (-not $token -or [long]$token.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
        $token = Invoke-AzJson -Arguments @("account", "get-access-token", "--subscription", $subscriptionId, "--resource", "https://management.azure.com/")
        if (-not $token.accessToken -or -not $token.expires_on) { throw "ARMのアクセストークンを取得できません。" }
        $script:armTokens[$subscriptionId] = $token
    }
    $token
}

# ARM APIを直接呼び、リソースごとにCLIを起動する時間を省きます。
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
            # 一時的な過負荷だけを再試行します。入力エラーはそのまま呼び出し元へ返します。
            if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
                $delay = [int][Math]::Pow(2, $attempt + 1)
                $retryAfter = [string]$failure.Exception.Response.Headers['Retry-After']
                if ($retryAfter -match '^\d+$') { $delay = [Math]::Max($delay, [int]$retryAfter) }
                Write-Host "ARM APIの一時エラー ($status)。$delay 秒後に再試行します。"
                Start-Sleep -Seconds $delay
                continue
            }
            $detail = $failure.ErrorDetails.Message
            # 5.1でErrorDetailsが空でも、本文中のAzureのエラーコードを残します。
            if (-not $detail -and $failure.Exception.Response -is [Net.WebResponse]) {
                $reader = [IO.StreamReader]::new($failure.Exception.Response.GetResponseStream())
                try { $detail = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            if (-not $detail) { $detail = $failure.Exception.Message }
            throw "ARM $Method 失敗 ($status): $detail / $ResourceId"
        }
    }
}

# APIの応答待ちを短くするため、調査と複製は標準ジョブを最大5個使います。
# 深い設定を5.1のジョブ間でも保持するため、入出力はJSON文字列で渡します。
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
        Receive-Job -Job $jobs.ToArray() -Wait | ForEach-Object { $_ | ConvertFrom-Json }
    }
    finally {
        if ($jobs.Count -gt 0) {
            Stop-Job -Job $jobs.ToArray() -ErrorAction SilentlyContinue
            Remove-Job -Job $jobs.ToArray() -Force -ErrorAction SilentlyContinue
        }
    }
}

# ARMの応答を、従来のCLIと同じ設定オブジェクトに揃えます。
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

# 配列順・プロパティ順と省略時の既定値を揃え、収集条件・送信先を比較します。
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
    # ワークスペースがなければ格納方式は無関係です。省略時はAzureDiagnosticsが既定です。
    $values.logAnalyticsDestinationType = ""
    if ($Setting.workspaceId) {
        $values.logAnalyticsDestinationType = if ($Setting.logAnalyticsDestinationType) {
            ([string]$Setting.logAnalyticsDestinationType).ToLowerInvariant()
        } else { "azurediagnostics" }
    }
    ConvertTo-Json -InputObject $values -Depth 30 -Compress
}

# 存在しない場合だけnullを返します。通信・認証・APIのエラーは停止します。
function Get-OptionalArmResource {
    param([string]$ResourceId, [string]$ApiVersion = "2024-03-11")
    try { Invoke-ArmRequest -ResourceId $ResourceId -ApiVersion $ApiVersion }
    catch {
        if ($_.Exception.Message -notmatch '^ARM Get 失敗 \(404\):') { throw }
    }
}

# 手動対応できるよう、失敗した対象と、作るべき設定の内容を残します。
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

function Add-MigrationFailure {
    param([object]$Target, [string]$ResourceId, [string]$Stage, [string]$Message, [object]$Expected)
    Add-MigrationCheck -Target $Target -ResourceId $ResourceId -Stage $Stage -Success $false -Message $Message -Expected $Expected
}

# 出力CSVは確認・手動作業用です。他の工程からは読み込みません。
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

# CSVとサブスクリプションIDを毎回確認します。別名による重複も許可しません。
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
            foreach ($column in $columns) {
                if ($column -eq "StorageAccount" -and $target.LogDestination -eq "Log") { continue }
                if ([string]::IsNullOrWhiteSpace($target[$column])) { throw "CSVの必須項目が空です: $column / $($target.SubscriptionName)" }
            }
            if ($target.LogDestination -notin @("Storage", "Log")) { throw "LogDestinationはStorageまたはLogを指定してください。" }
            if ($target.LogDestination -eq "Storage" -and
                ($target.StorageAccount -cnotmatch '^[a-z0-9]{3,24}$' -or [regex]::Matches($target.StorageAccount, 'jpe').Count -ne 1)) {
                throw "StorageAccountは小文字英数字3～24文字で、jpeを1箇所だけ含めてください: $($target.StorageAccount)"
            }
            $matches = @($accounts | Where-Object { $_.id -eq $target.SubscriptionName -or $_.name -eq $target.SubscriptionName })
            if ($matches.Count -ne 1) { throw "サブスクリプションを一意に特定できません。CSVにはIDを指定してください: $($target.SubscriptionName)" }
            $target.SubscriptionId = $matches[0].id
            if (-not $subscriptionIds.Add($target.SubscriptionId)) { throw "同じサブスクリプションをCSVの複数行に指定できません: $($target.SubscriptionId)" }
            $target.WorkspaceId = "/subscriptions/$($target.SubscriptionId)/resourceGroups/$($target.ResourceGroup)/providers/Microsoft.OperationalInsights/workspaces/$($target.WorkspaceName)"
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
        if (@($targets | Where-Object { $_.LogDestination -eq "Storage" }).Count -gt 0) {
            $script:regionNames = Invoke-RestMethod -Uri $regionNamesUrl -TimeoutSec 30
            if ($script:regionNames.Count -eq 0) { throw "Azure Naming Toolのリージョン略称を取得できません。" }
        }
        # 旧2本から一度だけ一覧を取得し、VMSSも元の関連付けの親IDで扱います。
        $oldAssociations = @(Get-OldDcrAssociations -Targets $targets.ToArray() -DcrIds $oldDcrIds)
        foreach ($target in $targets) {
            $target.OldAssociations = @($oldAssociations | Where-Object { $_.SubscriptionId -eq $target.SubscriptionId })
        }
        $targets.ToArray()
    }
    catch { Add-MigrationFailure -Target $target -ResourceId $inputCsvPath -Stage "CSV・サブスクリプション確認" -Message $_.Exception.Message }
}

# Azureの現在値から、対象と期待する送信先を毎回組み立てます。
# Freshは初回の事前チェックだけで使い、既存名を一切再利用しません。
function Get-MigrationPlan {
    param([object]$Target, [switch]$Fresh)

    $subscriptionId = $Target.SubscriptionId
    $Target.CurrentSettings = @{}
    $Target.Storages = @{}
    $Target.DiagnosticPlans.Clear()
    $ready = $true
    if ($Fresh) {
        $assignmentUrl = "https://management.azure.com/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyAssignments?api-version=2022-06-01&`$filter=atScope()"
        $assignments = @()
        do {
            $page = Invoke-ArmRequest -ResourceId $assignmentUrl
            $assignments += @($page.value)
            $assignmentUrl = $page.nextLink
        } while ($assignmentUrl)
        foreach ($assignment in $policyAssignments) {
            if ($assignment.Id -notin $assignments.id) { throw "指定環境の割り当てが適用されていません: $($assignment.Id)" }
        }
        $assignment = $assignments | Where-Object { $_.id -eq $policyAssignments[2].Id } | Select-Object -First 1
        $definitionId = $assignment.properties.policyDefinitionId
        if (-not $definitionId -or $definitionId -notmatch '/policySetDefinitions/') { throw "3件目の割り当てからイニシアティブの定義IDを取得できません。" }
        if (-not $script:initiativeDefinition) { $script:initiativeDefinition = Invoke-ArmRequest -ResourceId $definitionId -ApiVersion "2023-04-01" }
        foreach ($referenceId in $policyReferenceIds) {
            if ($referenceId -cnotin $script:initiativeDefinition.properties.policyDefinitions.policyDefinitionReferenceId) { throw "指定の参照IDがイニシアティブに存在しません: $referenceId" }
        }
    }

    $resources = @(Invoke-AzJson -Arguments @("resource", "list", "--subscription", $subscriptionId))
    $Target.Collectors = @($Target.OldAssociations.ParentResourceId | Where-Object { $_ } | Sort-Object -Unique)
    $dcrName = $Target.WorkspaceName -replace '^log','dcr'
    $dcrId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $newAssociationIds = @($Target.Collectors | ForEach-Object { "$_/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName" })
    Assert-DcrCutoverIds -OldDcrIds $oldDcrIds -NewDcrIds @(if ($Target.Collectors.Count -gt 0) { $dcrId }) -OldAssociations $Target.OldAssociations -NewAssociationIds $newAssociationIds
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
            if ($source.name -eq $newDiagnosticSettingName) { throw "旧設定名と新しい診断設定名が同じです。" }
            $expected = @{ logs = @($source.logs | Where-Object { $null -ne $_ }); metrics = @($source.metrics | Where-Object { $null -ne $_ }) }
            $region = ""
            if ($Target.LogDestination -eq "Storage") {
                $region = ([string]$diagnosticResources[$resourceId] -replace '\s', '').ToLowerInvariant()
                if (-not $region -or $region -eq "global") { $region = $globalResourceLocation }
                $regionName = @($script:regionNames | Where-Object { ($_.name -replace '\s', '') -eq $region })
                if ($regionName.Count -ne 1 -or $regionName[0].shortName -cnotmatch '^[a-z0-9]+$') { throw "Azure Naming Toolの略称を一意に取得できません: $region" }
                $storageName = $Target.StorageAccount.Replace("jpe", [string]$regionName[0].shortName)
                if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') { throw "変換後のストレージ名が不正です: $storageName" }
                $storageId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$storageName"
                $Target.Storages[$region] = @{ Name = $storageName; Id = $storageId; Location = $region }
                $expected.storageAccountId = $storageId
            }
            else {
                $expected.workspaceId = $Target.WorkspaceId
                if ($source.logAnalyticsDestinationType) { $expected.logAnalyticsDestinationType = $source.logAnalyticsDestinationType }
            }
            $newSettings = @($settings | Where-Object { $_.name -eq $newDiagnosticSettingName })
            if ($Fresh -and $newSettings.Count -gt 0) { throw "新しい診断設定名が既存設定と重複しています。初回の事前チェックを停止します。" }
            if ($newSettings.Count -eq 0 -and $settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定を残して追加する余地がありません。" }
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

    if ($Fresh -and $Target.Storages.Count -gt 0) {
        $skus = @(Invoke-AzJson -Arguments @("storage", "sku", "list", "--subscription", $subscriptionId))
        foreach ($storage in @($Target.Storages.Values | Sort-Object Name)) {
            try {
                if (-not $script:storageNames.Add($storage.Name)) { throw "変換後のストレージ名が重複しています: $($storage.Name)" }
                if (-not ($skus | Where-Object { $_.name -eq "Standard_ZRS" -and $_.kind -eq "StorageV2" -and $storage.Location -in $_.locations })) { throw "Standard_ZRSを利用できないリージョンです: $($storage.Location)" }
                $availability = Invoke-AzJson -Arguments @("storage", "account", "check-name", "--subscription", $subscriptionId, "--name", $storage.Name)
                if ($availability.nameAvailable -ne $true) { throw "名前を利用できません: $($storage.Name) / $($availability.reason) / $($availability.message)" }
                Add-MigrationCheck -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Success $true -Message "利用可能"
            }
            catch {
                Add-MigrationFailure -Target $Target -ResourceId $storage.Id -Stage "ストレージ名の事前確認" -Message $_.Exception.Message
                $ready = $false
            }
        }
    }
    Write-Host "調査完了: $($Target.SubscriptionName) / 対象診断設定=$($Target.DiagnosticPlans.Count) / ストレージ=$($Target.Storages.Count) / 旧DCR関連=$($Target.OldAssociations.Count) / 収集対象=$($Target.Collectors.Count)"
    $ready
}

# 全件確認と削除前確認で、現在の旧設定に対する新設定の収集条件・送信先を調べます。
function Test-MigrationDiagnostics {
    param([object]$Target, [object]$BackupTarget)

    foreach ($saved in $BackupTarget.Diagnostics) {
        $settings = @($Target.CurrentSettings[$saved.ResourceId] | Where-Object { $_.name -eq $newDiagnosticSettingName })
        $matched = $settings.Count -eq 1 -and
            (Get-DiagnosticSignature -Setting $settings[0]) -ceq (Get-DiagnosticSignature -Setting $saved.After)
        $message = if ($matched) { "新設定がバックアップの完成形と一致" } else { "新設定が存在しないか、収集条件・送信先が一致しません。旧設定は削除できません。" }
        Add-MigrationCheck -Target $Target -ResourceId $saved.ResourceId -Stage "診断設定の全件確認" -Success $matched -Message $message -Expected $saved.After
    }
}

# ARMが付加する読取専用項目を除き、必要な設定値を比較します。
# 配列は順序を無視しますが、要素数と各要素は一致させます。
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

# 同じ設定への書込みを省き、途中停止した場合も不足する部分だけ設定します。
function Set-BaselineResource {
    param(
        [string]$ResourceId, [string]$ApiVersion, [hashtable]$Body,
        [hashtable]$Expected, [string]$Method = "Put", [switch]$VerifyOnly
    )

    if (-not $Expected) { $Expected = $Body }
    $current = Get-OptionalArmResource -ResourceId $ResourceId -ApiVersion $ApiVersion
    if ($current -and ($current.properties.provisioningState -in @('Creating','Updating','Accepted') -or
        ($Expected.properties.provisioningState -and $current.properties.provisioningState -ne $Expected.properties.provisioningState))) {
        throw "リソースの作成・更新が完了していません: state=$($current.properties.provisioningState)"
    }
    if (Test-BaselineValues -Actual $current -Expected $Expected) { return $current }
    if ($VerifyOnly) { throw "必要な設定が未作成、または期待値と一致しません。" }
    $null = Invoke-ArmRequest -Method $Method -ResourceId $ResourceId -ApiVersion $ApiVersion -Body $Body
    $current = Invoke-ArmRequest -ResourceId $ResourceId -ApiVersion $ApiVersion
    if (-not (Test-BaselineValues -Actual $current -Expected $Expected)) {
        throw "設定後の読み戻しで期待値と一致しません。再実行前に現在の設定を確認してください。"
    }
    $current
}

# 既存の適用除外は範囲が一致する場合だけ再利用します。
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

# 診断設定の宛先とVMログ収集に必要な準備を、設定版・確認版から共通で使います。
# VerifyOnlyではAzureを変更せず、不足や不一致をすべて確認結果に残します。
function Set-MigrationBaseline {
    param([object]$Target, [switch]$VerifyOnly)

    $subscriptionId = $Target.SubscriptionId
    $groupId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)"
    $ready = $true
    foreach ($assignment in $policyAssignments) {
        $resourceId = "/subscriptions/$subscriptionId/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
        $stage = "ポリシー適用除外"
        $expected = @{ policyAssignmentId = $assignment.Id; exemptionCategory = "Waiver"; assignmentScopeValidation = "Default" }
        if (@($assignment.ReferenceIds).Count -gt 0) { $expected.policyDefinitionReferenceIds = @($assignment.ReferenceIds) }
        try {
            $exemption = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2022-07-01-preview"
            if (-not $exemption) {
                if ($VerifyOnly) { throw "適用除外がありません。" }
                $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2022-07-01-preview" -Body @{ properties = $expected }
                $exemption = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2022-07-01-preview"
            }
            Assert-PolicyExemption -Exemption $exemption -Assignment $assignment
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }
    }
    # 適用除外を確認できない場合は、他の作成・変更を開始しません。
    if (-not $ready -and -not $VerifyOnly) { return $false }

    $namespaces = @("Microsoft.OperationalInsights", "Microsoft.Insights")
    if ($Target.Storages.Count -gt 0) { $namespaces += @("Microsoft.Storage", "Microsoft.Security") }
    foreach ($namespace in $namespaces) {
        $resourceId = "/subscriptions/$subscriptionId/providers/$namespace"
        $stage = "プロバイダー登録"
        try {
            $provider = Invoke-AzJson -Arguments @("provider", "show", "--subscription", $subscriptionId, "--namespace", $namespace)
            if ($provider.registrationState -ne "Registered") {
                if ($VerifyOnly) { throw "リソースプロバイダーが登録されていません: $namespace" }
                $null = Invoke-AzJson -Arguments @("provider", "register", "--subscription", $subscriptionId, "--namespace", $namespace, "--wait")
                $provider = Invoke-AzJson -Arguments @("provider", "show", "--subscription", $subscriptionId, "--namespace", $namespace)
                if ($provider.registrationState -ne "Registered") { throw "リソースプロバイダーの登録が完了していません: $namespace" }
            }
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "登録済み"
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message
        }
    }
    if (-not $ready -and -not $VerifyOnly) { return $false }

    $resourceId = $groupId
    $stage = "リソースグループ"
    try {
        $group = Get-OptionalArmResource -ResourceId $groupId -ApiVersion "2022-09-01"
        if (-not $group) {
            if ($VerifyOnly) { throw "リソースグループがありません。" }
            $null = Invoke-ArmRequest -Method Put -ResourceId $groupId -ApiVersion "2022-09-01" -Body @{ location = $location }
            $group = Invoke-ArmRequest -ResourceId $groupId -ApiVersion "2022-09-01"
        }
        if (-not $group) { throw "リソースグループを確認できません。" }
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "存在確認済み"
    }
    catch {
        $ready = $false
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message
        if (-not $VerifyOnly) { return $false }
    }

    foreach ($storagePlan in @($Target.Storages.Values | Sort-Object Name)) {
        $resourceId = $storagePlan.Id
        $stage = "ストレージアカウント"
        $immutable = @{
            id = $storagePlan.Id; location = $storagePlan.Location; kind = "StorageV2"; sku = @{ name = "Standard_ZRS" }
            properties = @{
                encryption = @{ requireInfrastructureEncryption = $true }
                immutableStorageWithVersioning = @{ enabled = $true }
            }
        }
        $properties = @{
            publicNetworkAccess = "Enabled"; allowBlobPublicAccess = $false; allowSharedKeyAccess = $false
            supportsHttpsTrafficOnly = $true; minimumTlsVersion = "TLS1_2"
            networkAcls = @{ defaultAction = "Deny"; bypass = "AzureServices" }
        }
        $expected = $immutable.Clone()
        $expected.properties = $immutable.properties.Clone()
        foreach ($key in $properties.Keys) { $expected.properties[$key] = $properties[$key] }
        $expected.properties.provisioningState = "Succeeded"
        try {
            $storage = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-05-01"
            if (-not $storage) {
                if ($VerifyOnly) { throw "ストレージアカウントがありません。" }
                $null = Invoke-AzJson -Arguments @(
                    "storage", "account", "create", "--subscription", $subscriptionId,
                    "--resource-group", $Target.ResourceGroup, "--name", $storagePlan.Name,
                    "--location", $storagePlan.Location, "--kind", "StorageV2", "--sku", "Standard_ZRS",
                    "--public-network-access", "Enabled", "--default-action", "Deny", "--bypass", "AzureServices",
                    "--allow-blob-public-access", "false", "--allow-shared-key-access", "false",
                    "--https-only", "true", "--min-tls-version", "TLS1_2",
                    "--require-infrastructure-encryption", "true", "--enable-alw", "true"
                )
                $storage = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-05-01"
            }
            # リージョンや暗号化などの基礎構成が異なる既存アカウントは変更しません。
            if (-not (Test-BaselineValues -Actual $storage -Expected $immutable)) {
                throw "既存ストレージのID・リージョン・種類・SKU・インフラ暗号化・ALWが一致しません。上書きしません。"
            }
            # 個別に追加されたネットワーク規則は保持します。
            $networkAcls = @{}
            foreach ($property in $storage.properties.networkAcls.PSObject.Properties) { $networkAcls[$property.Name] = $property.Value }
            $networkAcls.defaultAction = "Deny"
            $networkAcls.bypass = "AzureServices"
            $bodyProperties = $properties.Clone()
            $bodyProperties.networkAcls = $networkAcls
            $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-05-01" -Method Patch `
                -Body @{ properties = $bodyProperties } -Expected $expected -VerifyOnly:$VerifyOnly
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
            continue
        }

        $resourceId = "$($storagePlan.Id)/blobServices/default"
        $stage = "Blobバージョン管理"
        $expected = @{ properties = @{ isVersioningEnabled = $true } }
        try {
            $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-05-01" -Body $expected -VerifyOnly:$VerifyOnly
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }

        $resourceId = "$($storagePlan.Id)/managementPolicies/default"
        $stage = "ライフサイクル"
        $expected = @{
            name = "log-append-365"; enabled = $true; type = "Lifecycle"
            definition = @{
                filters = @{ blobTypes = @("appendBlob") }
                actions = @{ baseBlob = @{ delete = @{ daysAfterModificationGreaterThan = 365 } } }
            }
        }
        try {
            $policy = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-05-01"
            $rules = @($policy.properties.policy.rules | Where-Object { $_.name -eq $expected.name })
            if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) {
                if ($VerifyOnly) { throw "log-append-365ルールが未設定、または期待値と一致しません。" }
                # このスクリプトのルールだけ補完し、別名のルールは保持します。
                $rules = @($policy.properties.policy.rules | Where-Object { $null -ne $_ -and $_.name -ne $expected.name }) + @($expected)
                $null = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2023-05-01" -Body @{ properties = @{ policy = @{ rules = $rules } } }
                $policy = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-05-01"
                $rules = @($policy.properties.policy.rules | Where-Object { $_.name -eq $expected.name })
                if ($rules.Count -ne 1 -or -not (Test-BaselineValues -Actual $rules[0] -Expected $expected)) { throw "ライフサイクルの読み戻しが一致しません。" }
            }
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }

        $resourceId = "$($storagePlan.Id)/providers/Microsoft.Security/defenderForStorageSettings/current"
        $stage = "Defender for Storage"
        $expected = @{ properties = @{ isEnabled = $false; overrideSubscriptionLevelSettings = $true } }
        try {
            $null = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2025-01-01" -Body $expected -VerifyOnly:$VerifyOnly
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }
    }

    $resourceId = $Target.WorkspaceId
    $stage = "Log Analytics"
    $expected = @{
        location = $location
        properties = @{
            retentionInDays = 365; publicNetworkAccessForIngestion = "Enabled"; publicNetworkAccessForQuery = "Enabled"
            features = @{ enableLogAccessUsingOnlyResourcePermissions = $true }
            provisioningState = "Succeeded"
        }
    }
    try {
        $workspace = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2023-09-01"
        if (-not $workspace) {
            if ($VerifyOnly) { throw "Log Analyticsワークスペースがありません。" }
            $null = Invoke-AzJson -Arguments @(
                "monitor", "log-analytics", "workspace", "create", "--subscription", $subscriptionId,
                "--resource-group", $Target.ResourceGroup, "--workspace-name", $Target.WorkspaceName,
                "--location", $location, "--retention-time", "365", "--ingestion-access", "Enabled", "--query-access", "Enabled"
            )
            $workspace = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2023-09-01"
        }
        if (($workspace.location -replace '\s', '') -ne $location) { throw "既存ワークスペースのリージョンが一致しません。変更しません。" }
        $features = @{}
        foreach ($property in $workspace.properties.features.PSObject.Properties) { $features[$property.Name] = $property.Value }
        $features.enableLogAccessUsingOnlyResourcePermissions = $true
        $bodyProperties = $expected.properties.Clone()
        $bodyProperties.Remove("provisioningState")
        $bodyProperties.features = $features
        $workspace = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2023-09-01" -Method Patch `
            -Body @{ properties = $bodyProperties } -Expected $expected -VerifyOnly:$VerifyOnly
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
    }
    catch {
        $ready = $false
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        if (-not $VerifyOnly) { return $false }
        # 確認時はワークスペースに不備があっても、テーブル・DCR・関連付けまで調べます。
        $workspace = @{ location = $location }
    }
    if ($Target.Collectors.Count -eq 0) { return $ready }

    $tablesReady = $true
    foreach ($name in @("Event", "Syslog")) {
        $resourceId = "$($Target.WorkspaceId)/tables/$name"
        $stage = "VMログテーブル"
        $expected = @{ properties = @{ schema = @{ name = $name }; provisioningState = "Succeeded" } }
        try {
            $table = Get-OptionalArmResource -ResourceId $resourceId -ApiVersion "2025-07-01"
            if (-not (Test-BaselineValues -Actual $table -Expected $expected)) {
                if ($VerifyOnly) { throw "VMログテーブルが未作成、または準備未完了です。" }
                if (-not $table) {
                    $table = Invoke-ArmRequest -Method Put -ResourceId $resourceId -ApiVersion "2025-07-01" -Body @{ properties = @{ schema = @{ name = $name } } }
                }
                $deadline = (Get-Date).AddMinutes(5)
                while ($table.properties.provisioningState -ne "Succeeded") {
                    if ((Get-Date) -ge $deadline -or $table.properties.provisioningState -in @("Failed", "Canceled", "Deleting")) {
                        throw "VMログテーブルが利用できません: state=$($table.properties.provisioningState)"
                    }
                    Start-Sleep -Seconds 10
                    $table = Invoke-ArmRequest -ResourceId $resourceId -ApiVersion "2025-07-01"
                }
                if (-not (Test-BaselineValues -Actual $table -Expected $expected)) { throw "VMログテーブルの設定が一致しません。" }
            }
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false; $tablesReady = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }
    }

    $dcrName = $Target.WorkspaceName -replace '^log', 'dcr'
    $dcrId = "$groupId/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $body = Get-MigrationDcrBody -Target $Target
    $expected = @{ location = $body.location; properties = $body.properties.Clone() }
    $expected.properties.provisioningState = "Succeeded"
    $resourceId = $dcrId
    $stage = "DCR"
    $dcrReady = $false
    try {
        if (-not $tablesReady -and -not $VerifyOnly) { throw "テーブルの準備に失敗したため、DCR作成を開始していません。" }
        $deadline = (Get-Date).AddMinutes(5)
        while ($true) {
            try {
                $null = Set-BaselineResource -ResourceId $dcrId -ApiVersion "2024-03-11" -Body $body -Expected $expected -VerifyOnly:$VerifyOnly
                break
            }
            catch {
                if ($VerifyOnly -or $_.Exception.Message -notmatch '\bInvalidOutputTable\b' -or (Get-Date) -ge $deadline) { throw }
                Write-Host "DCR宛先テーブルの反映を待っています: $($Target.WorkspaceName)"
                Start-Sleep -Seconds 10
            }
        }
        $dcrReady = $true
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
    }
    catch {
        $ready = $false
        Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
    }
    foreach ($collectorId in $Target.Collectors) {
        $resourceId = "$collectorId/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName"
        $stage = "DCR関連付け"
        $expected = @{ properties = @{ dataCollectionRuleId = $dcrId } }
        try {
            if (-not $dcrReady -and -not $VerifyOnly) { throw "DCRの準備に失敗したため、関連付けを開始していません。" }
            $association = Set-BaselineResource -ResourceId $resourceId -ApiVersion "2024-03-11" -Body $expected -VerifyOnly:$VerifyOnly
            if (-not $VerifyOnly -and $association.properties.provisioningState -in @('Creating','Updating','Accepted')) {
                $association = Wait-RollbackResource -ResourceId $resourceId -Association
            }
            else { $association = Get-RollbackBody $association -Association -RequireReady }
            if (-not (Test-BaselineValues $association $expected)) { throw '更新完了後のDCR関連が完成形と一致しません。' }
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $true -Message "一致" -Expected $expected
        }
        catch {
            $ready = $false
            Add-MigrationCheck -Target $Target -ResourceId $resourceId -Stage $stage -Success $false -Message $_.Exception.Message -Expected $expected
        }
    }
    $ready
}


# 設定時とバックアップで、同じDCRの完成形を使います。
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

# DCR・関連付けは、書込み可能な前値だけを保存・比較します。
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


# 壊れたファイルや別の移行のファイルを使って、Azureを変更しないよう先に確認します。
function Read-MigrationBackup {
    param([string]$Path = $migrationBackupPath, [switch]$CheckCsv)
    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backup.Version -ne 2 -or -not $backup.CreatedAtUtc -or $backup.TargetWorkspaceId -ne $targetWorkspaceId -or
        $backup.Environment -ne $environment -or $backup.NewDiagnosticSettingName -ne $newDiagnosticSettingName -or
        $backup.Targets -isnot [array] -or $backup.Targets.Count -eq 0) { throw 'バックアップの版・環境・移行元・新設定名が今回の設定と一致しません。' }
    if ($backup.OldDcrIds -isnot [array] -or $backup.OldDcrIds.Count -ne 2 -or $backup.OldDcrIds[0] -eq $backup.OldDcrIds[1] -or
        @($backup.OldDcrIds | Where-Object { $_ -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.Insights/dataCollectionRules/[^/]+$' }).Count -gt 0 -or
        (@($backup.OldDcrIds | Sort-Object) -join ',') -ne (@($oldDcrIds | Sort-Object) -join ',')) { throw 'バックアップの旧DCR 2本が今回の設定と一致しません。' }
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
        if (-not $target.Routing.ResourceGroup -or -not $target.Routing.WorkspaceName -or $target.Routing.LogDestination -notin @('Storage','Log')) { throw 'バックアップのCSV情報が不正です。' }
        $prefix = "/subscriptions/$($target.SubscriptionId)/"
        $resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($saved in $target.Diagnostics) {
            if (-not ([string]$saved.ResourceId).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or
                -not $resources.Add($saved.ResourceId) -or $saved.OldName -isnot [string] -or [string]::IsNullOrWhiteSpace($saved.OldName) -or $saved.OldName -eq $newDiagnosticSettingName -or
                $saved.Before.workspaceId -ne $targetWorkspaceId -or -not $saved.After -or
                -not ($saved.After.workspaceId -or $saved.After.storageAccountId)) { throw 'バックアップの診断設定の対象・名前・送信先が不正、または重複しています。' }
        }
        # 同じDCRが診断対象と前値保存の両方に含まれることは許可します。
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
            if (@($target.Associations | Where-Object { ($_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','') -eq $parentId }).Count -ne 1) { throw '旧DCR関連の親リソースに、新DCR関連の保存情報がありません。' }
        }
        Assert-DcrCutoverIds -OldDcrIds $backup.OldDcrIds -NewDcrIds @(if ($target.Dcr) { $dcrId }) -OldAssociations $target.OldAssociations -NewAssociationIds @($target.Associations.ResourceId)
        $ownExemptions = @(foreach ($assignment in $policyAssignments) { "/subscriptions/$($target.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)" })
        if ((@($target.Exemptions.ResourceId | Sort-Object) -join ',') -ne (@($ownExemptions | Sort-Object) -join ',') -or
            @($target.Exemptions | Where-Object { $_.Existed -isnot [bool] }).Count -gt 0) { throw 'バックアップの適用除外情報が不正です。' }
    }
    if ($CheckCsv) {
        $rows = @(Import-Csv -LiteralPath $inputCsvPath -Encoding UTF8)
        if ($rows.Count -eq 0) { throw '対象CSVが空です。' }
        foreach ($row in $rows) {
            $saved = @($backup.Targets | Where-Object { $_.SubscriptionName -eq ([string]$row.SubscriptionName).Trim() })
            if ($saved.Count -ne 1) { throw 'CSVにバックアップ外のサブスクリプションがあります。' }
            foreach ($key in @('SubscriptionName','ResourceGroup','StorageAccount','WorkspaceName','LogDestination')) {
                if (([string]$row.$key).Trim() -ne [string]$saved[0].Routing.$key) { throw "CSVの$key がバックアップと一致しません。" }
            }
        }
    }
    $backup
}

# 削除途中の再実行では、保存済みの旧設定・旧関連が減ることだけを許可します。
function Assert-MigrationBackup {
    param([object]$Backup, [object[]]$Targets, [switch]$AllowMissingOld)
    if (@($Targets | Where-Object { $_.SubscriptionId -notin $Backup.Targets.SubscriptionId }).Count -gt 0) { throw 'サブスクリプションの実IDがバックアップにありません。' }
    foreach ($target in $Targets) {
        $saved = @($Backup.Targets | Where-Object SubscriptionId -eq $target.SubscriptionId)[0]
        $savedCollectors = @($saved.Associations | ForEach-Object { $_.ResourceId -replace '/providers/Microsoft.Insights/dataCollectionRuleAssociations/[^/]+$','' } | Sort-Object)
        if (-not $AllowMissingOld -and $target.DiagnosticPlans.Count -ne @($saved.Diagnostics).Count) { throw '旧診断設定の対象数がバックアップから変わっています。' }
        foreach ($plan in $target.DiagnosticPlans) {
            $original = @($saved.Diagnostics | Where-Object { $_.ResourceId -eq $plan.ResourceId -and $_.OldName -eq $plan.SourceName })
            if ($original.Count -ne 1 -or $plan.SourceSignature -cne (Get-DiagnosticSignature $original[0].Before) -or
                $plan.NewSignature -cne (Get-DiagnosticSignature $original[0].After)) { throw "バックアップ外、または変更された旧診断設定です: $($plan.ResourceId)" }
        }
        if (-not $AllowMissingOld -and $target.OldAssociations.Count -ne $saved.OldAssociations.Count) { throw '旧DCR関連の対象数がバックアップから変わっています。' }
        foreach ($association in $target.OldAssociations) {
            $original = @($saved.OldAssociations | Where-Object ResourceId -eq $association.ResourceId)
            # 一覧が返す参照先だけを照合し、削除直前は保存した全内容と比較します。
            if ($original.Count -ne 1 -or $original[0].Before.properties.dataCollectionRuleId -ne $association.Before.properties.dataCollectionRuleId) { throw "バックアップ外、または参照先が変わった旧DCR関連です: $($association.ResourceId)" }
        }
        # ④で旧関連が消えた親リソースも、新関連の全件確認から落としません。
        $target.Collectors = $savedCollectors
        foreach ($storage in $saved.Storages) { $target.Storages[$storage.Location] = $storage }
    }
}
# 旧設定の不足だけを補い、既存同名の異なる設定は上書きしません。
function Invoke-RollbackDiagnostics {
    param([object]$Target, [object[]]$Diagnostics, [switch]$Restore)
    $subscriptionId = $Target.SubscriptionId
    $items = @(foreach ($saved in $Diagnostics) {
        @{ ResourceId = $saved.ResourceId; OldName = $saved.OldName; Before = $saved.Before; After = $saved.After; Restore = [bool]$Restore }
    })
    Invoke-DiagnosticBatch -Items $items -SettingName $newDiagnosticSettingName -Action {
        param($saved, $newName)
        $settings = @(Get-DiagnosticSettings -ResourceId $saved.ResourceId)
        $old = @($settings | Where-Object { $_.name -eq $saved.OldName })
        $new = @($settings | Where-Object { $_.name -eq $newName })
        if ($old.Count -gt 1 -or ($old.Count -eq 1 -and (Get-DiagnosticSignature $old[0]) -cne (Get-DiagnosticSignature $saved.Before))) { throw '同名の旧診断設定が前値と異なります。上書きしません。' }
        if ($new.Count -gt 1 -or ($new.Count -eq 1 -and (Get-DiagnosticSignature $new[0]) -cne (Get-DiagnosticSignature $saved.After))) { throw '新診断設定が移行時の完成形と異なります。削除しません。' }
        if ($old.Count -eq 0 -and $settings.Count -ge 5) { throw '旧設定を復元する空きがありません。新設定は残します。' }
        if ($old.Count -eq 0 -and $saved.Restore) {
            $id = "$($saved.ResourceId)/providers/Microsoft.Insights/diagnosticSettings/$([Uri]::EscapeDataString($saved.OldName))"
            $null = Invoke-ArmRequest -Method Put -ResourceId $id -ApiVersion '2021-05-01-preview' -Body @{ properties = $saved.Before }
            $old = @(Get-DiagnosticSettings -ResourceId $saved.ResourceId -Name $saved.OldName)
            if ($old.Count -ne 1 -or (Get-DiagnosticSignature $old[0]) -cne (Get-DiagnosticSignature $saved.Before)) { throw '旧診断設定の復元後の読み戻しが一致しません。' }
        }
        [pscustomobject]@{ OldPresent = $old.Count -eq 1; NewPresent = $new.Count -eq 1 }
    }
}

# Afterの指定項目は一致必須。DCRの収集元・宛先・フローへの外部追加も見逃しません。
function Test-RollbackAfter {
    param([object]$Current, [object]$After, [object]$Before)
    if (-not (Test-BaselineValues $Current $After)) { return $false }
    foreach ($key in @('dataSources','destinations','dataFlows')) {
        if ($null -ne $After.properties.$key -and -not (Test-BaselineValues $After.properties.$key $Current.properties.$key)) { return $false }
    }
    foreach ($key in @('dataCollectionEndpointId','streamDeclarations','description')) {
        if ($null -eq $After.properties.$key -and $null -ne $Current.properties.$key -and
            -not ((Test-BaselineValues $Current.properties.$key $Before.properties.$key) -and (Test-BaselineValues $Before.properties.$key $Current.properties.$key))) { return $false }
    }
    $true
}
# 旧2本のDCRごとに一度一覧を取得し、対象Subの関連だけを保存します。
# VMごとの全関連一覧は取得せず、一覧が複数ページならnextLinkを辿ります。
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

# 新側への設定で旧経路を上書きする組合せは、名前を変えず事前停止します。
function Assert-DcrCutoverIds {
    param([string[]]$OldDcrIds, [string[]]$NewDcrIds, [object[]]$OldAssociations, [string[]]$NewAssociationIds)
    if (@($OldDcrIds | Where-Object { $_ -in $NewDcrIds }).Count -gt 0) { throw '旧DCRと新DCRのIDが同じです。' }
    if (@($OldAssociations | Where-Object { $_.ResourceId -in $NewAssociationIds }).Count -gt 0) { throw '旧関連と新関連のIDが同じです。既存経路を上書きしません。' }
}

# 自分の復元直後の更新中だけ、最大30秒待ってから完成状態を確認します。
function Wait-RollbackResource {
    param([string]$ResourceId, [switch]$Association)
    for ($attempt = 0; $attempt -lt 15; $attempt++) {
        $restored = Get-OptionalArmResource -ResourceId $ResourceId
        if ($restored -and $restored.properties.provisioningState -notin @('Creating','Updating','Accepted')) { break }
        Start-Sleep -Seconds 2
    }
    Get-RollbackBody $restored -Association:$Association -RequireReady
}
