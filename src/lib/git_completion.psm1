# Deliberately small Git completion: common verbs, refs, and configured remotes.
$script:GitCommands = @(
    'add', 'branch', 'checkout', 'cherry-pick', 'clone', 'commit', 'diff', 'fetch',
    'init', 'log', 'merge', 'pull', 'push', 'rebase', 'remote', 'reset', 'restore',
    'revert', 'show', 'stash', 'status', 'switch', 'tag'
)

$script:GitQueryCache = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
$script:GitCacheLifetimeMs = 1000
$script:GitCacheLimit = 16
$script:GitExecutable = $null

function Clear-GitCompletionCache {
    $script:GitQueryCache.Clear()
}

function Resolve-GitCompletionExecutable {
    param([string]$WorkingDirectory)

    $cached = $script:GitExecutable
    if ($cached -and $cached.SearchPath -ceq $env:PATH -and $cached.Extensions -ceq $env:PATHEXT -and
        $cached.Directory -ceq $WorkingDirectory -and [IO.File]::Exists($cached.Path)) {
        return $cached.Path
    }
    Clear-GitCompletionCache
    $script:GitExecutable = $null
    $git = Get-Command git -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($git) {
        $script:GitExecutable = [pscustomobject]@{
            SearchPath = $env:PATH; Extensions = $env:PATHEXT; Directory = $WorkingDirectory; Path = $git.Source
        }
        return $git.Source
    }
}

function Read-GitCompletionData {
    param([string[]]$DirectoryArgs, [string[]]$Arguments)

    $directory = $ExecutionContext.SessionState.Path.CurrentFileSystemLocation.ProviderPath
    $executable = Resolve-GitCompletionExecutable $directory
    if (-not $executable) { return @() }
    # Git environment overrides can select a different repository/configuration without cd.
    $environment = [Environment]::GetEnvironmentVariables('Process')
    $gitEnvironment = [Collections.Generic.List[string]]::new()
    foreach ($name in $environment.Keys) {
        if ($name.StartsWith('GIT_', [StringComparison]::OrdinalIgnoreCase) -or $name -in @('HOME', 'XDG_CONFIG_HOME')) {
            $value = [string]$environment[$name]
            $gitEnvironment.Add("${name}=$value")
        }
    }
    $gitEnvironment.Sort([StringComparer]::Ordinal)
    $keyBuilder = [Text.StringBuilder]::new()
    # Length-prefix each component so spaces, quotes and separators cannot collide.
    foreach ($part in @($executable, $directory, [string]$DirectoryArgs.Count) + $DirectoryArgs +
        @([string]$Arguments.Count) + $Arguments + @($gitEnvironment.ToArray())) {
        [void]$keyBuilder.Append($part.Length).Append(':').Append($part)
    }
    $key = $keyBuilder.ToString()
    $now = [Environment]::TickCount64
    foreach ($oldKey in @($script:GitQueryCache.Keys)) {
        if ($now - $script:GitQueryCache[$oldKey].CreatedAt -ge $script:GitCacheLifetimeMs) {
            [void]$script:GitQueryCache.Remove($oldKey)
        }
    }
    $cached = $null
    if ($script:GitQueryCache.TryGetValue($key, [ref]$cached)) {
        return $cached.Lines
    }

    $start = [Diagnostics.ProcessStartInfo]::new()
    $start.FileName = $executable
    $start.WorkingDirectory = $directory
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.Encoding]::UTF8
    foreach ($argument in @('--no-pager', '--no-optional-locks') + $DirectoryArgs + $Arguments) {
        [void]$start.ArgumentList.Add($argument)
    }
    $process = $null
    try {
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(500)) {
            $process.Kill($true)
            $process.WaitForExit()
            return @()
        }
        $text = $stdout.GetAwaiter().GetResult()
        $null = $stderr.GetAwaiter().GetResult()
        if ($process.ExitCode -eq 0) {
            $lines = @($text -split '\r?\n' | Where-Object { $_ })
            if ($script:GitQueryCache.Count -ge $script:GitCacheLimit) {
                $oldest = $null
                foreach ($entry in $script:GitQueryCache.GetEnumerator()) {
                    if ($null -eq $oldest -or $entry.Value.CreatedAt -lt $oldest.Value.CreatedAt) { $oldest = $entry }
                }
                [void]$script:GitQueryCache.Remove($oldest.Key)
            }
            $script:GitQueryCache[$key] = [pscustomobject]@{ CreatedAt = [Environment]::TickCount64; Lines = $lines }
            return $lines
        }
    } catch {
        # Missing Git, non-repositories, and slow queries leave the command line usable.
    } finally {
        if ($process) { $process.Dispose() }
    }
}

