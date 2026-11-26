# 빌드 및 시험 기록

## 2026-11-26 물리 입력 최종 검증

원격 `main`의 `e942f0f`에서 시작했다. Windows 11 Pro 25H2(26200.9974), Core i7-12700, 모니터 1대에서 Oracle Java 11.0.15 x64와 MSVC 19.44 Release를 사용했다. x64 전체 Interactive 원본은 `e942f0f` 커밋 직전 작업 트리에서 생성됐다. 원본의 `gitCommit`에는 실행 당시 HEAD인 `224f0d7`이 기록돼 있으며, JAR·x64 EXE·WinForms 픽스처 SHA-256을 해당 빌드와 대조했다. 이후 좌표 변환 경계 수정(`cc93de3`)은 관련 케이스만 다시 검증했다. [x64 전체 기준선 JSON](test-results/2026-11-26-physical-input-baseline-x64.json)

### Interactive 결과

| 실행 | Agent | PASS | FAIL | BLOCKED | NOT_RUN | 원본 |
|---|---|---:|---:|---:|---:|---|
| x64 전체 기준선 | Java x64 | 14 | 0 | 0 | 2 | [JSON](test-results/2026-11-26-physical-input-baseline-x64.json) |
| x64 전체 기준선 | C++ x64 | 14 | 0 | 0 | 2 | [JSON](test-results/2026-11-26-physical-input-baseline-x64.json) |
| 최종 빌드 좌표 중심 회귀 | Java x64 | 6 | 0 | 0 | 0 | [JSON](test-results/2026-11-26-physical-input-final-x64.json) |
| 최종 빌드 좌표 중심 회귀 | C++ x64 | 6 | 0 | 0 | 0 | [JSON](test-results/2026-11-26-physical-input-final-x64.json) |
| 최종 빌드 핵심 입력 회귀(WOW64) | C++ x86 | 5 | 0 | 0 | 0 | [JSON](test-results/2026-11-26-physical-input-final-x86.json) |
| Java 11 대상 AWT 입력 | Java x64, C++ x64 각각 | 1 | 0 | 0 | 0 | [JSON](test-results/2026-11-26-physical-input-baseline-awt-workflow-jdk11.json) |
| AWT 물리 유니코드 진단, Java 11·21 대상 | 대상별 Java x64, C++ x64 각각 | 0 | 1 | 0 | 0 | [Java 11 대상 JSON](test-results/2026-11-26-physical-input-baseline-awt-unicode-jdk11.json) · [Java 21 대상 JSON](test-results/2026-11-26-physical-input-baseline-awt-unicode-jdk21.json) |

