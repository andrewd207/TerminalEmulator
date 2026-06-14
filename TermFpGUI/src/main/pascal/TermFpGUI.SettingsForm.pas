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
  fpg_button, fpg_dialogs, fpg_label, fpg_edit, fpg_combobox,
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
  V: TfpgString;
  Code: Integer;
  Act: TTermAction;
begin
  V := '9';
  if not fpgInputQuery('Add Signal', 'OSC code (e.g. 9, 52, 99, 777):', V) then Exit;
  Code := StrToIntDef(Trim(V), -1);
  if Code < 0 then
  begin
    TfpgMessageDialog.Critical('Add Signal', 'That is not a valid OSC code.');
    Exit;
  end;
  if not PromptAction(Act) then Exit;
  FConfig.AddSignal(tskOSC, Code, Act);
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
