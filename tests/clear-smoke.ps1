#Requires -Version 7.0
param(
    [string]$Repository = (Join-Path (Split-Path -Parent $PSScriptRoot) 'clear-migration'),
    [string]$ReportPath
)
$ErrorActionPreference = 'Stop'

# 既存テストの直接API呼出しへSub IDを渡す。判定式と試験用の応答はそのまま使う。
$sourcePath = Join-Path $PSScriptRoot 'procedural-smoke.ps1'
$source = [IO.File]::ReadAllText($sourcePath)
$tokens = $null
$errors = $null
$ast = [Management.Automation.Language.Parser]::ParseInput($source, [ref]$tokens, [ref]$errors)
if ($errors.Count) {
    throw '既存テストの構文に誤りがあります。'
}
$calls = @($ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -eq 'Invoke-ArmRequest' }, $true))
if ($calls.Count -ne 5) {
    throw '既存テストの直接API呼出しが変わっています。適合方法を確認してください。'
}
foreach ($call in @($calls | Sort-Object { $_.CommandElements[0].Extent.EndOffset } -Descending)) {
    $source = $source.Insert($call.CommandElements[0].Extent.EndOffset, ' -SubscriptionId $subscriptionId')
}

# 生成したテストだけを一時保存して実行し、終了時にそのファイルを削除する。
$temporaryPath = Join-Path ([IO.Path]::GetTempPath()) ('clear-migration-smoke-' + [guid]::NewGuid().ToString('N') + '.ps1')
try {
    [IO.File]::WriteAllText($temporaryPath, $source, [Text.UTF8Encoding]::new($true))
    $arguments = @{ Repository = $Repository }
    if ($ReportPath) {
        $arguments.ReportPath = $ReportPath
    }
    & $temporaryPath @arguments
}
finally {
    if (Test-Path $temporaryPath) {
        Remove-Item $temporaryPath
    }
}
