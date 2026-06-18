{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  Configuration model + INI persistence.

  Three sections, all built on TTermAction:
    * Profiles       - appearance (font, fg, bg) applied to a tab's view.
    * Keybindings    - key chord  -> action.
    * Signal bindings- OSC code / bell / title -> action.

  Persisted as a single INI file (TIniFile) in the app config dir, matching
  the project's existing INI/GKeyFile-style font persistence.
}
unit TermFpGUI.Config;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, IniFiles, fpg_base,
  TermFpGUI.Actions, Terminal.View.fpGUI;

type
  { How the hover drawer reveals itself. }
  TTermDrawerAnim = (tdaFade, tdaAssemble, tdaNone);
  { When the drawer's program is launched. }
  TTermDrawerLaunch = (tdlOnShow, tdlOnStart);
  { What to do to a still-running hosted program when the drawer's tab/window
    closes.  Only meaningful for a live custom program — a terminal copy idling
    at its shell prompt just closes (tdkNone behaviour) regardless. }
  TTermDrawerShutdown = (tdkNone,    // let it fail when the console closes
                         tdkSignal,  // send DrawerShutdownSignal to the child
                         tdkKeys);   // type DrawerShutdownKeys (e.g. exit\r)

  TTermProfile = class
  public
    Name: string;
    FontDesc: string;
    FGColor: TfpgColor;
    BGColor: TfpgColor;
    { Hover-drawer overlay defined by this profile (one per profile). The edge
      it docks to is TTermViewEdge (veLeft/veRight/veTop/veBottom; veNone when
      disabled-by-gravity is irrelevant — DrawerEnabled gates it). }
    DrawerEnabled: Boolean;
    DrawerName: string;            // label shown on the handle / tab
    DrawerCommand: string;         // '' = default login shell
    DrawerGravity: TTermViewEdge;  // which edge it hides on
    DrawerSizeFrac: Double;        // 0.1..0.9 of content width/height
    DrawerAnim: TTermDrawerAnim;
    DrawerLaunch: TTermDrawerLaunch;
    DrawerColorProfile: string;    // profile whose fg/bg the drawer uses; '' = own
    DrawerShutdown: TTermDrawerShutdown; // how to stop a live custom program
    DrawerShutdownSignal: Integer; // signal number for tdkSignal (e.g. 15=TERM)
    DrawerShutdownKeys: string;    // key/byte seq for tdkKeys (\n \r \e \xNN ^D)
    constructor Create(const AName, AFont: string; AFG, ABG: TfpgColor);
    procedure ApplyTo(AView: TTerminalFPGUIView);
  end;

  TTermKeyBinding = class
  public
    KeyCode: Word;
    Shift: TShiftState;
    Action: TTermAction;          // owned
    destructor Destroy; override;
    function ChordText: string;
  end;

  { Signal sources.  tskOSC carries a Code; bell/title ignore it. }
  TTermSignalKind = (tskOSC, tskBell, tskTitle);

  TTermSignalBinding = class
  public
    Kind: TTermSignalKind;
    Code: Integer;
    Action: TTermAction;          // owned
    destructor Destroy; override;
    function SignalText: string;
  end;

  TTermConfig = class
  private
    FProfiles: TFPList;
    FKeys: TFPList;
    FSignals: TFPList;
    FTheme: string;
    FActiveProfile: string;
    FFont: string;
    FEmojiFont: string;
    FLinkOpenCommand: string;
    FDesktopPromptDismissed: Boolean;
    function GetProfile(I: Integer): TTermProfile;
    function GetKey(I: Integer): TTermKeyBinding;
    function GetSignal(I: Integer): TTermSignalBinding;
    function GetProfileCount: Integer;
    function GetKeyCount: Integer;
    function GetSignalCount: Integer;
  public
    constructor Create;
    destructor Destroy; override;
    procedure Clear;
    procedure LoadDefaults;
    procedure Load(const APath: string);
    procedure Save(const APath: string);

    function AddProfile(P: TTermProfile): TTermProfile;
    function AddKey(AKeyCode: Word; AShift: TShiftState; AAction: TTermAction): TTermKeyBinding;
    function AddSignal(AKind: TTermSignalKind; ACode: Integer; AAction: TTermAction): TTermSignalBinding;
    procedure RemoveProfile(AIndex: Integer);
    procedure RemoveKey(AIndex: Integer);
    procedure RemoveSignal(AIndex: Integer);

    function FindProfile(const AName: string): TTermProfile;
    function MatchKey(AKeyCode: Word; AShift: TShiftState): TTermKeyBinding;
    function MatchOSC(ACode: Integer): TTermSignalBinding;
    function MatchSignalKind(AKind: TTermSignalKind): TTermSignalBinding;

    property ProfileCount: Integer read GetProfileCount;
    property Profiles[I: Integer]: TTermProfile read GetProfile;
    property KeyCount: Integer read GetKeyCount;
    property Keys[I: Integer]: TTermKeyBinding read GetKey;
    property SignalCount: Integer read GetSignalCount;
    property Signals[I: Integer]: TTermSignalBinding read GetSignal;
    property Theme: string read FTheme write FTheme;
    { Name of the profile currently applied; restored at startup and shown
      checked in the Profile menu.  '' falls back to the first profile. }
    property ActiveProfile: string read FActiveProfile write FActiveProfile;
    { Last font chosen via the view's right-click menu; '' = use profile font. }
    property Font: string read FFont write FFont;
    property EmojiFont: string read FEmojiFont write FEmojiFont;
    { Custom opener for OSC 8 hyperlinks; '%u' is replaced with the URI.
      Empty = let the view fall back to its built-in xdg-open. }
    property LinkOpenCommand: string read FLinkOpenCommand write FLinkOpenCommand;
    { Set once the user picks "Don't ask again" on the desktop-install prompt. }
    property DesktopPromptDismissed: Boolean read FDesktopPromptDismissed
      write FDesktopPromptDismissed;
  end;

  { An "app mode" launch config (loaded via --app <file>): runs a single program
    in the main terminal, optionally with a configured drawer, and the host hides
    the tab strip.  The appearance + drawer live in Profile (it reuses the very
    same INI keys a normal profile uses), so anything a profile can express the
    app config can too. }
  TTermAppConfig = class
  private
    FProfile: TTermProfile;
  public
    Title: string;        // window title ('' = leave default)
    Command: string;      // main program for the terminal ('' = login shell)
    Theme: string;        // fpGUI style override ('' = leave config's theme)
    constructor Create;
    destructor Destroy; override;
    { Read the [App] section.  Returns False if the file is missing. }
    function Load(const APath: string): Boolean;
    { Hand the profile to a caller that takes ownership (e.g. a TTermConfig);
      after this the app config no longer frees it. }
    function TakeProfile: TTermProfile;
    property Profile: TTermProfile read FProfile;
  end;

{ Path of the INI in the per-user app config dir. }
function DefaultConfigPath: string;

implementation

uses
  StrUtils, fpg_main;

const
  CSignalKindNames: array[TTermSignalKind] of string = ('OSC', 'Bell', 'Title');

function DefaultConfigPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + 'termfpgui.ini';
end;

{ ---- shift-state encode/decode (e.g. [ssCtrl,ssShift] <-> 'CS') ---- }

function ShiftToStr(S: TShiftState): string;
begin
  Result := '';
  if ssCtrl  in S then Result := Result + 'C';
  if ssShift in S then Result := Result + 'S';
  if ssAlt   in S then Result := Result + 'A';
  if ssMeta  in S then Result := Result + 'M';
end;

function StrToShift(const S: string): TShiftState;
var
  i: Integer;
begin
  Result := [];
  for i := 1 to Length(S) do
    case UpCase(S[i]) of
      'C': Include(Result, ssCtrl);
      'S': Include(Result, ssShift);
      'A': Include(Result, ssAlt);
      'M': Include(Result, ssMeta);
    end;
end;

function ColorToHex(C: TfpgColor): string;
begin
  Result := IntToHex(LongWord(C) and $FFFFFF, 6);
end;

function HexToColor(const S: string): TfpgColor;
begin
  Result := TfpgColor(StrToIntDef('$' + Trim(S), 0));
end;

{ ---- drawer enum <-> ini string ---- }

function EdgeToStr(E: TTermViewEdge): string;
begin
  case E of
    veLeft:   Result := 'left';
    veRight:  Result := 'right';
    veTop:    Result := 'top';
    veBottom: Result := 'bottom';
  else        Result := 'none';
  end;
end;

function StrToEdge(const S: string): TTermViewEdge;
begin
  if SameText(S, 'left') then Result := veLeft
  else if SameText(S, 'top') then Result := veTop
  else if SameText(S, 'bottom') then Result := veBottom
  else if SameText(S, 'none') then Result := veNone
  else Result := veRight;
end;

{ Read every appearance + drawer field of a profile from section Sec into P.
  Shared by TTermConfig.Load (Profile.* sections) and TTermAppConfig.Load
  ([App]) so the two never drift apart. }
procedure ReadProfileFields(Ini: TIniFile; const Sec: string; P: TTermProfile);
begin
  P.FontDesc := Ini.ReadString(Sec, 'font', 'Monospace-11');
  P.FGColor  := HexToColor(Ini.ReadString(Sec, 'fg', 'FFFFFF'));
  P.BGColor  := HexToColor(Ini.ReadString(Sec, 'bg', '000000'));
  P.DrawerEnabled := Ini.ReadBool(Sec, 'drawer_enabled', False);
  P.DrawerName    := Ini.ReadString(Sec, 'drawer_name', 'Drawer');
  P.DrawerCommand := Ini.ReadString(Sec, 'drawer_command', '');
  P.DrawerGravity := StrToEdge(Ini.ReadString(Sec, 'drawer_gravity', 'right'));
  P.DrawerSizeFrac := Ini.ReadFloat(Sec, 'drawer_size', 0.33);
  case Ini.ReadString(Sec, 'drawer_anim', 'fade') of
    'assemble': P.DrawerAnim := tdaAssemble;
    'none':     P.DrawerAnim := tdaNone;
  else          P.DrawerAnim := tdaFade;
  end;
  if Ini.ReadString(Sec, 'drawer_launch', 'onshow') = 'onstart' then
    P.DrawerLaunch := tdlOnStart else P.DrawerLaunch := tdlOnShow;
  P.DrawerColorProfile := Ini.ReadString(Sec, 'drawer_colors', '');
  case Ini.ReadString(Sec, 'drawer_shutdown', 'none') of
    'signal': P.DrawerShutdown := tdkSignal;
    'keys':   P.DrawerShutdown := tdkKeys;
  else        P.DrawerShutdown := tdkNone;
  end;
  P.DrawerShutdownSignal := Ini.ReadInteger(Sec, 'drawer_signal', 15);
  P.DrawerShutdownKeys := Ini.ReadString(Sec, 'drawer_keys', 'exit\r');
end;

{ ---- action (de)serialisation under a key prefix within a section ---- }

procedure WriteAction(Ini: TIniFile; const Sec, Pfx: string; A: TTermAction);
begin
  if A.Kind = takExternal then
  begin
    Ini.WriteString(Sec, Pfx + 'kind', 'external');
    Ini.WriteString(Sec, Pfx + 'command', A.Command);
  end
  else
  begin
    Ini.WriteString(Sec, Pfx + 'kind', 'builtin');
    Ini.WriteString(Sec, Pfx + 'builtin', BuiltinToName(A.Builtin));
    Ini.WriteString(Sec, Pfx + 'arg', A.Arg);
  end;
end;

function ReadAction(Ini: TIniFile; const Sec, Pfx: string): TTermAction;
begin
  if SameText(Ini.ReadString(Sec, Pfx + 'kind', 'builtin'), 'external') then
    Result := TTermAction.CreateExternal(Ini.ReadString(Sec, Pfx + 'command', ''))
  else
    Result := TTermAction.CreateBuiltin(
      NameToBuiltin(Ini.ReadString(Sec, Pfx + 'builtin', 'None')),
      Ini.ReadString(Sec, Pfx + 'arg', ''));
end;

{ TTermProfile }

constructor TTermProfile.Create(const AName, AFont: string; AFG, ABG: TfpgColor);
begin
  inherited Create;
  Name := AName;
  FontDesc := AFont;
  FGColor := AFG;
  BGColor := ABG;
  { Drawer defaults: disabled, a shell on the right, fade in, lazy launch. }
  DrawerEnabled := False;
  DrawerName := 'Drawer';
  DrawerCommand := '';
  DrawerGravity := veRight;
  DrawerSizeFrac := 0.33;
  DrawerAnim := tdaFade;
  DrawerLaunch := tdlOnShow;
  DrawerColorProfile := '';
  DrawerShutdown := tdkNone;
  DrawerShutdownSignal := 15;   { SIGTERM }
  DrawerShutdownKeys := 'exit\r';
end;

procedure TTermProfile.ApplyTo(AView: TTerminalFPGUIView);
begin
  if AView = nil then Exit;
  if FontDesc <> '' then
    AView.FontDesc := FontDesc;
  AView.DefaultFGColor := FGColor;
  AView.DefaultBGColor := BGColor;
  AView.Invalidate;
end;

{ TTermKeyBinding }

destructor TTermKeyBinding.Destroy;
begin
  Action.Free;
  inherited Destroy;
end;

function TTermKeyBinding.ChordText: string;
begin
  { KeycodeToText (fpg_base) renders "Ctrl+Shift+C" etc. }
  Result := KeycodeToText(KeyCode, Shift);
end;

{ TTermSignalBinding }

destructor TTermSignalBinding.Destroy;
begin
  Action.Free;
  inherited Destroy;
end;

function TTermSignalBinding.SignalText: string;
begin
  if Kind = tskOSC then
    Result := 'OSC ' + IntToStr(Code)
  else
    Result := CSignalKindNames[Kind];
end;

{ TTermConfig }

constructor TTermConfig.Create;
begin
  inherited Create;
  FProfiles := TFPList.Create;
  FKeys := TFPList.Create;
  FSignals := TFPList.Create;
end;

destructor TTermConfig.Destroy;
begin
  Clear;
  FProfiles.Free;
  FKeys.Free;
  FSignals.Free;
  inherited Destroy;
end;

procedure TTermConfig.Clear;
var
  i: Integer;
begin
  for i := 0 to FProfiles.Count - 1 do TObject(FProfiles[i]).Free;
  for i := 0 to FKeys.Count - 1 do TObject(FKeys[i]).Free;
  for i := 0 to FSignals.Count - 1 do TObject(FSignals[i]).Free;
  FProfiles.Clear;
  FKeys.Clear;
  FSignals.Clear;
end;

function TTermConfig.GetProfile(I: Integer): TTermProfile;
begin Result := TTermProfile(FProfiles[I]); end;
function TTermConfig.GetKey(I: Integer): TTermKeyBinding;
begin Result := TTermKeyBinding(FKeys[I]); end;
function TTermConfig.GetSignal(I: Integer): TTermSignalBinding;
begin Result := TTermSignalBinding(FSignals[I]); end;
function TTermConfig.GetProfileCount: Integer;
begin Result := FProfiles.Count; end;
function TTermConfig.GetKeyCount: Integer;
begin Result := FKeys.Count; end;
function TTermConfig.GetSignalCount: Integer;
begin Result := FSignals.Count; end;

function TTermConfig.AddProfile(P: TTermProfile): TTermProfile;
begin FProfiles.Add(P); Result := P; end;

function TTermConfig.AddKey(AKeyCode: Word; AShift: TShiftState; AAction: TTermAction): TTermKeyBinding;
begin
  Result := TTermKeyBinding.Create;
  Result.KeyCode := AKeyCode;
  Result.Shift := AShift;
  Result.Action := AAction;
  FKeys.Add(Result);
end;

function TTermConfig.AddSignal(AKind: TTermSignalKind; ACode: Integer; AAction: TTermAction): TTermSignalBinding;
begin
  Result := TTermSignalBinding.Create;
  Result.Kind := AKind;
  Result.Code := ACode;
  Result.Action := AAction;
  FSignals.Add(Result);
end;

procedure TTermConfig.RemoveProfile(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FProfiles.Count) then Exit;
  TObject(FProfiles[AIndex]).Free;
  FProfiles.Delete(AIndex);
end;

procedure TTermConfig.RemoveKey(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FKeys.Count) then Exit;
  TObject(FKeys[AIndex]).Free;
  FKeys.Delete(AIndex);
end;

procedure TTermConfig.RemoveSignal(AIndex: Integer);
begin
  if (AIndex < 0) or (AIndex >= FSignals.Count) then Exit;
  TObject(FSignals[AIndex]).Free;
  FSignals.Delete(AIndex);
end;

function TTermConfig.FindProfile(const AName: string): TTermProfile;
var
  i: Integer;
begin
  for i := 0 to FProfiles.Count - 1 do
    if SameText(GetProfile(i).Name, AName) then
      Exit(GetProfile(i));
  Result := nil;
end;

function TTermConfig.MatchKey(AKeyCode: Word; AShift: TShiftState): TTermKeyBinding;
var
  i: Integer;
begin
  { Only Ctrl/Shift/Alt/Meta are meaningful for a chord; strip lock-key and
    mouse-button bits (ssNum/ssCaps/ssScroll/…) the backend folds into the
    shift-state, or an exact set compare misses every binding when e.g. NumLock
    is on.  The stored side already keeps only these four (see ShiftToStr). }
  AShift := AShift * [ssCtrl, ssShift, ssAlt, ssMeta];
  for i := 0 to FKeys.Count - 1 do
    if (GetKey(i).KeyCode = AKeyCode) and (GetKey(i).Shift = AShift) then
      Exit(GetKey(i));
  Result := nil;
end;

function TTermConfig.MatchOSC(ACode: Integer): TTermSignalBinding;
var
  i: Integer;
begin
  for i := 0 to FSignals.Count - 1 do
    if (GetSignal(i).Kind = tskOSC) and (GetSignal(i).Code = ACode) then
      Exit(GetSignal(i));
  Result := nil;
end;

function TTermConfig.MatchSignalKind(AKind: TTermSignalKind): TTermSignalBinding;
var
  i: Integer;
begin
  for i := 0 to FSignals.Count - 1 do
    if GetSignal(i).Kind = AKind then
      Exit(GetSignal(i));
  Result := nil;
end;

procedure TTermConfig.LoadDefaults;
begin
  Clear;
  FTheme := '';                          { '' = fpGUI's built-in default style }
  FActiveProfile := 'Default';
  FFont := '';
  FEmojiFont := '';
  FLinkOpenCommand := '';                { '' = view's built-in xdg-open }
  FDesktopPromptDismissed := False;

  { ---- Profiles ---- }
  AddProfile(TTermProfile.Create('Default',        'Monospace-11', clWhite,            TfpgColor($000000)));
  AddProfile(TTermProfile.Create('Solarized Dark', 'Monospace-11', TfpgColor($839496), TfpgColor($002B36)));
  AddProfile(TTermProfile.Create('Light',          'Monospace-11', TfpgColor($000000), TfpgColor($F5F5F5)));

  { ---- Keybindings (smart copy/paste: chord wins on selection) ---- }
  AddKey(Ord('C'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baCopy));
  AddKey(Ord('V'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baPaste));
  AddKey(keyInsert, [ssShift],        TTermAction.CreateBuiltin(baPaste));
  { Ctrl+C: copy when something is selected, else falls through to SIGINT. }
  AddKey(Ord('C'), [ssCtrl],          TTermAction.CreateBuiltin(baCopy));
  { Tab management }
  AddKey(Ord('T'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baNewTab));
  AddKey(Ord('W'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baCloseTab));
  AddKey(Ord('N'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baMoveToWindow));
  AddKey(keyPageDown, [ssCtrl],       TTermAction.CreateBuiltin(baNextTab));
  AddKey(keyPageUp,   [ssCtrl],       TTermAction.CreateBuiltin(baPrevTab));
  { Hover drawer toggle (quake-style). Profile must have a drawer enabled. }
  AddKey(Ord('D'), [ssCtrl, ssShift], TTermAction.CreateBuiltin(baToggleDrawer));

  { ---- Signal bindings (examples; user edits in Settings) ---- }
  { OSC 9 ; <text>  -> built-in desktop notification (iTerm2 convention). }
  AddSignal(tskOSC, 9,   TTermAction.CreateBuiltin(baNotify));
  { OSC 777 -> run an external notifier, passing the payload. }
  AddSignal(tskOSC, 777, TTermAction.CreateExternal('notify-send "Terminal" %p'));
end;

procedure TTermConfig.Load(const APath: string);
var
  Ini: TIniFile;
  Sections: TStringList;
  s, Name: string;
  i, n: Integer;
  P: TTermProfile;
  KB: TTermKeyBinding;
  SB: TTermSignalBinding;
begin
  if not FileExists(APath) then
  begin
    LoadDefaults;
    Exit;
  end;
  Clear;
  Ini := TIniFile.Create(APath);
  Sections := TStringList.Create;
  try
    FTheme := Ini.ReadString('General', 'theme', '');
    FActiveProfile := Ini.ReadString('General', 'profile', 'Default');
    FFont := Ini.ReadString('General', 'font', '');
    FEmojiFont := Ini.ReadString('General', 'emojifont', '');
    FLinkOpenCommand := Ini.ReadString('General', 'linkopencommand', '');
    FDesktopPromptDismissed := Ini.ReadBool('General', 'desktop_prompt_dismissed', False);
    Ini.ReadSections(Sections);
    for i := 0 to Sections.Count - 1 do
    begin
      s := Sections[i];
      if AnsiStartsText('Profile.', s) then
      begin
        Name := Copy(s, Length('Profile.') + 1, MaxInt);
        P := TTermProfile.Create(Name, 'Monospace-11', clWhite, TfpgColor($000000));
        ReadProfileFields(Ini, s, P);
        AddProfile(P);
      end
      else if AnsiStartsText('Key.', s) then
      begin
        KB := AddKey(
          Word(Ini.ReadInteger(s, 'keycode', 0)),
          StrToShift(Ini.ReadString(s, 'shift', '')),
          ReadAction(Ini, s, 'action_'));
      end
      else if AnsiStartsText('Signal.', s) then
      begin
        n := Ini.ReadInteger(s, 'kind', 0);
        if n > Ord(High(TTermSignalKind)) then n := 0;
        SB := AddSignal(TTermSignalKind(n),
          Ini.ReadInteger(s, 'code', 0),
          ReadAction(Ini, s, 'action_'));
      end;
    end;
  finally
    Sections.Free;
    Ini.Free;
  end;
  { Migrate a legacy global font override (older versions stored the font here
    instead of in the profile) into the active profile, then drop it. }
  if FFont <> '' then
  begin
    P := FindProfile(FActiveProfile);
    if (P = nil) and (ProfileCount > 0) then
      P := GetProfile(0);
    if P <> nil then
      P.FontDesc := FFont;
    FFont := '';
  end;
  { An empty/partial file still gets sane keybindings. }
  if (KeyCount = 0) and (ProfileCount = 0) then
    LoadDefaults;
end;

procedure TTermConfig.Save(const APath: string);
var
  Ini: TIniFile;
  i: Integer;
  Sec: string;
  Dir: string;
begin
  Dir := ExtractFileDir(APath);
  if (Dir <> '') and (not DirectoryExists(Dir)) then
    ForceDirectories(Dir);
  { Rewrite from scratch so removed/renamed profiles, keys and signals don't
    leave orphan sections behind (Profile.* / Key.N sections would otherwise
    survive and be reloaded). }
  if FileExists(APath) then
    DeleteFile(APath);
  Ini := TIniFile.Create(APath);
  try
    Ini.WriteString('General', 'theme', FTheme);
    Ini.WriteString('General', 'profile', FActiveProfile);
    Ini.WriteString('General', 'font', FFont);
    Ini.WriteString('General', 'emojifont', FEmojiFont);
    Ini.WriteString('General', 'linkopencommand', FLinkOpenCommand);
    Ini.WriteBool('General', 'desktop_prompt_dismissed', FDesktopPromptDismissed);
    for i := 0 to FProfiles.Count - 1 do
    begin
      Sec := 'Profile.' + GetProfile(i).Name;
      Ini.WriteString(Sec, 'font', GetProfile(i).FontDesc);
      Ini.WriteString(Sec, 'fg', ColorToHex(GetProfile(i).FGColor));
      Ini.WriteString(Sec, 'bg', ColorToHex(GetProfile(i).BGColor));
      Ini.WriteBool  (Sec, 'drawer_enabled', GetProfile(i).DrawerEnabled);
      Ini.WriteString(Sec, 'drawer_name',    GetProfile(i).DrawerName);
      Ini.WriteString(Sec, 'drawer_command', GetProfile(i).DrawerCommand);
      Ini.WriteString(Sec, 'drawer_gravity', EdgeToStr(GetProfile(i).DrawerGravity));
      Ini.WriteFloat (Sec, 'drawer_size',    GetProfile(i).DrawerSizeFrac);
      case GetProfile(i).DrawerAnim of
        tdaAssemble: Ini.WriteString(Sec, 'drawer_anim', 'assemble');
        tdaNone:     Ini.WriteString(Sec, 'drawer_anim', 'none');
      else           Ini.WriteString(Sec, 'drawer_anim', 'fade');
      end;
      if GetProfile(i).DrawerLaunch = tdlOnStart then
        Ini.WriteString(Sec, 'drawer_launch', 'onstart')
      else Ini.WriteString(Sec, 'drawer_launch', 'onshow');
      Ini.WriteString(Sec, 'drawer_colors', GetProfile(i).DrawerColorProfile);
      case GetProfile(i).DrawerShutdown of
        tdkSignal: Ini.WriteString(Sec, 'drawer_shutdown', 'signal');
        tdkKeys:   Ini.WriteString(Sec, 'drawer_shutdown', 'keys');
      else         Ini.WriteString(Sec, 'drawer_shutdown', 'none');
      end;
      Ini.WriteInteger(Sec, 'drawer_signal', GetProfile(i).DrawerShutdownSignal);
      Ini.WriteString(Sec, 'drawer_keys', GetProfile(i).DrawerShutdownKeys);
    end;
    for i := 0 to FKeys.Count - 1 do
    begin
      Sec := 'Key.' + IntToStr(i);
      Ini.WriteInteger(Sec, 'keycode', GetKey(i).KeyCode);
      Ini.WriteString(Sec, 'shift', ShiftToStr(GetKey(i).Shift));
      WriteAction(Ini, Sec, 'action_', GetKey(i).Action);
    end;
    for i := 0 to FSignals.Count - 1 do
    begin
      Sec := 'Signal.' + IntToStr(i);
      Ini.WriteInteger(Sec, 'kind', Ord(GetSignal(i).Kind));
      Ini.WriteInteger(Sec, 'code', GetSignal(i).Code);
      WriteAction(Ini, Sec, 'action_', GetSignal(i).Action);
    end;
    Ini.UpdateFile;
  finally
    Ini.Free;
  end;
end;

{ TTermAppConfig }

constructor TTermAppConfig.Create;
begin
  inherited Create;
  FProfile := TTermProfile.Create('App', 'Monospace-11', clWhite, TfpgColor($000000));
end;

destructor TTermAppConfig.Destroy;
begin
  FProfile.Free;          { nil after TakeProfile, so this is a no-op then }
  inherited Destroy;
end;

function TTermAppConfig.Load(const APath: string): Boolean;
var
  Ini: TIniFile;
begin
  Result := FileExists(APath);
  if not Result then Exit;
  Ini := TIniFile.Create(APath);
  try
    Title   := Ini.ReadString('App', 'title', '');
    Command := Ini.ReadString('App', 'command', '');
    Theme   := Ini.ReadString('App', 'theme', '');
    { Same keys a profile uses, read straight into the app's profile. }
    ReadProfileFields(Ini, 'App', FProfile);
    FProfile.Name := Ini.ReadString('App', 'profile_name', 'App');
  finally
    Ini.Free;
  end;
end;

function TTermAppConfig.TakeProfile: TTermProfile;
begin
  Result := FProfile;
  FProfile := nil;
end;

end.
