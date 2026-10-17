param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'Build the Windows app on Windows with Flutter 3.47.6 and Visual Studio 2022.'
}
if ([System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'The Windows release bundle requires an x64 Windows build host.'
}

# PowerShell 5.1 does not turn a native process failure into a terminating error.
# Check every Flutter/Dart exit code explicitly, so failed tests cannot be packaged.
function Invoke-Checked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Command $($Arguments -join ' ') failed with exit code $LASTEXITCODE."
    }
}

$repoRoot = Split-Path -Parent $PSScriptRoot
Push-Location $repoRoot
try {
    $versionMatch = [regex]::Match((Get-Content pubspec.yaml -Raw), '(?m)^version:\s*(\d+\.\d+\.\d+)\+(\d+)\s*$')
    if (-not $versionMatch.Success) {
        throw 'pubspec.yaml must contain version: major.minor.patch+build.'
    }
    $version = $versionMatch.Groups[1].Value
    $buildNumber = $versionMatch.Groups[2].Value
    $flutter = (Get-Command flutter -ErrorAction Stop).Source
    $dart = (Get-Command dart -ErrorAction Stop).Source

    Invoke-Checked -Command $flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Invoke-Checked -Command $dart -Arguments @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test')
    Invoke-Checked -Command $flutter -Arguments @('analyze', '--no-pub')
    Invoke-Checked -Command $flutter -Arguments @('test', '--no-pub')
    & (Join-Path $PSScriptRoot 'test-windows-native.ps1')
    # Flutter 3.47 selects the Windows target from the host architecture.
    Invoke-Checked -Command $flutter -Arguments @('build', 'windows', '--release', '--no-pub')

    $releaseDir = Join-Path $repoRoot 'build\windows\x64\runner\Release'
    $executable = Join-Path $releaseDir 'Tamayura.exe'
    foreach ($required in @($executable, (Join-Path $releaseDir 'flutter_windows.dll'), (Join-Path $releaseDir 'sqlite3.dll'), (Join-Path $releaseDir 'data\icudtl.dat'), (Join-Path $releaseDir 'data\app.so'), (Join-Path $releaseDir 'data\flutter_assets'))) {
        if (-not (Test-Path -LiteralPath $required)) {
            throw "The release bundle is incomplete: $required"
        }
    }
    if (Test-Path -LiteralPath (Join-Path $releaseDir 'native_assets.json')) {
        throw 'The release bundle contains the host-only Flutter test native-assets manifest.'
    }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
    $expectedVersion = "$version.$buildNumber"
    $actualVersion = "$($fileVersion.FileMajorPart).$($fileVersion.FileMinorPart).$($fileVersion.FileBuildPart).$($fileVersion.FilePrivatePart)"
    if ($actualVersion -ne $expectedVersion) {
        throw "Executable version mismatch: $actualVersion; expected $expectedVersion."
    }

    $outputDir = Join-Path $repoRoot "dist\$version"
    $archiveName = "Tamayura-$version-windows-x64.zip"
    $archivePath = Join-Path $outputDir $archiveName
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    $temporaryArchive = Join-Path $outputDir "$archiveName.tmp"
    try {
        if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive }
        # Include the entire Flutter Release bundle: plugins, native assets, data,
        # and runtime DLLs. Copying only Tamayura.exe does not produce a runnable app.
        [IO.Compression.ZipFile]::CreateFromDirectory($releaseDir, $temporaryArchive, [IO.Compression.CompressionLevel]::Optimal, $false)
        $zip = [IO.Compression.ZipFile]::OpenRead($temporaryArchive)
        try {
            $archiveFiles = @($zip.Entries | Where-Object { $_.Name } | ForEach-Object { $_.FullName.Replace('\', '/') })
            $releaseFiles = @(Get-ChildItem -LiteralPath $releaseDir -File -Recurse | ForEach-Object { $_.FullName.Substring($releaseDir.Length + 1).Replace('\', '/') })
            if (Compare-Object $releaseFiles $archiveFiles) {
                throw 'The ZIP file list differs from the complete Release bundle.'
            }
        } finally {
            $zip.Dispose()
        }
        Move-Item -LiteralPath $temporaryArchive -Destination $archivePath -Force
    } finally {
        if (Test-Path -LiteralPath $temporaryArchive) { Remove-Item -LiteralPath $temporaryArchive }
    }
    $hash = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
    # Keep the existing Android/macOS release manifest and checksums intact.
    [IO.File]::WriteAllText((Join-Path $outputDir 'SHA256SUMS-windows'), "$hash  $archiveName`n", [Text.Encoding]::ASCII)
    Write-Host "Windows preview bundle: $archivePath"
    Write-Host 'Unsigned ZIP for local testing. Extract the whole bundle before running Tamayura.exe.'
} finally {
    Pop-Location
}
