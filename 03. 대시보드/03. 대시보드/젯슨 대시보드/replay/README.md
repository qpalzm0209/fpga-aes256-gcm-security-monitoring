# Replay Engine

Jetson이 정상 AES-GCM frame 한 개를 저장하고 같은 packet bytes를 RX 방향에 추가 주입한다.

## 동작

- 입력: TX ingress의 UDP 5602 PCAM packet
- 저장 단위: 1280 packet으로 구성된 완전한 frame
- 출력: RX 방향 물리 interface
- 보존 범위: Ethernet, IPv4, UDP, AAD, ciphertext, GCM TAG, packet length
- 주입률: `30 fps × rate / 100`
- rate: 5, 10, 20, 40, 60%
- 실행 권한: `cap_net_raw=ep`

Dashboard backend가 `replay_engine`을 자식 process로 시작하고 status JSON을 읽는다. 공격 정지 시 SIGTERM을 보내며 엔진은 마지막 상태를 기록하고 종료한다.

## 준비

```bash
./enable_replay.sh
```

## 실행 형식

```bash
./replay_engine \
  --rate 20 \
  --status /run/zybo-replay-status.json \
  --source /path/to/frame.pcap \
  <TX ingress>:<RX egress>
```

## 파일

- `replay_engine.c`: frame capture, 저장, pacing, packet injection
- `replay_engine`: Jetson 실행 파일
- `tamper_shared.h`: PCAM packet 공통 정의
- `enable_replay.sh`: raw socket capability 설정
