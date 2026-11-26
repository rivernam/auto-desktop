# 물리 입력 (SendInput)

접근성 API(UIA·JAB·MSAA)가 조작하지 못하는 컨트롤을 실제 마우스·키보드 입력으로 조작한다. Java/JNA Agent와 C++ Agent가 같은 NDJSON 계약을 따른다. 물리 입력은 기존 접근성 동작과 분리된 명령 영역이다. 접근성 동작이 실패해도 Agent가 물리 입력으로 자동 전환하거나 재시도하지 않는다. 호출자가 물리 입력 연산을 명시적으로 보낼 때만 입력이 발생한다.

이 문서는 계약과 검증 규칙을 정한다. 시험 방법과 결과는 [Interactive 시험](#interactive-시험)과 [시험 기록](TEST-RESULTS.md)에 있다.

## 허용과 capability

물리 입력은 시작 옵션으로 켠다. 기존 `--allow-pid`와 함께 다음 액션을 허용한다. 허용하지 않은 세션은 이전과 같다(`physicalInput: false`, 입력 연산 없음).

| 액션 | 연산 |
|---|---|
| `pointer` | `pointerMove`, `pointerClick`, `pointerDrag`, `pointerScroll`, `clickElement` |
| `keyboard` | `keyPress`, `keyDown`, `keyUp`, `typeText` |
| `activate` | `activateWindow` |

```powershell
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --backend multi --allow-pid 1234 --allow-action pointer --allow-action keyboard --allow-action activate
./target/cpp-agent/Release/cpp-agent.exe --backend multi --allow-pid 1234 --allow-action pointer --allow-action keyboard --allow-action activate
```

입력 액션을 하나라도 허용한 세션의 `getCapabilities`는 `physicalInput`이 입력 장치 사용 가능 여부이고 `input` 객체를 더한다. 허용된 입력 연산은 `operations`에도 추가된다. multi 세션에서는 최상위 결과에 붙는다.

```json
"input": {"available": true, "allowedActions": ["keyboard","pointer"], "dpiAwareness": "perMonitorV2",
          "integrity": "medium", "inputDesktop": true, "virtualScreen": {"x":-1920,"y":0,"width":3840,"height":1080},
          "monitors": 2, "buttonsSwapped": false}
```

`available`이 false이면 `reason`이 붙는다. 이 값은 요청 시점의 정보다. 각 입력 요청은 실행 직전에 모든 조건을 다시 검사한다.

## 연산

모든 입력 요청은 `id`가 필요하며 기존 변경 연산과 같은 명령 ID 기록을 공유한다. `clickElement`를 제외한 연산은 대상 창을 `windowId`(`listWindows`의 값)와 `processId`로 지정한다. 대상은 최상위 창이어야 한다. 소유 창(모달 대화상자, 팝업)도 자체 `windowId`로 지정한다.

| op | 필드 | 동작 |
|---|---|---|
| activateWindow | windowId, processId | `SetForegroundWindow` 한 번. 전경이 되지 않으면 `FOREGROUND_MISMATCH`. 재시도·우회 기법(Alt 입력, 스레드 입력 연결)은 쓰지 않는다. 최소화된 창은 복원하지 않고 `PRECONDITION_FAILED` |
| pointerMove | windowId, processId, point | 커서 이동 |
| pointerClick | windowId, processId, point, button?, clicks? | 이동 후 클릭. `button`: `left`(기본)·`right`·`middle`. `clicks`: 1(기본) 또는 2(더블 클릭) |
| pointerDrag | windowId, processId, from, to, button?, steps?, stepDelayMs? | from에서 누르고 `steps`(1~100, 기본 10)번에 나눠 이동한 뒤 to에서 뗀다. 단계 사이 `stepDelayMs`(0~100, 기본 10) |
| pointerScroll | windowId, processId, point, delta, axis? | `delta`: 휠 눈금 수(-20~20, 0 제외, 양수는 위·오른쪽). `axis`: `vertical`(기본)·`horizontal` |
| keyPress | windowId, processId, keys | 단축키 한 번. `"Ctrl+Shift+K"`처럼 수정 키와 키 하나를 `+`로 잇는다. 수정 키를 순서대로 누르고 역순으로 뗀다. 키 하나만 써도 된다. 세션이 `keyDown`으로 누르고 있는 수정 키는 다시 누르거나 떼지 않는다. 조합의 마지막 키를 세션이 누르고 있으면 `PRECONDITION_FAILED` |
| keyDown | windowId, processId, key | 키 하나를 누른 채 둔다. 세션이 누른 키는 `keyUp`, 입력 실패, 세션 종료 중 먼저 오는 때에 뗀다. 동시에 최대 8개 |
| keyUp | windowId, processId, key | 이 세션이 `keyDown`으로 누른 키만 뗀다. 아니면 `PRECONDITION_FAILED` |
| typeText | windowId, processId, text, intervalMs? | 유니코드 문자열 입력(`KEYEVENTF_UNICODE`, 1~1,024 UTF-16 단위). `\r\n`·`\n`은 Enter, `\t`는 Tab 키다. 그 밖의 제어 문자는 거부한다. 16단위씩 보내며 묶음 사이에 전경·사용자 입력을 다시 확인한다. `intervalMs`(0~50, 기본 0)는 묶음 사이 대기 |
| clickElement | ref, button?, clicks?, position?, acceptWeakReference? | 스냅샷 요소의 현재 bounds 안을 클릭한다. `position`은 bounds 안의 비율 `{"x":0~1,"y":0~1}`(기본 중앙) |

공통 선택 필드 `quietMs`(0~10,000, 기본 500)는 요청 직전 이 시간 안에 외부 입력이 있었으면 거부한다.

### 좌표

`point`, `from`, `to`는 `{"x": 정수, "y": 정수, "space": "screen"|"window"|"client"}`이다. `space`는 필수다.

- `screen`: 가상 화면의 물리 픽셀. 주 모니터 왼쪽·위에 있는 모니터는 음수 좌표다.
- `window`: 대상 창의 `GetWindowRect` 왼쪽 위 기준 물리 픽셀.
- `client`: 대상 창 클라이언트 영역 원점(`ClientToScreen`) 기준 물리 픽셀.

Agent의 입력 스레드는 Per-Monitor v2 DPI 인식으로 동작한다(Windows 10 1607 이상은 스레드 단위 설정, 그 이전은 프로세스 DPI 인식 확인). DPI 비인식으로 남으면 Java는 항상 `INPUT_UNAVAILABLE`이고, C++은 배율이 없는 화면에서만 허용한다. 따라서 모든 좌표는 배율 적용 후 물리 픽셀이다. 절대 이동은 가상 데스크톱 정규화 좌표(`MOUSEEVENTF_ABSOLUTE | MOUSEEVENTF_VIRTUALDESK`)로 보내 다중 모니터와 음수 좌표를 처리한다. 정규화 값은 `ceil((p - origin) × 65536 / size)`다. 이동 후 `GetCursorPos`로 실제 커서 위치를 확인하고 다르면 버튼을 누르지 않는다. 주 버튼이 바뀐 환경(`SM_SWAPBUTTON`)에서는 논리 버튼 기준으로 보낸다. 해석한 점은 대상 창의 `GetWindowRect` 안에 있어야 한다.

### clickElement와 bounds

`clickElement`는 참조를 발급한 백엔드에서 요소와 스냅샷 루트(창)의 현재 정보를 다시 읽는다. 요소가 활성이고 `offscreen`이 아니며 너비·높이가 양수여야 한다. 대상 창은 스냅샷의 `windowId`이고 창 소유 PID가 요소의 PID와 같아야 한다.

백엔드가 보고한 좌표계는 창의 실제 `GetWindowRect`와 스냅샷 루트 bounds를 비교해 정한다.

- 실제 크기와 백엔드 루트 크기의 차이가 각 축에서 루트 크기의 1% 이내이고 원점 차이가 2픽셀 이내면 `boundsMapping: "physical"`로 그대로 쓴다(UIA, MSAA, DPI 인식 Java 앱의 JAB).
- MSAA 루트가 클라이언트 영역을 보고하는 경우 실제 클라이언트 영역의 화면 좌표와 같은 기준으로 비교한다. 일치하면 요소 좌표는 그대로 쓴다.
- 가로·세로 비율이 서로 2% 안에서 같고 0.5~4 범위면 `boundsMapping: "scaled"`로 창 원점 기준으로 환산한다. HiDPI Java 앱의 JAB 좌표가 이 경우다.
- 그 밖이면 `BOUNDS_UNVERIFIED`다. `scopeRef`로 받은 부분 스냅샷은 루트가 창이 아니므로 UIA·MSAA는 물리 좌표로 간주하고(`boundsMapping: "assumedPhysical"`) JAB는 `BOUNDS_UNVERIFIED`로 거부한다.

MSAA `weak` 참조는 위치로 다시 찾은 객체가 같은 요소라는 보장이 없다. 기본은 `PRECONDITION_FAILED`로 거부한다. `acceptWeakReference: true`를 주면 현재 이름·역할·식별자·bounds가 스냅샷과 모두 같을 때만 클릭하고, 다르면 `STALE_REFERENCE`다. 응답의 `referenceStrength: "weak"`는 동일성을 확인하지 못했다는 표시다.

## 입력 전 검증

Agent는 입력을 보내기 전에 아래를 차례로 확인한다. 하나라도 실패하면 아무 입력도 보내지 않는다(`inputSent: false`).

| 순서 | 검사 | 실패 코드 |
|---|---|---|
| 1 | 액션 허용, PID 허용과 프로세스 시작 시각 일치 | `PERMISSION_DENIED` |
| 2 | HWND가 존재하고 그 소유 PID가 요청의 `processId`와 같음(창 교체 감지) | `WINDOW_NOT_FOUND` |
| 3 | 최상위 창이며 보이고 최소화되지 않음 | `PRECONDITION_FAILED` |
| 4 | 입력 데스크톱이 Agent의 데스크톱과 같음(잠금 화면, UAC 보안 데스크톱, 연결 끊긴 세션 감지) | `INPUT_DESKTOP_UNAVAILABLE` |
| 5 | 대상 프로세스의 무결성 수준이 Agent 이하. 읽을 수 없으면 높은 것으로 본다(UIPI는 차단을 알리지 않으므로 사전 거부) | `INTEGRITY_MISMATCH` |
| 6 | 입력 스레드의 DPI 인식이 물리 좌표를 보장 | `INPUT_UNAVAILABLE` |
| 7 | 전경 창이 대상 창이거나 같은 프로세스의 소유 창(팝업, 드롭다운). 키보드는 포커스 창(`GetGUIThreadInfo`)도 대상 프로세스 | `FOREGROUND_MISMATCH` |
| 8 | 사용자가 누르고 있는 마우스 버튼·수정 키가 없고(세션이 `keyDown`으로 누른 키 제외), `quietMs` 안에 외부 입력이 없음 | `USER_INPUT_CONFLICT` |
| 9 | 좌표가 창 안이며 `WindowFromPoint`의 최상위 창이 대상 창 또는 같은 프로세스의 소유 창 | `PRECONDITION_FAILED`, `WINDOW_OBSCURED` |

명령 ID는 요청 형식과 1번을 통과해 입력 장치에 넘길 때 기록한다. 2번 이후의 거부도 같은 ID를 소비한다. 전송 직전에 1번, 2번과 기한을 다시 확인한다.

## 전송 중 감시와 해제

입력을 허용한 세션은 첫 입력 전송 직전에 저수준 마우스·키보드 훅(`WH_MOUSE_LL`, `WH_KEYBOARD_LL`)을 전용 스레드에 설치한다. 검증 단계에서 거부된 요청은 훅을 설치하지 않는다. Agent가 보내는 이벤트에는 세션마다 무작위로 정한 `dwExtraInfo` 값을 붙인다. 훅은 이 표시가 없는 이벤트를 외부 입력으로 기록한다. 다른 프로그램이 주입한 입력도 외부 입력이다. 훅 설치 전에는 `GetLastInputInfo`로 `quietMs`를 확인한다.

- 전송 중 외부 입력이 관찰되면 남은 입력을 보내지 않고 `USER_INPUT_CONFLICT`로 끝낸다.
- 드래그는 버튼을 누르기 전과 단계마다 hit-test와 커서 도달을 확인하고, 떼기 전에 끝점을 다시 hit-test한다. 외부 입력은 묶음마다 확인한다. 클릭은 버튼을 누르기 직전에 다시 hit-test한다.
- 입력 장치가 요청을 받은 뒤의 모든 실패(2번 이후의 거부 포함), 예외, 기한 초과, 세션 종료 때 이 연산이 누른 버튼과 키, 세션이 `keyDown`으로 누른 키를 모두 뗀다. 해제 이벤트가 모두 받아들여지면 오류 응답에 `released: true`가 붙는다. 1번 이전의 거부(형식 오류, 허용되지 않은 PID·액션, 중복 ID)는 해제하지 않는다.
- 보낸 이벤트가 모두 훅을 지나간 것을 확인하면 `inputObserved: true`다. 500ms 안에 확인하지 못하면 false이며 다음 요청에서 훅을 다시 설치한다.
- `SendInput`이 첫 묶음에서 0을 반환하면 `INPUT_BLOCKED`(입력 없음), 일부를 보낸 뒤 실패하면 `ACTION_OUTCOME_UNKNOWN`이다.
- 입력은 요청 기한(10초) 안에 끝나야 한다. 전송 전에 기한이 지나면 `TIMEOUT`, 전송 시작 후에는 `ACTION_OUTCOME_UNKNOWN`이다.

키 이름은 대소문자를 구분하지 않는다. `A`~`Z`, `0`~`9`, `F1`~`F24`, `Enter`, `Tab`, `Escape`(`Esc`), `Space`, `Backspace`, `Delete`(`Del`), `Insert`, `Home`, `End`, `PageUp`, `PageDown`, `Left`, `Right`, `Up`, `Down`, `Apps`, `NumPad0`~`NumPad9`, `Multiply`, `Add`, `Subtract`, `Decimal`, `Divide`, 수정 키 `Shift`, `Ctrl`(`Control`), `Alt`. Windows 키, 잠금 키(CapsLock 등), PrintScreen, 창 전환 조합(`Alt+Tab`, `Alt+Esc`, `Ctrl+Esc`, `Ctrl+Shift+Esc`)은 대상 창이 아니라 셸로 가므로 `INVALID_REQUEST`다. 세션이 `keyDown`으로 누르고 있는 Alt·Ctrl도 조합에 포함해 판정한다(Alt를 누른 채 `typeText`의 Tab도 거부). 키 이름 앞뒤의 공백은 허용하지 않는다.

## 응답

성공 응답은 입력이 전달됐다는 뜻이며 앱의 반응은 확인하지 않는다.

```json
{"id":"c1","ok":true,"result":{"performed":true,"inputSent":true,"inputObserved":true,"effectVerified":false,
 "events":4,"point":{"x":812,"y":440}}}
```

`clickElement`는 `backend`, `boundsMapping`, 해당하면 `referenceStrength`를 더한다. 입력 연산의 오류 객체에는 `inputSent`(입력을 일부라도 보냈는지)가 항상 있고, 해제를 수행했으면 `released`가 있다. `inputSent: true`인 오류는 `ACTION_OUTCOME_UNKNOWN`처럼 다룬다. 앱 상태를 확인하기 전에는 같은 조작을 다시 보내지 않는다.

```json
{"id":"t2","ok":false,"error":{"code":"USER_INPUT_CONFLICT","message":"...","inputSent":true,"released":true}}
```

| code | 호출자의 처리 |
|---|---|
| INPUT_UNAVAILABLE | 입력 장치나 DPI 인식을 쓸 수 없다. `getCapabilities.input.reason` 확인 |
| INPUT_DESKTOP_UNAVAILABLE | 화면 잠금·UAC·세션 연결 상태 확인 |
| INTEGRITY_MISMATCH | Agent와 대상 앱을 같은 권한 수준으로 실행 |
| FOREGROUND_MISMATCH | 대상 창을 전경으로 가져온 뒤(사용자 또는 `activateWindow`) 새 요청 |
| WINDOW_OBSCURED | 좌표를 가리는 창 확인 |
| USER_INPUT_CONFLICT | 사용자가 PC를 쓰는 중. 자동화를 멈추고 앱 상태 확인 |
| BOUNDS_UNVERIFIED | 창 전체 스냅샷을 다시 받거나 좌표 연산 사용 |
| INPUT_BLOCKED | 시스템이 입력을 받지 않았다. 권한·데스크톱 확인 |

## 픽스처 실행 모드

시험 픽스처(Win32, MFC, WinForms, WPF, Swing/AWT)는 환경 변수 `DESKTOP_FIXTURE_MODE`로 모드를 정한다.

- `background`(기본, 변수 없음): 기존처럼 포커스를 가져가지 않고 사용자 창 뒤에 머문다. 접근성 API 시험은 이 모드로 실행한다.
- `interactive`: 포커스와 전경 배치를 허용한다. 물리 입력 시험에서만 쓴다. 시험 실행기가 `-Interactive` 스위치를 받은 경우에만 설정한다.
- 다른 값이면 픽스처는 시작하지 않고 종료 코드 2로 끝난다.

픽스처는 상태 디렉터리에 `fixture-mode.txt`(`background` 또는 `interactive`)를 남긴다.

## Interactive 시험

`tools/Test-PhysicalInput.ps1`이 Java와 C++ Agent를 차례로 실제 입력으로 시험한다. 성공 여부는 Agent 응답이 아니라 픽스처의 상태 파일로 판정하고 결과를 JSON 하나에 저장한다.

### 실행 전 확인

- 시험하는 동안 PC를 쓰지 않는다. 시험이 마우스를 움직이고, 클릭하고, 입력하고, 시험 창을 앞으로 가져온다.
- 잠금 화면이나 화면 보호기가 켜지면 `INPUT_DESKTOP_UNAVAILABLE`로 막힌다. 절전·화면 잠금 시간을 시험보다 길게 둔다.
- 다른 자동화 도구, 원격 제어, 마우스 흔들기 프로그램을 끈다. 태그가 없는 입력은 모두 사용자 입력으로 판정된다.
- 실행기는 시작 전에 경고를 띄우고, 키보드·마우스 입력이 `-CountdownSeconds`(기본 30초) 동안 없을 때 시작한다. 최대 `-IdleWaitMinutes`(기본 15분) 기다린다. 케이스마다 2초 이상 입력이 없는지 다시 확인한다. 예상하지 않은 `USER_INPUT_CONFLICT`가 나오면 나머지를 실행하지 않고 `NOT_RUN`으로 남긴다. Ctrl+C로 언제든 멈출 수 있다.

### 명령

저장소 루트의 Windows PowerShell 5.1에서 빌드 후 실행한다. `$jdk11`은 Java Agent를 실행할 JDK 11의 `java.exe`, `$jdk17`은 Swing/AWT 픽스처를 실행할 JDK 17의 `java.exe`다(픽스처 클래스는 JDK 17로 빌드한다).

```powershell
$jdk11 = 'C:\path\to\jdk-11\bin\java.exe'
$jdk17 = 'C:\Program Files\Java\jdk-17\bin\java.exe'
& .\tools\Test-PhysicalInput.ps1 -Interactive -JavaExe $jdk11 -FixtureJava $jdk17 -OutputPath target\physical-input.json
```

| 옵션 | 뜻 |
|---|---|
| `-Agent Java\|Cpp\|Both` | 시험할 Agent. 기본 `Both`(Java 다음 C++) |
| `-Case A,B` | 일부 케이스만 실행. `AwtUnicodePackets`는 명시적으로 선택해 AWT의 물리 유니코드 입력 호환성을 확인 |
| `-IncludeElevated` | `PermissionMismatch`를 실행한다. 관리자 권한 픽스처를 UAC로 띄우므로 사람이 승인해야 한다. 없으면 `NOT_RUN` |
| `-PerformanceIterations N` | 성능 측정 반복 수(기본 60) |
| `-Interactive` 없이 | 입력과 창 없이 모든 케이스를 `NOT_RUN`으로 기록한 계획 파일만 만든다 |

예상 소요 시간은 시작 대기 30초를 포함해 약 10분이다(케이스당 5~20초 × 15개 × Agent 2개, 성능 측정 Agent당 약 30초). PC가 느리면 15분까지 걸릴 수 있다. `-IncludeElevated`는 UAC 승인을 기다리므로 무인 실행에 넣지 않는다.

### 케이스

| 케이스 | 확인하는 것 |
|---|---|
| AwtButtonClick | AWT 버튼의 UIA invoke는 응답만 받고 카운터가 그대로인 기존 실패를 기록한 뒤, 같은 UIA 요소의 bounds 클릭으로 카운터가 정확히 1 증가 |
| AwtTextInput | AWT TextField의 UIA bounds를 물리 클릭해 포커스를 확인하고, End·Backspace로 마지막 문자를 지운다. UIA `setValue`로 한글이 섞인 전체 문자열을 설정한다. 두 단계의 결과는 각각 `value.txt`로 확인한다. |
| SwingModal | Swing 동기 모달을 JAB bounds 클릭으로 열고(JAB invoke는 약 8초 대기), 모달 안의 닫기 버튼 클릭으로 닫음 |
| WinFormsListBox | UIA 또는 MSAA ListItem 클릭으로 선택. MSAA weak 참조는 동의 없이 거부되고 `acceptWeakReference`로 선택 |
| WinFormsTab | UIA 또는 MSAA TabItem 클릭으로 세 페이지 전환 |
| DataGridView | UIA에 행·셀이 없는 그리드를 클릭한 뒤 Ctrl+Home, Down, Right로 셀 선택, F2·입력·Enter로 편집 확정 |
| CanvasMouse | 접근성 자식이 없는 직접 그린 캔버스에 클릭, 더블 클릭, 오른쪽·가운데 클릭, 드래그, 세로·가로 휠. 화면·창·클라이언트 좌표를 모두 사용 |
| CanvasKeyboard | 한글·이모지(서로게이트 쌍)·Tab·Enter 입력, Ctrl+Shift+K, keyDown/keyUp, 거부(보유하지 않은 키의 keyUp, Alt+Tab, Win+R) |
| MultiMonitor | 다른 모니터마다 창을 옮겨 클릭(음수 좌표 포함). 모니터가 하나면 `NOT_RUN` |
| FocusChange | 다른 창이 전경일 때 키보드·포인터 입력이 입력 없이 `FOREGROUND_MISMATCH`. `activateWindow` 결과는 기록만 한다 |
| WindowObscured | 포커스를 가져가지 않는 최상위 창이 캔버스 일부를 가리면 그 점의 클릭은 `WINDOW_OBSCURED`, 가리지 않은 점은 클릭 |
| TargetReplaced | 다른 프로세스 창을 옛 PID로 지정하면 `WINDOW_NOT_FOUND`. 대상이 종료·재시작되면 옛 창·새 창·옛 참조가 입력 없이 거부 |
| PermissionMismatch | 관리자 권한 대상은 `INTEGRITY_MISMATCH` (`-IncludeElevated`) |
| UserInputConflict | 입력 도중과 직전에 실행기가 태그 없는 마우스 이동을 넣으면 `USER_INPUT_CONFLICT`. 도중이면 `inputSent: true`이고 문자열이 중간에서 끊김 |
| ReleaseOnFailure | Shift를 누른 채 드래그하다 외부 입력으로 중단되면 버튼과 Shift가 모두 떨어지고(`released: true`), 세션 종료 시 누르고 있던 Ctrl도 떨어짐 |
| Performance | `pointerMove`, `pointerClick`, `clickElement`, `keyPress`, `typeText`(32자)의 요청 지연 p50·p95·최대와 캔버스가 기록한 클릭·문자 수 |

케이스가 끝날 때마다 마우스 버튼과 Shift·Ctrl·Alt가 눌려 있지 않은지 확인하고, 눌려 있으면 그 케이스를 실패로 기록한다.

### 결과 확인

콘솔에 케이스마다 한 줄이 나오고 마지막에 개수가 나온다. FAIL이 있으면 종료 코드가 1이다. JSON은 다음과 같이 본다.

```powershell
$r = Get-Content target\physical-input.json -Raw -Encoding UTF8 | ConvertFrom-Json
$r.summary
$r.cases | Format-Table agent, case, status, reason -AutoSize
$r.parity | Format-Table
$r.cases | Where-Object case -eq 'Performance' | ForEach-Object { $_.agent; $_.evidence.latencyMs | Format-List }
```

| 상태 | 뜻 |
|---|---|
| PASS | 앱 상태가 기대대로 바뀌었고 아무 키·버튼도 눌린 채 남지 않았다 |
| FAIL | 기대와 다른 응답 코드, 앱 상태, 남은 키·버튼. `reason`과 `steps`(요청별 코드, `inputSent`, `inputObserved`, `boundsMapping`)를 본다 |
| BLOCKED | 환경 때문에 시험할 수 없었다. 예: Windows가 전경 전환을 거부, 픽스처가 뜨지 않음, JAB 요소 없음 |
| NOT_RUN | 실행하지 않았다. 계획 모드, 모니터 하나, `-IncludeElevated` 없음, 사용자 입력으로 중단 |

`parity`는 두 Agent가 모두 실행한 케이스마다 상태와 응답 코드 순서가 같은지 보인다. `environment`에는 OS, 모니터, 보고서 생성 시 유휴 시간, 소스 커밋, 실행기·JAR·C++·픽스처 해시, Agent 및 픽스처의 Java 버전이 있다. CanvasMouse는 픽스처 창의 DPI와 포인터 이동의 예상·실측 좌표를 함께 기록한다. [최종 검증과 원본](TEST-RESULTS.md#2026-11-26-물리-입력-최종-검증)

## 지원 범위

| 항목 | 상태 |
|---|---|
| 요청 형식, 키 이름, 정규화, bounds 대응, 정책, 명령 ID, 오류 필드 | Java 단위 테스트와 C++ CTest로 확인 |
| capability, 거부 경로(창 없음, PID 불일치, 정책, 중복 ID, 셸 단축키), DPI·무결성·입력 데스크톱 조회 | Windows 11 x64에서 Java 11과 C++ x64로 확인했다. C++ x86의 상태 조회는 WOW64에서 확인했다. |
| 실제 SendInput 전송, 훅 감시, 커서 도달, 해제, `activateWindow` | Windows 11 x64 전체 기준선에서 Java·C++ 각각 14 PASS·2 NOT_RUN, 최종 좌표 중심 회귀 각각 6 PASS. C++ x86 WOW64 핵심 입력은 5 PASS. 전경 전환 요청의 결과는 기록만 하고 합격 조건으로 삼지 않는다. |
| 다중 모니터·음수 좌표·모니터별 배율 | 정규화 계산은 단위 시험. 실제 다중 모니터는 미실행 |
| Windows 7, Windows 10, 네이티브 x86 OS, Java x86, RDP | 실기기 미실행. Windows 7에서 없는 API는 실행 중에 찾도록 작성했다. |

## 미해결 문제와 제약

- **AWT 텍스트 입력.** Java 11·21 AWT 픽스처의 편집 필드는 일반 `keyPress` 입력에 반응했지만 `typeText`의 유니코드 이벤트를 픽스처 값에 반영하지 않았다. 두 Agent에서 포커스와 훅 관측을 확인했다. 이 경로는 `-Case AwtUnicodePackets`로 별도 검증할 수 있다. AWT 편집 필드의 Unicode 값 변경에는 UIA 참조로 `setValue`를 호출한다. 호출자는 `setValue` 권한을 부여하고 변경 뒤 앱 상태를 확인한다.
- **전경 전환.** `activateWindow`는 `SetForegroundWindow`를 한 번만 부른다. Windows의 전경 잠금 규칙 때문에 거부될 수 있고, 우회 기법은 쓰지 않는다. 그때는 사용자가 창을 앞으로 가져와야 한다.
- **외부 입력의 범위.** 세션 태그가 없는 입력은 모두 사용자 입력으로 본다. 다른 자동화 도구, 원격 제어, 펜·터치 드라이버의 합성 입력도 `USER_INPUT_CONFLICT`를 일으킨다.
- **훅이 사라지는 경우.** Windows는 응답이 늦은 저수준 훅을 알리지 않고 제거한다. 전송한 이벤트를 일부라도 놓치면 `inputObserved`는 false다. 관측이 0건이면 다음 요청에서 훅 재설치를 시도한다. 일부 관측 뒤의 훅 손실과 재설치 전 외부 입력 감지는 보장되지 않는다. [Windows 저수준 훅](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc)
- **비정상 종료.** Agent가 강제 종료되거나 충돌하면 `keyDown`으로 누른 키가 눌린 채 남을 수 있다. 정상 종료(표준 입력 닫기)에서는 뗀다.
- **입력 전송과 조작 성공.** 응답의 `performed`·`inputSent`는 입력이 시스템에 들어갔다는 뜻이고 `effectVerified`는 항상 false다. 앱 상태는 호출자가 확인한다.
- **MSAA weak 참조.** `acceptWeakReference`는 이름·역할·식별자·bounds가 같은지만 비교한다. 같은 속성을 가진 다른 객체는 구별하지 못한다.
- **JAB 좌표.** 창 하나 안에서 배율이 균일하다고 가정한다. 모니터마다 배율이 다른 환경의 HiDPI Java 앱과 부분 스냅샷의 JAB 요소는 시험하지 않았거나 거부한다.
- **UIPI.** 무결성 수준만 비교한다. UIAccess 권한을 가진 Agent는 고려하지 않는다.
- **픽스처.** Background 모드에서 WinForms·AWT·MSAA 픽스처 창이 표시 직후 20~30 ms 동안 사용자 창 위에 그려지는 경우가 있다(포커스는 가져가지 않음). 이번 변경 전 빌드에서도 같았다. Win32·MFC 모달 대화상자는 Background 모드에서도 위에 그려진다. Delphi VCL 픽스처에는 모드 구분이 없다.
