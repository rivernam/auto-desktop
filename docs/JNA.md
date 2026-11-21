# Java에서 직접 UI Automation을 호출하는 경로

```text
CLI → Agent → DesktopAdapter → JnaDesktopAdapter → 전용 MTA 스레드
                                                 → JnaUiaSession → UiaCom → UIAutomationCore
```

`--backend jna`는 현대 Java 빌드에만 적용된다. Agent는 기존 정책과 중복 명령 검사를 수행한다. Locator는 공통 DesktopSnapshot에서 이름·역할·AutomationId·클래스를 검색한다. 어댑터는 Control View 관찰과 현재 요소 재검증을 담당한다. 변경은 공급자가 제공하는 InvokePattern 및 쓰기 가능한 ValuePattern에 한정한다. 사용자 입력을 합성할 필요가 없다.

### 단일 언어로 줄어드는 비용과 남는 비용

JNA 경로는 제품 코드를 Java로 작성하고, 요청마다 워커 파이프로 트리를 직렬화하는 단계를 없앤다. JVM 비트수와 맞는 jnidispatch DLL, Windows의 COM/UIA와 대상 앱의 접근성 제공자는 여전히 필요하다. IUnknown vtable 슬롯, 호출 규약, 포인터 폭과 출력 메모리의 소유권은 유지보수 대상이다. 공급자가 한 요소의 여러 속성을 별도 호출로 제공하므로 JVM 내부화만으로 응답 지연이나 메모리 절감을 단정할 수 없다.

COM 인터페이스는 초기화한 MTA 스레드에서 사용하고 해제한다. 장시간 보관하는 요소는 최신 캡처에 묶이고 교체·실패·종료 경로에서 해제되어야 한다. BSTR 및 SAFEARRAY는 해당 Windows API의 소유권 규약을 따른다. 호출자가 기다릴 수 있는 시간과 공급자의 실제 실행 시간은 다르다. 제한 시간이 지나도 네이티브 스택은 실행 중일 수 있으므로 세션을 폐기하고, 응답이 끊긴 변경을 자동 재전송하지 않는다. 네이티브 호출이 영구 정지하면 같은 스레드에서의 정상 해제도 완료할 수 없다. 접근 위반은 JVM 전체를 종료시킬 수 있다. [Microsoft UIA 스레딩](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading) · [COM 참조 계수](https://learn.microsoft.com/en-us/windows/win32/com/rules-for-managing-reference-counts)

### 채택 기준

**설비 기본값은 현행 워커로 유지한다.** 실제 Windows 공급자에서 세 백엔드가 같은 유일 요소를 찾고, 같은 최종 앱 상태·커서 좌표·오류를 내는지 확인해야 한다. 그다음 x86/x64 조합, 반복 캡처 중 핸들·private bytes 추세, 공급자 무응답과 장비 재접속을 시험한다. 기존 Compare-UiaWorkers.ps1의 측정 범위는 PowerShell·C#이다. JNA의 실측값은 없다.

단일 JVM의 장애가 설비 관리 세션까지 종료시켜도 복구할 수 있는 환경에서는 직접 호출이 후보가 된다. 관리 세션을 유지한 채 공급자 정지나 네이티브 충돌에서 복구해야 한다면 같은 JNA 세션을 **별도 Java 프로세스**에서 실행하는 후속 설계가 가능하다. 기존 파이프 감독과 참조 무효화 규칙을 재사용할 수 있다. 이 경우 프로세스 격리를 위해 C#이나 PowerShell이 필수인 것은 아니다.

### 레거시

Windows XP는 Java 17, JNA 5.17의 네이티브 디스패처, 설치된 UIA 버전 전체가 검증되지 않았다. 현재 XP용 Java 7 조회 호스트와 x86 Win32 창 열거 PoC를 유지한다. XP 이미지별 KB971513, MSAA 및 구형 JNA/JVM 조합의 로딩부터 검증해야 한다. CentOS 5는 기존 Linux 진단과 읽기 전용 호스트를 사용하며 Windows COM 어댑터를 로드할 이유가 없다. [레거시 호환성](COMPATIBILITY.md)
