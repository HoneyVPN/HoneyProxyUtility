param(
    [Parameter(Mandatory=$true)][string]$SourceDirectory,
    [Parameter(Mandatory=$true)][string]$OutputDirectory
)
$ErrorActionPreference = 'Stop'
$compiler = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) { throw 'Windows .NET Framework x64 compiler is missing' }
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$output = Join-Path $OutputDirectory 'HoneyVpnService.exe'
$sources = @(
    (Join-Path $SourceDirectory 'HoneyVpnService.cs'),
    (Join-Path $SourceDirectory 'SafeTunConfiguration.cs'),
    (Join-Path $SourceDirectory 'ProviderGeoRuleSetValidator.cs'),
    (Join-Path $SourceDirectory 'KernelEpoch.cs'),
    (Join-Path $SourceDirectory 'DesktopUserIdentity.cs')
)
foreach ($source in $sources) {
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Windows service source is missing' }
}
& $compiler /nologo /target:exe /platform:x64 /optimize+ "/out:$output" `
    /reference:System.dll /reference:System.Core.dll /reference:System.ServiceProcess.dll `
    /reference:System.Web.Extensions.dll /reference:System.Security.dll $sources
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath $output -PathType Leaf)) {
    throw 'Windows VPN service compilation failed'
}
