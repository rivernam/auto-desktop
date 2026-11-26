# 실행 구조와 개발 순서

## 공통 Core와 플랫폼 경계

```text
로컬 클라이언트 ─ UTF-8 NDJSON ─ Cli
                                 │
                      Agent (플랫폼 공통 세션, 백엔드 하나 이상)
                         ├─ DesktopSnapshot ─ ElementLocator
                         │  트리, 공개 ref ↔ 어댑터 key, 유일성, 만료 (백엔드마다 하나)
                         ├─ ActionDispatcher ─ DesktopAction
                         │  실행 정책, 중복 ID, 결과 미상 처리
                         └─ DesktopAdapter
                              ├─ WindowsAdapter → PowerShell 또는 C# → UIAutomationClient
                              ├─ JnaDesktopAdapter → 전용 스레드 → UI Automation COM (JnaUiaSession)
                              │                                  또는 Java Access Bridge (JabSession)
                              │                                  또는 Active Accessibility COM (MsaaSession)
                              └─ 어댑터 미탑재 환경 → 미가용 capability
```

실행 진입점과 명령 해석기는 하나다. CLI는 시작할 때 `DesktopAdapters`에서 어댑터 하나를 받아 Agent에 주입한다. OS 선택과 C# 실행 경로는 여기에서 결정한다. MSAA는 같은 Agent 코어를 사용한다. Linux용 AT-SPI도 이 코어에 연결할 수 있다. 현재 기본 Linux 실행에서는 `backend="none"`, `available=false`를 반환한다. Windows UIA 워커를 명시적으로 선택하면 해당 백엔드의 가용 여부를 보고한다.

| 책임 | 공통 Java 코드 | 플랫폼 어댑터 |
|---|---|---|
| 관찰 | 창 ID를 불투명 문자열로 처리하고 최대 깊이·요소 수를 제한한다. 스냅샷의 부모 관계를 검증하고 공개 ref를 발급한다. | OS의 창과 트리를 열거하고 노드에 비공개 key를 발급한다. UIA 요소, HWND 및 런타임 ID의 의미는 Windows 구현 안에 둔다. |
| 검색·참조 | Locator의 조건 검사, 선택한 가지에서의 유일성, 잘린 트리의 오류, 최신 스냅샷과 120초 만료를 관리한다. | 살아 있는 요소의 창·조상 경로를 재검증한다. JNA는 같은 창의 검증된 요소부터 하위 트리를 수집할 수 있다. |
| 동작 | `DesktopAction`과 요소의 지원 목록을 대조하고 프로세스·액션 정책 및 명령 ID를 검사한다. | `perform`에서 현재 대상과 패턴을 재검증한 뒤 OS API를 호출한다. IPC·JNA·JNI 중 무엇을 쓰는지는 이 경계 안에서 결정한다. |
| capability | 세션 가용성·작업 목록의 JSON 계약과 요소별 actions를 구분한다. | 현재 사용자 세션과 설치된 API를 조회한다. 성공적인 capability 응답 뒤에도 각 요소에서 패턴을 확인한다. |

`DesktopAdapter`는 관찰·현재 속성·동작을 이름이 있는 Java 메서드로 제공한다. 결과 문서는 현재 NDJSON의 JSON 모델을 재사용한다. 코어는 워커의 `op` 프레임을 만들지 않는다. 기존 Windows 어댑터는 JSON 브리지를 통해 같은 구현을 사용한다. `findElement`는 공통 스냅샷에서 평가하므로 플랫폼마다 검색 규칙을 다시 구현할 필요가 없다. 물리 입력이나 시스템 관리 기능을 추가할 때는 별도 연산과 capability를 도입한다. [원본 구조 및 명령 대조](UPSTREAM-COMPARISON.md)

기본 모드의 WindowsAdapter는 첫 백엔드 요청 시 JAR에 포함된 스크립트를 로컬 임시 파일로 추출하고 Windows PowerShell을 실행한다. 선택형 C# 모드에서는 CLI 시작 시 받은 절대 경로의 EXE를 같은 파이프 계약으로 실행한다. 두 모드 모두 작업 프로세스의 MTA 스레드가 관리형 UIA 요소와 Control View 트리를 소유한다. 스냅샷에는 공개 속성만 투영하고 네이티브 객체는 최근 캡처 하나에만 보관한다. 다음 캡처가 기존 객체에 대한 참조를 해제하며 프로세스 종료가 최종 리소스 해제 경계다. 스레드 풀에서 파이프 쓰기와 응답 읽기를 수행하며 Java 호출자는 최대 10초 기다린다. 제한을 넘기거나 응답을 해석할 수 없으면 작업 프로세스를 폐기한다. 다음 요청에서 새 프로세스를 시작할 수 있다. 변경 명령 전송 후 응답을 잃으면 결과가 불명확하므로 자동 재시도하지 않는다.

