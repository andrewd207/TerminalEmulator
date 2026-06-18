{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.

  ---------------------------------------------------------------------------
  Settings dialog: three tabs (Profiles / Keys / Signals) over a TTermConfig.

  Each tab is a two-column TfpgStringGrid so the trigger and action columns line
  up evenly regardless of text width.  Add/Remove use simple input prompts; the
  model underneath supports anything, so the UI can grow without touching the
  data layer.  Persists on "Save & Close".
}
unit TermFpGUI.SettingsForm;

{$mode objfpc}{$H+}

interface

uses
  Classes, SysUtils, fpg_base, fpg_main, fpg_form, fpg_tab, fpg_grid,
  fpg_button, fpg_dialogs, fpg_label, fpg_edit, fpg_combobox, fpg_panel,
  fpg_checkbox,
  Terminal.View.fpGUI,                 { TTermViewEdge }
  TermFpGUI.Config, TermFpGUI.Actions;

type
  TTermSettingsForm = class(TfpgForm)
  private
    FConfig: TTermConfig;
    FConfigPath: string;
    FPages: TfpgPageControl;
    FProfilesGrid: TfpgStringGrid;
    FKeysGrid: TfpgStringGrid;
    FSignalsGrid: TfpgStringGrid;
    procedure RefreshProfiles;
    procedure RefreshKeys;
    procedure RefreshSignals;
    function  MakeGridTab(const ATitle, ACol0, ACol1: string;
                          AW0, AW1: Integer; out ASheet: TfpgTabSheet): TfpgStringGrid;
    function  PromptAction(out AAction: TTermAction): Boolean;
    procedure AddProfileClick(Sender: TObject);
    procedure EditProfileClick(Sender: TObject);
    procedure RemoveProfileClick(Sender: TObject);
    procedure AddKeyClick(Sender: TObject);
    procedure AddSignalClick(Sender: TObject);
    procedure RemoveSignalClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    procedure SaveCloseClick(Sender: TObject);
  public
    constructor CreateFor(AOwner: TComponent; AConfig: TTermConfig; const APath: string);
  end;

implementation

type
  { Modal dialog that captures one key chord.  Modifier-only presses are ignored
    until a real key arrives; Esc cancels. }
  TKeyCaptureForm = class(TfpgForm)
  private
    FLabel: TfpgLabel;
    FKeyCode: Word;
    FShift: TShiftState;
  protected
    procedure HandleKeyPress(var keycode: word; var shiftstate: TShiftState;
      var consumed: boolean); override;
  public
    constructor Create(AOwner: TComponent); override;
    property KeyCode: Word read FKeyCode;
    property Shift: TShiftState read FShift;
  end;

  { Modal dialog to pick an action: a builtin from the list (with an optional
    argument), or a free-form external shell command that overrides it. }
  TActionPickerForm = class(TfpgForm)
  private
    FCombo: TfpgComboBox;
    FArg: TfpgEdit;
    FCmd: TfpgEdit;
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    function BuildAction: TTermAction;     { valid after ShowModal = mrOK }
  end;

  { Modal dialog to add/edit a profile: name, font (via font dialog), and
    foreground / background colours (via the colour picker, shown as swatches). }
  TProfileEditForm = class(TfpgForm)
  private
    FNameEdit: TfpgEdit;
    FFontEdit: TfpgEdit;
    FFgSwatch, FBgSwatch: TfpgBevel;
    FFontDesc: string;
    FFg, FBg: TfpgColor;
    { drawer section }
    FDrawerEnabled: TfpgCheckBox;
    FDrawerName: TfpgEdit;
    FDrawerCmd: TfpgEdit;
    FDrawerSize: TfpgEdit;
    FDrawerGravity: TfpgComboBox;
    FDrawerAnim: TfpgComboBox;
    FDrawerLaunch: TfpgComboBox;
    FDrawerColors: TfpgComboBox;
    procedure SyncSwatches;
    procedure ChooseFontClick(Sender: TObject);
    procedure ChooseFgClick(Sender: TObject);
    procedure ChooseBgClick(Sender: TObject);
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    { Populate the drawer colour-source list ('(this profile)' + every profile
      name) so the drawer can borrow another profile's colours. }
    procedure SetAvailableProfiles(AConfig: TTermConfig; const ASelfName: string);
    procedure LoadFrom(P: TTermProfile);
    procedure StoreTo(P: TTermProfile);
    function  ProfileName: string;
  end;

  { Modal dialog to choose a signal source (OSC code / Bell / Title) with an
    explanation of the common ones. }
  TSignalPickerForm = class(TfpgForm)
  private
    FKindCombo: TfpgComboBox;
    FCodeEdit: TfpgEdit;
    procedure OkClick(Sender: TObject);
    procedure CancelClick(Sender: TObject);
  public
    constructor Create(AOwner: TComponent); override;
    function Kind: TTermSignalKind;        { valid after ShowModal = mrOK }
    function Code: Integer;
  end;

{ Modifier / lock keys live in $E300..$E386 (see keys.inc). }
function IsModifierKey(AKey: Word): Boolean; inline;
begin
  Result := (AKey >= $E300) and (AKey <= $E386);
end;

{ TKeyCaptureForm }

constructor TKeyCaptureForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  WindowTitle := 'Capture Key';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, 320, 96);
  Sizeable := False;
  FKeyCode := 0;
  FLabel := TfpgLabel.Create(Self);
  FLabel.SetPosition(16, 28, 288, 44);
  FLabel.Text := 'Press the key combination for this binding.'
               + LineEnding + '(Esc to cancel)';
