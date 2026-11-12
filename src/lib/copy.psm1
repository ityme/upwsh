# Internal Windows copy adapter. The shell command and path conversion live elsewhere.

# Fail closed for copy operations: never traverse a reparse point, including
# one in a parent directory or a dangling link. Does not create missing paths.
function Assert-CopyPathWithoutLinks {
    param([string]$Path, [switch]$Recurse)

    $fullPath = Resolve-WindowsPath $Path
    $current = $fullPath
    while ($current) {
        try { $attributes = [IO.File]::GetAttributes($current) }
        catch [IO.FileNotFoundException] { $attributes = $null }
        catch [IO.DirectoryNotFoundException] { $attributes = $null }
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw "cp: refusing junction, symbolic link, or other reparse point: '$current'."
        }
        $current = [IO.Path]::GetDirectoryName($current.TrimEnd('\', '/'))
    }
    if (-not $Recurse -or -not [IO.Directory]::Exists($fullPath)) { return }
    $pending = [Collections.Generic.Stack[string]]::new()
    $pending.Push($fullPath)
    while ($pending.Count) {
        foreach ($entry in ([IO.DirectoryInfo]::new($pending.Pop())).EnumerateFileSystemInfos()) {
            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw "cp: refusing junction, symbolic link, or other reparse point: '$($entry.FullName)'."
            }
            if ($entry.Attributes -band [IO.FileAttributes]::Directory) { $pending.Push($entry.FullName) }
        }
    }
}


