# 卸掉 upwsh：unload，再删 UPWSH_HOME、Path 和安装目录。
#   irm https://github.com/ityme/upwsh/raw/main/src/script/uninstall.ps1 | iex
#   pwsh -NoLogo -NoProfile -File src/script/uninstall.ps1

$script:SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$script:Arguments = @($args)
$script:BeginMarker = '# >>> upwsh >>>'
$script:EndMarker = '# <<< upwsh <<<'

function Get-UninstallUsage {
    @'
usage: uninstall.ps1 [-h | --help] [-c | --check]
                     [-p | --profile <path>] [--current-host]

These are common uninstall.ps1 commands used in various situations:

remove this runtime
   --profile        pwsh profile to edit, default CurrentUserAllHosts
   --current-host   Write $PROFILE.CurrentUserCurrentHost

inspect without writing
   --check          Show what would be removed

A network uninstall can run:

  irm https://github.com/ityme/upwsh/raw/main/src/script/uninstall.ps1 | iex

Unload first, then drop UPWSH_HOME and managed Path entries, then delete ~/.config/upwsh.
A changed user-settings.ps1 is kept; an unchanged template is deleted with the runtime. Themes are not kept.
'@
}

function New-UninstallParseResult {
    [pscustomobject]@{
        Help        = $false
        Error       = $null
        Check       = $false
        CurrentHost = $false
        Profile     = $null
    }
}

function ConvertFrom-UninstallArguments {
    param([object[]]$Tokens)

    $tokens = @(
        $Tokens |
            Where-Object { $_ -ne $null -and [string]$_ -ne '' }
    )
    $result = New-UninstallParseResult
    $index = 0

    while ($index -lt $tokens.Count) {
        $token = [string]$tokens[$index]
        switch -Regex ($token) {
            '^(--help|-h)$' {
                $result.Help = $true
                return $result
            }
            '^(--check|-c)$' {
                $result.Check = $true
                $index++
            }
            '^--current-host$' {
                $result.CurrentHost = $true
                $index++
            }
            '^(--profile|-p)$' {
                if ($index + 1 -ge $tokens.Count) {
                    $result.Help = $true
                    $result.Error = 'missing profile path'
                    return $result
                }
                $result.Profile = [string]$tokens[$index + 1]
                $index += 2
            }
            default {
                $result.Help = $true
                $result.Error = "unknown option: $token"
                return $result
            }
        }
    }

    return $result
}

# BEGIN GENERATED PATH CONVERTERS (src/lib/path_convert.ps1)
# Shared path conversion interfaces. No filesystem access or shell initialization.
function winpath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [AllowEmptyString()][string[]]$Path
    )
    process {
        foreach ($item in $Path) {
            if ($item -match '^~(?:[/\\]|$)') {
                $HOME.TrimEnd('\', '/').Replace('\', '/') + $item.Substring(1).Replace('\', '/')
            } elseif ($item -match '^/([A-Za-z]):(?=[/\\]|$)') {
                $Matches[1].ToUpperInvariant() + ':' + $item.Substring(3)
            } elseif ($item -match '^/([A-Za-z])(?:/|$)') {
                # C: is drive-relative; /c must become the drive root C:/.
                $Matches[1].ToUpperInvariant() + ':/' + $item.Substring([Math]::Min(3, $item.Length))
            } else {
                $item
            }
        }
    }
}

function unixpath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, Position = 0, ValueFromPipeline, ValueFromRemainingArguments)]
        [AllowEmptyString()][string[]]$Path
    )
    process {
        foreach ($item in $Path) {
            $unix = [regex]::Replace(
                $item,
                '^/?([A-Za-z]):[\\/]+',
                { param($match) '/' + $match.Groups[1].Value.ToLowerInvariant() + '/' }
            )
            $unix.Replace('\', '/')
        }
    }
}
# END GENERATED PATH CONVERTERS

