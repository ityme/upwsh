# upwsh：统一入口。load / unload 挂钩 profile；install / uninstall / update 管安装树。
#   upwsh --help
#   upwsh load
#   upwsh unload
#   upwsh install
#   upwsh uninstall
#   upwsh update
#   upwsh tool list
#   upwsh tool install eza rg
#   upwsh tool install --all
#   upwsh tool update eza
#   upwsh tool update --all
#   upwsh tool uninstall eza
#   upwsh theme list
#   upwsh theme use pure-classic
#   upwsh edit

$ErrorActionPreference = 'Stop'
$script:Arguments = @($args)
. (Join-Path $PSScriptRoot '..\lib\upwsh_home.ps1')

function Get-UpwshUsage {
    @'
usage: upwsh [-h | --help] <command> [<args>]

These are common upwsh commands used in various situations:

install and manage unixify-powershell
   install          Install or repair the runtime, then load this pwsh
   update           Update the runtime, then load this pwsh
   uninstall        Unload and remove the runtime; keep changed user settings

maintenance
   load             Enable startup loading and load this pwsh
   unload           Disable startup loading and unload this pwsh

manage optional command-line tools
   tool list        List supported tools and whether they are available
   tool install     Download named tools; --all installs all supported tools
   tool update      Update named tools; --all updates installed tools
   tool uninstall   Remove named tools

select a prompt theme
   theme list       List installed themes; * marks the active theme
   theme use        Select a theme and refresh the prompt

edit personal settings
   edit             Open user-settings.ps1, then reload this pwsh

'upwsh --help' prints this overview.

Listed tools: bat btm delta dust eza fd fzf hyperfine jq lazygit procs
rg shfmt starship tssh yazi yq zoxide
'@
}

function New-UpwshParseResult {
    param(
        [string]$Command = '',
        [switch]$Help,
        [string]$Error
    )

    [pscustomobject]@{
        Help    = [bool]$Help
        Error   = $Error
        Command = $Command
        Action  = ''
        Only    = @()
        Rest    = @()
        All     = $false
    }
}

