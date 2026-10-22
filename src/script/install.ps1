# 安装或修复 ~/.config/upwsh，然后 load。
#   irm https://github.com/ityme/upwsh/raw/main/src/script/install.ps1 | iex
#   pwsh -NoLogo -NoProfile -File src/script/install.ps1

$script:SavedErrorActionPreference = $ErrorActionPreference
$ErrorActionPreference = 'Stop'
$script:Arguments = @($args)
$script:DefaultRepo = 'ityme/upwsh'
$script:DefaultRef = 'main'
$script:UserAgent = 'upwsh-installer'
$script:UpdateOnly = $UpwshSetupMode -eq 'update'

function Get-InstallUsage {
    @'
usage: install.ps1 [-h | --help] [-c | --check]
                   [--local | --remote] [--source <dir>]
                   [--ref <ref>] [--repo <owner/name>]

These are common install.ps1 commands used in various situations:

install this runtime
   --local          Use the local project at the current directory or script location
   --remote         Download the runtime; default for irm | iex
   --source         Local source tree, skip download
   --ref            Git branch or tag to download
   --repo           GitHub repository, default ityme/upwsh

inspect without writing
   --check          Show installation status without copying files

A network install can run:

  irm https://github.com/ityme/upwsh/raw/main/src/script/install.ps1 | iex

Environment: UPWSH_REF UPWSH_REPO UPWSH_SOURCE
Install or repair ~/.config/upwsh. UPWSH_HOME records this fixed location.
Install then loads the current pwsh. Install and update default to --remote; use --local for a project source.
The upwsh command is UPWSH_HOME\\bin\\upwsh.cmd.
CLI tools go in UPWSH_HOME\\tool\\bin.
After install, missing eza, dust, or btm are listed with upwsh tool install.
'@
}

function New-InstallParseResult {
    [pscustomobject]@{
        Help   = $false
        Error  = $null
        Check  = $false
        Local  = $false
        Remote = $false
        Ref    = $null
        Repo   = $null
        Source   = $null
        SkipLoad = $false
    }
}

