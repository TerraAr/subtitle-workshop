unit WaveformAdapter;

interface

uses
  Windows,
  SysUtils,
  Classes,
  ExtCtrls,
  Controls,
  Graphics,
  Types,
  VirtualTrees,
  WAVDisplayerUnit,
  Renderer,
  SubStructUnit,
  CommonTypes;

type

  // Adapter for simple usage TWAVDisplayer bound with TVirtualStringTree
  TWaveformAdapter = class
  private
    WAVDisplayer        : TWAVDisplayer;
    WAVRenderer         : TDShowRenderer;
    FSourceTree         : TVirtualStringTree;
    FSceneChangeWrapper : TSceneChangeWrapper;
    FCharset            : Byte;
    FShowSubtitleText   : Boolean;
    FSafetyOffset       : Integer;

    procedure InitDisplayer(parentPanel: TPanel);
    procedure InitRenderer;
    function HasNodeChanged(node: PVirtualNode): Boolean;
    procedure UpdateSceneChanges;

  protected
    procedure OnCustomDrawRange(Sender: TObject; ACanvas: TCanvas; Range: TRange; Rect: TRect);
    procedure SelectNode(node: PVirtualNode);
    function GetSelectedNode: PVirtualNode;
    procedure SetCharset(charset: Byte);
    procedure SetSafetyOffset(offset: Integer);
    procedure PlaySubtitle(next: Boolean);
  public
    constructor Create(parentPanel: TPanel; sourceTree: TVirtualStringTree);
    destructor Destroy; override;
    
    procedure Clear;
    procedure ClearSubtitles;
    procedure LoadWAV(filename: WideString);
    procedure AddSubtitle; overload;
    procedure AddSubtitle(node: PVirtualNode); overload;
    procedure SyncSubtitlesWithTree;
    procedure UpdateSubtitle; overload;
    procedure UpdateSubtitle(node: PVirtualNode); overload;
    procedure DeleteSubtitle; overload;
    procedure DeleteSubtitle(node: PVirtualNode); overload;
    procedure ClearSelection;
    procedure InsertSceneChange;
    procedure DeleteSceneChangesInSelection;
    procedure PlayPause;
    procedure Stop;
    procedure PlayNextSubtitle;
    procedure PlayPrevSubtitle;

    property Displayer: TWAVDisplayer read WAVDisplayer;
    property Renderer: TDShowRenderer read WAVRenderer;
    property SelectedNode: PVirtualNode read GetSelectedNode write SelectNode;
    property Charset: Byte read FCharset write SetCharset;
    property ShowSubtitleText: Boolean read FShowSubtitleText write FShowSubtitleText;
    property SafetyOffset: Integer read FSafetyOffset write SetSafetyOffset;
  end;

//------------------------------------------------------------------------------

implementation

uses
  TreeViewHandle;
  
// Common utility routines

var
  rangeFactory: TSubtitleRangeFactory;

type
  TAccessCanvas = class(TCanvas);

procedure CanvasDrawText(Canvas: TCanvas; Rect: TRect;
  const Text: AnsiString; AllowLineBreak : Boolean = False; AlignBottom : Boolean = True);
var
  Options: Cardinal;
  OriginalRectBottom, OriginalRectRight, BottomDiff : Integer;
begin
  with TAccessCanvas(Canvas) do begin
    Changing;
    RequiredState([csHandleValid, csFontValid, csBrushValid]);
    Options := DT_END_ELLIPSIS or DT_NOPREFIX or DT_EDITCONTROL;
    if AllowLineBreak then
      Options := Options or DT_WORDBREAK;
    if AlignBottom then
    begin
      OriginalRectBottom := Rect.Bottom;
      OriginalRectRight := Rect.Right;
      Windows.DrawText(Handle, PChar(Text), Length(Text), Rect, Options or DT_CALCRECT);
      BottomDiff := OriginalRectBottom - Rect.Bottom;
      if (BottomDiff > 0) then
        OffsetRect(Rect, 0, BottomDiff)
      else
        Rect.Bottom := OriginalRectBottom;
      Rect.Right := OriginalRectRight;
    end;
    Windows.DrawText(Handle, PChar(Text), Length(Text), Rect, Options);
    Changed;
  end;
end;

// TWaveformAdapter

constructor TWaveformAdapter.Create(parentPanel: TPanel; sourceTree: TVirtualStringTree);
begin
  FSourceTree := sourceTree;
  FCharset    := DEFAULT_CHARSET;

  InitDisplayer(parentPanel);
end;

destructor TWaveformAdapter.Destroy;
begin
  FSourceTree := nil;

  FreeAndNil(WAVRenderer);
  FreeAndNil(WAVDisplayer);

  inherited;
end;

