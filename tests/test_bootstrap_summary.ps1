# Focused output test: mock acquisition/deployment, never run a real installation.
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
$root = Join-Path ([IO.Path]::GetTempPath()) ('upwsh-summary-' + [guid]::NewGuid().ToString('N'))
$passed = 0
try {
    $source = Join-Path $root 'download-temp/src'
    [IO.Directory]::CreateDirectory((Join-Path $source script)) | Out-Null
    Copy-Item (Join-Path $PSScriptRoot '../src/script/_setup_output.ps1') (Join-Path $source 'script/_setup_output.ps1')
    [IO.File]::WriteAllText((Join-Path $source 'script/_deploy.ps1'), @'
function Install-UpwshRuntime {
    param($Source,$Destination)
    "home      $Destination"
    "source    $Source"
    'state     deployed'
    'warn      fixture warning'
    if ($env:UPWSH_SUMMARY_TEST_FAIL) { throw 'fixture deployment failed' }
    [IO.Directory]::CreateDirectory((Join-Path $Destination script)) | Out-Null
    [IO.File]::WriteAllText((Join-Path $Destination 'script/upwsh.ps1'), '"state     installed"')
}
'@)
    $entry = Join-Path $root install.ps1
    $text = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/script/install.ps1'))
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($text,[ref]$t,[ref]$e)
    foreach ($spec in @(
        @{Name='Get-DownloadedRuntime'; Body='[pscustomobject]@{Root=$env:UPWSH_SUMMARY_TEST_SOURCE;Work=$env:UPWSH_SUMMARY_TEST_WORK;SourceLabel="https://github.com/ityme/upwsh@main"}'},
        @{Name='Resolve-RuntimeRoot'; Body='param($Path) $Path'}
    ) | Sort-Object {($ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $spec.Name},$true)).Extent.StartOffset} -Descending) {
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $spec.Name},$true)
        $text=$text.Remove($fn.Extent.StartOffset,$fn.Extent.Text.Length).Insert($fn.Extent.StartOffset,"function $($spec.Name) { $($spec.Body) }")
    }
    [IO.File]::WriteAllText($entry,$text)
    foreach($mode in @('standalone','nested','failure','legacy')) {
        if($mode -eq 'legacy'){Remove-Item -LiteralPath (Join-Path $source 'script/_setup_output.ps1')}
        $homePath=Join-Path $root $mode
        $work=Join-Path $root ("work-$mode");[IO.Directory]::CreateDirectory($work)|Out-Null
        $envs=@{UPWSH_SUMMARY_TEST_SOURCE=$source;UPWSH_SUMMARY_TEST_WORK=$work;UPWSH_SKIP_SESSION_LOAD=$null;UPWSH_OSC='Off'}
        if($mode -eq 'failure'){$envs.UPWSH_SUMMARY_TEST_FAIL='1'}
        $suffix=if($mode -eq 'nested'){' --skip-load'}else{''}
        $code = if ($mode -eq 'nested') {
            '& ' + (ConvertTo-TestLiteral $entry) + ' --skip-load; exit $LASTEXITCODE'
        } else {
            'Get-Content -Raw ' + (ConvertTo-TestLiteral $entry) + ' | Invoke-Expression; exit $LASTEXITCODE'
        }
        $r=Invoke-UpwshTestProcess -UserHome $homePath -Command $code -Environment $envs
        if($mode -eq 'failure'){
            if($r.Code -eq 0 -or $r.Text -notmatch 'fixture deployment failed' -or $r.Text -match '✓'){throw $r.Text}
        } elseif($mode -eq 'standalone') {
            if($r.Code -ne 0 -or ([regex]::Matches($r.Text,'upwsh installed ✓')).Count -ne 1 -or $r.Text -notmatch 'Source\s+https://github\.com/ityme/upwsh@main\s+remote' -or $r.Text -match 'download-temp' -or $r.Text -notmatch 'fixture warning'){throw $r.Text}
        } elseif($r.Code -ne 0 -or $r.Text -match '✓' -or $r.Text -notmatch 'state\s+deployed') {throw $r.Text}
        $passed++
    }
    # Exercise the real fixed-main download without network or extraction.
    $original = [IO.File]::ReadAllText((Join-Path $PSScriptRoot '../src/script/install.ps1'))
    $t=$null;$e=$null;$ast=[Management.Automation.Language.Parser]::ParseInput($original,[ref]$t,[ref]$e)
    $downloadFn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq 'Get-DownloadedRuntime'},$true)
    & {
        param($definition)
        Invoke-Expression $definition
        function Save-Uri { param($Uri,$Path) $script:RequestedUri=$Uri }
        function Expand-Archive { param($LiteralPath,$DestinationPath,[switch]$Force) }
        function Resolve-RuntimeRoot { param($Path) $Path }
        $savedRef=$env:UPWSH_REF; $savedRepo=$env:UPWSH_REPO
        try {
            $env:UPWSH_REF='dev'; $env:UPWSH_REPO='other/repo'
            $download = Get-DownloadedRuntime
            try {
                if ($download.SourceLabel -cne 'https://github.com/ityme/upwsh@main') { throw 'incorrect fixed-main source label' }
                if ($script:RequestedUri -cne 'https://github.com/ityme/upwsh/archive/refs/heads/main.zip') { throw 'remote download changed from official main' }
            } finally { Remove-Item -LiteralPath $download.Work -Recurse -Force }
        } finally { $env:UPWSH_REF=$savedRef; $env:UPWSH_REPO=$savedRepo }
    } $downloadFn.Extent.Text
    $passed++
    foreach ($definitionName in @('New-InstallParseResult','ConvertFrom-InstallArguments')) {
        $fn=$ast.Find({param($n)$n -is [Management.Automation.Language.FunctionDefinitionAst] -and $n.Name -eq $definitionName},$true)
        Invoke-Expression $fn.Extent.Text
    }
    foreach ($option in @('--ref','--repo')) {
        $parsed=ConvertFrom-InstallArguments @($option,'dev')
        if (-not $parsed.Help -or $parsed.Error -cne "unknown option: $option") { throw 'obsolete remote selector was accepted' }
    }
    $passed++
} finally { Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue }
Write-Output "$passed bootstrap summary tests passed."
