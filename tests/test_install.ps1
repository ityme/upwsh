$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')

$sourceRoot = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '..'))
$runtimeRoot = Join-Path $sourceRoot 'src'
$installer = Join-Path $runtimeRoot 'script\install.ps1'
$uninstaller = Join-Path $runtimeRoot 'script\uninstall.ps1'
$updater = Join-Path $runtimeRoot 'script\update.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) ('unixify-install-' + [Guid]::NewGuid().ToString('N'))
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()

function Invoke-InstallTest {
    param([string]$Name, [scriptblock]$Body)
    try {
        & $Body
        $script:Passed++
    } catch {
        $script:Failures.Add("$Name`n  $($_.Exception.Message)")
    }
}

function Assert-Equal {
    param($Actual, $Expected)
    if ([string]$Actual -cne [string]$Expected) { throw "expected '$Expected', got '$Actual'" }
}

function Assert-True {
    param([bool]$Condition, [string]$Message)
    if (-not $Condition) { throw $Message }
}

function Assert-Contains {
    param([string]$Text, [string]$Expected)
    if (-not $Text.Contains($Expected)) { throw "expected '$Expected' in '$Text'" }
}

function Install-Fixture {
    param([string]$UserHome)
    $result = Invoke-UpwshTestProcess -UserHome $UserHome -File $installer -Arguments @('--local')
    Assert-Equal $result.Code 0
    return $result
}