function ConvertFrom-InstallArguments {
    param([object[]]$Tokens)

    $tokens = @(
        $Tokens |
            Where-Object { $_ -ne $null -and [string]$_ -ne '' }
    )
    $result = New-InstallParseResult
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
            '^--local$' {
                $result.Local = $true
                $index++
            }
            '^--remote$' {
                $result.Remote = $true
                $index++
            }
            '^--ref$' {
                if ($index + 1 -ge $tokens.Count) {
                    $result.Help = $true
                    $result.Error = 'missing ref'
                    return $result
                }
                $result.Ref = [string]$tokens[$index + 1]
                $index += 2
            }
            '^--repo$' {
                if ($index + 1 -ge $tokens.Count) {
                    $result.Help = $true
                    $result.Error = 'missing repo'
                    return $result
                }
                $result.Repo = [string]$tokens[$index + 1]
                $index += 2
            }
            '^--source$' {
                if ($index + 1 -ge $tokens.Count) {
                    $result.Help = $true
                    $result.Error = 'missing source directory'
                    return $result
                }
                $result.Source = [string]$tokens[$index + 1]
                $index += 2
            }
            '^--skip-load$' {
                $result.SkipLoad = $true
                $index++
            }
            default {
                $result.Help = $true
                $result.Error = "unknown option: $token"
                return $result
            }
        }
    }

    if ($result.Local -and $result.Remote) {
        $result.Help = $true
        $result.Error = 'use only one of --local or --remote'
    }
    if ($result.Remote -and $result.Source) {
        $result.Help = $true
        $result.Error = 'use only one of --remote or --source'
    }
    if ($result.Local -and ($result.Ref -or $result.Repo)) {
        $result.Help = $true
        $result.Error = '--local cannot be used with --ref or --repo'
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

function Test-CommandToolPresent {
    param([string]$Name, [string]$ToolBin)

    if ([IO.File]::Exists((Join-Path $ToolBin "$Name.exe"))) {
        return $true
    }
    $null -ne (Get-Command -Name $Name -CommandType Application -ErrorAction SilentlyContinue)
}

function Get-MissingCommandToolHint {
    param([string]$InstallHome)

    $toolBin = Join-Path $InstallHome 'tool\bin'
    $savedPath = $env:PATH
    try {
        if ([IO.Directory]::Exists($toolBin) -and $savedPath -notlike "*$toolBin*") {
            $env:PATH = $toolBin + ';' + $savedPath
        }
        $missing = @(
            @('eza', 'dust', 'btm') |
                Where-Object { -not (Test-CommandToolPresent -Name $_ -ToolBin $toolBin) }
        )
    } finally {
        $env:PATH = $savedPath
    }
    if ($missing.Count -eq 0) {
        return @()
    }
    Write-Output ''
    Write-UpwshStatus missing ($missing -join ', ') next ('upwsh tool install ' + ($missing -join ' '))
}

function Get-DefaultDestination {
    [IO.Path]::GetFullPath((Join-Path $HOME '.config\upwsh'))
}

function Test-RuntimeRoot {
    param([string]$Path)

    if (-not $Path) {
        return $false
    }
    (Test-Path -LiteralPath (Join-Path $Path 'profile.ps1') -PathType Leaf) -and
        (Test-Path -LiteralPath (Join-Path $Path 'script\install_profile.ps1') -PathType Leaf)
}

function Resolve-RuntimeRoot {
    param([string]$Path)

    $full = [IO.Path]::GetFullPath($Path)
    if (Test-RuntimeRoot $full) {
        return $full
    }

    $src = Join-Path $full 'src'
    if (Test-RuntimeRoot $src) {
        return [IO.Path]::GetFullPath($src)
    }

    $dirs = @(Get-ChildItem -LiteralPath $full -Directory -ErrorAction SilentlyContinue)
    if ($dirs.Count -eq 1) {
        return Resolve-RuntimeRoot $dirs[0].FullName
    }

    throw "missing profile.ps1 under $full"
}

function Get-LocalScriptRoot {
    if ($PSScriptRoot) {
        return $PSScriptRoot
    }
    if ($PSCommandPath) {
        return Split-Path -Parent $PSCommandPath
    }
    return $null
}

function Get-LocalProjectRuntimeRoot {
    $starts = @()
    if ((Get-Location).Provider.Name -eq 'FileSystem') {
        $starts += (Get-Location).ProviderPath
    }
    $starts += Get-LocalScriptRoot
    foreach ($start in $starts) {
        $current = $start
        while ($current) {
            $src = Join-Path $current 'src'
            if (
                (Test-RuntimeRoot $src) -and
                (Test-Path -LiteralPath (Join-Path $src 'script\upwsh.ps1') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $current 'README.md') -PathType Leaf)
            ) {
                return [IO.Path]::GetFullPath($src)
            }
            $parent = Split-Path -Parent $current
            if (-not $parent -or $parent -eq $current) {
                break
            }
            $current = $parent
        }
    }
    return $null
}

function Get-GitHubHeaders {
    @{
        'User-Agent' = $script:UserAgent
        Accept       = 'application/vnd.github+json'
    }
}

function Get-LatestReleaseZipUri {
    param([string]$Repo)

    $release = Invoke-RestMethod `
        -Uri "https://api.github.com/repos/$Repo/releases/latest" `
        -Headers (Get-GitHubHeaders)
    $asset = @(
        $release.assets |
            Where-Object { $_.name -like '*.zip' -and $_.browser_download_url }
    )[0]
    if (-not $asset) {
        throw "release has no zip: $Repo"
    }
    $asset.browser_download_url
}

function Get-ArchiveZipUri {
    param([string]$Repo, [string]$Ref)

    $encoded = [uri]::EscapeDataString($Ref)
    if ($Ref -match '^v\d' -or $Ref -like 'refs/tags/*') {
        $tag = $Ref -replace '^refs/tags/', ''
        return "https://github.com/$Repo/archive/refs/tags/$([uri]::EscapeDataString($tag)).zip"
    }
    "https://github.com/$Repo/archive/refs/heads/$encoded.zip"
}

