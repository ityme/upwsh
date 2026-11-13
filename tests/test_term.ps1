$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '_test_host.ps1')
if ($env:UPWSH_TEST_ISOLATED -ne '1') {
    Invoke-UpwshIsolatedTest -File $PSCommandPath
    exit $LASTEXITCODE
}
. (Join-Path $PSScriptRoot '..\src\profile.ps1')
$term = (Get-Command Sync-TermPrompt).Module
$hook = (Get-Command prompt).Module
$script:Passed = 0
$script:Failures = [Collections.Generic.List[string]]::new()
function Assert-Equal {
    param($Actual, $Expected)
    if ([string]$Actual -cne [string]$Expected) { throw "expected <$Expected>, got <$Actual>" }
}
function Capture {
    param([scriptblock]$Action)
    $original = [Console]::Out
    $writer = [IO.StringWriter]::new()
    try { [Console]::SetOut($writer); & $Action | Out-Null; $writer.ToString() }
    finally { [Console]::SetOut($original); $writer.Dispose() }
}
function Variables {
    param([string]$Text)
    $result = @{}
    foreach ($match in [regex]::Matches($Text, '\x1b\]1337;SetUserVar=([^=]+)=([^\x07]*)\x07')) {
        $result[$match.Groups[1].Value] = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($match.Groups[2].Value))
    }
    return $result
}
function Test-Term {
    param([string]$Name, [scriptblock]$Body)
    try {
        Set-TermReporting -Reset -Mode On
        & $term { $script:TermPhase = 'none'; $script:TermEndPending = $false; $script:TermCommandStarted = $null }
        & $Body
        $script:Passed++
    } catch { $script:Failures.Add("$Name`: $($_.Exception.Message)") }
}