try {
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    $userHome = Join-Path $root 'user'
    $installHome = Join-Path $userHome '.config\upwsh'
    $hook = Join-Path $userHome 'test-profile.ps1'
    $settings = Join-Path $installHome 'user-settings.ps1'
    $tool = Join-Path $installHome 'tool\bin\fixture.exe'

    Invoke-InstallTest 'source script installs into the fixed user home' {
        $result = Install-Fixture $userHome
        Assert-Contains $result.Text $runtimeRoot
        Assert-Contains $result.Text 'state     deployed'
        Assert-Contains $result.Text '%UPWSH_HOME%\bin'
        Assert-Contains $result.Text '%UPWSH_HOME%\tool\bin'
        foreach ($file in @('profile.ps1', 'user-settings.ps1', 'lib\git_completion.psm1', 'bin\upwsh.cmd')) {
            Assert-True (Test-Path -LiteralPath (Join-Path $installHome $file) -PathType Leaf) "missing $file"
        }
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installHome 'tests'))) 'tests were deployed'
        $text = [IO.File]::ReadAllText($hook)
        Assert-Contains $text (Join-Path $installHome 'profile.ps1')
        Assert-Contains $result.Text 'command   upwsh'
        Assert-Contains $result.Text 'state     installed'
        Assert-Contains $result.Text 'missing   '
        Assert-Contains $result.Text 'next      upwsh tool install '
        Assert-Contains $result.Text 'eza'
        Assert-True ($result.Text -notlike '*Open a new pwsh*') 'install asked to open a new pwsh'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installHome 'tool\bin\eza.exe'))) 'install downloaded eza'
    }

    Invoke-InstallTest 'install skips the missing-tool hint when eza dust and btm exist' {
        $presentUser = Join-Path $root 'present-tools-user'
        $toolDir = Join-Path $presentUser '.config\upwsh\tool\bin'
        New-Item -ItemType Directory -Path $toolDir -Force | Out-Null
        foreach ($name in @('eza.exe', 'dust.exe', 'btm.exe')) {
            [IO.File]::WriteAllText((Join-Path $toolDir $name), 'stub')
        }
        $result = Invoke-UpwshTestProcess -UserHome $presentUser -File $installer -Arguments @('--local') -Environment @{
            PATH = "$toolDir;$env:PATH"
        }
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'state     installed'
        Assert-True (-not $result.Text.Contains('missing   ')) 'hinted while tools were present'
        Assert-True (-not $result.Text.Contains('upwsh tool install')) 'install command printed while tools were present'
    }

    Invoke-InstallTest 'UPWSH_HOME cannot redirect installation to a source tree' {
        $staleHome = Join-Path $root 'stale-user'
        $result = Invoke-UpwshTestProcess -UserHome $staleHome -File $installer -Environment @{ UPWSH_HOME = $runtimeRoot }
        Assert-Equal $result.Code 0
        Assert-True (Test-Path -LiteralPath (Join-Path $staleHome '.config\upwsh\profile.ps1')) 'fixed home not installed'
        Assert-Contains $result.Text (Join-Path $staleHome '.config\upwsh')
    }

    foreach ($file in @($installer, $uninstaller, $updater)) {
        Invoke-InstallTest "help and invalid flags: $(Split-Path -Leaf $file)" {
            $result = Invoke-UpwshTestProcess -UserHome $userHome -File $file -Arguments @('--help')
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text (Split-Path -Leaf $file)
            $result = Invoke-UpwshTestProcess -UserHome $userHome -File $file -Arguments @('--nope')
            Assert-Equal $result.Code 2
            Assert-Contains $result.Text 'unknown option'
        }
    }

    Invoke-InstallTest 'explicit source accepts a project or src directory' {
        foreach ($source in @($sourceRoot, $runtimeRoot)) {
            $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installer -Arguments @('--source', $source)
            Assert-Equal $result.Code 0
            Assert-Contains $result.Text $runtimeRoot
        }
    }

    Invoke-InstallTest 'check does not deploy or create a profile' {
        $checkHome = Join-Path $root 'check-user'
        $result = Invoke-UpwshTestProcess -UserHome $checkHome -File $installer -Arguments @('--check')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'state     missing'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $checkHome '.config\upwsh'))) 'check deployed runtime'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $checkHome 'test-profile.ps1'))) 'check wrote profile'
    }

    Invoke-InstallTest 'missing source returns failure' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installer -Arguments @('--source', (Join-Path $root 'missing'))
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'missing profile.ps1'
    }

    # A separate project proves that cwd, not the installed command location, supplies the source.
    $project = Join-Path $root "local project [test]'s"
    $projectSrc = Join-Path $project 'src'
    New-Item -ItemType Directory -Path $projectSrc -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $project 'README.md'), '# unixify-powershell')
    Get-ChildItem -LiteralPath $runtimeRoot -Force |
        Where-Object Name -NE 'tests' |
        ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $projectSrc -Recurse -Force }
    [IO.File]::WriteAllText((Join-Path $projectSrc 'local-source.txt'), 'from-cwd')
    $installedCommand = Join-Path $installHome 'script\upwsh.ps1'

    Invoke-InstallTest 'install and uninstall accept the shared path syntax without a profile' {
        $pathUser = Join-Path $root 'path-user'
        $sourcePath = $project.Replace('\', '/')
        $unixSource = '/' + $sourcePath.Substring(0, 1).ToLowerInvariant() + $sourcePath.Substring(2)
        $profilePath = '~/nested profile/hook.ps1'
        $result = Invoke-UpwshTestProcess -UserHome $pathUser -File $installer -Arguments @('--source', $unixSource)
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-True (Test-Path -LiteralPath (Join-Path $pathUser '.config\upwsh\profile.ps1')) 'unix source install missed runtime'
        $result = Invoke-UpwshTestProcess -UserHome $pathUser -File $uninstaller
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $pathUser '.config\upwsh'))) 'installation remained'
    }

    Invoke-InstallTest 'installed upwsh install detects the project in cwd' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('install', '--local') -WorkingDirectory $project
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text $projectSrc
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))) 'from-cwd'
    }

    Invoke-InstallTest 'upwsh install detects the project from a subdirectory' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('install', '--local') -WorkingDirectory (Join-Path $projectSrc 'lib')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text $projectSrc
    }

    Invoke-InstallTest 'installed command downloads outside a project and honors explicit ref inside one' {
        $archive = Join-Path $root 'source.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($project, $archive)
        $command = @'
$ErrorActionPreference = 'Stop'
function Invoke-RestMethod { throw 'no release' }
function Invoke-WebRequest {
    param($Uri, $OutFile, $Headers, [switch]$UseBasicParsing)
    Write-Host "DOWNLOAD:$Uri"
    Copy-Item -LiteralPath ARCHIVE -Destination $OutFile
}
& ENTRY install OPTIONS
exit $LASTEXITCODE
'@
        $command = $command.Replace('ARCHIVE', (ConvertTo-TestLiteral $archive)).Replace('ENTRY', (ConvertTo-TestLiteral $installedCommand))
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command.Replace('OPTIONS', '--remote')
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-Contains $result.Text '/archive/refs/heads/main.zip'
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command.Replace('OPTIONS', '--remote --ref dev') -WorkingDirectory $project
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-Contains $result.Text '/archive/refs/heads/dev.zip'
    }

    Invoke-InstallTest 'installed runtime is rejected as an explicit copy source' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('install', '--source', $installHome)
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'cannot be its own source'
    }

    Invoke-InstallTest 'unload only removes the startup hook' {
        $load = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('load') -WorkingDirectory $project -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Equal $load.Code 0
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('unload') -WorkingDirectory $project -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Equal $result.Code 0
        Assert-True (-not ([IO.File]::ReadAllText($hook)).Contains('# >>> unixify-powershell >>>')) 'hook remained'
        Assert-True (Test-Path -LiteralPath (Join-Path $installHome 'bin\upwsh.cmd')) 'unload removed shim'
        Assert-True (-not $result.Text.Contains('path      removed')) 'unload removed Path'
    }

    Invoke-InstallTest 'load from the project still targets the installed profile' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File (Join-Path $projectSrc 'script\upwsh.ps1') -Arguments @('load') -WorkingDirectory $project -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Equal $result.Code 0
        Assert-Contains ([IO.File]::ReadAllText($hook)) (Join-Path $installHome 'profile.ps1')
        Assert-True (-not ([IO.File]::ReadAllText($hook)).Contains($projectSrc)) 'load hooked source'
    }

    Invoke-InstallTest 'update uses local project and preserves user-settings and tools' {
        [IO.File]::WriteAllText($settings, '# keep user settings')
        [IO.File]::WriteAllText($tool, 'keep installed tool')
        [IO.File]::WriteAllText((Join-Path $installHome 'obsolete.ps1'), '# old managed file')
        [IO.File]::WriteAllText((Join-Path $projectSrc 'local-source.txt'), 'updated')
        $beforeHook = [IO.File]::ReadAllText($hook)
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('update', '--local') -WorkingDirectory $project -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Equal $result.Code 0
        Assert-Equal ([IO.File]::ReadAllText($settings)) '# keep user settings'
        Assert-Equal ([IO.File]::ReadAllText($tool)) 'keep installed tool'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installHome 'obsolete.ps1'))) 'obsolete program file remained'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))) 'updated'
        Assert-Equal ([IO.File]::ReadAllText($hook)) $beforeHook
    }

    Invoke-InstallTest 'update without an installation fails before source acquisition' {
        $newUser = Join-Path $root 'not-installed'
        $result = Invoke-UpwshTestProcess -UserHome $newUser -File $updater -Arguments @('--source', $project)
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'run upwsh install first'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $newUser '.config\upwsh'))) 'update created an installation'
    }

    Invoke-InstallTest 'update leaves the profile hook unchanged and install reloads it' {
        [IO.File]::WriteAllText($hook, "# personal profile`r`n")
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $updater -Arguments @('--source', $project)
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-Equal ([IO.File]::ReadAllText($hook)) "# personal profile`r`n"
        Assert-Equal ([IO.File]::ReadAllText($tool)) 'keep installed tool'
        Assert-Equal ([IO.File]::ReadAllText($settings)) '# keep user settings'
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installer -Arguments @('--source', $project)
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-Contains ([IO.File]::ReadAllText($hook)) (Join-Path $installHome 'profile.ps1')
        Assert-Contains $result.Text 'state     installed'
        Assert-Equal ([IO.File]::ReadAllText($tool)) 'keep installed tool'
        Assert-Equal ([IO.File]::ReadAllText($settings)) '# keep user settings'
    }

    Invoke-InstallTest 'bad source and failed download leave the working installation intact' {
        $before = [IO.File]::ReadAllText((Join-Path $installHome 'profile.ps1'))
        $beforeHook = [IO.File]::ReadAllText($hook)
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $updater -Arguments @('--source', (Join-Path $root 'missing'))
        Assert-Equal $result.Code 1
        $command = @'
function Invoke-WebRequest { throw 'offline fixture' }
& UPDATER --ref test
exit $LASTEXITCODE
'@
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command.Replace('UPDATER', (ConvertTo-TestLiteral $updater))
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'offline fixture'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'profile.ps1'))) $before
        Assert-Equal ([IO.File]::ReadAllText($hook)) $beforeHook
        Assert-Equal ([IO.File]::ReadAllText($tool)) 'keep installed tool'
    }

    Invoke-InstallTest 'invalid runtime syntax is rejected before replacing installed files' {
        $badRoot = Join-Path $root 'invalid-runtime'
        Copy-Item -LiteralPath $projectSrc -Destination $badRoot -Recurse
        [IO.File]::WriteAllText((Join-Path $badRoot 'lib\path.psm1'), 'function Broken {')
        $before = [IO.File]::ReadAllText((Join-Path $installHome 'lib\path.psm1'))
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $updater -Arguments @('--source', $badRoot)
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'invalid runtime'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'lib\path.psm1'))) $before
    }

    Invoke-InstallTest 'configuration failure after replacement rolls back runtime tools and environment' {
        $badRoot = Join-Path $root 'rollback-runtime'
        Copy-Item -LiteralPath $projectSrc -Destination $badRoot -Recurse
        [IO.File]::WriteAllText((Join-Path $badRoot 'lib\upwsh_home.ps1'), @'
throw 'configuration fixture failure'
'@)
        [IO.File]::WriteAllText((Join-Path $badRoot 'local-source.txt'), 'must roll back')
        $beforeHook = [IO.File]::ReadAllText($hook)
        $beforeShim = [IO.File]::ReadAllText((Join-Path $installHome 'bin\upwsh.cmd'))
        $command = @'
$beforePath = $env:PATH
$env:UPWSH_HOME = 'C:\prior-environment'
& UPDATER --source SOURCE
if ($LASTEXITCODE -ne 1) { throw 'expected deployment failure' }
if ($env:PATH -cne $beforePath -or $env:UPWSH_HOME -cne 'C:\prior-environment') { throw 'environment not restored' }
exit 0
'@
        $command = $command.Replace('UPDATER', (ConvertTo-TestLiteral $updater)).Replace('SOURCE', (ConvertTo-TestLiteral $badRoot))
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-Contains $result.Text 'configuration fixture failure'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))) 'updated'
        Assert-True (-not ([IO.File]::ReadAllText((Join-Path $installHome 'lib\upwsh_home.ps1')).Contains('configuration fixture failure'))) 'broken source remained'
        Assert-Equal ([IO.File]::ReadAllText($hook)) $beforeHook
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'bin\upwsh.cmd'))) $beforeShim
        Assert-Equal ([IO.File]::ReadAllText($tool)) 'keep installed tool'
        Assert-Equal ([IO.File]::ReadAllText($settings)) '# keep user settings'
        Assert-Equal (@(Get-ChildItem -LiteralPath (Split-Path $installHome) -Directory -Filter '.upwsh-*')).Count 0
    }

    Invoke-InstallTest 'uninstall check does not delete installed files' {
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $uninstaller -Arguments @('--check')
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'tree      present'
        Assert-True (Test-Path -LiteralPath $installedCommand) 'check deleted files'
    }

    Invoke-InstallTest 'uninstall ignores a stale UPWSH_HOME and leaves the project untouched' {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot 'user-settings.ps1') -Destination $settings -Force
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File (Join-Path $projectSrc 'script\upwsh.ps1') -Arguments @('uninstall') -WorkingDirectory $project -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'home      removed'
        Assert-Contains $result.Text 'path      removed'
        Assert-True (-not (Test-Path -LiteralPath $installHome)) 'install tree remained'
        Assert-True (Test-Path -LiteralPath (Join-Path $projectSrc 'profile.ps1')) 'source was deleted'
        Assert-True (-not ([IO.File]::ReadAllText($hook)).Contains('# >>> unixify-powershell >>>')) 'hook remained'
    }

    Invoke-InstallTest 'uninstall cleans environment even when runtime files are missing' {
        $command = @'
$ErrorActionPreference = 'Stop'
$target = Join-Path $HOME '.config\upwsh'
$env:PATH = $env:PATH + ';' + (Join-Path $target 'bin') + ';%UPWSH_HOME%\tool\bin;C:\keep-path'
$env:UPWSH_HOME = 'C:\stale-source'
& UNINSTALL
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
if ($env:UPWSH_HOME) { throw 'UPWSH_HOME remained' }
if ($env:PATH.Contains($target) -or $env:PATH.Contains('%UPWSH_HOME%')) { throw 'managed paths remained' }
if (-not $env:PATH.Contains('C:\keep-path')) { throw 'unrelated path removed' }
'@
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command.Replace('UNINSTALL', (ConvertTo-TestLiteral $uninstaller))
        Assert-Equal $result.Code 0
    }

    Invoke-InstallTest 'uninstall removes an unchanged user-settings template' {
        Install-Fixture $userHome | Out-Null
        Copy-Item -LiteralPath (Join-Path $runtimeRoot 'user-settings.ps1') -Destination $settings -Force
        Assert-True (Test-Path -LiteralPath $settings)
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $uninstaller
        Assert-Equal $result.Code 0
        Assert-True (-not (Test-Path -LiteralPath $installHome)) 'runtime remained'
        Assert-True (-not $result.Text.Contains('keep      ')) 'kept an unchanged template'
    }

    Invoke-InstallTest 'uninstall keeps a changed user-settings file and deletes themes' {
        Install-Fixture $userHome | Out-Null
        [IO.File]::AppendAllText($settings, "`nfunction global:work { Get-Date }`n")
        $themeFile = Join-Path $installHome 'theme\personal.json'
        [IO.File]::WriteAllText($themeFile, '{}')
        $selection = Join-Path $installHome 'theme.json'
        [IO.File]::WriteAllText($selection, '{"Theme":"personal.json"}')
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $uninstaller
        Assert-Equal $result.Code 0
        Assert-True (Test-Path -LiteralPath $settings) 'changed user-settings was deleted'
        Assert-True ([IO.File]::ReadAllText($settings).Contains('function global:work')) 'kept settings lost edits'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installHome 'theme'))) 'themes remained'
        Assert-True (-not (Test-Path -LiteralPath $selection)) 'theme.json remained'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $installHome 'profile.ps1'))) 'runtime files remained'
        Assert-Contains $result.Text 'keep      '
    }

    Invoke-InstallTest 'piped install keeps the host and defines upwsh in this session' {
        $pipeUser = Join-Path $root 'pipe-user'
        $command = @"
[IO.File]::ReadAllText($(ConvertTo-TestLiteral $installer)) | Invoke-Expression
Write-Output ('AFTER_IEX:' + `$LASTEXITCODE)
Write-Output ('UPWSH:' + ((Get-Command upwsh -ErrorAction SilentlyContinue).CommandType))
"@
        $result = Invoke-UpwshTestProcess -UserHome $pipeUser -Command $command -Environment @{ UPWSH_SOURCE = $project; UPWSH_SKIP_SESSION_LOAD = $null }
        Assert-Equal $result.Code 0
        Assert-Contains $result.Text 'AFTER_IEX:0'
        Assert-Contains $result.Text 'state     deployed'
        Assert-Contains $result.Text 'UPWSH:Function'
        Assert-Contains ([IO.File]::ReadAllText((Join-Path $pipeUser 'test-profile.ps1'))) (Join-Path $pipeUser '.config\upwsh\profile.ps1')
    }

    Invoke-InstallTest 'piped update keeps user-settings and uses local source' {
        $pipeUser = Join-Path $root 'pipe-update-user'
        Install-Fixture $pipeUser | Out-Null
        $pipeSettings = Join-Path $pipeUser '.config\upwsh\user-settings.ps1'
        [IO.File]::WriteAllText($pipeSettings, '# keep piped settings')
        $command = @'
$ErrorActionPreference = 'Stop'
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing)
    $name = ($Uri -split '/')[-1]
    if ($name -notin @('install.ps1', 'uninstall.ps1')) { throw "unexpected URL: $Uri" }
    [pscustomobject]@{ Content = [IO.File]::ReadAllText((Join-Path SCRIPTS $name)) }
}
[IO.File]::ReadAllText(UPDATER) | Invoke-Expression
Write-Output ('AFTER_IEX:' + $LASTEXITCODE)
'@
        $command = $command.Replace('SCRIPTS', (ConvertTo-TestLiteral (Join-Path $runtimeRoot 'script'))).Replace('UPDATER', (ConvertTo-TestLiteral $updater))
        $result = Invoke-UpwshTestProcess -UserHome $pipeUser -Command $command -WorkingDirectory $project -Environment @{ UPWSH_SOURCE = $project }
        Assert-Contains $result.Text 'AFTER_IEX:0'
        Assert-Contains $result.Text $projectSrc
        Assert-Equal ([IO.File]::ReadAllText($pipeSettings)) '# keep piped settings'
    }

    Invoke-InstallTest 'piped uninstall removes the fixed installation without closing the host' {
        $pipeUser = Join-Path $root 'pipe-uninstall-user'
        Install-Fixture $pipeUser | Out-Null
        $command = "[IO.File]::ReadAllText($(ConvertTo-TestLiteral $uninstaller)) | Invoke-Expression; Write-Output ('AFTER_IEX:' + `$LASTEXITCODE)"
        $result = Invoke-UpwshTestProcess -UserHome $pipeUser -Command $command -Environment @{ UPWSH_HOME = $projectSrc }
        Assert-Contains $result.Text 'AFTER_IEX:0'
        Assert-True (-not (Test-Path -LiteralPath (Join-Path $pipeUser '.config\upwsh'))) 'piped uninstall left runtime'
        Assert-True (Test-Path -LiteralPath (Join-Path $projectSrc 'profile.ps1')) 'piped uninstall deleted source'
    }

    Invoke-InstallTest 'piped install failure returns without closing the host' {
        $command = "[IO.File]::ReadAllText($(ConvertTo-TestLiteral $installer)) | Invoke-Expression; Write-Output ('AFTER_IEX:' + `$LASTEXITCODE)"
        $result = Invoke-UpwshTestProcess -UserHome $userHome -Command $command -Environment @{ UPWSH_SOURCE = (Join-Path $root 'missing') }
        Assert-Contains $result.Text 'AFTER_IEX:1'
    }

    Invoke-InstallTest 'piped update does not leak update-only mode into later installs' {
        $modeUser = Join-Path $root 'mode-user'
        $command = @'
function Invoke-WebRequest {
    param($Uri, [switch]$UseBasicParsing)
    [pscustomobject]@{ Content = [IO.File]::ReadAllText(INSTALLER) }
}
[IO.File]::ReadAllText(UPDATER) | Invoke-Expression
if ($LASTEXITCODE -ne 1) { throw 'update should require an installation' }
[IO.File]::ReadAllText(INSTALLER) | Invoke-Expression
if ($LASTEXITCODE -ne 0) { throw 'install inherited update-only mode' }
'@
        $command = $command.Replace('INSTALLER', (ConvertTo-TestLiteral $installer)).Replace('UPDATER', (ConvertTo-TestLiteral $updater))
        $result = Invoke-UpwshTestProcess -UserHome $modeUser -Command $command -Environment @{ UPWSH_SOURCE = $project }
        Assert-True ($result.Code -eq 0) $result.Text
        Assert-True (Test-Path -LiteralPath (Join-Path $modeUser '.config\upwsh\profile.ps1')) 'install did not recover after failed update'
    }

    Invoke-InstallTest 'installed -File update preserves cwd across relaunch' {
        Install-Fixture $userHome | Out-Null
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('update', '--local') -WorkingDirectory $project -Environment @{ UPWSH_SKIP_RELAUNCH = $null }
        Assert-Equal $result.Code 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))) 'updated'
    }

    Invoke-InstallTest 'installed -File update reports child failure and keeps the installation' {
        $before = [IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('update', '--local', '--source', (Join-Path $root 'missing')) -Environment @{ UPWSH_SKIP_RELAUNCH = $null }
        Assert-Equal $result.Code 1
        Assert-Contains $result.Text 'missing profile.ps1'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $installHome 'local-source.txt'))) $before
    }

    Invoke-InstallTest 'installed -File uninstall relaunches and removes only the installation' {
        Copy-Item -LiteralPath (Join-Path $runtimeRoot 'user-settings.ps1') -Destination $settings -Force
        $result = Invoke-UpwshTestProcess -UserHome $userHome -File $installedCommand -Arguments @('uninstall') -Environment @{ UPWSH_SKIP_RELAUNCH = $null }
        Assert-Equal $result.Code 0
        Assert-True (-not (Test-Path -LiteralPath $installHome)) 'relaunch left installation'
        Assert-True (Test-Path -LiteralPath (Join-Path $projectSrc 'profile.ps1')) 'relaunch deleted project'
    }
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

if ($script:Failures.Count -gt 0) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) of $($script:Passed + $script:Failures.Count) install tests failed."
}
Write-Output "$script:Passed install tests passed."