function Save-Uri {
    param([string]$Uri, [string]$Path)

    Invoke-WebRequest `
        -Uri $Uri `
        -OutFile $Path `
        -Headers @{ 'User-Agent' = $script:UserAgent } `
        -UseBasicParsing |
        Out-Null
}

function Get-DownloadedRuntime {
    param(
        [string]$Repo,
        [string]$Ref
    )

    $work = Join-Path ([IO.Path]::GetTempPath()) (
        'upwsh-' + [Guid]::NewGuid().ToString('N')
    )
    New-Item -ItemType Directory -Path $work -Force | Out-Null
    try {
        $zip = Join-Path $work 'source.zip'
        $extract = Join-Path $work 'extract'
        New-Item -ItemType Directory -Path $extract -Force | Out-Null

        $uris = [Collections.Generic.List[string]]::new()
        if ($Ref) {
            $uris.Add((Get-ArchiveZipUri -Repo $Repo -Ref $Ref)) | Out-Null
        } else {
            try {
                $uris.Add((Get-LatestReleaseZipUri -Repo $Repo)) | Out-Null
            } catch {
                $uris.Add((Get-ArchiveZipUri -Repo $Repo -Ref $script:DefaultRef)) | Out-Null
            }
        }

        $saved = $false
        $lastError = $null
        foreach ($uri in $uris) {
            try {
                Save-Uri -Uri $uri -Path $zip
                $saved = $true
                break
            } catch {
                $lastError = $_
            }
        }
        if (-not $saved) {
            throw "download failed: $($lastError.Exception.Message)"
        }

        Expand-Archive -LiteralPath $zip -DestinationPath $extract -Force
        [pscustomobject]@{
            Root = (Resolve-RuntimeRoot $extract)
            Work = $work
        }
    } catch {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
        throw
    }
}

function Test-InstallFileEntry {
    if (-not $PSCommandPath) {
        return $false
    }
    $cli = [Environment]::GetCommandLineArgs()
    for ($index = 0; $index -lt $cli.Count; $index++) {
        $token = [string]$cli[$index]
        $candidate = $null
        if (($token -eq '-File' -or $token -eq '-f') -and $index + 1 -lt $cli.Count) {
            $candidate = [string]$cli[$index + 1]
        } elseif ($token -match '^-File:(.+)$') {
            $candidate = $Matches[1]
        }
        if ($candidate) {
            try {
                return [IO.Path]::GetFullPath($candidate) -eq $PSCommandPath
            } catch {
                return $false
            }
        }
    }
    return $false
}

function Complete-Install {
    param(
        [int]$Code,
        $Invocation = $MyInvocation
    )

    $ErrorActionPreference = $script:SavedErrorActionPreference
    $global:LASTEXITCODE = $Code
    if (Test-InstallFileEntry) {
        exit $Code
    }
}

$parsed = ConvertFrom-InstallArguments -Tokens $script:Arguments
$scriptInvocation = $MyInvocation
if ($parsed.Help) {
    if ($parsed.Error) {
        Write-Output "upwsh: $($parsed.Error)"
        Write-Output ''
    }
    Get-InstallUsage
    if ($parsed.Error) {
        Complete-Install 2 $scriptInvocation
        return
    }
    Complete-Install 0 $scriptInvocation
    return
}

if ($PSVersionTable.PSVersion.Major -lt 7) {
    Write-Output 'upwsh: need PowerShell 7'
    Complete-Install 1 $scriptInvocation
    return
}

