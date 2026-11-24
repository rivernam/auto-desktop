# Windows 11 C++ Native Agent와 Java/JNA 평가

## 요약

Windows 11 x64의 실제 WPF 제공자에서 독립 C++ CLI와 기존 Java/JNA CLI를 비교했다. C++는 첫 스냅샷 중앙값을 584ms에서 245ms로 줄였고, 5분 반복 시험 종료 시점의 Private Bytes는 70.80 MiB에서 9.36 MiB로 줄었다. 지속 UIA 지연의 차이는 명령과 백분위마다 달랐다. 운영 기본은 Java/JNA로 유지하면서 시작 시간·메모리 예산이 엄격하거나 JDK를 설치할 수 없는 Windows 호스트에 C++를 선택지로 두는 것을 권장한다. [C++ Agent 빌드와 실행](../native/cpp-agent/README.md)

## A. 기능 동등성

| 명령 | Java/JNA와 C++에서 확인한 결과 |
|---|---|
| `getCapabilities` | UIA 가용 상태, 7개 명령, 물리 입력·스크린샷 미제공 |
| `listWindows` | 같은 WPF 창의 제목, HWND, PID |
| `snapshot` | 장식 있는 창에서 각 20개 요소. 콘텐츠 19개와 제목 표시줄 1개 모두 일치. 부모 경로, 이름, 역할, AutomationId, 클래스, 사각형, enabled, offscreen, 패턴 및 대상 프로세스 소속 일치 |
| `findElement` | 정확 일치 AND, 대소문자 구분, 중복 거부, 부분 범위, 잘린 트리의 보수적 거부 |
| `getElementInfo` | 동일한 공개 ref와 부모 ref를 유지하며 편집 요소의 패턴과 마스킹 상태 재조회 |
| `invoke` | 버튼 카운터 1회 증가와 물리 커서 유지. 중복 명령, 비활성 요소, 권한 없는 세션 및 교체된 컨트롤 거부 |
| `setValue` | 빈 문자열과 한글·보충 평면 문자가 포함된 Agent별 고유 문자열이 WPF 상태 파일에 반영됨. 읽기 전용 컨트롤을 거부하고 기존 값을 보존 |

스냅샷·요소 ID는 비교에서 제외하고 부모 경로로 정규화했다. 정렬한 경로 목록은 중복을 보존한다. 장식 있는 창에서 제목 표시줄 경로도 확인했으며, 콘텐츠에서 빠진 요소는 없었다. 부분 트리는 기존 List의 ref로 새로 수집하고 ListItem의 부모를 확인했다. 새 스냅샷으로 교체된 ref, 다른 세션의 ref, 종료된 대상의 ref는 재사용할 수 없었다. 중복 JSON 키, 잘못된 UTF-8, 초과 프레임, 잘못된 한도 및 미지원 명령을 거부하고 후속 요청에 응답했다. [비교 스크립트](../tools/Compare-JavaCpp.ps1)

Java Maven `clean verify`는 GUI 옵션 3개를 켠 상태에서 57개 통과, 실패·오류·건너뜀 0개였다. 이 중 4개는 PowerShell, C# Worker, Java/JNA와 꾸밈이 있는 WPF 트리를 다룬다. 패키징한 JNA의 모의 COM 세션 검사와 기존 PowerShell 도구·상태 게시 검사 2개도 통과했다. CMake Release x64 빌드와 CTest 계약 시험 1개가 통과했다. CTest에서 프레임 복구, Locator와 스냅샷, ID 기록 한도, 120초 TTL, 사전 검사·전송 후 타임아웃 및 소유 스레드에서 Adapter가 파괴되는 것을 검사했다.

## B. 지연과 처리량

Windows 11 25H2 x64 빌드 26200.9974, Core i7-12700, 메모리 약 32 GiB, 균형 전원 계획의 같은 대화형 세션에서 측정했다. Java는 `main`의 `46feceb`에서 빌드해 `-XX:+UseSerialGC -Xms16m`으로 실행했다. C++는 MSVC 19.44 Release x64와 Windows SDK 10.0.26100.0을 사용했다. 장식 있는 창으로 동등성을 확인한 후, 제목 표시줄 프록시의 영향을 없애기 위해 두 Agent의 성능 측정에 같은 테두리 없는 WPF 창과 같은 PID를 사용했다.

