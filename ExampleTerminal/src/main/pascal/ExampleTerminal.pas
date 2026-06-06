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
    procedure FormShow(Sender: TObject);
    procedure FontChanged(Sender: TObject);
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
  OnShow := @FormShow;
end;

destructor TTerminalForm.Destroy;
begin
  TerminalView.DetachController;
  FreeAndNil(FController);
  inherited Destroy;
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
