program DelphiVclFixture;

{$APPTYPE GUI}

uses
  Winapi.Windows,
  System.Classes,
  System.IOUtils,
  System.SysUtils,
  System.Types,
  Vcl.ComCtrls,
  Vcl.Controls,
  Vcl.DBGrids,
  Vcl.ExtCtrls,
  Vcl.Forms,
  Vcl.Graphics,
  Vcl.Grids,
  Vcl.StdCtrls,
  Data.DB,
  Datasnap.DBClient,
  MidasLib;

const
  InitialValue = 'initial fixture value';
  FixedValue = 'fixed fixture value';
  IncrementLabel = 'Increment fixture counter';
  EditableControlId = 4101;
  ReadOnlyControlId = 4102;
  PasswordControlId = 4103;

type
  TFixtureCustomControl = class(TCustomControl)
  protected
    procedure Paint; override;
  published
    property OnClick;
  end;

  TFixtureForm = class(TForm)
  private
    FStateDirectory: string;
    FCount: Integer;
    FCounterPanel: TPanel;
    FIncrement: TButton;
    FEditable: TEdit;
    FReadOnly: TEdit;
    FPassword: TEdit;
    FModal: TForm;
    FCloseRequested: Boolean;
    FCommands: TTimer;
    function AddButton(AOwner: TComponent; AParent: TWinControl;
      const AName, ACaption: string; X, Y, AWidth: Integer;
      AHandler: TNotifyEvent): TButton;
    function AddEdit(AParent: TWinControl; const AName, ALabel, AValue: string;
      Y: Integer; IsReadOnly: Boolean; APasswordChar: Char;
      AHandler: TNotifyEvent): TEdit;
    procedure BuildControls(AParent: TWinControl);
    procedure BuildData(AParent: TWinControl);
    function NewIncrement: TButton;
    procedure SetEditControlId(AEdit: TEdit; AId: Integer; const AStateFile: string);
    procedure WriteState(const AName, AValue: string);
    function Consume(const AName: string): Boolean;
    procedure Ready(Sender: TObject);
    procedure ReadCommands(Sender: TObject);
    procedure IncrementClicked(Sender: TObject);
    procedure DisabledClicked(Sender: TObject);
    procedure DuplicateClicked(Sender: TObject);
    procedure EditChanged(Sender: TObject);
    procedure ReadOnlyChanged(Sender: TObject);
    procedure SelectionChanged(Sender: TObject);
    procedure GridCellSelected(Sender: TObject; ACol, ARow: Longint; var CanSelect: Boolean);
    procedure TreeChanged(Sender: TObject; Node: TTreeNode);
    procedure ListChanged(Sender: TObject; Item: TListItem; Selected: Boolean);
    procedure DatabaseScrolled(DataSet: TDataSet);
    procedure OpenModal(Sender: TObject);
    procedure MarkModalOpen(Sender: TObject);
    procedure DrawListItem(Control: TWinControl; Index: Integer;
      Rect: TRect; State: TOwnerDrawState);
  public
    constructor Create(AOwner: TComponent); override;
  end;

procedure TFixtureCustomControl.Paint;
begin
  Canvas.Brush.Color := RGB(228, 238, 249);
  Canvas.FillRect(ClientRect);
  Canvas.Font.Color := RGB(26, 52, 79);
  Canvas.TextOut(8, 8, 'Painted custom area');
end;

constructor TFixtureForm.Create(AOwner: TComponent);
var
  Tabs: TPageControl;
  ControlsTab, DataTab: TTabSheet;
  DisabledButton: TButton;
