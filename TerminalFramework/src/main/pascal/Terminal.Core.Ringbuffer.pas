unit Terminal.Core.Ringbuffer;
{$mode objfpc}{$H+}
{$ModeSwitch advancedrecords}
{$ModeSwitch typehelpers}

interface

uses
  Classes, Sysutils;

type
  ERingBufferFull = class(Exception);
  ERingBufferEmpty = class(Exception);

  generic TRingBuffer<T: class> = class
  private type
    TArrayOfT = array of T;
  private
    FData: TArrayOfT;
    FHead: SizeInt;
    FTail: SizeInt;
    FCount: SizeInt;
    FOwnsObjects: Boolean;
    FOverwriteWhenFull: Boolean;
    function GetCapacity: SizeInt;
    function NextIndex(AIndex: SizeInt): SizeInt; inline;
    function PrevIndex(AIndex: SizeInt): SizeInt; inline;
    procedure FreeSlot(AIndex: SizeInt);
    function GetItem(AIndex: SizeInt): T;
  public
    constructor Create(ACapacity: SizeInt;
      AOwnsObjects: Boolean = True;
      AOverwriteWhenFull: Boolean = False);
    destructor Destroy; override;

    procedure Clear;

    procedure Push(AItem: T);
    function Pop: T;
    function PeekFirst: T;
    function PeekLast: T;

    property Count: SizeInt read FCount;
    property Capacity: SizeInt read GetCapacity;
    property OwnsObjects: Boolean read FOwnsObjects write FOwnsObjects;
    property OverwriteWhenFull: Boolean read FOverwriteWhenFull write FOverwriteWhenFull;

    property Items[AIndex: SizeInt]: T read GetItem; default;
  end;

 implementation

 constructor TRingBuffer.Create(ACapacity: SizeInt;
  AOwnsObjects: Boolean; AOverwriteWhenFull: Boolean);
begin
  inherited Create;
  if ACapacity <= 0 then
    raise Exception.Create('Capacity must be > 0');

  SetLength(FData, ACapacity);
  FHead := 0;
  FTail := 0;
  FCount := 0;
  FOwnsObjects := AOwnsObjects;
  FOverwriteWhenFull := AOverwriteWhenFull;
end;

destructor TRingBuffer.Destroy;
begin
  Clear;
  inherited Destroy;
end;

function TRingBuffer.GetCapacity: SizeInt;
begin
  Result := Length(FData);
end;

function TRingBuffer.NextIndex(AIndex: SizeInt): SizeInt;
begin
  Inc(AIndex);
  if AIndex >= Length(FData) then
    AIndex := 0;
  Result := AIndex;
end;

function TRingBuffer.PrevIndex(AIndex: SizeInt): SizeInt;
begin
  if AIndex = 0 then
    Result := Length(FData) - 1
  else
    Result := AIndex - 1;
end;

procedure TRingBuffer.FreeSlot(AIndex: SizeInt);
begin
  if FData[AIndex] <> nil then
  begin
    if FOwnsObjects then
      FData[AIndex].Free;
    FData[AIndex] := nil;
  end;
end;

procedure TRingBuffer.Clear;
var
  I: SizeInt;
begin
  for I := 0 to High(FData) do
    FreeSlot(I);

  FHead := 0;
  FTail := 0;
  FCount := 0;
end;

procedure TRingBuffer.Push(AItem: T);
begin
  if AItem = nil then
    raise Exception.Create('Push: item is nil');

  if FCount = Length(FData) then
  begin
    if not FOverwriteWhenFull then
      raise ERingBufferFull.Create('Ring buffer is full');

    FreeSlot(FTail);
    FTail := NextIndex(FTail);
    Dec(FCount);
  end;

  FData[FHead] := AItem;
  FHead := NextIndex(FHead);
  Inc(FCount);
end;

function TRingBuffer.Pop: T;
begin
  if FCount = 0 then
    raise ERingBufferEmpty.Create('Ring buffer is empty');

  Result := FData[FTail];
  FData[FTail] := nil;
  FTail := NextIndex(FTail);
  Dec(FCount);
end;

function TRingBuffer.PeekFirst: T;
begin
  if FCount = 0 then
    raise ERingBufferEmpty.Create('Ring buffer is empty');
  Result := FData[FTail];
end;

function TRingBuffer.PeekLast: T;
begin
  if FCount = 0 then
    raise ERingBufferEmpty.Create('Ring buffer is empty');
  Result := FData[PrevIndex(FHead)];
end;

function TRingBuffer.GetItem(AIndex: SizeInt): T;
var
  RealIndex: SizeInt;
begin
  if (AIndex < 0) or (AIndex >= FCount) then
    raise Exception.CreateFmt('Index %d out of bounds (Count=%d)', [AIndex, FCount]);

  RealIndex := FTail + AIndex;
  if RealIndex >= Length(FData) then
    Dec(RealIndex, Length(FData));

  Result := FData[RealIndex];
end;

end.

 end.
