# Java Desktop Automation Agent

하나의 Java Core와 DesktopAdapter를 공유하는 데스크톱 에이전트다. 첫 어댑터는 Windows 10/11에서 UI Automation으로 창과 요소를 탐색하고, 요소가 제공하는 InvokePattern과 ValuePattern을 실행한다. Java CLI 한 개를 띄워 두면 같은 세션에서 스냅샷 참조를 사용할 수 있다. 실제 Windows GUI에서의 합격 여부는 [시험 기록](docs/TEST-RESULTS.md)에서 확인할 수 있다.

## 빌드와 실행

JDK 17 이상과 Maven 3.9를 사용한다. 처음 빌드할 때 Maven이 의존성을 내려받는다. 빌드한 JAR에는 Jackson, JNA 및 UIA 작업 스크립트가 포함된다. Agent 실행에는 외부 서버가 필요하지 않다.

```sh
mvn clean verify
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar
```

`-XX:+UseSerialGC -Xms16m`는 권장 JVM 옵션이다. 옵션이 없으면 JVM이 물리 메모리의 1/64를 초기 Heap으로 커밋해, 32 GiB PC에서 Agent 프로세스가 시작하자마자 약 620~640 MiB를 쓴다. 옵션을 주면 55~70 MiB다. JNA 백엔드 10분 시험에서 약 63 MiB로 유지됐고 반복당 JVM CPU 시간은 같았다. 최대 Heap은 바꾸지 않으므로 필요하면 늘어난다. 측정값은 [Heap 옵션 비교](docs/TEST-RESULTS.md#2026-11-23-heap-옵션-비교)에 있다.

CLI가 실행되면 JSON 한 줄을 입력할 때마다 응답 한 줄을 출력한다. 다음 두 명령은 조회 전용이다.

```jsonl
{"id":"probe","op":"getCapabilities"}
{"id":"windows","op":"listWindows"}
```

Windows에서는 로그인한 사용자의 로컬 대화형 세션에서 대상 앱과 같은 권한 수준으로 실행한다. 기본 백엔드에는 Windows PowerShell 5.1과 .NET Framework의 UI Automation 어셈블리가 필요하다. 출력된 창의 PID를 확인한 뒤 변경이 필요한 경우에만 새 세션을 시작한다. 아래의 1234는 승인한 테스트 앱의 실제 PID로 바꾼다.

```powershell
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --allow-pid 1234 --allow-action invoke --allow-action setValue
```

Windows 통합 테스트는 독립된 WPF 창을 만들고 해당 PID만 허용한다. Windows 10/11 테스트 데스크톱에서 마우스를 건드리지 않고 실행한다.

```powershell
mvn '-Ddesktop.windowsIT=true' '-Dtest=WindowsGuiTest' test
```

## C# 워커와 비교하기

기본 실행은 기존 PowerShell 워커를 사용한다. C# 워커는 Windows에서만 선택하는 별도 EXE다. Java API, NDJSON 명령, Snapshot Reference 및 허용 정책은 두 방식에 공통이다. Windows용 .NET Framework 4.8 또는 4.8.1 런타임이 필요하다. 소스에서 워커를 다시 빌드하려면 .NET Framework 4.8 Targeting Pack이 설치된 Visual Studio Build Tools의 Developer PowerShell에서 다음을 실행한다. 배포 ZIP에는 빌드한 EXE와 JAR가 해당 경로에 들어 있다.

```powershell
msbuild .\workers\csharp\UiaWorker.csproj /p:Configuration=Release
$worker = (Resolve-Path '.\workers\csharp\bin\Release\UiaWorker.exe').Path
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --csharp-worker "$worker"
```

`--csharp-worker`에는 로컬 운영자가 배포한 신뢰할 수 있는 EXE의 절대 경로를 지정한다. 두 워커에서 변경을 수행할 때는 같은 `--allow-pid` 및 `--allow-action` 옵션이 필요하다. C# 워커 기동에 실패하면 원래 요청에 실패 또는 capability 응답을 반환한다. 다른 워커로 같은 명령을 자동 전송하지 않는다.

같은 전용 WPF 창의 테스트를 두 방식으로 실행할 때는 아래 명령을 사용한다. 테스트 앱을 띄우는 데에는 Windows PowerShell이 필요하다.

```powershell
mvn '-Ddesktop.windowsIT=true' '-Ddesktop.csharpIT=true' "-Ddesktop.csharpWorker=$worker" '-Dtest=WindowsGuiTest' test
```

## 문서

- [PowerShell·JNA 직접 COM·C# 워커 비교와 권고](docs/WINDOWS-BACKENDS.md)

- [Vercel 원본과 Java Core의 구조·명령 대조](docs/UPSTREAM-COMPARISON.md)
- [명령 예제, JSON 모델과 오류 코드](docs/API.md)
- [실행 구조와 Phase 2~5 개발 계획](docs/ARCHITECTURE.md)
- [접근성 기술 선택 근거 및 원본 자료](docs/TECHNOLOGY-DECISIONS.md)
- [OS·런타임 호환성 및 레거시 검증 전략](docs/COMPATIBILITY.md)
- [빌드·테스트 결과와 남은 실기기 시험](docs/TEST-RESULTS.md)
- [Win32·MFC·VCL·Swing/AWT·WPF·WinForms 호환성 및 재현 명령](docs/UI-FRAMEWORK-COMPATIBILITY.md)

## Windows 실기기 및 레거시 검증

Windows 10/11 테스트 데스크톱에서 프로젝트 루트의 `.\tools\Test-WindowsUia.ps1`을 실행한다. 두 워커에 대해 전용 WPF 앱의 상태·커서·장애 복구를 확인하고 Surefire 보고서와 환경 기록을 생성한다. 성능 비교는 별도 Compare-UiaWorkers.ps1에서 실행한다. [시험 결과](docs/TEST-RESULTS.md) · [레거시 실행 방법](docs/COMPATIBILITY.md)

## JNA 직접 호출 PoC

Windows 10/11의 대화형 데스크톱에서 다음 명령으로 Java 프로세스 안의 UI Automation COM 어댑터를 선택한다. 첫 줄은 조회 전용이다. 변경 요청에는 기존 PID 및 액션 허용 옵션이 그대로 적용된다. 옵션을 생략하면 기존 기본 백엔드를 사용한다.

```powershell
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --backend jna
java -XX:+UseSerialGC -Xms16m -jar target/desktop-agent.jar --backend jna --allow-pid 1234 --allow-action invoke --allow-action setValue
.\tools\Test-WindowsUia.ps1 -IncludeJna
```

마지막 명령은 Windows의 동일한 WPF 시험을 PowerShell, C#, JNA에 대해 실행한다. [JNA 설계 및 채택 기준](docs/JNA.md)

JNA 장시간 안정성은 구간별로 측정하고 Python 표준 라이브러리 도구로 분석한다. 측정은 JVM과 함께 시험 앱·호스트 지표와 GC 로그를 남겨 느린 구간의 원인을 좁힐 수 있게 한다. `-JvmOptions`로 위의 권장 JVM 옵션을 준다. 5분 확인 절차와 옵션 설명은 [장시간 측정 도구](docs/TEST-RESULTS.md#jna-장시간-측정-및-분석-도구)에 있다.

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromMinutes(5)) -IntervalSeconds 60 -SampleSeconds 30 -JvmOptions '-XX:+UseSerialGC -Xms16m' -OutputPath .\target\windows-uia-jna-soak-5min.json
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromHours(8)) -IntervalSeconds 60 -SampleSeconds 60 -JvmOptions '-XX:+UseSerialGC -Xms16m' -OutputPath .\target\windows-uia-jna-soak-8h.json
python .\tools\Analyze-JnaSoak.py .\target\windows-uia-jna-soak-8h.json --output .\target\jna-soak-analysis.md --csv-dir .\target
```