단기는 프로세스를 매번 새로 시작한 6쌍이며, 쌍마다 시작 순서를 뒤집었다. 첫 capability, 창 열거, 스냅샷을 수집한 뒤 각 세션을 5회 워밍업하고 20회 측정했다. 1회는 Snapshot, FindElement 2회, GetElementInfo, SetValue, Invoke 순으로 요청한다. 변경 시작 사이 간격은 최소 50ms다. 두 변경 모두 WPF가 기록한 실제 상태를 확인했다. 반복 측정은 구현당 600회, 500ms 주기이며 세션마다 동일한 워밍업을 적용했다.

시작 지표는 프로세스 실행 호출 직전부터 각 지점까지 누적한 벽시계 시간이다. 단기 요청 지연은 stdin에 쓰기 직전부터 stdout 응답 한 줄을 받기까지이며 JSON 역직렬화와 WPF 상태 파일 대기는 제외한다. 처리량에는 상태 확인과 변경 간격이 포함된다. 백분위는 정렬 표본의 `ceil(p × N)`번째 값이다. 프로세스 시작 표본은 구현당 6개, 지속 단기 표본은 명령별로 120개씩이다. FindElement는 편집과 버튼 Locate를 각각 120개로 집계했다. 5분 반복 시험에서는 각 열에 600개를 수집했다.

UIA 호출과 JSON·스레드 대기·파이프 비용은 개별 계측하지 않았다. 네이티브 호출을 하지 않는 FindElement는 캐시 조회와 프레임 왕복 비용을 관찰하는 데 쓸 수 있다. OS 및 WPF 제공자 캐시는 워밍된 환경이었다. 재부팅 직후나 다른 머신에서 측정한 기존 PowerShell·C# 수치는 직접 비교에 사용하지 않았다. [기존 Windows UIA 기록](TEST-RESULTS.md)

### 새 프로세스 기동

| 누적 시간 p50, ms | Java/JNA | C++ |
|---|---:|---:|
| 프로세스 시작 호출 반환 | 5.07 | 4.12 |
| 첫 `getCapabilities` | 401.60 | 96.63 |
| 첫 `listWindows` | 518.67 | 196.35 |
| 첫 `snapshot` | 583.70 | 244.94 |

첫 스냅샷까지 339ms, 약 58% 짧았다. 6개 첫 스냅샷 중 최댓값은 Java 625.79ms, C++ 257.66ms였다. 프로세스 시작 호출 반환은 준비 완료 시각과 별개다.

### 지속 세션

각 셀은 p50 / p95 / p99이며 단위는 ms다.

| 명령 | Java/JNA 단기 | C++ 단기 | Java/JNA 5분 | C++ 5분 |
|---|---:|---:|---:|---:|
| Snapshot | 45.41 / 59.74 / 67.25 | 42.19 / 51.68 / 67.46 | 42.15 / 57.89 / 61.91 | 41.13 / 59.94 / 80.91 |
| FindElement 편집 | 0.402 / 0.572 / 0.675 | 0.122 / 0.175 / 0.259 | 0.187 / 0.368 / 0.557 | 0.124 / 0.204 / 0.274 |
| FindElement 버튼 | 0.310 / 0.455 / 0.622 | 0.100 / 0.175 / 0.337 | 0.139 / 0.305 / 0.423 | 0.104 / 0.180 / 0.216 |
| GetElementInfo | 4.49 / 6.01 / 8.10 | 3.86 / 4.66 / 4.92 | 4.13 / 5.01 / 7.91 | 3.84 / 5.16 / 8.69 |
| Invoke | 12.44 / 24.28 / 42.42 | 10.66 / 23.74 / 24.72 | 11.87 / 24.25 / 28.30 | 11.50 / 25.52 / 40.53 |
| SetValue | 13.39 / 19.88 / 109.13 | 12.06 / 16.26 / 18.14 | 12.99 / 18.48 / 67.65 | 15.82 / 24.63 / 71.83 |

