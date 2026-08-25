# AES-GCM 영상 송수신 + X25519/HKDF + RX 5종 오류 검출 데모

기본 영상·세션 규격은 [`docs/ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md`](./docs/ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md)를 유지한다. 다만 **2026-08-11 RX 5종 PL 오류 검출기·PC UI 변경과 3-2 TX PL 직결 변경**이 우선한다. 기존 RSA/SW2/BTN3 문서는 역사 자료다.

> [!WARNING]
> 이 폴더는 3-1의 차분 파일 모음이 아니라 독립 빌드 가능한 **3-2 TX PL 직결 후보본**이다. `MIPI → PL AES-GCM → DDR → PS UDP`가 실기기에서 검증되기 전까지 SD 카드 안전 기준은 3-1이다. 진행 상태와 완료 gate는 `STATUS_TX_PL_직결.md`, 상세 경로는 `AES_GCM_TX/petalinux/TX_PL_DIRECT_30FPS_PATH.md`를 따른다.

> [!IMPORTANT]
> 세션 Wi-Fi fallback은 `KCCI_STC_S`를 사용하며 PSK는 `wpa.conf`에 해시로 저장한다. 기본 영상·세션 경로는 Jetson 유선 브리지에서 상대 보드를 런타임 탐색하며, Wi-Fi 연결 실패나 지연이 영상·세션 시작을 막지 않는다.
>
> TX PetaLinux는 부팅 완료 후 **Jetson 연결이나 명령 없이** CSPRNG 기반 Secure Session을 자동 생성·활성화한다. Jetson은 나중에 `CREATE_SECURE_SESSION`으로 Secure Session을 재생성하거나 `CREATE_WEAK_SESSION(seed_bits=N)`으로 현재 Secure Session을 Weak Demo Session으로 override한다. Jetson 명령은 post-boot override/control 경로이지 최초 Secure Session의 유일한 trigger가 아니다.

## 현재 구조

```text
Pcam
  → Zybo TX MIPI/PL
  → PL AES-256-GCM 또는 SW3 plaintext bypass
  → DDR에는 PL 처리 후 프레임만 기록
  → PS UDP
  → Jetson 2-NIC Linux kernel bridge
  → Zybo RX
  → 인증·복호 + software replay freshness 검사
  → VDMA
  → HDMI
  → Capture Board
  → PC

Zybo RX → Wi-Fi learned-PC unicast telemetry → PC UI (127.0.0.1:8765)
Jetson  → management/attack control  → Zybo TX/RX path (01·02)
```

- 영상 hot path는 Jetson Python relay가 아니라 Linux kernel bridge를 통과한다.
- PC는 상단 `RX VIDEO | SECURITY | GEMINI`, 하단 기존 `NORMAL FLOW`를 담당한다. Jetson `:4173`은 `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH` 공격 콘솔로만 남긴다.
- PC backend는 고정 PC/RX IP 없이 현재 물리 IPv4 `/24`에서 RX discovery port를 탐색한다. RX는 구독 요청에서 실제 PC telemetry/event port를 학습해 unicast하고, multicast/limited broadcast는 discovery 실패 때의 fallback으로만 남긴다.
- TX/RX session agent는 런타임 wired peer 파일을 우선 사용한다. Wi-Fi helper는 별도 best-effort 경로이며 USB 동글·DHCP·AP 부팅 속도가 secure video hot path를 block하지 않는다.
- RX HDMI의 반송 타이밍은 `1280×720p60`이고, 실제 영상 내용은 약 `29~30 fps`로 갱신된다. 60 fps는 HDMI carrier이지 암호 영상 생성률이 아니다.
- PC 모니터는 RX HDMI에 직접 연결하지 않고 `RX HDMI → Capture Board → PC`로 연결한다.
- Normal/Secure 성능 목표는 30 fps class이며 hard regression gate는 약 29 fps이다.
- 3-2 TX에는 기존 `plaintext DDR → AXI DMA MM2S → AES → AXI DMA S2MM` 왕복과 `/dev/pcam_aes_bridge`가 없다.

## 부팅과 Session 제어

부팅 기본값은 항상 `NORMAL SECURE`이다.

```text
TX PetaLinux boot
  → OpenSSL CSPRNG로 새 AES-256 key 생성
  → X25519 static-static ECDH
  → peer public-key pinning 확인
  → HKDF-SHA256으로 session wrapping material 파생
  → AES-GCM으로 session capsule 보호
  → RX READY / COMMIT / DONE
  → TX/RX Secure Session 원자적 활성화
```

V1은 X25519 static-static과 pinned peer public key를 사용한다. Forward Secrecy를 위한 ephemeral authenticated ECDH는 V2 범위다. 기존의 단조 증가 counter, `PENDING`/`ACTIVE` 내구 상태, READY/COMMIT/DONE, 안전 경계 atomic commit, 중복 요청 멱등성, 재시작 복구 계약은 유지한다.

