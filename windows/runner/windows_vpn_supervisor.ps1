param([string]$Request, [switch]$RecoverProxy)
# One supervisor owns one retained child handle. Recovery never kills by PID.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Assert-PlainPath([string]$Path) {
    $p = [IO.Path]::GetFullPath($Path)
    while ($p) {
        if (Test-Path -LiteralPath $p) {
            $item = Get-Item -LiteralPath $p -Force
            if (($item.Attributes -band [IO.FileAttributes]::ReparsePoint) -ne 0) {
                throw 'unsafe-path'
            }
        }
        $p = [IO.Path]::GetDirectoryName($p)
    }
}

function Write-SessionState($Session, [string]$Phase, [bool]$Confirmed) {
    Assert-PlainPath $Session.Directory
    $state = @{version=1; nonce=$Session.Nonce; phase=$Phase; cleanupConfirmed=$Confirmed;
        reasonCode=$Session.ReasonCode; coreExitCode=$Session.CoreExitCode;
        connectElapsedMs=$Session.ConnectElapsedMs}
    $tmp = Join-Path $Session.Directory 'state.tmp'
    $target = Join-Path $Session.Directory 'state.json'
    Assert-PlainPath $tmp
    Assert-PlainPath $target
    [IO.File]::WriteAllText($tmp, ($state | ConvertTo-Json -Compress), [Text.UTF8Encoding]::new($false))
    Move-Item -LiteralPath $tmp -Destination $target -Force
}

function Read-SupervisorRequest([string]$Path, [switch]$MetadataOnly) {
    Assert-PlainPath $Path
    $path = [IO.Path]::GetFullPath($Path)
    if ([IO.Path]::GetFileName($path) -cne 'request.json') { throw 'invalid-request' }
    $directory = [IO.Path]::GetDirectoryName($path)
    $nonce = [IO.Path]::GetFileName($directory)
    if ($nonce -cnotmatch '^[a-f0-9]{64}$') { throw 'invalid-request' }
    $data = Read-SessionBoundedJson $path 16384
    if (($data.version -isnot [int] -and $data.version -isnot [long]) -or $data.version -ne 1 -or $data.nonce -cne $nonce -or
        ($data.parentPid -isnot [int] -and $data.parentPid -isnot [long]) -or $data.parentPid -le 0 -or $data.parentPid -gt [int]::MaxValue -or
        $data.parentStartTicks -isnot [string] -or $data.parentStartTicks -notmatch '^\d{15,20}$' -or
        $data.tunnel -isnot [bool] -or ($data.httpPort -isnot [int] -and $data.httpPort -isnot [long]) -or
        $data.httpPort -lt 1 -or $data.httpPort -gt 65535) { throw 'invalid-request' }
    if ($data.tunnel -and (($data.brokerParentPid -isnot [int] -and $data.brokerParentPid -isnot [long]) -or $data.brokerParentPid -le 0 -or $data.brokerParentPid -gt [int]::MaxValue -or
        $data.brokerParentStartTicks -isnot [string] -or $data.brokerParentStartTicks -notmatch '^\d{15,20}$')) {
        throw 'invalid-request'
    }
    if ($null -ne $data.proxyIp) {
        $ip = $null
        if (-not [Net.IPAddress]::TryParse($data.proxyIp, [ref]$ip) -or
            $ip.AddressFamily -ne [Net.Sockets.AddressFamily]::InterNetwork) { throw 'invalid-request' }
    }
    $root = [IO.Path]::GetDirectoryName($directory)
    $pointerPath = Join-Path $root 'active.json'
    Assert-PlainPath $pointerPath
    $pointer = Read-SessionBoundedJson $pointerPath 16384
    if ($pointer.version -ne 1 -or $pointer.nonce -cne $nonce) { throw 'invalid-request' }
    $configPath = Join-Path $directory 'config.json'
    Assert-PlainPath $configPath
    if (-not $MetadataOnly) {
        $config = Get-Content -LiteralPath $configPath -Raw | ConvertFrom-Json
        if ($config.experimental.clash_api.secret -cne $nonce -or
            $config.experimental.clash_api.external_controller -cne '127.0.0.1:9090') { throw 'invalid-config' }
    }
    return [PSCustomObject]@{Nonce=$nonce; Directory=$directory; Data=$data; ConfigPath=$configPath;
        ProxyOwnership=$null; Recovery=$null; RecoveryLock=$null; ReasonCode='none'; CoreExitCode=$null; ConnectElapsedMs=$null}
}

