#Requires -Version 5.1

# 実行時に指定する環境と、移行元のワークスペース・DCR
# このワークスペースへ送信している診断設定を、コピー・削除の対象にする。
$targetWorkspaceId = "/subscriptions/43fc6c39-e53d-449d-9871-6d66f95ed2f3/resourcegroups/rg-hub-sand-resource-01/providers/microsoft.operationalinsights/workspaces/log-hub-sand-collection-01"
# CSVに記載したサブスクリプションの環境を選ぶ。
$environment = "dev" # prod / stg / dev
# step3で解除する、VM・VMSSに関連付けられた旧DCRのリソースID。
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

# 通信設定と、移行で使用する名前・ファイル
$ErrorActionPreference = "Stop"
$script:stepTimer = [Diagnostics.Stopwatch]::StartNew()
# CLIの出力をUTF-8で受け取り、ARMへのHTTPS通信でTLS 1.2を使う。
$OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
$env:PYTHONIOENCODING = "utf-8"
[Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
$script:armTokens = @{}
if ($targetWorkspaceId -notmatch '^/subscriptions/[^/]+/resourcegroups/[^/]+/providers/microsoft\.operationalinsights/workspaces/[^/]+$') {
    throw "targetWorkspaceIdには移行元のLog AnalyticsワークスペースのリソースIDを指定してください。"
}
# 新しいLog AnalyticsとDCRを作成するリージョン。
$location = "japaneast"

# リソースの所在地がglobalまたは空の場合、Storageは東日本に作成する。
$globalResourceLocation = "japaneast"

# Storage名のjpe部分を置き換えるため、Microsoft公開のリージョン略称を取得する。
$regionNamesUrl = "https://raw.githubusercontent.com/mspnp/AzureNamingTool/main/src/repository/resourcelocations.json"

# 各リソースに追加する新しい診断設定の名前。
$newDiagnosticSettingName = "storage-archive"

# 除外するポリシー割り当て3件。先頭2件は全体、3件目は下の12参照IDを対象にする。
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

# 対象CSVと、step1が保存する変更前情報のファイル。
$inputCsvPath = Join-Path $PSScriptRoot "log_migration_targets_regional.csv"
$migrationBackupPath = Join-Path $PSScriptRoot "log_migration_backup_$environment.json"
$script:failures = [System.Collections.Generic.List[object]]::new()
$script:verificationResults = [System.Collections.Generic.List[object]]::new()
$script:regionNames = @()
$script:storageNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

# Azure CLIのJSON出力を、PowerShellのオブジェクトとして返す。
function Invoke-AzJson {
    param([string[]]$Arguments)

    $null = Get-Command az -ErrorAction Stop
    # JSONと警告を混ぜないよう標準エラーを別ファイルへ出し、終了コードで成否を判定する。
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
            # PowerShell 5.1のJSON配列も、要素を1件ずつ返す。
            foreach ($item in ($text | ConvertFrom-Json)) { $item }
        }
    }
    finally {
        $ErrorActionPreference = $previousPreference
        Remove-Item -LiteralPath $errorFile -Force
    }
}

