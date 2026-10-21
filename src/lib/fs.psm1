# 文件系统命令。改名映射在 alias.ps1。

if (-not (Test-Path Variable:script:PreviousDirectory)) {
    $script:PreviousDirectory = $null
}

# 用途：切换目录并记录上一个位置，同时接受 /i/workspace 形式的路径。
# 示例：cd /i/workspace；随后执行 cd - 返回上一目录
function global:cd {
    param([string]$Path = $HOME)

    if ($Path -eq '-') {
        if (-not $script:PreviousDirectory) {
            Write-Error 'No previous directory is available.'
            return
        }

        $target = $script:PreviousDirectory
    } else {
        $target = $Path
    }

    $current = (Get-Location).Path
    try {
        Set-Location -LiteralPath $target -ErrorAction Stop
        $script:PreviousDirectory = $current
    } catch {
        Write-Error $_
    }
}


function Invoke-Eza {
    param(
        [string[]]$Options,
        [object[]]$Arguments
    )

    $windowsArguments = @(ConvertTo-WindowsPathOperands $Arguments)
    & eza '--time-style=+%Y-%m-%d %H:%M:%S' @Options @windowsArguments
}

# 用途：创建空文件；文件已存在时只更新最后修改时间；-p 允许创建缺失的父目录。
# 示例：touch notes.txt；touch -p logs/archive/app.log
function global:touch {
    try {
        $parsed = ConvertFrom-UnixArguments -Arguments @($args) -AllowedOptions @('p')
    } catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    $paths = @(ConvertTo-WindowsPathOperands $parsed.Operands)
    if ($paths.Count -eq 0) {
        $global:LASTEXITCODE = 2
        Write-Error 'Usage: touch [-p] PATH...'
        return
    }

    $status = 0
    foreach ($item in $paths) {
        try {
            $windowsPath = Resolve-WindowsPath $item
            if (Test-Path -LiteralPath $windowsPath) {
                (Get-Item -LiteralPath $windowsPath -ErrorAction Stop).LastWriteTime = Get-Date
                continue
            }

            if ($parsed.Options.Contains('p')) {
                $parent = [IO.Path]::GetDirectoryName($windowsPath)
                if (
                    $parent -and
                    -not (Test-Path -LiteralPath $parent -PathType Container)
                ) {
                    # Same recursive operation used by mkdir -p, without invoking a nested command.
                    [IO.Directory]::CreateDirectory($parent) | Out-Null
                }
            }

            [IO.File]::WriteAllText($windowsPath, '')
        } catch {
            $status = 1
            Write-Error "touch: cannot create or update '$item': $($_.Exception.Message)"
        }
    }

    $global:LASTEXITCODE = $status
}

# 用途：创建目录并立即进入该目录。
# 示例：mkcd /i/workspace/demo
function global:mkcd {
    param(
        [Parameter(Mandatory, Position = 0)]
        [string]$Path
    )

    $target = $Path
    [IO.Directory]::CreateDirectory((Resolve-WindowsPath $target)) | Out-Null
    cd $target
}

# 用途：递归查找文件或目录，支持 -name 和 -type f/d。
# 示例：find . -name '*.ps1' -type f
function global:find {
    [CmdletBinding()]
    param(
        [Parameter(Position = 0)]
        [string]$Path = '.',

        [string]$Name = '*',

        [ValidateSet('f', 'd')]
        [string]$Type
    )

    $windowsPath = Resolve-WindowsPath $Path
    if (-not (Test-Path -LiteralPath $windowsPath)) {
        Write-Warning "find: path does not exist: '$Path'."
        $global:LASTEXITCODE = 1
        return
    }

    $findErrors = $null
    $items = Get-ChildItem -LiteralPath $windowsPath -Recurse -Force -ErrorAction SilentlyContinue -ErrorVariable findErrors

    if ($Type -eq 'f') {
        $items = $items | Where-Object { -not $_.PSIsContainer }
    } elseif ($Type -eq 'd') {
        $items = $items | Where-Object { $_.PSIsContainer }
    }

    $items |
        Where-Object Name -Like $Name |
        ForEach-Object {
            unixpath $_.FullName
        }

    if ($findErrors.Count -gt 0) {
        Write-Warning "find: skipped $($findErrors.Count) inaccessible or invalid path(s)."
        $global:LASTEXITCODE = 1
    } else {
        $global:LASTEXITCODE = 0
    }
}

