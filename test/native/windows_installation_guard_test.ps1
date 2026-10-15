$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../scripts/secure_windows_installation.ps1')
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message } }
function Assert-Throws([scriptblock]$Action, [string]$Message, [int]$ExpectedGuardCode = 0) {
    $thrown = $false
    try { & $Action | Out-Null } catch {
        $thrown = $true
        if ($ExpectedGuardCode -ne 0) {
            Assert-True ((Get-InstallationGuardExitCode $_.Exception.Message 'application-state') -eq $ExpectedGuardCode) 'Process classification must preserve the specific safe guard code'
        }
    }
    Assert-True $thrown $Message
}
function New-FixtureAcl([string]$Owner, [bool]$UsersWrite) {
    $acl = [Security.AccessControl.DirectorySecurity]::new()
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner))
    $acl.SetAccessRuleProtection($true, $false)
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'),
        [Security.AccessControl.FileSystemRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    $rights = if ($UsersWrite) { [Security.AccessControl.FileSystemRights]::Modify }
        else { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
    $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'), $rights,
        [Security.AccessControl.AccessControlType]::Allow))
    return $acl
}
function New-FixtureRegistryAcl([string]$Owner, [int]$UsersRights = 0x20019) {
    $acl = [Security.AccessControl.RegistrySecurity]::new()
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new($Owner))
    $acl.SetAccessRuleProtection($true, $false)
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544')) {
        $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid),
            [Security.AccessControl.RegistryRights]::FullControl, [Security.AccessControl.AccessControlType]::Allow))
    }
    $acl.AddAccessRule([Security.AccessControl.RegistryAccessRule]::new(
        [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
        [Security.AccessControl.RegistryRights]$UsersRights, [Security.AccessControl.AccessControlType]::Allow))
    return $acl
}
function New-FixtureNullDacl([bool]$Registry) {
    $acl = if ($Registry) { [Security.AccessControl.RegistrySecurity]::new() }
        else { [Security.AccessControl.DirectorySecurity]::new() }
    $raw = [Security.AccessControl.RawSecurityDescriptor]::new('O:BAG:BA')
    $bytes = [byte[]]::new($raw.BinaryLength)
    $raw.GetBinaryForm($bytes, 0)
    $acl.SetSecurityDescriptorBinaryForm($bytes)
    return $acl
}
foreach ($case in @(
    @{reason='unexpected-install-directory';stage='directory';expected=10},
    @{reason='unsafe-install-path';stage='directory';expected=11},
    @{reason='unsafe-install-owner';stage='directory';expected=12},
    @{reason='unsafe-install-write-access';stage='directory';expected=13},
    @{reason='close-installed-app';stage='application-state';expected=20},
    @{reason='installed-process-path-unavailable';stage='application-state';expected=24},
    @{reason='legacy-core-cleanup-unconfirmed';stage='application-state';expected=21},
    @{reason='legacy-cleanup-unconfirmed';stage='legacy-cleanup';expected=22},
    @{reason='unexpected-legacy-mode';stage='legacy-registration';expected=30},
    @{reason='untrusted-legacy-registration';stage='legacy-registration';expected=31},
    @{reason='untrusted-legacy-command';stage='legacy-registration';expected=32},
    @{reason='missing-legacy-uninstaller';stage='legacy-registration';expected=33},
    @{reason='changed-legacy-registration';stage='legacy-registration';expected=36},
    @{reason='unsafe-legacy-registry-access';stage='legacy-registration';expected=37},
    @{reason='legacy-registration-has-children';stage='legacy-registration';expected=38},
    @{reason='private native error with a user path';stage='directory';expected=14},
    @{reason='private native error with a user path';stage='application-state';expected=24},
    @{reason='private native error with a user path';stage='desktop-profile';expected=23},
    @{reason='private native error with a user path';stage='legacy-cleanup';expected=22},
    @{reason='private native error with a user path';stage='legacy-registration';expected=34},
    @{reason='private native error with a user path';stage='unknown';expected=2}
)) {
    Assert-True ((Get-InstallationGuardExitCode $case.reason $case.stage) -eq $case.expected) 'Guard failure must map to a fixed diagnostic code'
}
Write-Host 'PASS fixed guard diagnostics distinguish directory, process, desktop and cleanup stages'
$expected = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) 'HoneyProxyUtility'
Assert-True (-not (Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='System';ExecutablePath=$null;ProcessId=4}
) { throw 'Unrelated unknown processes must not be queried' })) 'Unknown system paths cannot block unrelated installation'
Assert-True (-not (Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='sing-box.exe';ExecutablePath='C:\OtherVpn\sing-box.exe';ProcessId=1}
) { throw 'Already readable paths must not be queried' })) 'Known foreign VPN processes cannot block Honey installation'
Assert-True (-not (Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='sing-box.exe';ExecutablePath=$null;ProcessId=123}
) { param($ProcessId) if ($ProcessId -ne 123) { throw 'Wrong candidate PID' }; 'C:\OtherVpn\sing-box.exe' })) 'Read-only resolution must preserve an unrelated VPN process'
Assert-Throws { Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='HoneyProxyUtility.exe';ExecutablePath=$null;ProcessId=123}
) { throw 'Access denied' } } 'Unreadable candidate cannot prove that Honey UI is closed' 24
Assert-Throws { Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='sing-box.exe';ExecutablePath=' ';ProcessId=123}
) { 'relative.exe' } } 'An unresolved candidate cannot prove that the owned core has exited' 24
Assert-Throws { Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='HoneyProxyUtility.exe';ExecutablePath=$null;ProcessId=123}
) { Join-Path $expected 'HoneyProxyUtility.exe' } } 'Resolved running Honey UI must block installation' 20
Assert-True (Test-InstallationCoreRunning $expected @(
    [pscustomobject]@{Name='sing-box.exe';ExecutablePath=$null;ProcessId=123}
) { Join-Path $expected 'sing-box.exe' }) 'Resolved owned core must wait for scoped cleanup'
Write-Host 'PASS process ownership classification resolves only named candidates and fails closed on unknown paths'
Assert-True (Test-ExpectedInstallationDirectory $expected) 'Canonical x64 Program Files directory must be accepted'
Assert-True (-not (Test-ExpectedInstallationDirectory ([IO.Path]::GetTempPath()))) 'Custom user-writable /DIR must be rejected'
# Dot-sourcing retains the production [switch]$Legacy parameter in this scope.
# Keep fixture paths distinct from every production entry-point parameter.
$legacyDirectory = Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFilesX86)) 'HoneyProxyUtility'
Assert-ExpectedLegacyRegistration $legacyDirectory $legacyDirectory ('"' + (Join-Path $legacyDirectory 'unins000.exe') + '"') 'HoneyVPN'
Assert-Throws { Assert-ExpectedLegacyRegistration $legacyDirectory $legacyDirectory 'C:\Windows\System32\cmd.exe /c anything' 'HoneyVPN' } 'Registry command cannot select an arbitrary executable'
Assert-Throws { Assert-ExpectedLegacyRegistration $legacyDirectory $legacyDirectory ('"' + (Join-Path $legacyDirectory 'unins000.exe') + '" /anything') 'HoneyVPN' } 'Unknown registry command arguments must be rejected'
Assert-Throws { Assert-ExpectedLegacyRegistration $legacyDirectory ([IO.Path]::GetTempPath()) ('"' + (Join-Path $legacyDirectory 'unins000.exe') + '"') 'HoneyVPN' } 'InstallLocation must bind the fixed legacy directory'
Assert-Throws { Assert-ExpectedLegacyRegistration $legacyDirectory $legacyDirectory ('"' + (Join-Path $legacyDirectory 'unins000.exe') + '"') 'OtherPublisher' } 'Foreign registration cannot be uninstalled'
Write-Host 'PASS fixed legacy registration/filename/publisher validation; arbitrary registry commands are rejected'
Assert-TrustedLegacyRegistryAcl (New-FixtureRegistryAcl 'S-1-5-32-544')
foreach ($rights in @(2, 4, 32, 65536, 262144, 524288)) {
    Assert-Throws { Assert-TrustedLegacyRegistryAcl (New-FixtureRegistryAcl 'S-1-5-32-544' $rights) } 'Registry value, child, link, deletion or security mutation by users must fail closed' 37
}
Assert-Throws { Assert-TrustedLegacyRegistryAcl (New-FixtureRegistryAcl 'S-1-5-21-1-2-3-1001') } 'Creator-owned registry metadata cannot be retired with administrator privileges' 37
Assert-Throws { Assert-TrustedLegacyRegistryAcl (New-FixtureNullDacl $true) } 'A NULL registry DACL grants mutation and cannot be trusted' 37
Write-Host 'PASS registry descriptors allow read access and reject every metadata mutation right, foreign owner and NULL DACL'
Assert-LegacyRegistryString 'HoneyVPN Россия 😀'
Assert-Throws { Assert-LegacyRegistryString ([string][char]0xD800) } 'Malformed UTF-16 cannot collide in a metadata fingerprint' 36
Assert-Throws { Assert-LegacyRegistryString ([string][char]0xFFFD) } 'Replacement-decoded registry bytes cannot prove exact metadata equality' 36
Assert-TrustedInstallationAcl (New-FixtureAcl 'S-1-5-32-544' $false)
Assert-Throws { Assert-TrustedInstallationAcl (New-FixtureAcl 'S-1-5-32-544' $true) } 'User-modifiable existing code must fail closed'
Assert-Throws { Assert-TrustedInstallationAcl (New-FixtureAcl 'S-1-5-21-1-2-3-1001' $false) } 'Unprivileged owner can alter DACL and must be rejected'
Assert-Throws { Assert-TrustedInstallationAcl (New-FixtureNullDacl $false) } 'A NULL directory DACL cannot prove a protected namespace'
$ancestor = New-FixtureAcl 'S-1-5-32-544' $false
$ancestor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
    [Security.AccessControl.FileSystemRights]::CreateDirectories,
    [Security.AccessControl.AccessControlType]::Allow))