`--backend jab`은 같은 JNA 호스트에 Java Access Bridge 세션을 올린다. Swing과 AWT 창을 같은 명령으로 탐색하고 조작한다. C++ Agent도 같은 계약의 Adapter를 가진다. 변경 요청을 다른 백엔드로 다시 보내는 경로는 어느 모드에도 없다. [Java Access Bridge Adapter](JAVA-ACCESS-BRIDGE.md)

`--backend multi`는 UIA, JAB, MSAA Adapter를 한 세션에 함께 둔다. 세션은 백엔드마다 Adapter, 전용 스레드, 최신 스냅샷을 따로 갖고, 명령 ID 기록과 허용 정책만 공유한다. 스냅샷 요청이 백엔드를 고르고, 참조는 자신을 발급한 백엔드로만 전달된다. 각 트리는 독립된 스냅샷이다. 한 백엔드의 호출이 기한을 넘기면 그 Adapter만 폐기된다. Java에서는 `Agent`가 백엔드 목록을 직접 갖고, C++에서는 `MultiSession`이 백엔드마다 `SessionWorker` 하나를 두고 요청을 나눈다. MSAA Adapter는 위치 기반 요소를 조회 전용 참조로 보관하고, Provider의 객체 수명을 확인한 경우에만 원래 객체로 변경을 전달한다. [MSAA 참조 정책](MSAA-ADAPTER.md) [Multi-Backend 구조와 검증](MULTI-BACKEND.md)

선택형 JNA 어댑터에서는 하나의 MTA 스레드가 COM 세션과 참조를 소유한다. 대기열의 요청 취소는 해당 요청에만 영향을 준다. 이미 인수된 호출이 타임아웃되면 어댑터를 폐기하고 새 요청을 막으며, COM 해제는 호출 반환 뒤에 수행한다. 별도 프로세스는 중단된 네이티브 호출이나 충돌의 격리를 위한 후보로 유지한다. [JNA 채택 및 장애 격리](JNA.md)

CLI는 대상 앱과 같은 사용자·로그인 세션에서 실행한다. 일반 권한과 높은 무결성 수준으로 실행한 프로세스 사이에는 UI 접근 제한이 있다. GUI 작업을 Windows Session 0의 서비스에서 직접 실행하는 방식은 지원하지 않는다. 후속 서비스 모델에서는 서비스가 작업 큐를 관리하고, 사용자의 대화형 세션에서 실행한 별도 워커가 실제 GUI에 접근하도록 한다. Linux에서도 사용자 접근성 버스와 디스플레이 자격 증명이 해당 GUI 세션에 속한다.

## 개발 순서와 검증 기준

Java와 C++는 각각 Core와 Windows Adapter를 소유한다. 공통 NDJSON 계약, 보안 정책, 실기기 픽스처와 측정 도구를 공유한다. 레거시 Agent 기능이 양쪽에서 완성되면 같은 운영 시나리오로 비교한다. 분리 프로세스는 각 구현의 네이티브 장애 격리 후보이며, JVM 격리 가능성과 별개로 평가한다. [안정화 및 분리 프로세스 검증](MULTI-BACKEND-STABILIZATION.md)

