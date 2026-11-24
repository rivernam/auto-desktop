# Multi-Backend Agent

현재 Java와 C++의 `--backend multi`는 UIA, JAB, MSAA를 열며 기본 Snapshot은 UIA다. 아래 UIA/JAB 검증은 MSAA 추가 전 기록이다. [MSAA 참조 정책 및 세 백엔드 검증](MSAA-ADAPTER.md)

AWT 화면은 버튼을 누르려면 Java Access Bridge(JAB)가, 텍스트를 넣으려면 UI Automation(UIA)이 필요하다. 지금까지는 백엔드마다 Agent를 따로 띄워야 했다. `--backend multi`는 두 백엔드를 한 Agent 프로세스의 한 세션에 올린다. Java/JNA Agent와 C++ Agent에 모두 구현했고, 2026-11-24에 Windows 11에서 실제 GUI로 검증했다. 요청 형식은 [API](API.md#여러-백엔드를-한-세션에서-쓰기)에 있다.

## 요약

| 항목 | 결과 |
|---|---|
| 구현 | Java/JNA와 C++ 두 Agent. `--backend multi`를 명시해야 선택된다. 기존 옵션과 기본값, 단일 백엔드 응답 형식은 그대로다. |
| AWT 혼합 자동화 | 한 Agent 프로세스가 같은 AWT 창에서 UIA로 텍스트를 넣고, JAB로 버튼을 누르고 모달을 열고 닫은 뒤, UIA로 다시 텍스트를 넣었다. 두 Agent 모두 11/11, 결과는 픽스처 상태 파일로 판정했다. |
| JAB 장애 뒤 UIA | Swing 버튼이 모달을 열어 JAB가 응답하지 않는 동안, 같은 Agent가 WPF 창을 UIA로 읽고 값을 넣고 버튼을 눌렀다. 모달을 닫자 장애 전의 JAB 참조가 다시 동작했다. |
| UIA 장애 뒤 JAB | WPF 프로세스를 일시 중지해 UIA가 10초 기한을 넘기게 했다(Fault Injection). 그동안 JAB는 장애 전의 참조로 AWT 버튼을 눌렀다. 프로세스를 재개하자 UIA가 같은 Agent 프로세스 안에서 약 0.7초 뒤 다시 동작했다. |
| JVM 간 격리 | **격리되지 않는다.** 한 JVM이 응답하지 않으면 다른 JVM을 향한 JAB 요청도 `TARGET_NOT_RESPONDING`이다. 브리지 구조에서 오는 기존 제약이다. 그 JVM의 창이 AWT라면 텍스트는 UIA로 계속 넣을 수 있었다. |
| 최종 기능 실행 | 6개 시나리오, Agent당 42개 검사, 합계 84/84 PASS. 두 Agent의 판정이 모든 검사에서 같다. |
| 그 전의 두 실행 | 각각 2개, 3개 검사가 실패했다. 재현되지 않았고 PC를 사람이 쓰던 시간대와 겹친다. 원인을 확정하지 못한 항목은 [아래](#통과하지-못한-두-번의-실행)에 따로 적었다. |
| 발견해 고친 문제 | Multi 모드의 `listWindows`가 약 1초 걸렸다. UIA가 JAB의 숨은 창에 보낸 메시지가 250 ms 주기로만 처리됐기 때문이다. 다른 백엔드의 요청이 도는 동안 메시지를 즉시 처리하게 했고, 이제 UIA 단독보다 4~5 ms 길다. |
| 단일 백엔드 회귀 | UIA 256/298(이전과 검사 단위까지 같음), JAB 120/128(이전과 같음). 통과하지 못한 검사는 이전과 같은 Provider 제약이다. |
| 10분 혼합 반복 | Java/JNA 2,989회, C++ 3,050회. 요청 20,024건과 20,439건 모두 OK. 핸들·스레드·JVM 안의 참조가 일정했다. 명령 한도 때문에 각각 세션을 한 번 교체했다. |
| 미실행 | 32비트 Agent의 multi 모드, Java 8·11·21 대상 JVM, 1시간 이상 연속 시험, 다중 모니터·RDP, 실제 설비 프로그램. |

## 구조

```text
로컬 클라이언트 ─ UTF-8 NDJSON(요청 하나에 응답 하나, 순서대로) ─ Cli / main.cpp
                                   │
                 세션: 명령 ID 기록, PID·액션 허용 정책 (세션 전체에 하나)
                                   │ 라우팅: snapshot.backend, 참조를 발급한 백엔드
          ┌────────────────────────┴────────────────────────┐
   백엔드 "UIA" (기본)                                백엔드 "JAB"
   전용 MTA 스레드, COM 세션                          전용 스레드, 브리지 DLL과 숨은 창
   최신 스냅샷 하나와 그 참조                         최신 스냅샷 하나와 그 참조
   장애 상태, 다시 만들기 가능                        장애 상태, 다시 만들지 않음
```

백엔드마다 따로 갖는 것과 세션이 하나만 갖는 것은 다음과 같다.

| 구분 | 백엔드마다 | 세션에 하나 |
|---|---|---|
| 실행 | Adapter, 전용 스레드, 10초 요청 기한 | 요청을 한 번에 하나씩 받는 순서 |
| 리소스 | COM 포인터 또는 JVM 안의 참조, 브리지 DLL | 없음 |
| 스냅샷 | 최신 스냅샷 하나, 120초 만료, 공개 ref | 없음. 트리를 합치지 않는다 |
| 장애 | 응답 없음·기한 초과·폐기 상태, capability의 사유 | 없음 |
| 정책 | 조작 직전의 대상 재검증 | 허용 PID와 프로세스 시작 시각, 허용 액션, 명령 ID 기록(4,096개) |

두 Agent의 배치는 다르다. 계약은 같다.

| | Java/JNA | C++ |
|---|---|---|
| 세션 | [`Agent`](../src/main/java/dev/desktop/Agent.java)가 백엔드 목록을 직접 갖는다. 단일 백엔드 세션은 항목이 하나인 같은 코드다. | [`MultiSession`](../native/cpp-agent/src/core/multi_session.cpp)이 백엔드마다 기존 `SessionWorker`(스레드, `Agent`, Adapter) 하나를 둔다. 단일 백엔드 실행은 `SessionWorker`를 그대로 쓴다. |
| 참조의 소유자 찾기 | 각 백엔드의 현재 스냅샷에서 ref를 찾는다. ref는 UUID다. | ref와 snapshotId의 접두사(`세션.백엔드.세대-`)로 가린다. |
| 명령 ID | `ActionDispatcher` 하나 | 모든 워커가 같은 `CommandHistory`를 쓴다 |
| 백엔드 목록 | [`DesktopAdapters.multi()`](../src/main/java/dev/desktop/DesktopAdapters.java) | [`main.cpp`](../native/cpp-agent/src/main.cpp)의 `MultiSession::Backend` 목록 |

새 Adapter(예: MSAA)는 이 목록에 이름과 생성 함수를 하나 더하는 것으로 들어간다. 라우팅, 스냅샷 분리, 명령 ID, 장애 처리는 이름에 의존하지 않는다. `getCapabilities`의 `backends`와 `listWindows`의 `backends`는 배열이라 항목이 늘어도 형식이 바뀌지 않는다.

### 라우팅 규칙

| 요청 | 가는 곳 |
|---|---|
| `getCapabilities` | 모든 백엔드. 결과는 백엔드별 행으로 모은다. 실패한 백엔드는 `available=false`와 사유가 된다. |
| `listWindows` | 모든 백엔드. `windowId`와 `processId`가 같은 행을 하나로 합치고 나열한 백엔드를 적는다. 일부가 실패하면 나머지 결과와 함께 실패한 백엔드의 오류 코드를 돌려준다. |
| `snapshot` | `backend`가 가리키는 백엔드. 없으면 기본 백엔드(UIA). `scopeRef`가 있으면 그 참조를 발급한 백엔드. |
| `findElement` | `snapshotId`를 발급한 백엔드의 그 스냅샷. Adapter를 부르지 않는다. |
| `getElementInfo` 및 모든 변경 명령 | `ref`를 발급한 백엔드. 다른 백엔드로 가는 경로는 없다. |

기본 백엔드를 UIA로 둔 것은 단일 백엔드 클라이언트가 `--backend multi`에서 고치지 않고 돌게 하기 위해서다. 읽기 요청에만 적용되는 기본값이고, 변경 요청은 언제나 참조가 정한다.

`listWindows`의 백엔드별 상태를 `result` 안이 아니라 응답의 최상위에 둔 것도 같은 이유다. `result`는 모든 모드에서 창 배열이다.

## 격리 범위

### 백엔드 사이

| 상황 | 그 백엔드 | 다른 백엔드 |
|---|---|---|
| 대상 JVM이 브리지 요청에 답하지 않음 (Swing 모달 등) | JAB 요청은 `TARGET_NOT_RESPONDING`, 보낸 조작은 `ACTION_OUTCOME_UNKNOWN`. 세션과 참조는 유지되고 JVM이 돌아오면 그대로 쓴다. | UIA의 요청과 참조에 영향 없음 |
| 한 요청이 10초 기한을 넘김 | 그 Adapter를 폐기한다. 이후 요청은 `BACKEND_UNAVAILABLE`, capability에 사유가 나온다. | 영향 없음. 참조도 그대로 |
| 스냅샷 요청 실패 | 그 백엔드의 이전 참조가 폐기된다(기존 규칙). | 영향 없음 |
| 브리지 DLL 없음, JVM이 브리지를 켜지 않음 | JAB만 `available=false` 또는 `BRIDGE_NOT_CONNECTED` | UIA는 정상 |
| 대상 프로세스 종료 | 그 창의 참조가 두 백엔드 모두에서 `STALE_REFERENCE`, 창은 `WINDOW_NOT_FOUND` | 다른 창의 참조는 그대로 |

**다시 만들기.** 폐기된 UIA 백엔드는 멈췄던 호출이 반환해 스레드가 COM 자원을 놓은 뒤, 그 백엔드를 향한 다음 요청에서 새로 만들어진다. Agent를 다시 시작하지 않으므로 JAB 참조와 명령 ID 기록이 남는다. 폐기된 세션의 UIA 참조는 새 세션에 닿지 않는다(Java는 새 UUID, C++는 세대가 든 접두사). 멈춘 호출이 끝나지 않는 동안에는 다시 만들지 않고 `BACKEND_UNAVAILABLE`을 돌려준다.

JAB 백엔드는 다시 만들지 않는다. 폐기된 브리지 세션은 응답 없는 JVM 때문에 DLL을 내리지 못한 채 남았을 수 있고, 같은 프로세스에서 `Windows_run`을 다시 부르는 것은 검증하지 않았다. 이 경우 JAB는 Agent를 다시 시작할 때까지 `available=false`이고 UIA는 계속 동작한다. JAB가 폐기되는 것은 요청이 10초를 넘겼을 때뿐이다. JVM 무응답은 폐기 사유가 아니다.

### JVM 사이

JVM 간 격리는 백엔드 간 격리와 다른 문제이고, **이번 구현으로 달라지지 않았다.** 브리지 DLL은 창 하나를 물을 때 연결된 모든 JVM에 차례로 묻고 응답 없는 JVM을 몇 초씩 기다린다. 그래서 JAB Adapter는 아는 JVM 하나가 답하지 않으면 다른 JVM을 향한 요청도 바로 `TARGET_NOT_RESPONDING`으로 끝낸다. 실측에서 Java 17 Swing JVM이 모달로 멈춘 동안 Java 23 AWT JVM의 JAB 스냅샷은 1 ms 만에 `TARGET_NOT_RESPONDING`이었다(두 Agent 동일).

Multi 모드가 주는 것은 우회로다. 멈추지 않은 JVM의 창이 AWT면 UIA 백엔드는 그 네이티브 컨트롤을 계속 읽고 쓴다. 같은 상황에서 AWT 텍스트 입력은 성공했다. Swing 창은 UIA에 창 틀만 보이므로 우회로가 없다.

### 같은 프로세스 안의 창 메시지

Multi 모드에서만 생기는 간섭이 하나 있었다. UIA는 창 목록을 만들 때 최상위 창을 모두 방문하고, 그 안에는 브리지 DLL이 Agent 프로세스의 JAB 스레드에 만든 숨은 창이 있다. JAB 스레드는 요청이 없으면 250 ms마다 메시지를 처리하므로 UIA 호출이 그 주기를 기다렸다.

| `listWindows` p50 | UIA 단독 | JAB 단독 | Multi, 고치기 전 | Multi, 고친 뒤 |
|---|---:|---:|---:|---:|
| Java/JNA | 61 ms | 6 ms | 956 ms | 73 ms |
| C++ | 51 ms | 5 ms | 1,066 ms | 66 ms |

같은 PC에서 몇 분 간격으로 1쌍·6회씩 잰 값이다([고치기 전](test-results/2026-11-24-multi-backend-performance-before-message-service.json), [고친 뒤](test-results/2026-11-24-multi-backend-performance-after-message-service.json)). 고치기 전의 3쌍·20회 실행에서도 1,107 ms와 1,082 ms였으나 그 파일은 다음 실행이 덮어썼다. 입력이 없는 PC에서 잰 최종 성능 표에서는 Multi가 32 ms와 30 ms, UIA 단독이 28 ms와 26 ms다.

고친 방식: 세션이 한 백엔드에 요청을 보내는 동안 나머지 백엔드에 알린다. 창을 가진 백엔드(JAB)는 그동안 자기 스레드에서 메시지가 오는 즉시 처리하고(`MsgWaitForMultipleObjectsEx`), 자기 요청이 오면 바로 그쪽으로 돌아간다. 요청이 없는 시간의 동작은 그대로 250 ms 주기다. 주기를 20 ms로 줄이는 방법은 190 ms까지만 내려갔고 유휴 시간에 계속 깨어나야 해서 쓰지 않았다. UIA가 Agent 자신의 창을 건너뛰게 하는 방법은 효과가 없었다(대기가 속성 조회가 아니라 창 순회에서 생긴다).

단일 백엔드 세션의 동작은 바꾸지 않았다. 따라서 **JAB 전용 Agent를 띄워 둔 PC에서는 다른 프로세스의 UIA 클라이언트가 같은 지연을 겪을 수 있다.** 이 경우는 측정하지 않았다.

## 유지한 안전 규칙

| 규칙 | Multi 모드에서 |
|---|---|
| 기존 API 호환 | 단일 백엔드 세션의 요청과 응답은 바이트 단위로 같은 형식이다. 추가된 것은 `snapshot.backend`(선택)와 multi 세션의 `backends`, `backend`, `defaultBackend` 필드다. |
| PID와 프로세스 시작 시각 | 세션의 정책 하나가 모든 백엔드의 조작에 적용된다. 재시작한 프로세스는 PID가 달라 두 백엔드 모두 `PERMISSION_DENIED`다(실측). |
| 액션 허용, 참조 동일성 | 조작 직전의 재검증은 각 Adapter가 그대로 한다. |
| 스냅샷 만료와 무효화 | 백엔드마다 따로. UIA 스냅샷 60초 뒤 JAB 스냅샷을 받고, 121초에 UIA 참조만 `STALE_REFERENCE`, 그 61초 뒤 JAB 참조가 `STALE_REFERENCE`임을 실측했다. |
| 명령 ID 중복 | 세션 전체. UIA로 쓴 ID를 JAB 조작에 다시 쓰면 `DUPLICATE_COMMAND`이고 픽스처 상태는 바뀌지 않았다. 그 반대도 같다. |
| 변경의 Fallback·재시도 금지 | 조작은 참조를 발급한 백엔드로만 간다. 실패하거나 결과를 모르면 그대로 보고한다. 다른 백엔드로 보내는 코드 경로가 없다. |
| `ACTION_OUTCOME_UNKNOWN`, `effectVerified` | 뜻이 같다. 성공 응답은 언제나 `{"performed":true,"effectVerified":false}`다. |
| 민감 정보 | 백엔드별 정책 그대로다. 두 트리를 합치지 않으므로 한 백엔드가 가린 이름이 다른 백엔드의 행에 붙지 않는다. |
| 네이티브 리소스 해제 | 종료 때 백엔드를 서로 기다리지 않고 닫는다. 정상인 JAB는 JVM 안의 참조를 반환한다(10분 반복 뒤 JVM에 남은 요청별 접근성 객체 0개). |

## 기존 JAB 위험 세 가지의 검토

| 항목 | 확인한 것 | 조치 |
|---|---|---|
| 편집 요소의 Name 노출 | 고유 문자열을 텍스트 필드에 넣은 뒤 두 백엔드의 스냅샷 전체(AWT 45행, Swing 95행)에서 그 문자열을 찾았다. 나온 행은 0개다. JAB의 편집 요소 이름은 앱이 붙인 라벨(`Fixture edit` 등)이었고 UIA의 편집 요소 이름은 빈 문자열이었다. | 정책은 그대로 둔다. 이 검사를 회귀에 넣었다(`editContentNotExposed`, `swingEditContentNotExposed`). 앱이 접근성 이름에 업무 데이터를 직접 넣는 경우는 여전히 막지 못한다. AWT에서는 UIA 백엔드로 편집 요소를 찾으면 이름이 나가지 않는다. |
| AWT `setValue` 지원 여부 | 브리지의 컨텍스트 정보에는 `AccessibleEditableText` 구현 여부가 없다. JDK 17의 `AccessBridgePackages.h`가 정의한 인터페이스 비트는 Value, Action, Component, Selection, Table, Text, Hypertext 일곱 개다. Agent가 스냅샷 시점에 AWT 필드를 가려낼 근거가 없다. | 바꾸지 않았다. JAB의 AWT 텍스트 필드는 계속 `setValue`를 내보내고 실행하면 `ACTION_OUTCOME_UNKNOWN`이다. Multi 모드에서는 같은 창의 UIA 스냅샷으로 입력한다. 두 트리를 이어 붙여 JAB 행의 `setValue`를 지우는 것은 좌표로 짝을 맞추는 일이라 하지 않았다. |
| 응답 시간으로 판정하는 타임아웃 | 3.5초를 넘긴 브리지 호출의 결과를 버리는 규칙은 그대로다. 한 세션에서 모달을 여는 클릭을 Agent마다 15번 반복한 실험(30회)에서 응답은 모두 8.0초대의 `ACTION_OUTCOME_UNKNOWN`이었다. 시나리오 실행 중에 예외가 한 번 있었다(아래). | 바꾸지 않았다. 더 나은 신호(브리지 DLL의 전송 실패 여부)는 DLL이 내보내지 않아 검증할 방법을 찾지 못했다. 예외 한 건을 다시 잡을 수 있게 시험 도구가 응답 코드, 지연, 픽스처의 모달 상태와 호스트 상태를 남기게 했다. |

## 검증 결과

Windows 11 Pro 25H2(빌드 26200.7840), 12세대 Core i7-1255U, 125 % 배율 단일 모니터의 대화형 세션. Agent는 x64(Java Agent는 Oracle JDK 17.0.10, C++ Agent는 MSVC 19.44). 대상은 Java 17.0.10의 AWT·Swing 픽스처, Temurin 23.0.2의 AWT 픽스처, WPF 픽스처다. 조작의 성공은 Agent 응답이 아니라 픽스처가 쓰는 상태 파일로 판정했다. 시험 대상 커밋은 각 JSON의 `environment.git`에 있다.

### 실제 실행과 Fault Injection의 구분

| 종류 | 뜻 | 해당 검증 |
|---|---|---|
| 실제 실행 | Agent와 고치지 않은 픽스처 앱만 참여한다. 장애도 앱의 실제 동작에서 나온다. | AWT 혼합 자동화, 참조·명령 ID 규칙, Swing 모달에 의한 JAB 무응답과 복구, JVM 간 영향, 대상 종료와 재시작, 성능, 10분 반복, 단일 백엔드 회귀 |
| Fault Injection, 실제 프로세스 | 시험 도구가 장애를 만든다. Agent와 대상은 실제 프로세스다. | WPF 프로세스 일시 중지(`NtSuspendProcess`)로 만든 UIA 기한 초과, 없는 경로를 준 브리지 DLL, 브리지를 켜지 않고 시작한 JVM |
| Fault Injection, 단위 테스트 | 각본대로 움직이는 Adapter를 세션에 넣는다. GUI가 없다. | Java `MultiBackendAgentTest` 16개, `JnaDesktopAdapterTest` 2개, `CliTest` 1개. C++ `core_test`의 `multiBackend`. 재시작할 수 없는 백엔드의 기한 초과, 모든 백엔드의 실패, 폐기된 Adapter의 참조 차단처럼 실제로 만들기 어려운 경우를 맡는다. |

JAB 백엔드 자체가 10초 기한을 넘겨 폐기되는 경우는 실제 프로세스로 재현하지 못했다. 단위 테스트로만 검증했다.

### 기능 (최종 실행)

[`2026-11-24-multi-backend-functional.json`](test-results/2026-11-24-multi-backend-functional.json), 커밋 `77e41ea`. 실행 내내 키보드·마우스 입력이 없었다(마지막 입력 뒤 31~41분).

| 시나리오 | 종류 | Java/JNA | C++ | 확인한 것 |
|---|---|---|---|---|
| AwtMixed | 실제 | 11/11 | 11/11 | 아래 표 |
| Safety | 실제 | 9/9 | 9/9 | 기본 백엔드, 없는 백엔드 거부, 백엔드별 최신 스냅샷, 다른 백엔드·다른 세션의 참조 거부, 범위 스냅샷, 백엔드 간 중복 명령 ID, 편집 내용 비노출, 백엔드별 만료(181초) |
| JabFault | 실제 | 11/11 | 11/11 | 아래 표 |
| UiaFault | Fault Injection | 7/7 | 7/7 | 아래 표 |
| Environment | Fault Injection | 2/2 | 2/2 | 브리지 DLL 없음: JAB만 `available=false`와 사유, UIA로 입력 성공. 브리지를 켜지 않은 JVM: 창은 UIA만 나열, JAB 스냅샷은 `BRIDGE_NOT_CONNECTED`, `bridge.javaWindows` 3 > `connectedWindows` 2, UIA로 입력 성공 |
| TargetRestart | 실제 | 2/2 | 2/2 | 종료 뒤 두 백엔드의 참조가 `STALE_REFERENCE`, 창은 `WINDOW_NOT_FOUND`. 재시작한 프로세스를 두 백엔드가 1.7~1.8초 안에 발견, 조작은 `PERMISSION_DENIED`이고 픽스처 불변 |

**AWT 혼합 자동화.** Agent 프로세스 하나(요청 24건), AWT 픽스처 하나.

| 단계 | 백엔드 | 판정 근거 |
|---|---|---|
| 창 목록에 한 행, `backends`가 `["UIA","JAB"]` | 둘 다 | 응답 |
| TextField를 찾아 SetValue | UIA (23개 요소) | `value.txt`가 보낸 값 |
| Button을 찾아 Invoke | JAB (22개 요소) | `count.txt`가 1 증가 |
| JAB 스냅샷 뒤에도 UIA 참조가 유효 | UIA | `getElementInfo` 성공 |
| 모달 열기 | JAB | `modal.txt=open`, 모달 행의 `ownerWindowId`가 픽스처 창 |
| 모달 닫기 (모달의 자체 스냅샷에서 버튼) | JAB | `modal.txt=closed`, 모달 창은 `WINDOW_NOT_FOUND` |
| 다시 텍스트 입력, 처음 받은 UIA 참조로 | UIA | `value.txt`가 새 값 |
| 다시 텍스트 입력, 새 UIA 스냅샷으로. 이전 UIA 참조는 `STALE_REFERENCE` | UIA | `value.txt`가 새 값 |
| Agent PID가 처음과 같음, EOF 뒤 종료 코드 0 | | 프로세스 |

**JAB 장애와 격리.** Swing(Java 17), AWT(Java 23), WPF 창을 한 Agent가 다룬다.

| 단계 | Java/JNA | C++ |
|---|---|---|
| Swing의 모달을 여는 버튼 Invoke | `ACTION_OUTCOME_UNKNOWN`, 8,025 ms, 모달은 열림 | 같음, 8,001 ms |
| 그동안 JAB 참조로 `getElementInfo` | `TARGET_NOT_RESPONDING`, 3 ms | 같음 |
| 그동안 `listWindows` | 성공. UIA 행만, 응답의 `backends`에 JAB `TARGET_NOT_RESPONDING` | 같음 |
| 그동안 UIA로 WPF 창: 장애 전 참조로 버튼, 새 스냅샷(20개 요소), SetValue, Invoke | 모두 성공, 픽스처 상태로 확인 | 같음 |
| 모달을 닫은 뒤 장애 전의 JAB 참조 | 96 ms 안에 `getElementInfo` 성공, Invoke로 카운터 증가 | 93 ms, 같음 |
| 다시 모달을 연 상태에서 다른 JVM(AWT, Java 23)의 JAB 스냅샷 | `TARGET_NOT_RESPONDING`, 1 ms | 같음 |
| 같은 상태에서 그 AWT 창에 UIA로 SetValue | 성공 | 성공 |
| 모달이 열린 채 EOF | 16 ms에 종료 코드 0, 픽스처 셋은 살아 있음 | 8 ms에 종료 코드 0 |
| 모달을 닫고 새 Agent로 두 JVM 조작 | 성공 | 성공 |

**UIA 장애와 격리.** AWT와 WPF 창을 한 Agent가 다룬다. WPF 프로세스를 일시 중지한다.

| 단계 | Java/JNA | C++ |
|---|---|---|
| 중지된 WPF 창의 UIA 스냅샷 | `TIMEOUT`, 10,018 ms | `TIMEOUT`, 10,002 ms |
| 그 뒤 JAB: 장애 전 참조로 `getElementInfo`와 Invoke, 새 스냅샷(22개 요소)과 Invoke | 모두 성공, 카운터로 확인 | 같음 |
| `getCapabilities` | UIA `available=false`와 사유, JAB `available=true` | 같음 |
| `listWindows` | 성공(10 ms). JAB 행만, `backends`에 UIA `BACKEND_UNAVAILABLE` | 같음 |
| 프로세스 재개 뒤 UIA 스냅샷(AWT 창) | 738 ms 뒤 성공, 23개 요소 전부. SetValue 성공 | 677 ms, 같음 |
| 폐기 전의 UIA 참조 | `STALE_REFERENCE` | 같음 |
| 재시작 전에 받은 JAB 참조 | Invoke 성공 | 같음 |
| 다시 중지해 `TIMEOUT`을 낸 뒤 EOF | 10.5초 뒤 종료 코드 0 | 10.0초 뒤 종료 코드 **1** |
| 새 Agent로 AWT(JAB)와 WPF(UIA) 조작 | 성공 | 성공 |

UIA 호출이 멈춘 채 끝날 때의 종료 코드는 두 Agent가 다르다. C++는 스레드가 10초 안에 끝나지 않으면 프로세스를 종료 코드 1로 끝내고, Java는 기다린 뒤 0으로 끝난다. 단일 백엔드 모드에서도 같았던 기존 차이다. 두 경우 모두 JAB 백엔드는 그 전에 정상적으로 닫혔고 AWT 픽스처는 다음 Agent에서 바로 쓸 수 있었다.

### 통과하지 못한 두 번의 실행

최종 실행 전에 같은 기능 시험을 두 번 돌렸고 둘 다 일부 검사가 실패했다. 숨기지 않고 원본을 남긴다.

| 실행 | 실패 | 관찰 | 판단 |
|---|---|---|---|
| 1차, 15:49 KST, 커밋 `c3e35c9` ([원본](test-results/2026-11-24-multi-backend-functional-attempt1.json)) | C++ JabFault의 두 번째 모달 열기 클릭이 `ACTION_OUTCOME_UNKNOWN`이 아니라 `OK`로 왔다. 직후 `modal.txt`는 `open`이 아니었다. 그 뒤 검사 1개 실패, 1개 미실행. | 응답 지연과 호스트 상태를 남기지 않던 때다. 같은 시나리오를 C++로 18번, Java로 6번 더 돌리고 한 세션에서 모달 클릭을 Agent별 15번 반복했으나 재현되지 않았다. | **원인 미확정.** 모달이 열리자마자 닫혔다면 리스너가 3.5초 안에 반환해 `OK`가 맞는 응답이다. 픽스처 창이 전면에 뜨므로 사람의 키 입력이 닫기 버튼에 들어갔을 수 있다. 확인할 기록이 없다. 브리지가 실패한 호출에 TRUE를 돌려준 경우도 배제하지 못한다. |
| 2차, 17:06 KST, 커밋 `59cf04c` ([원본](test-results/2026-11-24-multi-backend-functional-attempt2.json), [성능](test-results/2026-11-24-multi-backend-performance-attempt2.json)) | Java Safety: 거부된 중복 명령 뒤 `count.txt`가 기대값과 달랐다(Agent는 0.5 ms에 `DUPLICATE_COMMAND`로 거부했다). C++ UiaFault: UIA 스냅샷이 14 ms에 Edit 없이 왔다. 이어진 성능 실행 18개 중 3개가 AWT 창을 찾지 못했고, UIA 스냅샷이 2개 요소뿐인 실행이 3개였다. | 뒤에 넣은 호스트 기록으로 계산하면 마지막 키보드·마우스 입력이 17:13:49다. 증상이 있던 17:07~17:14와 겹친다. 17:14:14에 시작한 10분 반복 두 번과 회귀는 입력이 없는 동안 돌았고 실패가 없었다. | **사람이 PC를 쓰던 시간과 겹친다. 원인은 확정하지 못했다.** 확인한 것은 그 시간대에 입력이 있었다는 것과, 입력이 없는 동안의 실행에서는 같은 증상이 나오지 않았다는 것이다. 어떤 조작이었는지는 모른다. 창 최소화는 원인이 아니다(최소화한 AWT 창을 UIA로 읽으면 23개 요소가 그대로 나온다). 다른 가상 데스크톱으로의 전환이나 화면 잠금처럼 창을 UIA 목록에서 빼는 조작, 전면의 픽스처에 들어간 키·마우스 입력이 후보다. |

이 뒤로 시험 도구는 실패한 검사마다 마지막 입력 뒤 경과 시간, 입력 데스크톱, 각 픽스처 창의 표시 상태(전면, 뒤, 최소화, 숨김, 다른 가상 데스크톱)를 남기고, 실패한 시나리오의 마지막 요청 60건을 코드·지연과 함께 남긴다. 상태 파일을 읽지 못한 것을 값이 바뀐 것으로 판정하지도 않는다.

1차 실행의 항목은 `performed=true`의 신뢰와 닿아 있으므로 원인이 밝혀질 때까지 미해결로 둔다.

### 단일 백엔드 회귀

커밋 `59cf04c`(Agent 코드는 최종과 같다).

| 시험 | 결과 | 이전 결과와 비교 |
|---|---|---|
| UIA, 일곱 프레임워크 × 두 Agent ([원본](test-results/2026-11-24-multi-uia-regression.json)) | PASS 256, FAIL 32, NOT_RUN 10. 일곱 프레임워크의 트리 비교 모두 PASS | MFC를 뺀 214개 검사가 [이전 실행](test-results/2026-11-24-jab-uia-regression.json)과 이름·판정·분류까지 같다. MFC는 두 Agent 21/21로 [따로 저장된 이전 결과](test-results/2026-11-24-jab-uia-mfc.json)와 같다. FAIL 32개는 이전과 같은 `UIA_PROVIDER_LIMITATION` 14개와 `JAB_ONLY` 18개다. |
| `Test-UiaDefectRegression.ps1 -RequireBothBackends` | 통과 | 소유 모달, 부분 스냅샷, 무반응 Invoke의 판정이 같다 |
| JAB, Swing·AWT × 두 Agent ([원본](test-results/2026-11-24-multi-jab-regression.json)) | Swing 33/34, AWT 27/30. 두 Agent 동일, 트리 일치 | 만료 검사 없이 돌린 [이전 실행](test-results/2026-11-24-jab-functional-java23.json)과 검사 이름·판정·분류가 모두 같다 |
| `Test-JabRegression.ps1 -RequireBothBackends` | 통과 | 통과하지 못한 검사는 증거가 있는 Java 쪽 제약뿐 |
| Java 단위 테스트 (`mvn -o package`) | 102개 중 98개 실행, 실패 0. 4개는 GUI 통합 테스트 | 이전 83개에 19개 추가 |
| C++ 코어 테스트 (CTest) | x64 1/1, x86 1/1 | `multiBackend` 추가 |

JAB 회귀의 121초 만료 검사(`-IncludeExpiry`)와 Java GUI 통합 테스트(`WindowsGuiTest`)는 이번에 실행하지 않았다. 단일 백엔드의 만료는 Java 단위 테스트가, 백엔드별 만료는 위 Safety 시나리오가 실제 대기로 확인했다. 32비트 C++ Agent는 빌드와 코어 테스트만 했고 GUI 시험은 하지 않았다.

## 성능과 리소스

같은 AWT 픽스처(UIA 23개 요소, JAB 22개 요소)에 대해 모드마다 Agent 프로세스를 새로 띄워 3번씩 쟀다. 한 번의 실행은 준비 3회 뒤 20회 반복이고, 반복 하나는 `listWindows` 한 번과 그 모드의 백엔드마다 전체 스냅샷 한 번이다. Multi는 반복마다 스냅샷이 두 번이다. 리소스는 반복이 끝난 시점의 값이다. 커밋 `77e41ea`, 입력이 없는 PC. [원본](test-results/2026-11-24-multi-backend-performance.json)

| 항목 (3회 중앙값) | Java UIA | Java JAB | Java Multi | C++ UIA | C++ JAB | C++ Multi |
|---|---:|---:|---:|---:|---:|---:|
| 첫 `getCapabilities`까지, ms | 396 | 582 | 660 | 75 | 280 | 288 |
| 모든 백엔드의 첫 스냅샷까지, ms | 513 | 619 | 803 | 163 | 310 | 385 |
| `listWindows` p50, ms | 27.5 | 6.2 | 31.9 | 25.5 | 4.9 | 29.9 |
| `snapshot` p50, ms | UIA 49.3 | JAB 12.3 | UIA 50.8, JAB 11.5 | UIA 43.8 | JAB 10.2 | UIA 44.8, JAB 9.9 |
| `snapshot` p95, ms | UIA 57.9 | JAB 16.8 | UIA 63.4, JAB 14.6 | UIA 49.2 | JAB 11.5 | UIA 50.4, JAB 13.8 |
| 반복당 Agent CPU, ms | 48.4 | 15.6 | 59.4 | 26.6 | 1.6 | 27.3 |
| Private Bytes, MiB | 69.6 | 60.4 | 71.4 | 4.0 | 3.0 | 4.8 |
| Working Set, MiB | 84.0 | 67.8 | 87.5 | 20.1 | 12.9 | 22.6 |
| 핸들 | 463 | 386 | 491 | 288 | 196 | 312 |
| 스레드 | 22 | 18 | 24 | 7 | 2 | 8 |
| EOF 뒤 종료, ms | 25.6 | 21.7 | 25.5 | 5.2 | 5.9 | 7.9 |

- **기동.** Multi의 준비 시간은 두 백엔드를 차례로 여는 시간이다. Java는 UIA 단독보다 0.29초, C++는 0.22초 길다. JAB 단독과 비교하면 Java 0.18초, C++ 0.08초 길다.
- **지연.** 백엔드별 스냅샷 지연은 단독 모드와 같다(차이 3 ms 이내). `listWindows`는 두 백엔드를 차례로 묻는 만큼이다.
- **CPU.** Multi의 반복당 CPU는 UIA 단독과 JAB 단독의 합에 가깝다(Java 59 대 48+16, C++ 27 대 27+2).
- **메모리.** Multi는 UIA 단독보다 Java 1.8 MiB, C++ 0.8 MiB 많다. 두 프로세스를 따로 띄우면 Java 130 MiB, C++ 7.0 MiB이므로 Java에서는 Multi가 약 58 MiB 적다.
- **핸들과 스레드.** Multi는 UIA 단독보다 핸들 24~28개, 스레드 1~2개 많다.

값은 실행마다 달라진다. 같은 날 PC를 쓰던 시간대의 실행에서는 스냅샷 지연이 약 두 배였다(UIA 96~132 ms, JAB 25~32 ms). 모드 사이의 비는 비슷했다.

## 10분 혼합 반복

Agent 하나가 AWT 픽스처에 대해 UIA 스냅샷 → Edit 찾기 → SetValue → JAB 스냅샷 → Button 찾기 → Invoke를 반복하고, 열 번에 한 번은 JAB로 모달을 열고 닫은 뒤 그 전에 받은 UIA 참조로 다시 SetValue를 한다. 모든 조작을 픽스처 상태로 확인한다. 15초마다 Agent와 픽스처 JVM을 표본으로 남긴다. 커밋 `59cf04c`, 실행 중 PC 입력 없음. [원본](test-results/2026-11-24-multi-backend-soak.json)

| 항목 | Java/JNA | C++ |
|---|---:|---:|
| 반복 | 2,989 | 3,050 |
| 모달 열고 닫기 | 298 | 305 |
| 요청, OK가 아닌 응답 | 20,024, 0 | 20,439, 0 |
| 실패한 반복 | 0 | 0 |
| UIA 스냅샷 p50 / p95 / p99, ms | 69.9 / 98.6 / 111.8 | 66.9 / 91.3 / 104.3 |
| UIA SetValue p50 / p95 / p99, ms | 10.0 / 16.9 / 22.7 | 8.7 / 14.3 / 19.2 |
| JAB 스냅샷 p50 / p95 / p99, ms | 21.4 / 28.4 / 31.6 | 20.8 / 26.9 / 29.8 |
| JAB Invoke p50 / p95 / p99, ms | 4.1 / 6.0 / 7.5 | 3.1 / 4.5 / 5.8 |
| **세션 교체** | 1회, 350.7초에 (조작 4,002건) | 1회, 342.7초에 (조작 4,002건) |

세션 교체는 장애가 아니다. 한 세션이 받는 조작은 4,096건까지이므로 시험 도구가 그 전에 Agent를 끝내고 새로 띄운다. 교체 전후는 다른 프로세스라 리소스를 이어서 비교하지 않고 세션별로 적는다.

| Agent 리소스 | Java 세션 1 (0~351초) | Java 세션 2 (351~600초) | C++ 세션 1 (0~343초) | C++ 세션 2 (343~600초) |
|---|---:|---:|---:|---:|
| Private Bytes, 처음 → 끝, MiB | 68.3 → 68.7 | 70.8 → 64.2 | 4.5 → 6.0 | 4.6 → 6.0 |
| 핸들, 처음 → 끝 | 491 → 493 | 491 → 492 | 312 → 310 | 312 → 310 |
| 스레드, 처음 → 끝 | 24 → 25 | 24 → 24 | 8 → 8 | 8 → 6 |
| 종료 (EOF 뒤) | 27 ms, 코드 0 | 24 ms, 코드 0 | 13 ms, 코드 0 | 18 ms, 코드 0 |

| 픽스처 JVM (전체 600초, 첫 1/4 뒤부터) | Java Agent 실행 | C++ Agent 실행 |
|---|---:|---:|
| Private Bytes, MiB | 119.6 → 127.8 (범위 119.6~134.9) | 124.2 → 122.4 (범위 119.7~127.3) |
| 핸들 | 530 → 532 | 531 → 531 |
| 스레드 | 38 → 40 | 38 → 40 |
| JVM 안의 요청별 접근성 객체 | 0~2개 | 0~2개 |
| Agent 종료 뒤 남은 요청별 접근성 객체 | 0 | 0 |

- 핸들과 스레드는 두 Agent와 픽스처 모두 일정했다. Agent가 붙잡은 JVM 안의 객체는 스냅샷 하나 분량을 넘지 않았고 종료 뒤 0이 됐다.
- Java Agent의 Private Bytes는 64~78 MiB 사이에서 오르내렸고 방향이 없다.
- **C++ Agent의 Private Bytes는 세션 안에서 계속 늘었다.** 조작 4,002건에 약 1.5 MiB다. 단일 백엔드 JAB 반복에서도 같은 모양이었다([C++ AWT](test-results/2026-11-24-jab-stability-cpp-awt.json): 3.16 → 4.37 MiB 뒤 세션 교체로 3.23 MiB). 명령 ID 기록이 세션 한도(4,096건)까지 쌓이는 것과 맞는 크기이고 한도가 상한이 된다. 항목별로 나눠 재지는 않았으므로 원인은 추정이다.
- 픽스처 JVM의 Private Bytes는 GC에 따라 움직였다. 10분 범위에서 누수 여부를 판단할 수 없다.

## Java와 C++의 중복 구현 비용

### 이번 작업에서 든 비용

| | Java/JNA | C++ |
|---|---|---|
| 제품 코드 (추가/변경 줄) | 약 470줄. `Agent` 306, `JnaDesktopAdapter` 42, `DesktopAdapters`·`Cli` 48, 브리지 쪽 51 | 약 390줄. `multi_session` 251, `session_worker` 66, `main` 48, `jab_adapter` 22 |
| 테스트 코드 | 약 490줄, 테스트 19개 | 약 230줄, 시나리오 1개 |
| 구조 | 기존 `Agent`에 백엔드 목록을 넣었다. Adapter가 이미 자기 스레드를 갖고 있어 세션은 한 스레드로 충분했다. | `Agent`가 워커 스레드 안에 있어 그 위에 라우터 계층을 새로 얹었다. 참조의 소유자를 접두사로 가리는 규칙이 생겼다. |
| 공유 | 실제 GUI 회귀 [`Test-MultiBackend.ps1`](../tools/Test-MultiBackend.ps1) 하나를 두 Agent가 같이 통과한다 | 같음 |

두 번 쓴 것: capability 합치기, 창 목록 병합과 부분 실패 보고, 백엔드 선택 규칙, 다시 만들기 조건, 오류의 우선순위(중복 ID가 낡은 참조보다 먼저), 메시지 처리 알림. 같은 규칙을 서로 다른 구조에 맞춰 두 번 설계했다. Java는 "스냅샷에서 ref를 찾는다", C++는 "접두사로 가른다"로 방법이 달라졌고, 이런 차이는 한쪽만 고쳐질 여지를 만든다.

중복이 실제로 낸 차이: 장애 상태에서 끝날 때의 종료 코드(Java 0, C++ 1), capability의 사유 문구, ref의 형식. 동작 계약의 차이는 실제 GUI 회귀에서 나오지 않았다(84개 검사의 판정이 같다).

중복이 준 이득도 있었다. `listWindows`가 1초 걸리는 문제는 두 구현에서 같은 값으로 나와 Agent 코드가 아니라 브리지의 숨은 창이 원인임을 바로 좁힐 수 있었다.

Java와 C++를 독립 제품 후보로 유지한다. 양쪽에서 레거시 Agent 기능이 완성된 뒤 같은 운영 시나리오로 비교한다. 당시 결과는 UIA/JAB 수준의 비교 기준선이다. 후속 실험에서는 JVM별 JAB 프로세스와 PID 허용 목록으로도 JVM 장애가 전파됐다. UIA와 JAB의 프로세스 수명을 분리하는 방안은 별도로 평가한다. [안정화 결과](MULTI-BACKEND-STABILIZATION.md)

## 초기 검증의 미해결 문제

아래 표는 초기 검증 결과다. 공유 조회 기한, 종료 상태, JAB 응답 판정과 현재 남은 한계는 후속 문서에 있다. [안정화 결과](MULTI-BACKEND-STABILIZATION.md)

| 문제 | 상태 |
|---|---|
| 모달을 여는 클릭이 한 번 `OK`로 온 것 (1차 실행, C++) | 재현하지 못했다. 원인 미확정. 기록 수단을 넣었다. |
| JVM 간 격리 | 없음. 기존 제약 그대로. |
| JAB 백엔드 다시 만들기 | 하지 않는다. 폐기되면 Agent 재시작이 필요하다. 실제 프로세스로 그 폐기를 재현하지 못했다. |
| 기한을 넘긴 UIA 호출 | 반환할 때까지 UIA를 쓸 수 없고 종료에 약 10초가 걸린다. 대상 프로세스가 끝내 반환하지 않으면 UIA는 그 Agent에서 돌아오지 않는다. |
| JAB 전용 Agent가 다른 UIA 클라이언트를 늦추는지 | 측정하지 않았다. 구조상 가능하다. |
| 모든 백엔드를 차례로 묻는 요청의 최악 시간 | `listWindows`와 `getCapabilities`는 백엔드마다 10초 기한을 따로 쓴다. 두 백엔드가 모두 멈추면 20초까지 걸릴 수 있다. |
| C++ Agent의 세션 안 메모리 증가 | 조작 4,002건에 약 1.5 MiB. 한도가 상한이지만 원인을 나눠 재지 않았다. |
| AWT의 JAB `setValue` 표시, 편집 요소 이름 정책, 3.5초 규칙 | 검토만 했고 바꾸지 않았다. |
| 종료 코드 차이 | 장애 상태 종료에서 Java 0, C++ 1. 맞추지 않았다. |

## 후속 작업 (이번 범위 밖)

1. 실제 설비 Java 프로그램에서 Multi 모드를 돌려 본다. 모달 빈도, 여러 JVM, 서드파티 컴포넌트를 본다.
2. 전체 레거시 기능을 구현한 뒤 8시간 및 24시간 안정성 시험을 수행한다.
3. JVM별 격리에는 접속 대상 자체를 제한할 수 있는 브리지 통신 실험이 필요하다.
4. MSAA Adapter를 세 번째 백엔드로 넣는다. 위치 기반 참조 정책이 먼저 정해져야 한다([검토](JAVA-ACCESS-BRIDGE.md#msaa-adapter-검토)).
5. 레거시 JVM과 32비트 조합, Delphi·MFC 추가 검증, 물리 입력, 선택·토글 같은 새 액션.

## 재현

잠금 해제된 Windows 대화형 세션의 저장소 루트에서, JDK의 `bin`을 `PATH`에 두고 실행한다. 시험 중에는 PC를 쓰지 않는다. 픽스처 창이 전면에 뜬다.

```powershell
mvn clean verify
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
New-Item -ItemType Directory -Force target/framework-fixtures/swing-awt | Out-Null
javac -Xlint:all -d target/framework-fixtures/swing-awt tests/fixtures/swing-awt/FrameworkFixture.java

# 기능: 6개 시나리오, 두 Agent, 백엔드별 만료(181초) 포함
& ./tools/Test-MultiBackend.ps1 -Agent Both -Mode Functional -IncludeExpiry -SecondFixtureJava C:\path\to\other\java.exe -OutputPath target/multi-backend-functional.json
# 시나리오 하나만
& ./tools/Test-MultiBackend.ps1 -Agent Cpp -Scenario JabFault,UiaFault -OutputPath target/multi-backend-faults.json
# 성능: UIA 단독, JAB 단독, Multi
& ./tools/Test-MultiBackend.ps1 -Agent Both -Mode Performance -Pairs 3 -Iterations 20 -Warmup 3 -OutputPath target/multi-backend-performance.json
# 10분 혼합 반복, Agent마다
& ./tools/Test-MultiBackend.ps1 -Agent Both -Mode Soak -DurationSeconds 600 -OutputPath target/multi-backend-soak.json

# 단일 백엔드 회귀
& ./tools/Test-UiaFrameworks.ps1 -Framework WinFormsFramework,Win32,Wpf,WinFormsModern,Swing,Awt,Mfc -Backend Both -OutputPath target/multi-uia-regression.json
& ./tools/tests/Test-UiaDefectRegression.ps1 -ReportPath target/multi-uia-regression.json -RequireBothBackends
& ./tools/Test-UiaFrameworks.ps1 -Framework Swing,Awt -Backend BothJab -SecondFixtureJava C:\path\to\other\java.exe -OutputPath target/multi-jab-regression.json
& ./tools/tests/Test-JabRegression.ps1 -ReportPath target/multi-jab-regression.json -RequireBothBackends
```

`Test-MultiBackend.ps1`은 픽스처(AWT, Swing, WPF)를 직접 띄우고 그 PID만 허용한다. 각 검사에 `real` 또는 `faultInjection`을 적고, 실패한 검사에는 호스트 상태를, 실패한 시나리오에는 마지막 요청들을 남긴다. 종료 코드는 모든 검사가 통과하고 두 Agent의 판정이 같을 때만 0이다.
