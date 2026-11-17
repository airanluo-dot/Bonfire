#ifndef PublishDir
#error Define PublishDir with the absolute path to the published WinUI application.
#endif
#ifndef OutputDir
#error Define OutputDir with the output directory.
#endif
#ifndef ReleaseVersion
#error Define ReleaseVersion from VERSION.
#endif

#define BonfireId "{0C99D780-D42C-4133-B71A-DBD4A6F25A6F}"

[Setup]
AppId={{#BonfireId}
AppName=Bonfire
AppVersion={#ReleaseVersion}
AppPublisher=Bonfire
AppPublisherURL=https://github.com/airanluo-dot/Bonfire
DefaultDirName={localappdata}\Programs\Bonfire
UsePreviousAppDir=yes
DisableDirPage=auto
AlwaysShowDirOnReadyPage=yes
DefaultGroupName=Bonfire
UsePreviousTasks=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
MinVersion=10.0.22000
DisableProgramGroupPage=yes
UninstallDisplayIcon={app}\Bonfire.exe
SetupIconFile={#PublishDir}\app.ico
OutputDir={#OutputDir}
OutputBaseFilename=Bonfire-{#ReleaseVersion}-Windows-x64-Setup
WizardStyle=modern
Compression=lzma2
SolidCompression=yes
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "zh"; MessagesFile: "localization\ChineseSimplified.isl"

[Messages]
en.ApplicationsFound=Save your work in the following applications before continuing. Setup can close them to update the files they are using.
zh.ApplicationsFound=请先保存以下应用程序中的工作，再继续安装。安装程序可以关闭这些应用程序，以更新正在使用的文件。

[CustomMessages]
en.VersionChange=Installed version: %1  →  New version: %2
zh.VersionChange=已安装版本：%1  →  本次安装版本：%2

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Bonfire"; Filename: "{app}\Bonfire.exe"
Name: "{userdesktop}\Bonfire"; Filename: "{app}\Bonfire.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\Bonfire.exe"; Description: "{cm:LaunchProgram,Bonfire}"; Flags: postinstall nowait skipifsilent; Check: not RestartUpdatedApp
Filename: "{app}\Bonfire.exe"; Flags: nowait; Check: RestartUpdatedApp

[Code]
const
  UninstallKey = 'Software\Microsoft\Windows\CurrentVersion\Uninstall\{#BonfireId}_is1';

var
  InstalledVersion: String;
  HadDesktopShortcut: Boolean;

procedure InitializeWizard;
var
  Tasks: String;
begin
  RegQueryStringValue(HKCU, UninstallKey, 'DisplayVersion', InstalledVersion);
  if RegQueryStringValue(HKCU, UninstallKey, 'Inno Setup: Selected Tasks', Tasks) then
    HadDesktopShortcut := Pos(',desktopicon,', ',' + Tasks + ',') > 0;
end;

procedure CurPageChanged(CurPageID: Integer);
begin
  if (CurPageID = wpReady) and (InstalledVersion <> '') then
    WizardForm.ReadyMemo.Lines.Insert(0,
      FmtMessage(CustomMessage('VersionChange'), [InstalledVersion, '{#ReleaseVersion}']) + #13#10);
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if (CurStep = ssPostInstall) and HadDesktopShortcut and
     not WizardIsTaskSelected('desktopicon') then
    DeleteFile(ExpandConstant('{userdesktop}\Bonfire.lnk'));
end;

function RestartUpdatedApp(): Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/BONFIRERESTART') = 0 then Result := True;
end;
