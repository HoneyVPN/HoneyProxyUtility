param([string]$RootDirectory, [switch]$Normalize, [switch]$Legacy,
      [switch]$VerifyLegacyRegistration, [switch]$RequireClosed,
      [switch]$RetireOrphanedLegacy)
$ErrorActionPreference = 'Stop'

function Get-InstallationGuardExitCode([string]$Reason, [string]$Stage) {
    # Only our fixed reason strings and stage names leave the hidden process.
    # Native/PowerShell exception messages may contain paths and identities.
    switch -Exact ($Reason) {
        'unexpected-install-directory' { return 10 }
        'unsafe-install-path' { return 11 }
        'unsafe-install-owner' { return 12 }
        'unsafe-install-write-access' { return 13 }
        'close-installed-app' { return 20 }
        'installed-process-path-unavailable' { return 24 }
        'legacy-core-cleanup-unconfirmed' { return 21 }
        'legacy-cleanup-unconfirmed' { return 22 }
        'unexpected-legacy-mode' { return 30 }
        'untrusted-legacy-registration' { return 31 }
        'untrusted-legacy-command' { return 32 }
        'missing-legacy-uninstaller' { return 33 }
        'changed-legacy-registration' { return 36 }
        'unsafe-legacy-registry-access' { return 37 }
        'legacy-registration-has-children' { return 38 }
    }
    switch -Exact ($Stage) {
        'directory' { return 14 }
        'application-state' { return 24 }
        'desktop-profile' { return 23 }
        'legacy-cleanup' { return 22 }
        'legacy-registration' { return 34 }
        default { return 2 }
    }
}

