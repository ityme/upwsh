# Shared lifecycle result formatting; no installation side effects.
function Write-UpwshSetupSummary {
    param(
        [string]$Command, [string[]]$SetupOutput, [bool]$Loaded,
        [string]$HomePath, [string]$HookPath, [bool]$Color,
        [hashtable]$Before, [hashtable]$After, [string]$SourceKind = 'local'
    )
    $sourcePath = ''
    $kept = [Collections.Generic.List[string]]::new()
    $notices = [Collections.Generic.List[string]]::new()
    foreach ($line in $SetupOutput) {
        $plain = $line -replace '\x1b\[[0-9;]*m', ''
        if ($plain -match '^source\s+(.+)$') { $sourcePath = $Matches[1] }
        elseif ($plain -match '^profile\s+(.+)$') { $hookPath = $Matches[1] }
        elseif ($plain -match '^keep\s+(.+)$') { if (-not $kept.Contains($Matches[1])) { $kept.Add($Matches[1]) } }
        elseif ($plain -match '^(missing|next|warn)\s+(.+)$') { $notices.Add($plain) }
        elseif ($plain -match '^tree\s+kept\s+(.+)$') { if (-not $kept.Contains($Matches[1])) { $kept.Add($Matches[1]) } }
        elseif ($plain -and $plain -notmatch '^(home|path|target|state|cmd|command|relaunch|tree)\s+') { $notices.Add($plain) }
    }
    $result = switch ($Command) { 'install' { 'installed' } 'update' { 'updated' } 'uninstall' { 'uninstalled' } }
    $heading = "upwsh $result ✓"
    if ($color) { $heading = "$($PSStyle.Foreground.Green)$heading$($PSStyle.Reset)" }
    Write-Output ''
    $settingsPath = Join-Path $homePath 'user-settings.ps1'
    $rows = [Collections.Generic.List[object]]::new()
    if ($sourcePath -and $Command -ne 'uninstall') {
        $rows.Add(@{ Label = 'Source'; Path = $sourcePath; Status = $SourceKind })
    }
    if ($Command -eq 'uninstall') {
        $homeStatus = if ($After.HomeExists) { 'runtime removed' } else { 'removed' }
        $profileStatus = if ($Before.HookPresent) { 'unlinked' } else { 'not linked' }
        $settingsStatus = if ($After.SettingsExists) { 'kept' } elseif ($Before.SettingsExists) { 'removed' } else { 'absent' }
    } else {
        $homeStatus = $result
        $profileStatus = 'linked'
        $settingsStatus = if ($Before.SettingsExists) { 'kept' } else { 'created' }
    }
    $rows.Add(@{ Label = 'Home'; Path = $homePath; Status = $homeStatus })
    $rows.Add(@{ Label = 'Profile'; Path = $hookPath; Status = $profileStatus })
    $rows.Add(@{ Label = 'Settings'; Path = $settingsPath; Status = $settingsStatus })
    foreach ($path in $kept) {
        if ($path -ine $settingsPath -and $path -ine $homePath) {
            $rows.Add(@{ Label = 'Kept'; Path = $path; Status = 'kept' })
        }
    }
    $width = ($rows | ForEach-Object { $_.Path.Length } | Measure-Object -Maximum).Maximum
    foreach ($row in $rows) {
        $prefix = '{0,-8}' -f $row.Label
        $status = $row.Status
        if ($color) {
            $prefix = "$($PSStyle.Foreground.Green)$prefix$($PSStyle.Reset)"
            $statusColor = if ($status -eq 'kept') { $PSStyle.Foreground.Yellow } else { $PSStyle.Foreground.Green }
            $status = "$statusColor$status$($PSStyle.Reset)"
        }
        Write-Output ("  {0}  {1}  {2}" -f $prefix, $row.Path.PadRight($width), $status)
    }
    if ($notices.Count) {
        Write-Output ''
        foreach ($notice in $notices) { Write-Output "  $notice" }
    }
    Write-Output ''
    Write-Output "  $heading"
    if ($Command -eq 'uninstall') {
        Write-Output '  Restart your shell to finish cleanup.'
    } elseif ($Loaded) {
        Write-Output '  Ready in this shell.'
    } else {
        Write-Output '  Open a new PowerShell window to load upwsh.'
    }
    if ($Command -eq 'install') {
        Write-Output '  Run upwsh --help to get started.'
    }
    Write-Output ''
}
