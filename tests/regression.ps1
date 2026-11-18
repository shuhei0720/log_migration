#Requires -Version 5.1
param([string]$Repository = (Join-Path (Split-Path -Parent $PSScriptRoot) 'migration'))
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$checks = 0

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw "検証失敗: $Message" }
    $script:checks++
}
function Read-ProductionAst {
    param([string]$Name)
    $tokens = $null; $errors = $null
    $sourceName = if (Test-Path (Join-Path $Repository 'common.ps1')) { 'common.ps1' } else { $Name }
    $ast = [System.Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository $sourceName), [ref]$tokens, [ref]$errors)
    if ($errors.Count) { throw "構文エラー: $Name / $($errors.Message -join '; ')" }
    $ast
}
function Copy-Setting {
    param([object]$Setting)
    $Setting | ConvertTo-Json -Depth 30 | ConvertFrom-Json
}

# 共通ファイルと各工程は、実際のファイルを個別に構文確認します。
$productionFiles=@('common.ps1','precheck.ps1','step1_copy.ps1','step2_verify.ps1','step3_delete.ps1','rollback.ps1')
foreach ($entryFile in $productionFiles) {
    $tokens = $null; $errors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile((Join-Path $Repository $entryFile),[ref]$tokens,[ref]$errors)
    Assert-True ($errors.Count -eq 0) "$entryFile : 構文"
}

# 本体は実行せず、実際に使用する比較関数だけを読み込みます。
foreach ($name in @('step1_copy.ps1', 'step3_delete.ps1')) {
    $ast = Read-ProductionAst $name
    $node = @($ast.FindAll({ param($item)
        $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Get-DiagnosticSignature'
    }, $true))
    Assert-True ($node.Count -eq 1) "$name の比較関数"
    Invoke-Expression $node[0].Extent.Text
    $base = [pscustomobject]@{
        storageAccountId = '/subscriptions/test/storage'
        logs = @(
            @{categoryGroup='allLogs';enabled=$true;retentionPolicy=@{enabled=$false;days=0}},
            @{category='Audit';enabled=$false;retentionPolicy=@{enabled=$false;days=30}}
        )
        metrics = @(@{category='AllMetrics';enabled=$true;timeGrain='PT1M'}, @{category='OtherMetric';enabled=$false})
    }
    $other = Copy-Setting $base
    $other | Add-Member logAnalyticsDestinationType 'AzureDiagnostics'
    Assert-True ((Get-DiagnosticSignature $base) -ceq (Get-DiagnosticSignature $other)) "$name : Storageの無関係な格納方式"
    $base | Add-Member workspaceId '/subscriptions/test/workspace'
    $other = Copy-Setting $base
    $other | Add-Member logAnalyticsDestinationType 'AzureDiagnostics'
    Assert-True ((Get-DiagnosticSignature $base) -ceq (Get-DiagnosticSignature $other)) "$name : 省略時の既定方式"
    $other.logAnalyticsDestinationType = 'Dedicated'
    Assert-True ((Get-DiagnosticSignature $base) -cne (Get-DiagnosticSignature $other)) "$name : Dedicatedとの差異"
    foreach ($change in @('ログ有効', '保持日数', '保持有効', 'カテゴリー群', 'メトリックカテゴリー', 'メトリック有効', '送信先')) {
        $other = Copy-Setting $base
        switch ($change) {
            'ログ有効' { $other.logs[0].enabled = $false }
            '保持日数' { $other.logs[1].retentionPolicy.days = 31 }
            '保持有効' { $other.logs[1].retentionPolicy.enabled = $true }
            'カテゴリー群' { $other.logs[0].categoryGroup = 'audit' }
            'メトリックカテゴリー' { $other.metrics[0].category = 'Changed' }
            'メトリック有効' { $other.metrics[0].enabled = $false }
            '送信先' { $other.storageAccountId = '/subscriptions/test/other' }
        }
        Assert-True ((Get-DiagnosticSignature $base) -cne (Get-DiagnosticSignature $other)) "$name : $change"
    }
    $other = Copy-Setting $base
    $other.logs = @($other.logs[1], $other.logs[0]); $other.metrics = @($other.metrics[1], $other.metrics[0])
    Assert-True ((Get-DiagnosticSignature $base) -ceq (Get-DiagnosticSignature $other)) "$name : 配列順に依存しない"
    Assert-True ((Get-DiagnosticSignature @{logs=$null;metrics=$null}) -ceq (Get-DiagnosticSignature @{logs=@();metrics=@()})) "$name : nullと空配列"
}
foreach ($name in @('step1_copy.ps1')) {
    $ast = Read-ProductionAst $name
    $text = Get-Content (Join-Path $Repository 'precheck.ps1') -Raw
    Assert-True ($text -match '"storage"\s*,\s*"sku"\s*,\s*"list"') "$name : 正しいSKUコマンド"
    Assert-True ($text -match 'atScope\(\)' -and $text -match 'policyAssignments\?api-version') "$name : 継承を含む割り当て取得"
    $guards = @($ast.FindAll({ param($item)
        $item -is [System.Management.Automation.Language.IfStatementAst] -and
        $item.Clauses[0].Item1.Extent.Text -match 'Matches.*jpe' -and $item.Clauses[0].Item1.Extent.Text -match '\{3,24\}'
    }, $true))
    Assert-True ($guards.Count -eq 1) "$name : 名前チェックを実コードから抽出"
    foreach ($case in @(
        @{Name='jp';Valid=$false}, @{Name='jpe';Valid=$true},
        @{Name=('jpe'+('a'*21));Valid=$true}, @{Name=('jpe'+('a'*22));Valid=$false},
        @{Name='jpeA';Valid=$false}, @{Name='JPE';Valid=$false}, @{Name='abc';Valid=$false},
        @{Name='jpejpe';Valid=$false}, @{Name='jpe-123';Valid=$false}, @{Name='jpe123';Valid=$true}
    )) {
        $target = @{LogDestination='Storage';StorageAccount=$case.Name}; $nameToCheck = $case.Name
        $name = $nameToCheck; $accepted = $true
        try { Invoke-Expression $guards[0].Extent.Text } catch { $accepted = $false }
        Assert-True ($accepted -eq $case.Valid) "ストレージ名: $nameToCheck"
    }
    $target = @{LogDestination='Log';StorageAccount=''}; $name = ''
    Invoke-Expression $guards[0].Extent.Text
    Assert-True $true 'Logではストレージ名は不要'
}

