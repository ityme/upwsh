$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    $testUserHome = Join-Path ([IO.Path]::GetTempPath()) ("upwsh path user's " + [guid]::NewGuid().ToString('N'))
    try {
        $result = Invoke-UpwshTestProcess -UserHome $testUserHome -File $PSCommandPath
        Write-Output $result.Text
        exit $result.Code
    } finally {
        Remove-Item -LiteralPath $testUserHome -Recurse -Force -ErrorAction SilentlyContinue
    }
}
. (Join-Path $PSScriptRoot '..\src\profile.ps1')
$script:Passed = 0
$script:Skipped = 0
$script:Failures = [Collections.Generic.List[string]]::new()
function Test-Case {
    param([string]$Name, [scriptblock]$Body)
    $skippedBefore = $script:Skipped
    try { & $Body; if ($script:Skipped -eq $skippedBefore) { $script:Passed++ } } catch { $script:Failures.Add("$Name`: $($_.Exception.Message)") }
}
function Assert-Equal {
    param($Actual, $Expected)
    if ([string]$Actual -cne [string]$Expected) { throw "expected <$Expected>, got <$Actual>" }
}

Test-Case 'copy adapter stays private to filesystem commands' {
    Assert-Equal ([bool](Get-Command Invoke-UpwshCopy -ErrorAction SilentlyContinue)) $false
    Assert-Equal ([bool](Get-Command Assert-CopyPathWithoutLinks -ErrorAction SilentlyContinue)) $false
    Assert-Equal (((Get-Module fs).NestedModules.Name) -join '|') 'copy'
}
Test-Case 'standalone converter copies match the shared implementation' {
    & (Join-Path $PSScriptRoot '..\src\script\sync_path_convert.ps1') -Check | Out-Null
}
foreach ($entry in @('lib\path_convert.ps1', 'lib\upwsh_home.ps1', 'script\install.ps1', 'script\uninstall.ps1')) {
    Test-Case "shared converter contract without a loaded profile: $entry" {
        $file = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot "..\src\$entry"))
        $code = @'
