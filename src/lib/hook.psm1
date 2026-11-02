# 按键与 prompt 管道。
#
# Tab:  completion -> path
# Enter: path rewrite -> accept
# ReadLine: submitted code -> command state
# prompt: render only after submission or layout change -> term

$script:SkipConvertedHistory = $false
$script:CommandPending = $false
$script:SubmittedParseError = $false
$script:ReadingInput = $false
$script:SubmittedDisplayLine = $null
$script:LastCommandSucceeded = $true
$script:LastCommandExitCode = 0
$script:LastNativeExitCode = 0
$script:LastCommandStatus = 'success'
$script:ErrorBeforeCommand = $null
$script:CachedPrompt = $null
$script:CachedPromptLocation = $null
$script:CachedPromptWidth = 0
$script:CachedPromptThemeRevision = -1

function Set-HookPromptInput {
    param([AllowEmptyString()][string]$Line = '')

    if (Test-CompleteCommandLine -InputScript $Line) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
        $script:SubmittedParseError = $errors.Count -gt 0
        $script:CommandPending = $true
        $script:ErrorBeforeCommand = $global:Error[0]
        Clear-GitCompletionCache
        Sync-TermCommand -Command $Line
    }
}

function Test-CompleteCommandLine {
    param(
        [AllowEmptyString()]
        [string]$InputScript = ''
    )

    if ([string]::IsNullOrWhiteSpace($InputScript)) {
        return $false
    }

    $tokens = $null
    $parseErrors = $null
    $ast = [System.Management.Automation.Language.Parser]::ParseInput(
        $InputScript,
        [ref]$tokens,
        [ref]$parseErrors
    )
    if (@($parseErrors | Where-Object IncompleteInput).Count) { return $false }
    # Comments/empty statements have no work, but declarations and submitted parse errors do.
    return $parseErrors.Count -gt 0 -or @($ast.EndBlock.Statements).Count -gt 0 -or
        $null -ne $ast.ParamBlock -or @($ast.UsingStatements).Count -gt 0
}

function Test-WindowsCommandLineReplacement {
    param(
        [string]$Original,
        [string]$Converted
    )

    if ($Converted -ceq $Original) {
        return $false
    }

    return $true
}

function New-HookState {
    param(
        [string]$Line,
        [int]$Cursor
    )

    [pscustomobject]@{
        Line               = $Line
        Cursor             = $Cursor
        ReplacementIndex   = 0
        ReplacementLength  = 0
        Matches            = @()
        LiteralPaths       = $false
        MatchesNormalized  = $false
        SpaceAfterWord     = $false
    }
}

function Complete-HookLine {
    param(
        [string]$Line,
        [int]$Cursor = -1
    )

    if ($Cursor -lt 0) {
        $Cursor = $Line.Length
    }

    $state = New-HookState -Line $Line -Cursor $Cursor
    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($Line, [ref]$tokens, [ref]$errors)
    $git = Get-GitCompletion -Line $Line -Cursor $Cursor -Ast $ast
    if ($null -ne $git) {
        $state.ReplacementIndex = $git.ReplacementIndex
        $state.ReplacementLength = $git.ReplacementLength
        $state.Matches = $git.Matches
        $state.MatchesNormalized = $true
        $state.SpaceAfterWord = $true
        if ($git.AllowPathCompletion) {
            $currentText = $Line.Substring($git.ReplacementIndex, $git.ReplacementLength)
            $pathMatches = @(Get-UnixPathCompletion -WordToComplete $currentText)
            if ($pathMatches.Count -gt 0) {
                # checkout accepts either a ref or a path in this position. Keep both
                # candidate types so an identically named ref and file remain visible.
                $state.Matches = @($git.Matches) + $pathMatches
                $state.MatchesNormalized = $false
            }
        }
        return $state
    }
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)
    $pathElement = $null
    foreach ($command in $commands) {
        if ($command.Extent.StartOffset -le $Cursor -and $command.Extent.EndOffset -ge $Cursor) {
            $state.LiteralPaths = $command.GetCommandName() -in @('winpath', 'unixpath')
            $pathElement = $null
            foreach ($element in $command.CommandElements | Select-Object -Skip 1) {
                if ($element -is [Management.Automation.Language.StringConstantExpressionAst] -and
                    $element.Extent.StartOffset -lt $Cursor -and $element.Extent.EndOffset -ge $Cursor -and
                    $element.Value -match '^(?:\.{1,2}[/\\]|~[/\\]|/[A-Za-z](?:/|$)|/?[A-Za-z]:[/\\])') {
                    $pathElement = $element
                }
            }
        }
    }
    if ($pathElement) {
        $state.ReplacementIndex = $pathElement.Extent.StartOffset
        $state.ReplacementLength = $pathElement.Extent.EndOffset - $pathElement.Extent.StartOffset
        $state = Invoke-PathCompletionHook -State $state
        if ($state.Matches.Count -gt 0) {
            $state.MatchesNormalized = $true
            return $state
        }
    }
    $state = Invoke-PowerShellCompletionHook -State $state
    $state = Invoke-PathCompletionHook -State $state
    $state.MatchesNormalized = $true
    return $state
}