end;

procedure TKeyCaptureForm.HandleKeyPress(var keycode: word;
  var shiftstate: TShiftState; var consumed: boolean);
begin
  consumed := True;
  if keycode = keyEscape then
  begin
    FKeyCode := 0;
    ModalResult := mrCancel;
    Exit;
  end;
  if IsModifierKey(keycode) then
    Exit;                       { hold for a real key }
  FKeyCode := keycode;
  FShift := shiftstate;
  ModalResult := mrOK;
end;

{ TActionPickerForm }

constructor TActionPickerForm.Create(AOwner: TComponent);
var
  Lbl: TfpgLabel;
  Btn: TfpgButton;
begin
  inherited Create(AOwner);
  WindowTitle := 'Choose Action';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, 380, 210);
  Sizeable := False;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 12, 356, 18);
  Lbl.Text := 'Builtin action:';

  FCombo := TfpgComboBox.Create(Self);
  FCombo.SetPosition(12, 32, 356, 24);
  ListBuiltins(FCombo.Items);
  if FCombo.Items.Count > 0 then
    FCombo.FocusItem := 0;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 64, 356, 18);
  Lbl.Text := 'Argument (e.g. profile name / tab title) — optional:';

  FArg := TfpgEdit.Create(Self);
  FArg.SetPosition(12, 84, 356, 24);

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 116, 356, 18);
  Lbl.Text := 'Or external shell command (overrides the builtin):';

  FCmd := TfpgEdit.Create(Self);
  FCmd.SetPosition(12, 136, 356, 24);

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Cancel';
  Btn.SetPosition(196, 174, 80, 26);
  Btn.OnClick := @CancelClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'OK';
  Btn.SetPosition(284, 174, 84, 26);
  Btn.OnClick := @OkClick;
end;

procedure TActionPickerForm.OkClick(Sender: TObject);
begin
  ModalResult := mrOK;
end;

procedure TActionPickerForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

function TActionPickerForm.BuildAction: TTermAction;
begin
  if Trim(FCmd.Text) <> '' then
    Result := TTermAction.CreateExternal(Trim(FCmd.Text))
  else
    Result := TTermAction.CreateBuiltin(NameToBuiltin(FCombo.Text), Trim(FArg.Text));
end;

{ TProfileEditForm }

