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

  { Shortcut page colours (TColor is $BBGGRR), matching the wizard art. }
  ColCard    = $100C0A;
  ColCap     = $F2EFEC;
  ColCapEdge = $77716C;
  ColCapText = $201A16;
  ColTeal    = $BFD42D;
  ColAmber   = $0B9EF5;
  ColMuted   = $9A948E;

var
  ShortcutPage: TWizardPage;
  ShortcutBox, CtrlBox, AltBox, ShiftBox: TNewCheckBox;
  KeyCombo: TNewComboBox;
  Card: TPanel;
  Caps, CapEdges: array[0..3] of TPanel;
  Pluses: array[0..2] of TNewStaticText;
  NoKeyText, StatusText, FolderText: TNewStaticText;
  CurrentKb: AnsiString;     { reaper-kb.ini of the chosen folder, for the live check }
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

function CapWidth(Text: String): Integer;
begin
  Result := ScaleX(26 + 10 * Length(Text));
  if Result < ScaleX(44) then
    Result := ScaleX(44);
end;

procedure CenterInCard(Text: TNewStaticText);
begin
  Text.Left := (Card.Width - Text.Width) div 2;
end;

{ Draws the chosen keys as keycaps, centred in the card. }
procedure LayoutCaps();
var
  Texts: array[0..3] of String;
  N, I, X, W, Total, PlusW, CapTop, CapH: Integer;
begin
  N := 0;
  if ShortcutBox.Checked then
  begin
    if CtrlBox.Checked then begin Texts[N] := 'Ctrl'; N := N + 1; end;
    if AltBox.Checked then begin Texts[N] := 'Alt'; N := N + 1; end;
    if ShiftBox.Checked then begin Texts[N] := 'Shift'; N := N + 1; end;
    Texts[N] := KeyName(KeyCombo.ItemIndex);
    N := N + 1;
  end;

  PlusW := ScaleX(24);
  CapTop := ScaleY(34);
  CapH := ScaleY(36);
  Total := 0;
  for I := 0 to N - 1 do
    Total := Total + CapWidth(Texts[I]);
  if N > 1 then
    Total := Total + (N - 1) * PlusW;
  X := (Card.Width - Total) div 2;

  for I := 0 to 3 do
  begin
    Caps[I].Visible := I < N;
    CapEdges[I].Visible := I < N;
    if I < 3 then
      Pluses[I].Visible := I < N - 1;
    if I < N then
    begin
      W := CapWidth(Texts[I]);
      Caps[I].Caption := Texts[I];
      Caps[I].Left := X;
      Caps[I].Top := CapTop;
      Caps[I].Width := W;
      Caps[I].Height := CapH;
      { A darker slab just below the cap gives it a pressed-key edge. }
      CapEdges[I].Left := X;
      CapEdges[I].Top := CapTop + ScaleY(4);
      CapEdges[I].Width := W;
      CapEdges[I].Height := CapH;
      X := X + W;
      if I < N - 1 then
      begin
        Pluses[I].Left := X + (PlusW - Pluses[I].Width) div 2;
        Pluses[I].Top := CapTop + (CapH - Pluses[I].Height) div 2;
        X := X + PlusW;
      end;
    end;
  end;
  NoKeyText.Visible := N = 0;
end;

procedure UpdateShortcutPage();
var
  Owner: String;
