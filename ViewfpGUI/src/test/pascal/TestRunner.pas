{
  This file is part of the TerminalEmulatorAgregator project.
  Copyright (c) 2026 Andrew Haines

  SPDX-License-Identifier: BSD-3-Clause

  Licensed under the BSD-3-Clause License. See LICENSE file for details.
}

program TestRunner;

{$mode objfpc}{$H+}

uses
  Classes, SysUtils, fpcunit, testregistry, consoletestrunner;

type
  { Sample test case - replace with your actual tests }
  TSampleTest = class(TTestCase)
  published
    procedure TestExample;
  end;

procedure TSampleTest.TestExample;
begin
  AssertEquals('Sample test', 2, 1 + 1);
end;

var
  Application: TTestRunner;

begin
  Application := TTestRunner.Create(nil);
  try
    RegisterTest(TSampleTest);
    Application.Initialize;
    Application.Run;
  finally
    Application.Free;
  end;
end.
