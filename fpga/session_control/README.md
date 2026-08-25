# Session Control V1 — 3-1 final

## 역할과 전송 경로

- USB Wi-Fi는 TX/RX 키 교환과 세션 관리에만 사용한다.
- 영상은 `TX 유선 LAN -> Jetson 2-NIC 커널 브리지 -> RX 유선 LAN`으로만 흐른다.
- RX 텔레메트리는 `RX 5-pin UART -> PC`로만 흐른다.
- RX 화면은 `RX HDMI -> USB 캡처보드 -> PC`로 표시한다.

키 교환 에이전트는 `/sys/class/net`에서 실제 USB 무선 장치를 찾고, DHCP로 받은 현재 주소와 넷마스크를 사용한다. AP가 브로드캐스트를 전달하지 않으면 현재 무선 서브넷을 unicast로 검색한다. RX 주소, 무선 인터페이스 이름, PC 주소, Jetson 주소 및 Tailscale 주소는 소스에 고정하지 않는다. 발견된 상대가 올바른지는 고정 주소가 아니라 pinned X25519 공개키와 인증된 capsule 교환으로 확인한다.

유선 영상 peer 파일(`/run/aes-gcm-rx-peer`, `/run/aes-gcm-tx-peer`)을 키 교환 발견 경로에 재사용하지 않는다.

## 정상 부팅

TX와 RX는 어떤 순서로 켜져도 다음 과정을 반복해 자동 수렴한다.

1. USB Wi-Fi 연결 및 상대 발견
2. OpenSSL CSPRNG로 AES-256 세션 키 생성
3. X25519 static-static ECDH와 pinned peer public key 확인
4. HKDF-SHA256으로 capsule 보호 키 파생
5. AES-GCM 보호 capsule 교환
6. RX READY / TX COMMIT / RX DONE
7. 양쪽 PL 세션 원자적 활성화 후 영상 시작

Jetson은 최초 정상 세션의 필수 trigger가 아니다. Jetson의 `CREATE_SECURE_SESSION` 및 `CREATE_WEAK_SESSION(seed_bits=N)`은 이미 동작 중인 세션을 재생성하거나 데모용 weak session으로 바꾸는 사후 관리 명령이다.

## 재부팅·카운터 복구

RX는 낮거나 같은 counter의 다른 capsule을 계속 replay로 거부한다. 다만 TX가 JTAG/RAM 부팅처럼 로컬 영속 counter를 잃었을 때에는 다음 인증 절차로 복구한다.

- RX가 거부한 정확한 capsule의 SHA-256, session ID, counter, RX committed floor를 포함한 counter-floor 응답을 만든다.
- 응답은 양쪽 pinned 장기 X25519 키에서 파생한 키로 인증·암호화한다.
- TX는 응답이 현재 자신이 보낸 capsule과 정확히 결합됐는지 검증한 뒤 `floor + 1`의 새 capsule을 만든다.
- 인증되지 않은 floor, 다른 capsule용 floor, 낮은 counter 재사용은 수락하지 않는다.

따라서 TX만 먼저 또는 나중에 재부팅되어도 RX 보안 상태를 강제로 지우지 않고 새 세션으로 자동 수렴한다.

## 저장 위치와 부팅 방식 독립성

- `AES_SESSION_DATA_DIR`가 명시되면 그 경로를 사용한다.
- 기본값은 항상 `/var/lib/aes-session`이다.
- SD rootfs 부팅에서는 `/var/lib`가 rootfs에 속하므로 자연스럽게 영속된다.
- JTAG/RAM 부팅에서는 `/var/lib`가 휘발성이지만 위의 인증된 counter-floor 교환으로 정상 복구한다.

SD 라벨, `/run/media/...` 자동 마운트 이름, 삽입된 SD 유무를 프로토콜의 정확성 조건으로 사용하지 않는다. 평문 AES 키는 영속 저장하지 않는다.

## 관리 명령

```text
CREATE_SECURE_SESSION <request_id>
CREATE_WEAK_SESSION <request_id> <seed_bits>

SECURE_SESSION_ACTIVE <request_id> <session_id>
WEAK_SESSION_ACTIVE <request_id> <session_id> <seed_bits>
ERROR <request_id> <reason>
```

- `request_id`는 중복 요청을 멱등 처리한다.
- `seed_bits`는 데모용 `1..32`이다.
- weak key는 `SHA-256("ZYBO-SEED-v1" || uint32_be(seed))`로만 만든다.
- 관리 socket은 video hot path와 분리한다.

## 회귀 시험

```sh
make clean
make
make test
./test_session_recovery.sh
./test_wifi_recovery.sh
./test_init_supervision.sh
```

`test_session_recovery.sh`에는 TX 상태만 삭제하고 RX 상태는 유지한 JTAG/RAM TX-only reboot 회귀 시험이 포함된다. RX의 인증된 floor를 받은 TX가 다음 counter로 수렴해야 통과한다.
