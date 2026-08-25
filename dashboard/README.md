# Dashboard

PC 수신 콘솔과 Jetson 보안 대시보드의 최신 실행본을 보관한다. 정상 흐름, 패킷 변조, 리플레이, 취약 키 검색과 로컬 VLM 분석을 한 흐름으로 관제한다.

## 폴더 구성

- `pc/`: RX HDMI 캡처 영상, RX UART 텔레메트리, Jetson 공격 상태를 표시한다.
- `jetson/`: 인라인 패킷 모니터링, 무결성 공격, Weak-Key 검색, 로컬 VLM 분석을 제공한다.

## 실행 주소

- PC 대시보드: `http://127.0.0.1:8765/`
- Jetson 대시보드: `http://<Jetson 주소>:4173/`
- Jetson 로컬 VLM API: `http://127.0.0.1:4188/`

각 하위 폴더의 `README.md`에 실행 방법과 데이터 경로를 정리했다.

## 2026-08-20 실제 Jetson 대조

- 실제 `/home/jetson/projects/zybo-security-demo`의 현재 backend, 배포 UI, Tamper/Replay/Weak-Key 실행 파일을 파일별 SHA-256으로 대조했다.
- 실제 `/home/jetson/local-vlm-test`의 앱, Cosmos-Reason2-2B 모델, vision projector와 컴파일된 runtime을 대조했다.
- 현재 실행 파일과 보관본은 일치한다. 장치에 누적된 과거 backup, `*.before-*`, 검증 캡처와 runtime 업로드는 실행 정본에 중복 포함하지 않는다.
