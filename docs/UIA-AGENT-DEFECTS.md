# UIA Agent 결함 분석과 개선

[UI 프레임워크 호환성 검증](UI-FRAMEWORK-COMPATIBILITY.md)에서 남은 세 가지 문제의 원인을 실제 GUI에서 규명하고, Java/JNA와 C++ Native Agent를 같은 방식으로 고쳤다. 새 UI 프레임워크나 어댑터는 추가하지 않았다. 기준 커밋은 `main`의 `8823168`이다.

## 요약

| 문제 | 원인 | 구분 | 결과 |
|---|---|---|---|
| 소유 모달·팝업이 `listWindows`에 없음 | UI Automation은 소유 창을 Raw View에서도 소유자 창 아래에 둔다. Agent는 데스크톱의 직계 자식만 열거하고 스냅샷 대상으로 인정했다. | Agent 결함 | 해결. Win32, WPF, WinForms(.NET Framework 4.8, .NET 9)의 모달과 WPF 팝업을 두 Agent에서 열거·스냅샷·조작했다. |
| .NET Framework WinForms의 부분 스냅샷 | 공급자가 탭·목록 항목·그리드 행과 셀에 빈 Runtime ID를 반환한다. Agent는 어디가 잘렸는지 알리지 않았고, 온전한 가지의 검색도 전부 거부했다. | 빈 Runtime ID는 Provider 제약, 잘린 위치를 알리지 않은 것은 Agent 결함 | Agent 쪽 해결. 잘린 요소를 `partial`로 표시하고 온전한 범위의 검색을 허용한다. 식별할 수 없는 요소 자체는 미해결. |
| AWT 버튼 Invoke가 반환돼도 카운터가 그대로 | `java.awt.Button`의 네이티브 피어가 `BM_CLICK`과 MSAA 기본 동작을 처리하지 않는다. Agent 없이 보낸 같은 호출도 효과가 없다. | Provider 제약. 응답이 성공으로 읽히던 점은 Agent 결함 | 응답에 `effectVerified:false`를 넣고 판정을 앱 상태로만 한다. 버튼 조작 자체는 미해결. |

검증 중에 두 가지를 더 고쳤다. C++ Agent가 DPI를 선언하지 않아 배율 125% 화면에서 `bounds`가 Java/JNA의 1/1.25였다. Windows PowerShell 5.1에서 시험 실행기가 C++ 빌드 정보를 저장하다 끝나지 않았다.

기능 시험은 두 Agent 합계 256개 체크 중 214개 통과, 32개 실패, 10개 미실행이다. 실패 32개는 모두 원인이 분류됐고 Agent 결함이나 미분류는 없다. 두 Agent의 체크별 판정과 여섯 프레임워크의 트리는 일치했다. [기능 원본](test-results/2026-11-24-uia-defects-functional.json) · [원인 실험 기록](test-results/2026-11-24-uia-defects-investigation.json)

## 1. 소유 모달과 팝업

### 원인

Win32 `EnumWindows`·`GetWindow(GW_OWNER)`와 관리형 UI Automation 클라이언트로 같은 창을 조회했다. 두 Agent와 무관한 [진단 스크립트](../tools/Probe-UiaWindows.ps1)다.

| 창 | Win32 소유자 | 데스크톱 직계 (Control / Raw) | UIA 부모 경로 (Control, Raw 동일) |
|---|---|---|---|
| Win32 `DialogBoxParam` 대화상자 (`#32770`) | 주 창 | 아니오 / 아니오 | 소유자 → 데스크톱 |
| WPF `Window.Owner` + `ShowDialog` | 주 창 | 아니오 / 아니오 | 소유자 → 데스크톱 |
| WPF `Popup` | 주 창 | 아니오 / 아니오 | 소유자 → 데스크톱 |
| WinForms `ShowDialog(owner)`, .NET Framework 4.8과 .NET 9 | 주 창 | 아니오 / 아니오 | 소유자 → 데스크톱 |

소유 창은 Win32에서는 최상위 창이지만 UI Automation 트리에서는 소유자의 자식이다. Raw View에서도 같으므로 Control View의 필터가 원인이 아니다. 기존 `listWindows`는 데스크톱의 직계 자식만 순회했고, `snapshot`은 부모가 데스크톱인 창만 `windowId`로 받았다. 모달의 내용은 소유자 창의 스냅샷 안에 하위 Window로 이미 들어 있었다. 빠져 있던 것은 창 목록의 행과 모달을 루트로 하는 스냅샷이다.

