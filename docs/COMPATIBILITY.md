# 실행 환경과 호환성

1단계의 실제 데스크톱 백엔드는 Windows용이다. 운영체제 이름만으로 UI 트리 조회나 입력 성공을 보증할 수 없다. 공통 전제는 호환 JVM, 로그인 세션 및 대상 앱의 접근성 제공자다. 기본 PowerShell 경로는 Windows PowerShell과 관리형 UIA 어셈블리를 사용한다. 선택형 JNA 경로는 JVM 비트수에 맞는 jnidispatch와 Windows UIA COM 클래스가 필요하다. 아래 표의 ‘대상’은 구현이 겨냥한 환경을 뜻한다. 실제 장비에서 실행한 증거가 있는 항목만 검증 완료로 취급한다.

| 환경 | 1단계 판단 | 전제와 제한 |
|---|---|---|
| Windows 11 x64 | 우선 검증 대상 | Java 17 이상, Windows PowerShell 5.1, .NET Framework UIA, 로그인한 사용자의 대화형 데스크톱. WPF·Win32·브라우저는 각각 다른 제공자를 사용하므로 앱별 확인이 필요하다. |
| Windows 10 x64 | 조건부 검증 대상 | 에디션·빌드 및 사용 중인 Java 공급사의 지원표를 확인한다. Windows 11의 시험 결과를 그대로 적용할 수 없다. Oracle은 일반 Windows 10을 JDK 17의 과거 지원 목록에 싣고 있다. |
| Windows 7 SP1 | 1단계 지원 대상 밖 | UIA COM API가 있고 WMF 5.1을 추가 설치할 수 있는 조합도 있다. 현재 Java 17 배포판의 Windows 7 지원과 전체 조합의 동작은 확인되지 않았다. |
| Windows Server | Desktop Experience가 설치된 최신 x64 버전은 조건부 후보 | 서버용 JVM 지원과 원격 세션 내 UI 접근은 별개다. 대상 앱과 같은 사용자 세션에서 시험한다. Server Core, 서비스의 Session 0 및 연결 해제된 원격 데스크톱에서 일반 데스크톱 조작을 보장하지 않는다. |
| Windows XP SP3 / XP Embedded | 1단계 미지원 | XP 시기에도 .NET 기반 UIA와 MSAA가 있었으나 현재 Java 17 및 WMF 5.1 조합은 지원 대상이 아니다. 임베디드 이미지는 설치한 접근성·.NET 구성과 아키텍처까지 확인해야 한다. |
| 현대 Linux의 X11 | Java 코어 실행 후보. 실제 Linux 백엔드는 후속 범위 | AT-SPI2 접근성 버스, 애플리케이션의 툴킷 브리지 및 대화형 세션이 필요하다. XTest의 물리 입력은 별도 기능이다. |
| 현대 Linux의 Wayland | 실제 Linux 백엔드는 후속 범위 | 세션의 AT-SPI2 버스에서 요소를 관찰할 수 있는지 확인한다. 전역 좌표, 화면 캡처 및 합성 입력은 컴포지터·포털의 권한에 의존하므로 X11에서의 결과를 일반화할 수 없다. |
| CentOS 5 / 5.x Embedded 이미지 | 1단계 미지원 | 배포판 업데이트는 2017년에 종료됐다. 현재 JDK 인증 범위와 구형 libc·CPU ABI, 데스크톱 유무가 제약이다. GNOME 2 계열의 구형 AT-SPI/CORBA를 AT-SPI2/D-Bus로 가정할 수 없다. |

