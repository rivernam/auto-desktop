# Windows UI Automation 백엔드 선택

**PowerShell 5.1 워커를 기본값으로 유지하고, 현대 Windows용 C# 워커(.NET Framework 4.8)를 선택형 PoC로 비교한다.** 두 방식 모두 관리형 UI Automation(UIA)을 호출하므로 같은 앱과 같은 조작으로 측정할 수 있다. C# 워커는 기존 프로세스 격리와 Java 정책을 유지하면서 PowerShell 엔진의 영향을 분리해 시험할 수 있다. Windows 실기기에서 세 방식의 지연, 메모리 및 장시간 안정성을 비교한 수치는 아직 없다. JNA 직접 연동도 선택형 Java 어댑터로 구현했다. [현재 PoC와 검증 범위](JNA.md)

비교할 기능은 창 목록, 범위가 제한된 Control View 트리, 스냅샷 내 요소 검색, 현재 속성 조회, InvokePattern.Invoke와 쓰기 가능한 ValuePattern.SetValue다. Java가 명령 계약, 검색, 허용 정책과 참조 수명을 담당한다. 검색에는 이미 받은 스냅샷을 사용하므로 검색 시간과 OS 트리 조회 시간을 분리해 측정해야 한다. 실제 제어 범위는 앱이 공개하는 패턴에 달려 있다. [현재 API](API.md) · [Microsoft 관리형 UIA 모델](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/ui-automation-overview)

## 세 방식의 차이

| 판단 항목 | 기존 PowerShell 5.1 | JVM 내부 Java + JNA + UIA COM | 자체 C# Worker.exe |
|---|---|---|---|
| 현대 Windows | 설치된 Windows PowerShell과 UIA 어셈블리를 사용한다. 조직의 스크립트 정책을 확인해야 한다. | JVM과 같은 아키텍처의 JNA 디스패처와 대상 API의 COM 인터페이스가 필요하다. | 4.8을 대상으로 빌드한 EXE, 호환되는 4.x 런타임, UIA 어셈블리가 필요하다. PowerShell 엔진 없이 워커를 실행할 수 있다. |
| XP | WMF 5.1 및 현행 Java 코어가 제약이다. | 레거시 JVM·JNA·DLL·UIA가 모두 맞아야 한다. 현재 JAR는 XP 지원 대상 밖이다. | 현대용 4.8 EXE는 XP에서 실행할 수 없다. 하위 프레임워크용 별도 빌드와 호스트 구성이 연구 대상이다. |
| 기동·응답 시간 | 세션당 엔진을 한 번 시작한다. 관찰 시 OS 호출, PowerShell 객체 처리, IPC 직렬화 비용이 든다. | 워커 기동·IPC를 생략한다. 속성마다 JNA·COM 및 대상 제공자 경계를 건너면 대형 트리에서 여전히 느릴 수 있다. | PowerShell 엔진 비용은 없지만 CLR 초기화·JIT·UIA 호출·IPC 비용이 남는다. 실제 차이는 앱별 측정이 필요하다. |
| 메모리 | JVM과 PowerShell 프로세스의 private bytes, 핸들을 각각 기록한다. | 추가 프로세스가 없다. JVM 힙 외부의 COM·JNA 할당 누수는 JVM 힙 지표만으로 볼 수 없다. | JVM과 CLR 워커가 각각 상주한다. 문자열과 응답 버퍼, UIA 참조를 포함해 양쪽 private bytes를 측정한다. |
| 장애 격리·회복 | 헬퍼가 멈추면 Java에서 종료·재시작하고 참조를 무효화할 수 있다. | DLL 접근 위반은 Java 프로세스를 종료시킬 수 있다. 응답 없는 COM 호출은 Future 취소만으로 중단을 보장할 수 없다. JVM을 재시작하면 Java 세션 상태도 소실된다. | 헬퍼 비정상 종료·무응답을 프로세스 경계에서 처리할 수 있다. 전달 후 응답이 끊긴 변경 요청은 실행 결과 미상으로 처리한다. |
| 의존성·유지보수 | 스크립트를 읽어 오류 지점을 확인하기 쉽고 별도 컴파일이 필요 없다. 호스트 버전·정책 영향을 받는다. | JNA, 필요 시 jna-platform, 네이티브 바이너리·ABI·COM 수명에 대한 회귀 시험이 필요하다. JNA 4.0 이후 배포판은 Apache 2.0 또는 LGPL 2.1 이상을 선택할 수 있으며 채택한 버전의 고지를 확인해야 한다. | 외부 자동화 엔진 없이 OS의 관리형 UIA를 쓴다. 빌드 시 참조 어셈블리, 배포 시 Java와 워커의 프로토콜 버전·패키지 무결성을 관리한다. |
| 확장성 | 관리형 UIA에 노출된 API를 스크립트로 호출할 수 있다. | 설치된 COM 인터페이스가 제공하는 최신 패턴이나 캐시를 세밀하게 매핑할 여지가 있다. 이를 사용하려면 별도 바인딩과 검증이 필요하다. | PoC의 패턴 범위는 기존 관리형 워커와 같다. C#을 쓴다는 이유만으로 기존에 보이지 않던 요소가 노출되지는 않는다. |