begin
  CtrlBox.Enabled := ShortcutBox.Checked;
  AltBox.Enabled := ShortcutBox.Checked;
  ShiftBox.Enabled := ShortcutBox.Checked;
  KeyCombo.Enabled := ShortcutBox.Checked;
  LayoutCaps();

  if not ShortcutBox.Checked then
  begin
    StatusText.Font.Color := ColMuted;
    if ExistingShortcut <> '' then
      StatusText.Caption := 'Samanvaya keeps the shortcut it has now: ' + ExistingShortcut
    else
      StatusText.Caption := 'Run it from Actions > Show action list';
  end else
  begin
    Owner := KeyOwner(CurrentKb, ChosenFlags(), ChosenVk());
    if Owner <> '' then
    begin
      StatusText.Font.Color := ColAmber;
      StatusText.Caption := 'Already used by ' + ActionName(CurrentKb, Owner) + '. Setup will ask first.';
    end else
    begin
      StatusText.Font.Color := ColTeal;
      if ShortcutText(ChosenFlags(), ChosenVk()) = ExistingShortcut then
        StatusText.Caption := 'This is Samanvaya''s shortcut now'
      else
        StatusText.Caption := 'Free in this REAPER';
    end;
  end;
  CenterInCard(StatusText);
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
  Flags, Vk, ParamFlags, ParamVk: Integer;
begin
  if PrefilledFor = WizardDirValue() then
    Exit;
  PrefilledFor := WizardDirValue();
  ExistingShortcut := '';
  if not LoadStringFromFile(KbPath(), Kb) then
    Kb := '';
  CurrentKb := Kb;
  FolderText.Caption := 'REAPER folder:  ' +
    MinimizePathName(WizardDirValue(), FolderText.Font, ShortcutPage.SurfaceWidth - ScaleX(100));
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

  if ParseShortcut(ExpandConstant('{param:SHORTCUT|}'), Enabled, ParamFlags, ParamVk) then
    SetChoice(Enabled, ParamFlags, ParamVk)
  else if Found and (IndexOfVk(Vk) >= 0) then
    SetChoice(True, Flags, Vk)
  else if Found or (Pos(CmdId, Kb) > 0) then
    { An update where the user removed the shortcut, or bound a key this
      page cannot show: leave it as it is. }
    SetChoice(False, 1, 65)
  else
    SetChoice(True, 1, 65);
end;

function CardText(Caption: String; Size: Integer; Color: TColor): TNewStaticText;
begin
  Result := TNewStaticText.Create(ShortcutPage);
  Result.Parent := Card;
  Result.Font.Name := 'Segoe UI';
  Result.Font.Size := Size;
  Result.Font.Color := Color;
  Result.Caption := Caption;
end;

function ModifierBox(Caption: String; Left, Top: Integer): TNewCheckBox;
begin
  Result := TNewCheckBox.Create(ShortcutPage);
  Result.Parent := ShortcutPage.Surface;
  Result.Caption := Caption;
  Result.Left := Left;
  Result.Top := Top;
  Result.Width := ScaleX(56);
  Result.Height := ScaleY(17);
  Result.OnClick := @ShortcutChanged;
end;

procedure CreateShortcutPage();
var
  Title, KeyLabel, Note: TNewStaticText;
  I, Y: Integer;
