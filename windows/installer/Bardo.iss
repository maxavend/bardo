; The Windows installer, built with Inno Setup 6 from a published, self-contained Bardo.
;
;   iscc /DAppVersion=1.2.0 /DArch=x64 /DSourceDir=<publish folder> /DOutputDir=<folder> Bardo.iss
;
; Arch is x64 or arm64; each gets its own installer, as the download page offers.
; It installs for the current person only, under %LOCALAPPDATA%\Programs, so it needs no
; administrator rights. Uninstalling leaves the Library in %LOCALAPPDATA%\Bardo alone.

#ifndef AppVersion
  #error Pass /DAppVersion=<version>
#endif
#ifndef Arch
  #error Pass /DArch=x64 or /DArch=arm64
#endif
#ifndef SourceDir
  #error Pass /DSourceDir=<published app folder>
#endif
#ifndef OutputDir
  #define OutputDir "."
#endif

[Setup]
; Never change the AppId: Windows uses it to recognise updates and uninstalls.
AppId={{60814A1D-0410-4489-8216-315E5518781B}
AppName=Bardo
AppVersion={#AppVersion}
AppVerName=Bardo {#AppVersion}
AppPublisher=Bardo
AppPublisherURL=https://github.com/maxavend/bardo
AppSupportURL=https://github.com/maxavend/bardo/issues
VersionInfoVersion={#AppVersion}
DefaultDirName={localappdata}\Programs\Bardo
DisableDirPage=yes
DisableProgramGroupPage=yes
DisableReadyPage=yes
PrivilegesRequired=lowest
MinVersion=10.0.22621
#if Arch == "arm64"
ArchitecturesAllowed=arm64
ArchitecturesInstallIn64BitMode=arm64
#else
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
#endif
SetupIconFile=..\src\Bardo.App\Assets\AppIcon.ico
UninstallDisplayIcon={app}\Bardo.exe
UninstallDisplayName=Bardo
WizardStyle=modern
Compression=lzma2/ultra64
SolidCompression=yes
CloseApplications=yes
OutputDir={#OutputDir}
OutputBaseFilename=Bardo-{#AppVersion}-Setup-{#Arch}

[Languages]
Name: "es"; MessagesFile: "compiler:Languages\Spanish.isl"
Name: "en"; MessagesFile: "compiler:Default.isl"

[InstallDelete]
; An update replaces the whole program folder, so no file of an older version lingers.
Type: filesandordirs; Name: "{app}\*"

[Files]
Source: "{#SourceDir}\*"; DestDir: "{app}"; Flags: ignoreversion recursesubdirs createallsubdirs

[Icons]
Name: "{autoprograms}\Bardo"; Filename: "{app}\Bardo.exe"

[Run]
Filename: "{app}\Bardo.exe"; Description: "{cm:LaunchProgram,Bardo}"; Flags: nowait postinstall skipifsilent