function Assert-PlainInstallationPath([string]$Path) {
    $current = [IO.Path]::GetFullPath($Path)
    while ($current) {
        # Attribute lookup inspects the link itself, including dangling links.
        # Test-Path/Directory.Exists can instead report a missing target.
        $attributes = Get-InstallationPathAttributes $current
        if ($null -ne $attributes -and ($attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
            throw 'unsafe-install-path'
        }
        $parent = [IO.Path]::GetDirectoryName($current)
        if ($parent -eq $current) { break }
        $current = $parent
    }
}

function Get-InstallationPathAttributes([string]$Path) {
    try { return [IO.File]::GetAttributes($Path) }
    catch [IO.FileNotFoundException] { return $null }
    catch [IO.DirectoryNotFoundException] { return $null }
    # Access-denied and all other IO failures cannot prove absence.
}

function Test-ExpectedInstallationDirectory([string]$Path, [bool]$LegacyDirectory = $false) {
    $folder = if ($LegacyDirectory) { [Environment+SpecialFolder]::ProgramFilesX86 }
        else { [Environment+SpecialFolder]::ProgramFiles }
    $expected = Join-Path ([Environment]::GetFolderPath($folder)) 'HoneyProxyUtility'
    return [IO.Path]::GetFullPath($Path).TrimEnd('\') -ieq $expected.TrimEnd('\')
}

function Assert-TrustedInstallationAcl($Acl, [bool]$Ancestor = $false) {
    $trusted = @('S-1-5-18', 'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    $owner = $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
    if ($trusted -notcontains $owner) { throw 'unsafe-install-owner' }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl -or
        ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0) {
        throw 'unsafe-install-write-access'
    }
    $write = [long]([Security.AccessControl.FileSystemRights]::Write -bor
        [Security.AccessControl.FileSystemRights]::Delete -bor
        [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
        [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
        [Security.AccessControl.FileSystemRights]::TakeOwnership)
    # Ordinary volume ancestors may allow creating unrelated subdirectories.
    # They must not allow replacing/removing the protected installed subtree.
    if ($Ancestor) { $write = 0xD0040 }
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -ne [Security.AccessControl.AccessControlType]::Allow -or
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -ne 0) { continue }
        if (([long]$rule.FileSystemRights -band $write) -ne 0 -and $trusted -notcontains $rule.IdentityReference.Value) {
            throw 'unsafe-install-write-access'
        }
    }
}

function New-ProtectedInstallationAcl([bool]$Directory) {
    $acl = if ($Directory) { [Security.AccessControl.DirectorySecurity]::new() }
        else { [Security.AccessControl.FileSecurity]::new() }
    $acl.SetOwner([Security.Principal.SecurityIdentifier]::new('S-1-5-32-544'))
    $acl.SetAccessRuleProtection($true, $false)
    $inherit = if ($Directory) {
        [Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit
    } else { [Security.AccessControl.InheritanceFlags]::None }
    foreach ($sid in @('S-1-5-18', 'S-1-5-32-544', 'S-1-5-32-545')) {
        $rights = if ($sid -eq 'S-1-5-32-545') { [Security.AccessControl.FileSystemRights]::ReadAndExecute }
            else { [Security.AccessControl.FileSystemRights]::FullControl }
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new($sid), $rights, $inherit,
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
        $acl.AddAccessRule($rule)
    }
    return $acl
}

function Set-ProtectedInstallationAcl($Item) {
    Set-Acl -LiteralPath $Item.FullName -AclObject (New-ProtectedInstallationAcl $Item.PSIsContainer)
}

function Protect-HoneyInstallation([string]$Path, [bool]$NormalizeAcl, [bool]$LegacyDirectory = $false) {
    if (-not [Environment]::Is64BitProcess -or -not (Test-ExpectedInstallationDirectory $Path $LegacyDirectory) -or
        ($NormalizeAcl -and $LegacyDirectory)) { throw 'unexpected-install-directory' }
    Assert-PlainInstallationPath $Path
    $ancestor = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    while ($ancestor) {
        Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $ancestor) $true
        $parent = [IO.Path]::GetDirectoryName($ancestor)
        if ($parent -eq $ancestor) { break }
        $ancestor = $parent
    }
    $items = @()
    if (Test-Path -LiteralPath $Path) {
        $root = Get-Item -LiteralPath $Path -Force
        if (-not $root.PSIsContainer) { throw 'unexpected-install-directory' }
        # Existing code is never executed before its directory and all writable
        # descendants are shown to be trusted. No recursive repair of a foreign
        # writable tree or junction is attempted with administrator privileges.
        Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $root.FullName)
        $items = @($root) + @(Get-ChildItem -LiteralPath $Path -Force -Recurse)
        foreach ($item in $items) {
            Assert-PlainInstallationPath $item.FullName
            Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $item.FullName)
        }
    } elseif ($NormalizeAcl) {
        $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
        Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $parent)
        # The first visible object already has the final DACL and owner. Never
        # create a permissive directory and try to repair it after publication.
        [IO.Directory]::CreateDirectory($Path, (New-ProtectedInstallationAcl $true)) | Out-Null
        $items = @(Get-Item -LiteralPath $Path -Force)
    }
    if ($NormalizeAcl) {
        foreach ($item in $items) { Set-ProtectedInstallationAcl $item }
        foreach ($item in $items) { Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $item.FullName) }
    }
}

