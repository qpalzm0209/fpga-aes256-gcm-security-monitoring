# PC Receiver Console

RX HDMI 영상과 RX 보안 상태를 PC에서 확인하는 웹 콘솔이다.

## 화면

- `01 / LIVE RECEIVER`: HDMI 캡처 영상, 현재 공격 상태, RX 보안 상태
- `02 / SECURITY ANALYSIS`: 최근 30초 FPS·드롭·지터·거부율, 5종 디텍터, 최근 60초 이벤트 타임라인
- `GEMINI SECURITY ASSISTANT`: 현재 PC·Jetson 공격·RX 텔레메트리 기반 분석, 채팅, 한국어 마이크 입력

시작 화면은 RX UART의 OCC 판정에 잠긴다. `PASS`가 1초간 표시된 뒤 좌우 잠금 패널이 열리며, `FAIL`은 잠금을 유지한다. 개발용 Q+W+E 해제와 L+K+J 재잠금은 기존 동작을 유지한다.

## 데이터 경로

```text
RX HDMI → USB3 Capture Board → PC video element
RX 5-pin UART → PC backend → /api/state
Jetson /api/attack/status → PC backend → /api/state
```

RX UART 프레임은 `ZYBO_RX_V1`, CRC32, `source_role=zybo-rx`, `transport=uart`를 검증한다. COM 번호가 바뀌면 backend가 RX 역할 프레임을 기준으로 다시 찾는다. Jetson 공격 상태는 200 ms 주기로 읽고 연결 상태가 오래되면 오프라인으로 표시한다.

공격 설정과 마지막 결과는 다음 공격이 준비될 때까지 유지한다. RX 누적 디텍터 값은 실제 증가가 관찰된 시점에 이벤트로 기록한다.

## 실행

1. RX의 5핀 USB-UART와 HDMI 캡처보드를 PC에 연결한다.
2. `run_pc_ui.bat` 또는 `launch_pc_ui.vbs`를 실행한다.
3. 브라우저에서 캡처 장치를 선택하고 `START VIDEO`를 누른다.

기본 주소는 `http://127.0.0.1:8765/`이다. 기본 포트가 사용 중이면 실행기가 다음 빈 포트를 선택한다.

## 설정

`pc_rx_ui.env.example.cmd`를 `pc_rx_ui.env.cmd`로 복사한 뒤 장비별 값을 설정한다.

| 변수 | 기본값 | 용도 |
|---|---|---|
| `PC_RX_UI_HOST` | `127.0.0.1` | 웹 bind 주소 |
| `PC_RX_UI_PORT` | `8765` | 선호 웹 포트 |
| `JETSON_DASHBOARD_URL` | `http://100.72.159.6:4173` | Jetson API 기준 주소 |
| `PC_RX_UART_PORT` | 자동 탐색 | RX UART 포트 |
| `PC_RX_UART_BAUD` | `115200` | UART 속도 |
| `PC_RX_UART_PROBE_SECONDS` | `1.5` | 포트 식별 시간 |
| `PC_TELEMETRY_ONLINE_SECONDS` | `1.5` | UART 온라인 판정 시간 |
| `GEMINI_API_KEY` | 로컬 설정 | Gemini API 키, 소스에 저장하지 않음 |
| `GEMINI_MODEL` | `gemini-3.6-flash` | Gemini 모델 |
| `GEMINI_BASE_URL` | Google API v1beta | Gemini Interactions API 기준 주소 |
| `GEMINI_TIMEOUT_SECONDS` | `45` | Gemini 요청 제한 시간 |

마이크 버튼은 브라우저의 음성 인식을 `ko-KR`로 실행하고, 확정된 문장을 Gemini 질문으로 자동 전송한다. 브라우저 주소창의 마이크 권한을 허용해야 한다.

## 파일

- `server.py`: 웹 서버, RX UART 수신, Jetson 공격 상태 수집, Gemini API 프록시
- `web/`: PC UI 정적 파일
- `serial/`: 포함된 Python serial 모듈
- `run_pc_ui.bat`: 콘솔 실행기
- `launch_pc_ui.vbs`: 바탕화면용 무창 실행기
- `pc_rx_ui.env.example.cmd`: 환경 설정 예시

## 검사

```powershell
py -3 .\server.py --self-test
node --check .\web\app.js
```
