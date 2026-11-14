; Instalator Przesył dla Windows (Inno Setup 6)
[Setup]
AppId={{6E1C2B0A-6F3B-4D8E-9C2A-5B7D1E3F4A10}
AppName=Przesył
AppVersion=1.1.0
AppPublisher=Przesył
DefaultDirName={autopf}\Przesyl
DefaultGroupName=Przesył
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
OutputDir=dist
OutputBaseFilename=Przesyl-Windows-Instalator
Compression=lzma2
SolidCompression=yes
ArchitecturesAllowed=x64
ArchitecturesInstallIn64BitMode=x64
UninstallDisplayIcon={app}\przesyl.exe
WizardStyle=modern

[Languages]
Name: "polish"; MessagesFile: "compiler:Languages\Polish.isl"

[Tasks]
Name: "desktopicon"; Description: "{cm:CreateDesktopIcon}"; GroupDescription: "{cm:AdditionalIcons}"

[Files]
Source: "build\windows\x64\runner\Release\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{group}\Przesył"; Filename: "{app}\przesyl.exe"
Name: "{autodesktop}\Przesył"; Filename: "{app}\przesyl.exe"; Tasks: desktopicon

[Run]
Filename: "{app}\przesyl.exe"; Description: "{cm:LaunchProgram,Przesył}"; Flags: nowait postinstall skipifsilent