$ErrorActionPreference = 'Stop'
. ENTRY --help | Out-Null
if ((winpath '/c/my work') -cne 'C:/my work') { throw 'drive conversion failed' }
if ((unixpath 'C:\my work') -cne '/c/my work') { throw 'inverse conversion failed' }
if ((winpath 'text /c/a') -cne 'text /c/a') { throw 'literal text changed' }
if ((winpath '~/my work') -cne ($HOME.Replace('\', '/') + '/my work')) { throw 'home expansion failed' }
if ((unixpath 'C:relative') -cne 'C:relative') { throw 'drive-relative path changed' }
if (((@('/c/a', '/d/b') | winpath) -join '|') -cne 'C:/a|D:/b') { throw 'pipeline conversion failed' }
if (Get-Command Set-HookPromptInput -ErrorAction SilentlyContinue) { throw 'converter loaded the interactive shell' }
'@
        $result = Invoke-UpwshTestProcess -UserHome $HOME -Command $code.Replace('ENTRY', (ConvertTo-TestLiteral $file))
        if ($result.Code -ne 0) { throw $result.Text }
    }
}

Test-Case 'winpath converts drive paths including spaces without requiring existence' {
    Assert-Equal (winpath '/c/my work/missing.txt') 'C:/my work/missing.txt'
    Assert-Equal (winpath '/d') 'D:/'
    Assert-Equal (winpath '/e/') 'E:/'
}
Test-Case 'winpath expands home and keeps Windows paths' {
    Assert-Equal (winpath '~/my work') ($HOME.Replace('\', '/').TrimEnd('/') + '/my work')
    Assert-Equal (winpath 'C:\my work') 'C:\my work'
    Assert-Equal (winpath 'C:relative') 'C:relative'
}
Test-Case 'unixpath converts drive paths and UNC paths' {
    Assert-Equal (unixpath 'C:\my work\missing.txt') '/c/my work/missing.txt'
    Assert-Equal (unixpath 'D:\') '/d/'
    Assert-Equal (unixpath '\\server\share\my work') '//server/share/my work'
    Assert-Equal (unixpath 'C:relative') 'C:relative'
}
Test-Case 'multiple paths and pipeline input preserve order' {
    Assert-Equal ((winpath /c/a /d/b) -join '|') 'C:/a|D:/b'
    Assert-Equal ((@('C:\a', 'D:\b') | unixpath) -join '|') '/c/a|/d/b'
    Assert-Equal ((@('/c/a', '/d/b') | winpath) -join '|') 'C:/a|D:/b'
}
Test-Case 'explicit converters preserve empty paths and round-trip UNC and absolute paths' {
    Assert-Equal (winpath '') ''
    Assert-Equal (unixpath '') ''
    Assert-Equal (winpath (unixpath 'C:\my work\a.txt')) 'C:/my work/a.txt'
    Assert-Equal (winpath '//server/share/a') '//server/share/a'
    Assert-Equal (unixpath (winpath '/c/my work')) '/c/my work'
}
Test-Case 'explicit conversion does not replace fragments or expand wildcards' {
    Assert-Equal (winpath 'text /c/a') 'text /c/a'
    Assert-Equal (winpath 'https://example.test/c/a') 'https://example.test/c/a'
    Assert-Equal (winpath '/c/*.txt') 'C:/*.txt'
    Assert-Equal (unixpath 'text C:\a') 'text C:/a'
    Assert-Equal (unixpath 'relative\a') 'relative/a'
    Assert-Equal (unixpath '/c/a') '/c/a'
}
Test-Case 'cd preserves provider roots relative navigation and previous location' {
    $original = (Get-Location).Path
    try {
        foreach ($providerRoot in @('Env:\', 'Variable:\', 'HKCU:\')) {
            cd $providerRoot
            Assert-Equal (Get-Location).Path $providerRoot
            cd .
            Assert-Equal (Get-Location).Path $providerRoot
            cd -
            Assert-Equal (Get-Location).Path $providerRoot
        }
        cd 'HKCU:\Software'
        cd ..
        Assert-Equal (Get-Location).Path 'HKCU:\'
        cd $original
        cd -
        Assert-Equal (Get-Location).Path 'HKCU:\'
        cd $original
        Assert-Equal (Get-Location).ProviderPath $original
    } finally { Set-Location -LiteralPath $original }
}
Test-Case 'cp file copy, rename, and multiple sources use robocopy semantics' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-cp-files-' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'source dir'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        $first = Join-Path $source 'first file.txt'
        $second = Join-Path $source 'second.txt'
        [IO.File]::WriteAllText($first, 'first')
        [IO.File]::WriteAllText($second, 'second')

        $renamed = Join-Path $root 'renamed.data'
        cp $first $renamed
        Assert-Equal ([IO.File]::ReadAllText($renamed)) 'first'

        $multiple = Join-Path $root 'multiple'
        cp $first,$second $multiple
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $multiple 'first file.txt'))) 'first'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $multiple 'second.txt'))) 'second'

        [IO.File]::WriteAllText($renamed, 'old')
        cp $first $renamed
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText($renamed)) 'first'
        [IO.File]::WriteAllText((Join-Path $multiple 'first file.txt'), 'old')
        cp $first $multiple
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $multiple 'first file.txt'))) 'first'
        cp -f $first $renamed
        Assert-Equal ([IO.File]::ReadAllText($renamed)) 'first'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'cp -rf overwrites renamed files and existing directories repeatedly' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-cp-rf-' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'source'
        $destination = Join-Path $root 'destination'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        $file = Join-Path $source 'a.txt'
        $renamed = Join-Path $destination 'b.txt'
        $unrelated = Join-Path $destination 'a.txt'
        [IO.File]::WriteAllText($file, 'new')
        [IO.File]::WriteAllText($renamed, 'old')
        [IO.File]::WriteAllText($unrelated, 'keep')
        cp -rf $file $renamed
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText($renamed)) 'new'
        Assert-Equal ([IO.File]::ReadAllText($unrelated)) 'keep'
        cp -r -f $file $renamed
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText($file)) 'new'
        cp -rf $source $destination
        cp -rf $source $destination
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'source\a.txt'))) 'new'
        Assert-Equal ([IO.File]::ReadAllText($unrelated)) 'keep'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'cp recursive directory copy preserves destination layout and never mirrors deletes' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-cp-' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'source'
        $sourceChild = Join-Path $source 'nested'
        $destination = Join-Path $root 'destination'
        [IO.Directory]::CreateDirectory($sourceChild) | Out-Null
        [IO.File]::WriteAllText((Join-Path $sourceChild 'source.txt'), 'source')

        cp -r $source $destination
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'nested\source.txt'))) 'source'

        [IO.File]::WriteAllText((Join-Path $destination 'keep.txt'), 'keep')
        cp -r $source $destination
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'source\nested\source.txt'))) 'source'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'keep.txt'))) 'keep'
        cp -rf $source $destination
        Assert-Equal (Test-Path -LiteralPath (Join-Path $destination 'source\source')) $false

        $secondSource = Join-Path $root 'second'
        [IO.Directory]::CreateDirectory($secondSource) | Out-Null
        [IO.File]::WriteAllText((Join-Path $secondSource 'second.txt'), 'second')
        $multipleDestination = Join-Path $root 'multiple'
        cp -r $source,$secondSource $multipleDestination
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $multipleDestination 'source\nested\source.txt'))) 'source'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $multipleDestination 'second\second.txt'))) 'second'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'cp refuses self and descendant destinations before creating files' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-cp-self-' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'source'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [IO.File]::WriteAllText((Join-Path $source 'value.txt'), 'keep')
        foreach ($target in @($source, (Join-Path $source 'backup'), (Join-Path $source 'child\backup'), $root)) {
            $message = ''
            try { cp -rf $source $target } catch { $message = $_.Exception.Message }
            Assert-Equal $LASTEXITCODE 1
            if ($message -notmatch 'itself|same directory') { throw "missing self-copy explanation: $message" }
        }
        Assert-Equal (Test-Path -LiteralPath (Join-Path $source 'backup')) $false
        Assert-Equal (Test-Path -LiteralPath (Join-Path $source 'child')) $false
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $source 'value.txt'))) 'keep'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'cp recursive copy replaces files with unchanged timestamps and size' {
    $root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-cp-force-' + [guid]::NewGuid().ToString('N'))
    try {
        $source = Join-Path $root 'source'
        $destination = Join-Path $root 'destination'
        [IO.Directory]::CreateDirectory($source) | Out-Null
        [IO.Directory]::CreateDirectory($destination) | Out-Null
        $sourceFile = Join-Path $source 'value.txt'
        [IO.Directory]::CreateDirectory((Join-Path $destination 'source')) | Out-Null
        $destinationFile = Join-Path $destination 'source\value.txt'
        [IO.File]::WriteAllText($sourceFile, 'new')
        $timestamp = [datetime]'2020-01-02T03:04:05'
        [IO.File]::SetLastWriteTime($sourceFile, $timestamp)
        # NTFS change time differs even though length and LastWriteTime match.
        # Separate the writes beyond Robocopy's timestamp comparison granularity.
        Start-Sleep -Milliseconds 1100
        [IO.File]::WriteAllText($destinationFile, 'old')
        [IO.File]::SetLastWriteTime($destinationFile, $timestamp)

        cp -r $source $destination
        Assert-Equal ([IO.File]::ReadAllText($destinationFile)) 'new'
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Test-Case 'filesystem commands share quoted and variable drive-path conversion' {
    $root = Join-Path $HOME '第二步 paths'
    $original = (Get-Location).Path
    try {
        $unixRoot = unixpath $root
        mkdir -p $unixRoot
        cd $unixRoot
        Assert-Equal (Get-Location).ProviderPath $root
        touch -p "$unixRoot/source/中文.txt"
        $file = Join-Path $root 'source/中文.txt'
        [IO.File]::WriteAllText($file, "needle /i/tmp`nlast")
        Assert-Equal (head -n 1 (unixpath $file)) 'needle /i/tmp'
        Assert-Equal (tail -n 1 (unixpath $file)) 'last'
        Assert-Equal (grep '/i/tmp' (unixpath $file)) 'needle /i/tmp'
        Assert-Equal (@(find "$unixRoot/source" -Type f)).Count 1
        cp (unixpath $file) "$unixRoot/copied.txt"
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $root copied.txt))) "needle /i/tmp`nlast"
        mv "$unixRoot/copied.txt" "$unixRoot/moved.txt"
        Assert-Equal (Test-Path -LiteralPath (Join-Path $root moved.txt)) $true
        mkcd "$unixRoot/new folder"
        Assert-Equal (Get-Location).ProviderPath (Join-Path $root 'new folder')
        cd -
        Assert-Equal (Get-Location).ProviderPath $root
        Assert-Equal (@('text /i/tmp' | grep '/i/tmp') -join '|') 'text /i/tmp'
    } finally {
        Set-Location -LiteralPath $original
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'cp and mv expand only sources and reject wildcard destinations without touching matches' {
    $root = Join-Path $HOME 'source target boundary'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        foreach ($name in @('source.txt', 'target-a.txt', 'target-b.txt')) {
            [IO.File]::WriteAllText((Join-Path $root $name), $name)
        }
        foreach ($command in @('cp', 'mv')) {
            $failed = $false
            try { & $command (unixpath (Join-Path $root source.txt)) ((unixpath $root) + '/target-*.txt') } catch { $failed = $true }
            Assert-Equal $failed $true
            foreach ($name in @('source.txt', 'target-a.txt', 'target-b.txt')) {
                Assert-Equal ([IO.File]::ReadAllText((Join-Path $root $name))) $name
            }
        }
        $destination = Join-Path $root 'out [literal]'
        mkdir (unixpath $destination)
        cp ((unixpath $root) + '/target-*.txt') (unixpath $destination)
        Assert-Equal (Test-Path -LiteralPath (Join-Path $destination target-a.txt)) $true
        Assert-Equal (Test-Path -LiteralPath (Join-Path $destination target-b.txt)) $true
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
Test-Case 'mixed arguments preserve ambiguous option values and convert explicit path operands' {
    $values = @(ConvertTo-WindowsMixedPathArguments @('/i/folder', '--ignore-glob', '/i/*', '--', '/i/中文 folder'))
    Assert-Equal ($values -join '|') 'I:/folder|--ignore-glob|/i/*|--|I:/中文 folder'
    Assert-Equal ((ConvertTo-WindowsMixedPathArguments @('--time-style=+%Y', '--sort', 'name', '--', '/i/folder')) -join '|') '--time-style=+%Y|--sort|name|--|I:/folder'
}
Test-Case 'external adapters and rm receive converted paths without converting patterns' {
    $fs = Get-Module fs
    & $fs {
        function eza { $args -join '|' }
        $value = Invoke-Eza -Options @('--tree') -Arguments @('--ignore-glob', '/i/*', '--', '/i/中文 folder')
        if ($value -cne '--time-style=+%Y-%m-%d %H:%M:%S|--tree|--ignore-glob|/i/*|--|I:/中文 folder') { throw $value }
        # Intercept lookup before any recycle operation; do not touch actual files.
        function Get-Item { param($LiteralPath, [switch]$Force, $ErrorAction) throw "LOOKUP:$LiteralPath" }
        try { rm '/i/中文 folder' } catch {
            if ($_.Exception.Message -cne 'LOOKUP:I:/中文 folder') { throw }
            return
        }
        throw 'rm lookup was not intercepted'
    }
    & (Get-Module tool) {
        function dust { $args -join '|' }
        $value = du -sh '/i/中文 folder'
        if ($value -cne '--depth|0|I:/中文 folder') { throw $value }
    }
}

Test-Case 'cp rejects junction parents and source or target tree links before writing' {
    $root = Join-Path $HOME 'copy links'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $links = [Collections.Generic.List[string]]::new()
    try {
        $source = Join-Path $root source
        $other = Join-Path $root other
        $destination = Join-Path $root destination
        foreach ($path in @($source,$other,$destination)) { [IO.Directory]::CreateDirectory($path) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $source 'x.txt'), 'source')
        [IO.File]::WriteAllText((Join-Path $other 'x.txt'), 'keep')
        $alias = Join-Path $root alias
        New-Item -ItemType Junction -Path $alias -Target $source | Out-Null
        $links.Add($alias)
        foreach ($pair in @(@($source,(Join-Path $alias backup)),@($alias,(Join-Path $root fresh)))) {
            $message = ''
            try { cp -rf $pair[0] $pair[1] } catch { $message = $_.Exception.Message }
            if ($message -notmatch 'reparse point') { throw "missing link rejection: $message" }
            Assert-Equal $LASTEXITCODE 1
        }
        Assert-Equal (Test-Path -LiteralPath (Join-Path $source backup)) $false
        Assert-Equal (Test-Path -LiteralPath (Join-Path $root fresh)) $false
        $cycle = Join-Path $source loop
        New-Item -ItemType Junction -Path $cycle -Target $source | Out-Null
        $links.Add($cycle)
        $message = ''
        try { cp -rf $source $destination } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'reparse point') { throw "cycle was not rejected: $message" }
        [IO.Directory]::Delete($cycle); $links.Remove($cycle) | Out-Null
        $redirect = Join-Path $destination source
        New-Item -ItemType Junction -Path $redirect -Target $other | Out-Null
        $links.Add($redirect)
        $message = ''
        try { cp -rf $source $destination } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'reparse point') { throw "destination link was not rejected: $message" }
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $other 'x.txt'))) 'keep'
    } finally {
        foreach ($link in $links) { [IO.Directory]::Delete($link) }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
Test-Case 'cp ignores unrelated target junctions but rejects links at effective write targets' {
    $root = Join-Path $HOME 'copy target scope'
    $links = [Collections.Generic.List[string]]::new()
    try {
        $source = Join-Path $root source
        $destination = Join-Path $root destination
        $other = Join-Path $root other
        foreach ($p in @($source,$destination,$other)) { [IO.Directory]::CreateDirectory($p) | Out-Null }
        [IO.File]::WriteAllText((Join-Path $source 'a.txt'), 'new')
        [IO.File]::WriteAllText((Join-Path $other 'keep.txt'), 'keep')
        $unrelated = Join-Path $destination unrelated
        New-Item -ItemType Junction -Path $unrelated -Target $other | Out-Null
        $links.Add($unrelated)
        cp (Join-Path $source 'a.txt') $destination
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'a.txt'))) 'new'
        cp -r $source $destination
        Assert-Equal $LASTEXITCODE 0
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $destination 'source/a.txt'))) 'new'
        Assert-Equal ([IO.File]::ReadAllText((Join-Path $other 'keep.txt'))) 'keep'

        $nested = Join-Path $destination 'source/nested'
        New-Item -ItemType Junction -Path $nested -Target $other | Out-Null
        $links.Add($nested)
        # A later invalid source must prevent earlier sources from being copied too.
        $early = Join-Path $root 'early.txt'
        [IO.File]::WriteAllText($early, 'early')
        $message = ''
        try { cp -rf $early $source $destination } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'reparse point') { throw "effective subtree link was not rejected: $message" }
        Assert-Equal (Test-Path -LiteralPath (Join-Path $destination 'early.txt')) $false

        $fileLink = Join-Path $destination 'early.txt'
        New-Item -ItemType Junction -Path $fileLink -Target $other | Out-Null
        $links.Add($fileLink)
        $message = ''
        try { cp -f $early $destination } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'reparse point') { throw "effective file target link was not rejected: $message" }
    } finally {
        foreach ($link in $links) { [IO.Directory]::Delete($link) }
        Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
    }
}
Test-Case 'copy preflight rejects dangling symbolic links without following them' {
    $root = Join-Path $HOME 'copy symlinks'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    $link = Join-Path $root link.txt
    try {
        try {
            New-Item -ItemType SymbolicLink -Path $link -Target (Join-Path $root missing.txt) -ErrorAction Stop | Out-Null
        } catch {
            # PowerShell's explicit elevation check or Windows ERROR_PRIVILEGE_NOT_HELD.
            # Do not hide access-denied, invalid-path, or other unexpected test failures.
            $exception = $_.Exception
            $privilegeMissing = $_.FullyQualifiedErrorId -like 'NewItemSymbolicLinkElevationRequired,*'
            while ($exception) {
                if (($exception.HResult -band 0xffff) -eq 1314) { $privilegeMissing = $true }
                $exception = $exception.InnerException
            }
            if (-not $privilegeMissing) { throw }
            $script:Skipped++
            Write-Output 'SKIP: symbolic-link creation requires Developer Mode or SeCreateSymbolicLinkPrivilege; junction tests still run.'
            return
        }
        $message = ''
        try {
            & (Get-Module fs) {
                param($path)
                & (Get-Module copy) { param($p) Assert-CopyPathWithoutLinks $p } $path
            } $link
        } catch { $message = $_.Exception.Message }
        if ($message -notmatch 'reparse point') { throw "dangling symbolic link not rejected: $message" }
    } finally {
        if ([IO.File]::Exists($link)) { [IO.File]::Delete($link) }
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
Test-Case 'cp -rf replaces readonly files and restores attributes on failed replacement' {
    $root = Join-Path $HOME 'copy readonly'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $source = Join-Path $root source.txt; $target = Join-Path $root target.txt
        [IO.File]::WriteAllText($source, 'new'); [IO.File]::WriteAllText($target, 'old')
        [IO.File]::SetAttributes($target, [IO.FileAttributes]::ReadOnly)
        foreach ($targetArgument in @($target, $root)) {
            if ($targetArgument -eq $root) {
                # Use a separate source folder so copying to the target parent is not self-copy.
                $sourceFolder = Join-Path $root inputs
                [IO.Directory]::CreateDirectory($sourceFolder) | Out-Null
                $inputFile = Join-Path $sourceFolder target.txt
                [IO.File]::WriteAllText($inputFile, 'new')
            } else { $inputFile = $source }
            $failed = $false
            try { cp $inputFile $targetArgument } catch { $failed = $true }
            Assert-Equal $failed $true
            Assert-Equal ([IO.File]::ReadAllText($target)) 'old'
        }
        $treeSource = Join-Path $root tree
        $treeTarget = Join-Path $root 'out/tree'
        [IO.Directory]::CreateDirectory($treeSource) | Out-Null
        [IO.Directory]::CreateDirectory($treeTarget) | Out-Null
        [IO.File]::WriteAllText((Join-Path $treeSource 'value.txt'), 'new')
        $treeFile = Join-Path $treeTarget value.txt
        [IO.File]::WriteAllText($treeFile, 'old')
        [IO.File]::SetAttributes($treeFile, [IO.FileAttributes]::ReadOnly)
        $failed = $false
        try { cp -r $treeSource (Join-Path $root out) } catch { $failed = $true }
        Assert-Equal $failed $true
        Assert-Equal ([IO.File]::ReadAllText($treeFile)) 'old'
        cp -rf $treeSource (Join-Path $root out)
        Assert-Equal ([IO.File]::ReadAllText($treeFile)) 'new'
        cp -rf $source $target
        Assert-Equal ([IO.File]::ReadAllText($target)) 'new'
        [IO.File]::WriteAllText($target, 'old')
        [IO.File]::SetAttributes($target, [IO.FileAttributes]::ReadOnly)
        $lock = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
        try {
            $failed = $false
            try { cp -rf $source $target } catch { $failed = $true }
            Assert-Equal $failed $true
            Assert-Equal ([IO.File]::ReadAllText($target)) 'old'
            Assert-Equal ([bool]([IO.File]::GetAttributes($target) -band [IO.FileAttributes]::ReadOnly)) $true
        } finally { $lock.Dispose() }
        Assert-Equal (@(Get-ChildItem -LiteralPath $root -Force -Filter '.upwsh-copy-*')).Count 0
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}

$cases = @(
    ,@('drive argument', 'capture /c/work', 'capture /c/work')
    ,@('unknown command preserves arguments', 'unknown-command /d/work', 'unknown-command /d/work')
    ,@('quoted literal', "capture '/c/work'", "capture '/c/work'")
    ,@('double quoted literal', 'capture "~/work"', 'capture "~/work"')
    ,@('literal substring', "capture 'use /c/demo'", "capture 'use /c/demo'")
    ,@('option value', 'capture --output=/c/a', 'capture --output=/c/a')
    ,@('parameter value', 'capture -Path:/c/a', 'capture -Path:/c/a')
    ,@('regex text', "capture '/c/users' README.md", "capture '/c/users' README.md")
    ,@('script text', "capture -Command 'Write-Output /c/demo'", "capture -Command 'Write-Output /c/demo'")
    ,@('script block', 'capture { capture /c/a } /d/out', 'capture { capture /c/a } /d/out')
    ,@('subexpression', 'capture $(capture /c/a) /d/out', 'capture $(capture /c/a) /d/out')
    ,@('explicit conversion', "capture (winpath '/c/my work')", "capture (winpath '/c/my work')")
    ,@('comment', 'capture /c/a # /d/comment', 'capture /c/a # /d/comment')
    ,@('compound tokens', "capture /c/a; capture '/d/literal' /e/b", "capture /c/a; capture '/d/literal' /e/b")
    ,@('pipeline tokens', 'capture /c/a | capture /d/b', 'capture /c/a | capture /d/b')
    ,@('pipeline chain tokens', 'capture /c/a && capture /d/b', 'capture /c/a && capture /d/b')
    ,@('assignment body', '$text = capture /c/a', '$text = capture /c/a')
    ,@('conditional body', 'if ($true) { capture /c/a }', 'if ($true) { capture /c/a }')
    ,@('variable expression', 'capture /c/$name', 'capture /c/$name')
    ,@('escaped whitespace', 'capture /c/my` work', 'capture /c/my` work')
    ,@('quoted segment', 'capture /c/"my work"', 'capture /c/"my work"')
    ,@('stop parsing', 'capture --% /c/a', 'capture --% /c/a')
    ,@('redirection', 'capture /c/a > /d/out', 'capture /c/a > /d/out')
    ,@('function definition', 'function f { capture /c/a }', 'function f { capture /c/a }')
    ,@('incomplete input', "capture /c/a '", "capture /c/a '")
    ,@('glob argument', 'capture /c/*.txt', 'capture /c/*.txt')
    ,@('relative argument', 'capture ./foo ../bar feature/name', 'capture ./foo ../bar feature/name')
    ,@('here string', "capture @'`n/c/data`n'@", "capture @'`n/c/data`n'@")
)
foreach ($case in $cases) {
    Test-Case $case[0] { Assert-Equal (ConvertTo-WindowsCommandLine $case[1]) $case[2] }
}
Test-Case 'Enter preserves search and option values before shared adapters run' {
    $root = Join-Path $HOME 'enter semantics'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        $file = Join-Path $root data.txt
        [IO.File]::WriteAllText($file, "literal /i/tmp`nother")
        $line = 'grep /i/tmp ' + (ConvertTo-TestLiteral (unixpath $file))
        Assert-Equal (Invoke-Expression (ConvertTo-WindowsCommandLine $line)) 'literal /i/tmp'
        & (Get-Module fs) {
            function eza { $args -join '|' }
            $line = 'Invoke-Eza -Options @() -Arguments @(''--ignore-glob'', ''/i/*'', ''--'', ''/i/tmp'')'
            $output = Invoke-Expression (ConvertTo-WindowsCommandLine $line)
            if ($output -cne '--time-style=+%Y-%m-%d %H:%M:%S|--ignore-glob|/i/*|--|I:/tmp') { throw $output }
        }
    } finally { Remove-Item -LiteralPath $root -Recurse -Force }
}
Test-Case 'Enter preserves home arguments even when HOME contains spaces' {
    Assert-Equal (ConvertTo-WindowsCommandLine 'capture ~/my-file') 'capture ~/my-file'
}
Test-Case 'functions preserve ordinary arguments and execute explicit conversion' {
    function capture { $args }
    $line = ConvertTo-WindowsCommandLine "capture /c/a '/d/text' (winpath '/e/my work')"
    Assert-Equal ((Invoke-Expression $line) -join '|') '/c/a|/d/text|E:/my work'
}
Test-Case 'native applications receive unchanged bare arguments and explicit conversion' {
    $receiver = Join-Path $HOME 'receive arguments.ps1'
    [IO.File]::WriteAllText($receiver, 'ConvertTo-Json -InputObject @($args) -Compress')
    $pwsh = (Get-Process -Id $PID).Path
    $line = '& ' + (ConvertTo-TestLiteral $pwsh) + ' -NoLogo -NoProfile -File ' + (ConvertTo-TestLiteral $receiver) + " /c/a '/d/literal' (winpath '/e/my work')"
    $received = Invoke-Expression (ConvertTo-WindowsCommandLine $line) | ConvertFrom-Json
    Assert-Equal ($received -join '|') '/c/a|/d/literal|E:/my work'
}
Test-Case 'path-shaped bracket text is preserved as an argument' {
    function capture { $args }
    $line = ConvertTo-WindowsCommandLine 'capture /c/[draft].txt'
    Assert-Equal (Invoke-Expression $line) '/c/[draft].txt'
}
Test-Case 'known path operands convert drive prefixes but not embedded text' {
    Assert-Equal ((ConvertTo-WindowsPathOperands @('/c/no-such-test-item')) -join '|') 'C:/no-such-test-item'
    Assert-Equal ((ConvertTo-WindowsPathOperands @('text /c/a')) -join '|') 'text /c/a'
    Assert-Equal ((ConvertTo-WindowsPathOperands @('relative/file.txt')) -join '|') 'relative/file.txt'
}
Test-Case 'path operands handle quoted values variables and home paths consistently' {
    $path = '/i/中文 folder/file.txt'
    Assert-Equal (ConvertTo-WindowsPathOperands @($path) -Literal) 'I:/中文 folder/file.txt'
    Assert-Equal (ConvertTo-WindowsPathOperands @('/i/中文 folder/file.txt') -Literal) 'I:/中文 folder/file.txt'
    Assert-Equal (ConvertTo-WindowsPathOperands @('~/file.txt') -Literal) (winpath '~/file.txt')
    Assert-Equal (ConvertTo-WindowsPathOperands @('//server/share/file.txt') -Literal) '//server/share/file.txt'
    Assert-Equal (ConvertTo-WindowsPathOperands @('I:\中文 folder\file.txt') -Literal) 'I:\中文 folder\file.txt'
}
Test-Case 'path operands skip absent values without turning them into filesystem requests' {
    Assert-Equal (@(ConvertTo-WindowsPathOperands $null)).Count 0
    Assert-Equal (@(ConvertTo-WindowsPathOperands @())).Count 0
    Assert-Equal ((ConvertTo-WindowsPathOperands @($null, 'a', $null, 'b')) -join '|') 'a|b'
}
Test-Case 'path conversion precedes glob expansion and literal mode never expands targets' {
    $root = Join-Path $HOME '路径 glob'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    try {
        [IO.File]::WriteAllText((Join-Path $root 'one.txt'), 'one')
        [IO.File]::WriteAllText((Join-Path $root 'two.txt'), 'two')
        $pattern = (unixpath $root) + '/*.txt'
        $paths = @(ConvertTo-WindowsPathOperands @($pattern) -Absolute)
        Assert-Equal $paths.Count 2
        foreach ($path in $paths) {
            Assert-Equal ([IO.File]::Exists($path)) $true
        }
        $literal = @(ConvertTo-WindowsPathOperands @($pattern) -Literal -Absolute)
        Assert-Equal $literal.Count 1
        Assert-Equal $literal[0] ($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath((winpath $pattern)))
        $unmatched = (unixpath $root) + '/missing-*.txt'
        Assert-Equal (ConvertTo-WindowsPathOperands @($unmatched)) (winpath $unmatched)
        Assert-Equal (Resolve-WindowsPath ((unixpath $root) + '/[draft].txt')) (Join-Path $root '[draft].txt')
    } finally {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
Test-Case 'absolute path resolution uses shell location and normalizes relative segments' {
    $root = Join-Path $HOME 'resolve folder'
    [IO.Directory]::CreateDirectory($root) | Out-Null
    Push-Location -LiteralPath $root
    try {
        Assert-Equal (Resolve-WindowsPath './child/../missing.txt') (Join-Path $root 'missing.txt')
        Assert-Equal (Resolve-WindowsPath '/i/tmp/file.txt') 'I:\tmp\file.txt'
        Assert-Equal (Resolve-WindowsPath '~/missing.txt') (Join-Path $HOME 'missing.txt')
        Assert-Equal (Resolve-WindowsPath '\\server\share\missing.txt') '\\server\share\missing.txt'
        Assert-Equal (ConvertTo-WindowsPathOperands @('./missing.txt') -Literal -Absolute) (Join-Path $root 'missing.txt')
    } finally { Pop-Location; Remove-Item -LiteralPath $root -Recurse -Force }
}
Test-Case 'absolute completion containing spaces is executable' {
    $directory = Join-Path $HOME 'my work'
    [void][IO.Directory]::CreateDirectory($directory)
    $prefix = (unixpath $HOME) + '/my'
    $line = 'capture ' + (ConvertTo-QuotedText $prefix)
    $state = Complete-HookLine -Line $line
    $text = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
    $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $text
    $completed = $line.Remove($state.ReplacementIndex, $state.ReplacementLength).Insert($state.ReplacementIndex, $decision.Replacement)
    function capture { $args }
    Assert-Equal (Invoke-Expression (ConvertTo-WindowsCommandLine $completed)) ((unixpath $directory) + '/')
    if ($completed.Contains('(winpath ')) { throw 'completion exposed a conversion expression' }
    $module = (Get-Command Complete-HookLine).Module
    $edit = & $module { param($s,$d) Get-HookCompletionEdit $s $d } $state $decision
    Assert-Equal $edit.Cursor ($edit.Start + $edit.Text.Length - 1)
    # Known path consumers still resolve the plain quoted value correctly.
    Assert-Equal ((Resolve-WindowsPath (Invoke-Expression $completed)).TrimEnd('\', '/')) $directory
}
Test-Case 'attached option completion produces a usable path without Enter rewriting' {
    $match = [Management.Automation.CompletionResult]::new("--output='C:\my work'", 'my work', 'ProviderContainer', 'C:\my work')
    $normalized = ConvertTo-UnixCompletionResult -Match $match -CurrentText '--output=C:/my'
    function capture { $args }
    Assert-Equal (Invoke-Expression ('capture ' + $normalized.CompletionText)) '--output=C:/my work/'
}
Test-Case 'repeated Tab inside a quoted path keeps the cursor inside the closing quote' {
    $line = "touch -p '~/my work/'"
    $child = Join-Path $HOME 'my work\child.txt'
    [IO.File]::WriteAllText($child, '')
    $cursor = $line.Length - 1
    $state = Complete-HookLine -Line $line -Cursor $cursor
    $text = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
    $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $text -LiteralPaths:$state.LiteralPaths
    $module = (Get-Command Complete-HookLine).Module
    $edit = & $module { param($s,$d) Get-HookCompletionEdit $s $d } $state $decision
    $completed = $line.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
    Assert-Equal $completed "touch -p '~/my work/child.txt'"
    Assert-Equal $edit.Cursor ($completed.Length - 1)
    # Typing at the returned cursor appends to the path, not after the quote.
    $typed = $completed.Insert($edit.Cursor, '.bak')
    Assert-Equal $typed "touch -p '~/my work/child.txt.bak'"
}
Test-Case 'completion within explicit conversion keeps the literal path argument' {
    $line = "capture (winpath '~/my')"
    $cursor = $line.IndexOf("')")
    $state = Complete-HookLine -Line $line -Cursor $cursor
    $text = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
    $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $text -LiteralPaths:$state.LiteralPaths
    Assert-Equal $decision.Replacement "'~/my work/'"
}
if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) path command tests failed."
}
Write-Output "$script:Passed path command tests passed; $script:Skipped skipped."