전체 기준선에서 두 Agent의 케이스 상태와 응답 코드 순서는 일치했다. 캔버스 클릭·더블 클릭·드래그·휠은 픽스처가 기록한 좌표와 델타, 키보드·단축키는 유니코드 문자열과 키 이벤트·카운터로 확인했다. Swing 모달은 열림·닫힘, AWT 버튼은 카운터의 정확히 1 증가를 확인했다. AWT 텍스트는 물리 Backspace 뒤 값과 UIA `setValue` 뒤 한글 문자열을 각각 대조했다. WinForms는 선택한 항목, 탭 제목, 커밋한 셀 값을 확인했다. MSAA weak 참조의 명시적 허용 전에는 값이 유지됐고 허용 후에는 선택이 바뀌었다. 전경 불일치, 가림, 대상 교체, 외부 입력 충돌, 드래그 중단과 정상 종료 후 해제도 확인했다. [픽스처 판정 및 결과 형식](PHYSICAL-INPUT.md#interactive-시험)

### 좌표 경계 수정과 자동 회귀

물리 창과 백엔드 루트의 크기를 비교할 때 Java와 C++가 서로 다른 분모를 사용했다. 1,000픽셀 기준으로 창 크기 990픽셀을 준 회귀가 양쪽에서 `scaled`로 떨어졌다. 양쪽 모두 백엔드 루트 크기의 ±1%를 포함해 물리 일치를 판정한다. 990·1,010픽셀은 물리 일치, 989·1,011픽셀은 확대·축소로 확인했다. 기존 테스트에서도 음수 원점 정규화, 좌표 반올림, MSAA 클라이언트 영역 일치 및 불일치 거부를 확인했다. Java 11 Maven 130개 통과·4개 GUI 옵션 미실행, C++ CTest x64·x86 각각 3/3 통과했다. 패키지의 읽기 전용 NDJSON 계약은 Java와 C++ x64·x86에서 각각 9/9 통과했다. [Java 경계 회귀](../src/test/java/dev/desktop/InputLogicTest.java) · [C++ 경계 회귀](../native/cpp-agent/tests/input_test.cpp)

최종 x64 회귀는 CanvasMouse·WinForms ListBox·TabItem·DataGridView·Swing 모달·성능을 포함했다. 6개 케이스의 상태와 응답 코드 순서가 양쪽에서 같았다. 96 DPI 캔버스에서 실제 포인터 위치 `(813, 783)`과 클라이언트 기준 스크롤 후 위치 `(960, 802)`가 예상값과 일치했다. 픽스처가 기록한 버튼·드래그 좌표, 세로 240 및 가로 -120 휠 델타도 일치했다. [최종 x64 JSON](test-results/2026-11-26-physical-input-final-x64.json)

C++ x86 실행 파일(PE Machine `0x014c`)은 같은 PC의 WOW64에서 캔버스 마우스·키보드, WinForms ListBox/MSAA, 외부 입력 충돌, 실패 후 해제를 통과했다. 두 최종 JSON은 `cc93de3`과 실행기·픽스처·Agent 해시를 담고 있다. Java x86과 네이티브 x86 OS의 실제 입력은 미실행이다. [최종 x86 JSON](test-results/2026-11-26-physical-input-final-x86.json)

### 최종 x64 단기 성능

같은 PC의 단일 실행에서 측정한 요청 왕복 지연이다. 두 Agent 모두 클릭 60/60건과 문자 320/320자를 픽스처에서 확인했다. 화면 위치 이동은 Agent 응답과 별도로 캔버스 회귀에서 실제 커서 위치를 확인했다. 장시간 부하와 환경 간 성능 차이는 이 측정 범위에 포함하지 않았다. [측정 원본](test-results/2026-11-26-physical-input-final-x64.json)

| 명령 | 표본 수(Agent당) | Java p50 / p95 / 최대(ms) | C++ p50 / p95 / 최대(ms) |
|---|---:|---:|---:|
| `pointerMove` | 60 | 2.04 / 2.45 / 25.07 | 0.39 / 0.49 / 3.32 |
| `pointerClick` | 30 | 2.58 / 16.62 / 18.10 | 0.54 / 16.96 / 17.17 |
| `clickElement` | 30 | 26.70 / 39.02 / 298.13 | 25.92 / 65.89 / 303.85 |
| `keyPress` | 60 | 2.15 / 3.33 / 5.46 | 0.73 / 1.45 / 2.39 |
| `typeText`(32자) | 10 | 12.91 / 15.42 / 15.42 | 8.52 / 10.33 / 10.33 |

### 미해결 및 환경별 미실행

| 항목 | 판정과 다음 검증 |
|---|---|
| AWT `KEYEVENTF_UNICODE` | 두 Agent와 두 대상 JDK에서 훅은 입력을 관측했지만 AWT 필드 값은 바뀌지 않았다. 일반 키와 UIA 값 설정은 동작했다. 대상의 문자 처리 경로에서 발생하는 호환성 제약으로 분류했다. AWT 내부의 정확한 차단 지점은 미확정이다. [Windows Unicode 키 이벤트](https://learn.microsoft.com/en-us/windows/win32/api/winuser/ns-winuser-keybdinput) |
| 저수준 훅 제거 | Windows는 시간 초과로 훅을 제거해도 알리지 않는다. 앱의 훅 제거를 강제로 재현하는 시험은 미실행이다. 양쪽 코드는 관측이 0건이면 다음 요청에서 재설치를 시도하며, 일부 관측 이후의 누락 및 재설치까지의 외부 입력은 보장할 수 없다. 다음 단계에서 훅 손실 주입과 관측 누락 시 중단 정책을 별도로 검증한다. [Windows 저수준 훅](https://learn.microsoft.com/en-us/windows/win32/winmsg/lowlevelkeyboardproc) |
| Agent 강제 종료 | 이번 시험에서 강제 종료는 미실행이다. 강제 종료된 프로세스는 키·버튼을 해제하는 코드를 실행할 기회가 없다. 감시 프로세스가 필요한 구조적 제약이다. 요청 중단과 표준 입력을 닫은 정상 종료에서의 해제는 PASS다. [Windows 프로세스 종료](https://learn.microsoft.com/en-us/windows/win32/procthread/terminating-a-process) |
| 다중 모니터·혼합 DPI | 모니터 1대로 미실행. 음수 원점 계산은 단위 시험에서 검증했다. |
| 관리자 권한 대상 | UAC 승인이 필요한 `-IncludeElevated`를 사용하지 않아 미실행. |
| 나머지 x86 조합 | C++ x86은 WOW64에서 지정한 5건을 실행했다. 나머지 Interactive 케이스와 Java x86 런타임·네이티브 x86 OS는 해당 구성으로 실행하지 않았다. |
| Windows 7·10, RDP | 해당 OS 이미지와 RDP 시험 세션을 사용하지 않아 미실행. |

일반 권한의 Windows 11 대화형 세션을 대상으로 개발을 이어갈 수 있다. AWT 직접 유니코드 입력 또는 훅 손실·강제 종료 중 입력 안전성이 필수인 운영에는 별도 검증이 필요하다. 두 Agent는 독립 빌드와 공통 실행기로 검증했으며 PID·권한·전경 검증과 자동 Fallback 금지 정책을 유지했다.

## 2026-11-26 물리 입력 초기 빌드 및 Background 회귀

Windows 11 Pro 25H2(빌드 26200.7840), Core i7-1255U, 125 % 배율 모니터 1개. Java Agent는 Temurin 11.0.33 x64, C++ Agent는 MSVC 19.44 x64·x86 Release. Swing/AWT 픽스처는 이전 기준선과 같은 JDK 17.0.10. 사용자가 PC로 업무를 보는 중이었으므로 실제 입력이 발생하는 시험은 실행하지 않았다. 아래 GUI 시험은 모두 포커스를 가져가지 않는 Background 모드 픽스처로 했고, `tools/Watch-Foreground.ps1`을 함께 실행했다. [물리 입력 계약과 시험 방법](PHYSICAL-INPUT.md)

| 시험 | 결과 | 원본 |
|---|---|---|
| Java 빌드·단위 테스트, JDK 11 (`mvn -o package`) | 132개 중 128개 실행, 실패 0. 4개는 GUI 통합 테스트(별도 플래그) | 빌드 로그 |
| Java 11 런타임 실행 | JAR를 Temurin 11.0.33으로 실행. `getCapabilities`, `listWindows`(17개 창), 입력 허용 세션의 `input` 행(perMonitorV2, medium, 1920×1080), 거부 경로. 같은 요청에 C++ Agent와 같은 오류 코드와 `inputSent` | 콘솔 |
| Java GUI 통합 (`WindowsGuiTest`, Java 11) | 1개 실행 PASS(나머지 3개는 C#·PowerShell 워커 플래그 필요). 첫 실행은 사용자의 마우스 이동으로 "Physical cursor moved" 실패, PC가 한가할 때 재실행 통과 | Surefire 보고서 |
| C++ CTest | x64 3/3, x86 3/3 (`agent-core-contract`, `input-contract`, `input-driver-status`) | 빌드 로그 |
| 물리 입력 네이티브 거부 경로 (Java `WindowsInputDriverTest`) | 없는 창·다른 PID·창 밖 좌표가 입력 없이 거부되고 게이트 호출과 훅 설치가 없음 | Surefire 보고서 |
| UIA 프레임워크 회귀 (Java 11 JNA, C++) | 298개 검사 중 PASS 256. 2026-11-24 기준선과 검사 단위까지 같음. 기준선에서 NOT_RUN이던 MFC가 두 Agent 모두 22/22 | [JSON](test-results/2026-11-26-input-uia-regression.json) |
| JAB 회귀 (Swing·AWT, 두 Agent) | 128개 중 PASS 120. 기준선과 검사 단위까지 같음 | [JSON](test-results/2026-11-26-input-jab-regression.json) |
| Multi-Backend Safety·UiaFault·Metadata | 두 Agent 6/6 시나리오 PASS | [JSON](test-results/2026-11-26-input-multi-regression.json) |
| MSAA (Java, C++ x64, C++ x86) | 각 6/6 | [JSON](test-results/2026-11-26-input-msaa-regression.json) |
| 읽기 전용 계약 (`check-readonly-contract.py`) | Java 9, C++ 9 | 콘솔 |
| 포커스 감시 | 첫 회귀에서 Swing 픽스처의 옵션 창(JOptionPane)이 Background 모드에서도 전경을 두 번 가져갔다. 이번 변경 전부터 있던 코드였고, 모달과 같은 방식으로 고친 뒤 JAB 회귀를 다시 실행해 0회. 표시 직후 20~30 ms 동안 픽스처 창이 위에 그려진 기록이 실행마다 1~2건 있다(포커스는 이동하지 않음, 이전 빌드와 같음) | 로컬 보고서 |
| 물리 입력 Interactive 시험 | NOT_RUN. 계획 파일만 생성(32건 모두 NOT_RUN) | [JSON](test-results/2026-11-26-physical-input-plan.json) |

이 초기 실행에서는 실제 SendInput 전송 및 성능 비교, 다중 모니터, 관리자 권한 대상, Windows 7·10, x86 Agent의 GUI, RDP, Java 11 대상 JVM 시험이 미실행이었다. 이후 실측 범위는 위 최종 검증을 참조한다. 화면 캡처·이미지 매칭·OCR·장시간 시험은 범위 밖이었다. 포커스 감시 원본에는 사용자의 창 제목이 들어 있어 저장소에 넣지 않았다.

## 2026-11-25 MSAA Adapter

Java x64와 C++ x64·x86에서 WinForms 탐색, 표준 Win32 재조회, 테스트 COM Provider 동작, 객체 교체와 장애 복구를 검증했다. 관찰 범위, CPU·메모리 수치, 원본 및 기존 UIA·JAB·Multi-Backend 회귀 결과는 [MSAA Adapter](MSAA-ADAPTER.md)에 있다.

## 2026-11-24 Multi-Backend 안정화

Java와 C++의 공유 조회 기한, UIA 재생성, JAB 응답 판정, 명령 ID 메모리와 JVM별 프로세스 실험을 다시 검증했다. 시작 실패와 도구 오류가 있던 실행도 남겼다. 각 바이너리의 해시, 실행 시간, 미실행 항목은 후속 보고서와 원본에 있다. [Multi-Backend 안정화](MULTI-BACKEND-STABILIZATION.md)

## 2026-11-24 Multi-Backend Agent

Windows 11 Pro 25H2(빌드 26200.7840), Agent x64, 대상은 Java 17.0.10의 AWT·Swing, Temurin 23.0.2의 AWT, WPF 픽스처. 구조, 표, 판단과 재현 명령은 [Multi-Backend Agent](MULTI-BACKEND.md)에 있다.

| 시험 | 결과 | 원본 |
|---|---|---|
| Java 단위 테스트 (`mvn -o package`) | 102개 중 98개 실행, 실패 0. 4개는 GUI 통합 테스트 | 빌드 로그 |
| C++ 코어 테스트 (CTest) | x64 1/1, x86 1/1 | 빌드 로그 |
| Multi 기능, 최종 실행 (6개 시나리오 × 두 Agent) | 84/84, 두 Agent의 판정이 같음 | [JSON](test-results/2026-11-24-multi-backend-functional.json) |
| Multi 기능, 그 전의 두 실행 | 81/84(실패 2, 미실행 1)와 78/84(실패 3, 미실행 3). 재현되지 않음, 원인 미확정 | [1차](test-results/2026-11-24-multi-backend-functional-attempt1.json) · [2차](test-results/2026-11-24-multi-backend-functional-attempt2.json) |
| 성능: UIA 단독, JAB 단독, Multi | Multi의 스냅샷 지연은 단독과 같고(차이 3 ms 이내), 준비 시간은 0.22~0.29초 길다 | [JSON](test-results/2026-11-24-multi-backend-performance.json) · [실패가 섞인 2차](test-results/2026-11-24-multi-backend-performance-attempt2.json) |
| Multi `listWindows` 지연의 원인과 수정 | 약 1,000 ms → 66~73 ms (같은 조건) | [전](test-results/2026-11-24-multi-backend-performance-before-message-service.json) · [후](test-results/2026-11-24-multi-backend-performance-after-message-service.json) |
| 10분 혼합 반복, Agent마다 | Java/JNA 2,989회, C++ 3,050회, 실패 0. 세션 교체 각 1회 | [JSON](test-results/2026-11-24-multi-backend-soak.json) |
| UIA 단일 백엔드 회귀 | 298개 중 PASS 256. 이전 결과와 검사 단위까지 같음 | [JSON](test-results/2026-11-24-multi-uia-regression.json) |
| JAB 단일 백엔드 회귀 | Swing 33/34, AWT 27/30. 이전 결과와 같음 | [JSON](test-results/2026-11-24-multi-jab-regression.json) |

미실행: JAB 회귀의 121초 만료 검사, Java GUI 통합 테스트(`WindowsGuiTest`), 32비트 Agent의 GUI 시험, Java 8·11·21 대상 JVM, 1시간 이상 연속 시험. 기능 시험의 앞선 두 실행에서 나온 실패는 [따로 정리했다](MULTI-BACKEND.md#통과하지-못한-두-번의-실행). 그중 모달을 여는 클릭이 한 번 `OK`로 온 건은 미해결이다.

## 2026-11-24 Java Access Bridge Adapter

Windows 11 Pro 25H2(빌드 26200), Agent x64, 대상 JVM Oracle JDK 17.0.10과 Eclipse Adoptium 23.0.2(둘 다 x64). 원인, 표와 재현 명령은 [Java Access Bridge Adapter](JAVA-ACCESS-BRIDGE.md)에 있다.

| 시험 | 결과 | 원본 |
|---|---|---|
| Java 단위 테스트 (`mvn -o package`) | 83개 중 79개 실행, 실패 0. 4개는 GUI 통합 테스트 | 빌드 로그 |
| C++ 코어 테스트 (CTest) | x64 1/1, x86 1/1 | 빌드 로그 |
| Java GUI 통합 (`WindowsGuiTest`) | 4개 중 2개 통과, 2개는 C# 워커가 없어 건너뜀 | 빌드 로그 |
| JAB 기능, 대상 Java 17 | Swing 34/35, AWT 28/31. 두 Agent 동일, 트리 일치 | [JSON](test-results/2026-11-24-jab-functional-java17.json) |
| JAB 기능, 대상 Java 23 | Swing 33/34, AWT 27/30. 두 Agent 동일, 트리 일치 | [JSON](test-results/2026-11-24-jab-functional-java23.json) |
| JAB 성능, Swing 95개 요소 | 스냅샷 p50 38~42 ms(Java/JNA), 34~37 ms(C++) | [JSON](test-results/2026-11-24-jab-performance.json) |
| JAB 반복 안정성, Swing 10분 | Java/JNA 2,209회, C++ 2,954회, 실패 0, 핸들·스레드·JVM 참조 일정 | [Java](test-results/2026-11-24-jab-stability-java-swing.json) · [C++](test-results/2026-11-24-jab-stability-cpp-swing.json) |
| JAB 반복 안정성, AWT 5분 | Java/JNA 4,042회, C++ 4,481회, 실패 0 | [Java](test-results/2026-11-24-jab-stability-java-awt.json) · [C++](test-results/2026-11-24-jab-stability-cpp-awt.json) |
| UIA 회귀, 여섯 프레임워크 | 256개 중 PASS 214, 이전 결과와 검사 단위까지 같음 | [JSON](test-results/2026-11-24-jab-uia-regression.json) |
| UIA, Win32 x86 픽스처와 x86 C++ Agent | 22/22 | [x86 픽스처](test-results/2026-11-24-jab-uia-win32-x86.json) · [x86 Agent](test-results/2026-11-24-jab-uia-cpp-x86.json) |
| UIA, MFC x64 대화상자 (구성 요소 설치 후 첫 실행) | 두 Agent 21/21, 트리 일치. SDI·MDI·Property Sheet는 탐색 확인 | [JSON](test-results/2026-11-24-jab-uia-mfc.json) · [프레임](test-results/2026-11-24-jab-uia-mfc-frames.json) |
| 원인 실험, 환경 조사, MSAA 프로브 | 기록 | [JSON](test-results/2026-11-24-jab-investigation.json) |

통과하지 못한 JAB 검사는 Swing의 모달을 여는 버튼과 AWT의 텍스트 입력이며 둘 다 Java 쪽 구현의 제약이다. 미실행: Java 6·7·8·11·21과 32비트 JVM, 32비트 브리지, Delphi VCL, 1시간 이상 연속 시험. MFC 결과는 픽스처 수정이 작업 트리에 있는 상태에서 측정해 `git.dirty`가 true다. 최종 실행 중 Java 17 Swing 실행 한 번이 픽스처의 명령 파일 경합으로 실패했다. 픽스처를 고친 뒤 다시 실행한 결과를 저장했다.

## JNA 장시간 측정 및 분석 도구

`tools/Test-JnaSoak.ps1`은 `-IntervalSeconds`(기본 60초) 구간마다 요청 완료·실패 수, 연산별(Snapshot, FindElement, GetElementInfo, SetValue, Invoke) 호출 수와 평균·p50·p95·p99·최대 지연, 처리량, 오류 코드별 횟수를 집계한다. 구간이 끝날 때 Heap used/committed, NMT reserved/committed, Private bytes, Working set, CPU 시간, 핸들, 스레드, JVM PID·시작 시각, HotSpot GC 횟수·시간(`jcmd PerfCounter.print`)을 함께 기록한다. 실패·Timeout은 시각·구간·세션과 함께 `failures`에, 세션 재시작과 비정상 JVM 종료는 `sessionRestarts`, `unexpectedJvmExits`와 세션별 `endReason`에 남는다.

- 구간 내부 분위수는 정확한 nearest-rank 값이며, 구간이 닫히면 개별 지연 표본을 해제한다.
- 기존 `latencyMs`(snapshot, findEdit, findButton, elementInfo, setValue, invoke)는 유지한다. 전체 기간 분위수는 1% 폭 로그 히스토그램의 **근사값**(최대 1% 과대)이며 count·mean·max는 정확하다. 방식은 JSON의 `latencyStatistics`에 기록된다. 이전 60초 JSON의 분위수는 모든 표본을 보관한 정확한 값이다.
- 세션 표본의 jcmd 원문(`heap`, `nativeMemory`)은 세션의 첫·마지막 표본에만 남기고 숫자 필드는 모두 유지한다. 8시간·60초 구간 기준 구간 480개(각 약 2 KB), 표본 480개(각 약 1 KB), 히스토그램 연산당 최대 약 1,700칸으로 보관량이 실행 시간에 비례해 작게만 늘어난다.
- 구간 종료, 표본 수집 때마다 체크포인트를 저장한다. 파일은 임시 파일에 write-through로 기록한 뒤 원자적으로 교체한다. jcmd 수집 시간(`samplingMs`)과 체크포인트 저장 시간(`checkpointMs`)은 구간 시간에서 제외한다. 강제 GC는 호출하지 않는다.
- Ctrl+C로 중단하면 `interrupted`와 마지막 부분 구간을 저장한다. 프로세스가 강제 종료되면 마지막 체크포인트까지 남는다.

스키마 버전 3부터는 느린 구간이 생겼을 때 에이전트, 시험 앱, 호스트 중 무엇이 달라졌는지 가릴 수 있도록 다음을 함께 기록한다.

- 리소스 표본마다 `fixture`(WPF 시험 앱, UIA 공급자)와 `driver`(측정 스크립트) 프로세스의 CPU 시간·private bytes·working set·핸들·스레드를 남긴다.
- `host`에는 전체 논리 프로세서의 사용·유휴 CPU 시간과 `% Processor Performance` 누적값, 가용 메모리, AC 전원 여부, 마지막 키보드·마우스 입력 이후 시간, 시험 창의 전경·최소화 상태를 남긴다. CPU 시간과 성능 카운터는 누적값이어서 두 표본의 차이가 그 사이의 평균이 된다. 성능 카운터의 기준값은 주기적으로 되돌아가며, 분석 도구는 그 구간의 프로세서 속도를 NOT AVAILABLE로 둔다.
- `-TopProcesses N`을 주면 JVM·시험 앱·스크립트를 제외하고 직전 표본 이후 CPU를 가장 많이 쓴 프로세스 N개의 이름과 CPU 시간을 `host.topProcesses`에 남긴다. 기본값 0은 프로세스 이름을 기록하지 않는다. 이름이 JSON에 남으므로 결과를 공개 저장소에 올리기 전에 확인한다.
- young·survivor 크기(`heapYoungBytes`, `heapSurvivorBytes`)를 표본마다 남긴다. G1에서는 young 영역과 survivor 영역의 크기이고, Serial GC에서는 young 세대와 from 공간의 사용량이다. 다른 수집기의 `GC.heap_info` 형식은 읽지 않는다.
- 지연이 `-SlowRequestMs`(기본 100 ms) 이상인 요청은 구간·연산별로 세고(`slowRequestCount`), 구간마다 가장 느린 `-SlowRequestLimit`(기본 10)개는 완료 시각과 함께 `slowRequests`에 남긴다.
- JVM마다 GC 로그를 보고서 옆에 `<보고서 이름>.gc-<PID>.log`로 쓰고 파일 이름을 세션의 `gcLog`에 기록한다. `gc*`와 `safepoint`, 단계·참조 처리·age 상세를 UTC 시각과 함께 남기며 수거 1회에 약 15 KB, 1시간에 2~3 MB다. `-NoGcLog`로 끈다.
- 환경 정보에 CPU 모델과 명목 주파수, 메모리, 전원 구성표와 전원 모드, 스크립트의 git 커밋을 추가한다.
- `-JvmOptions '-XX:+UseSerialGC -Xms16m'`처럼 에이전트 JVM에 옵션을 넘길 수 있다. 여러 옵션은 공백이나 쉼표로 구분한다. 따옴표가 필요한 옵션은 받지 않고, 사용한 옵션은 `jvmOptions`에 기록되어 보고서 1절에 표시된다.

`tools/Analyze-JnaSoak.py`(Python 3.8 이상, 표준 라이브러리만 사용)는 기존 60초 JSON과 새 JSON, 중단된 체크포인트를 읽어 Markdown 보고서와 선택적 CSV(`jna-soak-resources.csv`, `jna-soak-intervals.csv`)를 만든다. 메모리 누수는 최초·최종 차이가 아니라 JVM 세션별 워밍업 이후 Theil-Sen 기울기, 초반·후반 중앙값, 후반부 기울기로 판정하고, 워밍업 이후 관측이 1시간 미만이면 INCONCLUSIVE로 표시한다. Heap used는 하한 포락선으로 GC 톱니를 줄인다. 입력에 없는 값은 NOT AVAILABLE로 표시하며 추정하지 않는다. 보고서 파일이 손상되고 같은 위치에 완전한 `.pending` 체크포인트가 남아 있으면 그 파일을 분석한다.

스키마 3의 값은 다음과 같이 쓰인다. 스키마 2 이하에서 계산할 수 없는 항목은 NOT AVAILABLE이다.

- 4절: 구간별 부하 표(반복 1회당 JVM·시험 앱·스크립트 CPU 시간, 호스트와 다른 프로세스의 CPU 사용률, 프로세서 속도, GC, 느린 요청 수)와 느린 구간·정상 구간 비교. snapshot p95가 유효 구간 하위 25% 값의 1.5배를 넘으면 느린 구간으로 보고, 측정값별 중앙값과 snapshot p95에 대한 Spearman 순위 상관을 보여준다. 상관은 함께 변한 항목을 가리킬 뿐 원인 판정은 아니다.
- 4절: setValue·invoke처럼 구간당 요청이 적은 연산은 요청이 20개에 이를 때까지 연속 구간을 묶은 평균으로 초반·후반을 비교한다.
- 5절: 세대별 Heap과 수거 횟수, GC 로그의 일시정지 통계. GC 로그는 보고서와 같은 폴더에서 찾으며 `--gc-log`로 지정할 수 있다. old 영역 수거가 한 번도 없던 JVM의 Heap used 증가는 누수와 가비지 누적을 구분할 수 없어 INCONCLUSIVE로 둔다.
- 6~8절: `private bytes − NMT committed`(HotSpot이 추적하지 않는 COM·JNA 등 네이티브 할당)을 누수 지표에 추가하고, 시험 앱과 스크립트 프로세스의 추세를 전체 실행 기간으로 본다. 시험 앱의 지속 증가는 경고, 스크립트의 증가는 참고로 표시한다.
- 9절: 느린 요청 수와, 완료 시각이 남은 요청 중 GC 일시정지와 겹친 요청 수.

### Windows 실행 명령

잠금 해제된 대화형 데스크톱에서 프로젝트 루트를 작업 디렉터리로 사용한다. `java.exe`는 `jcmd.exe`가 함께 있는 JDK여야 한다. Oracle `javapath` 바로가기가 먼저 잡히면 JDK `bin`을 PATH 앞에 둔다. 먼저 `mvn package`로 `target/desktop-agent.jar`를 만든다.

아래 명령은 README의 권장 JVM 옵션으로 에이전트를 띄운다. JVM 기본 설정을 재려면 `-JvmOptions`를 뺀다.

5분 시험:

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromMinutes(5)) -IntervalSeconds 60 -SampleSeconds 30 -JvmOptions '-XX:+UseSerialGC -Xms16m' -OutputPath .\target\windows-uia-jna-soak-5min.json
```

2시간 시험. 워밍업 10분을 빼고도 추세 판정에 필요한 1시간을 넘긴다. 다른 프로세스의 부하까지 보려면 `-TopProcesses 3`을 붙인다:

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromHours(2)) -IntervalSeconds 60 -SampleSeconds 60 -TopProcesses 3 -JvmOptions '-XX:+UseSerialGC -Xms16m' -OutputPath .\target\windows-uia-jna-soak-2h.json
```

8시간 시험:

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromHours(8)) -IntervalSeconds 60 -SampleSeconds 60 -JvmOptions '-XX:+UseSerialGC -Xms16m' -OutputPath .\target\windows-uia-jna-soak-8h.json
```

변경 요청은 기본 15초 간격이라 JVM 재시작 조건(세션당 변경 2,048회)에 약 8.6시간 뒤에 닿는다. 8시간 안에 재시작 경로까지 보려면 `-MutationIntervalSeconds 5`처럼 간격을 줄인다.

작업 스케줄러처럼 `powershell -File .\tools\Test-JnaSoak.ps1`로 실행할 때는 `-Jar`와 `-OutputPath`를 직접 지정한다. Windows PowerShell 5.1은 이 실행 방식에서 매개변수 기본값을 계산할 때 `$PSScriptRoot`가 비어 있어 기본 경로를 만들지 못한다. JVM 옵션은 `-JvmOptions:"-XX:+UseSerialGC -Xms16m"`처럼 콜론으로 붙여 쓴다. 띄어 쓰면 `-`로 시작하는 값이 매개변수 이름으로 해석된다.

분석 보고서 생성:

```powershell
python .\tools\Analyze-JnaSoak.py .\target\windows-uia-jna-soak-8h.json --output .\target\jna-soak-analysis.md --csv-dir .\target
```

5분 결과에서 구간 데이터가 수집됐는지 확인한다. 구간 4개 이상, 각 구간의 snapshot 지연과 JVM·시험 앱·스크립트·호스트 표본, 스키마 버전 3, GC 로그 파일이 있어야 한다.

```powershell
$r = Get-Content .\target\windows-uia-jna-soak-5min.json -Raw | ConvertFrom-Json; $bad = @($r.intervals | Where-Object { !$_.latencyMs.snapshot.count -or !$_.resources.privateBytes -or $null -eq $_.resources.nmtCommittedBytes -or !$_.resources.fixture.available -or !$_.resources.driver.available -or !$_.resources.host.available -or $null -eq $_.resources.heapYoungBytes }); "schema=$($r.schemaVersion) passed=$($r.passed) intervals=$($r.intervals.Count) incomplete=$($bad.Count) failures=$($r.failedIterations) gcLog=$(Test-Path (Join-Path .\target $r.sessions[0].gcLog))"
```

이어서 `python .\tools\Analyze-JnaSoak.py .\target\windows-uia-jna-soak-5min.json --output .\target\jna-soak-5min-analysis.md`를 실행해 4절 표에 구간이 나열되는지 본다. 5분 시험은 1시간 기준보다 짧아 메모리 추세가 INCONCLUSIVE로 표시되는 것이 정상이다.

### 2026-11-23 도구 검증

Windows 11 Pro x64 빌드 26200, Oracle JDK 17.0.10, Windows PowerShell 5.1, Maven 3.9.16, Python 3.11.9에서 검증했다.

| 검사 | 결과 |
|---|---|
| 현대 Maven `verify` | 55개 중 51개 통과, 실패·오류 0, Windows GUI 4개는 기본 설정대로 건너뜀. 변경 전 기준과 같음 |
| Python 분석 도구 단위 시험 | 18개 통과. 판정 보류 항목을 '증가 없음'으로 쓰지 않는 검사 포함. 정상, 필드 누락, 실행 중 실패, 다중 JVM, 메모리 증가·안정화, Heap 톱니, 지연 증가, 짧은 구간, 요청 수가 적은 구간, 잘못된 JSON, 체크포인트·`.pending` 복구, 기존 60초 JSON 수치 일치 |
| PowerShell 도구 시험 | 2개 스크립트 통과. 히스토그램 오차 1% 이내와 버킷 수 상한, 구간 집계와 표본 해제, 오류 코드 분류, GC 카운터 해석 추가 |
| 기존 60초 JSON 분석 | 반복 958·992회, 변경 11쌍, 스냅샷 p95 61.9·58.0 ms, p99 89.6·72.3 ms, private bytes +13.3·+15.8 MiB가 기존 기록과 일치. 기록된 `resourceChange` 9개 항목과 재계산 값 불일치 0. 구간 지연은 NOT AVAILABLE, 메모리 추세는 INCONCLUSIVE |
| 8시간 크기 체크포인트 | 구간 480개·표본 480개 문서의 JSON 변환 117 ms, write-through 저장 49 ms |

실제 WPF 5분 시험은 위의 5분 명령으로 실행했다. 단일 JVM에서 6,196회 반복, 변경 20쌍, 실패 0회, 정상 종료였고 60초 구간 5개가 모두 지연과 리소스 표본을 포함했다. 전체 스냅샷 p95는 63.2 ms(히스토그램 근사), jcmd 표본 수집은 구간당 약 0.6초, 체크포인트 저장은 11~16 ms였다. 첫 네 구간은 초당 21.5~23.3회였고 마지막 구간은 초당 14.8회, 스냅샷 p95 82.9 ms로 느렸다. 원인은 확인하지 않았으며, 분석 도구는 1시간 미만 구간이라 성능 추세를 INCONCLUSIVE로 표시했다. 첫·마지막 표본 사이 private bytes는 -4.8 MiB, working set은 +330.4 MiB, 핸들은 +24개, GC는 12회·541 ms였다. 5분 관측으로 장기 누수 여부는 판단할 수 없다. 이 실행은 Temurin 21이 아닌 JDK 17을 사용했다. [5분 시험 원본](test-results/2026-11-23-jna-soak-5min-intervals.json)

### 2026-11-23 JNA 1시간 시험

같은 환경에서 `-Duration ([TimeSpan]::FromHours(1)) -IntervalSeconds 60 -SampleSeconds 60`으로 실행했다. 단일 JVM에서 48,881회 반복, 변경 237쌍, 요청 195,998건을 처리했고 실패·Timeout·세션 재시작·비정상 종료는 0이었다. 60초 구간 60개가 모두 지연과 리소스 표본을 포함했다.

| 연산 | p50 | p95 | p99 | 최대 |
|---|---:|---:|---:|---:|
| Snapshot | 45.1 ms | 119.6 ms | 208.7 ms | 433.0 ms |
| GetElementInfo | 5.8 ms | 12.0 ms | 27.4 ms | 203.0 ms |
| SetValue | 19.2 ms | 55.0 ms | 87.0 ms | 105.8 ms |
| Invoke | 19.4 ms | 35.5 ms | 54.5 ms | 64.3 ms |

전체 분위수는 히스토그램 근사값이다. 처음 약 25분은 스냅샷 p95가 약 60 ms, 처리량이 초당 약 15.7회였다. 이후 일부 구간에서 p95가 150~220 ms로 오르고 처리량이 초당 7.6~13회로 떨어졌으나, 39·40·48·51·58번 구간은 p95 65~78 ms로 돌아와 단조 증가는 아니었다. 느린 구간에서도 반복 1회당 JVM CPU 시간은 약 20~24 ms로 같았고 JVM CPU 사용률은 낮아져, JVM이 추가 작업을 하기보다 대기한 것으로 보인다. WPF 시험 앱의 CPU는 측정하지 않아 공급자 지연과 호스트 부하를 구분하지 못했다.

Heap committed는 508 MiB로 일정했고 NMT committed는 약 619 MiB에서 유지됐다. Private bytes는 약 633 MiB에서 643 MiB로 완만히 늘었고, 핸들은 552~557개, 스레드는 40~42개였다. Working set은 104 MiB에서 465 MiB로 늘었으며 대부분 시작 후 5분 안에 증가했다. GC는 76회였다. 워밍업 10분을 제외한 추세 구간이 47.5분이라 분석 도구는 메모리와 성능 추세를 INCONCLUSIVE로 판정했다. [1시간 시험 원본](test-results/2026-11-23-jna-soak-1h-intervals.json)

### 2026-11-23 계측 보강 검증

1시간 시험의 느린 구간은 시험 앱과 호스트를 측정하지 않아 원인을 좁힐 수 없었다. 스키마 3의 계측과 분석을 추가하고 같은 환경에서 검증했다. Java 소스는 바꾸지 않았다. Maven `test`는 55개 중 51개 통과, 실패·오류 0, Windows GUI 4개는 기본 설정대로 건너뜀으로 이전과 같고, JAR는 다시 만들지 않았다.

| 검사 | 결과 |
|---|---|
| Python 분석 도구 단위 시험 | 39개 통과(기존 18개 포함, 2시간 시험 뒤 1개 추가). 누적 카운터로 구간별 부하 계산, 느린 구간·정상 구간 비교, 스키마 2 보고서의 누락 열, 묶음 평균 추세, NMT 밖 네이티브 추세, 세대별 Heap과 old 수거가 없을 때의 판정 보류, 시험 앱·스크립트 추세, GC 로그 해석과 회전된 로그, 느린 요청과 GC 일시정지 대조, 환경 표와 CSV 열 |
| PowerShell 도구 시험 | 통과. `GC.heap_info`의 세대 크기 해석, GC 로그 옵션의 경로 인용, 느린 요청 집계와 상한, 리소스 포인트의 새 필드, 모의 에이전트 프로세스로 요청 완료 시각 확인, 호스트 표본의 CPU 시간·전원·입력 유휴 시간·상위 프로세스, 환경 정보 |
| 기존 1시간 JSON 재분석 | 유효 구간 49개 중 느린 구간 27개. snapshot p95와의 순위 상관은 getElementInfo p95가 0.92, JVM 안에서 끝나는 findElement 평균이 -0.48이다. 반복당 JVM CPU 중앙값은 정상 구간 20.9 ms, 느린 구간 21.5 ms다. setValue와 invoke는 5구간 묶음 평균이 17.1 → 27.4 ms, 17.2 → 21.2 ms이며 1시간 미만이라 INCONCLUSIVE다. 시험 앱·호스트 값은 NOT AVAILABLE이다 |

실제 WPF 창에서 짧게 두 번 실행해 수집을 확인했다. 두 실행 모두 실패 0회였고 모든 구간이 JVM·시험 앱·스크립트·호스트 표본과 세대 크기를 포함했으며, 분석 도구가 보고서 옆의 GC 로그를 읽었다.

| 항목 | 90초, `-IntervalSeconds 20 -SampleSeconds 10 -SlowRequestMs 60 -TopProcesses 3` | 150초, `-IntervalSeconds 30 -SampleSeconds 30` |
|---|---:|---:|
| 반복 | 1,317회 | 3,450회 |
| 처리량 | 초당 14.6~15.9회 | 초당 23.2~24.3회 |
| 반복당 JVM CPU (첫 구간 제외) | 17.8~22.2 ms | 11.5~13.5 ms |
| 반복당 시험 앱 CPU | 30.6~36.6 ms | 28.7~30.4 ms |
| 반복당 스크립트 CPU | 15.2~23.8 ms | 6.9~8.2 ms |
| 프로세서 속도 (명목 대비) | 105~126% | 129~136% |
| GC 로그의 일시정지 | 5회, 중앙값 54.0 ms, 최대 64.0 ms | 8회, 중앙값 23.3 ms, 최대 94.2 ms |
| 느린 요청 | 60 ms 이상 61건. 시각이 남은 40건 중 4건이 GC 일시정지와 겹침 | 100 ms 이상 2건. 2건 모두 GC 일시정지와 겹침 |

두 실행 모두 시험 앱 프로세스가 JVM보다 반복당 CPU 시간을 더 썼다. 두 실행 사이에 처리량이 약 1.5배 달랐고 프로세서 속도와 JVM·스크립트의 반복당 CPU 시간도 함께 달랐다. 짧은 실행이라 원인은 판단하지 않는다. 기본 옵션 실행에서는 프로세스 이름이 기록되지 않았다.

검증 중에 기존 결함 하나를 고쳤다. 콘솔 입력 코드 페이지가 UTF-8(65001)인 Windows PowerShell에서 실행하면 .NET이 CLI의 표준 입력 앞에 BOM을 보내 첫 요청이 `INVALID_REQUEST`로 실패했다. `Start-Cli`가 프로세스를 시작하는 동안 BOM이 없는 인코딩을 쓰도록 바꾸고 도구 시험에 넣었다.

`Compare-UiaWorkers.ps1`은 이 체크아웃에 C# 워커 빌드가 없어 설정 실패 경로만 시험했다. 2시간 시험은 아래에 기록했고 8시간 시험은 아직 실행하지 않았다.

도구 단위 시험:

```powershell
python -m unittest discover -s tools\tests -p "test_*.py"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tests\Test-UiaTools.ps1
```

### 2026-11-23 JNA 2시간 시험

같은 환경과 같은 JAR로 `-Duration ([TimeSpan]::FromHours(2)) -IntervalSeconds 60 -SampleSeconds 60 -TopProcesses 3`을 실행했다. AC 전원, 전원 구성표 '균형 조정'이었고 시험 중에 같은 PC를 다른 작업에도 썼다. 단일 JVM에서 104,955회 반복, 변경 473쌍, 요청 420,766건을 처리했고 실패·Timeout·세션 재시작·비정상 종료는 0이었다. 60초 구간 119개(마지막은 20초)가 모두 JVM·시험 앱·스크립트·호스트 표본을 포함했다.

| 연산 | p50 | p95 | p99 | 최대 |
|---|---:|---:|---:|---:|
| Snapshot | 44.2 ms | 97.0 ms | 176.3 ms | 521.8 ms |
| GetElementInfo | 5.5 ms | 10.9 ms | 22.0 ms | 210.2 ms |
| SetValue | 18.2 ms | 45.1 ms | 74.2 ms | 95.8 ms |
| Invoke | 16.3 ms | 30.6 ms | 38.8 ms | 66.7 ms |

분석 도구의 종합 판정은 PASS WITH WARNINGS다. 경고는 snapshot p95와 setValue 평균의 초반·후반 차이, Heap used와 working set의 증가다. 아래 구분 중 '조용한 구간'과 '사용 중 구간'은 분석 도구에 없는 분류라서 원자료에서 따로 계산했다.

**느린 구간은 PC를 쓴 시간과 겹친다.** 워밍업 10분과 마지막 짧은 구간을 뺀 유효 구간 108개 중 snapshot p95가 95.1 ms를 넘는 느린 구간이 40개였다. 그중 38개는 표본을 뜬 시점에 키보드·마우스 입력이 60초 안에 있었다. 구간 안의 두 표본 모두 입력 후 60초가 지났고 시험 창이 전경이던 구간을 조용한 구간으로 보면 46개이고, 그중 느린 구간은 2개다. 그 2개는 보안 검사, 검색 색인, 스크립트 실행 같은 다른 프로세스가 CPU를 10초 넘게 쓴 구간이었다.

| 항목 (구간 중앙값) | 조용한 구간 46개 | 사용 중 구간 62개 |
|---|---:|---:|
| 처리량 | 초당 15.2회 | 초당 13.3회 |
| Snapshot p50 | 44.8 ms | 46.0 ms |
| Snapshot p95 | 63.5 ms | 114.6 ms |
| Snapshot p99 | 80.4 ms | 193.2 ms |
| 반복당 JVM CPU | 22.1 ms | 21.2 ms |
| 반복당 시험 앱 CPU | 34.0 ms | 45.4 ms |
| 느린 구간 | 2개 | 38개 |

분석 도구의 느린 구간·정상 구간 비교에서 snapshot p95와 가장 강하게 함께 움직인 값은 반복당 시험 앱 CPU(34.6 → 51.9 ms, 순위 상관 0.92)였다. 다른 프로세스의 CPU 사용률은 0.69, 마지막 입력 이후 시간은 -0.69, 프로세서 속도는 -0.63이었다. 반복당 JVM CPU는 21.7 ms와 21.8 ms로 같았고(0.21), GC 일시정지 시간(-0.28)과 JVM 안에서 끝나는 findElement(-0.03)는 함께 움직이지 않았다. 100 ms 이상 걸린 요청 4,866건 중 4,496건이 사용 중 구간에서 나왔다.

**조용한 구간끼리 비교하면 시간이 지나도 느려지지 않았다.** 17~58번 구간의 조용한 구간 16개는 초당 15.2회, snapshot p50 44.8 ms, p95 63.0 ms였고 59~117번의 24개는 초당 15.0회, p50 44.9 ms, p95 65.1 ms였다. setValue 평균은 19.0 → 18.7 ms, invoke 평균은 16.5 → 15.9 ms였다. 분석 도구가 snapshot p95(66.7 → 108.8 ms)와 setValue 묶음 평균(18.6 → 26.0 ms)을 DEGRADING으로 표시한 것은 초반 1/4과 후반 1/4을 비교하기 때문이다. 후반 1/4의 27개 구간 중 18개가 사용 중 구간이었다. 분석 도구는 PC 사용에 따른 차이와 누적 저하를 구분하지 못한다.

**시작 후 약 17분에 처리량이 한 단계 내려갔고 원인은 확인하지 못했다.** 10~15번 구간은 초당 19.9회, snapshot p50 37.4 ms, 반복당 JVM CPU 14.0 ms, 스크립트 CPU 7.8 ms, 프로세서 속도는 명목의 100~112%(중앙값 110%)였다. 시작 후 처음으로 입력이 들어온 16번 구간을 지나 17번 구간부터는 초당 15.2회, p50 44.8 ms, JVM 22.0 ms, 스크립트 18.5 ms, 프로세서 속도 약 100%가 됐다. 시험 앱의 반복당 CPU는 35.8 ms와 34.0 ms로 거의 같았다. 이후 입력이 14분 동안 없던 구간에서도 돌아오지 않았고, 일부 사용 중 구간(32·33·81·88·111~117번 등)에서는 반복당 CPU가 JVM 15~20 ms, 스크립트 8~12 ms로 다시 낮아졌다. 같은 일을 하는 데 드는 CPU 시간이 프로세스별로 따로 변한 것이어서 P 코어 2개와 E 코어 8개인 CPU에서 프로세스가 놓인 코어나 주파수가 달라졌을 가능성이 있다. 코어별 기록이 없어 이번 계측으로는 확인할 수 없다.

**GC 일시정지는 약 42초마다 127 ms다.** GC 로그의 일시정지는 181회, 중앙값 127.0 ms, p95 185.9 ms, 최대 265.4 ms, 합계 21.0초(실행 시간의 0.29%)다. Object Copy가 중앙값 94.2 ms로 대부분을 차지했다. young 수거 뒤에 남는 객체는 중앙값 36.7 MiB이고 179회 중 177회에서 모두 age 1이었다. 한 번 살아남은 뒤 다음 수거 전에 죽는 객체가 eden의 약 15%라는 뜻이다. 아래 Heap 누수 확인에서 이 객체가 COM 호출마다 만드는 JNA 네이티브 버퍼의 정리용 객체임을 확인했다. 시각이 남은 느린 요청 799건 중 GC 일시정지와 겹친 것은 115건이다.

**Heap의 old 영역이 늘었고, 이 시험만으로는 누수 여부를 판정할 수 없었다.** 아래 Heap 누수 확인에서 도달 가능한 객체는 늘지 않는다는 것을 따로 확인했다. GC 로그 기준 old와 humongous 영역은 20회째 수거에서 20 MiB, 80회째 44 MiB, 120회째 108 MiB, 158회째(1시간 48분) 232 MiB로 점점 빠르게 늘었다. 이때 첫 concurrent mark와 mixed 수거 3회가 실행되어 112 MiB로 줄었고 종료 때는 128 MiB였다. 줄어든 절반은 young 수거가 치우지 못한 가비지다. 남은 약 100 MiB는 마킹 시점에 살아 있다고 판정된 객체인데, 사이클이 한 번뿐이어서 이 값이 계속 늘어나는지 알 수 없다. old 수거 뒤 young 일시정지 중앙값은 131.3 ms에서 78.4 ms(15회)로 줄었다. Heap committed는 508 MiB로 일정했다. Working set 증가(+58.7 MiB/h)는 old 영역이 차면서 committed 범위 안의 페이지를 처음 쓰는 것과 같은 방향이어서 단독으로 누수 지표가 되지 않는다.

Heap 밖의 지표는 안정적이었다. 워밍업 이후 private bytes는 +3.2 MiB/h(640.8 → 651.5 MiB), NMT 밖 네이티브는 +1.5 MiB/h, NMT committed는 +0.6 MiB/h였고 핸들은 563개 안팎, 스레드는 44~47개였다. 시험 앱의 private bytes는 +0.3 MiB/h였다. 측정 스크립트 프로세스의 private bytes는 +11.1 MiB/h로 늘었으며 분석 도구는 참고 항목으로 표시한다.

이 실행에서 분석 도구의 결함 하나를 찾아 고쳤다. `% Processor Performance`의 기준값은 논리 프로세서마다 32비트 값이고 `_Total`은 그 평균이어서, 한 프로세서의 값이 넘칠 때마다 2^32 / 프로세서 수만큼 되돌아간다. 2시간 동안 두 번 일어났고 그 구간의 속도가 -2%로 계산됐다. 기준값이 되돌아간 구간은 NOT AVAILABLE로 두도록 바꾸고 단위 시험에 넣었다(40개 통과).

원자료와 GC 로그에는 `-TopProcesses`로 기록한 프로세스 이름이 들어 있어 저장소에 넣지 않았다.

### 2026-11-23 Heap 누수 확인

2시간 시험에서 남은 의문은 old 영역의 증가가 누수인지였다. 같은 환경과 JAR로 16분 시험(`-IntervalSeconds 60 -SampleSeconds 60`)을 실행하면서 JVM 시작 후 84초, 509초, 873초에 클래스별 객체 집계를 떴다. 시점마다 `jcmd <PID> GC.class_histogram -all`(수거 없이 모든 객체), `jcmd <PID> GC.class_histogram`(전체 GC 뒤 도달 가능한 객체), 2초 뒤 같은 명령을 한 번 더 실행했다. 시험은 18,193회 반복에 실패 0회였다.

| 시점 | 반복 수 | 전체 GC 직후 | 2초 뒤 다시 전체 GC |
|---|---:|---:|---:|
| 84초 | 1,317 | 20.93 MiB | 7.12 MiB |
| 509초 | 9,616 | 4.31 MiB | 4.36 MiB |
| 873초 | 16,714 | 4.58 MiB | 4.39 MiB |

**도달 가능한 객체는 늘지 않았다.** 9,658회와 16,755회 사이에 4.36 MiB에서 4.39 MiB로 약 30 KB 늘었다. 늘어난 것은 String, byte 배열, HashMap 노드가 각각 70~100개다. `ActionDispatcher`가 중복 방지를 위해 보관하는 명령 ID(그 사이 약 48개, 세션당 상한 4,096개)와 집계 순간에 처리 중이던 요청의 객체로 설명되는 크기다. 에이전트가 붙잡고 있는 UIA 객체는 스냅샷 1개분(`Capture` 1개, 요소 약 20개)이었고 살아 있는 JNA `Memory`는 3개였다.

**GC 때 살아남는 객체는 JNA 버퍼의 정리용 객체다.** 84초 시점에는 직전 young 수거에서 12.8초가 지나 있었다. 전체 GC 직후 20.93 MiB 중 16.9 MiB가 `Cleaner$CleanerRef`(48바이트), `Memory$MemoryDisposer`(24), `WeakReference`(32), `ConcurrentHashMap$Node`(32), `Long`(24) 다섯 클래스였고 각각 약 109,000개였다. JNA `Memory` 하나에 160바이트가 딸려 있고, 버퍼가 죽은 것을 GC가 확인한 뒤에야 정리 스레드가 해제하므로 수거 한 번은 반드시 살아남는다. 2초 뒤에는 각각 약 18,500개로 줄었다.

반복 1회에 `Memory`가 427개 만들어진다. 그중 `PointerByReference` 193개와 `IntByReference` 172개는 `UiaCom`의 COM 호출 보조 메서드가 호출마다 새로 만들고 닫지 않는 버퍼다. 나머지 약 60개는 대부분 `try`로 바로 닫아 정리용 객체가 남지 않는다. 닫지 않는 버퍼를 반복당 370개로 잡고 2시간 시험의 수거 간격으로 계산하면 42초 × 초당 15회 × 370개 × 160바이트 = 35.6 MiB로, 그 시험에서 수거마다 살아남은 36.7 MiB와 맞는다. 이 버퍼는 아래 출력 버퍼 재사용에서 없앴다.

**old 영역 증가는 이 정리용 객체가 승격된 것으로 본다.** 살아남는 양이 survivor 공간을 넘으면 일부가 old로 승격된다. OpenJDK 17의 `ReferenceProcessor::discover_reference`는 발견 대상 영역 밖의 참조 객체를 일반 객체처럼 처리하므로, 같은 수거에서 old로 옮겨진 참조 객체는 대상 버퍼를 강한 참조처럼 붙잡고 concurrent mark까지 남는다. 2시간 시험에서 첫 concurrent mark의 참조 처리가 119 ms 걸렸고, 직후 NMT 밖 네이티브가 29.0 MiB에서 23.6 MiB로 줄었으며, old 영역의 절반만 회수된 것이 이 설명과 맞는다. 이 경로를 직접 재현하지는 않았다. 누적은 concurrent mark마다 정리되므로 상한이 있다.

**전체 GC 뒤에는 JVM이 작은 Heap으로 동작했다.** 첫 집계의 전체 GC 뒤 Heap committed가 508 MiB에서 28 MiB로, private bytes가 640 MiB에서 135 MiB로 줄었고 시험이 끝날 때까지 유지됐다. young 수거는 0.49초마다 중앙값 2.6 ms, 최대 6.6 ms였고 합계는 실행 시간의 0.54%였다. 다른 프로세스의 부하가 낮던 7개 구간에서 반복당 JVM CPU는 12.8~14.6 ms로 2시간 시험의 초기 구간(14.0 ms)과 같은 수준이었고, 100 ms 이상 걸린 요청은 합계 1건, snapshot 최대는 79~106 ms였다. 2시간 시험의 조용한 구간은 구간마다 1~4건, 최대는 대체로 170~230 ms였다. 기본 설정의 초기 Heap(물리 메모리의 1/64인 508 MiB)이 도달 가능한 객체 4.4 MiB인 이 에이전트에는 크다는 뜻이다. Heap 옵션을 지정한 실행은 아래 Heap 옵션 비교에 있다.

집계와 비교 결과는 `target\jna-leak-check`에 있다.

### 2026-11-23 UiaCom 출력 버퍼 재사용

위 확인에서 찾은 원인을 고쳤다. `UiaCom`은 COM 호출마다 `PointerByReference`나 `IntByReference`를 새로 만드는 대신 세션이 가진 버퍼 두 개를 다시 쓴다. 쓰기 전에 매번 0으로 지우므로, 호출 대상이 출력 값을 쓰지 않았을 때 0이나 null이 읽히는 것은 이전과 같다. 한 세션의 호출은 소유 스레드 하나에서만 일어나고, 각 값은 다음 호출 전에 읽는다.

`UiaComTest`에 가짜 COM 객체를 쓰는 시험 두 개를 추가했다. 수정 전에는 호출 5번에 서로 다른 버퍼 주소 5개가 넘어가 실패했고, 지우지 않고 재사용만 했을 때는 이전 호출의 값이 읽혀 실패했다. Maven `test`에 `-Ddesktop.jnaIT=true`를 주어 57개 중 54개 통과, 실패·오류 0, 건너뜀 3개(PowerShell·C# GUI 시험)였다. 실제 WPF 창을 쓰는 JNA 시험이 포함된다. JAR의 SHA-256은 `35952D53…`에서 `8F6433A3D3AA81DBDACB959D84A3EEAE25BA6A6A877F01CE6D50B45EBCD621BC`로 바뀌었다.

새 JAR로 10분 시험(`-IntervalSeconds 60 -SampleSeconds 60`)을 실행했다. 9,059회 반복에 실패 0회였다. 이전 JAR의 값은 같은 날 2시간 시험의 처음 10분이다.

| 항목 | 이전 JAR | 새 JAR |
|---|---:|---:|
| young 수거 횟수 (시작 60초 이후) | 18회 | 9회 |
| 수거 간격 | 31.6초 | 62.6초 |
| 일시정지 중앙값 | 74.3 ms | 3.7 ms |
| 일시정지 최대 | 99.7 ms | 5.2 ms |
| 수거 뒤 살아남은 객체 | 37.5 MiB | 0.10 MiB |
| 10분 동안의 일시정지 합계 | 1,434 ms | 44 ms |
| 10분 시점의 old + humongous 영역 | 20 MiB | 4 MiB |
| NMT 밖 네이티브 (처음 → 10분) | 13.3 → 19.8 MiB | 13.5 → 12.2 MiB |

간격·중앙값·최대·살아남은 객체는 young 영역 크기가 정해진 시작 60초 이후의 값이다. 새 JAR에서는 old 영역이 처음 8초에 1개 영역이 된 뒤 끝까지 그대로였다. 수거 간격이 늘어난 것은 반복당 할당량이 약 400 KB에서 300 KB로 줄었고 이 실행의 처리량이 낮았기 때문이다.

처리량과 CPU는 이 두 실행으로 비교할 수 없다. 새 JAR 실행은 처음부터 2시간 시험의 17분 이후와 같은 느린 상태(반복당 스크립트 CPU 16.6 ms)였고 10개 구간 중 5개에서 입력이 있었다. 같은 상태인 2시간 시험의 조용한 구간(초당 15.2회, 반복당 JVM CPU 22.0 ms, snapshot p99 79.7 ms, 100 ms 이상 요청이 구간마다 1~4건, snapshot 최대 170~230 ms)과 견주면, 새 JAR의 조용한 구간 5개는 초당 16.1회, JVM CPU 19.7 ms, p99 72.2 ms, 100 ms 이상 요청 0~1건(한 구간은 6건), 최대 87~137 ms였다. 한 번의 실행이라 참고값이다.

초기 Heap 508 MiB를 커밋하는 것은 그대로여서 private bytes는 630 MiB였다. Heap 옵션은 아래에서 비교했다. 결과는 `target\jna-buffer-fix`에 있다.

### 2026-11-23 Heap 옵션 비교

기본 설정의 JVM은 초기 Heap으로 물리 메모리의 1/64인 508 MiB를 시작할 때 커밋한다. `Test-JnaSoak.ps1`에 `-JvmOptions`를 추가하고, 버퍼 수정이 들어간 같은 JAR로 옵션마다 10분 시험을 실행했다. 세 실행 모두 실패 0회였다. 기본 옵션의 값은 위 출력 버퍼 재사용의 10분 시험이다.

| 항목 (10분 시점) | 기본 | `-Xms16m` | `-XX:+UseSerialGC -Xms16m` |
|---|---:|---:|---:|
| Private bytes | 630.4 MiB | 129.0 MiB | 62.8 MiB |
| Working set | 381.0 MiB | 93.7 MiB | 79.5 MiB |
| Heap 커밋 | 508.0 MiB | 24.0 MiB | 16.0 MiB |
| GC 보조 구조 (NMT의 GC 항목) | 72.9 MiB | 54.4 MiB | 0.1 MiB |
| NMT의 나머지 항목 | 37.3 MiB | 37.3 MiB | 36.9 MiB |
| 스레드 | 36개 | 35개 | 22개 |
| GC 일시정지 횟수 | 11회 | 365회 | 601회 |
| 일시정지 중앙값 / 최대 | 4.3 / 8.4 ms | 3.2 / 8.2 ms | 0.7 / 2.4 ms |
| 일시정지 합계 (실행 시간 대비) | 44 ms (0.01%) | 1,139 ms (0.19%) | 423 ms (0.07%) |
| 반복당 JVM CPU (구간 중앙값) | 19.7 ms | 19.9 ms | 19.1 ms |

초기 Heap만 줄여도 private bytes가 501 MiB 줄었다. G1은 Heap이 24 MiB여도 보조 구조에 54 MiB를 쓰고, Serial GC는 거의 쓰지 않아 다시 절반이 된다. Heap이 작으면 수거가 0.9~1.6초마다 일어나지만 한 번이 짧아 반복당 JVM CPU는 달라지지 않았다. 세 실행 모두 전체 GC는 없었고 최대 Heap은 기본값 그대로다.

지연은 조용한 구간(입력 후 60초가 지나고 시험 창이 전경)끼리 비교했다.

| 조용한 구간 중앙값 | 기본 (5개 구간) | `-Xms16m` (9개) | Serial (2개) |
|---|---:|---:|---:|
| 처리량 | 초당 16.1회 | 초당 15.6회 | 초당 15.2회 |
| Snapshot p50 | 43.3 ms | 43.9 ms | 44.5 ms |
| Snapshot p95 | 61.6 ms | 60.2 ms | 61.8 ms |
| Snapshot p99 | 72.2 ms | 74.2 ms | 107.0 ms |

`-Xms16m`는 기본과 차이가 없다. Serial 실행은 3번 구간부터 PC를 써서 조용한 구간이 2개뿐이고 그중 하나에 다른 프로세스의 부하가 있었다. GC 일시정지가 최대 2.4 ms여서 GC가 지연을 늘릴 여지는 없지만, 지연이 같다는 것을 이 실행으로 확인하지는 못했다.

`-XX:+UseSerialGC -Xms16m`를 권장 옵션으로 정하고 README의 실행 명령과 장시간 시험 명령에 넣었다. 그 뒤에 확인한 것은 다음과 같다.

- README의 방식으로 Agent를 띄워 조회 요청 두 개를 보낸 직후의 private bytes는 기본 백엔드가 620.7 MiB에서 55.4 MiB, JNA 백엔드가 636.2 MiB에서 67.6 MiB였다. 네 실행 모두 두 요청에 정상 응답하고 종료 코드 0으로 끝났다. C# 워커 경로는 이 체크아웃에 워커 빌드가 없어 실행하지 않았다.
- 비교 시험 때는 측정 도구가 Serial GC의 `GC.heap_info` 형식을 읽지 못해 그 실행의 Heap used와 committed가 NOT AVAILABLE이었다. 도구가 Serial GC의 두 세대를 읽도록 고친 뒤 권장 옵션으로 3분 시험을 실행했다. 2,681회 반복에 실패 0회였고 모든 구간에 Heap 커밋 16.0 MiB와 사용량 3.5~5.5 MiB가 기록됐다. GC 일시정지는 201회, 중앙값 0.4 ms, 최대 2.3 ms였다.
- Serial GC에서 길어질 수 있는 일시정지는 전체 수거다. 10분 시험에는 전체 수거가 없어, 2분 시험 중에 `GC.class_histogram`으로 두 번 일으켰다. 도달 가능한 객체 3.3 MiB에서 16.0 ms와 30.0 ms였다. 10분 시험에서 tenured 사용량은 2.7 MiB에서 3.3 MiB로 늘었고, 이 속도면 첫 전체 수거는 약 2시간 뒤다.
- PowerShell 도구 시험과 Python 분석 도구 시험 42개가 통과했다.

남은 제약은 다음과 같다. 요소 20개인 시험 창과 10분 이하의 시험만 했다. Serial 실행의 지연은 조용한 구간이 부족해 기본 설정과 같다는 것을 확인하지 못했다. 권장 옵션으로 장시간 시험을 실행해 확인해야 한다. 결과는 `target\jna-heap-options`에 있다.

## 2026-11-23 PR #2 헤드 재검증

PR #2의 소스 커밋 `2824aa1`과 로컬 `HEAD`가 일치함을 확인했다. Windows 11 Pro x64 빌드 26200에서 C# 워커를 다시 빌드하고, PowerShell·C#·JNA의 실제 WPF 시험을 활성화해 현대 Maven `verify`를 재실행했다.

| 검사 | 안정화 검증 | PR 헤드 재검증 |
|---|---:|---:|
| 현대 Maven 전체 | 55개 통과 | 55개 통과 |
| 실제 WPF GUI, Maven 전체에 포함 | 4개 통과 | 4개 통과 |
| Maven 실패 / 오류 / 건너뜀 | 0 / 0 / 0 | 0 / 0 / 0 |
| 패키징된 JNA 모의 COM 검사 | 통과 | 통과 |
| PowerShell 시험 도구 | 2개 통과 | 2개 통과 |
| 레거시 Java 및 읽기 전용 계약 | 4개 + 7개 통과 | 4개 + 7개 통과 |

### 세 백엔드 단기 성능 재측정

두 실행에서 동일한 Windows·JDK와 WPF 시험 앱을 사용했고, 세 백엔드 모두 제목 표시줄을 제외한 19개 요소의 트리와 실제 변경 결과를 확인했다. 백엔드별로 새 프로세스에서 첫 스냅샷 2회, 지속 세션 2개에서 각각 10회를 측정했다. 실행 순서는 무작위였으며, 재검증 때 다시 패키징한 JAR와 다시 빌드한 C# 워커를 사용했다.

| 지표, 이전 → 재측정 | PowerShell | C# Worker | Java/JNA |
|---|---:|---:|---:|
| 첫 스냅샷 응답 중앙값 (ms) | 991.9 → 1,003.4 | 621.1 → 611.6 | 497.5 → 517.3 |
| 지속 세션 스냅샷 p50 (ms) | 92.4 → 91.3 | 54.6 → 57.4 | 57.7 → 50.0 |
| 지속 세션 스냅샷 p95 (ms) | 111.5 → 116.7 | 57.5 → 70.6 | 73.6 → 66.2 |
| `Invoke` p50 (ms) | 21.6 → 20.3 | 17.8 → 16.8 | 14.1 → 20.2 |
| `SetValue` p50 (ms) | 21.3 → 21.8 | 18.4 → 18.9 | 19.3 → 18.3 |
| 작업 집합 중앙값 (MiB) | 192.6 → 191.3 | 128.8 → 127.9 | 105.7 → 105.5 |
| 10회 반복 구간 CPU 시간 중앙값 (ms) | 1,156.3 → 1,101.6 | 421.9 → 398.4 | 500.0 → 406.3 |

JNA의 첫 스냅샷 응답과 작업 집합은 두 실행 모두 가장 낮았다. 지속 세션 스냅샷과 `Invoke`의 C#·JNA 순위는 실행 사이에 바뀌었다. 시료가 적고 실행 순서도 달라, 지연 차이는 반복 간 변동으로 기록한다. CPU와 작업 집합은 JVM과 해당 워커의 합계다. [이전 원본](test-results/windows-uia-benchmark-jna-stabilization.json) · [재측정 원본](test-results/2026-11-23-pr-2-benchmark-recheck.json)

### JNA 60초 반복 시험 재측정

일반 WPF 창에서 단일 JVM으로 반복 횟수는 958회에서 992회로 바뀌었다. 두 실행 모두 실제 변경 11쌍, 실패 0회, 정상 종료를 기록했다. 스냅샷 p95는 61.9ms에서 58.0ms로, p99는 89.6ms에서 72.3ms로 낮아졌다. 첫·마지막 표본 사이 private bytes 증가량은 13.3MiB에서 15.8MiB로 바뀌었다. 두 실행 모두 60초 관측이므로 장기 메모리 추세는 별도 시험이 필요하다. [이전 원본](test-results/windows-uia-jna-soak-stabilization.json) · [재측정 원본](test-results/2026-11-23-pr-2-jna-soak-recheck.json)

## JNA 안정화 회귀 검증

Windows 11 Pro x64 빌드 26200, JDK 21.0.11, Maven 3.9.9 및 .NET Framework 4.8 대상 C# 워커에서 검증했다.

| 검사 | 결과 |
|---|---|
| 현대 Maven 빌드 및 시험 | 55개 통과. 실패·오류·건너뜀 각 0개 |
| 실제 WPF 통합 시험 | 4개 통과. 세 백엔드의 변경 결과와 커서 좌표, 일반 창의 콘텐츠 트리 비교, JNA 하위 트리 재수집과 잘림 오류 처리 포함 |
| 패키징된 JNA의 모의 COM 공급자 시험 | 같은 창 안에서 부모가 바뀐 요소, 보호 상태 변경, 부분 캡처 실패 시 참조 해제, 네이티브 타임아웃, 이미 타임아웃된 사전 검사에서의 늦은 변경 차단 통과 |
| Windows PowerShell 5.1 시험 도구 | 상태 파일 동시 읽기, 결과 JSON 공유 잠금·체크포인트, 분위수 및 트리 비교를 검증하는 두 스크립트 통과 |
| 레거시 Java | JDK 11에서 테스트 4개 및 패키징된 JAR의 읽기 전용 계약 7개 통과 |

일반 WPF 창의 25 대 20 차이는 다시 재현됐다. 역할, AutomationId, 이름, 부모 경로가 일치하는 WPF 콘텐츠는 19개였다. PowerShell과 C#은 제목 표시줄과 자식 5개를, JNA는 제목 표시줄 노드 하나를 반환했다. .NET 클라이언트 측 프록시가 시스템 메뉴와 창 제어 버튼을 추가하는 경로를 소스에서 확인했다. [제목 표시줄 차이와 SDK 검토](JNA.md)

기존 `fixture.log`는 프로세스 출력 핸들이 남아 임시 디렉터리 정리에 실패한 기록이 있다. 통합 시험은 이제 출력을 파이프로 소비하고 종료 후 진단을 수집한다. WPF 상태 파일은 동시 읽기가 기존 덮어쓰기를 막는 공유 위반을 재현해 원자적 교체로 전환했다. 이전 벤치마크의 WPF 종료에는 로그가 없어 같은 원인이었는지 확인할 수 없다.

### 최종 빌드 단기 성능

제목 표시줄을 제외한 WPF 트리 19개가 일치했다. 각 백엔드에서 새 프로세스로 첫 스냅샷을 2회 측정하고, 지속 세션 2개에서 워밍업 뒤 각 10회 반복했다. CPU와 작업 집합은 JVM과 해당 워커의 합계이며, 작업 집합은 공유 페이지가 중복으로 계산될 수 있다.

| 지표 | PowerShell | C# Worker | Java/JNA |
|---|---:|---:|---:|
| JVM 시작부터 첫 스냅샷 응답까지 중앙값 | 991.9 ms | 621.1 ms | 497.5 ms |
| 지속 세션 스냅샷 p50 / p95 | 92.4 / 111.5 ms | 54.6 / 57.5 ms | 57.7 / 73.6 ms |
| 지속 세션 `Invoke` p50 | 21.6 ms | 17.8 ms | 14.1 ms |
| 지속 세션 `SetValue` p50 | 21.3 ms | 18.4 ms | 19.3 ms |
| 세션 종료 직전 작업 집합 중앙값 | 192.6 MiB | 128.8 MiB | 105.7 MiB |
| 10회 반복 구간 CPU 시간 중앙값 | 1,156.3 ms | 421.9 ms | 500.0 ms |

같은 장비의 짧은 실행으로, 시작 시간과 작업 집합은 JNA가 가장 낮았고 지속 세션 스냅샷은 C#이 빨랐다. [최종 벤치마크 JSON](test-results/windows-uia-benchmark-jna-stabilization.json)

### JNA 60초 반복 시험

일반 WPF 창에서 JVM 하나로 958회 반복을 완료했다. 입력값 설정과 버튼 실행을 함께 수행하는 변경 11쌍을 확인했고 실패는 0회였다. 스냅샷 p95는 61.9 ms, p99는 89.6 ms였다. 프로세스 표본 7개를 수집하고 CLI가 EOF로 정상 종료됨을 확인했다.

약 59초의 첫·마지막 표본 사이에 private bytes는 13.3 MiB, working set은 138.4 MiB, NMT committed는 10.0 MiB 증가했다. 핸들은 2개, 스레드는 3개 감소했고 JVM 힙 committed는 같았다. 시작 구간의 단기 변화만으로 장기 누수 여부를 판단할 수 없으며, HotSpot NMT는 COM 객체를 직접 계수하지 않는다. [JNA 반복 시험 JSON](test-results/windows-uia-jna-soak-stabilization.json)

### 재현 명령

```powershell
.\tools\Test-WindowsUia.ps1 -IncludeJna
.\tools\Compare-UiaWorkers.ps1 -CSharpWorker .\workers\csharp\bin\Release\UiaWorker.exe -IncludeJna `
    -ColdRuns 2 -Sessions 2 -Iterations 10 -OutputPath .\target\windows-uia-benchmark.json
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromHours(8)) -OutputPath .\target\windows-uia-jna-soak.json
```

8시간 반복, 실제 설비 앱, x86 JVM과 Windows XP·CentOS 5, 실제 네이티브 영구 정지 및 JVM 충돌의 복구는 미검증이다. PowerShell은 기본값으로 유지한다.

## 2026-11-22 로컬 Windows 실기기 검증

`main` 커밋 `fefcb53`을 Windows 11 Pro x64 빌드 26200에서 검증했다. 현대 빌드에는 JDK 21.0.11과 Maven 3.9.9를 사용했고, C# 워커는 MSBuild로 .NET Framework 4.8 대상 Release 빌드를 생성했다.

| 검증 | 결과 |
|---|---|
| 현대 Maven 빌드 및 패키징 | 45개 통과. 실패·오류·건너뜀 각 0개 |
| 실제 WPF GUI | PowerShell, C# Worker, Java/JNA 각각 통과. 창·트리 조회, 요소 검색, 버튼 이벤트 1회, 실제 텍스트 변경, 두 동작 전후 물리 커서 좌표 일치를 확인 |
| 워커 장애 및 변경 명령 중복 방지 | PowerShell과 C#에서 워커 강제 종료 후 복구, 변경 응답 유실 후 동일 명령 재실행 차단을 확인 |
| 패키징한 JNA 세션 및 C# 워커 프로토콜 | 모의 COM 트리로 JNA 세션 검사 통과. C# 워커는 비정상·초과 프레임 거부 후 후속 요청에 정상 응답 |
| 레거시 Java | JDK 11로 Java 7 대상 빌드 및 테스트 4개 통과. 패키징한 레거시 JAR는 읽기 전용 프로토콜 7개 통과. 클래스 229개 모두 major 51 |

첫 실행에서는 JNA 동작 검증 후 JUnit이 잠긴 `fixture.log`를 삭제하지 못했다. 같은 명령을 재실행했을 때 오류는 재현되지 않았다. 레거시 빌드는 JDK 21에서 `--release 7`을 지원하지 않아 JDK 11로 재실행했다.

### PowerShell, C# Worker, Java/JNA 단기 성능

기존 WPF 창에서는 두 워커가 25개, JNA가 20개 요소를 반환했다. 차이는 제목 표시줄 하위의 시스템 메뉴와 창 제어 버튼이었다. 제목 표시줄을 제거한 전용 WPF 창에서 세 백엔드의 19개 요소가 역할, AutomationId, 부모 경로 기준으로 일치함을 확인하고 다시 측정했다. 백엔드별로 새 프로세스에서 요청 종류당 5회, 지속 세션 3개에서 워밍업 1회 후 20회씩 측정했다. 총 180회 반복에서 입력값 변경과 버튼 카운터 증가를 확인했다.

| 지표 | PowerShell | C# Worker | Java/JNA |
|---|---:|---:|---:|
| 프로세스 시작부터 첫 스냅샷 응답까지 중앙값 | 955.4 ms | 638.3 ms | 462.6 ms |
| 지속 세션 `snapshot` p50 / p95 | 89.0 / 106.3 ms | 56.9 / 76.9 ms | 49.7 / 59.8 ms |
| 지속 세션 `invoke` p50 | 20.6 ms | 16.9 ms | 14.2 ms |
| 지속 세션 `setValue` p50 | 15.3 ms | 12.9 ms | 9.8 ms |
| 세션 종료 직전 작업 집합 중앙값 | 196.6 MiB | 130.1 MiB | 106.8 MiB |
| 세션 반복 구간 CPU 시간 중앙값 | 2,000.0 ms | 1,078.1 ms | 828.1 ms |

지연은 CLI 요청부터 응답까지의 시간이다. CPU와 작업 집합은 JVM과 별도 워커를 합산했으며, JVM 내부에서 실행되는 JNA는 JVM만 측정했다. 합산 작업 집합은 프로세스가 공유하는 페이지를 중복 계산할 수 있다. 표의 지표는 모두 JNA가 가장 낮았지만, 이 단일 장비의 단기 결과로 장시간 안정성을 판단할 수는 없다.

제목 표시줄을 제거한 첫 시험에서는 WPF 앱이 도중에 종료됐다. 종료 로그를 수집하도록 설정한 재실행에서는 세 백엔드가 모두 완료했고 오류 로그는 비어 있었다. 장시간 안정성, 실제 설비 앱, Windows XP SP3 및 CentOS 5에서의 실행은 미검증이다.

### 실행 명령과 로컬 보고서

```powershell
.\tools\Test-WindowsUia.ps1 -IncludeJna
.\target\Compare-UiaBackends-Matched.ps1 -CSharpWorker .\workers\csharp\bin\Release\UiaWorker.exe -ColdRuns 5 -Sessions 3 -Iterations 20
```

GUI 결과는 `target/surefire-reports/TEST-dev.desktop.WindowsGuiTest.xml`, 실행 환경은 `target/windows-uia-run.json`에 있다. 3종 벤치마크는 `tools/Compare-UiaWorkers.ps1`을 확장한 로컬 시험용 사본으로 실행했다. 기존 WPF 창의 트리 비교는 `target/windows-uia-tree-comparison.json`에 있다. 레거시 빌드는 JDK 11 환경에서 `mvn -f legacy/pom.xml clean verify`로 실행했다. [성능 측정 원본 JSON](test-results/2026-11-22-windows-uia-benchmark.json)

## JNA 직접 COM 어댑터 추가 후 검증

2026-11-21, Debian x86_64. OpenJDK 21과 Maven 3.9.11로 현대 JAR의 Java 17 대상 빌드를 검증했다.

| 검사 | 결과 |
|---|---|
| 현대 프로젝트 `mvn clean verify` | 총 45개 중 42 통과, 실패·오류 0, Windows GUI 3 미실행 |
| JNA 단위 검사 | 모의 함수 포인터에 대한 실제 JNA 호출, HRESULT·GUID·UTF-16 처리, 참조 해제, MTA 소유 스레드와 변경 시간 초과 시 중복 방지 |
| 패키징한 세션과 모의 COM 트리 | 창과 트리 열거, 편집 정보 마스킹, 두 패턴의 상태 변화, 스냅샷 교체·조상 변경·PID 재검증, 참조 정리 통과. [재현 명령](../tools/jna-session-check/README.md) |
| 배포 JAR | JNA의 x86·x64 Windows DLL을 원본과 바이트 단위 비교, PE 머신 타입과 라이선스 고지 확인. Linux에서 명시적 JNA 선택 시 capability 미가용, 창 조회는 BACKEND_UNAVAILABLE |
| 레거시 회귀 | `mvn -f legacy/pom.xml clean verify` 4 통과. 레거시 JAR 클래스 229개 모두 major 51. Linux x64 Java 7에서 모의 워커로 창 열거 및 변경 거부 확인 |
| 읽기 전용 프로토콜 | `tools/check-readonly-contract.py`로 현대·레거시 JAR 각각 7개 사례 통과 |
| 실제 Windows COM·GUI, 성능·메모리·장기 실행, XP SP3, CentOS 5 | **NOT TESTED** |

Windows 10/11에서 세 백엔드의 같은 WPF 시험을 실행하는 명령은 다음과 같다. 잠금을 해제한 데스크톱에서 프로젝트 루트를 작업 디렉터리로 사용한다.

```powershell
.\tools\Test-WindowsUia.ps1 -IncludeJna
```

세 GUI 사례가 모두 통과해야 실제 앱의 버튼 이벤트 횟수, 텍스트 변경, 커서 좌표 유지가 확인된다. 성공 시 환경과 실행 사례가 `target/windows-uia-run.json`에 기록된다.

## 이전 워커 및 공통 Core 빌드 기록

2026-11-21 UTC, 공통 Java Core 개편 후 전체 빌드. Codex Cloud Debian 13 x86_64, OpenJDK 21.0.13, Apache Maven 3.9.11. Java 컴파일 대상을 17로 설정했다. Windows 장비는 연결되지 않았다.

| 대상 | 결과 | 확인한 내용 |
|---|---|---|
| Maven `clean verify` | 성공 | 본체와 테스트 컴파일, 실행형 `target/desktop-agent.jar` 패키징 |
| AgentTest, 가짜 DesktopAdapter | 15 통과 | 정확 일치·중복·불완전한 트리 처리, 참조 트리와 TTL·교체·재시작 무효화, 한도·정책·패턴 검사, 변경 결과 불명확 및 재전송 거부, 비공개 필드 차단과 잘못된 트리 거부 |
| DesktopAdapterTest | 3 통과 | 기존 JSON 어댑터와 신규 메서드 기반 어댑터 간 호출 호환성, 잘못된 요청 거부 |
| DesktopAdaptersTest | 1 통과 | Windows 선택 및 Linux·미지원 OS에서 미가용 보고 |
| DesktopContractTest | 2 통과 | PID·창 ID·자식 순서가 다른 모의 공급자 두 구성에 동일 JSON 시나리오 적용. 참조·오류·변경 횟수 및 마지막 입력값 비교 |
| WindowsTransportTest, Linux의 자식 JVM | 5 통과 | 세션 재사용, 프로세스 사망 후 복구, 손상된 응답, 읽기 및 쓰기 정지 시 시간 제한, 실행 파일이 없을 때 capability |
| CliTest | 4 통과 | C# 워커 지정 및 경로 검사, 잘못된 JSON·중복 키·연결된 객체·크기 초과 뒤 다음 요청 처리, UTF-8 검사, 잘못된 정책 거부 |
| WindowsGuiTest | 2 건너뜀 | 두 워커에 같은 WPF 시험 적용. Linux에서 두 시험을 명시적으로 활성화하면 환경 검사 실패 |
| C# 워커 컴파일 | 성공 | Roslyn, C# 5, NuGet의 Microsoft.NETFramework.ReferenceAssemblies.net48 1.0.3. WindowsBase·UIAutomationClient·UIAutomationTypes 포함 실제 Microsoft 참조 어셈블리에 바인딩한 AnyCPU 콘솔 EXE 생성 |
| C# 워커 프로토콜 | 성공 | 같은 EXE를 Linux의 Mono 6.12에서 실행. 잘못된 JSON 및 크기 초과 프레임 거부 후 후속 요청 성공, 오류 응답의 입력 마스킹, UIA 미가용 보고 검사. 실행 스크립트는 `workers/csharp/tests/protocol_smoke.py` |
| C# 워커 로직 | 모의 공급자 시험 통과 | 같은 UiaWorker.cs를 테스트용 요소와 함께 컴파일해 트리·마스킹·Invoke/Value·참조 재검증 확인. [재현 명령](../workers/csharp/tests/README.md) |
| 성능·메모리·장기 실행 | 미측정 | Windows에서 두 워커의 동일 작업량 비교가 필요. JNA 직접 연동은 설계 검토 단계 |
| 패키징한 JAR의 로컬 CLI | 성공 | 같은 프로세스에서 getCapabilities → available=false, listWindows → BACKEND_UNAVAILABLE, mouseClick → UNKNOWN_OPERATION |
| 패키지 내용 | 확인 | CLI 클래스 파일 버전 61(Java 17), 원본과 일치하는 UIA 워커, Jackson 라이선스 고지 포함 |
| PowerShell 작업 코드 | Linux에서 보조 검증 | PowerShell 7.6.9 구문 검사, UIA 부재 시 오류 응답 확인. 메모리상의 모의 공급자로 순회, 배열 형태, 값 마스킹, 두 패턴 호출, 오래된 참조 거부 확인 |
| Windows PowerShell 5.1 및 실제 UIA | **미실행** | 실제 창 열거, WPF 공급자의 패턴 실행, 커서 좌표 유지 및 실기기 지연은 미검증 |

Surefire 집계는 총 32개, 성공 30개, 실패 0개, 오류 0개, 건너뜀 2개다. 테스트 보고서는 빌드 후 `target/surefire-reports/`에서 볼 수 있다. Cloud에서는 임시 디렉터리에 준비한 JDK·Maven·로컬 저장소로 오프라인 빌드를 수행했다.

## Windows에서의 합격 판정

1. Windows 10 또는 11의 잠금 해제된 대화형 데스크톱에서 JDK 11 이상과 Maven을 준비한다. 테스트 중 다른 사용자가 마우스를 움직이지 않아야 한다.
2. 프로젝트 루트의 PowerShell에서 아래 명령을 실행한다. 테스트가 전용 WPF 앱을 열고, 실제 창 제목과 PID로 앱을 식별한다.
3. 시험은 스냅샷 참조로 편집 요소와 버튼을 찾아 두 패턴을 호출한다. WPF TextChanged 이벤트가 기록한 값, Click 이벤트의 카운터(0 → 1), GetPhysicalCursorPos로 읽은 실행 전후 좌표를 각각 검사한다. 중복 이름·패턴 미지원·중복 명령·민감한 입력값 노출도 검사한다.
4. 두 백엔드를 함께 활성화하면 `WindowsGuiTest`의 시험이 2개 실행되고 실패·오류·건너뜀이 모두 0이어야 한다. 시험 앱의 성공은 해당 Windows 빌드와 WPF 공급자 조합에 대한 결과다.

```powershell
$worker = (Resolve-Path '.\workers\csharp\bin\Release\UiaWorker.exe').Path
mvn '-Ddesktop.windowsIT=true' '-Ddesktop.csharpIT=true' "-Ddesktop.csharpWorker=$worker" '-Dtest=WindowsGuiTest' test
```

Cloud에서는 Roslyn으로 C# 소스를 직접 빌드했다. Windows MSBuild 프로젝트 실행, .NET Framework 4.8 런타임, Windows 10/11 실기기, XP·CentOS 5를 포함한 레거시 이미지, 32비트 JVM, 실제 장비 애플리케이션, 잠금 및 권한이 다른 세션, 장시간 리소스 사용량은 후속 시험 대상이다.

## Windows 실기기 준비 및 레거시 PoC 최종 검증

현대 Maven 30 통과·Windows GUI 2 미실행, 레거시 Maven 4 통과. 두 배포 JAR에서 같은 읽기 전용 프로토콜 7개 사례를 각각 통과했다. 레거시 JAR 내부 클래스 229개는 모두 major 51이며 Debian x64 Zulu 7u352에서 -Xverify:all로 모의 워커의 조회 성공과 변경 명령 거부를 확인했다. C# 재컴파일·Mono 프로토콜·모의 UIA 회귀 시험, XP x86 PE 정적 검사와 호스트에서의 문자열 직렬화 시험이 통과했다.

Windows 전용 시험은 두 워커에 같은 WPF 컨트롤과 테스트 전용 파이프 릴레이를 사용한다. 컨트롤 교체 후 stale, 비활성·읽기 전용 조작 거부, 워커 강제 종료 후 복구, 실제 변경 응답을 보류한 뒤 동일 명령이 다시 실행되지 않는지를 앱 상태로 검사한다. Windows 실기기, 커서, 성능, 장기 안정성, XP SP3 및 CentOS 5는 모두 NOT TESTED다. Debian 더미 Xorg에서 X11 읽기는 성공했고 기본 셸에서는 DISPLAY와 AT-SPI1 런타임이 없었다.
