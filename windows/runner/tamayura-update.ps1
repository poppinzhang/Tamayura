param(
    [ValidateSet('Prepare', 'Apply', 'Manifest')][string]$Mode = 'Prepare',
    [string]$Archive,
    [string]$Sha256,
    [string]$Version,
    [int]$BuildNumber,
    [string]$Target,
    [int]$ParentProcessId,
    [string]$Workspace
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem
$script:ManifestName = 'tamayura-bundle.json'
$script:Utf8 = New-Object Text.UTF8Encoding($false)

function Stop-Update([string]$Message) {
    throw [InvalidOperationException]::new('TamayuraUpdate: ' + $Message)
}

function Get-UpdateErrorMessage($Failure) {
    $exception = $Failure.Exception
    while ($null -ne $exception) {
        if ($exception.Message.StartsWith('TamayuraUpdate: ', [StringComparison]::Ordinal)) {
            return $exception.Message.Substring('TamayuraUpdate: '.Length)
        }
        $exception = $exception.InnerException
    }
    return 'The update could not be completed. Check free space, file permissions and Windows PowerShell policy, then retry. If it still fails, install the release manually.'
}

function Assert-PlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    if ($full -notmatch '^[A-Za-z]:\\' -or $full.Length -le 3) {
        Stop-Update 'Updates require a dedicated application folder on a local Windows drive.'
    }
    $current = $full
    while ($current -and (Test-Path -LiteralPath $current)) {
        $item = Get-Item -LiteralPath $current -Force
        if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            Stop-Update 'Updates cannot use symbolic links, junctions or reparse points.'
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Get-SafeRelativePath([string]$Name) {
    $relative = $Name.Replace('\', '/').TrimEnd('/')
    if (-not $relative -or $relative.StartsWith('/') -or $relative.Length -gt 240) {
        Stop-Update 'The update contains an invalid file path.'
    }
    foreach ($segment in $relative.Split('/')) {
        if (-not $segment -or $segment -in @('.', '..') -or
            $segment -match '[\x00-\x1f<>:"|?*]' -or $segment -match '[. ]$' -or
            $segment -match '^(?i:CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])(?:\.|$)') {
            Stop-Update 'The update contains an unsafe file path.'
        }
    }
    return $relative
}

function Get-BundleFiles([string]$Directory) {
    $root = Assert-PlainPath $Directory
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        foreach ($item in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                Stop-Update 'The application bundle contains a symbolic link or junction.'
            }
            $relative = Get-SafeRelativePath $item.FullName.Substring($root.Length + 1)
            if ($item.PSIsContainer) {
                $pending.Enqueue($item.FullName)
            } else {
                [PSCustomObject]@{ Path = $relative; FullName = $item.FullName; Size = $item.Length }
            }
        }
    }
}

function Assert-BundleVersion([string]$Directory, [string]$ExpectedVersion, [int]$ExpectedBuild) {
    if ($ExpectedVersion -notmatch '^\d+\.\d+\.\d+$' -or $ExpectedBuild -lt 1 -or $ExpectedBuild -gt 65535) {
        Stop-Update 'The update version is invalid.'
    }
    foreach ($required in @('Tamayura.exe', 'flutter_windows.dll', 'sqlite3.dll', 'tamayura-update.ps1', 'data/icudtl.dat', 'data/app.so')) {
        if (-not [IO.File]::Exists((Join-Path $Directory $required))) {
            Stop-Update 'The update does not contain a complete Windows application bundle.'
        }
    }
    if (-not [IO.Directory]::Exists((Join-Path $Directory 'data/flutter_assets'))) {
        Stop-Update 'The update is missing Flutter assets.'
    }
    if (Test-Path -LiteralPath (Join-Path $Directory 'native_assets.json')) {
        Stop-Update 'The update contains a development-only native asset manifest.'
    }
    $executable = Join-Path $Directory 'Tamayura.exe'
    $info = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
    if ("$($info.FileMajorPart).$($info.FileMinorPart).$($info.FileBuildPart).$($info.FilePrivatePart)" -ne "$ExpectedVersion.$ExpectedBuild") {
        Stop-Update 'The executable version does not match the requested release.'
    }
    $stream = [IO.File]::OpenRead($executable)
    $reader = New-Object IO.BinaryReader($stream)
    try {
        if ($reader.ReadUInt16() -ne 0x5a4d) { Stop-Update 'The update executable is invalid.' }
        $stream.Position = 0x3c
        $peOffset = $reader.ReadUInt32()
        if ($peOffset -gt $stream.Length - 6) { Stop-Update 'The update executable is invalid.' }
        $stream.Position = $peOffset
        if ($reader.ReadUInt32() -ne 0x4550 -or $reader.ReadUInt16() -ne 0x8664) {
            Stop-Update 'The update must contain an x64 Windows executable.'
        }
    } finally {
        $reader.Dispose()
    }
}

function Write-BundleManifest([string]$Directory, [string]$ExpectedVersion, [int]$ExpectedBuild) {
    Assert-BundleVersion $Directory $ExpectedVersion $ExpectedBuild
    $files = @(Get-BundleFiles $Directory | Where-Object { $_.Path -ne $script:ManifestName } | Sort-Object Path | ForEach-Object {
        @{ path = $_.Path; size = $_.Size; sha256 = (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant() }
    })
    $manifest = @{ schemaVersion = 1; version = $ExpectedVersion; buildNumber = $ExpectedBuild; files = $files }
    [IO.File]::WriteAllText((Join-Path $Directory $script:ManifestName), ($manifest | ConvertTo-Json -Depth 4), $script:Utf8)
}

function Assert-Bundle([string]$Directory, [string]$ExpectedVersion = '', [int]$ExpectedBuild = 0) {
    $manifestPath = Join-Path $Directory $script:ManifestName
    if (-not [IO.File]::Exists($manifestPath) -or (Get-Item -LiteralPath $manifestPath).Length -gt 33554432) {
        Stop-Update 'This application folder has no valid update manifest. Install a complete release bundle and retry.'
    }
    $manifest = [IO.File]::ReadAllText($manifestPath) | ConvertFrom-Json
    if ($manifest.schemaVersion -ne 1 -or @($manifest.files).Count -eq 0 -or @($manifest.files).Count -gt 50000) {
        Stop-Update 'The application bundle manifest is invalid.'
    }
    if ($ExpectedVersion -and ($manifest.version -ne $ExpectedVersion -or $manifest.buildNumber -ne $ExpectedBuild)) {
        Stop-Update 'The bundle manifest does not match the requested release.'
    }
    Assert-BundleVersion $Directory $manifest.version $manifest.buildNumber
    $expected = New-Object 'Collections.Generic.Dictionary[string,object]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($entry in $manifest.files) {
        $relative = Get-SafeRelativePath $entry.path
        if ($relative -eq $script:ManifestName -or $entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or $entry.size -lt 0 -or $expected.ContainsKey($relative)) {
            Stop-Update 'The application bundle manifest contains an invalid entry.'
        }
        $expected.Add($relative, $entry)
    }
    foreach ($file in Get-BundleFiles $Directory) {
        if ($file.Path -eq $script:ManifestName) { continue }
        if (-not $expected.ContainsKey($file.Path)) {
            Stop-Update 'The application folder contains extra files. Move personal files outside the application folder before updating.'
        }
        $entry = $expected[$file.Path]
        if ($file.Size -ne $entry.size -or (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash -ne $entry.sha256) {
            Stop-Update 'An application file is damaged or modified. Download a complete release bundle and retry.'
        }
        $expected.Remove($file.Path) | Out-Null
    }
    if ($expected.Count -ne 0) { Stop-Update 'The application bundle is incomplete.' }
    return $manifest
}

function Expand-Update([string]$ZipPath, [string]$ExpectedHash, [string]$Destination) {
    if ($ExpectedHash -notmatch '^[a-fA-F0-9]{64}$') { Stop-Update 'The update checksum is invalid.' }
    $archivePath = Assert-PlainPath $ZipPath
    $inputFile = [IO.File]::Open($archivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
    try {
        $hasher = [Security.Cryptography.SHA256]::Create()
        try { $actualHash = [BitConverter]::ToString($hasher.ComputeHash($inputFile)).Replace('-', '') }
        finally { $hasher.Dispose() }
        if ($actualHash -ne $ExpectedHash) { Stop-Update 'The downloaded update failed its SHA-256 check. Download it again.' }
        $inputFile.Position = 0
        $zip = New-Object IO.Compression.ZipArchive($inputFile, [IO.Compression.ZipArchiveMode]::Read, $true)
        try {
            if ($zip.Entries.Count -eq 0 -or $zip.Entries.Count -gt 50000) { Stop-Update 'The update ZIP contains too many files or is empty.' }
            $names = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
            [long]$expandedBytes = 0
            $buffer = New-Object byte[] 65536
            foreach ($entry in $zip.Entries) {
                $relative = Get-SafeRelativePath $entry.FullName
                $attributes = [long]$entry.ExternalAttributes
                if (($attributes -band 0x400) -ne 0 -or (($attributes -shr 16) -band 0xf000) -eq 0xa000 -or -not $names.Add($relative)) {
                    Stop-Update 'The update ZIP contains links or duplicate file names.'
                }
                $expandedBytes += $entry.Length
                if ($expandedBytes -gt 4294967296 -or $entry.Length -gt 2147483648) { Stop-Update 'The update ZIP exceeds the permitted extracted size.' }
                $outputPath = Join-Path $Destination $relative
                if ($entry.FullName.EndsWith('/') -or $entry.FullName.EndsWith('\')) {
                    [IO.Directory]::CreateDirectory($outputPath) | Out-Null
                    continue
                }
                [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($outputPath)) | Out-Null
                $output = [IO.File]::Open($outputPath, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
                try {
                    $content = $entry.Open()
                    try {
                        while (($readCount = $content.Read($buffer, 0, $buffer.Length)) -gt 0) {
                            if ($output.Length + $readCount -gt $entry.Length) {
                                Stop-Update 'The update ZIP contains an invalid expanded file size.'
                            }
                            $output.Write($buffer, 0, $readCount)
                        }
                    } finally { $content.Dispose() }
                    if ($output.Length -ne $entry.Length) { Stop-Update 'The update ZIP contains a truncated file.' }
                } finally { $output.Dispose() }
            }
        } finally { $zip.Dispose() }
    } finally { $inputFile.Dispose() }
}

function Quote-ProcessArgument([string]$Value) {
    return '"' + [regex]::Replace([regex]::Replace($Value, '(\\*)"', '$1$1\"'), '(\\+)$', '$1$1') + '"'
}

function Start-Application([string]$Directory) {
    $start = New-Object Diagnostics.ProcessStartInfo
    $start.FileName = Join-Path $Directory 'Tamayura.exe'
    $start.WorkingDirectory = $Directory
    $start.UseShellExecute = $false
    $process = [Diagnostics.Process]::Start($start)
    if (-not $process) { Stop-Update 'Windows could not restart Tamayura.' }
    $process.Dispose()
}

function Install-Bundle([string]$InstallDirectory, [string]$Stage, [string]$Backup, [string]$ExpectedVersion, [int]$ExpectedBuild) {
    Assert-PlainPath $InstallDirectory | Out-Null
    Assert-PlainPath $Stage | Out-Null
    $null = Assert-Bundle $InstallDirectory
    $null = Assert-Bundle $Stage $ExpectedVersion $ExpectedBuild
    [IO.Directory]::Move($InstallDirectory, $Backup)
    try {
        [IO.Directory]::Move($Stage, $InstallDirectory)
        Start-Application $InstallDirectory
    } catch {
        $failure = $_
        if ([IO.Directory]::Exists($InstallDirectory)) {
            [IO.Directory]::Move($InstallDirectory, $Stage)
        }
        [IO.Directory]::Move($Backup, $InstallDirectory)
        try { Start-Application $InstallDirectory } catch { }
        throw $failure
    }
}

function Clear-InstalledUpdate([string]$ArchivePath, [string]$WorkPath, [string]$CacheRoot) {
    try {
        $cache = Assert-PlainPath $CacheRoot
        $work = Assert-PlainPath $WorkPath
        $package = Assert-PlainPath $ArchivePath
        $download = [IO.Path]::GetDirectoryName($package)
        if ([IO.Path]::GetDirectoryName($work) -ne $cache -or
            [IO.Path]::GetFileName($work) -notmatch '^[a-fA-F0-9]{8}(?:-[a-fA-F0-9]{4}){3}-[a-fA-F0-9]{12}$' -or
            [IO.Path]::GetDirectoryName($download) -ne $cache -or
            [IO.Path]::GetFileName($download) -notmatch '^update-[a-zA-Z0-9_-]+$' -or
            [IO.Path]::GetFileName($package) -notmatch '^Tamayura-\d+\.\d+\.\d+-windows-x64\.zip$') {
            return
        }
        [IO.File]::Delete($package)
        if ([IO.Directory]::GetFileSystemEntries($download).Length -eq 0) {
            [IO.Directory]::Delete($download)
        }
        foreach ($name in @('tamayura-update.ps1', 'state.json', 'ready', 'complete')) {
            $file = Join-Path $work $name
            if ([IO.File]::Exists($file)) {
                Assert-PlainPath $file | Out-Null
                [IO.File]::Delete($file)
            }
        }
        if ([IO.Directory]::GetFileSystemEntries($work).Length -eq 0) {
            [IO.Directory]::Delete($work)
        }
    } catch { }
}

function Prepare-Update {
    $targetPath = Assert-PlainPath $Target
    $workPath = Assert-PlainPath $Workspace
    if ($workPath.StartsWith($targetPath + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Stop-Update 'The update workspace must be outside the application folder.'
    }
    $current = Assert-Bundle $targetPath
    if ([version]$Version -lt [version]$current.version -or
        ([version]$Version -eq [version]$current.version -and $BuildNumber -le $current.buildNumber)) {
        Stop-Update 'The update must be newer than the installed application.'
    }
    $parent = [IO.Path]::GetDirectoryName($targetPath)
    $identifier = [guid]::NewGuid().ToString('N')
    $stage = Join-Path $parent ('.tamayura-update-' + $identifier)
    $backup = Join-Path $parent ('.tamayura-backup-' + $identifier)
    $started = $false
    try {
        try {
            [IO.Directory]::CreateDirectory($stage) | Out-Null
            $probe = Join-Path $targetPath ('.tamayura-probe-' + $identifier)
            [IO.File]::WriteAllText($probe, '')
            [IO.File]::Delete($probe)
        } catch {
            Stop-Update 'Cannot write to the application folder or its parent. Move the whole application to a writable folder and retry, or update manually.'
        }
        Expand-Update $Archive $Sha256 $stage
        $null = Assert-Bundle $stage $Version $BuildNumber
        $state = @{ target = $targetPath; stage = $stage; backup = $backup; version = $Version; buildNumber = $BuildNumber; parentProcessId = $ParentProcessId; archive = (Assert-PlainPath $Archive) }
        [IO.File]::WriteAllText((Join-Path $workPath 'state.json'), ($state | ConvertTo-Json), $script:Utf8)
        $start = New-Object Diagnostics.ProcessStartInfo
        $start.FileName = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $workPath 'tamayura-update.ps1'), '-Mode', 'Apply', '-Workspace', $workPath)
        $start.Arguments = ($arguments | ForEach-Object { Quote-ProcessArgument $_ }) -join ' '
        $start.WorkingDirectory = $workPath
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $helper = [Diagnostics.Process]::Start($start)
        try {
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            while (-not [IO.File]::Exists((Join-Path $workPath 'ready'))) {
                if ($helper.HasExited -or [DateTime]::UtcNow -gt $deadline) {
                    Stop-Update 'The update installer did not start. Check Windows PowerShell policy and retry.'
                }
                Start-Sleep -Milliseconds 100
            }
            $started = $true
        } finally {
            if (-not $started -and -not $helper.HasExited) { $helper.Kill(); $helper.WaitForExit() }
            $helper.Dispose()
        }
    } finally {
        if (-not $started -and [IO.Directory]::Exists($stage)) {
            Remove-Item -LiteralPath $stage -Force -Recurse
        }
    }
}

function Apply-Update {
    $workPath = Assert-PlainPath $Workspace
    $state = [IO.File]::ReadAllText((Join-Path $workPath 'state.json')) | ConvertFrom-Json
    try {
        $parent = [Diagnostics.Process]::GetProcessById($state.parentProcessId)
        try {
            $null = $parent.Handle
            if ($parent.MainModule.FileName -ne (Join-Path $state.target 'Tamayura.exe')) {
                Stop-Update 'The update installer could not identify the running application.'
            }
            [IO.File]::WriteAllText((Join-Path $workPath 'ready'), [string]$PID)
            if (-not $parent.WaitForExit(300000)) { Stop-Update 'Tamayura did not exit within five minutes. Retry the update.' }
        } finally { $parent.Dispose() }
        try {
            Install-Bundle $state.target $state.stage $state.backup $state.version $state.buildNumber
        } catch {
            if ([IO.Directory]::Exists($state.backup)) {
                Stop-Update 'Update failed and automatic recovery was blocked. The previous application is preserved in the adjacent .tamayura-backup folder. Restore it manually before retrying.'
            }
            Stop-Update 'Update failed. The previous application was retained or restored. Close other Tamayura instances and any programs using its files, then retry. If needed, download the release and install it manually.'
        }
    } finally {
        if ([IO.Directory]::Exists($state.stage)) {
            try { Remove-Item -LiteralPath $state.stage -Force -Recurse } catch { }
        }
    }
    try { Remove-Item -LiteralPath $state.backup -Force -Recurse } catch { }
    [IO.File]::WriteAllText((Join-Path $workPath 'complete'), '')
    $cacheRoot = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData)) 'Tamayura\updates'
    Clear-InstalledUpdate $state.archive $workPath $cacheRoot
}

if ($MyInvocation.InvocationName -ne '.') {
    try {
        switch ($Mode) {
            'Manifest' { Write-BundleManifest $Target $Version $BuildNumber }
            'Prepare' { Prepare-Update }
            'Apply' { Apply-Update }
        }
    } catch {
        $message = Get-UpdateErrorMessage $_
        if ($Workspace -and [IO.Directory]::Exists($Workspace)) {
            [IO.File]::WriteAllText((Join-Path $Workspace 'error.txt'), $message, $script:Utf8)
        }
        if ($Mode -eq 'Apply') {
            Add-Type -AssemblyName System.Windows.Forms
            [Windows.Forms.MessageBox]::Show($message, 'Tamayura update failed', 'OK', 'Error') | Out-Null
        } else { Write-Error $message -ErrorAction Continue }
        exit 1
    }
}