# 変換後の名前と診断設定数も、本体のガードをそのまま呼び出して境界を確認します。
$copyAst = Read-ProductionAst 'step1_copy.ps1'
$convertedNameGuards = @($copyAst.FindAll({ param($item)
    $item -is [Management.Automation.Language.IfStatementAst] -and
    $item.Clauses[0].Item1.Extent.Text -match '^\$(storagePlan\.Name|storageName)\s+-cnotmatch\s+' -and
    $item.Clauses[0].Item1.Extent.Text -match '\{3,24\}'
}, $true))
Assert-True ($convertedNameGuards.Count -eq 1) '変換後ストレージ名のガードを実コードから抽出'
foreach ($case in @(
    @{BaseName=('jpe'+('a'*21));ShortName='usw2';FinalLength=25;Valid=$false},
    @{BaseName=('jpe'+('a'*20));ShortName='usw2';FinalLength=24;Valid=$true},
    @{BaseName='jpe';ShortName='jp';FinalLength=2;Valid=$false}
)) {
    $storagePlan = @{Name=$case.BaseName.Replace('jpe',$case.ShortName)}
    $storageName = $storagePlan.Name
    $accepted = $true
    try { Invoke-Expression $convertedNameGuards[0].Extent.Text } catch { $accepted = $false }
    Assert-True ($accepted -eq $case.Valid -and $storagePlan.Name.Length -eq $case.FinalLength) "変換前$($case.BaseName.Length)文字→変換後$($case.FinalLength)文字"
}
$settingCountGuards = @($copyAst.FindAll({ param($item)
    $item -is [Management.Automation.Language.IfStatementAst] -and
    $item.Clauses[0].Item1.Extent.Text -match '\$settings\.Count\s+-ge\s+5\b' -and
    $item.Clauses[0].Item1.Extent.Text -match '\$newSettings\.Count\s+-eq\s+0'
}, $true))
Assert-True ($settingCountGuards.Count -eq 1) '診断設定数のガードを実コードから抽出'
foreach ($case in @(@{Count=4;Valid=$true}, @{Count=5;Valid=$false}, @{Count=6;Valid=$false})) {
    $settings = @(1..$case.Count | ForEach-Object { [pscustomobject]@{name="old$_"} })
    $newSettings = @()
    $accepted = $true
    try { Invoke-Expression $settingCountGuards[0].Extent.Text } catch { $accepted = $false }
    Assert-True ($accepted -eq $case.Valid) "診断設定が$($case.Count)件の場合"
}

# 外部接続せず、本物のネイティブプロセスで警告・終了コードを再現します。
$onWindows = $env:OS -eq 'Windows_NT'
$root = Join-Path ([IO.Path]::GetTempPath()) ('migration-regression-'+[guid]::NewGuid().ToString('N'))
$bin = New-Item -ItemType Directory (Join-Path $root 'bin') -Force
$scratch = New-Item -ItemType Directory (Join-Path $root 'scratch') -Force
$originalPath = $env:PATH; $originalTmpDir = $env:TMPDIR
$originalTmp = $env:TMP; $originalTemp = $env:TEMP; $originalPathExt = $env:PATHEXT
$originalSystemTemp = $env:SystemTemp
$originalConsoleEncoding = [Console]::OutputEncoding; $originalOutputEncoding = $OutputEncoding
try {
    $OutputEncoding = [Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
    if ($onWindows) {
        $fakeScript = @'
param([string]$Mode)
[Console]::OutputEncoding = [Text.UTF8Encoding]::new($false)
if ($Mode -eq 'fail') { [Console]::Error.WriteLine('native-failure-7'); exit 7 }
[Console]::Error.WriteLine('native-warning')
if ($Mode -eq 'empty') { exit 0 }
if ($Mode -eq 'array2') { [Console]::Out.WriteLine('[{"index":1},{"index":2}]'); exit 0 }
if ($Mode -eq 'singlearray1') { [Console]::Out.WriteLine('[{"index":1}]'); exit 0 }
if ($Mode -eq 'emptyarray0') { [Console]::Out.WriteLine('[]'); exit 0 }
[Console]::Out.WriteLine('{"ok":true,"name":"日本語"}')
exit 0
'@
        [IO.File]::WriteAllText((Join-Path $bin.FullName 'fake-az.ps1'), $fakeScript, [Text.UTF8Encoding]::new($true))
        $engine = [Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
        $fakePath = Join-Path $bin.FullName 'az.cmd'
        $batch = '@echo off' + "`r`n" + '"' + $engine + '" -NoProfile -NonInteractive -File "%~dp0fake-az.ps1" %*' + "`r`nexit /b %errorlevel%`r`n"
        [IO.File]::WriteAllText($fakePath, $batch, [Text.UTF8Encoding]::new($false))
        if ('.CMD' -notin ($env:PATHEXT -split ';')) { $env:PATHEXT = '.CMD;' + $env:PATHEXT }
    }
    else {
        $fake = @'
#!/bin/sh
case "$1" in
 fail) printf '%s\n' 'native-failure-7' >&2; exit 7 ;;
 empty) printf '%s\n' 'native-warning' >&2; exit 0 ;;
esac
printf '%s\n' 'native-warning' >&2
case "$1" in
 array2) printf '%s\n' '[{"index":1},{"index":2}]' ;;
 singlearray1) printf '%s\n' '[{"index":1}]' ;;
 emptyarray0) printf '%s\n' '[]' ;;
 *) printf '%s\n' '{"ok":true,"name":"日本語"}' ;;
