# Terminal protocol events and state. No subprocesses, polling, or command-specific adapters.
. ([IO.Path]::Combine($PSScriptRoot, 'path_convert.ps1'))
$script:TermKnownFields = @(
    'SHELL', 'SHELL_VERSION', 'HOST', 'USER', 'DOMAIN', 'ADMIN', 'SSH', 'PID', 'SESSION_ID', 'SCHEMA',
    'CWD', 'CWD_UNIX', 'DIR', 'CWD_HOME', 'DRIVE', 'PROVIDER', 'LOCATION', 'VENV',
    'COMMAND', 'CMD', 'BUSY', 'OK', 'EXIT', 'STATUS', 'ELAPSED_MS', 'LAST_CMD', 'LAST_ELAPSED_MS',
    'LAST_NATIVE_EXIT', 'COMMAND_ID', 'TITLE', 'OSC7', 'OSC9_9', 'OSC133', 'USERVARS'
)
$script:TermReport = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$script:TermSent = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$script:TermEncoded = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
$script:TermBuilder = [Text.StringBuilder]::new(2048)
$script:TermUtf8 = [Text.Encoding]::UTF8
$script:TermSessionId = [guid]::NewGuid().ToString('N')
$script:TermIdentity = $null
$script:TermCommandStarted = $null
$script:TermCommandId = [long]0
$script:TermRunningName = ''
$script:TermLastName = ''
$script:TermLastElapsed = ''
$script:TermMode = 'Auto'
$script:TermFullCommand = $false
$script:TermCommandMaxBytes = 2048
$script:TermPhase = 'none'
$script:TermEndPending = $false
$script:TermIdleKey = $null
$script:TermLocationKey = $null
$script:TermLocationValues = $null
$script:TermResync = $true
$script:TermConfigVersion = 0
$script:TermClearFields = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)

function Set-TermReporting {
    [CmdletBinding()]
    param(
        [ValidateSet('Auto', 'On', 'Off')][string]$Mode,
        [AllowEmptyCollection()][string[]]$Fields,
        [bool]$FullCommand,
        [ValidateRange(0, 16384)][int]$CommandMaxBytes,
        [switch]$Reset
    )
    if ($Reset) {
        $script:TermReport = [Collections.Generic.HashSet[string]]::new([string[]]$script:TermKnownFields, [StringComparer]::OrdinalIgnoreCase)
        if (-not $env:WT_SESSION) { [void]$script:TermReport.Remove('OSC9_9') }
        if ($Mode -ne 'On' -and -not ($env:WEZTERM_PANE -or $env:TERM_PROGRAM -in @('WezTerm', 'iTerm.app'))) {
            [void]$script:TermReport.Remove('USERVARS')
        }
        $script:TermMode = 'Auto'
        $script:TermFullCommand = $false
        $script:TermCommandMaxBytes = 2048
    }
    if ($PSBoundParameters.ContainsKey('Fields')) {
        foreach ($name in $Fields) {
            if ($name -notin $script:TermKnownFields) { throw "unknown terminal field: $name" }
        }
        $selected = [Collections.Generic.HashSet[string]]::new([string[]]$Fields, [StringComparer]::OrdinalIgnoreCase)
        foreach ($name in @($script:TermEncoded.Keys)) {
            if (-not $selected.Contains('USERVARS') -or -not $selected.Contains($name)) {
                [void]$script:TermClearFields.Add($name)
            }
        }
        $script:TermReport = $selected
    }
    if ($Mode) { $script:TermMode = $Mode }
    if ($PSBoundParameters.ContainsKey('FullCommand')) { $script:TermFullCommand = $FullCommand }
    if ($PSBoundParameters.ContainsKey('CommandMaxBytes')) { $script:TermCommandMaxBytes = $CommandMaxBytes }
    $script:TermConfigVersion++
    $script:TermResync = $true
    $script:TermIdleKey = $null
}

$initialSettings = @{ Reset = $true }
if ($env:UPWSH_OSC -in @('Auto', 'On', 'Off')) { $initialSettings.Mode = $env:UPWSH_OSC }
if ($null -ne $env:UPWSH_OSC_FIELDS) {
    $initialSettings.Fields = [string[]]@($env:UPWSH_OSC_FIELDS -split ',' | ForEach-Object { $_.Trim() } | Where-Object { $_ })
}
$initialSettings.FullCommand = $env:UPWSH_OSC_COMMAND -eq '1'
Set-TermReporting @initialSettings

