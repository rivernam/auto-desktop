# 0단계 기술 결정

후속 비교에서 관리형 C# 워커를 선택형으로 구현했다. 아래는 최초 PowerShell 기준선을 선정했을 때의 기록이다. [비교 결과와 권고](WINDOWS-BACKENDS.md)

1단계에서는 Java 17 이상에서 Windows PowerShell 5.1 프로세스 하나를 세션 동안 유지한다. Java가 명령, 스냅샷, 참조 수명과 결과 형식을 관리하고, 프로젝트에 포함된 스크립트가 .NET Framework의 `UIAutomationClient`를 호출한다. 첫 요청의 프로세스 기동 비용은 세션 내 후속 요청에 반복되지 않는다. 외부 자동화 엔진이나 별도 JNI DLL을 배포할 필요가 없다. 이 결정은 Windows 접근성 트리를 실제로 읽는 최소 단위를 먼저 구현하기 위한 것이다.

## 원본에서 확인한 설계

**vercel-labs/agent-desktop.** CLI나 C 라이브러리가 공통 코어를 호출하고 접근성 API는 운영체제별로 분리한다. Rust의 Windows 및 Linux 어댑터는 관찰, 동작, 입력 인터페이스를 각각 구현한다. 스냅샷은 요소 참조를 발급하고, 호출자는 동작 후 새 스냅샷으로 결과를 확인한다. 화면이 바뀌어 참조가 낡거나 창 후보가 여럿이면 호출자가 다시 대상을 고른다. 이 프로젝트에서는 관찰과 동작을 분리하는 방식, 참조의 유효 범위, 구조화된 결과를 설계에 반영한다. 원본의 참조 문자열이나 전체 CLI와의 호환성은 제공 범위 밖이다. [README](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/README.md) · [Windows 어댑터](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/windows/src/adapter.rs) · [Linux 어댑터](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/crates/linux/src/adapter.rs)

