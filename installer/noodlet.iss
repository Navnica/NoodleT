; Inno Setup script for the Windows installer of NoodleT.
;
; Build the app first (flutter build windows --release), then compile this
; script with Inno Setup 6:
;   ISCC.exe /DAppVersion=7fa625d installer\noodlet.iss
; The installer lands in dist\. The release workflow in .github/workflows does
; both steps for every push to the build branch, naming the build after the
; short hash of the commit.

#define AppName "NoodleT"
#define AppExe "noodlet.exe"
#ifndef AppVersion
  #define AppVersion "0.0.0-dev"
#endif
#define BundleDir "..\build\windows\x64\runner\Release"

[Setup]
; Identifies the app to Windows across versions: never change it, or updates
; install next to the old copy instead of over it.
AppId={{235D4A45-4DD7-45A3-85A6-A2EDC3A65366}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher=Navnica
AppPublisherURL=https://github.com/Navnica/NoodleT
AppSupportURL=https://github.com/Navnica/NoodleT/issues
AppUpdatesURL=https://github.com/Navnica/NoodleT/releases
DefaultDirName={autopf}\{#AppName}
DisableProgramGroupPage=yes
; Installs for the current user without a UAC prompt; the user may still pick
; "all users" in the first dialog.
PrivilegesRequired=lowest
PrivilegesRequiredOverridesAllowed=dialog
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
ChangesAssociations=yes
; Lets an update replace noodlet.exe while NoodleT is running.
CloseApplications=yes
SetupIconFile=..\windows\runner\resources\app_icon.ico
UninstallDisplayIcon={app}\{#AppExe}
OutputDir=..\dist
OutputBaseFilename=NoodleT-Setup-{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern

[Languages]
Name: "en"; MessagesFile: "compiler:Default.isl"
Name: "ru"; MessagesFile: "compiler:Languages\Russian.isl"

[CustomMessages]
en.AssocTask=Open .torrent files and magnet links with NoodleT
ru.AssocTask=Открывать .torrent-файлы и magnet-ссылки в NoodleT

[Tasks]
Name: "assoc"; Description: "{cm:AssocTask}"
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"; Flags: unchecked

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\{#AppName}"; Filename: "{app}\{#AppExe}"
Name: "{autodesktop}\{#AppName}"; Filename: "{app}\{#AppExe}"; Tasks: desktopicon

[Registry]
; .torrent files. NoodleT is offered in "Open with"; Windows still asks the
; user once before making it the default over another torrent client.
Root: HKA; Subkey: "Software\Classes\.torrent\OpenWithProgids"; ValueType: string; ValueName: "NoodleT.torrent"; ValueData: ""; Flags: uninsdeletevalue; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\NoodleT.torrent"; ValueType: string; ValueName: ""; ValueData: "Torrent file"; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\NoodleT.torrent\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExe},0"; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\NoodleT.torrent\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: assoc

; magnet: links.
Root: HKA; Subkey: "Software\Classes\magnet"; ValueType: string; ValueName: ""; ValueData: "URL:Magnet link"; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\magnet"; ValueType: string; ValueName: "URL Protocol"; ValueData: ""; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\magnet\DefaultIcon"; ValueType: string; ValueName: ""; ValueData: "{app}\{#AppExe},0"; Tasks: assoc
Root: HKA; Subkey: "Software\Classes\magnet\shell\open\command"; ValueType: string; ValueName: ""; ValueData: """{app}\{#AppExe}"" ""%1"""; Tasks: assoc

; Lists NoodleT under Settings > Apps > Default apps.
Root: HKA; Subkey: "Software\NoodleT\Capabilities"; ValueType: string; ValueName: "ApplicationName"; ValueData: "{#AppName}"; Flags: uninsdeletekey; Tasks: assoc
Root: HKA; Subkey: "Software\NoodleT\Capabilities"; ValueType: string; ValueName: "ApplicationDescription"; ValueData: "A simple desktop torrent client"; Tasks: assoc
Root: HKA; Subkey: "Software\NoodleT\Capabilities\FileAssociations"; ValueType: string; ValueName: ".torrent"; ValueData: "NoodleT.torrent"; Tasks: assoc
Root: HKA; Subkey: "Software\NoodleT\Capabilities\URLAssociations"; ValueType: string; ValueName: "magnet"; ValueData: "magnet"; Tasks: assoc
Root: HKA; Subkey: "Software\RegisteredApplications"; ValueType: string; ValueName: "NoodleT"; ValueData: "Software\NoodleT\Capabilities"; Flags: uninsdeletevalue; Tasks: assoc

[Run]
Filename: "{app}\{#AppExe}"; Description: "{cm:LaunchProgram,{#AppName}}"; Flags: nowait postinstall skipifsilent
