#ifndef AppVer
  #error AppVer must be provided by the validated release build
#endif

[Setup]
AppName=HoneyProxyUtility
AppVersion={#AppVer}
AppPublisher=HoneyVPN
AppPublisherURL=https://honeyvpn.ru
AppSupportURL=https://t.me/honeyvpnmanagerbot
DefaultDirName={autopf}\HoneyProxyUtility
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
DisableDirPage=yes
UsePreviousAppDir=no
DefaultGroupName=HoneyVPN
OutputDir=..\build\windows\installer
OutputBaseFilename=HoneyProxyUtility-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\HoneyProxyUtility.exe
LanguageDetectionMethod=uilanguage
ShowLanguageDialog=yes

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
english.GuardCloseApp=Close HoneyProxyUtility and run the installer again.
russian.GuardCloseApp=Закройте HoneyProxyUtility и повторите установку.
english.GuardPreviousConnection=Could not confirm that the previous VPN connection stopped. Installation has been stopped.
russian.GuardPreviousConnection=Не удалось подтвердить остановку предыдущего VPN-подключения. Установка остановлена.
english.GuardUserProfile=Could not identify your Windows user profile. Run the installer from your normal Windows session.
russian.GuardUserProfile=Не удалось определить профиль пользователя. Запустите установщик из обычного сеанса Windows.
english.GuardProcesses=Could not check running Windows processes. Installation has been stopped.
russian.GuardProcesses=Не удалось проверить запущенные процессы Windows. Установка остановлена.
english.GuardPreviousRegistration=The previous HoneyProxyUtility installation record could not be verified. Installation has been stopped.
russian.GuardPreviousRegistration=Запись предыдущей установки HoneyProxyUtility не прошла проверку. Установка остановлена.
english.GuardMissingUninstaller=Files remain in the previous installation folder, but its uninstaller is missing. Contact support to repair the previous installation.
russian.GuardMissingUninstaller=В каталоге предыдущей версии остались файлы, но её программа удаления отсутствует. Обратитесь в поддержку для восстановления предыдущей установки.
english.GuardUninstallFailed=The previous version could not be uninstalled. Remove it before running the installer again.
russian.GuardUninstallFailed=Не удалось удалить предыдущую версию. Удалите её перед повторной установкой.
english.GuardRegistrationChanged=The previous installation record changed, or its removal could not be confirmed. Installation has been stopped.
russian.GuardRegistrationChanged=Запись предыдущей установки изменилась или её удаление не подтверждено. Установка остановлена.
english.GuardRegistrationUnsafe=Could not verify the security of the previous installation record. Installation has been stopped.
russian.GuardRegistrationUnsafe=Не удалось подтвердить безопасность записи предыдущей установки. Установка остановлена.
english.GuardCheckUnavailable=Could not start the Windows installation check. Installation has been stopped.
russian.GuardCheckUnavailable=Не удалось запустить проверку установки Windows. Установка остановлена.
english.GuardDirectoryUnsafe=Could not verify the security of the HoneyProxyUtility installation folder. Installation has been stopped.
russian.GuardDirectoryUnsafe=Не удалось подтвердить безопасность каталога HoneyProxyUtility. Установка остановлена.
english.FixedDirectoryRequired=Install HoneyProxyUtility in its default Program Files folder.
russian.FixedDirectoryRequired=Установите HoneyProxyUtility в стандартный каталог Program Files.
english.ServiceStopInstallFailed=Could not confirm that the VPN service stopped. Close HoneyProxyUtility and run the installer again.
russian.ServiceStopInstallFailed=Не удалось подтвердить остановку службы VPN. Закройте HoneyProxyUtility и повторите установку.
english.ServiceInstallFailed=The VPN service could not be installed. Run the HoneyProxyUtility installer again.
russian.ServiceInstallFailed=Не удалось установить службу VPN. Повторите установку HoneyProxyUtility.
english.ServiceStopUninstallFailed=Could not confirm that the VPN service stopped. Close HoneyProxyUtility and try uninstalling again.
russian.ServiceStopUninstallFailed=Не удалось подтвердить остановку службы VPN. Закройте HoneyProxyUtility и повторите удаление.

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Dirs]
; The preflight guard creates this fixed directory with its final ACL before
; Inno copies files. Record removal even though it already exists at install.
; Inno removes it only when empty; profiles and unrelated contents are retained.
Name: "{app}"; Flags: uninsalwaysuninstall

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs
Source: "..\scripts\secure_windows_installation.ps1"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\scripts\secure_windows_installation.ps1"; DestName: "honey-installation-guard.ps1"; Flags: dontcopy
Source: "..\windows\service\DesktopUserIdentity.cs"; DestName: "DesktopUserIdentity.cs"; Flags: dontcopy