### 조치

- `listWindows`는 기존 순회 결과 뒤에 소유 창을 덧붙인다. 대상은 `EnumWindows`로 얻은 창 중 보이고, Win32 부모가 데스크톱이고, 소유자가 있는 창이다. UIA 요소의 HWND가 같고 Control View 부모의 HWND가 Win32 소유자와 같은 경우에만 행을 만든다. 그 행에만 `ownerWindowId`가 있다.
- `snapshot`의 창 검증은 같은 조건을 만족하는 소유 창도 받는다. 그 밖의 자식 HWND는 계속 `WINDOW_NOT_FOUND`다.
- 기존 행의 순서와 내용, 이름 마스킹, 4,096개 방문 한도는 그대로다. 요소의 PID, 프로세스 시작 시각, Runtime ID, 조상 경로 검증과 PID·액션 허용 정책도 바꾸지 않았다. 소유 창의 요소도 자신의 PID가 허용돼야 변경을 받는다.

### 검증

모달을 연 뒤 Win32가 보고한 HWND와 소유자를 `listWindows`의 `windowId`·`ownerWindowId`와 대조했다. 모달의 `windowId`로 스냅샷을 받아 닫기 버튼을 Invoke하고, 픽스처가 기록한 상태 파일로 닫힘을 확인했다. 닫힌 뒤 그 스냅샷의 참조는 `STALE_REFERENCE`, 그 `windowId`는 `WINDOW_NOT_FOUND`였고 목록에서도 사라졌다. WPF 팝업은 자신의 스냅샷에서 버튼을 Invoke해 픽스처의 클릭 기록을 확인했다. Win32 x64·x86, WPF, WinForms .NET Framework·.NET 9에서 두 Agent가 모두 통과했다.

### 남는 제약

- WPF 모달의 UIA Name은 창 제목이 아니라 내용의 텍스트였다(`uiaNameMatchesTitle=false`). `listWindows.name`은 UIA Name을 그대로 싣는다. 모달은 이름 대신 `ownerWindowId`와 `processId`로 고른다.
- `ownerWindowId`는 Win32 소유 관계다. 모달 여부나 소유자의 입력 차단 상태를 뜻하지 않는다. 모달이 열려 있어도 소유자 창의 요소에 대한 Invoke를 Agent가 막지 않는 것은 기존 정책 그대로다.
- 소유자가 보이지 않는 창이면 UI Automation은 소유 창을 데스크톱 아래에 두었다(보이지 않는 IME 창에서 관찰). 그런 창이 보이는 경우는 기존 순회가 찾는다. Delphi VCL처럼 숨은 소유자를 쓰는 앱은 시험하지 못했다.
- 메뉴(`#32768`), 콤보 드롭다운, 다른 프로세스가 소유한 창, 중첩 모달은 시험하지 않았다.
- PowerShell과 C# Worker 백엔드는 바꾸지 않았다. 두 백엔드의 `listWindows`는 이전과 같다.

## 2. .NET Framework WinForms의 Runtime ID와 부분 스냅샷

### 원인

두 Agent와 무관한 COM 클라이언트로 `GetRuntimeId`의 결과를 직접 읽었다. [진단 스크립트](../tools/Probe-UiaRuntimeIds.ps1)

| 화면 | 조회한 요소 | 빈 Runtime ID | 해당 요소 |
|---|---:|---:|---|
| Common controls | 59 | 13 | TabItem 3, ListItem 3, ComboBox 내부 4, Slider 내부 3 |
| Grid and tree, 가상 행 2,000개 | 2,000 (한도) | 1,985 | 그리드 행 496, 셀 988, 헤더 497, 스크롤바 내부 4 |
| Virtual lists | 600 (한도) | 0 | 없음 |

빈 값은 모두 `S_OK`와 경계 `[0..-1]`의 `VT_I4` SAFEARRAY였다. 중복된 Runtime ID는 없었다. app.config 없이 실행해도 같았다. HWND가 없는 WinForms 접근성 객체에서만 나타났고 .NET 9에서는 나타나지 않았다. 이 부분은 Provider 제약이다.