# 保存済みのARM認証トークンを返す。期限まで5分以下ならCLIで再取得する。
function Get-ArmToken {
    $token = $script:armTokens[$subscriptionId]
    if (-not $token -or [long]$token.expires_on -le [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 300) {
        $token = Invoke-AzJson -Arguments @("account", "get-access-token", "--subscription", $subscriptionId, "--resource", "https://management.azure.com/")
        if (-not $token.accessToken -or -not $token.expires_on) { throw "ARMのアクセストークンを取得できません。" }
        $script:armTokens[$subscriptionId] = $token
    }
    $token
}

# リソースIDからARMのURLを作り、GET・PUT・PATCH・DELETEを送信する。
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
            # 認証切れならトークンを破棄し、取り直して同じ要求を送る。
            if ($status -eq 401 -and $attempt -lt 3) {
                $script:armTokens.Remove($subscriptionId)
                continue
            }
            # タイムアウト・過負荷・サーバーエラーは、待ち時間を延ばして再送する。
            if ($status -in @(408, 429, 500, 502, 503, 504) -and $attempt -lt 3) {
                $delay = [int][Math]::Pow(2, $attempt + 1)
                $retryAfter = [string]$failure.Exception.Response.Headers['Retry-After']
                if ($retryAfter -match '^\d+$') { $delay = [Math]::Max($delay, [int]$retryAfter) }
                Write-Host "ARM APIの一時エラー ($status)。$delay 秒後に再試行します。"
                Start-Sleep -Seconds $delay
                continue
            }
            $detail = $failure.ErrorDetails.Message
            # PowerShell 5.1でエラー詳細が空の場合は、HTTP応答本文から取得する。
            if (-not $detail -and $failure.Exception.Response -is [Net.WebResponse]) {
                $reader = [IO.StreamReader]::new($failure.Exception.Response.GetResponseStream())
                try { $detail = $reader.ReadToEnd() } finally { $reader.Dispose() }
            }
            if (-not $detail) { $detail = $failure.Exception.Message }
            throw "ARM $Method 失敗 ($status): $detail / $ResourceId"
        }
    }
}

# 対象を最大5組に分けて処理し、対象ごとの結果またはエラーを返す。
# ジョブに渡す設定値と戻り値は、ネストした項目が欠けないようJSONにする。
function Invoke-DiagnosticBatch {
    param([object[]]$Items, [scriptblock]$Action, [string]$SettingName)

    # 0～1件ならジョブを起動せず、このPowerShell内で処理する。
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

    # 子ジョブで使う関数の定義と認証トークンを用意する。
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
            # 各ジョブの対象件数が偏らないよう、順番に振り分ける。
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
                # 子ジョブ内に関数を登録し、渡された処理を各対象に実行する。
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
        # 全ジョブの結果を受け取り、JSONから設定オブジェクトへ戻す。
        Receive-Job -Job $jobs.ToArray() -Wait | ForEach-Object { $_ | ConvertFrom-Json }
    }
    finally {
        if ($jobs.Count -gt 0) {
            # 途中でエラーになった場合も、起動したジョブを停止・削除する。
            Stop-Job -Job $jobs.ToArray() -ErrorAction SilentlyContinue
            Remove-Job -Job $jobs.ToArray() -Force -ErrorAction SilentlyContinue
        }
    }
}

# 診断設定を取得し、propertiesに設定名を加えて返す。Name指定時はその1件を取得する。
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

# 診断設定を比較するため、収集条件と送信先を同じ順序のJSONにまとめる。
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
    # 送信先の文字列は大文字・小文字をそろえて比較する。
    foreach ($key in @("workspaceId", "storageAccountId", "eventHubAuthorizationRuleId", "eventHubName", "serviceBusRuleId", "marketplacePartnerId")) {
        $values[$key] = ([string]$Setting.$key).ToLowerInvariant()
    }
    # Log Analyticsの格納方式が省略されていれば、AzureDiagnosticsとして比較する。
    $values.logAnalyticsDestinationType = ""
    if ($Setting.workspaceId) {
        $values.logAnalyticsDestinationType = if ($Setting.logAnalyticsDestinationType) {
            ([string]$Setting.logAnalyticsDestinationType).ToLowerInvariant()
        } else { "azurediagnostics" }
    }
    ConvertTo-Json -InputObject $values -Depth 30 -Compress
}

# リソースをGETする。404なら値を返さず、それ以外の取得エラーは呼出し元へ返す。
function Get-OptionalArmResource {
    param([string]$ResourceId, [string]$ApiVersion = "2024-03-11")
    try { Invoke-ArmRequest -ResourceId $ResourceId -ApiVersion $ApiVersion }
    catch {
        if ($_.Exception.Message -notmatch '^ARM Get 失敗 \(404\):') { throw }
    }
}

# 対象ID・確認結果・理由・必要な設定値を記録する。NGは失敗一覧にも追加する。
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

