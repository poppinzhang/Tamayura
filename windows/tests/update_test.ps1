param(
    [Parameter(Mandatory = $true)][string]$OldExecutable,
    [Parameter(Mandatory = $true)][string]$NewExecutable
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
$updater = [IO.Path]::GetFullPath([IO.Path]::Combine($PSScriptRoot, '../runner/tamayura-update.ps1'))
$previousModulePath = $env:PSModulePath
$unavailableModulePath = [IO.Path]::Combine([IO.Path]::GetTempPath(), 'tamayura-unavailable-modules-' + [guid]::NewGuid().ToString('N'))
try {
    $env:PSModulePath = $unavailableModulePath
    . $updater
} finally {
    $env:PSModulePath = $previousModulePath
}
$root = Join-Path ([IO.Path]::GetTempPath()) ('tamayura-update-tests-' + [guid]::NewGuid().ToString('N'))
[IO.Directory]::CreateDirectory($root) | Out-Null
$script:caseCount = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}

function Assert-Throws([scriptblock]$Action) {
    $threw = $false
    try { & $Action | Out-Null } catch { $threw = $true }
    Assert-True $threw 'Expected the operation to reject invalid input.'
}

function Invoke-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:caseCount += 1
    Write-Host "PASS: $Name"
}

function New-Bundle([string]$Name, [bool]$NewVersion = $false) {
    $directory = Join-Path $root $Name
    [IO.Directory]::CreateDirectory((Join-Path $directory 'data/flutter_assets')) | Out-Null
    Copy-Item -LiteralPath $(if ($NewVersion) { $NewExecutable } else { $OldExecutable }) -Destination (Join-Path $directory 'Tamayura.exe')
    Copy-Item -LiteralPath $updater -Destination (Join-Path $directory 'tamayura-update.ps1')
    foreach ($file in @('flutter_windows.dll', 'sqlite3.dll', 'data/icudtl.dat', 'data/app.so', 'data/flutter_assets/AssetManifest.bin')) {
        [IO.File]::WriteAllText((Join-Path $directory $file), 'fixture')
    }
    if ($NewVersion) { Write-BundleManifest $directory '1.2.4' 5 }
    else { Write-BundleManifest $directory '1.2.3' 4 }
    return $directory
}

function New-Zip([string]$Name, [string[]]$Entries, [int]$Attributes = 0) {
    $archive = Join-Path $root $Name
    $zip = [IO.Compression.ZipFile]::Open($archive, [IO.Compression.ZipArchiveMode]::Create)
    try {
        foreach ($entryName in $Entries) {
            $entry = $zip.CreateEntry($entryName)
            $entry.ExternalAttributes = $Attributes
            $writer = New-Object IO.StreamWriter($entry.Open())
            try { $writer.Write('test payload') } finally { $writer.Dispose() }
        }
    } finally { $zip.Dispose() }
    return $archive
}

