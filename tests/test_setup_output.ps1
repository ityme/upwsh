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
'path      removed'
Write-Host 'relaunch C:\temp\upwsh-run-fixture\install.ps1'
'command   upwsh'
'state     deployed'
if ($MyInvocation.MyCommand.Name -eq 'uninstall.ps1') {
    if ($env:UPWSH_OUTPUT_KEEP_SETTINGS -ne '0') {
        $homePath = Join-Path $HOME '.config/upwsh'
        [IO.Directory]::CreateDirectory($homePath) | Out-Null
        [IO.File]::WriteAllText((Join-Path $homePath 'user-settings.ps1'), '# kept')
        'keep      ' + (Join-Path $homePath 'user-settings.ps1')
    } else {
        $homePath = Join-Path $HOME '.config/upwsh'
        $settings = Join-Path $homePath 'user-settings.ps1'
        if ([IO.File]::Exists($settings)) { [IO.File]::Delete($settings) }
        if ([IO.Directory]::Exists($homePath)) { [IO.Directory]::Delete($homePath) }
    }
}
'warn      fixture warning'; 'unexpected diagnostic'
exit 0
'@
    foreach ($name in @('install.ps1', 'update.ps1', 'uninstall.ps1')) {
        [IO.File]::WriteAllText((Join-Path $fixture "script/$name"), $stub)
    }
    [IO.File]::WriteAllText((Join-Path $fixture 'script/install_profile.ps1'), "'profile   C:\fixture\profile.ps1'`n'state     installed'")
    foreach ($command in @('install', 'update', 'uninstall')) {
        $userHome = Join-Path $root $command
        if ($command -eq 'uninstall') {
            [IO.Directory]::CreateDirectory($userHome) | Out-Null
            [IO.File]::WriteAllText((Join-Path $userHome 'test-profile.ps1'), '# >>> upwsh >>>')
        }
        $flags = if ($command -eq 'uninstall') { '' } else { ' --local' }
        $code = '& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + " $command$flags"
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $code
        if ($result.Code -ne 0) { throw $result.Text }
        $verb = switch ($command) { install { 'installed' } update { 'updated' } uninstall { 'uninstalled' } }
        if ($result.Text -notmatch [regex]::Escape("upwsh $verb ✓")) { throw "missing success heading: $($result.Text)" }
        if ($result.Text -notmatch 'Home\s+' -or $result.Text -notmatch 'Profile\s+') { throw 'missing result details' }
        if ($result.Text -match 'relaunch|state\s+deployed|command\s+upwsh|(?m)^path\s+removed|\x1b\[') { throw "internal/ANSI output leaked: $($result.Text)" }
        if ($result.Text -notmatch 'fixture warning' -or $result.Text -notmatch 'unexpected diagnostic') { throw 'diagnostics were hidden' }
        $successIndex = $result.Text.IndexOf("upwsh $verb ✓")
        if ($successIndex -lt $result.Text.IndexOf('Home') -or $successIndex -lt $result.Text.IndexOf('unexpected diagnostic')) { throw 'success result must follow details and notices' }
        if ($command -eq 'install') {
            if ($result.Text -notmatch 'Run upwsh --help to get started\.') { throw 'installation missed help hint' }
        } elseif ($result.Text -match 'Run upwsh --help') { throw 'install help hint leaked to another action' }
        if ($command -eq 'uninstall') {
            if ($result.Text -notmatch 'Restart your shell to finish cleanup\.' -or
                $result.Text -notmatch '(?m)^  Home\s+.+\s+runtime removed\r?$' -or
                $result.Text -notmatch '(?m)^  Profile\s+.+\s+unlinked\r?$' -or
                $result.Text -notmatch '(?m)^  Settings\s+.+\s+kept\r?$' -or $result.Text -match 'Ready in this shell') { throw $result.Text }
        } else {
            if ($result.Text -notmatch 'Source\s+I:\\fixture\\source' -or $result.Text -notmatch 'Open a new PowerShell window') { throw $result.Text }
            $settingsPath = Join-Path $userHome '.config/upwsh/user-settings.ps1'
            if ($result.Text -notmatch ('Settings\s+' + [regex]::Escape($settingsPath))) { throw 'missing personal settings path' }
            foreach ($label in @('Source','Home','Profile','Settings')) {
                if ($result.Text -notmatch ('(?m)^  ' + $label + '\s{' + (10 - $label.Length) + '}\S')) { throw "misaligned label $label" }
            }
        }
        $detailLines = @($result.Text -split '\r?\n' | Where-Object { $_ -match '^  (Source|Home|Profile|Settings)\s+' })
        $statusPositions = @($detailLines | ForEach-Object {
            if ($_ -notmatch '\s{2}(local|remote|installed|updated|linked|unlinked|not linked|runtime removed|removed|created|kept|absent)$') { throw "missing status column: $_" }
            $_.Length - $Matches[1].Length
        } | Select-Object -Unique)
        if ($statusPositions.Count -ne 1) { throw 'status column alignment differs between rows' }
        if ($command -ne 'uninstall' -and $result.Text -notmatch '(?m)^  Settings\s+.+\s+created\r?$') { throw 'fresh settings were not labeled created' }
        if ($result.Text -notmatch ('(?m)^  upwsh ' + $verb + ' ✓\r?$')) { throw 'success line indentation changed' }
        $passed++
    }
    $existingHome = Join-Path $root existing
    $existingRuntime = Join-Path $existingHome '.config/upwsh'
    [IO.Directory]::CreateDirectory($existingRuntime) | Out-Null
    [IO.File]::WriteAllText((Join-Path $existingRuntime 'user-settings.ps1'), '# user settings')
    $result = Invoke-UpwshTestProcess -UserHome $existingHome -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install --local')
    if ($result.Code -ne 0 -or $result.Text -notmatch '(?m)^  Settings\s+.+\s+kept\r?$') { throw 'existing settings were not labeled kept' }
    $passed++
    $result = Invoke-UpwshTestProcess -UserHome (Join-Path $root removed) -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' uninstall') -Environment @{ UPWSH_OUTPUT_KEEP_SETTINGS = '0' }
    if ($result.Code -ne 0 -or $result.Text -notmatch '(?m)^  Home\s+.+\s+removed\r?$' -or $result.Text -notmatch '(?m)^  Settings\s+.+\s+absent\r?$') { throw 'fully absent runtime status incorrect' }
    $passed++
    $deletedHome = Join-Path $root deleted
    $deletedRuntime = Join-Path $deletedHome '.config/upwsh'
    [IO.Directory]::CreateDirectory($deletedRuntime) | Out-Null
    [IO.File]::WriteAllText((Join-Path $deletedRuntime 'user-settings.ps1'), '# unchanged template')
    $result = Invoke-UpwshTestProcess -UserHome $deletedHome -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' uninstall') -Environment @{ UPWSH_OUTPUT_KEEP_SETTINGS = '0' }
    if ($result.Code -ne 0 -or $result.Text -notmatch '(?m)^  Home\s+.+\s+removed\r?$' -or $result.Text -notmatch '(?m)^  Settings\s+.+\s+removed\r?$') { throw 'deleted settings were not labeled removed' }
    $passed++
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
    # Verify the palette directly; subprocess captures above must remain ANSI-free.
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile((Join-Path $fixture 'script/upwsh.ps1'), [ref]$tokens, [ref]$errors)
    $formatter = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Write-UpwshSetupSummary' }, $true)
    Invoke-Expression $formatter.Extent.Text
    $rendering = $PSStyle.OutputRendering
    try {
        $PSStyle.OutputRendering = 'Ansi'
        $colored = @(Write-UpwshSetupSummary -Command install -SetupOutput @('source    I:\fixture\source') -Loaded:$true -HomePath 'C:\fixture\home' -HookPath 'C:\fixture\profile.ps1' -Color:$true -Before @{ SettingsExists = $true } -After @{})
        foreach ($label in @('Source','Home','Profile','Settings')) {
            $expected = '  ' + $PSStyle.Foreground.Green + ('{0,-8}' -f $label) + $PSStyle.Reset + '  '
            if (-not @($colored | Where-Object { $_.StartsWith($expected) }).Count) { throw "missing project green label: $label" }
        }
        if ('  ' + $PSStyle.Foreground.Green + 'upwsh installed ✓' + $PSStyle.Reset -cnotin $colored) { throw 'success line did not use project green' }
        $settingsLine = @($colored | Where-Object { $_ -match 'Settings' })[0]
        if (-not $settingsLine.EndsWith($PSStyle.Foreground.Yellow + 'kept' + $PSStyle.Reset)) { throw 'kept status did not use yellow' }
        if ('  Ready in this shell.' -cnotin $colored -or '  Run upwsh --help to get started.' -cnotin $colored) { throw 'footer was unexpectedly styled' }
        $passed++
    } finally { $PSStyle.OutputRendering = $rendering }
    $result = Invoke-UpwshTestProcess -UserHome (Join-Path $root help) -Command ('& ' + (ConvertTo-TestLiteral (Join-Path $fixture 'script/upwsh.ps1')) + ' install --help')
    if ($result.Code -ne 0 -or $result.Text -notmatch 'fixture help' -or $result.Text -match '✓') { throw 'help was summarized as success' }
    $passed++
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "$passed setup output tests passed."