Assert-TrustedInstallationAcl $ancestor $true
$ancestor.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
    [Security.Principal.SecurityIdentifier]::new('S-1-5-32-545'),
    [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles,
    [Security.AccessControl.AccessControlType]::Allow))
Assert-Throws { Assert-TrustedInstallationAcl $ancestor $true } 'A mutable ancestor cannot permit replacement of the installed subtree'
Write-Host 'PASS canonical directory and real access-descriptor policy (read-execute allowed, user write/owner denied)'

$root = Join-Path ([IO.Path]::GetTempPath()) ('honey-install-guard-' + [Guid]::NewGuid().ToString('N'))
$junction = Join-Path $root 'junction'
try {
    New-Item -ItemType Directory -Path $root | Out-Null
    $plain = Join-Path $root 'plain'
    New-Item -ItemType Directory -Path $plain | Out-Null
    [IO.File]::WriteAllText((Join-Path $plain 'fixture.json'), '{}')
    Set-ProtectedInstallationAcl (Get-Item -LiteralPath $plain)
    Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $plain)
    New-Item -ItemType Junction -Path $junction -Target $plain | Out-Null
    Assert-Throws { Assert-PlainInstallationPath (Join-Path $junction 'absent.exe') } 'A junction cannot hide inside an installation path'
    $danglingTarget = Join-Path $root 'dangling-target'
    $danglingJunction = Join-Path $root 'dangling-junction'
    New-Item -ItemType Directory -Path $danglingTarget | Out-Null
    New-Item -ItemType Junction -Path $danglingJunction -Target $danglingTarget | Out-Null
    [IO.Directory]::Delete($danglingTarget, $false)
    try {
        Assert-Throws { Assert-PlainInstallationPath $danglingJunction } 'A dangling junction cannot prove directory absence' 11
    } finally {
        Assert-True (([IO.File]::GetAttributes($danglingJunction) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Dangling fixture cleanup must remove only the link'
        [IO.Directory]::Delete($danglingJunction, $false)
    }
    Assert-Throws { Protect-HoneyInstallation $plain $true } 'Production guard must not normalize an arbitrary directory'
    # Execute the actual entry point, not only its dot-sourced functions. A
    # rejected arbitrary directory must expose only a fixed HNG code/stage.
    $guardScript = Join-Path $PSScriptRoot '../../scripts/secure_windows_installation.ps1'
    $nativePowerShell = Join-Path $env:WINDIR 'System32/WindowsPowerShell/v1.0/powershell.exe'
    $guardOutput = @(& $nativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $guardScript -RootDirectory $plain -Normalize 2>&1)
    $guardExit = $LASTEXITCODE
    Assert-True ($guardExit -eq 10) 'Guard CLI must retain fail-closed custom-directory rejection'
    Assert-True (($guardOutput -join "`n").Trim() -ceq 'HNG-10 phase=directory') 'Guard CLI diagnostics cannot expose raw exceptions or paths'
    $guardOutput = @(& $nativePowerShell -NoProfile -NonInteractive -ExecutionPolicy Bypass -File $guardScript -RootDirectory $plain -RetireOrphanedLegacy 2>&1)
    Assert-True ($LASTEXITCODE -eq 30) 'Orphan retirement cannot bypass legacy registration, process or cleanup validation'
    Assert-True (($guardOutput -join "`n").Trim() -ceq 'HNG-30 phase=directory') 'Invalid retirement mode exposes only a fixed code and stage'
    Write-Host 'PASS real x64 guard CLI rejects a custom directory with a safe code and stage'
    $sessions = Join-Path $root 'support/windows-vpn-sessions'
    $nonce = 'a' * 64
    $session = Join-Path $sessions $nonce
    New-Item -ItemType Directory -Path $session -Force | Out-Null
    [IO.File]::WriteAllText((Join-Path $sessions 'active.json'), (@{version=1;nonce=$nonce} | ConvertTo-Json -Compress))
    foreach ($case in @(
        @{phase='prepared';cleanupConfirmed=$false;expected=$true},
        @{phase='launching';cleanupConfirmed=$false;expected=$false},
        @{phase='stopping';cleanupConfirmed=$false;expected=$false},
        @{phase='failed';cleanupConfirmed=$false;expected=$false},
        @{phase='failed';cleanupConfirmed='True';expected=$false},
        @{phase='stopped';cleanupConfirmed=$true;expected=$true}
    )) {
        [IO.File]::WriteAllText((Join-Path $session 'state.json'), (@{version=1;nonce=$nonce;phase=$case.phase;cleanupConfirmed=$case.cleanupConfirmed} | ConvertTo-Json -Compress))
        Assert-True ((Test-LegacySessionCleanupAcknowledged (Join-Path $root 'support')) -eq $case.expected) ('Legacy cleanup policy phase ' + $case.phase)
    }
    Write-Host 'PASS legacy nonce acknowledgement policy blocks pending launch, stop and failed cleanup'
    Write-Host 'PASS actual owned temporary ACL normalization and junction rejection (no service or Program Files changes)'
} finally {
    if (Test-Path -LiteralPath $junction) {
        Assert-True (([IO.File]::GetAttributes($junction) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Fixture cleanup refuses a non-junction directory'
        # Nonrecursive deletion removes the junction itself, without a prompt
        # or traversal into its target under Windows PowerShell 5.1.
        [IO.Directory]::Delete($junction, $false)
        Assert-True (-not (Test-Path -LiteralPath $junction)) 'The owned junction must be removed'
        Assert-True ([IO.File]::ReadAllText((Join-Path $plain 'fixture.json')) -ceq '{}') 'Junction cleanup must preserve target contents'
        Write-Host 'PASS noninteractive junction cleanup preserves target contents'
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}

# Real owned registry keys exercise typed snapshot/CAS and nonrecursive removal
# without touching HKLM, Program Files, any uninstall record or user profile.
$registryBase = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::CurrentUser,
    [Microsoft.Win32.RegistryView]::Registry32)
$fixtureKeyName = 'Software\HoneyGuardFixture-' + [Guid]::NewGuid().ToString('N')
$registryParent = $null
try {
    $registryParent = $registryBase.CreateSubKey($fixtureKeyName,
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [Microsoft.Win32.RegistryOptions]::None, (New-FixtureRegistryAcl 'S-1-5-32-544'))
    $sibling = $registryParent.CreateSubKey('unrelated-sibling',
        [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
        [Microsoft.Win32.RegistryOptions]::None, (New-FixtureRegistryAcl 'S-1-5-32-544'))
    try { $sibling.SetValue('marker', 'must-survive', [Microsoft.Win32.RegistryValueKind]::String) }
    finally { $sibling.Dispose() }
    foreach ($caseName in @('unchanged', 'value-change', 'kind-change', 'acl-change', 'child-change', 'invalid-utf16')) {
        $fixtureKey = $registryParent.CreateSubKey($caseName,
            [Microsoft.Win32.RegistryKeyPermissionCheck]::ReadWriteSubTree,
            [Microsoft.Win32.RegistryOptions]::None, (New-FixtureRegistryAcl 'S-1-5-32-544'))
        try {
            $fixtureKey.SetValue('InstallLocation', $legacyDirectory, [Microsoft.Win32.RegistryValueKind]::String)
            $fixtureKey.SetValue('UninstallString', ('"' + (Join-Path $legacyDirectory 'unins000.exe') + '"'), [Microsoft.Win32.RegistryValueKind]::String)
            $fixtureKey.SetValue('Publisher', 'HoneyVPN', [Microsoft.Win32.RegistryValueKind]::String)
            $fixtureKey.SetValue('ExtraString', 'same', [Microsoft.Win32.RegistryValueKind]::String)
            $fixtureKey.SetValue('ExtraExpandable', '%TEMP%\literal', [Microsoft.Win32.RegistryValueKind]::ExpandString)
            $fixtureKey.SetValue('ExtraBinary', [byte[]]@(0, 1, 255), [Microsoft.Win32.RegistryValueKind]::Binary)
            $fixtureKey.SetValue('ExtraDword', [int]-1, [Microsoft.Win32.RegistryValueKind]::DWord)
            $fixtureKey.SetValue('ExtraQword', [long]12345678901, [Microsoft.Win32.RegistryValueKind]::QWord)
            $fixtureKey.SetValue('ExtraMulti', [string[]]@('first', 'second'), [Microsoft.Win32.RegistryValueKind]::MultiString)
            Assert-ExpectedLegacyRegistryKey $legacyDirectory $fixtureKey
            $fingerprint = Get-LegacyRegistryFingerprint $fixtureKey
            Assert-True ($fingerprint -ceq (Get-LegacyRegistryFingerprint $fixtureKey)) 'Unchanged typed metadata has a stable snapshot'
            switch ($caseName) {
                'value-change' { $fixtureKey.SetValue('ExtraString', 'foreign', [Microsoft.Win32.RegistryValueKind]::String) }
                'kind-change' { $fixtureKey.SetValue('ExtraString', 'same', [Microsoft.Win32.RegistryValueKind]::ExpandString) }
                'acl-change' {
                    $changedAcl = New-FixtureRegistryAcl 'S-1-5-32-544'
                    $changedAcl.SetGroup([Security.Principal.SecurityIdentifier]::new('S-1-5-18'))
                    $fixtureKey.SetAccessControl($changedAcl)
                }
                'child-change' {
                    $child = $fixtureKey.CreateSubKey('must-survive')
                    $child.Dispose()
                }
                'invalid-utf16' {
                    $fixtureKey.SetValue('ExtraString', [string][char]0xD800, [Microsoft.Win32.RegistryValueKind]::String)
                }
            }
        } finally { $fixtureKey.Dispose() }
        if ($caseName -ceq 'unchanged') {
            Remove-VerifiedRegistryLeaf $registryParent $caseName $fingerprint
            $remainingKey = $registryParent.OpenSubKey($caseName)
            Assert-True ($null -eq $remainingKey) 'Only the unchanged owned leaf is removed'
        } else {
            $expectedCode = if ($caseName -ceq 'child-change') { 38 } else { 36 }
            Assert-Throws { Remove-VerifiedRegistryLeaf $registryParent $caseName $fingerprint } 'Changed metadata or child keys must be preserved' $expectedCode
            $remainingKey = $registryParent.OpenSubKey($caseName, $true)
            Assert-True ($null -ne $remainingKey) 'Rejected retirement retains the entire owned fixture record'
            try {
                if ($caseName -ceq 'child-change') {
                    $remainingChild = $remainingKey.OpenSubKey('must-survive')
                    Assert-True ($null -ne $remainingChild) 'Nonrecursive retirement preserves child keys'
                    $remainingChild.Dispose()
                    # Remove only the fixture-owned fixed child after proving
                    # production preserved it. Never recursively delete keys.
                    $remainingKey.DeleteSubKey('must-survive', $true)
                }
            } finally { $remainingKey.Dispose() }
            $registryParent.DeleteSubKey($caseName, $true)
        }
    }
    $sibling = $registryParent.OpenSubKey('unrelated-sibling')
    Assert-True ($null -ne $sibling) 'Removing the verified leaf cannot remove a sibling registration'
    try { Assert-True ($sibling.GetValue('marker') -ceq 'must-survive') 'Sibling registry values remain intact' }
    finally { $sibling.Dispose() }
    $registryParent.DeleteSubKey('unrelated-sibling', $true)
    Write-Host 'PASS real typed registry snapshot/CAS preserves value, type, ACL and child changes; unchanged leaf alone is deleted'
} finally {
    if ($null -ne $registryParent) {
        # A failing case deliberately leaves evidence rather than deleting
        # unexpected contents or relying on recursive fixture cleanup.
        $empty = $registryParent.SubKeyCount -eq 0
        $registryParent.Dispose()
        if ($empty) { $registryBase.DeleteSubKey($fixtureKeyName, $true) }
    }
    $registryBase.Dispose()
}

# Exercise the production ordering, with only external probes stubbed. A
# failed closed-process or global ACK check cannot reach registry retirement.
$savedFunctions = @{}
foreach ($name in @('Assert-InstalledAppClosed', 'Get-DesktopApplicationSupportPath',
    'Assert-LegacySessionCleanupAcknowledged', 'Remove-OrphanedLegacyRegistration',
    'Assert-LegacyUninstallersAbsent')) {
    $savedFunctions[$name] = (Get-Item ('Function:' + $name)).ScriptBlock
}
try {
    $script:retirementTrace = [Collections.Generic.List[string]]::new()
    $script:retirementFailure = ''
    function Assert-InstalledAppClosed { param($Path)
        $script:retirementTrace.Add('closed')
        if ($script:retirementFailure -ceq 'closed') { throw 'close-installed-app' }
    }
    function Get-DesktopApplicationSupportPath { $script:retirementTrace.Add('desktop'); return 'fixture-support' }
    function Assert-LegacySessionCleanupAcknowledged { param($SupportDirectory)
        $script:retirementTrace.Add('ack')
        if ($script:retirementFailure -ceq 'ack') { throw 'legacy-cleanup-unconfirmed' }
    }
    function Remove-OrphanedLegacyRegistration { param($Path, $Fingerprint)
        Assert-True ($Path -ceq 'fixture-directory' -and $Fingerprint -ceq 'fixture-fingerprint') 'Retirement binds the validated directory and snapshot'
        $script:retirementTrace.Add('retire')
        if ($script:retirementFailure -ceq 'unsafe-registry') { throw 'unsafe-legacy-registry-access' }
        if ($script:retirementFailure -ceq 'changed-registry') { throw 'changed-legacy-registration' }
    }
    function Assert-LegacyUninstallersAbsent { param($Path)
        Assert-True ($Path -ceq 'fixture-directory') 'Final absence check binds the fixed legacy directory'
        $script:retirementTrace.Add('absent')
        if ($script:retirementFailure -ceq 'new-uninstaller') { throw 'missing-legacy-uninstaller' }
    }
    $retire = [pscustomobject]@{Disposition='RetireOrphan'; Fingerprint='fixture-fingerprint'}
    $preserve = [pscustomobject]@{Disposition='PreserveUnsafeOrphan'; Fingerprint=$null}
    foreach ($failure in @('closed', 'ack', '')) {
        $script:retirementTrace.Clear()
        $script:retirementFailure = $failure
        if ($failure) {
            Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $true $retire } 'Required legacy cleanup failure must stop migration'
            Assert-True (-not $script:retirementTrace.Contains('retire')) 'No registry changes occur before both cleanup proofs'
        } else {
            Complete-LegacyInstallationValidation 'fixture-directory' $true $retire
            Assert-True (($script:retirementTrace -join ',') -ceq 'closed,desktop,ack,retire') 'Retirement follows process closure and global ACK'
        }
    }
    $script:retirementTrace.Clear()
    Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $false $retire } 'Orphan cleanup cannot be invoked without required closure checks' 30
    Assert-True ($script:retirementTrace.Count -eq 0) 'Invalid retirement mode cannot reach a probe or registry mutation'
    Write-Host 'PASS production migration ordering requires closed processes and global cleanup ACK before retirement'
    foreach ($failure in @('closed', 'ack', 'new-uninstaller', '')) {
        $script:retirementTrace.Clear(); $script:retirementFailure = $failure
        if ($failure) {
            Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $true $preserve } 'Unsafe orphan preservation still requires closure, cleanup and final absence proofs'
        } else {
            Assert-True ((Complete-LegacyInstallationValidation 'fixture-directory' $true $preserve) -eq 39) 'Unsafe orphan has a separate non-executable exit39 disposition'
            Assert-True (($script:retirementTrace -join ',') -ceq 'closed,desktop,ack,absent') 'Preservation validates absence after closure/cleanup without registry retirement'
        }
        Assert-True (-not $script:retirementTrace.Contains('retire')) 'Preservation never invokes privileged registry deletion'
    }
    $script:retirementTrace.Clear(); $script:retirementFailure = 'unsafe-registry'
    Assert-True ((Complete-LegacyInstallationValidation 'fixture-directory' $true $retire) -eq 39) 'A namespace becoming unsafe after the snapshot is preserved after absence revalidation'
    Assert-True (($script:retirementTrace -join ',') -ceq 'closed,desktop,ack,retire,absent') 'A late unsafe namespace still cannot reach an uninstaller'
    $script:retirementFailure = 'changed-registry'
    Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $true $retire } 'Changed registry metadata is not confused with optional unsafe-namespace preservation' 36
    foreach ($invalid in @($null, 'fixture-fingerprint',
        [pscustomobject]@{Disposition='PreserveUnsafeOrphan'; Fingerprint='fixture-fingerprint'},
        [pscustomobject]@{Disposition='RetireOrphan'; Fingerprint=$null},
        [pscustomobject]@{Disposition='unknown'; Fingerprint=$null})) {
        $script:retirementTrace.Clear()
        Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $true $invalid } 'Disposition is explicit and cannot be confused with null, a fingerprint or an unknown mode' 30
        Assert-True ($script:retirementTrace.Count -eq 0) 'Invalid disposition cannot reach any cleanup or registry probe'
    }
    Assert-Throws { Complete-LegacyInstallationValidation 'fixture-directory' $false $preserve } 'Exit39 is unavailable without required closure checks' 30
    Write-Host 'PASS unsafe orphan preservation is a distinct exit39 after closure/ACK/absence, with no registry repair or deletion'

} finally {
    foreach ($name in $savedFunctions.Keys) { Set-Item ('Function:' + $name) $savedFunctions[$name] }
}
