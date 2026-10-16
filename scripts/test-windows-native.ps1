param()

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT') {
    throw 'Windows native tests require Windows and Visual Studio 2022 with Desktop development with C++.'
}

$repoRoot = Split-Path -Parent $PSScriptRoot
$cmakeCommand = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmakeCommand) {
    $cmake = $cmakeCommand.Source
} else {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path -LiteralPath $vswhere)) {
        throw 'CMake was not found. Install the Visual Studio 2022 C++ CMake tools, or add CMake to PATH.'
    }
    $visualStudio = & $vswhere -latest -products '*' -version '[17.0,18.0)' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
    if ($LASTEXITCODE -ne 0 -or -not $visualStudio) {
        throw 'Visual Studio 2022 C++ build tools were not found.'
    }
    $cmake = Join-Path $visualStudio 'Common7\IDE\CommonExtensions\Microsoft\CMake\CMake\bin\cmake.exe'
}
$ctest = Join-Path (Split-Path -Parent $cmake) 'ctest.exe'
if (-not (Test-Path -LiteralPath $cmake) -or -not (Test-Path -LiteralPath $ctest)) {
    throw 'CMake and CTest are required. Install the Visual Studio 2022 C++ CMake tools.'
}

$testBuild = Join-Path $repoRoot 'build\windows-native-tests'
& $cmake -S (Join-Path $repoRoot 'windows\tests') -B $testBuild -G 'Visual Studio 17 2022' -A x64
if ($LASTEXITCODE -ne 0) { throw 'Windows native test configuration failed.' }
& $cmake --build $testBuild --config Release
if ($LASTEXITCODE -ne 0) { throw 'Windows native test build failed.' }
& $ctest --test-dir $testBuild -C Release --output-on-failure --no-tests=error
if ($LASTEXITCODE -ne 0) { throw 'Windows native tests failed.' }
