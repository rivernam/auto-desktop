# 빌드 및 시험 기록

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

GUI 결과는 `target/surefire-reports/TEST-dev.desktop.WindowsGuiTest.xml`, 실행 환경은 `target/windows-uia-run.json`에 있다. 3종 벤치마크는 `tools/Compare-UiaWorkers.ps1`을 확장한 로컬 시험용 사본으로 실행했다. 성능 원본은 `target/windows-uia-benchmark-matched-retry.json`, 기존 WPF 창의 트리 비교는 `target/windows-uia-tree-comparison.json`에 있다. 레거시 빌드는 JDK 11 환경에서 `mvn -f legacy/pom.xml clean verify`로 실행했다.

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

1. Windows 10 또는 11의 잠금 해제된 대화형 데스크톱에서 JDK 17 이상과 Maven을 준비한다. 테스트 중 다른 사용자가 마우스를 움직이지 않아야 한다.
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
