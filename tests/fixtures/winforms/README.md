# WinForms 픽스처

같은 소스(`WinFormsFixture.cs`)를 .NET Framework와 .NET 9로 빌드한다. 저장소 루트의 PowerShell에서 실행한다.

```powershell
& "$env:SystemRoot\Microsoft.NET\Framework64\v4.0.30319\csc.exe" /nologo /target:winexe /out:target\framework-fixtures\winforms-framework.exe /reference:System.Windows.Forms.dll /reference:System.Drawing.dll tests\fixtures\winforms\WinFormsFixture.cs
dotnet build tests/fixtures/winforms/WinFormsFixture.csproj -c Release --no-incremental -o target/framework-fixtures/winforms-modern "-p:BaseIntermediateOutputPath=$PWD/target/framework-fixtures/winforms-modern-obj/"
```

`--no-incremental`이 없으면 `dotnet build`가 성공을 보고하고도 이전 `WinFormsFixture.dll`을 남길 수 있다. 빌드 후 출력 파일의 시각을 확인한다.

```powershell
& target/framework-fixtures/winforms-framework.exe 'target/winforms-state' 'WinForms fixture session'
& target/framework-fixtures/winforms-modern/WinFormsFixture.exe 'target/winforms-state' 'WinForms fixture session'
```

첫 인수는 상태 디렉터리, 둘째 인수는 창 제목이다. 상태 파일은 BOM 없는 UTF-8이며 `.pending` 파일을 쓴 뒤 교체해 원자적으로 바뀐다. 시험기가 파일을 읽는 순간과 겹치면 잠시 뒤 다시 교체한다. `close-fixture` 파일을 만들면 종료한다.

## 실행 모드

모든 픽스처(Win32, MFC, WinForms, WPF `src/test/resources/windows-gui-fixture.ps1`, Swing/AWT)는 환경 변수 `DESKTOP_FIXTURE_MODE`를 시작할 때 한 번 읽는다. [물리 입력 문서](../../../docs/PHYSICAL-INPUT.md#픽스처-실행-모드)의 계약을 따른다.

| 값 | 동작 |
|---|---|
| 없음, `background` | 기존 동작. 활성화를 거부하는 CBT 훅, 활성화 없는 표시, `WS_EX_NOACTIVATE`, 맨 아래 z-순서 유지(WinForms·WPF), 포커스 불가 창(Java) |
| `interactive` | 물리 입력 시험 전용. 훅과 위 장치를 모두 끄고 일반 앱처럼 표시·활성화한다. 모달 대화상자도 활성화되고 포커스를 받는다 |
| 그 밖의 값 | 창을 만들기 전에 종료 코드 2로 끝난다. 대소문자도 구분한다 |

두 모드 모두 전원 스로틀링 해제(Win32, MFC, WinForms, WPF)는 유지한다. 각 픽스처는 `ready`보다 먼저 상태 디렉터리에 `fixture-mode.txt`(`background` 또는 `interactive`)를 쓴다. Delphi VCL 픽스처는 이 변수를 읽지 않는다. 원래 포커스 보호 장치가 없고 이 PC에서 빌드할 수 없다.

## 물리 입력 시험용 상태

기존 상태 파일(`count.txt`, `value.txt`, `selected.txt`, `modal.txt`, `page.txt`, `grid-edit.txt` 등)은 그대로다. 다음이 추가됐다.

| 파일 | 내용 |
|---|---|
| `list.txt` | 목록 `fixtureList`(공통 컨트롤 탭)에서 선택한 항목 텍스트. 시작 값 `Item one` |
| `tab.txt` | 탭 `fixtureTab`에서 선택한 탭 이름(`Common controls`, `Grid and tree`, `Virtual lists`). 시작 값 `Common controls` |
| `grid-cell.txt` | 그리드 `fixtureDataGrid`(Grid and tree 탭)의 현재 셀 `행,열`(0부터). 그리드가 처음 표시될 때 `0,0`이 생긴다 |
| `grid-edits.txt` | 확정된 셀 편집마다 한 줄 `행,열,값`(0부터, 값은 줄 끝까지). 편집 가능한 열은 1(Value)뿐이다 |
| `shortcut.txt` | 주 창 안 어디에 포커스가 있든 받은 Ctrl+Shift+K 횟수. 시작 값 `0` |

## 캔버스

탭 아래에 항상 보이는 직접 그린 컨트롤이 있다. `Name`(UIA AutomationId) `fixtureCanvas`, 접근성 이름 **Fixture canvas**, 역할 Pane이고 접근 가능한 자식이 없다. 논리 크기는 약 734×184이다(125%에서 두 빌드 모두 물리 918×230). 클릭하면 키보드 포커스를 받는다. Tab, Enter, 화살표 키는 포커스를 옮기지 않고 캔버스에 입력된다. Alt 조합은 시스템 동작을 유지한다.

좌표는 클라이언트 크기에 대한 비율(0~1, 소수 셋째 자리, 불변 문화권)이다. 버튼을 누른 채 캔버스 밖에서 떼면 0~1을 벗어날 수 있다. 로그 파일은 이벤트마다 한 줄을 더하고 파일 전체를 원자적으로 다시 쓴다(줄 끝 `\n`).

`{a,b}`는 둘 중 하나의 단어다.

| 파일 | 줄 형식 |
|---|---|
| `canvas-buttons.txt` | `{down,up} {left,right,middle} fx fy` |
| `canvas-clicks.txt` | `{left,right,middle} {single,double} fx fy`. WinForms MouseClick·MouseDoubleClick 기준이라 더블 클릭은 `single` 다음 `double`로 남는다. 드래그도 캔버스 안에서 떼면 `single`을 남긴다 |
| `canvas-drag.txt` | `button fx0 fy0 fx1 fy1`. 처음 누른 버튼을 떼었을 때 4픽셀보다 많이 움직였으면 |
| `canvas-wheel.txt` | `{vertical,horizontal} delta`. 휠 메시지의 원시 값(한 눈금 120, 위·오른쪽이 양수) |
| `canvas-text.txt` | 지금까지 입력한 전체 텍스트(KeyPress 문자). Enter는 `\n`, Tab은 `\t`. Backspace와 Ctrl+문자 같은 다른 제어 문자는 더하지 않는다 |
| `canvas-keys.txt` | `{down,up} KeyCode`. 수정 키 단독은 `ShiftKey`, `ControlKey`, `Menu`. `Enter`, `PageUp`, `PageDown`, `CapsLock`, `HangulMode`, `HanjaMode`는 이 이름으로 고정한다. `KEYEVENTF_UNICODE` 입력은 `Packet`으로 남는다 |
