$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    Invoke-UpwshIsolatedTest -File $PSCommandPath
    exit $LASTEXITCODE
}
. (Join-Path $PSScriptRoot '..\src\profile.ps1')
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()
function Test-Interaction {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++ } catch { $script:Failures.Add("$Name`: $($_.Exception.Message)") }
}
function Assert-Equal {
    param($Actual, $Expected)
    if ([string]$Actual -cne [string]$Expected) { throw "expected <$Expected>, got <$Actual>" }
}
function Capture-TermPrompt {
    param([bool]$Succeeded = $true, [int]$ExitCode = 0, [bool]$CommandCompleted = $true)
    $original = [Console]::Out
    $writer = [IO.StringWriter]::new()
    try {
        [Console]::SetOut($writer)
        Sync-TermPrompt -Succeeded $Succeeded -ExitCode $ExitCode -CommandCompleted:$CommandCompleted
        $writer.ToString()
    } finally {
        [Console]::SetOut($original)
        $writer.Dispose()
    }
}

Test-Interaction 'normalized paths preserve unique count and common prefix for 1000 entries' {
    $matches = @(foreach ($i in 1..1000) {
        $text = './files/file-{0:d4}.txt' -f $i
        [Management.Automation.CompletionResult]::new($text, $text, 'ProviderItem', $text)
    })
    $result = Get-CompletionDecision -Matches ($matches + $matches[0]) -CurrentText './files/' -Normalized
    Assert-Equal $result.MatchCount 1000
    Assert-Equal $result.Replacement './files/file-'
}
Test-Interaction 'empty prefix still counts all candidates' {
    $matches = @(foreach ($text in @('a', 'b', 'c')) {
        [Management.Automation.CompletionResult]::new($text, $text, 'ProviderItem', $text)
    })
    foreach ($normalized in @($false, $true)) {
        $result = Get-CompletionDecision -Matches $matches -CurrentText '' -Normalized:$normalized
        Assert-Equal $result.MatchCount 3
        Assert-Equal $result.Replacement ''
    }
}
Test-Interaction 'legacy conversion candidates normalize to plain quoted common prefixes' {
    $matches = @(foreach ($text in @("(winpath '/c/my work/a')", "(winpath '/c/my work/b')")) {
        [Management.Automation.CompletionResult]::new($text, $text, 'ProviderItem', $text)
    })
    $result = Get-CompletionDecision -Matches $matches -CurrentText '/c/my' -Normalized
    Assert-Equal $result.MatchCount 2
    Assert-Equal $result.Replacement "'/c/my work/'"
    $result = Get-CompletionDecision -Matches $matches -CurrentText '/c/my' -Normalized -LiteralPaths
    Assert-Equal $result.Replacement "'/c/my work/'"
}
Test-Interaction 'semantic candidates are not interpreted as normalized paths' {
    $matches = @(foreach ($text in @('feature/one', 'feature/two')) {
        [Management.Automation.CompletionResult]::new($text, $text, 'ParameterValue', 'ref')
    })
    Assert-Equal (Get-CompletionDecision -Matches $matches -CurrentText 'feature/' -Normalized).Replacement 'feature/'
}
Test-Interaction 'filesystem lists directories first and includes newly created files on the next query' {
    $fixture = Join-Path $HOME 'query'
    [void][IO.Directory]::CreateDirectory((Join-Path $fixture 'z-dir'))
    [IO.File]::WriteAllText((Join-Path $fixture 'a-file'), '')
    $prefix = (unixpath $fixture) + '/'
    $first = @(Get-UnixPathCompletion -WordToComplete $prefix)
    Assert-Equal $first.Count 2
    Assert-Equal $first[0].ResultType 'ProviderContainer'
    [IO.File]::WriteAllText((Join-Path $fixture 'b-new'), '')
    Assert-Equal (@(Get-UnixPathCompletion -WordToComplete $prefix)).Count 3
    $line = 'example ' + $prefix
    Assert-Equal (@((Complete-HookLine -Line $line).Matches)).Count 3
    [IO.File]::WriteAllText((Join-Path $fixture 'c-after-tab'), '')
    Assert-Equal (@((Complete-HookLine -Line $line).Matches)).Count 4
}
Test-Interaction 'the candidate display reuses only the active Tab request' {
    $hook = (Get-Command Complete-HookLine).Module
    $line = 'example ./query/'
    $match = [Management.Automation.CompletionResult]::new('cached-value', 'cached-value', 'ParameterValue', 'display fixture')
    try {
        & $hook { param($line, $match)
            $script:CompletionDisplayState = [pscustomobject]@{
                Line = $line; Cursor = $line.Length; Matches = @($match); ReplacementIndex = 8; ReplacementLength = 8
            }
        } $line $match
        $completion = TabExpansion2 -inputScript $line -cursorColumn $line.Length
        Assert-Equal $completion.CompletionMatches[0].CompletionText 'cached-value'
    } finally { & $hook { $script:CompletionDisplayState = $null } }
}
Test-Interaction 'idle terminal reports omit unchanged state but retain boundaries' {
    $null = Capture-TermPrompt -CommandCompleted:$false
    $null = Capture-TermPrompt -CommandCompleted:$false
    $second = Capture-TermPrompt -CommandCompleted:$false
    if ($second.Contains('SetUserVar=')) { throw 'unchanged idle variables resent' }
    if (-not $second.Contains(']133;A') -or -not $second.Contains(']133;B')) { throw 'prompt boundaries missing' }
}
Test-Interaction 'terminal report cache follows status changes' {
    $null = Capture-TermPrompt
    $failed = Capture-TermPrompt -Succeeded $false -ExitCode 7
    if (-not $failed.Contains('SetUserVar=OK=MA==') -or -not $failed.Contains('SetUserVar=EXIT=Nw==')) { throw 'failure status stale' }
    $success = Capture-TermPrompt
    if (-not $success.Contains('SetUserVar=OK=MQ==') -or -not $success.Contains('SetUserVar=EXIT=MA==')) { throw 'success status stale' }
}
Test-Interaction 'terminal cache follows virtual environment changes at the same location' {
    $saved = $env:VIRTUAL_ENV
    try {
        $env:VIRTUAL_ENV = 'C:\venvs\one'
        $first = Capture-TermPrompt
        $env:VIRTUAL_ENV = 'C:\venvs\two'
        $second = Capture-TermPrompt
        if (-not $first.Contains('SetUserVar=VENV=b25l') -or -not $second.Contains('SetUserVar=VENV=dHdv')) { throw 'virtual environment stale' }
        $env:VIRTUAL_ENV = $null
        if (-not (Capture-TermPrompt).Contains("SetUserVar=VENV=`a")) { throw 'deactivation stale' }
    } finally { $env:VIRTUAL_ENV = $saved }
}
Test-Interaction 'terminal report cache follows directory changes' {
    $null = Capture-TermPrompt
    $directory = Join-Path $HOME 'new-location'
    [void][IO.Directory]::CreateDirectory($directory)
    Push-Location $directory
    try {
        $output = Capture-TermPrompt
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($directory))
        if (-not $output.Contains("SetUserVar=CWD=$encoded")) { throw 'directory stayed cached' }
    } finally { Pop-Location }
}
Test-Interaction 'changing enabled fields invalidates cached reports' {
    $term = (Get-Command Sync-TermPrompt).Module
    $null = Capture-TermPrompt
    try {
        & $term { Set-TermReporting -Fields @($script:TermReport | Where-Object { $_ -notin @('HOST', 'CWD') }) }
        $output = Capture-TermPrompt
        if ($output -match 'SetUserVar=(?:HOST|CWD)=[^\x07]+') { throw 'disabled field remained cached' }
    } finally { & $term { Set-TermReporting -Fields @(@($script:TermReport) + @('HOST', 'CWD')) } }
    if (-not (Capture-TermPrompt).Contains('SetUserVar=HOST=')) { throw 're-enabled field missing' }
}
Test-Interaction 'command elapsed time is emitted once rather than replayed from idle cache' {
    $original = [Console]::Out
    try { [Console]::SetOut([IO.TextWriter]::Null); Sync-TermCommand -Command 'fixture' } finally { [Console]::SetOut($original) }
    $completed = Capture-TermPrompt
    $idle = Capture-TermPrompt -CommandCompleted:$false
    if ($completed.Contains("SetUserVar=ELAPSED_MS=`a")) { throw 'elapsed time missing' }
    if (-not $idle.Contains("SetUserVar=ELAPSED_MS=`a")) { throw 'elapsed time repeated' }
}
if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) interaction tests failed."
}
Write-Output "$script:Passed interaction tests passed."
