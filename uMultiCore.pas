unit uMultiCore;

interface

uses Windows,Classes;

const _MultiCoreRotateCycle=16;

// function type
type
  TMultiCoreThreadFunc = procedure(ptr:Pointer);
  TMultiCoreThreadEvent = procedure(ptr:pointer) of object;

type
  // TemaphoreClass
  TMultiCoreSemaphore=class
    protected
      //FSema : THANDLE;
      FCS : TRTLCriticalSection;
    public
      constructor Create(name:String='');
      destructor  Destroy; override;
      procedure   Lock(t:DWORD=$FFFFFF);
      procedure   UnLock;
  end;
  // MultiCore Thread Class
  TMultiCoreThreadData=packed record
    CoreNo : Integer;
    FuncPtr : TMultiCoreThreadFunc;
    EventPtr : TMultiCoreThreadEvent;
    UserPtr : Pointer;
  end;
  TMultiCoreThread=class(TThread)
    protected
      FThreadCount,FThreadIndex : Integer;
      // task array
      FTasks : array of TMultiCoreThreadData;
      FTaskCount,FEntryCount: Integer;

      FSem : TMultiCoreSemaphore;      // sync between mainthread and subthread
      FWaitSem : TMultiCoreSemaphore;  // wait(satndby) semaphore
      FStart : Boolean;                // task start flag. polling.
      FFinished : boolean;             // task finished flag. polling.
      FWeight : integer;               // task virtual weight.

      procedure   TaskArrayResize(need:integer);
      procedure   TaskExcute;
      procedure   Execute; override;
    public
      constructor Create(aThreadIndex,aThreadCount:integer);
      destructor  Destroy; override;
      procedure   Clear;
      procedure   TaskStart;
      procedure   TaskSync(sleeptime:integer=0);
      procedure   TaskAdd(func:TMultiCoreThreadFunc; ptr:Pointer); overload;
      procedure   TaskAdd(event:TMultiCoreThreadEvent; ptr:Pointer); overload;

      property    Weight:integer read FWeight write FWeight;
  end;
  // Manager Class
  TMultiCoreThreadManager=class
    protected
      // thread
      FThreadCount : Integer;
      FThread : array of TMultiCoreThread;

      FCoreLock : Boolean;
      FSingleCoreProcess : Boolean;
      FRotateCycle : Integer;
      FTaskRotate : Boolean;

      procedure   CreateThread(n:Integer);
      procedure   FreeThread;
      function    GetLightWeightCore(FuncWeight:integer):integer;
    public
      constructor Create(ThreadCount:Integer=1; CoreLock:Boolean=TRUE);
      destructor  Destroy; override;
      procedure   Clear;

      procedure   Start(SingleCoreProcess:Boolean=FALSE);
      procedure   Sync(sleeptime:Integer=0);
      procedure   Add(func:TMultiCoreThreadFunc; ptr:Pointer; FuncWeight:Integer=1; ThreadIndex:Integer=-1); overload;
      procedure   Add(event:TMultiCoreThreadEvent; ptr:Pointer; FuncWeight:Integer=1; ThreadIndex:Integer=-1); overload;

      property    Count:Integer read FThreadCount;
      property    TaskRotate:Boolean read FTaskRotate write FTaskRotate;  // rotation use core index.
  end;

//get core count function
function _MultiCoreGetCoreCount:Integer;
//initialize
procedure _MultiCoreInitialize(ThreadCount:Integer=2; CoreLock:Boolean=true); // corelock=false : normal thread mode.
//finalize
procedure _MultiCoreFinalize;

var
  _MultiCoreManager:TMultiCoreThreadManager = nil;
  _MultiCore_IdealProcessorMargin:Integer = 1;     // ThreadCount >= CPU.CoreCount-Margin ... thread force lock each core.
  _MultiCore_SpinOutCount:integer = 500;           // CriticalSection SpinOutTime.

implementation


procedure _MultiCoreInitialize(ThreadCount:Integer; CoreLock:Boolean);
var
  cores : integer;
