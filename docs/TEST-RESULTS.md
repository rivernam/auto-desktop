# 빌드 및 시험 기록

## JNA 장시간 측정 및 분석 도구

`tools/Test-JnaSoak.ps1`은 `-IntervalSeconds`(기본 60초) 구간마다 요청 완료·실패 수, 연산별(Snapshot, FindElement, GetElementInfo, SetValue, Invoke) 호출 수와 평균·p50·p95·p99·최대 지연, 처리량, 오류 코드별 횟수를 집계한다. 구간이 끝날 때 Heap used/committed, NMT reserved/committed, Private bytes, Working set, CPU 시간, 핸들, 스레드, JVM PID·시작 시각, HotSpot GC 횟수·시간(`jcmd PerfCounter.print`)을 함께 기록한다. 실패·Timeout은 시각·구간·세션과 함께 `failures`에, 세션 재시작과 비정상 JVM 종료는 `sessionRestarts`, `unexpectedJvmExits`와 세션별 `endReason`에 남는다.

- 구간 내부 분위수는 정확한 nearest-rank 값이며, 구간이 닫히면 개별 지연 표본을 해제한다.
- 기존 `latencyMs`(snapshot, findEdit, findButton, elementInfo, setValue, invoke)는 유지한다. 전체 기간 분위수는 1% 폭 로그 히스토그램의 **근사값**(최대 1% 과대)이며 count·mean·max는 정확하다. 방식은 JSON의 `latencyStatistics`에 기록된다. 이전 60초 JSON의 분위수는 모든 표본을 보관한 정확한 값이다.
- 세션 표본의 jcmd 원문(`heap`, `nativeMemory`)은 세션의 첫·마지막 표본에만 남기고 숫자 필드는 모두 유지한다. 8시간·60초 구간 기준 구간 480개(각 약 2 KB), 표본 480개(각 약 1 KB), 히스토그램 연산당 최대 약 1,700칸으로 보관량이 실행 시간에 비례해 작게만 늘어난다.
- 구간 종료, 표본 수집 때마다 체크포인트를 저장한다. 파일은 임시 파일에 write-through로 기록한 뒤 원자적으로 교체한다. jcmd 수집 시간(`samplingMs`)과 체크포인트 저장 시간(`checkpointMs`)은 구간 시간에서 제외한다. 강제 GC는 호출하지 않는다.
- Ctrl+C로 중단하면 `interrupted`와 마지막 부분 구간을 저장한다. 프로세스가 강제 종료되면 마지막 체크포인트까지 남는다.

`tools/Analyze-JnaSoak.py`(Python 3.8 이상, 표준 라이브러리만 사용)는 기존 60초 JSON과 새 JSON, 중단된 체크포인트를 읽어 Markdown 보고서와 선택적 CSV(`jna-soak-resources.csv`, `jna-soak-intervals.csv`)를 만든다. 메모리 누수는 최초·최종 차이가 아니라 JVM 세션별 워밍업 이후 Theil-Sen 기울기, 초반·후반 중앙값, 후반부 기울기로 판정하고, 워밍업 이후 관측이 1시간 미만이면 INCONCLUSIVE로 표시한다. Heap used는 하한 포락선으로 GC 톱니를 줄인다. 입력에 없는 값은 NOT AVAILABLE로 표시하며 추정하지 않는다. 보고서 파일이 손상되고 같은 위치에 완전한 `.pending` 체크포인트가 남아 있으면 그 파일을 분석한다.

### Windows 실행 명령

잠금 해제된 대화형 데스크톱에서 프로젝트 루트를 작업 디렉터리로 사용한다. `java.exe`는 `jcmd.exe`가 함께 있는 JDK여야 한다. Oracle `javapath` 바로가기가 먼저 잡히면 JDK `bin`을 PATH 앞에 둔다. 먼저 `mvn package`로 `target/desktop-agent.jar`를 만든다.

5분 시험:

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromMinutes(5)) -IntervalSeconds 60 -SampleSeconds 30 -OutputPath .\target\windows-uia-jna-soak-5min.json
```

8시간 시험:

```powershell
.\tools\Test-JnaSoak.ps1 -Duration ([TimeSpan]::FromHours(8)) -IntervalSeconds 60 -SampleSeconds 60 -OutputPath .\target\windows-uia-jna-soak-8h.json
```

분석 보고서 생성:

```powershell
python .\tools\Analyze-JnaSoak.py .\target\windows-uia-jna-soak-8h.json --output .\target\jna-soak-analysis.md --csv-dir .\target
```

5분 결과에서 구간 데이터가 수집됐는지 확인한다. 구간 4개 이상, 각 구간의 snapshot 지연과 리소스 표본, 스키마 버전 2가 있어야 한다.

```powershell
$r = Get-Content .\target\windows-uia-jna-soak-5min.json -Raw | ConvertFrom-Json; $bad = @($r.intervals | Where-Object { !$_.latencyMs.snapshot.count -or !$_.resources.privateBytes -or $null -eq $_.resources.nmtCommittedBytes }); "schema=$($r.schemaVersion) passed=$($r.passed) intervals=$($r.intervals.Count) incomplete=$($bad.Count) failures=$($r.failedIterations)"
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

8시간 시험은 아직 실행하지 않았다.

도구 단위 시험:

```powershell
python -m unittest discover -s tools\tests -p "test_*.py"
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\tests\Test-UiaTools.ps1
```

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
