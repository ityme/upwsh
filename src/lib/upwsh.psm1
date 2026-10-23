# upwsh 命令入口。实现在 script/upwsh.ps1。

function global:upwsh {
    $installer = [IO.Path]::GetFullPath(
        (Join-Path $PSScriptRoot '..\script\upwsh.ps1')
    )
    & $installer @args
}

# upwsh 子命令补全。静态候选；只有 theme use 读本地主题目录。
$script:UpwshCommands = @('install', 'update', 'uninstall', 'tool', 'theme', 'edit', 'load', 'unload')
$script:UpwshToolActions = @('list', 'install', 'update', 'uninstall')
$script:UpwshToolNames = @(
    'bat', 'btm', 'delta', 'difft', 'dust', 'duf', 'eza', 'fd', 'fzf', 'gh',
    'hyperfine', 'jq', 'lazygit', 'procs', 'rg', 'shfmt', 'starship', 'tssh',
    'yazi', 'yq', 'zoxide'
)

function script:ConvertTo-UpwshCompletionText {
    param([string]$Name)

    if ($Name -match '^[\p{L}\p{M}\p{N}._-]+$') { return $Name }
    return "'" + $Name.Replace("'", "''") + "'"
}

function script:Get-UpwshArgumentCompletion {
    param([string]$WordToComplete, [int]$CursorPosition, [Management.Automation.Language.CommandAst]$CommandAst)

    # Context words are elements fully before the cursor; the cursor-containing element is the
    # in-progress prefix and is handled by the caller's $wordToComplete.
    $words = @(
        $CommandAst.CommandElements |
            Select-Object -Skip 1 |
            ForEach-Object {
                if ($_.Extent.EndOffset -ge $CursorPosition) { return }
                if ($_ -is [Management.Automation.Language.StringConstantExpressionAst]) { $_.Value }
                elseif ($_ -is [Management.Automation.Language.CommandParameterAst]) { $_.Extent.Text }
            }
    )

    if ($words.Count -eq 0) {
        return @($script:UpwshCommands)
    }

    switch ($words[0]) {
        'tool' {
            if ($words.Count -eq 1) { return @($script:UpwshToolActions) }
            if ($words.Count -eq 2 -and $words[1] -in @('install', 'update')) {
                return @($script:UpwshToolNames)
            }
            return @()
        }
        'theme' {
            if ($words.Count -eq 1) { return @('list', 'use') }
            if ($words.Count -eq 2 -and $words[1] -eq 'use') {
                # Inline home resolution: session helpers are not always visible from module scope.
                $themeDir = Join-Path ([IO.Path]::Combine($HOME, '.config', 'upwsh')) 'theme'
                if (-not [IO.Directory]::Exists($themeDir)) { return @() }
                return @(
                    Get-ChildItem -LiteralPath $themeDir -Filter '*.json' -File |
                        ForEach-Object { [IO.Path]::GetFileNameWithoutExtension($_.Name) }
                )
            }
            return @()
        }
        { $_ -in @('install', 'update') } {
            if ($words.Count -eq 1) { return @('--local', '--remote') }
            return @()
        }
        default { return @() }
    }
}

Register-ArgumentCompleter -CommandName upwsh -ScriptBlock {
    param($wordToComplete, $commandAst, $cursorPosition)

    try {
        $names = @(Get-UpwshArgumentCompletion -WordToComplete $wordToComplete -CursorPosition $cursorPosition -CommandAst $commandAst)
    } catch {
        return
    }
    foreach ($name in $names) {
        if (-not $name.StartsWith($wordToComplete, [StringComparison]::OrdinalIgnoreCase)) { continue }
        $text = ConvertTo-UpwshCompletionText -Name $name
        [System.Management.Automation.CompletionResult]::new($text, $name, 'ParameterValue', $name)
    }
}

Export-ModuleMember -Function @()
