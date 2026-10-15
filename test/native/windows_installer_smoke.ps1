param([Parameter(Mandatory=$true)][string]$Setup,
      [Parameter(Mandatory=$true)][string]$Version,
      [Parameter(Mandatory=$true)][string]$OutputDirectory)
$ErrorActionPreference = 'Stop'

# This fixture really installs our service. It is restricted to a fresh,
# disposable Windows Actions machine and never starts the UI or a VPN tunnel.
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_OS -ne 'Windows' -or
    -not [Environment]::Is64BitProcess -or
    -not ([Security.Principal.WindowsPrincipal]::new(
        [Security.Principal.WindowsIdentity]::GetCurrent())).IsInRole(
            [Security.Principal.WindowsBuiltInRole]::Administrator)) {
    throw 'Actual Setup smoke requires an elevated x64 disposable Windows Actions machine'
}
$repositoryRoot = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '../..')).Path
$setupPath = (Resolve-Path -LiteralPath $Setup).Path
$releaseDirectory = Join-Path $repositoryRoot 'build/windows/x64/runner/Release'
$installedDirectory = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::ProgramFiles)) 'HoneyProxyUtility'
$legacyDirectory = Join-Path ([Environment]::GetFolderPath(
    [Environment+SpecialFolder]::ProgramFilesX86)) 'HoneyProxyUtility'
$serviceName = 'HoneyVpnTunnelService'
$serviceRegistry = 'Software\HoneyVPN\HoneyProxyUtility\WindowsTunnel'
$uninstallRegistry = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\HoneyProxyUtility_is1'
$baselineCommit = '7e9c5811a7847d2684c744feebd5dc6a49477e5c'
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$proofDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path

function Assert-Smoke([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Read-MachineValue([string]$Subkey, [string]$Name,
    [Microsoft.Win32.RegistryView]$View = [Microsoft.Win32.RegistryView]::Registry64) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    try {
        $key = $base.OpenSubKey($Subkey)
        if ($null -eq $key) { return $null }
        try { return $key.GetValue($Name) } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}
function Test-MachineKey([string]$Subkey,
    [Microsoft.Win32.RegistryView]$View = [Microsoft.Win32.RegistryView]::Registry64) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $View)
    try {
        $key = $base.OpenSubKey($Subkey)
        if ($null -eq $key) { return $false }
        try { return $true } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}
function Read-Service {
    return @(Get-CimInstance Win32_Service -Filter "Name='$serviceName'" -ErrorAction Stop)
}
function Invoke-SetupProcess([string]$Executable, [string]$Phase) {
    $log = Join-Path $proofDirectory ($Phase + '.log')
    $arguments = '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART /SP- /LOG="' + $log + '"'
    $child = Start-Process -FilePath $Executable -ArgumentList $arguments -WorkingDirectory $env:WINDIR -PassThru
    try {
        $retainedHandle = $child.Handle
        if (-not $child.WaitForExit(180000)) {
            # Kill only this retained fixture child, never processes by name/PID.
            $child.Kill()
            $child.WaitForExit(10000) | Out-Null
            throw ('Actual Setup smoke timed out at ' + $Phase)
        }
        $result = $child.ExitCode
        Write-Host ('HNSM phase=' + $Phase + ' exit=' + $result)
        return $result
    } finally { $child.Dispose() }
}
function Wait-Uninstalled {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        if (-not (Test-Path -LiteralPath $installedDirectory) -and
            @(Read-Service).Count -eq 0) { return }
        Start-Sleep -Milliseconds 200
    } while ($clock.ElapsedMilliseconds -lt 30000)
    throw 'Actual uninstall did not remove its installation directory and service'
}
function Read-GitSource([string]$Path) {
    $info = [Diagnostics.ProcessStartInfo]::new()
    $info.FileName = (Get-Command git.exe -ErrorAction Stop).Source
    $info.Arguments = 'show ' + $baselineCommit + ':' + $Path
    $info.WorkingDirectory = $repositoryRoot
    $info.UseShellExecute = $false
    $info.RedirectStandardOutput = $true
    $info.RedirectStandardError = $true
    $info.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    $child = [Diagnostics.Process]::Start($info)
    try {
        $text = $child.StandardOutput.ReadToEnd()
        $errorText = $child.StandardError.ReadToEnd()
        $child.WaitForExit()
        Assert-Smoke ($child.ExitCode -eq 0 -and $errorText.Length -eq 0) 'Immutable125 baseline source is unavailable'
        return $text
    } finally { $child.Dispose() }
}

