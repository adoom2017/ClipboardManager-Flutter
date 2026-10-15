; Inno Setup script for the Windows installer.
; Invoked by scripts/build-release.ps1 -CreateInstaller, which passes:
;   /DAppVersion=<x.y.z> /DSourceDir=<Release bundle> /DOutputDir=<dir>

#ifndef AppVersion
  #error AppVersion must be defined
#endif
#ifndef SourceDir
  #error SourceDir must be defined
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

#define AppName "Clipboard Manager"
#define AppExeName "clipboard_manager.exe"

[Setup]
; AppId identifies the product for upgrades and uninstall; never change it.
AppId={{A36BE75B-F9EA-4D5E-BD18-95294A5994E3}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=ClipboardManager
VersionInfoVersion={#AppVersion}
; Per-user install: no administrator prompt, upgrades in place.
PrivilegesRequired=lowest
DefaultDirName={localappdata}\Programs\ClipboardManager
DisableProgramGroupPage=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
OutputDir={#OutputDir}
OutputBaseFilename=ClipboardManager-Windows-{#AppVersion}-Setup
SetupIconFile=..\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExeName}
UninstallDisplayName={#AppName}
Compression=lzma2
SolidCompression=yes
WizardStyle=modern
; The app lives in the tray; ask Restart Manager to close it before upgrading.
CloseApplications=yes
RestartApplications=no

[Languages]
Name: "english"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExeName}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#AppExeName}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
