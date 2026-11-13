# Presentation tests with stub lifecycle scripts: never installs or uninstalls a runtime.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ("upwsh output user's " + [guid]::NewGuid().ToString('N'))
$passed = 0
try {
    $fixture = Join-Path $root fixture
    [IO.Directory]::CreateDirectory((Join-Path $fixture script)) | Out-Null
    [IO.Directory]::CreateDirectory((Join-Path $fixture lib)) | Out-Null
    foreach ($name in @('upwsh_home.ps1', 'path_convert.ps1')) {
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot "../src/lib/$name") -Destination (Join-Path $fixture "lib/$name")
    }
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../src/script/upwsh.ps1') -Destination (Join-Path $fixture 'script/upwsh.ps1')
    $stub = @'
if ('--help' -in $args) { 'fixture help'; exit 0 }
if ($env:UPWSH_OUTPUT_TEST_FAIL -eq '1') { 'upwsh: fixture operation failed'; exit 7 }
'home      C:\fixture\home'
'source    I:\fixture\source'
'cmd       C:\fixture\upwsh.cmd'
Write-Host 'relaunch C:\temp\upwsh-run-fixture\install.ps1'
'command   upwsh'
'state     deployed'
if ($MyInvocation.MyCommand.Name -eq 'uninstall.ps1') { 'keep      C:\fixture\user-settings.ps1' }
'warn      fixture warning'; 'unexpected diagnostic'
exit 0
'@
    foreach ($name in @('install.ps1', 'update.ps1', 'uninstall.ps1')) {
        [IO.File]::WriteAllText((Join-Path $fixture "script/$name"), $stub)
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'script/install_profile.ps1'), "'profile   C:\fixture\profile.ps1'`n'state     installed'")
    foreach ($command in @('install', 'update', 'uninstall')) {
        $userHome = Join-Path $root $command
        $code = '& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + " $command"
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $code
        if ($result.Code -ne 0) { throw $result.Text }
        $verb = switch ($command) { install { 'installed' } update { 'updated' } uninstall { 'uninstalled' } }
        if ($result.Text -notmatch [regex]::Escape("✓ upwsh $verb")) { throw "missing success heading: $($result.Text)" }
        if ($result.Text -notmatch 'Home\s+' -or $result.Text -notmatch 'Profile\s+') { throw 'missing result details' }
        if ($result.Text -match 'relaunch|state\s+deployed|command\s+upwsh|\x1b\[') { throw "internal/ANSI output leaked: $($result.Text)" }
        if ($result.Text -notmatch 'fixture warning' -or $result.Text -notmatch 'unexpected diagnostic') { throw 'diagnostics were hidden' }
        $successIndex = $result.Text.IndexOf("✓ upwsh $verb")
        if ($successIndex -lt $result.Text.IndexOf('Home') -or $successIndex -lt $result.Text.IndexOf('unexpected diagnostic')) { throw 'success result must follow details and notices' }
        if ($command -eq 'install') {
            if ($result.Text -notmatch 'Run upwsh --help to get started\.') { throw 'installation missed help hint' }
        } elseif ($result.Text -match 'Run upwsh --help') { throw 'install help hint leaked to another action' }
        if ($command -eq 'uninstall') {
            if ($result.Text -notmatch 'Restart your shell to clear any remaining session state\.' -or
                $result.Text -notmatch 'Kept\s+C:\\fixture\\user-settings.ps1' -or $result.Text -match 'Ready in this shell') { throw $result.Text }
        } elseif ($result.Text -notmatch 'Source\s+I:\\fixture\\source' -or $result.Text -notmatch 'Open a new PowerShell window') { throw $result.Text }
        $passed++
    }
    $readyHome = Join-Path $root ready
    $readyRuntime = Join-Path $readyHome '.config/upwsh'
    [IO.Directory]::CreateDirectory($readyRuntime) | Out-Null
    [IO.File]::WriteAllText((Join-Path $readyRuntime 'profile.ps1'), '$global:OutputFixtureLoaded = $true')
    $readyCode = '& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install; if (-not $global:OutputFixtureLoaded) { exit 9 }; exit $LASTEXITCODE'
    $result = Invoke-UpwshTestProcess -UserHome $readyHome -Command $readyCode -Environment @{ UPWSH_SKIP_SESSION_LOAD = $null }
    if ($result.Code -ne 0 -or $result.Text -notmatch 'Ready in this shell\.' -or $result.Text -match 'relaunch') { throw "loaded result failed: $($result.Text)" }
    $passed++
    [IO.File]::WriteAllText((Join-Path $readyRuntime 'profile.ps1'), 'throw "fixture profile load failed"')
    $result = Invoke-UpwshTestProcess -UserHome $readyHome -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install; exit $LASTEXITCODE') -Environment @{ UPWSH_SKIP_SESSION_LOAD = $null }
    if ($result.Code -eq 0 -or $result.Text -notmatch 'fixture profile load failed' -or $result.Text -match '✓|Ready in this shell') { throw "reload failure misreported: $($result.Text)" }
    $passed++
    $result = Invoke-UpwshTestProcess -UserHome (Join-Path $root fileFailure) -File (Join-Path $fixture 'script/upwsh.ps1') -Arguments @('install') -Environment @{ UPWSH_OUTPUT_TEST_FAIL = '1' }
    if ($result.Code -ne 7 -or $result.Text -match '✓') { throw 'native -File failure exit changed' }
    $passed++
    $result = Invoke-UpwshTestProcess -UserHome (Join-Path $root failure) -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install; exit $LASTEXITCODE') -Environment @{ UPWSH_OUTPUT_TEST_FAIL = '1' }
    if ($result.Code -ne 7 -or $result.Text -notmatch 'fixture operation failed' -or $result.Text -match '✓') { throw "failed action misreported: $($result.Text)" }
    $passed++
    $result = Invoke-UpwshTestProcess -UserHome (Join-Path $root help) -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install --help')
    if ($result.Code -ne 0 -or $result.Text -notmatch 'fixture help' -or $result.Text -match '✓') { throw 'help was summarized as success' }
    $passed++
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "$passed setup output tests passed."