# Read the real desktop identity. A headless runner is an explicit failure, not
# a skipped test or an excuse to configure the installer account as the owner.
$identitySource = Join-Path $repositoryRoot 'windows/service/DesktopUserIdentity.cs'
Assert-Smoke (Test-Path -LiteralPath $identitySource -PathType Leaf) 'Shared desktop identity source is missing'
if ($null -eq ('DesktopUserIdentity' -as [type])) { Add-Type -LiteralPath $identitySource }
try {
    $originalOwner = [DesktopUserIdentity]::ReadOwnerSid()
    $originalRoaming = [DesktopUserIdentity]::ReadRoamingPath()
} catch { throw 'Actual Setup smoke requires a real interactive desktop shell; no owner fallback is permitted' }
Assert-Smoke (-not [string]::IsNullOrWhiteSpace($originalOwner) -and
    -not [string]::IsNullOrWhiteSpace($originalRoaming)) 'Desktop shell identity/profile is unavailable'
Assert-Smoke (-not (Test-Path -LiteralPath $installedDirectory) -and
    -not (Test-Path -LiteralPath $legacyDirectory) -and @(Read-Service).Count -eq 0 -and
    -not (Test-MachineKey $uninstallRegistry) -and
    -not (Test-MachineKey $uninstallRegistry ([Microsoft.Win32.RegistryView]::Registry32))) `
    'Actual Setup smoke refuses an existing or foreign Honey installation'
Assert-Smoke ($null -eq (Read-MachineValue 'Software\Classes\honeyvpn' 'URL Protocol')) `
    'Actual Setup smoke refuses an existing machine protocol registration'