# 用途：输出文件或管道的前 N 项。
# 示例：Get-Content app.log | head -n 20
function global:head {
    [CmdletBinding()]
    param(
        [Alias('n')]
        [ValidateRange(0, 2147483647)]
        [int]$Lines = 10,

        [Parameter(Position = 0, ValueFromRemainingArguments)]
        [string[]]$Path,

        [Parameter(ValueFromPipeline)]
        [object]$InputObject
    )

    begin {
        if (-not $Path) {
            $selector = { Select-Object -First $Lines }.GetSteppablePipeline(
                $MyInvocation.CommandOrigin
            )
            $selector.Begin($PSCmdlet)
        }
    }

    process {
        if (-not $Path) {
            $selector.Process($InputObject)
        }
    }

    end {
        foreach ($item in @(ConvertTo-WindowsPathOperands $Path)) {
            Get-Content -LiteralPath ($item) -TotalCount $Lines
        }

        if (-not $Path) {
            $selector.End()
        }
    }
}

# 用途：输出最后 N 项；管道模式只保留 N 项，-f 可持续跟踪文件。
# 示例：tail -n 50 -f app.log
function global:tail {
    [CmdletBinding()]
    param(
        [Alias('n')]
        [ValidateRange(0, 2147483647)]
        [int]$Lines = 10,

        [Alias('f')]
        [switch]$Follow,

        [Parameter(Position = 0, ValueFromRemainingArguments)]
        [string[]]$Path,

        [Parameter(ValueFromPipeline)]
        [object]$InputObject
    )

    begin {
        $buffer = [Collections.Generic.Queue[object]]::new()
    }

    process {
        if (-not $Path -and $Lines -gt 0) {
            if ($buffer.Count -eq $Lines) {
                $null = $buffer.Dequeue()
            }
            $buffer.Enqueue($InputObject)
        }
    }

    end {
        if ($Path) {
            foreach ($item in @(ConvertTo-WindowsPathOperands $Path)) {
                Get-Content -LiteralPath ($item) -Tail $Lines -Wait:$Follow
            }
        } else {
            $buffer.ToArray()
        }
    }
}

