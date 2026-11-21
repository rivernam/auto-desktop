# CentOS 5 계열 데스크톱 접근 진단

**CentOS 5 실기기·VM 결과는 NOT TESTED다.** 이 프로브는 대상 호스트에서 Java 런타임과 ABI를 기록하고, 로그인한 사용자의 X11 및 AT-SPI 1(CORBA) 데스크톱을 각각 한 번 읽는다. 시스템 설정을 바꾸거나 마우스·키보드 입력을 보내지 않는다. Linux 자동화 워커 및 창 열거 API는 이 디렉터리의 제공 범위 밖이다.

## 대상에서 실행

프로젝트 루트에서 다음 스크립트를 실행한다. GUI 확인은 실제 로그인한 데스크톱 사용자의 셸에서 수행한다. SSH X 전달 환경에서는 전달된 화면을 관찰하게 되므로 대상 세션과 결과를 구분해야 한다.

```sh
sh legacy/linux/probe.sh
```

POSIX 셸, mktemp, cc, libc 개발 헤더와 libdl이 빌드에 필요하다. RPM, pkg-config, file, readelf가 있으면 진단 정보를 추가로 출력한다. Xlib 및 cspi는 런타임에 동적으로 로드하므로 그 개발용 헤더나 .pc 파일은 컴파일에 필요하지 않다. 컴파일러가 없는 장비에는 같은 CentOS 5 사용자 공간과 CPU ABI로 별도 빌드한 실행 파일을 지정할 수 있다.

```sh
cc -std=gnu89 -Wall -Wextra -O2 legacy/linux/desktop-probe.c -ldl -o ./desktop-probe
sh legacy/linux/probe.sh ./desktop-probe
```

| 확인 항목 | 통과 시 알 수 있는 것 | 추가 확인이 필요한 것 |
|---|---|---|
| uname, getconf, java -version | 커널·사용자 공간 비트 수·glibc 및 JVM 자체의 기동 여부 | 사용할 Java 바이트코드 버전, 실제 JAR의 로드 및 응답 |
| file, readelf | 실행 파일의 ELF 클래스·아키텍처·직접 의존성·요구 GLIBC 심볼 버전 | JNI, libjvm.so, 동적 로드한 라이브러리의 전이 의존성은 별도 확인 |
| X11 | libX11.so.6를 열고 현재 DISPLAY로 연결해 XQueryTree로 루트 자식 수를 실제 읽음 | 자식 수는 창 관리자가 보여 주는 앱 목록과 다르다. 0도 정상적인 읽기다. |
| AT-SPI 1 | libcspi.so.0의 SPI_init, SPI_getDesktopCount, SPI_getDesktop(0), Accessible_getChildCount를 호출해 레지스트리와 첫 데스크톱 응답을 확인 | 자식 0은 빈 데스크톱일 수 있다. 앱별 접근성 브리지 및 위젯 탐색·동작은 별도 시험해야 한다. |
| pkg-config, rpm | 개발 메타데이터 및 호스트 패키지명·버전의 존재 여부 | cspi-1.0이 없더라도 런타임은 있을 수 있다. atspi-2, libatspi.so.0는 다른 세대의 D-Bus API다. |

C 소스는 GNOME at-spi 1.7.12 릴리스의 cspi/spi.h에서 반환형과 인자형을 확인했다. 특히 Accessible_getChildCount의 반환형은 long이다. AT-SPI 1의 데스크톱 참조는 Accessible_unref로 해제한다. X11의 자식 배열은 XFree로 반환한다. [GNOME 원본 소스](https://download.gnome.org/sources/at-spi/1.7/at-spi-1.7.12.tar.gz) · [GNOME의 CORBA·D-Bus 전환 설명](https://github.com/GNOME/at-spi2-core/blob/main/README.md)

C 프로브의 종료 코드는 0(읽기 성공), 1(잘못된 인자), 2(라이브러리·심볼을 로드하지 못함), 3(세션 연결 또는 조회 실패), 124(10초 경과)다. 두 검사는 독립 프로세스로 동작하며 한쪽 실패 후에도 다른 쪽을 실행한다. 비정상 종료나 라이브러리 내부 종결은 해당 프로세스의 실제 종료 코드로 표시한다. 셸 스크립트는 두 조회가 모두 성공해야 0을 반환한다.

## 빌드 장비와 배포 장비가 다를 때

프로브·JVM·libX11·libcspi 각각의 ELF 클래스를 확인한다. 64비트 커널에서도 32비트 사용자 공간 또는 JVM을 쓸 수 있다. 프로브는 자신의 클래스에 맞는 라이브러리를 로드하므로 i386와 x86_64를 별도로 시험한다. 현대 장비에서 gcc -m32로 바꿔도 오래된 glibc를 대상으로 링크했다는 보장은 없다. 대상 이미지나 해당 툴체인·sysroot에서 빌드하고 readelf -V로 요구 심볼을 확인한다. Java 프로세스와 별도 프로브의 비트 수가 다르다면 각 프로세스의 결과를 따로 기록한다.

## 현대 Linux에서 실행한 결과

| 실행 환경 | 실제 결과 |
|---|---|
| Debian 사용자 공간, x86_64, glibc 2.41, GCC 14.2 | GNU89 빌드 성공. 호스트 java -version은 OpenJDK 21.0.13. 빌드한 프로브는 ELF64, GLIBC_2.34를 요구하므로 이 바이너리는 CentOS 5 호환 빌드로 배포할 수 없다. |
| 기본 셸, DISPLAY 미설정 | libX11.so.6 로드 성공 후 XOpenDisplay 실패(exit 3). libcspi.so.0 누락으로 AT-SPI 1 로드 실패(exit 2). cspi-1.0, x11 개발 메타데이터 모두 미설치. |
| 같은 호스트에 별도로 기동한 인증된 Xorg 더미 화면 | XOpenDisplay와 XQueryTree 성공. READ_OK X11 root_children=0, exit 0. 기존 로그인 세션과 분리된 빈 화면에서 관찰했다. |

대상 장비의 재현 기록에는 OS 에디션, CPU·유저랜드·JVM 비트 수, glibc 및 JVM 버전, 두 프로브의 출력·종료 코드와 실행한 로그인 세션을 남긴다. AT-SPI 1과 구형 JVM의 양성 결과는 아직 확보하지 못했다.