constructor TProfileEditForm.Create(AOwner: TComponent);
var
  Lbl: TfpgLabel;
  Btn: TfpgButton;
begin
  inherited Create(AOwner);
  WindowTitle := 'Edit Profile';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, 420, 446);
  Sizeable := False;
  FFontDesc := 'Monospace-11';
  FFg := clWhite;
  FBg := TfpgColor($000000);

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 12, 80, 24);
  Lbl.Text := 'Name:';
  FNameEdit := TfpgEdit.Create(Self);
  FNameEdit.SetPosition(96, 10, 272, 24);

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 46, 80, 24);
  Lbl.Text := 'Font:';
  FFontEdit := TfpgEdit.Create(Self);
  FFontEdit.SetPosition(96, 44, 184, 24);
  FFontEdit.Enabled := False;             { display only; use the picker }
  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Choose…';
  Btn.SetPosition(286, 44, 82, 24);
  Btn.OnClick := @ChooseFontClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Foreground…';
  Btn.SetPosition(96, 82, 110, 26);
  Btn.OnClick := @ChooseFgClick;
  FFgSwatch := TfpgBevel.Create(Self);
  FFgSwatch.SetPosition(216, 82, 60, 26);
  FFgSwatch.Shape := bsBox;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Background…';
  Btn.SetPosition(96, 116, 110, 26);
  Btn.OnClick := @ChooseBgClick;
  FBgSwatch := TfpgBevel.Create(Self);
  FBgSwatch.SetPosition(216, 116, 60, 26);
  FBgSwatch.Shape := bsBox;

  { ---- Hover drawer (overlay panel defined by this profile) ---- }
  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 152, 396, 18);
  Lbl.Text := '— Hover drawer (slide-out side panel) —';

  FDrawerEnabled := TfpgCheckBox.Create(Self);
  FDrawerEnabled.SetPosition(12, 174, 200, 22);
  FDrawerEnabled.Text := 'Enable drawer';

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 204, 70, 24);
  Lbl.Text := 'Name:';
  FDrawerName := TfpgEdit.Create(Self);
  FDrawerName.SetPosition(86, 202, 150, 24);
  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(248, 204, 40, 24);
  Lbl.Text := 'Size:';
  FDrawerSize := TfpgEdit.Create(Self);
  FDrawerSize.SetPosition(290, 202, 60, 24);

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 236, 70, 24);
  Lbl.Text := 'Command:';
  FDrawerCmd := TfpgEdit.Create(Self);
  FDrawerCmd.SetPosition(86, 234, 322, 24);

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 264, 16, 18);
  Lbl.Text := '';
  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(86, 260, 322, 16);
  Lbl.Text := '(empty = default login shell; e.g. htop, ranger, btop)';

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 290, 70, 24);
  Lbl.Text := 'Gravity:';
  FDrawerGravity := TfpgComboBox.Create(Self);
  FDrawerGravity.SetPosition(86, 288, 120, 24);
  FDrawerGravity.Items.Add('Left');
  FDrawerGravity.Items.Add('Right');
  FDrawerGravity.Items.Add('Top');
  FDrawerGravity.Items.Add('Bottom');
  FDrawerGravity.FocusItem := 1;
  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(216, 290, 44, 24);
  Lbl.Text := 'Anim:';
  FDrawerAnim := TfpgComboBox.Create(Self);
  FDrawerAnim.SetPosition(262, 288, 146, 24);
  FDrawerAnim.Items.Add('Fade');
  FDrawerAnim.Items.Add('Assemble');
  FDrawerAnim.Items.Add('None');
  FDrawerAnim.FocusItem := 0;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 322, 70, 24);
  Lbl.Text := 'Launch:';
  FDrawerLaunch := TfpgComboBox.Create(Self);
  FDrawerLaunch.SetPosition(86, 320, 200, 24);
  FDrawerLaunch.Items.Add('On first show');
  FDrawerLaunch.Items.Add('On profile start');
  FDrawerLaunch.FocusItem := 0;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 354, 70, 24);
  Lbl.Text := 'Colors:';
  FDrawerColors := TfpgComboBox.Create(Self);
  FDrawerColors.SetPosition(86, 352, 200, 24);
  FDrawerColors.Items.Add('(this profile)');
  FDrawerColors.FocusItem := 0;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Cancel';
  Btn.SetPosition(236, 410, 80, 26);
  Btn.OnClick := @CancelClick;
  Btn := TfpgButton.Create(Self);
  Btn.Text := 'OK';
  Btn.SetPosition(324, 410, 84, 26);
  Btn.OnClick := @OkClick;