function ConvertFrom-UpwshArguments {
    param([object[]]$Tokens)

    $tokens = @(
        $Tokens |
            Where-Object { $_ -ne $null -and [string]$_ -ne '' }
    )
    $result = New-UpwshParseResult
    $index = 0

    if ($tokens.Count -eq 0) {
        $result.Help = $true
        return $result
    }

    $first = [string]$tokens[0]
    switch -Regex ($first) {
        '^(--help|-h)$' {
            $result.Help = $true
            return $result
        }
        '^load$' {
            $result.Command = 'load'
            $index = 1
        }
        '^unload$' {
            $result.Command = 'unload'
            $index = 1
        }
        '^tool$' {
            $result.Command = 'tool'
            $index = 1
        }
        '^theme$' {
            $result.Command = 'theme'
            $index = 1
        }
        '^install$' {
            $result.Command = 'install'
            $index = 1
        }
        '^uninstall$' {
            $result.Command = 'uninstall'
            $index = 1
        }
        '^update$' {
            $result.Command = 'update'
            $index = 1
        }
        '^edit$' {
            $result.Command = 'edit'
            $index = 1
        }
        default {
            $result.Help = $true
            $result.Error = "unknown option: $first"
            return $result
        }
    }

    if ($result.Command -eq 'theme') {
        $rest = @($tokens | Select-Object -Skip 1)
        if ($rest.Count -eq 1 -and $rest[0] -in @('-h', '--help')) {
            $result.Help = $true
        } elseif ($rest.Count -eq 1 -and $rest[0] -eq 'list') {
            $result.Action = 'list'
        } elseif ($rest.Count -eq 2 -and $rest[0] -in @('use', 'install') -and -not $rest[1].StartsWith('-')) {
            $result.Action = 'use'
            $result.Only = @([string]$rest[1])
        } else {
            $result.Help = $true
            $result.Error = 'usage: upwsh theme list | upwsh theme use <name>'
        }
        return $result
    }

    if ($result.Command -eq 'tool') {
        if ($index -ge $tokens.Count) {
            $result.Help = $true
            $result.Error = 'missing tool command'
            return $result
        }
        $action = [string]$tokens[$index]
        switch -Regex ($action) {
            '^(--help|-h)$' {
                $result.Help = $true
                return $result
            }
            '^(--install|-i|install)$' {
                $result.Action = 'install'
            }
            '^(--uninstall|-u|uninstall)$' {
                $result.Action = 'uninstall'
            }
            '^(--list|list)$' {
                $result.Action = 'list'
            }
            '^(--update|update)$' {
                $result.Action = 'update'
            }
            default {
                $result.Help = $true
                $result.Error = "unknown tool command: $action"
                return $result
            }
        }
        $index++
    }

    if ($result.Command -in @('install', 'uninstall', 'update')) {
        $allowed = @('--help', '-h', '--check', '-c', '--local', '--remote', '--ref', '--repo', '--source')
        if ($result.Command -eq 'uninstall') { $allowed = @('--help', '-h', '--check', '-c', '--profile', '-p', '--current-host') }
        if ($result.Command -eq 'update') { $allowed = @('--help', '-h', '--check', '-c', '--local', '--remote', '--ref', '--repo', '--source') }
        while ($index -lt $tokens.Count) {
            $token = [string]$tokens[$index]
            if ($token -notin $allowed) {
                $result.Help = $true
                $result.Error = "unknown option: $token"
                return $result
            }
            $result.Rest = @($result.Rest + $token)
            if ($token -in @('--profile', '-p', '--ref', '--repo', '--source')) {
                if ($index + 1 -ge $tokens.Count) {
                    $result.Help = $true
                    $result.Error = "missing value for $token"
                    return $result
                }
                $result.Rest = @($result.Rest + [string]$tokens[$index + 1])
                $index += 2
            } else { $index++ }
        }
        return $result
    }

    while ($index -lt $tokens.Count) {
        $token = [string]$tokens[$index]
        switch -Regex ($token) {
            '^(--help|-h)$' {
                $result.Help = $true
                return $result
            }
            '^--all$' {
                if ($result.Command -ne 'tool') {
                    $result.Help = $true
                    $result.Error = "unknown option: $token"
                    return $result
                }
                $result.All = $true
                $index++
            }
            '^(load|unload|tool|theme|install|uninstall|update|edit)$' {
                $result.Help = $true
                $result.Error = 'use only one of load, unload, tool, theme, install, uninstall, update, or edit'
                return $result
            }
            default {
                if ($result.Command -eq 'tool' -and -not $token.StartsWith('-')) {
                    $result.Only = @($result.Only + $token)
                    $index++
                } else {
                    $result.Help = $true
                    $result.Error = "unknown option: $token"
                    return $result
                }
            }
        }
    }

    if ($result.Command -eq 'tool' -and $result.All -and $result.Action -eq 'list') {
        $result.Help = $true
        $result.Error = 'usage: upwsh tool list'
        return $result
    }
    if ($result.Command -eq 'tool' -and $result.All -and $result.Action -eq 'uninstall') {
        $result.Help = $true
        $result.Error = 'usage: upwsh tool uninstall <name>...'
        return $result
    }
    if ($result.Command -eq 'tool' -and $result.All -and $result.Only.Count -gt 0) {
        $result.Help = $true
        $result.Error = 'use names or --all'
        return $result
    }
    if ($result.Command -eq 'tool' -and $result.Action -in @('install', 'update') -and -not $result.All -and $result.Only.Count -eq 0) {
        $result.Help = $true
        $result.Error = 'usage: upwsh tool ' + $result.Action + ' <name>... | upwsh tool ' + $result.Action + ' --all'
        return $result
    }
    if ($result.Command -eq 'tool' -and $result.Action -eq 'uninstall' -and $result.Only.Count -eq 0) {
        $result.Help = $true
        $result.Error = 'usage: upwsh tool uninstall <name>...'
        return $result
    }

    return $result
}

function Restore-UpwshDefaultPrompt {
    Remove-Item Function:global:PSConsoleHostReadLine -ErrorAction SilentlyContinue
    function global:prompt {
        "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
    }
}

function Invoke-UpwshLoad {
    param($Parsed)

    $installer = Join-Path $PSScriptRoot 'install_profile.ps1'
    $installerArgs = @{}
    if ($Parsed.Command -eq 'unload') {
        $installerArgs.Uninstall = $true
    }
    & $installer @installerArgs
    if ($env:UPWSH_SKIP_SESSION_LOAD) {
        return
    }
    if ($Parsed.Command -eq 'unload') {
        Restore-UpwshDefaultPrompt
    }
}

function Get-UpwshSessionProfilePath {
    if ($env:UPWSH_SKIP_SESSION_LOAD) {
        return
    }
    $runtimeProfile = Join-Path (Get-UpwshHome) 'profile.ps1'
    if (Test-Path -LiteralPath $runtimeProfile -PathType Leaf) {
        return $runtimeProfile
    }
}

function Invoke-UpwshSessionProfile {
    $sessionProfile = Get-UpwshSessionProfilePath
    if ($sessionProfile) {
        & $sessionProfile
    }
}

function Invoke-UpwshTool {
    param($Parsed)

    $installer = Join-Path $PSScriptRoot 'install_cli_tool.ps1'
    $installerArgs = @{}
    if ($Parsed.Only.Count -gt 0) {
        $installerArgs.Only = @($Parsed.Only)
    }
    switch ($Parsed.Action) {
        'list' {
            $installerArgs.List = $true
        }
        'uninstall' {
            $installerArgs.Uninstall = $true
        }
        'update' {
            $installerArgs.Update = $true
            if ($Parsed.All) {
                $installerArgs.InstalledOnly = $true
            }
        }
        'install' {
            if ($Parsed.All) {
                $installerArgs.Only = @()
            }
        }
    }
    & $installer @installerArgs
}