function Test-SessionStop($Session) {
    $path = Join-Path $Session.Directory 'stop'
    Assert-PlainPath $path
    return (Test-Path -LiteralPath $path) -and
        ([IO.File]::ReadAllText($path) -ceq $Session.Nonce)
}

function Open-CapturedSessionProcess([int]$CapturedPid, [string]$CapturedBirth) {
    try {
        $p = [Diagnostics.Process]::GetProcessById($CapturedPid)
        $null = $p.Handle # Keep the original kernel object, not a reusable PID.
        if ($p.StartTime.ToUniversalTime().Ticks.ToString() -cne $CapturedBirth -or $p.HasExited) {
            $p.Dispose()
            return $null
        }
        return $p
    } catch { return $null }
}

function Open-SessionParent($Session) {
    return Open-CapturedSessionProcess $Session.Data.parentPid $Session.Data.parentStartTicks
}

function Test-BrokerParentExited($Process) {
    return $null -ne $Process -and $Process.HasExited
}

function Start-SessionChild($Session) {
    $core = Join-Path $PSScriptRoot 'sing-box.exe'
    Assert-PlainPath $core
    if (-not (Test-Path -LiteralPath $core -PathType Leaf)) { throw 'missing-core' }
    # Start-Process joins arrays; the configuration path must be explicitly quoted.
    $arguments = 'run -c "' + $Session.ConfigPath + '"'
    $proc = Start-Process -FilePath $core -ArgumentList $arguments -NoNewWindow -PassThru
    return $proc
}

function Stop-SessionChild($Process) {
    if ($null -eq $Process) { return }
    if (-not $Process.HasExited) { $Process.Kill() }
    if (-not $Process.WaitForExit(10000)) { throw 'child-stop-unconfirmed' }
}

function Test-SessionCore($Session) {
    foreach ($authorized in @($false, $true)) {
        $request = [Net.HttpWebRequest]::Create('http://127.0.0.1:9090/version')
        $request.Proxy = $null
        $request.Timeout = 1000
        $request.ReadWriteTimeout = 1000
        if ($authorized) { $request.Headers['Authorization'] = 'Bearer ' + $Session.Nonce }
        $response = $null
        try { $response = $request.GetResponse() }
        catch [Net.WebException] { $response = $_.Exception.Response }
        if ($null -eq $response) { return $false }
        try {
            $expected = if ($authorized) { 200 } else { 401 }
            if ([int]$response.StatusCode -ne $expected) { return $false }
            if ($authorized) {
                $stream = $response.GetResponseStream()
                $stream.ReadTimeout = 1000
                $buffer = [byte[]]::new(1024)
                $body = [IO.MemoryStream]::new()
                $readClock = [Diagnostics.Stopwatch]::StartNew()
                try {
                    while (($count = $stream.Read($buffer, 0, $buffer.Length)) -gt 0) {
                        if ($body.Length + $count -gt 4096 -or $readClock.ElapsedMilliseconds -gt 2000) { return $false }
                        $body.Write($buffer, 0, $count)
                    }
                    $value = [Text.Encoding]::UTF8.GetString($body.ToArray()) | ConvertFrom-Json
                    if ($value.version -isnot [string] -or $value.version -notmatch '^sing-box \d+\.\d+\.\d+(?:[-+][a-zA-Z0-9.\-]+)?$') { return $false }
                } catch { return $false }
                finally { $body.Dispose(); $stream.Dispose() }
            }
        } finally { $response.Dispose() }
    }
    return $true
}