end;

procedure TProfileEditForm.SyncSwatches;
begin
  FFgSwatch.BackgroundColor := FFg;
  FBgSwatch.BackgroundColor := FBg;
  FFgSwatch.Invalidate;
  FBgSwatch.Invalidate;
  FFontEdit.Text := FFontDesc;
end;

function EdgeToIndex(E: TTermViewEdge): Integer;
begin
  case E of
    veLeft:   Result := 0;
    veRight:  Result := 1;
    veTop:    Result := 2;
    veBottom: Result := 3;
  else        Result := 1;
  end;
end;

function IndexToEdge(I: Integer): TTermViewEdge;
begin
  case I of
    0: Result := veLeft;
    2: Result := veTop;
    3: Result := veBottom;
  else Result := veRight;
  end;
end;

procedure TProfileEditForm.SetAvailableProfiles(AConfig: TTermConfig;
  const ASelfName: string);
var
  i: Integer;
begin
  FDrawerColors.Items.Clear;
  FDrawerColors.Items.Add('(this profile)');
  if AConfig <> nil then
    for i := 0 to AConfig.ProfileCount - 1 do
      FDrawerColors.Items.Add(AConfig.Profiles[i].Name);
  FDrawerColors.FocusItem := 0;
end;

procedure TProfileEditForm.LoadFrom(P: TTermProfile);
var
  idx: Integer;
begin
  FNameEdit.Text := P.Name;
  FFontDesc := P.FontDesc;
  FFg := P.FGColor;
  FBg := P.BGColor;
  SyncSwatches;
  FDrawerEnabled.Checked := P.DrawerEnabled;
  FDrawerName.Text := P.DrawerName;
  FDrawerCmd.Text := P.DrawerCommand;
  FDrawerSize.Text := FormatFloat('0.00', P.DrawerSizeFrac);
  FDrawerGravity.FocusItem := EdgeToIndex(P.DrawerGravity);
  case P.DrawerAnim of
    tdaAssemble: FDrawerAnim.FocusItem := 1;
    tdaNone:     FDrawerAnim.FocusItem := 2;
  else           FDrawerAnim.FocusItem := 0;
  end;
  if P.DrawerLaunch = tdlOnStart then FDrawerLaunch.FocusItem := 1
  else FDrawerLaunch.FocusItem := 0;
  if P.DrawerColorProfile = '' then
    FDrawerColors.FocusItem := 0
  else
  begin
    idx := FDrawerColors.Items.IndexOf(P.DrawerColorProfile);
    if idx >= 0 then FDrawerColors.FocusItem := idx
    else FDrawerColors.FocusItem := 0;
  end;
end;

procedure TProfileEditForm.StoreTo(P: TTermProfile);
var
  f: Double;
begin
  P.Name := Trim(FNameEdit.Text);
  P.FontDesc := FFontDesc;
  P.FGColor := FFg;
  P.BGColor := FBg;
  P.DrawerEnabled := FDrawerEnabled.Checked;
  P.DrawerName := Trim(FDrawerName.Text);
  if P.DrawerName = '' then P.DrawerName := 'Drawer';
  P.DrawerCommand := Trim(FDrawerCmd.Text);
  f := StrToFloatDef(StringReplace(Trim(FDrawerSize.Text), ',', '.', []), 0.33);
  if f < 0.1 then f := 0.1;
  if f > 0.9 then f := 0.9;
  P.DrawerSizeFrac := f;
  P.DrawerGravity := IndexToEdge(FDrawerGravity.FocusItem);
  case FDrawerAnim.FocusItem of
    1: P.DrawerAnim := tdaAssemble;
    2: P.DrawerAnim := tdaNone;
  else P.DrawerAnim := tdaFade;
  end;
  if FDrawerLaunch.FocusItem = 1 then P.DrawerLaunch := tdlOnStart
  else P.DrawerLaunch := tdlOnShow;
  if FDrawerColors.FocusItem <= 0 then
    P.DrawerColorProfile := ''
  else
    P.DrawerColorProfile := FDrawerColors.Text;
