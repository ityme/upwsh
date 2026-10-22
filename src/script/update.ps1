# Update an existing installation through the same transaction as install.
#   irm https://github.com/ityme/upwsh/raw/main/src/script/update.ps1 | iex
$ErrorActionPreference = 'Stop'
$updateArguments = @($args)
$updateInvocation = $MyInvocation
$updateScriptPath = $PSCommandPath
$updateCode = 0
$tempInstall = $null

function Invoke-UpwshUpdateInstall {
    param([string]$Path, [object[]]$Tokens)
    # A function scope also prevents mode leakage when update is run through iex.
    $UpwshSetupMode = 'update'
    & $Path @Tokens
}

try {
    $installHome = [IO.Path]::GetFullPath((Join-Path $HOME '.config\upwsh'))
    $wantsHelp = @($updateArguments | Where-Object { $_ -in @('-h', '--help') }).Count -gt 0
    if (-not $wantsHelp -and $updateArguments.Count -eq 0 -and
        -not [IO.File]::Exists((Join-Path $installHome 'profile.ps1')) -and
        -not [IO.File]::Exists((Join-Path $installHome 'script\upwsh.ps1'))) {
        throw 'runtime is not installed; run upwsh install first'
    }
    $install = if ($PSScriptRoot) { Join-Path $PSScriptRoot 'install.ps1' } else { $null }
    if (-not $install -or -not [IO.File]::Exists($install)) {
        $tempInstall = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-install-' + [guid]::NewGuid().ToString('N') + '.ps1')
        $raw = Invoke-WebRequest -Uri 'https://github.com/ityme/upwsh/raw/main/src/script/install.ps1' -UseBasicParsing
        [IO.File]::WriteAllText($tempInstall, $raw.Content)
        $install = $tempInstall
    }
    if ($wantsHelp) {
        Invoke-UpwshUpdateInstall -Path $install -Tokens $updateArguments | ForEach-Object {
            $_.Replace('install.ps1', 'update.ps1').Replace('install this runtime', 'update this runtime').Replace(
                'Install then loads the current pwsh. Install and update default to --remote; use --local for a project source.',
                'Requires an installed runtime; preserves tools, user-settings.ps1, extra theme JSON, and startup loading state.'
            )
        }
    } else {
        Invoke-UpwshUpdateInstall -Path $install -Tokens $updateArguments
    }
    $updateCode = $global:LASTEXITCODE
} catch {
    Write-Output "upwsh: $($_.Exception.Message)"
    $updateCode = 1
} finally {
    if ($tempInstall -and [IO.File]::Exists($tempInstall)) {
        Remove-Item -LiteralPath $tempInstall -Force -ErrorAction SilentlyContinue
    }
}
$global:LASTEXITCODE = $updateCode
if ($updateScriptPath -and $updateInvocation.CommandOrigin -eq 'Runspace') { exit $updateCode }