begin
  cores := _MultiCoreGetCoreCount;
  if ThreadCount > cores then ThreadCount := cores;

  _MultiCoreManager := TMultiCoreThreadManager.Create(ThreadCount,CoreLock);
end;

procedure _MultiCoreFinalize;
begin
  _MultiCoreManager.Free;
  _MultiCoreManager := nil;
end;

function _MultiCoreGetCoreCount:Integer;
  function inCoreCount(const r:SYSTEM_INFO):Integer;
  var
    n,a,i : Integer;
    nn : Integer;
  begin
    nn := 0;
    n := r.dwNumberOfProcessors;

    a := 1;
    for i:=0 to n-1 do
    begin
      if (r.dwActiveProcessorMask and a) <> 0 then inc(nn);
      a := a shl 1;
    end;
    RESULT := nn;
  end;
var
  r : SYSTEM_INFO;
  v : OSVERSIONINFO;
  nn : Integer;
begin
  RESULT := 1;
  //OS Check
  v.dwOSVersionInfoSize := sizeof(OSVERSIONINFO);
  GetVersionEx(v);
  if not(v.dwMajorVersion >= 5)then exit;  //Windows98系はダメ

  GetSystemInfo(r);
  nn := inCoreCount(r); //nn := r.dwNumberOfProcessors;  //論理コア
  if nn < 1   then nn := 1;
  if nn > 256 then nn := 256;
  RESULT := nn;
end;


{ TMultiCoreThread }

procedure TMultiCoreThread.TaskAdd(func: TMultiCoreThreadFunc; ptr: Pointer);
begin
  TaskArrayResize(FEntryCount+1);

  FTasks[FEntryCount].FuncPtr := func;
  FTasks[FEntryCount].EventPtr := nil;
  FTasks[FEntryCount].UserPtr := ptr;

  inc(FEntryCount);
end;

constructor TMultiCoreThread.Create(aThreadIndex,aThreadCount:integer);
begin
  FThreadIndex := aThreadIndex;  // ThreadNo
  FThreadCount := aThreadCount;  // AllThreadCount

  FTaskCount := 64;              // start cache size
  SetLength(FTasks,FTaskCount);

  FSem := TMultiCoreSemaphore.Create('');
  FWaitSem := TMultiCoreSemaphore.Create('');
  FWaitSem.Lock;

  FStart := false;
  FFinished := false;
  FEntryCount := 0;

  inherited Create(true);        //create suspend true
end;

procedure TMultiCoreThread.TaskAdd(event: TMultiCoreThreadEvent; ptr: Pointer);
begin
  TaskArrayResize(FEntryCount+1);

  FTasks[FEntryCount].FuncPtr := nil;
  FTasks[FEntryCount].EventPtr := event;
  FTasks[FEntryCount].UserPtr := ptr;

  inc(FEntryCount);
end;

procedure TMultiCoreThread.TaskArrayResize(need:integer);
var
  newlen : integer;
begin
  newlen := FTaskCount;
  while (need >= newlen) do
    newlen := newlen * 2;

  if FTaskCount <> newlen then
  begin
    FTaskCount := newlen;
    SetLength(FTasks,newlen);
  end;
end;

procedure TMultiCoreThread.TaskExcute;
var
  i,n : Integer;
begin
  n := FEntryCount;
  for i:=0 to n-1 do
  begin
    // function
    if (Assigned(FTasks[i].FuncPtr))then
    begin
      try
        FTasks[i].FuncPtr(FTasks[i].UserPtr);
      except
        break;
      end;
    end;

    // event (class method)
    if (Assigned(FTasks[i].EventPtr))then
    begin
      try
        FTasks[i].EventPtr(FTasks[i].UserPtr);
      except
        break;
      end;
    end;

  end;
end;

destructor TMultiCoreThread.Destroy;
begin
  FSem.Lock;
  FEntryCount := 0;
  FStart := true;                   //start flag
  FFinished := false;
  Terminate;                        //set terminate
  FSem.UnLock;

  if Suspended then Start;
  TaskStart;

  Sleep(1);
  WaitFor;                          //wait for escape execute function

  FSem.Free;
  FWaitSem.Free;

  inherited;
end;

