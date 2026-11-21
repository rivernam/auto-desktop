# JNA 세션 로직 검사

JDK 17 이상과 빌드된 JAR를 사용한다. 아래 명령은 저장소 루트에서 실행한다. 테스트 클래스 경로에서만 메모리 내 COM 트리가 네이티브 바인딩을 대신한다. 세션 로직은 JAR 안의 프로덕션 바이트코드를 실행한다.

```sh
classes=$(mktemp -d)
javac --release 17 -encoding UTF-8 -cp target/desktop-agent.jar -d "$classes" tools/jna-session-check/*.java
java -cp "$classes:target/desktop-agent.jar" dev.desktop.SessionCheck
```

이 검사는 참조 해제, 트리 탐색 제한, 편집 컨트롤 마스킹, 요소 재검증, 액션 결과와 실패 처리를 검증한다. Windows COM ABI와 실제 UIA 공급자 동작은 Windows GUI 통합 검사의 대상이다.
