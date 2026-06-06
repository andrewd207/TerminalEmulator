{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

program ExampleTerminal;

{$mode objfpc}{$H+}

uses
  Classes,
  SysUtils,
  fpg_base,
  fpg_main,
  fpg_form,
  Terminal.Controller,
  Terminal.View.fpGUI;

const
  CONFIG_FILE = 'font.conf';

type
  TTerminalForm = class(TTerminalFPGUIForm)
  private
    FController: TTerminalController;
    FCloseTimer: TfpgTimer;
    FCloseCountdown: Integer;
    procedure FormShow(Sender: TObject);
    procedure FontChanged(Sender: TObject);
    procedure ShellExited(Sender: TObject);
    procedure CloseTickTimer(Sender: TObject);
    procedure WriteCountdown(N: Integer);
    function ConfigPath: string;
    procedure LoadFont;
    procedure SaveFont;
  protected
    procedure AfterCreate; override;
  public
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
begin
  if not FileExists(ConfigPath) then Exit;
  AssignFile(F, ConfigPath);
  try
    Reset(F);
    if not Eof(F) then
    begin
      ReadLn(F, S);
      S := Trim(S);
      if S <> '' then
        TerminalView.FontDesc := S;
    end;
    if not Eof(F) then
    begin
      ReadLn(F, S);
      S := Trim(S);
      if S <> '' then
        TerminalView.EmojiFontDesc := S;
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
    WriteLn(F, TerminalView.FontDesc);
    WriteLn(F, TerminalView.EmojiFontDesc);
  finally
    CloseFile(F);
  end;
end;

procedure TTerminalForm.AfterCreate;
begin
  inherited AfterCreate;
  FController := TTerminalController.Create(80, 25, 5000);
  TerminalView.AttachController(FController);
  LoadFont;
  TerminalView.OnFontChanged := @FontChanged;
  TerminalView.OnShellExit := @ShellExited;
  OnShow := @FormShow;
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
  FCloseTimer := TfpgTimer.Create(1000);
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
  TerminalView.SetFocus;
end;

procedure TTerminalForm.FontChanged(Sender: TObject);
begin
  SaveFont;
end;

procedure MainProc;
var
  frm: TTerminalForm;
begin
  fpgApplication.Initialize;
  frm := TTerminalForm.Create(nil);
  try
    frm.Show;
    fpgApplication.Run;
  finally
    frm.Free;
  end;
end;

begin
  MainProc;
end.