# 取得・設定に失敗した対象を、NGの確認結果として記録する。
function Add-MigrationFailure {
    param([object]$Target, [string]$ResourceId, [string]$Stage, [string]$Message, [object]$Expected)
    Add-MigrationCheck -Target $Target -ResourceId $ResourceId -Stage $Stage -Success $false -Message $Message -Expected $Expected
}

# 結果一覧と失敗一覧をCSVに出力し、未完了があればエラーで工程を終える。
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

# CSVの各行を検査し、サブスクリプションIDと保存先IDを含む対象一覧を作る。
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
        # CSVの名前またはIDを照合するため、ログイン中のサブスクリプション一覧を取得する。
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
            # この行で見つかった診断設定・Storage・収集対象を格納する入れ物を用意する。
            $target.CurrentSettings = @{}
            $target.Storages = @{}
            $target.DiagnosticPlans = [System.Collections.Generic.List[object]]::new()
            $target.Collectors = @()
            $target.OldAssociations = @()
            $targets.Add($target)
        }
        # Storage宛ての行があれば、リージョン名と略称の一覧を1回取得する。
        if (@($targets | Where-Object { $_.LogDestination -eq "Storage" }).Count -gt 0) {
            $script:regionNames = Invoke-RestMethod -Uri $regionNamesUrl -TimeoutSec 30
            if ($script:regionNames.Count -eq 0) { throw "Azure Naming Toolのリージョン略称を取得できません。" }
        }
        $targets.ToArray()
    }
    catch { Add-MigrationFailure -Target $target -ResourceId $inputCsvPath -Stage "CSV・サブスクリプション確認" -Message $_.Exception.Message }
}

# 旧診断設定と旧DCR関連を調べ、追加する診断設定・地域別StorageをTargetに格納する。
function Get-MigrationPlan {
    param([object]$Target)

    $subscriptionId = $Target.SubscriptionId
    $Target.CurrentSettings = @{}
    $Target.Storages = @{}
    $Target.DiagnosticPlans.Clear()
    $ready = $true
    # 旧2DCRの関連から、このサブスクリプションの収集対象を取り出す。
    $Target.OldAssociations = @(Get-OldDcrAssociations -Targets @($Target) -DcrIds $oldDcrIds)
    $resources = @(Invoke-AzJson -Arguments @("resource", "list", "--subscription", $subscriptionId))
    $Target.Collectors = @($Target.OldAssociations.ParentResourceId | Where-Object { $_ } | Sort-Object -Unique)
    # ワークスペース名から、新DCR名と各収集対象の新関連IDを作る。
    $dcrName = $Target.WorkspaceName -replace '^log','dcr'
    $dcrId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Insights/dataCollectionRules/$dcrName"
    $newAssociationIds = @($Target.Collectors | ForEach-Object { "$_/providers/Microsoft.Insights/dataCollectionRuleAssociations/$dcrName" })
    Assert-DcrCutoverIds -OldDcrIds $oldDcrIds -NewDcrIds @(if ($Target.Collectors.Count -gt 0) { $dcrId }) -OldAssociations $Target.OldAssociations -NewAssociationIds $newAssociationIds
    # 通常のリソース一覧に加え、StorageのBlob・File・Queue・Tableも調査対象にする。
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
    # 全調査対象の診断設定を取得する。
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
            # 指定した旧ワークスペースを宛先にする診断設定だけを選ぶ。
            $sources = @($settings | Where-Object { $_.workspaceId -eq $targetWorkspaceId })
            if ($sources.Count -eq 0) { continue }
            if ($sources.Count -gt 1) { throw "対象の旧設定が複数あります。統合や上書きは行いません。" }
            $source = $sources[0]
            if ($source.name -eq $newDiagnosticSettingName) { throw "旧設定名と新しい診断設定名が同じです。" }
            # 旧設定のログ・メトリックをそのまま引き継ぎ、送信先を組み立てる。
            $expected = @{ logs = @($source.logs | Where-Object { $null -ne $_ }); metrics = @($source.metrics | Where-Object { $null -ne $_ }) }
            $region = ""
            if ($Target.LogDestination -eq "Storage") {
                $region = ([string]$diagnosticResources[$resourceId] -replace '\s', '').ToLowerInvariant()
                if (-not $region -or $region -eq "global") { $region = $globalResourceLocation }
                # リージョンの略称を取得し、CSVのStorage名にあるjpeを置き換える。
                $regionName = @($script:regionNames | Where-Object { ($_.name -replace '\s', '') -eq $region })
                if ($regionName.Count -ne 1 -or $regionName[0].shortName -cnotmatch '^[a-z0-9]+$') { throw "Azure Naming Toolの略称を一意に取得できません: $region" }
                $storageName = $Target.StorageAccount.Replace("jpe", [string]$regionName[0].shortName)
                if ($storageName -cnotmatch '^[a-z0-9]{3,24}$') { throw "変換後のストレージ名が不正です: $storageName" }
                $storageId = "/subscriptions/$subscriptionId/resourceGroups/$($Target.ResourceGroup)/providers/Microsoft.Storage/storageAccounts/$storageName"
                $Target.Storages[$region] = @{ Name = $storageName; Id = $storageId; Location = $region }
                $expected.storageAccountId = $storageId
            }
            else {
                # Log宛てはリージョンで分けず、CSVのワークスペースへ送る。
                $expected.workspaceId = $Target.WorkspaceId
                if ($source.logAnalyticsDestinationType) { $expected.logAnalyticsDestinationType = $source.logAnalyticsDestinationType }
            }
            # 新設定が未作成なら、既存設定を残して追加できる空き枠があるか確認する。
            $newSettings = @($settings | Where-Object { $_.name -eq $newDiagnosticSettingName })
            if ($newSettings.Count -eq 0 -and $settings.Count -ge 5) { throw "診断設定が上限の5件です。旧設定を残して追加する余地がありません。" }
            # 対象ID・旧設定名・新しい設定値と、比較用JSONを記録する。
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

    Write-Host "調査完了: $($Target.SubscriptionName) / 対象診断設定=$($Target.DiagnosticPlans.Count) / ストレージ=$($Target.Storages.Count) / 旧DCR関連=$($Target.OldAssociations.Count) / 収集対象=$($Target.Collectors.Count)"
    $ready
}


