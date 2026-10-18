; ──────────────────────────────────────────────────────────────
;  Samanvaya — Windows installer (Inno Setup 6).
;
;  Do not compile this by hand: run installer\build.ps1, which first
;  prepares the bundled Python in installer\build\python and passes
;  the version from VERSION as /DAppVersion.
;
;  What the installed result looks like:
;    <REAPER resource folder>\Scripts\Samanvaya\Samanvaya.lua  (+ .py files)
;    <REAPER resource folder>\Scripts\Samanvaya\python\         (bundled runtime)
;    reaper-kb.ini gains one SCR line, so "Samanvaya.lua" is in the
;    Action List the next time REAPER starts.
;
;  {app} is the REAPER resource folder itself (normally %APPDATA%\REAPER),
;  not the script folder, so the reaper-kb.ini path is simply {app}.
; ──────────────────────────────────────────────────────────────

#ifndef AppVersion
  #define AppVersion "0.0.0"
#endif

#define AppName    "Samanvaya"
#define ScriptDir  "{app}\Scripts\Samanvaya"
; Stable Action List id: "RS" + sha1("Samanvaya/Samanvaya.lua"). It must
; never change, or every user's shortcuts and toolbar buttons break.
#define CmdId      "RS1e176e80a0ad75d464682690d1fe4c50a773f95c"