function Add-SessionRoute($Session) {
    if (-not $Session.Data.tunnel -or $null -eq $Session.Data.proxyIp) { return $null }
    $allRoutes = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop)
    # InterfaceMetric belongs to MSFT_NetIPInterface, not the base route class.
    # Query the documented provider instead of relying on an implicit adapter.
    $interfaceMetrics = @{}
    foreach ($ipInterface in @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)) {
        $interfaceMetrics[[int]$ipInterface.InterfaceIndex] = [long]$ipInterface.InterfaceMetric
    }
    $gateway = $allRoutes |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' } |
        Sort-Object @{ Expression = {
            if (-not $interfaceMetrics.ContainsKey([int]$_.InterfaceIndex)) { throw 'missing-interface-metric' }
            [long]$_.RouteMetric + $interfaceMetrics[[int]$_.InterfaceIndex]
        } }, InterfaceIndex, NextHop | Select-Object -First 1
    if ($null -eq $gateway) { throw 'missing-gateway' }
    $prefix = $Session.Data.proxyIp + '/32'
    $existing = @($allRoutes |
        Where-Object { $_.DestinationPrefix -eq $prefix -and $_.InterfaceIndex -eq $gateway.InterfaceIndex -and $_.NextHop -eq $gateway.NextHop })
    # Never take ownership of a pre-existing route, including its metric.
    if ($existing.Count -gt 0) { return $null }
    # A host /32 wins over a default route regardless of this randomized metric.
    # The nonce-derived value also distinguishes a later ordinary replacement.
    $metric = 10000 + ([Convert]::ToInt32($Session.Nonce.Substring(0,4),16) % 40000)
    return New-NetRoute -DestinationPrefix $prefix -InterfaceIndex $gateway.InterfaceIndex -NextHop $gateway.NextHop -RouteMetric $metric -PolicyStore ActiveStore
}

function Remove-SessionRoute($Owned) {
    if ($null -eq $Owned) { return }
    $current = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.DestinationPrefix -eq $Owned.DestinationPrefix -and $_.InstanceID -ceq $Owned.InstanceID -and
            $_.InterfaceIndex -eq $Owned.InterfaceIndex -and $_.NextHop -eq $Owned.NextHop -and
            $_.RouteMetric -eq $Owned.RouteMetric })
    if ($current.Count -eq 1) { Remove-NetRoute -InputObject $current[0] -Confirm:$false -ErrorAction Stop }
}

function Initialize-SessionProxyApi {
    if ($null -eq ('HoneyProxyWinInet' -as [type])) {
        $source = Join-Path $PSScriptRoot 'windows_proxy_settings.cs'
        Assert-PlainPath $source
        Add-Type -LiteralPath $source
    }
    [HoneyProxyWinInet]::VerifyLayout()
}

function Invoke-SessionProxyNotification([int]$Option) {
    Initialize-SessionProxyApi
    return [HoneyProxyWinInet]::InternetSetOption([IntPtr]::Zero, $Option, [IntPtr]::Zero, 0)
}

function Send-SessionProxyChanged {
    # 39 rereads registry settings; 37 refreshes proxy data; 95 explicitly
    # alerts all WinINet instances, including browsers opened before the app.
    foreach ($option in @(39, 37, 95)) {
        if (-not (Invoke-SessionProxyNotification $option)) { throw 'proxy-notify-failed' }
    }
}

function Read-SessionProxySettings {
    Initialize-SessionProxyApi
    return [HoneyProxyWinInet]::Read()
}

function Write-SessionProxySettings($Settings) {
    Initialize-SessionProxyApi
    [HoneyProxyWinInet]::Write($Settings.Flags, $Settings.Server, $Settings.Bypass, $Settings.AutoConfigUrl)
}

function Test-SessionProxySettingsEqual($A, $B) {
    return $A.Flags -eq $B.Flags -and $A.Server -ceq $B.Server -and
        $A.Bypass -ceq $B.Bypass -and $A.AutoConfigUrl -ceq $B.AutoConfigUrl
}


