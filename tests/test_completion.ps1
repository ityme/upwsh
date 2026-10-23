$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    Invoke-UpwshIsolatedTest -File $PSCommandPath
    exit $LASTEXITCODE
}

$profilePath = Join-Path $PSScriptRoot '..\src\profile.ps1'
$root = Join-Path ([IO.Path]::GetTempPath()) (
    'pwsh-completion-' + [Guid]::NewGuid().ToString('N')
)
$work = Join-Path $root 'work'
$fakeHome = Join-Path $root 'home'
$originalHome = $HOME
$originalUpwshHome = $env:UPWSH_HOME
$locationPushed = $false
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()

function Invoke-CompletionTest {
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
        [object[]]$Values,
        [string]$Expected
    )

    if ($Expected -notin @($Values)) {
        throw "expected '$Expected' in [$(@($Values) -join ', ')]"
    }
}

function Assert-NoBackslash {
    param([object[]]$Values)

    $invalid = @($Values | Where-Object { [string]$_ -match '\\' })
    if ($invalid.Count -gt 0) {
        throw "unexpected backslash in [$($invalid -join ', ')]"
    }
}

function Assert-NoUppercaseWindowsDrivePrefix {
    param([object[]]$Values)

    $invalid = @($Values | Where-Object { [string]$_ -match '^/[A-Z]:/' })
    if ($invalid.Count -gt 0) {
        throw "unexpected uppercase Windows drive prefix in [$($invalid -join ', ')]"
    }
}

function Get-TabCompletionTexts {
    param(
        [string]$Line,
        [int]$CursorColumn = -1
    )

    if ($CursorColumn -lt 0) {
        $CursorColumn = $Line.Length
    }
    $state = Complete-HookLine -Line $Line -Cursor $CursorColumn
    @(
        foreach ($match in @($state.Matches)) {
            [string]$match.CompletionText
        }
    )
}