begin
  ShortcutPage := CreateCustomPage(wpSelectDir, 'Keyboard shortcut',
    'Pick the key that opens Samanvaya in REAPER.');

  { Dark card with the shortcut drawn as keycaps and a live status line. }
  Card := TPanel.Create(ShortcutPage);
  Card.Parent := ShortcutPage.Surface;
  Card.Width := ShortcutPage.SurfaceWidth;
  Card.Height := ScaleY(108);
  Card.BevelOuter := bvNone;
  Card.ParentBackground := False;
  Card.Color := ColCard;

  Title := CardText('SAMANVAYA OPENS WITH', 7, ColMuted);
  Title.Font.Style := [fsBold];
  Title.Top := ScaleY(10);
  CenterInCard(Title);

  for I := 0 to 3 do
  begin
    CapEdges[I] := TPanel.Create(ShortcutPage);
    CapEdges[I].Parent := Card;
    CapEdges[I].BevelOuter := bvNone;
    CapEdges[I].ParentBackground := False;
    CapEdges[I].Color := ColCapEdge;
    Caps[I] := TPanel.Create(ShortcutPage);
    Caps[I].Parent := Card;
    Caps[I].BevelOuter := bvNone;
    Caps[I].ParentBackground := False;
    Caps[I].Color := ColCap;
    Caps[I].Font.Name := 'Segoe UI';
    Caps[I].Font.Size := 13;
    Caps[I].Font.Style := [fsBold];
    Caps[I].Font.Color := ColCapText;
  end;
  for I := 0 to 2 do
  begin
    Pluses[I] := CardText('+', 14, ColTeal);
    Pluses[I].Font.Style := [fsBold];
  end;

  NoKeyText := CardText('No shortcut', 13, ColMuted);
  NoKeyText.Top := ScaleY(40);
  CenterInCard(NoKeyText);

  StatusText := CardText('', 9, ColTeal);
  StatusText.Top := ScaleY(82);

  { Controls }
  Y := Card.Top + Card.Height + ScaleY(14);
  ShortcutBox := TNewCheckBox.Create(ShortcutPage);
  ShortcutBox.Parent := ShortcutPage.Surface;
  ShortcutBox.Caption := 'Open Samanvaya with a keyboard shortcut';
  ShortcutBox.Top := Y;
  ShortcutBox.Width := ShortcutPage.SurfaceWidth;
  ShortcutBox.Height := ScaleY(17);
  ShortcutBox.OnClick := @ShortcutChanged;

  Y := Y + ScaleY(28);
  KeyLabel := TNewStaticText.Create(ShortcutPage);
  KeyLabel.Parent := ShortcutPage.Surface;
  KeyLabel.Caption := 'Key:';
  KeyLabel.Left := ScaleX(18);
  KeyLabel.Top := Y + ScaleY(3);

  KeyCombo := TNewComboBox.Create(ShortcutPage);
  KeyCombo.Parent := ShortcutPage.Surface;
  KeyCombo.Style := csDropDownList;
  KeyCombo.Left := ScaleX(50);
  KeyCombo.Top := Y;
  KeyCombo.Width := ScaleX(64);
  for I := 0 to KeyCount - 1 do
    KeyCombo.Items.Add(KeyName(I));
  KeyCombo.ItemIndex := 0;
  KeyCombo.OnChange := @ShortcutChanged;

  CtrlBox := ModifierBox('Ctrl', ScaleX(140), Y + ScaleY(3));
  AltBox := ModifierBox('Alt', ScaleX(200), Y + ScaleY(3));
  ShiftBox := ModifierBox('Shift', ScaleX(256), Y + ScaleY(3));

  Y := Y + ScaleY(34);
  FolderText := TNewStaticText.Create(ShortcutPage);
  FolderText.Parent := ShortcutPage.Surface;
  FolderText.Top := Y;
  FolderText.Font.Color := clGrayText;

  Note := TNewStaticText.Create(ShortcutPage);
  Note.Parent := ShortcutPage.Surface;
  Note.Top := Y + ScaleY(18);
  Note.Width := ShortcutPage.SurfaceWidth;
  Note.AutoSize := False;
  Note.WordWrap := True;
  Note.Height := ShortcutPage.SurfaceHeight - Note.Top;
  Note.Font.Color := clGrayText;
  Note.Caption := 'REAPER''s built-in keys cannot be checked from here. If you pick one, it opens ' +
    'Samanvaya instead. You can change the shortcut later in Actions > Show action list.';

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
  { The folder offered is the last install's, or %APPDATA%\REAPER. If it
    holds no reaper.ini (the last install went to a folder that is gone or
    was never REAPER's), fall back to %APPDATA%\REAPER, then to a portable
    REAPER in Program Files, which keeps reaper.ini beside reaper.exe. }
  if not FileExists(AddBackslash(WizardForm.DirEdit.Text) + 'reaper.ini') then
  begin
    if FileExists(ExpandConstant('{userappdata}\REAPER\reaper.ini')) then
      WizardForm.DirEdit.Text := ExpandConstant('{userappdata}\REAPER')
    else if FileExists(ExpandConstant('{autopf}\REAPER (x64)\reaper.ini')) then
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