$repo = if ($parsed.Repo) {
    $parsed.Repo
} elseif ($env:UPWSH_REPO) {
    $env:UPWSH_REPO
} else {
    $script:DefaultRepo
}
$ref = if ($parsed.Ref) { $parsed.Ref } elseif ($env:UPWSH_REF) { $env:UPWSH_REF } else { $null }
$source = if ($parsed.Source) {
    $parsed.Source
} elseif ($env:UPWSH_SOURCE) {
    $env:UPWSH_SOURCE
} else {
    $null
}
$directory = Get-DefaultDestination
$installed = [IO.File]::Exists((Join-Path $directory 'profile.ps1')) -or
    [IO.File]::Exists((Join-Path $directory 'script\upwsh.ps1'))
$workRoot = $null
try {
    if ($script:UpdateOnly -and -not $installed) {
        throw 'runtime is not installed; run upwsh install first'
    }
    if ($parsed.Check) {
        Write-UpwshStatus home $directory state $(if ($installed) { 'installed' } else { 'missing' })
        Complete-Install 0 $scriptInvocation
        return
    }
    $helper = if ($PSScriptRoot) { Join-Path $PSScriptRoot '_relaunch.ps1' } else { $null }
    if (-not $helper -or -not [IO.File]::Exists($helper)) {
        $helper = Join-Path $directory 'script\_relaunch.ps1'
    }
    if ([IO.File]::Exists($helper)) {
        . $helper
        Wait-UpwshRelaunchParent
        $entry = if ($script:UpdateOnly) { 'update.ps1' } else { 'install.ps1' }
        if (Start-UpwshRelaunchIfNeeded -InstallHome $directory -EntryName $entry -Arguments $script:Arguments) {
            Complete-Install $global:LASTEXITCODE $scriptInvocation
            return
        }
    }
    $wantRemote = -not $parsed.Local -and -not $source
    if ($parsed.Remote -or [bool]$ref -or [bool]$parsed.Repo -or [bool]$env:UPWSH_REPO) {
        $wantRemote = $true
    }
    $sibling = $null
    if (-not $source -and -not $wantRemote) {
        $sibling = Get-LocalProjectRuntimeRoot
    }
    if ($parsed.Local -and -not $source -and -not $sibling) {
        throw 'no local project found; run from the repository or pass --source'
    }
    if ($source) {
        $runtimeRoot = Resolve-RuntimeRoot (winpath $source)
    } elseif ($sibling -and -not $wantRemote) {
        $runtimeRoot = $sibling
    } else {
        $downloaded = Get-DownloadedRuntime -Repo $repo -Ref $ref
        $runtimeRoot = $downloaded.Root
        $workRoot = $downloaded.Work
    }

    if ([IO.Path]::GetFullPath($runtimeRoot).TrimEnd('\', '/') -ieq $directory.TrimEnd('\', '/')) {
        throw 'the installed runtime cannot be its own source; use a local project or a download'
    }

    # Use the implementation bundled with the chosen source, including standalone downloads.
    $deploy = Join-Path $runtimeRoot 'script\_deploy.ps1'
    if (-not [IO.File]::Exists($deploy)) { throw 'invalid runtime: missing script\_deploy.ps1' }
    . $deploy
    Install-UpwshRuntime -Source $runtimeRoot -Destination $directory
    $commandPath = Join-Path $directory 'lib\upwsh.psm1'
    if (-not $env:UPWSH_SKIP_SESSION_LOAD -and [IO.File]::Exists($commandPath)) {
        Import-Module $commandPath -Global -Force -DisableNameChecking
    }
    if (-not $script:UpdateOnly) {
        foreach ($line in @(Get-MissingCommandToolHint -InstallHome $directory)) {
            Write-Output $line
        }
        if (-not $parsed.SkipLoad) {
            $loader = Join-Path $directory 'script\upwsh.ps1'
            if (-not [IO.File]::Exists($loader)) {
                throw "missing $loader"
            }
            & $loader load
        }
    }
    Complete-Install 0 $scriptInvocation
} catch {
    Write-Output "upwsh: $($_.Exception.Message)"
    Complete-Install 1 $scriptInvocation
} finally {
    if ($workRoot -and (Test-Path -LiteralPath $workRoot)) {
        Remove-Item -LiteralPath $workRoot -Recurse -Force -ErrorAction SilentlyContinue
    }
}
