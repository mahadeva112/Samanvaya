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
;    Action List the next time REAPER starts, and one KEY line for the
;    shortcut picked on the "Keyboard shortcut" page (A by default).
;    Silent installs take /SHORTCUT=Ctrl+Shift+A, or /SHORTCUT=none.
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
; Artwork comes from make_icon.py. The comma lists let Inno pick the bitmap
; that fits the screen's DPI scale.
SetupIconFile=Samanvaya.ico
UninstallDisplayIcon={#ScriptDir}\uninstall\Samanvaya.ico
WizardImageFile=wizard_large.bmp,wizard_large_150.bmp,wizard_large_200.bmp,wizard_large_250.bmp
WizardSmallImageFile=wizard_small.bmp,wizard_small_150.bmp,wizard_small_200.bmp,wizard_small_250.bmp
WizardImageStretch=no
WizardImageBackColor=$100C0A

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
Source: "Samanvaya.ico";               DestDir: "{#ScriptDir}\uninstall"; Flags: ignoreversion

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
  { A KEY line is "KEY <flags> <virtual key> <command> <section>". The flags
    are Windows accelerator bits: 1 virtual key, 4 Shift, 8 Ctrl, 16 Alt.
    Section 0 is REAPER's Main section. }
  FlagShift = 4;
  FlagCtrl  = 8;
  FlagAlt   = 16;
  KeyCount  = 48;   { A-Z, 0-9, F1-F12 }

var
  ShortcutPage: TWizardPage;
  ShortcutBox, CtrlBox, AltBox, ShiftBox: TNewCheckBox;
  KeyCombo: TNewComboBox;
  PreviewText: TNewStaticText;
  PrefilledFor: String;      { the folder whose reaper-kb.ini filled the page }
  ExistingShortcut: String;  { what Samanvaya is bound to there now, if anything }
  ReplaceOk: Boolean;        { the user agreed to take the key from another action }
  InstalledShortcut: String; { what was written, for the Finished page }

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

{ ── Keys the shortcut page offers ─────────────────────────────── }

function KeyVk(Index: Integer): Integer;
begin
  if Index < 26 then
    Result := 65 + Index             { A-Z }
  else if Index < 36 then
    Result := 48 + Index - 26        { 0-9 }
  else
    Result := 112 + Index - 36;      { F1-F12 }
end;

function KeyName(Index: Integer): String;
begin
  if Index < 36 then
    Result := Chr(KeyVk(Index))
  else
    Result := 'F' + IntToStr(Index - 35);
end;

function IndexOfVk(Vk: Integer): Integer;
var
  I: Integer;
begin
  Result := -1;
  for I := 0 to KeyCount - 1 do
    if KeyVk(I) = Vk then
    begin
      Result := I;
      Exit;
    end;
end;

function ShortcutText(Flags, Vk: Integer): String;
var
  I: Integer;
begin
  Result := '';
  if (Flags and FlagCtrl) <> 0 then Result := Result + 'Ctrl+';
  if (Flags and FlagAlt) <> 0 then Result := Result + 'Alt+';
  if (Flags and FlagShift) <> 0 then Result := Result + 'Shift+';
  I := IndexOfVk(Vk);
  if I >= 0 then
    Result := Result + KeyName(I)
  else
    Result := Result + 'key ' + IntToStr(Vk);
end;

{ "Ctrl+Shift+A", "A" or "none", for /SHORTCUT= on the command line. }
function ParseShortcut(S: String; var Enabled: Boolean; var Flags, Vk: Integer): Boolean;
var
  Part: String;
  P, I: Integer;
begin
  Result := False;
  S := Uppercase(Trim(S));
  Flags := 1;
  Vk := 65;
  if S = 'NONE' then
  begin
    Enabled := False;
    Result := True;
    Exit;
  end;
  P := Pos('+', S);
  while P > 0 do
  begin
    Part := Trim(Copy(S, 1, P - 1));
    Delete(S, 1, P);
    if Part = 'CTRL' then Flags := Flags or FlagCtrl
    else if Part = 'ALT' then Flags := Flags or FlagAlt
    else if Part = 'SHIFT' then Flags := Flags or FlagShift
    else Exit;
    P := Pos('+', S);
  end;
  S := Trim(S);
  for I := 0 to KeyCount - 1 do
    if KeyName(I) = S then
    begin
      Vk := KeyVk(I);
      Enabled := True;
      Result := True;
      Exit;
    end;
end;

{ ── reaper-kb.ini lines ────────────────────────────────────────── }

{ Cuts the first line, line break included, off Rest. }
function NextLine(var Rest: AnsiString): AnsiString;
var
  P: Integer;
begin
  P := Pos(#10, Rest);
  if P = 0 then
  begin
    Result := Rest;
    Rest := '';
  end else
  begin
    Result := Copy(Rest, 1, P);
    Delete(Rest, 1, P);
  end;
end;

{ The N-th whitespace-separated word of a line, from 1. }
function Token(Line: String; N: Integer): String;
var
  I, Count: Integer;
begin
  Result := '';
  Count := 0;
  I := 1;
  while I <= Length(Line) do
  begin
    while (I <= Length(Line)) and (Line[I] <= ' ') do
      I := I + 1;
    if I > Length(Line) then
      Exit;
    Count := Count + 1;
    Result := '';
    while (I <= Length(Line)) and (Line[I] > ' ') do
    begin
      Result := Result + Line[I];
      I := I + 1;
    end;
    if Count = N then
      Exit;
  end;
  Result := '';
end;

function IsMainKeyLine(Line: String): Boolean;
begin
  Result := (Token(Line, 1) = 'KEY') and (Token(Line, 5) = '0');
end;

function IsOurKeyLine(Line: String): Boolean;
begin
  Result := IsMainKeyLine(Line) and (Token(Line, 4) = '_' + CmdId);
end;

{ The command another action holds this key with, or ''. }
function KeyOwner(Kb: AnsiString; Flags, Vk: Integer): String;
var
  Rest, Line: AnsiString;
begin
  Result := '';
  Rest := Kb;
  while Length(Rest) > 0 do
  begin
    Line := NextLine(Rest);
    if IsMainKeyLine(Line) and not IsOurKeyLine(Line) and
       (Token(Line, 2) = IntToStr(Flags)) and (Token(Line, 3) = IntToStr(Vk)) then
    begin
      Result := Token(Line, 4);
      Exit;
    end;
  end;
end;

{ A readable name for a command in a KEY line. Scripts and custom actions
  have their name in their own SCR/ACT line; built-in ones are numbers. }
function ActionName(Kb: AnsiString; Cmd: String): String;
var
  Rest, Line: AnsiString;
  Id: String;
  P: Integer;
begin
  if (Length(Cmd) > 0) and (Cmd[1] <> '_') then
  begin
    Result := 'REAPER action ' + Cmd;
    Exit;
  end;
  Result := 'the action ' + Cmd;
  Id := Copy(Cmd, 2, Length(Cmd));
  Rest := Kb;
  while Length(Rest) > 0 do
  begin
    Line := NextLine(Rest);
    if ((Token(Line, 1) = 'SCR') or (Token(Line, 1) = 'ACT')) and (Pos(Id, Line) > 0) then
    begin
      { The name is the first quoted text after the id (ACT quotes the id itself). }
      Line := Copy(Line, Pos(Id, Line) + Length(Id) + 1, Length(Line));
      P := Pos('"', Line);
      if P = 0 then Exit;
      Delete(Line, 1, P);
      P := Pos('"', Line);
      if P > 1 then
        Result := '"' + Copy(Line, 1, P - 1) + '"';
      Exit;
    end;
  end;
end;

{ ── Shortcut page ──────────────────────────────────────────────── }

function ChosenFlags(): Integer;
begin
  Result := 1;
  if CtrlBox.Checked then Result := Result or FlagCtrl;
  if AltBox.Checked then Result := Result or FlagAlt;
  if ShiftBox.Checked then Result := Result or FlagShift;
end;

function ChosenVk(): Integer;
begin
  Result := KeyVk(KeyCombo.ItemIndex);
end;

function ShortcutSummary(): String;
begin
  if ShortcutBox.Checked then
    Result := ShortcutText(ChosenFlags(), ChosenVk())
  else if ExistingShortcut <> '' then
    Result := 'keep ' + ExistingShortcut
  else
    Result := 'none';
end;

procedure UpdateShortcutPage();
begin
  CtrlBox.Enabled := ShortcutBox.Checked;
  AltBox.Enabled := ShortcutBox.Checked;
  ShiftBox.Enabled := ShortcutBox.Checked;
  KeyCombo.Enabled := ShortcutBox.Checked;
  if ShortcutBox.Checked then
    PreviewText.Caption := 'Samanvaya will open with:  ' + ShortcutText(ChosenFlags(), ChosenVk())
  else if ExistingShortcut <> '' then
    PreviewText.Caption := 'Samanvaya keeps the shortcut it already has:  ' + ExistingShortcut
  else
    PreviewText.Caption := 'No shortcut. Samanvaya stays in Actions > Show action list.';
end;

procedure ShortcutChanged(Sender: TObject);
begin
  ReplaceOk := False;
  UpdateShortcutPage();
end;

procedure SetChoice(Enabled: Boolean; Flags, Vk: Integer);
var
  I: Integer;
begin
  ShortcutBox.Checked := Enabled;
  CtrlBox.Checked := (Flags and FlagCtrl) <> 0;
  AltBox.Checked := (Flags and FlagAlt) <> 0;
  ShiftBox.Checked := (Flags and FlagShift) <> 0;
  I := IndexOfVk(Vk);
  if I < 0 then I := 0;
  KeyCombo.ItemIndex := I;
  ReplaceOk := False;
  UpdateShortcutPage();
end;

{ Fills the page from /SHORTCUT=, else from the shortcut Samanvaya already
  has in this REAPER, else A. Runs again only if the folder changes, so a
  choice made on the page is not overwritten. }
procedure PrefillShortcut();
var
  Kb, Rest, Line: AnsiString;
  Enabled, Found: Boolean;
  Flags, Vk: Integer;
begin
  if PrefilledFor = WizardDirValue() then
    Exit;
  PrefilledFor := WizardDirValue();
  ExistingShortcut := '';
  if not LoadStringFromFile(KbPath(), Kb) then
    Kb := '';
  Found := False;
  Rest := Kb;
  while (Length(Rest) > 0) and not Found do
  begin
    Line := NextLine(Rest);
    if IsOurKeyLine(Line) then
    begin
      Found := True;
      Flags := StrToIntDef(Token(Line, 2), 1);
      Vk := StrToIntDef(Token(Line, 3), 65);
      ExistingShortcut := ShortcutText(Flags, Vk);
    end;
  end;

  if ParseShortcut(ExpandConstant('{param:SHORTCUT|}'), Enabled, Flags, Vk) then
    SetChoice(Enabled, Flags, Vk)
  else if Found and (IndexOfVk(Vk) >= 0) then
    SetChoice(True, Flags, Vk)
  else if Found or (Pos(CmdId, Kb) > 0) then
    { An update where the user removed the shortcut, or bound a key this
      page cannot show: leave it as it is. }
    SetChoice(False, 1, 65)
  else
    SetChoice(True, 1, 65);
end;

procedure CreateShortcutPage();
var
  Note, Plus: TNewStaticText;
  I, Y: Integer;
begin
  ShortcutPage := CreateCustomPage(wpSelectDir, 'Keyboard shortcut',
    'Choose the key that opens Samanvaya in REAPER.');

  ShortcutBox := TNewCheckBox.Create(ShortcutPage);
  ShortcutBox.Parent := ShortcutPage.Surface;
  ShortcutBox.Caption := 'Open Samanvaya with a keyboard shortcut';
  ShortcutBox.Width := ShortcutPage.SurfaceWidth;
  ShortcutBox.Height := ScaleY(17);
  ShortcutBox.OnClick := @ShortcutChanged;

  Y := ScaleY(36);
  CtrlBox := TNewCheckBox.Create(ShortcutPage);
  CtrlBox.Parent := ShortcutPage.Surface;
  CtrlBox.Caption := 'Ctrl';
  CtrlBox.Left := ScaleX(20);
  CtrlBox.Top := Y + ScaleY(3);
  CtrlBox.Width := ScaleX(60);
  CtrlBox.Height := ScaleY(17);
  CtrlBox.OnClick := @ShortcutChanged;

  AltBox := TNewCheckBox.Create(ShortcutPage);
  AltBox.Parent := ShortcutPage.Surface;
  AltBox.Caption := 'Alt';
  AltBox.Left := ScaleX(85);
  AltBox.Top := CtrlBox.Top;
  AltBox.Width := ScaleX(55);
  AltBox.Height := ScaleY(17);
  AltBox.OnClick := @ShortcutChanged;

  ShiftBox := TNewCheckBox.Create(ShortcutPage);
  ShiftBox.Parent := ShortcutPage.Surface;
  ShiftBox.Caption := 'Shift';
  ShiftBox.Left := ScaleX(145);
  ShiftBox.Top := CtrlBox.Top;
  ShiftBox.Width := ScaleX(60);
  ShiftBox.Height := ScaleY(17);
  ShiftBox.OnClick := @ShortcutChanged;

  Plus := TNewStaticText.Create(ShortcutPage);
  Plus.Parent := ShortcutPage.Surface;
  Plus.Caption := '+';
  Plus.Left := ScaleX(212);
  Plus.Top := CtrlBox.Top;

  KeyCombo := TNewComboBox.Create(ShortcutPage);
  KeyCombo.Parent := ShortcutPage.Surface;
  KeyCombo.Style := csDropDownList;
  KeyCombo.Left := ScaleX(230);
  KeyCombo.Top := Y;
  KeyCombo.Width := ScaleX(80);
  for I := 0 to KeyCount - 1 do
    KeyCombo.Items.Add(KeyName(I));
  KeyCombo.ItemIndex := 0;
  KeyCombo.OnChange := @ShortcutChanged;

  PreviewText := TNewStaticText.Create(ShortcutPage);
  PreviewText.Parent := ShortcutPage.Surface;
  PreviewText.Top := ScaleY(84);
  PreviewText.Font.Style := [fsBold];

  Note := TNewStaticText.Create(ShortcutPage);
  Note.Parent := ShortcutPage.Surface;
  Note.Top := ScaleY(120);
  Note.Width := ShortcutPage.SurfaceWidth;
  Note.AutoSize := False;
  Note.WordWrap := True;
  Note.Height := ScaleY(80);
  Note.Caption := 'Setup warns you if a key you set yourself in REAPER is already on another action. ' +
    'REAPER''s own default keys cannot be checked from here: if you pick one of those, ' +
    'it opens Samanvaya instead.' + #13#10#13#10 +
    'You can change the shortcut later in REAPER under Actions > Show action list.';

  SetChoice(True, 1, 65);
end;

{ reaper-kb.ini is handled as raw bytes (AnsiString) so lines holding
  non-ASCII script paths survive exactly as REAPER wrote them. }
procedure RegisterAction();
var
  Kb, Rest, Line, OutKb: AnsiString;
  Flags, Vk: Integer;
  Owner: String;
  HasScr, SetKey, Drop: Boolean;
begin
  PrefillShortcut();
  if not LoadStringFromFile(KbPath(), Kb) then
    Kb := '';
  SetKey := ShortcutBox.Checked;
  Flags := ChosenFlags();
  Vk := ChosenVk();
  InstalledShortcut := '';
  if SetKey then
  begin
    Owner := KeyOwner(Kb, Flags, Vk);
    { Asked on the shortcut page; a silent install never takes a key. }
    if (Owner <> '') and not ReplaceOk then
    begin
      Log('Shortcut ' + ShortcutText(Flags, Vk) + ' is held by ' + Owner + '; not assigned.');
      SetKey := False;
    end;
  end;

  { Drop Samanvaya's old shortcut and whatever else holds the new key, then
    append the action and the new shortcut. }
  HasScr := False;
  OutKb := '';
  Rest := Kb;
  while Length(Rest) > 0 do
  begin
    Line := NextLine(Rest);
    if (Token(Line, 1) = 'SCR') and (Token(Line, 4) = CmdId) then
      HasScr := True;
    Drop := SetKey and IsMainKeyLine(Line) and (IsOurKeyLine(Line) or
      ((Token(Line, 2) = IntToStr(Flags)) and (Token(Line, 3) = IntToStr(Vk))));
    if not Drop then
      OutKb := OutKb + Line;
  end;
  if (Length(OutKb) > 0) and (OutKb[Length(OutKb)] <> #10) then
    OutKb := OutKb + #13#10;
  if not HasScr then
    OutKb := OutKb + KbLine + #13#10;
  if SetKey then
  begin
    OutKb := OutKb + 'KEY ' + IntToStr(Flags) + ' ' + IntToStr(Vk) + ' _' + CmdId + ' 0' + #13#10;
    InstalledShortcut := ShortcutText(Flags, Vk);
  end else
    InstalledShortcut := ExistingShortcut;
  if OutKb = Kb then
    Exit;
  if not SaveStringToFile(KbPath(), OutKb, False) then
  begin
    InstalledShortcut := '';
    SuppressibleMsgBox('Could not add Samanvaya to the REAPER Action List.' + #13#10 +
      'In REAPER, use Actions > Show action list > New action > Load ReaScript and pick:' + #13#10 +
      ExpandConstant('{app}\Scripts\Samanvaya\Samanvaya.lua'), mbError, MB_OK, IDOK);
  end;
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
  CreateShortcutPage();
end;

procedure CurPageChanged(CurPageID: Integer);
var
  Text: String;
begin
  if CurPageID = ShortcutPage.ID then
    PrefillShortcut()
  else if CurPageID = wpFinished then
  begin
    if InstalledShortcut <> '' then
      Text := 'Open REAPER and press ' + InstalledShortcut + ' to open Samanvaya. ' +
        'It is also in Actions > Show action list.'
    else
      Text := 'Open REAPER, then go to Actions > Show action list and search for "Samanvaya".';
    WizardForm.FinishedLabel.Caption := Text + #13#10#13#10 +
      'The first time it runs, Samanvaya will offer to install ReaImGui if REAPER does not have it yet.';
    WizardForm.AdjustLabelHeight(WizardForm.FinishedLabel);
  end;
end;

function NextButtonClick(CurPageID: Integer): Boolean;
var
  Kb: AnsiString;
  Owner: String;
begin
  Result := True;
  if CurPageID = wpSelectDir then
  begin
    if not FileExists(AddBackslash(WizardDirValue()) + 'reaper.ini') then
      Result := SuppressibleMsgBox('No reaper.ini was found in:' + #13#10 + WizardDirValue() + #13#10#13#10 +
        'This does not look like a REAPER resource folder. If REAPER has never been ' +
        'started on this computer, start it once first.' + #13#10#13#10 +
        'Install here anyway?', mbConfirmation, MB_YESNO, IDNO) = IDYES;
  end
  { Silent installs skip this: RegisterAction leaves a taken key alone. }
  else if (CurPageID = ShortcutPage.ID) and ShortcutBox.Checked and not ReplaceOk and not WizardSilent() then
  begin
    if not LoadStringFromFile(KbPath(), Kb) then
      Kb := '';
    Owner := KeyOwner(Kb, ChosenFlags(), ChosenVk());
    if Owner <> '' then
    begin
      Result := SuppressibleMsgBox(ShortcutText(ChosenFlags(), ChosenVk()) +
        ' is already used in this REAPER by ' + ActionName(Kb, Owner) + '.' + #13#10#13#10 +
        'Give this key to Samanvaya instead?' + #13#10 +
        'Choose No to pick a different key.', mbConfirmation, MB_YESNO, IDNO) = IDYES;
      ReplaceOk := Result;
    end;
  end;
end;

function UpdateReadyMemo(Space, NewLine, MemoUserInfoInfo, MemoDirInfo, MemoTypeInfo,
  MemoComponentsInfo, MemoGroupInfo, MemoTasksInfo: String): String;
begin
  Result := MemoDirInfo + NewLine + NewLine +
    'Keyboard shortcut:' + NewLine + Space + ShortcutSummary();
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