단기 처리량은 전체 측정 시간으로 나눠 Java/JNA **33.42 요청/초**, C++ **35.51 요청/초**였다. 5분 시험은 각각 **12.00 요청/초**로 설정한 속도를 유지했고, 일정 초과는 한 번씩이었다. 두 구현 모두 단기 720건, 반복 3,600건에서 예기치 않은 실패가 0건이었다.

단기 Snapshot p50 차이는 3.22ms이고 p99는 비슷했다. 5분 구간에서는 C++의 Snapshot·Invoke p99와 SetValue p50·p95가 더 높았다. 캐시에서 처리하는 FindElement는 C++가 두 시험 모두 짧았다. 단기 결과와 5분 결과를 함께 보면 UIA를 호출하는 모든 명령에서 일관된 속도 우위를 확인하기 어렵다.

구간 경계 모두 AC 전원과 WPF의 전경 상태를 확인했다. 단기 호스트 평균 CPU 점유율 범위는 Java 실행 시 12.3~23.6%, C++ 실행 시 10.8~15.5%였다. 5분 평균은 각각 9.7%, 9.1%였고, C++ 구간의 호스트 입력 유휴 카운터가 초기화된 흔적이 있어 두 구간의 사용자 입력 조건이 완전히 동일했는지는 확인할 수 없었다. 5분 구간은 구현별 한 세션이며 꼬리 지연의 원인을 확정할 표본은 부족하다. [직접 측정 원본](test-results/2026-11-23-java-cpp-comparison.json)

## C. 리소스와 배포

| 항목 | Java/JNA 단기 | C++ 단기 | Java/JNA 5분 | C++ 5분 |
|---|---:|---:|---:|---:|
| Private Bytes 종료, MiB | 72.44 | 8.72 | 70.80 | 9.36 |
| Working Set 종료, MiB | 84.71 | 22.73 | 84.53 | 24.07 |
| Peak Working Set 종료, MiB | 85.85 | 22.74 | 119.48 | 24.07 |
| 구간 CPU 시간, ms | 531.25 | 265.63 | 10,796.88 | 7,484.38 |
| 핸들 종료 | 507 | 306 | 501 | 316 |
| 스레드 종료 | 26 | 9 | 23 | 9 |
| 산출물 크기, 바이트 | 5,814,261 (JAR) | 508,928 (EXE) |  |  |

단기 수치는 6개 세션의 중앙값이다. CPU는 워밍업 후부터 측정 종료까지의 프로세스 CPU 시간 증가분이며, WPF·하네스·호스트 CPU는 제외한다. 5분 종료 시 C++는 Private Bytes가 **61.44 MiB(86.8%)**, Working Set이 **60.46 MiB(71.5%)** 적었고, CPU 시간은 **3.31초(30.7%)** 적었다.

5분 세션별 프로세스 표본은 22개였다. C++ Private Bytes는 8.62 → 9.36 MiB, 핸들은 306 → 316개로 증가했다. 핸들 최대값은 320개였다. Java/JNA Private Bytes는 70.14 → 70.80 MiB, 구간 관측 범위는 68.98~80.52 MiB였다. Java/JNA 핸들은 507 → 501개였다. 5분 관측만으로 어느 쪽도 장기 누수 여부를 판단할 수 없다.

MSVC `dumpbin /headers`에서 x64, `dumpbin /dependents`에서 `ole32.dll`, `OLEAUT32.dll`, `USER32.dll`, `KERNEL32.dll` 가져오기를 확인했다. C++는 운영체제에 등록된 UI Automation COM 구현도 런타임에 사용한다. Release EXE는 MSVC 런타임을 정적으로 링크하므로 CRT 업데이트를 포함하려면 재빌드해야 한다. Java/JNA는 Java 17 이상을 요구하며 시험에서는 Temurin 21.0.11+10 x64를 사용했다. JAR에는 Jackson 및 JNA와 플랫폼용 JNA 네이티브 디스패처가 포함된다. JDK 설치 크기는 비교하지 않았다.