if (-not (Get-Command Write-UpwshStatus -ErrorAction SilentlyContinue)) {
    function Test-UpwshStatusColor {
        if ($env:NO_COLOR -or $env:UPWSH_TEST_ISOLATED) { return $false }
        if ($null -eq $PSStyle -or $PSStyle.OutputRendering -eq 'PlainText') { return $false }
        try { if ([Console]::IsOutputRedirected) { return $false } } catch { return $false }
        return [bool]$Host.UI.SupportsVirtualTerminal
    }
    function Get-UpwshStatusValueColor {
        param([string]$Key, [string]$Value)
        switch -Regex ($Key) {
            '^(ok|command|theme)$' { return $PSStyle.Foreground.Green }
            '^(warn|missing|skip)$' { return $PSStyle.Foreground.Yellow }
            '^(next|get)$' { return $PSStyle.Foreground.Cyan }
        }
        $token = ($Value -split '\s+', 2)[0]
        switch -Regex ($token) {
            '^(installed|deployed|present|keep|kept)$' { return $PSStyle.Foreground.Green }
            '^(missing|removed)$' { return $PSStyle.Foreground.Yellow }
            default { return '' }
        }
    }
    function Write-UpwshStatus {
        param(
            [Parameter(ValueFromRemainingArguments)]
            [object[]]$Pairs
        )
        if ($null -eq $Pairs -or $Pairs.Count -eq 0) { return }
        if ($Pairs.Count % 2 -ne 0) { throw 'Write-UpwshStatus requires key/value pairs' }
        $color = Test-UpwshStatusColor
        for ($index = 0; $index -lt $Pairs.Count; $index += 2) {
            $key = [string]$Pairs[$index]
            $value = [string]$Pairs[$index + 1]
            $label = '{0,-8}' -f $key
            if ($color) {
                $label = "$($PSStyle.Foreground.Cyan)$label$($PSStyle.Reset)"
                $valueColor = Get-UpwshStatusValueColor -Key $key -Value $value
                if ($valueColor) { $value = "$valueColor$value$($PSStyle.Reset)" }
            }
            Write-Output ("$label  $value")
        }
    }
}

function Get-UninstallHome {
    [IO.Path]::GetFullPath((Join-Path $HOME '.config\upwsh'))
}

function Get-UpwshUserSettingsTemplate {
    @'
# Personal shell settings. profile.ps1 dotsources this last.
# Open with: upwsh edit (reloads this pwsh when the editor exits)
# upwsh update leaves an existing copy in place. Uninstall keeps a changed copy and deletes an unchanged template with the runtime.
#
# Examples (uncomment and edit):
# $script:CommandMap['w'] = 'cd /i/workspace'
# $script:CommandMap['t'] = 'cd /i/tmp'
# $script:CommandMap['i'] = 'cd /i/ispace'
# $script:CommandMap['d'] = 'cd ~/Desktop'
# $script:CommandMap['gs'] = 'git status'
# Install-CommandMap
'@
}

function Get-UpwshNormalizedText {
    param([string]$Text)
    if ($null -eq $Text) { return '' }
    if ($Text.Length -gt 0 -and [int][char]$Text[0] -eq 0xFEFF) {
        $Text = $Text.Substring(1)
    }
    $Text.Replace("`r`n", "`n").Replace("`r", "`n").Trim()
}

function Test-UpwshChangedUserSettings {
    param([string]$Path)
    if (-not [IO.File]::Exists($Path)) { return $false }
    $actual = Get-UpwshNormalizedText ([IO.File]::ReadAllText($Path))
    $template = Get-UpwshNormalizedText (Get-UpwshUserSettingsTemplate)
    return $actual -cne $template
}