procedure TMultiCoreThread.Execute;
var
  b : boolean;
begin
  // thread : Execute
  try
    while not Terminated do
    begin
      // wait start flag. always loop.
      while true do
      begin
        FWaitSem.Lock;   // wait. start-sysnc間のみunlockされる。処理がないときはここで停止。
        FWaitSem.UnLock;

        FSem.Lock;       // safety flag. FWaitSemだけでは終了時にLockが間に合わず数回通過するのでここで状態を監視する。
        b := FStart;
        FSem.UnLock;

        if b then break; // if enable startflag , break wait loop.

        sleep(0);
      end;

      // task execute
      TaskExcute;
      // task finished
      FSem.Lock;     // sync() との同期用
      FStart := false;
      FFinished := true;
      Clear;
      FSem.UnLock;
    end;
  except
    { error }
    FStart := false;
    FFinished := true;
    Clear;
  end;
end;

procedure TMultiCoreThread.Clear;
begin
  FEntryCount := 0;
  FWeight := 0;
end;

procedure TMultiCoreThread.TaskStart;
begin
  // MainThread：set start flag.
  // SubThread : break waitloop & task execute.

  // set start flag
  FSem.Lock;
  FStart := true;
  FFinished := false;
  FSem.UnLock;

  // subthread run
  if Suspended then Start;

  FWaitSem.UnLock;  // thread wait unlock
end;

procedure TMultiCoreThread.TaskSync(sleeptime:integer);
var
  b : boolean;
begin
  // MainThread : waitfor FFinished = true.
  // SubThread : task executing...
  while true do
  begin
    FSem.Lock;      //sync execute()
    b := FFinished;
    FSem.UnLock;

    if b then
    begin
      FSem.Lock;
      FStart := false;
      FFinished := false;
      FSem.UnLock;
      break;
    end;

    sleep(sleeptime);
  end;

  FWaitSem.Lock;    // thread wait lock. wait.
end;

{ TMultiCoreSemaphore }

constructor TMultiCoreSemaphore.Create(name: String);
begin
  //InitializeCriticalSection(&FCS);
  InitializeCriticalSectionAndSpinCount(&FCS,_MultiCore_SpinOutCount);
end;

destructor TMultiCoreSemaphore.Destroy;
begin
  DeleteCriticalSection(&FCS);
  inherited;
end;

procedure TMultiCoreSemaphore.Lock(t:DWORD);
begin
  EnterCriticalSection(&FCS);
end;

procedure TMultiCoreSemaphore.UnLock;
begin
  LeaveCriticalSection(&FCS);
end;

{ TMultiCoreThreadManager }

procedure TMultiCoreThreadManager.Add(func: TMultiCoreThreadFunc; ptr: Pointer;  FuncWeight,ThreadIndex:Integer);
var
  n : Integer;
begin
  if ThreadIndex < 0 then
  begin
    //select min weight thread.
    n := GetLightWeightCore(FuncWeight);
  end
  else
  begin
    n := ThreadIndex;
    if not(n < FThreadCount) then n := FThreadCount-1;
  end;

  //add
  FThread[n].TaskAdd(func,ptr);
  //weight
  FThread[n].Weight := FThread[n].FWeight + FuncWeight;
end;

procedure TMultiCoreThreadManager.CreateThread(n: Integer);
  const inMaxProcesserMask:integer = 31;

  function inRotation(n:integer):integer;
  begin
    result := (n + 1) and inMaxProcesserMask;
  end;
  function inBit(no:integer):cardinal;
  begin
    result := 1 shl (no and 31);
  end;
  procedure inCoreLock;
  var
    no : integer;
    i : Integer;
    r : SYSTEM_INFO;
    v : OSVERSIONINFO;
    b : Boolean;
  begin
    // OS version check
    v.dwOSVersionInfoSize := sizeof(OSVERSIONINFO);
    GetVersionEx(v);
    if not(v.dwMajorVersion >= 5)then exit;  // need windows2000 upper.

    // use SetThreadAffinityMask() flag.
    //スレッド数がプロセッサ数と同じ場合は、AffinityMaskを使用する
    GetSystemInfo(r);
    b := TRUE;
    if FThreadCount <= r.dwNumberOfProcessors-_MultiCore_IdealProcessorMargin then b := FALSE;

    no := (r.dwNumberOfProcessors div 2) and 0;  // rotation start index
    for i:=0 to FThreadCount-1 do
    begin
      while (r.dwActiveProcessorMask and inBit(no) = 0) do
        no := inRotation(no);

      if (b)then
        SetThreadAffinityMask(FThread[i].Handle,inBit(no))   // set bit mask. use core lock.
      else
        SetThreadIdealProcessor(FThread[i].Handle,no);       // set no. auto idel core select.

      no := inRotation(no);
    end;
  end;