| 단계 | 구현 또는 조사 | 다음 단계로 넘어갈 증거 |
|---|---|---|
| 0 | 두 참고 프로젝트, OS 지원 범위, 런타임·네이티브 연동 대안 검토 | 기술 결정서와 호환성 표 |
| 1 | UIA 트리와 패턴 워커, Java 명령·정책·참조 관리, 지속형 CLI, 모킹 및 WPF 테스트 | Linux 빌드·단위 테스트와 별도로 Windows 10/11에서 앱의 값·클릭 카운터 및 커서 전후 좌표 확인 |
| 1b | Java Access Bridge Adapter. Swing과 AWT 창의 트리, Locator, 버튼 실행과 텍스트 입력 (Java/JNA와 C++) | Windows 11에서 Java 17·23 대상 JVM의 실제 카운터·입력값·모달 상태, 참조 무효화와 핸들 반환 확인. 구형 JVM과 x86은 미실행 |
| 1c | Multi-Backend 세션. UIA와 JAB를 한 Agent에서 함께 쓰고 장애를 백엔드 단위로 가둔다 (Java/JNA와 C++) | 한 프로세스로 AWT 창의 텍스트(UIA)와 버튼·모달(JAB)을 조작, JAB 무응답 중 UIA 동작과 그 반대, 참조·명령 ID 규칙, 10분 혼합 반복 |
| 1d | 물리 입력(SendInput). 좌표·요소 bounds 기반 마우스와 키보드, 입력 전 창·PID·권한·전경·사용자 입력 검증, 실패 시 해제 (Java/JNA와 C++) | 단위·거부 경로 시험과 기존 접근성 회귀 유지. Interactive 시험(`tools/Test-PhysicalInput.ps1 -Interactive`)으로 실제 앱 상태 변화와 해제 확인. 2026-11-26 기준 Interactive 시험은 미실행 |
| 2 | XP SP3/x86과 XP Embedded 이미지에서 실행 가능한 JVM·Win32 헬퍼 조합 조사. MSAA의 IAccessible, accDoDefaultAction, 속성 조회 구현. UIA 설치본별 탐지 | 현대 Windows와 동일 JSON 계약 테스트, 구형 컨트롤의 지원·미지원 패턴, 실제 x86/x64 조합 및 리소스 회수 결과 |
| 3 | Ubuntu 22.04에서 AT-SPI2/D-Bus 탐색 및 Action·EditableText 어댑터 개발. CentOS 5는 AT-SPI1/CORBA와 구형 ABI로 별도 빌드. CentOS 6/7·RHEL은 설치된 접근성 버스 탐지 | 각 이미지와 데스크톱에서 직접 수행한 트리·동작 테스트. X11의 XTest·캡처와 Wayland RemoteDesktop/ScreenCast 포털의 동의·권한 결과를 각각 기록 |
| 4 | 명령 큐·작업 상태·heartbeat, 지속적인 중복 방지, 재접속, 세션별 워커 감독, 인증된 로컬 IPC와 원격 명령 계약 | 지연·충돌·재시작 시 상태 보존 및 미확인 변경의 중복 실행 방지 시험. 중앙 서버 구현은 별도 범위 |
| 5 | OS·CPU별 패키징, 로그인 시 자동 시작, 서명한 업데이트·롤백, 진단 로그 수집과 장시간 부하 시험 | 승인된 환경에서 CPU·RSS·핸들 추이, 업그레이드/롤백, 세션 잠금·해제·재연결 결과 기록 |

추후 공통 API 후보에는 `getWindow`, `toggle`, `waitFor`가 포함된다. 현재 `select`는 MSAA의 `SELFLAG_TAKESELECTION`에 한정한다. 물리 입력(SendInput)은 별도 명령 영역으로 구현했다. 포인터·키보드·창 활성화마다 `--allow-action` 허용과 capability의 `input` 행이 따로 있고, Java는 `InputDriver`·`WindowsInputDriver`, C++은 `InputDriver`·`windows/input_driver.cpp`가 같은 계약을 따른다. 접근성 호출 실패로 물리 입력을 발생시키는 경로는 없다. 화면 캡처는 아직 없다. [물리 입력](PHYSICAL-INPUT.md) 실제 설비 조작을 도입할 때는 공정별 사전 조건, 조작 후 독립적인 상태 확인 및 승인된 환경에서의 시험이 필요하다.

## 레거시 조회 PoC

현대·레거시 Maven 빌드는 shared/src/main/java의 Utf8Frames와 ReadOnlyDesktopAdapter를 각각 컴파일한다. 공개 JSON 계약은 공통이며 최신 Core는 Jackson, Java 7 최소 호스트는 Gson을 사용한다. 레거시 호스트는 변경 명령을 거부하고 지정된 워커에 창 열거·가용성 조회만 전달한다. XP 워커는 요청마다 별도 프로세스로 실행된다. Linux에서는 같은 JAR를 워커 없이 실행하고 GUI 의존성은 독립 진단한다.
