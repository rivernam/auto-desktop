# Java Access Bridge Adapter

Swing과 AWT 창은 UI Automation에 창 틀만 보인다. 두 Agent(Java/JNA, C++)에 Java Access Bridge(JAB) 백엔드를 추가해 같은 일곱 NDJSON 명령으로 이 창들을 탐색하고 조작하도록 했다. 2026-11-24에 Windows 11에서 구현하고 측정한 내용이다. 시험 대상 커밋은 각 결과 JSON의 `environment.git`에 기록돼 있다.

## 요약

| 항목 | 결과 |
|---|---|
| 구현 | Java/JNA와 C++ 두 Agent 모두. `--backend jab`으로 명시해야 선택된다. 기본 백엔드와 UIA 동작은 바뀌지 않았다. |
| Swing (Java 17, Java 23 x64) | 트리 95개 요소 탐색, Locator, 버튼 실행, 텍스트 입력, 참조 무효화까지 Agent별 35개 검사 중 34개 통과(Java 23은 만료 검사를 뺀 34개 중 33개). |
| AWT (Java 17, Java 23 x64) | 트리 22개 요소 탐색, 버튼 실행과 모달 열기·닫기 통과. Agent별 31개 검사 중 28개 통과(Java 23은 30개 중 27개). |
| 통과하지 못한 검사 | Swing: 모달 대화상자를 여는 버튼(1). AWT: 텍스트 입력(1)과 그에 딸린 미실행 2. 모두 Java 쪽 구현의 한계이며 원인을 소스와 실측으로 확인했다. Agent 결함으로 분류된 항목은 없다. |
| AWT 버튼 | UIA Invoke, `BM_CLICK`, MSAA 기본 동작으로는 움직이지 않던 `java.awt.Button`이 JAB에서는 실제로 실행된다. |
| 두 구현의 일치 | Swing과 AWT 모두 두 Agent가 같은 트리를 캡처했고 모든 검사에서 같은 판정을 냈다. |
| 기존 UIA 회귀 | Win32, WPF, WinForms 두 종류, Swing, AWT 모두 이전 결과와 같다. |
| MFC (UIA) | MFC 구성 요소를 설치해 처음으로 실행했다. 두 Agent 모두 21/21, 트리 일치. |
| 미실행 | Java 6·7·8·11·21 대상 JVM, x86 JVM과 x86 브리지, Delphi VCL, 1시간 이상 연속 시험은 아래에 사유와 함께 적었다. |

## 구조

```text
Cli / main.cpp ── --backend jab ──┐
                                   ▼
          Agent (공통 Core: Snapshot, Locator, 공개 ref, 120초 만료,
                 PID·액션 허용 정책, 중복 명령 ID, 결과 미상 처리)
                                   │ DesktopAdapter (한 세션에 하나)
        ┌──────────────────────────┴──────────────────────────┐
  UIA Adapter (기본)                                    JAB Adapter
  JnaUiaSession / uia_adapter.cpp                 JabSession / jab_adapter.cpp
                                                         │
                                         WindowsAccessBridge-64.dll (Agent 프로세스 안)
                                                         │ 창 메시지 + 공유 메모리
                                         대상 JVM의 JavaAccessBridge.dll과 AccessBridge 클래스
```

공통 Core는 한 줄도 JAB를 알지 못한다. 추가한 것은 Adapter 하나와 선택 옵션, 그리고 Core의 작은 확장 세 가지다.

- 요소 행의 선택 필드 `nativeRole`과 `partialReason`.
- 세션 스레드가 요청 사이에 Adapter의 유휴 작업을 부르는 훅. JAB는 요청이 없을 때도 창 메시지를 받아야 한다.
- 백엔드가 시작하지 못한 사유를 `getCapabilities.reason`으로 전달하는 경로.

| 책임 | 위치 |
|---|---|
| NDJSON, Snapshot, Locator, 공개 ref와 만료, 허용 정책, 중복 ID, 오류 코드, 10초 요청 기한 | 공통 Core. Java `Agent`·`DesktopSnapshot`·`ActionDispatcher`, C++ `core/agent.cpp`·`session_worker.cpp` |
| 브리지 DLL 선택과 로딩, 메시지 전달, 호출 시간 판정 | Java [`JabBridge`](../src/main/java/dev/desktop/JabBridge.java), C++ [`jab_adapter.cpp`의 `Bridge`](../native/cpp-agent/src/windows/jab_adapter.cpp) |
| Java 창 식별, 트리 수집, 역할·상태 매핑, 참조 검증, 액션 호출, 핸들 반환 | Java [`JabSession`](../src/main/java/dev/desktop/JabSession.java), C++ `JabAdapter` |
| 한 스레드에 세션을 가두고 기한을 넘긴 호출을 처리 | Java [`JnaDesktopAdapter`](../src/main/java/dev/desktop/JnaDesktopAdapter.java)(UIA와 공용), C++ `SessionWorker`(UIA와 공용) |

`JabSession`은 추상 클래스 [`JabApi`](../src/main/java/dev/desktop/JabApi.java)에만 의존한다. 단위 테스트는 실제 JVM 없이 각본대로 움직이는 브리지를 넣어 참조 규칙과 핸들 반환 횟수를 검사한다.

## 선택과 초기화

```powershell
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --backend jab --allow-pid 1234 --allow-action invoke --allow-action setValue
./target/cpp-agent/Release/cpp-agent.exe --backend jab --allow-pid 1234 --allow-action invoke --allow-action setValue
```

`--jab-dll C:\절대\경로\WindowsAccessBridge-64.dll`로 브리지 DLL을 직접 지정할 수 있다. `--backend jab` 없이 쓰면 시작을 거부한다. C++ Agent는 `--backend uia`도 받으며 생략하면 UIA다.

**DLL 선택.** 현재 작업 디렉터리와 `PATH`는 찾지 않는다.

| Agent | 지정이 없을 때 찾는 순서 |
|---|---|
| Java/JNA | Agent를 실행한 Java의 `bin`, 그다음 Windows 시스템 디렉터리 |
| C++ | Windows 시스템 디렉터리, 그다음 `HKLM\SOFTWARE\JavaSoft`에 등록된 Java 설치의 `bin` |

지정한 경로가 있으면 그 파일만 쓴다. 상대 경로는 거부한다. 로드 전에 PE 헤더의 Machine 값을 Agent 프로세스의 비트수와 대조한다. `LoadLibraryExW`는 DLL 자신의 디렉터리와 System32만 의존 DLL 탐색에 쓰도록 호출한다. 64비트 Agent는 `WindowsAccessBridge-64.dll`, 32비트 Agent는 `WindowsAccessBridge-32.dll`을 쓴다. 객체 핸들이 32비트인 구형 `WindowsAccessBridge.dll` ABI는 지원하지 않는다.

**필요한 Export.** `Windows_run`, `isJavaWindow`, `getAccessibleContextFromHWND`, `getHWNDFromAccessibleContext`, `releaseJavaObject`, `isSameObject`, `getAccessibleContextInfo`, `getAccessibleChildFromContext`, `getAccessibleParentFromContext`, `getAccessibleActions`, `doAccessibleActions`, `setTextContents`. Java Agent는 `getVersionInfo`도 요구한다. 하나라도 없으면 백엔드를 쓰지 않고 그 이름을 사유로 보고한다. 구조체 배치는 JDK의 `AccessBridgePackages.h`를 따랐고 C++에서는 `static_assert`로 크기를 고정했다.

**스레드와 메시지.** `Windows_run`은 호출한 스레드에 숨은 대화상자를 만들고, 각 JVM은 게시 메시지로 응답해 서로를 알게 된다. 그래서 한 스레드가 DLL을 로드하고 모든 호출을 하며 메시지도 직접 꺼낸다.