function Invoke-UpwshCopy {
    param(
        [Parameter(Mandatory)][string[]]$Sources,
        [Parameter(Mandatory)][string]$Destination,
        [switch]$Recurse,
        [switch]$Force
    )

    # Preflight the complete operation before creating targets or changing attributes.
    foreach ($source in $sources) { Assert-CopyPathWithoutLinks $source -Recurse }
    Assert-CopyPathWithoutLinks $destination
    $sourceItems = @(
        foreach ($source in $sources) {
            Get-Item -LiteralPath $source -Force -ErrorAction Stop
        }
    )
    $directories = @($sourceItems | Where-Object { $_ -is [IO.DirectoryInfo] })
    if ($directories.Count -gt 0 -and -not $Recurse) {
        throw 'cp: source is a directory; use -r.'
    }

    $robocopy = Join-Path $env:WINDIR 'System32\robocopy.exe'
    if (-not (Test-Path -LiteralPath $robocopy -PathType Leaf)) {
        throw 'robocopy.exe was not found in the Windows system directory.'
    }
    $destinationExists = Test-Path -LiteralPath $destination -PathType Container
    $singleFileRename = $sourceItems.Count -eq 1 -and
        $sourceItems[0] -is [IO.FileInfo] -and
        -not $destinationExists
    $destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($destination)
    $destinationDirectory = $destinationExists -or $directories.Count -gt 0 -or
        $sourceItems.Count -gt 1
    $copyRoot = if ($destinationDirectory) {
        $destination
    } else {
        [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($destination))
    }
    if ([string]::IsNullOrWhiteSpace($copyRoot)) { $copyRoot = (Get-Location).ProviderPath }
    # Validate every directory source before creating or copying any destination.
    foreach ($directory in $directories) {
        $sourcePath = [IO.Path]::GetFullPath($directory.FullName).TrimEnd('\', '/')
        $destinationPath = [IO.Path]::GetFullPath($destination).TrimEnd('\', '/')
        if ($destinationPath.Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase) -or
            $destinationPath.StartsWith($sourcePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw "cp: cannot copy '$sourcePath' into itself or its subdirectory '$destinationPath'."
        }
        $targetPath = if ($destinationExists -or $sourceItems.Count -gt 1) {
            Join-Path $destination $directory.Name
        } else { $destination }
        if ([IO.Path]::GetFullPath($targetPath).TrimEnd('\', '/').Equals($sourcePath, [StringComparison]::OrdinalIgnoreCase)) {
            throw "cp: source and destination are the same directory: '$sourcePath'."
        }
    }
    # Inspect only each effective write target, not unrelated destination siblings.
    # Preflight all sources before starting any copy in a multi-source operation.
    foreach ($item in $sourceItems) {
        $targetPath = if ($destinationExists -or $sourceItems.Count -gt 1) {
            Join-Path $destination $item.Name
        } else { $destination }
        Assert-CopyPathWithoutLinks $targetPath -Recurse:($item -is [IO.DirectoryInfo])
        if (-not $Force) {
            # Robocopy can clear ReadOnly itself; keep the same -f policy for
            # explicit file targets, parent-directory targets, and directory trees.
            $files = if ($item -is [IO.DirectoryInfo]) {
                $item.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)
            } else { @($item) }
            foreach ($file in $files) {
                $fileTarget = if ($item -is [IO.DirectoryInfo]) {
                    Join-Path $targetPath ([IO.Path]::GetRelativePath($item.FullName, $file.FullName))
                } else { $targetPath }
                if ([IO.File]::Exists($fileTarget) -and
                    ([IO.File]::GetAttributes($fileTarget) -band [IO.FileAttributes]::ReadOnly)) {
                    throw "cp: destination is read-only; use -f: '$fileTarget'."
                }
            }
        }
    }
    [IO.Directory]::CreateDirectory($copyRoot) | Out-Null
    if ($singleFileRename -and $sourceItems[0].FullName.Equals($destination, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'cp: source and destination are the same file.'
    }
    if ($destinationDirectory -and -not $destinationExists) {
        [IO.Directory]::CreateDirectory($destination) | Out-Null
    }

    foreach ($item in $sourceItems) {
        $sourceRoot = if ($item -is [IO.DirectoryInfo]) {
            $item.FullName
        } else {
            $item.DirectoryName
        }
        # Stage renamed files so a same-named sibling at the destination stays intact.
        $staging = if ($singleFileRename) {
            Join-Path $copyRoot ('.upwsh-copy-' + [guid]::NewGuid().ToString('N'))
        } else { $null }
        $writeRoot = if ($staging) {
            $staging
        } elseif ($item -is [IO.DirectoryInfo] -and ($destinationExists -or $sourceItems.Count -gt 1)) {
            Join-Path $destination $item.Name
        } else { $copyRoot }
        $arguments = @($sourceRoot, $writeRoot)
        if ($item -is [IO.DirectoryInfo]) {
            $arguments += @('/E', '/DCOPY:DAT')
        } else {
            $arguments += @($item.Name, '/LEV:1')
        }
        # Same, Tweaked and Modified are distinct Robocopy file classes.
        # /IM includes matching size/mtime files with a different NTFS change time.
        $arguments += @('/COPY:DAT', '/IS', '/IT', '/IM', '/XJ', '/R:1', '/W:1', '/NFL', '/NDL', '/NP', '/NJH', '/NJS')
        $clearedAttributes = [Collections.Generic.Dictionary[string, IO.FileAttributes]]::new([StringComparer]::OrdinalIgnoreCase)
        try {
            if ($Force -and -not $singleFileRename) {
                $files = if ($item -is [IO.DirectoryInfo]) {
                    $item.EnumerateFiles('*', [IO.SearchOption]::AllDirectories)
                } else { @($item) }
                foreach ($file in $files) {
                    $fileTarget = if ($item -is [IO.DirectoryInfo]) {
                        Join-Path $writeRoot ([IO.Path]::GetRelativePath($item.FullName, $file.FullName))
                    } else { Join-Path $writeRoot $file.Name }
                    if ([IO.File]::Exists($fileTarget)) {
                        $attributes = [IO.File]::GetAttributes($fileTarget)
                        if ($attributes -band [IO.FileAttributes]::ReadOnly) {
                            Assert-CopyPathWithoutLinks $fileTarget
                            $clearedAttributes[$fileTarget] = $attributes
                            [IO.File]::SetAttributes($fileTarget, $attributes -band (-bnot [IO.FileAttributes]::ReadOnly))
                        }
                    }
                }
            }
            & $robocopy @arguments | Out-Null
            $robocopyCode = $LASTEXITCODE
            if ($robocopyCode -ge 8) {
                throw "robocopy failed with exit code $robocopyCode while copying '$($item.FullName)'."
            }
            if ($singleFileRename) {
                $copiedPath = Join-Path $writeRoot $item.Name
                # Recheck after the copy, before touching the existing target.
                Assert-CopyPathWithoutLinks $destination
                $originalAttributes = $null
                if ($Force -and [IO.File]::Exists($destination)) {
                    $originalAttributes = [IO.File]::GetAttributes($destination)
                    if ($originalAttributes -band [IO.FileAttributes]::ReadOnly) {
                        [IO.File]::SetAttributes($destination, $originalAttributes -band (-bnot [IO.FileAttributes]::ReadOnly))
                    }
                }
                try {
                    [IO.File]::Move($copiedPath, $destination, $true)
                } catch {
                    if ($null -ne $originalAttributes -and [IO.File]::Exists($destination)) {
                        [IO.File]::SetAttributes($destination, $originalAttributes)
                    }
                    throw
                }
            }
        } catch {
            foreach ($path in $clearedAttributes.Keys) {
                if ([IO.File]::Exists($path)) { [IO.File]::SetAttributes($path, $clearedAttributes[$path]) }
            }
            throw
        } finally {
            if ($staging -and [IO.Directory]::Exists($staging)) {
                [IO.Directory]::Delete($staging, $true)
            }
        }
    }
}

Export-ModuleMember -Function Invoke-UpwshCopy
