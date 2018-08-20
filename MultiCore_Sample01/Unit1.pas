unit Unit1;

interface

uses
  Windows, Messages, SysUtils, Variants, Classes, Graphics, Controls, Forms,
  Dialogs, Menus, ExtCtrls, StdCtrls,
  mmsystem,
  uMultiCore;

// multicore user record
type
  TMultiCoreData = record
    // scanline area
    StartIndex,EndIndex : integer;
    // rgb-color prefix sum
    AccumLength : integer;
    AccumR,AccumG,AccumB : array of integer;
  end;
  PMultiCoreData = ^TMultiCoreData;

type
  TForm1 = class(TForm)
    MainPaintBox: TPaintBox;
    MainMenu1: TMainMenu;
    EditMenuItem: TMenuItem;
    ClearMenuItem: TMenuItem;
    LogMemo: TMemo;
    MultiCoreMenuItem: TMenuItem;
    EnableMenuItem: TMenuItem;
    DisableMenuItem: TMenuItem;
    procedure FormCreate(Sender: TObject);
    procedure FormDestroy(Sender: TObject);
    procedure MainPaintBoxPaint(Sender: TObject);
    procedure ClearMenuItemClick(Sender: TObject);
    procedure MainPaintBoxMouseDown(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure MainPaintBoxMouseUp(Sender: TObject; Button: TMouseButton;
      Shift: TShiftState; X, Y: Integer);
    procedure MainPaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X,
      Y: Integer);
    procedure FormResize(Sender: TObject);
    procedure MultiCoreMenuItemClick(Sender: TObject);
    procedure EnableMenuItemClick(Sender: TObject);
    procedure DisableMenuItemClick(Sender: TObject);
  private
    { Private 宣言 }
    // enbale
    MultiCoreEnable : boolean;
    // core threads
    corecount : integer;
    // bitmap buffer
    Buffer : TBitmap;
    // cache bitmap scanline[]
    // warning : if call TBitmap.Scaline[] function in multicore process, the speed drops markedly.
    // 注意：マルチコア処理下でTBitmap.Scanline[]を使用すると、速度が著しく低下します。
    // get Scanline pointer in advance to avoid it(speed drops).
    // 速度低下を回避するには、あらかじめスキャラインを取得しておきましょう。
    BufferScanline : array of pointer;
    // user record
    UserRecord : array of TMultiCoreData;
    // mouse down event flag
    MouseDownFlag : boolean;

    // multicore blur function
    procedure MultiCore_HorizonBlur(ptr:pointer);
    // buffer & multicore userrecord update
    procedure SizeUpdate;
  public
    { Public 宣言 }
    procedure DrawBuffer;
  end;

var
  Form1: TForm1;

implementation

{$R *.dfm}

procedure TForm1.ClearMenuItemClick(Sender: TObject);
begin
  // clear
  Buffer.Canvas.Brush.Style := bsSolid;   // solid fill
  Buffer.Canvas.Brush.Color := $00ffffff; // black
  Buffer.Canvas.FillRect(rect(0,0,Buffer.Width,Buffer.Height));
end;

procedure TForm1.DisableMenuItemClick(Sender: TObject);
begin
  MultiCoreEnable := false;
end;

procedure TForm1.DrawBuffer;
begin
  BitBlt(
    MainPaintBox.Canvas.Handle,
    0,0,Buffer.Width,Buffer.Height,
    Buffer.Canvas.Handle,
    0,0,
    SRCCOPY
  );
end;

procedure TForm1.EnableMenuItemClick(Sender: TObject);
begin
  MultiCoreEnable := true;
end;

procedure TForm1.FormCreate(Sender: TObject);
begin
  MultiCoreEnable := true;

  // create & initialize multicore
  _MultiCoreInitialize(4);
  corecount := _MultiCoreManager.Count;

  // buffer
  Buffer := TBitmap.Create;
  Buffer.HandleType := bmDIB;
  Buffer.PixelFormat := pf32bit;

  // multicore user record
  SetLength(UserRecord,CoreCount);

  // size update
  // buffer & userdata & scanline
  SizeUpdate;

  TimeBeginPeriod(1);
end;

procedure TForm1.FormDestroy(Sender: TObject);
begin
  // free multicore
  _MultiCoreFinalize;

  // buffer
  Buffer.Free;

  TimeEndPeriod(1);
end;

procedure TForm1.FormResize(Sender: TObject);
begin
  // To be called after FormDestroy :-Q
  if not(self.Showing) then exit;

  SizeUpdate;
end;