Runtime ID가 없는 요소는 다음 요청 때 같은 요소인지 확인할 수 없다. 참조를 발급하면 목록이 바뀐 뒤 다른 항목을 조작할 수 있으므로 생략이 맞다. Agent의 문제는 그다음이었다. 스냅샷 전체에 `truncated=true` 하나만 표시해 어디가 빠졌는지 알 수 없었고, 그 창에서는 온전히 수집된 가지의 `findElement`까지 모두 `INCOMPLETE_SNAPSHOT`이었다.

### 조치

- 하위 트리가 잘린 요소에 `partial: true`를 표시한다. 식별할 수 없는 자식을 생략한 요소, 깊이·개수 한도로 자식을 더 읽지 못한 요소, 식별 문자열이 잘린 요소다. `truncated`가 되는 모든 경로가 요소 하나를 표시한다.
- `truncated` 스냅샷에서도 `findElement.scopeRef`의 요소와 그 하위에 `partial` 요소가 없으면 검색 결과를 확정한다. 그 가지의 Control View 자손은 모두 수집됐기 때문이다. 범위 안에 `partial`이 있거나 범위가 없으면 이전처럼 거부한다. 이미 수집된 중복은 이전처럼 `AMBIGUOUS_ELEMENT`가 먼저다.
- `partial`을 표시하지 않는 백엔드의 잘린 스냅샷은 어떤 범위도 확정하지 않는다. `truncated` 없이 `partial`이 온 응답은 `WORKER_PROTOCOL`로 거부한다.
- 식별할 수 없는 요소에는 계속 참조를 발급하지 않는다. 비밀번호·편집·ValuePattern 요소의 하위 생략은 정책이므로 `partial`이 아니다.

### 검증

.NET Framework 픽스처의 창 스냅샷은 39개 요소, `truncated=true`였고 `partial`은 Tab과 List 두 요소였다.

| 요청 | 결과 |
|---|---|
| 창 전체에서 검색, 있는 요소와 없는 요소 | `INCOMPLETE_SNAPSHOT` |
| 온전한 가지(버튼 줄)를 `scopeRef`로 검색 | 일치는 성공, 없는 요소는 `ELEMENT_NOT_FOUND` |
| `partial`인 List를 `scopeRef`로 검색 | `INCOMPLETE_SNAPSHOT` |
| List부터 새 스냅샷 | `truncated=true`, 루트가 `partial`, ListItem 행 없음 |
| 온전한 가지부터 새 스냅샷 | `truncated=false`, 7개 요소, 범위 없는 검색 성공 |

온전한 범위를 거쳐 버튼 Invoke와 편집 SetValue를 실행하고 카운터와 입력값을 픽스처에서 확인했다. 창 전체가 잘려 이전에 실행하지 못한 모달, 교체, 비활성, 읽기 전용, PID 거부, 중복 명령 체크도 이 방식으로 두 Agent에서 통과했다. 창 전체 트리, 목록 하위 범위, 그리드 행 체크는 실패로 남기고 `UIA_PROVIDER_LIMITATION`으로 분류했다. 잘린 트리가 통과로 집계된 체크는 없다.

### 남는 제약

- .NET Framework WinForms의 ListBox 항목, TabItem, DataGridView의 행·셀·헤더, ComboBox와 TrackBar의 내부 요소는 참조가 없어 조회와 조작을 할 수 없다. 이 요소가 필요하면 MSAA 같은 다른 접근 경로나 앱 쪽 접근성 구현이 있어야 한다. 이번 범위가 아니다.
- 온전한 범위 안의 유일성만 보장한다. 창 전체에서 유일한지는 잘린 창에서 증명할 수 없다.
- Runtime ID가 중복되는 공급자는 관찰하지 못했다. Agent는 중복을 검사하지 않는다.

## 3. AWT 버튼의 Invoke

### 원인

같은 `java.awt.Button`(네이티브 클래스 `Button`)을 시도마다 새 픽스처에서 다섯 가지 방법으로 눌렀다. 판정은 픽스처가 기록하는 카운터다.

| 활성화 방법 | 호출 결과 | 카운터 |
|---|---|---|
| Agent의 UIA InvokePattern | `S_OK`, 키보드 포커스가 버튼으로 이동 | 0 → 0 |
| `PostMessage(BM_CLICK)` | 게시됨 | 0 → 0 |
| `SendMessageTimeout(BM_CLICK)` | 반환 | 0 → 0 |
| MSAA `accDoDefaultAction` (기본 동작 Press) | 반환 | 0 → 0 |
| 관리형 UIA InvokePattern | 패턴 미제공 | 시도 불가 |

