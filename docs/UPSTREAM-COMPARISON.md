# agent-desktop 원본과 Java 구현의 대응 관계

비교 기준은 vercel-labs/agent-desktop의 고정 커밋 `e8934a5e95e1d212c74ead95cd3e4701c04eca31`이다. Java 구현이 공유하는 설계는 **대상을 관찰해 참조를 얻고, 동작 직전에 대상을 다시 확인한 뒤, 결과를 재관찰하는 흐름**이다. 두 프로젝트의 참조 형식·유효 기간·명령·운영체제 지원은 다르다. 아래의 원본 링크는 모두 같은 커밋의 구현을 가리킨다. [원본 커밋](https://github.com/vercel-labs/agent-desktop/commit/e8934a5e95e1d212c74ead95cd3e4701c04eca31) · [Java 공개 API](API.md)

## 어디에서 OS를 호출하는가

| 원본의 실제 타입 | 원본 책임 | Java에서의 경계 |
|---|---|---|
| `PlatformAdapter` | `ObservationOps + ActionOps + InputOps + SystemOps`를 합친 Rust trait. 네 trait를 구현한 타입에 공통 구현을 제공한다. | `DesktopAdapter`가 필요한 관찰·동작·가용성만 정의한다. `DesktopAdapters`가 OS에 맞는 구현을 선택한다. |
| `ObservationOps` | 창·앱 목록, 트리 관찰, 현재 상태·값·동작 조회, 참조 재해석과 hit test를 수행한다. | 창 목록·트리·요소 정보가 해당한다. Java 스냅샷 검색은 이미 받은 데이터에 수행한다. |
| `ActionOps` | 요청한 접근성 동작 실행, 스크롤, 특정 동작의 포커스·커서 필요 여부 판단을 제공한다. | `DesktopAction`과 `ActionDispatcher`는 이 프로젝트의 내부 이름이다. 변경 요청을 정책에 따라 검사하고 어댑터에 전달한다. |
| `InputOps` | 키·마우스·드래그·클립보드 같은 입력을 담당한다. | 현재 공개 API에서 물리 입력을 제공하지 않는다. |
| `SystemOps` | 권한, 지원 surface, 세션, 스크린샷, 앱·창 제어 등의 시스템 작업을 담당한다. | 현재 가용성 보고는 이 중 일부에만 해당한다. |

원본은 명령 이름과 네이티브 호출을 1대1로 결합하지 않는다. 예를 들어 `list-windows`의 관찰과 `focus-window`의 시스템 조작은 다른 trait를 사용한다. Java의 내부 클래스 이름은 Rust 타입이나 원본 CLI 명령 이름을 지칭하지 않는다. [PlatformAdapter](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/adapter/mod.rs) · [ObservationOps](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/adapter/observation.rs) · [ActionOps](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/adapter/actions.rs) · [InputOps](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/adapter/input.rs) · [SystemOps](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/adapter/system.rs)

## 스냅샷과 참조의 수명

| 질문 | 원본 | Java |
|---|---|---|
| 스냅샷에는 무엇이 있는가? | `SnapshotResult`는 `tree`, `refmap`, `owner`, `snapshot_id`, `complete`, `nodes_observed`, `identity_unproven`을 가진다. CLI는 이 중 공개 결과를 구성한다. `AccessibilityNode`의 자식은 중첩되고 `ref_id`는 선택 사항이다. | 창 하나의 결과를 `elements` 배열로 제공한다. 각 행의 `parentRef`로 계층을 복원한다. 깊이·개수 한도 등으로 조회가 불완전하면 `truncated`를 보고한다. |
| 참조는 어디에 저장되는가? | 실제 타입 이름이 `RefStore`다. 기본 상태 디렉터리 또는 이름 있는 세션 경로 아래 `snapshots/<id>/refmap.json`과 최신 스냅샷 포인터를 둔다. 참조 형식은 `@<snapshot_id>:e<N>`이며 단독 `@eN` 입력은 거부한다. | `DesktopSnapshot`이 세션 내 최근 스냅샷 및 참조를 관리한다. 호출자는 발급된 문자열을 불투명한 값으로 사용한다. 프로세스가 끝나면 복구할 디스크 저장소가 없다. |
| 새 스냅샷을 만들면? | 완전한 스냅샷은 최신 포인터를 갱신한다. 불완전한 결과의 참조 맵은 별도로 저장한다. 이전 스냅샷도 보존될 수 있다. 저장 수가 128개를 넘으면 96개를 목표로 오래된 항목을 정리한다. | 다음 스냅샷을 백엔드로 전달할 때 기존 참조가 무효화된다. 기존 공개 계약의 유효 기간은 120초다. |
| 저장된 참조로 지금 동작할 수 있는가? | `RefEntry`는 프로세스·식별 근거·위치·능력·출처·범위를 기록한다. 보존된 실제 객체 토큰이 있으면 어댑터가 엄격히 재해석한다. 토큰이 없다면 캡처 시 유일했고 현재 해당 창의 완전한 관찰에서도 일치 대상이 하나임을 확인한다. | 최신 세션 참조와 창·프로세스·요소의 현재 식별 정보를 확인한다. 창이 닫히거나 요소가 바뀌면 새로 관찰해야 한다. |

원본의 최대 보존 개수는 저장 공간을 정리하는 조건이다. 저장된 참조가 128회 동안 조작 가능하다는 보증은 없다. 소스의 60초 상수는 남겨진 임시 파일 정리 기준이며 요소 참조 TTL을 규정하지 않는다. [SnapshotResult](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/snapshot/mod.rs) · [스냅샷 출력](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/snapshot.rs) · [AccessibilityNode](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/tree/node.rs) · [참조 발급](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/ref_alloc.rs) · [토큰 파싱](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/ref_token.rs) · [RefStore](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/refs_store.rs) · [보존 정책](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/refs_store_prune.rs) · [RefEntry](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/ref_entry.rs) · [재식별](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/resolve_saved_ref.rs)

## Locator와 capability가 각각 뜻하는 것

원본의 검색 질의 타입은 **LocatorQuery**다. `IdentityPredicate`의 role·name·description·native_id·value와 별도로 has_text, exact, states, containment를 담을 수 있다. 짧은 selector인 `button:Submit`은 역할과 검색 텍스트로 파싱된다. CLI의 `find`는 실제 앱·창·하위 트리를 관찰하며 count·first·last·nth·limit 같은 선택 옵션도 제공한다. 이미 발급한 ref의 동일성을 판정하는 저장 구조는 별도의 `RefEntryIdentity`다. Java의 `ElementLocator`는 공개 API에 전달한 name·role·automationId·className 조건을 기존 스냅샷에서 대소문자 구분 완전 일치로 조합한다. 불완전한 스냅샷이나 여러 후보는 단일 요소 검색에 실패한다. [LocatorQuery](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/locator/mod.rs) · [IdentityPredicate](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/locator/identity_predicate.rs) · [selector 파서](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/query.rs) · [find](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/find.rs) · [실시간 조회](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/find_live.rs) · [저장된 식별 정보](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/ref_entry_identity.rs)

원본에는 요소 수준의 `RefCapabilities { states, available_actions }`와 `Click`, `Toggle`, `SetValue` 같은 표준 액션 문자열이 있다. 시스템 수준에서는 `status`가 platform, version, permissions, supported_surfaces, 최신 스냅샷, 세션, 추적 상태 등을 조합한다. Java의 `getCapabilities`는 현재 백엔드의 가용성·연산·물리 입력·스크린샷 지원을 보고한다. 요소별 `actions`, 세션 정책의 실행 허가, 플랫폼 기능은 각각 확인해야 한다. [RefCapabilities](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/refs/ref_capabilities.rs) · [액션 능력표](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/actions/capability.rs) · [status 응답](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/status.rs)

## 명령 대응과 동작 결과

| Java JSONL 명령 | 원본 CLI의 가장 가까운 명령 | 호출자가 알아야 할 차이 |
|---|---|---|
| getCapabilities | status, permissions | 결과 필드와 권한 확인 범위가 다르다. |
| listWindows | list-windows | 원본은 앱 필터와 시간 제한도 받는다. |
| snapshot | snapshot | 원본의 surface, skeleton, root, interactive, compact 옵션 및 중첩 트리는 Java 계약에 없다. |
| findElement | find | Java는 기존 스냅샷에서 단일 요소를 찾고, 원본은 실시간 질의와 다양한 선택 방식을 제공한다. |
| getElementInfo | get, 일부 is | Java는 현재 요소 정보 여러 개를 묶어 반환한다. 원본 get은 text·value·title·bounds·role·states 중 한 속성을 고른다. 속성에 따라 기록된 값이나 현재 조회값을 사용한다. |
| invoke | click의 Windows Invoke 경로 | Java는 UIA InvokePattern만 호출한다. 원본 Windows Click은 Invoke와 Legacy 기본 동작을 검토하며, Linux Click은 AT-SPI 동작을 사용한다. 물리 클릭은 또 다른 입력 경로다. |
| setValue | set-value | Java는 쓰기 가능한 UIA ValuePattern만 지원한다. 원본 Windows는 ValuePattern과 RangeValuePattern을 다룬다. 키보드 입력인 type에는 별도 의미가 있다. |

원본의 Rust `Action`은 Click, SetValue, Toggle, Check, Scroll, PressKey, Drag 등을 구분한다. `ActionResult`는 수행한 단계, 후속 상태, 전달·검증 여부를 표현할 수 있다. Java 성공 응답의 `performed: true`는 패턴 호출이 반환됐다는 의미다. 설비나 앱의 최종 상태는 다음 관찰로 확인해야 한다. [Action](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/actions/action.rs) · [ActionResult](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/actions/action_result.rs) · [창 목록](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/list_windows.rs) · [속성 조회](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/get.rs) · [click 명령](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/click.rs) · [set-value 명령](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/set_value.rs)

Java에서 제공하지 않는 명령에는 요소의 toggle·check·expand·select·scroll, 키·마우스·드래그, 스크린샷·클립보드, 앱 시작·종료와 창 이동·리사이즈, 알림, wait, session, trace, batch, sandbox 등이 있다. 원본에서도 명령의 존재와 플랫폼에서의 실행 가능성은 구별한다. 예를 들어 해당 커밋의 key-down은 인자를 확인한 뒤 단독 입력 유지를 거부한다. [원본 명령 모듈](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/mod.rs) · [key-down 구현](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/core/src/commands/key_down.rs)

## Windows와 Linux의 구현 차이

- **Windows.** 원본 WindowsAdapter는 UIA 제공자가 노출한 패턴 가용성을 읽는다. Invoke·Toggle·ExpandCollapse·SelectionItem·Value 등의 가용성을 개별 판정하며, LegacyIAccessible이 있다는 사실만으로 Click을 광고하지 않는다. 비어 있지 않은 기본 동작도 확인한다. 현재 Java Windows 백엔드의 PowerShell 및 C# 워커는 관리형 UIA를 사용하고 Invoke와 쓰기 가능한 Value만 변경 동작으로 노출한다. [WindowsAdapter](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/windows/src/adapter.rs) · [가능한 동작 판정](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/windows/src/tree/actions.rs) · [동작 분기](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/windows/src/actions/dispatch.rs) · [값 쓰기](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/windows/src/actions/value_write.rs)
- **Linux.** 원본 LinuxAdapter는 공유 버스를 통해 AT-SPI 트리를 읽고, Click 구현은 대상에 노출된 동작 이름으로 Action.DoAction 경로를 선택한다. 접근성 관찰과 물리 입력은 별도다. 화면 서버에 따라 X11 또는 Wayland 경로를 선택하며 구현된 Wayland 입력 경로에는 GNOME Mutter의 RemoteDesktop 서비스가 등장한다. 임의의 Wayland 환경에서 같은 입력을 보장한다는 뜻은 아니다. 현재 Java 배포물에는 Linux 데스크톱 어댑터가 없어 Linux에서 실제 창 조회나 동작은 사용할 수 없다. [LinuxAdapter](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/linux/src/adapter.rs) · [AT-SPI 클릭](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/linux/src/actions/click.rs) · [화면 서버 경로](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/linux/src/system/display/route.rs) · [Mutter 서비스](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/linux/src/input/wayland/remote_desktop.rs)

## 이번 변경의 경계

기존에는 Agent가 워커용 JSON 프레임을 만들고, 한 클래스 안에서 스냅샷 인덱스·Locator·변경 이력을 함께 관리했다. 이제 Agent는 어댑터의 관찰·동작 메서드를 호출하고, DesktopSnapshot은 검증된 트리와 ref를, ElementLocator는 조건을, ActionDispatcher는 정책과 중복 방지를 소유한다. 기존 7개 공개 명령과 PowerShell·C#의 내부 프로토콜을 유지했다. 디스크 RefStore나 원본의 물리 입력을 이번 범위에 도입하지 않은 것은 현장 세션의 참조 수명과 명시적인 입력 정책을 유지하기 위한 결정이다. 레거시 OS에서 실행 파일을 나눠야 하는 문제는 JVM·접근성 라이브러리 호환성으로 별도 검증한다. [공통 명령 계약](../src/test/resources/contracts/desktop-v1.json) · [레거시 빌드 전략](COMPATIBILITY.md)
