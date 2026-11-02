$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    Invoke-UpwshIsolatedTest -File $PSCommandPath
    exit $LASTEXITCODE
}
. (Join-Path $PSScriptRoot '..\src\profile.ps1')
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()
function Test-GitCase {
    param([string]$Name, [scriptblock]$Body)
    try { & $Body; $script:Passed++ } catch { $script:Failures.Add("$Name`: $($_.Exception.Message)") }
}
function Assert-Equal {
    param($Actual, $Expected)
    if ([string]$Actual -cne [string]$Expected) { throw "expected <$Expected>, got <$Actual>" }
}
function Get-GitCandidates {
    param([string]$Line)
    @((Complete-HookLine -Line $Line).Matches | ForEach-Object CompletionText)
}
function Complete-GitTab {
    param([string]$Line, [int]$Cursor = $Line.Length)

    $state = Complete-HookLine -Line $Line -Cursor $Cursor
    $current = $Line.Substring($state.ReplacementIndex, $state.ReplacementLength)
    $decision = Get-CompletionDecision -Matches $state.Matches -CurrentText $current -Normalized:$state.MatchesNormalized -LiteralPaths:$state.LiteralPaths
    $module = (Get-Command Complete-HookLine).Module
    $edit = & $module { param($state, $decision) Get-HookCompletionEdit -State $state -Decision $decision } $state $decision
    [pscustomobject]@{
        Line = $Line.Remove($edit.Start, $edit.Length).Insert($edit.Start, $edit.Text)
        Cursor = $edit.Start + $edit.Text.Length
    }
}
function Assert-Candidate {
    param([string]$Line, [string]$Expected)
    $values = @(Get-GitCandidates $Line)
    if ($Expected -cnotin $values) { throw "$Line missed $Expected; got $($values -join ', ')" }
}
function Invoke-FixtureGit {
    & $script:GitExe @args 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) { throw "fixture git failed: $args" }
}