- 시작 직후 최소 0.2초, 메시지가 0.1초 동안 없을 때까지(최대 2초) 메시지를 처리한다.
- 모든 요청의 시작에 대기 메시지를 처리한다. 나중에 시작한 JVM의 알림이 여기서 들어온다.
- 요청이 없을 때는 250 ms마다 같은 스레드에서 메시지를 처리한다. 숨은 창을 가진 스레드가 메시지를 꺼내지 않으면 시스템 전체 브로드캐스트를 보낸 쪽이 기다리게 된다.

**실패의 보고.** 초기화에 실패해도 다른 백엔드로 넘어가지 않는다.

| 상황 | 응답 |
|---|---|
| DLL 없음, 비트수 불일치, Export 부족, 로드 실패 | `getCapabilities`가 `available=false`, `backend="JAB"`, 빈 `operations`와 `reason`을 반환한다. 다른 요청은 `BACKEND_UNAVAILABLE`. |
| 브리지를 켜지 않은 JVM의 창 | `listWindows`에 나오지 않는다. 그 창의 `snapshot`은 `BRIDGE_NOT_CONNECTED`. `getCapabilities.bridge`의 `javaWindows`가 `connectedWindows`보다 크다. |
| Java 창이 아닌 창 | `WINDOW_NOT_FOUND` |

`javaWindows`는 창 클래스 이름이 `SunAwt`로 시작하는 보이는 최상위 창의 수다. 이 값은 진단용이고 대상을 고르는 데에는 쓰지 않는다.

**Agent가 하지 않는 일.** 대상 JVM 재시작, JVM 옵션 변경, `.accessibility.properties`나 `jabswitch` 같은 사용자·시스템 설정 변경, DLL 교체, 대상 프로세스에 코드 주입은 하지 않는다. 브리지는 대상 JVM을 시작하는 쪽이 켠다.

| 켜는 방법 | 범위 |
|---|---|
| `-Djavax.accessibility.assistive_technologies=com.sun.java.accessibility.AccessBridge` | 그 JVM 프로세스 하나. 이 검증의 픽스처가 쓴 방법이다. |
| `%USERPROFILE%\.accessibility.properties`에 `assistive_technologies=com.sun.java.accessibility.AccessBridge` | 그 사용자의 모든 JVM |
| `jabswitch -enable` | 위 파일을 써 주는 JDK 도구 |

## 창과 트리

**창 식별.** `listWindows`는 보이는 최상위 창마다 `isJavaWindow`를 묻고, 통과한 창에 대해 다음을 모두 확인한 뒤에만 행을 만든다.

1. `getAccessibleContextFromHWND`가 컨텍스트와 JVM 식별자를 돌려준다.
2. 그 컨텍스트에 `getHWNDFromAccessibleContext`를 물으면 같은 HWND가 나온다.
3. `snapshot`에서는 추가로, JVM 식별자가 가리키는 브리지 창의 프로세스가 대상 HWND의 프로세스와 같다. JVM 식별자는 대상 JVM 안 브리지 창의 핸들이다(Java 17과 23에서 확인).

창 제목이나 프로세스 이름으로 대상을 정하지 않는다. `windowId`는 HWND의 10진 문자열이라 같은 창이면 UIA 백엔드의 값과 같다. 소유자가 보이는 창이면 `ownerWindowId`를 붙인다. Swing이 소유자 없는 대화상자에 붙이는 숨은 공유 소유자는 적지 않는다.

**요소 행.**

| 필드 | JAB에서의 값 |
|---|---|
| `name` | 접근성 이름. 비밀번호 역할(`password text`)은 빈 문자열. |
| `role` | 아래 표로 정규화한 공통 역할. 대응이 분명하지 않으면 `Custom`. |
| `nativeRole` | 브리지가 준 영문 역할 그대로(`push button`, `page tab list` 등). 검색 조건은 아니다. |
| `automationId`, `className` | 항상 빈 문자열. JAB에는 해당 정보가 없고 Agent는 만들어 넣지 않는다. Java의 `Component.getName()`은 브리지로 나오지 않는다. |
| `processId` | 창의 PID. 한 창의 모든 요소가 같다. |
| `enabled`, `offscreen` | 상태 문자열의 `enabled` 포함 여부, `showing` 미포함 여부 |
| `bounds` | 브리지가 준 화면 좌표. 125 % 배율의 Java 17·23에서 Win32 `GetWindowRect`의 물리 픽셀과 일치했다. 폭이나 높이가 0 이하면 null. |
| `actions` | 아래 조작 규칙을 통과한 `invoke`, `setValue` |
| `backend` | `JAB` |

| 공통 역할 | JAB 역할 |
|---|---|
| Button | push button, toggle button |
| CheckBox, RadioButton, ComboBox | check box, radio button, combo box |
| Edit | text, password text |
| Text | label |
| List, ListItem, Table, Tree | list, list item, table, tree |
| Tab, TabItem | page tab list, page tab |
| MenuBar, Menu, MenuItem | menu bar, popup menu, menu·menu item·check box menu item·radio button menu item |
| Window | frame, dialog, window, internal frame |
| Pane | panel, root pane, layered pane, glass pane, viewport, scroll pane, split pane, desktop pane, option pane |
| 기타 | ScrollBar, Slider, ProgressBar, ToolBar, ToolTip, Separator, Hyperlink, Spinner, StatusBar, Image(icon), Group(group box), Header, HeaderItem |
| Custom | 그 밖의 모든 역할. 예: 메시지 대화상자의 `alert`, 접힌 트리 노드의 `unknown`. |

**이름과 민감 정보.** UIA 백엔드는 편집 요소의 이름을 모두 가린다. JAB에는 AutomationId가 없어서 이름을 가리면 텍스트 필드를 찾을 방법이 없다. Java 텍스트 컴포넌트의 접근성 이름은 앱이 지정한 이름이나 연결된 라벨이고 문서 내용에서 만들어지지 않는다. 그래서 JAB 백엔드는 `text` 역할의 이름을 그대로 내보내고 `password text` 역할만 가린다. Agent는 텍스트 내용이나 값을 읽는 브리지 함수(`getAccessibleText*`, 값 조회)를 아예 바인딩하지 않았다. 비밀번호 필드의 자식은 읽지 않는다. `java.awt.TextField`에 에코 문자를 설정한 필드는 브리지가 일반 `text`로 보고하므로 비밀번호로 구분할 수 없다. 이름은 라벨이고 내용은 노출되지 않는다. 이 정책은 UIA 백엔드와 다르므로 채택 전에 검토가 필요하다.

**제한과 부분 스냅샷.** `maxDepth`, `maxElements`, `truncated`, `partial`, `scopeRef`는 UIA 백엔드와 같은 의미다. JAB 행은 잘린 이유를 `partialReason`으로 구분한다.

| `partialReason` | 뜻 |
|---|---|
| `limit` | 요청의 깊이나 요소 수 한도 때문에 이 요소의 자식을 더 읽지 않았다. 한도를 늘리거나 범위를 좁히면 해소된다. |
| `provider` | 브리지가 자식 컨텍스트를 주지 않았거나 그 정보를 읽지 못했다. 또는 이름이 1,023자에서 잘려 왔다. 다시 읽어도 같을 수 있다. |
| `limit,provider` | 두 가지가 한 요소에서 함께 일어났다. |

깊이는 32, 요소는 2,000으로 묶여 있어 순환하거나 지나치게 큰 트리도 그 안에서 끝난다. 자식 수가 음수면 0으로 본다. 온전한 하위 범위에서는 `scopeRef` 검색이 확정이고, `partial` 요소가 든 범위는 `INCOMPLETE_SNAPSHOT`이다.

## 참조와 리소스 수명

브리지가 돌려주는 컨텍스트 핸들 하나는 대상 JVM 안의 참조 하나다. `releaseJavaObject`로 돌려줄 때까지 JVM이 그 객체를 붙잡는다.