[Icons]
Name: "{group}\HoneyVPN"; Filename: "{app}\HoneyProxyUtility.exe"
Name: "{group}\{cm:UninstallProgram,HoneyProxyUtility}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\HoneyVPN"; Filename: "{app}\HoneyProxyUtility.exe"; Tasks: desktopicon

[Registry]
; The machine registration points directly to the fixed asInvoker UI. A URI is
; one quoted data argument; it never goes through cmd.exe or PowerShell.
Root: HKLM64; Subkey: "Software\Classes\honeyvpn"; ValueType: string; ValueName: ""; ValueData: "URL:HoneyVPN Import"
Root: HKLM64; Subkey: "Software\Classes\honeyvpn"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""
Root: HKLM64; Subkey: "Software\Classes\honeyvpn\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: """{app}\HoneyProxyUtility.exe"",0"
Root: HKLM64; Subkey: "Software\Classes\honeyvpn\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\HoneyProxyUtility.exe"" --import-link ""%1"""

[Run]
; The installer owns privileged service setup; the UI runs as the original user
; so profiles, AppData and system-proxy settings remain in that user's account.
Filename: "{app}\HoneyProxyUtility.exe"; Description: "{cm:LaunchProgram,HoneyProxyUtility}"; Flags: nowait postinstall skipifsilent runasoriginaluser

[Code]
var
  LastInstallationGuardCode: Integer;

function NativeSystemExecutable(const RelativePath: String): String;
begin
  { Sysnative is an entry alias for a 32-bit launcher. A native installer
    cannot see it and uses physical System32 instead. The guard independently
    rejects a 32-bit PowerShell process before changing installation ACLs. }
  Result := AddBackslash(ExpandConstant('{sysnative}')) + RelativePath;
  if not FileExists(Result) then
    Result := AddBackslash(ExpandConstant('{sys}')) + RelativePath;
end;

function InstallationGuardFailureText: String;
begin
  case LastInstallationGuardCode of
    20: Result := CustomMessage('GuardCloseApp');
    21, 22: Result := CustomMessage('GuardPreviousConnection');
    23: Result := CustomMessage('GuardUserProfile');
    24: Result := CustomMessage('GuardProcesses');
    31, 32, 34: Result := CustomMessage('GuardPreviousRegistration');
    33: Result := CustomMessage('GuardMissingUninstaller');
    35: Result := CustomMessage('GuardUninstallFailed');
    36: Result := CustomMessage('GuardRegistrationChanged');
    37, 38: Result := CustomMessage('GuardRegistrationUnsafe');
    90: Result := CustomMessage('GuardCheckUnavailable');
    else Result := CustomMessage('GuardDirectoryUnsafe');
  end;
  Result := Result + ' (HNG-' + IntToStr(LastInstallationGuardCode) + ')';
end;

function InstallationDirectoryIsFixed: Boolean;
begin
  Result := CompareText(RemoveBackslashUnlessRoot(ExpandFileName(WizardDirValue)),
    RemoveBackslashUnlessRoot(ExpandConstant('{autopf}\HoneyProxyUtility'))) = 0;
end;

function RunInstallationGuard(const Directory: String; Normalize: Boolean; Legacy: Boolean; const Phase: String): Boolean;
var
  ExitCode: Integer;
  Params: String;