function Get-FileSystemCompletionTexts {
    param(
        [string]$WordToComplete,
        [switch]$DirectoryOnly,
        [string]$BaseDirectory = $work
    )

    @(
        Get-UnixPathCompletion `
            -WordToComplete $WordToComplete `
            -DirectoryOnly:$DirectoryOnly `
            -BaseDirectory $BaseDirectory |
            ForEach-Object CompletionText
    )
}

function New-FixtureDirectory {
    param(
        [string]$RelativePath,
        [switch]$Hidden,
        [string]$BaseDirectory = $work
    )

    $item = New-Item -ItemType Directory `
        -Path (Join-Path $BaseDirectory $RelativePath) `
        -Force
    if ($Hidden) {
        $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    }
    $item
}

function New-FixtureFile {
    param(
        [string]$RelativePath,
        [switch]$Hidden,
        [string]$BaseDirectory = $work
    )

    $item = New-Item -ItemType File `
        -Path (Join-Path $BaseDirectory $RelativePath) `
        -Force
    if ($Hidden) {
        $item.Attributes = $item.Attributes -bor [IO.FileAttributes]::Hidden
    }
    $item
}

try {
    New-Item -ItemType Directory -Path $work, $fakeHome -Force | Out-Null
    New-FixtureDirectory 'target-unique' | Out-Null
    New-FixtureDirectory 'target-alpha' | Out-Null
    New-FixtureDirectory 'target-beta' | Out-Null
    New-FixtureDirectory 'target-dir/child-dir' | Out-Null
    New-FixtureDirectory 'app-factory/.git' -Hidden | Out-Null
    New-FixtureDirectory 'space alpha' | Out-Null
    New-FixtureDirectory 'space beta' | Out-Null
    New-FixtureDirectory "quote's-dir" | Out-Null
    New-FixtureDirectory 'cash$dir' | Out-Null
    New-FixtureDirectory 'amp&dir' | Out-Null
    New-FixtureDirectory 'semi;dir' | Out-Null
    New-FixtureDirectory 'hash#dir' | Out-Null
    New-FixtureDirectory 'paren(dir)' | Out-Null
    New-FixtureDirectory '[bracket]-dir' | Out-Null
    New-FixtureDirectory '-dash-dir' | Out-Null
    New-FixtureDirectory 'CaseDir' | Out-Null
    New-FixtureDirectory '中文目录' | Out-Null
    New-FixtureDirectory '.hidden-dir' -Hidden | Out-Null
    New-FixtureDirectory 'empty-dir' | Out-Null
    New-FixtureDirectory 'sibling-dir' -BaseDirectory $root | Out-Null
    New-FixtureFile 'target-file.txt' | Out-Null
    New-FixtureFile 'target-dir/child-file.txt' | Out-Null
    New-FixtureFile '.hidden-file' -Hidden | Out-Null
    New-FixtureFile '.viminfo' -Hidden -BaseDirectory $fakeHome | Out-Null
    New-FixtureDirectory '.vim' -Hidden -BaseDirectory $fakeHome | Out-Null

    & (Join-Path $PSScriptRoot '..\src\script\install_profile.ps1') -Deploy | Out-Null
    $profilePath = Join-Path $HOME '.config\upwsh\profile.ps1'
    $env:UPWSH_HOME = Split-Path -Parent $profilePath
    $userSettings = Join-Path (Split-Path -Parent $profilePath) 'user-settings.ps1'
    Set-Content -LiteralPath $userSettings -Value @'
$script:CommandMap['w'] = 'cd /i/workspace'
$script:CommandMap['gs'] = 'git status'
Install-CommandMap
Set-Alias -Name user_settings_marker -Value Get-Date -Scope Global -Force
'@
    . (Resolve-Path $profilePath)
    Set-Variable -Name HOME -Value $fakeHome -Scope Global -Force

    Invoke-CompletionTest 'cd is a function, not Set-Location alias' {
        $command = Get-Command cd -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Function'
    }
    Invoke-CompletionTest 'cp is a function, not Copy-Item alias' {
        $command = Get-Command cp -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Function'
    }
    Invoke-CompletionTest 'profile does not define tool or tools commands' {
        $tool = Get-Command tool -CommandType Function, Alias -ErrorAction SilentlyContinue
        Assert-True ($null -eq $tool) 'tool command still defined'
        $tools = Get-Command tools -CommandType Function, Alias -ErrorAction SilentlyContinue
        Assert-True ($null -eq $tools) 'tools command still defined'
    }
    Invoke-CompletionTest 'vim is an alias of nvim' {
        $command = Get-Command vim -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Alias'
        Assert-Equal $command.Definition 'nvim'
    }
    Invoke-CompletionTest 'personal shortcuts come from user-settings' {
        $command = Get-Command w -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Function'
        $command = Get-Command gs -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Function'
    }
    Invoke-CompletionTest 'user-settings.ps1 loads after stock aliases' {
        $command = Get-Command user_settings_marker -ErrorAction Stop
        Assert-Equal $command.CommandType.ToString() 'Alias'
        Assert-Equal $command.Definition 'Get-Date'
    }
    Push-Location $work
    $locationPushed = $true

    $driveRoot = [IO.Path]::GetPathRoot($work)
    $driveLetter = $driveRoot.Substring(0, 1).ToLowerInvariant()
    $driveLetterUpper = $driveLetter.ToUpperInvariant()
    $unixWork = (unixpath $work).TrimEnd('/')
    $slashPrefixedWindowsWork = "/$driveLetterUpper`:" +
        $work.Substring(2).Replace('\', '/')

    $commandReadinessCases = @(
        ,@('external command', 'Start-Sleep 1', $true)
        ,@('empty loop', 'while ($true) { }', $true)
        ,@('assignment', '$x = 1', $true)
        ,@('blank input', '   ', $false)
        ,@('line comment', '# ignored', $false)
        ,@('block comment', '<# ignored #>', $false)
        ,@('empty statement', ';', $false)
        ,@('using declaration', 'using namespace System', $true)
        ,@('parameter declaration', 'param($x)', $true)
        ,@('invalid submitted syntax', '1 + * 2', $true)
        ,@('incomplete block', 'while ($true) {', $false)
        ,@('incomplete string', 'Write-Output "value', $false)
    )
    foreach ($case in $commandReadinessCases) {
        Invoke-CompletionTest "command status: $($case[0])" {
            Assert-Equal `
                (Test-CompleteCommandLine -InputScript $case[1]) `
                $case[2]
        }
    }
    Invoke-CompletionTest 'pane title: idle shows current directory' {
        Assert-Equal (Get-TermPaneTitle) (Split-Path -Leaf $work)
    }
    Invoke-CompletionTest 'pane title: command includes directory and command' {
        Assert-Equal `
            (Get-TermPaneTitle -Command 'git status') `
            "$(Split-Path -Leaf $work) › git"
    }
    Invoke-CompletionTest 'pane title: command control characters are flattened' {
        Assert-Equal `
            (Get-TermPaneTitle -Command "Write-Output`nvalue`a") `
            "$(Split-Path -Leaf $work) › Write-Output"
    }
    Invoke-CompletionTest 'pane title: long command is bounded' {
        $title = Get-TermPaneTitle -Command ('x' * 300)
        Assert-Equal $title.Length 160
        Assert-True $title.EndsWith('...') 'long pane title was not truncated'
    }
    Invoke-CompletionTest 'command name: first token and path leaf' {
        Assert-Equal (Get-TermCommandName 'git status') 'git'
        Assert-Equal (Get-TermCommandName "& 'C:\bin\rg.exe' -n foo") 'rg.exe'
    }
    Invoke-CompletionTest 'term report includes configured fields' {
        $originalOut = [Console]::Out
        $stream = [IO.MemoryStream]::new()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        try {
            [Console]::SetOut($writer)
            Sync-TermPrompt -Succeeded $true -ExitCode 0
            $writer.Flush()
            $text = [Text.Encoding]::UTF8.GetString($stream.ToArray())
        } finally {
            [Console]::SetOut($originalOut)
            $writer.Dispose()
        }
        Assert-True ($text -match 'SetUserVar=HOST=') 'missing HOST'
        Assert-True ($text -match 'SetUserVar=USER=') 'missing USER'
        Assert-True ($text -match 'SetUserVar=CWD=') 'missing CWD'
        Assert-True ($text.Contains("]2;")) 'missing OSC 2'
        Assert-True ($text.Contains("]7;")) 'missing OSC 7'
        Assert-True ($text.Contains("]133;A")) 'missing OSC 133 A'
    }
    Invoke-CompletionTest 'term report skips commented fields' {
        $module = (Get-Command Sync-TermPrompt -ErrorAction Stop).Module
        Assert-True ([bool]$module) 'term module was not loaded'
        $originalOut = [Console]::Out
        $stream = [IO.MemoryStream]::new()
        $writer = [IO.StreamWriter]::new($stream)
        $writer.AutoFlush = $true
        try {
            & $module {
                Set-TermReporting -Fields @($script:TermReport | Where-Object { $_ -ne 'HOST' })
            }
            [Console]::SetOut($writer)
            Sync-TermPrompt -Succeeded $true -ExitCode 0
            $writer.Flush()
            $text = [Text.Encoding]::UTF8.GetString($stream.ToArray())
        } finally {
            & $module {
                Set-TermReporting -Fields @(@($script:TermReport) + 'HOST')
            }
            [Console]::SetOut($originalOut)
            $writer.Dispose()
        }
        Assert-True ($text -notmatch 'SetUserVar=HOST=[^\x07]+') 'HOST still reported a nonempty value'
        Assert-True ($text -match 'SetUserVar=USER=') 'USER was dropped with HOST'
    }
    Invoke-CompletionTest 'term report finishes within 20ms' {
        $originalOut = [Console]::Out
        $buffer = [IO.StreamWriter]::new([IO.MemoryStream]::new())
        try {
            [Console]::SetOut($buffer)
            1..15 | ForEach-Object {
                Sync-TermPrompt -Succeeded $true -ExitCode 0
                Sync-TermCommand -Command 'git status'
            }
            $promptTimes = foreach ($i in 1..40) {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                Sync-TermPrompt -Succeeded $true -ExitCode 0
                $watch.Stop()
                $watch.Elapsed.TotalMilliseconds
            }
            $commandTimes = foreach ($i in 1..40) {
                $watch = [Diagnostics.Stopwatch]::StartNew()
                Sync-TermCommand -Command 'git status'
                $watch.Stop()
                $watch.Elapsed.TotalMilliseconds
            }
        } finally {
            [Console]::SetOut($originalOut)
            $buffer.Dispose()
        }
        $sorted = @(@($promptTimes) + @($commandTimes) | Sort-Object)
        $p95 = $sorted[[Math]::Min($sorted.Count - 1, [int][Math]::Floor($sorted.Count * 0.95))]
        $avg = ($sorted | Measure-Object -Average).Average
        Assert-True (
            $avg -lt 10 -and $p95 -lt 20
        ) "term report avg ${avg}ms p95 ${p95}ms"
    }
    Invoke-CompletionTest 'command status: Enter handler is registered once' {
        $handler = Get-PSReadLineKeyHandler -Chord Enter
        Assert-Equal $handler.Function 'HookAcceptLine'

        . (Resolve-Path $profilePath)
        $reloadedHandler = Get-PSReadLineKeyHandler -Chord Enter
        Assert-Equal $reloadedHandler.Function 'HookAcceptLine'
    }
    Invoke-CompletionTest 'literal path wrappers preserve wildcard characters' {
        $literalPath = 'literal-[a].txt'
        touch $literalPath
        Assert-True (
            Test-Path -LiteralPath (Join-Path $work $literalPath)
        ) 'touch did not preserve wildcard characters in a literal filename'
    }
    Invoke-CompletionTest 'touch does not create missing parents without -p' {
        $missingPath = Join-Path $work 'missing-parent/file.txt'
        try {
            touch 'missing-parent/file.txt' 2>$null
        } catch {
            # The command intentionally reports a nonzero status for this case.
        }
        Assert-True (
            -not (Test-Path -LiteralPath $missingPath)
        ) 'touch created a file without its parent directory'
    }
    Invoke-CompletionTest 'touch -p creates missing parent directories' {
        touch -p 'nested/deep/file.txt'
        Assert-True (
            Test-Path -LiteralPath (Join-Path $work 'nested\deep\file.txt')
        ) 'touch -p did not create the file'
    }
    Invoke-CompletionTest 'touch -p preserves existing file content' {
        $existingPath = Join-Path $work 'nested\existing.txt'
        [IO.File]::WriteAllText($existingPath, 'keep')
        touch -p 'nested/existing.txt'
        Assert-Equal ([IO.File]::ReadAllText($existingPath)) 'keep'
    }
    Invoke-CompletionTest 'mkdir preserves wildcard characters in a literal directory' {
        $literalDirectory = 'literal-[dir]'
        mkdir $literalDirectory
        Assert-True (
            Test-Path -LiteralPath (Join-Path $work $literalDirectory) -PathType Container
        ) 'mkdir did not preserve wildcard characters in a literal directory'
    }

    # Pure path conversion.
    $unixHome = $fakeHome.TrimEnd('\', '/') -replace '\\', '/'
    $conversionCases = @(
        ,@('home', (winpath '~'), $unixHome)
        ,@('home child', (winpath '~/alpha/beta'), "$unixHome/alpha/beta")
        ,@('unix drive root', (winpath "/$driveLetter"), "$driveLetterUpper`:/")
        ,@('unix drive root slash', (winpath "/$driveLetter/"), "$driveLetterUpper`:/")
        ,@('unix absolute', (winpath "/$driveLetter/alpha/beta"), "$driveLetterUpper`:/alpha/beta")
        ,@('relative unchanged', (winpath 'alpha/beta'), 'alpha/beta')
        ,@('windows absolute', (unixpath "$driveLetterUpper`:\alpha\beta"), "/$driveLetter/alpha/beta")
        ,@('slash-prefixed windows absolute', (unixpath "/$driveLetterUpper`:/alpha/beta"), "/$driveLetter/alpha/beta")
        ,@('windows root', (unixpath "$driveLetterUpper`:\"), "/$driveLetter/")
        ,@('slash-prefixed windows root', (unixpath "/$driveLetterUpper`:/"), "/$driveLetter/")
        ,@('drive-relative path', (unixpath "$driveLetterUpper`:alpha"), "$driveLetterUpper`:alpha")
        ,@('drive-relative value', (unixpath "$driveLetterUpper`:foo/bar"), "$driveLetterUpper`:foo/bar")
        ,@('slash-prefixed windows input', (winpath "/$driveLetterUpper`:/alpha/beta"), "$driveLetterUpper`:/alpha/beta")
        ,@('relative separator', (unixpath 'alpha\beta'), 'alpha/beta')
        ,@('unc separator', (unixpath '\\server\share\dir'), '//server/share/dir')
    )
    foreach ($case in $conversionCases) {
        Invoke-CompletionTest "convert: $($case[0])" {
            Assert-Equal $case[1] $case[2]
        }
    }
    Invoke-CompletionTest 'argument conversion: home and unix paths only' {
        $converted = @(ConvertTo-WindowsArguments @('~', '~/notes', "/$driveLetter/tmp", 'C:relative', '--name'))
        Assert-Equal $converted.Count 5
        Assert-Equal $converted[0] $unixHome
        Assert-Equal $converted[1] "$unixHome/notes"
        Assert-Equal $converted[2] "$driveLetterUpper`:/tmp"
        Assert-Equal $converted[3] 'C:relative'
        Assert-Equal $converted[4] '--name'
    }
    Invoke-CompletionTest 'semantics: unix absolute path is rewritten' {
        $line = ConvertTo-WindowsCommandLine "ls $unixWork"
        $windowsWork = $work -replace '\\', '/'
        Assert-True ($line.Contains($windowsWork)) "unix path was not rewritten: $line"
        Assert-True ($unixWork -notin $line) "unix path remained in rewritten line: $line"
    }
    Invoke-CompletionTest 'semantics: unquoted glob stays on the command line' {
        $line = ConvertTo-WindowsCommandLine 'ls target-*'
        Assert-Equal $line 'ls target-*'
        $line = ConvertTo-WindowsCommandLine 'cp opsp/* dest'
        Assert-Equal $line 'cp opsp/* dest'
    }
    Invoke-CompletionTest 'execute: glob operands expand without rewriting the line' {
        $expanded = @(ConvertTo-WindowsPathOperands @('target-*'))
        Assert-True ($expanded.Count -gt 1) "glob operands were not expanded: $expanded"
        Assert-True (@($expanded | Where-Object { $_ -like 'target-unique*' }).Count -gt 0) "missing target-unique in $($expanded -join ', ')"
        Assert-True (@($expanded | Where-Object { $_ -like 'target-dir*' }).Count -gt 0) "missing target-dir in $($expanded -join ', ')"
        Assert-True (@($expanded | Where-Object { $_ -like '*[*?]*' }).Count -eq 0) "literal glob leaked into operands: $($expanded -join ', ')"
    }
    Invoke-CompletionTest 'semantics: quoted glob stays literal' {
        $line = ConvertTo-WindowsCommandLine "ls 'target-*'"
        Assert-Equal $line "ls 'target-*'"
    }
    Invoke-CompletionTest 'semantics: git ref is not treated as a path' {
        $line = ConvertTo-WindowsCommandLine 'git checkout feature/aaaa'
        Assert-Equal $line 'git checkout feature/aaaa'
    }
    Invoke-CompletionTest 'semantics: options stay unchanged' {
        $line = ConvertTo-WindowsCommandLine 'ls --all'
        Assert-Equal $line 'ls --all'
    }

    # Completion quoting must be safe for PowerShell parsing while retaining slash paths.
    $quoteCases = @(
        ,@('plain', 'target-dir/', 'target-dir/')
        ,@('space', 'space alpha/', "'space alpha/'")
        ,@('single quote', "quote's-dir/", "'quote''s-dir/'")
        ,@('dollar', 'cash$dir/', "'cash`$dir/'")
        ,@('ampersand', 'amp&dir/', "'amp&dir/'")
        ,@('semicolon', 'semi;dir/', "'semi;dir/'")
        ,@('hash', 'hash#dir/', "'hash#dir/'")
        ,@('parenthesis', 'paren(dir)/', "'paren(dir)/'")
        ,@('bracket', '[bracket]-dir/', "'[bracket]-dir/'")
        ,@('leading dash', '-dash-dir/', "'-dash-dir/'")
        ,@('unicode', '中文目录/', '中文目录/')
    )
    foreach ($case in $quoteCases) {
        Invoke-CompletionTest "quote: $($case[0])" {
            Assert-Equal (ConvertTo-QuotedText $case[1]) $case[2]
            Assert-Equal (ConvertFrom-QuotedText $case[2]) $case[1]
        }
    }

    # Direct filesystem completion boundaries.
    $fileSystemCases = @(
        ,@('relative directory', 'target-u', 'target-unique/')
        ,@('relative file', 'target-f', 'target-file.txt')
        ,@('nested forward slash', 'target-dir/ch', 'target-dir/child-dir/')
        ,@('nested backslash', 'target-dir\ch', 'target-dir/child-dir/')
        ,@('relative slash path', 'target-dir/child-', 'target-dir/child-file.txt')
        ,@('explicit current forward', './target-u', './target-unique/')
        ,@('explicit current backslash', '.\target-u', './target-unique/')
        ,@('parent forward', '../sib', '../sibling-dir/')
        ,@('parent backslash', '..\sib', '../sibling-dir/')
        ,@('unix absolute', "$unixWork/target-u", "$unixWork/target-unique/")
        ,@('windows absolute', (Join-Path $work 'target-u'), "$unixWork/target-unique/")
        ,@('slash-prefixed windows absolute', "$slashPrefixedWindowsWork/target-u", "$unixWork/target-unique/")
        ,@('space', 'space a', "'space alpha/'")
        ,@('single quote', 'quote', "'quote''s-dir/'")
        ,@('unicode', '中', '中文目录/')
        ,@('case insensitive', 'case', 'CaseDir/')
        ,@('hidden explicit', '.hidden-d', '.hidden-dir/')
        ,@('hidden nested', 'app-factory/', 'app-factory/.git/')
        ,@('home hidden file', '~/.vimi', '~/.viminfo')
        ,@('home hidden directory', '~/.vim', '~/.vim/')
        ,@('special dollar', 'cash', "'cash`$dir/'")
        ,@('special ampersand', 'amp', "'amp&dir/'")
        ,@('special semicolon', 'semi', "'semi;dir/'")
        ,@('special hash', 'hash', "'hash#dir/'")
        ,@('special parenthesis', 'paren', "'paren(dir)/'")
        ,@('special bracket', '[b', "'[bracket]-dir/'")
        ,@('leading dash', '-d', "'-dash-dir/'")
    )
    foreach ($case in $fileSystemCases) {
        Invoke-CompletionTest "filesystem: $($case[0])" {
            $values = @(Get-FileSystemCompletionTexts $case[1])
            Assert-Contains $values $case[2]
            Assert-NoBackslash $values
            Assert-NoUppercaseWindowsDrivePrefix $values
        }
    }
    Invoke-CompletionTest 'path-like detection: relative slash and home paths' {
        Assert-True (Test-PathLikeToken 'target-dir/child-') 'relative slash path was not detected'
        Assert-True (Test-PathLikeToken '~/alpha') 'home path was not detected'
        Assert-True (-not (Test-PathLikeToken 'feature-name')) 'plain value was misdetected as a path'
    }

    Invoke-CompletionTest 'upwsh: top-level subcommands' {
        $state = Complete-HookLine -Line 'upwsh '
        $values = @($state.Matches | ForEach-Object CompletionText)
        foreach ($expected in @('install', 'update', 'uninstall', 'tool', 'theme', 'edit')) {
            Assert-Contains $values $expected
        }
    }
    Invoke-CompletionTest 'upwsh: tool action and tool names' {
        $state = Complete-HookLine -Line 'upwsh tool in'
        $values = @($state.Matches | ForEach-Object CompletionText)
        Assert-Contains $values 'install'
        Assert-True ('uninstall' -notin $values) 'substring filter matched uninstall for prefix in'
        $state = Complete-HookLine -Line 'upwsh tool install du'
        $values = @($state.Matches | ForEach-Object CompletionText)
        Assert-Contains $values 'duf'
        Assert-Contains $values 'dust'
    }
    Invoke-CompletionTest 'upwsh: theme use completes installed theme names' {
        $themeDir = Join-Path $fakeHome '.config\upwsh\theme'
        New-Item -ItemType Directory -Path $themeDir -Force | Out-Null
        [IO.File]::WriteAllText((Join-Path $themeDir 'colorful-blue.json'), '{}')
        [IO.File]::WriteAllText((Join-Path $themeDir 'pure-classic.json'), '{}')
        try {
            $state = Complete-HookLine -Line 'upwsh theme use co'
            $values = @($state.Matches | ForEach-Object CompletionText)
            Assert-Contains $values 'colorful-blue'
            $state = Complete-HookLine -Line 'upwsh theme use pure-class'
            $values = @($state.Matches | ForEach-Object CompletionText)
            Assert-Contains $values 'pure-classic'
        } finally {
            Remove-Item -LiteralPath (Join-Path $fakeHome '.config\upwsh') -Recurse -Force -ErrorAction SilentlyContinue
        }
    }
    Invoke-CompletionTest 'upwsh: install and update offer source flags' {
        $state = Complete-HookLine -Line 'upwsh install --'
        $values = @($state.Matches | ForEach-Object CompletionText)
        Assert-Contains $values '--local'
        Assert-Contains $values '--remote'
        $state = Complete-HookLine -Line 'upwsh update --l'
        $values = @($state.Matches | ForEach-Object CompletionText)
        Assert-Contains $values '--local'
    }
    Invoke-CompletionTest 'filesystem: multiple candidates' {
        $values = @(Get-FileSystemCompletionTexts 'target-')
        Assert-Contains $values 'target-alpha/'
        Assert-Contains $values 'target-beta/'
        Assert-Contains $values 'target-file.txt'
        Assert-NoBackslash $values
        Assert-NoUppercaseWindowsDrivePrefix $values
    }
    Invoke-CompletionTest 'filesystem: directory only excludes files' {
        $values = @(Get-FileSystemCompletionTexts 'target-' -DirectoryOnly)
        Assert-Contains $values 'target-unique/'
        Assert-True ('target-file.txt' -notin $values) 'directory-only result contained a file'
        Assert-NoUppercaseWindowsDrivePrefix $values
    }
    Invoke-CompletionTest 'filesystem: empty word hides hidden entries' {
        $values = @(Get-FileSystemCompletionTexts '')
        Assert-True ('.hidden-dir/' -notin $values) 'empty prefix exposed a hidden directory'
        Assert-True ('.hidden-file' -notin $values) 'empty prefix exposed a hidden file'
    }
    Invoke-CompletionTest 'filesystem: current directory is not a hidden prefix' {
        $values = @(Get-FileSystemCompletionTexts '.')
        Assert-Contains $values 'target-unique/'
        Assert-True ('.hidden-dir/' -notin $values) 'bare current directory exposed hidden entries'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'filesystem: parent directory is not a hidden prefix' {
        $values = @(Get-FileSystemCompletionTexts '..')
        Assert-Contains $values '../sibling-dir/'
        Assert-True ('.hidden-dir/' -notin $values) 'parent directory prefix exposed hidden entries'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'filesystem: missing prefix has no direct candidates' {
        $values = @(Get-FileSystemCompletionTexts 'does-not-exist')
        Assert-Equal $values.Count 0
    }
    Invoke-CompletionTest 'filesystem: slash root lists drives' {
        $values = @(Get-FileSystemCompletionTexts '/')
        Assert-Contains $values "/$driveLetter/"
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'filesystem: bare drive remains absolute' {
        $values = @(Get-FileSystemCompletionTexts "/$driveLetter")
        Assert-True ($values.Count -gt 0) 'bare drive produced no candidates'
        Assert-True (
            @(
                $values |
                    ForEach-Object { ConvertFrom-QuotedText $_ } |
                    Where-Object { $_ -notmatch "^/$driveLetter/" }
            ).Count -eq 0
        ) 'bare drive produced a non-unix absolute path'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'filesystem: wildcard current token completes matching names' {
        $values = @(Get-FileSystemCompletionTexts 'target-*')
        Assert-Contains $values 'target-unique/'
        Assert-Contains $values 'target-alpha/'
        Assert-Contains $values 'target-file.txt'
        Assert-True ('app-factory/' -notin $values) 'wildcard matched an unrelated name'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'filesystem: destination after wildcard source still completes' {
        $values = @(Get-TabCompletionTexts 'cp target-* app-f')
        Assert-Contains $values 'app-factory/'
        Assert-NoBackslash $values
    }

    # Central post-processing of PowerShell default completion results.
    $normalizationCases = @(
        ,@('relative directory', '.\target-unique', 'target-u', 'ProviderContainer', 'target-unique/')
        ,@('explicit current directory', '.\target-unique', './target-u', 'ProviderContainer', './target-unique/')
        ,@('explicit current backslash prefix', '.\target-unique', '.\target-u', 'ProviderContainer', './target-unique/')
        ,@('relative file', '.\target-file.txt', 'target-f', 'ProviderItem', 'target-file.txt')
        ,@('absolute directory', "$driveLetterUpper`:\alpha\beta", "$driveLetterUpper`:\a", 'ProviderContainer', "/$driveLetter/alpha/beta/")
        ,@('unc directory', '\\server\share\dir', '\\server\share\d', 'ProviderContainer', '//server/share/dir/')
        ,@('quoted path', "'.\space alpha'", 'space a', 'ProviderContainer', "'space alpha/'")
    )
    foreach ($case in $normalizationCases) {
        Invoke-CompletionTest "normalize: $($case[0])" {
            $result = [System.Management.Automation.CompletionResult]::new(
                $case[1],
                $case[1],
                $case[3],
                $case[1]
            )
            $normalized = ConvertTo-UnixCompletionResult `
                -Match $result `
                -CurrentText $case[2]
            Assert-Equal $normalized.CompletionText $case[4]
        }
    }
    Invoke-CompletionTest 'normalize: home prefix stays as tilde' {
        $homeChild = Join-Path $fakeHome 'alpha'
        $result = [System.Management.Automation.CompletionResult]::new(
            $homeChild,
            $homeChild,
            'ProviderContainer',
            $homeChild
        )
        $normalized = ConvertTo-UnixCompletionResult -Match $result -CurrentText '~/al'
        Assert-Equal $normalized.CompletionText '~/alpha/'
    }
    Invoke-CompletionTest 'normalize: Git ref remains unchanged' {
        $result = [System.Management.Automation.CompletionResult]::new(
            'feature/aaaa',
            'feature/aaaa',
            'ParameterValue',
            'git ref'
        )
        $normalized = ConvertTo-UnixCompletionResult -Match $result -CurrentText 'feature/a'
        Assert-Equal $normalized.CompletionText 'feature/aaaa'
    }
    Invoke-CompletionTest 'normalize: command remains unchanged' {
        $result = [System.Management.Automation.CompletionResult]::new(
            'git',
            'git',
            'Command',
            'command'
        )
        $normalized = ConvertTo-UnixCompletionResult -Match $result -CurrentText 'g'
        Assert-Equal $normalized.CompletionText 'git'
    }
    Invoke-CompletionTest 'decision: unique path is normalized on demand' {
        $match = [System.Management.Automation.CompletionResult]::new(
            '.\target-unique',
            'target-unique',
            'ProviderContainer',
            '.\target-unique'
        )
        $decision = Get-CompletionDecision -Matches @($match) -CurrentText 'target-u'
        Assert-Equal $decision.MatchCount 1
        Assert-Equal $decision.Replacement 'target-unique/'
    }
    Invoke-CompletionTest 'decision: duplicate raw candidates count once' {
        $match = [System.Management.Automation.CompletionResult]::new(
            '.\target-unique',
            'target-unique',
            'ProviderContainer',
            '.\target-unique'
        )
        $decision = Get-CompletionDecision -Matches @($match, $match) -CurrentText 'target-u'
        Assert-Equal $decision.MatchCount 1
        Assert-Equal $decision.Replacement 'target-unique/'
    }
    Invoke-CompletionTest 'decision: normalized path candidates count once' {
        $matches = @(
            [System.Management.Automation.CompletionResult]::new(
                '.\target-unique', 'target-unique', 'ProviderContainer', '.\target-unique'
            )
            [System.Management.Automation.CompletionResult]::new(
                'target-unique/', 'target-unique', 'ProviderContainer', 'target-unique/'
            )
        )
        $decision = Get-CompletionDecision -Matches $matches -CurrentText 'target-u'
        Assert-Equal $decision.MatchCount 1
        Assert-Equal $decision.Replacement 'target-unique/'
    }
    Invoke-CompletionTest 'decision: path common prefix is normalized on demand' {
        $matches = @(
            [System.Management.Automation.CompletionResult]::new(
                '.\target-alpha', 'target-alpha', 'ProviderItem', '.\target-alpha'
            )
            [System.Management.Automation.CompletionResult]::new(
                '.\target-beta', 'target-beta', 'ProviderItem', '.\target-beta'
            )
        )
        $decision = Get-CompletionDecision -Matches $matches -CurrentText 't'
        Assert-Equal $decision.MatchCount 2
        Assert-Equal $decision.Replacement 'target-'
    }
    Invoke-CompletionTest 'decision: quoted common prefix remains valid' {
        $matches = @(
            [System.Management.Automation.CompletionResult]::new(
                "'.\space alpha'", 'space alpha', 'ProviderItem', '.\space alpha'
            )
            [System.Management.Automation.CompletionResult]::new(
                "'.\space beta'", 'space beta', 'ProviderItem', '.\space beta'
            )
        )
        $decision = Get-CompletionDecision -Matches $matches -CurrentText 'space '
        Assert-Equal $decision.MatchCount 2
        Assert-Equal $decision.Replacement "'space '"
    }
    Invoke-CompletionTest 'decision: Git ref common prefix remains semantic' {
        $matches = @(
            [System.Management.Automation.CompletionResult]::new(
                'feature/alpha', 'feature/alpha', 'ParameterValue', 'git ref'
            )
            [System.Management.Automation.CompletionResult]::new(
                'feature/beta', 'feature/beta', 'ParameterValue', 'git ref'
            )
        )
        $decision = Get-CompletionDecision -Matches $matches -CurrentText 'feature/'
        Assert-Equal $decision.MatchCount 2
        Assert-Equal $decision.Replacement 'feature/'
    }

    Invoke-CompletionTest 'integration: path-like home hidden' {
        $values = @(Get-TabCompletionTexts 'vim ~/.vimi')
        Assert-Contains $values '~/.viminfo'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'integration: slash-prefixed Windows path stays canonical' {
        $line = "vim $slashPrefixedWindowsWork/target-u"
        $values = @(Get-TabCompletionTexts $line)
        Assert-Contains $values "$unixWork/target-unique/"
        Assert-NoBackslash $values
        Assert-NoUppercaseWindowsDrivePrefix $values
    }
    Invoke-CompletionTest 'integration: explicit relative pathspec' {
        $values = @(Get-TabCompletionTexts 'git checkout -- ./target-u')
        Assert-Contains $values './target-unique/'
        Assert-NoBackslash $values
    }

    Invoke-CompletionTest 'tab: backslash relative unique keeps ./' {
        $line = 'ls .\app'
        $state = Complete-HookLine -Line $line -Cursor $line.Length
        $current = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
        $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $current
        Assert-Equal $decision.MatchCount 1
        Assert-Equal $decision.Replacement './app-factory/'
        $replaced = $line.Remove($state.ReplacementIndex, $state.ReplacementLength).Insert(
            $state.ReplacementIndex,
            $decision.Replacement
        )
        Assert-Equal $replaced 'ls ./app-factory/'
    }
    Invoke-CompletionTest 'tab: forward relative unique keeps ./' {
        $line = 'ls ./app'
        $state = Complete-HookLine -Line $line -Cursor $line.Length
        $current = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
        $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $current
        Assert-Equal $decision.Replacement './app-factory/'
    }
    Invoke-CompletionTest 'tab: unix drive root lists candidates' {
        $line = "ls /$driveLetter/"
        $values = @(Get-TabCompletionTexts $line)
        Assert-True ($values.Count -gt 1) "drive root produced $($values.Count) candidates"
        Assert-NoBackslash $values
        Assert-NoUppercaseWindowsDrivePrefix $values
    }
    Invoke-CompletionTest 'tab: wrapped TabExpansion2 lists unix drive children' {
        $line = "ls /$driveLetter/"
        $completion = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        $values = @($completion.CompletionMatches | ForEach-Object CompletionText)
        Assert-True ($values.Count -gt 1) 'wrapped TabExpansion2 produced no candidates'
        Assert-NoBackslash $values
        Assert-NoUppercaseWindowsDrivePrefix $values
    }
    Invoke-CompletionTest 'tab: glob token keeps matches without requiring unique prefix' {
        $line = 'ls target-*'
        $state = Complete-HookLine -Line $line -Cursor $line.Length
        $current = $line.Substring($state.ReplacementIndex, $state.ReplacementLength)
        $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $current
        Assert-True ($decision.MatchCount -gt 1) 'glob token should have multiple matches'
        $values = @($state.Matches | ForEach-Object CompletionText)
        Assert-Contains $values 'target-unique/'
    }
    Invoke-CompletionTest 'semantics: bare unix directory becomes cd' {
        $line = ConvertTo-WindowsCommandLine "/$driveLetter/"
        Assert-Equal $line "cd ${driveLetterUpper}:/"
    }
    Invoke-CompletionTest 'semantics: ls unix drive stays a listing command' {
        $line = ConvertTo-WindowsCommandLine "ls /$driveLetter/"
        Assert-Equal $line "ls ${driveLetterUpper}:/"
        $line = ConvertTo-WindowsCommandLine "ls /$driveLetter"
        Assert-Equal $line "ls ${driveLetterUpper}:/"
    }
    Invoke-CompletionTest 'eza: passes converted operands to the binary' {
        $definition = (Get-Command Invoke-Eza).Definition
        Assert-True ($definition -match 'windowsArguments') 'Invoke-Eza lost converted operand variable'
        Assert-True ($definition -notmatch 'nativeArguments') 'Invoke-Eza still splats renamed nativeArguments'
    }
    Invoke-CompletionTest 'eza: unix drive argument is converted' {
        $expanded = @(Expand-PathGlob (winpath "/$driveLetter/"))
        Assert-Equal $expanded.Count 1
        Assert-Equal $expanded[0] "${driveLetterUpper}:/"
    }

    Invoke-CompletionTest 'path hook: missing files keep git-style matches' {
        $line = 'git checkout feature/aa'
        $state = [pscustomobject]@{
            Line              = $line
            Cursor            = $line.Length
            ReplacementIndex  = 13
            ReplacementLength = 10
            Matches           = @(
                [System.Management.Automation.CompletionResult]::new(
                    'feature/aaaa',
                    'feature/aaaa',
                    'ParameterValue',
                    'ref'
                )
            )
        }
        $state = Invoke-PathCompletionHook -State $state
        Assert-Equal @($state.Matches).Count 1
        Assert-Equal $state.Matches[0].CompletionText 'feature/aaaa'
    }
    Invoke-CompletionTest 'path hook: existing relative slash uses filesystem' {
        $values = @(Get-TabCompletionTexts 'ls target-dir/ch')
        Assert-Contains $values 'target-dir/child-dir/'
        Assert-NoBackslash $values
    }
    Invoke-CompletionTest 'tab: reserved Windows device names do not throw' {
        $reserved = Join-Path $work 'nul'
        $extended = '\\?\' + $reserved
        [IO.File]::WriteAllText($extended, '')
        try {
            $values = @(Get-TabCompletionTexts 'rm nu')
            Assert-True ('nul' -notin @($values)) 'reserved device name was offered as a completion'
            $files = @(Get-FileSystemCompletionTexts 'nu')
            Assert-True ('nul' -notin @($files)) 'filesystem completer offered a reserved device name'
        } finally {
            if ([IO.File]::Exists($extended)) { [IO.File]::Delete($extended) }
        }
    }
    Invoke-CompletionTest 'enter: functions and applications share path rewriting' {
        Assert-True (
            Test-WindowsCommandLineReplacement `
                -Original "ls /$driveLetter/" `
                -Converted "ls ${driveLetterUpper}:/"
        ) 'function arguments should use the same path rules'
        Assert-True (
            Test-WindowsCommandLineReplacement `
                -Original 'vim /i/test/notes.txt' `
                -Converted 'vim I:/test/notes.txt'
        ) 'vim should replace the command line for the TUI'
        Assert-True (
            Test-WindowsCommandLineReplacement `
                -Original "/$driveLetter/" `
                -Converted "cd ${driveLetterUpper}:/"
        ) 'bare directory should become cd'
    }

    if ($script:Failures.Count -gt 0) {

        $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
        throw "$($script:Failures.Count) of $($script:Passed + $script:Failures.Count) path completion tests failed."
    }

    Write-Output "$script:Passed path completion tests passed."
} finally {
    if ($locationPushed) {
        Pop-Location -ErrorAction SilentlyContinue
    }
    Set-Variable -Name HOME -Value $originalHome -Scope Global -Force
    $env:UPWSH_HOME = $originalUpwshHome
    if (Test-Path -LiteralPath $root) {
        Remove-Item -LiteralPath $root -Recurse -Force
    }
}