# 用途：把本地固定磁盘上的文件或目录送入 Windows 回收站，拒绝根目录和网络路径。
# 示例：Move-ToRecycleBin (Get-Item './old.txt')
function Move-ToRecycleBin {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory, ValueFromPipeline)]
        [System.IO.FileSystemInfo]$Item
    )

    process {
        $fullPath = [IO.Path]::GetFullPath($Item.FullName)
        $root = [IO.Path]::GetPathRoot($fullPath)
        $trimCharacters = [char[]]@('\', '/')
        $normalizedPath = $fullPath.TrimEnd($trimCharacters)
        $normalizedRoot = $root.TrimEnd($trimCharacters)

        if ([string]::IsNullOrWhiteSpace($root) -or $fullPath.StartsWith('\\')) {
            throw "rm: recycle bin is unavailable for network path '$fullPath'."
        }
        if ($normalizedPath -eq $normalizedRoot) {
            throw "rm: refusing to remove drive root '$fullPath'."
        }

        $drive = [IO.DriveInfo]::new($root)
        if ($drive.DriveType -ne [IO.DriveType]::Fixed) {
            throw "rm: recycle bin is only enabled for local fixed drives: '$fullPath'."
        }

        $ui = [Microsoft.VisualBasic.FileIO.UIOption]::OnlyErrorDialogs
        $recycle = [Microsoft.VisualBasic.FileIO.RecycleOption]::SendToRecycleBin
        $cancel = [Microsoft.VisualBasic.FileIO.UICancelOption]::ThrowException
        if ($Item -is [IO.DirectoryInfo]) {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory(
                $fullPath,
                $ui,
                $recycle,
                $cancel
            )
        } else {
            [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile(
                $fullPath,
                $ui,
                $recycle,
                $cancel
            )
        }
    }
}

# 用途：删除命令只会把目标送入回收站；-r 允许目录，-f 忽略不存在的目标。
# 示例：rm -rf build
function global:rm {
    try {
        $parsed = ConvertFrom-UnixArguments -Arguments @($args) -AllowedOptions @('r', 'f')
    } catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    $paths = @(ConvertTo-WindowsPathOperands $parsed.Operands)

    if ($paths.Count -eq 0) {
        $global:LASTEXITCODE = 2
        Write-Error 'Usage: rm [-rf] PATH...'
        return
    }

    $status = 0
    foreach ($path in $paths) {
        try {
            $items = @(Get-Item -LiteralPath $path -Force -ErrorAction Stop)
        } catch {
            if (-not $parsed.Options.Contains('f')) {
                $status = 1
                Write-Error $_
            }
            continue
        }

        foreach ($item in $items) {
            if ($item -is [IO.DirectoryInfo] -and -not $parsed.Options.Contains('r')) {
                $status = 1
                Write-Error "rm: '$($item.FullName)' is a directory; use -r."
                continue
            }

            try {
                Move-ToRecycleBin $item
            } catch {
                $status = 1
                Write-Error $_
            }
        }
    }
    $global:LASTEXITCODE = $status
}

# 用途：复制文件或目录，支持 -r 递归和 -f 覆盖。
# 示例：cp -r source backup
function global:cp {
    try {
        $parsed = ConvertFrom-UnixArguments -Arguments @($args) -AllowedOptions @('r', 'f')
    } catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    $paths = @(ConvertTo-WindowsPathOperands $parsed.Operands)

    if ($paths.Count -lt 2) {
        $global:LASTEXITCODE = 2
        Write-Error 'Usage: cp [-r] SOURCE DEST'
        return
    }

    try {
        Copy-Item -LiteralPath $paths[0..($paths.Count - 2)] -Destination $paths[-1] -Recurse:$parsed.Options.Contains('r') -Force:$parsed.Options.Contains('f') -ErrorAction Stop
        $global:LASTEXITCODE = 0
    } catch {
        $global:LASTEXITCODE = 1
        Write-Error $_
    }
}

# 用途：移动或重命名文件和目录，支持 -f。
# 示例：mv old.txt new.txt
function global:mv {
    try {
        $parsed = ConvertFrom-UnixArguments -Arguments @($args) -AllowedOptions @('f')
    } catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    $paths = @(ConvertTo-WindowsPathOperands $parsed.Operands)

    if ($paths.Count -lt 2) {
        $global:LASTEXITCODE = 2
        Write-Error 'Usage: mv SOURCE DEST'
        return
    }

    try {
        Move-Item -LiteralPath $paths[0..($paths.Count - 2)] -Destination $paths[-1] -Force:$parsed.Options.Contains('f') -ErrorAction Stop
        $global:LASTEXITCODE = 0
    } catch {
        $global:LASTEXITCODE = 1
        Write-Error $_
    }
}

# 用途：创建一个或多个目录，-p 允许父目录不存在或目标已存在。
# 示例：mkdir -p logs/archive
function global:mkdir {
    try {
        $parsed = ConvertFrom-UnixArguments -Arguments @($args) -AllowedOptions @('p')
    } catch {
        $global:LASTEXITCODE = 2
        Write-Error $_
        return
    }

    $paths = @(
        foreach ($operand in $parsed.Operands) {
            Resolve-WindowsPath $operand
        }
    )

    if ($paths.Count -eq 0) {
        $global:LASTEXITCODE = 2
        Write-Error 'Usage: mkdir [-p] PATH...'
        return
    }

    try {
        foreach ($path in $paths) {
            if (-not $parsed.Options.Contains('p')) {
                if (Test-Path -LiteralPath $path) {
                    throw "mkdir: cannot create directory '$path': File exists."
                }

                $parent = [IO.Path]::GetDirectoryName($path)
                if (
                    $parent -and
                    -not (Test-Path -LiteralPath $parent -PathType Container)
                ) {
                    throw "mkdir: cannot create directory '$path': parent does not exist."
                }
            }

            [IO.Directory]::CreateDirectory($path) | Out-Null
        }
        $global:LASTEXITCODE = 0
    } catch {
        $global:LASTEXITCODE = 1
        Write-Error $_
    }
}

Export-ModuleMember -Function Invoke-Eza