Test-Term 'OSC133 encloses returned prompt text rather than preceding it' {
    & $hook { $script:CachedPrompt = $null; $script:CommandPending = $false; $script:ReadingInput = $false; $script:BasePrompt = { 'VISIBLE> ' } }
    $wire = Capture { $text = prompt; [Console]::Write($text); Complete-TermPrompt }
    if (-not ($wire.IndexOf(']133;A') -lt $wire.IndexOf('VISIBLE> ') -and $wire.IndexOf('VISIBLE> ') -lt $wire.IndexOf(']133;B'))) { throw 'wrong A/text/B ordering' }
    Assert-Equal ([regex]::Matches($wire, '\]133;B').Count) 1
}
Test-Term 'OSC133 also encloses direct-write renderer output' {
    & $hook { $script:CachedPrompt = $null; $script:BasePrompt = { [Console]::Write('DIRECT'); 'RETURNED' } }
    $wire = Capture { $text = prompt; [Console]::Write($text); Complete-TermPrompt }
    if (-not ($wire.IndexOf(']133;A') -lt $wire.IndexOf('DIRECT') -and $wire.IndexOf('DIRECT') -lt $wire.IndexOf('RETURNED') -and $wire.IndexOf('RETURNED') -lt $wire.IndexOf(']133;B'))) { throw 'direct writer escaped prompt zone' }
}
Test-Term 'unchanged idle reports send boundaries only, not fields' {
    $first = Capture { Sync-TermPrompt -CommandCompleted:$false }
    $idle = Capture { Sync-TermPrompt -CommandCompleted:$false }
    Assert-Equal $idle "$([char]27)]133;D$([char]7)$([char]27)]133;A$([char]7)$([char]27)]133;B$([char]7)"
    Assert-Equal ([Text.Encoding]::UTF8.GetByteCount($idle)) 24
    Assert-Equal (Variables $idle).Count 0
    if ([Text.Encoding]::UTF8.GetByteCount($first) -le 100) { throw 'initial snapshot missing' }
}
Test-Term 'command return restores the full snapshot after a child may have changed terminal state' {
    $null = Capture { Sync-TermPrompt -CommandCompleted:$false; Sync-TermCommand -Command 'example' }
    $completed = Capture { Sync-TermPrompt -CommandCompleted:$true -Succeeded $true -ExitCode 0 }
    $values = Variables $completed
    foreach ($name in @('HOST','SESSION_ID','CWD','CWD_UNIX','PROVIDER','BUSY','OK','EXIT')) {
        if (-not $values.ContainsKey($name)) { throw "missing resynchronized $name" }
    }
    if (-not $completed.Contains(']133;D;0')) { throw 'completion status missing' }
}
Test-Term 'failure with zero or unknown native exit never reports success' {
    foreach ($code in @(0, $null, 7)) {
        $wire = Capture { Sync-TermPrompt -Succeeded $false -ExitCode $code }
        $values = Variables $wire
        Assert-Equal $values.OK '0'
        Assert-Equal $values.STATUS 'error'
        if ($values.EXIT -eq '0' -or $wire.Contains(']133;D;0')) { throw 'failure reported success' }
    }
    Assert-Equal (Variables (Capture { Sync-TermPrompt -Succeeded $true -ExitCode 7 })).EXIT '0'
}
Test-Term 'cmdlet failure does not reuse the previous native exit code' {
    & $hook { $script:CommandPending = $false; $script:CachedPrompt = $null }
    $global:LASTEXITCODE = 7
    $wire = Capture {
        Set-HookPromptInput -Line 'Write-Error fixture'
        Write-Error 'fixture' -ErrorAction SilentlyContinue
        $text = prompt
        [Console]::Write($text)
        Complete-TermPrompt
    }
    $values = Variables $wire
    Assert-Equal $values.EXIT '1'
    Assert-Equal $values.LAST_NATIVE_EXIT '7'
    Assert-Equal $global:LASTEXITCODE 7
    $global:LASTEXITCODE = 0
}
Test-Term 'file URIs encode reserved and non-ASCII characters without changing filesystem path' {
    foreach ($path in @('C:\my work\a#b', 'C:\literal%20\中文', '\\server\share\my work', 'C:\')) {
        $text = & $term { param($p) ConvertTo-TermFileUri $p } $path
        $uri = [uri]$text
        Assert-Equal $uri.Fragment ''
        $decoded = [uri]::UnescapeDataString($uri.AbsolutePath).Replace('/', '\')
        if ($path.StartsWith('\\')) {
            Assert-Equal ('\\' + $uri.Host + $decoded) $path
        } else {
            Assert-Equal $decoded.TrimStart('\') $path
            Assert-Equal $uri.Host ''
            if (-not $text.StartsWith('file:///')) { throw 'local drive URI must use an empty authority' }
        }
        if ($text.Contains(' ')) { throw 'URI has unescaped space' }
    }
}
Test-Term 'native path, Unix path and provider location are distinct' {
    $values = Variables (Capture { Sync-TermPrompt -CommandCompleted:$false })
    Assert-Equal $values.CWD_UNIX (unixpath $values.CWD)
    Push-Location Env:\
    try {
        $next = Variables (Capture { Sync-TermPrompt -CommandCompleted:$false })
        Assert-Equal $next.PROVIDER 'Environment'
        Assert-Equal $next.LOCATION 'Env:\'
        if ($next.ContainsKey('CWD')) { throw 'unchanged filesystem location sent again' }
    } finally { Pop-Location }
}
Test-Term 'identity fields are cheap stable session values' {
    $first = Variables (Capture { Sync-TermPrompt -CommandCompleted:$false })
    $next = Variables (Capture { Sync-TermPrompt -CommandCompleted:$true })
    Assert-Equal $first.PID $PID
    Assert-Equal $first.SHELL_VERSION $PSVersionTable.PSVersion.ToString()
    Assert-Equal $first.SCHEMA '2'
    Assert-Equal $first.SESSION_ID $next.SESSION_ID
    if (-not [guid]::Parse($first.SESSION_ID)) { throw 'missing session id' }
}
Test-Term 'full commands are opt-in and byte bounded including Unicode' {
    $text = 'tool --secret=fake-sensitive-value'
    $wire = Capture { Sync-TermCommand $text }
    Assert-Equal (Variables $wire).COMMAND ''
    Set-TermReporting -FullCommand $true -CommandMaxBytes 20
    $wire = Capture { Sync-TermCommand ('example ' + ('中文' * 100)) }
    $value = (Variables $wire).COMMAND
    if ([Text.Encoding]::UTF8.GetByteCount($value) -gt 20 -or $value.Contains([char]0xfffd)) { throw 'invalid/truncated UTF8 command' }
    Set-TermReporting -CommandMaxBytes 1
    $wire = Capture { Sync-TermCommand '中文' }
    Assert-Equal (Variables $wire).COMMAND ''
    Set-TermReporting -FullCommand $false
    $wire = Capture { Sync-TermCommand 'next-command' }
    Assert-Equal (Variables $wire).COMMAND ''
}
Test-Term 'last command and duration persist across idle prompts while transient elapsed clears' {
    $null = Capture { Sync-TermCommand 'example --flag' }
    $completed = Variables (Capture { Sync-TermPrompt })
    Assert-Equal $completed.LAST_CMD 'example'
    if (-not $completed.LAST_ELAPSED_MS) { throw 'persistent duration missing' }
    Assert-Equal $completed.LAST_ELAPSED_MS $completed.ELAPSED_MS
    $idle = Variables (Capture { Sync-TermPrompt -CommandCompleted:$false })
    Assert-Equal $idle.ELAPSED_MS ''
    if ($idle.ContainsKey('LAST_CMD') -or $idle.ContainsKey('LAST_ELAPSED_MS')) { throw 'unchanged last result resent' }
}
Test-Term 'monotonic duration supports long commands without Int32 overflow' {
    $null = Capture { Sync-TermCommand 'long-command' }
    & $term { $script:TermCommandStarted = [Diagnostics.Stopwatch]::GetTimestamp() - [long](25 * 86400.0 * [Diagnostics.Stopwatch]::Frequency) }
    $values = Variables (Capture { Sync-TermPrompt })
    if ([long]$values.ELAPSED_MS -lt 2160000000) { throw 'long duration invalid' }
}
Test-Term 'field selection and terminal channels are independent' {
    Set-TermReporting -Fields @('OSC133','OSC7')
    $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
    foreach ($value in (Variables $wire).Values) {
        if ($value -ne '') { throw 'disabled field was sent instead of cleared' }
    }
    if ($wire.Contains(']2;')) { throw 'disabled title emitted' }
    if (-not $wire.Contains(']133;A') -or -not $wire.Contains(']7;file://')) { throw 'selected channel missing' }
    if ((Capture { Sync-TermPrompt -CommandCompleted:$false }).Contains('SetUserVar=')) { throw 'disabled channel emitted again' }
    Set-TermReporting -Fields @('USERVARS','PID')
    $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
    Assert-Equal (Variables $wire).Count 1
    Assert-Equal (Variables $wire).PID $PID
}
Test-Term 'Auto is silent with redirected output and On is an explicit override' {
    Set-TermReporting -Mode Auto
    Assert-Equal (Capture { Sync-TermCommand 'example'; Sync-TermPrompt; Complete-TermPrompt }) ''
    Set-TermReporting -Mode On
    $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
    if (-not $wire.Contains('SetUserVar=PID=')) { throw 'forced output did not resync' }
    Set-TermReporting -Mode Off
    Assert-Equal (Capture { Sync-TermPrompt; Complete-TermPrompt }) ''
}
Test-Term 'cd reports new location before the next same-line command without prompt events' {
    $original = (Get-Location).Path
    $target = Join-Path $HOME '立即同步 # literal%20'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    try {
        Set-TermReporting -Fields @('OSC133','OSC7','OSC9_9','USERVARS','CWD','CWD_UNIX','PROVIDER','LOCATION','BUSY','COMMAND_ID')
        $null = Capture { Sync-TermPrompt -CommandCompleted:$false; Sync-TermCommand 'cd target; external' }
        $before = & $term { @($script:TermPhase, $script:TermCommandId, $script:TermCommandStarted, $script:TermEndPending) }
        $global:LASTEXITCODE = 17
        # The marker stands in for a foreground TUI: no prompt runs between cd and it.
        $wire = Capture { cd (unixpath $target); [Console]::Write('EXTERNAL_STARTED') }
        $expected = & $term { param($p) ConvertTo-TermFileUri $p } $target
        if ($wire.IndexOf("]7;$expected") -lt 0 -or $wire.IndexOf("]7;$expected") -gt $wire.IndexOf('EXTERNAL_STARTED')) { throw 'new CWD was not sent before external command' }
        if (-not $wire.Contains("]9;9;`"$target`"")) { throw 'Windows Terminal directory report missing' }
        Assert-Equal (Variables $wire).CWD $target
        Assert-Equal (Variables $wire).CWD_UNIX (unixpath $target)
        if ($wire.Contains(']133;') -or $wire.Contains('SetUserVar=BUSY=') -or $wire.Contains('SetUserVar=COMMAND_ID=') -or $wire.Contains(']2;')) { throw 'cd emitted unrelated lifecycle or title events' }
        $after = & $term { @($script:TermPhase, $script:TermCommandId, $script:TermCommandStarted, $script:TermEndPending) }
        Assert-Equal ($after -join '|') ($before -join '|')
        Assert-Equal $global:LASTEXITCODE 17
        Assert-Equal (Capture { cd (unixpath $target) }) ''
        $failedWire = Capture { try { cd (Join-Path $target missing) } catch { } }
        Assert-Equal $failedWire ''
        Assert-Equal (Get-Location).ProviderPath $target
        Set-Location -LiteralPath $original
        $null = Capture { cd (unixpath $target); cd - }
        Assert-Equal (Get-Location).Path $original
        Set-TermReporting -Mode Off
        Assert-Equal (Capture { cd (unixpath $target) }) ''
        Assert-Equal (Get-Location).ProviderPath $target
    } finally {
        Set-Location -LiteralPath $original
        Remove-Item -LiteralPath $target -Recurse -Force
        $global:LASTEXITCODE = 0
    }
}
Test-Term 'immediate location sync respects channel selection and provider paths' {
    $original = (Get-Location).Path
    try {
        Set-TermReporting -Fields @('OSC7')
        $null = Capture { Sync-TermPrompt -CommandCompleted:$false }
        $wire = Capture { cd Env:\ }
        # The filesystem CWD did not change; do not resend the same OSC7 value.
        Assert-Equal $wire ''
        if ($wire.Contains('SetUserVar=') -or $wire.Contains(']9;9;') -or $wire.Contains(']133;')) { throw 'unselected location channel emitted' }
        Assert-Equal (Get-Location).Provider.Name 'Environment'
        Set-TermReporting -Fields @('USERVARS','PROVIDER','LOCATION')
        $wire = Capture { cd Variable:\ }
        $values = Variables $wire
        Assert-Equal $values.PROVIDER 'Variable'
        Assert-Equal $values.LOCATION 'Variable:\'
        if ($wire.Contains(']7;') -or $wire.Contains(']9;9;')) { throw 'disabled cwd channel emitted' }
    } finally { Set-Location -LiteralPath $original }
}
Test-Term 'metadata failure never aborts successful cd and the next prompt resynchronizes' {
    $original = (Get-Location).Path
    $target = Join-Path $HOME 'metadata failure'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $saved = & $term { (Get-Command Get-TermLocationValues).ScriptBlock }
    try {
        $null = Capture { Sync-TermPrompt -CommandCompleted:$false }
        & $term { function script:Get-TermLocationValues { throw 'injected metadata failure' } }
        $global:LASTEXITCODE = 23
        $errorBefore = $global:Error[0]
        $errorCount = $global:Error.Count
        $wire = Capture { cd (unixpath $target); $script:MetadataContinued = $true }
        Assert-Equal $wire ''
        Assert-Equal $script:MetadataContinued $true
        Assert-Equal $global:Error.Count $errorCount
        Assert-Equal ([object]::ReferenceEquals($global:Error[0], $errorBefore)) $true
        Assert-Equal (Get-Location).ProviderPath $target
        Assert-Equal $global:LASTEXITCODE 23
        Assert-Equal (& $term { $script:TermResync }) $true
        & $term { param($body) Set-Item Function:script:Get-TermLocationValues $body } $saved
        $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
        Assert-Equal (Variables $wire).CWD $target
    } finally {
        & $term { param($body) Set-Item Function:script:Get-TermLocationValues $body } $saved
        Set-Location -LiteralPath $original
        Remove-Item -LiteralPath $target -Force
        $global:LASTEXITCODE = 0
    }
}
Test-Term 'failed write does not commit directory channels or fields and retries at the same location' {
    $original = (Get-Location).Path
    $target = Join-Path $HOME 'write failure'
    [IO.Directory]::CreateDirectory($target) | Out-Null
    $saved = & $term { (Get-Command Write-TermText).ScriptBlock }
    try {
        $null = Capture { Sync-TermPrompt -CommandCompleted:$false }
        $before = & $term { @($script:TermSent['CWD'], $script:TermSent['OSC7']) }
        & $term { function script:Write-TermText { param($Text) throw [IO.IOException]::new('injected write failure') } }
        $global:LASTEXITCODE = 31
        $errorBefore = $global:Error[0]
        $errorCount = $global:Error.Count
        $wire = Capture { cd (unixpath $target) }
        Assert-Equal $wire ''
        Assert-Equal (Get-Location).ProviderPath $target
        Assert-Equal $global:LASTEXITCODE 31
        Assert-Equal $global:Error.Count $errorCount
        Assert-Equal ([object]::ReferenceEquals($global:Error[0], $errorBefore)) $true
        $after = & $term { @($script:TermSent['CWD'], $script:TermSent['OSC7']) }
        Assert-Equal ($after -join '|') ($before -join '|')
        & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved
        $wire = Capture { Sync-TermLocation }
        Assert-Equal (Variables $wire).CWD $target
        if (-not $wire.Contains(']7;file://')) { throw 'unchanged location did not retry failed channel' }
        Assert-Equal (Capture { Sync-TermLocation }) ''
    } finally {
        & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved
        Set-Location -LiteralPath $original
        Remove-Item -LiteralPath $target -Force
        $global:LASTEXITCODE = 0
    }
}
Test-Term 'field clears remain pending on failed output and commit only on retry' {
    Set-TermReporting -Fields @('USERVARS','CWD')
    $null = Capture { Sync-TermLocation }
    $saved = & $term { (Get-Command Write-TermText).ScriptBlock }
    try {
        Set-TermReporting -Fields @('OSC7')
        & $term { function script:Write-TermText { param($Text) throw [IO.IOException]::new('injected clear failure') } }
        $null = Capture { Sync-TermLocation }
        Assert-Equal (& $term { $script:TermClearFields.Contains('CWD') }) $true
        Assert-Equal (& $term { $script:TermSent.ContainsKey('CWD') }) $true
        & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved
        $wire = Capture { Sync-TermLocation }
        if (-not $wire.Contains("]1337;SetUserVar=CWD=$([char]7)")) { throw 'field clear was lost on failed output' }
        Assert-Equal (& $term { $script:TermClearFields.Contains('CWD') }) $false
        Assert-Equal (& $term { $script:TermSent.ContainsKey('CWD') }) $false
        if ((Capture { Sync-TermLocation }).Contains('SetUserVar=CWD=')) { throw 'successful clear was resent' }
    } finally { & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved }
}
Test-Term 'a partially written frame forces even previously unchanged location data to resend' {
    Set-TermReporting -Fields @('USERVARS','CWD','OSC7')
    $null = Capture { Sync-TermLocation }
    $saved = & $term { (Get-Command Write-TermText).ScriptBlock }
    try {
        # A device may accept a prefix before throwing. The shell cannot know which
        # sequences arrived, so the next location frame must resend its snapshot.
        Set-TermReporting -Fields @('OSC7')
        & $term { function script:Write-TermText { param($Text) [Console]::Write($Text); throw [IO.IOException]::new('partial output') } }
        $wire = Capture { Sync-TermLocation }
        if (-not $wire.Contains('SetUserVar=CWD=')) { throw 'partial-clear fixture did not write' }
        Set-TermReporting -Fields @('USERVARS','CWD','OSC7')
        & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved
        $wire = Capture { Sync-TermLocation }
        Assert-Equal (Variables $wire).CWD (Get-Location).ProviderPath
        if (-not $wire.Contains(']7;file://')) { throw 'partial output did not force channel resync' }
    } finally { & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved }
}
Test-Term 're-enabling a field cancels its undelivered clear' {
    Set-TermReporting -Fields @('USERVARS','CWD')
    $null = Capture { Sync-TermLocation }
    Set-TermReporting -Fields @('OSC7')
    Assert-Equal (& $term { $script:TermClearFields.Contains('CWD') }) $true
    Set-TermReporting -Fields @('USERVARS','CWD')
    $wire = Capture { Sync-TermLocation }
    if ($wire.Contains("]1337;SetUserVar=CWD=$([char]7)")) { throw 're-enabled field was incorrectly cleared' }
    Assert-Equal (& $term { $script:TermSent.ContainsKey('CWD') }) $true
}
Test-Term 'prompt write failure keeps resync pending until a successful snapshot' {
    $saved = & $term { (Get-Command Write-TermText).ScriptBlock }
    try {
        & $term { function script:Write-TermText { param($Text) throw [IO.IOException]::new('injected prompt failure') } }
        $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
        Assert-Equal $wire ''
        Assert-Equal (& $term { $script:TermResync }) $true
        Assert-Equal (& $term { $script:TermIdleKey }) $null
        & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved
        $wire = Capture { Sync-TermPrompt -CommandCompleted:$false }
        if (-not (Variables $wire).ContainsKey('CWD')) { throw 'prompt did not resend the full snapshot' }
        Assert-Equal (& $term { $script:TermResync }) $false
    } finally { & $term { param($body) Set-Item Function:script:Write-TermText $body } $saved }
}
Test-Term 'no command label invents an executable from an expression' {
    Assert-Equal (Get-TermCommandName '$null = 1') ''
    Assert-Equal (Get-TermCommandName '"text"') ''
    Assert-Equal (Get-TermCommandName '& "C:\my tools\rg.exe" pattern') 'rg.exe'
}
if ($script:Failures.Count) {
    $script:Failures | ForEach-Object { Write-Error $_ -ErrorAction Continue }
    throw "$($script:Failures.Count) terminal tests failed."
}
Write-Output "$script:Passed terminal tests passed."
