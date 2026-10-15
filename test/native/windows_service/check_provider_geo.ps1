param([string]$OutputDirectory,
      [string]$ComposerFixtureDirectory)
$ErrorActionPreference = 'Stop'
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../../..')).Path
$sources = @(
    (Join-Path $repositoryRoot 'windows/service/SafeTunConfiguration.cs'),
    (Join-Path $repositoryRoot 'windows/service/ProviderGeoRuleSetValidator.cs'),
    (Join-Path $PSScriptRoot 'ProviderGeoRuleSetTests.cs')
)
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw "Provider geo fixture source is missing: $source" }
}
$arguments = [string[]]@()
if ($ComposerFixtureDirectory) {
    $arguments = [string[]]@((Resolve-Path -LiteralPath $ComposerFixtureDirectory).Path)
}
if ([Environment]::OSVersion.Platform -eq [PlatformID]::Win32NT) {
    $compiler = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'Windows .NET Framework compiler is required' }
    if (-not $OutputDirectory) { $OutputDirectory = Join-Path ([IO.Path]::GetTempPath()) ('HoneyProviderGeoTests-' + [Guid]::NewGuid().ToString('N')) }
    New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
    $output = (Resolve-Path -LiteralPath $OutputDirectory).Path
    $fixture = Join-Path $output 'ProviderGeoRuleSetTests.exe'
    & $compiler /nologo /target:exe /platform:x64 /langversion:5 /warnaserror+ /main:ProviderGeoRuleSetTests /reference:System.Web.Extensions.dll "/out:$fixture" $sources
    if ($LASTEXITCODE -ne 0) { throw 'Windows provider geo fixture C#5 compilation failed' }
    & $fixture @arguments
    if ($LASTEXITCODE -ne 0) { throw 'Windows provider geo typed-inline fixture failed' }
} else {
    $compatibility = Join-Path $PSScriptRoot 'ProviderGeoSerializerCompatibility.cs'
    # Only schema/CIDR/regex fixtures run here. Windows-native serializer and
    # Windows process/ACL/service guards require their existing native checks.
    Add-Type -Path (@($sources) + @($compatibility)) -CompilerOptions @('/langversion:5', '/warnaserror+')
    $exitCode = [ProviderGeoRuleSetTests]::Main($arguments)
    if ($exitCode -ne 0) { throw 'Local provider geo typed-inline fixture failed' }
    Write-Output 'PASS local C#5 fixtures; test-only serializer adapter used, no Windows kernel/API checks claimed'
}