function Invoke-UpwshTheme {
    param($Parsed)

    $themePath = Join-Path (Get-UpwshHome) 'lib\theme.psm1'
    if (-not [IO.File]::Exists($themePath)) { throw 'themes are not installed; run upwsh install first' }
    $module = Import-Module $themePath -Global -PassThru -ErrorAction Stop
    if ($Parsed.Action -eq 'list') {
        foreach ($theme in @(& $module { Get-UpwshThemeList })) {
            $mark = if ($theme.Active) { '*' } else { ' ' }
            Write-Output "$mark $($theme.Name)"
        }
    } else {
        $selected = & $module { param($name) Set-UpwshTheme $name } $Parsed.Only[0]
        Write-UpwshStatus theme $selected
    }
}

function Get-UpwshSettingsEditor {
    foreach ($name in @('nvim', 'vim')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) {
            return $command.Source
        }
    }
}

function Invoke-UpwshEdit {
    $settings = Join-Path (Get-UpwshHome) 'user-settings.ps1'
    if (-not [IO.File]::Exists($settings)) {
        throw 'user-settings.ps1 is not installed; run upwsh install first'
    }
    $editor = Get-UpwshSettingsEditor
    if (-not $editor) {
        throw 'nvim is not on PATH; install Neovim to edit user-settings.ps1'
    }
    Write-UpwshStatus file $settings editor ([IO.Path]::GetFileNameWithoutExtension($editor))
    & $editor $settings
    if ($null -ne $LASTEXITCODE) {
        $global:LASTEXITCODE = $LASTEXITCODE
    }
}

function Invoke-UpwshSetup {
    param($Parsed)

    $script = Join-Path $PSScriptRoot "$($Parsed.Command).ps1"
    if (-not (Test-Path -LiteralPath $script -PathType Leaf)) {
        throw "missing $($Parsed.Command) script: $script"
    }
    $setupArgs = @($Parsed.Rest)
    if ($Parsed.Command -in @('install', 'update')) {
        $setupArgs += '--skip-load'
    }
    & $script @setupArgs
}

function Complete-Upwsh {
    param(
        [int]$Code,
        $Invocation = $MyInvocation
    )

    $global:LASTEXITCODE = $Code
    if ($PSCommandPath -and $Invocation.CommandOrigin -eq 'Runspace') {
        exit $Code
    }
}

$parsed = ConvertFrom-UpwshArguments -Tokens $script:Arguments
$scriptInvocation = $MyInvocation
if ($parsed.Help -or -not $parsed.Command) {
    if ($parsed.Error) {
        Write-Output "upwsh: $($parsed.Error)"
        Complete-Upwsh 2 $scriptInvocation
        return
    }
    Get-UpwshUsage
    Complete-Upwsh 0 $scriptInvocation
    return
}

if ($parsed.Command -eq 'theme') {
    try {
        Invoke-UpwshTheme -Parsed $parsed
    } catch {
        Write-Output "upwsh: $($_.Exception.Message)"
        Complete-Upwsh 1 $scriptInvocation
        return
    }
    Complete-Upwsh 0 $scriptInvocation
    return
}

if ($parsed.Command -in @('load', 'unload')) {
    Invoke-UpwshLoad -Parsed $parsed
    Complete-Upwsh 0 $scriptInvocation
    if ($parsed.Command -eq 'load') {
        Invoke-UpwshSessionProfile
    }
    return
}

if ($parsed.Command -in @('install', 'uninstall', 'update')) {
    Invoke-UpwshSetup -Parsed $parsed
    $setupCode = $global:LASTEXITCODE
    if ($parsed.Command -in @('install', 'update') -and $setupCode -eq 0) {
        Invoke-UpwshLoad -Parsed ([pscustomobject]@{ Command = 'load' })
        Invoke-UpwshSessionProfile
    }
    Complete-Upwsh $setupCode $scriptInvocation
    return
}

if ($parsed.Command -eq 'edit') {
    $sessionProfile = $null
    try {
        Invoke-UpwshEdit
        $sessionProfile = Get-UpwshSessionProfilePath
        if ($sessionProfile) {
            Write-UpwshStatus state loaded
        }
    } catch {
        Write-Output "upwsh: $($_.Exception.Message)"
        Complete-Upwsh 1 $scriptInvocation
        return
    }
    Complete-Upwsh 0 $scriptInvocation
    if ($sessionProfile) {
        & $sessionProfile
    }
    return
}

Invoke-UpwshTool -Parsed $parsed
Complete-Upwsh $global:LASTEXITCODE $scriptInvocation
