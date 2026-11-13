# 由 upwsh tool 调用。可执行文件装到 $UPWSH_HOME\tool\bin。
#   upwsh tool list
#   upwsh tool install eza ripgrep
#   upwsh tool install --all
#   upwsh tool update eza
#   upwsh tool update --all
#   upwsh tool uninstall eza

[CmdletBinding()]
param(
    [string[]]$Only = @(),
    [switch]$List,
    [switch]$Uninstall,
    [switch]$Update,
    [switch]$InstalledOnly
)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '..\lib\upwsh_home.ps1')
$Dir = Get-UpwshToolBin

$script:Tools = @(
    @{ Name = 'bat'; Description = 'Syntax-highlighted cat alternative'; Repo = 'sharkdp/bat'; Exe = 'bat.exe' }
    @{ Name = 'btm'; Description = 'System monitor; top alternative'; Repo = 'ClementTsang/bottom'; Exe = 'btm.exe' }
    @{ Name = 'delta'; Description = 'Readable, highlighted Git diffs'; Repo = 'dandavison/delta'; Exe = 'delta.exe' }
    @{ Name = 'difft'; Description = 'Syntax-aware diff tool'; Repo = 'Wilfred/difftastic'; Exe = 'difft.exe' }
    @{ Name = 'dust'; Description = 'Disk usage; du alternative'; Repo = 'bootandy/dust'; Exe = 'dust.exe' }
    @{ Name = 'duf'; Description = 'Free disk space; df alternative'; Repo = 'muesli/duf'; Exe = 'duf.exe' }
    @{ Name = 'eza'; Description = 'File listing; ls alternative'; Repo = 'eza-community/eza'; Exe = 'eza.exe' }
    @{ Name = 'fd'; Description = 'File search; find alternative'; Repo = 'sharkdp/fd'; Exe = 'fd.exe' }
    @{ Name = 'fzf'; Description = 'Interactive fuzzy finder'; Repo = 'junegunn/fzf'; Exe = 'fzf.exe' }
    @{ Name = 'gh'; Description = 'GitHub from the command line'; Repo = 'cli/cli'; Exe = 'gh.exe' }
    @{ Name = 'hyperfine'; Description = 'Command-line benchmarking'; Repo = 'sharkdp/hyperfine'; Exe = 'hyperfine.exe' }
    @{ Name = 'jq'; Description = 'JSON query and transformation'; Repo = 'jqlang/jq'; Exe = 'jq.exe' }
    @{ Name = 'lazygit'; Description = 'Terminal UI for Git'; Repo = 'jesseduffield/lazygit'; Exe = 'lazygit.exe' }
    @{ Name = 'procs'; Description = 'Process viewer; ps alternative'; Repo = 'dalance/procs'; Exe = 'procs.exe' }
    @{ Name = 'ripgrep'; Description = 'Fast text search; grep alternative (rg)'; Repo = 'BurntSushi/ripgrep'; Exe = 'rg.exe' }
    @{ Name = 'shfmt'; Description = 'Shell script formatter'; Repo = 'mvdan/sh'; Exe = 'shfmt.exe' }
    @{ Name = 'starship'; Description = 'Customizable shell prompt'; Repo = 'starship/starship'; Exe = 'starship.exe' }
    @{ Name = 'tssh'; Description = 'SSH client with file transfer'; Repo = 'trzsz/trzsz-ssh'; Exe = 'tssh.exe' }
    @{ Name = 'yazi'; Description = 'Terminal file manager'; Repo = 'sxyazi/yazi'; Exe = 'yazi.exe' }
    @{ Name = 'yq'; Description = 'YAML query and transformation'; Repo = 'mikefarah/yq'; Exe = 'yq.exe' }
    @{ Name = 'zoxide'; Description = 'Smarter directory navigation; cd alternative'; Repo = 'ajeetdsouza/zoxide'; Exe = 'zoxide.exe' }
)

function Test-WindowsAmd64Asset {
    param([string]$Name)

    if ($Name -match '\.(sha256|sha256sum|sig|deb|rpm|txt|json)$') {
        return $false
    }
    if ($Name -match 'arm|aarch64|i686|i386|386|32-bit|win32|darwin|linux|musl') {
        return $false
    }
    if ($Name -match 'gnu' -and $Name -notmatch 'windows|win64|pc-windows') {
        return $false
    }
    return $Name -match 'windows|win64|msvc|pc-windows'
}