# Expectedに指定した項目が、Actualにも同じ値で存在するか調べる。
# 配列は順序にかかわらず、件数と要素を照合する。
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
            # 一致済みの要素を外し、同じ要素を2回使って一致と判定しないようにする。
            $remaining.RemoveAt($match)
        }
        return $true
    }
    if ($Expected -is [bool] -and $Actual -isnot [bool]) { return $false }
    return $Actual -eq $Expected
}


# 適用除外の割り当て・Waiver・期限・対象参照IDを指定値と照合する。
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


# WindowsイベントログとSyslogを、新ワークスペースへ送るDCRの設定値を作る。
function Get-MigrationDcrBody {
    param([object]$Target)
    $body = @{
        location = $location
        properties = @{
            # Windowsの3ログと、LinuxのSyslogの収集条件。
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
            # 収集した2種類のストリームを、CSVのLog Analyticsへ接続する。
            destinations = @{ logAnalytics = @(@{ name = "new-workspace"; workspaceResourceId = $Target.WorkspaceId }) }
            dataFlows = @(
                @{ streams = @("Microsoft-Event"); destinations = @("new-workspace") }
                @{ streams = @("Microsoft-Syslog"); destinations = @("new-workspace") }
            )
        }
    }
    $body
}

# DCR・関連付けのGET応答から、復元時のPUTに必要な項目を取り出す。
function Get-RollbackBody {
    param([object]$Resource, [switch]$Association, [switch]$RequireReady)
    if (-not $Resource) { return $null }
    if ($RequireReady -and (-not $Association -or $Resource.properties.provisioningState) -and $Resource.properties.provisioningState -ne 'Succeeded') {
        throw "DCR・関連付けの作成・更新が完了していません: state=$($Resource.properties.provisioningState)"
    }
    # 元の応答を残したまま、コピーから読み取り専用項目を除く。
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
    # マネージドIDは種類とユーザー割当IDを残し、Azureが採番したIDを除く。
    if ($body.identity) {
        foreach ($key in @('principalId','tenantId')) { $body.identity.PSObject.Properties.Remove($key) }
        foreach ($identity in $body.identity.userAssignedIdentities.PSObject.Properties) { $identity.Value = [pscustomobject]@{} }
    }
    $body
}