## D. COM 자원, 시간 제한 및 복구

C++의 전용 MTA 스레드는 `CoInitializeEx`부터 참조 해제와 `CoUninitialize`까지 담당한다. `ComPtr`가 요소와 패턴을 해제하고 BSTR 및 Runtime ID SAFEARRAY는 스코프 종료 때 해제한다. SAFEARRAY는 접근 잠금을 먼저 푼다. 등록된 프로세스는 생성 시각과 생존 상태를 확인한다. 변경 직전에 현재 창, PID와 시작 시각, Runtime ID, 보호된 조상 경로, 식별 속성, enabled·offscreen, 라이브 패턴과 쓰기 가능 여부를 검증한다. 공급자가 두 검사 사이에 UI를 바꿀 수 있어, 실행 결과는 WPF의 독립 상태로 확인했다. [Microsoft UI Automation 스레딩](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-threading)

C++는 120초가 지난 네이티브 캐시를 유휴 중에도 정리한다. Java의 공개 ref는 120초 뒤 거부되며 JNA의 네이티브 캐시는 다음 스냅샷이나 세션 종료까지 남을 수 있다. C++는 기본 창의 프로세스 시작 시각을 읽지 못하는 경우 읽기 스냅샷과 참조 재검증도 거부할 수 있다. 비밀번호, 편집 및 ValuePattern 요소는 양쪽에서 이름을 가리고 하위 노드를 생략한다. 입력값이나 원본 COM Runtime ID를 응답·감사 로그에 기록하지 않는다.

두 구현의 통신 제한은 10초다. C++는 Worker 안에서 Core 처리도 같은 기한에 포함한다. C++ 사전 검사 중 타임아웃은 변경 진입을 막고 `TIMEOUT`을 반환한다. 실제 호출 진입 후 응답 미확인은 `ACTION_OUTCOME_UNKNOWN`이다. Java/JNA는 일부 사전 검사 타임아웃도 보수적으로 결과 미상으로 처리한다. 양쪽 모두 변경 요청 자동 재시도가 없으며, C++는 타임아웃으로 세션을 폐기한 뒤에도 이미 기록한 ID를 중복으로 거부한다.

