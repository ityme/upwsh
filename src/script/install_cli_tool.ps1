# 由 upwsh tool 调用。可执行文件装到 $UPWSH_HOME\tool\bin。
#   upwsh tool list
#   upwsh tool install eza rg
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
    @{ Name = 'bat'; Repo = 'sharkdp/bat'; Exe = 'bat.exe' }
    @{ Name = 'btm'; Repo = 'ClementTsang/bottom'; Exe = 'btm.exe' }
    @{ Name = 'delta'; Repo = 'dandavison/delta'; Exe = 'delta.exe' }
    @{ Name = 'dust'; Repo = 'bootandy/dust'; Exe = 'dust.exe' }
    @{ Name = 'eza'; Repo = 'eza-community/eza'; Exe = 'eza.exe' }
    @{ Name = 'fd'; Repo = 'sharkdp/fd'; Exe = 'fd.exe' }
    @{ Name = 'fzf'; Repo = 'junegunn/fzf'; Exe = 'fzf.exe' }
    @{ Name = 'hyperfine'; Repo = 'sharkdp/hyperfine'; Exe = 'hyperfine.exe' }
    @{ Name = 'jq'; Repo = 'jqlang/jq'; Exe = 'jq.exe' }
    @{ Name = 'lazygit'; Repo = 'jesseduffield/lazygit'; Exe = 'lazygit.exe' }
    @{ Name = 'procs'; Repo = 'dalance/procs'; Exe = 'procs.exe' }
    @{ Name = 'rg'; Repo = 'BurntSushi/ripgrep'; Exe = 'rg.exe' }
    @{ Name = 'shfmt'; Repo = 'mvdan/sh'; Exe = 'shfmt.exe' }
    @{ Name = 'starship'; Repo = 'starship/starship'; Exe = 'starship.exe' }
    @{ Name = 'tssh'; Repo = 'trzsz/trzsz-ssh'; Exe = 'tssh.exe' }
    @{ Name = 'yazi'; Repo = 'sxyazi/yazi'; Exe = 'yazi.exe' }
    @{ Name = 'yq'; Repo = 'mikefarah/yq'; Exe = 'yq.exe' }
    @{ Name = 'zoxide'; Repo = 'ajeetdsouza/zoxide'; Exe = 'zoxide.exe' }
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
            'User-Agent' = 'unixify-powershell-installer'
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

function Write-CliToolListLine {
    param([string]$Name, [bool]$Installed)

    $reset = $PSStyle.Reset
    if ($Installed) {
        $mark = "$($PSStyle.Foreground.Green)+$reset"
        $state = "$($PSStyle.Foreground.Green)installed$reset"
    } else {
        $mark = "$($PSStyle.Foreground.Yellow)-$reset"
        $state = "$($PSStyle.Foreground.Yellow)uninstalled$reset"
    }
    Write-Output ("{0} {1,-10} {2}" -f $mark, $Name, $state)
}

function Uninstall-CliTool {
    param($Tool, [string]$Destination)

    $target = Join-Path $Destination $Tool.Exe
    if (-not (Test-Path -LiteralPath $target)) {
        Write-UpwshStatus skip "$($Tool.Name)  missing"
        return
    }
    Remove-Item -LiteralPath $target -Force
    Write-UpwshStatus ok "$($Tool.Name)  removed"
}

function Install-CliTool {
    param($Tool, [string]$Destination, [switch]$Force)

    $target = Join-Path $Destination $Tool.Exe
    if (-not $Force -and (Test-Path -LiteralPath $target)) {
        Write-UpwshStatus skip "$($Tool.Name)  already installed"
        return
    }

    $release = Get-GitHubLatestRelease -Repo $Tool.Repo
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
        Write-UpwshStatus get "$($Tool.Name)  $($release.tag_name)  $($asset.name)"
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
        Write-UpwshStatus ok "$($Tool.Name)  $target"
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

if ($List) {
    foreach ($tool in $selected) {
        Write-CliToolListLine `
            -Name $tool.Name `
            -Installed:(Test-CliToolCommand $tool.Name)
    }
    return
}

New-Item -ItemType Directory -Path $Dir -Force | Out-Null
Write-UpwshStatus dir $Dir
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
        Write-UpwshStatus error "$($tool.Name)  $($_.Exception.Message)"
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