function Get-HookCompletionEdit {
    param($State, $Decision)

    $length = $State.ReplacementLength
    $text = $Decision.Replacement
    if ($State.SpaceAfterWord -and $Decision.MatchCount -eq 1) {
        $end = $State.ReplacementIndex + $length
        if ($end -eq $State.Line.Length) {
            $text += ' '
        } elseif ($State.Line[$end] -in @([char]' ', [char]9)) {
            # Consume and reinsert one existing separator so Replace also advances the cursor.
            $text += $State.Line[$end]
            $length++
        }
    }
    [pscustomobject]@{ Start = $State.ReplacementIndex; Length = $length; Text = $text }
}

function Complete-HookTab {
    param(
        [string]$Line,
        [int]$Cursor
    )

    $state = Complete-HookLine -Line $Line -Cursor $Cursor
    $currentText = ''
    if (
        $state.ReplacementIndex -ge 0 -and
        $state.ReplacementLength -ge 0 -and
        $state.ReplacementIndex -le $Line.Length -and
        $state.ReplacementLength -le ($Line.Length - $state.ReplacementIndex)
    ) {
        $currentText = $Line.Substring(
            $state.ReplacementIndex,
            $state.ReplacementLength
        )
    }

    $decision = Get-CompletionDecision `
        -Matches $state.Matches `
        -CurrentText $currentText `
        -LiteralPaths:$state.LiteralPaths `
        -Normalized:$state.MatchesNormalized

    if ($decision.MatchCount -eq 1) {
        $edit = Get-HookCompletionEdit -State $state -Decision $decision
        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
            $edit.Start,
            $edit.Length,
            $edit.Text
        )
        return
    }

    $currentHasGlob = (
        -not $currentText.StartsWith("'") -and
        -not $currentText.StartsWith('"') -and
        $currentText -match '[*?]'
    )

    if ($decision.MatchCount -gt 1) {
        if (
            -not $currentHasGlob -and
            $decision.Replacement -and
            -not $decision.Replacement.Equals(
                $currentText,
                [StringComparison]::OrdinalIgnoreCase
            )
        ) {
            [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
                $state.ReplacementIndex,
                $state.ReplacementLength,
                $decision.Replacement
            )
            return
        }

        $script:CompletionDisplayState = $state
        try {
            [Microsoft.PowerShell.PSConsoleReadLine]::PossibleCompletions()
        } finally {
            $script:CompletionDisplayState = $null
        }
    }
}

function global:TabExpansion2 {
    [CmdletBinding(DefaultParameterSetName = 'ScriptInputSet')]
    param(
        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory, Position = 0)]
        [string]$inputScript,

        [Parameter(ParameterSetName = 'ScriptInputSet', Mandatory, Position = 1)]
        [int]$cursorColumn,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 0)]
        [System.Management.Automation.Language.Ast]$ast,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 1)]
        [System.Management.Automation.Language.Token[]]$tokens,

        [Parameter(ParameterSetName = 'AstInputSet', Mandatory, Position = 2)]
        [System.Management.Automation.Language.IScriptPosition]$positionOfCursor,

        [Parameter(ParameterSetName = 'ScriptInputSet', Position = 2)]
        [Parameter(ParameterSetName = 'AstInputSet', Position = 3)]
        [Hashtable]$options = $null
    )

    if ($PSCmdlet.ParameterSetName -eq 'AstInputSet') {
        $inputScript = $ast.Extent.Text
        $cursorColumn = $positionOfCursor.Offset
    }

    # PossibleCompletions calls TabExpansion2 again; reuse this keypress's candidates only.
    $state = $script:CompletionDisplayState
    if (-not $state -or $state.Line -cne $inputScript -or $state.Cursor -ne $cursorColumn) {
        $state = Complete-HookLine -Line $inputScript -Cursor $cursorColumn
    }
    $results = [System.Collections.ObjectModel.Collection[System.Management.Automation.CompletionResult]]::new()
    foreach ($match in @($state.Matches)) {
        $results.Add($match)
    }

    return [System.Management.Automation.CommandCompletion]::new(
        $results,
        -1,
        $state.ReplacementIndex,
        $state.ReplacementLength
    )
}

