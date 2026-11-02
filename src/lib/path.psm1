# 路径转换与补全。显式转换处理单个路径；交互改写只处理顶层裸参数。

. ([IO.Path]::Combine($PSScriptRoot, 'path_convert.ps1'))

function Resolve-ExpandedGlobPath {
    param(
        [string]$Pattern,
        [System.IO.FileSystemInfo]$Item
    )

    $fullName = $Item.FullName.Replace('\', '/')
    $windowsPattern = winpath $Pattern
    if (
        [IO.Path]::IsPathRooted($windowsPattern) -or
        $windowsPattern -match '^[A-Za-z]:'
    ) {
        return $fullName
    }

    try {
        $cwd = (Get-Location).ProviderPath.Replace('\', '/').TrimEnd('/')
        $fullTrim = $fullName.TrimEnd('/')
        if ($fullTrim.StartsWith($cwd + '/', [StringComparison]::OrdinalIgnoreCase)) {
            return $fullTrim.Substring($cwd.Length + 1)
        }
        if ($fullTrim.Equals($cwd, [StringComparison]::OrdinalIgnoreCase)) {
            return '.'
        }
    } catch {
    }

    return $fullName
}

function Expand-PathGlob {
    param([string]$Pattern)

    if ($Pattern -notmatch '[*?]') {
        return @($Pattern)
    }

    $leaf = Split-Path -Leaf $Pattern
    $force = $leaf.StartsWith('.')
    $items = @(
        Get-ChildItem -Path $Pattern -Force:$force -ErrorAction SilentlyContinue
    )
    if ($items.Count -eq 0) {
        return @($Pattern)
    }

    foreach ($item in $items) {
        Resolve-ExpandedGlobPath -Pattern $Pattern -Item $item
    }
}

function ConvertTo-WindowsPathOperands {
    param([object[]]$Arguments)

    foreach ($argument in @($Arguments)) {
        if ($argument -is [string]) {
            Expand-PathGlob $argument
        } else {
            $argument
        }
    }
}

function ConvertTo-WindowsCommandLine {
    param([AllowEmptyString()][string]$InputScript = '')

    if ([string]::IsNullOrWhiteSpace($InputScript)) {
        return $InputScript
    }

    $tokens = $null
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseInput($InputScript, [ref]$tokens, [ref]$errors)
    if ($errors.Count) { return $InputScript }
    $changes = [Collections.Generic.List[object]]::new()
    $commands = $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $false)
    foreach ($command in $commands) {
        # Only top-level pipelines/chains; never descend into subexpressions or script bodies.
        $parent = $command.Parent
        while ($parent -is [Management.Automation.Language.PipelineAst] -or
               $parent -is [Management.Automation.Language.PipelineChainAst]) {
            $parent = $parent.Parent
        }
        if ($parent -ne $ast.EndBlock) { continue }
        $elements = $command.CommandElements
        if ($elements.Count -eq 1 -and $command.Redirections.Count -eq 0 -and
            $command.InvocationOperator -eq 'Unknown' -and $command.Extent.Text -ceq $InputScript.Trim()) {
            $element = $elements[0]
            if ($element -is [Management.Automation.Language.StringConstantExpressionAst] -and
                $element.StringConstantType -eq 'BareWord' -and
                $element.Extent.Text -ceq $element.Value -and
                (Test-PathLikeToken $element.Value)) {
                $directory = winpath $element.Value
                if (Test-Path -LiteralPath $directory -PathType Container) {
                    return 'cd ' + (ConvertTo-QuotedText $directory)
                }
            }
        }
        for ($index = 1; $index -lt $elements.Count; $index++) {
            $element = $elements[$index]
            if ($element.Extent.Text -eq '--%') { break }
            if ($element -isnot [Management.Automation.Language.StringConstantExpressionAst] -or
                $element.StringConstantType -ne 'BareWord' -or
                $element.Extent.Text -cne $element.Value -or
                $element.Value -notmatch '^(?:/[A-Za-z](?:/[^\s]*|$)|~(?:/[^\s]*|$))$') {
                continue
            }
            $converted = winpath $element.Value
            $changes.Add([pscustomobject]@{
                Start = $element.Extent.StartOffset
                Length = $element.Extent.EndOffset - $element.Extent.StartOffset
                Text = ConvertTo-QuotedText $converted
            })
        }
    }
    $result = $InputScript
    foreach ($change in ($changes | Sort-Object Start -Descending)) {
        $result = $result.Remove($change.Start, $change.Length).Insert($change.Start, $change.Text)
    }
    return $result
}


function ConvertTo-WindowsArguments {
    param([object[]]$Arguments)
    foreach ($argument in $Arguments) {
        if ($argument -is [string]) { winpath $argument } else { $argument }
    }
}

function Resolve-WindowsPath {
    param([string]$Path)
    $windowsPath = $Path
    if ([IO.Path]::IsPathRooted($windowsPath) -or $windowsPath -match '^[a-zA-Z]:[^\\/]') { return $windowsPath }
    try {
        return [IO.Path]::GetFullPath((Join-Path (Get-Location).ProviderPath $windowsPath))
    } catch { return $windowsPath }
}

function ConvertFrom-QuotedText {
    param([string]$Text)
    if ($Text -match '^\(winpath (''(?:[^'']|'''')*'')\)$') {
        $Text = $Matches[1]
    }
    if ($Text.Length -ge 2) {
        if ($Text[0] -eq "'" -and $Text[-1] -eq "'") { return $Text.Substring(1, $Text.Length - 2).Replace("''", "'") }
        if ($Text[0] -eq '"' -and $Text[-1] -eq '"') { return $Text.Substring(1, $Text.Length - 2) }
    }
    return $Text
}

function ConvertTo-QuotedText {
    param([string]$Text)
    if ([string]::IsNullOrEmpty($Text)) { return $Text }
    $safeBareWord = $Text -match '^[\p{L}\p{M}\p{N}._~/:+=%!-]+$'
    if (-not $safeBareWord -or $Text.StartsWith('-')) { return "'$($Text.Replace("'", "''"))'" }
    return $Text
}

function ConvertTo-PathCompletionText {
    param([string[]]$Text, [switch]$LiteralPaths)

    foreach ($item in $Text) {
        if ($item -match '^[\p{L}\p{M}\p{N}._~/:+=%!-]+$' -and -not $item.StartsWith('-')) {
            $item
        } else {
            $quoted = "'$($item.Replace("'", "''"))'"
            if (-not $LiteralPaths -and $item -match '^(?:/[A-Za-z](?:/|$)|~(?:/|$))') {
                "(winpath $quoted)"
            } else {
                $quoted
            }
        }
    }
}

function Get-UnixPathCompletion {
    param(
        [string]$WordToComplete,
        [switch]$DirectoryOnly,
        [string]$BaseDirectory
    )

    $word = ConvertFrom-QuotedText $WordToComplete
    if ($word.StartsWith("'")) {
        $word = $word.Substring(1).Replace("''", "'")
    } elseif ($word.StartsWith('"')) {
        $word = $word.Substring(1)
    }
    $isHomePath = $word -eq '~' -or $word -match '^~[\\\/]'
    $isAbsolutePath = $word -match '^(?:/[a-zA-Z](?:/|$)|/?[a-zA-Z]:[\\/])'
    $wordSeparatorIndex = [Math]::Max($word.LastIndexOf('\'), $word.LastIndexOf('/'))
    $relativeParent = if (-not $isAbsolutePath -and $wordSeparatorIndex -ge 0) {
        $word.Substring(0, $wordSeparatorIndex + 1) -replace '\\', '/'
    } elseif (-not $isAbsolutePath -and $word -eq '..') {
        '../'
    } else {
        ''
    }

    if ($word -match '^/$') {
        Get-PSDrive -PSProvider FileSystem |
            Where-Object { $_.Name -match '^[a-zA-Z]$' } |
            Sort-Object Name |
            ForEach-Object {
                $completion = "/$($_.Name.ToLower())/"
                [System.Management.Automation.CompletionResult]::new(
                    $completion,
                    $completion,
                    'ProviderContainer',
                    $_.Root
                )
            }
        return
    }

    # A bare drive such as /i means the root of I: during completion.
    if ($word -eq '~') {
        $windowsWord = $HOME.TrimEnd([char[]]@('\', '/')) + '\'
    } elseif ($word -match '^/([a-zA-Z])$') {
        $windowsWord = $Matches[1].ToUpper() + ':\'
    } else {
        $windowsWord = winpath $word
    }

    if ([string]::IsNullOrWhiteSpace($BaseDirectory)) {
        try {
            $BaseDirectory = (Get-Location).ProviderPath
        } catch {
            $BaseDirectory = '.'
        }
    } else {
        $BaseDirectory = winpath $BaseDirectory
    }

    if ([string]::IsNullOrWhiteSpace($windowsWord)) {
        $parent = '.'
        $leaf = ''
    } elseif ($windowsWord -eq '.' -or $windowsWord -eq '..') {
        # '.' / '..' 是目录本身，不是隐藏文件前缀。
        $parent = $windowsWord
        $leaf = ''
    } else {
        $separatorIndex = [Math]::Max(
            $windowsWord.LastIndexOf('\'),
            $windowsWord.LastIndexOf('/')
        )

        if ($separatorIndex -ge 0) {
            $parent = $windowsWord.Substring(0, $separatorIndex + 1)
            $leaf = $windowsWord.Substring($separatorIndex + 1)
        } else {
            $parent = '.'
            $leaf = $windowsWord
        }
    }

    $lookupParent = if ($isAbsolutePath -or [IO.Path]::IsPathRooted($parent)) {
        $parent
    } else {
        Join-Path $BaseDirectory $parent
    }

    # 用户进入一个目录后也应能继续补全其隐藏项，例如 app-factory/.git；
    # 其他没有明确路径上下文的补全仍保持隐藏项默认不显示。
    # '.' 和 '..' 是当前/上级目录，不能当成隐藏文件前缀。
    $hasTrailingSeparator = $word.EndsWith('/') -or $word.EndsWith('\')
    $includeHidden = (
        $hasTrailingSeparator -or
        (
            $leaf.StartsWith('.') -and
            $leaf -ne '.' -and
            $leaf -ne '..'
        )
    )
    $directories = [Collections.Generic.SortedList[string, IO.FileSystemInfo]]::new([StringComparer]::Ordinal)
    $files = [Collections.Generic.SortedList[string, IO.FileSystemInfo]]::new([StringComparer]::Ordinal)
    $matcher = if ($leaf.Contains('*') -or $leaf.Contains('?')) {
        [WildcardPattern]::new($leaf, [Management.Automation.WildcardOptions]::IgnoreCase)
    } else { $null }
    $reserved = [Collections.Generic.HashSet[string]]::new(
        [string[]]@(
            'CON', 'PRN', 'AUX', 'NUL',
            'COM1', 'COM2', 'COM3', 'COM4', 'COM5', 'COM6', 'COM7', 'COM8', 'COM9',
            'LPT1', 'LPT2', 'LPT3', 'LPT4', 'LPT5', 'LPT6', 'LPT7', 'LPT8', 'LPT9'
        ),
        [StringComparer]::OrdinalIgnoreCase
    )
    try {
        foreach ($item in ([IO.DirectoryInfo]::new($lookupParent)).EnumerateFileSystemInfos()) {
            if ($reserved.Contains($item.Name)) { continue }
            $dot = $item.Name.IndexOf('.')
            if ($dot -gt 0 -and $reserved.Contains($item.Name.Substring(0, $dot))) { continue }
            $isDirectory = ($item.Attributes -band [IO.FileAttributes]::Directory) -ne 0
            if ($DirectoryOnly -and -not $isDirectory) { continue }
            if (-not $includeHidden -and ($item.Attributes -band ([IO.FileAttributes]::Hidden -bor [IO.FileAttributes]::System))) { continue }
            if ($matcher) {
                if (-not $matcher.IsMatch($item.Name)) { continue }
            } elseif (-not $item.Name.StartsWith($leaf, [StringComparison]::OrdinalIgnoreCase)) { continue }
            if ($isDirectory) { $directories[$item.Name] = $item } else { $files[$item.Name] = $item }
        }
    } catch {
        # Missing/inaccessible directories have no candidates, like Get-ChildItem -ErrorAction SilentlyContinue.
    }
    $items = @($directories.Values) + @($files.Values)
    if ($items.Count -eq 0) { return }
    $texts = @(if ($isAbsolutePath -and -not $isHomePath) {
        @(unixpath -Path ([string[]]$items.FullName))
    } else {
        @(
            foreach ($item in $items) {
                if ($isHomePath -and -not $relativeParent) { '~/' + $item.Name }
                else { $relativeParent + $item.Name }
            }
        )
    })
    for ($index = 0; $index -lt $directories.Count; $index++) {
        $texts[$index] = $texts[$index].TrimEnd('/') + '/'
    }
    $texts = @(ConvertTo-PathCompletionText -Text $texts)
    for ($index = 0; $index -lt $items.Count; $index++) {
        $type = if ($index -lt $directories.Count) { 'ProviderContainer' } else { 'ProviderItem' }
        [Management.Automation.CompletionResult]::new($texts[$index], $items[$index].Name, $type, $items[$index].FullName)
    }
}

#endregion

function Test-PathLikeToken {
    param([string]$WordToComplete)

    $word = $WordToComplete.Trim([char[]]@([char]39, [char]34))
    if ([string]::IsNullOrEmpty($word)) {
        return $false
    }

    # 含 / 或 \ 当作路径候选；若目录里没有匹配项，hook 会把原生补全留下，
    # 避免 git 的 feature/aaaa 被空的文件系统结果盖掉。
    return $word -match '^(?:~(?:[\\/]|$)|\./|\.\./|/|[a-zA-Z]:[\\/])' -or
        $word.Contains('/') -or
        $word.Contains('\')
}


function Test-PathCompletionResult {
    param([object]$Match)

    return [string]$Match.ResultType -in @(
        'ProviderItem'
        'ProviderContainer'
        'ProviderFile'
        'ProviderDirectory'
    )
}

# 用途：统一处理 PowerShell 默认补全和项目自定义补全的路径文本。
function ConvertTo-UnixCompletionResult {
    param(
        [object]$Match,
        [string]$CurrentText,
        [switch]$LiteralPaths
    )

    if (-not (Test-PathCompletionResult $Match)) {
        return $Match
    }

    $completionText = [string]$Match.CompletionText
    $currentPath = ConvertFrom-QuotedText $CurrentText
    $completionPrefix = ''
    $pathText = $completionText
    if ($currentPath -match '^(--?[^=]+=)(.*)$') {
        $candidatePrefix = $Matches[1]
        if ($completionText.StartsWith($candidatePrefix)) {
            $completionPrefix = $candidatePrefix
            $pathText = $completionText.Substring($candidatePrefix.Length)
            $currentPath = $Matches[2]
        }
    }

    $path = ConvertFrom-QuotedText $pathText
    $normalizedPath = unixpath $path

    # 用户已经输入 ~/... 时，保留波浪线前缀，不要把原生补全展开成
    # /c/Users/... 绝对路径。
    if ($currentPath -eq '~' -or $currentPath -match '^~[/\\]') {
        $windowsHome = $HOME.TrimEnd([char[]]@('\', '/'))
        $unixHome = unixpath $windowsHome
        $unquotedNormalized = ConvertFrom-QuotedText $normalizedPath
        if ($unquotedNormalized -eq $unixHome -or $unquotedNormalized.StartsWith("$unixHome/")) {
            $normalizedPath = '~' + $unquotedNormalized.Substring($unixHome.Length)
            if ($normalizedPath -eq '~') {
                $normalizedPath = '~/'
            }
        }
    }

    # PowerShell 默认补全经常为相对路径添加 .\；只有用户明确输入 ./ 或
    # ../ 时才保留该前缀，避免把 app-f 补成 ./app-factory。
    if (
        $normalizedPath.StartsWith('./') -and
        $currentPath -notmatch '^\.([/\\]|$)'
    ) {
        $normalizedPath = $normalizedPath.Substring(2)
    }

    if (
        [string]$Match.ResultType -eq 'ProviderContainer' -and
        -not $normalizedPath.EndsWith('/')
    ) {
        $normalizedPath += '/'
    }

    $normalizedText = if ($completionPrefix) {
        # Attached option values are not rewritten on Enter; return an executable path now.
        $completionPrefix + (ConvertTo-QuotedText (winpath $normalizedPath))
    } else {
        ConvertTo-PathCompletionText $normalizedPath -LiteralPaths:$LiteralPaths
    }
    if ($normalizedText -eq $completionText) {
        return $Match
    }

    [System.Management.Automation.CompletionResult]::new(
        $normalizedText,
        [string]$Match.ListItemText,
        [string]$Match.ResultType,
        [string]$Match.ToolTip
    )
}

# 用途：生成补全候选的比较文本。文件系统候选先经过 unix 路径规范化，
# 其他候选保持原文，避免把 Git ref 或普通参数错误合并。
function Get-CompletionComparisonText {
    param(
        [object]$Match,
        [string]$CurrentText
    )

    if (Test-PathCompletionResult $Match) {
        return [string](
            ConvertTo-UnixCompletionResult `
                -Match $Match `
                -CurrentText $CurrentText
        ).CompletionText
    }

    return [string]$Match.CompletionText
}

# 用途：单遍去重并计算最终写回文本；只转换唯一候选或公共前缀。
function Get-CompletionDecision {
    param(
        [object[]]$Matches,
        [string]$CurrentText,
        [switch]$LiteralPaths,
        [switch]$Normalized
    )

    if ($Normalized -and $Matches.Count -gt 0) {
        $texts = [string[]]$Matches.CompletionText
        $types = [string[]]$Matches.ResultType
        if (-not ($types -ne 'ProviderItem' -ne 'ProviderContainer') -and
            -not [regex]::IsMatch(($texts -join ''), '[\s''"()]')) {
            # Plain, normalized paths need no per-candidate parsing or PowerShell calls.
            $unique = [Collections.Generic.HashSet[string]]::new($texts, [StringComparer]::OrdinalIgnoreCase)
            [Array]::Sort($texts, [StringComparer]::OrdinalIgnoreCase)
            $prefix = $texts[0]
            $last = $texts[$texts.Length - 1]
            while ($prefix.Length -gt 0 -and -not $last.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
                $prefix = $prefix.Substring(0, $prefix.Length - 1)
            }
            return [pscustomobject]@{
                MatchCount  = $unique.Count
                Replacement = $prefix
                ResultType  = 'ProviderItem'
            }
        }
    }

    $allPathResults = @($Matches | Where-Object { [string]$_.ResultType -notin @('ProviderItem', 'ProviderContainer', 'ProviderFile', 'ProviderDirectory') }).Count -eq 0
    $comparer = if ($allPathResults) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    $comparison = if ($allPathResults) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    $seen = [Collections.Generic.HashSet[string]]::new($comparer)
    $firstMatch = $null
    $prefix = $null
    $matchCount = 0

    foreach ($match in @($Matches)) {
        $comparisonText = if ($Normalized) {
            [string]$match.CompletionText
        } else {
            Get-CompletionComparisonText -Match $match -CurrentText $CurrentText
        }
        if (-not $seen.Add($comparisonText)) {
            continue
        }

        $matchCount++
        if (-not $firstMatch) {
            $firstMatch = $match
        }

        $resultType = [string]$match.ResultType
        if (-not $resultType.StartsWith('Provider', [StringComparison]::Ordinal)) {
            $allPathResults = $false
        }

        $candidate = if ($comparisonText.StartsWith('(winpath ')) {
            ConvertFrom-QuotedText $comparisonText
        } else {
            $comparisonText
        }
        if ($candidate.Length -ge 2) {
            $first = $candidate[0]
            $last = $candidate[$candidate.Length - 1]
            if ($first -eq [char]39 -and $last -eq [char]39) {
                $candidate = $candidate.Substring(1, $candidate.Length - 2).
                    Replace("''", "'")
            } elseif ($first -eq [char]34 -and $last -eq [char]34) {
                $candidate = $candidate.Substring(1, $candidate.Length - 2).
                    Replace('""', '"')
            }
        }

        if ($null -eq $prefix) {
            $prefix = $candidate
            continue
        }

        # Once the prefix is short, most candidates need one native string comparison.
        while ($prefix.Length -gt 0 -and -not $candidate.StartsWith($prefix, $comparison)) {
            $prefix = $prefix.Substring(0, $prefix.Length - 1)
        }
    }

    $replacement = ''
    if ($matchCount -eq 1) {
        $replacement = [string](
            ConvertTo-UnixCompletionResult `
                -Match $firstMatch `
                -CurrentText $CurrentText `
                -LiteralPaths:$LiteralPaths
        ).CompletionText
    } elseif ($matchCount -gt 1 -and $prefix) {
        if ($allPathResults) {
            $prefixResult = [System.Management.Automation.CompletionResult]::new(
                $prefix,
                $prefix,
                'ProviderItem',
                $prefix
            )
            $replacement = [string](
                ConvertTo-UnixCompletionResult `
                    -Match $prefixResult `
                    -CurrentText $CurrentText `
                    -LiteralPaths:$LiteralPaths
            ).CompletionText
        } else {
            $replacement = ConvertTo-QuotedText $prefix
        }
    }

    [pscustomobject]@{
        MatchCount  = $matchCount
        Replacement = $replacement
        ResultType  = if ($matchCount -eq 1) { [string]$firstMatch.ResultType } else { $null }
    }
}

function Invoke-PathCompletionHook {
    param($State)

    $currentText = ''
    if (
        $State.ReplacementIndex -ge 0 -and
        $State.ReplacementLength -ge 0 -and
        $State.ReplacementIndex -le $State.Line.Length -and
        $State.ReplacementLength -le ($State.Line.Length - $State.ReplacementIndex)
    ) {
        $currentText = $State.Line.Substring(
            $State.ReplacementIndex,
            $State.ReplacementLength
        )
    }

    if (Test-PathLikeToken $currentText) {
        $fileMatches = @(
            Get-UnixPathCompletion -WordToComplete $currentText
        )
        if ($fileMatches.Count -gt 0) {
            $State.Matches = if ($State.LiteralPaths) {
                @(
                    foreach ($match in $fileMatches) {
                        ConvertTo-UnixCompletionResult -Match $match -CurrentText $currentText -LiteralPaths
                    }
                )
            } else {
                $fileMatches
            }
            return $State
        }
    }

    $State.Matches = @(
        foreach ($match in @($State.Matches)) {
            ConvertTo-UnixCompletionResult `
                -Match $match `
                -CurrentText $currentText `
                -LiteralPaths:([bool]$State.LiteralPaths)
        }
    )
    return $State
}


Export-ModuleMember -Function @(
    'winpath'
    'unixpath'
    'ConvertTo-WindowsArguments'
    'ConvertTo-WindowsCommandLine'
    'ConvertTo-WindowsPathOperands'
    'ConvertFrom-QuotedText'
    'ConvertTo-QuotedText'
    'ConvertTo-PathCompletionText'
    'ConvertTo-UnixCompletionResult'
    'Expand-PathGlob'
    'Get-CompletionDecision'
    'Get-UnixPathCompletion'
    'Invoke-PathCompletionHook'
    'Resolve-WindowsPath'
    'Test-PathLikeToken'
)