function Assert-ExpectedLegacyRegistration([string]$Path, [string]$InstallLocation,
    [string]$UninstallCommand, [string]$Publisher) {
    if (-not (Test-ExpectedInstallationDirectory $Path $true) -or $Publisher -cne 'HoneyVPN' -or
        [IO.Path]::GetFullPath($InstallLocation).TrimEnd('\') -ine [IO.Path]::GetFullPath($Path).TrimEnd('\')) {
        throw 'untrusted-legacy-registration'
    }
    $expected = '"' + (Join-Path $Path 'unins000.exe') + '"'
    if ($UninstallCommand.Trim() -ine $expected) { throw 'untrusted-legacy-command' }
}

function Assert-TrustedLegacyRegistryAcl($Acl) {
    $trusted = @('S-1-5-18', 'S-1-5-32-544',
        'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
    if ($trusted -notcontains $Acl.GetOwner([Security.Principal.SecurityIdentifier]).Value) {
        throw 'unsafe-legacy-registry-access'
    }
    $descriptor = [Security.AccessControl.RawSecurityDescriptor]::new($Acl.GetSecurityDescriptorBinaryForm(), 0)
    if ($null -eq $descriptor.DiscretionaryAcl -or
        ($descriptor.ControlFlags -band [Security.AccessControl.ControlFlags]::DiscretionaryAclPresent) -eq 0) {
        throw 'unsafe-legacy-registry-access'
    }
    # KEY_SET_VALUE, KEY_CREATE_SUB_KEY, KEY_CREATE_LINK, DELETE, WRITE_DAC,
    # WRITE_OWNER. A writable parent can replace even a protected leaf key.
    foreach ($rule in $Acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier])) {
        if ($rule.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
            ($rule.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and
            ([long]$rule.RegistryRights -band 0xD0026) -ne 0 -and
            $trusted -notcontains $rule.IdentityReference.Value) { throw 'unsafe-legacy-registry-access' }
    }
}

function Assert-TrustedLegacyRegistryAncestors($Base) {
    $name = ''
    foreach ($part in @('Software', 'Microsoft', 'Windows', 'CurrentVersion', 'Uninstall')) {
        $name = if ($name) { $name + '\' + $part } else { $part }
        $key = $Base.OpenSubKey($name)
        if ($null -eq $key) { throw 'changed-legacy-registration' }
        try { Assert-TrustedLegacyRegistryAcl ($key.GetAccessControl()) }
        finally { $key.Dispose() }
    }
}

function Assert-ExpectedLegacyRegistryKey([string]$Path, $Key) {
    foreach ($name in @('InstallLocation', 'UninstallString', 'Publisher')) {
        if ($Key.GetValueKind($name) -ne [Microsoft.Win32.RegistryValueKind]::String) {
            throw 'untrusted-legacy-registration'
        }
    }
    $raw = [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames
    Assert-ExpectedLegacyRegistration $Path $Key.GetValue('InstallLocation', $null, $raw) `
        $Key.GetValue('UninstallString', $null, $raw) $Key.GetValue('Publisher', $null, $raw)
}

function Get-LegacyRegistryFingerprint($Key) {
    Assert-TrustedLegacyRegistryAcl ($Key.GetAccessControl())
    if ($Key.SubKeyCount -ne 0) { throw 'legacy-registration-has-children' }
    $names = [string[]]$Key.GetValueNames()
    if ($names.Length -gt 128) { throw 'changed-legacy-registration' }
    [Array]::Sort($names, [StringComparer]::Ordinal)
    $stream = [IO.MemoryStream]::new()
    # Invalid UTF-16 must fail closed rather than collide after replacement
    # encoding in the snapshot of names and string values.
    $writer = [IO.BinaryWriter]::new($stream, [Text.UTF8Encoding]::new($false, $true), $true)
    try {
        $sections = [Security.AccessControl.AccessControlSections]::Access -bor
            [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Group
        $writer.Write($Key.GetAccessControl().GetSecurityDescriptorSddlForm($sections))
        $writer.Write($names.Length)
        foreach ($name in $names) {
            if ($name.Length -gt 32768) { throw 'changed-legacy-registration' }
            $kind = $Key.GetValueKind($name)
            $value = $Key.GetValue($name, $null, [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)
            Assert-LegacyRegistryString $name
            $writer.Write($name)
            $writer.Write([int]$kind)
            switch ($kind) {
                { $_ -eq [Microsoft.Win32.RegistryValueKind]::String -or $_ -eq [Microsoft.Win32.RegistryValueKind]::ExpandString } {
                    if ($value -isnot [string] -or $value.Length -gt 32768) { throw 'changed-legacy-registration' }
                    Assert-LegacyRegistryString $value
                    $writer.Write([string]$value); break
                }
                { $_ -eq [Microsoft.Win32.RegistryValueKind]::Binary -or $_ -eq [Microsoft.Win32.RegistryValueKind]::None } {
                    if ($value -isnot [byte[]] -or $value.Length -gt 65536) { throw 'changed-legacy-registration' }
                    $writer.Write($value.Length); $writer.Write([byte[]]$value); break
                }
                ([Microsoft.Win32.RegistryValueKind]::DWord) { $writer.Write([int]$value); break }
                ([Microsoft.Win32.RegistryValueKind]::QWord) { $writer.Write([long]$value); break }
                ([Microsoft.Win32.RegistryValueKind]::MultiString) {
                    if ($value -isnot [string[]] -or $value.Length -gt 128) { throw 'changed-legacy-registration' }
                    $writer.Write($value.Length)
                    foreach ($text in $value) {
                        Assert-LegacyRegistryString $text
                        $writer.Write([string]$text)
                    }
                    break
                }
                default { throw 'changed-legacy-registration' }
            }
            if ($stream.Length -gt 1048576) { throw 'changed-legacy-registration' }
        }
        $writer.Flush()
        $hash = [Security.Cryptography.SHA256]::Create()
        try { return [Convert]::ToBase64String($hash.ComputeHash($stream.ToArray())) }
        finally { $hash.Dispose() }
    } finally { $writer.Dispose(); $stream.Dispose() }
}

function Assert-LegacyRegistryString([string]$Text) {
    # .NET Framework's REG_SZ decoder may already replace malformed UTF-16.
    # Reject both a surviving surrogate and its replacement representation,
    # rather than treating two different stored byte strings as equal.
    if ($Text.Length -gt 32768 -or $Text.IndexOf([char]0xFFFD) -ge 0) { throw 'changed-legacy-registration' }
    try { [Text.UTF8Encoding]::new($false, $true).GetByteCount($Text) | Out-Null }
    catch [Text.EncoderFallbackException] { throw 'changed-legacy-registration' }
}

function Assert-EmptyOrAbsentLegacyDirectory([string]$Path) {
    # No deletion or ACL repair is performed. In particular, missing-target
    # junctions cannot be mistaken for an absent installation directory.
    Protect-HoneyInstallation $Path $false $true
    $parent = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($Path))
    Assert-TrustedInstallationAcl (Get-Acl -LiteralPath $parent)
    $attributes = Get-InstallationPathAttributes $Path
    if ($null -eq $attributes) { return }
    if (($attributes -band [IO.FileAttributes]::Directory) -eq 0 -or
        [IO.Directory]::GetFileSystemEntries($Path).Length -ne 0) { throw 'missing-legacy-uninstaller' }
}

function Assert-LegacyUninstallersAbsent([string]$Path) {
    Assert-EmptyOrAbsentLegacyDirectory $Path
    foreach ($leaf in @('unins000.exe', 'unins000.dat')) {
        if ($null -ne (Get-InstallationPathAttributes (Join-Path $Path $leaf))) {
            throw 'missing-legacy-uninstaller'
        }
    }
}

function Assert-TrustedLegacyRegistration([string]$Path, [bool]$AllowOrphan = $false) {
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry32)
    try {
        $key = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall\HoneyProxyUtility_is1')
        if ($null -eq $key) { throw 'untrusted-legacy-registration' }
        try {
            Assert-ExpectedLegacyRegistryKey $Path $key
            if ((Test-Path -LiteralPath (Join-Path $Path 'unins000.exe') -PathType Leaf) -and
                (Test-Path -LiteralPath (Join-Path $Path 'unins000.dat') -PathType Leaf)) {
                return [pscustomobject]@{Disposition='Installed'; Fingerprint=$null}
            }
            if (-not $AllowOrphan) { throw 'missing-legacy-uninstaller' }
            Assert-LegacyUninstallersAbsent $Path
            if ($key.SubKeyCount -ne 0) { throw 'legacy-registration-has-children' }
            try {
                Assert-TrustedLegacyRegistryAncestors $base
                $fingerprint = Get-LegacyRegistryFingerprint $key
                return [pscustomobject]@{Disposition='RetireOrphan'; Fingerprint=$fingerprint}
            } catch {
                if ($_.Exception.Message -cne 'unsafe-legacy-registry-access') { throw }
                # Unsafe orphan metadata is never repaired, deleted or used
                # to launch code. Closure/session checks and a final absence
                # check are still required before the separate exit39 result.
                return [pscustomobject]@{Disposition='PreserveUnsafeOrphan'; Fingerprint=$null}
            }
        } finally { $key.Dispose() }
    } finally { $base.Dispose() }
}

function Remove-VerifiedRegistryLeaf($Parent, [string]$Leaf, [string]$Fingerprint) {
    # Caller retains a trusted fixed parent. Never delete child keys or replay a
    # registry-provided command. The typed snapshot also binds extra metadata.
    Assert-TrustedLegacyRegistryAcl ($Parent.GetAccessControl())
    $key = $Parent.OpenSubKey($Leaf)
    if ($null -eq $key) { throw 'changed-legacy-registration' }
    try {
        if ((Get-LegacyRegistryFingerprint $key) -cne $Fingerprint) { throw 'changed-legacy-registration' }
    } finally { $key.Dispose() }
    $Parent.DeleteSubKey($Leaf, $true)
    $remaining = $Parent.OpenSubKey($Leaf)
    if ($null -ne $remaining) {
        $remaining.Dispose()
        throw 'changed-legacy-registration'
    }
}

function Remove-OrphanedLegacyRegistration([string]$Path, [string]$Fingerprint) {
    Assert-EmptyOrAbsentLegacyDirectory $Path
    $base = [Microsoft.Win32.RegistryKey]::OpenBaseKey([Microsoft.Win32.RegistryHive]::LocalMachine,
        [Microsoft.Win32.RegistryView]::Registry32)
    try {
        Assert-TrustedLegacyRegistryAncestors $base
        $parent = $base.OpenSubKey('Software\Microsoft\Windows\CurrentVersion\Uninstall', $true)
        if ($null -eq $parent) { throw 'changed-legacy-registration' }
        try {
            $key = $parent.OpenSubKey('HoneyProxyUtility_is1')
            if ($null -eq $key) { throw 'changed-legacy-registration' }
            try { Assert-ExpectedLegacyRegistryKey $Path $key }
            finally { $key.Dispose() }
            Remove-VerifiedRegistryLeaf $parent 'HoneyProxyUtility_is1' $Fingerprint
        } finally { $parent.Dispose() }
    } finally { $base.Dispose() }
}

function Initialize-DesktopUserIdentity {
    if ($null -eq ('DesktopUserIdentity' -as [type])) {
        # Setup extracts this fixed source alongside its own guard resource.
        # Uninstall verifies the installed tree before executing this guard.
        $helper = Join-Path $PSScriptRoot 'DesktopUserIdentity.cs'
        Assert-PlainInstallationPath $helper
        if (-not (Test-Path -LiteralPath $helper -PathType Leaf)) { throw 'desktop-context-unavailable' }
        Add-Type -LiteralPath $helper
    }
}

function Test-InstallationCoreRunning([string]$Path, [object[]]$Processes,
    [scriptblock]$ReadProcessImage = $null) {
    $ui = Join-Path $Path 'HoneyProxyUtility.exe'
    $core = Join-Path $Path 'sing-box.exe'
    if ($null -eq $ReadProcessImage) {
        $ReadProcessImage = {
            param([uint32]$ProcessId)
            Initialize-DesktopUserIdentity
            [DesktopUserIdentity]::ReadProcessImage($ProcessId)
        }
    }
    $coreRunning = $false
    foreach ($process in $Processes) {
        $image = [string]$process.ExecutablePath
        if (($process.Name -ieq 'HoneyProxyUtility.exe' -or $process.Name -ieq 'sing-box.exe') -and
            [string]::IsNullOrWhiteSpace($image)) {
            # CIM can withhold paths belonging to another elevated identity.
            # Resolve only these candidates through a retained read-only
            # process handle. Unknown ownership never means "already closed".
            try { $image = & $ReadProcessImage ([uint32]$process.ProcessId) }
            catch { throw 'installed-process-path-unavailable' }
            if ([string]::IsNullOrWhiteSpace($image) -or -not [IO.Path]::IsPathRooted($image)) {
                throw 'installed-process-path-unavailable'
            }
        }
        if ($image -ieq $ui) { throw 'close-installed-app' }
        if ($image -ieq $core) { $coreRunning = $true }
    }
    return $coreRunning
}

function Assert-InstalledAppClosed([string]$Path) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        $processes = @(Get-CimInstance Win32_Process -ErrorAction Stop)
        if (-not (Test-InstallationCoreRunning $Path $processes)) { return }
        # Let the previous app's retained-child supervisor finish its scoped
        # cleanup after window exit. Never kill by image name or recovered PID.
        Start-Sleep -Milliseconds 250
    } while ($clock.ElapsedMilliseconds -lt 15000)
    throw 'legacy-core-cleanup-unconfirmed'
}

function Get-DesktopApplicationSupportPath {
    Initialize-DesktopUserIdentity
    return Join-Path ([DesktopUserIdentity]::ReadRoamingPath()) 'ru.honeyvpn\HoneyProxyUtility'
}

function Test-LegacySessionCleanupAcknowledged([string]$SupportDirectory) {
    $root = Join-Path $SupportDirectory 'windows-vpn-sessions'
    Assert-PlainInstallationPath $root
    $pointer = Join-Path $root 'active.json'
    if (-not (Test-Path -LiteralPath $pointer)) { return $true }
    Assert-PlainInstallationPath $pointer
    if ((Get-Item -LiteralPath $pointer).Length -gt 16384) { throw 'legacy-cleanup-unconfirmed' }
    $active = Get-Content -LiteralPath $pointer -Raw | ConvertFrom-Json
    if ($active.version -ne 1 -or $active.nonce -cnotmatch '^[a-f0-9]{64}$') { throw 'legacy-cleanup-unconfirmed' }
    $statePath = Join-Path (Join-Path $root $active.nonce) 'state.json'
    Assert-PlainInstallationPath $statePath
    if (-not (Test-Path -LiteralPath $statePath)) { return $false }
    if ((Get-Item -LiteralPath $statePath).Length -gt 16384) { throw 'legacy-cleanup-unconfirmed' }
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    # The legacy version writes launching before UAC/core invocation. Prepared
    # therefore proves no late elevated launch was attempted; all other phases
    # require the supervisor's captured-nonce cleanup acknowledgement.
    if ($state.version -ne 1 -or $state.nonce -cne $active.nonce) {
        throw 'legacy-cleanup-unconfirmed'
    }
    return $state.phase -ceq 'prepared' -or
        ($state.phase -cin @('stopped','failed') -and $state.cleanupConfirmed -is [bool] -and $state.cleanupConfirmed)
}

function Assert-LegacySessionCleanupAcknowledged([string]$SupportDirectory) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    do {
        try {
            if (Test-LegacySessionCleanupAcknowledged $SupportDirectory) { return }
        } catch [IO.FileNotFoundException] {
            # Atomic legacy release can remove the pointer between metadata IO.
        }
        Start-Sleep -Milliseconds 100
    } while ($clock.ElapsedMilliseconds -lt 15000)
    throw 'legacy-cleanup-unconfirmed'
}

function Complete-LegacyInstallationValidation([string]$Path, [bool]$ClosedRequired,
    $Registration) {
    if ($Registration -isnot [pscustomobject] -or
        $null -eq $Registration.PSObject.Properties['Disposition'] -or
        $null -eq $Registration.PSObject.Properties['Fingerprint']) { throw 'unexpected-legacy-mode' }
    if ($Registration.Disposition -isnot [string] -or $Registration.Disposition -cnotin
        @('None', 'Installed', 'RetireOrphan', 'PreserveUnsafeOrphan') -or
        ($Registration.Disposition -ceq 'RetireOrphan' -and
            ($Registration.Fingerprint -isnot [string] -or
                [string]::IsNullOrEmpty($Registration.Fingerprint))) -or
        ($Registration.Disposition -cne 'RetireOrphan' -and $null -ne $Registration.Fingerprint) -or
        ($Registration.Disposition -cin @('RetireOrphan', 'PreserveUnsafeOrphan') -and -not $ClosedRequired)) {
        throw 'unexpected-legacy-mode'
    }
    if ($ClosedRequired) {
        $script:honeyGuardStage = 'application-state'
        Assert-InstalledAppClosed $Path
        $script:honeyGuardStage = 'desktop-profile'
        $support = Get-DesktopApplicationSupportPath
        $script:honeyGuardStage = 'legacy-cleanup'
        Assert-LegacySessionCleanupAcknowledged $support
    }
    if ($Registration.Disposition -ceq 'RetireOrphan') {
        $script:honeyGuardStage = 'legacy-registration'
        try { Remove-OrphanedLegacyRegistration $Path $Registration.Fingerprint }
        catch {
            if ($_.Exception.Message -cne 'unsafe-legacy-registry-access') { throw }
            # The namespace can change after the initial snapshot. Exit39 is
            # still safe only when no legacy executable/data can be launched.
            Assert-LegacyUninstallersAbsent $Path
            return 39
        }
    } elseif ($Registration.Disposition -ceq 'PreserveUnsafeOrphan') {
        $script:honeyGuardStage = 'legacy-registration'
        Assert-LegacyUninstallersAbsent $Path
        return 39
    }
    return 0
}

if ($MyInvocation.InvocationName -ne '.') {
    $honeyGuardStage = 'directory'
    try {
        if ($RetireOrphanedLegacy -and (-not $Legacy -or -not $VerifyLegacyRegistration -or
            -not $RequireClosed -or $Normalize)) { throw 'unexpected-legacy-mode' }
        Protect-HoneyInstallation $RootDirectory $Normalize.IsPresent $Legacy.IsPresent
        $honeyLegacyRegistration = [pscustomobject]@{Disposition='None'; Fingerprint=$null}
        if ($VerifyLegacyRegistration) {
            $honeyGuardStage = 'legacy-registration'
            if (-not $Legacy) { throw 'unexpected-legacy-mode' }
            $honeyLegacyRegistration = Assert-TrustedLegacyRegistration $RootDirectory $RetireOrphanedLegacy.IsPresent
        }
        $honeyLegacyExit = Complete-LegacyInstallationValidation $RootDirectory $RequireClosed.IsPresent $honeyLegacyRegistration
        if ($honeyLegacyExit -eq 39) {
            if (-not $RetireOrphanedLegacy -or -not $Legacy -or -not $VerifyLegacyRegistration -or
                -not $RequireClosed -or $Normalize) { throw 'unexpected-legacy-mode' }
            Write-Output 'HNG-39 phase=orphan-registration-preserved'
            exit 39
        }
        Write-Output 'HNG-0 phase=complete'
        exit 0
    }
    catch {
        $honeyGuardExitCode = Get-InstallationGuardExitCode $_.Exception.Message $honeyGuardStage
        Write-Output ('HNG-' + $honeyGuardExitCode + ' phase=' + $honeyGuardStage)
        exit $honeyGuardExitCode
    }
}