[Setup]
AppId={{8DD5BB5B-D325-40C6-8654-7658C2D67F0B}
AppName={#AppName}
AppVersion={#AppVersion}
AppVerName={#AppName} {#AppVersion}
AppPublisher={#AppName}
VersionInfoVersion={#AppVersion}
VersionInfoProductName={#AppName}
VersionInfoDescription={#AppName} Setup
; Per-user install: no admin prompt, and %APPDATA% is this user's REAPER.
PrivilegesRequired=lowest
DefaultDirName={userappdata}\REAPER
AppendDefaultDirName=no
DirExistsWarning=no
UsePreviousAppDir=yes
DisableProgramGroupPage=yes
LicenseFile=LICENSE.txt
OutputDir=dist
OutputBaseFilename=Samanvaya_Setup_{#AppVersion}
Compression=lzma2/max
SolidCompression=yes
WizardStyle=modern
ArchitecturesAllowed=x64compatible
ArchitecturesInstallIn64BitMode=x64compatible
UninstallDisplayName={#AppName}
UninstallFilesDir={#ScriptDir}\uninstall
CloseApplications=no
#ifexist "Samanvaya.ico"
SetupIconFile=Samanvaya.ico
UninstallDisplayIcon={#ScriptDir}\uninstall\Samanvaya.ico
#endif

[Messages]
WelcomeLabel2=This will install [name/ver] into REAPER on this computer.%n%nSamanvaya syncs dubbed voice-over to the original in REAPER. Everything it needs, Python included, comes with this installer.%n%nPlease close REAPER before you continue.
SelectDirDesc=Where is REAPER's resource folder?
SelectDirLabel3=Samanvaya will be installed into the Scripts folder of the REAPER resource folder below. This is the folder that holds reaper.ini.%n%nTo check it, open REAPER and choose Options > Show REAPER resource path.
SelectDirBrowseLabel=Click Next to use this folder, or Browse to pick a different one (for a portable REAPER).
FinishedHeadingLabel=Samanvaya is installed
FinishedLabelNoIcons=Open REAPER, then go to Actions > Show action list and search for "Samanvaya".%n%nThe first time it runs, Samanvaya will offer to install ReaImGui if REAPER does not have it yet.
FinishedLabel=Open REAPER, then go to Actions > Show action list and search for "Samanvaya".%n%nThe first time it runs, Samanvaya will offer to install ReaImGui if REAPER does not have it yet.

[InstallDelete]
; A fresh runtime on every update, so no stale packages linger.
Type: filesandordirs; Name: "{#ScriptDir}\python"

[Files]
Source: "..\Samanvaya.lua";            DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\run_sync.py";              DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\sync_matcher.py";          DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\SyncingPrompt.txt";        DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\VERSION";                  DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\README.md";                DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\requirements.txt";         DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\requirements-direct.txt";  DestDir: "{#ScriptDir}"; Flags: ignoreversion
Source: "..\setup.bat";                DestDir: "{#ScriptDir}"; Flags: ignoreversion
; The track template is edited inside REAPER by the user: never overwrite it
; on update, and leave it behind on uninstall like the settings.
Source: "..\AutoSync\AutoSync.RPP";    DestDir: "{#ScriptDir}\AutoSync"; Flags: onlyifdoesntexist uninsneveruninstall
Source: "build\python\*";              DestDir: "{#ScriptDir}\python"; Flags: ignoreversion recursesubdirs createallsubdirs
#ifexist "Samanvaya.ico"
Source: "Samanvaya.ico";               DestDir: "{#ScriptDir}\uninstall"; Flags: ignoreversion
#endif

[UninstallDelete]
; Runtime leftovers. API keys (sync_pipeline_settings.json, vertex_key.json)
; are deliberately NOT listed: a reinstall picks them up again.
Type: filesandordirs; Name: "{#ScriptDir}\python"
Type: filesandordirs; Name: "{#ScriptDir}\__pycache__"
Type: files; Name: "{#ScriptDir}\sync_cache.json"
Type: files; Name: "{#ScriptDir}\sync_config.json"
Type: files; Name: "{#ScriptDir}\sync_results.json"
Type: files; Name: "{#ScriptDir}\sync_python_*.txt"
Type: files; Name: "{#ScriptDir}\.clip_tmp.txt"

[Code]
const
  CmdId   = '{#CmdId}';
  KbLine  = 'SCR 4 0 {#CmdId} "Custom: Samanvaya.lua" "Samanvaya\Samanvaya.lua"';

function IsReaperRunning(): Boolean;
begin
#ifdef SkipReaperCheck
  { Test builds only (ISCC /DSkipReaperCheck): install next to a running REAPER. }
  Result := False;
#else
  Result := FindWindowByClassName('REAPERwnd') <> 0;
#endif
end;

{ Asks until REAPER is closed. False when the user gives up. REAPER rewrites
  reaper-kb.ini when it quits, so an edit made while it runs would be lost. }
function WaitForReaperClosed(): Boolean;
begin
  Result := True;
  while IsReaperRunning() do
  begin
    if SuppressibleMsgBox('REAPER is running. Please save your work and close REAPER, then click Retry.',
         mbError, MB_RETRYCANCEL, IDCANCEL) = IDCANCEL then
    begin
      Result := False;
      Exit;
    end;
  end;
end;

function KbPath(): String;
begin
  Result := ExpandConstant('{app}\reaper-kb.ini');
end;

{ reaper-kb.ini is handled as raw bytes (AnsiString) so lines holding
  non-ASCII script paths survive exactly as REAPER wrote them. }
procedure RegisterAction();
var
  Kb: AnsiString;
begin
  if not LoadStringFromFile(KbPath(), Kb) then
    Kb := '';
  if Pos(CmdId, Kb) > 0 then
    Exit;
  if (Length(Kb) > 0) and (Kb[Length(Kb)] <> #10) then
    Kb := Kb + #13#10;
  Kb := Kb + KbLine + #13#10;
  if not SaveStringToFile(KbPath(), Kb, False) then
    SuppressibleMsgBox('Could not add Samanvaya to the REAPER Action List.' + #13#10 +
      'In REAPER, use Actions > Show action list > New action > Load ReaScript and pick:' + #13#10 +
      ExpandConstant('{app}\Scripts\Samanvaya\Samanvaya.lua'), mbError, MB_OK, IDOK);
end;

procedure UnregisterAction();
var
  Kb, Rest, Line, OutKb: AnsiString;
  P: Integer;
begin
  if not LoadStringFromFile(KbPath(), Kb) then
    Exit;
  if Pos(CmdId, Kb) = 0 then
    Exit;
  Rest := Kb;
  OutKb := '';
  while Length(Rest) > 0 do
  begin
    P := Pos(#10, Rest);
    if P = 0 then
    begin
      Line := Rest;
      Rest := '';
    end else
    begin
      Line := Copy(Rest, 1, P);
      Delete(Rest, 1, P);
    end;
    if Pos(CmdId, Line) = 0 then
      OutKb := OutKb + Line;
  end;
  SaveStringToFile(KbPath(), OutKb, False);
end;

procedure InitializeWizard();
begin
  { A portable REAPER keeps reaper.ini beside reaper.exe. If the usual
    %APPDATA%\REAPER has none but a Program Files copy does, start there. }
  if not FileExists(ExpandConstant('{userappdata}\REAPER\reaper.ini')) then
  begin
    if FileExists(ExpandConstant('{autopf}\REAPER (x64)\reaper.ini')) then
      WizardForm.DirEdit.Text := ExpandConstant('{autopf}\REAPER (x64)')
    else if FileExists(ExpandConstant('{autopf}\REAPER\reaper.ini')) then
      WizardForm.DirEdit.Text := ExpandConstant('{autopf}\REAPER');
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not FileExists(AddBackslash(WizardDirValue()) + 'reaper.ini') then
      Result := SuppressibleMsgBox('No reaper.ini was found in:' + #13#10 + WizardDirValue() + #13#10#13#10 +
        'This does not look like a REAPER resource folder. If REAPER has never been ' +
        'started on this computer, start it once first.' + #13#10#13#10 +
        'Install here anyway?', mbConfirmation, MB_YESNO, IDNO) = IDYES;
  end;
end;

function PrepareToInstall(var NeedsRestart: Boolean): String;
begin
  Result := '';
  if not WaitForReaperClosed() then
    Result := 'REAPER is still running. Close it and run Setup again.';
end;

procedure CurStepChanged(CurStep: TSetupStep);
begin
  if CurStep = ssPostInstall then
    RegisterAction();
end;

function InitializeUninstall(): Boolean;
begin
  Result := WaitForReaperClosed();
end;

procedure CurUninstallStepChanged(CurUninstallStep: TUninstallStep);
begin
  if CurUninstallStep = usUninstall then
    UnregisterAction();
end;