procedure TForm1.MainPaintBoxMouseDown(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  MouseDownFlag := true;

  // draw circle
  MainPaintBoxMouseMove(sender,Shift,X,Y);
end;

procedure TForm1.MainPaintBoxMouseMove(Sender: TObject; Shift: TShiftState; X, Y: Integer);
var
  col : integer;
  l : integer;
  i : integer;
  t : int64;
begin
  if not(MouseDownFlag) then exit;

  // left button
  if not(Shift = [ssLeft]) then exit;

  // random color
  col := random($ffffff);
  // draw circle
  Buffer.Canvas.Pen.Style := psSolid;
  Buffer.Canvas.Pen.Color := col;
  Buffer.Canvas.Brush.Style := bsSolid;
  Buffer.Canvas.Brush.Color := col;

  l := random(20) + 60;
  Buffer.Canvas.Ellipse(X-l,Y-l,X+l,Y+l);

  // *** multicore processing ***
  // blur buffer
  // task add
  for i:=0 to CoreCount-1 do
    _MultiCoreManager.Add(MultiCore_HorizonBlur,@UserRecord[i]);
  // start
  t := TimeGetTime;
  if MultiCoreEnable then _MultiCoreManager.Start          // multicore mode
                     else _MultiCoreManager.Start(true);   // single mode
  // sync
  _MultiCoreManager.Sync;
  t := TimeGetTime - t;

  // log
  LogMemo.Lines.Add(IntToStr(t)+'ms');

  // buffer
  DrawBuffer;
  // wait
  sleep(10);
end;

procedure TForm1.MainPaintBoxMouseUp(Sender: TObject; Button: TMouseButton; Shift: TShiftState; X, Y: Integer);
begin
  MouseDownFlag := false;
end;

procedure TForm1.MainPaintBoxPaint(Sender: TObject);
begin
  DrawBuffer;
end;

procedure TForm1.MultiCoreMenuItemClick(Sender: TObject);
begin
  // menu check update
  EnableMenuItem.Checked := MultiCoreEnable = true;
  DisableMenuItem.Checked := MultiCoreEnable= false;
end;

procedure TForm1.MultiCore_HorizonBlur(ptr: pointer);
const
  blurpixel : integer = 24;
var
  data : PMultiCoreData;
  i,j,len : integer;
  sline,eline : integer;
  sptr : ^cardinal;
  r,g,b : integer;
  leftpos,rightpos,divcount : integer;
begin
  // user record pointer
  data := PMultiCoreData(ptr);
  // area
  sline := data.startindex;
  eline := data.endindex;

  for i:=sline to eline do
  begin
    // make prefix sum buffer(add)
    // https://en.wikipedia.org/wiki/Prefix_sum
    //
    len := data.AccumLength;
    r := 0;
    g := 0;
    b := 0;
    sptr := BufferScanline[i];
    for j:=0 to len-1 do
    begin
      r := r + (sptr^ and $ff0000) shr 16;
      g := g + (sptr^ and $00ff00) shr  8;
      b := b + (sptr^ and $0000ff);
      data.AccumR[j] := r;
      data.AccumG[j] := g;
      data.AccumB[j] := b;
      inc(sptr);
    end;

    // blur
    // AccumRGB[pos+8] - AccumRGB[pos-8] = RGB[pos-8] + RGB[pos-7] + ... + RGB[pos+7] + RGB[pos+8]
    sptr := BufferScanline[i];
    for j:=0 to len-1 do
    begin
      leftpos  := j - blurpixel;
      rightpos := j + blurpixel;
      if leftpos < 0 then leftpos := 0;
      if rightpos > len-1 then rightpos := len-1;
      divcount := rightpos - leftpos;
      r := data.AccumR[rightpos] - data.AccumR[leftpos];
      g := data.AccumG[rightpos] - data.AccumG[leftpos];
      b := data.AccumB[rightpos] - data.AccumB[leftpos];
      r := (r div divcount) and $ff;
      g := (g div divcount) and $ff;
      b := (b div divcount) and $ff;
      r := (r shl 16) or (g shl 8) or b;
      sptr^ := r;
      inc(sptr);
    end;
  end;
end;

procedure TForm1.SizeUpdate;
var
  i : integer;
begin
  // buffer
  Buffer.SetSize(MainPaintBox.Width,MainPaintBox.Height);
  // clear
  Buffer.Canvas.Brush.Style := bsSolid;   // solid fill
  Buffer.Canvas.Brush.Color := $00ffffff; // black
  Buffer.Canvas.FillRect(rect(0,0,Buffer.Width,Buffer.Height));

  // get scanline
  SetLength(BufferScanline,Buffer.Height);
  for i:=0 to Buffer.Height-1 do
    BufferScanline[i] := Buffer.ScanLine[i];

  // setup multicore user record
  for i:=0 to CoreCount-1 do
  begin
    // process index area (do not duplicate area)
    UserRecord[i].startindex := (i * Buffer.Height) div CoreCount;
    UserRecord[i].endindex   := ((i+1) * Buffer.Height) div CoreCount -1;
    // Accumlation buffer (horizon only)
    UserRecord[i].AccumLength := Buffer.Width;
    SetLength(UserRecord[i].AccumR , Buffer.Width);
    SetLength(UserRecord[i].AccumG , Buffer.Width);
    SetLength(UserRecord[i].AccumB , Buffer.Width);
  end;
end;

end.

