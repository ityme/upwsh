# Focused tool output checks with a fake download; no network or user installation.
$ErrorActionPreference = 'Stop'
$entry = Join-Path $PSScriptRoot '../src/script/install_cli_tool.ps1'
$t = $null; $e = $null
$ast = [Management.Automation.Language.Parser]::ParseFile($entry, [ref]$t, [ref]$e)
foreach ($name in @('Write-CliToolRow','Install-CliTool')) {
    $fn = $ast.Find({ param($n) $n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $name }, $true)
    Invoke-Expression $fn.Extent.Text
}
function Test-UpwshStatusColor { $false }
function Get-GitHubLatestRelease { param($Repo) @{tag_name='v1.2.3'} }
function Get-ReleaseAsset { param($Release,$Exe) @{name='fixture-windows.exe';browser_download_url='https://example.invalid/fixture.exe'} }
function Invoke-WebRequest {
    param($Uri,$OutFile,[switch]$UseBasicParsing)
    if ($script:FailDownload) { throw 'fixture download failed' }
    [IO.File]::WriteAllText($OutFile,'fixture executable')
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-tool-output-' + [guid]::NewGuid().ToString('N'))
$tool = @{Name='fixture';Repo='example/fixture';Exe='fixture.exe'}
try {
    $text = @(Install-CliTool -Tool $tool -Destination $root)
    if ($text.Count -ne 1 -or $text[0] -notmatch '^  fixture\s+v1.2.3\s+installed\s+' -or
        $text[0] -notmatch [regex]::Escape((Join-Path $root 'fixture.exe'))) { throw "unexpected result: $text" }
    if ($text[0] -match '\x1b\[|downloading|fixture-windows') { throw 'process details leaked into final row' }
    $text = @(Install-CliTool -Tool $tool -Destination $root)
    if ($text.Count -ne 1 -or $text[0] -notmatch '^  fixture\s+-\s+installed\s+') { throw 'existing tool was not shown as installed' }
    $script:FailDownload = $true
    $failed = $false
    try { Install-CliTool -Tool $tool -Destination $root -Force } catch { $failed = $_.Exception.Message -eq 'fixture download failed' }
    if (-not $failed) { throw 'download failure hidden' }
    $row = Write-CliToolRow -Name fixture -Status uninstalled
    if ($row -notmatch '^  fixture\s+-\s+uninstalled\s+-') { throw 'uninstalled status incorrect' }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output '4 tool install output tests passed.'
