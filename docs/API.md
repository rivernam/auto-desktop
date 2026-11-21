# 로컬 Desktop Automation API

동일 CLI 프로세스의 표준 입력과 표준 출력으로 UTF-8 JSON 객체를 한 줄씩 교환한다. 한 줄의 최대 크기는 65,536바이트이며, 응답은 요청 순서대로 온다. 표준 오류는 감사 로그용이다. 입력 스트림을 닫으면 세션이 종료된다. 요청의 `id`는 비어 있지 않은 문자열(최대 128자)이다.

## 명령

| op | 요청 필드 | 성공 시 result |
|---|---|---|
| getCapabilities | 없음 | `backend`, `available`, `operations`, `physicalInput`, `screenshot`. 사용할 수 없으면 `reason` 포함 |
| listWindows | 없음 | 창 배열. 각 행에 불투명 문자열 `windowId`, `processId`, `name`을 제공한다. 현재 Windows 구현은 Control View 직계 자식 중 HWND와 PID가 있는 창을 조회하고 HWND를 10진 문자열로 표현한다. |
| snapshot | `windowId`, 선택적 `maxDepth`(기본 12, 0~32)와 `maxElements`(기본 500, 1~2000) | `snapshotId`, `windowId`, `elements`, `truncated`. 깊이 0은 루트 |
| findElement | `snapshotId`, `locator` | 일치하는 단일 요소. `name`, `role`, `automationId`, `className` 중 한 개 이상을 대소문자 구분 완전 일치로 AND 검색 |
| getElementInfo | `ref` | 현재 UIA 속성과 패턴을 다시 읽은 요소 |
| invoke | `ref` | `{"performed":true}`. UIA InvokePattern 호출 반환 |
| setValue | `ref`, `value` | `{"performed":true}`. 쓰기 가능한 ValuePattern 호출 반환. 빈 문자열도 허용하며 Java 문자열 기준 최대 길이 16,384 |

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
- 깊이·개수 제한에 걸리거나 식별 문자열을 표시 길이(256자)로 잘라야 하면 `truncated`가 true다. 이 경우 `findElement`는 유일성을 보장할 수 없으므로 실패한다. 이미 명시적으로 선택한 행의 `ref`로는 현재 속성을 조회하거나 허용된 패턴을 호출할 수 있다. 단, 식별 문자열이 잘린 행의 변경 명령은 거부한다.
- UIA 공급자가 노출하는 동작은 각 행의 `actions`에 표시된다. 세션의 capability는 개별 컨트롤이나 현재 정책의 실행 허가를 뜻하지 않는다. 목록과 스냅샷은 로그인한 사용자 권한으로 조회한다. 변경은 CLI 시작 시 지정한 PID의 프로세스 시작 시각이 일치하고 해당 액션도 허용된 경우에만 전송된다.
- 워커는 창 핸들·PID·런타임 ID와 현재 요소의 창 소속을 대조한다. 변경 직전에는 식별 속성, enabled·offscreen 상태, 실제 패턴과 쓰기 가능 여부도 검사한다. 대상 앱이 자체적으로 상태를 바꿀 수 있으므로 설비의 성공 여부는 별도 신호나 상태 변화로 확인한다.
- 비밀번호 및 편집 요소의 이름과 입력값 노출을 제한한다. UIA Value는 읽지 않고 편집·비밀번호·ValuePattern 요소의 하위 트리는 생략한다. 일반 라벨·창 제목에는 앱이 업무 데이터를 표시할 수 있다. 스냅샷 전체를 저장하는 경우 이 점을 고려한다.
- 변경 요청은 매번 새 `id`를 쓴다. 작업 프로세스에 보내기 직전에 ID를 기록하며, 이후 같은 세션에서 같은 ID로 다시 실행하려 하면 거부한다. 세션당 최대 4,096개이며 재시작 간 기록은 유지되지 않는다.

## 오류 처리

실패 응답 형식은 `{"id":"5","ok":false,"error":{"code":"STALE_REFERENCE","message":"..."}}`이다. 해석할 수 없는 프레임에서는 id가 null이다.

| code | 호출자의 처리 |
|---|---|
| INVALID_REQUEST, UNKNOWN_OPERATION | 요청 형식·필드·범위나 연산명 수정 |
| BACKEND_UNAVAILABLE, WINDOW_NOT_FOUND | GUI 세션 및 설치 상태 확인, 창 목록 재조회 |
| STALE_REFERENCE | 새 스냅샷에서 대상 다시 식별 |
| ELEMENT_NOT_FOUND, AMBIGUOUS_ELEMENT | 현재 창과 Locator 조건 확인 |
| INCOMPLETE_SNAPSHOT | 한도 안에서 탐색 범위 확대, 트리와 잘림 여부 확인 |
| PERMISSION_DENIED | 실행 시 지정한 대상 프로세스 및 액션 확인 |
| PATTERN_UNSUPPORTED, PRECONDITION_FAILED | 해당 요소의 패턴·읽기 전용·활성·표시 상태 확인 |
| TIMEOUT | 읽기 요청 또는 탐지 중 10초 통신 제한 초과 |
| ACTION_OUTCOME_UNKNOWN | 변경이 이미 수행됐을 수 있으므로 앱의 독립적인 상태를 확인. 자동 재전송 금지 |
| DUPLICATE_COMMAND, SESSION_LIMIT | 변경 명령의 세션 기록 또는 한도 확인 |
| WORKER_PROTOCOL, INTERNAL_ERROR | 현재 요청의 로그와 버전 확인 |
