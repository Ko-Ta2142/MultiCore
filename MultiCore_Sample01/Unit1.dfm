object Form1: TForm1
  Left = 0
  Top = 0
  Caption = 'Form1'
  ClientHeight = 720
  ClientWidth = 1280
  Color = clBtnFace
  Font.Charset = DEFAULT_CHARSET
  Font.Color = clWindowText
  Font.Height = -12
  Font.Name = 'Tahoma'
  Font.Style = []
  Menu = MainMenu1
  OldCreateOrder = False
  OnCreate = FormCreate
  OnDestroy = FormDestroy
  OnResize = FormResize
  PixelsPerInch = 96
  TextHeight = 14
  object MainPaintBox: TPaintBox
    Left = 0
    Top = 0
    Width = 1200
    Height = 720
    Align = alClient
    OnMouseDown = MainPaintBoxMouseDown
    OnMouseMove = MainPaintBoxMouseMove
    OnMouseUp = MainPaintBoxMouseUp
    OnPaint = MainPaintBoxPaint
    ExplicitLeft = 144
    ExplicitTop = 112
    ExplicitWidth = 105
    ExplicitHeight = 105
  end
  object LogMemo: TMemo
    Left = 1200
    Top = 0
    Width = 80
    Height = 720
    Align = alRight
    Lines.Strings = (
      'blur process '
      'time')
    TabOrder = 0
  end
  object MainMenu1: TMainMenu
    Left = 56
    Top = 72
    object EditMenuItem: TMenuItem
      Caption = 'Edit'
      object ClearMenuItem: TMenuItem
        Caption = 'Clear'
        OnClick = ClearMenuItemClick
      end
    end
    object MultiCoreMenuItem: TMenuItem
      Caption = 'MultiCore'
      OnClick = MultiCoreMenuItemClick
      object EnableMenuItem: TMenuItem
        Caption = 'Enable'
        OnClick = EnableMenuItemClick
      end
      object DisableMenuItem: TMenuItem
        Caption = 'Disable'
        OnClick = DisableMenuItemClick
      end
    end
  end
end