$script:GitExe = (Get-Command git -CommandType Application -ErrorAction Stop | Select-Object -First 1).Source
$fixture = Join-Path $HOME "repo with space's"
[void][IO.Directory]::CreateDirectory($fixture)
# All Git mutations below are confined to a disposable fixture, never the project repository.
Invoke-FixtureGit init --initial-branch=main $fixture
Invoke-FixtureGit -C $fixture -c user.name=Fixture -c user.email=fixture@example.invalid -c commit.gpgsign=false commit --allow-empty -m fixture
foreach ($branch in @('feature/one', 'feature/two', 'UpperCase')) { Invoke-FixtureGit -C $fixture branch $branch }
Invoke-FixtureGit -C $fixture tag v1.0
Invoke-FixtureGit -C $fixture remote add origin https://example.invalid/repo.git
Invoke-FixtureGit -C $fixture remote add upstream https://example.invalid/upstream.git
Invoke-FixtureGit -C $fixture update-ref refs/remotes/origin/main HEAD
Invoke-FixtureGit -C $fixture update-ref refs/remotes/origin/topic HEAD
Invoke-FixtureGit -C $fixture symbolic-ref refs/remotes/origin/HEAD refs/remotes/origin/main
Invoke-FixtureGit -C $fixture update-ref refs/remotes/upstream/only-upstream HEAD
[void][IO.Directory]::CreateDirectory((Join-Path $fixture 'feature'))
[IO.File]::WriteAllText((Join-Path $fixture 'feature\file-not-branch.txt'), '')
[IO.File]::WriteAllText((Join-Path $fixture 'notes.txt'), '')
Push-Location $fixture
try {
    Test-GitCase 'common subcommands complete without querying a repository' {
        Push-Location $HOME
        try {
            Assert-Candidate 'git ' 'status'
            Assert-Candidate 'git ch' 'checkout'
            Assert-Candidate 'git ch' 'cherry-pick'
            Assert-Equal ((Get-GitCandidates 'git sw') -join '|') 'switch'
        } finally { Pop-Location }
    }
    Test-GitCase 'unique Git words append one space for continuous completion' {
        $step = Complete-GitTab 'git pul'
        Assert-Equal $step.Line 'git pull '
        Assert-Equal $step.Cursor $step.Line.Length
        $step = Complete-GitTab ($step.Line + 'o')
        Assert-Equal $step.Line 'git pull origin '
        $step = Complete-GitTab ($step.Line + 'ma')
        Assert-Equal $step.Line 'git pull origin main '
        Assert-Equal $step.Cursor $step.Line.Length
    }
    Test-GitCase 'an already complete unique word also advances to the next argument' {
        Assert-Equal (Complete-GitTab 'git pull').Line 'git pull '
        Assert-Equal (Complete-GitTab 'git chec').Line 'git checkout '
    }
    Test-GitCase 'ambiguous common prefixes do not append a space' {
        Assert-Equal (Complete-GitTab 'git ch').Line 'git che'
        Assert-Equal (Complete-GitTab 'git switch fe').Line 'git switch feature/'
    }
    Test-GitCase 'completion reuses existing whitespace and moves the cursor past it' {
        $step = Complete-GitTab 'git pul origin main' 7
        Assert-Equal $step.Line 'git pull origin main'
        Assert-Equal $step.Cursor 9
        $step = Complete-GitTab 'git pull o main' 10
        Assert-Equal $step.Line 'git pull origin main'
        Assert-Equal $step.Cursor 16
        $step = Complete-GitTab "git pul`torigin" 7
        Assert-Equal $step.Line "git pull`torigin"
        Assert-Equal $step.Cursor 9
    }
    Test-GitCase 'quoted refs get a separator outside the completed word' {
        Assert-Equal (Complete-GitTab "git checkout 'feature/o'").Line 'git checkout feature/one '
    }
    Test-GitCase 'file and directory completion keep their existing behavior' {
        Assert-Equal (Complete-GitTab 'git add ./no').Line 'git add ./notes.txt'
        Assert-Equal (Complete-GitTab 'git add ./fea').Line 'git add ./feature/'
    }
    Test-GitCase 'completion before syntax delimiters does not add separators' {
        $step = Complete-GitTab 'git pul; Write-Output done' 7
        Assert-Equal $step.Line 'git pull; Write-Output done'
        Assert-Equal $step.Cursor 8
    }
    Test-GitCase 'switch suggests branches but not tags or symbolic remote HEAD' {
        Assert-Candidate 'git switch ' 'main'
        Assert-Candidate 'git switch --track ' 'origin/main'
        $values = Get-GitCandidates 'git switch '
        if ('v1.0' -in $values -or 'origin/main' -in $values -or 'origin/HEAD' -in $values) { throw 'wrong switch candidates' }
    }
    Test-GitCase 'checkout merges bare filesystem paths with refs' {
        Assert-Candidate 'git checkout fe' 'feature/one'
        Assert-Candidate 'git checkout fe' 'feature/two'
        Assert-Candidate 'git checkout fe' 'feature/'
        Assert-Candidate 'git checkout feature/fi' 'feature/file-not-branch.txt'
        Assert-Equal (Complete-GitTab 'git checkout no').Line 'git checkout notes.txt '
        Assert-Equal (Complete-GitTab 'git checkout -- no').Line 'git checkout -- notes.txt'
        if ('notes.txt' -in (Get-GitCandidates 'git switch no')) { throw 'switch leaked filesystem candidates' }
    }
    Test-GitCase 'checkout merge and rebase provide refs' {
        foreach ($verb in @('checkout', 'merge', 'rebase', 'cherry-pick', 'show', 'reset')) {
            Assert-Candidate "git $verb fe" 'feature/one'
            Assert-Candidate "git $verb v" 'v1.0'
        }
        Assert-Candidate 'git switch --detach v' 'v1.0'
    }
    Test-GitCase 'branch names containing slashes are not replaced by filesystem candidates' {
        $values = Get-GitCandidates 'git checkout feature/'
        Assert-Equal ($values -join '|') 'feature/one|feature/two|feature/file-not-branch.txt'
        Assert-Equal (Get-GitCandidates 'git switch feature/file').Count 0
    }
    Test-GitCase 'ref matching preserves case' {
        Assert-Equal ((Get-GitCandidates 'git switch U') -join '|') 'UpperCase'
        $matches = @(foreach ($ref in @('feature/A', 'feature/a')) {
            [Management.Automation.CompletionResult]::new($ref, $ref, 'ParameterValue', 'git ref')
        })
        $result = Get-CompletionDecision -Matches $matches -CurrentText 'feature/' -Normalized
        Assert-Equal $result.MatchCount 2
        Assert-Equal $result.Replacement 'feature/'
    }
    Test-GitCase 'configured remotes and cached remote branches complete without network access' {
        foreach ($verb in @('push', 'pull', 'fetch')) { Assert-Candidate "git $verb o" 'origin' }
        Assert-Candidate 'git push -u origin fe' 'feature/one'
        Assert-Candidate 'git push origin v' 'v1.0'
        Assert-Candidate 'git pull origin to' 'topic'
        Assert-Candidate 'git fetch upstream only' 'only-upstream'
        if ('only-upstream' -in (Get-GitCandidates 'git pull origin ')) { throw 'other remote leaked' }
    }
    Test-GitCase 'remote and branch maintenance use limited completions' {
        Assert-Candidate 'git remote ' 'add'
        Assert-Candidate 'git remote remove o' 'origin'
        Assert-Candidate 'git branch -d fe' 'feature/one'
        if ('origin/main' -in (Get-GitCandidates 'git branch -d ')) { throw 'branch delete suggested remote ref' }
    }
    Test-GitCase 'file commands and double dash retain path completion' {
        Assert-Candidate 'git add ./no' './notes.txt'
        Assert-Candidate 'git checkout -- ./no' './notes.txt'
        Assert-Candidate 'git restore ./no' './notes.txt'
    }
    Test-GitCase 'git -C queries the requested directory with spaces and quotes' {
        Push-Location $HOME
        try { Assert-Candidate ("git -C " + (ConvertTo-TestLiteral $fixture) + ' switch fe') 'feature/one' }
        finally { Pop-Location }
    }
    Test-GitCase 'active command and cursor replacement do not disturb surrounding text' {
        Assert-Candidate 'Write-Output ignored; git sw' 'switch'
        $line = 'git checkout fe; Write-Output untouched'
        $cursor = $line.IndexOf(';')
        $state = Complete-HookLine -Line $line -Cursor $cursor
        Assert-Equal $line.Substring($state.ReplacementIndex, $state.ReplacementLength) 'fe'
        Assert-Equal ($state.Matches.CompletionText -join '|') 'feature/one|feature/two|feature/'
    }
    Test-GitCase 'quoted refs and git.exe use the same candidates' {
        Assert-Candidate "git checkout 'feature/o'" 'feature/one'
        Assert-Candidate 'git.exe sw' 'switch'
    }
    Test-GitCase 'new refs appear after command execution and native exit status is preserved' {
        $null = Get-GitCandidates 'git switch new'
        Set-HookPromptInput -Line 'git branch new-branch'
        Invoke-FixtureGit branch new-branch
        $global:LASTEXITCODE = 7
        Assert-Candidate 'git switch new' 'new-branch'
        Assert-Equal $global:LASTEXITCODE 7
    }
    Test-GitCase 'Git completion does not run for ordinary file completion or empty Enter' {
        $module = (Get-Command Get-GitCompletion).Module
        $saved = & $module { (Get-Command Read-GitCompletionData).ScriptBlock }
        try {
            & $module { Set-Item Function:Read-GitCompletionData { throw 'unexpected Git query' } }
            Assert-Candidate 'git sw' 'switch'
            Assert-Candidate 'git add ./no' './notes.txt'
            Assert-Candidate 'ls ./no' './notes.txt'
            $oldOut = [Console]::Out
            try {
                [Console]::SetOut([IO.TextWriter]::Null)
                $null = prompt
                Set-HookPromptInput -Line ''
                $null = prompt
            } finally { [Console]::SetOut($oldOut) }
        } finally { & $module { param($body) Set-Item Function:Read-GitCompletionData $body } $saved }
    }
    Test-GitCase 'outside a repository ref completion is empty and silent' {
        Push-Location $HOME
        try { Assert-Equal (Get-GitCandidates 'git switch ').Count 0 } finally { Pop-Location }
    }
    Test-GitCase 'unhandled Git syntax declines rather than guessing' {
        foreach ($line in @('git commit -m text', 'git switch -c new', 'git -c core.bare=false switch ', 'git --git-dir=/tmp switch ', 'git push origin main:other', 'git --% switch fe', 'git show > ./file')) {
            $tokens = $null; $errors = $null
            $ast = [Management.Automation.Language.Parser]::ParseInput($line, [ref]$tokens, [ref]$errors)
            Assert-Equal ($null -eq (Get-GitCompletion -Line $line -Cursor $line.Length -Ast $ast)) $true
        }
    }
} finally { Pop-Location }
if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) Git completion tests failed."
}
Write-Output "$script:Passed Git completion tests passed."