# The piped uninstaller must also work when the runtime files are already gone.
function Remove-UninstallEnvironment {
    param([string]$InstallHome)

    $managed = @(
        '%UPWSH_HOME%\bin'
        '%UPWSH_HOME%\tool\bin'
        (Join-Path $InstallHome 'bin')
        (Join-Path $InstallHome 'tool\bin')
    )
    $filterPath = {
        param([string]$Value)
        @($Value -split ';' | Where-Object {
            $entry = $_.Trim().TrimEnd('\', '/').Replace('/', '\')
            $entry -and $entry -notin $managed
        }) -join ';'
    }
    $env:PATH = & $filterPath $env:PATH
    Remove-Item Env:\UPWSH_HOME -ErrorAction SilentlyContinue
    if (-not $env:UPWSH_SKIP_PERSIST_PATH) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment', $true)
        if ($key) {
            try {
                $raw = $key.GetValue('Path', $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
                if ($null -ne $raw) {
                    $key.SetValue('Path', (& $filterPath $raw), [Microsoft.Win32.RegistryValueKind]::ExpandString)
                }
                $key.DeleteValue('UPWSH_HOME', $false)
            } finally {
                $key.Close()
            }
        }
    }
    Write-UpwshStatus home removed path removed
}

function Get-UninstallHookPath {
    param($Parsed)

    if ($Parsed.Profile) {
        return [IO.Path]::GetFullPath(
            (winpath $Parsed.Profile)
        )
    }
    if ($Parsed.CurrentHost) {
        return $PROFILE.CurrentUserCurrentHost
    }
    if (-not [string]::IsNullOrWhiteSpace($env:UPWSH_PROFILE)) {
        return [IO.Path]::GetFullPath(
            (winpath $env:UPWSH_PROFILE)
        )
    }
    $PROFILE.CurrentUserAllHosts
}

function Test-GitCheckout {
    param([string]$Path)

    if (Test-Path -LiteralPath (Join-Path $Path '.git')) {
        return $true
    }
    $leaf = Split-Path -Leaf $Path
    $parent = Split-Path -Parent $Path
    if ($leaf -eq 'src' -and $parent -and (Test-Path -LiteralPath (Join-Path $parent '.git'))) {
        return $true
    }
    return $false
}

function Test-ProfileHook {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return $false
    }
    $text = [IO.File]::ReadAllText($Path)
    $text.Contains($script:BeginMarker)
}

function Remove-ProfileHookFallback {
    param([string]$Path)

    if (-not (Test-ProfileHook $Path)) {
        return
    }
    $pattern = '(?ms)^' + [regex]::Escape($script:BeginMarker) +
        '\r?\n.*?' + [regex]::Escape($script:EndMarker) +
        '(?:\r?\n)?'
    $text = [IO.File]::ReadAllText($Path)
    $removed = [regex]::Replace($text, $pattern, '')
    $removed = $removed.TrimEnd() + $(if ($removed.Trim()) { "`r`n" } else { '' })
    [IO.File]::WriteAllText($Path, $removed)
    Write-UpwshStatus profile $Path state removed
}

function Complete-Uninstall {
    param(
        [int]$Code,
        $Invocation = $MyInvocation
    )

    $ErrorActionPreference = $script:SavedErrorActionPreference
    $global:LASTEXITCODE = $Code
    if ($PSCommandPath -and $Invocation.CommandOrigin -eq 'Runspace') {
        exit $Code
    }
}

$parsed = ConvertFrom-UninstallArguments -Tokens $script:Arguments
$scriptInvocation = $MyInvocation
if ($parsed.Help) {
    if ($parsed.Error) {
        Write-Output "upwsh: $($parsed.Error)"
        Write-Output ''
    }
    Get-UninstallUsage
    if ($parsed.Error) {
        Complete-Uninstall 2 $scriptInvocation
        return
    }
    Complete-Uninstall 0 $scriptInvocation
    return
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output 'upwsh: need PowerShell 7'
    Complete-Uninstall 1 $scriptInvocation
    return
}

$directory = Get-UninstallHome
$hookPath = Get-UninstallHookPath -Parsed $parsed
$keepTree = Test-GitCheckout $directory
if ($PSScriptRoot) {
    $relaunch = Join-Path $PSScriptRoot '_relaunch.ps1'
    if (Test-Path -LiteralPath $relaunch -PathType Leaf) {
        . $relaunch
    }
}
if (Get-Command Wait-UpwshRelaunchParent -ErrorAction SilentlyContinue) {
    Wait-UpwshRelaunchParent
}