procedure TWaveformAdapter.InitDisplayer(parentPanel: TPanel);
begin
  WAVDisplayer := TWAVDisplayer.Create(nil);

  WAVDisplayer.OnCustomDrawRange := Self.OnCustomDrawRange;

  with WAVDisplayer do begin
    Left    := 0;
    Top     := 0;
    Width   := parentPanel.Width;
    Height  := parentPanel.Height - 12;
    Align   := alClient;
    Parent  := parentPanel;

    SetPageSizeMs(10000);
    AutoScrolling   := True;
    SnappingEnabled := True;
  end;

  FSceneChangeWrapper := TSceneChangeWrapper.Create;
end;

procedure TWaveformAdapter.InitRenderer;
begin
  WAVRenderer := TDShowRenderer.Create;
  WAVRenderer.SetAutoInsertCustomVSFilter(True);
  WAVDisplayer.SetRenderer(WAVRenderer);
end;

procedure TWaveformAdapter.Clear;
begin
  ClearSubtitles;
  with WAVDisplayer do begin
//    Enabled := False;
    Close;
    Invalidate;
    VerticalScaling := 100;
  end;
end;

procedure TWaveformAdapter.ClearSubtitles;
var
  emptyArray: TIntegerDynArray;
begin
  with WAVDisplayer do begin
    ClearRangeList;
    ClearRangeListVO;
    SetSceneChangeList(emptyArray);
  end;
  FSceneChangeWrapper.SetSceneChangeList(emptyArray);
end;

procedure TWaveformAdapter.LoadWAV(filename: WideString);
var
  loadWAV: Boolean;
begin
  loadWAV := WAVDisplayer.LoadWAV(filename);

  if loadWAV then begin
    InitRenderer;
    WAVRenderer.Open(filename);

    WAVDisplayer.Enabled := True;
    WAVDisplayer.SetPageSizeMs(WAVDisplayer.Length div 4);
  end;
end;

procedure TWaveformAdapter.AddSubtitle;
begin
  AddSubtitle(FSourceTree.FocusedNode);
end;

procedure TWaveformAdapter.AddSubtitle(node: PVirtualNode);
var
  range   : TSubtitleRange;
  subtitle: PSubtitleItem;
begin
  if Assigned(node) then begin
    subtitle := FSourceTree.GetNodeData(node);

    if Assigned(subtitle) then begin
      range       := TSubtitleRange(rangeFactory.CreateRangeSS(subtitle.InitialTime, subtitle.FinalTime));
      range.Text  := subtitle.Text;
      range.Node  := node;

      subtitle.Range := range;

      WAVDisplayer.AddRange(range);
    end;
  end;
end;

procedure TWaveformAdapter.SyncSubtitlesWithTree;
var
  node: PVirtualNode;
begin
  ClearSubtitles;
  
  node := FSourceTree.GetFirst;

  while Assigned(node) do begin
    AddSubtitle(node);

    node := FSourceTree.GetNextSibling(node);
  end;
end;

function TWaveformAdapter.HasNodeChanged(node: PVirtualNode): Boolean;
var
  range   : TSubtitleRange;
  subtitle: PSubtitleItem;
begin
  Result := False;

  subtitle  := FSourceTree.GetNodeData(node);
  range     := subtitle.Range;

  if  (range.StartTime <> subtitle.InitialTime) or
      (range.StopTime <> subtitle.FinalTime) or
      (range.Text <> subtitle.Text) then
     Result := True;
end;

procedure TWaveformAdapter.UpdateSubtitle;
begin
  UpdateSubtitle(FSourceTree.FocusedNode);
end;

procedure TWaveformAdapter.UpdateSubtitle(node: PVirtualNode);
var
  range   : TSubtitleRange;
  subtitle: PSubtitleItem;
begin
  if Assigned(node) then begin
    subtitle  := FSourceTree.GetNodeData(node);
    range     := subtitle.Range;

    if Assigned(range) then begin
      if not HasNodeChanged(node) then Exit;

      range.StartTime := subtitle.InitialTime;
      range.StopTime  := subtitle.FinalTime;
      range.Text      := subtitle.Text;

      WAVDisplayer.RefreshSelection;
    end;
  end;
end;

procedure TWaveformAdapter.DeleteSubtitle;
begin
  DeleteSubtitle(FSourceTree.FocusedNode);
end;

procedure TWaveformAdapter.DeleteSubtitle(node: PVirtualNode);
var
  range   : TSubtitleRange;
  subtitle: PSubtitleItem;
begin
  if Assigned(node) then begin
    subtitle  := FSourceTree.GetNodeData(node);
    range     := subtitle.Range;

    if Assigned(range) then
      WAVDisplayer.DeleteRangeAtIdx(WAVDisplayer.RangeList.IndexOf(range));
  end;
end;

