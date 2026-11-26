# C++ Native Desktop Automation Agent

Windows 11 x64용 독립 CLI다. 실행 파일은 Windows UI Automation COM에 직접 연결한다. MSVC의 C/C++ 런타임을 정적으로 링크하며 Java, JNA, .NET, PowerShell 설치가 필요 없다. 비교 도구는 Java/JNA와 기존 WPF 시험 앱을 띄우기 위해 Java와 Windows PowerShell을 사용한다.

## 빌드와 실행

Visual Studio 2022의 C++ 데스크톱 개발 워크로드, Windows SDK, CMake 3.20 이상이 필요하다. 저장소 루트의 Developer PowerShell에서 실행한다.

```powershell
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
```

빌드에서 사용하는 nlohmann/json 3.12.0 단일 헤더와 MIT 라이선스는 `third_party/nlohmann`에 포함되어 있다. CMake 구성에서 패키지를 다운로드하지 않는다. 공식 헤더의 SHA-256은 `aaf127c04cb31c406e5b04a63f1ae89369fccde6d8fa7cdda1ed4f32dfc5de63`이다. [공식 릴리스](https://github.com/nlohmann/json/releases/tag/v3.12.0)

실행 파일의 stdin으로 UTF-8 JSON 한 줄씩 보내고 stdout에서 같은 순서로 응답을 읽는다. 예시는 한 번의 읽기 전용 세션을 열고 입력을 닫는다.

```powershell
'{"id":"1","op":"getCapabilities"}','{"id":"2","op":"listWindows"}' |
  & ./target/cpp-agent/Release/cpp-agent.exe
```

변경하려면 승인된 대상 PID와 필요한 액션을 시작할 때 지정한다. `1234`를 실제 PID로 바꾼다. 후속 요청은 같은 프로세스의 stdin/stdout으로 교환한다.

```powershell
./target/cpp-agent/Release/cpp-agent.exe --allow-pid 1234 --allow-action invoke --allow-action setValue
```

Swing과 AWT 창은 Java Access Bridge 백엔드로 연다. `--backend uia`가 기본값이다. `--jab-dll`로 브리지 DLL의 절대 경로를 지정할 수 있고, 생략하면 Windows 시스템 디렉터리와 `HKLM\SOFTWARE\JavaSoft`에 등록된 Java 설치에서 찾는다. 이 백엔드는 대상 PC에 브리지 DLL이 있어야 하고 대상 JVM이 브리지를 켜야 한다.

```powershell
./target/cpp-agent/Release/cpp-agent.exe --backend jab --allow-pid 1234 --allow-action invoke --allow-action setValue
```

`--backend multi`는 UIA, JAB, MSAA를 한 프로세스에서 함께 연다. `snapshot` 요청의 `backend`로 `UIA`, `JAB`, `MSAA`를 고른다. 단독 MSAA는 `--backend msaa`로 실행한다. [MSAA 참조 정책](../../docs/MSAA-ADAPTER.md) [Multi-Backend](../../docs/MULTI-BACKEND.md)

```powershell
./target/cpp-agent/Release/cpp-agent.exe --backend multi --allow-pid 1234 --allow-action invoke --allow-action setValue
```

물리 입력(SendInput)은 `--allow-action pointer`, `keyboard`, `activate`로 켠다. 허용한 세션만 `getCapabilities`에 `input` 객체와 입력 연산(`activateWindow`, `pointerMove`, `pointerClick`, `pointerDrag`, `pointerScroll`, `clickElement`, `keyPress`, `keyDown`, `keyUp`, `typeText`)이 붙고, 허용하지 않은 세션의 응답은 이전과 같다. 입력 전 검증 순서, 좌표, 오류 필드(`inputSent`, `released`)는 [물리 입력](../../docs/PHYSICAL-INPUT.md)을 따른다.

```powershell
./target/cpp-agent/Release/cpp-agent.exe --backend multi --allow-pid 1234 --allow-action pointer --allow-action keyboard --allow-action activate
```

`getCapabilities`, `listWindows`, `snapshot`, `findElement`, `getElementInfo`, `invoke`, `setValue`를 제공하며 MSAA는 별도로 `defaultAction`과 `select`를 제공한다. `windowId`는 조회 결과에서, `snapshotId`와 `ref`는 최신 스냅샷에서 가져온다. 지원 필드와 오류 코드, 같은 세션에서의 요청 순서는 [공통 API](../../docs/API.md)에 있다.

## 세션 동작

- `src/protocol`은 UTF-8 NDJSON 프레임을 읽고 중복 키와 연결된 JSON 객체를 거부한다. 입력 줄 한도는 65,536바이트이며 초과한 프레임은 줄 끝까지 소모한다. 문자열 한도는 Java와 같은 UTF-16 코드 단위로 센다. JSON 중첩은 128단계로 제한하며 짝이 없는 Unicode surrogate escape는 거부한다.
- `src/core`는 Locator, 최신 스냅샷의 참조와 120초 만료, 액션 허용 정책, 4,096개의 명령 ID 기록, 요청 기한을 관리한다. 참조는 세션별 GUID에서 파생된 불투명 문자열이다. 새 조회가 Adapter에 전달되면 기존 참조를 폐기한다. 유휴 중 TTL이 만료되면 소유 스레드에서 네이티브 캐시도 해제한다.
- `src/windows`는 Control View, HWND와 프로세스 시작 시각, Runtime ID, 조상 경로를 검증하는 Adapter다. 창 목록은 데스크톱 직계 창 뒤에 소유 창(모달, 팝업)을 `ownerWindowId`와 함께 덧붙이고, 하위 트리가 잘린 요소에는 `partial`을 표시한다. 원인과 검증은 [UIA Agent 결함 분석](../../docs/UIA-AGENT-DEFECTS.md)에 있다. 창의 시작 시각을 읽을 권한이 없으면 해당 창의 스냅샷이나 참조 재검증을 거부할 수 있다. 편집·비밀번호·ValuePattern 요소의 이름을 가리고 하위 트리를 건너뛴다. Value 속성을 읽지 않는다.
- `src/windows/jab_adapter.cpp`는 Java Access Bridge Adapter다. 같은 세션 스레드가 브리지 DLL을 로드하고 모든 호출과 창 메시지 처리를 맡으며, 요청이 없을 때도 250 ms마다 메시지를 처리한다. 받은 컨텍스트 핸들은 한 번씩 반환하고, 응답하지 않는 JVM의 핸들은 보류한다. 그런 JVM이 있으면 DLL을 내리지 않고 프로세스를 끝낸다. 요소 모델과 제약은 [Java Access Bridge Adapter](../../docs/JAVA-ACCESS-BRIDGE.md)에 있다.
- `src/core/multi_session.cpp`는 multi 모드의 라우터다. 백엔드마다 `SessionWorker` 하나(스레드, Adapter, 최신 스냅샷)를 두고 명령 ID 기록만 공유한다. 참조와 스냅샷 ID의 접두사로 발급한 백엔드를 가려 그 워커로만 전달한다. 기한을 넘긴 UIA·MSAA 워커는 스레드가 끝난 뒤 새 워커로 바뀌고, JAB 워커는 바꾸지 않는다.
- `src/core/input.cpp`는 입력 요청 검증, 키 이름, 가상 데스크톱 정규화, `clickElement`의 bounds 대응을 플랫폼과 무관하게 처리한다. `InputDriver` 하나를 세션의 모든 워커가 공유하며, 시험은 가짜 드라이버를 쓴다. `src/windows/input_driver.cpp`는 Windows 구현이다. 새 DPI API는 실행 중에 찾으므로 Windows 7과 x86에서도 로드된다. 저수준 훅은 첫 입력 직전에 전용 스레드에 설치하고, 세션이 끝나면 `keyDown`으로 누른 키를 떼고 훅을 제거한다. CTest의 `input-driver-status`는 입력을 보내거나 훅을 설치하지 않고 DPI 인식, 무결성 수준, 입력 데스크톱, 가상 화면만 읽는다.
- UIA 호출과 COM 자원 해제는 같은 전용 MTA 스레드에서 수행한다. 요청 기한은 10초다. 변경 호출에 진입하기 전에 기한이 지나면 `TIMEOUT`, 진입한 호출의 결과를 확인할 수 없으면 `ACTION_OUTCOME_UNKNOWN`을 반환한다. Java/JNA는 일부 변경 사전 검사의 타임아웃도 결과 미상으로 처리한다. 타임아웃 뒤 C++ 세션은 폐기되며, 호출이 반환되는 시점에 소유 스레드가 참조를 해제한다. EOF 후 정리가 10초 내 끝나지 않으면 종료 코드 1로 프로세스 종료를 시도한다. 외부 호출자는 응답이 끊긴 변경을 재전송하기 전에 대상 상태를 확인해야 한다.

## Java/JNA와 비교

잠금이 해제된 대화형 Windows 세션에서 실행한다. `mvn clean`이 `target`을 제거하므로 Java JAR를 먼저 패키징하고 C++를 빌드한다.

```powershell
mvn clean verify
# 위의 CMake Release 빌드와 CTest를 실행한다.
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File tools/Compare-JavaCpp.ps1 -ParityOnly
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File tools/Compare-JavaCpp.ps1 -OutputPath target/java-cpp-comparison.json
```

기본 실행은 단기 6쌍과 구현당 5분의 반복 측정을 수행한다. 시험용 WPF 앱만 변경할 수 있도록 그 PID를 허용한다. `-ParityOnly`는 실제 GUI 동등성만 검사한다. 통계, 수집 방법과 결과는 [기술 비교 보고서](../../docs/CPP-VS-JAVA-EVALUATION.md)에 있다.
