# Track function/alias changes made while loading the runtime, across reloads.
$script:Owned = @{}
$script:Keys = @{}
$script:Options = @{}
function Get-UpwshCommandSnapshot {
    $snapshot = @{}
    foreach ($command in @(Get-ChildItem Function:) + @(Get-Alias -Scope Global)) {
        if ($command.ModuleName -eq $ExecutionContext.SessionState.Module.Name) { continue }
        $kind = if ($command -is [Management.Automation.AliasInfo]) { 'Alias' } else { 'Function' }
        $snapshot["$kind/$($command.Name)"] = [pscustomobject]@{
            Kind = $kind
            Definition = $command.Definition
            Options = $command.Options
            ScriptBlock = if ($kind -eq 'Function') { $command.ScriptBlock } else { $null }
        }
    }
    return $snapshot
}
function Test-UpwshCommandIdentity {
    param($Left, $Right)
    if ($null -eq $Left -or $null -eq $Right) { return $null -eq $Left -and $null -eq $Right }
    if ($Left.Kind -eq 'Alias') {
        return $Right.Kind -eq 'Alias' -and $Left.Definition -ceq $Right.Definition -and $Left.Options -eq $Right.Options
    }
    return $Right.Kind -eq 'Function' -and [object]::ReferenceEquals($Left.ScriptBlock, $Right.ScriptBlock)
}
function Start-UpwshSessionTracking {
    $script:Before = Get-UpwshCommandSnapshot
}
function Complete-UpwshSessionTracking {
    $after = Get-UpwshCommandSnapshot
    foreach ($key in @($script:Before.Keys) + @($after.Keys) | Select-Object -Unique) {
        if (Test-UpwshCommandIdentity $script:Before[$key] $after[$key]) { continue }
        if (-not $script:Owned.ContainsKey($key) -or
            -not (Test-UpwshCommandIdentity $script:Owned[$key].Installed $script:Before[$key])) {
            $script:Owned[$key] = @{ Original = $script:Before[$key]; Installed = $after[$key] }
        } else { $script:Owned[$key].Installed = $after[$key] }
    }
    $script:Before = $null
}
function Set-UpwshReadLineKeyHandler {
    param(
        [Alias('Key')][string]$Chord,
        [string]$Function,
        [scriptblock]$ScriptBlock,
        [string]$BriefDescription,
        [string]$LongDescription
    )
    $current = Get-PSReadLineKeyHandler -Chord $Chord
    if (-not $script:Keys.ContainsKey($Chord)) {
        # PSReadLine does not expose custom handler scriptblocks. Leave them alone
        # instead of replacing a binding that cannot be restored reliably.
        $method = [Microsoft.PowerShell.PSConsoleReadLine].GetMethods() | Where-Object Name -eq $current.Function
        if (-not $method) { return }
        $script:Keys[$Chord] = @{ Original = $current.Function; Installed = $null }
    }
    $parameters = @{ Chord = $Chord }
    if ($ScriptBlock) {
        $parameters.ScriptBlock = $ScriptBlock
        $parameters.BriefDescription = if ($BriefDescription) { $BriefDescription } else { "Upwsh$Chord" }
        if ($LongDescription) { $parameters.LongDescription = $LongDescription }
    } else { $parameters.Function = $Function }
    Set-PSReadLineKeyHandler @parameters
    $script:Keys[$Chord].Installed = (Get-PSReadLineKeyHandler -Chord $Chord).Function
}
function Set-UpwshReadLineOption {
    param([string]$Name, $Value)
    $current = (Get-PSReadLineOption).$Name
    if (-not $script:Options.ContainsKey($Name)) {
        $script:Options[$Name] = @{ Original = $current; Installed = $null }
    }
    $parameters = @{}; $parameters[$Name] = $Value
    Set-PSReadLineOption @parameters
    $script:Options[$Name].Installed = (Get-PSReadLineOption).$Name
}
function Restore-UpwshSessionCommands {
    param([switch]$KeepEntry)
    foreach ($chord in $script:Keys.Keys) {
        $record = $script:Keys[$chord]
        if ((Get-PSReadLineKeyHandler -Chord $chord).Function -ceq $record.Installed) {
            Set-PSReadLineKeyHandler -Chord $chord -Function $record.Original
        }
    }
    $script:Keys.Clear()
    foreach ($name in $script:Options.Keys) {
        $record = $script:Options[$name]
        if ([object]::Equals((Get-PSReadLineOption).$name, $record.Installed)) {
            $parameters = @{}; $parameters[$name] = $record.Original
            Set-PSReadLineOption @parameters
        }
    }
    $script:Options.Clear()
    $current = Get-UpwshCommandSnapshot
    foreach ($key in @($script:Owned.Keys)) {
        if ($KeepEntry -and $key -eq 'Function/upwsh') { continue }
        $record = $script:Owned[$key]
        if (-not (Test-UpwshCommandIdentity $record.Installed $current[$key])) { continue }
        $kind, $name = $key -split '/', 2
        $original = $record.Original
        # The initial installer imports the same entry before profile tracking starts.
        # That entry belongs to this installation, not to a pre-existing user command.
        if ($key -eq 'Function/upwsh' -and $original -and $record.Installed -and
            $original.Definition -ceq $record.Installed.Definition) { $original = $null }
        if ($kind -eq 'Alias') {
            Remove-Alias -Name $name -Scope Global -Force -ErrorAction Ignore
            if ($original) { Set-Alias -Name $name -Value $original.Definition -Option $original.Options -Scope Global -Force }
        } else {
            Remove-Item -LiteralPath "Function:$name" -Force -ErrorAction Ignore
            if ($original) { Set-Item -LiteralPath "Function:global:$name" -Value $original.ScriptBlock -Options $original.Options -Force }
        }
        $script:Owned.Remove($key)
    }
}
Export-ModuleMember -Function Start-UpwshSessionTracking, Complete-UpwshSessionTracking, Restore-UpwshSessionCommands, Set-UpwshReadLineKeyHandler, Set-UpwshReadLineOption
