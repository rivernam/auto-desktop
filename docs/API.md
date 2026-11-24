# 로컬 Desktop Automation API

동일 CLI 프로세스의 표준 입력과 표준 출력으로 UTF-8 JSON 객체를 한 줄씩 교환한다. 한 줄의 최대 크기는 65,536바이트이며, 응답은 요청 순서대로 온다. 표준 오류는 감사 로그용이다. 입력 스트림을 닫으면 세션이 종료된다. 요청의 `id`는 비어 있지 않은 문자열(최대 128자)이다.

## 명령

| op | 요청 필드 | 성공 시 result |
|---|---|---|
| getCapabilities | 없음 | `backend`, `available`, `operations`, `physicalInput`, `screenshot`. 사용할 수 없으면 `reason` 포함. JAB 백엔드는 `bridge.javaWindows`(보이는 Java 최상위 창 수)와 `bridge.connectedWindows`(브리지에 연결된 창 수)를 더한다. |
| listWindows | 없음 | 창 배열. 각 행에 불투명 문자열 `windowId`, `processId`, `name`을 제공한다. 현재 Windows 구현은 Control View 직계 자식 중 HWND와 PID가 있는 창을 조회하고 HWND를 10진 문자열로 표현한다. Java/JNA와 C++ UIA는 그 뒤에 소유 창(모달 대화상자, 팝업)을 덧붙이고 해당 행에만 소유자의 `ownerWindowId`를 넣는다. JAB 백엔드는 브리지에 연결된 JVM의 Java 창만 나열하며 `windowId`는 같은 HWND 문자열이다. |
| snapshot | `windowId`, 선택적 `scopeRef`, `maxDepth`(기본 12, 0~32), `maxElements`(기본 500, 1~2000) | `snapshotId`, `windowId`, `elements`, `truncated`. `scopeRef`가 있으면 해당 요소부터 새로 조회하고 그 요소가 깊이 0이다. Java/JNA와 C++ UIA에서 지원한다. |
| findElement | `snapshotId`, `locator`, 선택적 `scopeRef` | 일치하는 단일 요소. `name`, `role`, `automationId`, `className` 중 한 개 이상을 대소문자 구분 완전 일치로 AND 검색한다. `scopeRef`가 있으면 해당 요소와 그 하위 요소만 검색한다. |
| getElementInfo | `ref` | 현재 UIA 속성과 패턴을 다시 읽은 요소 |
| invoke | `ref` | `{"performed":true,"effectVerified":false}`. UIA InvokePattern 또는 JAB 접근성 액션의 호출 반환. 앱의 반응은 확인하지 않는다. |
| setValue | `ref`, `value` | `{"performed":true,"effectVerified":false}`. 쓰기 가능한 ValuePattern 또는 JAB `setTextContents`의 호출 반환. 빈 문자열도 허용하며 Java 문자열 기준 최대 길이는 UIA 16,384, JAB 1,023 |

백엔드는 CLI를 시작할 때 하나로 정한다. Java Agent는 `--backend jna|jab|powershell`, C++ Agent는 `--backend uia|jab`를 받고, 생략하면 기존 기본값이다. 한 세션의 요청은 모두 그 백엔드로만 처리한다. 백엔드가 실패해도 다른 백엔드로 같은 요청을 보내지 않는다. Swing과 AWT 창은 `--backend jab`으로 연다. [JAB 백엔드의 선택, 요소 모델과 제약](JAVA-ACCESS-BRIDGE.md)

기본 선택에서 현재 OS용 어댑터가 없으면 `getCapabilities`는 `available=false`, `backend="none"`, 빈 `operations`를 반환한다. 공개 ref와 windowId는 그대로 다음 요청에 전달한다. OS 핸들이나 원본 Vercel ref로 해석할 필요가 없다.

## 같은 세션에서 탐색하고 실행하기

아래는 형식을 보여 주는 예제다. `65572`, `SNAPSHOT`, `BUTTON`, `EDIT`는 각 단계 응답에서 받은 값으로 바꾼다. 변경이 필요한 경우 CLI 시작 시 대상의 실제 PID 및 허용할 액션을 지정한다. WPF 통합 테스트의 버튼 AutomationId는 `fixtureIncrement`다.

```jsonl
{"id":"1","op":"listWindows"}
{"id":"2","op":"snapshot","windowId":"65572","maxDepth":12,"maxElements":500}
{"id":"3","op":"findElement","snapshotId":"SNAPSHOT","locator":{"automationId":"fixtureIncrement","role":"Button"}}
{"id":"4","op":"getElementInfo","ref":"BUTTON"}
{"id":"5","op":"invoke","ref":"BUTTON"}
{"id":"6","op":"findElement","snapshotId":"SNAPSHOT","locator":{"automationId":"fixtureEdit"}}
{"id":"7","op":"setValue","ref":"EDIT","value":"시험값"}
```

예를 들어 루트 하나만 조회하면 다음 형식의 결과를 받는다. 아래 식별자와 속성값은 예시다. `parentRef`가 같은 행이 해당 부모의 자식이다. 좌표를 제공하지 않는 요소의 `bounds`는 null이다.