end;

function TProfileEditForm.ProfileName: string;
begin
  Result := Trim(FNameEdit.Text);
end;

procedure TProfileEditForm.ChooseFontClick(Sender: TObject);
var
  S: string;
begin
  S := FFontDesc;
  if SelectFontDialog(S) then
  begin
    FFontDesc := S;
    FFontEdit.Text := S;
  end;
end;

procedure TProfileEditForm.ChooseFgClick(Sender: TObject);
begin
  FFg := fpgSelectColorDialog(FFg);
  SyncSwatches;
end;

procedure TProfileEditForm.ChooseBgClick(Sender: TObject);
begin
  FBg := fpgSelectColorDialog(FBg);
  SyncSwatches;
end;

procedure TProfileEditForm.OkClick(Sender: TObject);
begin
  if ProfileName = '' then
  begin
    TfpgMessageDialog.Warning('Profile', 'Please enter a profile name.');
    Exit;
  end;
  ModalResult := mrOK;
end;

procedure TProfileEditForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

{ TSignalPickerForm }

constructor TSignalPickerForm.Create(AOwner: TComponent);
var
  Lbl: TfpgLabel;
  Btn: TfpgButton;
begin
  inherited Create(AOwner);
  WindowTitle := 'Add Signal';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, 420, 300);
  Sizeable := False;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 10, 120, 24);
  Lbl.Text := 'Signal source:';
  FKindCombo := TfpgComboBox.Create(Self);
  FKindCombo.SetPosition(120, 8, 130, 24);
  FKindCombo.Items.Add('OSC');     { order matches TTermSignalKind }
  FKindCombo.Items.Add('Bell');
  FKindCombo.Items.Add('Title');
  FKindCombo.FocusItem := 0;

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(258, 10, 60, 24);
  Lbl.Text := 'Code:';
  FCodeEdit := TfpgEdit.Create(Self);
  FCodeEdit.SetPosition(298, 8, 110, 24);
  FCodeEdit.Text := '9';

  Lbl := TfpgLabel.Create(Self);
  Lbl.SetPosition(12, 44, 396, 210);
  Lbl.WrapText := True;
  Lbl.Text :=
    'Run an action when the program emits a terminal signal.' + LineEnding +
    LineEnding +
    'Kinds:' + LineEnding +
    '  OSC <code>  — an OSC escape: ESC ] code ; payload  BEL/ST' + LineEnding +
    '  Bell        — the terminal bell (Ctrl-G); Code is ignored' + LineEnding +
    '  Title       — a window-title change (OSC 0/2); Code ignored' + LineEnding +
    LineEnding +
    'Common OSC codes:' + LineEnding +
    '  9    desktop notification (iTerm2) — payload is the message' + LineEnding +
    '  777  notify — payload is "notify;<title>;<body>"' + LineEnding +
    '  99   kitty notification protocol' + LineEnding +
    '  52   clipboard set / query' + LineEnding +
    LineEnding +
    'The payload reaches your action as %p (and the code as %c).';

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Cancel';
  Btn.SetPosition(236, 266, 80, 26);
  Btn.OnClick := @CancelClick;
  Btn := TfpgButton.Create(Self);
  Btn.Text := 'OK';
  Btn.SetPosition(324, 266, 84, 26);
  Btn.OnClick := @OkClick;
end;