창이 포그라운드인 상태에서도 같았다. OpenJDK 17의 `awt_Button.cpp`에서 액션 콜백은 `AwtButton::WmMouseUp`에서만 호출되고, 그 전에 `WmMouseDown`이 눌림을 기록해야 한다. `BN_CLICKED`, `BM_CLICK`, `WM_COMMAND` 처리는 없다. Win32 버튼용 UIA 프록시의 Invoke와 MSAA 기본 동작은 AWT 피어에서 효과가 없고, Agent 없이 보내도 같다. Agent의 호출 경로는 결함이 아니다.

Agent 쪽 결함은 응답이었다. `{"performed":true}`만 반환해 액션이 수행된 것으로 읽혔다.

### 조치

- `invoke`와 `setValue`의 성공 응답에 `effectVerified:false`를 넣는다. `performed`는 공급자가 호출을 받아 정상 반환했다는 뜻으로 남는다. 기존 필드는 그대로이고 `ACTION_OUTCOME_UNKNOWN`, 중복 명령 거부, 자동 재전송 금지도 그대로다.
- 시험 실행기는 Agent 응답으로 성공을 판정하지 않는다. `effectVerified`가 false인지 확인한 뒤 픽스처 상태만 본다. 반응이 없으면 같은 HWND에 `BM_CLICK`과 MSAA 기본 동작을 대조군으로 보낸다. 대조군도 효과가 없으면 `UIA_PROVIDER_LIMITATION`, 대조군만 효과가 있으면 `AGENT_BUG`로 기록한다.
- Agent가 앱의 반응을 직접 확인하는 기능은 넣지 않았다. UIA Invoked 이벤트는 공급자마다 발생 여부가 다르고 대기 시간이 모든 Invoke에 더해진다. SetValue 후 값 재조회는 Value를 읽지 않는 정책과 충돌한다. 마우스 메시지 주입은 UIA 패턴만 쓰는 정책 밖이다.

### 검증

AWT 픽스처에서 두 Agent 모두 Invoke가 `performed:true, effectVerified:false`로 반환됐고 카운터는 0이었다. 대조군 두 가지도 효과가 없어 카운터 증가, 모달 열기, 교체 후 재호출 체크 세 개가 `UIA_PROVIDER_LIMITATION` 실패로 기록됐다. 같은 요청 ID의 재전송은 앱 반응이 없었어도 `DUPLICATE_COMMAND`였다. AWT 편집 필드의 SetValue는 이전처럼 픽스처 상태로 확인됐다.

### 남는 제약

- UIA로는 `java.awt.Button`을 누를 수 없다. [이전 검증](UI-FRAMEWORK-COMPATIBILITY.md)에서 Java Access Bridge가 AWT 요소 22개를 반환했지만 JAB 어댑터와 AWT 버튼 액션은 이번 범위가 아니다.
- AWT 목록의 항목 이름도 읽을 수 없다. 네이티브 ListBox가 `LBS_HASSTRINGS` 없는 owner-draw(스타일 `0x54000111`)다.
- Oracle JDK 17.0.10에서만 확인했다. 다른 JDK의 AWT 피어는 시험하지 않았다.
- `effectVerified`는 현재 항상 false다. 앱의 독립적인 상태 확인은 호출자의 몫이다.

## 검증 중에 고친 것

- **C++ Agent의 DPI.** 배율 125% 화면에서 C++ Agent의 `bounds`가 모두 Java/JNA 값의 1/1.25였다. 경로, 역할, 이름, 상태, 액션은 같았다. 실행 파일이 DPI 인식을 선언하지 않아 UI Automation이 96 DPI 기준 좌표를 돌려준 것이다. [매니페스트](../native/cpp-agent/src/windows/cpp-agent.manifest)에 PerMonitorV2를 선언한 뒤 여섯 프레임워크의 트리 비교가 좌표까지 일치했다. 이전 검증은 배율 100%에서만 실행돼 드러나지 않았다.
- **시험 실행기.** Windows PowerShell 5.1의 `Get-Content`가 돌려준 줄에는 공급자 객체가 붙어 있어, C++ 빌드 정보를 보고서에 넣으면 `ConvertTo-Json`이 끝나지 않았다. 일반 문자열로 바꿨다. 보고서를 읽는 단언 스크립트는 5.1의 2 MB 한도와 UTF-8 해석 문제를 피하도록 고쳤다.
- **진단 격리.** 관리형 UI Automation 라이브러리를 올린 프로세스에서는 COM 클라이언트가 WinForms 창을 59개 대신 40개 요소로 보고 빈 Runtime ID가 0개가 됐다. 진단은 각각 별도 프로세스에서 실행한다.

