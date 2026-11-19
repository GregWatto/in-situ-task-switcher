#if !Defined(AppVersion) || !Defined(RuntimeDir) || !Defined(CompilerDir)
  #error Build this installer with Build-Installer.ps1.
#endif

#define AppName "In Situ - Task Switcher"
#define AppURL "https://github.com/GregWatto/in-situ-task-switcher"
#define Runtime "{app}\runtime\AutoHotkey64.exe"
#define ScriptPath "{app}\WindowSwitcher.ahk"

[Setup]
AppId={{63108C38-966F-4921-875C-0629EB981759}
AppName={#AppName}
AppVersion={#AppVersion}
AppPublisher=Greg Watkinson
AppPublisherURL={#AppURL}
AppSupportURL={#AppURL}/issues
AppUpdatesURL={#AppURL}/releases
DefaultDirName={localappdata}\Programs\In Situ
DefaultGroupName=In Situ
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22000
SetupArchitecture=x64
ArchitecturesAllowed=x64os
ArchitecturesInstallIn64BitMode=x64os
CloseApplications=yes
RestartApplications=no
UninstallDisplayIcon={#Runtime}
WizardStyle=modern
OutputDir=..\dist
OutputBaseFilename=InSitu-Setup-{#AppVersion}-x64
Compression=lzma2
SolidCompression=yes
VersionInfoVersion={#AppVersion}

[Files]
Source: "..\WindowSwitcher.ahk"; DestDir: "{app}"
Source: "..\DesktopSwitcher.ahk"; DestDir: "{app}"
Source: "..\Lib\UIA.ahk"; DestDir: "{app}\Lib"
Source: "..\LICENSE"; DestDir: "{app}"; DestName: "LICENSE.txt"
Source: "..\THIRD_PARTY_NOTICES.md"; DestDir: "{app}"
Source: "..\Lib\LICENSE"; DestDir: "{app}\Lib"
Source: "..\LICENSES\VirtualDesktop-MIT.txt"; DestDir: "{app}\LICENSES"
Source: "{#RuntimeDir}\AutoHotkey64.exe"; DestDir: "{app}\runtime"
Source: "{#RuntimeDir}\license.txt"; DestDir: "{app}\LICENSES"; DestName: "AutoHotkey.txt"
Source: "{#CompilerDir}\license.txt"; DestDir: "{app}\LICENSES"; DestName: "Inno-Setup.txt"

[Icons]
Name: "{group}\In Situ"; Filename: "{#Runtime}"; Parameters: "/CP65001 ""{#ScriptPath}"""; WorkingDir: "{app}"
Name: "{group}\In Situ (Alt+Tab mode)"; Filename: "{#Runtime}"; Parameters: "/CP65001 ""{#ScriptPath}"" --alt-tab"; WorkingDir: "{app}"

[Run]
Filename: "{#Runtime}"; Parameters: "/CP65001 ""{#ScriptPath}"""; WorkingDir: "{app}"; Description: "Launch In Situ"; Flags: nowait postinstall skipifsilent

[UninstallRun]
Filename: "{#Runtime}"; Parameters: "/CP65001 ""{#ScriptPath}"" --exit"; WorkingDir: "{app}"; Flags: skipifdoesntexist; RunOnceId: "StopInSitu"

[Code]
function PrepareToInstall(var NeedsRestart: Boolean): String;
var
  RuntimePath, ScriptPath: String;
  ExitCode: Integer;
begin
  Result := '';
  RuntimePath := ExpandConstant('{#Runtime}');
  ScriptPath := ExpandConstant('{#ScriptPath}');
  if FileExists(RuntimePath) and FileExists(ScriptPath) then
  begin
    if not Exec(RuntimePath, '/CP65001 "' + ScriptPath + '" --exit',
      ExpandConstant('{app}'), SW_HIDE, ewWaitUntilTerminated, ExitCode) then
      Result := 'Exit In Situ from the tray icon before updating it.'
    else if ExitCode <> 0 then
      Result := 'Exit In Situ from the tray icon before updating it.';
  end;
end;