Jetson이 부팅 후 사용할 수 있는 관리 명령은 다음 두 개다.

| 명령 | 효과 |
|---|---|
| `CREATE_SECURE_SESSION` | 새 CSPRNG AES-256 key로 Secure Session 재생성 |
| `CREATE_WEAK_SESSION(seed_bits=N)` | `N`비트 seed로 새 Weak Demo Session을 만들어 현재 Secure Session override |

응답 계약:

```text
SECURE_SESSION_ACTIVE(request_id, session_id)
WEAK_SESSION_ACTIVE(request_id, session_id, seed_bits)
ERROR(request_id, reason)
```

`request_id`는 재전송을 멱등 처리한다. management socket은 video packet loop와 분리하며 실제 IP/port는 설정값으로 둔다. UI의 `RETURN TO SECURE SESSION` 버튼도 wire에서는 `CREATE_SECURE_SESSION`을 보낸다.

Weak Demo key는 다음 규칙으로만 만든다.

```text
seed_bits N = runtime 1..32
seed         = N-bit random value
AES-256 key  = SHA-256("ZYBO-SEED-v1" || uint32_be(seed))
```

Jetson에는 seed나 AES key를 전달하지 않는다. Jetson은 `N`, 공개 KDF 규칙, 캡처한 AES-GCM packet만으로 후보를 검증한다. Weak Session은 데모 전용이며 production 기본값으로 사용하지 않는다.

## 물리 입력

- TX에서 관객이 조작하는 데모 입력은 `SW3` 하나뿐이다.
- `SW3 OFF`: AES-GCM OFF / plaintext bypass.
- `SW3 ON`: AES-GCM ON / 현재 활성 Session Key 사용.
- TX `SW2`와 `BTN3`에는 데모 기능을 배정하지 않는다. 세션 생성, 재키, Weak 선택, 영상 정지에 사용하지 않는다.
- RX의 기존 SW3가 복호/bypass 표시 경로에 연결되어 있으면 그 기능만 유지한다. RX `SW2`/`BTN3`는 데모 제어로 사용하지 않는다.
- Tamper, Replay, Weak-key brute-force 데모는 양쪽 암호 경로가 켜진 `SW3 ON` 상태에서 수행한다.

> [!WARNING]
> `SW2`/`BTN3`에는 데모 기능이 없다. PS/session-control software는 `SW2`를 무시하고, 재빌드한 TX 역할 wrapper는 `ENABLE_TERMINATE_BUTTON=0`으로 BTN3 입력을 비활성화한다. 따라서 BTN3를 눌렀다 떼어도 active key, session, 영상 경로에 영향이 없다. 정상 세션 COMMIT/CLEAR와 recovery는 PS 관리 경로로만 수행한다.

## RX PL 5종 오류 검출과 PC telemetry

RX PL의 `gcm_rx_error_detector.sv`는 AXI4-Stream을 입력 전용 tap으로 관찰하며 다음 5종을 독립 계수한다.

| 코드 | 검출 항목 | 기준 |
|---:|---|---|
| E1 | TAG | AES-GCM 코어의 인증 실패 확정 pulse |
| E2 | REPLAY | 동일 frame packet 중복 또는 완료 frame 재수신 |
| E3 | SEQUENCE | packet index 불연속 또는 미완료 frame 뒤 새 SOF |
| E4 | SESSION | active session 불일치, frame 중간 session 변경, 잘못된 magic |
| E5 | TIMEOUT | 유효 키가 있는데 설정 시간 동안 packet 완료가 없음 |

키 COMMIT/CLEAR 때 re-key 유예 창을 자동 적용하고, 키가 의도적으로 지워진 동안에는 TIMEOUT을 억제한다. sticky flag, 개별 누계, 마지막 frame/packet/session은 AXI GPIO `0x41220000`의 view mux로 RX PetaLinux가 읽는다. 기존 software replay freshness 검사도 방어 계층으로 유지한다.

RX는 Jetson이 아니라 PC로 versioned UDP telemetry v2를 약 5 Hz 전송한다. rate 값은 최근 1초 rolling window로 계산하며 다음 계열을 포함한다.

- valid/attempted frame rate
- authentication/format reject rate와 누계
- replay reject rate와 누계
- drop/delivery, jitter, queue/sequence 상태
- active session과 필요한 system status
- PL 5종 detector 누계, sticky/last code, 마지막 frame/packet/session

`auth_reject`는 현 PL 상태에서 TAG fail만을 독립적으로 뜻한다고 과장하지 않는다. replay freshness reject와 authentication/format reject는 별도로 집계한다.

## 고정 packet 규격

| 항목 | 값 |
|---|---:|
| 영상 | 1280×720 YUYV, 16 bit/pixel |
| frame 크기 | 1,843,200 B |
| frame당 packet | 1,280 |
| payload | 1,440 B = 90 × 128-bit block |
| AAD | 16 B = 1 block |
| TAG | 16 B = 1 block |
| UDP data | 1,472 B = 92 × 128-bit block |
| IPv4 packet | 1,500 B |

