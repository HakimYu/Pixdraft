[Setup]
AppId=HakimYu.Pixdraft
AppName=Pixdraft
AppVersion={#PixdraftVersion}
AppPublisher=Pixdraft
DefaultDirName={localappdata}\Programs\Pixdraft
DisableProgramGroupPage=yes
PrivilegesRequired=lowest
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
SetupIconFile={#AppIcon}
UninstallDisplayIcon={app}\Pixdraft.exe
OutputBaseFilename=Pixdraft-windows-x64-setup
WizardStyle=modern

[Files]
Source: "{#BundleDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Pixdraft"; Filename: "{app}\Pixdraft.exe"; WorkingDir: "{app}"