function TSignalPickerForm.Kind: TTermSignalKind;
begin
  case FKindCombo.FocusItem of
    1: Result := tskBell;
    2: Result := tskTitle;
  else
    Result := tskOSC;
  end;
end;

function TSignalPickerForm.Code: Integer;
begin
  if Kind = tskOSC then
    Result := StrToIntDef(Trim(FCodeEdit.Text), -1)
  else
    Result := 0;
end;

procedure TSignalPickerForm.OkClick(Sender: TObject);
begin
  if (Kind = tskOSC) and (Code < 0) then
  begin
    TfpgMessageDialog.Warning('Add Signal', 'Enter a numeric OSC code (e.g. 9, 52, 99, 777).');
    Exit;
  end;
  ModalResult := mrOK;
end;

procedure TSignalPickerForm.CancelClick(Sender: TObject);
begin
  ModalResult := mrCancel;
end;

const
  FORM_W  = 560;
  FORM_H  = 440;
  GRID_H  = 312;
  COL0_W  = 170;        // trigger column
  COL1_W  = 348;        // action column

constructor TTermSettingsForm.CreateFor(AOwner: TComponent; AConfig: TTermConfig;
  const APath: string);
var
  Btn: TfpgButton;
  ProfSheet, KeysSheet, SigSheet: TfpgTabSheet;
begin
  inherited Create(AOwner);
  FConfig := AConfig;
  FConfigPath := APath;

  WindowTitle := 'Settings';
  WindowPosition := wpScreenCenter;
  SetPosition(0, 0, FORM_W, FORM_H);
  Sizeable := False;

  FPages := TfpgPageControl.Create(Self);
  FPages.SetPosition(6, 6, FORM_W - 12, GRID_H + 56);

  FProfilesGrid := MakeGridTab('Profiles',    'Profile', 'Font',   COL0_W, COL1_W, ProfSheet);
  FKeysGrid     := MakeGridTab('Keybindings', 'Key',     'Action', COL0_W, COL1_W, KeysSheet);
  FSignalsGrid  := MakeGridTab('Signals',     'Signal',  'Action', COL0_W, COL1_W, SigSheet);

  { Per-tab add/remove buttons live inside their own tab sheet, so each is only
    shown when that tab is active. }
  Btn := TfpgButton.Create(ProfSheet);
  Btn.Parent := ProfSheet;
  Btn.Text := 'Add Profile';
  Btn.SetPosition(4, GRID_H - 26, 100, 26);
  Btn.OnClick := @AddProfileClick;

  Btn := TfpgButton.Create(ProfSheet);
  Btn.Parent := ProfSheet;
  Btn.Text := 'Edit Profile';
  Btn.SetPosition(110, GRID_H - 26, 100, 26);
  Btn.OnClick := @EditProfileClick;

  Btn := TfpgButton.Create(ProfSheet);
  Btn.Parent := ProfSheet;
  Btn.Text := 'Remove Profile';
  Btn.SetPosition(216, GRID_H - 26, 110, 26);
  Btn.OnClick := @RemoveProfileClick;

  Btn := TfpgButton.Create(KeysSheet);
  Btn.Parent := KeysSheet;
  Btn.Text := 'Add Key';
  Btn.SetPosition(4, GRID_H - 26, 100, 26);
  Btn.OnClick := @AddKeyClick;

  Btn := TfpgButton.Create(KeysSheet);
  Btn.Parent := KeysSheet;
  Btn.Text := 'Remove Key';
  Btn.SetPosition(110, GRID_H - 26, 100, 26);
  Btn.OnClick := @RemoveKeyClick;

  Btn := TfpgButton.Create(SigSheet);
  Btn.Parent := SigSheet;
  Btn.Text := 'Add Signal';
  Btn.SetPosition(4, GRID_H - 26, 100, 26);
  Btn.OnClick := @AddSignalClick;

  Btn := TfpgButton.Create(SigSheet);
  Btn.Parent := SigSheet;
  Btn.Text := 'Remove Signal';
  Btn.SetPosition(110, GRID_H - 26, 100, 26);
  Btn.OnClick := @RemoveSignalClick;

  { Save & Close is form-level, shown on every tab. }
  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Save & Close';
  Btn.SetPosition(FORM_W - 130, FORM_H - 38, 124, 26);
  Btn.OnClick := @SaveCloseClick;

  RefreshProfiles;
  RefreshKeys;
  RefreshSignals;
