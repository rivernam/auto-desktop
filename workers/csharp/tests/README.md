# C# 워커 오프라인 시험

다음 명령은 `workers/csharp` 디렉터리에서 실행한다.

## 배포용 EXE의 프로토콜

Python 3 스크립트가 빌드된 워커를 실행하고 표준 입력과 출력으로 여러 요청을 주고받는다. JSON 오류 및 길이 초과 요청을 거부한 뒤 다음 요청이 성공하는지, 오류 응답에 원래 입력값이 노출되는지 검사한다.

```powershell
py -3 tests/protocol_smoke.py bin/Release/UiaWorker.exe
```

Linux에서 Mono와 System.Web.Extensions가 설치되어 있으면 같은 EXE로 UIA 미가용 응답도 확인할 수 있다.

```sh
python3 tests/protocol_smoke.py --expect-unavailable mono bin/Release/UiaWorker.exe
```

## 모의 트리에서 워커 로직 시험

테스트용 실행 파일은 제품과 같은 UiaWorker.cs, 메모리상의 요소 트리, 테스트 진입점을 함께 컴파일한다. 창 열거·트리 제한·입력값 마스킹·부모 참조, Invoke 및 Value 호출의 효과, 지원하지 않는 액션과 오래된 참조 거부를 확인한다. 제품 EXE에는 테스트 타입을 포함하지 않는다. Mono의 mcs, System.Web.Extensions 및 WindowsBase가 필요하다.

```sh
mcs -langversion:5 -main:ProviderChecks -r:System.Web.Extensions -r:WindowsBase \
  -out:/tmp/ProviderChecks.exe UiaWorker.cs tests/SimulatedUia.cs tests/ProviderChecks.cs
mono /tmp/ProviderChecks.exe
```

실제 앱의 값과 커서 좌표는 Windows에서 전용 WPF 통합 테스트로 확인한다. [Windows 실행 방법](../../../README.md)