**mmarquee/ui-automation.** Java에서 JNA의 COM 포인터와 `QueryInterface`를 이용해 Windows의 `IUIAutomation`과 루트 요소를 얻는다. 조사한 POM의 프로젝트 버전은 0.7.0이고 `jna`와 `jna-platform`은 5.6.0이다. Java 객체에서 UIA 요소를 탐색하는 실제 구현을 확인할 수 있다. Windows 전용 라이브러리이며 POM에 적힌 버전만으로 현재 JDK 및 대상 앱에서의 동작을 판단할 수 없다. [구현](https://github.com/mmarquee/ui-automation/blob/7f173ef93b391f663c3dd3597475832970786f8d/src/main/java/mmarquee/automation/UIAutomation.java) · [POM](https://github.com/mmarquee/ui-automation/blob/7f173ef93b391f663c3dd3597475832970786f8d/pom.xml)

두 저장소의 해당 리비전은 모두 Apache License 2.0이다. 1단계 배포물은 두 프로젝트를 실행하거나 링크하지 않는다. 이후 소스나 바이너리를 재배포한다면 라이선스 사본, 관련 고지 보존, 수정 파일 표시 등 제4조의 조건을 해당 배포물에 적용해야 한다. [agent-desktop 라이선스](https://github.com/vercel-labs/agent-desktop/blob/e8934a5e95e1d212c74ead95cd3e4701c04eca31/LICENSE) · [ui-automation 라이선스](https://github.com/mmarquee/ui-automation/blob/7f173ef93b391f663c3dd3597475832970786f8d/LICENCE.txt)

## 판단 기준과 적용 순서

| 순위 | 기준 | 선택에 미친 영향 |
|---|---|---|
| 1 | Windows XP·CentOS 5 호환 가능성 | Java 17과 PowerShell 5.1을 공통 전제하면 두 환경을 포괄할 수 없다. 현행 호스트용 코어와 향후 구형 OS용 어댑터의 경계를 먼저 정한다. 두 구형 OS 지원이 출하 조건이라면 1단계 결과만으로는 출하할 수 없다. |
| 2 | 장시간 실행 안정성 | 요청마다 새 프로세스를 만드는 비용을 피한다. 접근성 객체 수명과 세션 종료 시 정리를 관리하고, 장시간 반복 시험에서 핸들·메모리 증가를 확인해야 한다. |
| 3 | 유지보수·디버깅 | PowerShell에서 UIA 로드를 독립적으로 점검할 수 있고 C/C++ 디버거 없이 Java와 OS 측 오류를 구분할 수 있다. |
| 4 | API 범위 | 관리형 UIA의 요소, 속성, 패턴을 먼저 쓴다. 관리형 API가 제공하지 않는 최신 네이티브 패턴은 직접 바인딩 검토 사유다. |
| 5 | 장애 격리·복구 | UIA를 별도 프로세스에 둔다. 헬퍼가 중단되면 세션 참조를 폐기하고 새 스냅샷에서 시작해야 한다. |
| 6 | 의존성 유지보수·라이선스 | 참고 프로젝트를 의존 목록에 넣지 않고 호스트에 설치된 Windows 구성 요소를 이용한다. |
| 7 | 배포·업데이트 | JAR와 프로젝트 스크립트로 배포할 수 있다. 실제 배포 대상에서는 조직의 PowerShell 정책과 설치한 Java 배포판을 확인한다. |
| 8 | 자원 사용량 | 상주 프로세스 메모리와 직렬화 비용을 지불한다. 제한된 트리 순회로 부하를 줄이고 대상 환경에서 측정한다. |

## Windows 구현 경로 비교

| 경로 | 얻을 수 있는 기능 | 설치 및 유지보수 비용 | 1단계 판단 |
|---|---|---|---|
| 직접 JNA 바인딩 | JVM에서 UIA COM을 호출하고 속성 캐시와 패턴을 직접 선택한다. | JNA 네이티브 디스패처가 필요하다. COM 스레드 초기화, vtable 매핑, HRESULT, 참조 해제와 아키텍처별 검증을 맡는다. | 측정 결과 IPC 비용이 병목일 때 재검토 |
| 직접 JNI 바인딩 | C/C++에서 탐색과 패턴 호출을 묶어 한 번에 JVM으로 전달할 수 있다. | Windows SDK, C++ 컴파일러, 아키텍처별 DLL과 JNI 경계의 메모리 관리가 필요하다. 네이티브 오류가 JVM 전체에 영향을 줄 수 있다. | ARM64·x64 패키징 및 테스트 비용을 감당할 후속 단계 후보 |
| 기존 Java 라이브러리 | mmarquee의 컨트롤 래퍼로 UIA 탐색을 빨리 시작한다. | JNA 버전과 래퍼에 구현된 패턴에 의존한다. 기존 앱에서 오래된 의존성 교체를 별도로 검증해야 한다. | 코드 참고용 |
| 기존 외부 실행 파일 | agent-desktop의 완성된 CLI나 C 라이브러리로 여러 OS를 다룬다. | 운영체제와 CPU에 맞는 엔진을 배포하고 해당 릴리스의 참조·에러·최소 OS 계약에 종속된다. | 독립 구현 목적에 부적합 |
| 자체 컴파일한 C#/C++ 헬퍼 | 네이티브 객체를 별도 프로세스에 보관하고 장애를 격리할 수 있다. | 헬퍼 빌드, 런타임 선택, 바이너리 패키징이 추가된다. | 스크립트 배포가 어려운 환경의 후보 |
| **Windows PowerShell 5.1 + .NET UIA** | 설치된 관리형 UIA로 요소의 속성, 자식, 지원하는 컨트롤 패턴을 확인한다. | 시작 및 IPC 비용이 있고 PowerShell 정책과 .NET 어셈블리 가용성에 의존한다. | **채택. 세션당 한 번 시작하고 한 요청에서 트리를 순회한다.** |
| AWT Robot만 사용 | 키보드·마우스 이벤트와 픽셀 캡처를 제공한다. | 포커스, 데스크톱 권한 및 좌표에 영향을 받는다. 요소의 이름·역할·패턴을 읽을 API가 없다. | 접근성 백엔드 대체 불가 |

JNA는 Java에서 네이티브 라이브러리를 호출하는 브리지이고 JNI는 JVM의 표준 네이티브 인터페이스다. Microsoft의 관리형 UIA 클라이언트는 `UIAutomationClient`와 `UIAutomationTypes`에 있는 `System.Windows.Automation` 형식을 사용한다. 따라서 OS에 설치된 프레임워크로 UI 요소에 접근하면서 프로젝트의 Java 경계를 유지할 수 있다. [JNA](https://github.com/java-native-access/jna) · [JNI 명세](https://docs.oracle.com/en/java/javase/17/docs/specs/jni/intro.html) · [Microsoft UIA 개요](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/ui-automation-overview) · [AWT Robot](https://docs.oracle.com/en/java/javase/17/docs/api/java.desktop/java/awt/Robot.html)

## 결정의 한계와 재검토 조건

UIA 제공자가 노출하는 트리와 패턴이 실제 제어 범위를 정한다. 사용자 지정 그리기 영역이나 가상화된 목록은 보이는 모든 항목을 요소로 제공하지 않을 수 있다. 동일 로그인 세션에서 특정 앱과 컨트롤에 대해 관찰 및 동작을 확인해야 한다. 공급자가 응답을 멈추면 해당 요청의 완료 여부가 불명확할 수 있으므로 변경 동작을 자동으로 다시 실행하면 안 된다. 성능 비교는 아직 실측하지 않았다. 재검토 시 동일한 창과 트리 제한에서 첫 스냅샷 시간, 후속 스냅샷 지연, 노드 수와 메모리를 함께 기록한다. [Microsoft UIA 테스트 모델](https://learn.microsoft.com/en-us/dotnet/framework/ui-automation/using-ui-automation-for-automated-testing)
