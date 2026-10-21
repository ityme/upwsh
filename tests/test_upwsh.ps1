$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    Invoke-UpwshIsolatedTest -File $PSCommandPath
    exit $LASTEXITCODE
}

$upwsh = Join-Path $PSScriptRoot '..\src\script\upwsh.ps1'
$sourceProfile = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..\src\profile.ps1'))
$root = Join-Path ([IO.Path]::GetTempPath()) (
    'pwsh-upwsh-' + [Guid]::NewGuid().ToString('N')
)
$installHome = Join-Path $HOME '.config\upwsh'
$installedProfile = Join-Path $installHome 'profile.ps1'
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()

function Invoke-UpwshTest {
    param(
        [string]$Name,
        [scriptblock]$Body
    )

    try {
        & $Body
        $script:Passed++
    } catch {
        $script:Failures.Add("$Name`n  $($_.Exception.Message)")
    }
}

function Assert-Equal {
    param(
        [AllowNull()][object]$Actual,
        [AllowNull()][object]$Expected
    )

    if ([string]$Actual -cne [string]$Expected) {
        throw "expected '$Expected', got '$Actual'"
    }
}

function Assert-True {
    param(
        [bool]$Condition,
        [string]$Message
    )

    if (-not $Condition) {
        throw $Message
    }
}

function Assert-Contains {
    param(
        [string]$Text,
        [string]$Expected
    )

    if ($Text -notlike "*${Expected}*") {
        throw "expected '$Expected' in '$Text'"
    }
}