function Get-GitHubLatestRelease {
    param([string]$Repo)

    $gh = Get-Command gh -ErrorAction SilentlyContinue
    if ($gh) {
        return gh api "repos/$Repo/releases/latest" | ConvertFrom-Json
    }

    Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers @{
            'User-Agent' = 'upwsh-installer'
            Accept       = 'application/vnd.github+json'
        }
}

function Get-ReleaseAsset {
    param($Release, [string]$Exe)

    $preferred = @(
        $Release.assets |
            Where-Object {
                $_.name -and
                (Test-WindowsAmd64Asset $_.name) -and
                (
                    $_.name -like '*.zip' -or
                    $_.name -like '*.exe'
                )
            }
    )
    if ($preferred.Count -eq 0) {
        return $null
    }

    $exeStem = [IO.Path]::GetFileNameWithoutExtension($Exe)
    $named = @(
        $preferred |
            Where-Object { $_.name -match [regex]::Escape($exeStem) }
    )
    if ($named.Count -gt 0) {
        return $named[0]
    }
    return $preferred[0]
}

function Test-CliToolCommand {
    param([string]$Name)

    $null -ne (
        Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue
    )
}

function Write-CliToolHeader {
    param([switch]$WithDescription)

    $header = '  {0,-10}  {1,-9}  {2,-11}  {3}' -f 'Tool', 'Version', 'Status', ('Path'.PadRight($script:ToolPathWidth))
    $separator = '  {0}  {1}  {2}  {3}' -f ('-' * 10), ('-' * 9), ('-' * 11), ('-' * $script:ToolPathWidth)
    if ($WithDescription) { $header += '  Description'; $separator += '  ' + ('-' * 35) }
    Write-Output ($header.TrimEnd())
    Write-Output $separator
}

function Write-CliToolRow {
    param([string]$Name, [string]$Version = '-', [string]$Status, [string]$Path = '-', [string]$Description, [switch]$Pending)

    # Only a real terminal gets an in-place download row; pipes get final rows only.
    $interactive = $Host.UI.SupportsVirtualTerminal -and -not [Console]::IsOutputRedirected
    if ($Pending -and -not $interactive) { return }
    if ($script:ToolRowPending) { [Console]::Write("`r$([char]27)[2K") }
    $state = '{0,-11}' -f $Status
    if (Test-UpwshStatusColor) {
        $color = switch ($Status) {
            'installed' { $PSStyle.Foreground.Green }
            'downloading' { $PSStyle.Foreground.Cyan }
            'failed' { $PSStyle.Foreground.Red }
            default { $PSStyle.Foreground.BrightBlack }
        }
        $state = "$color$state$($PSStyle.Reset)"
    }
    $row = '  {0,-10}  {1,-9}  {2}  {3}' -f $Name, $Version, $state, $Path
    if ($PSBoundParameters.ContainsKey('Description')) {
        $row = '  {0,-10}  {1,-9}  {2}  {3}  {4}' -f $Name, $Version, $state, $Path.PadRight($script:ToolPathWidth), $Description
    }
    $script:ToolRowPending = [bool]$Pending
    if ($Pending) { [Console]::Write($row) } else { Write-Output $row }
}

function Uninstall-CliTool {
    param($Tool, [string]$Destination)

    $target = Join-Path $Destination $Tool.Exe
    if (-not (Test-Path -LiteralPath $target)) {
        Write-CliToolRow -Name $Tool.Name -Status uninstalled -Path $target
        return
    }
    Remove-Item -LiteralPath $target -Force
    Write-CliToolRow -Name $Tool.Name -Status uninstalled -Path $target
}

