# Windows XP SP3 x86 창 목록 워커

`xp-window-worker.exe`는 Java 레거시 에이전트가 실행하는 Win32 콘솔 프로그램이다. 로그인한 세션의 현재 입력 데스크톱에서 보이는 최상위 창을 열거한다. 제목이 없는 창도 포함한다. 각 행의 `windowId`는 32비트 HWND를 부호 없는 10진 문자열로 표현하며, `processId`와 `name`은 관찰한 PID와 창 제목이다. 열거 중 닫힌 창은 건너뛴다. Windows는 HWND와 PID를 재사용할 수 있다.

## 빌드와 확인

Debian의 `gcc-mingw-w64-i686` 및 `binutils-mingw-w64-i686` 패키지를 설치한 빌드 머신에서 다음을 실행한다. 검사는 호스트 C 컴파일러, GNU objdump, Python 3을 사용한다.

```sh
cd legacy/windows
./build.sh
./tests/check.sh
```

출력은 `build/xp-window-worker.exe`이다. 다른 경로가 필요하면 `OUT_DIR` 환경 변수를 설정하고 결과 파일을 `./tests/check.sh <경로>`에 전달한다. 컴파일러 실행 파일은 `XP_CC`로 선택할 수 있다. 개별 빌드 옵션은 [build.sh](build.sh)에 있다.

Debian MinGW-w64 GCC 14.2와 GNU binutils 2.44로 생성한 결과물에서 i386 PE32, 콘솔 서브시스템 5.1, OS 버전 5.1 및 두 DLL의 가져오기 목록을 검사했다. `-nostdlib`와 명시적인 진입점으로 C 런타임 시작 코드를 제외했다. 정적 가져오기는 KERNEL32.dll의 파일 입출력·스레드·프로세스 종료 함수와 USER32.dll의 데스크톱·창 조회 함수 14개다. 테스트가 허용된 함수 이름을 모두 대조한다. 호스트 C 테스트는 UTF-16 제목의 이스케이프, 잘린 대리 쌍 처리, 32비트 정수 출력, 버퍼 한도를 검사한다. XP SP3 실기 또는 VM에서의 실행은 별도 확인이 필요하다.

## 내부 프로토콜

Java가 인수 없이 프로세스를 실행하고 아래 두 줄 중 하나를 UTF-8로 보낸다. 끝에는 LF 또는 CRLF를 붙인다. 워커는 응답 한 줄을 표준 출력에 쓰고 종료한다.

```json
{"op":"getCapabilities"}
{"op":"listWindows"}
```

`getCapabilities`는 윈도 스테이션의 표시 속성, 입력 데스크톱 접근 권한, 호출 스레드의 데스크톱 이름 및 실제 `EnumWindows` 완료 여부를 확인한다. 조회가 가능하면 `available:true`와 두 연산을, 불가능하면 `available:false`와 빈 연산 목록 및 이유를 돌려준다. `listWindows`는 같은 데스크톱 검사를 다시 한다. 이 검사는 해당 프로세스가 볼 수 있는 데스크톱의 접근성을 나타낸다.

제목은 UTF-16 코드 단위 256개까지 수집한다. 비ASCII 문자는 JSON 유니코드 이스케이프로 보내며, 짝이 없는 대리 문자는 U+FFFD로 바꾼다. 최대 4,096개 창 또는 4 MiB 응답 한도를 초과하면 전체 조회가 오류를 반환한다. 이 워커는 마우스·키보드 입력이나 화면 캡처를 지원하지 않는다.

Microsoft의 문서에서 API의 용도와 지원 운영체제를 확인할 수 있다. [EnumWindows](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-enumwindows) · [GetWindowTextW](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getwindowtextw) · [OpenInputDesktop](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-openinputdesktop) · [GetUserObjectInformationW](https://learn.microsoft.com/windows/win32/api/winuser/nf-winuser-getuserobjectinformationw)