esac
'@
        $fakePath = Join-Path $bin.FullName 'az'
        [IO.File]::WriteAllText($fakePath, $fake.Replace("`r`n", "`n"), [Text.UTF8Encoding]::new($false))
        & chmod +x $fakePath
        if ($LASTEXITCODE) { throw '模擬CLIの権限設定に失敗しました。' }
    }
    $env:PATH = $bin.FullName + [IO.Path]::PathSeparator + $originalPath
    $env:TMPDIR = $scratch.FullName; $env:TMP = $scratch.FullName; $env:TEMP = $scratch.FullName
    # WindowsのSYSTEM実行ではGetTempPath2がSystemTempを優先します。
    if ($onWindows) { $env:SystemTemp = $scratch.FullName }
    Assert-True (([IO.Path]::GetTempPath()).TrimEnd([char[]]@('/','\')) -eq $scratch.FullName) '一時ファイルの検査先'
    Assert-True ((Get-Command az -ErrorAction Stop).Source -eq $fakePath) '実Azure CLIではなくネイティブ模擬CLIを選択'
    foreach ($file in @('step1_copy.ps1','step3_delete.ps1')) {
        $ast = Read-ProductionAst $file
        $node = $ast.Find({ param($item)
            $item -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq 'Invoke-AzJson'
        }, $true)
        Invoke-Expression $node.Extent.Text
        $result = Invoke-AzJson -Arguments @('warning')
        Assert-True ($result.ok -and $result.name -eq '日本語') "$file : 警告と日本語JSONを分離"
        Assert-True (@(Invoke-AzJson -Arguments @('empty')).Count -eq 0) "$file : 空の結果"
        foreach ($case in @(
            @{Mode='array2';Count=2}, @{Mode='singlearray1';Count=1}, @{Mode='emptyarray0';Count=0}
        )) {
            $items = @(Invoke-AzJson -Arguments @($case.Mode))
            Assert-True ($items.Count -eq $case.Count) "$file : JSON配列の件数 $($case.Mode)"
            # パイプラインで再展開せず、直接添字で配列の入れ子化とnullを検出します。
            $objectElements = $true
            for ($index = 0; $index -lt $items.Count; $index++) {
                if ($items[$index] -isnot [pscustomobject]) { $objectElements = $false }
            }
            Assert-True $objectElements "$file : JSON配列の要素型 $($case.Mode)"
        }
        $message = ''
        try { $null = Invoke-AzJson -Arguments @('fail') } catch { $message = $_.Exception.Message }
        Assert-True ($message -match 'native-failure-7') "$file : エラー本文を保持"
        Assert-True (@(Get-ChildItem $scratch.FullName -Force).Count -eq 0) "$file : 一時ファイルを除去"
        Assert-True ($ErrorActionPreference -eq 'Stop') "$file : 呼び出し元のエラー処理方針を復元"
    }
}
finally {
    $env:PATH = $originalPath; $env:TMPDIR = $originalTmpDir
    $env:TMP = $originalTmp; $env:TEMP = $originalTemp; $env:PATHEXT = $originalPathExt
    $env:SystemTemp = $originalSystemTemp
    [Console]::OutputEncoding = $originalConsoleEncoding; $OutputEncoding = $originalOutputEncoding
    Remove-Item $root -Recurse -Force
}

# 5.1と7の両方で、HTTP応答付き例外を外部接続せず再現します。
if (-not ('MigrationRegression.ArmException' -as [type])) {
    Add-Type -IgnoreWarnings -TypeDefinition @'
using System;
using System.Collections;
using System.IO;
using System.Text;
namespace MigrationRegression {
    public sealed class ArmResponse : System.Net.WebResponse {
        public int StatusCode { get; private set; }
        private readonly System.Net.WebHeaderCollection headers;
        private readonly string body;
        public override System.Net.WebHeaderCollection Headers { get { return headers; } }
        public ArmResponse(int status, Hashtable values, string text) {
            StatusCode=status; body=text; headers=new System.Net.WebHeaderCollection();
            foreach (DictionaryEntry entry in values) { headers[Convert.ToString(entry.Key)]=Convert.ToString(entry.Value); }
        }
        public override Stream GetResponseStream() { return new MemoryStream(Encoding.UTF8.GetBytes(body)); }
    }
    public sealed class ArmException : Exception {
        public ArmResponse Response { get; private set; }
        public ArmException(int status, Hashtable headers, string text) : base("HTTP " + status) {
            Response=new ArmResponse(status, headers, text);
        }
    }
}
'@
}
function Reset-ArmMock {
    $script:armTokens = @{}
    $script:tokenRequests = [Collections.Generic.List[object]]::new()
    $script:armRequests = [Collections.Generic.List[object]]::new()
    $script:sleepRequests = [Collections.Generic.List[int]]::new()
    $script:armQueue = [Collections.Generic.List[object]]::new()
    $script:subscriptionId = 'subscription-a'
}
function Invoke-AzJson {
    param([string[]]$Arguments)
    if ($Arguments[0] -ne 'account' -or $Arguments[1] -ne 'get-access-token') {
        throw '想定外のCLI呼び出しです。実Azure CLIは起動しません。'
    }
    $script:tokenRequests.Add($Arguments.Clone())
    [pscustomobject]@{
        accessToken = 'fixture-token-' + $script:tokenRequests.Count
        expires_on = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() + 3600
    }
}
function Start-Sleep {
    param([int]$Seconds)
    $script:sleepRequests.Add($Seconds)
}
function Invoke-RestMethod {
    param([string]$Uri, [string]$Method, [hashtable]$Headers, [string]$ContentType, [int]$TimeoutSec, [object]$Body)
    $script:armRequests.Add([pscustomobject]@{
        Uri=$Uri; Method=$Method; Headers=$Headers.Clone(); ContentType=$ContentType; Body=$Body
    })
    if ($script:armQueue.Count -eq 0) { throw '想定外のHTTP呼び出しです。ネットワークには接続しません。' }
    $step = $script:armQueue[0]; $script:armQueue.RemoveAt(0)
    if ($step.Status -ge 400) {
        $headers = @{}
        if ($step.RetryAfter) { $headers['Retry-After'] = [string]$step.RetryAfter }
        $bodyText = '{"error":{"code":"FixtureError","message":"日本語のエラー本文"}}'
        $exception = [MigrationRegression.ArmException]::new([int]$step.Status, $headers, $bodyText)
        $record = [Management.Automation.ErrorRecord]::new($exception, 'MockArmFailure', [Management.Automation.ErrorCategory]::InvalidOperation, $Uri)
        if (-not $step.StreamOnly) { $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($bodyText) }
        throw $record
    }
    if ($step.ContainsKey('Result')) { return $step.Result }
    [pscustomobject]@{ok=$true}
}

foreach ($file in @('step1_copy.ps1','step3_delete.ps1')) {
    $ast = Read-ProductionAst $file
    foreach ($functionName in @('Get-ArmToken','Invoke-ArmRequest','Get-DiagnosticSettings')) {
        $node = @($ast.FindAll({ param($item)
            $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName
        }, $true))
        Assert-True ($node.Count -eq 1) "$file : $functionName を実コードから抽出"
        Invoke-Expression $node[0].Extent.Text
    }

    Reset-ArmMock
    $script:armQueue.Add(@{Status=200}); $script:armQueue.Add(@{Status=200}); $script:armQueue.Add(@{Status=200})
    $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/one'
    $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/two'
    Assert-True ($script:tokenRequests.Count -eq 1) "$file : 同一サブスクリプションではトークンを再利用"
    $script:subscriptionId = 'subscription-b'
    $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-b/resources/three'
    Assert-True ($script:tokenRequests.Count -eq 2 -and $script:armTokens.Count -eq 2) "$file : トークンをサブスクリプションごとに分離"
    Assert-True ($script:tokenRequests[0] -contains 'subscription-a' -and $script:tokenRequests[1] -contains 'subscription-b') "$file : 指定サブスクリプションのトークンを取得"
    Assert-True ($script:tokenRequests[0] -contains 'https://management.azure.com/') "$file : ARM用のトークンを要求"

    foreach ($remainingSeconds in @(299, 0, -1)) {
        Reset-ArmMock
        $script:armTokens[$subscriptionId] = [pscustomobject]@{accessToken='old-fixture-token';expires_on=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+$remainingSeconds}
        $script:armQueue.Add(@{Status=200})
        $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/renew'
        Assert-True ($script:tokenRequests.Count -eq 1) "$file : 残り$remainingSeconds 秒のトークンを期限前更新"
    }

    Reset-ArmMock
    $script:armQueue.Add(@{Status=401}); $script:armQueue.Add(@{Status=200})
    $result = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/refresh'
    Assert-True ($result.ok -and $script:tokenRequests.Count -eq 2 -and $script:armRequests.Count -eq 2) "$file : 401でトークンを再取得して再試行"
    Assert-True ($script:armRequests[0].Headers.Authorization -ne $script:armRequests[1].Headers.Authorization) "$file : 401後は新しいトークンを送信"

    foreach ($status in @(408,429,500,502,503,504)) {
        Reset-ArmMock
        $script:armQueue.Add(@{Status=$status;RetryAfter=7}); $script:armQueue.Add(@{Status=200})
        $result = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/throttled'
        Assert-True ($result.ok -and $script:armRequests.Count -eq 2 -and $script:tokenRequests.Count -eq 1) "$file : $status は同じトークンで再試行"
        Assert-True ($script:sleepRequests.Count -eq 1 -and $script:sleepRequests[0] -eq 7) "$file : Retry-Afterを尊重し、実際には待機しない"
    }

    Reset-ArmMock
    $script:armQueue.Add(@{Status=429;RetryAfter=120}); $script:armQueue.Add(@{Status=200})
    $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/long-retry-after'
    Assert-True (($script:sleepRequests | Measure-Object -Sum).Sum -ge 120) "$file : 長いRetry-Afterも短縮しない"

    Reset-ArmMock
    1..4 | ForEach-Object { $script:armQueue.Add(@{Status=429}) }
    $message = ''
    try { $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/retry-limit' } catch { $message = $_.Exception.Message }
    Assert-True ($message -match '429' -and $script:armRequests.Count -eq 4 -and $script:sleepRequests.Count -eq 3) "$file : 一時エラーでも再試行回数を制限"

    foreach ($streamOnly in @($false,$true)) {
        Reset-ArmMock
        $script:armQueue.Add(@{Status=400;StreamOnly=$streamOnly})
        $message = ''
        try { $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/bad-request' } catch { $message = $_.Exception.Message }
        Assert-True ($script:armRequests.Count -eq 1 -and $script:sleepRequests.Count -eq 0) "$file : 400は再試行せず即時停止（本文ストリーム=$streamOnly）"
        Assert-True ($message -match '400' -and $message -match '日本語のエラー本文') "$file : ARMの日本語エラー本文を保持（本文ストリーム=$streamOnly）"
    }

    Reset-ArmMock
    $script:armQueue.Add(@{Status=200})
    $body = @{description='日本語の設定';logs=@(@{category='監査';enabled=$true})}
    $null = Invoke-ArmRequest -ResourceId '/subscriptions/subscription-a/resources/put' -Method Put -Body $body -ApiVersion '2021-05-01-preview'
    $sent = $script:armRequests[0]
    Assert-True ($sent.Body -is [byte[]]) "$file : PUT本文はUTF-8バイト配列"
    $decoded = [Text.Encoding]::UTF8.GetString($sent.Body) | ConvertFrom-Json
    Assert-True ($decoded.description -eq '日本語の設定' -and $decoded.logs[0].category -eq '監査') "$file : PUTの日本語JSONを保持"
    Assert-True ($sent.Method -eq 'Put' -and $sent.ContentType -match 'charset=utf-8' -and $sent.Uri.EndsWith('?api-version=2021-05-01-preview')) "$file : PUTのメソッド・Content-Type・API版"

    Reset-ArmMock
    $script:armQueue.Add(@{Status=200;Result=[pscustomobject]@{value=@(
        [pscustomobject]@{name='old';properties=[pscustomobject]@{workspaceId='/workspaces/one';logs=@()}},
        [pscustomobject]@{name='new';properties=[pscustomobject]@{storageAccountId='/storage/two';metrics=@()}}
    )}})
    $settings = @(Get-DiagnosticSettings -ResourceId '/subscriptions/subscription-a/resources/list')
    Assert-True ($settings.Count -eq 2 -and $settings[0].name -eq 'old' -and $settings[1].name -eq 'new') "$file : ARM一覧を従来の設定オブジェクトへ変換"
    Assert-True ($settings[0].workspaceId -eq '/workspaces/one' -and $settings[1].storageAccountId -eq '/storage/two') "$file : 変換後も送信先を保持"

    Reset-ArmMock
    $script:armQueue.Add(@{Status=200;Result=[pscustomobject]@{value=@()}})
    Assert-True (@(Get-DiagnosticSettings -ResourceId '/subscriptions/subscription-a/resources/empty').Count -eq 0) "$file : ARMの空一覧"

    Reset-ArmMock
    $script:armQueue.Add(@{Status=200;Result=[pscustomobject]@{name='新設定 名';properties=[pscustomobject]@{logs=@()}}})
    $setting = Get-DiagnosticSettings -ResourceId '/subscriptions/subscription-a/resources/single' -Name '新設定 名'
    Assert-True ($setting.name -eq '新設定 名' -and $script:armRequests[0].Uri -match '%20' -and $script:armRequests[0].Uri -notmatch '新設定') "$file : 単体取得の設定名をURLエンコード"
}
# 候補の並列処理だけを、実際の標準ジョブとオフラインのActionで確認します。
function Reset-BatchMock {
    Reset-ArmMock
    $script:armTokens[$subscriptionId] = [pscustomobject]@{
        accessToken='batch-fixture-token';expires_on=[DateTimeOffset]::UtcNow.ToUnixTimeSeconds()+3600
    }
    $script:batchJobIds = [Collections.Generic.List[int]]::new()
    $script:maxBatchJobs = 0; $script:startJobCalls = 0; $script:failStartAt = 0
}
function Start-Job {
    [CmdletBinding()]
    param([scriptblock]$ScriptBlock, [object[]]$ArgumentList, [string]$Name, [scriptblock]$InitializationScript)
    $script:startJobCalls++
    if ($script:failStartAt -eq $script:startJobCalls) { throw 'fixture-start-failure' }
    $native = Get-Command Start-Job -CommandType Cmdlet
    $job = & $native @PSBoundParameters
    $script:batchJobIds.Add($job.Id)
    $owned = @(Get-Job | Where-Object { $_.Id -in $script:batchJobIds })
    $script:maxBatchJobs = [Math]::Max($script:maxBatchJobs,$owned.Count)
    $job
}
foreach ($file in @('step1_copy.ps1','step3_delete.ps1')) {
    $ast = Read-ProductionAst $file
    foreach ($functionName in @('Get-ArmToken','Invoke-ArmRequest','Get-DiagnosticSettings','Get-DiagnosticSignature','Invoke-DiagnosticBatch')) {
        $node = @($ast.FindAll({ param($item)
            $item -is [Management.Automation.Language.FunctionDefinitionAst] -and $item.Name -eq $functionName
        },$true))
        Assert-True ($node.Count -eq 1) "$file : batch用$functionName を実コードから抽出"
        Invoke-Expression $node[0].Extent.Text
    }
    $settingName = '監査設定 コピー①'
    $simpleAction = { param($item,$settingName)
        [pscustomobject]@{First=$item;Second=$settingName;ProcessId=$PID}
    }
    Reset-BatchMock
    $records = @(Invoke-DiagnosticBatch -Items @() -Action $simpleAction -SettingName $settingName)
    Assert-True ($records.Count -eq 0 -and $script:startJobCalls -eq 0) "$file : 0件はActionもジョブも実行しない"
    $records = @(Invoke-DiagnosticBatch -Items @('/resources/日本語') -Action $simpleAction -SettingName $settingName)
    Assert-True ($records.Count -eq 1 -and $records[0].Item -eq '/resources/日本語' -and -not $records[0].Error) "$file : 1件も同じ成功record形式"
    Assert-True ($records[0].Result.First -eq '/resources/日本語' -and $records[0].Result.Second -ceq $settingName) "$file : 直列Actionの第1・第2引数"
    Assert-True ($records[0].Result.ProcessId -eq $PID -and $script:startJobCalls -eq 0) "$file : 1件は親で実行して起動負荷を省く"
    $records = @(Invoke-DiagnosticBatch -Items @('single-error') -Action { param($item,$settingName) throw 'fixture-日本語-error' } -SettingName $settingName)
    Assert-True ($records.Count -eq 1 -and $records[0].Error -match 'fixture-日本語-error' -and $null -eq $records[0].Result) "$file : 1件の失敗もerror recordにする"

    $items = @(foreach ($index in 1..7) {
        [pscustomobject]@{
            Id=$index;ResourceId="/resources/$index"
            Expected=[pscustomobject]@{
                storageAccountId="/storage/$index"
                logs=@(
                    @{categoryGroup='allLogs';enabled=$true;retentionPolicy=@{enabled=$true;days=365}},
                    @{category='監査';enabled=$false;retentionPolicy=@{enabled=$false;days=31}}
                )
                metrics=@(@{category='AllMetrics';enabled=$true;timeGrain='PT1M';retentionPolicy=@{enabled=$false;days=0}})
                Deep=@{One=@{Two=@{Three=@{Four=@{Leaf='深い日本語'}}}}}
            }
        }
    })
    $expectedSignatures = @{}
    foreach ($item in $items) { $expectedSignatures[[string]$item.Id] = Get-DiagnosticSignature -Setting $item.Expected }
    $batchAction = { param($item,$settingName)
        if ($item.Id -eq 4) { throw 'fixture-日本語-error' }
        if ($item.Id -eq 1) { Write-Host 'fixture-info'; Write-Warning 'fixture-warning' }
        $token = Get-ArmToken
        [pscustomobject]@{
            First=$item.ResourceId;Second=$settingName;ProcessId=$PID
            Signature=Get-DiagnosticSignature -Setting $item.Expected
            Data=$item.Expected;CachedToken=($token.accessToken -eq 'batch-fixture-token')
        }
    }
    Reset-BatchMock
    try {
        $records = @(Invoke-DiagnosticBatch -Items $items -Action $batchAction -SettingName $settingName)
        Assert-True ($records.Count -eq 7) "$file : 複数itemは各1record"
        Assert-True (@($records | ForEach-Object { [string]$_.Item.Id } | Sort-Object -Unique).Count -eq 7) "$file : 全itemを1度ずつ返す"
        Assert-True ($script:maxBatchJobs -eq 5 -and $script:startJobCalls -eq 5) "$file : 実際の標準ジョブは最大5個"
        Assert-True ($script:tokenRequests.Count -eq 0) "$file : 親の有効トークンを共有してCLIを起動しない"
        $success = @($records | Where-Object { -not $_.Error })
        $failed = @($records | Where-Object { $_.Error })
        Assert-True ($success.Count -eq 6 -and $failed.Count -eq 1 -and $failed[0].Item.Id -eq 4 -and $failed[0].Error -match 'fixture-日本語-error') "$file : 子の成功と失敗を個別に返す"
        Assert-True (@($success | Where-Object { $_.Result.ProcessId -eq $PID }).Count -eq 0) "$file : 複数itemは子プロセスで実行"
        Assert-True (@($success | ForEach-Object { $_.Result.ProcessId } | Sort-Object -Unique).Count -gt 1) "$file : 複数の子プロセスを使用"
        foreach ($record in $success) {
            $item = $record.Item; $result = $record.Result
            Assert-True ($result.First -ceq $item.ResourceId -and $result.Second -ceq $settingName -and $result.CachedToken) "$file : 子の第1・第2引数とトークンを保持（$($item.Id)）"
            Assert-True ($result.Signature -ceq $expectedSignatures[[string]$item.Id]) "$file : 子の比較関数は親と同じ結果（$($item.Id)）"
            Assert-True ($result.Data.logs[0].retentionPolicy.enabled -eq $true -and $result.Data.logs[0].retentionPolicy.days -eq 365 -and $result.Data.logs[1].enabled -eq $false -and $result.Data.logs[1].retentionPolicy.days -eq 31 -and $result.Data.metrics[0].timeGrain -eq 'PT1M' -and $result.Data.Deep.One.Two.Three.Four.Leaf -eq '深い日本語') "$file : 深いログ・メトリックのJSON入出力を保持（$($item.Id)）"
        }
        Assert-True (@(Get-Job | Where-Object { $_.Id -in $script:batchJobIds }).Count -eq 0) "$file : 成功・Action失敗後にジョブを除去"
    }
    finally {
        Get-Job | Where-Object { $_.Id -in $script:batchJobIds } | Stop-Job -ErrorAction SilentlyContinue
        Get-Job | Where-Object { $_.Id -in $script:batchJobIds } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
    Reset-BatchMock
    $script:failStartAt = 2; $message = ''
    try {
        try { $null = Invoke-DiagnosticBatch -Items $items -Action $batchAction -SettingName $settingName } catch { $message = $_.Exception.Message }
        Assert-True ($message -match 'fixture-start-failure') "$file : ジョブ起動失敗を隠さない"
        Assert-True (@(Get-Job | Where-Object { $_.Id -in $script:batchJobIds }).Count -eq 0) "$file : 起動途中の失敗でもfinallyで既存ジョブを除去"
    }
    finally {
        Get-Job | Where-Object { $_.Id -in $script:batchJobIds } | Stop-Job -ErrorAction SilentlyContinue
        Get-Job | Where-Object { $_.Id -in $script:batchJobIds } | Remove-Job -Force -ErrorAction SilentlyContinue
    }
}

# 既存の工程smokeを隔離し、Azure接続は最小のメモリ内fixtureに置き換えます。
& {
    try {
$ErrorActionPreference = 'Stop'
$directory = $Repository
. (Join-Path $directory 'common.ps1')
$targetWorkspaceId = '/subscriptions/old/resourceGroups/old/providers/Microsoft.OperationalInsights/workspaces/old'
function Assert([bool]$condition, [string]$reason) { if (-not $condition) { throw $reason }; $script:checks++ }
$script:store = @{}
$script:writes = [System.Collections.Generic.List[string]]::new()
$script:availability = $true
$script:baselineBadSubscription = ''
$script:destinationReads = [Collections.Generic.List[string]]::new()
$script:cliCreates = [Collections.Generic.List[string]]::new()
$script:flow = [Collections.Generic.List[string]]::new()
$script:backedWrites = [Collections.Generic.List[string]]::new()
$script:nameChecks = [Collections.Generic.List[string]]::new()
$inputCsvPath = Join-Path ([IO.Path]::GetTempPath()) ('migration-staged-'+[guid]::NewGuid().ToString('N')+'.csv')
$migrationBackupPath = $inputCsvPath+'.backup.json'
$script:entryBackup = $null
@(
    [pscustomobject]@{SubscriptionName='s1';ResourceGroup='rg';StorageAccount='stjpetest1';WorkspaceName='log-new';LogDestination='Storage'},
    [pscustomobject]@{SubscriptionName='s2';ResourceGroup='rg';StorageAccount='stjpetest2';WorkspaceName='log-new';LogDestination='Storage'}
) | Export-Csv $inputCsvPath -NoTypeInformation -Encoding UTF8
function Reset-Report { $script:failures.Clear(); $script:verificationResults.Clear(); $script:writes.Clear(); $script:storageNames.Clear(); $script:initiativeDefinition=$null; $script:destinationReads.Clear();$script:cliCreates.Clear();$script:flow.Clear();$script:backedWrites.Clear();$script:nameChecks.Clear() }
function Get-ResourceId([string]$subscription) { "/subscriptions/$subscription/resourceGroups/source/providers/Some.Service/resources/example" }
function New-Fixture {
    $script:store = @{}
    $script:destinations = @{}
    $script:storageTemplates = @{}
    $script:resourceLocations = @{}
    foreach ($subscription in @('s1','s2')) {
        $resourceId = Get-ResourceId $subscription
        $script:resourceLocations[$resourceId]='japaneast'
        $script:store[$resourceId] = @{
            old = [pscustomobject]@{name='old';workspaceId=$targetWorkspaceId;logs=@([pscustomobject]@{category='日本語';enabled=$false;retentionPolicy=[pscustomobject]@{enabled=$true;days=17}});metrics=@()}
            unrelated = [pscustomobject]@{name='unrelated';workspaceId='/other';logs=@();metrics=@()}
        }
        # 保存先は一致した実状態を再現し、本体の作成/確認コードを省略しません。
        $groupId="/subscriptions/$subscription/resourceGroups/rg"
        $storageId="$groupId/providers/Microsoft.Storage/storageAccounts/stjpetest$($subscription.Substring(1))"
        $script:destinations[$groupId]=[pscustomobject]@{id=$groupId;location='japaneast'}
        $script:storageTemplates[$storageId]=Copy-Setting @{
            id=$storageId;location='japaneast';kind='StorageV2';sku=@{name='Standard_ZRS'}
            properties=@{
                provisioningState='Succeeded';encryption=@{requireInfrastructureEncryption=$true};immutableStorageWithVersioning=@{enabled=$true}
                publicNetworkAccess='Enabled';allowBlobPublicAccess=$false;allowSharedKeyAccess=$false;supportsHttpsTrafficOnly=$true;minimumTlsVersion='TLS1_2'
                networkAcls=@{defaultAction='Deny';bypass='AzureServices'}
            }
        }
        $script:destinations["$storageId/blobServices/default"]=Copy-Setting @{properties=@{isVersioningEnabled=$true}}
        $script:destinations["$storageId/managementPolicies/default"]=Copy-Setting @{properties=@{policy=@{rules=@(@{
            name='log-append-1095';enabled=$true;type='Lifecycle'
            definition=@{filters=@{blobTypes=@('appendBlob')};actions=@{baseBlob=@{delete=@{daysAfterModificationGreaterThan=1095}}}}
        })}}}
        $script:destinations["$storageId/providers/Microsoft.Security/defenderForStorageSettings/current"]=Copy-Setting @{properties=@{isEnabled=$false;overrideSubscriptionLevelSettings=$true}}
        $workspaceId="$groupId/providers/Microsoft.OperationalInsights/workspaces/log-new"
        $script:destinations[$workspaceId]=Copy-Setting @{
            location='japaneast';properties=@{retentionInDays=365;publicNetworkAccessForIngestion='Enabled';publicNetworkAccessForQuery='Enabled';features=@{enableLogAccessUsingOnlyResourcePermissions=$true};provisioningState='Succeeded'}
        }
        foreach($assignment in $policyAssignments){
            $properties=@{policyAssignmentId=$assignment.Id;exemptionCategory='Waiver';assignmentScopeValidation='Default'}
            if($assignment.ReferenceIds.Count -gt 0){$properties.policyDefinitionReferenceIds=@($assignment.ReferenceIds)}
            $exemptionId="/subscriptions/$subscription/providers/Microsoft.Authorization/policyExemptions/log-migration-$environment-$($assignment.Name)"
            $script:destinations[$exemptionId]=Copy-Setting @{properties=$properties}
        }
    }
}
function Invoke-AzJson {
    param([string[]]$Arguments)
    switch ($Arguments[0] + '/' + $Arguments[1]) {
        'account/list' { foreach ($id in @('s1','s2')) { [pscustomobject]@{id=$id;name=$id} }; return }
        'resource/list' {
            $subscription = $Arguments[3]
            $script:flow.Add('scan:'+$subscription)
            foreach($id in @($script:store.Keys | Sort-Object)){
                if($id -like "/subscriptions/$subscription/*"){[pscustomobject]@{id=$id;type='Some.Service/resources';location=$(if($script:resourceLocations.ContainsKey($id)){$script:resourceLocations[$id]}else{'japaneast'})}}
            }
            return
        }
        'storage/sku' { [pscustomobject]@{name='Standard_ZRS';kind='StorageV2';locations=@('japaneast','japanwest')}; return }
        'storage/account' {
            $sub=$Arguments[[array]::IndexOf($Arguments,'--subscription')+1]
            $name=$Arguments[[array]::IndexOf($Arguments,'--name')+1]
            $id="/subscriptions/$sub/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/$name"
            if($Arguments[2] -eq 'check-name'){
                $script:nameChecks.Add($name)
                [pscustomobject]@{nameAvailable=($script:availability -and -not $script:destinations.ContainsKey($id));reason='AlreadyExists'};return
            }
            if($Arguments[2] -eq 'create' -and $script:storageTemplates.ContainsKey($id)){
                Assert-BackedBeforeWrite $id
                $script:cliCreates.Add($id)
                $script:destinations[$id]=Copy-Setting $script:storageTemplates[$id]
                return $script:destinations[$id]
            }
            throw 'Unexpected storage command or creation target'
        }
        'provider/show' { [pscustomobject]@{registrationState='Registered'}; return }
        default { throw "Unexpected CLI: $($Arguments -join ' ')" }
    }
}
function Invoke-RestMethod {
    param([string]$Uri, [int]$TimeoutSec)
    # 実際のIRMと同じく、root JSON arrayを1オブジェクトとして返します。
    Write-Output -NoEnumerate @([pscustomobject]@{name='japaneast';shortName='jpe'},[pscustomobject]@{name='japanwest';shortName='jpw'})
}
# HTTP/CLIの変更直前に、今回の対象SubのBeforeが既にファイルへ保存済みか観測します。
function Assert-BackedBeforeWrite([string]$ResourceId) {
    if(-not (Test-Path -LiteralPath $migrationBackupPath)){throw 'TEST_BEFORE_NOT_DURABLE'}
    $saved=Get-Content -LiteralPath $migrationBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json
    $sub=($ResourceId -split '/')[2]
    $row=@($saved.Targets | Where-Object SubscriptionId -eq $sub)
    if($saved.Version -ne 3 -or $row.Count -ne 1){throw 'TEST_BEFORE_SUB_NOT_DURABLE'}
    if($ResourceId -match '^(.*)/providers/Microsoft.Insights/diagnosticSettings/[^/]+$'){
        $diagnostic=@($row[0].Diagnostics | Where-Object ResourceId -eq $Matches[1])
        if($diagnostic.Count -ne 1 -or $diagnostic[0].Before.workspaceId -ne $targetWorkspaceId){throw 'TEST_DIAGNOSTIC_BEFORE_NOT_DURABLE'}
    }
    $script:flow.Add('write:'+$sub)
    $script:backedWrites.Add($ResourceId)
}
# メモリ内fixtureの処理は同じActionを同じスコープで実行します。標準ジョブ自体は上の実テストで確認済みです。
function Invoke-DiagnosticBatch {
    param([object[]]$Items,[scriptblock]$Action,[string]$SettingName)
    foreach($item in $Items){
        try{[pscustomobject]@{Item=$item;Result=(& $Action $item $SettingName);Error=''}}
        catch{[pscustomobject]@{Item=$item;Result=$null;Error=$_.Exception.Message}}
    }
}
function Get-DiagnosticSettings {
    param([string]$ResourceId, [string]$Name)
    if ($Name) { $script:store[$ResourceId][$Name] }
    else { foreach ($setting in $script:store[$ResourceId].Values) { $setting } }
}
function Invoke-ArmRequest {
    param([string]$ResourceId, [string]$Method='Get', [hashtable]$Body, [string]$ApiVersion)
    if($Method -eq 'Get' -and $ResourceId -match '/storageAccounts/[^/]+$' -and -not $script:destinations.ContainsKey($ResourceId)){throw 'ARM Get 失敗 (404): fixture storage absent'}
    if($Method -eq 'Get' -and $script:destinations.ContainsKey($ResourceId)) {
        $script:destinationReads.Add($ResourceId)
        $current=Copy-Setting $script:destinations[$ResourceId]
        if($script:baselineBadSubscription -and $ResourceId -like "/subscriptions/$script:baselineBadSubscription/*/workspaces/*"){$current.properties.retentionInDays=30}
        return $current
    }
    if($ResourceId -match '/dataCollectionRules/[^/]+$' -or $ResourceId -match '/dataCollectionRuleAssociations/[^/]+$'){throw 'ARM Get 失敗 (404): fixture rule absent'}
    if ($ResourceId -match '/policyAssignments\?') {
        [pscustomobject]@{value=@(foreach ($assignment in $policyAssignments) {[pscustomobject]@{id=$assignment.Id;properties=[pscustomobject]@{policyDefinitionId='/providers/Microsoft.Authorization/policySetDefinitions/test'}}})}; return
    }
    if ($ResourceId -match '/policySetDefinitions/') {
        [pscustomobject]@{properties=[pscustomobject]@{policyDefinitions=@(foreach ($id in $policyReferenceIds) {[pscustomobject]@{policyDefinitionReferenceId=$id}})}}; return
    }
    if ($ResourceId -match '^(.*)/providers/Microsoft.Insights/diagnosticSettings/([^/]+)$') {
        $parentId=$Matches[1]; $name=[Uri]::UnescapeDataString($Matches[2]); Assert-BackedBeforeWrite $ResourceId; $script:writes.Add("$Method $ResourceId")
        if ($Method -eq 'Delete') { $script:store[$parentId].Remove($name); return }
        if ($Method -eq 'Put') {
            $setting = ConvertFrom-Json (ConvertTo-Json -InputObject $Body.properties -Depth 40)
            $setting | Add-Member name $name
            $script:store[$parentId][$name] = $setting
            return
        }
    }
    throw "Unexpected ARM: $Method $ResourceId"
}
function Complete-MigrationStep {
    param([string]$Step, [switch]$IncludeChecks)
    if ($script:failures.Count -gt 0) { throw "TEST_STEP_NG:$Step" }
}
# この既存工程smokeは短いs1/s2を使うため、ファイル形式の検証は専用backup smokeへ任せます。
function Read-MigrationBackup { param($Path,[switch]$CheckCsv) $script:entryBackup }
function Get-OldDcrAssociations {param([object[]]$Targets,[string[]]$DcrIds) @()}
function Run-Step([string]$Step, [bool]$FailureExpected=$false) {
    $script:storageNames.Clear()
    $text = Get-Content (Join-Path $directory (@{ precheck='precheck.ps1'; copy='step1_copy.ps1'; verify='step2_verify.ps1'; delete='step3_delete.ps1'; rollback='rollback.ps1' }[$Step])) -Raw
    $body = ($text -split "`n" | Select-Object -Skip 2) -join "`n"
    $failed = $false
    try { Invoke-Expression $body }
    catch { if ($_.Exception.Message -notlike 'TEST_STEP_NG:*') { throw }; $failed=$true }
    if ($Step -eq 'copy' -and (Test-Path -LiteralPath $migrationBackupPath)) { $script:entryBackup = Get-Content $migrationBackupPath -Raw -Encoding UTF8 | ConvertFrom-Json }
    Assert ($failed -eq $FailureExpected) "step outcome $Step"
}
New-Fixture
# 事前チェックは既存の①バックアップがあっても読み書きせず、単独で確認できます。
Set-Content -LiteralPath $migrationBackupPath -Value 'TEST_EXISTING_BACKUP_UNCHANGED' -Encoding UTF8
$beforeHash=(Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash
Reset-Report
Run-Step precheck
Assert ($script:writes.Count -eq 0) 'precheck must read only'
Assert ((Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash -ceq $beforeHash) 'precheck must not read or replace an existing backup'
Remove-Item -LiteralPath $migrationBackupPath -Force
Reset-Report
Run-Step precheck
Assert (-not (Test-Path -LiteralPath $migrationBackupPath)) 'precheck must not create a backup for later stages'
# 前日の事前チェック後に増えたリソースも、①が直前に調べて対象に含めます。
$lateId='/subscriptions/s2/resourceGroups/source/providers/Some.Service/resources/added-after-precheck'
$script:store[$lateId]=@{
    old=[pscustomobject]@{name='old';workspaceId=$targetWorkspaceId;logs=@([pscustomobject]@{category='翌日追加';enabled=$true});metrics=@()}
    unrelated=[pscustomobject]@{name='unrelated';workspaceId='/other';logs=@();metrics=@()}
}
$script:availability=$false
Reset-Report
Run-Step precheck $true
Assert ($script:writes.Count -eq 0 -and $script:failures.Count -eq 2) 'fresh same-name must stop both without writes'
$script:availability=$true
Reset-Report
Run-Step copy
Assert ($script:writes.Count -eq 3 -and $script:cliCreates.Count -eq 2) 'copy must freshly discover and capture three resources, then create two storage accounts'
Assert ($script:entryBackup.Version -eq 3 -and @($script:entryBackup.Targets.Diagnostics).Count -eq 3 -and $script:store[$lateId].ContainsKey($newDiagnosticSettingName)) 'stage II must include the resource added after day-before checks'
Assert ($script:flow.IndexOf('scan:s1') -lt $script:flow.IndexOf('write:s1') -and $script:flow.IndexOf('write:s1') -lt $script:flow.IndexOf('scan:s2')) 'sub A scan and durable capture and writes precede sub B resource scan'
Assert ($script:backedWrites.Count -eq 5) 'every initial storage and diagnostic mutation observed its durable Before'
$firstBackupHash=(Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash
$script:availability=$false
foreach ($id in $script:store.Keys) { Assert ($script:store[$id].ContainsKey('old') -and $script:store[$id].ContainsKey('unrelated')) 'old and unrelated retained' }
Reset-Report
Run-Step copy
Assert ($script:writes.Count -eq 0 -and $script:cliCreates.Count -eq 0 -and $script:nameChecks.Count -eq 0) 'copy rerun must skip matching new and saved storage names'
Assert ((Get-FileHash -LiteralPath $migrationBackupPath -Algorithm SHA256).Hash -ceq $firstBackupHash) 'no-op stage II must retain the original durable Before file'
# 同じサブスクリプションに後から増えた地域だけ、新しい保存先とBeforeを追加します。
$beforeRegionAppend=Copy-Setting $script:entryBackup
$regionResourceId='/subscriptions/s1/resourceGroups/source/providers/Some.Service/resources/added-japanwest'
$script:resourceLocations[$regionResourceId]='japanwest'
$script:store[$regionResourceId]=@{
    old=[pscustomobject]@{name='old';workspaceId=$targetWorkspaceId;logs=@([pscustomobject]@{category='別地域追加';enabled=$true});metrics=@()}
    unrelated=[pscustomobject]@{name='unrelated';workspaceId='/other';logs=@();metrics=@()}
}
$jpeStorage='/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/stjpetest1'
$jpwStorage='/subscriptions/s1/resourceGroups/rg/providers/Microsoft.Storage/storageAccounts/stjpwtest1'
$script:storageTemplates[$jpwStorage]=Copy-Setting $script:storageTemplates[$jpeStorage]
$script:storageTemplates[$jpwStorage].id=$jpwStorage
$script:storageTemplates[$jpwStorage].location='japanwest'
foreach($suffix in @('/blobServices/default','/managementPolicies/default','/providers/Microsoft.Security/defenderForStorageSettings/current')){
    $script:destinations[$jpwStorage+$suffix]=Copy-Setting $script:destinations[$jpeStorage+$suffix]
}
$script:availability=$true
Reset-Report
Run-Step copy
Assert ($script:cliCreates.Count -eq 1 -and $script:cliCreates[0] -eq $jpwStorage -and $script:writes.Count -eq 1) 'resume must create only the newly needed regional storage and diagnostic setting'
Assert ($script:store[$regionResourceId][$newDiagnosticSettingName].storageAccountId -eq $jpwStorage) 'new region diagnostic setting uses its own region storage'
Assert ($script:entryBackup.CreatedAtUtc -ceq $beforeRegionAppend.CreatedAtUtc -and @($script:entryBackup.Targets.Diagnostics).Count -eq 4) 'append must preserve the original migration metadata and add the new target'
foreach($original in $beforeRegionAppend.Targets.Diagnostics){
    $saved=@($script:entryBackup.Targets.Diagnostics | Where-Object ResourceId -eq $original.ResourceId)[0]
    Assert ((Get-DiagnosticSignature $saved.Before) -ceq (Get-DiagnosticSignature $original.Before)) 'regional append must preserve every prior diagnostic Before'
}

$script:availability=$true
Reset-Report
Run-Step precheck $true
Assert ($script:writes.Count -eq 0 -and @($script:failures | Where-Object { $_.Reason -match '新しい診断設定名' }).Count -eq 4) 'fresh must reject even identical existing new names'
$id1=Get-ResourceId s1; $id2=Get-ResourceId s2
$script:store[$id1][$newDiagnosticSettingName].logs[0].enabled=$true
Reset-Report
Run-Step copy $true
Assert ($script:writes.Count -eq 0 -and $script:failures.Count -eq 1) 'mismatching new must not overwrite'
Assert ($script:failures[0].ExpectedLogs -match '日本語' -and $script:failures[0].ExpectedStorageAccountId -like '*stjpetest1') 'manual CSV data must contain expected values'
$script:store[$id1][$newDiagnosticSettingName].logs[0].enabled=$false
Reset-Report
Run-Step verify
Assert ($script:writes.Count -eq 0) 'verify must read only'
Assert (@($script:destinationReads | Where-Object { $_ -match '/workspaces/log-new$' } | Sort-Object -Unique).Count -eq 2 -and @($script:destinationReads | Where-Object { $_ -match '/storageAccounts/stjpetest[12]$' } | Sort-Object -Unique).Count -eq 2) 'verify must read both subscriptions actual destination configurations'
$script:store[$id2].Remove($newDiagnosticSettingName)
Reset-Report
Run-Step delete $true
Assert ($script:writes.Count -eq 0 -and $script:store[$id1].ContainsKey('old')) 'late subscription mismatch must block all deletes'
Reset-Report
Run-Step copy
Assert ($script:writes.Count -eq 1) 'resume missing new only'
$script:baselineBadSubscription='s2'
Reset-Report
Run-Step delete $true
Assert ($script:writes.Count -eq 0) 'baseline mismatch must block all deletes'
$script:baselineBadSubscription=''
Reset-Report
Run-Step delete
Assert ($script:writes.Count -eq 4) 'all matching must delete all four old only'
foreach ($id in $script:store.Keys) { Assert (-not $script:store[$id].ContainsKey('old') -and $script:store[$id].ContainsKey('unrelated') -and $script:store[$id].ContainsKey($newDiagnosticSettingName)) 'new and unrelated retained after deletion' }
Reset-Report
Run-Step delete
Assert ($script:writes.Count -eq 0) 'delete rerun must skip already removed old'

    } finally { foreach ($path in @($inputCsvPath,$migrationBackupPath)) { if ($path -and (Test-Path -LiteralPath $path)) { Remove-Item -LiteralPath $path -Force } } }
}
$coreChecks=$script:checks
# 保存した実ARM応答を使うbaseline単体検証も、別script scopeで実行します。
$baselineReportPath = Join-Path ([IO.Path]::GetTempPath()) ('migration-baseline-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $baselineResult = & (Join-Path $PSScriptRoot 'baseline-smoke.ps1') -Repository $Repository -ReportPath $baselineReportPath -PassThru
    Assert-True ($baselineResult.Result -eq 'PASS' -and $baselineResult.AzureRequests -eq 0) '実ARM応答のbaselineオフライン再生'
    $script:checks += [int]$baselineResult.Checks
}
finally { if (Test-Path -LiteralPath $baselineReportPath) { Remove-Item -LiteralPath $baselineReportPath -Force } }
# 本体のライフサイクル処理からHTTP送信直前のUTF8本文まで通して確認します。
$lifecycleResult = & (Join-Path $PSScriptRoot 'lifecycle-request-replay.ps1') -SourceCommon (Join-Path $Repository 'common.ps1') -PassThru
Assert-True ($lifecycleResult.Result -eq 'PASS' -and $lifecycleResult.AzureRequests -eq 0) 'LifecycleのHTTP送信本文を外部通信なしで確認'
$script:checks += [int]$lifecycleResult.Assertions
# バックアップと切戻しの失敗保護・再実行も、外部通信なしで確認します。
$rollbackReportPath = Join-Path ([IO.Path]::GetTempPath()) ('migration-rollback-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $rollbackResult = & (Join-Path $PSScriptRoot 'backup-rollback-smoke.ps1') -Repository $Repository -ReportPath $rollbackReportPath -PassThru
    Assert-True ($rollbackResult.Result -eq 'PASS' -and $rollbackResult.AzureRequests -eq 0) 'バックアップ・切戻しのオフライン再生'
    $script:checks += [int]$rollbackResult.Checks
    $rollbackResult | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'backup-rollback-smoke-result.json') -Encoding UTF8
}
finally { if (Test-Path -LiteralPath $rollbackReportPath) { Remove-Item -LiteralPath $rollbackReportPath -Force } }
# 旧DCR2本の切替・VMSS・部分再実行も、実工程を状態mockへ通して確認します。
$cutoverReportPath = Join-Path ([IO.Path]::GetTempPath()) ('migration-dcr-cutover-'+[guid]::NewGuid().ToString('N')+'.json')
try {
    $cutoverResult = & (Join-Path $PSScriptRoot 'dcr-cutover-smoke.ps1') -Repository $Repository -ReportPath $cutoverReportPath -PassThru
    Assert-True ($cutoverResult.Result -eq 'PASS' -and $cutoverResult.AzureRequests -eq 0) '旧DCR2本の解除・復元と全件barrier'
    $script:checks += [int]$cutoverResult.Checks
    $cutoverResult | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'dcr-cutover-smoke-result.json') -Encoding UTF8
}
finally { if(Test-Path -LiteralPath $cutoverReportPath) {Remove-Item -LiteralPath $cutoverReportPath -Force} }
$hashes=@{}
foreach($file in $productionFiles){$hashes[$file]=(Get-FileHash (Join-Path $Repository $file) -Algorithm SHA256).Hash}
$summary=[pscustomobject]@{
    Result='PASS';Checks=$checks;AzureRequests=0;PowerShellVersion=$PSVersionTable.PSVersion.ToString()
    CoreChecks=$coreChecks
    BaselineCases=$baselineResult.CaseCount;BaselineChecks=$baselineResult.Checks
    LifecycleCases=@($lifecycleResult.Cases).Count;LifecycleChecks=$lifecycleResult.Assertions
    BackupCases=$rollbackResult.CaseCount;BackupChecks=$rollbackResult.Checks
    DcrCases=$cutoverResult.CaseCount;DcrChecks=$cutoverResult.Checks
    FormalCases=$baselineResult.CaseCount+@($lifecycleResult.Cases).Count+$rollbackResult.CaseCount+$cutoverResult.CaseCount
    FamilyConnectionChecks=4
    ManifestFiles=$productionFiles.Count+5+@(Get-ChildItem (Join-Path $PSScriptRoot 'fixtures/baseline-shapes') -File -Filter '*.json').Count
    Hashes=$hashes
}
$summary | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $PSScriptRoot 'regression-summary.json') -Encoding UTF8
Write-Host "ローカル回帰検証 $checks 件成功。Azureへの接続・変更は実行していません。"