try {
    Invoke-Case 'Load native utility and management commands despite an inherited invalid module path' {
        foreach ($name in @('Get-FileHash', 'ConvertFrom-Json', 'ConvertTo-Json', 'Start-Process', 'Get-ChildItem', 'Add-Type', 'New-Object')) {
            $command = Get-Command -Name $name -ErrorAction Stop
            Assert-True ($command.ModuleName -in @('Microsoft.PowerShell.Management', 'Microsoft.PowerShell.Utility')) 'The updater did not load its own built-in command module.'
        }
    }
    Invoke-Case 'Keep expected errors readable and redact filesystem exceptions' {
        try { Stop-Update 'Readable update failure.' }
        catch { Assert-True ((Get-UpdateErrorMessage $_) -eq 'Readable update failure.') 'Expected errors should remain readable.' }
        try { [IO.File]::ReadAllText((Join-Path $root 'missing-private-file')) }
        catch { Assert-True (-not (Get-UpdateErrorMessage $_).Contains($root)) 'Filesystem paths must not appear in the reported error.' }
    }
    Invoke-Case 'Reject traversal, absolute paths, alternate streams, reserved names and ambiguous names' {
        foreach ($name in @('../escape', '/absolute', 'C:/absolute', 'dir/../../escape', 'dir\\..\\escape', 'safe:stream', 'NUL.txt', 'dir/COM1', 'trailing.', 'trailing ', 'dir//file', "control`nname")) {
            Assert-Throws { Get-SafeRelativePath $name }
        }
        Assert-True ((Get-SafeRelativePath 'data/flutter_assets/a.bin') -eq 'data/flutter_assets/a.bin') 'Valid relative paths must work.'
    }
    Invoke-Case 'Extract valid archive and reject incorrect hash' {
        $archive = New-Zip 'valid.zip' @('data/item.bin')
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        $destination = Join-Path $root 'valid-output'
        Expand-Update $archive $hash $destination
        Assert-True ([IO.File]::Exists((Join-Path $destination 'data/item.bin'))) 'The file was not extracted.'
        Assert-Throws { Expand-Update $archive ('0' * 64) (Join-Path $root 'bad-hash') }
        Assert-True (-not [IO.Directory]::Exists((Join-Path $root 'bad-hash'))) 'Incorrect hashes must fail before extraction.'
    }
    Invoke-Case 'Reject malicious ZIP entries before writing outside staging' {
        $cases = @(
            @{ name = 'traversal.zip'; entries = @('../escape.bin'); attributes = 0 },
            @{ name = 'duplicates.zip'; entries = @('file.bin', 'FILE.bin'); attributes = 0 },
            @{ name = 'symlink.zip'; entries = @('link'); attributes = -1577058304 },
            @{ name = 'reparse.zip'; entries = @('link'); attributes = 1024 }
        )
        foreach ($case in $cases) {
            $archive = New-Zip $case.name $case.entries $case.attributes
            $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
            Assert-Throws { Expand-Update $archive $hash (Join-Path $root ($case.name + '-output')) }
        }
        Assert-True (-not [IO.File]::Exists((Join-Path $root 'escape.bin'))) 'A file escaped staging.'
    }
    Invoke-Case 'Reject corrupt ZIP with otherwise matching hash' {
        $archive = Join-Path $root 'corrupt.zip'
        [IO.File]::WriteAllText($archive, 'not a zip')
        $hash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        Assert-Throws { Expand-Update $archive $hash (Join-Path $root 'corrupt-output') }
    }
    Invoke-Case 'Clean only owned successful update downloads and workspace files' {
        $cache = Join-Path $root 'cleanup-cache'
        $download = Join-Path $cache 'update-package'
        $work = Join-Path $cache ([guid]::NewGuid().ToString())
        [IO.Directory]::CreateDirectory($download) | Out-Null
        [IO.Directory]::CreateDirectory($work) | Out-Null
        $package = Join-Path $download 'Tamayura-1.2.4-windows-x64.zip'
        [IO.File]::WriteAllText($package, 'download')
        foreach ($name in @('tamayura-update.ps1', 'state.json', 'ready', 'complete')) {
            [IO.File]::WriteAllText((Join-Path $work $name), 'owned')
        }
        Clear-InstalledUpdate $package $work $cache
        Assert-True (-not [IO.Directory]::Exists($download)) 'The successful download was retained.'
        Assert-True (-not [IO.Directory]::Exists($work)) 'The completed helper workspace was retained.'
        [IO.Directory]::CreateDirectory($download) | Out-Null
        [IO.Directory]::CreateDirectory($work) | Out-Null
        [IO.File]::WriteAllText($package, 'download')
        [IO.File]::WriteAllText((Join-Path $download 'personal.txt'), 'retain')
        [IO.File]::WriteAllText((Join-Path $work 'unrelated.txt'), 'retain')
        Clear-InstalledUpdate $package $work $cache
        Assert-True ([IO.File]::Exists((Join-Path $download 'personal.txt'))) 'Cleanup removed an unrelated file.'
        Assert-True ([IO.File]::Exists((Join-Path $work 'unrelated.txt'))) 'Cleanup removed an unrelated workspace file.'
    }
    Invoke-Case 'Cleanup rejects downloads outside the cache and directory junctions' {
        $cache = Join-Path $root 'cleanup-boundary'
        $work = Join-Path $cache ([guid]::NewGuid().ToString())
        $outside = Join-Path $root 'outside-download'
        [IO.Directory]::CreateDirectory($work) | Out-Null
        [IO.Directory]::CreateDirectory($outside) | Out-Null
        $package = Join-Path $outside 'Tamayura-1.2.4-windows-x64.zip'
        [IO.File]::WriteAllText($package, 'retain')
        Clear-InstalledUpdate $package $work $cache
        Assert-True ([IO.File]::Exists($package)) 'Cleanup deleted a download outside its cache.'
        $junction = Join-Path $cache 'update-linked'
        New-Item -ItemType Junction -Path $junction -Target $outside | Out-Null
        try {
            Clear-InstalledUpdate (Join-Path $junction 'Tamayura-1.2.4-windows-x64.zip') $work $cache
            Assert-True ([IO.File]::Exists($package)) 'Cleanup followed a directory junction.'
        } finally { [IO.Directory]::Delete($junction) }
    }
    Invoke-Case 'Validate full bundle, requested version and architecture' {
        $directory = New-Bundle 'manifest'
        $null = Assert-Bundle $directory '1.2.3' 4
        Assert-Throws { Assert-Bundle $directory '1.2.4' 5 }
        $executable = Join-Path $directory 'Tamayura.exe'
        $stream = [IO.File]::Open($executable, [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite)
        $reader = New-Object IO.BinaryReader($stream)
        try {
            $stream.Position = 0x3c
            $offset = $reader.ReadUInt32()
            $stream.Position = $offset + 4
            $stream.WriteByte(0x4c)
            $stream.WriteByte(0x01)
        } finally { $reader.Dispose() }
        Assert-Throws { Assert-BundleVersion $directory '1.2.3' 4 }
    }
    Invoke-Case 'Reject missing, modified and personal files without deleting them' {
        $directory = New-Bundle 'personal-files'
        $personal = Join-Path $directory 'personal-photo.jpg'
        [IO.File]::WriteAllText($personal, 'keep me')
        Assert-Throws { Assert-Bundle $directory }
        Assert-True ([IO.File]::ReadAllText($personal) -eq 'keep me') 'Personal files were changed.'
        [IO.File]::Delete($personal)
        [IO.File]::WriteAllText((Join-Path $directory 'sqlite3.dll'), 'changed')
        Assert-Throws { Assert-Bundle $directory }
        [IO.File]::Delete((Join-Path $directory 'sqlite3.dll'))
        Assert-Throws { Assert-Bundle $directory }
    }
    Invoke-Case 'Reject junctions in the installed directory' {
        $directory = New-Bundle 'junction'
        $other = Join-Path $root 'junction-target'
        [IO.Directory]::CreateDirectory($other) | Out-Null
        $junction = Join-Path $directory 'linked'
        New-Item -ItemType Junction -Path $junction -Target $other | Out-Null
        try { Assert-Throws { Assert-Bundle $directory } }
        finally { [IO.Directory]::Delete($junction) }
    }
    Invoke-Case 'Rollback the whole bundle when restart fails' {
        $directory = New-Bundle 'rollback-old'
        $stage = New-Bundle 'rollback-new' $true
        $backup = Join-Path $root 'rollback-backup'
        $script:launchCount = 0
        function Start-Application([string]$Directory) {
            $script:launchCount += 1
            if ($script:launchCount -eq 1) { throw 'Simulated launch failure' }
        }
        Assert-Throws { Install-Bundle $directory $stage $backup '1.2.4' 5 }
        $null = Assert-Bundle $directory '1.2.3' 4
        Assert-True (-not [IO.Directory]::Exists($backup)) 'Rollback should restore the original directory.'
        Assert-True ($script:launchCount -eq 2) 'Rollback should restart the previous application.'
    }
    Invoke-Case 'Retain the old application if a file is locked' {
        $directory = New-Bundle 'locked-old'
        $stage = New-Bundle 'locked-new' $true
        $backup = Join-Path $root 'locked-backup'
        $lock = [IO.File]::Open((Join-Path $directory 'sqlite3.dll'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try { Assert-Throws { Install-Bundle $directory $stage $backup '1.2.4' 5 } }
        finally { $lock.Dispose() }
        $null = Assert-Bundle $directory '1.2.3' 4
    }
    Invoke-Case 'Prepare the real helper, wait for exit and replace the complete bundle' {
        $script:Target = New-Bundle 'portable app & update'
        $new = New-Bundle 'new-complete-bundle' $true
        $script:Archive = Join-Path $root 'complete.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($new, $script:Archive)
        $script:Sha256 = (Get-FileHash -LiteralPath $script:Archive -Algorithm SHA256).Hash
        $script:Version = '1.2.4'
        $script:BuildNumber = 5
        $script:Workspace = Join-Path $root 'work & space'
        [IO.Directory]::CreateDirectory($script:Workspace) | Out-Null
        Copy-Item -LiteralPath $updater -Destination (Join-Path $script:Workspace 'tamayura-update.ps1')
        $running = Start-Process -FilePath (Join-Path $script:Target 'Tamayura.exe') -ArgumentList '--wait' -PassThru
        $previousHelperModulePath = $env:PSModulePath
        try {
            $env:PSModulePath = $unavailableModulePath
            $script:ParentProcessId = $running.Id
            Prepare-Update
            $null = Assert-Bundle $script:Target '1.2.3' 4
            $running.Kill()
            $running.WaitForExit()
            $deadline = [DateTime]::UtcNow.AddSeconds(30)
            $complete = $false
            while ([DateTime]::UtcNow -lt $deadline) {
                if ([IO.File]::Exists((Join-Path $script:Workspace 'error.txt'))) {
                    throw [IO.File]::ReadAllText((Join-Path $script:Workspace 'error.txt'))
                }
                try {
                    $null = Assert-Bundle $script:Target '1.2.4' 5
                    if (-not [IO.File]::Exists((Join-Path $script:Workspace 'complete'))) {
                        Start-Sleep -Milliseconds 100
                        continue
                    }
                    $complete = $true
                    break
                } catch { Start-Sleep -Milliseconds 100 }
            }
            Assert-True $complete 'The helper did not install the prepared bundle.'
        } finally {
            $env:PSModulePath = $previousHelperModulePath
            if (-not $running.HasExited) { $running.Kill(); $running.WaitForExit() }
            $running.Dispose()
        }
    }
    Write-Host "$script:caseCount Windows update tests passed."
} finally {
    if ([IO.Directory]::Exists($root)) { Remove-Item -LiteralPath $root -Recurse -Force }
}
