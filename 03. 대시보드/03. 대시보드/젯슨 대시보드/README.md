# Jetson Security Dashboard

Jetson Orin Nano가 Zybo TX와 RX 사이에서 수행하는 패킷 관찰과 공격 데모를 제공한다.

## 페이지

### 01 / NORMAL FLOW

Jetson의 `br-video` 양쪽 물리 포트와 UDP 5602 PCAM 패킷을 관찰한다.

- AAD 16 B, ciphertext 1440 B, TAG 16 B, 전체 1472 B
- session ID, frame ID, packet ID
- ciphertext entropy, byte distribution, serial correlation
- egress throughput 그래프와 ingress 보조값
- 관찰된 AES-GCM packet rate
- packet timestamp IAT 표준편차
- NIC drop/error 30초 증가량과 누계
- Jetson board power

패킷 parser는 트래픽을 계속 처리하고 frontend는 backend snapshot을 200 ms 주기로 읽는다.

### 02 / INTEGRITY ATTACK

- Tamper: ciphertext 비트를 변경하고 기존 TAG를 유지한다.
- Replay: 정상 암호 패킷을 캡처·저장한 뒤 live flow에 재주입한다.
- 공격 상태 API: `GET /api/attack/status`

공격 상태와 마지막 결과는 다음 공격이 준비될 때까지 유지한다.

### 03 / WEAK-KEY SEARCH

TX에 Weak Session 생성을 요청하고, 관찰한 AES-GCM packet으로 CPU 또는 CUDA key search를 실행한다. TAG 검증에 성공한 key로 recovered frame을 만들며 버튼을 눌렀을 때만 로컬 VLM 분석을 실행한다.

Prepare는 backend에서 생성한 64비트 request ID를 작업이 끝날 때까지 유지한다. TX ACK의 profile·request ID·seed bits와 실제 관찰 packet의 session ID가 모두 일치해야 `weak-ready`가 된다. timeout이나 다른 session packet이 관찰되면 같은 ID로 다시 시도한다. Reset, Secure, 준비 중 Stop은 기존 Weak 작업 종료 뒤 Secure 요청을 직렬 실행하며, Secure ACK와 같은 session packet을 확인할 때까지 `returning-secure`를 표시한다. frontend는 backend의 실제 `prepare_status`를 200 ms snapshot으로 표시하고 임의 시간 애니메이션으로 준비 단계를 꾸미지 않는다.

2026-08-20 실제 Jetson의 현재 backend·배포 UI·공격 엔진 파일을 이 폴더와 파일별 SHA-256으로 다시 대조했다. 현재 실행 파일은 일치하며, 장치에 남은 과거 backup·검증 캡처·runtime 업로드는 실행 정본에 중복 포함하지 않는다.

## 로컬 VLM

- 모델: NVIDIA Cosmos-Reason2-2B Q4_K_M GGUF
- vision projector: F16 GGUF
- runtime: CUDA llama.cpp
- VLM 앱/API: `127.0.0.1:4188`
- llama.cpp model server: `127.0.0.1:4190`
- 실행 위치: `/home/jetson/local-vlm-test`

이미지 분석은 Jetson 안에서 수행한다. UI에는 모델명, 응답 시간, 원문 결과와 구조화된 결과를 표시한다.

## 패킷 규격

| 바이트 | 필드 |
|---:|---|
| `0..3` | `PCAM` magic |
| `4..7` | session ID, big-endian |
| `8..11` | frame ID, big-endian |
| `12..13` | packet ID, big-endian |
| `14..15` | flags/version |
| `16..1455` | ciphertext 1440 B |
| `1456..1471` | GCM TAG 16 B |

## 폴더

- `backend/`: HTTP API와 Page 01·02·03 orchestration
- `dashboard/`: 배포용 정적 UI
- `dashboard-source/`: React/Vite 소스와 UI 테스트
- `stream-randomness/`: PCAM packet parser와 통계 계산
- `telemetry/`: backend 시작 시 사용하는 legacy UDP payload validator와 검증 샘플. 현재 Page 01은 이 경로가 아니라 로컬 packet capture를 사용하며 최신 RX의 PC telemetry는 UART다.
- `tamper/`: ciphertext bit 변조 엔진
- `replay/`: 정상 패킷 저장·재주입 엔진
- `bruteforce/`: Weak-Key CPU/CUDA 검색과 frame recovery
- `local-vlm-test/`: Cosmos VLM 앱, 모델, CUDA runtime
- `operator/`: 대시보드와 공격 엔진 실행 스크립트·서비스
- `tests/`: backend contract와 packet metadata 검사

## Jetson 실행

```bash
cd /home/jetson/projects/zybo-security-demo
./operator/start-dashboard.sh
```

대시보드는 `0.0.0.0:4173`에서 서비스된다. 로컬 VLM 서비스는 다음 user service로 실행한다.

```bash
systemctl --user enable --now zybo-local-vlm.service
```

Tamper 엔진은 다음 system service를 사용한다.

```bash
sudo systemctl enable --now zybo-tamper-engine.service
```

## 빌드와 검사

```bash
cd dashboard-source
npm ci
npm test
npm run build

cd ..
python3 -m unittest discover -s tests -p 'test_*.py'
```

## 2026-08-17 실제 배포본 대조

- 실제 Jetson project의 현재 backend, 배포 UI, Tamper, Replay, Weak-Key 공통 파일은 보관본과 대조했다.
- 실제 설치된 `zybo-tamper-engine.service`는 이 보관본의 service와 일치하며 enabled/active 상태다.
- 실제 Jetson에만 남아 있던 필수 `telemetry/receiver.py`, telemetry README와 두 정상 샘플을 이 보관본에 회수했다.
- `/home/jetson/local-vlm-test`의 앱, 실행 스크립트, 두 GGUF 모델은 이 보관본과 일치하며 user service가 enabled/active 상태다.
- 실제 project에 남아 있는 과거 assets, runtime, pcap, validation과 backup 파일은 현재 `dashboard/index.html`이 참조하는 배포 asset과 구분한다.
