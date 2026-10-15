param([string]$Supervisor = (Join-Path $PSScriptRoot '../../windows/runner/windows_vpn_supervisor.ps1'))
$ErrorActionPreference = 'Stop'; Set-StrictMode -Version Latest
. $Supervisor
$script:passed = 0
function Assert-True([bool]$Condition, [string]$Message) { if (-not $Condition) { throw $Message }; $script:passed++ }
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $caught = $false; try { & $Action | Out-Null } catch { $caught = $true }
    Assert-True $caught $Message
}
# Real process identity reads only. No process is signaled by these probes.
$self = [Diagnostics.Process]::GetCurrentProcess()
try {
    $birth = $self.StartTime.ToUniversalTime().Ticks.ToString()
    Assert-True (-not (Test-CapturedSessionProcessExited $self.Id $birth)) 'Live exact retained process must not be considered dead'
    Assert-True (Test-CapturedSessionProcessExited $self.Id '638000000000000000') 'A reused PID with another birth must not identify the captured owner'
} finally { $self.Dispose() }

$temporaryRoot = if ([IO.Directory]::Exists('/private/tmp')) { '/private/tmp' } else { [IO.Path]::GetTempPath() }
$root = Join-Path $temporaryRoot ('honey-proxy-recovery-tests-' + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$script:current = $null; $script:writes = 0; $script:notify = 0
$script:parentDead = $true; $script:supervisorDead = $true; $script:jobGone = $true; $script:jobUnknown = $false
$script:failWrite = $false; $script:failField = 'Server'; $script:probeCalls = 0
$script:fakeSid = 'S-1-5-21-111-222-333-1001'
# Only these native process/WinINet boundaries are mocked. Production journal IO,
# validation, lock, restore transaction and cleanup acknowledgement are exercised.
function Get-SessionProxyOwnerSid { return $script:fakeSid }
function Test-CapturedSessionProcessExited([int]$CapturedPid, [string]$CapturedBirth) {
    if ($CapturedPid -eq 32123) { return $script:parentDead }; return $script:supervisorDead
}
function Test-SessionProxyJobGone($Session) {
    $script:probeCalls++
    if ($script:jobUnknown) { throw 'proxy-job-unconfirmed' }; return $script:jobGone
}
function Copy-Settings($Value) { return [PSCustomObject]@{Flags=$Value.Flags; Server=$Value.Server; Bypass=$Value.Bypass; AutoConfigUrl=$Value.AutoConfigUrl} }
function Read-SessionProxySettings { return Copy-Settings $script:current }
function Write-SessionProxySettings($Value) {
    $script:writes++
    if ($script:failWrite) { $script:current.($script:failField) = $Value.($script:failField); throw 'proxy-set-failed' }
    $script:current = Copy-Settings $Value
}
function Send-SessionProxyChanged { $script:notify++ }
$script:prior = [PSCustomObject]@{Flags=[uint32]13; Server='corporate.example:8080'; Bypass='*.example;<local>'; AutoConfigUrl='https://pac.example.test/config.pac'}
function New-RecoveryFixture {
    $script:current = Copy-Settings $script:prior
    $script:writes = 0; $script:notify = 0; $script:probeCalls = 0
    $script:parentDead = $true; $script:supervisorDead = $true; $script:jobGone = $true; $script:jobUnknown = $false; $script:failWrite = $false
    $nonce = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $directory = Join-Path $root $nonce; New-Item -ItemType Directory -Path $directory | Out-Null
    $data = @{version=1; nonce=$nonce; parentPid=32123; parentStartTicks='638000000000000000'; tunnel=$false; httpPort=2081; proxyIp=$null}
    [IO.File]::WriteAllText((Join-Path $directory 'request.json'), ($data | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $root 'active.json'), (@{version=1; nonce=$nonce} | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $directory 'stop'), $nonce)
    $session = Read-SupervisorRequest (Join-Path $directory 'request.json') -MetadataOnly
    $session.Recovery = New-SessionProxyRecoveryRecord $session (Get-SessionProxyJobName $nonce)
    Write-SessionProxyRecovery $session
    Write-SessionState $session 'running' $false
    return $session
}
function Read-FixtureState($Session) { return Read-SessionBoundedJson (Join-Path $Session.Directory 'state.json') 16384 }
function Invoke-FixtureRecovery($Session) { return Invoke-WindowsVpnProxyRecovery (Join-Path $Session.Directory 'request.json') }
try {
    $session = New-RecoveryFixture
    $before = $script:writes
    Assert-True (Invoke-FixtureRecovery $session) 'A dead supervisor with a destroyed job and no proxy-write intent must be recoverable'
    Assert-True ($script:writes -eq $before -and (Read-FixtureState $session).cleanupConfirmed) 'Pre-proxy recovery needs no system settings write and publishes a native ACK'

    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session
    $saved = Read-SessionProxyRecovery $session
    Assert-True ($saved.Stage -ceq 'proxy-active' -and $saved.Applied -and $saved.Desired.Server -ceq '127.0.0.1:2081') 'Complete prior/desired settings must precede running publication'
    Assert-True (Invoke-FixtureRecovery $session) 'Owned active proxy must recover after exact process and job death'
    Assert-True (Test-SessionProxySettingsEqual $script:current $script:prior) 'Recovery must restore the full prior PAC/WPAD/bypass/manual descriptor'
    Assert-True ((Read-FixtureState $session).cleanupConfirmed -and (Read-FixtureState $session).reasonCode -ceq 'proxy-recovered') 'Only completed scoped recovery may acknowledge stopped'

    foreach ($gate in @('parent','supervisor','job')) {
        $session = New-RecoveryFixture; $owned = Set-SessionProxy $session; $before = $script:writes
        switch ($gate) {'parent' {$script:parentDead=$false} 'supervisor' {$script:supervisorDead=$false} 'job' {$script:jobGone=$false}}
        Assert-True (-not (Invoke-FixtureRecovery $session)) ('A surviving ' + $gate + ' must block recovery')
        Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) ('No ' + $gate + ' uncertainty may change settings or forge ACK')
    }
    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session; $before = $script:writes; $script:jobUnknown=$true
    Assert-Throws { Invoke-FixtureRecovery $session } 'Access/provider failure of the original job cannot mean it is gone'
    Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) 'Unknown job proof preserves the active journal and current settings'

    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session
    [IO.File]::Delete((Join-Path $session.Directory 'proxy-recovery.json')); $before=$script:writes
    Assert-True (-not (Invoke-FixtureRecovery $session)) 'Legacy missing prior/job journal cannot be automatically recovered'
    Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) 'Legacy no-proof state must survive unchanged'

    foreach ($field in @('OwnerSid','Nonce','ParentPid','SupervisorStartTicks','ChildPolicy','JobName','Stage')) {
        $session = New-RecoveryFixture; $owned = Set-SessionProxy $session; $before=$script:writes
        if ($field -ceq 'ParentPid') { $session.Recovery.ParentPid=32124 }
        else { $session.Recovery.$field='invalid-fixture' }
        Write-SessionProxyRecovery $session
        Assert-Throws { Invoke-FixtureRecovery $session } ('Mismatched ' + $field + ' must block authority')
        Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) ('Invalid ' + $field + ' must not change settings or ACK')
    }
    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session; $before=$script:writes
    [IO.File]::WriteAllText((Join-Path $session.Directory 'proxy-recovery.json'), ('x' * 65537))
    Assert-Throws { Invoke-FixtureRecovery $session } 'Oversized rollback records must fail with bounded input'
    Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) 'Oversized input cannot authorize cleanup'

    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session
    $script:current.Server='another-app.example:8080'; $script:current.Bypass='later-foreign-bypass'
    $foreign=Copy-Settings $script:current; $before=$script:writes
    Assert-True (Invoke-FixtureRecovery $session) 'A foreign replacement endpoint does not remain an owned resource'
    Assert-True ($script:writes -eq $before -and (Test-SessionProxySettingsEqual $script:current $foreign)) 'Foreign proxy endpoint and all options must survive recovery'

    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session; $script:current.Bypass='later-user-bypass'
    Assert-True (Invoke-FixtureRecovery $session) 'Later metadata change cannot retain a dead owned endpoint'
    Assert-True ($script:current.Bypass -ceq 'later-user-bypass' -and $script:current.Server -ceq $script:prior.Server -and $script:current.Flags -eq $script:prior.Flags) 'Restore owned options while preserving later foreign bypass choice'

    foreach ($field in @('Flags','Server','Bypass','AutoConfigUrl')) {
        $session = New-RecoveryFixture; $script:failWrite=$true; $script:failField=$field
        Assert-Throws { Set-SessionProxy $session } ('Partial initial ' + $field + ' write must not publish running')
        $script:failWrite=$false
        Assert-True (Invoke-FixtureRecovery $session) ('Partial initial ' + $field + ' intent must remain recoverable')
        Assert-True (Test-SessionProxySettingsEqual $script:current $script:prior) ('Partial initial ' + $field + ' write must restore exact prior options')
    }
    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session
    $script:failWrite=$true; $script:failField='Server'
    Assert-Throws { Invoke-FixtureRecovery $session } 'Partial rollback itself must not acknowledge cleanup'
    Assert-True (-not (Read-FixtureState $session).cleanupConfirmed -and $script:current.Server -ceq $script:prior.Server -and $script:current.Flags -eq 3) 'A partial rollback leaves a durable pending target and no ACK'
    $script:failWrite=$false
    Assert-True (Invoke-FixtureRecovery $session) 'A second bounded recovery must resume the recorded rollback target'
    Assert-True (Test-SessionProxySettingsEqual $script:current $script:prior) 'Retry after partial rollback must finish all owned options'

    $session = New-RecoveryFixture; $owned = Set-SessionProxy $session
    $held=Open-SessionProxyRecoveryLock $session; $before=$script:writes
    try { Assert-Throws { Invoke-FixtureRecovery $session } 'Concurrent recovery transaction must not edit a held lease' }
    finally {$held.Dispose()}
    Assert-True ($script:writes -eq $before -and -not (Read-FixtureState $session).cleanupConfirmed) 'Exclusive journal lock must prevent concurrent write/ACK'

    Write-Host ('PASS ' + $script:passed + ' proxy recovery identity/journal/rollback checks (mock process/job/WinINet boundaries; temp files only)')
} finally {
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