# BeforeのJSONを読み、環境・移行元・設定名・対象IDが今回の実行と合っているか確認する。
function Read-MigrationBackup {
    param([string]$Path = $migrationBackupPath, [switch]$CheckCsv)
    $backup = Get-Content -LiteralPath $Path -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($backup.Version -ne 3 -or -not $backup.CreatedAtUtc -or $backup.TargetWorkspaceId -ne $targetWorkspaceId -or
        $backup.Environment -ne $environment -or $backup.NewDiagnosticSettingName -ne $newDiagnosticSettingName -or
        $backup.Targets -isnot [array] -or $backup.Targets.Count -eq 0) { throw '①で作成したバックアップの版・環境・移行元・新設定名が今回の設定と一致しません。' }
    if ($backup.OldDcrIds -isnot [array] -or $backup.OldDcrIds.Count -ne 2 -or $backup.OldDcrIds[0] -eq $backup.OldDcrIds[1] -or
        @($backup.OldDcrIds | Where-Object { $_ -notmatch '^/subscriptions/[0-9a-f-]{36}/resourceGroups/[^/]+/providers/Microsoft.Insights/dataCollectionRules/[^/]+$' }).Count -gt 0 -or
        (@($backup.OldDcrIds | Sort-Object) -join ',') -ne (@($oldDcrIds | Sort-Object) -join ',')) { throw 'バックアップの旧DCR 2本が今回の設定と一致しません。' }
    # Subごとの必須項目と、保存されたリソースIDの重複を確認する。
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
        # 診断設定とは別に、Storage・DCR・関連付け・適用除外のID重複を確認する。
        $resources = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($saved in @($target.Storages) + @($target.Dcr | Where-Object { $null -ne $_ }) + @($target.Associations) + @($target.OldAssociations) + @($target.Exemptions)) {
            $id = if ($saved.ResourceId) { $saved.ResourceId } else { $saved.Id }
            if (-not ([string]$id).StartsWith($prefix,[StringComparison]::OrdinalIgnoreCase) -or -not $resources.Add($id)) { throw 'バックアップに別サブスクリプション、または重複したリソースが含まれています。' }
        }
        # 保存された新DCRのIDと関連名を、CSVのワークスペース名から照合する。
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
        # この環境で使う3つの適用除外と、作成前の有無が保存されているか確認する。
        $ownExemptions = @(foreach ($assignment in $policyAssignments) { "/subscriptions/$($target.SubscriptionId)/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)" })
        if ((@($target.Exemptions.ResourceId | Sort-Object) -join ',') -ne (@($ownExemptions | Sort-Object) -join ',') -or
            @($target.Exemptions | Where-Object { $_.Existed -isnot [bool] }).Count -gt 0) { throw 'バックアップの適用除外情報が不正です。' }
    }
    # 確認・削除工程では、CSVの対象と保存先も変更前記録と照合する。
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


# 旧2DCRの関連一覧から、CSVの対象Subにある関連だけを返す。
# 一覧が複数ページなら、nextLinkのページも取得する。
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
                # 関連IDから、親リソースIDと所属Sub IDを取り出す。
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

# 新旧でDCR本体または関連付けのIDが重複していないか確認する。
function Assert-DcrCutoverIds {
    param([string[]]$OldDcrIds, [string[]]$NewDcrIds, [object[]]$OldAssociations, [string[]]$NewAssociationIds)
    if (@($OldDcrIds | Where-Object { $_ -in $NewDcrIds }).Count -gt 0) { throw '旧DCRと新DCRのIDが同じです。' }
    if (@($OldAssociations | Where-Object { $_.ResourceId -in $NewAssociationIds }).Count -gt 0) { throw '旧関連と新関連のIDが同じです。既存経路を上書きしません。' }
}