## 회귀 시험 결과

Windows 11 Pro 25H2 빌드 26200.7840, Core i7-1255U, 배율 125%의 모니터 1개, 로컬 대화형 세션에서 실행했다. Agent의 Java는 Oracle JDK 17.0.10 x64, C++는 MSVC 19.44.35230 Release다. 픽스처 런타임은 .NET Framework 4.8.1, .NET 9.0.23, Oracle JDK 17.0.10이다.

| 프레임워크 | JNA | C++ | 통과하지 못한 체크 (두 Agent 동일) |
|---|---|---|---|
| Win32 x64 | 22 / 22 | 22 / 22 | 없음 |
| WPF Extended | 24 / 24 | 24 / 24 | 없음 |
| WinForms .NET 9 | 21 / 21 | 21 / 21 | 없음 |
| WinForms .NET Framework | 19 / 23 | 19 / 23 | 창 전체 트리, 목록 하위 범위, 그리드 행: `UIA_PROVIDER_LIMITATION`. AutomationId 없는 요소 검색: 해당 요소 없음 |
| AWT | 15 / 19 | 15 / 19 | 버튼 Invoke 3개, 목록 항목 이름: `UIA_PROVIDER_LIMITATION` |
| Swing | 6 / 19 | 6 / 19 | 9개 `JAB_ONLY`, 그에 딸린 4개 미실행 |
| MFC, Delphi VCL, Qt, Chromium/Electron, DirectX/OpenGL | 미실행 | 미실행 | 픽스처나 컴파일러 없음 |

- 분류: `UIA_PROVIDER_LIMITATION` 14, `JAB_ONLY` 18, 해당 없음 2, `AGENT_BUG` 0, 미분류 0.
- [이전 실행](test-results/2026-11-23-uia-frameworks-functional.json)과 비교하면 Win32, WPF, WinForms .NET 9는 유일한 실패였던 모달 체크가 통과해 전 항목 통과가 됐다. .NET Framework WinForms는 Agent당 통과하지 못한 체크가 22개 중 14개에서 23개 중 4개로 줄었다.
- 두 Agent의 트리 비교는 여섯 프레임워크 모두 일치했다. .NET Framework WinForms는 부분 트리끼리의 일치이며 `partial` 표시도 같았다.
- Win32 x86 픽스처는 x64 JNA, x64 C++, x86 C++에서 각각 22개 체크를 모두 통과했다. [x64 Agent](test-results/2026-11-24-uia-defects-win32-x86.json) · [x86 C++ Agent](test-results/2026-11-24-uia-defects-cpp-x86.json)
- 기존 WPF 동등성 비교는 콘텐츠 19개, 제목 표시줄, 교체, 프로세스 종료가 일치했다. [원본](test-results/2026-11-24-uia-defects-wpf-parity.json)
- Maven 비-GUI 시험 55개와 C++ CTest x64·x86이 통과했다. 기존 WPF 통합 시험은 PowerShell과 JNA 백엔드 2개가 통과했고, C# Worker가 필요한 2개는 이 PC에 Worker가 없어 건너뛰었다.

`docs/test-results`의 JSON은 실행기가 쓴 파일을 내용 변경 없이 들여쓰기만 줄여 저장했다.

## 판정에 영향을 준 환경 요인

- Win32 픽스처의 10,000행 가상 목록을 2,000개까지 수집하는 요청은 이 노트북에서 3.2~7.7초가 걸렸고 x86 픽스처에서는 10초 제한을 넘기도 했다. 수정 전 `main`의 C++ Agent와 JNA도 같은 시점에 똑같이 제한을 넘었으므로 이번 변경의 회귀가 아니다. x86 보고서는 제한 안에 끝난 재실행 결과다. 실행기는 읽기 요청의 `TIMEOUT`을 `INCONCLUSIVE`로 기록한다.
- 기존 WPF 통합 시험의 커서 고정 단언은 PC를 사용하는 중에 한 번 실패했고 재실행에서 통과했다.
- 성능은 다시 측정하지 않았다. `listWindows`는 `EnumWindows` 한 번과 소유 창마다 UIA 호출 서너 번이 늘었다. 소유 창이 없는 데스크톱에서 첫 호출 뒤 53~109 ms였다.

