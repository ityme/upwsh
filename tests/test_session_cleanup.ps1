# Focused current-shell teardown tests; no full install suite or real user changes.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ("upwsh cleanup user's " + [guid]::NewGuid().ToString('N'))
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$passed = 0
try {
    foreach ($mode in @('unload', 'uninstall', 'direct-uninstall', 'first-load-uninstall', 'custom-bindings')) {
        $userHome = Join-Path $root $mode
        $runtime = Join-Path $userHome '.config/upwsh'
        [IO.Directory]::CreateDirectory((Split-Path $runtime)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $runtime -Recurse
        [IO.File]::WriteAllText((Join-Path $runtime 'user-settings.ps1'), @'
$script:CommandMap['w'] = 'cd ~'
$script:CommandMap['t'] = 'cd ~'
$script:CommandMap['gs'] = 'git status'
$script:CommandMap['custom_shortcut'] = 'Get-Date'
Install-CommandMap
'@)
        $code = @'
$ErrorActionPreference = 'Stop'
Import-Module PSReadLine
if ($env:UPWSH_CLEANUP_TEST_MODE -eq 'custom-bindings') {
    Set-PSReadLineKeyHandler -Chord Tab -BriefDescription UserTab -ScriptBlock { }
    Set-PSReadLineKeyHandler -Chord Enter -BriefDescription UserEnter -ScriptBlock { }
}
$beforeCp = (Get-Alias cp).Definition
$beforePrompt = (Get-Command prompt).ScriptBlock
$beforeTab = (Get-PSReadLineKeyHandler -Chord Tab).Function
$beforeEnter = (Get-PSReadLineKeyHandler -Chord Enter).Function
$beforeQueryItems = (Get-PSReadLineOption).CompletionQueryItems
function global:w { 'original w' }
$originalW = (Get-Command w).ScriptBlock
$runtime = Join-Path $HOME '.config/upwsh'
if ($env:UPWSH_CLEANUP_TEST_MODE -eq 'first-load-uninstall') {
    Import-Module (Join-Path $runtime 'lib/upwsh.psm1') -Global -Force -DisableNameChecking
    & (Join-Path $runtime 'script/upwsh.ps1') load
} else { . (Join-Path $runtime 'profile.ps1') }
# Reload once: the original baseline must survive force-imports and profile edits.
. (Join-Path $runtime 'profile.ps1')
if ($env:UPWSH_CLEANUP_TEST_MODE -eq 'custom-bindings' -and
    ((Get-PSReadLineKeyHandler -Chord Tab).Function -ne 'UserTab' -or
     (Get-PSReadLineKeyHandler -Chord Enter).Function -ne 'UserEnter')) {
    throw 'pre-existing custom bindings were overwritten during load'
}
function global:gs { 'user override' }
$override = (Get-Command gs).ScriptBlock
Set-PSReadLineKeyHandler -Chord Ctrl+r -Function HistorySearchForward
if ($env:UPWSH_CLEANUP_TEST_MODE -eq 'unload') { upwsh unload }
elseif ($env:UPWSH_CLEANUP_TEST_MODE -eq 'direct-uninstall') { & (Join-Path $runtime 'script/uninstall.ps1') }
else { upwsh uninstall }
if (Get-Command t -CommandType Function,Alias -ErrorAction Ignore) { throw 't survived teardown' }
if (Get-Command custom_shortcut -CommandType Alias -ErrorAction Ignore) { throw 'personal alias survived teardown' }
if (-not [object]::ReferenceEquals((Get-Command w).ScriptBlock, $originalW)) { throw 'original w not restored' }
if (-not [object]::ReferenceEquals((Get-Command gs).ScriptBlock, $override)) { throw 'user override was removed' }
if ((Get-Command cp).CommandType -ne 'Alias' -or (Get-Alias cp).Definition -ne $beforeCp) { throw 'builtin cp alias not restored' }
if (-not [object]::ReferenceEquals((Get-Command prompt).ScriptBlock, $beforePrompt)) { throw 'original prompt not restored' }
if ((Get-PSReadLineKeyHandler -Chord Tab).Function -ne $beforeTab) { throw 'Tab not restored' }
if ((Get-PSReadLineKeyHandler -Chord Enter).Function -ne $beforeEnter) { throw 'Enter not restored' }
if ((Get-PSReadLineKeyHandler -Chord Ctrl+r).Function -ne 'HistorySearchForward') { throw 'user key override was removed' }
if ((Get-PSReadLineOption).CompletionQueryItems -ne $beforeQueryItems) { throw 'ReadLine option not restored' }
if ($env:UPWSH_CLEANUP_TEST_MODE -eq 'unload') {
    if (-not (Get-Command upwsh -CommandType Function -ErrorAction Ignore)) { throw 'unload removed load entry' }
    upwsh load
    upwsh unload
    if (Get-Command t -CommandType Function,Alias -ErrorAction Ignore) { throw 't survived second unload' }
} else {
    if (Get-Command upwsh -CommandType Function -ErrorAction Ignore) { throw 'upwsh survived uninstall' }
    if (Test-Path -LiteralPath (Join-Path $runtime 'profile.ps1')) { throw 'runtime was not uninstalled' }
}
'@
        $result = Invoke-UpwshTestProcess -UserHome $userHome -WorkingDirectory $userHome -Command $code -Environment @{
            UPWSH_CLEANUP_TEST_MODE = $mode
            UPWSH_SKIP_SESSION_LOAD = $null
            UPWSH_OSC = 'Off'
        }
        if ($result.Code -ne 0) { throw "$mode failed:`n$($result.Text)" }
        $passed++
    }
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "$passed session cleanup tests passed."
