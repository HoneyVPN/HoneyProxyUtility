param([string]$Supervisor = (Join-Path $PSScriptRoot '../../windows/runner/windows_vpn_supervisor.ps1'))
$ErrorActionPreference = 'Stop'
. $Supervisor
function Assert-True([bool]$Condition, [string]$Message) {
    if (-not $Condition) { throw $Message }
}
function Assert-Throws([scriptblock]$Action, [string]$Message) {
    $thrown = $false
    try { & $Action | Out-Null } catch { $thrown = $true }
    Assert-True $thrown $Message
}

$root = Join-Path ([IO.Path]::GetTempPath()) ('honeyproxy-supervisor-tests-' + [Guid]::NewGuid().ToString('N'))
$link = Join-Path $root 'junction'
New-Item -ItemType Directory -Path $root | Out-Null
$script:children = [Collections.Generic.List[Diagnostics.Process]]::new()
$script:parents = [Collections.Generic.List[Diagnostics.Process]]::new()
function New-DummyProcess([int]$Seconds) {
    $process = Start-Process powershell.exe -ArgumentList "-NoProfile -NonInteractive -Command Start-Sleep -Seconds $Seconds" -PassThru -WindowStyle Hidden
    $null = $process.Handle
    return $process
}
function New-Fixture($Parent, [bool]$Tunnel = $true, $BrokerParent = $null) {
    $nonce = [Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N')
    $directory = Join-Path $root $nonce
    New-Item -ItemType Directory -Path $directory | Out-Null
    $data = @{version=1; nonce=$nonce; parentPid=$Parent.Id;
        parentStartTicks=$Parent.StartTime.ToUniversalTime().Ticks.ToString();
        tunnel=$Tunnel; httpPort=2081; proxyIp='192.0.2.10'}
    if ($Tunnel) {
        if ($null -eq $BrokerParent) { $BrokerParent = [Diagnostics.Process]::GetCurrentProcess() }
        $data.brokerParentPid = $BrokerParent.Id
        $data.brokerParentStartTicks = $BrokerParent.StartTime.ToUniversalTime().Ticks.ToString()
    }
    $fixtureRequestPath = Join-Path $directory 'request.json'
    [IO.File]::WriteAllText($fixtureRequestPath, ($data | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $root 'active.json'), (@{version=1; nonce=$nonce} | ConvertTo-Json -Compress))
    [IO.File]::WriteAllText((Join-Path $directory 'config.json'), (@{experimental=@{clash_api=@{secret=$nonce; external_controller='127.0.0.1:9090'}}} | ConvertTo-Json -Depth 5 -Compress))
    $parsed = Read-SupervisorRequest $fixtureRequestPath
    if (-not $Tunnel) {
        # This harness mocks proxy/process boundaries; no real recovery job is
        # created by these fixtures. The dedicated recovery harness exercises it.
        $parsed.Recovery = New-SessionProxyRecoveryRecord $parsed (Get-SessionProxyJobName $nonce)
        Write-SessionProxyRecovery $parsed
    }
    return $parsed
}

try {
    # Actual marshaling/provider contract, read-only: never call Write or the
    # notification API on real settings. Do not print server/PAC/bypass values.
    Initialize-SessionProxyApi
    $nativeProxy = Read-SessionProxySettings
    Assert-True ($nativeProxy.Flags -is [uint32]) 'Native proxy flags must be DWORD'
    Assert-True ($nativeProxy.Server -is [string] -and $nativeProxy.Bypass -is [string] -and $nativeProxy.AutoConfigUrl -is [string]) 'Native proxy strings must marshal without exposing their contents'
    Write-Host 'PASS native read-only WinINet layout/PAC/WPAD/manual settings query'
    # Read-only real provider contract, before the route/registry mocks below.
    # No route is added, changed, or removed by this probe.
    $nativeGateways = @(Get-NetRoute -AddressFamily IPv4 -ErrorAction Stop |
        Where-Object { $_.DestinationPrefix -eq '0.0.0.0/0' -and $_.NextHop -ne '0.0.0.0' })
    if ($nativeGateways.Count -eq 0) {
        Write-Host 'SKIP native IPv4 gateway metric contract: VM has no gateway; physical TUN QA still required.'
    } else {
        $nativeInterfaces = @(Get-NetIPInterface -AddressFamily IPv4 -ErrorAction Stop)
        foreach ($gateway in $nativeGateways) {
            Assert-True ($null -ne $gateway.PSObject.Properties['InstanceID']) 'Route identity property must be exposed by the native provider'
            $matching = @($nativeInterfaces | Where-Object { $_.InterfaceIndex -eq $gateway.InterfaceIndex })
            Assert-True ($matching.Count -eq 1) 'Default gateway must have one matching IPv4 IP interface'
            Assert-True ($null -ne $matching[0].PSObject.Properties['InterfaceMetric']) 'Native IP-interface metric contract must exist'
            Assert-True ([long]$matching[0].InterfaceMetric -ge 0) 'Native IP-interface metric must be nonnegative'
        }
        Write-Host 'PASS native read-only Get-NetRoute/Get-NetIPInterface metric/identity contract'
    }
    $self = [Diagnostics.Process]::GetCurrentProcess()
    $session = New-Fixture $self
    $parent = Open-SessionParent $session
    Assert-True ($null -ne $parent) 'Exact parent creation identity should match'
    $parent.Dispose()
    $session.Data.parentStartTicks = '638000000000000000'
    Assert-True ($null -eq (Open-SessionParent $session)) 'Reused PID/different creation time must not match'
    [IO.File]::WriteAllText((Join-Path $session.Directory 'stop'), 'foreign-nonce')
    Assert-True (-not (Test-SessionStop $session)) 'Foreign cancellation token must be ignored'
    [IO.File]::WriteAllText((Join-Path $session.Directory 'stop'), $session.Nonce)
    Assert-True (Test-SessionStop $session) 'Owned cancellation token must be recognized'
    $linkTarget = Join-Path $root 'link-target'
    New-Item -ItemType Directory -Path $linkTarget | Out-Null
    [IO.File]::WriteAllText((Join-Path $linkTarget 'fixture.json'), '{}')
    New-Item -ItemType Junction -Path $link -Target $linkTarget | Out-Null
    Assert-Throws { Assert-PlainPath (Join-Path $link 'config.json') } 'Junction/reparse escapes must be rejected'
    Assert-True (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Fixture cleanup refuses a non-junction directory'
    [IO.Directory]::Delete($link, $false)
    Assert-True (-not (Test-Path -LiteralPath $link)) 'The owned junction must be removed'
    Assert-True ([IO.File]::ReadAllText((Join-Path $linkTarget 'fixture.json')) -ceq '{}') 'Junction cleanup must preserve target contents'
    Write-Host 'PASS noninteractive junction cleanup preserves target contents'
    Write-Host 'PASS request identity, nonce cancellation, reparse rejection'

    # Actual production readiness against a bounded loopback dummy HTTP core.
    # TcpListener needs no URL ACL, registry changes, administrator/UAC or VPN.
    $serverScript = Join-Path $root 'dummy-core.ps1'
    @'
param([string]$Nonce,[string]$ModeFile,[string]$ReadyFile)
$listener=[Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback,9090)
$listener.Start()
[IO.File]::WriteAllText($ReadyFile,'ready')
try {
  while($true) {
    $client=$listener.AcceptTcpClient()
    try {
      $stream=$client.GetStream();$stream.ReadTimeout=2000
      $reader=[IO.StreamReader]::new($stream,[Text.Encoding]::ASCII,$false,1024,$true)
      $authorized=$false
      while(($line=$reader.ReadLine()) -ne '') {
        if($null -eq $line){break}
        if($line -ceq ('Authorization: Bearer '+$Nonce)){$authorized=$true}
      }
      $mode=[IO.File]::ReadAllText($ModeFile).Trim()
      $status=if($authorized){200}else{401}
      $body='{"version":"sing-box 1.13.12-extended-2.1.2"}'
      if($mode -eq 'foreign'){$status=200}
      if($mode -eq 'malformed'){$body='{"version":42}'}
      if($mode -eq 'oversized'){$body='x'*5000}
      if($mode -eq 'nonJSON'){$body='not a JSON version packet'}
      $bytes=[Text.Encoding]::UTF8.GetBytes($body)
      $header=[Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $status OK`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n")
      $stream.Write($header,0,$header.Length);$stream.Write($bytes,0,$bytes.Length);$stream.Flush()
      $reader.Dispose()
    } catch [IO.IOException] {
      # Rejecting an oversized response may close the owned client's stream.
      # Keep the same dummy listener available for the next isolated case.
    } finally {$client.Dispose()}
  }
} finally {$listener.Stop()}
'@ | Set-Content -LiteralPath $serverScript -Encoding UTF8
    $modeFile = Join-Path $root 'http-mode.txt'
    $readyFile = Join-Path $root 'http-ready'
    [IO.File]::WriteAllText($modeFile, 'valid')
    $serverArguments = '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' + $serverScript + '" -Nonce ' + $session.Nonce + ' -ModeFile "' + $modeFile + '" -ReadyFile "' + $readyFile + '"'
    $server = Start-Process powershell.exe -ArgumentList $serverArguments -PassThru -WindowStyle Hidden
    $null = $server.Handle
    $script:children.Add($server)
    try {
        $deadline = [DateTime]::UtcNow.AddSeconds(5)
        while (-not (Test-Path -LiteralPath $readyFile) -and -not $server.HasExited -and [DateTime]::UtcNow -lt $deadline) { Start-Sleep -Milliseconds 50 }
        Assert-True (Test-Path -LiteralPath $readyFile) 'Dummy loopback server must start'
        foreach ($mode in @('valid','foreign','malformed','oversized','nonJSON')) {
            [IO.File]::WriteAllText($modeFile, $mode)
            $ready = Test-SessionCore $session
            Assert-True ($ready -eq ($mode -eq 'valid')) ('Readiness must reject ' + $mode + ' response')
            Write-Host ('PASS actual HTTP readiness mode: ' + $mode)
        }
        [IO.File]::WriteAllText($modeFile, 'valid')
        $wrongNonce = [PSCustomObject]@{Nonce=([Guid]::NewGuid().ToString('N') + [Guid]::NewGuid().ToString('N'))}
        Assert-True (-not (Test-SessionCore $wrongNonce)) 'Wrong session nonce must be rejected by the actual HTTP probe'
        Write-Host 'PASS actual HTTP readiness rejects another session nonce'
    } finally {
        if (-not $server.HasExited) { $server.Kill() }
        Assert-True ($server.WaitForExit(5000)) 'Owned dummy listener must exit before the next phase'
    }

    # Exercise the production route-ownership functions with in-memory cmdlets.
    $script:existing = @()
    $script:newRoutes = 0; $script:removedRoutes = 0
    $script:gateway = [PSCustomObject]@{DestinationPrefix='0.0.0.0/0'; InterfaceIndex=7; NextHop='192.0.2.1'; RouteMetric=10}
    $script:gateway2 = [PSCustomObject]@{DestinationPrefix='0.0.0.0/0'; InterfaceIndex=11; NextHop='192.0.2.254'; RouteMetric=1}
    function Get-NetRoute { param($DestinationPrefix, $AddressFamily, $ErrorAction)
        return @($script:gateway,$script:gateway2) + $script:existing
    }
    function Get-NetIPInterface { param($AddressFamily, $ErrorAction)
        return @([PSCustomObject]@{InterfaceIndex=7; InterfaceMetric=5},
            [PSCustomObject]@{InterfaceIndex=11; InterfaceMetric=80})
    }
    function New-NetRoute { param($DestinationPrefix, $InterfaceIndex, $NextHop, $RouteMetric, $PolicyStore)
        $script:newRoutes++
        return [PSCustomObject]@{DestinationPrefix=$DestinationPrefix; InterfaceIndex=$InterfaceIndex;
            NextHop=$NextHop; RouteMetric=$RouteMetric; InstanceID='owned-route-1'}
    }
    function Remove-NetRoute { param($InputObject, $Confirm, $ErrorAction) $script:removedRoutes++ }
    $session = New-Fixture $self
    $ownedRoute = Add-SessionRoute $session
    Assert-True ($script:newRoutes -eq 1) 'Missing route should be created once'
    Assert-True ($ownedRoute.InterfaceIndex -eq 7) 'Gateway selection must include explicit interface metric, not route metric alone'
    $script:existing = @($ownedRoute)
    Assert-True ($null -eq (Add-SessionRoute $session)) 'Pre-existing route must not be claimed'
    $replacement = [PSCustomObject]@{DestinationPrefix=$ownedRoute.DestinationPrefix; InterfaceIndex=7;
        NextHop='192.0.2.1'; RouteMetric=25; InstanceID='owned-route-1'}
    $script:existing = @($replacement)
    Remove-SessionRoute $ownedRoute
    Assert-True ($script:removedRoutes -eq 0) 'Modified/foreign route must survive cleanup'
    $script:existing = @($ownedRoute)
    Remove-SessionRoute $ownedRoute
    Assert-True ($script:removedRoutes -eq 1) 'Exact owned route must be removed'
    Write-Host 'PASS pre-existing/replaced/owned route isolation (mock cmdlets only)'

    # Production WinINet apply/compare/restore with a fake options provider.
    # No real system settings are changed by this harness.
    $script:notifications = @()
    $script:notificationSucceeds = $true
    function Invoke-SessionProxyNotification([int]$Option) {
        $script:notifications += $Option
        return $script:notificationSucceeds
    }
    Send-SessionProxyChanged
    Assert-True (($script:notifications -join ',') -eq '39,37,95') 'Registry change must notify and refresh every WinINet instance'
    $script:notificationSucceeds = $false
    Assert-Throws { Send-SessionProxyChanged } 'Failed browser cache notification must fail startup'
    $script:notificationSucceeds = $true
    function Copy-FakeSettings($Settings) {
        return [PSCustomObject]@{Flags=$Settings.Flags; Server=$Settings.Server;
            Bypass=$Settings.Bypass; AutoConfigUrl=$Settings.AutoConfigUrl}
    }
    $script:priorSettings = [PSCustomObject]@{Flags=[uint32]13; Server='corporate.example:8080';
        Bypass='*.example;<local>'; AutoConfigUrl='https://pac.example.test/config.pac'}
    $script:currentSettings = Copy-FakeSettings $script:priorSettings
    $script:writePartial = $false
    $script:partialField = 'Server'
    $script:writes = 0
    function Read-SessionProxySettings { return Copy-FakeSettings $script:currentSettings }
    function Write-SessionProxySettings($Settings) {
        $script:writes++
        if ($script:writePartial) {
            $script:currentSettings.($script:partialField) = $Settings.($script:partialField)
            throw 'proxy-set-failed'
        }
        $script:currentSettings = Copy-FakeSettings $Settings
    }
    $proxySession = New-Fixture $self $false
    $script:notifications = @()
    $ownedProxy = Set-SessionProxy $proxySession
    Assert-True ($script:currentSettings.Flags -eq 3 -and $script:currentSettings.Server -eq '127.0.0.1:2081') 'Selected manual proxy must be active before publishing running'
    Assert-True ($script:currentSettings.Bypass -eq '' -and $script:currentSettings.AutoConfigUrl -eq '') 'Previous bypass and PAC must not override the selected proxy'
    Assert-True (($script:notifications -join ',') -eq '39,37,95') 'Proxy apply must notify already-open browsers'
    Restore-SessionProxy $ownedProxy
    Assert-True (($script:notifications -join ',') -eq '39,37,95,39,37,95') 'Owned restoration must also refresh browser cache'
    Assert-True (Test-SessionProxySettingsEqual $script:currentSettings $script:priorSettings) 'Restore must preserve complete prior PAC/WPAD/bypass/manual settings'

    foreach ($field in @('Server','Bypass','AutoConfigUrl','Flags')) {
        $script:currentSettings = Copy-FakeSettings $script:priorSettings
        $proxySession = New-Fixture $self $false
        $ownedProxy = Set-SessionProxy $proxySession
        if ($field -eq 'Flags') { $script:currentSettings.Flags = [uint32]9 }
        else { $script:currentSettings.$field = 'later-user-setting' }
        $foreign = Copy-FakeSettings $script:currentSettings
        $before = $script:writes
        Restore-SessionProxy $ownedProxy
        if ($field -eq 'Server') {
            Assert-True ($script:writes -eq $before -and (Test-SessionProxySettingsEqual $script:currentSettings $foreign)) 'Foreign proxy endpoint and its configuration must survive'
        } else {
            Assert-True ($script:currentSettings.$field -ceq $foreign.$field) ('Foreign ' + $field + ' choice must survive')
            Assert-True ($script:currentSettings.Server -eq $script:priorSettings.Server) 'A metadata-only change must not leave the dead owned endpoint enabled'
            if ($field -ne 'Flags') { Assert-True ($script:currentSettings.Flags -eq $script:priorSettings.Flags) 'Still-owned manual-proxy flags must be restored' }
        }
    }
    foreach ($field in @('Flags','Server','Bypass','AutoConfigUrl')) {
        $script:currentSettings = Copy-FakeSettings $script:priorSettings
        $script:writePartial = $true
        $script:partialField = $field
        $proxySession = New-Fixture $self $false
        Assert-Throws { Set-SessionProxy $proxySession } 'Partial option write must not confirm startup'
        Assert-True ($null -ne $proxySession.ProxyOwnership) 'Partial write must retain its cleanup owner'
        $script:writePartial = $false
        Restore-SessionProxy $proxySession.ProxyOwnership
        Assert-True (Test-SessionProxySettingsEqual $script:currentSettings $script:priorSettings) ('Partial ' + $field + ' API write must roll back owned options')
    }

    $script:currentSettings = Copy-FakeSettings $script:priorSettings
    $script:notificationSucceeds = $false
    $proxySession = New-Fixture $self $false
    Assert-Throws { Set-SessionProxy $proxySession } 'Notification failure must not confirm startup'
    $script:notificationSucceeds = $true
    Restore-SessionProxy $proxySession.ProxyOwnership
    Assert-True (Test-SessionProxySettingsEqual $script:currentSettings $script:priorSettings) 'Notification failure must still restore the retained prior settings'
    Write-Host 'PASS PAC/WPAD/bypass apply+restore, WinINet notifications, partial-write rollback and foreign-option isolation (mock API only)'

    # The following lifecycle tests execute only unprivileged sleep processes.
    # Override every route/proxy/network boundary before calling the supervisor.
    $script:routesCleaned = 0; $script:proxiesRestored = 0; $script:childStarts = 0
    function Initialize-SessionProxyRecovery($Session) { }
    function Add-SessionRoute($Session) { return [PSCustomObject]@{Owned=$true} }
    function Remove-SessionRoute($Owned) { if ($null -ne $Owned) { $script:routesCleaned++ } }
    function Set-SessionProxy($Session) { return [PSCustomObject]@{Owned=$true} }
    function Restore-SessionProxy($Owned) { if ($null -ne $Owned) { $script:proxiesRestored++ } }
    function Test-SessionCore($Session) { return $true }
    function Start-SessionChild($Session) {
        $child = New-DummyProcess 60
        $script:children.Add($child)
        $script:childStarts++
        return $child
    }

    $session = New-Fixture $self
    [IO.File]::WriteAllText((Join-Path $session.Directory 'stop'), $session.Nonce)
    Invoke-WindowsVpnSupervisor (Join-Path $session.Directory 'request.json')
    $state = Get-Content -LiteralPath (Join-Path $session.Directory 'state.json') -Raw | ConvertFrom-Json
    Assert-True ($script:childStarts -eq 0 -and $state.cleanupConfirmed -and $state.phase -eq 'stopped') 'Late approval after cancellation must never start child'
    Write-Host 'PASS delayed-launch cancellation starts no child'

    $parent = New-DummyProcess 2; $script:parents.Add($parent)
    $session = New-Fixture $parent $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    Invoke-WindowsVpnSupervisor (Join-Path $session.Directory 'request.json')
    $state = Get-Content -LiteralPath (Join-Path $session.Directory 'state.json') -Raw | ConvertFrom-Json
    Assert-True ($state.cleanupConfirmed -and $state.phase -eq 'stopped') 'Parent death must produce confirmed cleanup'
    Assert-True ($script:childStarts -eq 1 -and $script:routesCleaned -eq 1 -and $script:proxiesRestored -eq 1) 'Parent death must clean only owned resources'
    Assert-True ($watch.Elapsed.TotalSeconds -lt 15) 'Parent-death cleanup must be bounded'
    Assert-True ($state.reasonCode -eq 'parent-exited' -and $state.connectElapsedMs -ge 0) 'Parent death must preserve credential-free reason and connection timing'
    Write-Host 'PASS retained-handle child cleanup after parent exit'

    $brokerParent = New-DummyProcess 2; $script:parents.Add($brokerParent)
    $session = New-Fixture $self $true $brokerParent
    $before = $script:childStarts
    Invoke-WindowsVpnSupervisor (Join-Path $session.Directory 'request.json')
    $state = Get-Content -LiteralPath (Join-Path $session.Directory 'state.json') -Raw | ConvertFrom-Json
    Assert-True ($script:childStarts -eq $before + 1 -and $state.cleanupConfirmed -and $state.reasonCode -eq 'broker-exited') 'Service death must stop the retained child and confirm scoped cleanup even while GUI parent lives'
    Write-Host 'PASS retained broker-parent watchdog cleanup while GUI remains alive'

    # A stop failure cannot publish a cleanup acknowledgement.
    function Stop-SessionChild($Process) { throw 'injected-stop-failure' }
    $session = New-Fixture $self
    [IO.File]::WriteAllText((Join-Path $session.Directory 'stop'), $session.Nonce)
    Invoke-WindowsVpnSupervisor (Join-Path $session.Directory 'request.json')
    $state = Get-Content -LiteralPath (Join-Path $session.Directory 'state.json') -Raw | ConvertFrom-Json
    Assert-True (-not $state.cleanupConfirmed) 'Failed cleanup must not acknowledge stop'
    Write-Host 'PASS injected cleanup failure never claims stopped/clean'
    Write-Host 'Windows supervisor fault harness passed (no VPN/UAC/registry/route changes).'
} finally {
    foreach ($process in @($script:children.ToArray()) + @($script:parents.ToArray())) {
        try { if (-not $process.HasExited) { $process.Kill() }; $null=$process.WaitForExit(5000) } catch {}
        try { $process.Dispose() } catch {}
    }
    if (Test-Path -LiteralPath $link) {
        Assert-True (([IO.File]::GetAttributes($link) -band [IO.FileAttributes]::ReparsePoint) -ne 0) 'Fixture cleanup refuses a non-junction directory'
        [IO.Directory]::Delete($link, $false)
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
