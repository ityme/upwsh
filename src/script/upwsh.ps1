# upwsh：统一入口。load / unload 挂钩 profile；install / uninstall / update 管安装树。
#   upwsh --help
#   upwsh load
#   upwsh unload
#   upwsh install
#   upwsh uninstall
#   upwsh update
#   upwsh tool list
#   upwsh tool install eza ripgrep
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

install and manage upwsh
   install          Install or repair the runtime, then load this pwsh
                    [--local | --remote | --source <dir>]
                    [--ref <ref>] [--repo <owner/name>]
   update           Update the runtime, then load this pwsh
                    [--local | --remote | --source <dir>]
                    [--ref <ref>] [--repo <owner/name>]
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

examples:
   upwsh install                     Install the latest release from GitHub
   upwsh install --local             Install from the project in the current directory
   upwsh install --remote --ref dev  Install a development branch
   upwsh update                      Update to the latest release
   upwsh uninstall                   Remove upwsh from this machine
   upwsh tool list                   Show which tools are installed
   upwsh tool install --all          Install every supported tool
   upwsh theme list                  List themes; * marks the active one
   upwsh theme use colorful-blue     Switch the prompt theme
   upwsh edit                        Edit personal settings

'upwsh --help' prints this overview.

Listed tools: bat btm delta difft dust duf eza fd fzf gh hyperfine jq lazygit procs
ripgrep shfmt starship tssh yazi yq zoxide
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
    param([switch]$Uninstall)
    if (Get-Command Restore-UpwshSessionCommands -ErrorAction SilentlyContinue) {
        Restore-UpwshSessionCommands -KeepEntry:(-not $Uninstall)
    } else {
        Remove-Item Function:global:PSConsoleHostReadLine -ErrorAction SilentlyContinue
        function global:prompt {
            "PS $($executionContext.SessionState.Path.CurrentLocation)$('>' * ($nestedPromptLevel + 1)) "
        }
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
    foreach ($name in @('nvim', 'vim', 'notepad')) {
        $command = Get-Command $name -CommandType Application -ErrorAction SilentlyContinue |
            Select-Object -First 1
        if ($command) {
            return [pscustomobject]@{
                Path = $command.Source
                Wait = $name -eq 'notepad'
            }
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
        throw 'nvim, vim, or notepad.exe is not available to edit user-settings.ps1'
    }
    $name = [IO.Path]::GetFileNameWithoutExtension($editor.Path)
    Write-UpwshStatus file $settings editor $name
    if ($editor.Wait) {
        Start-Process -FilePath $editor.Path -ArgumentList ('"' + $settings + '"') -Wait
    } else {
        & $editor.Path $settings
        if ($null -ne $LASTEXITCODE) {
            $global:LASTEXITCODE = $LASTEXITCODE
        }
    }
}

function Write-UpwshSetupSummary {
    param(
        [string]$Command, [string[]]$SetupOutput, [bool]$Loaded,
        [string]$HomePath, [string]$HookPath, [bool]$Color,
        [hashtable]$Before, [hashtable]$After, [string]$SourceKind = 'local'
    )
    $sourcePath = ''
    $kept = [Collections.Generic.List[string]]::new()
    $notices = [Collections.Generic.List[string]]::new()
    foreach ($line in $SetupOutput) {
        $plain = $line -replace '\x1b\[[0-9;]*m', ''
        if ($plain -match '^source\s+(.+)$') { $sourcePath = $Matches[1] }
        elseif ($plain -match '^profile\s+(.+)$') { $hookPath = $Matches[1] }
        elseif ($plain -match '^keep\s+(.+)$') { if (-not $kept.Contains($Matches[1])) { $kept.Add($Matches[1]) } }
        elseif ($plain -match '^(missing|next|warn)\s+(.+)$') { $notices.Add($plain) }
        elseif ($plain -match '^tree\s+kept\s+(.+)$') { if (-not $kept.Contains($Matches[1])) { $kept.Add($Matches[1]) } }
        elseif ($plain -and $plain -notmatch '^(home|path|target|state|cmd|command|relaunch|tree)\s+') { $notices.Add($plain) }
    }
    $result = switch ($Command) { 'install' { 'installed' } 'update' { 'updated' } 'uninstall' { 'uninstalled' } }
    $heading = "upwsh $result ✓"
    if ($color) { $heading = "$($PSStyle.Foreground.Green)$heading$($PSStyle.Reset)" }
    Write-Output ''
    $settingsPath = Join-Path $homePath 'user-settings.ps1'
    $rows = [Collections.Generic.List[object]]::new()
    if ($sourcePath -and $Command -ne 'uninstall') {
        $rows.Add(@{ Label = 'Source'; Path = $sourcePath; Status = $SourceKind })
    }
    if ($Command -eq 'uninstall') {
        $homeStatus = if ($After.HomeExists) { 'runtime removed' } else { 'removed' }
        $profileStatus = if ($Before.HookPresent) { 'unlinked' } else { 'not linked' }
        $settingsStatus = if ($After.SettingsExists) { 'kept' } elseif ($Before.SettingsExists) { 'removed' } else { 'absent' }
    } else {
        $homeStatus = $result
        $profileStatus = 'linked'
        $settingsStatus = if ($Before.SettingsExists) { 'kept' } else { 'created' }
    }
    $rows.Add(@{ Label = 'Home'; Path = $homePath; Status = $homeStatus })
    $rows.Add(@{ Label = 'Profile'; Path = $hookPath; Status = $profileStatus })
    $rows.Add(@{ Label = 'Settings'; Path = $settingsPath; Status = $settingsStatus })
    foreach ($path in $kept) {
        if ($path -ine $settingsPath -and $path -ine $homePath) {
            $rows.Add(@{ Label = 'Kept'; Path = $path; Status = 'kept' })
        }
    }
    $width = ($rows | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum
    foreach ($row in $rows) {
        $prefix = '{0,-8}' -f $row.Label
        $status = $row.Status
        if ($color) {
            $prefix = "$($PSStyle.Foreground.Green)$prefix$($PSStyle.Reset)"
            $statusColor = if ($status -eq 'kept') { $PSStyle.Foreground.Yellow } else { $PSStyle.Foreground.Green }
            $status = "$statusColor$status$($PSStyle.Reset)"
        }
        Write-Output ("  {0}  {1}  {2}" -f $prefix, $row.Path.PadRight($width), $status)
    }
    if ($notices.Count) {
        Write-Output ''
        foreach ($notice in $notices) { Write-Output "  $notice" }
    }
    Write-Output ''
    Write-Output "  $heading"
    if ($Command -eq 'uninstall') {
        Write-Output '  Restart your shell to finish cleanup.'
    } elseif ($Loaded) {
        Write-Output '  Ready in this shell.'
    } else {
        Write-Output '  Open a new PowerShell window to load upwsh.'
    }
    if ($Command -eq 'install') {
        Write-Output '  Run upwsh --help to get started.'
    }
    Write-Output ''
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

    # Lifecycle scripts run in a clean process so their private functions and script scope
    # cannot collide with the currently loaded upwsh function.
    $pwsh = (Get-Process -Id $PID).Path
    & $pwsh -NoLogo -NoProfile -File $script @setupArgs
}

function Invoke-UpwshPostSetup {
    param(
        [Parameter(Mandatory)][string]$Command,
        [Parameter(Mandatory)][int]$Code
    )

    if ($Code -ne 0) { return }
    if ($Command -in @('install', 'update')) {
        Add-UpwshUserEnvironment
        Invoke-UpwshLoad -Parsed ([pscustomobject]@{ Command = 'load' })
        Invoke-UpwshSessionProfile
        return
    }
    if ($Command -eq 'uninstall') {
        Remove-UpwshUserEnvironment
        Restore-UpwshDefaultPrompt -Uninstall
    }
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
    # Help/check output remains diagnostic; summarize only a completed lifecycle action.
    $diagnostic = @($parsed.Rest | Where-Object { $_ -in @('--help','-h','--check','-c') }).Count -gt 0
    if ($diagnostic) {
        Invoke-UpwshSetup -Parsed $parsed
        Complete-Upwsh $global:LASTEXITCODE $scriptInvocation
        return
    }
    $summaryHome = Get-UpwshHome
    $summaryProfile = if ($env:UPWSH_PROFILE) { [IO.Path]::GetFullPath((winpath $env:UPWSH_PROFILE)) } else { $PROFILE.CurrentUserAllHosts }
    for ($index = 0; $index -lt $parsed.Rest.Count - 1; $index++) {
        if ($parsed.Rest[$index] -in @('--profile','-p')) { $summaryProfile = [IO.Path]::GetFullPath((winpath $parsed.Rest[$index + 1])) }
    }
    if ('--current-host' -in $parsed.Rest) { $summaryProfile = $PROFILE.CurrentUserCurrentHost }
    $before = @{
        SettingsExists = [IO.File]::Exists((Join-Path $summaryHome 'user-settings.ps1'))
        HookPresent = [IO.File]::Exists($summaryProfile) -and [IO.File]::ReadAllText($summaryProfile).Contains('# >>> upwsh >>>')
    }
    $sourceKind = if (@($parsed.Rest | Where-Object { $_ -in @('--remote','--ref','--repo') }).Count -or $env:UPWSH_REF -or $env:UPWSH_REPO) {
        'remote'
    } elseif ('--local' -in $parsed.Rest -or '--source' -in $parsed.Rest -or $env:UPWSH_SOURCE) { 'local' } else { 'remote' }
    $setupOutput = @(Invoke-UpwshSetup -Parsed $parsed 6>&1 | ForEach-Object { [string]$_ })
    $setupCode = $global:LASTEXITCODE
    if ($setupCode -ne 0) {
        $setupOutput | Write-Output
        Complete-Upwsh $setupCode $scriptInvocation
        return
    }
    # Capture helpers before teardown/reload replaces their defining session state.
    $summary = ${function:Write-UpwshSetupSummary}
    $summaryColor = Test-UpwshStatusColor
    $setupCommand = $parsed.Command
    $loaded = -not [bool]$env:UPWSH_SKIP_SESSION_LOAD
    try {
        $postOutput = @(Invoke-UpwshPostSetup -Command $setupCommand -Code $setupCode | ForEach-Object { [string]$_ })
    } catch {
        $setupOutput | Write-Output
        Write-Output "upwsh: $($_.Exception.Message)"
        $global:LASTEXITCODE = 1
        if ($PSCommandPath -and $scriptInvocation.CommandOrigin -eq 'Runspace') { exit 1 }
        return
    }
    & $summary -Command $setupCommand -SetupOutput @($setupOutput + $postOutput) -Loaded:$loaded `
        -HomePath $summaryHome -HookPath $summaryProfile -Color:$summaryColor -Before $before `
        -After @{ HomeExists = [IO.Directory]::Exists($summaryHome); SettingsExists = [IO.File]::Exists((Join-Path $summaryHome 'user-settings.ps1')) } `
        -SourceKind $sourceKind
    $global:LASTEXITCODE = 0
    if ($PSCommandPath -and $scriptInvocation.CommandOrigin -eq 'Runspace') { exit 0 }
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
