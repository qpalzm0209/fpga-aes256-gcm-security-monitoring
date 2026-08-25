# Tamper Engine

Jetson의 TX ingress에 XDP/eBPF program을 연결해 선택된 AES-GCM packet의 ciphertext bit를 변경한다.

## 동작

- 대상: UDP 5602 PCAM packet
- 선택률: 5, 10, 20, 40, 60%
- 선택 조건: `frame_id % 100 < rate`
- packet 위치: 선택된 frame의 packet index 0
- 변조 위치: 첫 번째 16-bit ciphertext word의 한 bit
- 유지 필드: AAD, GCM TAG, packet length, 선택되지 않은 packet
- UDP checksum: 변조값에 맞춰 incremental update

XDP map은 `/sys/fs/bpf/zybo_tamper`에 pin된다. system service가 부팅 후 program과 map을 준비하며 공격 상태는 OFF로 시작한다. Dashboard backend는 `tamperctl`로 상태를 조회하고 공격을 시작·정지한다.

## 명령

```bash
./tamperctl status
./tamperctl start 20
./tamperctl stop
```

## 설치

```bash
sudo ./install_tamper.sh
sudo systemctl enable --now zybo-tamper-engine.service
```

## 파일

- `tamper_kern.c`, `tamper_kern.o`: XDP program
- `tamperctl.c`, `tamperctl`: runtime control
- `tamper_shared.h`: packet·map 공통 정의
- `install_tamper.sh`: program과 map 설치
- `ensure-tamper-ready.sh`: 부팅 시 준비 상태 확인
- `rollback_tamper.sh`: XDP program과 pin map 해제