Oracle JDK 17 인증표는 해당 공급사의 배포판에 적용된다. Windows 11 x64 및 일부 서버를 명시하며 XP·CentOS 5를 포함하지 않는다. Windows 7 SP1용 WMF 5.1 설치 가능 여부는 Microsoft의 운영체제별 표에서 확인할 수 있다. 일반 XP용 Java 8조차 Oracle이 지속적인 호환성을 보증하지 않는다. [Oracle JDK 17 인증 환경](https://www.oracle.com/java/technologies/javase/products-doc-jdk17certconfig.html) · [Microsoft WMF 지원표](https://learn.microsoft.com/en-us/powershell/scripting/windows-powershell/wmf/setup/install-configure) · [Oracle의 XP 안내](https://www.java.com/en/download/help/winxp.html)

Microsoft 문서상 UIA는 XP의 .NET Framework에서 처음 제공됐고 Windows 7에서 COM API가 개편됐다. XP를 별도로 다룬다면 설치된 UIA와 MSAA를 실제 컨트롤에서 탐지하고, 가능한 역할·이름·기본 동작만 보고하는 별도 경량 헬퍼를 검토한다. 공급자가 구현하지 않은 동작에 좌표를 임의 대입하지 않는다. [UIA의 버전 차이](https://learn.microsoft.com/en-us/windows/win32/winauto/uiauto-uiautomationoverview) · [MSAA와 UIA](https://learn.microsoft.com/en-us/windows/win32/winauto/active-accessibility-and-ui-automation)

CentOS 5용 경로는 대상 이미지의 CPU, 커널, libc, 설치한 GNOME·AT-SPI 패키지와 실제 세션을 조사하는 것부터 시작한다. 구형 CORBA 백엔드를 구현한다면 대상 ABI로 만든 경량 프로세스를 현행 Java 코어와 분리하고 참조 수명·오류 계약을 공유하는 방안을 검토할 수 있다. 현재 배포물에는 조회 전용 Java 7 호스트와 진단 절차가 있다. CORBA 어댑터와 원격 연결은 후속 범위다. [CentOS 5 종료 공지](https://lists.centos.org/hyperkitty/list/announce%40lists.centos.org/thread/EOTT33WN2JKJKQRDTIAQYH7L6A3D4Q6P/) · [GNOME의 AT-SPI 전환 설명](https://github.com/GNOME/at-spi2-core/blob/main/README.md) · [접근성 버스 시작 조건](https://github.com/GNOME/at-spi2-core/blob/main/bus/README.md)

## Java GUI와 Java Access Bridge

Swing과 AWT 설비 프로그램에는 Agent의 실행 환경과 별개로 **대상 GUI JVM**의 조건이 있다. Agent를 실행하는 Java(17 이상)나 C++ 실행 파일의 버전과 대상 프로그램의 Java 버전은 서로 다른 문제다.

| 조건 | 내용 |
|---|---|
| 대상 JVM의 브리지 | 대상 JVM이 `com.sun.java.accessibility.AccessBridge`를 보조 기술로 로드해야 한다. JVM 옵션, 사용자의 `.accessibility.properties`, `jabswitch -enable` 중 하나로 켠다. Agent는 켜 주지 않는다. |
| Agent 쪽 DLL | Agent 프로세스와 같은 비트수의 `WindowsAccessBridge-64.dll` 또는 `-32.dll`. 대상 JVM과 같은 버전일 필요는 없었다(JDK 17의 DLL로 Java 23 JVM에 접근). |
| 같은 세션 | Agent와 대상 JVM이 같은 사용자의 같은 대화형 데스크톱에 있어야 한다. 브리지는 창 메시지와 공유 메모리로 통신한다. |
| 검증된 조합 | Windows 11 x64, Agent x64(Java 17 JNA, C++), 대상 JVM Oracle JDK 17.0.10 x64와 Eclipse Adoptium 23.0.2 x64 |
| 미검증 조합 | 대상 JVM Java 6·7·8·11·21, 32비트 JVM, 32비트 Agent와 `WindowsAccessBridge-32.dll`, 구형 `WindowsAccessBridge.dll` ABI, Windows 7/XP. 이 PC에 해당 런타임이 없어 실행하지 못했다. |

Java SE 7 Update 6 이전의 JRE는 브리지(Java Access Bridge 2.0.x)를 따로 설치해야 했고, 그 이후에는 JRE에 들어 있다. 구형 설비에서는 설치된 JRE의 `bin`에 `JavaAccessBridge*.dll`과 `WindowsAccessBridge*.dll`이 있는지, 비트수가 무엇인지부터 확인한다. 32비트 JVM만 있는 설비에서 64비트 Agent가 접근할 수 있는지는 실제 조합으로 확인해야 한다. [Java Access Bridge Adapter의 검증 범위와 조건](JAVA-ACCESS-BRIDGE.md) · [Oracle Java Access Bridge 안내](https://docs.oracle.com/en/java/javase/17/access/java-access-bridge-overview.html)

## 검증 기록 방법

Windows 장비에서 OS 에디션·빌드, CPU, Java 배포판·버전, PowerShell 버전, 대상 앱 버전과 로그인 세션을 기록한다. 일반 권한 앱에서 창을 나열하고 한 창의 스냅샷을 얻은 뒤, 트리에 표시된 패턴으로 동작을 실행하고 새 스냅샷에서 변화를 확인한다. 이름이 같은 창, 닫힌 창, 새 스냅샷 뒤의 오래된 참조, 읽기 전용 필드는 별도로 기록한다. 장기 실행 검증에는 반복 횟수, 시작·종료 시 메모리와 핸들 수, 헬퍼 종료 후 복구 결과를 남긴다. Windows UI에 연결하지 않은 Linux 빌드나 테스트 더블의 통과로 위 항목을 대체할 수 없다.

## 추가 검증 조합

CentOS 6과 7, RHEL 파생 배포판에서는 먼저 사용자의 세션 버스·설치 패키지·툴킷 브리지를 확인한다. Ubuntu 22.04의 GNOME/Xorg와 GNOME/Wayland도 별도의 시험 항목이다. Windows x86/x64, WOW64, Linux i686/x86_64는 실제 설치 가능한 JVM·워커·대상 앱 조합을 기록해야 한다. 같은 JSON 규약을 처리하더라도 레거시 JVM에는 별도 바이트코드로 빌드한 코어 또는 별도 실행 파일이 필요하다.

XP SP3 x86 현장 이미지에서는 Windows Automation API 3.0 업데이트(KB971513)의 설치 여부와 실제 UIA COM 객체 생성을 각각 확인한다. XP Embedded는 구성요소가 빠질 수 있다. 업데이트 설치 여부, COM 생성, 대상 컨트롤의 InvokePattern 제공은 서로 다른 시험이다. 가능한 경우에만 UIA를 광고하고 MSAA의 기본 동작도 개별 컨트롤에서 조회해야 한다. [Microsoft Update Catalog](https://www.catalog.update.microsoft.com/ScopedViewInline.aspx?updateid=604d593e-b8a6-4710-a6ac-38a200bb8dab) · [Microsoft Windows Automation API 3.0](https://learn.microsoft.com/en-us/windows/win32/win7ip/platform-update-for-windows-vista-overview)

레거시 JVM 후보를 좁힐 때 XP SP3에서는 당시 사용된 Java 6/7 계열, CentOS 5에서는 정확한 마이너 버전·비트수에 맞는 런타임을 조사한다. Oracle의 JDK 7 자료에는 RHEL 5.5+ x86 항목이, Java 6 자료에는 RHEL 5.3 인증이 도입된 업데이트 번호가 있다. 이는 대상 CentOS 이미지의 인증이나 오래된 JVM의 현재 보안 지원을 뜻하지 않는다. 실제 바이너리로 시작·JSON 왕복·워커 실행·종료를 시험하고 배포 권리와 유지보수 경로를 확인한 뒤 조합을 결정한다. [Oracle JDK 7 과거 인증표](https://www.oracle.com/java/technologies/jdk-jre-7-cs-config.html) · [Oracle Java SE 6 과거 인증표](https://www.oracle.com/java/technologies/system-configurations.html)

## 레거시 빌드가 같은 Core 계약을 공유하는 방법

1. **현대 빌드.** Java 17 이상의 동일 JAR에서 플랫폼 어댑터를 선택한다. Windows UIA 워커는 네이티브 객체 수명과 OS 호출을 소유한다. MSAA·AT-SPI1·AT-SPI2·다른 연동 기술을 추가할 때도 공통 명령 파싱, Locator, 참조 수명, 실행 정책을 Java에 둔다.
2. **구형 장비의 런타임 확인.** XP SP3/Embedded와 CentOS 5의 정확한 이미지마다 CPU·JVM·기본 라이브러리·세션·접근성 API를 기록한다. 지원 가능한 JVM이 정해져야 어떤 소스와 의존성을 공유할 수 있는지 결정할 수 있다. 현재 코어에는 record, switch 식, ProcessHandle, 최신 Jackson API가 있어 컴파일 옵션만 낮춰서는 구형 JVM에서 실행할 수 없다.
3. **소스 공유와 빌드 분리.** 검증된 최저 JVM에서 쓸 수 있는 참조/Locator/정책 알고리즘과 DTO를 공통 소스로 유지하고 현대·레거시 빌드가 같은 소스를 컴파일하도록 한다. JSON 코덱, PID 시작 시각 확인, 워커 실행·시간 제한·자원 해제는 호환 런타임 경계에서 교체한다. OS·비트수별 전용 코드는 어댑터 및 배포 패키지에 둔다. 현재 두 빌드는 UTF-8 프레이밍과 조회 인터페이스를 공유한다. 레거시 JAR의 지원 범위는 capability와 창 열거다.
4. **바이너리 대신 검증할 계약.** 두 빌드에 같은 JSON 시나리오를 적용한다. 명령·응답·오류, 요소별 actions, 부모 ref, 교체 후 stale, 모호한 검색, 실행 횟수와 실제 값 변경이 일치해야 한다. ref·windowId의 실제 문자열이나 내부 키의 OS 형식은 비교하지 않는다. JVM을 구동할 수 없는 이미지는 지원 미검증으로 남긴다. [실행 구조](ARCHITECTURE.md)

이번 단계에서는 Java 7 조회 전용 PoC를 빌드했다. JDK 17과 Maven으로 `mvn -f legacy/pom.xml clean verify`를 실행한다. XP SP3 x86의 대화형 세션에서 검증할 명령은 아래와 같다. 입력 후 고유한 제목의 시험 창이 결과에 있는지 대조한다. 해당 이미지용 JVM은 별도로 준비해야 한다.

```bat
java -jar legacy\target\legacy-agent.jar --worker "%CD%\legacy\windows\build\xp-window-worker.exe"
```
```jsonl
{"id":"1","op":"getCapabilities"}
{"id":"2","op":"listWindows"}
```

Java 7 소스·표준 API 및 클래스 버전 51, Gson 포함 JAR의 Linux x64 Java 7 실행, XP용 PE의 정적 import 검사를 수행했다. XP의 JVM 설치·네이티브 로딩·창 열거와 CentOS 5의 실제 glibc·CORBA/X11 접속은 NOT TESTED다. [XP 워커](../legacy/windows/README.md) · [CentOS 진단](../legacy/linux/README.md)
