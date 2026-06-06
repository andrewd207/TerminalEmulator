{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

program ExampleTerminalLCL;

{$mode objfpc}{$H+}

uses
  Interfaces, { selects the LCL widgetset — must be first }
  Classes,
  SysUtils,
  Forms,
  ExtCtrls,
  Dialogs, Controls,
  Terminal.Controller,
  Terminal.View.LCL;

const
  CONFIG_FILE = 'font.conf';

type
  TTerminalForm = class(TTerminalLCLForm)
  private
    FController: TTerminalController;
    FCloseTimer: TTimer;
    FCloseCountdown: Integer;
    procedure FormShow(Sender: TObject);
    procedure FormCloseQuery(Sender: TObject; var CanClose: Boolean);
    procedure FontChanged(Sender: TObject);
    procedure ShellExited(Sender: TObject);
    procedure CloseTickTimer(Sender: TObject);
    procedure WriteCountdown(N: Integer);
    function ConfigPath: string;
    procedure LoadFont;
    procedure SaveFont;
  public
    constructor Create(AOwner: TComponent); override;
    destructor Destroy; override;
  end;

function TTerminalForm.ConfigPath: string;
begin
  Result := IncludeTrailingPathDelimiter(GetAppConfigDir(False)) + CONFIG_FILE;
end;

procedure TTerminalForm.LoadFont;
var
  F: TextFile;
  S: string;
  N: Integer;
begin
  if not FileExists(ConfigPath) then Exit;
  AssignFile(F, ConfigPath);
  try
    Reset(F);
    if not Eof(F) then
    begin
      ReadLn(F, S); S := Trim(S);
      if S <> '' then TerminalView.FontName := S;
    end;
    if not Eof(F) then
    begin
      ReadLn(F, S); S := Trim(S);
      if (S <> '') and TryStrToInt(S, N) then TerminalView.FontSize := N;
    end;
    if not Eof(F) then
    begin
      ReadLn(F, S); S := Trim(S);
      TerminalView.EmojiFontName := S;
    end;
    if not Eof(F) then
    begin
      ReadLn(F, S); S := Trim(S);
      if (S <> '') and TryStrToInt(S, N) then TerminalView.EmojiFontSize := N;
    end;
  finally
    CloseFile(F);
  end;
end;

procedure TTerminalForm.SaveFont;
var
  F: TextFile;
  Dir: string;
begin
  Dir := GetAppConfigDir(False);
  if not ForceDirectories(Dir) then Exit;
  AssignFile(F, ConfigPath);
  try
    Rewrite(F);
    WriteLn(F, TerminalView.FontName);
    WriteLn(F, TerminalView.FontSize);
    WriteLn(F, TerminalView.EmojiFontName);
    WriteLn(F, TerminalView.EmojiFontSize);
  finally
    CloseFile(F);
  end;
end;

constructor TTerminalForm.Create(AOwner: TComponent);
begin
  inherited Create(AOwner);
  FController := TTerminalController.Create(80, 25, 5000);
  TerminalView.AttachController(FController);
  LoadFont;
  TerminalView.OnFontChanged := @FontChanged;
  TerminalView.OnShellExit := @ShellExited;
  OnShow := @FormShow;
  OnCloseQuery := @FormCloseQuery;
end;

procedure TTerminalForm.FormCloseQuery(Sender: TObject; var CanClose: Boolean);
begin
  CanClose := True;
  if (FController <> nil) and FController.SubProcessRunning then
    CanClose := MessageDlg(
        'Close window?',
        'A program is still running in the shell. Quit anyway?',
        mtConfirmation, [mbYes, mbNo], 0) = mrYes;
end;

destructor TTerminalForm.Destroy;
begin
  FreeAndNil(FCloseTimer);
  TerminalView.DetachController;
  FreeAndNil(FController);
  inherited Destroy;
end;

procedure TTerminalForm.WriteCountdown(N: Integer);
var
  Msg: RawByteString;
begin
  Msg := #27'[0m'#13#10#27'[7m[ shell exited - closing in '
       + RawByteString(IntToStr(N)) + '... ]'#27'[0m'#13#10;
  FController.Parser.FeedBytes(Msg);
  TerminalView.Invalidate;
end;

procedure TTerminalForm.ShellExited(Sender: TObject);
begin
  FCloseCountdown := 3;
  WriteCountdown(FCloseCountdown);
  FCloseTimer := TTimer.Create(Self);
  FCloseTimer.Interval := 1000;
  FCloseTimer.OnTimer := @CloseTickTimer;
  FCloseTimer.Enabled := True;
end;

procedure TTerminalForm.CloseTickTimer(Sender: TObject);
begin
  Dec(FCloseCountdown);
  if FCloseCountdown <= 0 then
  begin
    FCloseTimer.Enabled := False;
    Close;
    Exit;
  end;
  WriteCountdown(FCloseCountdown);
end;

procedure TTerminalForm.FormShow(Sender: TObject);
begin
  TerminalView.StartShell;
  if TerminalView.CanFocus then
    TerminalView.SetFocus;
end;

procedure TTerminalForm.FontChanged(Sender: TObject);
begin
  SaveFont;
end;

var
  Frm: TTerminalForm;
begin
  Application.Initialize;
  Application.Title := 'LCL Terminal';
  Application.CreateForm(TTerminalForm, Frm);
  Frm.Caption := 'LCL Terminal';
  Application.Run;
end.
