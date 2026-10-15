param([Parameter(Mandatory=$true)][string]$OutputDirectory,
      [Parameter(Mandatory=$true)][string]$CoreConfigurationDirectory,
      [switch]$CompileOnly)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler)) { throw 'Windows .NET Framework compiler is required' }
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$serviceSourceDirectory = Join-Path $repositoryRoot 'windows/service'
$sources = @(
    (Join-Path $serviceSourceDirectory 'HoneyVpnService.cs'),
    (Join-Path $serviceSourceDirectory 'SafeTunConfiguration.cs'),
    (Join-Path $serviceSourceDirectory 'ProviderGeoRuleSetValidator.cs'),
    (Join-Path $serviceSourceDirectory 'KernelEpoch.cs'),
    (Join-Path $serviceSourceDirectory 'DesktopUserIdentity.cs')
)
$fixtureSource = Join-Path $PSScriptRoot 'HoneyServiceTests.cs'
foreach ($source in @($sources) + @($fixtureSource)) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) {
        throw "Windows service test source is missing: $source"
    }
}
if (-not (Test-Path -LiteralPath $CoreConfigurationDirectory -PathType Container)) {
    throw 'Windows service core configuration fixture directory is missing'
}
$coreConfigurations = (Resolve-Path -LiteralPath $CoreConfigurationDirectory).Path
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = (Resolve-Path -LiteralPath $OutputDirectory).Path
& $compiler /nologo /target:exe /platform:x64 /langversion:5 /warnaserror+ /reference:System.ServiceProcess.dll /reference:System.Web.Extensions.dll "/out:$output\HoneyVpnService.exe" $sources
if ($LASTEXITCODE -ne 0) { throw 'Windows service compilation failed' }
$fixture = Join-Path $output 'HoneyServiceTests.exe'
& $compiler /nologo /target:exe /platform:x64 /langversion:5 /warnaserror+ /define:HONEY_SERVICE_TEST /main:HoneyServiceTests /reference:System.ServiceProcess.dll /reference:System.Web.Extensions.dll "/out:$fixture" $sources $fixtureSource
if ($LASTEXITCODE -ne 0) { throw 'Windows service fixture compilation failed' }
if ($CompileOnly) {
    Write-Output 'PASS Windows service and fixture C#5 /warnaserror compilation only; runtime fixtures were not executed'
    return
}
& $fixture $coreConfigurations
if ($LASTEXITCODE -ne 0) { throw 'Windows service security/configuration fixture failed' }