end;

function TTermSettingsForm.MakeGridTab(const ATitle, ACol0, ACol1: string;
  AW0, AW1: Integer; out ASheet: TfpgTabSheet): TfpgStringGrid;
begin
  ASheet := FPages.AppendTabSheet(ATitle);
  Result := TfpgStringGrid.Create(ASheet);
  Result.Parent := ASheet;
  { Fixed height (not alClient) so a button strip fits below the grid. }
  Result.SetPosition(4, 4, FORM_W - 28, GRID_H - 34);
  Result.RowSelect := True;
  Result.ShowHeader := True;
  Result.AddColumn(ACol0, AW0, taLeftJustify);
  Result.AddColumn(ACol1, AW1, taLeftJustify);
end;

procedure TTermSettingsForm.RefreshProfiles;
var
  i: Integer;
begin
  FProfilesGrid.RowCount := FConfig.ProfileCount;
  for i := 0 to FConfig.ProfileCount - 1 do
  begin
    FProfilesGrid.Cells[0, i] := FConfig.Profiles[i].Name;
    FProfilesGrid.Cells[1, i] := FConfig.Profiles[i].FontDesc;
  end;
  FProfilesGrid.Invalidate;
end;

procedure TTermSettingsForm.RefreshKeys;
var
  i: Integer;
  KB: TTermKeyBinding;
begin
  FKeysGrid.RowCount := FConfig.KeyCount;
  for i := 0 to FConfig.KeyCount - 1 do
  begin
    KB := FConfig.Keys[i];
    FKeysGrid.Cells[0, i] := KB.ChordText;
    FKeysGrid.Cells[1, i] := KB.Action.Describe;
  end;
  FKeysGrid.Invalidate;
end;

procedure TTermSettingsForm.RefreshSignals;
var
  i: Integer;
  SB: TTermSignalBinding;
begin
  FSignalsGrid.RowCount := FConfig.SignalCount;
  for i := 0 to FConfig.SignalCount - 1 do
  begin
    SB := FConfig.Signals[i];
    FSignalsGrid.Cells[0, i] := SB.SignalText;
    FSignalsGrid.Cells[1, i] := SB.Action.Describe;
  end;
  FSignalsGrid.Invalidate;
end;

{ Prompt for an action via the picker dialog (builtin list + optional argument,
  or an external command). }
function TTermSettingsForm.PromptAction(out AAction: TTermAction): Boolean;
var
  Frm: TActionPickerForm;
begin
  Result := False;
  AAction := nil;
  Frm := TActionPickerForm.Create(nil);
  try
    if Frm.ShowModal = mrOK then
    begin
      AAction := Frm.BuildAction;
      Result := AAction <> nil;
    end;
  finally
    Frm.Free;
  end;
end;

procedure TTermSettingsForm.AddProfileClick(Sender: TObject);
var
  Frm: TProfileEditForm;
  Seed, P: TTermProfile;
begin
  Frm := TProfileEditForm.Create(nil);
  Seed := TTermProfile.Create('New Profile', 'Monospace-11', clWhite, TfpgColor($000000));
  try
    Frm.SetAvailableProfiles(FConfig, '');
    Frm.LoadFrom(Seed);
    if Frm.ShowModal = mrOK then
    begin
      P := TTermProfile.Create('', '', clWhite, TfpgColor($000000));
      Frm.StoreTo(P);
      FConfig.AddProfile(P);
      RefreshProfiles;
    end;
  finally
    Seed.Free;
    Frm.Free;
  end;
end;

