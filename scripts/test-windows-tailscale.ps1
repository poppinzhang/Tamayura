param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$HelperPath
)

$ErrorActionPreference = 'Stop'
Set-StrictMode -Version Latest

if ($env:OS -ne 'Windows_NT' -or [System.Runtime.InteropServices.RuntimeInformation]::OSArchitecture.ToString() -ne 'X64') {
    throw 'The Tailscale Windows runtime checks require x64 Windows.'
}
if (-not (Test-Path -LiteralPath $HelperPath -PathType Leaf)) {
    throw 'Pass the Tailscale helper from the built Windows release bundle.'
}
$helper = (Resolve-Path -LiteralPath $HelperPath).ProviderPath
$sdkRoot = Join-Path (Split-Path -Parent $PSScriptRoot) 'third_party\flutter_tailscale'
$go = (Get-Command go -ErrorAction Stop).Source
$flutter = (Get-Command flutter -ErrorAction Stop).Source

function Invoke-TailscaleChecked {
    param([string]$Command, [string[]]$Arguments)
    & $Command @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "Tailscale validation command failed with exit code ${LASTEXITCODE}: $($Arguments -join ' ')"
    }
}

$environment = @{
    CGO_ENABLED = '0'
    GOOS = 'windows'
    GOARCH = 'amd64'
    GOTOOLCHAIN = 'auto'
    FLUTTER_TAILSCALE_HELPER = $helper
}
$previousEnvironment = @{}
foreach ($name in $environment.Keys) {
    $previousEnvironment[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}

Push-Location -LiteralPath $sdkRoot
try {
    foreach ($name in $environment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $environment[$name], 'Process')
    }
    Set-Location -LiteralPath (Join-Path $sdkRoot 'native')
    Invoke-TailscaleChecked -Command $go -Arguments @('test', './...')
    Set-Location -LiteralPath $sdkRoot
    Invoke-TailscaleChecked -Command $flutter -Arguments @('pub', 'get', '--enforce-lockfile')
    Invoke-TailscaleChecked -Command $flutter -Arguments @('analyze', '--no-pub')
    # The absolute release-bundle helper enables the real process smoke tests.
    Invoke-TailscaleChecked -Command $flutter -Arguments @('test', '--no-pub')
} finally {
    try {
        foreach ($name in $previousEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $previousEnvironment[$name], 'Process')
        }
    } finally { Pop-Location }
}
