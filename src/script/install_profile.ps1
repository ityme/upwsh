# 管理 ~/.config/upwsh/profile.ps1 的自动加载。-Deploy 仅用于文件部署，不写 profile。
#   install_profile.ps1
#   install_profile.ps1 -Check
#   install_profile.ps1 -Uninstall
#   install_profile.ps1 -Deploy
#   install_profile.ps1 -CurrentHost

[CmdletBinding()]
param(
    [string]$ProfilePath,
    [string]$Destination,
    [switch]$Check,
    [switch]$Uninstall,
    [switch]$Deploy,
    [switch]$CurrentHost
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\upwsh_home.ps1')
$script:NewLine = "`r`n"
$script:BeginMarker = '# >>> upwsh >>>'
$script:EndMarker = '# <<< upwsh <<<'

function Get-SourceRoot {
    [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
}

function Get-SourceProfilePath {
    Join-Path (Get-SourceRoot) 'profile.ps1'
}

function Get-DefaultDestination {
    Get-UpwshHome
}

function Get-HookProfilePath {
    if ($ProfilePath) {
        return [IO.Path]::GetFullPath($ProfilePath)
    }
    if (-not [string]::IsNullOrWhiteSpace($env:UPWSH_PROFILE)) {
        return [IO.Path]::GetFullPath((winpath $env:UPWSH_PROFILE))
    }
    if ($CurrentHost) {
        return $PROFILE.CurrentUserCurrentHost
    }
    return $PROFILE.CurrentUserAllHosts
}

function ConvertTo-SingleQuotedText {
    param([string]$Text)
    "'" + $Text.Replace("'", "''") + "'"
}

function Get-InstallBlock {
    param([string]$TargetProfile)

    $quoted = ConvertTo-SingleQuotedText $TargetProfile
    @(
        $script:BeginMarker
        "if (Test-Path -LiteralPath $quoted -PathType Leaf) {"
        "    . $quoted"
        '}'
        $script:EndMarker
    ) -join $script:NewLine
}

function Get-InstallPattern {
    '(?ms)^' + [regex]::Escape($script:BeginMarker) +
    '\r?\n.*?' + [regex]::Escape($script:EndMarker) +
    '(?:\r?\n)?'
}

function Read-ProfileText {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        return ''
    }
    [IO.File]::ReadAllText($Path)
}

function Write-ProfileText {
    param([string]$Path, [string]$Text)

    $parent = Split-Path -Parent $Path
    if ($parent) {
        New-Item -ItemType Directory -Path $parent -Force | Out-Null
    }
    [IO.File]::WriteAllText($Path, $Text)
}

function Remove-InstallBlock {
    param([string]$Text)

    $removed = [regex]::Replace($Text, (Get-InstallPattern), '')
    $removed.TrimEnd() + $(if ($removed.Trim()) { $script:NewLine } else { '' })
}

function Set-InstallBlock {
    param([string]$Text, [string]$Block)

    $without = Remove-InstallBlock $Text
    if ([string]::IsNullOrWhiteSpace($without)) {
        return $Block + $script:NewLine
    }
    $without.TrimEnd() + $script:NewLine + $script:NewLine + $Block + $script:NewLine
}

function Get-InstalledTarget {
    param([string]$Text)

    $match = [regex]::Match($Text, (Get-InstallPattern))
    if (-not $match.Success) {
        return $null
    }
    if ($match.Value -match "LiteralPath '((?:''|[^'])*)'") {
        return $Matches[1].Replace("''", "'")
    }
    return $null
}

function Write-InstallStatus {
    param(
        [string]$HookPath,
        [string]$TargetPath,
        [string]$State
    )

    Write-UpwshStatus profile $HookPath target $TargetPath state $State
}

if ($Deploy -and ($Uninstall -or $Check)) {
    throw 'Use -Deploy separately from -Uninstall or -Check.'
}

$hookPath = Get-HookProfilePath
$targetProfile = Join-Path (Get-UpwshHome) 'profile.ps1'
if ($Deploy) {
    $sourceProfile = Get-SourceProfilePath
    if (-not (Test-Path -LiteralPath $sourceProfile -PathType Leaf)) {
        throw "missing profile: $sourceProfile"
    }
    if (-not $Destination) {
        $Destination = Get-DefaultDestination
    }
    $Destination = [IO.Path]::GetFullPath($Destination)
    . (Join-Path $PSScriptRoot '_deploy.ps1')
    Copy-UpwshRuntime -Source (Get-SourceRoot) -Destination $Destination
    $userSettings = Join-Path $Destination 'user-settings.ps1'
    $userSettingsSource = Join-Path (Get-SourceRoot) 'user-settings.ps1'
    if ([IO.File]::Exists($userSettingsSource) -and -not [IO.File]::Exists($userSettings)) {
        Copy-Item -LiteralPath $userSettingsSource -Destination $userSettings
    }
    $targetProfile = Join-Path $Destination 'profile.ps1'
    Write-InstallStatus -HookPath $hookPath -TargetPath $targetProfile -State 'deployed'
    return
}

$existing = Read-ProfileText $hookPath
$installedTarget = Get-InstalledTarget $existing

if ($Check) {
    $state = if ($installedTarget) { 'installed' } else { 'missing' }
    $shownTarget = if ($installedTarget) { $installedTarget } else { $targetProfile }
    Write-InstallStatus -HookPath $hookPath -TargetPath $shownTarget -State $state
    return
}

if ($Uninstall) {
    if (-not $installedTarget) {
        Write-InstallStatus -HookPath $hookPath -TargetPath $targetProfile -State 'missing'
        return
    }
    Write-ProfileText -Path $hookPath -Text (Remove-InstallBlock $existing)
    Write-InstallStatus -HookPath $hookPath -TargetPath $installedTarget -State 'removed'
    return
}

if (-not (Test-Path -LiteralPath $targetProfile -PathType Leaf)) {
    throw "runtime is not installed at $targetProfile; run upwsh install first"
}

$updated = Set-InstallBlock -Text $existing -Block (Get-InstallBlock $targetProfile)
if ($updated -cne $existing) {
    Write-ProfileText -Path $hookPath -Text $updated
}
Write-InstallStatus -HookPath $hookPath -TargetPath $targetProfile -State 'installed'
