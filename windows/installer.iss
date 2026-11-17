#ifndef PublishDir
#error Define PublishDir with the absolute path to the published WinUI application.
#endif
#ifndef OutputDir
#error Define OutputDir with the output directory.
#endif
#ifndef ReleaseVersion
#error Define ReleaseVersion from VERSION.
#endif

[Setup]
AppId={{0C99D780-D42C-4133-B71A-DBD4A6F25A6F}
AppName=Bonfire
AppVersion={#ReleaseVersion}
AppPublisher=Bonfire
AppPublisherURL=https://github.com/airanluo-dot/Bonfire
DefaultDirName={localappdata}\Programs\Bonfire
DefaultGroupName=Bonfire
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

[Files]
Source: "{#PublishDir}\*"; DestDir: "{app}"; Excludes: "*.pdb"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Bonfire"; Filename: "{app}\Bonfire.exe"

[Run]
Filename: "{app}\Bonfire.exe"; Flags: nowait; Check: RestartUpdatedApp

[Code]
function RestartUpdatedApp(): Boolean;
var I: Integer;
begin
  Result := False;
  for I := 1 to ParamCount do
    if CompareText(ParamStr(I), '/BONFIRERESTART') = 0 then Result := True;
end;
