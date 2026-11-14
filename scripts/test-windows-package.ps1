param([string]$BuildRoot)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest
. (Join-Path $PSScriptRoot 'windows-package.ps1')
if (-not $BuildRoot) { $BuildRoot = Join-Path $env:SystemDrive 'TamayuraBuild\packages' }
$root = New-WindowsPackageWorkspace $BuildRoot @([Environment]::GetFolderPath([Environment+SpecialFolder]::UserProfile))
$script:caseCount = 0

function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action) {
    $failed = $false
    try { & $Action | Out-Null } catch { $failed = $true }
    Assert-True $failed 'Expected packaging to reject unsafe input.'
}
function Invoke-Case([string]$Name, [scriptblock]$Action) {
    & $Action
    $script:caseCount++
    Write-Host "PASS: $Name"
}
function Write-Fixture([string]$Relative, [string]$Content = 'source') {
    $path = Join-Path $root $Relative
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($path)) | Out-Null
    [IO.File]::WriteAllText($path, $Content)
    return $path
}

$failure = $null
try {
    $source = Join-Path $root 'checkout'
    foreach ($name in $script:WindowsPackageRequiredFiles) { Write-Fixture "checkout/$name" | Out-Null }
    foreach ($name in @('lib/main.dart', 'test/app_test.dart', 'windows/CMakeLists.txt', 'windows/runner/main.cpp', 'scripts/package-windows.ps1', 'scripts/windows-package.ps1', 'scripts/test-windows-package.ps1', 'assets/branding/hibiki/hibiki-black.png', 'assets/branding/hibiki/license/ATTRIBUTION.txt', 'android/app/src/main/kotlin/dev/tamayura/app/LanDiscovery.kt', 'macos/Runner/LanDiscovery.swift')) { Write-Fixture "checkout/$name" | Out-Null }

    Invoke-Case 'Copy current sources and protocol fixtures without local build files or secrets' {
        foreach ($name in @('.git/config', '.env', '.dart_tool/package_config.json', '.flutter-plugins-dependencies', 'build/app.so', 'dist/private.zip', 'windows/flutter/ephemeral/private.h', 'windows/build/private.cpp', 'windows/CMakeCache.txt', 'windows/private.txt', 'windows/runner/private.pfx', 'scripts/unrelated.py', 'scripts/__pycache__/windows.py', 'android/local.properties', 'android/key.properties', 'macos/Runner/private.swift')) { Write-Fixture "checkout/$name" 'PRIVATE' | Out-Null }
        $copy = Join-Path $root 'source-copy'
        Copy-WindowsPackageSource $source $copy
        Assert-True ([IO.File]::Exists((Join-Path $copy 'lib/main.dart'))) 'Application sources were omitted.'
        Assert-True ([IO.File]::Exists((Join-Path $copy 'android/app/src/main/kotlin/dev/tamayura/app/LanDiscovery.kt'))) 'The shared Android protocol test input was omitted.'
        Assert-True ([IO.File]::Exists((Join-Path $copy 'macos/Runner/LanDiscovery.swift'))) 'The shared macOS protocol test input was omitted.'
        foreach ($file in Get-ChildItem -LiteralPath $copy -File -Recurse) {
            Assert-True ([IO.File]::ReadAllText($file.FullName) -ne 'PRIVATE') 'The source copy included private or generated input.'
        }
        Assert-Throws { Copy-WindowsPackageSource $source $copy }
        Assert-Throws { Copy-WindowsPackageSource $source (Join-Path $source 'nested-copy') }
    }
    Invoke-Case 'Reject source junctions before traversing their targets' {
        $outside = Join-Path $root 'outside-source'
        Write-Fixture 'outside-source/private.dart' 'KEEP' | Out-Null
        $link = Join-Path $source 'lib/linked'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        try { Assert-Throws { Get-WindowsPackageSourceFiles $source } }
        finally { [IO.Directory]::Delete($link) }
        $link = Join-Path $root 'linked-source'
        New-Item -ItemType Junction -Path $link -Target $source | Out-Null
        try { Assert-Throws { Get-WindowsPackageSourceFiles $link } }
        finally { [IO.Directory]::Delete($link) }
        Assert-True ([IO.File]::ReadAllText((Join-Path $outside 'private.dart')) -eq 'KEEP') 'Source traversal modified an external target.'
    }
    Invoke-Case 'Require a neutral workspace outside the checkout and user profile' {
        Assert-Throws { New-WindowsPackageWorkspace (Join-Path $source 'build') @($source) }
        Assert-Throws { New-WindowsPackageWorkspace (Join-Path $root 'private/build') @((Join-Path $root 'private')) }
        Assert-Throws { New-WindowsPackageWorkspace ([IO.Path]::GetPathRoot($root)) @() }
        Assert-Throws { Remove-WindowsPackageWorkspace $root ([IO.Path]::GetPathRoot($root)) }
    }
    Invoke-Case 'Cleanup removes only its owned workspace and never follows a plugin junction' {
        $owned = New-WindowsPackageWorkspace $BuildRoot @($source)
        $outside = Join-Path $root 'shared-cache'
        Write-Fixture 'shared-cache/keep.txt' 'KEEP' | Out-Null
        [IO.Directory]::CreateDirectory((Join-Path $owned 'source/windows/flutter/ephemeral/.plugin_symlinks')) | Out-Null
        $link = Join-Path $owned 'source/windows/flutter/ephemeral/.plugin_symlinks/plugin'
        New-Item -ItemType Junction -Path $link -Target $outside | Out-Null
        $readonly = Join-Path $owned 'readonly.txt'
        [IO.File]::WriteAllText($readonly, 'remove')
        [IO.File]::SetAttributes($readonly, [IO.FileAttributes]::ReadOnly)
        Remove-WindowsPackageWorkspace $owned $BuildRoot
        Assert-True (-not [IO.Directory]::Exists($owned)) 'The owned workspace was retained.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $outside 'keep.txt')) -eq 'KEEP') 'Cleanup followed a junction into the shared cache.'
    }
    Invoke-Case 'Recover only a symlink privilege failure using resolved plugin junctions' {
        $pluginSource = Join-Path $root 'plugin-source'
        $cache = Join-Path $root 'plugin-cache'
        Write-Fixture 'plugin-cache/pubspec.yaml' 'plugin' | Out-Null
        Write-Fixture 'plugin-source/.dart_tool/package_config.json' '{}' | Out-Null
        $metadata = @{ plugins = @{ windows = @(@{ name = 'sample_plugin'; path = $cache }) } } | ConvertTo-Json -Depth 5
        Write-Fixture 'plugin-source/.flutter-plugins-dependencies' $metadata | Out-Null
        $script:pubCalls = 0
        function Invoke-TestFlutter {
            $script:pubCalls++
            if ($script:pubCalls -eq 1) {
                Write-Output 'Building with plugins requires symlink support.'
                $global:LASTEXITCODE = 1
            } else { $global:LASTEXITCODE = 0 }
        }
        Invoke-WindowsPackagePubGet 'Invoke-TestFlutter' $pluginSource
        Assert-True ($script:pubCalls -eq 2) 'Dependency resolution was not retried and checked.'
        $link = Join-Path $pluginSource 'windows/flutter/ephemeral/.plugin_symlinks/sample_plugin'
        Assert-True (((Get-Item -LiteralPath $link -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'The resolved plugin junction was not created.'
        Assert-True ([IO.File]::ReadAllText((Join-Path $link 'pubspec.yaml')) -eq 'plugin') 'The junction points to the wrong resolved plugin.'
        function Invoke-BrokenFlutter { Write-Output 'Dependency lockfile mismatch.'; $global:LASTEXITCODE = 1 }
        Assert-Throws { Invoke-WindowsPackagePubGet 'Invoke-BrokenFlutter' $pluginSource }
        $global:LASTEXITCODE = 0
    }
    Invoke-Case 'Require the Tailscale helper and notices in the complete runtime bundle' {
        $bundle = Join-Path $root 'runtime-bundle'
        foreach ($name in @('Tamayura.exe', 'flutter_windows.dll', 'sqlite3.dll', 'flutter-tailscale-bridge.exe', 'flutter-tailscale-bridge.exe.NOTICES.txt', 'data/icudtl.dat', 'data/app.so')) {
            Write-Fixture "runtime-bundle/$name" | Out-Null
        }
        [IO.Directory]::CreateDirectory((Join-Path $bundle 'data/flutter_assets')) | Out-Null
        Assert-WindowsPackageRuntime $bundle
        foreach ($name in @('flutter-tailscale-bridge.exe', 'flutter-tailscale-bridge.exe.NOTICES.txt')) {
            $path = Join-Path $bundle $name
            [IO.File]::Delete($path)
            Assert-Throws { Assert-WindowsPackageRuntime $bundle }
            [IO.Directory]::CreateDirectory($path) | Out-Null
            Assert-Throws { Assert-WindowsPackageRuntime $bundle }
            [IO.Directory]::Delete($path)
            Write-Fixture "runtime-bundle/$name" | Out-Null
        }
        Assert-WindowsPackageRuntime $bundle
    }
    Invoke-Case 'Reject UTF-8 and UTF-16 checkout paths, URI and JSON forms across read boundaries' {
        $bundle = Join-Path $root 'bundle'
        $artifact = Write-Fixture 'bundle/data/app.so' 'neutral'
        $private = 'C:\Users\Private Example\checkout'
        $variants = @($private, $private.Replace('\', '/'), $private.Replace('\', '\\'), ([uri]($private + '\')).AbsoluteUri.TrimEnd('/'), $private.ToUpperInvariant())
        foreach ($value in $variants) {
            foreach ($encoding in @([Text.Encoding]::UTF8, [Text.Encoding]::Unicode, [Text.Encoding]::BigEndianUnicode)) {
                $bytes = $encoding.GetBytes($value + '/lib/main.dart')
                $content = New-Object byte[] (65535 + $bytes.Length + 2)
                [Array]::Copy($bytes, 0, $content, 65535, $bytes.Length)
                [IO.File]::WriteAllBytes($artifact, $content)
                $message = $null
                try { Assert-WindowsPackagePrivacy $bundle @($private) }
                catch { $message = $_.Exception.Message }
                Assert-True ($message -and $message.Contains('private build path')) 'A binary path crossing a read boundary escaped the privacy gate.'
                Assert-True (-not $message.Contains('Private Example')) 'The privacy failure itself disclosed the private path.'
            }
        }
        [IO.File]::WriteAllText($artifact, 'file:///C:/TamayuraBuild/packages/windows-package-neutral/source/lib/main.dart')
        Assert-WindowsPackagePrivacy $bundle @($private)
    }
    Invoke-Case 'Reject release junctions and host-only test or debug artifacts' {
        $bundle = Join-Path $root 'bundle'
        foreach ($name in @('native_assets.json', 'kernel_blob.bin', 'isolate_snapshot_data', 'vm_snapshot_data')) {
            $file = Write-Fixture "bundle/$name"
            try { Assert-Throws { Assert-WindowsPackagePrivacy $bundle @() } }
            finally { [IO.File]::Delete($file) }
        }
        $link = Join-Path $bundle 'cache-link'
        New-Item -ItemType Junction -Path $link -Target (Join-Path $root 'shared-cache') | Out-Null
        try { Assert-Throws { Assert-WindowsPackagePrivacy $bundle @() } }
        finally { [IO.Directory]::Delete($link) }
    }
} catch { $failure = $_ }
finally {
    try { Remove-WindowsPackageWorkspace $root $BuildRoot }
    catch {
        if ($null -eq $failure) { $failure = $_ }
        else { Write-Error -ErrorRecord $_ -ErrorAction Continue }
    }
}
if ($null -ne $failure) { throw $failure }
Write-Host "$script:caseCount Windows package tests passed."
