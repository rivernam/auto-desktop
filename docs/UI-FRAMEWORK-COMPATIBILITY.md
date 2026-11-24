# 설비 UI 프레임워크 호환성

2026-11-24에 소유 모달, 부분 스냅샷, AWT Invoke를 고치고 다시 검증했다. 프레임워크별 결과 표와 접근성 기술 절은 그 결과를 반영한다. 성능 수치, 실행 환경과 체크 개수는 2026-11-23 실행의 기록이다. [원인, 조치와 남은 제약](UIA-AGENT-DEFECTS.md)

## 검증 방법

Windows에서 프레임워크별 전용 픽스처를 띄워 Java/JNA와 C++의 일곱 NDJSON 명령을 실행했다. 준비 파일의 PID와 고유한 창 제목을 대조했다. 변경 전 같은 창에서 캡처한 요소를 정규화된 부모 경로, 역할·이름·AutomationId·클래스, 좌표, 활성·표시 상태, 액션과 프로세스 소속으로 비교했다. 제목 표시줄 차이는 콘텐츠 차이와 별도로 기록했다.

Invoke와 SetValue의 응답을 실제 GUI의 카운터와 입력값에 대조했다. 변경 권한은 각 시험에서 직접 시작한 픽스처 PID와 허용한 액션으로 제한했다. 중복 명령 ID, PID 권한 없음, 교체된 참조, 새 스냅샷 이후 참조, 창 종료 이후 참조를 시험했다. 보고서에는 입력 문자열과 스냅샷·요소 참조를 기록하지 않는다.

`PASS`는 명시된 시험의 합격, `PARTIAL`은 일부만 성공, `FAIL`은 실행한 시험의 실패, `NOT_RUN`은 미실행, `INCONCLUSIVE`는 증거 부족을 뜻한다. 제한에 걸리거나 공급자가 일부 가지를 식별할 수 없게 반환한 스냅샷은 완전한 탐색으로 판정하지 않는다.

## 프레임워크별 결과

| UI 프레임워크 | JNA 탐색 | C++ 탐색 | JNA 조작 | C++ 조작 | 접근성 기술과 제약 |
|---|---|---|---|---|---|
| Win32 Native x64 | PASS | PASS | PASS | PASS | 기본 트리 76개와 목록 하위 범위, 일반·owner-drawn 버튼, 편집, 교체 검증. 소유 대화상자를 창 목록에서 찾아 자체 스냅샷으로 닫았다. |
| MFC | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | 실제 MFC Dialog, SDI, MDI, Property Sheet 소스 준비. 설치된 VS의 ATL 경로에 MFC 헤더와 라이브러리가 없다. |
| Delphi VCL | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | 실제 TStringGrid/TDBGrid/TTreeView/TListView, owner-drawn 및 TCustomControl 소스 준비. Delphi 컴파일러 부재. |
| Swing | PARTIAL | PARTIAL | NOT_RUN | NOT_RUN | UIA에는 창과 내부 프레임만 보였다. 컨트롤은 Java Access Bridge에서 관찰됐다. |
| AWT | PARTIAL | PARTIAL | PARTIAL | PARTIAL | UIA에서 HWND 기반 버튼·Edit·List를 읽고 두 Agent에서 편집 필드 변경을 확인했다. 버튼은 Invoke가 반환되어도 카운터가 증가하지 않았다. 직접 보낸 `BM_CLICK`과 MSAA 기본 동작도 같아 Provider 제약으로 분류했다. |
| WPF Extended | PASS | PASS | PASS | PASS | UIA DataGrid, 템플릿, 가상화, TreeView, 호스트 및 Custom AutomationPeer. 소유 모달과 팝업을 창 목록에서 찾아 자체 스냅샷으로 조작했다. |
| WinForms .NET Framework | PARTIAL | PARTIAL | PARTIAL | PARTIAL | DataGridView는 Table, TreeView와 owner-drawn 목록은 탐색 가능. 공급자가 탭·목록 항목·그리드 행과 셀의 Runtime ID를 주지 않아 해당 요소는 `partial`로 표시되고 참조가 없다. 버튼·Edit·모달은 온전한 범위에서 조작했다. |
| WinForms .NET 9 | PASS | PASS | PASS | PASS | DataGridView와 TreeView 탐색 및 70개 범위에서 DataItem 32개 관찰. 소유 모달을 창 목록에서 찾아 자체 스냅샷으로 닫았다. |
| Qt Widgets | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | P1. 로컬 Qt 도구와 픽스처가 없다. |
| Chromium/Electron | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | P2. 전용 픽스처 미구성. |
| DirectX/OpenGL/Canvas | NOT_RUN | NOT_RUN | NOT_RUN | NOT_RUN | P2. 시각 경로 미구성. |