function Invoke-Upwsh {
    param(
        [string[]]$Tokens = @(),
        [switch]$LoadSession,
        [switch]$ViaFunction
    )

    $previous = $global:LASTEXITCODE
    $savedHome = $env:UPWSH_HOME
    $savedProfile = $env:UPWSH_PROFILE
    $savedSkip = $env:UPWSH_SKIP_PERSIST_PATH
    $savedSkipSession = $env:UPWSH_SKIP_SESSION_LOAD
    $savedPath = $env:PATH
    try {
        $env:UPWSH_HOME = Split-Path -Parent $sourceProfile
        $env:UPWSH_PROFILE = Join-Path $root 'profile.ps1'
        $env:UPWSH_SKIP_PERSIST_PATH = '1'
        if ($LoadSession) {
            Remove-Item Env:\UPWSH_SKIP_SESSION_LOAD -ErrorAction SilentlyContinue
        } else {
            $env:UPWSH_SKIP_SESSION_LOAD = '1'
        }
        $global:LASTEXITCODE = 0
        if ($ViaFunction) {
            $output = & {
                function upwsh { & $upwsh @args }
                upwsh @Tokens
            } 2>&1 | Out-String
        } else {
            $output = & $upwsh @Tokens 2>&1 | Out-String
        }
        [pscustomobject]@{
            Text = $output
            Code = $global:LASTEXITCODE
            Path = $env:PATH
        }
    } finally {
        $global:LASTEXITCODE = $previous
        $env:UPWSH_HOME = $savedHome
        $env:UPWSH_PROFILE = $savedProfile
        $env:UPWSH_SKIP_PERSIST_PATH = $savedSkip
        $env:UPWSH_SKIP_SESSION_LOAD = $savedSkipSession
        $env:PATH = $savedPath
    }
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $hook = Join-Path $root 'profile.ps1'
    $bin = Join-Path $installHome 'bin'
    $toolBin = Join-Path $installHome 'tool\bin'
    New-Item -ItemType Directory -Path $bin, $toolBin -Force | Out-Null
    $shim = Join-Path $bin 'upwsh.cmd'

    Invoke-UpwshTest 'no args prints usage' {
        $result = Invoke-Upwsh
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'upwsh'
        Assert-Contains $result.Text 'load'
        Assert-Contains $result.Text 'unload'
        Assert-Contains $result.Text 'tool install'
        Assert-Contains $result.Text 'tool uninstall'
        Assert-Contains $result.Text 'tool list'
        Assert-Contains $result.Text 'tool update'
        Assert-Contains $result.Text '   install'
        Assert-Contains $result.Text '   uninstall'
        Assert-Contains $result.Text '   update'
        Assert-Contains $result.Text '   edit'
        Assert-True ($result.Text -cnotmatch '--profile') 'help still lists --profile'
        Assert-True ($result.Text -cnotmatch '--check') 'help still lists --check'
        Assert-True ($result.Text -cnotmatch '--deploy') 'help still lists --deploy'
        Assert-True ($result.Text -cnotmatch '--force') 'help still lists --force'
        Assert-True ($result.Text -cnotmatch '--only') 'help still lists --only'
        Assert-True ($result.Text -cnotmatch '--current-host') 'help still lists --current-host'
    }

    Invoke-UpwshTest 'help flag prints usage' {
        $result = Invoke-Upwsh -Tokens @('--help')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'These are common upwsh commands'
        $result = Invoke-Upwsh -Tokens @('-h')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text "hook the current user's pwsh"
    }

    Invoke-UpwshTest 'unknown option prints usage and exits 2' {
        $result = Invoke-Upwsh -Tokens @('--nope')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option'
        Assert-True ($result.Text -cnotmatch 'These are common upwsh commands') 'error printed full help'
    }

    Invoke-UpwshTest 'load and tool together is an error' {
        $result = Invoke-Upwsh -Tokens @('load', 'tool')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'use only one of load, unload, tool, theme, install, uninstall, update, or edit'
    }

    Invoke-UpwshTest 'load and unload together is an error' {
        $result = Invoke-Upwsh -Tokens @('load', 'unload')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'use only one of load, unload, tool, theme, install, uninstall, update, or edit'
    }

    Invoke-UpwshTest 'edit extra arguments are rejected' {
        $result = Invoke-Upwsh -Tokens @('edit', 'user-settings.ps1')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option'
    }

    Invoke-UpwshTest 'edit before install fails' {
        $result = Invoke-Upwsh -Tokens @('edit')
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'user-settings.ps1 is not installed'
    }

    Invoke-UpwshTest 'load before install fails without writing a hook' {
        $failed = $false
        try { Invoke-Upwsh -Tokens @('load') | Out-Null } catch { $failed = $true }
        Assert-True $failed 'load unexpectedly used the source tree'
        Assert-True (-not (Test-Path -LiteralPath $hook)) 'failed load wrote a hook'
    }

    Invoke-UpwshTest 'install deploys and loads' {
        $result = Invoke-Upwsh -Tokens @('install')
        Assert-Equal $result.Code 0
        Assert-True (Test-Path -LiteralPath $installedProfile) 'install missed runtime'
        Assert-Contains $result.Text 'command   upwsh'
        Assert-Contains $result.Text 'state     installed'
        $text = [IO.File]::ReadAllText($hook)
        Assert-Contains $text '# >>> unixify-powershell >>>'
        Assert-Contains $text $installedProfile
    }

    Invoke-UpwshTest 'install through the loaded upwsh function completes after session load' {
        $result = Invoke-Upwsh -Tokens @('install') -LoadSession -ViaFunction
        Assert-Equal $result.Code 0
        Assert-True ($result.Text -notmatch 'Get-MissingCommandToolHint') 'install leaked the post-load helper error'
        Assert-True ($result.Text -notmatch 'Complete-Install') 'install leaked the completion helper error'
        Assert-Contains $result.Text 'state     installed'
    }

    Invoke-UpwshTest 'edit opens user-settings.ps1 in nvim' {
        $stub = Join-Path $root 'edit-nvim'
        New-Item -ItemType Directory -Path $stub -Force | Out-Null
        $log = Join-Path $stub 'called.txt'
        Set-Content -LiteralPath (Join-Path $stub 'nvim.cmd') -Value "@echo off`r`necho %*>`"$log`"`r`nexit /b 0"
        $savedPath = $env:PATH
        try {
            $env:PATH = $stub
            $result = Invoke-Upwsh -Tokens @('edit')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'user-settings.ps1'
            Assert-Contains $result.Text 'nvim'
            Assert-Contains ([IO.File]::ReadAllText($log)) (Join-Path $installHome 'user-settings.ps1')
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'edit falls back to vim when nvim is missing' {
        $stub = Join-Path $root 'edit-vim'
        New-Item -ItemType Directory -Path $stub -Force | Out-Null
        $log = Join-Path $stub 'called.txt'
        Set-Content -LiteralPath (Join-Path $stub 'vim.cmd') -Value "@echo off`r`necho %*>`"$log`"`r`nexit /b 0"
        $savedPath = $env:PATH
        try {
            $env:PATH = $stub
            $result = Invoke-Upwsh -Tokens @('edit')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'vim'
            Assert-Contains ([IO.File]::ReadAllText($log)) (Join-Path $installHome 'user-settings.ps1')
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'edit fails when nvim and vim are missing' {
        $savedPath = $env:PATH
        try {
            $env:PATH = Join-Path $root 'edit-empty'
            New-Item -ItemType Directory -Path $env:PATH -Force | Out-Null
            $result = Invoke-Upwsh -Tokens @('edit')
            Assert-Equal $result.Code 1
            Assert-Contains $result.Text 'nvim is not on PATH'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'edit reloads user-settings in this session' {
        $stub = Join-Path $root 'edit-reload'
        New-Item -ItemType Directory -Path $stub -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $stub 'nvim.cmd') -Value "@echo off`r`nexit /b 0"
        [IO.File]::WriteAllText(
            (Join-Path $installHome 'user-settings.ps1'),
            'Set-Alias -Name edited_only -Value Get-Date -Scope Global -Force'
        )
        $savedPath = $env:PATH
        try {
            $env:PATH = $stub
            $result = Invoke-Upwsh -LoadSession -Tokens @('edit')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'state     loaded'
            Assert-True ($result.Text -notlike '*Import-ShellModule*') 'edit reloaded profile in a nested function scope'
            Assert-True ($result.Text -notlike '*Complete-Upwsh*') 'edit lost script-scope helpers'
            Assert-Equal (Get-Command edited_only -ErrorAction Stop).Definition 'Get-Date'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'load hooks the installed profile' {
        $result = Invoke-Upwsh -Tokens @('load')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'state     installed'
        Assert-Contains $result.Text $hook
        Assert-Contains $result.Text $installedProfile
        Assert-True (-not $result.Text.Contains('path      ')) 'load wrote persistent Path'
        Assert-True (-not $result.Text.Contains('cmd       ')) 'load rewrote shim'
        Assert-True (Test-Path -LiteralPath $shim -PathType Leaf) 'load removed installed shim'
        $text = [IO.File]::ReadAllText($hook)
        Assert-Contains $text '# >>> unixify-powershell >>>'
        Assert-Contains $text $installedProfile
        Assert-True (-not $text.Contains($sourceProfile)) 'load hooked source tree'
    }

    Invoke-UpwshTest 'load does not recreate a missing shim or change the user environment' {
        $beforeShim = [IO.File]::ReadAllBytes($shim)
        [IO.File]::Delete($shim)
        try {
            $result = Invoke-Upwsh -Tokens @('load')
            Assert-Equal $result.Code 0
            Assert-True (-not (Test-Path -LiteralPath $shim)) 'load repaired shim instead of only enabling'
        } finally { [IO.File]::WriteAllBytes($shim, $beforeShim) }
    }

    Invoke-UpwshTest 'legacy load short flag is rejected' {
        $result = Invoke-Upwsh -Tokens @('-l')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option'
    }

    Invoke-UpwshTest 'load again reports installed' {
        $result = Invoke-Upwsh -Tokens @('load')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'state     installed'
    }

    Invoke-UpwshTest 'status lines stay plain when output is captured' {
        $result = Invoke-Upwsh -Tokens @('install', '--help')
        Assert-Equal $result.Code 0
        Assert-True ($result.Text -notmatch '\x1b\[') 'help output contained ANSI color'
        $loaded = Invoke-Upwsh -Tokens @('load')
        Assert-True ($loaded.Text -notmatch '\x1b\[') 'load output contained ANSI color'
    }

    Invoke-UpwshTest 'windows amd64 asset matching accepts eza gnu zip' {
        $tools = Join-Path $PSScriptRoot '..\src\script\install_cli_tool.ps1'
        $parser = [Management.Automation.Language.Parser]::ParseFile($tools, [ref]$null, [ref]$null)
        $fn = $parser.EndBlock.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'Test-WindowsAmd64Asset'
            }, $true)
        Assert-True ($null -ne $fn) 'missing Test-WindowsAmd64Asset'
        Invoke-Expression $fn.Extent.Text
        Assert-True (Test-WindowsAmd64Asset 'eza.exe_x86_64-pc-windows-gnu.zip') 'rejected eza windows gnu zip'
        Assert-True (-not (Test-WindowsAmd64Asset 'eza_x86_64-unknown-linux-gnu.zip')) 'accepted linux gnu zip'
        Assert-True (-not (Test-WindowsAmd64Asset 'eza_aarch64-unknown-linux-gnu.zip')) 'accepted aarch64 zip'
        Assert-True (Test-WindowsAmd64Asset 'bat-x86_64-pc-windows-msvc.zip') 'rejected msvc zip'
        Assert-True (Test-WindowsAmd64Asset 'lazygit_0.65.1_windows_x86_64.zip') 'rejected lazygit amd64 zip'
        Assert-True (-not (Test-WindowsAmd64Asset 'lazygit_0.65.1_windows_32-bit.zip')) 'accepted lazygit 32-bit zip'
        Assert-True (-not (Test-WindowsAmd64Asset 'tssh_0.1.26_windows_i386.zip')) 'accepted tssh i386 zip'
    }

    Invoke-UpwshTest 'tool install requires names or --all' {
        $missing = Invoke-Upwsh -Tokens @('tool', 'install')
        Assert-Equal $missing.Code 2
        Assert-Contains $missing.Text 'tool install <name>'
        $all = Invoke-Upwsh -Tokens @('tool', 'install', '--all', '--check')
        Assert-Equal $all.Code 2
        Assert-Contains $all.Text 'unknown option'
        $both = Invoke-Upwsh -Tokens @('tool', 'install', 'eza', '--all')
        Assert-Equal $both.Code 2
        Assert-Contains $both.Text 'use names or --all'
    }

    Invoke-UpwshTest 'tool update requires names or --all' {
        $missing = Invoke-Upwsh -Tokens @('tool', 'update')
        Assert-Equal $missing.Code 2
        Assert-Contains $missing.Text 'tool update <name>'
        $all = Invoke-Upwsh -Tokens @('tool', 'update', '--all', '--check')
        Assert-Equal $all.Code 2
        Assert-Contains $all.Text 'unknown option'
        $both = Invoke-Upwsh -Tokens @('tool', 'update', 'eza', '--all')
        Assert-Equal $both.Code 2
        Assert-Contains $both.Text 'use names or --all'
    }

    Invoke-UpwshTest 'lifecycle options are validated before delegation' {
        $result = Invoke-Upwsh -Tokens @('update', '--nope')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option'
        $missing = Invoke-Upwsh -Tokens @('install', '--source')
        Assert-Equal $missing.Code 2
        Assert-Contains $missing.Text 'missing value for --source'
        $conflict = Invoke-Upwsh -Tokens @('install', '--local', '--remote')
        Assert-Equal $conflict.Code 2
        Assert-Contains $conflict.Text 'use only one of --local or --remote'
    }

    Invoke-UpwshTest 'load -u is unknown' {
        $result = Invoke-Upwsh -Tokens @('load', '-u')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option: -u'
    }

    Invoke-UpwshTest 'unload removes the hook' {
        $result = Invoke-Upwsh -Tokens @('unload')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'state     removed'
        Assert-True ($result.Text -notlike '*home      removed*') 'unload removed UPWSH_HOME'
        Assert-True ($result.Text -notlike '*path      removed*') 'unload removed Path'
        Assert-True (Test-Path -LiteralPath $shim -PathType Leaf) 'unload deleted upwsh.cmd'
        $text = [IO.File]::ReadAllText($hook)
        Assert-True ($text -notlike '*unixify-powershell*') "unload left the marker:`n$text"
    }

    Invoke-UpwshTest 'tool options are rejected on load' {
        $result = Invoke-Upwsh -Tokens @('load', '--force')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option: --force'
    }

    Invoke-UpwshTest 'load --profile is unknown' {
        $result = Invoke-Upwsh -Tokens @('load', '--profile', $hook)
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown option: --profile'
    }

    Invoke-UpwshTest 'tool without a command prints usage' {
        $result = Invoke-Upwsh -Tokens @('tool')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'missing tool command'
    }

    Invoke-UpwshTest 'tool uninstall without a name prints usage' {
        $result = Invoke-Upwsh -Tokens @('tool', 'uninstall')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'tool uninstall <name>'
    }

    Invoke-UpwshTest 'unknown tool command prints usage' {
        $result = Invoke-Upwsh -Tokens @('tool', '--deploy')
        Assert-Equal $result.Code 2
        Assert-Contains $result.Text 'unknown tool command: --deploy'
    }

    Invoke-UpwshTest 'tool --all is parsed without treating it as a tool name' {
        $parser = [Management.Automation.Language.Parser]::ParseFile($upwsh, [ref]$null, [ref]$null)
        $newResult = $parser.EndBlock.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'New-UpwshParseResult'
            }, $true)
        $convert = $parser.EndBlock.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -eq 'ConvertFrom-UpwshArguments'
            }, $true)
        Assert-True ($null -ne $newResult) 'missing New-UpwshParseResult'
        Assert-True ($null -ne $convert) 'missing ConvertFrom-UpwshArguments'
        Invoke-Expression $newResult.Extent.Text
        Invoke-Expression $convert.Extent.Text
        $installAll = ConvertFrom-UpwshArguments -Tokens @('tool', 'install', '--all')
        Assert-Equal $installAll.Action 'install'
        Assert-True ([bool]$installAll.All) 'install --all did not set All'
        Assert-Equal $installAll.Only.Count 0
        Assert-True (-not $installAll.Help) 'install --all parsed as help'
        $updateAll = ConvertFrom-UpwshArguments -Tokens @('tool', 'update', '--all')
        Assert-Equal $updateAll.Action 'update'
        Assert-True ([bool]$updateAll.All) 'update --all did not set All'
        Assert-Equal $updateAll.Only.Count 0
        $listAll = ConvertFrom-UpwshArguments -Tokens @('tool', 'list', '--all')
        Assert-True $listAll.Help 'list --all did not fail'
        $uninstallAll = ConvertFrom-UpwshArguments -Tokens @('tool', 'uninstall', '--all')
        Assert-True $uninstallAll.Help 'uninstall --all did not fail'
    }

    Invoke-UpwshTest 'install help is forwarded' {
        $result = Invoke-Upwsh -Tokens @('install', '--help')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'install.ps1'
    }

    Invoke-UpwshTest 'uninstall help is forwarded' {
        $result = Invoke-Upwsh -Tokens @('uninstall', '--help')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'uninstall.ps1'
    }

    Invoke-UpwshTest 'update help is forwarded' {
        $result = Invoke-Upwsh -Tokens @('update', '--help')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'update.ps1'
    }

    Invoke-UpwshTest 'tool uninstall removes a named exe' {
        $exe = Join-Path $toolBin 'eza.exe'
        [IO.File]::WriteAllText($exe, 'stub')
        $result = Invoke-Upwsh -Tokens @(
            'tool', 'uninstall', 'eza'
        )
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'removed'
        Assert-True (-not (Test-Path -LiteralPath $exe)) "uninstall left $exe"
    }

    Invoke-UpwshTest 'tool list names limit the list' {
        $savedPath = $env:PATH
        try {
            $env:PATH = $toolBin
            $result = Invoke-Upwsh -Tokens @('tool', 'list', 'eza')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'eza'
            Assert-Contains $result.Text 'uninstalled'
            Assert-True ($result.Text -notmatch 'bat') 'tool list leaked extra tools'
            Assert-True ($result.Text -notmatch 'dir') 'tool list printed install dir'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'tool list reports a command on PATH' {
        $exe = Join-Path $toolBin 'eza.exe'
        [IO.File]::WriteAllText($exe, 'stub')
        $savedPath = $env:PATH
        try {
            $env:PATH = $toolBin
            $result = Invoke-Upwsh -Tokens @('tool', 'list', 'eza')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'eza'
            Assert-Contains $result.Text 'installed'
            Assert-True ($result.Text -notmatch 'uninstalled') 'tool list missed an on-PATH command'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'tool short flags list the upwsh tools' {
        $savedPath = $env:PATH
        try {
            $env:PATH = $toolBin
            $result = Invoke-Upwsh -Tokens @('tool', 'list', 'rg')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text 'rg'
            Assert-Contains $result.Text 'uninstalled'
        } finally {
            $env:PATH = $savedPath
        }
    }

    Invoke-UpwshTest 'install defines upwsh and loads the prompt' {
        $result = Invoke-Upwsh -LoadSession -Tokens @('install')
        Assert-Equal $result.Code 0
        Assert-Equal (Get-Command upwsh -ErrorAction Stop).CommandType.ToString() 'Function'
        Assert-True ((Get-Command prompt).Definition -like '*Get-UpwshThemeRevision*') 'install did not load the prompt'
        $unloaded = Invoke-Upwsh -LoadSession -Tokens @('uninstall')
        Assert-Equal $unloaded.Code 0
        Assert-True ((Get-Command prompt).Definition -notlike '*Get-UpwshThemeRevision*') 'uninstall left the theme prompt'
        $reloaded = Invoke-Upwsh -LoadSession -Tokens @('install')
        Assert-Equal $reloaded.Code 0
        Assert-True ((Get-Command prompt).Definition -like '*Get-UpwshThemeRevision*') 'reinstall did not restore the theme prompt'
    }

    Invoke-UpwshTest 'load applies only the installed runtime in this session' {
        $sentinel = Join-Path $installHome 'user-settings.ps1'
        [IO.File]::WriteAllText($sentinel, 'Set-Alias -Name installed_only -Value Get-Date -Scope Global -Force')
        $result = Invoke-Upwsh -LoadSession -Tokens @('load')
        Assert-Equal $result.Code 0
        Assert-True ($result.Text -notlike '*Import-ShellModule*') 'load lost Import-ShellModule'
        Assert-Equal (Get-Command installed_only -ErrorAction Stop).Definition 'Get-Date'
        Assert-True ((Get-Command prompt).Definition -like '*Get-UpwshThemeRevision*') 'load did not enable the prompt'
        $command = Get-Command vim -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Alias'
        Assert-Equal $command.Definition 'nvim'
        Assert-True ($result.Path -like "*$bin*") 'load did not add bin to PATH'
        Assert-True ($result.Path -like "*$toolBin*") 'load did not add tool\\bin to PATH'
        Assert-True (Test-Path -LiteralPath $shim -PathType Leaf) 'session load missed upwsh.cmd'
        Assert-True ($null -eq (Get-Command tool -CommandType Function, Alias -ErrorAction SilentlyContinue)) 'load defined tool'
        Assert-True ($null -eq (Get-Command tools -CommandType Function, Alias -ErrorAction SilentlyContinue)) 'load defined tools'
    }

    Invoke-UpwshTest 'profile function forwards to the script' {
        $savedHome = $env:UPWSH_HOME
        try {
            $env:UPWSH_HOME = $installHome
            . $installedProfile
            $output = upwsh --help | Out-String
            Assert-Contains $output 'load'
            Assert-Contains $output 'tool install'
            Assert-Contains $output 'tool update'
            $command = Get-Command upwsh -ErrorAction Stop
            Assert-Equal $command.CommandType.ToString() 'Function'
        } finally {
            $env:UPWSH_HOME = $savedHome
        }
    }
} finally {
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) of $($script:Passed + $script:Failures.Count) upwsh tests failed."
}

Write-Output "$script:Passed upwsh tests passed."

