[Setup]
AppName=HoneyProxyUtility
AppVersion=1.0.0
AppPublisher=HoneyVPN
AppPublisherURL=https://honeyvpn.ru
AppSupportURL=https://t.me/honeyvpnmanager
DefaultDirName={autopf}\HoneyProxyUtility
DefaultGroupName=HoneyVPN
OutputDir=..\build\windows\installer
OutputBaseFilename=HoneyProxyUtility-Setup
Compression=lzma2/ultra64
SolidCompression=yes
WizardStyle=modern
PrivilegesRequired=admin
UninstallDisplayIcon={app}\HoneyProxyUtility.exe

[Languages]
Name: "russian"; MessagesFile: "compiler:Languages\Russian.isl"
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "Создать значок на рабочем столе"; GroupDescription: "Дополнительные задачи"

[Files]
Source: "..\build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Registry]
Root: HKLM; Subkey: "Software\Microsoft\Windows NT\CurrentVersion\AppCompatFlags\Layers"; ValueType: string; ValueName: "{app}\HoneyProxyUtility.exe"; ValueData: "RUNASADMIN"; Flags: uninsdeletevalue

[Icons]
Name: "{group}\HoneyVPN"; Filename: "{app}\HoneyProxyUtility.exe"
Name: "{group}\{cm:UninstallProgram,HoneyProxyUtility}"; Filename: "{uninstallexe}"
Name: "{userdesktop}\HoneyVPN"; Filename: "{app}\HoneyProxyUtility.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\HoneyProxyUtility.exe"; Description: "Запустить HoneyProxyUtility"; Flags: nowait postinstall skipifsilent runasoriginaluser