# This record is per-user Proxy only. It is never a caller-supplied path or a
# SYSTEM restore instruction. Prior PAC/bypass values stay in private appdata.
function Get-SessionProxyOwnerSid {
    $identity = [Security.Principal.WindowsIdentity]::GetCurrent()
    try { return $identity.User.Value } finally { $identity.Dispose() }
}
function Get-SessionProxyJobName([string]$Nonce) {
    if ($Nonce -cnotmatch '\A[a-f0-9]{64}\z') { throw 'invalid-request' }
    $hash = [Security.Cryptography.SHA256]::Create()
    try {
        $digest = $hash.ComputeHash([Text.Encoding]::ASCII.GetBytes('HoneyVpnProxyJobV1:' + $Nonce))
        return 'Global\HoneyVpnProxyJobV1_' + [BitConverter]::ToString($digest).Replace('-', '').ToLowerInvariant()
    } finally { $hash.Dispose() }
}
function Write-SessionProxyRecovery($Session) {
    if ($null -eq $Session.Recovery -or $Session.Data.tunnel) { throw 'proxy-recovery-invalid' }
    $target = Join-Path $Session.Directory 'proxy-recovery.json'
    $temporary = Join-Path $Session.Directory 'proxy-recovery.tmp'
    Assert-PlainPath $target; Assert-PlainPath $temporary
    $bytes = [Text.UTF8Encoding]::new($false).GetBytes(($Session.Recovery | ConvertTo-Json -Compress -Depth 6))
    if ($bytes.Length -gt 65536) { throw 'proxy-recovery-invalid' }
    $stream = [IO.File]::Open($temporary, [IO.FileMode]::Create, [IO.FileAccess]::Write, [IO.FileShare]::None)
    try { $stream.Write($bytes, 0, $bytes.Length); $stream.Flush($true) } finally { $stream.Dispose() }
    if ([IO.File]::Exists($target)) { [IO.File]::Replace($temporary, $target, [System.Management.Automation.Language.NullString]::Value) }
    else { [IO.File]::Move($temporary, $target) }
    # Flush the committed name too: registry mutation must follow a durable
    # rollback record, not only a flushed temporary file awaiting rename.
    $committed = [IO.File]::Open($target, [IO.FileMode]::Open, [IO.FileAccess]::Write, [IO.FileShare]::Read)
    try { $committed.Flush($true) } finally { $committed.Dispose() }
}
function Open-SessionProxyRecoveryLock($Session) {
    $path = Join-Path $Session.Directory 'proxy-recovery.lock'
    Assert-PlainPath $path
    return [IO.File]::Open($path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
}
function New-SessionProxyRecoveryRecord($Session, [string]$JobName) {
    $self = [Diagnostics.Process]::GetCurrentProcess()
    try {
        return [PSCustomObject]@{Version=1; Nonce=$Session.Nonce; OwnerSid=(Get-SessionProxyOwnerSid);
            ParentPid=$Session.Data.parentPid; ParentStartTicks=$Session.Data.parentStartTicks;
            SupervisorPid=$self.Id; SupervisorStartTicks=$self.StartTime.ToUniversalTime().Ticks.ToString();
            ChildPolicy='supervisor-job-kill-on-close-v1'; JobName=$JobName;
            Stage='core-starting'; Prior=$null; Desired=$null; Applied=$false; RestoreTarget=$null}
    } finally { $self.Dispose() }
}
function Initialize-SessionProxyRecovery($Session) {
    if ($Session.Data.tunnel) { return }
    $Session.RecoveryLock = Open-SessionProxyRecoveryLock $Session
    Initialize-SessionProxyApi
    $name = [HoneyProxyProcessJob]::Initialize($Session.Nonce)
    $Session.Recovery = New-SessionProxyRecoveryRecord $Session $name
    # Journal and job both exist before any child starts or WinINet changes.
    Write-SessionProxyRecovery $Session
}
function Test-SessionProxyJobGone($Session) {
    Initialize-SessionProxyApi
    return [HoneyProxyProcessJob]::IsGone($Session.Nonce)
}
function Test-CapturedSessionProcessExited([int]$CapturedPid, [string]$CapturedBirth) {
    $process = $null
    try {
        $process = [Diagnostics.Process]::GetProcessById($CapturedPid)
        $null = $process.Handle # Retain identity; never kill or reopen by this PID.
        return $process.HasExited -or $process.StartTime.ToUniversalTime().Ticks.ToString() -cne $CapturedBirth
    } catch [ArgumentException] { return $true }
    catch { throw 'proxy-recovery-unavailable' }
    finally { if ($null -ne $process) { $process.Dispose() } }
}
function Read-SessionBoundedJson([string]$Path, [int]$MaximumBytes) {
    Assert-PlainPath $Path
    $stream = [IO.File]::Open($Path, [IO.FileMode]::Open, [IO.FileAccess]::Read, ([IO.FileShare]::Read -bor [IO.FileShare]::Delete))
    try {
        if ($stream.Length -le 0 -or $stream.Length -gt $MaximumBytes) { throw 'proxy-recovery-invalid' }
        $bytes = [byte[]]::new($MaximumBytes + 1); $total = 0
        while ($total -lt $bytes.Length) {
            $count = $stream.Read($bytes, $total, $bytes.Length - $total)
            if ($count -eq 0) { break }; $total += $count
        }
        if ($total -le 0 -or $total -gt $MaximumBytes) { throw 'proxy-recovery-invalid' }
        $text = [Text.UTF8Encoding]::new($false, $true).GetString($bytes, 0, $total)
        $value = $text | ConvertFrom-Json
        if ($null -eq $value -or $value -is [Array] -or @($value.PSObject.Properties).Count -gt 64) { throw 'proxy-recovery-invalid' }
        return $value
    } finally { $stream.Dispose() }
}
function Assert-SessionProxyDescriptor($Value) {
    if ($null -eq $Value -or $Value -is [Array] -or @($Value.PSObject.Properties).Count -ne 4 -or
        ($Value.Flags -isnot [int] -and $Value.Flags -isnot [long] -and $Value.Flags -isnot [uint32]) -or
        $Value.Flags -lt 0 -or $Value.Flags -gt 15) { throw 'proxy-recovery-invalid' }
    foreach ($field in @('Server','Bypass','AutoConfigUrl')) {
        if ($Value.$field -isnot [string] -or $Value.$field.Length -gt 4096 -or $Value.$field.Contains([char]0)) { throw 'proxy-recovery-invalid' }
    }
}
function Read-SessionProxyRecovery($Session) {
    $value = Read-SessionBoundedJson (Join-Path $Session.Directory 'proxy-recovery.json') 65536
    if (@($value.PSObject.Properties).Count -ne 14 -or ($value.Version -isnot [int] -and $value.Version -isnot [long]) -or $value.Version -ne 1 -or $value.Nonce -cne $Session.Nonce -or
        $value.OwnerSid -cne (Get-SessionProxyOwnerSid) -or
        ($value.ParentPid -isnot [int] -and $value.ParentPid -isnot [long]) -or $value.ParentPid -ne $Session.Data.parentPid -or $value.ParentStartTicks -cne $Session.Data.parentStartTicks -or
        ($value.SupervisorPid -isnot [int] -and $value.SupervisorPid -isnot [long]) -or $value.SupervisorPid -le 0 -or $value.SupervisorPid -gt [int]::MaxValue -or
        $value.SupervisorStartTicks -isnot [string] -or $value.SupervisorStartTicks -cnotmatch '^\d{15,20}$' -or
        $value.ChildPolicy -cne 'supervisor-job-kill-on-close-v1' -or
        $value.JobName -cne (Get-SessionProxyJobName $Session.Nonce) -or
        $value.Stage -cnotin @('core-starting','proxy-write-pending','proxy-active','restore-pending','proxy-restored') -or
        $value.Applied -isnot [bool]) { throw 'proxy-recovery-invalid' }
    if ($value.Stage -ceq 'core-starting') {
        if ($null -ne $value.Prior -or $null -ne $value.Desired -or $value.Applied -or $null -ne $value.RestoreTarget) { throw 'proxy-recovery-invalid' }
    } else {
        Assert-SessionProxyDescriptor $value.Prior; Assert-SessionProxyDescriptor $value.Desired
        if ($value.Desired.Flags -ne 3 -or $value.Desired.Server -cne ('127.0.0.1:' + $Session.Data.httpPort) -or
            $value.Desired.Bypass -cne '' -or $value.Desired.AutoConfigUrl -cne '') { throw 'proxy-recovery-invalid' }
        if ($value.Stage -ceq 'proxy-write-pending' -and $value.Applied) { throw 'proxy-recovery-invalid' }
        if ($value.Stage -cin @('proxy-active','restore-pending','proxy-restored') -and -not $value.Applied) { throw 'proxy-recovery-invalid' }
        if ($null -ne $value.RestoreTarget) {
            Assert-SessionProxyDescriptor $value.RestoreTarget
            if ($value.RestoreTarget.Server -cne $value.Prior.Server) { throw 'proxy-recovery-invalid' }
        }
        if ($value.Stage -ceq 'restore-pending' -and $null -eq $value.RestoreTarget) { throw 'proxy-recovery-invalid' }
    }
    return $value
}
function Invoke-WindowsVpnProxyRecovery([string]$RequestPath) {
    $session = Read-SupervisorRequest $RequestPath -MetadataOnly
    if ($session.Data.tunnel -or -not (Test-SessionStop $session)) { throw 'proxy-recovery-invalid' }
    $recordPath = Join-Path $session.Directory 'proxy-recovery.json'; Assert-PlainPath $recordPath
    # Earlier versions have no durable prior settings / job identity. Keep their
    # evidence and fail closed; a dead PID or listener absence is not an ACK.
    if (-not [IO.File]::Exists($recordPath)) { return $false }
    # A surviving owner already holds the exclusive lock and can consume stop.
    # Read a bounded atomic snapshot first so ordinary watchdog cleanup can ACK.
    $observed = Read-SessionProxyRecovery $session
    if (-not (Test-CapturedSessionProcessExited $observed.SupervisorPid $observed.SupervisorStartTicks)) { return $false }
    $lock = Open-SessionProxyRecoveryLock $session
    try {
        $session.Recovery = Read-SessionProxyRecovery $session
        if (-not (Test-CapturedSessionProcessExited $session.Data.parentPid $session.Data.parentStartTicks) -or
            -not (Test-CapturedSessionProcessExited $session.Recovery.SupervisorPid $session.Recovery.SupervisorStartTicks)) { return $false }
        if (-not (Test-SessionProxyJobGone $session)) { return $false }
        # Recheck the selected pointer inside the exclusive recovery transaction.
        $again = Read-SupervisorRequest $RequestPath -MetadataOnly
        if ($again.Nonce -cne $session.Nonce -or -not (Test-SessionStop $session)) { throw 'proxy-recovery-invalid' }
        if ($null -ne $session.Recovery.Prior) {
            $owned = [PSCustomObject]@{Prior=$session.Recovery.Prior; Desired=$session.Recovery.Desired;
                Applied=$session.Recovery.Applied; RestoreTarget=$session.Recovery.RestoreTarget}
            Restore-SessionProxy $owned $session
        }
        $session.ReasonCode = 'proxy-recovered'
        # This is a native ACK after proven job retirement and scoped restoration.
        Write-SessionState $session 'stopped' $true
        return $true
    } finally { $lock.Dispose() }
}

function Set-SessionProxy($Session) {
    if ($Session.Data.tunnel) { return $null }
    $prior = Read-SessionProxySettings
    # Manual LAN proxy only. Preserved PAC/WPAD/bypass choices cannot override
    # the selected server while this session owns the settings.
    $desired = [PSCustomObject]@{Flags=[uint32]3; Server=('127.0.0.1:' + $Session.Data.httpPort);
        Bypass=''; AutoConfigUrl=''}
    Assert-SessionProxyDescriptor $prior
    $owned = [PSCustomObject]@{Prior=$prior; Desired=$desired; Applied=$false; RestoreTarget=$null}
    $Session.ProxyOwnership = $owned
    if ($null -eq $Session.Recovery) { throw 'proxy-recovery-invalid' }
    $Session.Recovery.Prior = $prior; $Session.Recovery.Desired = $desired
    $Session.Recovery.Stage = 'proxy-write-pending'
    Write-SessionProxyRecovery $Session
    Write-SessionProxySettings $desired
    $owned.Applied = $true
    $Session.Recovery.Applied = $true; $Session.Recovery.Stage = 'proxy-active'
    Write-SessionProxyRecovery $Session
    Send-SessionProxyChanged
    if (-not (Test-SessionProxySettingsEqual (Read-SessionProxySettings) $desired)) { throw 'proxy-settings-overridden' }
    return $owned
}

function Restore-SessionProxy($Owned, $Session = $null) {
    if ($null -eq $Owned) { return }
    $current = Read-SessionProxySettings
    $pending = $null -ne $Owned.PSObject.Properties['RestoreTarget'] -and $null -ne $Owned.RestoreTarget
    # Another endpoint establishes a new owner. Even a retry never edits it.
    $endpointOwned = $current.Server -ceq $Owned.Desired.Server
    $partialWriteOnPriorEndpoint = -not $Owned.Applied -and $current.Server -ceq $Owned.Prior.Server
    $partialRestoreOnTargetEndpoint = $pending -and $current.Server -ceq $Owned.RestoreTarget.Server
    if (-not $endpointOwned -and -not $partialWriteOnPriorEndpoint -and -not $partialRestoreOnTargetEndpoint) { return }
    $restored = [PSCustomObject]@{Flags=$current.Flags; Server=$Owned.Prior.Server;
        Bypass=$current.Bypass; AutoConfigUrl=$current.AutoConfigUrl}
    foreach ($field in @('Flags','Bypass','AutoConfigUrl')) {
        if ($current.$field -ceq $Owned.Desired.$field) {
            $restored.$field = if ($pending) { $Owned.RestoreTarget.$field } else { $Owned.Prior.$field }
        }
    }
    if ($pending) { $restored.Server = $Owned.RestoreTarget.Server }
    if ($null -ne $Session) {
        $Owned.RestoreTarget = $restored
        $Session.Recovery.RestoreTarget = $restored
        $Session.Recovery.Applied = $true; $Session.Recovery.Stage = 'restore-pending'
        # Persist the exact rollback target before a possibly partial API write.
        Write-SessionProxyRecovery $Session
    }
    Write-SessionProxySettings $restored
    Send-SessionProxyChanged
    if (-not (Test-SessionProxySettingsEqual (Read-SessionProxySettings) $restored)) { throw 'proxy-restore-unconfirmed' }
    if ($null -ne $Session) {
        $Session.Recovery.Stage = 'proxy-restored'
        Write-SessionProxyRecovery $Session
    }
}

function Invoke-WindowsVpnSupervisor([string]$RequestPath) {
    $session = Read-SupervisorRequest $RequestPath
    $parent = $null; $brokerParent = $null; $child = $null; $route = $null; $proxy = $null
    $failed = $false; $cleanupConfirmed = $true
    $connectClock = [Diagnostics.Stopwatch]::StartNew()
    try {
        Write-SessionState $session 'launching' $false
        $parent = Open-SessionParent $session
        if ($null -eq $parent -or (Test-SessionStop $session)) { return }
        if ($session.Data.tunnel) {
            $brokerParent = Open-CapturedSessionProcess $session.Data.brokerParentPid $session.Data.brokerParentStartTicks
            if ($null -eq $brokerParent) { $session.ReasonCode = 'broker-exited'; return }
        }
        Initialize-SessionProxyRecovery $session
        $route = Add-SessionRoute $session
        # A delayed UAC approval must honor cancellation before starting the core.
        if ($parent.HasExited -or (Test-BrokerParentExited $brokerParent) -or (Test-SessionStop $session)) { return }
        $child = Start-SessionChild $session
        $null = $child.Handle # Retain the actual child even if handle acquisition fails.
        $startupClock = [Diagnostics.Stopwatch]::StartNew()
        $ready = $false
        while (-not $child.HasExited -and -not $parent.HasExited -and -not (Test-BrokerParentExited $brokerParent) -and -not (Test-SessionStop $session) -and $startupClock.ElapsedMilliseconds -lt 60000) {
            if (Test-SessionCore $session) { $ready = $true; break }
            Start-Sleep -Milliseconds 250
        }
        if (-not $ready -or $child.HasExited -or $parent.HasExited -or (Test-BrokerParentExited $brokerParent) -or (Test-SessionStop $session)) { throw 'start-failed' }
        $proxy = Set-SessionProxy $session
        if ($child.HasExited -or $parent.HasExited -or (Test-BrokerParentExited $brokerParent) -or (Test-SessionStop $session)) { throw 'start-cancelled' }
        $session.ConnectElapsedMs = $connectClock.ElapsedMilliseconds
        Write-SessionState $session 'running' $false
        while (-not $child.HasExited -and -not $parent.HasExited -and -not (Test-BrokerParentExited $brokerParent) -and -not (Test-SessionStop $session)) {
            Start-Sleep -Milliseconds 250
        }
        if ($child.HasExited) {
            $failed = $true
            $session.ReasonCode = 'core-exited'
            $session.CoreExitCode = $child.ExitCode
        } elseif ($parent.HasExited) { $session.ReasonCode = 'parent-exited' }
        elseif (Test-BrokerParentExited $brokerParent) { $session.ReasonCode = 'broker-exited' }
        else { $session.ReasonCode = 'cancelled' }
    } catch {
        $failed = $true
        # Exact application-owned codes only. Never persist arbitrary exception
        # text, which may contain config paths, node URLs or credentials.
        $safeCodes = @('unsafe-path','invalid-request','invalid-config','missing-core',
            'missing-gateway','missing-interface-metric','missing-proxy-settings',
            'proxy-notify-failed','proxy-settings-overridden','proxy-restore-unconfirmed',
            'proxy-query-failed','proxy-set-failed','proxy-abi-mismatch','proxy-job-failed',
            'proxy-job-unconfirmed','proxy-recovery-invalid','proxy-recovery-unavailable','start-failed','start-cancelled')
        $session.ReasonCode = if ($safeCodes -ccontains $_.Exception.Message) { $_.Exception.Message }
            else { 'supervisor-failed' }
        if ($null -ne $child -and $child.HasExited) { $session.CoreExitCode = $child.ExitCode }
        $session.ConnectElapsedMs = $connectClock.ElapsedMilliseconds
    }
    finally {
        if ($null -eq $proxy) { $proxy = $session.ProxyOwnership }
        try { Write-SessionState $session 'stopping' $false } catch { $cleanupConfirmed = $false }
        try { Stop-SessionChild $child } catch { $cleanupConfirmed = $false }
        try { Restore-SessionProxy $proxy $(if($session.Data.tunnel){$null}else{$session}) } catch { $cleanupConfirmed = $false }
        try { Remove-SessionRoute $route } catch { $cleanupConfirmed = $false }
        if ($null -ne $child) { $child.Dispose() }
        if ($null -ne $parent) { $parent.Dispose() }
        if ($null -ne $brokerParent) { $brokerParent.Dispose() }
        # This is the only acknowledgement accepted by Dart recovery/stop.
        try { Write-SessionState $session $(if($failed){'failed'}else{'stopped'}) $cleanupConfirmed } catch {}
        if ($null -ne $session.RecoveryLock) { $session.RecoveryLock.Dispose() }
    }
}

# Dot-sourcing exposes the exact production functions to the dummy-process CI
# harness, which replaces network/route/proxy boundaries, never system settings.
if ($MyInvocation.InvocationName -ne '.') {
    if ($RecoverProxy) { $null = Invoke-WindowsVpnProxyRecovery $Request }
    else { Invoke-WindowsVpnSupervisor $Request }
}