```json
{
  "id": "2",
  "ok": true,
  "result": {
    "snapshotId": "SNAPSHOT",
    "windowId": "65572",
    "truncated": true,
    "elements": [
      {
        "ref": "ROOT", "parentRef": null,
        "name": "Test window", "role": "Window",
        "automationId": "", "className": "Window", "processId": 1234,
        "bounds": {"x":100,"y":100,"width":350,"height":250},
        "enabled": true, "offscreen": false, "actions": [], "backend": "UIA"
      }
    ]
  }
}
```

## 참조, 조회 범위와 실행 조건

- 참조는 최신 스냅샷을 받은 CLI 세션에서 120초 동안 유효하다. 다음 스냅샷 요청이 백엔드로 전달되면 이전 참조는 폐기된다. CLI나 작업 프로세스를 다시 시작하면 기존 참조로 동작을 실행할 수 없다. 장기 설정에는 Locator를 저장하고 매번 현재 창을 확인해 다시 탐색한다.
- 깊이·개수 제한에 걸리거나 식별 문자열을 표시 길이(256자)로 잘라야 하면 `truncated`가 true다. 이미 캡처한 요소에서 중복을 확인하면 `AMBIGUOUS_ELEMENT`를 반환한다. 추가 일치 요소가 없음을 보장할 수 없으면 `INCOMPLETE_SNAPSHOT`을 반환한다. 이미 명시적으로 선택한 행의 `ref`로는 현재 속성을 조회하거나 허용된 패턴을 호출할 수 있다. 식별 문자열이 잘린 행은 변경 명령을 거부한다.
- Java/JNA와 C++ UIA는 공급자가 하위 요소의 Runtime ID를 정상 형식의 빈 배열로 반환하면 해당 가지를 생략하고 `truncated`를 true로 표시한다. 생략된 요소에는 참조를 발급하지 않으며, 요소 수 한도에는 시도한 방문을 포함한다.
- Java/JNA와 C++ UIA는 하위 트리가 잘린 요소에 `partial: true`를 붙인다. 깊이·개수 한도로 자식을 더 읽지 못한 요소, 식별할 수 없는 자식을 생략한 요소, 식별 문자열이 잘린 요소가 해당한다. 완전한 요소에는 이 필드가 없다. `truncated`가 true인 스냅샷에서도 `findElement.scopeRef`로 지정한 요소와 그 하위에 `partial` 요소가 하나도 없으면 그 범위의 검색 결과는 확정이다. 범위 안에 `partial` 요소가 있거나 `scopeRef`가 없으면 `INCOMPLETE_SNAPSHOT`을 반환한다. `partial`을 표시하지 않는 백엔드의 잘린 스냅샷은 어떤 범위도 확정하지 않는다.
- JAB 백엔드의 행은 `backend`가 `JAB`이고 `automationId`와 `className`이 빈 문자열이다. 브리지가 준 역할을 `nativeRole`에 그대로 싣고 `role`에는 공통 역할(대응이 없으면 `Custom`)을 넣는다. `partial` 요소에는 `partialReason`이 붙는다. `limit`은 요청의 깊이·개수 한도, `provider`는 브리지가 자식을 주지 않은 경우, `limit,provider`는 둘 다다. 두 필드는 검색 조건이 아니며 UIA 행에는 없다.
- 참조는 그것을 발급한 세션과 백엔드에서만 뜻이 있다. 다른 세션이나 다른 백엔드의 세션에 보내면 `STALE_REFERENCE`다. 같은 창의 `windowId`는 두 백엔드에서 같다.
- 소유 창의 `windowId`도 `snapshot`의 대상이 된다. 이 창은 소유자 창의 스냅샷에도 하위 Window 요소로 나타난다. 소유 창이 닫히면 그 `windowId`는 `WINDOW_NOT_FOUND`, 그 스냅샷의 참조는 `STALE_REFERENCE`가 된다. `ownerWindowId`는 Win32 소유 관계이며 모달 여부를 뜻하지 않는다.
- 큰 창에서는 `snapshot` 결과로 필요한 컨테이너의 `ref`를 지정한 뒤 같은 `windowId`와 `scopeRef`로 다시 `snapshot`을 호출한다. Java/JNA와 C++는 컨테이너부터 실제 UI 트리를 조회한다. `maxDepth`와 `maxElements`는 컨테이너를 기준으로 적용한다. 새 스냅샷의 `snapshotId`로 `findElement`를 호출하면 이 트리 안에서 일치 여부를 판단한다. 지원하지 않는 백엔드가 `SNAPSHOT_SCOPE_UNSUPPORTED`를 반환하면 기존 스냅샷은 계속 유효하다.
- UIA 공급자가 노출하는 동작은 각 행의 `actions`에 표시된다. 세션의 capability는 개별 컨트롤이나 현재 정책의 실행 허가를 뜻하지 않는다. 목록과 스냅샷은 로그인한 사용자 권한으로 조회한다. 변경은 CLI 시작 시 지정한 PID의 프로세스 시작 시각이 일치하고 해당 액션도 허용된 경우에만 전송된다.
- 워커는 창 핸들·PID·런타임 ID와 현재 요소의 창 소속을 대조한다. 변경 직전에는 식별 속성, enabled·offscreen 상태, 실제 패턴과 쓰기 가능 여부도 검사한다. 대상 앱이 자체적으로 상태를 바꿀 수 있으므로 설비의 성공 여부는 별도 신호나 상태 변화로 확인한다.
- 비밀번호 및 편집 요소의 이름과 입력값 노출을 제한한다. UIA Value는 읽지 않고 편집·비밀번호·ValuePattern 요소의 하위 트리는 생략한다. JAB 백엔드는 텍스트 내용을 읽는 함수를 쓰지 않는다. 비밀번호 역할의 이름을 가리고 하위 트리를 생략하며, 일반 텍스트 필드의 이름(앱이 붙인 라벨)은 내보낸다. 일반 라벨·창 제목에는 앱이 업무 데이터를 표시할 수 있다. 스냅샷 전체를 저장하는 경우 이 점을 고려한다.
- 변경 요청은 매번 새 `id`를 쓴다. 작업 프로세스에 보내기 직전에 ID를 기록하며, 이후 같은 세션에서 같은 ID로 다시 실행하려 하면 거부한다. 세션당 최대 4,096개이며 재시작 간 기록은 유지되지 않는다.
- `performed`는 공급자가 패턴 호출을 받아 정상 반환했다는 뜻이다. Agent는 앱의 반응을 관찰하지 않으므로 `effectVerified`는 항상 false다. 공급자가 호출을 받고도 앱이 반응하지 않는 사례가 있다(UIA에서 본 java.awt.Button의 네이티브 피어). 성공 여부는 앱의 독립적인 상태로 판정한다.
- JAB에서 Swing 버튼의 리스너가 모달 대화상자를 직접 열면 `invoke`는 약 8초 뒤 `ACTION_OUTCOME_UNKNOWN`으로 끝나고, 대화상자가 닫힐 때까지 그 JVM을 향한 요청은 `TARGET_NOT_RESPONDING`이다. 대화상자는 실제로 열려 있다. 닫히면 같은 세션을 계속 쓸 수 있다.