- 받은 핸들은 정확히 한 번 반환한다. 창 목록과 검증에 쓴 핸들은 그 요청 안에서 반환한다. 캡처의 핸들은 다음 캡처, 만료, 세션 종료 때 반환한다. Java는 GC에 맡기지 않고 직접 반환하며, C++는 임시 핸들을 RAII 객체로 감싼다.
- 범위 스냅샷은 범위에서 창까지의 경로 핸들만 넘겨받고 나머지를 반환한다.
- 읽지 못해 생략한 자식의 핸들도 반환 목록에 들어간다.
- `releaseJavaObject`는 시간 제한이 없는 `SendMessage`다. 응답하지 않는 JVM에는 보내지 않고 보류했다가 JVM이 다시 응답할 때 반환한다. JVM이 종료했으면 버린다.
- Agent가 강제 종료되면 반환하지 못한 참조는 대상 JVM이 끝날 때까지 남는다. 브리지 구조상 피할 수 없다.

**같은 요소인지 확인하는 방법.** 참조를 쓸 때마다 다음을 확인하고 하나라도 어긋나면 `STALE_REFERENCE`다.

1. 캡처한 PID와 요청의 PID가 같고, HWND가 여전히 그 PID의 보이는 최상위 창이다. C++는 프로세스 시작 시각도 대조한다.
2. HWND에서 다시 얻은 컨텍스트가 캡처한 창 루트와 `isSameObject`로 같은 객체이고 JVM 식별자가 같다.
3. 대상 요소에서 `getAccessibleParentFromContext`를 따라 올라가며 얻은 각 부모가 캡처한 조상과 `isSameObject`로 같고, 그 끝이 캡처한 창이다.
4. 조작 직전에는 이름·역할이 캡처와 같고, 활성·표시 상태이며, 액션이 여전히 제공된다.

자식 번호나 이름이 같다는 것은 근거로 쓰지 않는다. 같은 자리에 같은 이름의 새 버튼이 놓여도 옛 참조는 실패한다.

**요청마다 새로 만들어지는 객체.** Swing은 목록 항목, 표 셀, 트리 노드의 접근성 객체를 요청할 때마다 새로 만든다. 이런 객체가 부모인 요소(예: 트리의 2단계 이하 노드)는 3번 확인에서 부모가 같은 객체임을 증명할 수 없어 `getElementInfo`와 조작이 `STALE_REFERENCE`가 된다. 스냅샷에는 나타난다. 부모가 오래 유지되는 컴포넌트인 목록 항목과 표 셀은 확인된다.

**JVM 종료와 재시작.** 종료하면 창이 사라져 참조가 `STALE_REFERENCE`, 창은 `WINDOW_NOT_FOUND`가 된다. 열려 있는 세션은 새로 시작한 JVM을 창이 뜬 뒤의 다음 요청에서 발견한다(실측 9~86 ms). 새 JVM의 PID는 세션이 허용한 PID가 아니므로 제목과 컨트롤이 같아도 조작은 `PERMISSION_DENIED`다.

**Agent 종료.** DLL을 내리면 브리지가 각 JVM에 떠난다고 알리고 JVM은 공유 메모리를 닫는다. 이 알림도 시간 제한이 없다. 그래서 응답하지 않는 JVM을 알고 있으면 DLL을 내리지 않고 프로세스를 바로 끝낸다. 세션 스레드가 10초 안에 끝나지 않을 때도 같다. 실측에서 모달이 열린 채로도 Agent는 41~45 ms에 종료 코드 0으로 끝났다.

## 조작

**invoke.** 역할이 `push button` 또는 `menu item`이고 다음 중 하나일 때만 제공한다.

- 액션이 정확히 하나다. 그 이름이 무엇이든(Swing은 로캘에 따라 번역한다) 그 액션을 실행한다.
- 액션이 여럿이면 이름이 `click`인 것이 정확히 하나다.

목록의 첫 액션을 클릭으로 간주하지 않는다. 체크박스, 라디오 버튼, 콤보 박스, 메뉴, 탭은 액션이 있어도 `invoke`를 제공하지 않는다. 토글·선택·펼치기는 현재 API에 없기 때문이다. 스냅샷에서 역할과 상태는 읽을 수 있다.

**setValue.** 역할이 `text` 또는 `password text`이고 상태에 `editable`이 있을 때 제공한다. 값은 UTF-16 1,023 코드 단위까지다. 브리지의 전송 버퍼가 1,024이기 때문이다. 더 길거나 NUL 문자를 포함하면 보내기 전에 `PRECONDITION_FAILED`로 거부한다. UIA 백엔드의 한도는 16,384다.

**결과의 뜻.** 브리지가 TRUE를 돌려주면 `{"performed":true,"effectVerified":false}`다. 호출이 받아들여졌다는 뜻이고 앱 상태가 바뀌었다는 뜻이 아니다. FALSE는 거부와 응답 유실을 구분하지 못하므로 `ACTION_OUTCOME_UNKNOWN`이다. 어떤 실패에도 같은 조작을 UIA로 다시 보내지 않고, 다시 시도하지도 않는다. 물리 마우스·키보드 입력과 창 메시지 주입은 쓰지 않는다.

## 응답하지 않는 JVM