function Get-GitCompletion {
    param([string]$Line, [int]$Cursor, [Management.Automation.Language.ScriptBlockAst]$Ast)

    $active = $null
    foreach ($command in $Ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        if ($command.Extent.StartOffset -ge $Cursor) { continue }
        if ($command.Extent.EndOffset -ge $Cursor -or
            [string]::IsNullOrWhiteSpace($Line.Substring($command.Extent.EndOffset, $Cursor - $command.Extent.EndOffset))) {
            $active = $command
        }
    }
    if (-not $active -or $active.GetCommandName() -notin @('git', 'git.exe')) { return $null }
    if ($Cursor -le $active.CommandElements[0].Extent.EndOffset) { return $null }
    foreach ($redirect in $active.Redirections) {
        if ($redirect.Extent.StartOffset -lt $Cursor -and $redirect.Extent.EndOffset -ge $Cursor) { return $null }
    }

    $words = [Collections.Generic.List[string]]::new()
    $elements = [Collections.Generic.List[object]]::new()
    $start = $Cursor
    $length = 0
    $prefix = ''
    for ($index = 1; $index -lt $active.CommandElements.Count; $index++) {
        $element = $active.CommandElements[$index]
        if ($element.Extent.StartOffset -ge $Cursor) { break }
        if ($element.Extent.EndOffset -ge $Cursor) {
            if ($element -isnot [Management.Automation.Language.StringConstantExpressionAst]) { return $null }
            $start = $element.Extent.StartOffset
            $length = $element.Extent.EndOffset - $start
            $prefix = $Line.Substring($start, $Cursor - $start)
            if ($prefix.StartsWith("'")) { $prefix = $prefix.Trim([char]39).Replace("''", "'") }
            elseif ($prefix.StartsWith('"')) { $prefix = $prefix.Trim([char]34) }
            break
        }
        if ($element -is [Management.Automation.Language.StringConstantExpressionAst]) {
            $words.Add($element.Value)
        } elseif ($element -is [Management.Automation.Language.CommandParameterAst]) {
            $words.Add($element.Extent.Text)
        } else { return $null }
        $elements.Add($element)
    }
    if ('--%' -in $words -or $prefix.StartsWith('-')) { return $null }
    $directoryArgs = @()
    $index = 0
    while ($index -lt $words.Count -and $words[$index] -ceq '-C') {
        if ($index + 1 -ge $words.Count) { return $null }
        # Keep relative -C values relative: Git resolves repeated -C options in order.
        $directory = ConvertTo-WindowsPathOperands @($words[$index + 1]) -Literal
        $directoryArgs += @('-C', $directory)
        $index += 2
    }
    $kind = 'commands'
    $remote = ''
    $allowPathCompletion = $false
    $pathOnlyCompletion = $false
    if ($index -lt $words.Count) {
        $verb = $words[$index]
        $arguments = @($words | Select-Object -Skip ($index + 1))
        switch ($verb) {
            { $_ -in @('switch', 'checkout', 'merge', 'rebase', 'cherry-pick', 'show', 'reset', 'branch') } {
                if ($prefix -match '^(?:\.{1,2}[/\\]|~[/\\]|/[A-Za-z](?:/|$)|[A-Za-z]:[/\\])') { return $null }
                # Creating a branch expects a new name; checkout paths use the normal completer.
                if (@($arguments | Where-Object { $_ -cin @('-c', '-C', '-b', '-B', '--orphan') }).Count) { return $null }
                if ($verb -eq 'checkout' -and '--' -cin $arguments) {
                    return [pscustomobject]@{
                        ReplacementIndex    = $start
                        ReplacementLength   = $length
                        Matches             = @()
                        AllowPathCompletion = $true
                        PathOnlyCompletion  = $true
                    }
                }
                $allowed = @('--track', '-t', '--detach', '-d', '--force', '-f')
                if ($verb -eq 'branch') { $allowed = @('-d', '-D', '--delete') }
                if (@($arguments | Where-Object { $_ -cnotin $allowed }).Count) { return $null }
                $allowPathCompletion = $verb -eq 'checkout' -and
                    @($arguments | Where-Object { $_ -cin $allowed }).Count -eq $arguments.Count
                $kind = if ($verb -eq 'branch') { 'heads' }
                    elseif ($verb -eq 'switch' -and ('--track' -cin $arguments -or '-t' -cin $arguments)) { 'remote-refs' }
                    elseif ($verb -eq 'switch' -and '--detach' -cnotin $arguments -and '-d' -cnotin $arguments) { 'heads' }
                    else { 'refs' }
            }
            { $_ -in @('push', 'pull', 'fetch') } {
                $positionals = @($arguments | Where-Object { $_ -cnotin @('-u', '--set-upstream', '--force', '--force-with-lease', '--prune', '-p', '--rebase') })
                if (@($positionals | Where-Object { $_.StartsWith('-') }).Count) { return $null }
                if ($positionals.Count -eq 0) { $kind = 'remotes' }
                elseif ($verb -eq 'push') {
                    if ($prefix.Contains(':') -or $prefix.StartsWith('+')) { return $null }
                    $kind = 'local-refs'
                } else { $kind = 'remote-branches'; $remote = $positionals[0] }
            }
            'remote' {
                if ($arguments.Count -eq 0) { $kind = 'remote-actions' }
                elseif ($arguments.Count -eq 1 -and $arguments[0] -in @('remove', 'rename', 'set-url', 'show', 'prune')) { $kind = 'remotes' }
                else { return $null }
            }
            default { return $null }
        }
    }
    $values = switch ($kind) {
        'commands' { $script:GitCommands }
        'remote-actions' { @('add', 'remove', 'rename', 'set-url', 'show', 'prune', 'update') }
        'remotes' { Read-GitCompletionData $directoryArgs @('remote') }
        default {
            $refRoots = switch ($kind) {
                'heads' { @('refs/heads') }
                'remote-refs' { @('refs/remotes') }
                'local-refs' { @('refs/heads', 'refs/tags') }
                'remote-branches' { @('refs/remotes') }
                default { @('refs/heads', 'refs/remotes', 'refs/tags') }
            }
            foreach ($ref in @(Read-GitCompletionData $directoryArgs (@('for-each-ref', '--format=%(refname)') + $refRoots))) {
                if ($kind -eq 'remote-branches') {
                    $root = "refs/remotes/$remote/"
                    if ($ref.StartsWith($root, [StringComparison]::Ordinal) -and $ref -cne ($root + 'HEAD')) { $ref.Substring($root.Length) }
                } elseif ($ref -notmatch '^refs/remotes/.+/HEAD$') {
                    $ref -creplace '^refs/(heads|remotes|tags)/', ''
                }
            }
        }
    }
    $seen = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($value in $values) {
        if ($value.StartsWith($prefix, [StringComparison]::Ordinal)) { [void]$seen.Add($value) }
    }
    $matches = @(foreach ($value in $seen) {
        [Management.Automation.CompletionResult]::new((ConvertTo-QuotedText $value), $value, 'ParameterValue', "git $kind")
    })
    # Even an empty ref result is authoritative for other Git commands. Checkout can
    # also target a path, so the hook may merge filesystem candidates when requested.
    [pscustomobject]@{
        ReplacementIndex    = $start
        ReplacementLength   = $length
        Matches             = $matches
        AllowPathCompletion = $allowPathCompletion
        PathOnlyCompletion  = $pathOnlyCompletion
    }
}

Export-ModuleMember -Function Get-GitCompletion, Clear-GitCompletionCache
