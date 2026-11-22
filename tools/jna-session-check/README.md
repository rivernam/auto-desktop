# JNA 세션 로직 검사

JDK 17 이상과 빌드된 JAR를 사용한다. 아래 명령은 저장소 루트에서 실행한다. 테스트 클래스 경로에서만 메모리 내 COM 트리가 네이티브 바인딩을 대신한다. 세션 로직은 JAR 안의 프로덕션 바이트코드를 실행한다.

```sh
classes=$(mktemp -d)
javac --release 17 -encoding UTF-8 -cp target/desktop-agent.jar -d "$classes" tools/jna-session-check/*.java
java -cp "$classes:target/desktop-agent.jar" dev.desktop.SessionCheck
```

Windows PowerShell에서는 클래스 경로 구분자가 `;`다.

```powershell
$classes = (New-Item -ItemType Directory -Force target/jna-session-check).FullName
$sources = Get-ChildItem tools/jna-session-check -Filter '*.java' | ForEach-Object FullName
javac --release 17 -encoding UTF-8 -cp target/desktop-agent.jar -d $classes $sources
if ($LASTEXITCODE -eq 0) { java -cp "$classes;target/desktop-agent.jar" dev.desktop.SessionCheck }
```

참조 해제와 부분 실패, 하위 트리 제한, 편집 컨트롤 마스킹, 조상 변경, 늦은 변경 명령 차단과 공급자 반환 오류를 검증한다. Windows COM ABI와 실제 UIA 공급자 동작은 Windows GUI 통합 검사에서 확인한다.