if (
    -not $parsed.Check -and
    (Get-Command Start-UpwshRelaunchIfNeeded -ErrorAction SilentlyContinue)
) {
    if (
        Start-UpwshRelaunchIfNeeded `
            -InstallHome $directory `
            -EntryName 'uninstall.ps1' `
            -Arguments $script:Arguments
    ) {
        Complete-Uninstall 0 $scriptInvocation
        return
    }
}

if (
    -not $parsed.Check -and
    $PSCommandPath -and
    -not $env:UPWSH_UNINSTALL_REEXEC -and
    -not $env:UPWSH_SKIP_RELAUNCH -and
    (Get-Command Test-UpwshPathUnder -ErrorAction SilentlyContinue) -and
    (Test-UpwshPathUnder -Path $PSCommandPath -Root $directory)
) {
    $temp = Join-Path ([IO.Path]::GetTempPath()) (
        'upwsh-uninstall-' + [Guid]::NewGuid().ToString('N') + '.ps1'
    )
    Copy-Item -LiteralPath $PSCommandPath -Destination $temp -Force
    $savedReexec = $env:UPWSH_UNINSTALL_REEXEC
    try {
        $env:UPWSH_UNINSTALL_REEXEC = '1'
        & $temp @script:Arguments
        Complete-Uninstall $global:LASTEXITCODE $scriptInvocation
        return
    } finally {
        $env:UPWSH_UNINSTALL_REEXEC = $savedReexec
        Remove-Item -LiteralPath $temp -Force -ErrorAction SilentlyContinue
    }
}

Write-UpwshStatus home $directory profile $hookPath
if ($parsed.Check) {
    $state = if (Test-ProfileHook $hookPath) { 'installed' } else { 'missing' }
    $treeState = if (Test-Path -LiteralPath $directory) { 'present' } else { 'missing' }
    if ($keepTree -and $treeState -eq 'present') {
        $treeState = 'kept'
    }
    Write-UpwshStatus hook $state tree $treeState
    if (Test-UpwshChangedUserSettings (Join-Path $directory 'user-settings.ps1')) {
        Write-UpwshStatus keep (Join-Path $directory 'user-settings.ps1')
    }
    Complete-Uninstall 0 $scriptInvocation
    return
}

$savedProfile = $env:UPWSH_PROFILE
try {
    $env:UPWSH_PROFILE = $hookPath
    $env:UPWSH_HOME = $directory
    $loader = Join-Path $directory 'script\upwsh.ps1'
    if ([IO.File]::Exists($loader)) {
        & $loader unload
    } else {
        Remove-ProfileHookFallback -Path $hookPath
    }
    Remove-UninstallEnvironment -InstallHome $directory
} finally {
    $env:UPWSH_PROFILE = $savedProfile
}

if (Test-ProfileHook $hookPath) {
    Remove-ProfileHookFallback -Path $hookPath
}

if (-not $env:UPWSH_SKIP_SESSION_LOAD) {
    Remove-Item Function:global:PSConsoleHostReadLine -ErrorAction SilentlyContinue
    Remove-Item Function:global:upwsh -ErrorAction SilentlyContinue
    function global:prompt {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
}

if ($keepTree) {
    Write-UpwshStatus tree "kept  $directory"
} elseif (Test-Path -LiteralPath $directory) {
    $settings = Join-Path $directory 'user-settings.ps1'
    $keepSettings = Test-UpwshChangedUserSettings $settings
    $savedSettings = $null
    if ($keepSettings) {
        $savedSettings = Join-Path ([IO.Path]::GetTempPath()) (
            'upwsh-user-settings-' + [Guid]::NewGuid().ToString('N') + '.ps1'
        )
        Copy-Item -LiteralPath $settings -Destination $savedSettings -Force
    }
    if (Get-Command Remove-UpwshTree -ErrorAction SilentlyContinue) {
        Remove-UpwshTree -Path $directory
    } else {
        Remove-Item -LiteralPath $directory -Recurse -Force
    }
    if ($savedSettings) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Move-Item -LiteralPath $savedSettings -Destination $settings
        Write-UpwshStatus tree "removed  $directory"
        Write-UpwshStatus keep $settings
    } else {
        Write-UpwshStatus tree "removed  $directory"
    }
}

Complete-Uninstall 0 $scriptInvocation
