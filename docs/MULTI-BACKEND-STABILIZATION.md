# Java와 C++ Multi-Backend 안정화

기준은 원격 `main`의 `f70de7ccc9a96119e67856f2ed08dc431bab7a0a`다. Windows 11 x64에서 Temurin 21.0.11로 Java Agent와 Swing 픽스처를, Oracle Java 11.0.15로 두 번째 AWT 픽스처를 실행했다. 기본 DLL 선택에서 Java Agent는 Temurin 21 DLL을, C++ Agent는 Windows 시스템 디렉터리의 11.0.15 DLL을 사용했다. Java와 순수 C++는 각자의 Agent, 세션과 어댑터를 유지한다.

## A. 초기 실패 원본과 재현

| 항목 | 초기 증상과 재현 근거 | 이번 결과 | 상태 |
|---|---|---|---|
| A-1 C++ JAB 모달 | 기능 1차에서 두 번째 모달 클릭은 `OK`였고 상태 파일은 `open`을 확인하지 못했다. DLL 반환값과 호출 시간, 앱 이벤트 순서, 당시 입력은 원본에 없다. | 독립 픽스처 타임라인에서 모달 생성과 개방, 테스트의 닫기 명령과 종료를 구분한다. 최신 재검사에서 같은 비정상 조합은 나오지 않았다. DLL의 비영 반환이 정상 성공이 될 수 있던 판정 경로는 B에서 보강했다. | 원인 미확정 |
| A-2 Java 중복 거부 뒤 카운터 | 기능 2차의 로그에 약 0.5 ms의 `DUPLICATE_COMMAND`가 있다. 그 뒤 카운터가 기대와 달랐으나 당시 카운터 이벤트와 발행 시각, 요청 ID와 참조가 함께 남아 있지 않다. | 양쪽에서 같은 백엔드 및 양방향 교차 중복, 오래된 ref, 결과 미상 이후 같은 ID, UIA 교체 뒤 같은 ID를 검사했다. 동시 호출 단위 시험은 공급자 호출을 직접 세고 실기기 시험은 별도의 카운터와 텍스트 상태를 확인한다. 초기 불일치는 재현되지 않았다. | 원인 미확정 |
| A-3 UIA Edit 누락 | 기능 2차의 C++ 복구 스냅샷은 Edit 없이 약 14 ms에 끝났고 후속 WPF 탐색도 실패했다. 같은 시기의 성능 18개 중 3개는 AWT 창 탐색 실패, 3개는 UIA 요소 2개였다. 당시 트리 반환과 입력·창 상태를 같은 순간에 비교할 수 없다. | UIA 재생성 후 두 구현에서 AWT 첫 캡처 23개 요소와 Edit 조회가 확인됐다. 별도 IUIAutomation Control View 관찰자로 같은 창을 앞뒤에서 조회하는 시험을 추가했다. 현재 결과와 최초 증상의 원인은 별도로 기록한다. | 원인 미확정 |

기능 1차는 81 PASS·2 FAIL·1 NOT_RUN, 2차는 78 PASS·3 FAIL·3 NOT_RUN으로 기록됐다. 당시 마지막 입력이 실패 시간대와 겹친다는 후속 기록은 있다. 어떤 입력이 어떤 테스트 픽스처를 바꿨는지는 확인할 수 없다. 최종 기준선의 기능은 84/84였다. 성능, 10분 혼합 반복과 단일 백엔드 회귀 원본을 함께 대조했다. [기능 1차](test-results/2026-11-24-multi-backend-functional-attempt1.json) · [기능 2차](test-results/2026-11-24-multi-backend-functional-attempt2.json) · [실패가 있던 성능 실행](test-results/2026-11-24-multi-backend-performance-attempt2.json) · [최종 기준선 기능](test-results/2026-11-24-multi-backend-functional.json) · [최종 기준선 성능](test-results/2026-11-24-multi-backend-performance.json) · [기준선 혼합 반복](test-results/2026-11-24-multi-backend-soak.json) · [UIA 기준선](test-results/2026-11-24-multi-uia-regression.json) · [JAB 기준선](test-results/2026-11-24-multi-jab-regression.json)