JNA는 내부적으로 JNI 디스패치 라이브러리를 이용한다. managed UIA의 API 범위와 OS에 설치된 네이티브 UIA의 버전은 별개의 조건이다. [JNA 구현 및 라이선스](https://github.com/java-native-access/jna) · [Windows Management Framework 버전표](https://learn.microsoft.com/en-us/powershell/scripting/windows-powershell/wmf/setup/install-configure) · [.NET Framework 시스템 요구 사항](https://learn.microsoft.com/en-us/dotnet/framework/get-started/system-requirements)

## XP와 32·64비트의 실제 조건

- **XP SP3 x86.** Microsoft는 KB971513을 통해 Windows 7 세대의 Windows Automation API를 일부 XP 환경에 제공했다. 실제 이미지에서 서비스 팩, 아키텍처, 패치 및 COM 활성화를 확인해야 한다. 특정 패턴의 지원 여부는 컨트롤에서 다시 확인한다. 해당 업데이트가 없거나 구형 컨트롤이 MSAA만 노출하면 별도 IAccessible 구현으로 이름·역할·기본 동작을 조사할 수 있다. MSAA의 기본 동작이나 값 설정을 UIA Invoke·Value와 동등하게 간주하면 안 된다. [KB971513 x86 카탈로그](https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=604d593e-b8a6-4710-a6ac-38a200bb8dab) · [MSAA와 UIA 비교](https://learn.microsoft.com/en-us/windows/win32/winauto/microsoft-active-accessibility-and-ui-automation-compared)
- **XP Embedded 및 x64.** 제품 이름만으로 API 구성을 알 수 없다. 이미지의 UIAutomationCore·oleacc, .NET/WPF 어셈블리 및 대화형 세션을 조사해야 한다. x86 업데이트의 결과를 x64에 적용할 수 없다. 시험은 OS, JVM, 헬퍼 및 대상 앱 비트 수를 따로 적는다. 64비트 Windows에서는 32비트 앱과 64비트 앱을 각각 시험한다. UIA의 교차 비트 프록시는 요소를 만든 COM 아파트먼트의 수명에 영향을 받는다. [Microsoft UIA 스레딩 지침](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading)
- **레거시 Java.** 현재 Java 17 산출물을 구형 JVM에서 실행할 수 없다. Java를 XP에 두려면 호환 소스·클래스 버전과 XP에서 실행 가능한 실제 JVM 배포판을 별도로 정해야 한다. JNA 사용 시 해당 JVM에서 로드 가능한 JAR뿐 아니라 그 버전에 맞는 x86 또는 x64 jnidispatch.dll의 PE 아키텍처, 런타임 및 Windows API 요구 사항도 확인한다. DLL 로드, CoCreateInstance, 실제 트리와 동작까지 순서대로 증명해야 한다. [Oracle XP 안내](https://www.java.com/en/download/help/winxp.html) · [Java 17 인증 환경](https://www.oracle.com/java/technologies/javase/products-doc-jdk17certconfig.html) · [JNA](https://github.com/java-native-access/jna)
- **레거시 C#.** Microsoft의 호환표에서 XP SP3에 설치할 수 있는 마지막 .NET Framework는 4.0.3이다. XP용 후보는 설치 이미지에 맞춰 3.5 계열 또는 4.0 계열의 참조 어셈블리로 별도 빌드하고 UIA·JSON·표준 입출력 API까지 시험해야 한다. 4.8 EXE의 설정 파일만 바꿔 해결할 수 없다. 워커가 XP에서 기동해도 Java 17 코어의 XP 실행 문제는 남는다. 별도 레거시 호스트 또는 분리 배치에는 추가 설계가 필요하다. [Microsoft 운영체제별 최대 버전](https://learn.microsoft.com/en-us/dotnet/framework/install/on-windows-10) · [버전 간 관계](https://learn.microsoft.com/en-us/dotnet/framework/install/versions-and-dependencies)
- **Windows 7·10·11 및 Server.** .NET Framework 4.8 설치 가능 범위에는 Windows 7 SP1도 포함되지만 실제 제품의 실행 조건에는 Java 공급사의 지원 범위가 함께 적용된다. Windows 10·11 및 Desktop Experience가 있는 Server에서도 빌드, 런타임, 대화형 로그인 세션과 앱을 명시해 검증해야 한다. Server Core나 Session 0에서 같은 UI가 보인다고 가정할 수 없다. 세 후보는 모두 Windows UIA 경로이므로 CentOS 5용 접근성 백엔드는 별도 과제다. [Microsoft .NET 4.8 요구 사항](https://learn.microsoft.com/en-us/dotnet/framework/get-started/system-requirements) · [프로젝트 호환성 표](COMPATIBILITY.md)

## Java에서 UIA COM을 직접 호출할 때의 구현 비용

1. 창을 소유하지 않는 전용 MTA 스레드에서 CoInitializeEx(COINIT_MULTITHREADED) 후 CUIAutomation을 생성한다. S_OK와 S_FALSE 모두 같은 스레드의 CoUninitialize와 짝을 이룬다. RPC_E_CHANGED_MODE는 실패로 처리한다. 요청과 해제를 이 스레드로 모으면 다른 아파트먼트로 raw 포인터를 전달하는 문제를 피할 수 있다. [UIA 스레딩](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading) · [CoInitializeEx](https://learn.microsoft.com/en-us/windows/win32/api/combaseapi/nf-combaseapi-coinitializeex)
2. IUIAutomationElement, 트리 워커, 조건, 패턴 인터페이스의 vtable 순서와 호출 규약, 포인터 폭, HRESULT 및 출력 포인터를 SDK와 대조한다. QueryInterface와 소유권을 넘겨받는 out 참조는 범위 종료 또는 스냅샷 폐기 시 Release한다. 별도 소유권으로 보관하는 복사에는 AddRef가 필요하다. 캐시 교체·부분 순회 실패·타임아웃·종료 때의 해제를 시험한다. Java GC 시점에 의존하면 장기 실행에서 살아 있는 COM 참조 수를 제한하기 어렵다. [Microsoft COM 참조 계수](https://learn.microsoft.com/en-us/windows/win32/com/rules-for-managing-reference-counts)
3. 속성 VARIANT는 초기화하고 vt에 맞게 읽은 후 소유한 값에 VariantClear를 적용한다. 독립적으로 받은 BSTR은 Java 문자열로 복사한 후 소유권 계약에 따라 SysFreeString으로 해제한다. VARIANT가 소유한 BSTR이나 SAFEARRAY는 별도로 이중 해제하지 않는다. GetRuntimeId의 독립 반환 SAFEARRAY는 범위를 확인해 정수 배열로 복사하고, 접근 잠금을 썼다면 해제한 뒤 SafeArrayDestroy한다. BYREF 값은 원 소유자의 수명을 따른다. [VariantClear](https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-variantclear) · [get_CurrentName](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-get_currentname) · [GetRuntimeId](https://learn.microsoft.com/en-us/windows/win32/api/uiautomationclient/nf-uiautomationclient-iuiautomationelement-getruntimeid) · [SafeArrayDestroy](https://learn.microsoft.com/en-us/windows/win32/api/oleauto/nf-oleauto-safearraydestroy)
4. 외부에는 스냅샷 범위의 불투명 참조만 노출한다. 변경 전 현재 요소의 창·프로세스·런타임 ID와 가용 패턴을 재검증하고, 사라진 요소나 바뀐 창은 기존 API 오류로 변환한다. 프로세스 분리를 없애도 UIA 공급자는 별도 프로세스일 수 있다. 동일 제공자에 대한 속성 요청을 함께 가져오는 캐시는 지연 최적화 후보지만, 캐시의 오래된 값으로 변경을 허가해서는 안 된다. [현재 API의 참조 규약](API.md)

## 실측 계획과 기본 백엔드 변경 조건

다음 수치와 횟수는 **시험안**이다. 실측값과 제품 SLA는 아직 없다.

1. 같은 Windows VM 이미지, 전원 설정, JDK·CLR, 앱 버전 및 권한에서 동일한 WPF 시험 창으로 시작한다. 실제 도입 대상 Win32 앱도 별도로 기록한다. 각 셀에서 트리 깊이·노드 한도와 노출 패턴을 고정하고, 결과 노드 수·잘림 여부와 액션 후 실제 상태를 비교한다. 결과가 다른 셀의 지연 차이는 성능 우위로 해석할 수 없다.
2. 새 Java 프로세스 시작부터 첫 성공 스냅샷까지 30회 기록한다. 기존 세션에서는 예열 후 탐색·현재 정보·invoke·setValue를 종류별 100회 이상 기록한다. 동일 액션으로 되돌릴 수 있는 시험 앱을 쓰고 각 회차 결과를 관찰한다. 백엔드 실행 순서를 번갈아 배치하고 p50·p95, 실패율과 표본 수를 함께 제시한다.
3. JVM과 워커의 private bytes, working set, CPU 시간, 핸들 수, 스레드 수, 응답 바이트 및 완료한 노드 수를 동일 시점에 기록한다. 유휴, 첫 조회 후, 반복 조회 중, 참조 폐기 후의 추세를 비교한다. working set 합계에는 프로세스 간 공유 페이지가 중복될 수 있다. JVM 힙과 CLR 힙은 원인 분석용으로 따로 기록한다.
4. 대표 앱에서 예를 들어 8시간 연속 실행하며 스냅샷 교체, 창 닫기·재생성, 참조 만료를 반복한다. 읽기·변경 요청 도중 워커 종료, 공급자 무응답, 재시작 후 오래된 참조를 시험한다. 응답이 유실된 변경은 실행 결과 미상으로 남기고 자동 재전송하지 않는다. 오류 발생 시간과 복구 시간, 고아 워커 및 누적 핸들 증가를 기록한다.
5. 기본값 변경은 대상 OS·비트 수별 실기기 계약 시험, 정책·민감정보 처리의 동등성, 입력 후 관찰 결과, 워커 장애 복구, 장기 자원 추세와 설치·업데이트·이전 버전 복귀 검증을 통과한 뒤 결정한다. 결과표에는 원자료·환경·측정 절차를 남긴다. 유의미한 개선과 유지보수 비용을 확인하기 전에는 선택형 C# PoC를 기본 경로로 승격할 근거가 없다. JNA 경로도 같은 실기기 시험을 통과한 뒤 수치를 비교한다.

### 두 워커의 반복 측정

로그인하고 잠금을 해제한 Windows 데스크톱에서 빌드한 JAR와 C# 워커를 사용한다. 스크립트는 WPF 시험 창 하나를 열고 두 백엔드의 순서를 무작위로 정한다. 첫 예시는 백엔드마다 새 프로세스의 첫 응답을 측정하고, 이어서 한 세션에서 예열 후 100회 반복한다.

```powershell
.\tools\Compare-UiaWorkers.ps1 -CSharpWorker .\workers\csharp\bin\Release\UiaWorker.exe -ColdRuns 30 -Iterations 100 |
    Out-File -Encoding utf8 .\windows-uia-samples.json
```

- **새 프로세스**. 별도의 탐색 세션이 시험 창의 HWND를 찾는다. 측정 세션은 매번 새 JVM과 워커를 띄우고 `getCapabilities` 또는 `snapshot` 하나만 호출한 뒤 종료한다. `cold[].launchMs`는 JVM 실행 호출의 소요 시간, `requestMs`는 명령을 쓰기 시작해 응답 줄을 받을 때까지의 시간, `startToReplyMs`는 JVM을 시작하기 직전부터 첫 응답 해석이 끝날 때까지의 시간이다. 매 실행 사이 운영체제 캐시는 유지된다.
- **반복 세션**. 스냅샷이 잘리지 않았는지, 노드 수와 두 대상 컨트롤의 프로세스가 같은지 검사한다. 매회 편집 필드와 버튼을 찾고 현재 필드 정보를 조회한 뒤 값을 쓰고 버튼을 호출한다. 지연 측정 뒤 시험 앱이 기록한 문자열과 실제 카운터 증가를 확인한다. `sessions[].latencyMs`는 예열 1회를 제외한 각 연산의 평균, 최대, p50, p95를 밀리초로 나타낸다. 분위수는 정렬한 전체 반복 표본에서 해당 백분위 순위의 값을 택한다.
- **자원과 장애**. 각 세션의 예열 직후와 반복 중에 JVM·워커의 누적 CPU 시간, private bytes, working set, 핸들·스레드 수, PID와 시작 시각을 기록한다. `samples`에는 첫 회, 마지막 회와 최대 32개 간격 표본의 원시 지연과 자원 관측값이 들어간다. 같은 프로세스의 두 표본 간 `cpuMs` 차이가 해당 구간의 CPU 사용 시간이다. 워커 식별에 실패한 표본은 `available=false`다. PID 또는 시작 시각이 바뀌면 해당 백엔드의 실행을 중단한다. 실패한 보고서는 `passed=false`, `stage`, 완료한 반복 횟수와 수집한 표본을 제공한다.

더 긴 시험은 `-Sessions 5 -Iterations 1500`처럼 세션 수와 반복 수를 함께 지정한다. 세션마다 JVM·워커를 새로 시작하며 반복 한도 2,000회에 예열을 포함해도 세션당 변경 명령 4,096개 한도 안에 있다. 각 세션 안의 자원 추세와 새 세션의 기준값을 따로 비교한다. Windows 실측 결과는 이 저장소에 포함되어 있지 않다.