begin
  ExtractTemporaryFile('honey-installation-guard.ps1');
  ExtractTemporaryFile('DesktopUserIdentity.cs');
  Params := '-NoProfile -NonInteractive -ExecutionPolicy Bypass -File "' +
    ExpandConstant('{tmp}\honey-installation-guard.ps1') + '" -RootDirectory "' + Directory + '"';
  if Normalize then Params := Params + ' -Normalize';
  if Legacy then Params := Params + ' -Legacy -VerifyLegacyRegistration -RequireClosed -RetireOrphanedLegacy';
  if Normalize and not Legacy then Params := Params + ' -RequireClosed';
  { An empty working directory makes Exec inherit the executable's Sysnative
    alias. That alias is inaccessible to the 64-bit child. Use a real Windows
    directory for both 32-bit and native Setup/Uninstall. }
  Result := Exec(NativeSystemExecutable('WindowsPowerShell\v1.0\powershell.exe'),
    Params, ExpandConstant('{win}'), SW_HIDE, ewWaitUntilTerminated, ExitCode);
  if Result then begin
    case ExitCode of
      0, 2, 10, 11, 12, 13, 14, 20, 21, 22, 23, 24, 30, 31, 32, 33, 34, 36, 37, 38, 39:
        LastInstallationGuardCode := ExitCode;
      else LastInstallationGuardCode := 2;
    end;
    Log('HoneyVPN guard phase=' + Phase + ' HNG-' + IntToStr(LastInstallationGuardCode) +
      ' exit=' + IntToStr(ExitCode));
    Result := (ExitCode = 0) or ((ExitCode = 39) and Legacy and not Normalize and
      (Phase = 'legacy-migration'));
  end else begin
    LastInstallationGuardCode := 90;
    Log('HoneyVPN guard phase=' + Phase + ' HNG-90 launch-error=' + IntToStr(ExitCode));
  end;
end;

function MigrateLegacyInstallation: Boolean;
var
  LegacyDirectory: String;
  ExitCode: Integer;