타임아웃 응답이 이미 진행 중인 COM 호출을 취소하지는 않는다. 호출이 돌아오면 소유 스레드에서 정리한다. C++는 EOF로부터 최대 10초 동안 정리를 기다린 뒤 프로세스 종료를 시도한다. 공급자 또는 DLL 정리에서 프로세스가 멎으면 외부 감독자가 프로세스 경계에서 종료해야 한다. 두 구현 모두 네이티브 접근 위반 시 해당 Agent 프로세스가 손실될 수 있다. 호출자가 변경 후 응답을 잃으면 외부 상태를 확인한 다음 새 세션과 스냅샷으로 복구해야 한다. 실제 제공자 영구 정지와 충돌, PID 재사용, 각 COM 할당의 누수는 이번 실기기 시험에서 재현하지 않았다. [Windows 프로세스 종료 동작](https://learn.microsoft.com/en-us/windows/desktop/ProcThread/terminating-a-process)

## E. 개발과 운영체제 확장 비용

C++에서는 SDK 헤더가 COM 서명·타입·인터페이스를 컴파일 시점에 확인한다. Java/JNA에서 수동으로 관리하는 COM ABI 매핑은 줄어든다. C++에서는 HRESULT, COM 리소스 수명, Unicode, 스레드와 빌드 툴체인을 계속 관리해야 한다. 현재 두 구현에 요청 파싱·참조·정책 코드가 있어 계약 변경 때 함께 회귀 검사해야 한다. Java는 기존 테스트·패키징·다른 백엔드의 공유 비용이 낮다. C++의 Windows 코드는 Adapter로 묶여 있고 Core 단위 시험은 Win32 없이 빌드할 수 있게 구성했다. Windows 이외 환경의 컴파일과 실행은 이번에 확인하지 않았다.

현대 Linux에서도 Java/JNA와 C++ 모두 플랫폼 Adapter와 접근성 테스트가 필요하다. 양쪽에서 OS 호출의 지원 범위, 좌표와 보호 정책을 별도로 구현한다. 이미 호환 JVM이 있고 같은 Core를 여러 배포판에 유지해야 하면 Java 쪽 배포가 단순하다. 호환 JVM의 확보가 어려운 레거시 이미지에서는 작은 네이티브 배포의 가치가 커지지만, 이미지별 접근성 Adapter, sysroot와 실행 시험 비용을 포함해 판단해야 한다.

| 환경 | 확장에 필요한 작업 |
|---|---|
| Windows 11 x64 | 이 보고서의 검증 범위. 제공자 종류를 확대해 Win32, 브라우저, 고 DPI, 동적 트리, 혼합 비트수·권한 및 대화형 RDP를 확인한다. |
| Windows 10, Windows Server | 지원할 빌드별 SDK 및 CRT 가져오기 목록을 대조하고 별도 실행 검증이 필요하다. Server는 Desktop Experience와 대상 앱이 있는 대화형 사용자 세션에서 검증한다. |
| Windows 7 SP1 | UIA COM 세대는 존재한다. Windows 7을 대상으로 하는 툴체인·CRT·SDK/API 하한을 선택하고 실제 OS에서 EXE 로더와 WPF/Win32 제공자를 확인한다. |
| Windows XP / XP Embedded | 장치 이미지별 Automation API 3.0 설치 여부를 확인한다. Microsoft의 플랫폼 업데이트 대상에는 XP SP3 x86이 포함된다. 해당 업데이트가 없는 이미지나 UIA가 빈약한 공급자는 별도의 MSAA/`IAccessible` Adapter가 필요하다. MSAA 기본 동작과 쓰기 가능한 값이 UIA 계약으로 매핑되는지 각각 확인한다. `v141_xp` 등 호환 툴체인에서 C++17 부분집합과 JSON 라이브러리, SDK, 런타임, 프로세스 조회 API를 검증하고 대상 이미지 및 x86/x64별로 배포한다. |
| Ubuntu 22.04, 현대 RHEL 계열 및 기타 현대 Linux | AT-SPI2의 접근성 D-Bus와 `libatspi` 또는 D-Bus 바인딩으로 Adapter를 추가한다. Toolkit별 노출, 읽기·변경 정책, 경계 좌표와 X11/Wayland 차이를 검증한다. |
| CentOS 6·7 | 지원할 설치 이미지에 실제 존재하는 접근성 스택·등록 서비스와 `glibc`·`libstdc++`·CPU ABI를 조사한다. 각 배포 기준으로 빌드하고 라이브러리 심볼 및 GUI 제공자를 검증한다. |
| CentOS 5 | GNOME 2의 AT-SPI1은 CORBA/ORBit 계열을 별도 대상으로 삼는다. 현대 AT-SPI2 Adapter로 연결할 수 있다고 가정할 수 없다. 구형 사용자 공간에 맞는 sysroot·툴체인, 필요한 경우 작은 공통 언어 부분집합과 별도 배포를 검토한다. |

XP의 UIA 가용성은 설치 이미지의 업데이트와 실제 제공자가 결정한다. 최신 MSVC로 정적으로 링크해도 가져오는 OS 함수의 최소 버전은 유지된다. Windows는 x86/x64를 각각 빌드하고 교차 비트수의 UIA 프록시 수명을 확인해야 한다. Linux도 지원할 가장 오래된 ABI를 대상으로 빌드하고 `readelf --version-info` 및 실기기에서 `GLIBC_*`·`GLIBCXX_*` 요구 버전을 확인해야 한다. [Windows 플랫폼 업데이트](https://learn.microsoft.com/en-us/windows/win32/win7ip/platform-update-for-windows-vista-overview), [Microsoft XP 툴체인](https://learn.microsoft.com/en-us/cpp/build/configuring-programs-for-windows-xp), [MSAA와 UIA 매핑](https://learn.microsoft.com/en-us/windows/win32/winauto/appendix-g--active-accessibility-bridge-to-ui-automation), [GNOME AT-SPI2](https://gnome.pages.gitlab.gnome.org/at-spi2-core/libatspi/), [GNOME CORBA에서 D-Bus로의 이전](https://wiki.gnome.org/Accessibility%282f%29Documentation%282f%29GNOME2%282d%29MigrationBreakdown), [GNU libstdc++ ABI](https://gcc.sourceware.org/onlinedocs/libstdc%2B%2B/manual/abi.html)

## F. 아키텍처 선택

이 절은 WPF 기반 초기 비교다. 현 개발 방침은 Java와 C++를 독립 제품 후보로 유지하고 레거시 Agent 기능 완성 후 운영 조건에서 비교하는 것이다. [Multi-Backend 안정화](MULTI-BACKEND-STABILIZATION.md)

| 후보 | 장점 | 비용과 판단 |
|---|---|---|
| Java Core + Java/JNA | 공유 정책·계약·테스트와 기존 Windows 백엔드 활용. 이미 JVM 안에서 UIA COM을 직접 사용 | JDK 배포, JVM 시작·상주 비용, COM ABI 매핑이 있다. 운영 기본으로 사용할 수 있는 검증 범위가 가장 넓다. |
| C++ Core + Native Adapter | JVM 없이 실행. SDK 타입이 Windows 바인딩을 검증하며 단일 OS별 EXE로 배포 가능 | 공통 정책의 이중 관리와 플랫폼별 바이너리·디버깅, 네이티브 장애에 대한 감독이 필요하다. Windows 11 WPF 이외 실기기 검증이 필요하다. |
| Java Core + C++ Native Worker | COM 장애를 별도 프로세스로 격리하면서 정책·계약·명령 기록은 Java에 유지 가능 | JVM의 시작·상주 비용에 워커와 IPC가 추가된다. 프로세스 교체 시 참조 폐기와 변경 결과 미상 처리를 설계해야 한다. 이번 비교에서는 구현·계측하지 않았다. |

제품 기본 경로에서는 Java/JNA를 유지한다. 기존 Java 계약과 다른 백엔드를 함께 운영할 수 있고, 실제 WPF에서 JVM 시작과 상주 비용 차이에 비해 지속 Snapshot 및 변경 요청의 이점은 작거나 일관되지 않았다.

C++는 JDK를 배치하기 어려운 Windows 11 환경, 새 프로세스를 자주 시작하는 호출자, 또는 측정된 Java/JNA 상주 메모리보다 낮은 Agent당 예산이 필요한 환경에서 채택할 조건이 성립한다. 실제 대상에서 첫 응답·피크 메모리 목표와 Snapshot·변경 지연의 상위 백분위를 함께 충족하는지 확인한 뒤 전환한다.

기본 경로 변경 전에 실제 대상 앱의 큰 트리·비밀번호 컨트롤·고 DPI·교차 비트·권한 조합을 시험하고, UIA 제공자의 정지·충돌 및 불명확한 변경 결과에 대한 재시작 경로를 시험해야 한다. 반복 구간은 격리한 호스트에서 순서를 바꿔 재현하고, C++ 핸들 변동을 추적할 더 긴 표본을 수집한다. 레거시 Windows와 Linux는 E절의 이미지별 Adapter·툴체인 검증을 별도로 완료해야 한다. 하이브리드 구조는 장애 격리가 배포 비용보다 중요한 경우 후보로 남긴다.

측정 후 검토에서 WPF 동등성 시험의 두 구현이 같은 입력값을 쓰는 경우를 발견했다. 구현별 고유 값과 빈 값 검사를 추가해 GUI 시험을 다시 통과했다. 기본 성능 시험의 각 연속 입력은 서로 달랐고 양쪽 모두 실제 상태를 확인했으므로 해당 지연·리소스 표본을 유지했다. [최종 동등성 재검증 원본](test-results/2026-11-23-java-cpp-parity.json)