procedure TWaveformAdapter.SelectNode(node: PVirtualNode);
var
  range   : TSubtitleRange;
  subtitle: PSubtitleItem;
begin
  if Assigned(node) then begin
    if not FSourceTree.Selected[node] then Exit;
    
    subtitle  := FSourceTree.GetNodeData(node);
    range     := subtitle.Range;

    if Assigned(range) then begin
      WAVDisplayer.SelectedRange := range;
      WAVDisplayer.SetPositionMs(range.StartTime - WAVDisplayer.PageSize div 4);
    end;
  end else
    WAVDisplayer.ClearSelection;
end;

function TWaveformAdapter.GetSelectedNode: PVirtualNode;
begin
  Result := nil;
  if Assigned(WAVDisplayer.SelectedRange) then
    Result := TSubtitleRange(WAVDisplayer.SelectedRange).Node;
end;

procedure TWaveformAdapter.ClearSelection;
begin
  WAVDisplayer.ClearSelection;
end;

procedure TWaveformAdapter.SetCharset(charset: Byte);
begin
  FCharset := charset;

  WAVDisplayer.UpdateView([uvfRange]);
end;

procedure TWaveformAdapter.SetSafetyOffset(offset: Integer);
begin
  with WAVDisplayer do begin
    MinimumBlank            := offset;
    SceneChangeStartOffset  := offset;
    SceneChangeStopOffset   := offset;
    SceneChangeFilterOffset := offset;
  end;

  FSceneChangeWrapper.SetOffsets(offset, offset, offset);
end;

procedure TWaveformAdapter.InsertSceneChange;
var
  sceneChanges: TIntegerDynArray;
begin
  SetLength(sceneChanges, 1);
  sceneChanges[0] := WAVDisplayer.GetCursorPos;

  FSceneChangeWrapper.Insert(sceneChanges);

  UpdateSceneChanges;
end;

procedure TWaveformAdapter.DeleteSceneChangesInSelection;
begin
  with WAVDisplayer do begin
    if SelectionIsEmpty then Exit;

    FSceneChangeWrapper.Delete(Selection.StartTime, Selection.StopTime);
  end;
  UpdateSceneChanges;
end;

procedure TWaveformAdapter.UpdateSceneChanges;
begin
  WAVDisplayer.SetSceneChangeList(FSceneChangeWrapper.GetSCArray);
  WAVDisplayer.UpdateView([uvfRange]);
end;

procedure TWaveformAdapter.PlayPause;
var
  range: TSubtitleRange;
begin
  with WAVDisplayer do begin
    AutoScrolling := True;
    
    if IsPlaying then begin
      Pause;
      Exit;
    end;

    if SelectionIsEmpty then
      PlayRange(GetCursorPos, Length)
    else
      PlayRange(Selection);
  end;
end;

procedure TWaveformAdapter.Stop;
begin
  WAVDisplayer.Stop;
end;

procedure TWaveformAdapter.PlayNextSubtitle;
begin
  PlaySubtitle(True);
end;

procedure TWaveformAdapter.PlayPrevSubtitle;
begin
  PlaySubtitle(False);
end;

procedure TWaveformAdapter.PlaySubtitle(next: Boolean);
var
  ind: Integer;
begin
  with WAVDisplayer do begin
    AutoScrolling := True;
    
    if IsPlaying then Stop;
    if RangeList.Count = 0 then Exit;

    ind := RangeList.IndexOf(SelectedRange);

    if next then begin
      if (ind < RangeList.Count - 1) then Inc(ind);
    end else begin
      if (ind = -1) then ind := RangeList.Count;
      if (ind > 0) then Dec(ind);
    end;

    SelectedRange := RangeList[ind];
  end;

  PlayPause;
end;

procedure TWaveformAdapter.OnCustomDrawRange(Sender: TObject; ACanvas: TCanvas; Range : TRange; Rect : TRect);
const MINIMAL_SPACE : Integer = 25;
      TEXT_MARGINS : Integer = 5;
var WAVZoneHeight : Integer;
    AlignBottom : Boolean;
begin
  if (not FShowSubtitleText) then Exit;

  InflateRect(Rect, -TEXT_MARGINS, -TEXT_MARGINS);
  if (Rect.Right - Rect.Left) > MINIMAL_SPACE then begin
    ACanvas.Font.Charset := FCharset;

    WAVZoneHeight := WAVDisplayer.Height - WAVDisplayer.RulerHeight;
    AlignBottom := (Rect.Top > WAVZoneHeight div 2);
    ACanvas.Font.Color := ACanvas.Pen.Color;
    CanvasDrawText(ACanvas, Rect, TSubtitleRange(Range).Text, False, AlignBottom);
  end;
end;

//------------------------------------------------------------------------------

initialization

  rangeFactory := TSubtitleRangeFactory.Create;

end.