begin
  Result := True;
  LegacyDirectory := ExpandConstant('{pf32}\HoneyProxyUtility');
  if DirExists(LegacyDirectory) or RegKeyExists(HKLM32,
    'Software\Microsoft\Windows\CurrentVersion\Uninstall\HoneyProxyUtility_is1') then begin
    if not RunInstallationGuard(LegacyDirectory, False, True, 'legacy-migration') then begin
      Result := False;
      exit;
    end;
    { Exit39 is a separate safe disposition, never permission to execute the
      still-present registry record. No old files exist and closure/cleanup
      were checked. Leave unsafe orphan metadata unchanged. }
    if LastInstallationGuardCode = 39 then begin
      Log('HoneyVPN migration phase=orphan-registration HNG-39 preserved-unsafe-metadata no-uninstaller-launch');
      exit;
    end;
    { A validated orphan record is removed by the guard only after confirming
      an absent/empty protected tree, closed processes and session cleanup.
      No old executable exists in that case, so there is nothing to launch. }
    if not RegKeyExists(HKLM32,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\HoneyProxyUtility_is1') then begin
      Log('HoneyVPN migration phase=orphan-registration HNG-0');
      exit;
    end;
    { No registry-provided command is executed. Only our fixed, guarded Inno
      uninstaller is allowed to remove the old application files. AppData is
      outside both installation directories and remains untouched. }
    Result := Exec(AddBackslash(LegacyDirectory) + 'unins000.exe',
      '/VERYSILENT /SUPPRESSMSGBOXES /NORESTART', LegacyDirectory, SW_HIDE,
      ewWaitUntilTerminated, ExitCode);
    if not Result then begin
      LastInstallationGuardCode := 35;
      Log('HoneyVPN migration phase=legacy-uninstaller HNG-35 launch-error=' + IntToStr(ExitCode));
      exit;
    end;
    if ExitCode <> 0 then begin
      LastInstallationGuardCode := 35;
      Log('HoneyVPN migration phase=legacy-uninstaller HNG-35 exit=' + IntToStr(ExitCode));
      Result := False;
      exit;
    end;
    Result := not RegKeyExists(HKLM32,
      'Software\Microsoft\Windows\CurrentVersion\Uninstall\HoneyProxyUtility_is1');
    if not Result then begin
      LastInstallationGuardCode := 36;
      Log('HoneyVPN migration phase=legacy-registration HNG-36');
    end;
  end;
end;

function StopInstalledService(const Directory: String): Boolean;
var
  ExitCode: Integer;
  ServiceExe: String;
begin
  ServiceExe := AddBackslash(Directory) + 'HoneyVpnService.exe';
  Result := True;
  if FileExists(ServiceExe) then
    Result := Exec(ServiceExe, '--uninstall', Directory, SW_HIDE,
      ewWaitUntilTerminated, ExitCode) and (ExitCode = 0)
  else
    { Missing helper proves no cleanup only when SCM confirms no service. }
    Result := Exec(NativeSystemExecutable('sc.exe'), 'query HoneyVpnTunnelService',
      ExpandConstant('{win}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) and (ExitCode = 1060);
end;

function UninstallDirectoryIsTrusted: Boolean;
var
  Script, Directory: String;
  Code: Integer;
begin
  Directory := ExpandConstant('{app}');
  StringChangeEx(Directory, '''', '''''', True);
  { The installed guard is read only after trusted Windows APIs verify both its
    ACL and ancestor path. Uninstall has no access to Setup's temp resources. }
  Script := '$ErrorActionPreference=''Stop'';try{$root=''' + Directory + ''';' +
    '$expected=Join-Path ([Environment]::GetFolderPath([Environment+SpecialFolder]::ProgramFiles)) ''HoneyProxyUtility'';' +
    'if([IO.Path]::GetFullPath($root).TrimEnd(''\'') -ine $expected.TrimEnd(''\'')){exit 2};' +
    '$trusted=@(''S-1-5-18'',''S-1-5-32-544'',''S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464'');' +
    '$guard=Join-Path $root ''secure_windows_installation.ps1'';' +
    'foreach($item in @($root,$guard)){ $p=[IO.Path]::GetFullPath($item);while($p){' +
    'if(((Get-Item -LiteralPath $p -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)-ne 0){exit 2};' +
    '$mask=if($p -ieq $root -or $p -ieq $guard){0xD0156}else{0xD0040};' +
    '$a=Get-Acl -LiteralPath $p;if($trusted -notcontains $a.GetOwner([Security.Principal.SecurityIdentifier]).Value){exit 2};' +
    'foreach($r in $a.GetAccessRules($true,$true,[Security.Principal.SecurityIdentifier])){' +
    'if($r.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and ' +
    '($r.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -eq 0 -and ' +
    '([long]$r.FileSystemRights -band $mask) -ne 0 -and $trusted -notcontains $r.IdentityReference.Value){exit 2}};' +
    '$next=[IO.Path]::GetDirectoryName($p);if($next -eq $p){break};$p=$next}};' +
    '& $guard -RootDirectory $root -RequireClosed;if($LASTEXITCODE -ne 0){exit 2};exit 0}catch{exit 2}';
  Result := Exec(NativeSystemExecutable('WindowsPowerShell\v1.0\powershell.exe'),
    '-NoProfile -NonInteractive -ExecutionPolicy Bypass -Command "' + Script + '"',
    ExpandConstant('{win}'), SW_HIDE, ewWaitUntilTerminated, Code) and (Code = 0);
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not InstallationDirectoryIsFixed then begin
    Result := CustomMessage('FixedDirectoryRequired');
    exit;
  end;
  if not RunInstallationGuard(WizardDirValue, True, False, 'pre-install') then begin
    Result := InstallationGuardFailureText;
    exit;
  end;
  if not MigrateLegacyInstallation then begin
    Result := InstallationGuardFailureText;
    exit;
  end;
  if not StopInstalledService(WizardDirValue) then
    Result := CustomMessage('ServiceStopInstallFailed');
end;

procedure CurStepChanged(CurStep: TSetupStep);
var
  ExitCode: Integer;
begin
  if CurStep = ssPostInstall then begin
    if not RunInstallationGuard(ExpandConstant('{app}'), True, False, 'post-install') then
      RaiseException(InstallationGuardFailureText);
    if not Exec(ExpandConstant('{app}\HoneyVpnService.exe'), '--install',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) or (ExitCode <> 0) then
      RaiseException(CustomMessage('ServiceInstallFailed'));
  end;
end;

function InitializeUninstall: Boolean;
begin
  { Service helper validates its protected installed directory itself. A failed
    cleanup acknowledgement aborts before deleting live core/service files. }
  Result := False;
  if UninstallDirectoryIsTrusted then
    Result := StopInstalledService(ExpandConstant('{app}'));
  if not Result then
    MsgBox(CustomMessage('ServiceStopUninstallFailed'), mbError, MB_OK);
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
var
  Command, ExpectedCommand: String;
begin
  if CurUninstallStep = usPostUninstall then begin
    ExpectedCommand := '"' + ExpandConstant('{app}\HoneyProxyUtility.exe') +
      '" --import-link "%1"';
    { A different app or newer install may take ownership later. Remove only
      the protocol registration that still points to this exact installation. }
    if RegQueryStringValue(HKLM64, 'Software\Classes\honeyvpn\shell\open\command',
      '', Command) and (CompareText(Command, ExpectedCommand) = 0) then
      RegDeleteKeyIncludingSubkeys(HKLM64, 'Software\Classes\honeyvpn');
  end;
end;