## 오류 처리

실패 응답 형식은 `{"id":"5","ok":false,"error":{"code":"STALE_REFERENCE","message":"..."}}`이다. 해석할 수 없는 프레임에서는 id가 null이다.

| code | 호출자의 처리 |
|---|---|
| INVALID_REQUEST, UNKNOWN_OPERATION | 요청 형식·필드·범위나 연산명 수정 |
| BACKEND_UNAVAILABLE, WINDOW_NOT_FOUND | GUI 세션 및 설치 상태 확인, 창 목록 재조회. JAB 백엔드는 `getCapabilities.reason`에 브리지 DLL을 쓰지 못한 사유를 싣는다. |
| BRIDGE_NOT_CONNECTED | JAB 백엔드. Java 창이지만 그 JVM이 브리지를 켜지 않았다. 대상 JVM의 실행 옵션이나 사용자 접근성 설정에서 브리지를 켠다. Agent는 이를 대신 바꾸지 않는다. |
| TARGET_NOT_RESPONDING | JAB 백엔드. 연결된 JVM이 브리지 요청에 답하지 않는다. 세션과 스냅샷은 유지되므로 앱이 응답할 때 같은 요청을 다시 보낸다. 직전에 `ACTION_OUTCOME_UNKNOWN`이 있었다면 그 조작이 연 모달 대화상자를 먼저 확인한다. |
| STALE_REFERENCE | 새 스냅샷에서 대상 다시 식별 |
| ELEMENT_NOT_FOUND, AMBIGUOUS_ELEMENT | 현재 창과 Locator 조건 확인 |
| INCOMPLETE_SNAPSHOT | 깊이·요소 한도를 늘리거나, `partial` 요소가 없는 범위를 `scopeRef`로 지정하거나, 지정한 컨테이너부터 새 스냅샷 수집. 공급자가 Runtime ID를 주지 않는 가지는 새로 수집해도 완전해지지 않는다. |
| SNAPSHOT_SCOPE_UNSUPPORTED | 해당 백엔드에서 창 전체 스냅샷을 사용하거나 Java/JNA 또는 C++ UIA로 실행 |
| PERMISSION_DENIED | 실행 시 지정한 대상 프로세스 및 액션 확인 |
| PATTERN_UNSUPPORTED, PRECONDITION_FAILED | 해당 요소의 패턴·읽기 전용·활성·표시 상태 확인 |
| TIMEOUT | 읽기 요청 또는 탐지 중 10초 통신 제한 초과. 세션이 폐기되므로 Agent를 다시 시작한다. |
| ACTION_OUTCOME_UNKNOWN | 변경이 이미 수행됐을 수 있으므로 앱의 독립적인 상태를 확인. 자동 재전송 금지 |
| DUPLICATE_COMMAND, SESSION_LIMIT | 변경 명령의 세션 기록 또는 한도 확인 |
| WORKER_PROTOCOL, INTERNAL_ERROR | 현재 요청의 로그와 버전 확인 |
