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

type
  TTerminalForm = class(TTerminalFPGUIForm)
  private
    FController: TTerminalController;
    procedure FormShow(Sender: TObject);
  protected
    procedure AfterCreate; override;
  public
    destructor Destroy; override;
  end;

procedure TTerminalForm.AfterCreate;
begin
  inherited AfterCreate;
  FController := TTerminalController.Create(80, 25, 5000);
  TerminalView.AttachController(FController);
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
