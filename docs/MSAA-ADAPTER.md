# Microsoft Active Accessibility Adapter

Java/JNA와 C++ Agent가 각각 `oleacc.dll`을 호출한다. 단독 모드는 `--backend msaa`, 통합 모드는 `--backend multi`다. 통합 세션의 기본 Snapshot은 UIA이고 `backend: "MSAA"`로 MSAA 트리를 요청한다. 구현은 Windows 전용이며 두 Agent는 독립적으로 빌드하고 실행한다.

## 탐색과 속성

- 입력 데스크톱을 확인하고 Win32의 보이는 최상위 창을 나열한다. 같은 HWND/PID의 창은 다른 백엔드와 목록에서 합쳐진다. 목록에 표시된 창도 접근성 트리를 제공하지 않을 수 있다. 소유 팝업은 자신의 창 ID로 읽는다.
- 창의 `OBJID_CLIENT`로 시작해 `AccessibleChildren`의 `VT_DISPATCH`와 `VT_I4`를 처리한다. 정수 ID는 먼저 `get_accChild`로 완전한 객체인지를 확인한다. 실제 단순 요소는 조회 때만 부모의 `IAccessible`과 양의 Child ID를 함께 사용한다. 완전한 객체는 자신의 `IAccessible`과 `CHILDID_SELF`를 사용한다. 넓은 분기는 페이지 단위로 번갈아 읽으며 읽을 수 없거나 한도에서 잘린 분기를 표시한다. [Microsoft의 Child ID 계약](https://learn.microsoft.com/en-us/windows/win32/winauto/how-child-ids-are-used-in-parameters)
- 행은 공통 `name`, `role`, `className`, `enabled`, `offscreen`, `bounds`를 제공한다. `className`은 요소가 보고한 HWND의 Win32 클래스이며, 자체 HWND가 확인되지 않으면 가장 가까운 조상의 클래스를 쓴다. `automationId`는 빈 문자열이다. `nativeRole`은 MSAA 숫자 역할의 10진 문자열 또는 `unknown`이고, Row와 Cell에는 각자 공통 역할을 제공한다. 상태를 읽었으면 `selected`도 제공한다.
- Value와 Description은 읽지 않는다. 편집·보호 상태 및 역할이나 상태를 확인할 수 없는 노드의 이름과 하위 노드는 생략한다. 일반 라벨과 창 제목은 Provider가 제공한 메타데이터이며 업무 데이터가 포함될 수 있다.
- `findElement`는 보관된 Snapshot에서 검색한다. WinForms 전체 트리에는 반복되는 시스템 창 장식과 큰 그리드가 있다. 응답의 `partial`을 보고 필요한 List, Tab 또는 Table을 찾아 그 참조로 범위를 좁혀 다시 수집한다. Snapshot이 교체되면 같은 백엔드의 이전 ref는 만료된다. 일부 Win32 프록시는 이전 페이지에서 반환한 순번으로 바로 이동할 때 빈 결과를 냈다. 라이브 검증은 처음 사용한 페이지를 다시 가져오고 그 안의 위치를 확인한다.

## 참조 수명과 변경 권한

| 항목 | 정책 |
|---|---|
| `referenceStrength: "weak"` | 기본값. 조회 전용이다. `actions: []`를 반환한다. 라이브 조회와 범위 Snapshot은 최상위 HWND/PID/프로세스 시작 시각, 조상 경로, 형제 수, 위치, Child ID, 객체 유형, 역할·이름·클래스를 대조한다. 매칭 실패는 `STALE_REFERENCE`다. 같은 위치에 관찰 속성이 모두 같은 요소가 들어오면 라이브 조회에서 구분할 수 없다. |
| `referenceStrength: "strong"` | `--allow-pid PID`에 더해 `--trust-msaa-identity PID`로 지정한 Provider에만 적용한다. 대상은 자기 HWND의 `OBJID_CLIENT`로도 열리는 완전한 객체여야 한다. 대상 창과 같은 프로세스, 대상 창 또는 하위 HWND, 읽을 수 있는 상태·역할, 그리고 새로 열린 객체와 일치하는 비어 있지 않은 `IAccIdentity(CHILDID_SELF)` 값이 필요하다. 시스템이 HWND/HMENU 기반으로 분해하는 ID도 제외한다. Provider가 자체 HWND 대신 상위 HWND를 보고하면 최대 256개 하위 창에서 같은 ID를 가진 `OBJID_CLIENT` 하나를 확인한다. 실행 전에 원래 경로와 HWND를 새로 조회하고 보관한 객체의 ID·역할·상태를 다시 검사한다. |
| 신뢰 옵션의 전제 | Provider가 요소 인스턴스마다 값을 부여하고, 교체된 요소에 기존 값을 재사용하지 않으며, 폐기된 객체로 온 호출을 거부한다는 보장이 있어야 한다. 조회 결과와 설정만으로 Provider 내부 보장을 증명할 수는 없다. 위치 기반 참조에 변경 권한을 부여하는 옵션은 없다. |
| 실행 | `--allow-action`의 별도 허용과 활성 상태가 필요하다. 변경은 원래 보관한 객체에 `CHILDID_SELF`로 한 번만 전달한다. 기한 이후에는 호출하지 않는다. 네이티브 호출 이후 `S_OK` 외의 반환이나 대기 기한 초과는 `ACTION_OUTCOME_UNKNOWN`이다. 앱 효과는 별도 상태로 확인한다. |

기본 동작 `defaultAction`은 `accDoDefaultAction`을 호출한다. 메뉴 열기, 상태 전환 등 Provider가 정한 의미를 가지며 MSAA에는 `invoke`를 광고하지 않는다. `select`는 선택 가능한 요소에 `accSelect(SELFLAG_TAKESELECTION)`을 호출한다. 포커스 요청과 다중 선택 추가·범위 선택은 제공하지 않는다. `setValue`는 보호되지 않은 쓰기 가능 Edit 후보에 `put_accValue`로 UTF-16 값을 전달한다. 상태가 쓰기 가능으로 보여도 Provider가 메서드를 구현하지 않은 경우 호출 결과는 미상이다. 다섯 가지 공통 조회와 세 가지 MSAA 변경 명령은 기존 직렬 NDJSON, PID·액션 정책 및 세션당 4,096개 명령 ID 계약을 사용한다. 다른 백엔드로 자동 전달하는 경로와 자동 재시도는 없다. [Microsoft의 선택 플래그](https://learn.microsoft.com/en-us/windows/win32/winauto/selflag) · [공통 API](API.md)

수명 규약을 확인한 테스트 Provider의 예시다. `1234`에는 실행 중인 실제 테스트 프로세스 PID를 넣는다.

```powershell
java -jar target/desktop-agent.jar --backend msaa --allow-pid 1234 --trust-msaa-identity 1234 --allow-action defaultAction
./target/cpp-agent/Release/cpp-agent.exe --backend msaa --allow-pid 1234 --trust-msaa-identity 1234 --allow-action defaultAction
```

Client COM 포인터는 같은 Provider 인스턴스가 `WM_GETOBJECT`에 응답해도 서로 다른 래퍼를 가리킬 수 있었다. 실제 테스트 Provider에서 `IAccIdentity` 조회와 바이트 반환은 성공했고 두 재조회 포인터의 `IUnknown` 비교는 달랐다. 일반 COM의 `IUnknown` 규칙은 한 COM 객체에 적용되며 MSAA UI 요소 전체의 수명 규약을 대신하지 않는다. `IAccIdentity` 값은 통째로 비교하고 HWND/HMENU인지 확인할 때만 시스템 분류 API를 사용한다. [WM_GETOBJECT](https://learn.microsoft.com/en-us/windows/win32/winauto/wm-getobject) · [COM 객체 동일성](https://learn.microsoft.com/en-us/windows/win32/com/rules-for-implementing-queryinterface) · [IAccIdentity](https://learn.microsoft.com/en-us/windows/win32/api/oleacc/nf-oleacc-iaccidentity-getidentitystring)

### 소유권과 격리

각 MSAA 세션은 기존 백엔드 워커의 전용 MTA 스레드와 10초 기한을 사용한다. `IAccessible`, VARIANT, BSTR 및 COM 할당 ID를 반환한 API의 소유권 규칙에 따라 해제한다. 약한 항목은 저장소에 COM 객체를 남기지 않는다. 강한 객체와 조상은 마지막 Snapshot 동안만 보관하며 교체·만료·종료 때 풀린다. 기한을 넘긴 세션은 폐기하고, 네이티브 호출이 반환해 정리가 끝나면 Multi-Backend에서 새 세션을 열 수 있다. 새 세션에서는 이전 ref가 유효하지 않다. 영구 정지나 네이티브 프로세스 충돌은 이 구조의 한계다. [Multi-Backend 안정화](MULTI-BACKEND-STABILIZATION.md)

## 검증 범위와 기존 제한

- WinForms ListBox 항목, TabItem, DataGridView 행·셀은 MSAA로 조회한다. Fixture의 약한 참조는 쓰기가 차단된다. ListBox 아이템 교체·이동·삭제 뒤 라이브 조회는 거부되며 조작은 Fixture의 선택 상태를 바꾸지 않아야 한다.
- Win32 공용 컨트롤 Fixture의 ListBox와 탭은 약한 참조로 재조회하며, 선택이나 기본 동작이 앱 상태를 바꾸지 않는지 대조한다.
- 별도 Win32 COM Provider Fixture에서 범위 Snapshot으로 얻은 자식 HWND의 기본 동작, 선택, 유니코드 값 쓰기를 실제 앱 상태 파일로 검증한다. 교체된 객체가 같은 HWND·속성·ID를 제공해도 원본 객체가 ID를 철회하면 이전 ref의 조회와 변경을 거부한다. 사전 검사 중 비활성화, 이름 조회 중 보호 상태 전환, 상태를 변경한 뒤 실패 HRESULT를 내는 사례도 포함한다.
- 기존 WinForms Provider에서 선택이 반환되어도 이벤트가 발생하지 않았던 관측, AWT 버튼의 UIA/MSAA 기본 동작 무효, Swing 모달이 다른 JVM의 JAB 요청까지 지연하는 제약, 안정화 A-1~A-3의 미확정 증상은 기존 판정을 유지한다. [기존 WinForms MSAA Probe](JAVA-ACCESS-BRIDGE.md#msaa-adapter-검토) · [UIA 결함 기록](UIA-AGENT-DEFECTS.md) · [미확정 재현 기록](MULTI-BACKEND-STABILIZATION.md)
- MSAA ABI는 x86의 stdcall과 포인터 크기에 맞춰 사용한다. Windows XP API 일부의 존재는 현재 Java 11/JNA 또는 MSVC 바이너리의 XP 동작을 의미하지 않는다. XP와 XP Embedded는 별도 PE 임포트·런타임 조사와 실기기 검증이 필요하다.

### 실측 결과

| 검사 | 결과 |
|---|---|
| MSAA 실기기 기능 | Windows 11 빌드 26200에서 Java x64, C++ x64, C++ x86(WOW64) 각각 6/6, 합계 18/18. 세 구현의 범위 지정 DataGridView Snapshot에 Row 127개, Cell 126개가 있었다. ListBox 항목 교체·재정렬·삭제를 감지했고 약한 ref 요청은 앱 상태에 영향을 주지 않았다. [기능 원본](test-results/2026-11-25-msaa-functional.json) |
| Win32 x86 대상 | 별도로 빌드한 32비트 Win32 Fixture를 세 Agent에서 실행해 ListBox 항목·탭 재조회 및 변경 차단 확인, 3/3. [원본](test-results/2026-11-25-msaa-win32-x86-fixture.json) |
| 실제 COM 응답 지연 주입 | 세 구현에서 약 10초에 `TIMEOUT`. 독립 UIA 창의 기존 ref는 동작했다. 호출 반환과 정리 후 MSAA가 복구됐고 기존 ref는 `STALE_REFERENCE`였다. 새 ref의 기본 동작은 앱 카운터로 검증했다. [기능 원본](test-results/2026-11-25-msaa-functional.json) |
| Java 및 C++ 코어 | Maven 107개 통과, 선택 GUI 테스트 4개 미실행. CTest x64와 x86 각각 1/1. 공통 비가용 NDJSON 계약은 Java 및 C++의 두 빌드에서 각각 9개 검사 통과. |
| UIA·JAB GUI 회귀 | UIA는 214 PASS, 32 기존 Provider/JAB 분류, 10 미실행. JAB는 120 PASS, 4 기존 Provider 실패, 4 미실행. 두 결과에서 이전 안정화 보고서와 검사 이름·판정·분류가 모두 일치했다. 네이티브 MFC와 Delphi Fixture는 빌드 출력이 없어 실행하지 않았다. 두 전체 회귀는 최종 Win32 MSAA 재열거 조정 전 빌드로 수행했다. [UIA 원본](test-results/2026-11-24-msaa-uia-regression.json) · [JAB 원본](test-results/2026-11-24-msaa-jab-regression.json) |
| Multi-Backend 회귀 | 6개 시나리오 × 2개 Agent에서 실행한 82개 검사 통과. 최종 빌드에서 AwtMixed·Safety 38개도 통과했다. 최초 실행 도구의 미지원 백엔드 예시가 실제로 추가된 `MSAA`를 사용해 Safety 두 건이 실패했고, 미등록 이름으로 수정했다. [전체 원본](test-results/2026-11-24-msaa-multi-regression.json) · [최종 빌드 재확인](test-results/2026-11-25-msaa-multi-smoke-regression.json) · [초기 실패 원본](test-results/2026-11-24-msaa-multi-harness-attempt-regression.json) |

초기 실기기 시도에서 표준 Win32 프록시의 순번 재조회가 실패했고, 테스트 Provider의 자식 객체는 상위 HWND로 보고되었다. 동일 페이지 재조회와 신뢰 PID의 제한된 HWND 탐색을 적용한 뒤 최종 기능 원본에서 재검증했다. [초기 기능 원본](test-results/2026-11-24-msaa-functional-attempt.json)

XP/XP Embedded, Java x86 런타임, 잠금·보안 데스크톱, 실제 사업장 Provider, 1~5분 범위를 넘는 성능·자원 시험은 미실행이다.

### 60초 성능 및 자원 비교

같은 Windows 11 호스트에서 구현별로 새 프로세스를 실행했다. WinForms의 최대 500개 Snapshot 1회와 List 컨테이너의 라이브 속성 조회 1회를 한 반복으로 삼았다. 두 실행 모두 모든 요청에 응답했다.

| Agent | 측정 / 반복 | Snapshot p50 / p95 | 속성 조회 p50 / p95 | CPU, 논리 코어 1개 기준 | Private Bytes | Working Set | 핸들 |
|---|---|---|---|---|---|---|---|
| Java x64 | 60.03초 / 240 | 223.84 / 283.96 ms | 17.82 / 22.31 ms | 31.21% | 73.57 → 69.17 MiB | 84.48 → 85.53 MiB | 442 → 432 |
| C++ x64 | 60.19초 / 273 | 196.91 / 238.55 ms | 15.98 / 19.34 ms | 22.64% | 8.49 → 10.61 MiB | 17.33 → 19.39 MiB | 214 → 216 |

지원 범위와 해당 호스트의 단기 관측 결과다. C++ Private Bytes의 2.12 MiB 증가는 할당 수명 또는 장기 누수의 판단 근거로 쓰기에는 측정 범위가 좁다. [시간별 표본과 요청별 원본](test-results/2026-11-25-msaa-performance.json)

## 재현 명령

```powershell
mvn -o verify
cmake -S native/cpp-agent -B target/cpp-agent -G "Visual Studio 17 2022" -A x64
cmake --build target/cpp-agent --config Release
ctest --test-dir target/cpp-agent -C Release --output-on-failure
python tools/tests/Test-Msaa.py
python tools/tests/Test-Msaa.py --duration 60 --output target/msaa-performance.json
```

.NET Framework Fixture는 [빌드 절차](UI-FRAMEWORK-COMPATIBILITY.md)의 출력을 사용한다. 네이티브 ID Fixture는 CMake의 `BUILD_TESTING` 활성 빌드에서 만들어진다. 성능 실행은 3회 준비 Snapshot 후 구현별 프로세스 하나로 60초 측정한다. 반복마다 500개 이내의 Snapshot과 List 컨테이너의 라이브 조회를 수행하고, CPU 시간, Private Bytes, Working Set, 핸들 수를 10초마다 기록한다.