조작 열에서 `PASS`는 해당 시험이 검증한 Invoke/SetValue를 뜻한다. CheckBox Toggle, ComboBox/Tab 선택, ExpandCollapse, 스크롤, 가상 항목 실체화 및 Grid 셀 편집에는 별도 패턴이 필요하다. Win32의 10,000행 가상 목록은 2,000개 창 캡처와 60개 범위 캡처에서 모두 제한을 표시했다. `INCOMPLETE_SNAPSHOT`이 잘린 트리의 전체 검색을 차단했다. [기능 원본](test-results/2026-11-23-uia-frameworks-functional.json) · [WPF 가상 항목 UIA 모델](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-workingwithvirtualizeditems)

Win32 x86 픽스처의 두 x64 Agent는 48개 요소로 이루어진 트리와 기본 조작에서 일치했다. 별도로 실행한 x86 C++ Agent는 x86 픽스처에서 76개 요소를 캡처했다. 차이의 원인을 분리하려면 같은 인스턴스에서 클라이언트 비트수만 바꿔 비교해야 한다.

Win32와 확장 WPF는 네이티브로 최소화한 상태에서도 같은 창을 찾았다. 이때 Win32 UIA 루트는 `offscreen=true`, WPF 루트는 `false`를 보고했다. 최소화 상태 조작은 미실행이다. Windows 11 로컬 단일 모니터에서만 수행했다. RDP, 권한 차이, 다중 모니터, 다른 DPI 배율, 서드파티 컨트롤, Windows XP/7 및 Linux의 GUI는 `NOT_RUN`이다.

## UIA, MSAA, Java Access Bridge

