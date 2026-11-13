# Shared deployment for install/update. Source acquisition happens before this file is loaded.
function Test-UpwshThemeHeaders {
    param([string]$Root, [string[]]$Names)

    foreach ($name in $Names) {
        $file = Join-Path $Root $name
        if (-not [IO.File]::Exists($file)) { continue }
        try {
            if ([IO.FileInfo]::new($file).Length -gt 65536) { throw 'theme exceeds 64 KiB' }
            $data = [IO.File]::ReadAllText($file) | ConvertFrom-Json -AsHashtable -ErrorAction Stop
            if ($data -isnot [Collections.IDictionary] -or
                $data.Modules -isnot [Collections.IDictionary] -or $data.Order -isnot [array]) {
                throw 'requires Order and Modules'
            }
        } catch {
            throw "cannot deploy with theme '$file': $($_.Exception.Message). Back up old themes outside theme/, replace them with Order/Modules files or move them out, then retry. No theme conversion or overwrite is performed."
        }
    }
}

function Get-UpwshThemeNames {
    param([string]$Root)
    if (-not [IO.Directory]::Exists((Join-Path $Root 'theme'))) { return @() }
    return @(Get-ChildItem -LiteralPath (Join-Path $Root 'theme') -Filter '*.json' -File | ForEach-Object BaseName)
}

function Move-UpwshLegacyCustomThemes {
    param([string]$Target, [string]$Backup, $Migrations, $Created)

    $legacyRoot = Join-Path $Target 'custom\themes'
    if (-not [IO.Directory]::Exists($legacyRoot)) { return }
    $themeRoot = Join-Path $Target 'theme'
    New-UpwshDeploymentDirectory -Path $themeRoot -Created $Created
    foreach ($file in Get-ChildItem -LiteralPath $legacyRoot -Filter '*.json' -File) {
        $destination = Join-Path $themeRoot $file.Name
        if ([IO.File]::Exists($destination)) {
            Write-Warning "keeping existing theme; leftover custom theme remains: $($file.Name)"
            continue
        }
        [IO.File]::Move($file.FullName, $destination)
        $Migrations.Add([pscustomobject]@{ Legacy = $file.FullName; Destination = $destination })
    }
    $legacySelection = Join-Path $Target 'custom\theme.json'
    $selection = Join-Path $Target 'theme.json'
    if ([IO.File]::Exists($legacySelection) -and -not [IO.File]::Exists($selection)) {
        [IO.File]::Move($legacySelection, $selection)
        $Migrations.Add([pscustomobject]@{ Legacy = $legacySelection; Destination = $selection })
    }
}

function Test-UpwshRuntime {
    param(
        [string]$Root,
        [switch]$Staged
    )

    foreach ($name in @(
        'profile.ps1',
        'lib\path_convert.ps1', 'lib\upwsh_home.ps1', 'lib\alias.ps1', 'lib\session.psm1',
        'lib\path.psm1', 'lib\unix.psm1', 'lib\copy.psm1', 'lib\fs.psm1', 'lib\proc.psm1', 'lib\text.psm1', 'lib\sys.psm1',
        'lib\tool.psm1', 'lib\upwsh.psm1', 'lib\completion.psm1', 'lib\git_completion.psm1', 'lib\theme.psm1', 'lib\prompt.psm1', 'lib\term.psm1', 'lib\hook.psm1',
        'theme\pure-classic.json',
        'script\install.ps1', 'script\update.ps1', 'script\uninstall.ps1',
        'script\upwsh.ps1', 'script\install_profile.ps1', 'script\install_cli_tool.ps1',
        'script\_deploy.ps1', 'script\_relaunch.ps1', 'script\_setup_output.ps1'
    )) {
        if (-not [IO.File]::Exists([IO.Path]::Combine($Root, $name))) {
            throw "invalid runtime: missing $name"
        }
    }
    if (-not $Staged -and -not [IO.File]::Exists((Join-Path $Root 'user-settings.ps1'))) {
        throw 'invalid runtime: missing user-settings.ps1'
    }
    Test-UpwshThemeHeaders -Root (Join-Path $Root 'theme') -Names @(Get-ChildItem -LiteralPath (Join-Path $Root 'theme') -Filter '*.json' -File | ForEach-Object Name)
    $scripts = foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.Name -in @('tests', 'theme', 'themes', 'tool', 'bin', '.git', 'user-settings.ps1', 'theme.json')) { continue }
        if ($item.PSIsContainer) {
            Get-ChildItem -LiteralPath $item.FullName -Recurse -File | Where-Object Extension -In '.ps1', '.psm1'
        } elseif ($item.Extension -in @('.ps1', '.psm1')) { $item }
    }
    foreach ($file in $scripts) {
        $tokens = $null
        $errors = $null
        [void][Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref]$tokens, [ref]$errors)
        if ($errors.Count) { throw "invalid runtime: $($file.Name): $($errors[0].Message)" }
    }
}