TX packet controller는 packet당 payload 90 block을 처리하고 RX packet 입력은 AAD 1 + ciphertext 90 + TAG 1 = 92 block이다.

## SD 카드 배포 규칙

TX와 RX 각각 `sd_card` 폴더의 다음 **정확히 8개 파일을 모두** FAT32 첫 파티션 루트에 복사한다.

```text
BOOT.BIN
boot.cmd
boot.scr
image.ub
system.bit
system.dtb
README.md
SHA256SUMS
```

일부 파일만 골라 복사하면 안 된다. 복사 전후 `SHA256SUMS`를 대조한다. 카드의 두 번째 ext4 파티션도 그대로 유지한다.

- TX: `/run/media/rootfs-mmcblk0p2/var/lib/aes-session`에 단조 증가 counter만 보존한다. 평문 AES key는 저장하지 않는다.
- RX: 같은 경로에 인증된 capsule, counter, session ID와 phase를 root 전용 권한으로 보존해 RX 단독 재부팅 뒤 복구한다.
- JTAG/RAM 부팅 또는 ext4 부재 시 `/var/lib/aes-session`은 휘발성 fallback이다.

부팅 주소와 메모리 계약은 TX/RX 공통으로 고정한다.

```text
image.ub    = 0x10000000
system.dtb  = 0x00100000
mem         = 384M
bootm_low   = 0x00000000
bootm_size  = 0x18000000
initrd_high = 0x16ffffff
fdt_high    = 0x17ffffff
```

`boot.cmd`/`boot.scr`와 DMA 예약 영역을 임의 변경하지 않는다.

## JTAG RAM 부팅

현재 현장 기본값:

| 보드 | cable | UART | IP/CIDR | 유선 MAC |
|---|---|---|---|---|
| TX (Pcam) | `210351BE7DF5A` | `COM9` | `10.10.15.2/24` | `02:00:00:00:00:02` |
| RX | `210351BE7D5BA` | `COM12` | `10.10.15.3/24` | `02:00:00:00:00:03` |

영상용 유선 `en*`는 위 role-static 주소를 사용하고 generic DHCP를 실행하지 않는다. 그래서 Jetson L2 bridge 경유와 TX/RX on-link 직결 모두에서 link flap 뒤 주소가 사라지면 안 된다. 실제 PC 화면까지의 직결 결과는 `docs/2026-08-09_TX_RX_이더넷_직결_실기검증.md`에 기록한다.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\JTAG_AUTO_BOOT.ps1"
```

자동 실행기는 두 Digilent UART/JTAG 쌍을 열거하고 Pcam 장치가 실제로 검출된 보드만 TX로 승인한다. 개별 TX 스크립트도 Pcam이 없으면 실패하므로 잘못된 보드 업로드를 성공으로 처리하지 않는다.

JTAG loader도 `system.dtb=0x00100000`, `image.ub=0x10000000`을 사용한다. JTAG/RAM 부팅은 ext4 영속 상태를 제공하지 않는다는 점을 SD 부팅과 구분한다.

## 폴더 안내

- `AES_GCM_TX/`: TX Vivado/PetaLinux, JTAG와 SD 배포물
- `AES_GCM_RX/`: RX Vivado/PetaLinux, JTAG와 SD 배포물
- `PC_RX_UI/`: PC의 HDMI 캡처 + RX telemetry 통합 01 UI (`run_pc_ui.bat`, 기본 `127.0.0.1:8765`)
- `session_control/`: X25519/HKDF session contract와 양쪽 session agent
- `docs/2026-08-11_RX_5detector_PC_UI_validation.md`: 이번 RTL/PC UI 변경 및 검증 기록
- `docs/ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md`: V1 authoritative freeze
- `docs/2026-08-09_TX_RX_이더넷_직결_실기검증.md`: RX HDMI→캡처보드→PC 실제 화면 직결 검증
- `docs/JETSON_2NIC_중간삽입_재배선_운용README.md`: Jetson NIC1/NIC2 중간 삽입, cable flap, bridge, Web/UI 운용 절차
- `docs/2026-08-05_RSA_BTN3_실기검증.md`: 역사 자료
- `docs/EU_CRA_Jetson_GPU_데모_적용검토.md`: 역사 자료
- `STATUS_TX_PL_직결.md`: 3-2 완료 조건과 현재 검증 상태
- `AES_GCM_TX/petalinux/TX_PL_DIRECT_30FPS_PATH.md`: TX PL 직결 RTL/PS 경로와 재시작 복구 계약

3-2의 변경 범위는 RX 5종 detector/PC telemetry 기준을 그대로 유지하면서 TX의 카메라 평문을 DDR 전에 PL에서 AES-GCM 처리하는 것이다. xsim, Vivado, PetaLinux, JTAG 실영상, 공격 및 재시작 검증을 모두 통과해야 3-1을 대체한다.
