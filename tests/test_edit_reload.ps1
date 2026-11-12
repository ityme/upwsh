# Focused same-shell reload regression; no installation, registry, or real editor writes.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ("upwsh edit user's " + [guid]::NewGuid().ToString('N'))
$source = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../src'))
$passed = 0
try {
    foreach ($mode in @('first-install-load', 'profile-startup')) {
        $userHome = Join-Path $root $mode
        $runtime = Join-Path $userHome '.config/upwsh'
        [IO.Directory]::CreateDirectory((Split-Path $runtime)) | Out-Null
        Copy-Item -LiteralPath $source -Destination $runtime -Recurse
        $bin = Join-Path $userHome 'editor stub'
        [IO.Directory]::CreateDirectory($bin) | Out-Null
        [IO.File]::WriteAllText((Join-Path $bin 'nvim.cmd'), "@echo off`r`nexit /b 0`r`n")
        [IO.File]::WriteAllText((Join-Path $runtime 'user-settings.ps1'), 'Set-Alias -Name edit_reload_marker -Value Get-Date -Scope Global -Force')
        $code = @'
$ErrorActionPreference = 'Stop'
$runtime = Join-Path $HOME '.config/upwsh'
if ($env:UPWSH_RELOAD_TEST_MODE -eq 'first-install-load') {
    # The exact post-deploy sequence used by the initial installer, in this shell.
    Import-Module (Join-Path $runtime 'lib/upwsh.psm1') -Global -Force -DisableNameChecking
    & (Join-Path $runtime 'script/upwsh.ps1') load
} else {
    . (Join-Path $runtime 'profile.ps1')
}
$Error.Clear()
foreach ($iteration in 1..3) {
    Remove-Alias edit_reload_marker -Scope Global -Force -ErrorAction Ignore
    upwsh edit
    if ($LASTEXITCODE -ne 0) { throw "edit failed on iteration $iteration" }
    if ((Get-Alias edit_reload_marker).Definition -ne 'Get-Date') { throw 'settings were not reloaded' }
    if ((Get-Command Complete-HookLine).CommandType -ne 'Function') { throw 'completion module missing after reload' }
    if ((Get-Command prompt).Definition -notmatch 'Get-UpwshThemeRevision') { throw 'prompt missing after reload' }
}
if ($Error.Count) { throw ($Error | Out-String) }
'@
        $result = Invoke-UpwshTestProcess -UserHome $userHome -WorkingDirectory $userHome -Command $code -Environment @{
            PATH = "$bin;$env:PATH"
            UPWSH_RELOAD_TEST_MODE = $mode
            UPWSH_SKIP_SESSION_LOAD = $null
            UPWSH_OSC = 'Off'
        }
        if ($result.Code -ne 0 -or $result.Text -match 'not recognized|Import-ShellModule:') {
            throw "$mode failed:`n$($result.Text)"
        }
        $passed++
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Output "$passed edit reload tests passed."