begin
  inherited CreateNew(AOwner);
  FStateDirectory := ExpandFileName(ParamStr(1));
  if not DirectoryExists(FStateDirectory) and not ForceDirectories(FStateDirectory) then
    raise EInOutError.Create('Cannot create the fixture state directory');

  Caption := ParamStr(2);
  Name := 'FixtureWindow';
  Position := poScreenCenter;
  ClientWidth := 760;
  ClientHeight := 460;
  Constraints.MinWidth := 720;
  Constraints.MinHeight := 420;

  FCounterPanel := TPanel.Create(Self);
  FCounterPanel.Name := 'FixtureCounterPanel';
  FCounterPanel.Parent := Self;
  FCounterPanel.Align := alTop;
  FCounterPanel.BevelOuter := bvNone;
  FCounterPanel.Height := 44;
  FIncrement := NewIncrement;
  DisabledButton := AddButton(Self, FCounterPanel, 'FixtureDisabled', 'Disabled action',
    220, 8, 130, DisabledClicked);
  DisabledButton.Enabled := False;
  AddButton(Self, FCounterPanel, 'FixtureDuplicateOne', 'Duplicate label',
    360, 8, 130, DuplicateClicked);
  AddButton(Self, FCounterPanel, 'FixtureDuplicateTwo', 'Duplicate label',
    500, 8, 130, DuplicateClicked);

  Tabs := TPageControl.Create(Self);
  Tabs.Name := 'FixtureTabs';
  Tabs.Parent := Self;
  Tabs.Align := alClient;
  ControlsTab := TTabSheet.Create(Self);
  ControlsTab.Name := 'FixtureControlsTab';
  ControlsTab.Caption := 'Controls';
  ControlsTab.PageControl := Tabs;
  DataTab := TTabSheet.Create(Self);
  DataTab.Name := 'FixtureDataTab';
  DataTab.Caption := 'Data';
  DataTab.PageControl := Tabs;
  BuildControls(ControlsTab);
  BuildData(DataTab);
  Tabs.ActivePage := ControlsTab;

  FCommands := TTimer.Create(Self);
  FCommands.Enabled := False;
  FCommands.Interval := 50;
  FCommands.OnTimer := ReadCommands;
  OnShow := Ready;
  WriteState('framework.txt', 'Delphi VCL / compiler ' + FloatToStr(CompilerVersion));
  WriteState('count.txt', '0');
  WriteState('value.txt', InitialValue);
  WriteState('read-only.txt', FixedValue);
  WriteState('disabled-click.txt', '0');
end;

function TFixtureForm.AddButton(AOwner: TComponent; AParent: TWinControl;
  const AName, ACaption: string; X, Y, AWidth: Integer;
  AHandler: TNotifyEvent): TButton;
begin
  Result := TButton.Create(AOwner);
  Result.Parent := AParent;
  Result.Name := AName;
  Result.Caption := ACaption;
  Result.SetBounds(X, Y, AWidth, 28);
  Result.OnClick := AHandler;
end;

function TFixtureForm.AddEdit(AParent: TWinControl; const AName, ALabel, AValue: string;
  Y: Integer; IsReadOnly: Boolean; APasswordChar: Char; AHandler: TNotifyEvent): TEdit;
var
  LabelControl: TLabel;
begin
  Result := TEdit.Create(Self);
  Result.Parent := AParent;
  Result.Name := AName;
  Result.SetBounds(142, Y, 205, 25);
  Result.PasswordChar := APasswordChar;
  Result.ReadOnly := IsReadOnly;
  Result.Text := AValue;
  Result.OnChange := AHandler;
  LabelControl := TLabel.Create(Self);
  LabelControl.Parent := AParent;
  LabelControl.SetBounds(12, Y + 4, 115, 20);
  LabelControl.Caption := ALabel;
  LabelControl.FocusControl := Result;
end;

procedure TFixtureForm.BuildControls(AParent: TWinControl);
var
  Combo: TComboBox;
  Check: TCheckBox;
  List: TListBox;
  Custom: TFixtureCustomControl;
  ComboLabel: TLabel;