OpenJDK에서 Windows DLL은 공유 메모리의 완료 표지를 검사하지만 표지는 공개 API에 노출되지 않는다. 설치 DLL을 사용한 Swing 모달 실측에서는 약 8초 뒤 정수 1 이외의 값이 돌아왔고 실패 인덱스가 -1이었다. 두 Agent는 `invoke`에 정수 1과 성공 인덱스 -1이 모두 필요하다고 판단하며, `setValue`에도 정수 1을 요구한다. 3.5초 보수적 시간 제한은 유지한다. 결과와 무관하게 앱의 실제 효과는 별도 관측이 필요하다. [공식 소스와 실측](MULTI-BACKEND-STABILIZATION.md#b-jab-응답-신뢰성)

| 시점 | 응답 |
|---|---|
| 조작을 보낸 뒤 응답이 없음 | `ACTION_OUTCOME_UNKNOWN`. 조작은 이미 앱에 도달했을 수 있다. |
| 그 밖의 호출에서 응답이 없음, 또는 요청 시작 시 아는 JVM이 응답하지 않음 | `TARGET_NOT_RESPONDING`. 세션은 유지된다. JVM이 돌아오면 같은 세션과 같은 스냅샷으로 계속한다. |

요청을 시작할 때 이미 만난 JVM마다 0.5초 제한의 빈 메시지로 브리지 스레드가 살아 있는지 확인한다. 이 확인이 없으면 창 조회 하나가 응답 없는 JVM을 수 초씩 기다린다. 브리지 DLL은 창 하나를 물을 때 연결된 모든 JVM에 차례로 묻기 때문에, 한 JVM이 멈추면 다른 JVM의 창 조회도 느려진다. 그래서 아는 JVM 하나가 응답하지 않으면 다른 JVM을 향한 요청도 `TARGET_NOT_RESPONDING`으로 바로 끝낸다.

### 모달을 여는 Swing 버튼

Swing 버튼의 접근성 액션은 `AbstractButton.doClick()`이고, 이 메서드는 이벤트 스레드에서 리스너를 동기적으로 실행한다. 브리지는 그 실행이 끝나기를 시간 제한 없이 기다린다(JDK 17 `AccessBridge.InvocationUtils.invokeAndWait`의 `lock.wait()`). 리스너가 모달 대화상자를 띄우면 대화상자가 닫힐 때까지 돌아오지 않는다. 그동안 JVM의 브리지 스레드가 묶여 그 JVM은 어떤 브리지 요청에도 답하지 못한다.

실측(Java 17, 두 Agent 동일):

1. `invoke`가 8초 뒤 `ACTION_OUTCOME_UNKNOWN`으로 끝났다. 픽스처의 상태 파일은 모달이 열렸음을 보여 줬다.
2. 모달이 열린 동안 `listWindows`는 즉시 `TARGET_NOT_RESPONDING`이었다. 모달의 내용은 읽을 수 없었다.
3. 픽스처 명령으로 모달을 닫자 같은 세션의 같은 참조가 다시 동작했다.

따라서 **리스너 안에서 모달을 직접 여는 Swing 버튼은 JAB만으로는 끝까지 자동화할 수 없다.** 누군가 대화상자를 닫아야 다음 단계로 갈 수 있다. 앱이 스스로 연 모달(타이머나 `invokeLater`에서 연 경우)은 `listWindows`에 `ownerWindowId`와 함께 나오고, 자체 스냅샷으로 읽고 그 안의 버튼으로 닫을 수 있었다. `JOptionPane`도 같다. `java.awt.Button`의 액션은 이벤트를 게시하고 바로 돌아오므로 AWT에서는 모달을 열고 닫는 전 과정이 통과했다.

### AWT 텍스트 입력

브리지의 `setTextContents`는 컨텍스트가 `AccessibleEditableText`를 구현할 때만 동작한다. 표준 AWT `TextField` 및 `TextArea`의 컨텍스트는 `AccessibleText`를 제공한다. 두 Agent에서 편집 가능 상태인 JAB 행의 `setValueSupport`는 `unverified`이며, 편집 불가 행은 `unsupported`다. 기존 `actions`의 후보를 읽는 클라이언트도 계속 동작한다. AWT에서 네이티브 텍스트 필드를 쓸 때는 UIA의 새 스냅샷과 참조로 요청한다. [공통 API](API.md)

## 오류 코드

JAB 백엔드가 새로 쓰는 코드는 두 개다. 나머지는 기존 계약과 같다.

| code | 뜻과 처리 |
|---|---|
| `BRIDGE_NOT_CONNECTED` | Java 창이지만 그 JVM이 브리지에 연결돼 있지 않다. 대상 JVM에서 브리지를 켜야 한다. |
| `TARGET_NOT_RESPONDING` | 연결된 JVM이 브리지 요청에 답하지 않는다. 앱이 응답할 때 다시 요청한다. 세션과 스냅샷은 유지된다. |

## 검증 결과

모든 시험은 Windows 11 Pro 25H2(빌드 26200), 12세대 Core i7-1255U, 125 % 배율의 단일 모니터 대화형 세션에서 했다. Agent는 x64다(Java Agent는 Oracle JDK 17.0.10, C++ Agent는 MSVC 19.44). 브리지 DLL은 `WindowsAccessBridge-64.dll` 17.0.10.0이다. 시험 중 PC를 다른 작업에도 썼으므로 지연 값은 실행마다 달라진다. 조작의 성공은 Agent 응답이 아니라 픽스처가 쓰는 상태 파일(클릭 횟수, 입력값, 모달 상태)로 판정했다.

### 호환성

| UI 환경 | UIA 탐색 | UIA 조작 | JAB 탐색 | JAB 조작 |
|---|---|---|---|---|
| Swing, Java 17 x64 | 창 틀만(6/19) | 불가 | PASS, 95개 요소 | 버튼·텍스트 PASS. 모달을 여는 버튼은 Java 쪽 제약 |
| Swing, Java 23 x64 | 미실행 | 미실행 | PASS, 95개 요소 | Java 17과 같음 |
| AWT, Java 17 x64 | 네이티브 피어(15/19) | 텍스트 PASS, 버튼 무반응 | PASS, 22개 요소 | 버튼·모달 PASS. 텍스트는 Java 쪽 제약 |
| AWT, Java 23 x64 | 미실행 | 미실행 | PASS, 22개 요소 | Java 17과 같음 |
| Swing·AWT, Java 21 | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Swing·AWT, Java 11 | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Swing·AWT, Java 8 x86/x64 | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| Swing·AWT, Java 6·7 x86 | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN |
| 32비트 Agent와 32비트 브리지 | 해당 없음 | 해당 없음 | NOT_RUN | NOT_RUN |

`NOT_RUN`인 조합은 이 PC에 해당 Java 런타임이나 32비트 브리지 DLL이 없어서 실행하지 못했다. 런타임을 내려받거나 설치하지 않았다. 32비트 C++ Agent는 빌드되고 코어 테스트를 통과하며, `--backend jab`에서 DLL이 없다는 사유와 비트수 불일치 사유를 `available=false`로 보고하는 것까지 확인했다.

### 기능 회귀

`tools/Test-UiaFrameworks.ps1 -Backend BothJab`의 결과다. 두 Agent의 판정은 모든 검사에서 같고 캡처한 트리도 같다.

| 대상 JVM | 프레임워크 | Java/JNA | C++ | 통과하지 못한 검사 |
|---|---|---|---|---|
| Java 17.0.10 | Swing | 34/35 | 34/35 | `modalOpenedByInvoke` (JAB_PROVIDER_LIMITATION) |
| Java 17.0.10 | AWT | 28/31 | 28/31 | `setValueAndEmpty` (JAB_PROVIDER_LIMITATION), 그에 딸린 미실행 2 |
| Java 23.0.2 | Swing | 33/34 | 33/34 | 위와 같음 |
| Java 23.0.2 | AWT | 27/30 | 27/30 | 위와 같음 |

Java 17 실행에는 121초를 기다려 참조 만료를 확인하는 검사 하나가 더 들어 있다. `AGENT_BUG`나 `UNCLASSIFIED`로 남은 검사는 없다. [Java 17 원본](test-results/2026-11-24-jab-functional-java17.json) · [Java 23 원본](test-results/2026-11-24-jab-functional-java23.json)

| 요구 항목 | 검사 | 결과 |
|---|---|---|
| 요소 탐색, 정확 일치 Locator | `tree`, `controlInventory`, `buttonLocatorAndLiveMetadata`, `editLocatorAndLiveMetadata` | PASS |
| 중복 이름, 이름 없는 요소 | `ambiguousDuplicate`(AMBIGUOUS_ELEMENT), `unnamedElementByScope` | PASS |
| 잘린·부분 스냅샷, 범위 검색과 범위 스냅샷 | `truncatedSnapshot`, `scopedSnapshot` | PASS |
| Disabled, ReadOnly, 표시되지 않는 컨트롤 | `disabledControl`, `readOnlyControl`, `offscreenControl` | PASS (조작 거부, 픽스처 상태 불변) |
| 비밀번호 마스킹과 입력 | `passwordMetadata`, `passwordSetValue` | PASS (Swing). AWT는 비밀번호 역할이 없고 입력 불가 |
| 버튼 실행, 중복 요청 ID | `invokeAndDuplicateRequest` | PASS (카운터 1 증가, 재전송은 DUPLICATE_COMMAND) |
| 텍스트 입력: 일반, 빈 문자열, 한글, 보충 평면, 최대 길이 | `setValueAndEmpty`, `setValueUnicodeAndLimits` | Swing PASS. 1,024자는 PRECONDITION_FAILED |
| 커스텀 `AccessibleAction` 컴포넌트 | `customAccessibleAction` | PASS |
| 동적 컨트롤 교체 | `replacement` | PASS (옛 참조 STALE_REFERENCE, 새 참조로 실행) |
| 모달 창 | `modalOpenedByApplication`, `optionPane`, `modalOpenedByInvoke` | 앱이 연 모달과 JOptionPane PASS. Swing 버튼이 직접 여는 모달은 제약 |
| JVM 종료와 재시작 | `processExitInvalidatesReference`, `jvmRestart` | PASS |
| 여러 JVM, 서로 다른 버전 | `multipleJvms` (Java 17과 23을 함께 실행) | PASS |
| 다른 PID, 다른 세션, 다른 백엔드의 참조 | `otherProcessDenied`, `otherSessionReference`, `otherBackendReference` | PASS |
| 만료된 참조 | `expiredReference` (121초 대기) | PASS |
| JAB 비활성, DLL 없음, 초기화 실패 | `bridgeNotConnected`, `bridgeLibraryMissing`, `bridgeLibraryInvalid` | PASS |
| 액션 중 응답 없음과 복구, 그 상태에서의 종료 | `modalOpenedByInvoke`의 증거, `exitWhileTargetSilent` | 보고와 복구 PASS. Agent는 41 ms에 종료 코드 0으로 끝났다 |

### 컨트롤별 탐색과 조작

| Swing 컨트롤 | 공통 역할 (JAB 역할) | 탐색 | 조작 |
|---|---|---|---|
| JButton | Button (push button) | 예 | invoke 실행 확인 |
| JTextField, JTextArea | Edit (text) | 예 | setValue 실행 확인(JTextField). JTextArea는 `setValue` 제공까지 확인 |
| JPasswordField | Edit (password text) | 예, 이름 가림 | setValue 실행 확인(길이만 대조) |
| JCheckBox, JRadioButton | CheckBox, RadioButton | 예 | 없음. 토글·선택 API 부재 |
| JComboBox | ComboBox | 예, 팝업 목록 포함 | 없음 |
| JList | List, 항목은 Text (label) | 예 | 없음 |
| JTable | Table, 셀은 Text (label) | 예, 셀 4개와 헤더 | 없음 |
| JTree | Tree, 노드는 Text (label) | 예. 접힌 노드의 자식은 `unknown` | 없음. 하위 노드는 참조 재검증 불가 |
| JTabbedPane | Tab, TabItem | 예. 선택되지 않은 탭의 내용은 `offscreen` | 없음 |
| JMenuBar, JMenu, JMenuItem | MenuBar, MenuItem | 예 | 메뉴 항목은 `invoke`를 제공하나 닫힌 메뉴에서는 `offscreen`이라 거부 |
| JDialog, JOptionPane | Window, 내용은 Custom (alert) | 예, `ownerWindowId` 포함 | 내부 버튼 invoke 실행 확인 |
| JScrollPane | Pane, ScrollBar | 예 | 스크롤바 버튼이 `invoke` 제공(미실행) |
| `AccessibleAction`을 구현한 커스텀 컴포넌트 | Button (push button) | 예 | invoke 실행 확인 |
| 접근성 정보가 없는 커스텀 컴포넌트 | 없음 | 트리에 나타나지 않음 | 불가 |

| AWT 컨트롤 | 공통 역할 (JAB 역할) | 탐색 | 조작 |
|---|---|---|---|
| Button | Button (push button) | 예 | invoke 실행 확인. 모달 열기·닫기 포함 |
| TextField, TextArea | Edit (text) | 예 | `setValue`가 나오지만 실행 불가(Java 쪽 제약) |
| 에코 문자를 쓴 TextField | Edit (text) | 예, 일반 텍스트로 보고됨 | 위와 같음 |
| Checkbox, Choice | CheckBox, ComboBox | 예 | 없음 |
| List | List, ListItem (이름 없음) | 예 | 없음 |
| Panel, Label, Dialog | Pane, Text, Window | 예 | 해당 없음 |
| 접근성 정보가 없는 Component | 없음 | 나타나지 않음 | 불가 |

### 성능

Swing 창 95개 요소, 3개 세션 쌍, 세션당 준비 3회 뒤 20회 반복이다. 값은 세 세션의 p50 범위(ms)다. [원본](test-results/2026-11-24-jab-performance.json)

| 항목 | Java/JNA | C++ |
|---|---|---|
| 프로세스 시작부터 첫 `getCapabilities` 응답 | 570~595 | 253~288 |
| 프로세스 시작부터 첫 스냅샷 완료 | 652~666 | 296~329 |
| snapshot | 38~42 | 34~37 |
| findElement | 0.4~0.6 | 0.2 |
| getElementInfo | 1.7~1.9 | 1.2 |
| setValue | 5.3~6.0 | 4.2~4.5 |
| invoke | 74~76 | 74~75 |
| Private bytes | 61~64 MB | 3.4~3.5 MB |
| Working set | 68~72 MB | 13.5~13.6 MB |
| 핸들, 스레드 | 375, 18 | 186, 2 |

`invoke`의 약 70 ms는 Swing의 `doClick()`이 버튼을 눌린 모습으로 68 ms 동안 보여 주는 시간이다. AWT 버튼은 2~4 ms였다. 브리지 초기화에는 JVM들의 응답을 기다리는 최소 0.2초가 들어 있다. 스냅샷 시간은 대부분 대상 JVM이 이벤트 스레드에서 속성을 읽는 시간이라 두 Agent의 차이가 작다. UIA가 같은 Swing 창에서 2개 요소를 읽는 시간과 비교해 백엔드의 우열을 말할 수는 없다. 읽는 범위가 다르다.

### 반복 안정성

`tools/Test-JabStability.ps1`로 한 세션에서 스냅샷, 검색, 속성 조회, 입력(Swing), 버튼 실행을 반복했다. 15초마다 Agent와 대상 JVM의 리소스를 재고, 대상 JVM의 클래스 히스토그램에서 요청마다 새로 만들어지는 접근성 객체 수를 셌다. Agent가 핸들을 반환하지 않으면 이 수가 반복에 비례해 늘어난다.

| 실행 | 시간 | 반복 | 요청 | 실패 | Agent 핸들 | Agent 스레드 | Agent Private bytes | JVM의 요청별 접근성 객체 |
|---|---|---|---|---|---|---|---|---|
| Java/JNA, Swing | 600초 | 2,209 | 13,258 | 0 | 374~376 | 18~20 | 61.9~76.8 MB, 끝 61.9 MB | 9로 일정, 세션 종료 후 0 |
| C++, Swing | 600초 | 2,954 | 17,728 | 0 | 185~187 | 2~5 | 3.4~4.5 MB, 끝 4.0 MB | 9로 일정, 세션 종료 후 0 |
| Java/JNA, AWT | 300초 | 4,042 | 16,171 | 0 | 374~376 | 19~20 | 62.2~76.7 MB, 끝 63.1 MB | 2로 일정, 세션 종료 후 0 |
| C++, AWT | 300초 | 4,481 | 17,928 | 0 | 185~187 | 2~4 | 3.2~4.4 MB, 끝 3.4 MB | 2로 일정, 세션 종료 후 0 |

- 한 세션은 명령 4,096개까지만 보내므로 Swing 실행은 세션을 한 번 바꿨다.
- 대상 JVM의 핸들 수는 정착 뒤 514~526(Swing), 484~494(AWT) 안에 머물렀다.
- **응답 없는 JVM에서의 복구(Swing).** 모달을 여는 클릭이 8.0초 뒤 `ACTION_OUTCOME_UNKNOWN`, 열린 동안의 요청이 약 1 ms에 `TARGET_NOT_RESPONDING`이었고, 모달이 닫힌 뒤 같은 세션에서 10회 반복이 모두 성공했다.
- **Agent 시작·종료 10회.** 시작부터 첫 스냅샷까지 p50이 Java/JNA 0.70초, C++ 0.36초였다. 종료는 35 ms, 10 ms였다. 대상 JVM의 핸들 수는 10회 전후로 같았다(518→518, 520→520).
- **대상 JVM 재시작 3회.** 열려 있던 세션이 새 JVM의 창을 9~86 ms 안에 발견했다. Agent의 핸들과 스레드 수는 변하지 않았다.
- 이 10분 실행의 지연은 위 성능 표보다 높다(스냅샷 p50이 Java/JNA 100 ms, C++ 81 ms). 같은 시간에 PC를 다른 작업에 쓰고 있었다.

1시간 이상의 연속 시험은 하지 않았다. 위 결과는 5~10분 범위의 것이다. [Java/JNA Swing](test-results/2026-11-24-jab-stability-java-swing.json) · [C++ Swing](test-results/2026-11-24-jab-stability-cpp-swing.json) · [Java/JNA AWT](test-results/2026-11-24-jab-stability-java-awt.json) · [C++ AWT](test-results/2026-11-24-jab-stability-cpp-awt.json)

### 기존 UIA 기능의 회귀

JAB를 넣은 뒤 같은 명령으로 UIA 회귀를 다시 돌렸다. 256개 검사 중 PASS 214, FAIL 32(`UIA_PROVIDER_LIMITATION` 14, `JAB_ONLY` 18), NOT_RUN 10으로 2026-11-24의 이전 결과와 검사 단위까지 같다. 여섯 프레임워크의 Java/JNA와 C++ 트리 비교도 모두 통과했다. [원본](test-results/2026-11-24-jab-uia-regression.json)

| 프레임워크 | Java/JNA | C++ |
|---|---|---|
| Win32 x64 | 22/22 | 22/22 |
| WPF Extended | 24/24 | 24/24 |
| WinForms .NET 9 | 21/21 | 21/21 |
| WinForms .NET Framework | 19/23 | 19/23 |
| AWT (UIA) | 15/19 | 15/19 |
| Swing (UIA) | 6/19 | 6/19 |
| Win32 x86 픽스처 | 22/22 | 22/22, x86 Agent도 22/22 |
| MFC x64 | 21/21 | 21/21 |
| Delphi VCL | NOT_RUN | NOT_RUN |

단위 테스트는 Java 83개 중 79개 실행·통과(나머지 4개는 GUI 통합 테스트), C++ 코어 테스트는 x64와 x86에서 통과했다. Java GUI 통합 테스트는 PowerShell과 JNA 백엔드 2개가 통과했고 C# 워커가 필요한 2개는 워커가 빌드돼 있지 않아 건너뛰었다.

## Java/JNA와 C++ 구현 비교

| 기준 | Java/JNA | C++ |
|---|---|---|
| 기능 판정 | 모든 검사에서 C++와 같음 | 모든 검사에서 Java와 같음 |
| Adapter 코드 | `JabBridge` 451줄, `JabSession` 487줄, `JabApi` 40줄 | `jab_adapter.cpp` 903줄 |
| 세션 규칙의 단위 테스트 | 각본 브리지로 17개(핸들 반환 횟수, 참조 무효화, 보류 반환 포함) | 코어 계약 테스트만. Adapter는 실제 GUI 회귀로만 검증 |
| 첫 스냅샷까지 | 약 0.65초 | 약 0.3초 |
| 메모리 | Private 61~64 MB | Private 3.4 MB |
| 요청 지연 | 스냅샷 38~42 ms | 스냅샷 34~37 ms |
| 브리지 DLL | Agent를 실행하는 JDK/JRE의 `bin`에 들어 있으면 추가 설치가 없다 | 대상 PC의 System32나 등록된 Java 설치에 있어야 한다. 없으면 `--jab-dll`로 지정한다 |
| 리소스 관리 | 명시적 반환 목록. GC에 의존하지 않는다 | RAII와 명시적 반환 목록 |

기능과 안전 규칙에서는 두 구현이 같았고, 요청 지연의 차이는 대상 JVM 쪽 시간에 묻힌다. 차이는 기동 시간과 메모리, 그리고 배포 조건이다. JAB 연동 자체는 어느 쪽으로도 할 수 있다는 것이 측정 결과다.

비용은 중복이다. 역할 표, invoke 규칙, 참조 검증, 보류 반환, 응답 시간 판정이 두 언어로 한 번씩 쓰였다. 이번에는 Java 구현을 먼저 만들어 문제(시간 초과 뒤의 거짓 성공, 모달 대기, 종료 시 대기)를 찾고 C++로 옮겼다. C++ 구현만 있었다면 같은 문제를 실제 GUI 회귀로만 잡아야 했다. 따라서 JAB의 기준 구현은 단위 테스트가 가능한 Java/JNA로 두고, C++는 JVM을 둘 수 없거나 메모리 예산이 좁은 PC를 위한 동등 구현으로 유지하는 것을 권한다. 두 구현을 같은 회귀(`-Backend BothJab`)로 묶어 두면 한쪽만 바뀌는 일을 막을 수 있다.

## UIA와 JAB의 공존

> 이 절은 JAB Adapter를 처음 넣었을 때의 기록이다. 그 뒤 `--backend multi`로 두 백엔드를 한 세션에서 쓰는 구조를 구현했다. 아래 표의 규칙은 그 구현에 그대로 반영됐다. [Multi-Backend](MULTI-BACKEND.md)

JAB Adapter를 넣은 시점에는 세션 하나가 백엔드 하나를 썼다. Java 창은 `--backend jab` 세션에서, 나머지는 UIA 세션에서 다뤘다. 각 백엔드가 같은 계약을 따로 통과하는지 먼저 확인하는 것이 그때의 범위였다.

같은 창을 두 백엔드로 열었을 때 실제로 본 것:

| 문제 | 관찰 | 처리 또는 다음 설계의 규칙 |
|---|---|---|
| 같은 HWND에 두 백엔드 | `windowId`는 같다. UIA는 Swing 창에서 창 틀만, AWT 창에서 네이티브 피어를 본다. JAB는 둘 다 접근성 컨텍스트로 본다. | 창마다 스냅샷을 만든 백엔드를 하나로 고정한다. |
| 요소 중복 | AWT 버튼은 UIA 트리와 JAB 트리에 각각 다른 모델로 나온다. 둘을 이어 주는 식별자가 없고 좌표만 겹친다. | 두 트리를 합치지 않는다. 좌표로 짝을 맞추지 않는다. |
| 트리 모양 | UIA는 HWND 계층, JAB는 Java 컴포넌트 계층이다. 부모 경로가 서로 다르다. | Locator의 `scopeRef`는 같은 스냅샷 안에서만 쓴다. |
| Locator | UIA는 `automationId`와 `className`, JAB는 `name`과 `role`에 의존한다. | 저장하는 Locator에 백엔드를 함께 적는다. |
| 참조 | 다른 세션, 다른 백엔드의 참조는 `STALE_REFERENCE`다(검증함). | 백엔드를 바꾸면 스냅샷부터 다시 받는다. |
| 브리지 미연결 | `BRIDGE_NOT_CONNECTED`와 `bridge.javaWindows > connectedWindows`. | UIA 결과로 대신 답하지 않는다. 사유를 그대로 돌려준다. |
| 액션 차이 | AWT 버튼: UIA는 반환만 하고 무반응, JAB는 실행됨. AWT 텍스트: UIA는 입력됨, JAB는 불가. Swing: JAB만 가능. | 변경은 그 요소의 참조를 발급한 백엔드로만 보낸다. 실패해도 다른 백엔드로 다시 보내지 않는다. |

AWT 설비 화면은 버튼은 JAB, 텍스트 입력은 UIA가 필요한 실제 사례다. 지금은 두 세션을 각각 열어야 한다. Router를 만든다면 읽기 전용 탐색부터 넣는다. `listWindows` 행에 쓸 수 있는 백엔드를 표시하고, `snapshot`이 백엔드를 명시적으로 받으며, 스냅샷과 참조가 자신을 만든 백엔드를 기억하게 한다. 변경 요청의 자동 전환은 넣지 않는다.

## 구형 Java 설비 프로그램

이 PC에서 확인한 것은 Java 17과 23의 64비트 JVM뿐이다. 구형 설비에 적용하려면 다음을 실제 조합으로 확인해야 한다.

1. **브리지를 켤 수 있는가.** 설비 프로그램의 실행 스크립트나 사용자 프로필을 고칠 권한이 있어야 한다. Agent는 이를 대신하지 않는다. 운영 중인 JVM은 다시 시작해야 브리지가 붙는다.
2. **JRE에 브리지가 있는가.** Java SE 7 Update 6 이전의 JRE에는 브리지가 들어 있지 않아 Java Access Bridge 2.0.x를 따로 설치해야 한다. 그 이후 JRE는 `bin`에 DLL이 있다.
3. **비트수.** 64비트 Agent는 `WindowsAccessBridge-64.dll`을, 32비트 Agent는 `-32.dll`을 쓴다. 32비트 JVM만 있는 설비에서 어느 조합이 통하는지는 미실행이다. 객체 핸들이 32비트인 구형 `WindowsAccessBridge.dll` ABI는 두 Agent 모두 지원하지 않는다.
4. **브리지 API 범위.** 두 Agent는 Java Access Bridge 2.0에서 추가된 `setTextContents`와 액션 함수를 요구한다. 없으면 백엔드 전체를 쓰지 않고 빠진 함수 이름을 보고한다.
5. **Agent를 어디서 돌리는가.** 대상이 Java 6 프로그램이어도 Agent는 Java 11 이상(JNA) 또는 C++ 실행 파일이다. Windows XP나 7에서 이 Agent들이 실행되는지는 별개의 미검증 항목이다. 대상 JVM에 접근할 수 있다는 결과를 구형 OS에서 Agent가 돈다는 뜻으로 읽으면 안 된다.
6. **Java 쪽 동작 차이.** 모달 버튼의 대기와 AWT 텍스트 입력은 JDK 17 소스로 확인했다. 구형 JDK의 브리지 구현이 같은지는 확인하지 않았다.

## MSAA Adapter 검토

아래는 MSAA 구현 전의 직접 관측 기록이다. 현재 Adapter는 관측된 위치 기반 요소에 약한 조회 전용 참조를 제공한다. [MSAA Adapter의 지원 범위와 검증 결과](MSAA-ADAPTER.md)

.NET Framework WinForms의 목록 항목, 탭, DataGridView 행·셀에는 UIA가 쓸 수 있는 Runtime ID를 주지 않는다. 같은 픽스처를 MSAA(`oleacc.dll`의 `IAccessible`)로 직접 읽어 보았다. 도구는 [`tools/Probe-MsaaChildren.ps1`](../tools/Probe-MsaaChildren.ps1)이고 UI Automation과 Agent를 거치지 않는다.

| 컨트롤 | MSAA에 보이는 것 | 동일성 | 조작 |
|---|---|---|---|
| ListBox 항목 3개 | 역할 list item, 이름 있음 | 단순 요소. 부모 창과 자식 번호(위치)뿐이다. | `accSelect`가 반환했으나 앱의 `SelectedIndexChanged` 처리기는 실행되지 않았다. |
| TabControl 탭 3개 | 역할 page tab, 기본 동작 "전환" | 단순 요소. 위치뿐이다. | `accDoDefaultAction`으로 둘째 페이지가 보이게 됐다. |
| DataGridView 행 2,002개 | 역할 row, 이름 있음, 행마다 자식 3개 | COM 객체. 식별 인터페이스(`IAccIdentity`)가 없고 같은 행을 두 번 받으면 서로 다른 객체다. | 미실행 |

MSAA는 UIA가 참조를 주지 못한 요소를 보여 준다. 그러나 **위치보다 강한 동일성을 제공하지 않는다.** 이 프로젝트는 자식 번호나 이름이 같다는 이유로 같은 요소라고 판단하지 않는다는 원칙을 갖고 있고, JAB Adapter도 그렇게 만들었다. MSAA Adapter는 이 원칙을 그대로 지키면 참조를 발급할 수 없다. 목록 선택에서는 호출이 반환해도 앱이 반응하지 않는 사례도 나왔다.

따라서 다음 단계에서 MSAA Adapter를 바로 구현하기보다 먼저 정할 것이 있다. 위치로만 식별되는 요소에 "약한 참조"를 허용할지, 허용한다면 어떤 재검증(부모 HWND, 자식 수, 이름, 역할)과 어떤 표시를 붙일지다. MFC 픽스처에서는 UIA만으로 모든 요소를 읽어 MSAA가 필요한 사례가 나오지 않았다. Delphi VCL은 픽스처를 실행하지 못해 확인하지 못했다. 이 두 가지가 정해지면 범위를 다음과 같이 제안한다. 읽기 전용 탐색, 위치 기반 참조의 명시적 표시, 기본 동작(`accDoDefaultAction`)과 선택(`accSelect`)을 별도 액션으로 추가, 조작 후 앱 상태 확인 절차.

## MFC와 Delphi VCL

MFC는 사용자 승인을 받아 Visual Studio Installer로 `Microsoft.VisualStudio.Component.VC.ATLMFC`를 설치한 뒤 실행했다. Delphi VCL은 실행하지 못했고 다른 프레임워크로 대체하지 않았다.

| 대상 | 상태 | 확인한 것 | 필요한 조치 |
|---|---|---|---|
| MFC x64 (UIA 백엔드) | 두 Agent 21/21 | 대화상자 픽스처 79개 요소, 트리 일치. 버튼, 편집, owner-drawn 버튼, 교체, 10,000행 가상 목록의 제한 표시, 모달을 통과했다. | x86 MFC 빌드와 메뉴는 미실행 |
| Delphi VCL | `NOT_RUN` | `dcc32`, `dcc64`, `bds`가 없고 Embarcadero·Borland 설치 흔적이 없다. | 라이선스가 있는 Delphi(Win32 컴파일러, VCL, DataSnap/MIDAS) 설치. 빌드 절차는 [픽스처 README](../tests/fixtures/delphi-vcl/README.md)에 있다. |

MFC의 첫 실행은 18/21이었다. 원인은 픽스처였다. 모달의 결과(`canceled`)를 `modal.txt`에 썼는데, Win32 픽스처와 검사는 결과를 `modal-result.txt`에, 닫힘을 `modal.txt=closed`로 쓴다. Agent는 모달을 열고, 창 목록에서 찾고, 자체 스냅샷으로 닫는 데까지 성공한 상태였다. 픽스처를 같은 규약으로 고친 뒤 21/21이 됐다. [원본](test-results/2026-11-24-jab-uia-mfc.json)

회귀 검사는 대화상자만 다룬다. SDI 프레임, MDI 프레임, Property Sheet는 픽스처의 버튼을 Invoke로 눌러 열고 두 Agent로 따로 캡처했다. 결과는 두 Agent가 같다. [원본](test-results/2026-11-24-jab-uia-mfc-frames.json)

| 창 | 창 목록 | 스냅샷 |
|---|---|---|
| SDI 프레임 (`AfxFrameOrView140su`) | 소유자 없는 창으로 나열 | 3개 요소: Window, Edit, TitleBar |
| MDI 프레임 (`AfxMDIFrame140su`) | 소유자 없는 창으로 나열 | 9개 요소: 프레임과 자식 문서 창 2개(각각 Window와 Edit) |
| Property Sheet (`#32770`) | `ownerWindowId`가 있는 소유 창으로 나열 | 10개 요소: Tab과 TabItem 2개(General, Advanced), 버튼 3개, Edit |

이 픽스처에서 UIA만으로 읽지 못한 요소는 없었다. MFC에서 MSAA가 필요한 사례는 이 범위에서는 나오지 않았다. 탭 선택과 메뉴는 API에 액션이 없어 조작하지 않았다.

설치와 재현 명령:

```powershell
& "C:\Program Files (x86)\Microsoft Visual Studio\Installer\setup.exe" modify `
    --installPath "C:\Program Files (x86)\Microsoft Visual Studio\2022\BuildTools" `
    --add Microsoft.VisualStudio.Component.VC.ATLMFC --quiet --norestart
cmake -S tests/fixtures/mfc -B target/framework-fixtures/build-mfc -G "Visual Studio 17 2022" -A x64
cmake --build target/framework-fixtures/build-mfc --config Release
& ./tools/Test-UiaFrameworks.ps1 -Framework Mfc -Backend Both -DiagnoseAccessibility -OutputPath target/uia-mfc.json
```

## 남은 제약과 위험

- **모달을 여는 Swing 버튼.** 리스너가 모달을 직접 여는 버튼은 JAB만으로 다음 단계로 넘어갈 수 없다. 확인·경고 대화상자가 많은 설비 화면에서는 가장 큰 제약이다. 앱이 `invokeLater`로 대화상자를 열도록 고치거나, 명시적으로 허용한 입력 Adapter가 있어야 한다.
- **메뉴, 탭, 체크박스, 콤보, 트리.** 읽을 수 있지만 선택·토글·펼치기 액션이 API에 없다. 닫힌 메뉴의 항목과 선택되지 않은 탭의 내용은 `offscreen`이라 조작을 거부한다.
- **AWT 텍스트 입력.** JAB로는 불가능하다. UIA 세션이 필요하다.
- **이름 정책.** JAB는 텍스트 필드의 이름(라벨)을 내보낸다. UIA 백엔드보다 느슨하다. 앱이 접근성 이름에 업무 데이터를 넣는 경우를 배제하지 못한다.
- **한 JVM이 멈추면 전체가 기다린다.** 브리지 DLL의 구조 때문에, 알고 있는 JVM 하나가 응답하지 않으면 다른 JVM을 향한 요청도 `TARGET_NOT_RESPONDING`이 된다. 한 번도 만난 적 없는 JVM이 멈춰 있으면 조회가 수 초씩 걸려 10초 기한에 걸릴 수 있다.
- **응답 판정이 시간에 의존한다.** 3.5초를 넘긴 브리지 호출은 결과를 버린다. 정상이지만 오래 걸린 조작도 `ACTION_OUTCOME_UNKNOWN`이 된다.
- **Agent가 비정상 종료하면** 반환하지 못한 참조와 공유 메모리 매핑이 대상 JVM에 남는다.
- **요청마다 새로 만들어지는 객체**(트리의 하위 노드 등)를 부모로 둔 요소는 재검증할 수 없어 참조를 쓸 수 없다.
- **검증 범위.** Windows 11 x64, Java 17과 23의 64비트 JVM, 픽스처 하나뿐이다. 실제 설비 프로그램, 서드파티 Swing 컴포넌트, 수천 행의 표, 구형 JVM, 32비트, RDP 세션은 미실행이다. Java 21은 설치돼 있지 않아 23으로 대신 확인했고 21 자체는 `NOT_RUN`이다.
- **`effectVerified`는 항상 false다.** 후조건 확인은 호출자의 몫이다.

## 다음 우선순위

1. 실제 설비 Java 프로그램 한 종에서 브리지 활성 가능 여부, JRE 버전과 비트수, 서드파티 컴포넌트의 접근성 구현을 조사한다. 가능한 가장 낮은 버전의 JVM(Java 8 x86 우선)에서 같은 회귀를 돌린다.
2. 모달을 여는 Swing 버튼의 처리 방침을 정한다. 앱 수정 가이드, 또는 명시적 허용과 capability를 가진 별도 입력 Adapter 중 하나다.
3. 선택·토글·펼치기 액션을 API에 추가한다(탭, 체크박스, 콤보, 메뉴, 트리). JAB는 접근성 액션과 선택 인터페이스로 지원할 수 있다.
4. ~~UIA와 JAB를 함께 여는 읽기 전용 Router를 만든다.~~ `--backend multi`로 구현했다. 변경 요청도 참조를 발급한 백엔드로 전달한다. [Multi-Backend](MULTI-BACKEND.md)
5. Delphi 환경을 확보해 VCL 픽스처를 검증한다. MFC는 x86 빌드와 메뉴를 추가로 본다.
6. MSAA의 위치 기반 참조 정책을 정한 뒤 Adapter 범위를 확정한다.
7. 1시간 이상 연속 시험과 대량 요소 화면의 성능을 측정한다.

## 구현 위치와 재현

- Java [`JabBridge`](../src/main/java/dev/desktop/JabBridge.java) · [`JabSession`](../src/main/java/dev/desktop/JabSession.java) · [`JabApi`](../src/main/java/dev/desktop/JabApi.java) · [`JnaDesktopAdapter`](../src/main/java/dev/desktop/JnaDesktopAdapter.java) · 테스트 [`JabSessionTest`](../src/test/java/dev/desktop/JabSessionTest.java), [`JabBridgeTest`](../src/test/java/dev/desktop/JabBridgeTest.java)
- C++ [`jab_adapter.cpp`](../native/cpp-agent/src/windows/jab_adapter.cpp) · [`main.cpp`](../native/cpp-agent/src/main.cpp) · 테스트 [`core_test.cpp`](../native/cpp-agent/tests/core_test.cpp)
- 회귀 [`Test-UiaFrameworks.ps1`](../tools/Test-UiaFrameworks.ps1) · [`JabFrameworkCases.ps1`](../tools/JabFrameworkCases.ps1) · [`Test-JabRegression.ps1`](../tools/tests/Test-JabRegression.ps1) · [`Test-JabStability.ps1`](../tools/Test-JabStability.ps1) · [`Probe-MsaaChildren.ps1`](../tools/Probe-MsaaChildren.ps1)
- 픽스처 [`FrameworkFixture.java`](../tests/fixtures/swing-awt/FrameworkFixture.java). 메뉴, 텍스트 영역, 라디오 버튼, 옵션 창, 앱이 스스로 여는 모달, 탭 선택 명령을 추가했다.
- 원인 실험과 환경 조사 기록 [`2026-11-24-jab-investigation.json`](test-results/2026-11-24-jab-investigation.json)

시험 대상 커밋은 기능·성능이 `b3d435f`(Java 23, 성능)와 `4f9ec1f`(Java 17, UIA 회귀), 안정성이 `c8cc191`(Java/JNA AWT만 `4f9ec1f`)이다. 뒤의 두 커밋은 픽스처와 측정 스크립트만 고쳤고 Agent 코드는 `b3d435f`와 같다. 각 JSON의 `environment.git`에 커밋과 작업 트리 상태가 있다.

잠금 해제된 Windows 대화형 세션의 저장소 루트에서 실행한다. JDK의 `bin`이 `PATH`에 있어야 한다. `-FixtureJava`로 대상 GUI JVM을, `-SecondFixtureJava`로 여러 JVM 검사에 쓸 두 번째 런타임을 지정한다.

```powershell
mvn clean verify
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
New-Item -ItemType Directory -Force target/framework-fixtures/swing-awt | Out-Null
javac -Xlint:all -d target/framework-fixtures/swing-awt tests/fixtures/swing-awt/FrameworkFixture.java

& ./tools/Test-UiaFrameworks.ps1 -Framework Swing,Awt -Backend BothJab -SecondFixtureJava C:\path\to\other\java.exe -IncludeExpiry -OutputPath target/jab-functional.json
& ./tools/tests/Test-JabRegression.ps1 -ReportPath target/jab-functional.json -RequireBothBackends
& ./tools/Test-UiaFrameworks.ps1 -Framework Swing -Backend BothJab -Mode Performance -Pairs 3 -Iterations 20 -Warmup 3 -OutputPath target/jab-performance.json
& ./tools/Test-JabStability.ps1 -Backend Jab -Framework Swing -DurationSeconds 600 -OutputPath target/jab-stability-java-swing.json
& ./tools/Test-JabStability.ps1 -Backend CppJab -Framework Swing -DurationSeconds 600 -OutputPath target/jab-stability-cpp-swing.json
```

`-Backend Jab`은 Java/JNA Agent, `CppJab`은 C++ Agent, `BothJab`은 둘 다를 JAB 백엔드로 실행한다. 이 백엔드들은 픽스처 JVM에만 브리지 옵션을 붙이며 사용자나 시스템 설정을 바꾸지 않는다. `Test-JabRegression.ps1`은 통과하지 못한 검사가 실측 증거가 있는 Java 쪽 제약뿐인지, 두 Agent의 판정과 트리가 같은지 확인한다.
