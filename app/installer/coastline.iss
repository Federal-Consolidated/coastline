; Coastline for Windows: Inno Setup 6 script, run by scripts/package.py:
;   ISCC /DSource=<build\qt\Coastline> /DOutputDir=<build\qt> coastline.iss
; Installs per user (no administrator rights), with Start-menu and desktop shortcuts.

#ifndef Source
  #error Pass /DSource=<the packaged Coastline folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
AppId={{6C0A5B0E-7E1D-4C2B-9C1B-C0A57114E001}
AppName=Coastline
AppVersion=0.1
AppPublisher=Coastline
DefaultDirName={localappdata}\Programs\Coastline
DefaultGroupName=Coastline
PrivilegesRequired=lowest
DisableProgramGroupPage=yes
OutputDir={#OutputDir}
OutputBaseFilename=Coastline-Setup
Compression=lzma2/max
SolidCompression=yes
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
WizardStyle=modern
UninstallDisplayName=Coastline
SetupIconFile={#Source}\app\coastline_app\ui\coastline.ico
UninstallDisplayIcon={app}\app\coastline_app\ui\coastline.ico

[Files]
Source: "{#Source}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{group}\Coastline"; Filename: "{app}\python\pythonw.exe"; Parameters: "-m coastline_app"; WorkingDir: "{app}\app"; IconFilename: "{app}\app\coastline_app\ui\coastline.ico"
Name: "{userdesktop}\Coastline"; Filename: "{app}\python\pythonw.exe"; Parameters: "-m coastline_app"; WorkingDir: "{app}\app"; IconFilename: "{app}\app\coastline_app\ui\coastline.ico"; Tasks: desktopicon

[Tasks]
Name: "desktopicon"; Description: "Create a desktop shortcut"; GroupDescription: "Shortcuts:"

[Registry]
; .coastline job files open in Coastline.
Root: HKCU; Subkey: "Software\Classes\.coastline"; ValueType: string; ValueData: "Coastline.Job"; Flags: uninsdeletevalue
Root: HKCU; Subkey: "Software\Classes\Coastline.Job"; ValueType: string; ValueData: "Coastline Job"; Flags: uninsdeletekey
Root: HKCU; Subkey: "Software\Classes\Coastline.Job\shell\open\command"; ValueType: string; ValueData: """{app}\python\pythonw.exe"" -m coastline_app ""%1"""

[Run]
Filename: "{app}\python\pythonw.exe"; Parameters: "-m coastline_app"; WorkingDir: "{app}\app"; Description: "Start Coastline"; Flags: nowait postinstall skipifsilent