function Test-TermOutput {
    if ($script:TermMode -eq 'Off') { return $false }
    if ($script:TermMode -eq 'On') { return $true }
    return $Host.Name -eq 'ConsoleHost' -and $Host.UI.SupportsVirtualTerminal -and
        -not [Console]::IsOutputRedirected -and -not [Console]::IsInputRedirected -and $env:TERM -ne 'dumb'
}

function Write-TermText {
    param([string]$Text)
    if (-not $Text) { return }
    try { [Console]::Write($Text) }
    catch { $script:TermResync = $true; $script:TermIdleKey = $null }
}

function Add-TermVariables {
    param([Collections.IDictionary]$Values, [bool]$Force = $false)
    if (-not $script:TermReport.Contains('USERVARS')) { return }
    foreach ($name in $Values.Keys) {
        if (-not $script:TermReport.Contains($name)) { continue }
        $value = [string]$Values[$name]
        $previous = $null
        $same = $script:TermSent.TryGetValue($name, [ref]$previous) -and $previous -ceq $value
        if ($same -and -not $Force) { continue }
        if (-not $same) {
            $script:TermEncoded[$name] = "$([char]27)]1337;SetUserVar=$name=$([Convert]::ToBase64String($script:TermUtf8.GetBytes($value)))$([char]7)"
            $script:TermSent[$name] = $value
        }
        [void]$script:TermBuilder.Append($script:TermEncoded[$name])
    }
}

function Clear-TermRemovedFields {
    foreach ($name in $script:TermClearFields) {
        [void]$script:TermBuilder.Append("$([char]27)]1337;SetUserVar=$name=$([char]7)")
        [void]$script:TermEncoded.Remove($name)
        [void]$script:TermSent.Remove($name)
    }
    $script:TermClearFields.Clear()
}

function Add-TermChannel {
    param([string]$Name, [string]$Text, [bool]$Force = $false)
    if (-not $script:TermReport.Contains($Name)) { return }
    $previous = $null
    if (-not $Force -and $script:TermSent.TryGetValue($Name, [ref]$previous) -and $previous -ceq $Text) { return }
    $script:TermSent[$Name] = $Text
    [void]$script:TermBuilder.Append($Text)
}