procedure TTermSettingsForm.EditProfileClick(Sender: TObject);
var
  Frm: TProfileEditForm;
  P: TTermProfile;
  OldName: string;
begin
  if (FProfilesGrid.FocusRow < 0) or (FProfilesGrid.FocusRow >= FConfig.ProfileCount) then Exit;
  P := FConfig.Profiles[FProfilesGrid.FocusRow];
  OldName := P.Name;
  Frm := TProfileEditForm.Create(nil);
  try
    Frm.SetAvailableProfiles(FConfig, P.Name);
    Frm.LoadFrom(P);
    if Frm.ShowModal = mrOK then
    begin
      Frm.StoreTo(P);
      { Keep the active-profile pointer valid if this one was renamed. }
      if SameText(OldName, FConfig.ActiveProfile) and not SameText(P.Name, OldName) then
        FConfig.ActiveProfile := P.Name;
      RefreshProfiles;
    end;
  finally
    Frm.Free;
  end;
end;

procedure TTermSettingsForm.RemoveProfileClick(Sender: TObject);
var
  ProfName: string;
begin
  if (FProfilesGrid.FocusRow < 0) or (FProfilesGrid.FocusRow >= FConfig.ProfileCount) then Exit;
  if FConfig.ProfileCount <= 1 then
  begin
    TfpgMessageDialog.Warning('Remove Profile', 'At least one profile must remain.');
    Exit;
  end;
  ProfName := FConfig.Profiles[FProfilesGrid.FocusRow].Name;
  FConfig.RemoveProfile(FProfilesGrid.FocusRow);
  { If the active profile was removed, fall back to the first one. }
  if SameText(ProfName, FConfig.ActiveProfile) and (FConfig.ProfileCount > 0) then
    FConfig.ActiveProfile := FConfig.Profiles[0].Name;
  RefreshProfiles;
end;

{ Capture a key chord, then choose its action. }
procedure TTermSettingsForm.AddKeyClick(Sender: TObject);
var
  Cap: TKeyCaptureForm;
  KeyCode: Word;
  Shift: TShiftState;
  Act: TTermAction;
begin
  Cap := TKeyCaptureForm.Create(nil);
  try
    if Cap.ShowModal <> mrOK then Exit;
    KeyCode := Cap.KeyCode;
    Shift := Cap.Shift;
  finally
    Cap.Free;
  end;
  if KeyCode = 0 then Exit;
  if FConfig.MatchKey(KeyCode, Shift) <> nil then
  begin
    TfpgMessageDialog.Warning('Add Key',
      'That key combination is already bound. Remove it first to rebind.');
    Exit;
  end;
  if not PromptAction(Act) then Exit;
  FConfig.AddKey(KeyCode, Shift, Act);
  RefreshKeys;
end;

procedure TTermSettingsForm.AddSignalClick(Sender: TObject);
var
  Frm: TSignalPickerForm;
  Kind: TTermSignalKind;
  Code: Integer;
  Act: TTermAction;
begin
  Frm := TSignalPickerForm.Create(nil);
  try
    if Frm.ShowModal <> mrOK then Exit;
    Kind := Frm.Kind;
    Code := Frm.Code;
  finally
    Frm.Free;
  end;
  if not PromptAction(Act) then Exit;
  FConfig.AddSignal(Kind, Code, Act);
  RefreshSignals;
end;

procedure TTermSettingsForm.RemoveSignalClick(Sender: TObject);
begin
  if FSignalsGrid.FocusRow < 0 then Exit;
  FConfig.RemoveSignal(FSignalsGrid.FocusRow);
  RefreshSignals;
end;

procedure TTermSettingsForm.RemoveKeyClick(Sender: TObject);
begin
  if FKeysGrid.FocusRow < 0 then Exit;
  FConfig.RemoveKey(FKeysGrid.FocusRow);
  RefreshKeys;
end;

procedure TTermSettingsForm.SaveCloseClick(Sender: TObject);
begin
  FConfig.Save(FConfigPath);
  Close;
end;

end.