Assert-Smoke (-not (Test-Path 'HKCU:\Software\Classes\honeyvpn')) `
    'Actual Setup smoke refuses a user protocol override'
Write-Host 'PASS real desktop-shell context; fresh machine preconditions (no SMAA/Win11 claim)'

. (Join-Path $repositoryRoot 'scripts/secure_windows_installation.ps1')
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
public static class HoneyInstallerManifestFixture {
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr LoadLibraryEx(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll", CharSet=CharSet.Unicode, SetLastError=true)] private static extern IntPtr FindResource(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll", SetLastError=true)] private static extern IntPtr LoadResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern uint SizeofResource(IntPtr module, IntPtr resource);
    [DllImport("kernel32.dll")] private static extern IntPtr LockResource(IntPtr resource);
    [DllImport("kernel32.dll")] private static extern bool FreeLibrary(IntPtr module);
    public static byte[] Read(string path) {
        IntPtr module = LoadLibraryEx(path, IntPtr.Zero, 0x22);
        if (module == IntPtr.Zero) throw new InvalidOperationException("manifest-unavailable");
        try {
            IntPtr resource = FindResource(module, new IntPtr(1), new IntPtr(24));
            uint size = resource == IntPtr.Zero ? 0 : SizeofResource(module, resource);
            if (size == 0 || size > 65536) throw new InvalidOperationException("manifest-unavailable");
            IntPtr data = LockResource(LoadResource(module, resource));
            if (data == IntPtr.Zero) throw new InvalidOperationException("manifest-unavailable");
            byte[] bytes = new byte[size]; Marshal.Copy(data, bytes, 0, bytes.Length);
            // XML resources may include a BOM or an explicit encoding. Let the
            // XML reader consume the original bytes instead of decoding first.
            return bytes;
        } finally { FreeLibrary(module); }
    }
}
'@

$markerNonce = [Guid]::NewGuid().ToString('N')
$supportDirectory = Join-Path $originalRoaming 'ru.honeyvpn\HoneyProxyUtility'
$profileMarker = Join-Path $supportDirectory ('installer-smoke-' + $markerNonce + '.txt')
$unrelatedMarker = Join-Path $originalRoaming ('honey-unrelated-' + $markerNonce + '.txt')
$markerValue = 'synthetic-preserved-' + $markerNonce
$legacyRegistryView = [Microsoft.Win32.RegistryView]::Registry32
$legacyMarker = Join-Path $legacyDirectory ('installer-smoke-' + $markerNonce + '.txt')
$legacyUninstallCommand = '"' + (Join-Path $legacyDirectory 'unins000.exe') + '"'
$script:legacyFixtureSnapshot = $null
$profileDirectoryExisted = Test-Path -LiteralPath $supportDirectory
New-Item -ItemType Directory -Force -Path $supportDirectory | Out-Null
[IO.File]::WriteAllText($profileMarker, $markerValue)
[IO.File]::WriteAllText($unrelatedMarker, $markerValue)

function New-LegacyRegistryFixture([string]$FixturePublisher, [string]$FixtureCommand) {
    Assert-Smoke (-not (Test-MachineKey $uninstallRegistry $legacyRegistryView)) `
        'Legacy fixture refuses to replace an existing registration'
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $legacyRegistryView)
    try {
        $acl = [Security.AccessControl.RegistrySecurity]::new()
        $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
        $acl.SetAccessRuleProtection($true, $false)
        foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
            $rights = if ($sid -eq 'S-1-5-32-545') { [Security.AccessControl.RegistryRights]::ReadKey }
                else { [Security.AccessControl.RegistryRights]::FullControl }
            $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid), $rights,
                [Security.AccessControl.InheritanceFlags]::None,
                [Security.AccessControl.PropagationFlags]::None,
                [Security.AccessControl.AccessControlType]::Allow))
        }
        $key = $base.CreateSubKey($uninstallRegistry,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Microsoft.Win32.RegistryOptions]::None, $acl)
        try {
            $key.SetValue('InstallLocation', $legacyDirectory, [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue('Publisher', $FixturePublisher, [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue('UninstallString', $FixtureCommand, [Microsoft.Win32.RegistryValueKind]::String)
            $key.SetValue('HoneySmokeFixtureNonce', $markerNonce, [Microsoft.Win32.RegistryValueKind]::String)
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
    $script:legacyFixtureSnapshot = Read-LegacyFixtureSnapshot
}
function Read-LegacyFixtureSnapshot {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $legacyRegistryView)
    try {
        $key = $base.OpenSubKey($uninstallRegistry)
        if ($null -eq $key) { return $null }
        try {
            $sections = [Security.AccessControl.AccessControlSections]::Access -bor
                [Security.AccessControl.AccessControlSections]::Owner -bor
                [Security.AccessControl.AccessControlSections]::Group
            $values = @($key.GetValueNames() | Sort-Object | ForEach-Object {
                [ordered]@{ Name = $_; Kind = [int]$key.GetValueKind($_);
                   Value = $key.GetValue($_, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames) }
            })
            return ([ordered]@{ Values = $values; Children = @($key.GetSubKeyNames() | Sort-Object);
                Sddl = $key.GetAccessControl().GetSecurityDescriptorSddlForm($sections) } | ConvertTo-Json -Depth 6 -Compress)
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}
function Remove-LegacyRegistryFixture {
    if (-not (Test-MachineKey $uninstallRegistry $legacyRegistryView)) { return }
    Assert-Smoke ((Read-MachineValue $uninstallRegistry 'HoneySmokeFixtureNonce' $legacyRegistryView) -ceq $markerNonce) `
        'Legacy fixture cleanup refuses a registration not owned by this run'
    Assert-Smoke ($null -ne $script:legacyFixtureSnapshot -and
        (Read-LegacyFixtureSnapshot) -ceq $script:legacyFixtureSnapshot) `
        'Legacy fixture cleanup refuses changed typed metadata, permissions or children'
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $legacyRegistryView)
    try { $base.DeleteSubKey($uninstallRegistry, $false) } finally { $base.Dispose() }
    $script:legacyFixtureSnapshot = $null
}
function New-LegacyChildFixture {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $legacyRegistryView)
    try {
        $key = $base.OpenSubKey($uninstallRegistry, $true)
        try {
            $child = $key.CreateSubKey('smoke-child-' + $markerNonce)
            try { $child.SetValue('HoneySmokeFixtureNonce', $markerNonce, [Microsoft.Win32.RegistryValueKind]::String) }
            finally { $child.Dispose() }
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
    $script:legacyFixtureSnapshot = Read-LegacyFixtureSnapshot
}
function Remove-LegacyChildFixture {
    Assert-Smoke ((Read-LegacyFixtureSnapshot) -ceq $script:legacyFixtureSnapshot) `
        'Child fixture cleanup refuses changed parent metadata, ACL or child names'
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey(
        [Microsoft.Win32.RegistryHive]::LocalMachine, $legacyRegistryView)
    try {
        $key = $base.OpenSubKey($uninstallRegistry, $true)
        try {
            $child = $key.OpenSubKey('smoke-child-' + $markerNonce)
            Assert-Smoke ($null -ne $child) 'Owned child fixture is missing'
            try {
                Assert-Smoke ($child.SubKeyCount -eq 0 -and $child.ValueCount -eq 1 -and
                    $child.GetValueKind('HoneySmokeFixtureNonce') -eq [Microsoft.Win32.RegistryValueKind]::String -and
                    $child.GetValue('HoneySmokeFixtureNonce') -ceq $markerNonce) `
                    'Child fixture cleanup refuses foreign values or descendants'
            } finally { $child.Dispose() }
            $key.DeleteSubKey('smoke-child-' + $markerNonce, $true)
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
    $script:legacyFixtureSnapshot = Read-LegacyFixtureSnapshot
}
function Clear-FixturePreflightDirectory {
    if (-not (Test-Path -LiteralPath $installedDirectory)) { return }
    Assert-PlainInstallationPath $installedDirectory
    Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $installedDirectory)
    Assert-Smoke ([IO.Directory]::GetFileSystemEntries($installedDirectory).Length -eq 0) `
        'Rejected preflight unexpectedly copied files; fixture will not delete them'
    [IO.Directory]::Delete($installedDirectory, $false)
}
function Assert-RejectedLegacyFixture([string]$Phase, [string]$FixturePublisher, [string]$FixtureCommand, [int]$ExpectedGuardCode) {
    Assert-Smoke ((Invoke-SetupProcess $setupPath $Phase) -eq 7) `
        'Untrusted or nonempty legacy state must reject Setup before installation'
    $rejectionLog = [IO.File]::ReadAllText((Join-Path $proofDirectory ($Phase + '.log')))
    Assert-Smoke ($rejectionLog -match ('HoneyVPN guard phase=legacy-migration HNG-' + $ExpectedGuardCode + '\b')) `
        'Rejected Setup did not reach the expected guarded legacy boundary'
    Assert-Smoke ((Read-MachineValue $uninstallRegistry 'HoneySmokeFixtureNonce' $legacyRegistryView) -ceq $markerNonce -and
        (Read-MachineValue $uninstallRegistry 'InstallLocation' $legacyRegistryView) -ceq $legacyDirectory -and
        (Read-MachineValue $uninstallRegistry 'Publisher' $legacyRegistryView) -ceq $FixturePublisher -and
        (Read-MachineValue $uninstallRegistry 'UninstallString' $legacyRegistryView) -ceq $FixtureCommand) `
        'Rejected legacy registration must remain unchanged'
    Assert-Smoke ((Read-LegacyFixtureSnapshot) -ceq $script:legacyFixtureSnapshot) `
        'Rejected legacy registration changed typed values, permissions or child keys'
    Assert-Smoke (@(Read-Service).Count -eq 0 -and
        -not (Test-MachineKey $uninstallRegistry) -and
        $null -eq (Read-MachineValue 'Software\Classes\honeyvpn' 'URL Protocol')) `
        'Rejected legacy preflight installed a service or current registration'
    Assert-Markers
    Clear-FixturePreflightDirectory
    Write-Host ('PASS actualSetup ' + $Phase + ': rejected/legacyRegistrationPreserved/noService/noFiles')
}
function Remove-LegacyDirectoryFixture {
    if (-not (Test-Path -LiteralPath $legacyDirectory)) { return }
    Assert-PlainInstallationPath $legacyDirectory
    Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $legacyDirectory)
    Assert-Smoke ((Test-Path -LiteralPath $legacyMarker -PathType Leaf) -and
        [IO.File]::ReadAllText($legacyMarker) -ceq $markerValue -and
        [IO.Directory]::GetFileSystemEntries($legacyDirectory).Length -eq 1) `
        'Legacy fixture cleanup refuses unknown or changed files'
    [IO.File]::Delete($legacyMarker)
    [IO.Directory]::Delete($legacyDirectory, $false)
}

function Assert-Markers {
    foreach ($file in @($profileMarker, $unrelatedMarker)) {
        Assert-Smoke ((Test-Path -LiteralPath $file -PathType Leaf) -and
            [IO.File]::ReadAllText($file) -ceq $markerValue) 'Installer changed a saved profile or unrelated marker'
    }
}
function Assert-Installed([string]$Phase) {
    # Function output is enumerated even when Read-Service returns @(...).
    # Collect here; scalar Count is not reliable under Windows PowerShell 5.1.
    $service = @(Read-Service)
    $scmState = 'unavailable'
    $localSystem = $false
    if ($service.Count -eq 1) {
        $scmState = switch -Exact ([string]$service[0].State) {
            'Stopped' { 'stopped' }
            'Start Pending' { 'start-pending' }
            'Stop Pending' { 'stop-pending' }
            'Running' { 'running' }
            'Continue Pending' { 'continue-pending' }
            'Pause Pending' { 'pause-pending' }
            'Paused' { 'paused' }
            'Unknown' { 'unknown' }
            default { 'unrecognized' }
        }
        $localSystem = $service[0].StartName -eq 'LocalSystem'
    }
    # These fixed enums/booleans never reveal a username, SID or image path.
    Write-Host ('HNSM phase=' + $Phase + ' service-count=' + $service.Count +
        ' scm-state=' + $scmState + ' local-system=' + $localSystem.ToString().ToLowerInvariant())
    Assert-Smoke ($service.Count -eq 1 -and $service[0].State -eq 'Running' -and
        $service[0].StartName -eq 'LocalSystem') 'Installed TUN service is not running as LocalSystem'
    $expectedService = '"' + (Join-Path $installedDirectory 'HoneyVpnService.exe') + '" --service'
    Assert-Smoke ($service[0].PathName -ceq $expectedService) 'Installed service executable/arguments differ from the fixed installation'
    Assert-Smoke ((Read-MachineValue $serviceRegistry 'OwnerSid') -ceq $originalOwner) `
        'Installed service owner differs from the original desktop shell'
    $serviceClientFixture = Join-Path $repositoryRoot `
        'build/windows-service-client-tests/Release/windows_service_client_test.exe'
    Assert-Smoke (Test-Path -LiteralPath $serviceClientFixture -PathType Leaf) `
        'Compiled installed-service ordinary-client regression is required'
    $serviceClientProof = @(& $serviceClientFixture --installed-readactive-medium (Join-Path $installedDirectory 'HoneyVpnService.exe'))
    $serviceClientExit = $LASTEXITCODE
    $serviceClientProof | ForEach-Object { Write-Host $_ }
    Assert-Smoke ($serviceClientExit -eq 0 -and
        @($serviceClientProof | Where-Object { $_ -cmatch '^HNSP mode=assert-idle effectiveMedium=1 effectiveAdmin=0 sameOwner=1 .* stage=replyReceived .* replyPresent=1 readActiveNull=1 error=none$' }).Count -eq 1 -and
        @($serviceClientProof | Where-Object { $_ -ceq 'PASS installed LocalSystem service authenticated readActive under effective medium owner token' }).Count -eq 1) `
        'Installed service cannot authenticate the effective medium owner readActive client'
    $expectedProtocol = '"' + (Join-Path $installedDirectory 'HoneyProxyUtility.exe') + '" --import-link "%1"'
    Assert-Smoke ((Read-MachineValue 'Software\Classes\honeyvpn\shell\open\command' '') -ceq $expectedProtocol -and
        (Read-MachineValue 'Software\Classes\honeyvpn' 'URL Protocol') -ceq '') `
        'Honey protocol registration does not target the fixed UI with one quoted URI'
    Assert-PlainInstallationPath $installedDirectory
    foreach ($item in @((Get-Item -LiteralPath $installedDirectory)) + @(Get-ChildItem -LiteralPath $installedDirectory -Force -Recurse)) {
        Assert-PlainInstallationPath $item.FullName
        Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $item.FullName)
    }
    $manifestBytes = [HoneyInstallerManifestFixture]::Read((Join-Path $installedDirectory 'HoneyProxyUtility.exe'))
    $manifestStream = [IO.MemoryStream]::new([byte[]]$manifestBytes, $false)
    $xmlSettings = [Xml.XmlReaderSettings]::new()
    $xmlSettings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $xmlSettings.XmlResolver = $null
    $manifestReader = $null
    try {
        $manifestReader = [Xml.XmlReader]::Create($manifestStream, $xmlSettings)
        $manifest = [Xml.XmlDocument]::new()
        $manifest.XmlResolver = $null
        $manifest.Load($manifestReader)
    } finally {
        if ($null -ne $manifestReader) { $manifestReader.Dispose() }
        $manifestStream.Dispose()
    }
    $execution = $manifest.SelectSingleNode("//*[local-name()='requestedExecutionLevel']")
    Assert-Smoke ($null -ne $execution -and $execution.GetAttribute('level') -ceq 'asInvoker' -and
        $execution.GetAttribute('uiAccess') -ceq 'false') 'Installed UI manifest must remain asInvoker without uiAccess'
    foreach ($leaf in @('DesktopUserIdentity.cs', 'secure_windows_installation.ps1')) {
        $source = if ($leaf -eq 'DesktopUserIdentity.cs') { $identitySource }
            else { Join-Path $repositoryRoot 'scripts/secure_windows_installation.ps1' }
        Assert-Smoke ((Get-FileHash -Algorithm SHA256 -LiteralPath (Join-Path $installedDirectory $leaf)).Hash -ceq
            (Get-FileHash -Algorithm SHA256 -LiteralPath $source).Hash) 'Installed identity/guard source differs from reviewed source'
    }
    Assert-Markers
    Write-Host ('PASS actualSetup ' + $Phase + ': serviceRunning/originalOwner/protocol/ProgramFilesACL/asInvoker/profilePreservation/mediumClientReadActive')
}
function Assert-Uninstalled([string]$Phase) {
    Wait-Uninstalled
    Assert-Smoke ($null -eq (Read-MachineValue 'Software\Classes\honeyvpn' 'URL Protocol') -and
        $null -eq (Read-MachineValue $uninstallRegistry 'InstallLocation')) 'Actual uninstall retained its protocol/installation registration'
    Assert-Markers
    Write-Host ('PASS actualSetup ' + $Phase + ': ownInstallationRemoved/profileAndUnrelatedMarkerPreserved')
}
function Assert-OwnedOrphanDisposition([string]$Phase, [bool]$Preserved) {
    $log = [IO.File]::ReadAllText((Join-Path $proofDirectory ($Phase + '.log')))
    if ($Preserved) {
        Assert-Smoke ($log -match 'HoneyVPN guard phase=legacy-migration HNG-39\b' -and
            $log -match 'preserved-unsafe-metadata no-uninstaller-launch') `
            'Unsafe orphan must have an explicit preserved disposition before any uninstaller branch'
        Assert-Smoke ((Read-LegacyFixtureSnapshot) -ceq $script:legacyFixtureSnapshot) `
            'Unsafe orphan typed metadata, ACLs and children must remain unchanged'
    } else {
        Assert-Smoke (-not (Test-MachineKey $uninstallRegistry $legacyRegistryView)) `
            'Trusted orphan migration must remove only the old32 registration'
    }
    Assert-Smoke (-not (Test-Path -LiteralPath $legacyDirectory)) `
        'Orphan handling must not create or execute a legacy file tree'
}

$baselineRoot = Join-Path $proofDirectory 'baseline125'
$baselineRelease = Join-Path $baselineRoot 'build/windows/x64/runner/Release'
try {
    # The historical guard and installer are read from the immutable commit.
    # Only a fixture wrapper is added: it calls the original preflight, records
    # its result and always returns a PreparingToInstall error (exit7). No125
    # files, service or registry entries are ever installed.
    New-Item -ItemType Directory -Force -Path (Join-Path $baselineRoot 'windows'), (Join-Path $baselineRoot 'scripts'),
        (Split-Path -Parent $baselineRelease) | Out-Null
    $baselineInstaller = Read-GitSource 'windows/installer.iss'
    $baselineGuard = Read-GitSource 'scripts/secure_windows_installation.ps1'
    $signature = 'function PrepareToInstall(var NeedsRestart: Boolean): String;'
    Assert-Smoke ([regex]::Matches($baselineInstaller, [regex]::Escape($signature)).Count -eq 1) `
        'Baseline125 preflight hook must be unique'
    $baselineInstaller = $baselineInstaller.Replace($signature, 'function FixtureOriginalPrepareToInstall(var NeedsRestart: Boolean): String;')
    $baselineInstaller += @'

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := FixtureOriginalPrepareToInstall(NeedsRestart);
  if Result = '' then Log('HONEY baseline125 preflight=pass')
  else Log('HONEY baseline125 preflight=fail');
  if Result = '' then Result := 'HONEY baseline125 preflight-only completed';
end;
'@
    $baselineScript = Join-Path $baselineRoot 'windows/installer.iss'
    [IO.File]::WriteAllText($baselineScript, $baselineInstaller, [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $baselineRoot 'scripts/secure_windows_installation.ps1'), $baselineGuard, [Text.UTF8Encoding]::new($false))
    New-Item -ItemType Junction -Path $baselineRelease -Target $releaseDirectory | Out-Null
    & iscc.exe $baselineScript ('/DAppVer=' + $Version) ('/O' + $proofDirectory) '/FHoney125-PreflightOnly' 2>&1 |
        Out-File -LiteralPath (Join-Path $proofDirectory 'baseline125-compile.log') -Encoding utf8
    Assert-Smoke ($LASTEXITCODE -eq 0) 'Immutable125 preflight-only installer compilation failed'
    Assert-Smoke ((Invoke-SetupProcess (Join-Path $proofDirectory 'Honey125-PreflightOnly.exe') 'baseline125-preflight') -eq 7) `
        'Baseline125 fixture must stop at PreparingToInstall before copying files'
    $baselineLog = [IO.File]::ReadAllText((Join-Path $proofDirectory 'baseline125-preflight.log'))
    Assert-Smoke ($baselineLog -match 'HONEY baseline125 preflight=(pass|fail)') 'Baseline125 original preflight did not run'
    Assert-Smoke (@(Read-Service).Count -eq 0 -and
        $null -eq (Read-MachineValue $uninstallRegistry 'InstallLocation') -and
        $null -eq (Read-MachineValue 'Software\Classes\honeyvpn' 'URL Protocol')) `
        'Preflight-only baseline must not install a service or registration'
    if (Test-Path -LiteralPath $installedDirectory) {
        Assert-PlainInstallationPath $installedDirectory
        Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $installedDirectory)
        Assert-Smoke ([IO.Directory]::GetFileSystemEntries($installedDirectory).Length -eq 0) `
            'Preflight-only baseline copied application files'
        [IO.Directory]::Delete($installedDirectory, $false)
    }
    $baselineResult = if ($baselineLog -match 'HONEY baseline125 preflight=pass') { 'pass' } else { 'fail' }
    Write-Host ('PASS immutable125 originalPreflight=' + $baselineResult + '; preflightOnly/noService/noCopiedFiles (not Win11AdminProtection reproduction)')

    # Exercise the real Setup, not just guard functions. A foreign registration
    # must remain intact even when its directory and uninstaller are absent.
    New-LegacyRegistryFixture 'OtherFixturePublisher' $legacyUninstallCommand
    Assert-RejectedLegacyFixture 'orphan32-foreign-publisher' 'OtherFixturePublisher' $legacyUninstallCommand 31
    Remove-LegacyRegistryFixture
    $invalidLegacyCommand = $legacyUninstallCommand + ' /fixture-invalid'
    New-LegacyRegistryFixture 'HoneyVPN' $invalidLegacyCommand
    Assert-RejectedLegacyFixture 'orphan32-foreign-command' 'HoneyVPN' $invalidLegacyCommand 32
    Remove-LegacyRegistryFixture

    # A protected nonempty tree with no uninstaller is not an orphan that may
    # be discarded. Only this fixture removes its one known marker afterward.
    [IO.Directory]::CreateDirectory($legacyDirectory, (New-ProtectedInstallationAcl $true)) | Out-Null
    [IO.File]::WriteAllText($legacyMarker, $markerValue)
    Set-ProtectedInstallationAcl (Get-Item -LiteralPath $legacyMarker)
    New-LegacyRegistryFixture 'HoneyVPN' $legacyUninstallCommand
    Assert-RejectedLegacyFixture 'orphan32-protected-nonempty' 'HoneyVPN' $legacyUninstallCommand 33
    Assert-Smoke ((Test-Path -LiteralPath $legacyMarker -PathType Leaf) -and
        [IO.File]::ReadAllText($legacyMarker) -ceq $markerValue) `
        'Rejected nonempty legacy tree must preserve its file'
    Remove-LegacyRegistryFixture
    Remove-LegacyDirectoryFixture

    # Child keys remain a hard rejection even when an ancestor's ACL would
    # otherwise produce the optional unsafe-orphan preservation disposition.
    New-LegacyRegistryFixture 'HoneyVPN' $legacyUninstallCommand
    New-LegacyChildFixture
    try {
        Assert-RejectedLegacyFixture 'orphan32-child-key' 'HoneyVPN' $legacyUninstallCommand 38
    } finally { Remove-LegacyChildFixture }
    Remove-LegacyRegistryFixture

    # The device-reported HNG33 case: our exact HKLM32 registration remains,
    # but the canonical legacy directory/exe/dat do not exist. A trusted key
    # may be retired; an unsafe namespace is preserved without repair/deletion
    # or executable fallback. Both paths must install the current64 service.
    New-LegacyRegistryFixture 'HoneyVPN' $legacyUninstallCommand
    Assert-Smoke (-not (Test-Path -LiteralPath $legacyDirectory) -and
        -not (Test-Path -LiteralPath (Join-Path $legacyDirectory 'unins000.exe')) -and
        -not (Test-Path -LiteralPath (Join-Path $legacyDirectory 'unins000.dat'))) `
        'Owned orphan fixture must have no legacy directory or uninstaller'
    $orphanDisposition = Assert-TrustedLegacyRegistration $legacyDirectory $true
    Assert-Smoke ($orphanDisposition.Disposition -cin @('RetireOrphan', 'PreserveUnsafeOrphan')) `
        'Missing legacy files must produce an explicit orphan disposition'
    $preservedOrphan = $orphanDisposition.Disposition -ceq 'PreserveUnsafeOrphan'
    Assert-Smoke ((Invoke-SetupProcess $setupPath 'candidate-fresh-install') -eq 0) 'Actual candidate fresh installation failed'
    Assert-Installed 'fresh'
    Assert-OwnedOrphanDisposition 'candidate-fresh-install' $preservedOrphan
    Write-Host ('PASS actualSetup orphan32 missing-directory recovery: freshSuccess/oldMetadataPreserved=' +
        $preservedOrphan.ToString().ToLowerInvariant() + '/noLegacyTree/noLegacyExecutable')
    Assert-Smoke ((Invoke-SetupProcess $setupPath 'candidate-update') -eq 0) 'Actual candidate update failed'
    Assert-Installed 'update'
    if ($preservedOrphan) { Assert-OwnedOrphanDisposition 'candidate-update' $true }
    Assert-Smoke ((Invoke-SetupProcess (Join-Path $installedDirectory 'unins000.exe') 'candidate-uninstall') -eq 0) 'Actual candidate uninstall failed'
    Assert-Uninstalled 'uninstall'
    Assert-Smoke ((Invoke-SetupProcess $setupPath 'candidate-reinstall') -eq 0) 'Actual candidate reinstall after uninstall failed'
    Assert-Installed 'reinstall'
    if ($preservedOrphan) { Assert-OwnedOrphanDisposition 'candidate-reinstall' $true }
    Assert-Smoke ((Invoke-SetupProcess (Join-Path $installedDirectory 'unins000.exe') 'candidate-final-uninstall') -eq 0) 'Actual candidate final uninstall failed'
    Assert-Uninstalled 'final-uninstall'
    Write-Host 'PASS actualSetup fresh/update/uninstall/reinstall gate; no UI/VPN/TUN/route/network traffic was started'
} finally {
    Remove-LegacyRegistryFixture
    Remove-LegacyDirectoryFixture
    if (Test-Path -LiteralPath $baselineRelease) {
        Assert-Smoke (([IO.File]::GetAttributes($baselineRelease) -band [IO.FileAttributes]::ReparsePoint) -ne 0) `
            'Baseline fixture cleanup refuses an ordinary directory'
        [IO.Directory]::Delete($baselineRelease, $false)
    }
    foreach ($file in @($profileMarker, $unrelatedMarker)) {
        if (Test-Path -LiteralPath $file) {
            Assert-Smoke ([IO.File]::ReadAllText($file) -ceq $markerValue) 'Fixture marker changed; preserve it for diagnosis'
            [IO.File]::Delete($file)
        }
    }
    if (-not $profileDirectoryExisted -and (Test-Path -LiteralPath $supportDirectory) -and
        [IO.Directory]::GetFileSystemEntries($supportDirectory).Length -eq 0) {
        [IO.Directory]::Delete($supportDirectory, $false)
    }
}