function Copy-UpwshRuntime {
    param([string]$Source, [string]$Destination)

    [void][IO.Directory]::CreateDirectory($Destination)
    foreach ($item in Get-ChildItem -LiteralPath $Source -Force) {
        if ($item.Name -in @('tests', 'themes', 'tool', 'bin', '.git', 'user-settings.ps1', 'theme.json')) { continue }
        Copy-Item -LiteralPath $item.FullName -Destination (Join-Path $Destination $item.Name) -Recurse -Force
    }
}


function Get-UpwshEnvironmentSnapshot {
    $values = @{}
    if (-not $env:UPWSH_SKIP_PERSIST_PATH) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.OpenSubKey('Environment')
        try {
            foreach ($name in @('UPWSH_HOME', 'Path')) {
                $exists = $key -and $name -in $key.GetValueNames()
                $values[$name] = [pscustomobject]@{
                    Exists = [bool]$exists
                    Value = if ($exists) { $key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) } else { $null }
                    Kind = if ($exists) { $key.GetValueKind($name) } else { $null }
                }
            }
        } finally { if ($key) { $key.Close() } }
    }
    [pscustomobject]@{ Home = $env:UPWSH_HOME; Path = $env:PATH; UserValues = $values }
}

function Restore-UpwshEnvironment {
    param($Snapshot)

    $env:UPWSH_HOME = $Snapshot.Home
    $env:PATH = $Snapshot.Path
    if ($Snapshot.UserValues.Count) {
        $key = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
        try {
            foreach ($name in $Snapshot.UserValues.Keys) {
                $value = $Snapshot.UserValues[$name]
                if ($value.Exists) { $key.SetValue($name, $value.Value, $value.Kind) }
                else { $key.DeleteValue($name, $false) }
            }
        } finally { $key.Close() }
    }
}

function Get-UpwshManagedFiles {
    param([string]$Root)

    if (-not [IO.Directory]::Exists($Root)) { return }
    foreach ($item in Get-ChildItem -LiteralPath $Root -Force) {
        if ($item.Name -in @('theme', 'themes', 'tool', 'bin', '.git', 'user-settings.ps1', 'theme.json')) { continue }
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "refusing to replace a linked runtime path: $($item.FullName)"
        }
        if ($item.PSIsContainer) {
            foreach ($child in Get-ChildItem -LiteralPath $item.FullName -Recurse -Force) {
                if ($child.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                    throw "refusing to replace a linked runtime path: $($child.FullName)"
                }
                if (-not $child.PSIsContainer) { $child }
            }
        } else { $item }
    }
}

function New-UpwshDeploymentDirectory {
    param([string]$Path, [Collections.Generic.List[string]]$Created)

    if ([IO.Directory]::Exists($Path)) { return }
    $parent = [IO.Path]::GetDirectoryName($Path)
    if ($parent) { New-UpwshDeploymentDirectory -Path $parent -Created $Created }
    [void][IO.Directory]::CreateDirectory($Path)
    $Created.Add($Path)
}

function Set-UpwshDeploymentFile {
    param([string]$Source, [string]$Target, [string]$Backup, $Journal, $Created)

    New-UpwshDeploymentDirectory -Path ([IO.Path]::GetDirectoryName($Target)) -Created $Created
    if ([IO.File]::Exists($Target)) {
        $old = [IO.File]::ReadAllBytes($Target)
        $new = [IO.File]::ReadAllBytes($Source)
        if ($old.Length -eq $new.Length -and [Convert]::ToBase64String($old) -ceq [Convert]::ToBase64String($new)) { return }
        [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Backup))
        [IO.File]::Replace($Source, $Target, $Backup)
        $Journal.Add([pscustomobject]@{ Target = $Target; Backup = $Backup; Added = $false })
    } else {
        [IO.File]::Move($Source, $Target)
        $Journal.Add([pscustomobject]@{ Target = $Target; Backup = $null; Added = $true })
    }
}

