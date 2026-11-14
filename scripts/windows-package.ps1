# Helpers shared by the Windows packager and its standalone regression tests.
# Keep source selection aligned with package-windows-source.py. The two other
# platform discovery sources are also needed by protocol_version_test.dart.
$script:WindowsPackageRequiredFiles = @('AGENTS.md', 'CHANGELOG.md', 'LICENSE', 'README.md', 'analysis_options.yaml', 'l10n.yaml', 'pubspec.yaml', 'pubspec.lock')
$script:WindowsPackageOptionalFiles = @('.gitignore', '.metadata', '.github/workflows/windows.yml', 'assets/branding/hibiki/license/ATTRIBUTION.txt', 'assets/branding/hibiki/license/Nagino-OFL.txt', 'android/app/src/main/kotlin/dev/tamayura/app/LanDiscovery.kt', 'macos/Runner/LanDiscovery.swift', 'third_party/flutter_tailscale/test/fixtures/test-cert.pem', 'third_party/flutter_tailscale/test/fixtures/test-key.pem')
$script:WindowsPackageSuffixes = @{
    'third_party/flutter_tailscale' = @('.dart', '.go', '.c', '.h', '.mod', '.sum', '.yaml', '.lock', '.txt', '.json', '.md', '.gradle', '.kt', '.xml', '.sh', '.py')
    lib = @('.dart', '.arb'); test = @('.dart'); tool = @('.dart'); proto = @('.proto')
    assets = @('.png', '.jpg', '.jpeg', '.webp', '.ico', '.svg'); docs = @('.md')
    windows = @('.cc', '.cpp', '.h', '.hpp', '.cmake', '.txt', '.manifest', '.rc', '.ico', '.ps1')
    scripts = @('.ps1', '.py')
}
$script:WindowsPackageExcludedParts = @('.git', '.dart_tool', '.gradle', '.vs', '.idea', '.pub-cache', '.plugin_symlinks', 'ephemeral', 'build', 'dist', 'coverage', 'keystore', '__pycache__', 'node_modules')
$script:WindowsPackageExcludedNames = @('key.properties', 'local.properties', 'CMakeCache.txt')

