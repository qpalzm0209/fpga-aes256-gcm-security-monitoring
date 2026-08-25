# ZYBO RX HDMI PC 미리보기

`run_preview.bat`을 실행하면 `USB3. 0 capture`의 1280×720 MJPG 영상을 실제 Windows 창으로 표시한다.

## 최초 설치

Python 3가 설치된 Windows PC에서 다음 중 하나를 실행한다.

```bat
setup_venv.bat
```

또는 바로 `run_preview.bat`을 실행한다. `.venv`가 없으면 실행기가 자동으로 가상환경을 만들고 `requirements.txt`의 고정 버전을 설치한다.

```text
numpy==2.2.6
opencv-python==4.12.0.88
```

`.venv`는 PC별 생성물이라 보관본에 포함하지 않는다.

## 사용

- 종료: `Q` 또는 `Esc`
- 필요할 때만 수동 원본 프레임 저장: `S`
- 실시간 수치: `live_metrics.json`

창의 `capture fps`는 HDMI 720p60 carrier 수신률이다. Zybo RX의 authenticated/display content rate 약 30fps와 혼동하지 않는다. `PIXELS CHANGING`과 `change events`는 decoded PC 프레임의 실제 픽셀 변화이며, carrier가 살아 있어도 같은 화면만 반복되면 `PIXELS STATIC`으로 표시된다.

사진 찌꺼기가 쌓이지 않도록 자동 PNG 저장은 하지 않는다. `S`를 누른 경우에만 `manual_날짜_시간.png` 한 장을 저장한다.

2026-08-09 직결 재검증 결과와 원인·복구 내역은 `VALIDATION_RESULT.md`에 기록했다.

TX/RX 직결 케이블을 Jetson 2-NIC Linux bridge 경유로 다시 꽂을 때는 `JETSON_2NIC_중간삽입_재배선_운용README.md`를 먼저 따른다. Zybo IP/MAC/UDP 계약, 케이블 순서, 현재 old image의 link-flap 주소 유실 주의, 15초/300-frame 실제 화면 gate와 Web/UI 경계를 함께 기록했다.

현재 FPGA 기준본은 상위 `01. zybo_fpga/3-3. 2차변형_ECC_데모_260812_0144_TX_PL_직결_최종본.7z`이며, 최신 PC·Jetson Dashboard 실행본은 상위 `03. 대시보드`에 있다. 과거 PC AI·CUDA 사전검증은 형제 폴더 `00. 초기 통합 및 AI 실험 계보`에서 현재 도구와 분리해 보존한다.
