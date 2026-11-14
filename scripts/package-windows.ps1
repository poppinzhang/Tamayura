param([string]$BuildRoot)

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
. (Join-Path $PSScriptRoot 'windows-package.ps1')
if (-not $BuildRoot) { $BuildRoot = Join-Path $env:SystemDrive 'TamayuraBuild\packages' }
$privateRoots = @($repoRoot, [Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile), $env:USERPROFILE) | Select-Object -Unique
$workspace = $null
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
    $windowsPowerShell = Join-Path ([Environment]::SystemDirectory) 'WindowsPowerShell\v1.0\powershell.exe'
    Invoke-Checked -Command $windowsPowerShell -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $PSScriptRoot 'test-windows-package.ps1'), '-BuildRoot', $BuildRoot)

    # Flutter embeds the generated registrant's source URI in data/app.so. A
    # clean neutral source copy prevents the user's checkout path from shipping.
    $workspace = New-WindowsPackageWorkspace $BuildRoot $privateRoots
    $sourceDir = Join-Path $workspace 'source'
    Copy-WindowsPackageSource $repoRoot $sourceDir
    Set-Location -LiteralPath $sourceDir

    # Native checks are independent of Flutter dependencies; report storage and
    # desktop regressions before spending time on the shared Dart checks.
    & (Join-Path $sourceDir 'scripts/test-windows-native.ps1')
    Invoke-WindowsPackagePubGet $flutter $sourceDir
    Invoke-Checked -Command $dart -Arguments @('format', '--output=none', '--set-exit-if-changed', 'lib', 'test')
    Invoke-Checked -Command $flutter -Arguments @('analyze', '--no-pub')
    Invoke-Checked -Command $flutter -Arguments @('test', '--no-pub')
    # Flutter 3.47 selects the Windows target from the host architecture.
    Invoke-Checked -Command $flutter -Arguments @('build', 'windows', '--release', '--no-pub')

    $releaseDir = Join-Path $sourceDir 'build\windows\x64\runner\Release'
    $executable = Join-Path $releaseDir 'Tamayura.exe'
    Assert-WindowsPackageRuntime $releaseDir
    & (Join-Path $sourceDir 'scripts/test-windows-tailscale.ps1') -HelperPath (Join-Path $releaseDir 'flutter-tailscale-bridge.exe')
    if (Test-Path -LiteralPath (Join-Path $releaseDir 'native_assets.json')) {
        throw 'The release bundle contains the host-only Flutter test native-assets manifest.'
    }
    $fileVersion = [Diagnostics.FileVersionInfo]::GetVersionInfo($executable)
    $expectedVersion = "$version.$buildNumber"
    $actualVersion = "$($fileVersion.FileMajorPart).$($fileVersion.FileMinorPart).$($fileVersion.FileBuildPart).$($fileVersion.FilePrivatePart)"
    if ($actualVersion -ne $expectedVersion) {
        throw "Executable version mismatch: $actualVersion; expected $expectedVersion."
    }
    Invoke-Checked -Command $windowsPowerShell -Arguments @('-NoLogo', '-NoProfile', '-NonInteractive', '-ExecutionPolicy', 'Bypass', '-File', (Join-Path $releaseDir 'tamayura-update.ps1'), '-Mode', 'Manifest', '-Target', $releaseDir, '-Version', $version, '-BuildNumber', $buildNumber)
    if (-not (Test-Path -LiteralPath (Join-Path $releaseDir 'tamayura-bundle.json'))) {
        throw 'The release bundle update manifest was not generated.'
    }
    Assert-WindowsPackagePrivacy $releaseDir $privateRoots
    Write-Host 'PASS Windows release bundle environment privacy'

    $outputDir = Join-Path $repoRoot "dist\$version"
    $archiveName = "Tamayura-$version-windows-x64.zip"
    $archivePath = Join-Path $outputDir $archiveName
    New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
    Add-Type -AssemblyName System.IO.Compression
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
    Write-Host "Windows bundle: $archivePath"
    Write-Host 'Unsigned ZIP for local testing. Extract the whole bundle before running Tamayura.exe.'
} finally {
    Pop-Location
    if ($workspace) { Remove-WindowsPackageWorkspace $workspace $BuildRoot }
}