첫 독립 관찰에 쓴 관리형 .NET UIA 클라이언트는 같은 창에서 Edit를 찾지 못했지만 두 Agent 모두 23개 요소와 Edit를 받았다. 해당 관찰자만으로 Agent 누락을 판정할 수 없어 기존 COM 관찰 도구에 Edit 매칭을 추가했다. 최소화, 비활성, 복원 상태에서 COM 관찰과 두 Agent가 Edit를 찾았다. 복원 후에는 AWT가 전경이었다. 별도 전경 전환 시도는 창 관리자가 전경을 넘기지 않아 `NOT_RUN`이다. 가상 데스크톱, 잠금 및 보안 입력 데스크톱은 전용 환경에서 검증해야 한다. [관리형 관찰 원본](test-results/2026-11-24-stabilization-uia-observer-attempt.json) · [COM 관찰과 메타데이터](test-results/2026-11-24-stabilization-context-metadata.json)

같은 ID를 담은 두 프레임을 한 번의 쓰기로 전송했다. 두 Agent에서 입력 순서대로 `OK`, `DUPLICATE_COMMAND`가 왔고, 두 응답 구간에 JAB DLL은 한 번만 호출됐으며 독립 카운터도 정확히 1 증가했다. [파이프라인 중복 실행 원본](test-results/2026-11-24-stabilization-pipelined.json)

## B. JAB 응답 신뢰성