begin
  FEditable := AddEdit(AParent, 'FixtureEdit', 'Editable text', InitialValue, 12, False, #0, EditChanged);
  FReadOnly := AddEdit(AParent, 'FixtureReadOnly', 'Read-only text', FixedValue, 45, True, #0, ReadOnlyChanged);
  FPassword := AddEdit(AParent, 'FixturePassword', 'Password', 'synthetic', 78, False, '*', nil);

  Combo := TComboBox.Create(Self);
  Combo.Parent := AParent;
  Combo.Name := 'FixtureCombo';
  Combo.Style := csDropDownList;
  Combo.SetBounds(142, 111, 205, 24);
  Combo.Items.Add('Choice one');
  Combo.Items.Add('Choice two');
  Combo.ItemIndex := 0;
  Combo.OnChange := SelectionChanged;
  ComboLabel := TLabel.Create(Self);
  ComboLabel.Parent := AParent;
  ComboLabel.SetBounds(12, 115, 115, 20);
  ComboLabel.Caption := 'Choices';
  ComboLabel.FocusControl := Combo;

  Check := TCheckBox.Create(Self);
  Check.Parent := AParent;
  Check.Name := 'FixtureCheck';
  Check.Caption := 'Fixture check box';
  Check.SetBounds(12, 155, 175, 24);
  Check.OnClick := SelectionChanged;

  List := TListBox.Create(Self);
  List.Parent := AParent;
  List.Name := 'FixtureOwnerDrawList';
  List.Style := lbOwnerDrawFixed;
  List.ItemHeight := 24;
  List.SetBounds(380, 12, 225, 78);
  List.Items.Add('Owner-drawn item one');
  List.Items.Add('Owner-drawn item two');
  List.OnDrawItem := DrawListItem;
  List.OnClick := SelectionChanged;

  Custom := TFixtureCustomControl.Create(Self);
  Custom.Parent := AParent;
  Custom.Name := 'FixtureCustomPainted';
  Custom.SetBounds(380, 105, 225, 34);
  Custom.OnClick := SelectionChanged;
  AddButton(Self, AParent, 'FixtureModal', 'Open fixture modal', 12, 194, 175, OpenModal);
end;

procedure TFixtureForm.BuildData(AParent: TWinControl);
var
  Grid: TStringGrid;
  DBGrid: TDBGrid;
  Data: TClientDataSet;
  Source: TDataSource;
  Tree: TTreeView;
  Group: TTreeNode;
  List: TListView;
  Column: TListColumn;
  Row: TListItem;
begin
  Grid := TStringGrid.Create(Self);
  Grid.Parent := AParent;
  Grid.Name := 'FixtureStringGrid';
  Grid.SetBounds(12, 12, 340, 106);
  Grid.ColCount := 2;
  Grid.RowCount := 3;
  Grid.FixedCols := 0;
  Grid.FixedRows := 1;
  Grid.DefaultColWidth := 145;
  Grid.Options := Grid.Options + [goEditing];
  Grid.Cells[0, 0] := 'Name';
  Grid.Cells[1, 0] := 'Quantity';
  Grid.Cells[0, 1] := 'Alpha';
  Grid.Cells[1, 1] := '10';
  Grid.Cells[0, 2] := 'Beta';
  Grid.Cells[1, 2] := '20';
  Grid.OnSelectCell := GridCellSelected;

  Data := TClientDataSet.Create(Self);
  Data.Name := 'FixtureInventory';
  Data.FieldDefs.Add('Item', ftString, 30);
  Data.FieldDefs.Add('Quantity', ftInteger);
  Data.CreateDataSet;
  Data.AppendRecord(['Crate', 3]);
  Data.AppendRecord(['Pallet', 8]);
  Data.First;
  Source := TDataSource.Create(Self);
  Source.DataSet := Data;
  DBGrid := TDBGrid.Create(Self);
  DBGrid.Parent := AParent;
  DBGrid.Name := 'FixtureDBGrid';
  DBGrid.SetBounds(12, 131, 340, 118);
  DBGrid.DataSource := Source;
  Data.AfterScroll := DatabaseScrolled;

  Tree := TTreeView.Create(Self);
  Tree.Parent := AParent;
  Tree.Name := 'FixtureTree';
  Tree.SetBounds(369, 12, 290, 106);
  Group := Tree.Items.Add(nil, 'Warehouse');
  Tree.Items.AddChild(Group, 'Crate');
  Tree.Items.AddChild(Group, 'Pallet');
  Group.Expand(False);
  Tree.OnChange := TreeChanged;

  List := TListView.Create(Self);
  List.Parent := AParent;
  List.Name := 'FixtureList';
  List.SetBounds(369, 131, 290, 118);
  List.ViewStyle := vsReport;
  List.RowSelect := True;
  Column := List.Columns.Add;
  Column.Caption := 'Shelf';
  Column.Width := 125;
  Column := List.Columns.Add;
  Column.Caption := 'Status';
  Column.Width := 125;
  Row := List.Items.Add;
  Row.Caption := 'Shelf one';
  Row.SubItems.Add('In stock');
  Row := List.Items.Add;
  Row.Caption := 'Shelf two';
  Row.SubItems.Add('Empty');
  List.OnSelectItem := ListChanged;
end;

function TFixtureForm.NewIncrement: TButton;
begin
  Result := AddButton(Self, FCounterPanel, 'FixtureIncrement', IncrementLabel,
    12, 8, 198, IncrementClicked);
end;

procedure TFixtureForm.SetEditControlId(AEdit: TEdit; AId: Integer; const AStateFile: string);
var
  EditHandle: HWND;
  ActualId: Integer;
begin
  EditHandle := AEdit.Handle;
  SetLastError(ERROR_SUCCESS);
  if (SetWindowLongPtr(EditHandle, GWLP_ID, AId) = 0) and (GetLastError <> ERROR_SUCCESS) then
    RaiseLastOSError;
  ActualId := GetDlgCtrlID(EditHandle);
  if ActualId <> AId then
    raise EInvalidOperation.Create('Could not assign the native edit control identifier');
  WriteState(AStateFile, IntToStr(ActualId));
end;

procedure TFixtureForm.WriteState(const AName, AValue: string);
var
  StatePath, Pending: string;
begin
  StatePath := TPath.Combine(FStateDirectory, AName);
  Pending := StatePath + '.pending';
  TFile.WriteAllBytes(Pending, TEncoding.UTF8.GetBytes(AValue));
  if not MoveFileEx(PChar(Pending), PChar(StatePath),
    MOVEFILE_REPLACE_EXISTING or MOVEFILE_WRITE_THROUGH) then
    RaiseLastOSError;
end;

function TFixtureForm.Consume(const AName: string): Boolean;
var
  CommandPath: string;
begin
  CommandPath := TPath.Combine(FStateDirectory, AName);
  Result := FileExists(CommandPath);
  if Result and not Winapi.Windows.DeleteFile(PChar(CommandPath)) then
    RaiseLastOSError;
end;

procedure TFixtureForm.Ready(Sender: TObject);
begin
  SetEditControlId(FEditable, EditableControlId, 'edit-id.txt');
  SetEditControlId(FReadOnly, ReadOnlyControlId, 'read-only-id.txt');
  SetEditControlId(FPassword, PasswordControlId, 'password-id.txt');
  FCommands.Enabled := True;
  WriteState('ready', IntToStr(GetCurrentProcessId));
end;

procedure TFixtureForm.ReadCommands(Sender: TObject);
var
  Retired: TButton;
begin
  if Consume('close-fixture') then
  begin
    FCommands.Enabled := False;
    if Assigned(FModal) then
    begin
      FCloseRequested := True;
      FModal.ModalResult := mrCancel;
    end
    else
      Close;
    Exit;
  end;
  if Consume('close-modal') and Assigned(FModal) then
    FModal.ModalResult := mrCancel;
  if Consume('replace-control') then
  begin
    Retired := FIncrement;
    Retired.Enabled := False;
    Retired.Name := 'FixtureRetired';
    Retired.Hide;
    FIncrement := NewIncrement;
    Retired.Free;
    WriteState('replaced', 'ready');
  end;
end;

procedure TFixtureForm.IncrementClicked(Sender: TObject);
begin
  Inc(FCount);
  WriteState('count.txt', IntToStr(FCount));
end;

procedure TFixtureForm.DisabledClicked(Sender: TObject);
begin
  WriteState('disabled-click.txt', '1');
end;

procedure TFixtureForm.DuplicateClicked(Sender: TObject);
begin
  if TButton(Sender).Name = 'FixtureDuplicateOne' then
    WriteState('selected.txt', 'Duplicate one')
  else
    WriteState('selected.txt', 'Duplicate two');
end;

procedure TFixtureForm.EditChanged(Sender: TObject);
begin
  WriteState('value.txt', TEdit(Sender).Text);
end;

procedure TFixtureForm.ReadOnlyChanged(Sender: TObject);
begin
  WriteState('read-only.txt', TEdit(Sender).Text);
end;

procedure TFixtureForm.SelectionChanged(Sender: TObject);
var
  List: TListBox;
begin
  if Sender is TComboBox then
    WriteState('selected.txt', TComboBox(Sender).Text)
  else if Sender is TCheckBox then
    WriteState('selected.txt', LowerCase(BoolToStr(TCheckBox(Sender).Checked, True)))
  else if Sender is TFixtureCustomControl then
    WriteState('selected.txt', 'Painted custom area')
  else if Sender is TListBox then
  begin
    List := TListBox(Sender);
    if List.ItemIndex >= 0 then
      WriteState('selected.txt', List.Items[List.ItemIndex]);
  end;
end;

procedure TFixtureForm.GridCellSelected(Sender: TObject; ACol, ARow: Longint;
  var CanSelect: Boolean);
begin
  if CanSelect and (ARow > 0) then
    WriteState('selected.txt', TStringGrid(Sender).Cells[ACol, ARow]);
end;

procedure TFixtureForm.TreeChanged(Sender: TObject; Node: TTreeNode);
begin
  if Assigned(Node) then
    WriteState('selected.txt', Node.Text);
end;

procedure TFixtureForm.ListChanged(Sender: TObject; Item: TListItem; Selected: Boolean);
begin
  if Selected then
    WriteState('selected.txt', Item.Caption);
end;

procedure TFixtureForm.DatabaseScrolled(DataSet: TDataSet);
begin
  if DataSet.Active and not DataSet.IsEmpty then
    WriteState('selected.txt', DataSet.FieldByName('Item').AsString);
end;

procedure TFixtureForm.OpenModal(Sender: TObject);
var
  CloseButton: TButton;
begin
  FModal := TForm.CreateNew(Self);
  try
    FModal.Caption := Caption + ' modal';
    FModal.BorderStyle := bsDialog;
    FModal.Position := poMainFormCenter;
    FModal.ClientWidth := 285;
    FModal.ClientHeight := 75;
    CloseButton := AddButton(FModal, FModal, 'FixtureCloseModal', 'Close fixture modal',
      60, 22, 165, nil);
    CloseButton.ModalResult := mrOk;
    CloseButton.Default := True;
    CloseButton.Cancel := True;
    FModal.OnShow := MarkModalOpen;
    FModal.ShowModal;
  finally
    FreeAndNil(FModal);
    WriteState('modal.txt', 'closed');
  end;
  if FCloseRequested then
    Close;
end;

procedure TFixtureForm.MarkModalOpen(Sender: TObject);
begin
  WriteState('modal.txt', 'open');
end;

procedure TFixtureForm.DrawListItem(Control: TWinControl; Index: Integer;
  Rect: TRect; State: TOwnerDrawState);
var
  List: TListBox;
begin
  List := TListBox(Control);
  if odSelected in State then
  begin
    List.Canvas.Brush.Color := clHighlight;
    List.Canvas.Font.Color := clHighlightText;
  end
  else
  begin
    List.Canvas.Brush.Color := List.Color;
    List.Canvas.Font.Color := List.Font.Color;
  end;
  List.Canvas.FillRect(Rect);
  if Index >= 0 then
    List.Canvas.TextOut(Rect.Left + 8, Rect.Top + 4, List.Items[Index]);
end;

var
  Fixture: TFixtureForm;
begin
  if ParamCount <> 2 then
    Halt(2);
  Application.Initialize;
  Application.MainFormOnTaskbar := True;
  Application.CreateForm(TFixtureForm, Fixture);
  Application.Run;
end.