function Get-TermDirectoryLeaf {
    param([string]$Path)
    $trimmed = $Path.TrimEnd('\', '/')
    if (-not $trimmed) { return $Path }
    $slash = $trimmed.LastIndexOfAny([char[]]@('\', '/'))
    if ($slash -ge 0 -and $slash -lt $trimmed.Length - 1) { return $trimmed.Substring($slash + 1) }
    return $trimmed
}

function Get-TermCommandName {
    param([AllowEmptyString()][string]$Command = '')
    $tokens = $null; $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Command, [ref]$tokens, [ref]$errors)
    $commandAst = $ast.Find({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $false)
    $name = if ($commandAst) { $commandAst.GetCommandName() } else { '' }
    if (-not $name) { return '' }
    $label = (Get-TermDirectoryLeaf $name) -replace '[\x00-\x1f\x7f-\x9f]', ' '
    return $label.Substring(0, [math]::Min(160, $label.Length))
}

function Get-TermPaneTitle {
    param([AllowEmptyString()][string]$Command = '', [string]$CommandName)
    $location = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    $directory = Get-TermDirectoryLeaf $location
    $name = if ($PSBoundParameters.ContainsKey('CommandName')) { $CommandName } elseif ($Command) { Get-TermCommandName $Command } else { '' }
    $title = if ($name) { "$directory › $name" } else { $directory }
    $title = ($title -replace '[\x00-\x1f\x7f-\x9f]', ' ').Trim()
    if ($title.Length -gt 160) { return $title.Substring(0, 157) + '...' }
    return $title
}

function ConvertTo-TermFileUri {
    param([string]$Path)
    # Escape each filesystem segment, including literal %, before forming the file URI.
    $slashPath = $Path.Replace('\', '/')
    if ($slashPath.StartsWith('//')) {
        $parts = $slashPath.Substring(2).Split('/')
        $authority = $parts[0]
        $segments = @($parts | Select-Object -Skip 1)
    } elseif ($slashPath -match '^[A-Za-z]:/') {
        $authority = ''
        $segments = $slashPath.Split('/')
    } else { return '' }
    $encoded = [Collections.Generic.List[string]]::new()
    foreach ($segment in $segments) { $encoded.Add([uri]::EscapeDataString($segment)) }
    if (-not $slashPath.StartsWith('//')) { $encoded[0] = $segments[0] }
    return 'file://' + $authority + '/' + ($encoded -join '/')
}

function Get-TermIdentity {
    if ($null -eq $script:TermIdentity) {
        $admin = '0'
        try {
            $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
            try {
                $principal = [Security.Principal.WindowsPrincipal]::new($identity)
                if ($principal.IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) { $admin = '1' }
            } finally { $identity.Dispose() }
        } catch { }
        $script:TermIdentity = [ordered]@{
            SHELL = 'pwsh'; SHELL_VERSION = $PSVersionTable.PSVersion.ToString()
            HOST = [Environment]::MachineName; USER = [Environment]::UserName; DOMAIN = [Environment]::UserDomainName
            ADMIN = $admin; SSH = $(if ($env:SSH_CONNECTION -or $env:SSH_CLIENT -or $env:SSH_TTY) { '1' } else { '0' })
            PID = [string]$PID; SESSION_ID = $script:TermSessionId; SCHEMA = '2'
        }
    }
    return $script:TermIdentity
}

function Get-TermLocationValues {
    $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    $key = @($cwd, $location.Path, $location.Provider.Name, $HOME, $env:VIRTUAL_ENV) -join [char]0
    if ($script:TermLocationKey -ceq $key) { return $script:TermLocationValues }
    $homeRelative = $cwd
    $homeRoot = $HOME.TrimEnd('\', '/')
    if ($cwd -eq $homeRoot) { $homeRelative = '~' }
    elseif ($cwd.StartsWith($homeRoot + '\', [StringComparison]::OrdinalIgnoreCase)) {
        $homeRelative = '~/' + $cwd.Substring($homeRoot.Length + 1).Replace('\', '/')
    }
    $script:TermLocationValues = [ordered]@{
        CWD = $cwd; CWD_UNIX = unixpath $cwd; DIR = Get-TermDirectoryLeaf $cwd; CWD_HOME = $homeRelative
        DRIVE = $(if ($cwd -match '^([A-Za-z]):') { $Matches[1].ToUpperInvariant() + ':' } else { '' })
        PROVIDER = $location.Provider.Name; LOCATION = $location.Path
        VENV = $(if ($env:VIRTUAL_ENV) { Get-TermDirectoryLeaf $env:VIRTUAL_ENV } else { '' })
    }
    $script:TermFileUri = ConvertTo-TermFileUri $cwd
    $script:TermLocationTitle = Get-TermPaneTitle
    $script:TermLocationKey = $key
    return $script:TermLocationValues
}

function Sync-TermCommand {
    param([AllowEmptyString()][string]$Command = '')
    $script:TermCommandStarted = [Diagnostics.Stopwatch]::GetTimestamp()
    $script:TermCommandId++
    $script:TermRunningName = Get-TermCommandName $Command
    $script:TermIdleKey = $null
    if (-not (Test-TermOutput)) { $script:TermResync = $true; return }
    [void]$script:TermBuilder.Clear()
    Clear-TermRemovedFields
    $text = ''
    if ($script:TermFullCommand -and $script:TermCommandMaxBytes -gt 0) {
        $chars = $Command.Substring(0, [math]::Min($Command.Length, $script:TermCommandMaxBytes)).ToCharArray()
        $bytes = [byte[]]::new([math]::Max(4, $script:TermCommandMaxBytes))
        $charsUsed = 0; $bytesUsed = 0; $complete = $false
        $script:TermUtf8.GetEncoder().Convert($chars, 0, $chars.Length, $bytes, 0, $bytes.Length, $false, [ref]$charsUsed, [ref]$bytesUsed, [ref]$complete)
        $text = if ($bytesUsed -le $script:TermCommandMaxBytes) { $script:TermUtf8.GetString($bytes, 0, $bytesUsed) } else { '' }
    }
    Add-TermVariables ([ordered]@{ BUSY = '1'; CMD = $script:TermRunningName; COMMAND = $text; COMMAND_ID = [string]$script:TermCommandId })
    if ($script:TermReport.Contains('TITLE')) {
        Add-TermChannel 'TITLE' "$([char]27)]2;$(Get-TermPaneTitle -CommandName $script:TermRunningName)$([char]7)"
    }
    if ($script:TermReport.Contains('OSC133')) {
        [void]$script:TermBuilder.Append("$([char]27)]133;C$([char]7)")
        $script:TermPhase = 'running'
    }
    Write-TermText $script:TermBuilder.ToString()
}

function Complete-TermPrompt {
    if (-not $script:TermEndPending) { return }
    $script:TermEndPending = $false
    if ((Test-TermOutput) -and $script:TermReport.Contains('OSC133')) {
        Write-TermText "$([char]27)]133;B$([char]7)"
        $script:TermPhase = 'input'
    }
}

function Sync-TermPrompt {
    param(
        [bool]$Succeeded = $true,
        $ExitCode,
        $NativeExitCode,
        [ValidateSet('success', 'error', 'interrupted', 'unknown')][string]$Status,
        [bool]$CommandCompleted = $true,
        [long]$CompletedAt = [Diagnostics.Stopwatch]::GetTimestamp(),
        [switch]$DeferEnd
    )
    $effectiveExit = if ($Succeeded) { '0' } elseif ($null -ne $ExitCode -and [string]$ExitCode -notin @('', '0')) { [string]$ExitCode } else { '1' }
    $elapsed = ''
    if ($CommandCompleted) {
        if ($null -ne $script:TermCommandStarted) {
            $elapsed = [string][long][math]::Max(0.0, [math]::Floor(($CompletedAt - $script:TermCommandStarted) * 1000.0 / [Diagnostics.Stopwatch]::Frequency))
        }
        $script:TermLastElapsed = $elapsed
        $script:TermLastName = $script:TermRunningName
        $script:TermCommandStarted = $null
    }
    if (-not (Test-TermOutput)) { $script:TermResync = $true; $script:TermEndPending = $false; return }
    $location = $ExecutionContext.SessionState.Path.CurrentLocation
    $cwd = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $idleKey = @($cwd, $location.Path, $location.Provider.Name, $HOME, $env:VIRTUAL_ENV, $Succeeded, $effectiveExit, [string]$ExitCode, [string]$NativeExitCode, $Status, $script:TermConfigVersion) -join [char]0
    [void]$script:TermBuilder.Clear()
    Clear-TermRemovedFields
    if ($script:TermReport.Contains('OSC133')) {
        if ($CommandCompleted) {
            [void]$script:TermBuilder.Append("$([char]27)]133;D;$effectiveExit$([char]7)")
        } elseif ($script:TermPhase -eq 'input') {
            # D with no status after B closes an abandoned/empty input, not an executed command.
            [void]$script:TermBuilder.Append("$([char]27)]133;D$([char]7)")
        }
        [void]$script:TermBuilder.Append("$([char]27)]133;A$([char]7)")
        $script:TermEndPending = $true
        $script:TermPhase = 'prompt'
    }
    $force = $CommandCompleted -or $script:TermResync
    if ($force -or $script:TermIdleKey -cne $idleKey) {
        if ($script:TermReport.Contains('USERVARS')) {
            Add-TermVariables (Get-TermIdentity) $force
        }
        Add-TermVariables (Get-TermLocationValues) $force
        Add-TermVariables ([ordered]@{
            BUSY = '0'; COMMAND = ''; CMD = ''; OK = $(if ($Succeeded) { '1' } else { '0' })
            EXIT = $effectiveExit; STATUS = $(if ($Status) { $Status } elseif ($Succeeded) { 'success' } else { 'error' })
            ELAPSED_MS = $elapsed; LAST_CMD = $script:TermLastName; LAST_ELAPSED_MS = $script:TermLastElapsed
            LAST_NATIVE_EXIT = [string]$NativeExitCode; COMMAND_ID = [string]$script:TermCommandId
        }) $force
        Add-TermChannel 'TITLE' "$([char]27)]2;$script:TermLocationTitle$([char]7)" $force
        if ($script:TermReport.Contains('OSC7') -and $script:TermFileUri) {
            Add-TermChannel 'OSC7' "$([char]27)]7;$script:TermFileUri$([char]7)" $force
        }
        if ($script:TermReport.Contains('OSC9_9') -and $cwd -notmatch '[\x00-\x1f\x7f"\x9c]') {
            Add-TermChannel 'OSC9_9' "$([char]27)]9;9;`"$cwd`"$([char]7)" $force
        }
        $script:TermResync = $false
        # One later idle prompt clears transient elapsed time; the persistent value remains.
        $script:TermIdleKey = if ($elapsed) { $null } else { $idleKey }
    }
    Write-TermText $script:TermBuilder.ToString()
    if (-not $DeferEnd) { Complete-TermPrompt }
}

function Get-TermLastElapsedMilliseconds {
    # Share the completed command's monotonic duration with the native prompt, even with OSC off.
    return [long]$script:TermLastElapsed
}

Export-ModuleMember -Function Get-TermPaneTitle, Get-TermCommandName, Sync-TermCommand, Sync-TermPrompt, Complete-TermPrompt, Set-TermReporting, Get-TermLastElapsedMilliseconds