if ($Host.Name -eq 'ConsoleHost' -and -not (Get-Module PSReadLine)) {
    Import-Module PSReadLine -ErrorAction SilentlyContinue
}
if ($Host.Name -eq 'ConsoleHost' -and (Get-Module PSReadLine)) {
    # All PSReadLine submit keys converge here. Editing cancellations do not return code to run.
    function global:PSConsoleHostReadLine {
        [System.Diagnostics.DebuggerHidden()]
        param()
        $lastRunStatus = $?
        Complete-TermPrompt
        Microsoft.PowerShell.Core\Set-StrictMode -Off
        $script:ReadingInput = $true
        $script:SubmittedDisplayLine = $null
        try {
            $line = [Microsoft.PowerShell.PSConsoleReadLine]::ReadLine($Host.Runspace, $ExecutionContext, $lastRunStatus)
            $displayLine = $script:SubmittedDisplayLine
        } finally {
            $script:ReadingInput = $false
            $script:SubmittedDisplayLine = $null
        }
        if ($displayLine -and (Test-CompleteCommandLine -InputScript $line)) {
            Set-HookPromptInput -Line $displayLine
        } else {
            Set-HookPromptInput -Line $line
        }
        return $line
    }

    Set-PSReadLineOption -CompletionQueryItems 60
    Set-PSReadLineOption -AddToHistoryHandler {
        param($lineToBeAdded)
        if ($script:SkipConvertedHistory) {
            $script:SkipConvertedHistory = $false
            return $false
        }
        -not [string]::IsNullOrWhiteSpace($lineToBeAdded)
    }
    Set-PSReadLineKeyHandler -Key UpArrow -Function HistorySearchBackward
    Set-PSReadLineKeyHandler -Key DownArrow -Function HistorySearchForward
    Set-PSReadLineOption -HistorySearchCursorMovesToEnd
    Set-PSReadLineOption -PredictionSource None

    Set-PSReadLineKeyHandler -Key Tab -ScriptBlock {
        $line = $null
        $cursor = 0
        [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState([ref]$line, [ref]$cursor)
        try {
            Complete-HookTab -Line $line -Cursor $cursor
        } catch {
            # A thrown Tab handler leaves PSReadLine unable to process Ctrl+C.
        }
    }

    if (Get-Command fzf -ErrorAction SilentlyContinue) {
        Set-PSReadLineKeyHandler -Chord Ctrl+r -ScriptBlock {
            $historyPath = (Get-PSReadLineOption).HistorySavePath
            $selection = Get-Content -LiteralPath $historyPath -ErrorAction SilentlyContinue |
                fzf --tac --no-sort --height=40% --border

            if ($selection) {
                [Microsoft.PowerShell.PSConsoleReadLine]::RevertLine()
                [Microsoft.PowerShell.PSConsoleReadLine]::Insert(
                    ($selection -join [Environment]::NewLine)
                )
            }
        }
    }

    $enterHandler = Get-PSReadLineKeyHandler -Chord Enter
    if ($enterHandler.Function -in @(
            'AcceptLine'
            'ValidateAndAcceptLine'
            'HookAcceptLine'
        )) {
        Set-PSReadLineKeyHandler `
            -Chord Enter `
            -BriefDescription 'HookAcceptLine' `
            -LongDescription 'Path rewrite then accept line' `
            -ScriptBlock {
                param($key, $arg)

                $line = $null
                $cursor = 0
                [Microsoft.PowerShell.PSConsoleReadLine]::GetBufferState(
                    [ref]$line,
                    [ref]$cursor
                )
                if (Test-CompleteCommandLine -InputScript $line) {
                    $rewritten = ConvertTo-WindowsCommandLine -InputScript $line
                    if (
                        $rewritten -cne $line -and
                        (Test-WindowsCommandLineReplacement -Original $line -Converted $rewritten)
                    ) {
                        [Microsoft.PowerShell.PSConsoleReadLine]::AddToHistory($line)
                        $script:SubmittedDisplayLine = $line
                        $script:SkipConvertedHistory = $true
                        [Microsoft.PowerShell.PSConsoleReadLine]::Replace(
                            0,
                            $line.Length,
                            $rewritten
                        )
                    }
                }

                [Microsoft.PowerShell.PSConsoleReadLine]::AcceptLine($key, $arg)
            }
    }
}

if (-not (Test-Path Variable:script:BasePrompt)) {
    $script:BasePrompt = {
        Get-UpwshPromptText `
            -Succeeded $script:LastCommandSucceeded `
            -ExitCode $script:LastCommandExitCode `
            -DurationMs (Get-TermLastElapsedMilliseconds)
    }
}

function global:prompt {
    $succeeded = $?
    $exitCode = $global:LASTEXITCODE
    $lastError = $global:Error[0]
    $completedAt = [Diagnostics.Stopwatch]::GetTimestamp()
    $location = $ExecutionContext.SessionState.Path.CurrentLocation.Path
    $width = $Host.UI.RawUI.WindowSize.Width
    $completed = $script:CommandPending -and -not $script:ReadingInput
    if ($completed) {
        $script:CommandPending = $false
        $script:LastCommandSucceeded = $succeeded -and -not $script:SubmittedParseError
        $script:LastNativeExitCode = $exitCode
        $history = Get-History -Count 1
        $interrupted = -not $script:SubmittedParseError -and $history -and $history.ExecutionStatus -eq 'Stopped'
        $powerShellError = $lastError -and -not [object]::ReferenceEquals($lastError, $script:ErrorBeforeCommand) -and
            ($lastError -isnot [Management.Automation.ErrorRecord] -or
             $lastError.Exception -isnot [System.Exception] -or
             $lastError.Exception.GetType().FullName -ne 'System.Management.Automation.NativeCommandExitException')
        $script:LastCommandExitCode = if ($script:LastCommandSucceeded) { 0 }
            elseif ($interrupted -or $powerShellError -or $script:SubmittedParseError -or -not $exitCode) { 1 }
            else { $exitCode }
        $script:LastCommandStatus = if ($script:LastCommandSucceeded) { 'success' } elseif ($interrupted) { 'interrupted' } else { 'error' }
        $script:SubmittedParseError = $false
    }
    $themeRevision = Get-UpwshThemeRevision
    $reuse = -not $completed -and
        $null -ne $script:CachedPrompt -and
        $location -ceq $script:CachedPromptLocation -and
        $width -eq $script:CachedPromptWidth -and
        $themeRevision -eq $script:CachedPromptThemeRevision
    try {
        if (-not $script:ReadingInput) {
            # A must precede both direct host writes and the text returned by the renderer.
            Sync-TermPrompt -Succeeded $script:LastCommandSucceeded -ExitCode $script:LastCommandExitCode `
                -NativeExitCode $script:LastNativeExitCode -Status $script:LastCommandStatus `
                -CommandCompleted:$completed -CompletedAt $completedAt -DeferEnd
        }
        if (-not $reuse) {
            # Restore $? immediately before invoking renderers such as Starship. Ignore emits
            # nothing and does not add a synthetic entry to $Error or change LASTEXITCODE.
            $script:CachedPrompt = & $(
                $script:BasePrompt
                if (-not $script:LastCommandSucceeded) {
                    Microsoft.PowerShell.Utility\Write-Error 'Last command failed' -ErrorAction Ignore
                }
            )
            $script:CachedPromptLocation = $location
            $script:CachedPromptWidth = $width
            $script:CachedPromptThemeRevision = $themeRevision
        }
        # ConsoleHost writes the returned text before PSConsoleHostReadLine emits B.
        return $script:CachedPrompt
    } finally {
        $global:LASTEXITCODE = $exitCode
    }
}

Export-ModuleMember -Function Complete-HookLine, Test-CompleteCommandLine, Test-WindowsCommandLineReplacement, Set-HookPromptInput
