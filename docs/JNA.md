# Java에서 직접 UI Automation을 호출하는 경로

```text
CLI → Agent → DesktopAdapter → JnaDesktopAdapter → 전용 MTA 스레드
                                                 → JnaUiaSession → UiaCom → UIAutomationCore
```

`--backend jna`는 현대 Java 빌드에만 적용된다. Agent는 실행 정책과 명령 ID 중복 방지를 담당한다. Locator는 공통 DesktopSnapshot에서 이름·역할·AutomationId·클래스를 검색한다. JNA에서는 기존 참조를 `snapshot.scopeRef`로 지정해 같은 창의 특정 하위 트리를 다시 수집할 수 있다. 어댑터는 Control View를 순회하고 현재 요소와 캡처 당시의 부모 경로를 재검증한다. 변경은 공급자가 제공하는 InvokePattern과 쓰기 가능한 ValuePattern으로 실행한다. [API와 범위 지정 예제](API.md)

### 단일 언어로 줄어드는 비용과 남는 비용

JNA 경로는 제품 코드를 Java로 작성하고, 요청마다 워커 파이프로 트리를 직렬화하는 단계를 없앤다. JVM 비트수와 맞는 jnidispatch DLL, Windows의 COM/UIA와 대상 앱의 접근성 제공자는 여전히 필요하다. IUnknown vtable 슬롯, 호출 규약, 포인터 폭과 출력 메모리의 소유권은 유지보수 대상이다. 공급자가 한 요소의 여러 속성을 별도 호출로 제공하므로 JVM 내부화만으로 응답 지연이나 메모리 절감을 단정할 수 없다.

COM 참조는 전용 MTA에서 초기화하고 같은 스레드에서 해제한다. 성공한 캡처의 요소는 교체 또는 종료까지 유지하고 실패한 캡처의 부분 참조도 해제한다. BSTR과 독립 반환 SAFEARRAY는 Java 값으로 복사한 뒤 해당 COM API의 소유권 규약에 따라 해제한다. [Microsoft UIA 스레딩](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading) · [COM 참조 계수](https://learn.microsoft.com/en-us/windows/win32/com/rules-for-managing-reference-counts)

호출자가 대기열에 있을 때 취소하면 해당 요청을 제거한다. MTA가 요청을 인수한 뒤 시간 제한이 지나거나 공급자가 타임아웃을 반환하면 세션을 폐기한다. 패턴 확인 중 타임아웃된 요청이 뒤늦게 동작을 보내지 않도록 COM 변경 호출 직전에 기한과 세션 상태를 확인한다. 이미 시작했을 수 있는 변경의 결과는 `ACTION_OUTCOME_UNKNOWN`으로 알리고, 같은 명령 ID를 자동 재전송하거나 중복 실행하지 않는다. `close()`는 폐기된 세션에도 제한된 정리 시간을 준다. 네이티브 호출이 반환해야 소유 스레드에서 해제를 마칠 수 있다. 공급자가 영구 정지하면 이 JVM 안에서 COM 정리를 보장할 수 없고, 네이티브 접근 위반은 JVM 전체를 종료시킬 수 있다.

### WPF 트리와 단기 실측

Windows 11의 일반 WPF 창에서 PowerShell과 C#은 `TitleBar`의 시스템 메뉴와 창 제어 버튼을 포함해 25개 요소를 반환했고, JNA의 네이티브 Control View는 제목 표시줄 노드만 포함해 20개를 반환했다. 세 경로의 WPF 콘텐츠는 역할, AutomationId, 이름, 조상 경로가 일치했다. Windows SDK의 Control View 및 TreeWalker 슬롯을 대조했고, .NET의 클라이언트 측 WindowsTitleBar 프록시가 해당 AutomationId와 자식 요소를 구성하는 것을 확인했다. 차이는 네이티브와 관리형 클라이언트가 사용하는 제목 표시줄 프록시에 국한됐다. [Microsoft 클라이언트 측 프록시](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-clientsideprovider) · [.NET WindowsTitleBar 소스](https://github.com/dotnet/wpf/blob/main/src/Microsoft.DotNet.Wpf/src/UIAutomation/UIAutomationClientSideProviders/MS/Internal/AutomationProxies/WindowsTitleBar.cs)

2026-11-22에 같은 19개 요소로 측정한 지속 세션 스냅샷 p50은 JNA 49.7 ms, C# 56.9 ms, PowerShell 89.0 ms였다. 8시간 추세, 실제 설비 공급자 및 x86 JVM은 추가 검증 대상이다. [시험 결과와 측정 원본](TEST-RESULTS.md)

### 채택 및 장애 격리

**PowerShell을 기본값으로 유지한다.** JNA는 선택형 백엔드로 장시간 시험과 제품 대상 앱 검증을 진행한다. PowerShell과 C#은 기존 회귀 기준과 프로세스 격리 경로를 제공한다.

관리 세션이 공급자의 영구 정지 또는 네이티브 충돌 이후에도 살아 있어야 한다면 같은 JNA 세션을 별도 Java 워커로 실행하는 것이 후보가 된다. 부모는 워커를 종료·재시작하고 이전 스냅샷 참조를 무효화할 수 있다. 종료 당시 변경 결과는 미상으로 남겨 재전송을 막아야 한다. 이 방식은 JVM 추가 기동과 IPC 직렬화, 메모리 비용이 생긴다. 도입 전에 비정상 종료와 복구를 포함한 최소 PoC를 동일 워크로드에서 측정한다.

### 레거시

Windows XP는 Java 11 이상, JNA 5.17의 네이티브 디스패처, 설치된 UIA 버전 전체가 검증되지 않았다. 현재 XP용 Java 7 조회 호스트와 x86 Win32 창 열거 PoC를 유지한다. XP 이미지별 KB971513, MSAA 및 구형 JNA/JVM 조합의 로딩부터 검증해야 한다. CentOS 5는 기존 Linux 진단과 읽기 전용 호스트를 사용하며 Windows COM 어댑터를 로드할 이유가 없다. [레거시 호환성](COMPATIBILITY.md)