- **`JAB_ONLY` · Swing.** Temurin 21 x64의 기본 실행에서 두 Agent의 UIA 트리는 2개 요소, 직접 MSAA는 1개 요소였다. 해당 JVM 프로세스에서 JAB를 켜자 JAB가 78개 요소를 반환했다. 카운터 버튼, JTable, JTree, 탭, 비밀번호 역할 및 `AccessibleAction`을 제공하는 커스텀 스와치를 확인했다. 별도 시험 프로세스에서 JAB가 광고한 버튼 액션을 한 번 보냈고 실제 카운터가 0에서 1로 바뀌었다. AWT는 JAB에서 22개 요소를 반환했다. 이전 JVM·x86 브리지 및 다른 JAB 액션은 미실행이다. [JAB 활성화 원본](test-results/2026-11-23-uia-jab-enabled.json) · [Swing 실제 변경 증거](test-results/2026-11-23-uia-jab-action.json)
- **`UIA_PROVIDER_LIMITATION` · AWT 및 WinForms.** AWT Edit의 숫자 AutomationId와 RichEdit20W 클래스를 함께 사용해 입력을 확인했다. 동일 프록시의 Invoke 응답과 실제 카운터 사이에는 차이가 있었다. AWT 목록은 하위 요소의 이름을 채우지 않았다. .NET Framework WinForms의 탭 이름은 MSAA에서도 보였다. UIA의 저수준 호출에서는 이름을 읽을 수 있었고 빈 Runtime ID로 인해 Agent 참조 발급이 불가능했다. 직접 MSAA는 이 사례의 보조 조회 경로이며 안정적인 식별 및 조작은 미실행이다. [UIA의 표준 컨트롤 프록시](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-clientsideprovider) · [WinForms 접근성 버전 차이](https://learn.microsoft.com/en-us/dotnet/framework/whats-new/whats-new-in-accessibility)
- **`CUSTOM_CONTROL_LIMITATION` · 커스텀 표면.** WPF AutomationPeer를 구현한 표면은 Invoke 후 픽스처에서 활성화 신호를 받았다. AutomationPeer 없는 WPF 표면과 Java Accessible 미구현 스와치는 접근성 메타데이터에서 식별되지 않았다. WindowsFormsHost의 WinForms Edit와 HwndHost의 네이티브 EDIT는 WPF와 같은 스냅샷에서 별도 컨트롤로 관찰했다.
- **해결 · 소유 모달과 팝업.** UI Automation은 소유 창을 Raw View에서도 소유자 창의 자식으로 둔다. 데스크톱 직계 자식만 보던 `listWindows`에는 나타날 수 없었다. 두 Agent는 이제 Win32 소유 관계로 찾은 창을 `ownerWindowId`와 함께 덧붙이고 스냅샷 대상으로 받는다. Win32, WPF, WinForms .NET Framework·.NET 9에서 모달 내부 버튼까지 조작했다. 메뉴, 콤보 드롭다운과 중첩 모달은 `NOT_RUN`이다.
- **`UIA_PROVIDER_LIMITATION` · 동기 모달 콜백.** 초기 WinForms .NET 9 픽스처의 Invoke는 `ShowDialog`가 호출 안에서 열린 상태로 대기해 두 Agent에서 `ACTION_OUTCOME_UNKNOWN`이 발생했다. 픽스처 콜백이 UI 메시지 큐에 대화상자 열기를 게시하도록 한 뒤에는 반환과 실제 열림을 각각 확인할 수 있었다. 해당 요청의 자동 재전송은 없었다. [Microsoft Invoke 공급자 계약](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationcore/nf-uiautomationcore-iinvokeprovider-invoke)

## 확인된 Agent 결함

**`AGENT_BUG`와 `UIA_PROVIDER_LIMITATION` · .NET Framework WinForms Runtime ID.** ListBox 항목 3개와 TabItem 3개에서 네이티브 `GetRuntimeId`는 `S_OK`와 1차원 `VT_I4` SAFEARRAY를 반환했다. 하한 0, 상한 -1의 빈 배열이었다. 기존 두 백엔드는 이를 스냅샷 전체의 `STALE_REFERENCE`로 처리했다. 수정 후 두 백엔드는 식별할 수 없는 하위 가지를 생략하고 `truncated=true`를 반환한다. 방문 한도에는 생략한 요소도 포함한다. 실제 COM 실패와 식별할 수 없는 루트는 계속 거부한다. [독립 COM 진단](test-results/2026-11-23-winforms-runtime-ids.txt)

부분 스냅샷의 전체 창 검색은 `INCOMPLETE_SNAPSHOT`으로 차단된다. 이 픽스처에 유일하게 선언된 버튼과 입력 필드는 각각 완전한 범위를 다시 캡처한 뒤 조작했다. Java/JNA와 C++에서 실제 카운터 증가와 변경된 텍스트를 확인했다. 2026-11-24부터 잘린 요소에는 `partial`이 표시되고, `partial` 요소가 없는 범위는 다시 캡처하지 않아도 `scopeRef`로 검색할 수 있다. [API 계약](API.md)

## 기능을 통과한 시나리오의 성능

Win32 x64, 확장 WPF와 .NET 9 WinForms에서 프레임워크별 2쌍의 새 세션, 세션별 워밍업 2회와 측정 8회를 사용했다. 쌍마다 JNA와 C++의 순서를 바꿨다. 반복당 실제 편집과 카운터 상태를 확인했다. 총 12개 세션과 측정 반복 96회에서 실패와 타임아웃이 0건이었다. 해당 기능을 통과하지 못한 프레임워크·동작에는 성능 수치를 부여하지 않았다. [성능 원본](test-results/2026-11-23-uia-frameworks-performance.json)

| 프레임워크 · Agent | 기동부터 첫 스냅샷 ms, 2회 범위 | 지속 Snapshot ms p50/p95/p99 | Invoke ms p50/p95/p99 | SetValue ms p50/p95/p99 | 종료 전 Private Bytes / Working Set MiB |
|---|---:|---:|---:|---:|---:|
| Win32 · JNA | 653–834 | 248.6 / 350.3 / 350.3 | 11.1 / 21.6 / 21.6 | 19.7 / 31.2 / 31.2 | 71.2–72.1 / 81.3–81.9 |
| Win32 · C++ | 248–262 | 153.6 / 160.8 / 160.8 | 7.9 / 8.7 / 8.7 | 15.0 / 17.0 / 17.0 | 8.1–8.3 / 19.6–19.7 |
| WPF · JNA | 1,341–1,440 | 840.2 / 1,437.9 / 1,437.9 | 15.8 / 26.0 / 26.0 | 19.4 / 30.7 / 30.7 | 72.1–81.1 / 82.9–92.0 |
| WPF · C++ | 835–889 | 759.1 / 829.1 / 829.1 | 12.9 / 28.5 / 28.5 | 17.1 / 21.6 / 21.6 | 8.5–8.9 / 19.1 |
| WinForms .NET 9 · JNA | 570–586 | 101.9 / 145.0 / 145.0 | 15.9 / 20.5 / 20.5 | 29.1 / 33.1 / 33.1 | 70.6–71.8 / 81.3–82.6 |
| WinForms .NET 9 · C++ | 182–201 | 88.6 / 128.1 / 128.1 | 14.7 / 18.8 / 18.8 | 26.0 / 32.0 / 32.0 | 7.5–7.7 / 19.5–19.6 |

프로세스 생성 호출 자체는 약 6–9 ms였다. 반복 세션의 Agent CPU 차분은 Win32 JNA 1.27–1.45초와 C++ 0.52초, WPF JNA 2.77–2.92초와 C++ 1.30–1.48초, .NET 9 WinForms JNA 1.00–1.02초와 C++ 0.41–0.44초였다. 각 세션의 FindElement·GetElementInfo 백분위, CPU, 핸들, 스레드와 개별 표본은 원본에 있다. 백엔드·프레임워크별 지연 표본이 16개여서 nearest-rank p95와 p99는 둘 다 최댓값이다. C++의 첫 스냅샷과 메모리 이점은 이 구성에서 관찰됐다. 설비별 Provider 순회 작업량과 꼬리 지연은 별도 측정이 필요하다.

## 실행 환경과 검증 증거

- Windows 11 Pro 25H2 x64, 빌드 26200.9974, UIAutomationCore 7.2.26100.9949, Intel Core i7-12700 20 논리 프로세서, 31.8 GiB RAM. 로컬 대화형 세션 1, 모니터 1개.
- Temurin JDK 21.0.11+10 x64, `-XX:+UseSerialGC -Xms16m`. Windows PowerShell 5.1/WPF 및 Framework WinForms는 CLR 4.0.30319.42000 x64, 제품 런타임 .NET Framework 4.8.1(릴리스 533509)에서 실행했다. 현대 WinForms는 SDK 9.0.315로 빌드했고 .NET 9.0.17 x64에서 실행했다. [Framework 릴리스 식별](https://learn.microsoft.com/en-us/dotnet/framework/install/how-to-determine-which-versions-are-installed)
- Visual Studio 2022 MSVC 19.44.35228, Windows SDK 10.0.26100.0, Release `/O2 /Ob2 /DNDEBUG`, C++ Agent `/MT`. Win32 픽스처와 C++ Agent를 x86·x64로 빌드했다. [x86 Win32와 x64 Agent 결과](test-results/2026-11-23-uia-win32-x86.json) · [x86 C++ Agent 결과](test-results/2026-11-23-uia-cpp-x86.json)
- 빌드의 기준 `main` SHA는 `f50ce8048ba1e9ac129195db6f1b1188bb0159cd`다. 실행 당시 변경을 포함한 테스트 산출물의 SHA-256과 빌드 설정은 원본에 있다. [기준 main 커밋](https://github.com/rivernam/auto-desktop/commit/f50ce8048ba1e9ac129195db6f1b1188bb0159cd)
- 기능 행 12개 `PARTIAL`, 10개 `NOT_RUN`. 두 백엔드의 세부 체크는 186 성공, 48 실패, 20 미실행이다. 실패에는 발견 불가 모달, AWT 버튼의 상태 불일치와 부분 스냅샷에서 차단된 탐색이 포함된다. [기능 원본](test-results/2026-11-23-uia-frameworks-functional.json)
- Maven 비-GUI 시험 53개, 별도 실행한 기존 WPF 통합 시험 4개, x64·x86 CTest 각 1개가 통과했다. x64 두 백엔드를 대상으로 한 기존 WPF 비교도 콘텐츠 19개, 제목 표시줄, 교체 및 프로세스 종료가 일치했다. [기존 WPF 비교 원본](test-results/2026-11-23-uia-wpf-baseline.json)

## 아키텍처 평가

| 후보 | 적용 조건 |
|---|---|
| A. Java Core + JNA UIA | 현대 Windows의 기존 공통 계약과 정책을 재사용한다. JVM 배포·메모리와 프로세스 내부 COM 장애 복구가 비용이다. |
| B. C++ Native Agent | JVM 설치가 어렵거나 시작 시간·메모리 예산이 엄격한 현대 Windows의 대안이다. OS별 구현과 공통 정책의 동등성 유지가 비용이다. |
| C. 다중 접근성 어댑터 | UIA를 기준으로 두고 각 설비 앱에서 입증된 누락에 맞춰 MSAA나 JAB를 추가한다. Linux는 대화형 세션의 AT-SPI부터 검증한다. 접근성을 구현하지 않은 표면은 앱 상태 API나 공급자 구현을 먼저 확인한다. 이미지·OCR·좌표를 쓸 경우 별도의 식별과 조작 후조건 평가가 필요하다. |
| D. Java Core + C++ Native Worker | 공통 정책을 Java에 두면서 COM 장애를 별도 프로세스에 격리할 수 있다. IPC, 배포, 재시작 시 참조 폐기와 진행 중 액션의 결과 미상 처리가 필요하다. |

현대 Windows의 배포 기본값은 PowerShell이다. Java/JNA와 독립 C++ Agent는 실제 설비별 평가 결과에 따라 사용할 수 있다. 다음 검증은 MFC와 VCL의 실제 바이너리, 설비 Java 앱의 JAB 액션 후조건, 서드파티 그리드 순으로 진행한다. Windows 7 SP1은 JVM·UIA COM·대상 앱의 배포 조합을 확인한다. XP/Embedded는 정확한 이미지, 업데이트, MSAA, 네이티브 빌드의 import와 실행을 개별 검증한다. CentOS 5는 libc·CPU ABI 및 구형 AT-SPI/CORBA, 현대 Linux는 AT-SPI2와 X11/Wayland 세션이 독립 검증 대상이다. [레거시 지원 범위](COMPATIBILITY.md) · [기존 WPF 성능 비교](CPP-VS-JAVA-EVALUATION.md)

## 구현 위치

- 실제 프레임워크 픽스처와 진단 코드 [Win32](../tests/fixtures/win32/) · [MFC](../tests/fixtures/mfc/) · [Delphi VCL](../tests/fixtures/delphi-vcl/) · [Swing/AWT 및 JAB](../tests/fixtures/swing-awt/) · [WinForms](../tests/fixtures/winforms/) · [MSAA](../tests/fixtures/accessibility/) · [WPF 확장](../src/test/resources/windows-gui-fixture.ps1)
- Agent의 빈 Runtime ID 처리 [Java COM](../src/main/java/dev/desktop/UiaCom.java) · [Java/JNA 캡처](../src/main/java/dev/desktop/JnaUiaSession.java) · [C++ UIA](../native/cpp-agent/src/windows/uia_adapter.cpp)
- 실행 및 회귀 검증 [프레임워크 실행기](../tools/Test-UiaFrameworks.ps1) · [기능과 성능 체크](../tools/UiaFrameworkCases.ps1) · [Runtime ID 회귀](../tools/tests/Test-WinFormsRuntimeIds.ps1)

## 빌드와 재현

잠금 해제된 테스트용 Windows 대화형 세션에서 저장소 루트 기준으로 실행한다. MFC에는 Visual Studio 설치 관리자의 C++ MFC v143 x86/x64 구성 요소가 필요하다. Delphi는 VCL과 DataSnap을 사용할 수 있는 라이선스 및 컴파일러로 빌드한다. [MFC 설치 조건](https://learn.microsoft.com/en-us/visualstudio/msbuild/errors/msb8041?view=visualstudio) · [VCL 빌드 절차](../tests/fixtures/delphi-vcl/README.md)

```powershell
mvn clean verify
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
cmake -S native/cpp-agent -B target/cpp-agent-x86 -G "Visual Studio 17 2022" -A Win32
cmake --build target/cpp-agent-x86 --config Release
ctest --test-dir target/cpp-agent-x86 -C Release --output-on-failure

foreach ($fixture in 'win32', 'mfc', 'accessibility') {
    cmake -S "tests/fixtures/$fixture" -B "target/framework-fixtures/build-$fixture" -G "Visual Studio 17 2022" -A x64
    if ($LASTEXITCODE -eq 0) { cmake --build "target/framework-fixtures/build-$fixture" --config Release }
}
cmake -S tests/fixtures/win32 -B target/framework-fixtures/x86/build-win32 -G "Visual Studio 17 2022" -A Win32
cmake --build target/framework-fixtures/x86/build-win32 --config Release

$classes = 'target/framework-fixtures/swing-awt'
New-Item -ItemType Directory -Force $classes | Out-Null
javac -Xlint:all -d $classes tests/fixtures/swing-awt/FrameworkFixture.java

$csc = Join-Path $env:SystemRoot 'Microsoft.NET/Framework64/v4.0.30319/csc.exe'
$output = 'target/framework-fixtures/winforms-framework.exe'
& $csc /nologo /target:winexe "/out:$output" /reference:System.Windows.Forms.dll /reference:System.Drawing.dll tests/fixtures/winforms/WinFormsFixture.cs
Copy-Item tests/fixtures/winforms/WinFormsFixture.framework.config "$output.config"
dotnet build tests/fixtures/winforms/WinFormsFixture.csproj -c Release -o target/framework-fixtures/winforms-modern "-p:BaseIntermediateOutputPath=$PWD/target/framework-fixtures/winforms-modern-obj/"
```

```powershell
& ./tools/Test-UiaFrameworks.ps1 -Framework WinFormsFramework,Win32,Wpf,WinFormsModern,Swing,Awt,Mfc,DelphiVcl,Qt,ChromiumElectron,CustomRendering -DiagnoseAccessibility -OutputPath target/framework-functional-final.json
& ./tools/tests/Test-WinFormsRuntimeIds.ps1 -ReportPath target/framework-functional-final.json
& ./tools/Test-UiaFrameworks.ps1 -Framework Swing,Awt -DiagnoseAccessibility -EnableJab -OutputPath target/framework-jab-enabled.json
powershell.exe -NoProfile -ExecutionPolicy RemoteSigned -File tests/fixtures/swing-awt/Invoke-SwingFixtureCounter.ps1
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32 -FixtureRoot target/framework-fixtures/x86 -OutputPath target/framework-win32-x86.json
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32 -Backend Cpp -CppAgent target/cpp-agent-x86/Release/cpp-agent.exe -FixtureRoot target/framework-fixtures/x86 -OutputPath target/framework-cpp-x86.json
& ./tools/Test-UiaFrameworks.ps1 -Framework Win32,Wpf,WinFormsModern -Mode Performance -Pairs 2 -Iterations 8 -Warmup 2 -OutputPath target/framework-performance-final.json
& ./tools/Compare-JavaCpp.ps1 -ParityOnly -OutputPath target/framework-wpf-baseline.json

$worker = (Resolve-Path workers/csharp/bin/Release/UiaWorker.exe).Path
$junitTemp = (New-Item -ItemType Directory -Force target/framework-junit-tmp).FullName
mvn -o '-Ddesktop.windowsIT=true' '-Ddesktop.csharpIT=true' '-Ddesktop.jnaIT=true' "-Ddesktop.csharpWorker=$worker" "-DargLine=-Djava.io.tmpdir=$junitTemp" '-Dtest=WindowsGuiTest' test
```

`-Backend JNA`, `-Backend Cpp`, `-Backend Both`로 선택한다. `-RequirePass`는 모든 해당 기능·동등성·성능 판정이 통과해야 성공으로 종료한다. `-FixtureJava`로 GUI 픽스처 JVM을 바꾸고, `-EnableJab`으로 해당 JVM 프로세스의 브리지만 활성화한다. MSAA 진단은 PID/HWND 범위에서 최대 256개 항목을 읽는다. JAB 진단은 x64 JDK의 로컬 DLL에서 역할·상태·인터페이스를 조회하며 텍스트 값을 읽지 않는다. [Swing/AWT와 JAB 빌드 절차](../tests/fixtures/swing-awt/README.md) · [Oracle JDK 21 접근성 도구](https://docs.oracle.com/en/java/javase/21/docs/specs/man/index.html)