function Install-CliTool {
    param($Tool, [string]$Destination, [switch]$Force)

    $target = Join-Path $Destination $Tool.Exe
    if (-not $Force -and (Test-Path -LiteralPath $target)) {
        Write-CliToolRow -Name $Tool.Name -Status installed -Path $target
        return
    }

    $release = Get-GitHubLatestRelease -Repo $Tool.Repo
    $Tool.InstallVersion = [string]$release.tag_name
    $asset = Get-ReleaseAsset -Release $release -Exe $Tool.Exe
    if (-not $asset) {
        throw "no Windows amd64 asset for $($Tool.Repo)"
    }

    $tempRoot = Join-Path ([IO.Path]::GetTempPath()) (
        'cli-install-' + [Guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $tempRoot | Out-Null
    try {
        $download = Join-Path $tempRoot $asset.name
        Write-CliToolRow -Name $Tool.Name -Version $Tool.InstallVersion -Status downloading -Pending
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $download -UseBasicParsing

        if ($asset.name -like '*.zip') {
            Expand-Archive -LiteralPath $download -DestinationPath $tempRoot -Force
            $extracted = Get-ChildItem -LiteralPath $tempRoot -Recurse -Filter $Tool.Exe |
                Select-Object -First 1
        } else {
            $extracted = Get-Item -LiteralPath $download
        }

        if (-not $extracted) {
            throw "archive had no $($Tool.Exe)"
        }

        New-Item -ItemType Directory -Path $Destination -Force | Out-Null
        Copy-Item -LiteralPath $extracted.FullName -Destination $target -Force
        Write-CliToolRow -Name $Tool.Name -Version $Tool.InstallVersion -Status installed -Path $target
    } finally {
        Remove-Item -LiteralPath $tempRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$names = @(
    $Only |
        ForEach-Object { $_ -split ',' } |
        ForEach-Object { $_.Trim() } |
        Where-Object { $_ }
)
$selected = @(
    $script:Tools |
        Where-Object { $names.Count -eq 0 -or $_.Name -in $names }
)
if ($names.Count -gt 0) {
    $unknown = @($names | Where-Object { $_ -notin @($script:Tools.Name) })
    if ($unknown.Count -gt 0) {
        throw "unknown tools: $($unknown -join ', ')"
    }
}

if (([int][bool]$List + [int][bool]$Uninstall + [int][bool]$Update) -gt 1) {
    throw 'Use only one of -List, -Uninstall, or -Update.'
}
if ($Uninstall -and $names.Count -eq 0) {
    throw 'missing tool name'
}
if ($Update -and $InstalledOnly) {
    $selected = @(
        $selected |
            Where-Object { Test-Path -LiteralPath (Join-Path $Dir $_.Exe) }
    )
    if ($selected.Count -eq 0) {
        Write-UpwshStatus skip 'no installed tools to update'
        return
    }
}

$script:ToolPathWidth = 40
$script:ToolRowPending = $false
if ($List) {
    $rows = @(foreach ($tool in $selected) {
        $command = Get-Command ([IO.Path]::GetFileNameWithoutExtension($tool.Exe)) -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
        $path = if ($command) { $command.Source } else { '-' }
        $script:ToolPathWidth = [Math]::Max($script:ToolPathWidth, $path.Length)
        @{ Name = $tool.Name; Status = $(if ($command) { 'installed' } else { 'uninstalled' }); Path = $path; Description = $tool.Description }
    })
    Write-CliToolHeader -WithDescription
    foreach ($row in $rows) { Write-CliToolRow @row }
    return
}

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
Write-CliToolHeader
$script:ToolRowPending = $false
$global:LASTEXITCODE = 0
$failed = [Collections.Generic.List[string]]::new()
foreach ($tool in $selected) {
    try {
        if ($Uninstall) {
            Uninstall-CliTool -Tool $tool -Destination $Dir
            continue
        }
        Install-CliTool -Tool $tool -Destination $Dir -Force:$Update
    } catch {
        $failed.Add("$($tool.Name): $($_.Exception.Message)")
        $version = if ($tool.InstallVersion) { $tool.InstallVersion } else { '-' }
        Write-CliToolRow -Name $tool.Name -Version $version -Status failed
    }
}

if ($failed.Count -gt 0) {
    $global:LASTEXITCODE = 1
    Write-UpwshStatus failed ($failed -join '; ')
}

if (-not $Uninstall) {
    $resolvedDir = [IO.Path]::GetFullPath($Dir)
    $onPath = $false
    foreach ($entry in @($env:PATH -split ';')) {
        if ([string]::IsNullOrWhiteSpace($entry)) { continue }
        try {
            if ([IO.Path]::GetFullPath($entry) -eq $resolvedDir) {
                $onPath = $true
                break
            }
        } catch {
        }
    }
    if (-not $onPath) {
        Write-UpwshStatus warn 'tool bin is not on PATH'
    }
}