OpenJDK 11.0.15와 21.0.11의 Windows DLL은 요청을 JVM별 매핑에 복사하고 버퍼 끝 완료 바이트를 초기화한다. `SendMessageTimeout`은 `SMTO_BLOCK | SMTO_NOTIMEOUTIFNOTHUNG` 옵션과 4초 값을 받는다. 겉에서 관찰하는 호출 시간은 4초보다 길 수 있다. 소스상 완료 바이트는 DLL 내부에서 검사하며 Windows API의 전송 결과와 완료 바이트를 공개 함수에서 따로 읽을 수 없다. `doAccessibleActions`는 성공에 정수 `1`과 실패 인덱스 `-1`을 반환한다. 실패 인덱스는 JVM 쪽이 요청 하나를 모두 끝냈을 때의 응답 필드지만, 공개 함수가 해당 필드의 출처를 보증하는 별도 토큰은 없다. `setTextContents`는 성공 여부만 반환한다. [OpenJDK 11 Windows 전송](https://github.com/openjdk/jdk11u/blob/jdk-11.0.15%2B10/src/jdk.accessibility/windows/native/libwindowsaccessbridge/AccessBridgeJavaVMInstance.cpp) · [OpenJDK 21 Windows 전송](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/native/libwindowsaccessbridge/AccessBridgeJavaVMInstance.cpp) · [OpenJDK 21 공개 함수 구현](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/native/libwindowsaccessbridge/WinAccessBridge.cpp) · [OpenJDK 21 JVM 쪽 결과 기록](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/native/libjavaaccessbridge/AccessBridgeJavaEntryPoints.cpp)

정상 버튼은 두 구현에서 `raw=1 failureIndex=-1`로 돌아왔다. 정상 Swing 쓰기도 `raw=1`이었다. 모달이 열린 동안 C++ 재검사 두 번에서는 약 8초 후 `raw=1046831376 failureIndex=-1`이 나왔다. Java 기능 실행에서는 같은 시간대의 호출에서 `raw=20 failureIndex=-1`을 관찰했다. 원본 수치가 DLL 내부 완료 상태의 직접 증거인지 확인할 수 없어 3.5초 제한은 유지했다. Invoke는 반환 정수와 실패 인덱스를 모두, SetValue는 반환 정수를 검사한다. 값이 모순되거나 기한 이후에 돌아오면 결과 미상이다. Provider 호출을 자동으로 다시 보내지 않는다. `performed`는 Agent가 정상 Provider 반환을 확인했다는 뜻이고 `effectVerified`는 계속 false다. **부분 해결.** [Java 기능 및 PoC](test-results/2026-11-24-stabilization-functional-first.json) · [C++ 모달 재검사](test-results/2026-11-24-stabilization-jabfault-recheck.json)

## C. Swing 모달과 프로세스 격리 PoC

Swing 버튼의 리스너는 이벤트 스레드에서 모달 대화상자를 연다. JAB의 동기 Invoke는 리스너가 돌아오기를 기다리므로 그 JVM의 브리지 메시지 처리도 정지한다. 이벤트 알림 API는 있으며 Invoke 또는 SetValue를 비동기로 요청하는 공개 API는 확인하지 못했다. 열린 모달을 파일 명령으로 닫은 뒤 같은 JVM의 기존 참조를 다시 조회하고 정상 버튼을 조작했다. [OpenJDK 21 Java AccessBridge](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/classes/com/sun/java/accessibility/internal/AccessBridge.java)

`IsolatedJab`은 같은 구현의 JAB Agent를 JVM A(Swing)와 B(AWT)용으로 하나씩 시작하고, WPF용 UIA 프로세스를 따로 시작한다. 세 Agent의 PID 정책은 각 픽스처 하나만 허용한다. A의 Invoke는 Java 8.05초, C++ 8.01초에 결과 미상으로 끝났고 모달은 열려 있었다. B의 조회, Invoke, 스냅샷은 둘 다 `TARGET_NOT_RESPONDING`이었다. B 카운터는 준비 때 기록한 1을 유지했고, WPF는 각 실행에서 1에서 2로 증가했다. A의 모달을 닫은 뒤 A의 이전 ref가 다시 읽혔다. B를 정상 종료해 다시 띄운 후 이전 ref는 거부되고 새 ref로 카운터가 2가 됐다.

두 에이전트의 JAB 사전 검사는 연결된 JVM의 응답을 검사한다. DLL도 HWND에서 JVM을 찾는 `isJavaWindow`와 `getAccessibleContextFromHWND`에서 연결된 JVM 목록을 순회한다. 유효 PID 목록은 변경을 허용하는 범위를 제한하며 DLL 등록 대상을 제어하지 않는다. 결과는 이 DLL과 현재 어댑터에서 PID별 프로세스가 JVM 격리를 제공하지 않았음을 보여 준다. 실제 제품에서 JVM별 격리가 필요하면 대상 연결을 제한하는 통신 방식을 실험해야 한다. 네이티브 프로세스 충돌과 백엔드 종료 격리는 별도의 평가 항목이다. **구조적 제약.** [OpenJDK 21 Windows 브리지 탐색](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/native/libwindowsaccessbridge/WinAccessBridge.cpp)

## D와 E. 복구와 공유 조회 기한

| 문제 | Java | C++ | 검증과 한계 |
|---|---|---|---|
| 겹치는 UIA/JAB 조회 | `Agent`가 각 Adapter에 읽기 작업을 즉시 제출하고 동일 기한으로 결과를 수집한다. | `MultiSession`이 각 `SessionWorker`에 같은 절대 기한을 준다. | 초기 3백엔드 테스트는 양쪽에서 실패했고 수정 뒤 통과했다. 목록의 순서와 부분 성공 계약을 유지한다. |
| 메시지 서비스 | JAB 소유 스레드가 자기 조회가 끝난 뒤 다른 조회가 끝날 때까지 숨은 창의 메시지를 처리한다. | 같은 원칙을 기존 Worker의 `serve`에 적용한다. | 실제 WPF·AWT·Swing 목록을 확인했다. 동시에 네이티브 작업 중인 JAB가 메시지를 처리하지 못하면 그 영향은 조회 기한에 의해 제한된다. |
| UIA 일시 정지 | 대기 중 취소와 네이티브 변경 진입을 구분한다. 교체가 끝난 UIA의 이전 스냅샷을 로컬 Locator에서도 거부한다. | 기존 변경 진입 게이트를 유지하고 조회의 작업 시작과 응답에 공유 기한을 적용한다. | WPF 프로세스 일시 정지 주입 후 JAB 조작은 계속됐다. WPF를 재개하면 UIA 재생성과 이전 ref 무효화를 확인했다. 실제 호출이 영구히 반환하지 않으면 해당 프로세스의 UIA는 복구할 수 없다. |
| 초기화 및 폐기 | 회복할 수 없는 초기화 실패 사유를 유지한다. 네이티브 정리 실패를 Worker 스레드에서 CLI에 전달한다. | 초기화 예외를 백엔드 미가용으로 보고하고 자동 교체 반복을 막는다. Worker의 종료 대기를 공통 기한으로 맞춘다. | 누락된 DLL과 브리지를 켜지 않은 JVM에서 부분 실패를 시험했다. JAB 자체가 폐기되면 새 Agent가 필요하다. 콜백으로 시작 제한을 검증했으며 네이티브 DLL 충돌은 미실행이다. |

읽기 두 연산의 기한은 통상 10초다. 하나의 NDJSON 요청 안에서 읽기만 겹치며 다음 프레임 전에는 현재 프레임의 결과를 반환한다. UIA COM과 JAB의 스레드 소유권은 유지한다. 백엔드가 이미 폐기 중이면 빠르게 응답하며 안전하게 정리된 UIA만 요청 시 다시 생성한다. 대기 제한은 실행 중인 COM 호출을 취소하는 기능이 아니다. **공유 기한 해결, 네이티브 복구 부분 해결.** [공통 API](API.md)

두 구현에서 400 ms의 기한을 가진 3개 Provider를 모두 정지시키고 한 요청에서 TIMEOUT 행 3개를 검증했다. C++에서는 Bridge Worker와 프로토콜 대기자가 같은 기한을 관찰해도 변경을 전송한 사실이 보존된다. Java에서는 기한 후 도착한 Provider 오류가 TIMEOUT을 덮어쓰지 않으며, 소유 스레드가 종료 중이어도 기한 내에 확인된 변경 응답을 전달한다.

## F와 G. 할당 측정과 세션 수명

4,096개의 ID를 기록하는 Core 워크로드를 무보관 대조군과 비교했다. 각 실행에서 0·512·1,024·2,048·4,096개에 멈춰 샘플링했다. Java는 Serial GC와 16 MiB 초기 Heap을 사용하고 각 체크포인트의 GC 후 사용량을 보고했다. C++는 Windows Private Bytes와 Working Set을 제공한다.

| 식별자 길이 | Java GC 후 Heap 차이 | C++ Private Bytes 차이 |
|---|---:|---:|
| 36 ASCII 문자 | 517,080 B, 약 126 B/ID | 729,088 B, 약 178 B/ID |
| 128 ASCII 문자 | 878,808 B, 약 215 B/ID | 1,064,960 B, 약 260 B/ID |

차이는 각 실행의 최초와 최종 차에서 무보관 대조군의 증가분을 뺀 값이다. C++의 이 표본에서 대조군 Private Bytes는 그대로였다. 이 실측으로 명령 기록 증가분의 크기를 확인했으며 과거 4,002건에 약 1.5 MiB가 모두 명령 기록이었다고 결론내릴 수는 없다. 사전 할당, 네이티브 객체, 플랫폼 Heap의 페이지 보유를 포함하는 별도 측정이다. C++ 할당 사이트, 객체별 수명과 STL 버킷 용량의 계측은 미실행이다. Java는 백엔드별 최신 native 캡처 하나를 다음 교체 또는 정리까지 보유할 수 있고 C++는 스냅샷 만료 때 자체 스레드에서 캐시도 정리한다. **메모리 원인 부분 해결.**

5분 혼합 반복은 Java 300.7초·1,590회·조작 3,657건, C++ 300.6초·1,606회·조작 3,692건이었다. 두 실행 모두 1개의 프로세스와 세션을 사용했고 실패 0건과 종료 코드 0을 기록했다. 첫·마지막 Private Bytes는 Java 71.2→74.1 MiB, C++ 9.54→11.04 MiB였다. 이 수치에는 명령 ID 이외의 UIA/JAB 리소스와 allocator 보유 페이지가 함께 들어 있다. [Core 대조군](test-results/2026-11-24-stabilization-history.json) · [혼합 반복 원본](test-results/2026-11-24-stabilization-soak.json)

별도 실행은 Agent마다 유휴와 40회씩의 Snapshot, Snapshot+Locator, GetElementInfo, Invoke, SetValue, 혼합, UIA 창 교체를 측정했다. 16개 실행이 정상 종료했다. C++의 정착 표본에서 유휴·Info·Invoke·SetValue는 Private Bytes 차이가 0이고, Snapshot 80 KiB, Snapshot+Locator 68 KiB, 혼합 116 KiB, 창 교체 144 KiB가 증가했다. Java의 값은 GC와 페이지 재사용 영향을 받아 유휴 표본에서도 약 5 MiB 줄었다. 백엔드 재생성은 UIA 장애 시나리오에서 검증했으며 반복 재생성의 별도 할당 추적은 미실행이다. [개별 워크로드 원본](test-results/2026-11-24-stabilization-resources.json) · [최종 Java 복구 재검증](test-results/2026-11-24-stabilization-java-recovery.json)

세션당 4,096개 상한을 유지한다. 이 상한은 부하 예측과 중복 방지를 함께 제공한다. FIFO·LRU·TTL로 이전 실행 기록을 삭제하면 이전 명령이 다시 실행될 수 있다. 논리 세션 교체나 영속 기록을 도입하려면 ID의 범위와 만료 이후 재전송, 저장소 장애 시 착수 기준을 외부 계약으로 정해야 한다. 현재 프로세스 재시작은 새 세션을 발급하며 이전 실행 기록을 검사하지 않는다. 새 세션에서도 멱등성이 필요한 호출자는 별도의 명령 기록과 대상 상태 확인을 적용한다. **세션 정책 검토 완료.** [공통 API](API.md)

## H. JAB 편집 가능 표시

Java와 C++ 모두 JAB 편집 요소의 `setValueSupport`를 보고한다. 쓰기 후보는 `unverified`, 편집 상태를 제공하지 않는 요소는 `unsupported`다. JAB AccessibleContextInfo는 텍스트 인터페이스와 편집 상태를 내보내지만 `setTextContents`가 확인하는 컨텍스트의 `AccessibleEditableText` 구현 여부는 표시하지 않는다. AWT의 표준 TextField와 TextArea에 UIA로 새 참조를 발급할 수 있다. Swing의 쓰기 경로와 기존 클라이언트의 `actions` 후보를 유지했다. 쓰기 요청 전에 실행해 보는 capability 탐지는 자체적으로 텍스트를 바꾸므로 사용하지 않는다. AWT와 Swing 양쪽에서 편집 가능 표시와 실제 쓰기 결과를 구분한다. **부분 해결.** [OpenJDK 21 Java AccessBridge](https://github.com/openjdk/jdk21u/blob/jdk-21.0.11%2B10/src/jdk.accessibility/windows/classes/com/sun/java/accessibility/internal/AccessBridge.java)

## I. 민감정보와 종료

Provider의 Name은 탐색 메타데이터다. 앱에서 명시적으로 Name에 넣은 동적 라벨이나 입력 문자열은 Locator로 사용할 수 있으므로 공개 응답에도 나타날 수 있다. 비밀번호 역할은 이름을 가리고, JAB Description 및 텍스트 내용과 UIA ValuePattern의 실제 값은 노출하지 않는다. UIA 편집·비밀번호·ValuePattern 요소의 하위 탐색도 제한한다. 감사 출력은 연산, 결과 코드, 지연에 한정한다. 진단 로그에는 JAB 정수 반환과 시각만 추가하고 입력 문자열은 기록하지 않는다. 실기기에서 두 Agent의 비밀번호 Name 가림, 일반 쓰기 값과 Description 생략, Name 변경 뒤 Locator 성공, stderr의 입력 문자열 생략을 확인했다. 앱이 업무 데이터를 Name에 직접 넣는 경우는 별도의 제품 구성 또는 결과 보존 정책이 필요하다. **부분 해결.** [공통 API](API.md#참조-조회-범위와-실행-조건) · [메타데이터 시험](test-results/2026-11-24-stabilization-context-metadata.json)

UIA가 정지한 WPF에 대해 `TIMEOUT`을 반환한 뒤 EOF를 보내면 Java와 C++는 약 10초 후 모두 코드 1로 끝났다. JAB의 무응답이 알려져 DLL 해제를 건너뛸 수 있는 경우에는 두 구현에서 EOF가 신속하게 코드 0으로 끝났다. 새 세션에서 두 대상 JVM과 WPF를 다시 사용할 수 있었다. 잘못된 시작 인자는 2, 잘못된 프레임은 응답 오류이며 정상 EOF에서 0이다. 외부 강제 종료나 OS의 DLL 충돌 상태는 감독자가 별도로 기록해야 한다. **종료 상태 해결.** [공통 API](API.md#프로세스-종료)

## J. 재현성 및 남은 검증

`Test-MultiBackend.ps1`은 요청 ID와 ref, 전후 시각, 응답 코드와 지연, 스냅샷 요소 및 Edit 개수, 실패백엔드 정보, 픽스처 이벤트와 상태 파일 발행 순서를 보존한다. 호스트 기록에는 입력 데스크톱, 마지막 입력 추정 시각, 전경 픽스처 유형과 창 상태를 남긴다. 외부 창의 제목과 입력 내용은 수집하지 않는다. `AUTO_DESKTOP_NATIVE_TRACE=1`은 요청과 비교할 JAB 호출 시각·반환값을 stderr에 추가한다. 로깅이 없는 초기 시도의 실패를 사용자 간섭으로 판정하지 않았다.

보고서의 `status`는 합격 여부이며 `classification`은 확인된 원인을 별도로 담는다. 환경 간섭과 Agent 결함은 직접 증거가 있을 때 분류한다. 원인 미확정은 `INCONCLUSIVE`, 조건을 만들지 못했거나 픽스처를 시작하지 못한 경우는 `NOT_RUN`이다. Provider의 한계를 기록한 기존 실패는 실패 상태로 보존한다.

PowerShell 7에서 Win32 관찰 보조 코드에 필요한 .NET 참조가 빠졌고 회귀 판정기가 .NET Framework 전용 파서를 사용해 실패했다. 보조 코드의 참조를 고치고 런타임에 맞는 파서를 공유한다. 실패가 담긴 첫 결과를 별도로 보존했다. C++ 모달의 첫 실행은 WPF 픽스처 프로세스 시작이 Windows에서 거부돼 미실행으로 남겼다. 같은 빌드의 재검사에서 11개 검사가 모두 통과했다. [회귀 도구 첫 실행](test-results/2026-11-24-stabilization-uia-harness-attempt.json) · [C++ 모달 재검사](test-results/2026-11-24-stabilization-jabfault-recheck.json)

### 성능 비교

동일 Windows의 AWT 빌드에서 모드별 3회 측정했다. 기준선은 반복 20회, 이후 시험은 30회이고 준비는 각 3회다. 전체 벽시계 시간은 67초와 87초였다. 아래 값은 Multi 모드의 중앙값이며, 짧은 실행의 수 ms 편차만으로 성능 변화량을 확정할 수 없다.

| Agent | 창 목록 전 → 후 | UIA Snapshot 전 → 후 | JAB Snapshot 전 → 후 |
|---|---:|---:|---:|
| Java | 96.36 → 97.28 ms | 60.35 → 65.13 ms | 12.96 → 13.17 ms |
| C++ | 95.90 → 93.64 ms | 55.83 → 58.25 ms | 10.61 → 11.14 ms |

기준선과 시험 후 원본에는 각 모드의 시작 지연, Snapshot p95, CPU, 핸들 및 스레드 표본이 있다. 세 작업자 Fault Injection은 공통 기한 동작을 검증하며, 정상 실행의 지연 비교와는 별도다. [수정 전](test-results/2026-11-24-stabilization-performance-baseline.json) · [수정 후](test-results/2026-11-24-stabilization-performance.json)

### 검증 결과

| 시험 | 결과 | 소요 시간 |
|---|---|---:|
| Java Maven 전체, WPF 통합 시험 포함 | 109개 중 106개 통과, 3개 미실행 | 23.5초 |
| C++ CTest | Release x64·x86 각각 1/1 | 2.2초·2.5초 |
| 공통 NDJSON 계약 | Java·C++ 각각 9/9. 최초 EOF, 비정상 시작 인자, 손상·초과 프레임 후 계속 처리, 초기화 미가용 포함 | 3초 이내 |
| UIA 실기기 회귀 | Win32, WPF, 두 WinForms, Swing, AWT의 12개 결과 행과 256개 검사에서 기준선의 상태·분류와 일치. PASS 214, 기존 FAIL 32, NOT_RUN 10 | 179.5초 |
| JAB 실기기 회귀 | 기존 Swing 33/34와 AWT 27/30이 두 구현에서 일치. 128개 검사에서 기준선의 상태·분류와 일치 | 137.6초 |
| 장애 및 실제 GUI | WPF 정지·복구, JAB 모달, JVM 2개와 WPF를 사용한 분리 PoC, 누락 DLL, 종료 정책, 피처 PID 교체 | 최초 신규 기능 실행 228.2초, C++ 모달 재검사 26.7초, 최종 Java 재검사 49.2초 |
| 독립 COM 관찰 및 메타데이터 | 8개 PASS, 8개 NOT_RUN. 각 Agent에서 비활성·최소화·복원과 메타데이터를 확인 | 32.7초 |
| 리소스 | Core 명령 ID 대조군, 개별 워크로드 16개, 혼합 반복 두 번 | 2.4초, 67.5초, 610.7초 |
| NDJSON 파이프라인 중복 | 실기기에서 프레임 두 개를 한 번에 전송하고 Agent별 Provider 호출 1회 확인 | 22.9초 |

UIA의 FAIL 32건은 기존 `UIA_PROVIDER_LIMITATION` 14건과 `JAB_ONLY` 18건이다. JAB의 FAIL 4건과 NOT_RUN 4건은 Swing의 모달과 AWT의 편집 기능 제약에 해당한다. 이 상태는 원본에 그대로 남겼다. MFC는 이 호스트에 필요한 MSVC MFC 헤더와 라이브러리가 없어 구성 단계에서 중단됐고, Delphi VCL 빌드도 이 호스트에 없었다. Java의 별도 C# Worker 시험, x86 실기기 GUI, 가상·잠금·보안 데스크톱, 네이티브 DLL 충돌과 8·24시간 반복은 미실행이다. 120초 TTL은 단위 시험과 기존 Windows 기능 원본을 확인했고 이번 실기기 실행에서는 181초 시나리오를 생략했다.

원본에는 각 실행에서 사용한 JAR·EXE 해시를 남겼다. 단기 성능과 5분 혼합 반복은 코드 리뷰의 마지막 기한 경계 수정 전 바이너리로 측정했다. 마지막 수정은 양쪽 단위 테스트, 공통 프로토콜 시험, UIA 회귀와 메타데이터 실기기 시험에서 검증했다. 저장소에 실은 JSON은 사용자 경로와 일부 합성 텍스트를 가렸고 관찰 수치와 판정은 유지한다. [UIA 회귀](test-results/2026-11-24-stabilization-uia-regression.json) · [JAB 회귀](test-results/2026-11-24-stabilization-jab-regression.json)

저장한 JSON 14개의 실행 시간 합계는 1,668.6초다. 최종 Maven, CTest, 프로토콜 검사 등의 시간은 별도이며, 동시에 실행된 항목이 있어 합계는 전체 작업의 벽시계 시간과 다르다. 첫 Maven GUI 실행에서는 Windows PowerShell이 샌드박스 임시 경로의 픽스처 스크립트를 거부했다. 워크스페이스 아래의 임시 디렉터리로 옮긴 실행에서는 WPF 통합 시험이 통과했다.

후속 작업 순서는 실제 설비와 전용 Windows 데스크톱에서 A-1~A-3 재현, 별도 프로세스 감독과 대상 JVM 연결 제한 연구, MSAA 참조 및 재검증 계약 설계, 레거시 기능 양쪽 구현이다. 현재 검증 범위에서 기능 개발을 이어갈 수 있으며 모달·잠금 환경의 무인 운용과 최종 언어 결정에는 별도 실기기 자료가 필요하다.

### 재현 명령

`$cpp`는 이번 빌드의 x64 실행 파일, `$secondJava`는 다른 대상 JVM의 `java.exe`다. 테스트 전용 Windows 대화형 세션에서 각 실행의 출력 파일을 따로 지정한다.

```powershell
mvn -o verify
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
New-Item -ItemType Directory -Force target/framework-fixtures/swing-awt | Out-Null
javac --release 11 -d target/framework-fixtures/swing-awt tests/fixtures/swing-awt/FrameworkFixture.java
$cpp = 'target/cpp-agent/Release/cpp-agent.exe'
& ./tools/Test-MultiBackend.ps1 -Agent Both -Scenario JabFault,UiaFault,IsolatedJab -CppAgent $cpp -SecondFixtureJava $secondJava
& ./tools/Test-MultiBackend.ps1 -Agent Both -Scenario UiaContexts,Metadata -CppAgent $cpp -OutputPath target/context-metadata.json
& ./tools/Test-MultiBackend.ps1 -Agent Both -Mode Resources -Iterations 40 -CppAgent $cpp -OutputPath target/resources.json
& ./tools/Measure-CommandHistory.ps1 -CppTest target/cpp-agent/Release/agent-core-test.exe
& ./tools/Test-MultiBackend.ps1 -Agent Both -Mode Soak -DurationSeconds 300 -SampleSeconds 30 -CppAgent $cpp -OutputPath target/soak.json
python tools/check-readonly-contract.py --cpp $cpp target/desktop-agent.jar
```