function Install-UpwshRuntime {
    param(
        [string]$Source,
        [string]$Destination
    )

    $sourcePath = [IO.Path]::GetFullPath($Source).TrimEnd('\', '/')
    $targetPath = [IO.Path]::GetFullPath($Destination).TrimEnd('\', '/')
    if ($sourcePath -ieq $targetPath -or $sourcePath.StartsWith($targetPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        throw 'the installed runtime cannot be its own source; use a local project or a download'
    }
    if (Test-Path -LiteralPath (Join-Path $targetPath '.git')) { throw 'refusing to replace a git checkout' }
    Test-UpwshRuntime $sourcePath

    $parent = Split-Path -Parent $targetPath
    [void][IO.Directory]::CreateDirectory($parent)
    $id = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $parent ".upwsh-stage-$id"
    $backup = Join-Path $parent ".upwsh-backup-$id"
    $environment = Get-UpwshEnvironmentSnapshot
    $configurationStarted = $false
    $rollbackFailed = $false
    $journal = [Collections.Generic.List[object]]::new()
    $migrations = [Collections.Generic.List[object]]::new()
    $created = [Collections.Generic.List[string]]::new()
    $activeFile = $null
    $shim = Join-Path $targetPath 'bin\upwsh.cmd'
    $shimBytes = if ([IO.File]::Exists($shim)) { [IO.File]::ReadAllBytes($shim) } else { $null }
    $output = [Collections.Generic.List[object]]::new()
    try {
        Copy-UpwshRuntime -Source $sourcePath -Destination $stage
        Test-UpwshRuntime $stage -Staged
        Move-UpwshLegacyCustomThemes -Target $targetPath -Backup $backup -Migrations $migrations -Created $created
        # Windows can hold directory handles for running shells/tools. Keep all live directories
        # in place and replace only managed files, recording enough to undo every successful edit.
        $oldFiles = @(Get-UpwshManagedFiles $targetPath)
        $newFiles = @(Get-UpwshManagedFiles $stage)
        $names = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($file in $newFiles) {
            $relative = [IO.Path]::GetRelativePath($stage, $file.FullName)
            [void]$names.Add($relative)
            $activeFile = Join-Path $targetPath $relative
            Set-UpwshDeploymentFile -Source $file.FullName -Target $activeFile -Backup (Join-Path $backup $relative) -Journal $journal -Created $created
        }
        foreach ($file in $oldFiles) {
            $relative = [IO.Path]::GetRelativePath($targetPath, $file.FullName)
            if ($names.Contains($relative)) { continue }
            $activeFile = $file.FullName
            $saved = Join-Path $backup $relative
            [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
            [IO.File]::Move($activeFile, $saved)
            $journal.Add([pscustomobject]@{ Target = $activeFile; Backup = $saved; Added = $false })
        }
        $bundledNames = @(Get-UpwshThemeNames $sourcePath)
        foreach ($theme in Get-ChildItem -LiteralPath (Join-Path $stage 'theme') -Filter '*.json' -File) {
            if ($theme.BaseName -notin $bundledNames) { continue }
            $activeFile = Join-Path $targetPath ('theme\' + $theme.Name)
            Set-UpwshDeploymentFile -Source $theme.FullName -Target $activeFile -Backup (Join-Path $backup ('theme\' + $theme.Name)) -Journal $journal -Created $created
        }
        $legacyThemes = Join-Path $targetPath 'themes'
        if ([IO.Directory]::Exists($legacyThemes)) {
            $themeRoot = Join-Path $targetPath 'theme'
            New-UpwshDeploymentDirectory -Path $themeRoot -Created $created
            foreach ($file in Get-ChildItem -LiteralPath $legacyThemes -Filter '*.json' -File) {
                $destination = Join-Path $themeRoot $file.Name
                if ($file.BaseName -in $bundledNames -or [IO.File]::Exists($destination)) {
                    $activeFile = $file.FullName
                    $saved = Join-Path $backup ('themes\' + $file.Name)
                    [void][IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($saved))
                    [IO.File]::Move($activeFile, $saved)
                    $journal.Add([pscustomobject]@{ Target = $activeFile; Backup = $saved; Added = $false })
                    continue
                }
                [IO.File]::Move($file.FullName, $destination)
                $journal.Add([pscustomobject]@{ Target = $destination; Backup = $null; Added = $true })
            }
        }
        $userSettingsSource = Join-Path $sourcePath 'user-settings.ps1'
        $userSettingsTarget = Join-Path $targetPath 'user-settings.ps1'
        if ([IO.File]::Exists($userSettingsSource) -and -not [IO.File]::Exists($userSettingsTarget)) {
            $activeFile = $userSettingsTarget
            New-UpwshDeploymentDirectory -Path ([IO.Path]::GetDirectoryName($userSettingsTarget)) -Created $created
            Copy-Item -LiteralPath $userSettingsSource -Destination $userSettingsTarget
            $journal.Add([pscustomobject]@{ Target = $userSettingsTarget; Backup = $null; Added = $true })
        }
        foreach ($name in @('bin', 'tool\bin', 'theme')) {
            New-UpwshDeploymentDirectory -Path (Join-Path $targetPath $name) -Created $created
        }
        $activeFile = $null
        $configurationStarted = $true
        . (Join-Path $targetPath 'lib\upwsh_home.ps1')
        foreach ($line in @(Add-UpwshUserEnvironment)) { $output.Add($line) }
    } catch {
        $failure = $_
        $rollbackErrors = [Collections.Generic.List[string]]::new()
        if ($configurationStarted) {
            try {
                $shim = Join-Path $targetPath 'bin\upwsh.cmd'
                if ($null -ne $shimBytes) {
                    if (-not [IO.File]::Exists($shim) -or [Convert]::ToBase64String([IO.File]::ReadAllBytes($shim)) -cne [Convert]::ToBase64String($shimBytes)) {
                        [IO.File]::WriteAllBytes($shim, $shimBytes)
                    }
                }
                elseif ([IO.File]::Exists($shim)) { [IO.File]::Delete($shim) }
            } catch { $rollbackErrors.Add("shim: $($_.Exception.Message)") }
        }
        foreach ($migration in $migrations) {
            try {
                if ([IO.File]::Exists($migration.Destination)) { [IO.File]::Move($migration.Destination, $migration.Legacy) }
            } catch { $rollbackErrors.Add("theme migration $($migration.Legacy): $($_.Exception.Message)") }
        }
        for ($index = $journal.Count - 1; $index -ge 0; $index--) {
            $entry = $journal[$index]
            try {
                if ($entry.Added) { [IO.File]::Delete($entry.Target) }
                elseif ([IO.File]::Exists($entry.Target)) { [IO.File]::Replace($entry.Backup, $entry.Target, [Management.Automation.Language.NullString]::Value) }
                else { [IO.File]::Move($entry.Backup, $entry.Target) }
            } catch { $rollbackErrors.Add("$($entry.Target): $($_.Exception.Message)") }
        }
        for ($index = $created.Count - 1; $index -ge 0; $index--) {
            try { [IO.Directory]::Delete($created[$index], $false) }
            catch { $rollbackErrors.Add("$($created[$index]): $($_.Exception.Message)") }
        }
        if ($configurationStarted) {
            try { Restore-UpwshEnvironment $environment }
            catch { $rollbackErrors.Add("environment: $($_.Exception.Message)") }
        }
        if ($rollbackErrors.Count) {
            $rollbackFailed = $true
            throw "deployment failed: $($failure.Exception.Message); rollback incomplete: $($rollbackErrors -join '; '). Recovery locations: $targetPath, $backup and $stage"
        }
        if ($activeFile) {
            throw "could not update '$activeFile': $($failure.Exception.Message). Previous files restored. Close programs using this file, check its permissions, then retry."
        }
        throw $failure
    } finally {
        # Only our private staging/backup directories are removed; never the live install root.
        if (-not $rollbackFailed) {
            foreach ($temporary in @($stage, $backup)) {
                if (Test-Path -LiteralPath $temporary) {
                    try { Remove-Item -LiteralPath $temporary -Recurse -Force }
                    catch { Write-Warning "cleanup incomplete; recovery files remain at $temporary" }
                }
            }
        }
    }
    Write-UpwshStatus home $targetPath source $sourcePath state deployed
    if ($output.Count -gt 0) {
        Write-Output ''
        $output
    }
    Write-Output ''
    Write-UpwshStatus command upwsh
}
