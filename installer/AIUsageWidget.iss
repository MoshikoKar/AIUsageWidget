; Inno Setup script. Build via build.ps1 (passes /DAppVersion=x.y.z).
#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

[Setup]
AppId={{FC53E2D8-9BA7-4EE2-AB84-787F032F325A}
AppName=AIUsageWidget
AppVersion={#AppVersion}
AppPublisher=AIUsageWidget
DefaultDirName={autopf}\AIUsageWidget
DefaultGroupName=AIUsageWidget
PrivilegesRequired=lowest
OutputDir=..\dist
OutputBaseFilename=AIUsageWidget-Setup
SetupIconFile=..\assets\icon.ico
UninstallDisplayIcon={app}\AIUsageWidget.exe
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64compatible

[Tasks]
Name: "startup"; Description: "Start AIUsageWidget when I sign in to Windows"; Flags: checkedonce

[Files]
Source: "..\dist\AIUsageWidget.exe"; DestDir: "{app}"; Flags: ignoreversion
Source: "..\dist\scripts\*"; DestDir: "{app}\scripts"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\AIUsageWidget"; Filename: "{app}\AIUsageWidget.exe"

[Registry]
; Same Run-key value the in-app "Start with Windows" toggle reads and writes.
Root: HKCU; Subkey: "Software\Microsoft\Windows\CurrentVersion\Run"; ValueType: string; ValueName: "AIUsageWidget"; ValueData: """{app}\AIUsageWidget.exe"""; Tasks: startup; Flags: uninsdeletevalue

[Run]
; Not skipifsilent: after a silent self-update the app comes back up on its own.
Filename: "{app}\AIUsageWidget.exe"; Description: "Launch AIUsageWidget"; Flags: nowait postinstall runasoriginaluser