var
  i : Integer;
begin
  FreeThread;

  FThreadCount := n;
  SetLength(FThread,FThreadCount);
  for i:=0 to FThreadCount-1 do
    FThread[i] := TMultiCoreThread.Create(i,FThreadCount);

  if (FCoreLock)then inCoreLock;
end;

procedure TMultiCoreThreadManager.Add(event: TMultiCoreThreadEvent; ptr: Pointer; FuncWeight, ThreadIndex: Integer);
var
  n : Integer;
begin
  if ThreadIndex < 0 then
  begin
    //select min weight thread.
    n := GetLightWeightCore(FuncWeight);
  end
  else
  begin
    n := ThreadIndex;
    if not(n < FThreadCount) then n := FThreadCount-1;
  end;

  //add
  FThread[n].TaskAdd(event,ptr);
  //weight
  FThread[n].Weight := FThread[n].FWeight + FuncWeight;
end;

constructor TMultiCoreThreadManager.Create(ThreadCount:Integer; CoreLock:Boolean);
begin
  if ThreadCount < 1 then ThreadCount := 1;

  FCoreLock := CoreLock;
  FTaskRotate := true;

  CreateThread(ThreadCount);
  Clear;

  // create thread & standby
  Start;
  Sync;
end;

destructor TMultiCoreThreadManager.Destroy;
begin
  FreeThread;

  inherited;
end;

procedure TMultiCoreThreadManager.FreeThread;
var
  th : TMultiCoreThread;
begin
  for th in FThread do
    th.Free;
  FThreadCount := 0;
end;

function TMultiCoreThreadManager.GetLightWeightCore(FuncWeight: integer): integer;
var
  w : integer;
  i : integer;
  rot,idx : integer;
begin
  // rotation usecore index
  rot := FRotateCycle div _MultiCoreRotateCycle;
  rot := rot mod FThreadCount;
  if not(FTaskRotate) then rot := 0;

  w := $FFFFFF;
  result := 0;
  for i:=0 to FThreadCount-1 do
  begin
    // index rotation
    idx := rot + i;
    if idx >= FThreadCount then idx := idx - FThreadCount;

    // select min weight
    if FThread[idx].Weight < w then
    begin
      result := idx;
      w := FThread[idx].Weight;
    end;
  end;
end;

procedure TMultiCoreThreadManager.Clear;
var
  th : TMultiCoreThread;
begin
  for th in FThread do
    th.Clear;
end;

procedure TMultiCoreThreadManager.Start(SingleCoreProcess:Boolean);
var
  th : TMultiCoreThread;
begin
  FSingleCoreProcess := SingleCoreProcess;         // single process flag

  // rotation usecore index
  FRotateCycle := (FRotateCycle + 1) and $ffffff;

  if FSingleCoreProcess then
  begin
    // Single(MainThread)
    for th in FThread do
      th.TaskExcute;
  end
  else
  begin
    // Multicore(SubThreads)
    for th in FThread do
      th.TaskStart;

    Sleep(0);
  end;
end;

procedure TMultiCoreThreadManager.Sync(sleeptime:Integer);
var
  th : TMultiCoreThread;
begin
  if (FSingleCoreProcess)then
  begin
    // SingleCore
    // none
  end
  else
  begin
    // MultiCore
    // wait thread task finished
    for th in FThread do
      th.TaskSync(sleeptime);
  end;

  Clear;
end;

end.
