# PowerShell 7 入口：模块、库存别名、user-settings.ps1、再挂钩终端。

if ($PSVersionTable.PSVersion.Major -lt 7) {
    return
}

# Do not force-reload the tracker: it must retain the pre-upwsh definitions.
Import-Module (Join-Path $PSScriptRoot 'lib/session.psm1') -Global -DisableNameChecking
Start-UpwshSessionTracking
function Import-ShellModule {
    param([Parameter(Mandatory)][string]$Name)

    Import-Module ([IO.Path]::Combine($PSScriptRoot, 'lib', $Name)) -Global -Force -DisableNameChecking
}

. ([IO.Path]::Combine($PSScriptRoot, 'lib', 'upwsh_home.ps1'))
Add-UpwshSessionPath

Import-ShellModule 'path.psm1'
Import-ShellModule 'unix.psm1'
Import-ShellModule 'fs.psm1'
Import-ShellModule 'proc.psm1'
Import-ShellModule 'text.psm1'
Import-ShellModule 'sys.psm1'
Import-ShellModule 'tool.psm1'
Import-ShellModule 'upwsh.psm1'
. ([IO.Path]::Combine($PSScriptRoot, 'lib', 'alias.ps1'))
Import-ShellModule 'completion.psm1'
Import-ShellModule 'git_completion.psm1'
Import-ShellModule 'theme.psm1'
Import-ShellModule 'prompt.psm1'
Import-ShellModule 'term.psm1'

# AllScope 别名必须在 dot-source 的入口里删除。
Remove-Alias -Name @(
    'cd'
    'w'
    't'
    'i'
    'd'
    'gs'
    'grep'
    'ps'
    'kill'
    'rm'
    'cp'
    'mv'
    'mkdir'
) -Scope Global -Force -ErrorAction Ignore
if (Get-Command ls -CommandType Function -ErrorAction SilentlyContinue) {
    Remove-Alias -Name ls, tree -Scope Global -Force -ErrorAction Ignore
}

$script:UserSettings = Join-Path $PSScriptRoot 'user-settings.ps1'
if (Test-Path -LiteralPath $script:UserSettings -PathType Leaf) {
    . $script:UserSettings
}

Import-ShellModule 'hook.psm1'
Complete-UpwshSessionTracking