## 미해결 사항

| 항목 | 구분 | 다음 단계 |
|---|---|---|
| .NET Framework WinForms의 항목·탭·그리드 행과 셀 | Provider 제약 | 필요한 설비 앱이 확인되면 MSAA 경로 검토 |
| `java.awt.Button` 조작, AWT 목록 항목 이름 | Provider 제약 | JAB 어댑터 범위에서 검토 |
| Swing 컨트롤 | `JAB_ONLY` | 위와 같음 |
| 숨은 소유자를 쓰는 앱, 메뉴·콤보 드롭다운, 다른 프로세스 소유 창, 중첩 모달 | 미시험 | MFC·VCL 픽스처와 함께 확인 |
| PowerShell·C# Worker 백엔드의 소유 창과 `partial` | 미적용 | 해당 백엔드를 계속 쓸 경우 반영 |
| Agent가 액션의 효과를 직접 확인하는 기능 | 미구현 | 호출자가 앱 상태로 확인 |
| MFC, Delphi VCL, Qt, Chromium/Electron, 커스텀 렌더링, RDP, 다중 모니터 | 미실행 | 이전 문서와 같음 |

## 변경 위치와 재현

- Java/JNA: [창 열거와 캡처](../src/main/java/dev/desktop/JnaUiaSession.java) · [Win32 소유 관계 조회](../src/main/java/dev/desktop/UiaCom.java) · [범위 완전성 판정](../src/main/java/dev/desktop/DesktopSnapshot.java) · [액션 응답](../src/main/java/dev/desktop/Agent.java)
- C++: [UIA Adapter](../native/cpp-agent/src/windows/uia_adapter.cpp) · [Core](../native/cpp-agent/src/core/agent.cpp) · [DPI 매니페스트](../native/cpp-agent/src/windows/cpp-agent.manifest)
- 단위 시험: [Java 범위 검색](../src/test/java/dev/desktop/ScopedLocatorTest.java) · [Java 액션 응답](../src/test/java/dev/desktop/AgentTest.java) · [C++ Core](../native/cpp-agent/tests/core_test.cpp)
- 실제 GUI 시험: [체크](../tools/UiaFrameworkCases.ps1) · [실행기](../tools/Test-UiaFrameworks.ps1) · [세 결함 단언](../tools/tests/Test-UiaDefectRegression.ps1) · [WinForms 단언](../tools/tests/Test-WinFormsRuntimeIds.ps1)

빌드는 [호환성 문서의 절차](UI-FRAMEWORK-COMPATIBILITY.md#빌드와-재현)와 같다. 잠금 해제된 대화형 세션의 Windows PowerShell 5.1에서 실행한다.

```powershell
& ./tools/Test-UiaFrameworks.ps1 -Framework WinFormsFramework,Win32,Wpf,WinFormsModern,Swing,Awt,Mfc,DelphiVcl,Qt,ChromiumElectron,CustomRendering -DiagnoseAccessibility -OutputPath target/uia-defects-functional.json
& ./tools/tests/Test-UiaDefectRegression.ps1 -ReportPath target/uia-defects-functional.json -RequireBothBackends
& ./tools/tests/Test-WinFormsRuntimeIds.ps1 -ReportPath target/uia-defects-functional.json
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32 -FixtureRoot target/framework-fixtures/x86 -OutputPath target/uia-defects-win32-x86.json
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32 -Backend Cpp -CppAgent target/cpp-agent-x86/Release/cpp-agent.exe -FixtureRoot target/framework-fixtures/x86 -OutputPath target/uia-defects-cpp-x86.json
& ./tools/Compare-JavaCpp.ps1 -ParityOnly -OutputPath target/uia-defects-wpf-parity.json
```

진단 스크립트는 읽기 전용이다. 대상 창의 PID와 HWND를 지정한다.

```powershell
powershell.exe -NoProfile -File tools/Probe-UiaWindows.ps1 -ProcessId 1234
powershell.exe -NoProfile -File tools/Probe-UiaRuntimeIds.ps1 -WindowHandle 65572 -ProcessId 1234
```
