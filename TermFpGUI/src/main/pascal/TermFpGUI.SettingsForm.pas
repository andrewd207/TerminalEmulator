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
  fpg_button, fpg_dialogs,
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
                          AW0, AW1: Integer): TfpgStringGrid;
    function  PromptAction(out AAction: TTermAction): Boolean;
    procedure AddSignalClick(Sender: TObject);
    procedure RemoveSignalClick(Sender: TObject);
    procedure RemoveKeyClick(Sender: TObject);
    procedure SaveCloseClick(Sender: TObject);
  public
    constructor CreateFor(AOwner: TComponent; AConfig: TTermConfig; const APath: string);
  end;

implementation

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

  FProfilesGrid := MakeGridTab('Profiles',    'Profile', 'Font',   COL0_W, COL1_W);
  FKeysGrid     := MakeGridTab('Keybindings', 'Key',     'Action', COL0_W, COL1_W);
  FSignalsGrid  := MakeGridTab('Signals',     'Signal',  'Action', COL0_W, COL1_W);

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Remove Key';
  Btn.SetPosition(6, FORM_H - 38, 110, 26);
  Btn.OnClick := @RemoveKeyClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Add Signal';
  Btn.SetPosition(122, FORM_H - 38, 110, 26);
  Btn.OnClick := @AddSignalClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Remove Signal';
  Btn.SetPosition(238, FORM_H - 38, 110, 26);
  Btn.OnClick := @RemoveSignalClick;

  Btn := TfpgButton.Create(Self);
  Btn.Text := 'Save && Close';
  Btn.SetPosition(FORM_W - 130, FORM_H - 38, 124, 26);
  Btn.OnClick := @SaveCloseClick;

  RefreshProfiles;
  RefreshKeys;
  RefreshSignals;
end;

function TTermSettingsForm.MakeGridTab(const ATitle, ACol0, ACol1: string;
  AW0, AW1: Integer): TfpgStringGrid;
var
  Sheet: TfpgTabSheet;
begin
  Sheet := FPages.AppendTabSheet(ATitle);
  Result := TfpgStringGrid.Create(Sheet);
  Result.Parent := Sheet;
  Result.SetPosition(4, 4, FORM_W - 28, GRID_H);
  Result.Align := alClient;
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

{ Prompt for an action: a builtin name, or "run: <command>" for external. }
function TTermSettingsForm.PromptAction(out AAction: TTermAction): Boolean;
var
  V: TfpgString;
begin
  Result := False;
  AAction := nil;
  V := 'Notify';
  if not fpgInputQuery('Action',
       'Builtin action name, or "run: <shell command>" for external'
       + LineEnding + '(builtins: Copy Paste NewTab CloseTab Beep Flash Notify ...):',
       V) then
    Exit;
  V := Trim(V);
  if V = '' then Exit;
  if SameText(Copy(V, 1, 4), 'run:') then
    AAction := TTermAction.CreateExternal(Trim(Copy(V, 5, MaxInt)))
  else
    AAction := TTermAction.CreateBuiltin(NameToBuiltin(V));
  Result := True;
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