function Assert-WindowsPackagePlainPath([string]$Path) {
    $full = [IO.Path]::GetFullPath($Path).TrimEnd('\')
    $current = $full
    while ($current) {
        if (Test-Path -LiteralPath $current) {
            if (((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'Windows packaging cannot traverse a symbolic link or junction in a source or workspace path.'
            }
        }
        $current = [IO.Path]::GetDirectoryName($current)
    }
    return $full
}

function Get-WindowsPackageSourceFiles([string]$Root) {
    $rootPath = Assert-WindowsPackagePlainPath $Root
    $selected = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($name in $script:WindowsPackageRequiredFiles + $script:WindowsPackageOptionalFiles) {
        $path = Join-Path $rootPath $name
        if ([IO.File]::Exists($path)) {
            Assert-WindowsPackagePlainPath $path | Out-Null
            $null = $selected.Add($name.Replace('\', '/'))
        } elseif ($name -in $script:WindowsPackageRequiredFiles) { throw "Missing required source file: $name" }
    }
    foreach ($name in $script:WindowsPackageSuffixes.Keys) {
        $directory = Join-Path $rootPath $name
        if (-not [IO.Directory]::Exists($directory)) {
            if ($name -in @('lib', 'test', 'windows', 'scripts')) { throw "Missing required source directory: $name" }
            continue
        }
        Assert-WindowsPackagePlainPath $directory | Out-Null
        $pending = New-Object 'Collections.Generic.Queue[string]'
        $pending.Enqueue($directory)
        while ($pending.Count -gt 0) {
            foreach ($entry in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
                if ($entry.PSIsContainer) {
                    if ($entry.Name -in $script:WindowsPackageExcludedParts) { continue }
                    if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source directory links are not allowed in a Windows package build.' }
                    $pending.Enqueue($entry.FullName)
                    continue
                }
                if ($entry.Name -in $script:WindowsPackageExcludedNames -or $entry.Extension.ToLowerInvariant() -notin $script:WindowsPackageSuffixes[$name]) { continue }
                if ($name -eq 'windows' -and $entry.Extension -eq '.txt' -and $entry.Name -ne 'CMakeLists.txt') { continue }
                if ($name -eq 'scripts' -and -not $entry.Name.Contains('windows')) { continue }
                if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'Source file links are not allowed in a Windows package build.' }
                $null = $selected.Add($entry.FullName.Substring($rootPath.Length + 1).Replace('\', '/'))
            }
        }
    }
    return @($selected | Sort-Object)
}

function Copy-WindowsPackageSource([string]$Root, [string]$Destination) {
    $rootPath = Assert-WindowsPackagePlainPath $Root
    $target = Assert-WindowsPackagePlainPath $Destination
    if ($target -eq $rootPath -or $target.StartsWith($rootPath + '\', [StringComparison]::OrdinalIgnoreCase) -or (Test-Path -LiteralPath $target)) {
        throw 'The package source copy requires a new directory outside the checkout.'
    }
    $files = @(Get-WindowsPackageSourceFiles $rootPath)
    foreach ($name in $files) {
        $source = Assert-WindowsPackagePlainPath (Join-Path $rootPath $name)
        $copy = Join-Path $target $name
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($copy)) | Out-Null
        [IO.File]::Copy($source, $copy, $false)
    }
}

function New-WindowsPackageWorkspace([string]$Parent, [string[]]$PrivateRoots) {
    $parentPath = Assert-WindowsPackagePlainPath $Parent
    if ($parentPath -notmatch '^[A-Za-z]:\\' -or $parentPath.Length -le 3) { throw 'Use a dedicated local directory for neutral Windows builds.' }
    foreach ($private in $PrivateRoots) {
        if (-not $private) { continue }
        $privatePath = [IO.Path]::GetFullPath($private).TrimEnd('\')
        if ($parentPath -eq $privatePath -or $parentPath.StartsWith($privatePath + '\', [StringComparison]::OrdinalIgnoreCase)) {
            throw 'The neutral Windows build directory must be outside the checkout and user profile.'
        }
    }
    [IO.Directory]::CreateDirectory($parentPath) | Out-Null
    $workspace = Join-Path $parentPath ('windows-package-' + [guid]::NewGuid().ToString('N'))
    if (Test-Path -LiteralPath $workspace) { throw 'The Windows package workspace already exists.' }
    [IO.Directory]::CreateDirectory($workspace) | Out-Null
    return $workspace
}

function Remove-WindowsPackageWorkspace([string]$Workspace, [string]$Parent) {
    $parentPath = Assert-WindowsPackagePlainPath $Parent
    $root = [IO.Path]::GetFullPath($Workspace).TrimEnd('\')
    if ([IO.Path]::GetDirectoryName($root) -ne $parentPath -or [IO.Path]::GetFileName($root) -notmatch '^windows-package-[0-9a-f]{32}$') {
        throw 'Refusing to remove a directory not owned by this package build.'
    }
    if (-not [IO.Directory]::Exists($root)) { return }
    Assert-WindowsPackagePlainPath $root | Out-Null
    # Flutter plugin junctions refer to the shared package cache. Never recurse
    # through them, including under Windows PowerShell 5.1.
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $directories = New-Object 'Collections.Generic.List[string]'
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        $directory = $pending.Dequeue()
        $directories.Add($directory)
        foreach ($entry in Get-ChildItem -LiteralPath $directory -Force) {
            if (-not $entry.FullName.StartsWith($root + '\', [StringComparison]::OrdinalIgnoreCase)) { throw 'Unexpected package cleanup target.' }
            $linked = ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0
            if ($entry.PSIsContainer) {
                if ($linked) { [IO.Directory]::Delete($entry.FullName) }
                else { $pending.Enqueue($entry.FullName) }
            } else {
                if (-not $linked -and $entry.IsReadOnly) { $entry.IsReadOnly = $false }
                [IO.File]::Delete($entry.FullName)
            }
        }
    }
    for ($index = $directories.Count - 1; $index -ge 0; $index--) { [IO.Directory]::Delete($directories[$index]) }
}

function New-WindowsPackagePluginJunctions([string]$Source) {
    $root = Assert-WindowsPackagePlainPath $Source
    $metadata = Get-Content -LiteralPath (Join-Path $root '.flutter-plugins-dependencies') -Raw | ConvertFrom-Json
    if (-not (Test-Path -LiteralPath (Join-Path $root '.dart_tool/package_config.json'))) { throw 'Dependency resolution did not complete before plugin link creation.' }
    $links = Join-Path $root 'windows/flutter/ephemeral/.plugin_symlinks'
    Assert-WindowsPackagePlainPath $links | Out-Null
    [IO.Directory]::CreateDirectory($links) | Out-Null
    foreach ($plugin in $metadata.plugins.windows) {
        if ($plugin.name -notmatch '^[a-z][a-z0-9_]*$' -or -not [IO.Directory]::Exists($plugin.path)) { throw 'Invalid resolved Windows plugin metadata.' }
        $link = Join-Path $links $plugin.name
        if (Test-Path -LiteralPath $link) { continue }
        New-Item -ItemType Junction -Path $link -Target $plugin.path -ErrorAction Stop | Out-Null
    }
}

function Invoke-WindowsPackagePubGet([string]$Flutter, [string]$Source) {
    $output = New-Object 'Collections.Generic.List[string]'
    $previousPreference = $ErrorActionPreference
    try {
        $ErrorActionPreference = 'Continue'
        & $Flutter pub get --enforce-lockfile 2>&1 | ForEach-Object { $output.Add($_.ToString()); Write-Host $_ }
        $result = $LASTEXITCODE
    } finally { $ErrorActionPreference = $previousPreference }
    if ($result -eq 0) { return }
    if (($output -join "`n") -notmatch 'Building with plugins requires symlink support') { throw 'Flutter dependency resolution failed; packaging stopped.' }
    # Pub has resolved the locked dependencies and emitted plugin metadata. A
    # junction needs no symlink privilege and changes no system security setting.
    New-WindowsPackagePluginJunctions $Source
    & $Flutter pub get --enforce-lockfile
    if ($LASTEXITCODE -ne 0) { throw 'Flutter dependency resolution failed after creating Windows plugin junctions.' }
}

function Assert-WindowsPackageRuntime([string]$Bundle) {
    foreach ($name in @('Tamayura.exe', 'flutter_windows.dll', 'sqlite3.dll', 'flutter-tailscale-bridge.exe', 'flutter-tailscale-bridge.exe.NOTICES.txt', 'data\icudtl.dat', 'data\app.so')) {
        if (-not (Test-Path -LiteralPath (Join-Path $Bundle $name) -PathType Leaf)) {
            throw "The release bundle is incomplete: $name"
        }
    }
    if (-not (Test-Path -LiteralPath (Join-Path $Bundle 'data\flutter_assets') -PathType Container)) {
        throw 'The release bundle is incomplete: data\flutter_assets'
    }
}

function Assert-WindowsPackagePrivacy([string]$Bundle, [string[]]$PrivateRoots) {
    if (-not ('TamayuraPackage.BinaryPrivacy' -as [type])) {
        Add-Type -TypeDefinition @'
using System;
using System.IO;
using System.Text;
namespace TamayuraPackage {
    public static class BinaryPrivacy {
        private static byte Fold(byte value) {
            return value >= 65 && value <= 90 ? (byte)(value + 32) : value;
        }
        public static bool ContainsPath(string file, string[] markers) {
            var patterns = new System.Collections.Generic.List<byte[]>();
            int overlap = 0;
            foreach (var marker in markers) {
                foreach (var encoding in new Encoding[] { Encoding.UTF8, Encoding.Unicode, Encoding.BigEndianUnicode }) {
                    var bytes = encoding.GetBytes(marker);
                    for (int i = 0; i < bytes.Length; i++) bytes[i] = Fold(bytes[i]);
                    patterns.Add(bytes);
                    overlap = Math.Max(overlap, bytes.Length - 1);
                }
            }
            var buffer = new byte[65536 + overlap];
            int retained = 0;
            using (var input = File.OpenRead(file)) {
                int read;
                while ((read = input.Read(buffer, retained, 65536)) > 0) {
                    int length = retained + read;
                    for (int i = retained; i < length; i++) buffer[i] = Fold(buffer[i]);
                    foreach (var pattern in patterns) {
                        int offset = 0;
                        while (offset <= length - pattern.Length) {
                            offset = Array.IndexOf(buffer, pattern[0], offset, length - pattern.Length - offset + 1);
                            if (offset < 0) break;
                            int i = 1;
                            while (i < pattern.Length && buffer[offset + i] == pattern[i]) i++;
                            if (i == pattern.Length) return true;
                            offset++;
                        }
                    }
                    retained = Math.Min(overlap, length);
                    Buffer.BlockCopy(buffer, length - retained, buffer, 0, retained);
                }
            }
            return false;
        }
    }
}
'@
    }
    $root = Assert-WindowsPackagePlainPath $Bundle
    $markers = New-Object 'Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
    foreach ($private in $PrivateRoots) {
        if (-not $private) { continue }
        $path = [IO.Path]::GetFullPath($private).TrimEnd('\')
        if ($path.Length -le 3) { continue }
        $null = $markers.Add($path)
        $null = $markers.Add($path.Replace('\', '/'))
        $null = $markers.Add($path.Replace('\', '\\'))
        $null = $markers.Add(([uri]($path + '\')).AbsoluteUri.TrimEnd('/'))
    }
    $pending = New-Object 'Collections.Generic.Queue[string]'
    $pending.Enqueue($root)
    while ($pending.Count -gt 0) {
        foreach ($entry in Get-ChildItem -LiteralPath $pending.Dequeue() -Force) {
            if (($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) { throw 'The Windows release bundle contains a symbolic link or junction.' }
            if ($entry.PSIsContainer) { $pending.Enqueue($entry.FullName); continue }
            if ($entry.Name -in @('native_assets.json', 'kernel_blob.bin', 'isolate_snapshot_data', 'vm_snapshot_data')) { throw 'The Windows release bundle contains test or debug artifacts.' }
            if ([TamayuraPackage.BinaryPrivacy]::ContainsPath($entry.FullName, [string[]]@($markers))) {
                throw 'The Windows release bundle contains a private build path; packaging stopped before publishing any archive.'
            }
        }
    }
}
