; Build with Inno Setup 6:
;   "C:\Program Files (x86)\Inno Setup 6\ISCC.exe" scripts\installer.iss

#define MyAppName "Forever字幕工厂"
#define MyAppExeName "ForeverSubtitleFactory.exe"
#define MyAppVersion "1.0.0"
#define MyAppPublisher "Forever"
#define MyAppURL "https://github.com/Xpg666888/-TXT/upload"
#define MySourceDir "D:\AsrTools-main\AsrTools-main\dist\ForeverSubtitleFactory"

[Setup]
AppId={{DB6F8939-2E3A-4DC7-A6A2-0C38D4AFA15D}
AppName={#MyAppName}
AppVersion={#MyAppVersion}
AppPublisher={#MyAppPublisher}
AppPublisherURL={#MyAppURL}
AppSupportURL={#MyAppURL}
AppUpdatesURL={#MyAppURL}
DefaultDirName={autopf}\ForeverSubtitleFactory
DefaultGroupName=Forever字幕工厂
DisableProgramGroupPage=yes
OutputDir=D:\AsrTools-main\AsrTools-main\release
OutputBaseFilename=ForeverSubtitleFactory-Setup
Compression=lzma
SolidCompression=yes
WizardStyle=modern
ArchitecturesInstallIn64BitMode=x64
SetupIconFile=D:\AsrTools-main\AsrTools-main\resources\app.ico

[Languages]
Name: "chinesesimp"; MessagesFile: "compiler:Default.isl"

[Tasks]
Name: "desktopicon"; Description: "创建桌面图标"; GroupDescription: "附加任务:"; Flags: unchecked

[Files]
Source: "{#MySourceDir}\*"; DestDir: "{app}"; Flags: recursesubdirs createallsubdirs ignoreversion

[Icons]
Name: "{autoprograms}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"
Name: "{autodesktop}\{#MyAppName}"; Filename: "{app}\{#MyAppExeName}"; Tasks: desktopicon

[Run]
Filename: "{app}\{#MyAppExeName}"; Description: "启动 {#MyAppName}"; Flags: nowait postinstall skipifsilent
