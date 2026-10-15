param([string]$Helper = (Join-Path $PSScriptRoot '../../windows/runner/windows_proxy_settings.cs'))
$ErrorActionPreference='Stop';Set-StrictMode -Version Latest
if([Environment]::OSVersion.Platform -ne [PlatformID]::Win32NT -or -not [Environment]::Is64BitProcess){throw 'Windows x64 is required for the actual Job Object test'}
Add-Type -LiteralPath $Helper
# Native fixture reads the actual job's owner/DACL; it never changes a descriptor.
Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
using System.Security.AccessControl;
using System.Security.Principal;
public static class HoneyJobSecurityFixture {
 [DllImport("kernel32.dll",CharSet=CharSet.Unicode,SetLastError=true)]
 private static extern IntPtr OpenJobObjectW(uint access,bool inherit,string name);
 [DllImport("advapi32.dll",SetLastError=true)]
 [return:MarshalAs(UnmanagedType.Bool)]
 private static extern bool GetKernelObjectSecurity(IntPtr handle,uint information,[Out]byte[] descriptor,uint length,out uint required);
 [DllImport("kernel32.dll")]
 [return:MarshalAs(UnmanagedType.Bool)]
 private static extern bool CloseHandle(IntPtr handle);
 public static bool Trusted(string name) {
  IntPtr job=OpenJobObjectW(0x00020000,false,name); // READ_CONTROL only.
  if(job==IntPtr.Zero)throw new InvalidOperationException("fixture-job-security-unavailable");
  try {
   uint required; GetKernelObjectSecurity(job,5,null,0,out required);
   if(required==0||required>32768||Marshal.GetLastWin32Error()!=122)throw new InvalidOperationException("fixture-job-security-unavailable");
   byte[] buffer=new byte[required];
   if(!GetKernelObjectSecurity(job,5,buffer,required,out required))throw new InvalidOperationException("fixture-job-security-unavailable");
   RawSecurityDescriptor value=new RawSecurityDescriptor(buffer,0);
   SecurityIdentifier user;
   using(WindowsIdentity identity=WindowsIdentity.GetCurrent()){user=identity.User;}
   SecurityIdentifier system=new SecurityIdentifier(WellKnownSidType.LocalSystemSid,null);
   if(!user.Equals(value.Owner)||(value.ControlFlags&ControlFlags.DiscretionaryAclProtected)==0||value.DiscretionaryAcl==null)return false;
   bool userAllowed=false,systemAllowed=false;
   foreach(GenericAce item in value.DiscretionaryAcl){
    CommonAce ace=item as CommonAce;
    if(ace==null||ace.AceQualifier!=AceQualifier.AccessAllowed||ace.AceFlags!=AceFlags.None||
      (!user.Equals(ace.SecurityIdentifier)&&!system.Equals(ace.SecurityIdentifier)))return false;
    if(user.Equals(ace.SecurityIdentifier))userAllowed=true;
    if(system.Equals(ace.SecurityIdentifier))systemAllowed=true;
   }
   return userAllowed&&systemAllowed;
  }finally{CloseHandle(job);}
 }
}
'@
$script:passed=0
function Assert-True([bool]$Value,[string]$Message){if(-not$Value){throw$Message};$script:passed++}
$root=Join-Path ([IO.Path]::GetTempPath()) ('honey-proxy-job-tests-'+[Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $root | Out-Null
$owner=$null;$child=$null;$collision=$null
try {
    $nonce=[Guid]::NewGuid().ToString('N')+[Guid]::NewGuid().ToString('N')
    Assert-True ([HoneyProxyProcessJob]::IsGone($nonce)) 'A fresh nonce must have no named job before its owned fixture starts'
    $ownerScript=Join-Path $root 'owner.ps1';$ready=Join-Path $root 'ready.json'
    @'
param([string]$Helper,[string]$Nonce,[string]$Ready)
$ErrorActionPreference='Stop'
Add-Type -LiteralPath $Helper
$null=[HoneyProxyProcessJob]::Initialize($Nonce)
$exe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
# Same direct CreateProcess behavior as the real core: no ShellExecute/breakaway.
$child=Start-Process -FilePath $exe -ArgumentList '-NoProfile -NonInteractive -Command Start-Sleep -Seconds 60' -NoNewWindow -PassThru
try {
 $null=$child.Handle
 [IO.File]::WriteAllText($Ready,(@{Pid=$child.Id;Birth=$child.StartTime.ToUniversalTime().Ticks.ToString()}|ConvertTo-Json -Compress),[Text.UTF8Encoding]::new($false))
 Start-Sleep -Seconds 60
}finally{$child.Dispose()}
'@ | Set-Content -LiteralPath $ownerScript -Encoding UTF8
    $exe=[Diagnostics.Process]::GetCurrentProcess().MainModule.FileName
    $arguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$ownerScript+'" -Helper "'+[IO.Path]::GetFullPath($Helper)+'" -Nonce '+$nonce+' -Ready "'+$ready+'"'
    $owner=Start-Process -FilePath $exe -ArgumentList $arguments -PassThru -WindowStyle Hidden
    $null=$owner.Handle # Keep the process object returned by this test's creation.
    $clock=[Diagnostics.Stopwatch]::StartNew()
    while(-not[IO.File]::Exists($ready)-and-not$owner.HasExited-and$clock.ElapsedMilliseconds-lt10000){Start-Sleep -Milliseconds 50}
    Assert-True ([IO.File]::Exists($ready)-and-not$owner.HasExited) 'Owned dummy supervisor and its inherited child must start'
    Assert-True (-not[HoneyProxyProcessJob]::IsGone($nonce)) 'A live supervisor must retain its exact named Job Object'
    Assert-True ([HoneyJobSecurityFixture]::Trusted([HoneyProxyProcessJob]::NameFor($nonce))) 'Actual named Job DACL must be protected and allow only its creator SID and SYSTEM'
    $collisionScript=Join-Path $root 'collision.ps1'
    @'
param([string]$Helper,[string]$Nonce)
$ErrorActionPreference='Stop';Add-Type -LiteralPath $Helper
try{$null=[HoneyProxyProcessJob]::Initialize($Nonce);exit 88}
catch{if($_.Exception.GetBaseException().Message-ceq'proxy-job-failed'){exit 0};exit 89}
'@ | Set-Content -LiteralPath $collisionScript -Encoding UTF8
    $collisionArguments='-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "'+$collisionScript+'" -Helper "'+[IO.Path]::GetFullPath($Helper)+'" -Nonce '+$nonce
    $collision=Start-Process -FilePath $exe -ArgumentList $collisionArguments -PassThru -WindowStyle Hidden
    $null=$collision.Handle
    Assert-True ($collision.WaitForExit(10000)-and$collision.ExitCode-eq0) 'Existing job-name collision must fail before applying limits or assigning another process'
    Assert-True (-not$owner.HasExited-and-not[HoneyProxyProcessJob]::IsGone($nonce)) 'Refused collision must preserve the original supervisor/job lifetime'

    if((Get-Item -LiteralPath $ready).Length-gt1024){throw 'dummy metadata bound exceeded'}
    $value=[IO.File]::ReadAllText($ready)|ConvertFrom-Json
    if(($value.Pid-isnot[int]-and$value.Pid-isnot[long])-or$value.Pid-le0-or$value.Pid-gt[int]::MaxValue-or$value.Birth-isnot[string]-or$value.Birth-cnotmatch'^\d{15,20}$'){throw 'invalid dummy identity'}
    $observedChild=$null
    try {
        $observedChild=[Diagnostics.Process]::GetProcessById([int]$value.Pid);$null=$observedChild.Handle
        if($observedChild.HasExited-or$observedChild.StartTime.ToUniversalTime().Ticks.ToString()-cne$value.Birth){throw 'Dummy child identity changed; no kill target retained'}
        # A process opened from metadata is only a cleanup target after exact
        # birth identity matches. A rejected replacement is merely disposed.
        $child=$observedChild;$observedChild=$null
    }finally{if($null-ne$observedChild){$observedChild.Dispose()}}
    Assert-True ($null-ne$child) 'Retain the exact fixture child before fault injection; a PID alone is insufficient'
    # The only intentional termination targets are the captured processes created
    # by this isolated test. No production PID, service, VPN or settings are used.
    $owner.Kill();Assert-True ($owner.WaitForExit(5000)) 'Captured dummy supervisor must exit after the injected crash'
    Assert-True ($child.WaitForExit(5000)) 'Kernel kill-on-close must stop the inherited child when supervisor dies'
    $clock.Restart()
    while(-not[HoneyProxyProcessJob]::IsGone($nonce)-and$clock.ElapsedMilliseconds-lt5000){Start-Sleep -Milliseconds 25}
    Assert-True ([HoneyProxyProcessJob]::IsGone($nonce)) 'The named job must be destroyed only after its retained owner/child retire'
    Write-Host ('PASS '+$script:passed+' actual Windows kill-on-close Job Object checks (owned dummy processes only; no VPN or settings changes)')
}finally {
    foreach($process in @($owner,$child,$collision)){
        if($null-ne$process){try{if(-not$process.HasExited){$process.Kill()};$null=$process.WaitForExit(5000)}catch{};try{$process.Dispose()}catch{}}
    }
    Remove-Item -LiteralPath $root -Recurse -Force -ErrorAction SilentlyContinue
}
