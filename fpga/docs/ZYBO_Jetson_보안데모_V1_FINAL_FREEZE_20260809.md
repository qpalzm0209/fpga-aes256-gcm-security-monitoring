# ZYBO–Jetson 보안 데모 V1 최종 구조 및 Zybo 수정 범위 동결안

> **최종 확정본: V1-FREEZE / 2026-08-09**  
> 이 문서의 `100% 고정` 항목은 V1 구현 중 임의 변경하지 않는다. 변경이 필요하면 V2 항목으로 분리한다.

> 작성 목적  
> 현재까지 정한 데모 시나리오를 **실제 Zybo TX/RX 기준본에 적용하기 전에 구현 경계와 인터페이스를 고정**하기 위한 문서이다.  
> 핵심 목표는 새로운 기능을 추가하면서도 현재 확보한 약 29~30 fps 영상 경로와 AES-GCM RTL을 최대한 보존하는 것이다.
>
> 이 문서가 확정되면 이후 AI 모델, anomaly threshold, brute-force seed bit 후보, UI 표현이 바뀌더라도 **Zybo의 핵심 구조를 다시 수정하지 않는 것**을 원칙으로 한다.
>
> [!IMPORTANT]
> **부팅/제어 최종 규칙(사용자 확정)**
>
> - TX PetaLinux는 부팅 완료 후 Jetson 연결이나 명령 없이 CSPRNG 기반 `NORMAL SECURE` Session을 자동 생성·활성화한다.
> - Jetson이 나중에 연결되면 `CREATE_SECURE_SESSION`으로 새 Secure Session을 재생성하거나 `CREATE_WEAK_SESSION(seed_bits=N)`으로 현재 부팅 Secure Session을 Weak Demo Session으로 override한다.
> - 따라서 Jetson 관리 명령은 **부팅 후 재키/프로파일 override/control의 유일한 경로**이지, 최초 Secure Session 생성의 유일한 trigger가 아니다.
> - session Wi-Fi SSID는 `KCCI_STC_S`이며 PSK는 TX/RX `wpa.conf`에 해시로 저장한다.
> - N150UA의 인터페이스 이름, MAC, AP DHCP 주소는 제어 프로토콜 계약이 아니다. TX/RX는 각각 `169.254.77.2/24`, `169.254.77.3/24`를 사용하고 ARP로 peer를 해석한다.
> - Wi-Fi health 검사는 10초 간격이며 첫 불건전 sample에서 repair한다.
> - 영상 Ethernet은 TX `10.10.15.2/24`, RX `10.10.15.3/24` role-static이다. 유선 `en*`에 generic DHCP를 실행하지 않으며, Jetson L2 bridge 경유와 TX/RX on-link 직결을 모두 지원한다.
> - 직결 실기에서는 로그뿐 아니라 RX HDMI→USB 캡처보드→PC decoded pixel과 PCam rolling pattern 이동까지 확인한다. 결과는 [`2026-08-09_TX_RX_이더넷_직결_실기검증.md`](2026-08-09_TX_RX_이더넷_직결_실기검증.md)에 고정한다.
> - Jetson 2-NIC 중간 삽입의 재배선·bridge·실제 화면 gate는 [`JETSON_2NIC_중간삽입_재배선_운용README.md`](JETSON_2NIC_중간삽입_재배선_운용README.md)를 따른다. Web/UI는 관리 plane이고 정상 영상은 계속 kernel L2 bridge data plane을 사용한다.
> - 관객이 조작하는 TX 물리 입력은 `SW3`뿐이며 `SW2`와 `BTN3`에는 데모 기능을 배정하지 않는다.
> - 2026-08-09 최종 실기 결과와 산출물 해시는 [`2026-08-09_최종_실기검증.md`](2026-08-09_최종_실기검증.md)에 고정한다.

---

# 1. 현재 기준본에서 이미 확보된 것

현재 RSA 완성본 기준으로 다음 구조가 이미 존재한다.

```text
Pcam
→ Zybo TX
→ AES-256-GCM / Plaintext bypass
→ DDR / PetaLinux
→ Ethernet
→ Zybo RX
→ AES-GCM 검증·복호
→ VDMA
→ HDMI
```

현재 영상 규격은 다음으로 고정되어 있다.

```text
1280 × 720
YUYV 16 bit/pixel
1 frame = 1,843,200 B

1 frame = 1,280 packets
1 packet video payload = 1,440 B

AAD        16 B
Payload  1,440 B
TAG        16 B
----------------
UDP data 1,472 B

IPv4 + UDP = 28 B
IP packet  = 1,500 B
```

현재 TX 30 fps 경로는 DMA-BUF 기반으로 구성되어 있다.

```text
PCAM / Frame Buffer Write
→ V4L2 MMAP
→ DMA-BUF
→ AXI DMA
→ AES-GCM TX / bypass
→ AXI DMA
→ CMA DMA-BUF ping-pong
→ UDP packetization
→ Ethernet
```

이 경로는 이미 약 29 fps 수준으로 동작하고 있으므로 **앞으로의 데모 추가 작업에서 재설계 대상이 아니다.**

## 1.1 현재 성능 기준선

현재 프로젝트의 성능 기준선은 다음과 같이 잡는다.

```text
Target            : 30 fps class
실제 안정 기준    : 약 29~29.5 fps
PC 사전검증 측정  : 약 29.39 fps
```

최종 기능을 추가한 뒤에도 Normal/Secure Mode에서 이 수준을 유지해야 한다.

권장 regression gate:

```text
Target     : ≥ 29.5 fps
Hard Gate  : ≥ 29.0 fps
측정 길이  : 최소 300 frames
```

또한 시간에 따라 packet/frame loss가 계속 누적되는 현상이 없어야 한다.

---

# 2. 최종 데모 시나리오 — V1 동결

## 0. 보안 개념 설명

### AES-256

```text
목적:
데이터 기밀성 보호
```

AES-256은 영상 데이터를 암호화하여 키를 모르는 제3자가 원본 영상을 읽기 어렵게 만든다.

### GCM

```text
목적:
데이터 무결성 + 인증
```

GCM TAG를 이용하여 암호문 또는 인증 데이터가 전송 중 변경되었는지 검증한다.

```text
Ciphertext 수정
→ 수신 TAG 검증 불일치
→ 인증 실패
→ 해당 frame 표시 금지
```

### ECC / ECDH

발표와 UI에서는 포괄적인 `ECC`보다 실제 동작을 나타내는 다음 표현을 사용한다.

```text
ECDH(X25519)
→ AES 세션키를 안전하게 설정하기 위한 키 설정 계층
```

최종 설명 문구:

```text
AES-256  : 영상 데이터의 기밀성
GCM      : TAG 기반 무결성·변조 탐지
ECDH     : AES 세션키를 안전하게 설정하기 위한 키 합의
```

---

## 1. 실시간 보안 모니터링

실제 데이터 경로:

```text
Zybo TX
   │
   ▼
Jetson Inline Bridge
   │
   ▼
Zybo RX
```

Jetson UI에서 다음을 시각화한다.

- TX → Jetson → RX 실제 packet flow
- 현재 AES-GCM 상태
- 현재 stream byte distribution / entropy
- FPS
- Throughput
- Drop 관련 상태
- Jitter
- Power
- 기타 필요한 system telemetry

단, **실제 RX 영상은 Jetson UI가 아니라 별도 PC 화면에서 확인한다.**

```text
Zybo RX
   │ HDMI
   ▼
Capture Board
   │
   ▼
PC Display
```

역할 분리:

```text
Jetson UI
= 패킷 / 공격 / RX telemetry / AI 분석

PC Display
= 실제 RX 영상 결과
```

---

# 3. 최종 물리 구조

```text
                           VIDEO DATA PATH

        ┌──────────────────────────────────────────┐
        │                                          │
        ▼                                          ▼

    Zybo TX ───────▶ Jetson 2-NIC Bridge ───────▶ Zybo RX
                         │                           │
                         │                           │
                         │                           ├── HDMI → Capture → PC
                         │                           │
                         │                           └── RX Telemetry ──┐
                         │                                             │
                         └─────────────────────────────────────────────┘
                                             │
                                             ▼
                                      Jetson AI / UI
```

핵심:

- Jetson은 TX/RX 옆에 달린 모니터가 아니라 **TX와 RX 사이 실제 데이터 경로에 존재한다.**
- 정상 통신에서도 packet은 Jetson을 통과한다.
- Tamper / Replay 시 Jetson이 중간 공격자 역할을 수행한다.
- RX 내부 결과는 별도 telemetry를 통해 Jetson으로 전달한다.
- 실제 영상 결과는 RX HDMI → Capture → PC에서 확인한다.

---

# 4. Jetson 인라인 구조 — 동결

## 4.1 사용자 공간 전체 Relay 금지

다음 구조는 사용하지 않는다.

```text
TX
→ Jetson Python/C receive()
→ 모든 packet 사용자 공간 처리
→ send()
→ RX
```

약 30 fps 영상의 전체 packet stream을 사용자 공간 프로그램이 직접 중계하면 현재 확보한 영상 성능을 다시 흔들 가능성이 크다.

## 4.2 최종 구조

```text
Zybo TX
   │
Jetson NIC 1
   │
Linux Kernel Bridge
   │
Jetson NIC 2
   │
Zybo RX
```

정상 packet forwarding은 **Linux kernel bridge**가 담당한다.

Jetson attack engine은 지정된 PCAM/AES-GCM packet에 대해서만 필요한 작업을 수행한다.

```text
Normal
→ kernel forwarding

Tamper
→ 선택 packet 수정 / checksum 갱신

Replay
→ 저장한 valid frame 재주입
```

TX/RX의 기존 IP/MAC/UDP hot path는 최대한 그대로 유지한다.

### 중요한 이유

현재 TX는 성능을 위해 RAW Ethernet 및 고정 목적지 MAC 경로를 사용한다.

Transparent L2 bridge는 원래 Ethernet destination MAC을 보존하므로 이 구조와 충돌하지 않는다.

---

# 5. 키 설정 구조 — RSA → ECDH 전환 동결

## 5.1 변경 원칙

현재 RSA session-agent에는 이미 다음 제어 절차가 존재한다.

```text
Session secret 생성
→ Capsule 전달
→ READY
→ COMMIT
→ RX PL commit
→ DONE
→ TX PL commit
```

또한 기존 구조에는 다음 안정화 기능이 이미 있다.

- pending / active 상태
- 같은 capsule 재시도
- COMMIT/DONE 복구
- PL atomic key commit
- 세션 counter
- 종료 / 재시작 제어

따라서 RSA를 ECDH로 바꾼다고 해서 **session protocol 전체를 다시 작성하지 않는다.**

변경 대상은 주로:

```text
RSA-OAEP capsule 보호
        ↓
ECDH 기반 capsule 보호
```

부분이다.

---

# 6. 최종 ECDH 방식

데모 V1에서는 구현 복잡도와 기존 안정 경로 보존을 위해 다음 구조를 사용한다.

```text
X25519 static key pair
+ peer public-key pinning
+ HKDF-SHA256
+ AES-256-GCM session capsule wrapping
```

## 6.1 Key provision

TX와 RX에는 각각 X25519 key pair를 준비한다.

```text
TX:
- tx_x25519_private
- rx_x25519_public (pinned)

RX:
- rx_x25519_private
- tx_x25519_public (pinned)
```

공개키는 프로젝트 배포 단계에서 서로 고정한다.

따라서 네트워크 중간 장치가 임의 public key로 교체하는 단순 MITM 구조를 허용하지 않는다.

> V1 범위에서는 static-static X25519를 사용하여 구현 변경량을 줄인다.  
> Forward Secrecy를 위한 ephemeral authenticated ECDH는 별도 향후 확장으로 두며 V1에서는 추가하지 않는다.

## 6.2 Session wrapping key

양쪽은 X25519로 동일한 shared secret을 계산한다.

```text
ECDH Shared Secret
        ↓
HKDF-SHA256
        ↓
Session Wrapping Key
```

HKDF에는 세션마다 fresh salt/context를 사용한다.

예:

```text
HKDF-SHA256(
    IKM  = X25519 shared secret,
    salt = fresh session salt,
    info = "ZYBO-AES-SESSION-WRAP-v1"
)
```

static-static X25519에서는 ECDH shared secret 자체가 세션마다 바뀌지 않으므로, **fresh salt는 반드시 CSPRNG로 새로 생성**한다. Session capsule을 AES-GCM으로 wrapping할 때도 fresh 96-bit `wrap_nonce`를 사용하며 같은 wrapping key에서 nonce를 재사용하지 않는다.

권장 capsule 필드:

```text
version
salt
wrap_nonce
wrapped_session_secret
wrap_tag
```

`session_secret` 내부의 `session_id/counter/challenge/AES video key`는 ciphertext로 보호한다.

TX가 만든 실제 `session_secret`은 이 wrapping key로 AES-GCM 보호하여 RX에 전달한다.

```text
session_secret
    ├─ session_id
    ├─ counter
    ├─ challenge
    └─ AES-256 video key
          │
          ▼
AES-GCM wrapping
          │
          ▼
ECDH session capsule
```

RX는 같은 wrapping key로 capsule을 복호화한 뒤 기존 session protocol을 이어간다.

---

# 7. 기존 READY / COMMIT / DONE 유지

새 ECDH 구조에서도 아래 순서는 유지한다.

```text
TX Session Secret 생성
        ↓
ECDH Capsule 생성
        ↓
RX Capsule 복호
        ↓
READY
        ↓
COMMIT
        ↓
RX PL atomic commit
        ↓
DONE
        ↓
TX PL atomic commit
```

이 부분을 유지해야 기존에 이미 해결한:

- lost DONE
- duplicate request
- pending state
- board reset recovery
- safe commit
- session termination / recovery

등을 다시 설계하지 않아도 된다.

## 7.1 TX Zybo 물리 입력 — 최종 동결

최종 데모에서는 **TX Zybo의 물리 입력을 공격 모드나 키 프로파일 선택에 사용하지 않는다.**

관객이 **TX 보드에서 직접 조작하는 기능은 `SW3` 하나만 남긴다.**

```text
TX Zybo Physical Input

SW3 OFF
→ AES-GCM OFF / Plaintext Bypass

SW3 ON
→ AES-GCM ON
→ 현재 활성 Session Key로 영상 암호화
```

이 결정은 **TX 물리 입력에 대한 동결안**이다. RX 보드에 기존부터 존재하는 표시/복호 관련 SW3가 있다면 그 기능은 별도이며, 이번 `SW2/BTN3 제거` 결정으로 자동 삭제하지 않는다.

`SW3`는 오직 **암호화 ON/OFF**만 담당한다.

다음 기능은 TX 보드 물리 입력에서 제거한다.

```text
SW2
→ 기존 키 교환 시작 기능 제거
→ 데모 기능 배정 없음

BTN3
→ 기존 영상 정지 / release 시 재키 기능 제거
→ 데모 기능 배정 없음
```

최종 보정: PS는 `SW2`를 무시한다. TX 역할 wrapper는 `ENABLE_TERMINATE_BUTTON=0`으로 재합성하여 BTN3 입력을 비활성화한다. 따라서 BTN3를 눌렀다 떼어도 active key, session, 영상 경로에 영향이 없다. 정상 세션 COMMIT/CLEAR와 recovery는 PS 관리 경로로만 수행한다. 이 한 줄 역할 파라미터 변경 외의 AES-GCM/video RTL datapath와 720p timing은 동결 상태를 유지한다.

즉 최종 전시 운용에서:

```text
SW2를 눌러 키 교환 시작
BTN3를 눌러 영상 정지
BTN3를 떼어 새 세션 시작
```

같은 절차는 사용하지 않는다.

이유는 최종 시스템에서 Jetson UI가:

- Secure / Weak key profile
- 새 Session 생성 시작
- Session 설정 완료 여부
- Brute-force 시작 가능 여부

를 모두 알고 있어야 하기 때문이다.

초기 상태는 TX PetaLinux가 부팅 후 Jetson 없이 `NORMAL SECURE` Session을 자동 생성한다. 그 뒤 물리 스위치와 Jetson UI가 동시에 세션 상태를 변경하면 실제 TX/RX 상태와 UI 상태가 어긋날 수 있으므로, **부팅 후 Secure 재생성·Weak override·재키 제어는 Jetson → TX PetaLinux 관리 명령으로 단일화**한다. 즉 Jetson 명령은 post-boot override/control 경로이며 최초 Secure Session의 유일한 trigger가 아니다.

최종 조작 원칙:

```text
Zybo TX
└─ SW3 = AES-GCM ON/OFF만 담당

TX PetaLinux boot
└─ Jetson 없이 Secure Session 자동 생성

Jetson UI
├─ Secure Session 재생성
├─ Weak Session(N-bit) override
├─ Tamper
├─ Replay
└─ Brute-force
```

따라서 Tamper / Replay / Brute-force를 위해 새로운 FPGA switch/button 입력이나 `attack_mode` RTL 신호를 추가하지 않는다.

Tamper / Replay / Weak-key Brute-force 보안 데모는 **SW3 ON(AES-GCM ON)** 상태를 전제로 한다. Weak Session 준비 후부터 공격 종료까지 사용자는 TX 보드를 다시 조작하지 않고 Jetson UI만 사용한다.

---

# 8. Normal Mode와 Weak Mode의 키 생성

## 8.1 Normal Secure Mode

현재 기준본의 정상 키 생성 방식을 유지한다.

```text
OpenSSL CSPRNG
→ 256-bit random AES key
```

현재 코드의 `RAND_priv_bytes_ex(..., 256)` 계열을 유지하는 방향이다.

즉:

```text
Normal AES key entropy ≈ 256 bit class
```

---

## 8.2 Weak Demo Mode

Weak Mode는 **AES-256 형식은 유지하지만 실제 key source entropy만 의도적으로 줄인다.**

PC brute-force benchmark와 동일한 규칙을 고정한다.

```text
seed ∈ [0, 2^N - 1]

AES key =
SHA-256(
    "ZYBO-SEED-v1"
    || uint32_be(seed)
)
```

결과는 256-bit AES key이지만 가능한 seed가 `2^N`개뿐이므로 실질 탐색 공간은 최대:

```text
2^N
```

이다.

### 중요한 변경

기존 PC Validation V2 문서에서는 Weak Mode를:

```text
ECDH BYPASSED
```

로 두었지만 **최종 데모 V1에서는 이 구조를 사용하지 않는다.**

최종 구조:

```text
Normal Mode

CSPRNG
→ AES-256 session key
→ ECDH capsule
→ RX


Weak Mode

N-bit seed
→ SHA-256
→ AES-256 demo key
→ 동일한 ECDH capsule
→ RX
```

즉 Normal/Weak 모두 **같은 ECDH key-setting protocol**을 사용한다.

Weak Demo의 취약점은 ECDH가 아니라:

```text
낮은 entropy의 AES key source
```

이다.

발표 메시지:

> 키를 안전한 경로로 전달하더라도, 원래 만들어진 키의 엔트로피가 작으면 brute-force에 취약할 수 있다.

이 구조로 고정하면 Weak Mode 때문에 별도의 키 교환 프로토콜을 추가할 필요가 없다.

## 8.3 Secure / Weak 전환 제어 경로

부팅 기본값은 항상 `NORMAL SECURE`이다. TX PetaLinux는 Jetson이 없어도 부팅 후 CSPRNG로 새 AES-256 key를 만들고 기존과 동일한 X25519 + HKDF Session Setting을 거쳐 Secure Session을 자동 활성화한다.

```text
TX PetaLinux boot
→ CSPRNG로 새 AES-256 key 생성
        ↓
X25519 + HKDF Session Setting
        ↓
RX READY / COMMIT / DONE
        ↓
TX/RX Secure Session 자동 활성화
```

그 뒤 Secure 재생성 또는 Secure / Weak 전환은 TX 보드의 물리 스위치가 아니라 **Jetson UI의 관리 명령**으로 수행한다.

### 부팅 후 Secure Session 재생성

```text
Jetson UI (post-boot rekey)
→ CREATE_SECURE_SESSION
        ↓
TX PetaLinux
→ CSPRNG로 새 AES-256 key 생성
        ↓
기존과 동일한 X25519 + HKDF Session Setting
        ↓
RX READY / COMMIT / DONE
        ↓
TX/RX 새 Secure Session 활성화
        ↓
Jetson에 SECURE_SESSION_ACTIVE ACK
```

### Weak Session 생성

```text
Jetson UI
→ CREATE_WEAK_SESSION
   seed_bits = N
        ↓
TX PetaLinux
→ N-bit random seed 생성
→ SHA-256("ZYBO-SEED-v1" || uint32_be(seed))
→ AES-256 demo key 생성
        ↓
기존과 동일한 X25519 + HKDF Session Setting
        ↓
RX READY / COMMIT / DONE
        ↓
TX/RX 새 Weak Session 활성화
        ↓
Jetson에 WEAK_SESSION_ACTIVE ACK
```

중요:

```text
Secure ↔ Weak 전환
= 기존 AES key의 속성만 바꾸는 것 아님
= 항상 새 AES key를 만들고 새 Session을 설정하는 작업
```

따라서 Weak Brute-force 데모를 시작할 때의 권장 UI 순서는 다음과 같다.

```text
0. TX SW3 ON(AES-GCM ON) 확인
1. 사용자가 Jetson UI에서 Seed Bit N 선택
2. [PREPARE WEAK SESSION] 실행
3. Jetson → TX에 CREATE_WEAK_SESSION(N) 명령
4. TX/RX ECDH 기반 새 Session 설정
5. WEAK_SESSION_ACTIVE ACK 확인
6. Jetson이 새 Session의 AES-GCM packet capture
7. [START BRUTE FORCE] 활성화
8. CPU/GPU exhaustive search 시작
```

Brute-force 종료 후 Secure Mode로 복귀할 때도 같은 Secure Session 생성 명령을 사용한다.

```text
Jetson UI button label
→ RETURN TO SECURE SESSION

wire/control command
→ CREATE_SECURE_SESSION

TX
→ 새 CSPRNG AES-256 key 생성
→ 동일한 ECDH Session Setting
→ SECURE_SESSION_ACTIVE ACK
```

즉 `RETURN TO SECURE SESSION`은 **UI 표시 문구**이고, 실제 제어 명령 이름은 `CREATE_SECURE_SESSION` 하나로 통일한다.

Jetson은 Weak seed와 실제 AES key를 전달받지 않는다. Jetson이 아는 것은 `N`, 공개 KDF 규칙, 캡처한 AES-GCM packet뿐이다.

### 8.4 Jetson → TX Session Control 인터페이스

V1에서 고정해야 하는 것은 **명령 의미와 ACK 계약**이며, 영상 hot path와 분리한다.

```text
Commands
- CREATE_SECURE_SESSION
- CREATE_WEAK_SESSION(seed_bits=N)

ACK
- SECURE_SESSION_ACTIVE(request_id, session_id)
- WEAK_SESSION_ACTIVE(request_id, session_id, seed_bits)
- ERROR(request_id, reason)
```

`request_id`를 두어 재전송 시 같은 요청을 구분하고, 동일 요청이 중복 도착해도 세션이 불필요하게 여러 번 생성되지 않도록 idempotent하게 처리한다.

전송은 PetaLinux의 가벼운 management socket으로 구현한다. 실제 IP/port는 configuration으로 분리하며, **video packet 처리 루프를 block하지 않는다.** 기존 session-control UDP 경로를 재사용하거나 별도 management UDP port를 둘 수 있지만, 위 명령/ACK 의미는 바꾸지 않는다.

---

# 9. Weak-Key Brute-Force 데모 구조

Jetson 공격자는 다음 정보만 안다.

```text
- N bit seed를 사용했다는 사실
- 공개 KDF 규칙
- 수신한 AES-GCM packet
```

Jetson은 실제 seed/AES key를 전달받지 않는다.

공격:

```text
seed = 0
  ↓
SHA-256("ZYBO-SEED-v1" || seed)
  ↓
candidate AES key
  ↓
GCM TAG 검증
  ↓
fail
  ↓

seed = 1
...

정답 candidate
  ↓
TAG MATCH
  ↓
KEY FOUND
```

CPU/GPU 모두 동일한 후보 검증 규칙을 사용한다.

비교 기준:

```text
keys/s
elapsed time
```

CPU core 수와 CUDA core 수를 직접 비교하지 않는다.

## 9.1 Brute-force 검증 입력 — 실제 패킷 기준 동결

최종 brute-force 후보 검증은 축소된 16 B ciphertext가 아니라 **실제 영상 패킷 전체 인증 조건**을 사용한다.

```text
AAD          16 B
Ciphertext 1440 B
TAG          16 B
```

후보 하나의 검증 흐름:

```text
candidate seed
→ SHA-256("ZYBO-SEED-v1" || uint32_be(seed))
→ candidate AES-256 key
→ AAD 16 B + Ciphertext 1440 B 전체 GCM authentication 계산
→ 128-bit TAG 비교
→ 일치 시 KEY FOUND
```

다음 shortcut은 V1 최종 측정에서 사용하지 않는다.

- ciphertext 일부 16 B만 검사
- TAG 일부만 비교
- plaintext known-answer만으로 후보 판정

PC GPU 결과는 개발/예비 측정이며 **최종 Seed Bit `N`은 Jetson Orin Nano/Super에서 실제 측정한 keys/s로 결정**한다.

CUDA 구현은 PC 전용 코드로 고정하지 않는다.

```text
공통 CUDA .cu source
├─ PC GPU에서 native build / correctness + preliminary benchmark
└─ Jetson Linux에서 native build / final benchmark + demo
```

Jetson에서 사용할 수 있도록 전체 keyspace 크기의 후보 배열을 한 번에 만들지 않고 fixed-size chunk/batch 방식으로 처리한다. 최종 처리율은 후보 생성부터 전체 1440 B GCM TAG 비교까지의 end-to-end search 경로를 기준으로 한다.

성능 측정 전에 작은 탐색공간(예: 4096 candidates)에서 CPU AES-GCM reference와 CUDA 결과가 **동일한 seed 하나만 반환하는지** 교차검증한다.

런타임 NVRTC JIT는 V1 데모의 필수 조건으로 두지 않는다. 공통 `.cu` source를 `nvcc`로 사전 build할 수 있는 구조를 우선하며, build/JIT 시간은 공격 `keys/s`와 분리한다.

---

# 10. Brute-Force bit 값은 Zybo 구조와 분리

Seed bit `N`은 컴파일 상수가 아니라 **런타임 Demo Parameter**로 만든다.

예:

```text
16 bit
20 bit
24 bit
25 bit
26 bit
27 bit
28 bit
...
```

최종 전시 bit 후보는 Jetson 실제 benchmark 후 결정한다.

중요:

```text
AI 모델 변경
seed bit 변경
CPU/GPU 선택
```

은 Zybo PetaLinux/RTL 재빌드 이유가 되어서는 안 된다.

TX Weak Mode는:

```text
N
```

만 전달받아 `0 <= seed < 2^N` 범위에서 숨겨진 random seed를 생성하도록 한다.

구현은 `1 <= N <= 32`를 명시적으로 검사하고, `N=32`에서 `1u << 32` 같은 overflow/undefined shift가 발생하지 않도록 별도 처리한다. 모든 `N`에서 KDF 입력은 동일하게 `uint32_be(seed)` 4 B를 사용한다.

따라서 PC/Jetson brute-force benchmark가 아직 진행 중이어도 **Zybo 구현 시작을 막지 않는다.** benchmark 결과는 런타임 값 `N`만 결정하며, TX/RX RTL·패킷 형식·Session Control API를 변경하지 않는다.

---

# 11. Tamper 공격 — 정의 동결

UI의 `Attack Intensity`라는 모호한 표현 대신:

```text
TAMPERED FRAME RATE
```

를 사용한다.

예:

```text
Tampered Frame Rate = 20%
```

의미:

```text
전체 정상 frame opportunity 중 약 20%를 공격 대상으로 선택
```

선택된 frame마다:

```text
1개 packet 선택
→ Ciphertext의 1 bit 또는 1 byte 변경
→ TAG는 원래 값 유지
→ UDP/IP checksum 정상 재계산
→ RX로 전달
```

즉:

```text
100 frame 중 약 20 frame 공격
```

이지:

```text
전체 packet의 20% 변조
```

가 아니다.

패킷 비율로 공격하면 한 frame에 1,280 packet이 있기 때문에 지나치게 많은 frame이 즉시 실패할 수 있으므로 사용하지 않는다.

---

# 12. Tamper 처리 결과

```text
Jetson
Ciphertext 변경
        ↓
RX
AES-GCM TAG verification
        ↓
FAIL
        ↓
해당 frame DISPLAY 금지
        ↓
VDMA는 직전 정상 frame 유지
```

PC Display에서는 실제 결과를 확인한다.

```text
영상 freeze / frame update 감소
```

Jetson UI에서는:

```text
Jetson local attack state
+
RX feedback
+
AI anomaly result
```

를 보여준다.

---

# 13. Replay Attack — 정의 동결

Replay는 Tamper와 다르다.

```text
데이터를 변경하지 않는다.
```

Jetson은 같은 active session에서 과거에 정상적으로 전달된 **완전한 encrypted frame**을 저장한다.

```text
PAST VALID FRAME
[AAD | Ciphertext | TAG] × 1,280 packets
```

시간이 지난 뒤 정상 traffic은 계속 유지하면서 과거 frame을 다시 주입한다.

```text
CURRENT TRAFFIC
      +
OLD VALID FRAME INJECTION
```

UI 명칭:

```text
REPLAY INJECTION RATE
```

`Replay Frame Rate`처럼 정상 frame이 대체되는 것으로 오해할 수 있는 표현은 사용하지 않는다.

---

# 14. Replay 검증 순서

과거 frame의 packet 내용과 TAG는 바뀌지 않았기 때문에:

```text
GCM
→ PASS 가능
```

그 다음 RX의 freshness logic에서:

```text
old / duplicate frame_id
→ REPLAY REJECT
```

한다.

최종 흐름:

```text
Old valid encrypted frame
        ↓
GCM verification
        ↓
PASS
        ↓
Freshness Check
        ↓
OLD / DUPLICATE
        ↓
REPLAY REJECT
        ↓
DISPLAY 금지
```

이 차이를 데모에서 명확하게 설명한다.

```text
Tamper
→ GCM FAIL

Replay
→ GCM PASS
→ Freshness FAIL
```

---

# 15. Same-Session Replay 방어 구현 위치

현재 RX 애플리케이션은 GCM status를 확인한 뒤 정상 frame을 VDMA에 publish한다.

현재 개념:

```text
DMA AES/GCM
→ STATUS_FAILED?
   ├─ YES → DROP
   └─ NO
       ↓
    update_stats()
       ↓
    VDMA_PARK_PTR 변경
       ↓
    화면 표시
```

최종 구조:

```text
DMA AES/GCM
→ STATUS_FAILED?
   ├─ YES
   │    → auth_reject++
   │    → DROP
   │
   └─ NO
       ↓
   REPLAY / FRESHNESS CHECK
       │
       ├─ old/duplicate
       │     → replay_reject++
       │     → DROP
       │
       └─ new frame
             ↓
          update_stats()
             ↓
          VDMA publish
```

즉 Replay check는:

```text
GCM PASS 이후
+
VDMA publish 이전
```

에 둔다.

### Frame ID 비교

`uint32_t frame_id` wraparound까지 고려하려면 단순 `<` 비교 대신 serial-number 방식으로 처리한다.

개념:

```c
(int32_t)(new_frame_id - last_accepted_frame_id) > 0
```

이면 새로운 frame으로 본다.

세션이 바뀌면:

```text
last_accepted_frame_id state reset
```

한다.

---

# 16. Replay 방어를 RTL에 추가하지 않는 이유

현재 목적에는 PS software check만으로 충분하다.

현재 RX 구조는:

```text
GCM PASS
→ 아직 VDMA publish 전
```

시점에 frame ID를 알고 있으므로 소프트웨어에서 차단 가능하다.

따라서 V1에서는 다음을 하지 않는다.

- replay window RTL 추가
- 새로운 AXI status IP
- Vivado block design 변경
- XSA 재생성

이 선택은 **현재 29 fps 영상 경로를 보호하기 위한 의도적인 범위 제한**이다.

---

# 17. RX → Jetson Telemetry가 필요한 이유

Jetson은 TX와 RX 사이에 있으므로 다음은 직접 알 수 있다.

```text
- 내가 몇 frame을 Tamper했는가
- 몇 packet을 수정했는가
- 몇 Replay frame을 주입했는가
- TX→RX packet rate
- forwarding throughput
```

하지만 다음은 Jetson만으로는 알 수 없다.

```text
- RX가 실제로 몇 frame을 인증 실패시켰는가
- RX가 몇 Replay frame을 거부했는가
- 실제 valid frame acceptance rate
- RX 내부 queue/drop 상태
```

따라서 RX에서 Jetson으로 저속 telemetry를 보낸다.

---

# 18. RX Telemetry — 인터페이스 동결

영상 packet과 telemetry를 분리한다.

```text
Video:
TX → Jetson → RX

Telemetry:
RX → Jetson
```

Telemetry는 매우 작은 UDP message이며 영상 bandwidth와 비교하면 무시 가능한 수준이다.

권장:

```text
전송 주기        : 200 ms
rate 계산 window : 최근 1 second rolling window
```

즉 약 5 Hz UI update를 제공하면서 통계값은 1초 구간 기준으로 안정화한다.

UI의 상태 라벨도 이 계약과 맞춘다. `1 HZ STATUS UDP`처럼 고정된 과거 표기가 남아 있다면 `5 HZ STATUS UDP` 또는 rate에 덜 종속적인 `STATUS UDP`로 수정한다.

---

# 19. RX Telemetry 필드

V1 telemetry는 이후 AI/UI가 바뀌어도 Zybo를 다시 수정하지 않도록 **superset**으로 제공한다.

최소 필드:

```text
protocol_version
sequence
monotonic_ms
session_id

valid_frame_rate
frame_attempt_rate

auth_reject_rate
replay_reject_rate

frame_drop_ratio
frame_jitter_ms

network_loss_delta
queue_overrun_delta
stale_drop_delta
```

추가 진단용으로 필요하면:

```text
status_failure_delta
processed_frames_total
authentication_failures_total
replay_reject_total
```

등 누적값을 함께 제공할 수 있다.

## 19.1 Telemetry 의미 — Tamper/Replay 정합성

각 값의 의미를 다음처럼 고정한다.

```text
valid_frame_rate
= GCM/authentication과 replay freshness를 모두 통과해
  실제 display 대상으로 승인된 새로운 frame의 rate

frame_attempt_rate
= RX security decision 지점까지 완성되어 들어온 frame candidate rate
  (추가 replay frame도 포함 가능)

auth_reject_rate
= authentication/format status에서 거부된 frame candidate rate

replay_reject_rate
= authentication은 통과했지만 old/duplicate frame ID로 거부된 rate

frame_drop_ratio
= 정상 current stream에서 display에 사용되지 못한 frame 비율
  추가 주입된 replay frame은 이 비율의 정상-stream denominator에 넣지 않음

frame_jitter_ms
= accepted/display 대상 frame의 도착 간격 변동
```

따라서 대표적인 동작은:

```text
Tamper
30 fps current stream
→ 40% tampered
→ auth_reject ≈ 12/s
→ valid ≈ 18 fps
→ frame_drop_ratio ≈ 40%

Replay(additive injection)
30 fps current stream 유지
+ old valid frames 추가 주입
→ auth_reject ≈ 0
→ replay_reject > 0
→ valid ≈ 30 fps
→ frame_drop_ratio ≈ 0% 가능
```

즉 `frame_attempt_rate - valid_frame_rate`를 무조건 `frame_drop_ratio`로 계산하지 않는다. Replay injection은 별도 `replay_reject_rate`로 표현한다.

---

# 20. 현재 RX 코드에서 이미 얻을 수 있는 정보

기존 `aes-gcm-rx.c`에는 이미 다음 값 또는 이에 해당하는 상태가 존재한다.

- `processed_frames`
- `authentication_failures`
- `status_failures`
- `queue.overruns`
- `queue.stale_drops`
- frame loss 통계
- 실제 정상 처리 frame 기반 FPS
- 현재 session/frame ID

따라서 V1 telemetry를 위해 **새 RTL counter를 만들 필요가 없다.**

주요 수정:

```text
aes-gcm-rx.c

기존 counters
      ↓
1-second rolling stats
      ↓
telemetry message 생성
      ↓
UDP sendto(Jetson)
```

정도로 처리한다.

---

# 21. 중요한 Telemetry 명칭 주의

현재 `authentication_failures`는 **TAG Fail만 따로 분리한 하드웨어 counter가 아니다.**

현재 PL/frame status에서 발생한 인증/형식 실패가 통합될 수 있으므로 V1 telemetry 내부 명칭은:

```text
auth_reject_rate
```

처럼 두는 것이 안전하다.

Tamper 데모처럼 원인을 우리가 통제하는 경우에는:

```text
Ciphertext를 변경
→ GCM authentication fail
```

이라는 인과관계를 설명할 수 있다.

하지만 시스템 전체 통계에서:

```text
GCM_TAG_FAIL
FORMAT_FAIL
SESSION_FAIL
```

을 각각 완전히 독립된 hardware counter라고 주장하지 않는다.

원인별 PL counter는 V1 범위에서 제외한다.

---

# 22. Telemetry 전송 형식

V1에서는 구현과 디버깅 편의를 위해 **versioned UDP JSON**을 권장한다.

예:

```json
{
  "v": 1,
  "seq": 125,
  "session": 305419896,
  "valid_fps": 29.7,
  "attempt_fps": 30.1,
  "auth_reject_s": 0.0,
  "replay_reject_s": 0.0,
  "drop_ratio": 0.001,
  "jitter_ms": 1.3,
  "loss_delta": 0,
  "queue_overrun_delta": 0,
  "stale_drop_delta": 0
}
```

약 수백 byte를 5 Hz로 보내는 수준이므로 영상 traffic과 비교하면 매우 작다.

실제 IP/port는 configuration으로 분리한다.

```text
JETSON_TELEMETRY_IP
JETSON_TELEMETRY_PORT
```

즉 IP가 바뀌어도 코드 구조를 다시 수정하지 않는다.

---

# 23. Jetson Bridge와 Telemetry IP

두 physical bridge port에는 직접 IP를 두지 않는 것을 기본으로 한다.

```text
eth0 ─┐
      ├─ br0
eth1 ─┘
```

필요하면 `br0` 자체에 telemetry용 IP를 할당한다.

```text
RX → Jetson br0 IP : telemetry UDP
```

UI/원격 관리는 Jetson Wi-Fi 또는 별도 management path를 사용할 수 있다.

정확한 IP는 현장 subnet과 충돌하지 않도록 설정 파일에서 결정하며, **프로토콜 구조에는 영향을 주지 않는다.**

---

# 24. AI 역할 — 동결

GCM과 AI의 역할을 섞지 않는다.

```text
GCM
= 이 packet/frame의 인증이 실패했는가?

Replay Check
= 이 frame이 과거/중복 데이터인가?

AI
= RX 시스템 전체 동작이 평소 정상 패턴에서 벗어났는가?
```

따라서 AI는:

```text
TAMPER DETECTED
REPLAY DETECTED
```

같은 공격 종류 분류기가 아니다.

AI 출력:

```text
NORMAL
ANOMALY DETECTED
```

로 제한한다.

---

# 25. AI 입력과 Security Ground Truth 분리

RX에서 다음 값이 Jetson으로 오더라도 모두 AI feature로 넣지 않는다.

Security Result / Ground Truth:

```text
auth_reject_rate
replay_reject_rate
attack_mode
tampered count
replay injected count
```

이 값들은:

- UI 설명
- ground truth
- detector 성능 검증

에 사용한다.

AI feature는 최종 Jetson 검증에서 선정된 **system behavior telemetry**만 사용한다.

후보 예:

```text
valid_frame_rate
frame_attempt_rate / ingress packet behavior
frame_jitter_ms
network / queue behavior
```

`auth_reject` 또는 `replay_reject`를 그대로 AI 입력으로 넣어 정답을 누출하지 않는다.

PC V3에서 `delivery_ratio`는 공격 결과와 매우 강하게 연동되어 단순 rule baseline 자체가 높은 성능을 보였으므로, **`delivery_ratio`를 AI 핵심 feature로 자동 확정하지 않는다.** rule baseline과 AI를 분리해서 비교하고, 실제 Zybo RX telemetry에서 feature를 최종 선택한다.

---

# 26. AI 모델은 아직 Zybo 동결 조건이 아니다

현재 PC V3 사전검증에서는 **단순 delivery-ratio rule baseline이 테스트한 AI 모델보다 높은 성능을 보였고**, AI 모델끼리 비교하면 Lightweight Autoencoder가 가장 나은 후보였다.

따라서 현재 상태는:

```text
Rule baseline
→ 비교 기준으로 유지

PC AI candidate
→ Lightweight Autoencoder

Jetson final AI model / threshold
→ PENDING
```

이며, 무엇을 최종 선택하더라도 Zybo에는 영향이 없어야 한다.

Zybo가 담당하는 것은:

```text
versioned RX telemetry 제공
```

까지이다.

AI model / threshold / anomaly score normalization은 Jetson의 책임이다.

---

# 27. PC Display 역할 — 동결

PC는 다음만 담당한다.

```text
RX HDMI actual output
```

즉:

```text
"공격 결과 실제 영상이 어떻게 되었는가?"
```

를 보여준다.

예:

- 정상 영상
- frame freeze
- update 감소
- 필요하면 간단한 `AUTH FAIL`, `REPLAY BLOCKED` overlay

Jetson UI와 같은 AI/packet dashboard를 PC에 다시 복제하지 않는다.

---

# 28. Page 2와 실제 데이터 source

Jetson Page 2는 세 source를 분리한다.

## A. Jetson Local Attack State

```text
attackActive
attackMode

tamperedFrameRate
modifiedFrames
modifiedPackets

replayInjectionRate
replayedFrames
replayInjections

forwardedPackets
attackRuntime
```

## B. RX Feedback

```text
validFrameRate
frameAttemptRate
frameDropRatio

authRejectRate
replayRejectRate
rxJitter
```

## C. AI Result

```text
anomalyScore
detectionBoundary
anomalyState
modelName
scoreHistory
```

이 세 source를 서로 섞지 않는다.

### Page 2 표시 의미 — 최종 정합성

Tamper 화면은 숫자 나열만 하지 않고 다음 인과관계를 함께 보여준다.

```text
incoming fps
→ tampered frames
→ authentication failed frames
→ frames accepted for display
```

Replay 화면은 다음 의미를 보여준다.

```text
old valid frame resent
→ content authentication OK
→ old/duplicate frame ID
→ replay rejected
```

Replay는 정상 traffic에 과거 frame을 **추가 주입**하는 구조이므로 정상 valid fps가 약 30 fps를 유지하면서 `replayRejectRate`만 증가할 수 있다.

UI의 `GCM REJECT`는 Tamper 데모에서 이해를 돕기 위한 표시명으로 사용할 수 있지만, 실제 RX telemetry source는 `auth_reject_rate`이다. 현재 하드웨어가 TAG fail 원인만 독립 counter로 제공한다고 과장하지 않는다.

---

# 29. 현재 Zybo에서 변경하지 않을 것

다음은 **V1 Freeze 영역**이다.

## TX/RX RTL

- AES-256 core
- GHASH
- GCM TAG 생성/검증
- packet payload length
- AAD/Header 16 B 구조
- Nonce 구성
- AXI Stream 폭
- 150 MHz AES-GCM 구조
- Frame Buffer / DMA / VDMA 구조
- session register interface
- atomic key commit

## Packet format

```text
1280 packets/frame
1440 B payload
16 B AAD
16 B TAG
1472 B UDP data
```

## Video path

```text
1280 × 720 YUYV
1,843,200 B/frame
DMA-BUF based 30fps path
```

이 영역은 새로운 데모 기능 때문에 수정하지 않는다.

---

# 30. Zybo에서 실제 수정할 부분

## 30.1 TX / RX Session Agent

현재:

```text
RSA-OAEP
```

변경:

```text
X25519
+ HKDF-SHA256
+ AES-GCM session capsule
```

유지:

```text
READY
COMMIT
DONE
counter
pending state
atomic commit
termination
recovery
```

예상 변경 범위:

```text
aes_session_agent.c
crypto helper .c/.h
recipe / key provisioning files
TX/RX session-agent package
Jetson → TX session-control endpoint / command parser
```

추가 제어 명령의 개념:

```text
CREATE_SECURE_SESSION
CREATE_WEAK_SESSION(seed_bits=N)
```

기존 `SW2` 키 교환 트리거와 `BTN3` 영상 정지/재키 트리거는 최종 데모 경로에서 제거한다. TX 부팅 시 Secure Session은 Jetson 없이 자동 생성하며, 위 관리 명령은 그 이후 Secure 재생성 또는 Weak override를 수행하는 유일한 정상 제어 경로로 사용한다.

Vivado 변경:

```text
TX aes_session_key_regs_bd 역할 파라미터 1줄:
ENABLE_TERMINATE_BUTTON = 0
AES-GCM/video datapath 변경 없음
```

---

## 30.2 TX Weak Key Source

현재 Normal `create_secret()`는 CSPRNG AES key를 생성한다.

최종:

```text
NORMAL
→ CSPRNG AES key

WEAK_DEMO
→ N-bit random seed
→ SHA-256("ZYBO-SEED-v1" || uint32_be(seed))
→ AES key
```

그 다음 session protocol은 동일하다.

Vivado 변경:

```text
없음
```

---

## 30.3 RX Replay Check

수정:

```text
aes-gcm-rx.c
```

추가:

- last accepted session/frame state
- serial number comparison
- replay reject counter
- GCM PASS 후 VDMA publish 전 check

Vivado 변경:

```text
없음
```

---

## 30.4 RX Telemetry

수정:

```text
aes-gcm-rx.c
```

필요하면 init/config file도 수정한다.

추가:

- rolling statistics
- telemetry JSON
- UDP sender
- Jetson destination config

Vivado 변경:

```text
없음
```

---

# 31. 이번 수정의 예상 영향도

| 작업 | Zybo PS | RTL/Vivado | 29 fps 위험 |
|---|---|---|---|
| RSA → X25519/HKDF | 중간 | 없음 | 낮음 |
| Weak key source | 낮음~중간 | 없음 | 매우 낮음 |
| RX Replay check | 낮음 | 없음 | 매우 낮음 |
| RX Telemetry | 낮음~중간 | 없음 | 낮음 |
| Jetson 2-NIC bridge | Zybo 소스 없음 | 없음 | 중간 — 반드시 성능 검증 |
| Tamper / Replay engine | Jetson | 없음 | 공격 시 의도적 영향 |
| TX BTN3 입력 비활성화 | 없음 | 역할 파라미터 1줄 | 매우 낮음 — 전체 구현/영상 회귀 검증 |
| AI 모델 변경 | 없음 | 없음 | 없음 |
| Brute-force bit 변경 | 없음 | 없음 | 없음 |
| UI 변경 | 없음 | 없음 | 없음 |

가장 큰 runtime 위험은 ECDH가 아니라:

```text
Jetson을 실제 영상 data path에 삽입하는 것
```

이다.

그 때문에 kernel bridge를 사용한다.

---

# 32. 29 fps 보호 전략

현재 정상 동작본을 **Golden Baseline**으로 보존한다.

```text
golden/
- source snapshot
- current BOOT.BIN
- current image.ub
- current system.dtb
- current bitstream/XSA
- current TX/RX binaries
- current fps/log evidence
```

새 작업은 별도 branch / 복사본에서 수행한다.

한 번에 여러 변경을 합치지 않는다.

---

# 33. 구현 순서 — 반드시 단계별 진행

## STEP 0 — Golden Baseline 고정

현재 상태 측정:

```text
TX → RX
AES ON
약 29~29.5 fps
```

최소 300 frame log 저장.

---

## STEP 1 — Jetson Transparent Bridge만 삽입

Zybo 소스 수정 없음.

```text
TX → Jetson kernel bridge → RX
```

Attack OFF.

검증:

```text
fps ≥ 29.0
packet/frame loss 지속 누적 없음
영상 정상
```

여기서 성능이 깨지면 다른 기능을 추가하지 않는다.

---

## STEP 2 — RSA → ECDH Session Layer 교체

영상 코드/RTL은 건드리지 않는다.

검증:

```text
ECDH session setup 성공
RX READY
COMMIT
DONE
TX/RX same session
영상 약 29 fps 유지
```

reset / retry / duplicate command 복구와 Jetson 관리 명령 기반 Session 재생성을 기존 RSA 안정성 기준과 동일하게 재검증한다.

---

## STEP 3 — RX Software Replay Check 추가

Attack OFF 상태에서 기존 영상 성능이 유지되는지 먼저 검증한다.

그 다음 same-session replay frame을 주입하여:

```text
GCM PASS
Replay Reject
No VDMA publish
```

확인.

---

## STEP 4 — RX Telemetry 추가

Attack OFF 상태:

```text
valid fps ≈ 29
auth reject ≈ 0
replay reject = 0
drop ratio ≈ 0
```

Jetson에서 5 Hz telemetry 수신 확인.

영상 FPS regression 확인.

---

## STEP 5 — Weak Key Source + Jetson Session Control 추가

Normal default를 절대 바꾸지 않는다.

```text
default = NORMAL SECURE
```

이 기본 Secure Session은 TX PetaLinux 부팅 후 Jetson 연결이나 명령 없이 자동 생성·활성화한다. Jetson Session Control은 부팅 이후의 Secure 재생성/Weak override에 사용한다.

TX 물리 입력으로 Weak Mode를 선택하지 않는다.

```text
SW2  → 사용하지 않음
BTN3 → 사용하지 않음
SW3  → AES-GCM ON/OFF만 유지
```

Weak Mode 진입은 Jetson UI가 TX PetaLinux로 보내는 명시적 관리 명령에서만 수행한다.

```text
CREATE_WEAK_SESSION(seed_bits=N)
```

Secure Mode 복귀:

```text
CREATE_SECURE_SESSION
```

각 명령은 새 AES key 생성 후 **Normal/Weak 모두 동일한 ECDH session path**를 통해 RX와 새 Session을 설정한다.

`WEAK_SESSION_ACTIVE` 또는 `SECURE_SESSION_ACTIVE` ACK를 받은 뒤에만 다음 데모 단계로 진행한다.

---

## STEP 6 — Jetson Tamper / Replay 연동

Tamper:

```text
selected frame modification
→ RX auth reject 증가
→ actual PC video 영향
```

Replay:

```text
old valid frame injection
→ GCM pass
→ replay reject 증가
→ actual PC video 보호
```

---

## STEP 7 — AI 연결

RX telemetry를 Jetson AI input으로 연결.

AI model은 이후 교체 가능하도록 분리한다.

기존 PC 30분 Normal dataset과 반복 공격 dataset은 PC 사전검증 evidence로 유지하며, 현재 V1 구조 확정을 위해 다시 수집할 필요가 없다. 실제 Zybo→Jetson telemetry가 연결된 뒤에는 **하드웨어 분포에 맞춘 최종 AI 재검증**만 수행한다.

---

## STEP 8 — Brute-Force 연결

실제 캡처 packet을 사용하고, 후보 판정은 **AAD 16 B + Ciphertext 1440 B + TAG 16 B 전체 GCM 인증**으로 수행한다.

```text
CPU 1T
CPU Multi
PC CUDA      → preliminary
Jetson CUDA  → final demo benchmark
```

PC와 Jetson은 동일한 core CUDA source를 각 환경에서 native build한다.

Jetson 실측 keys/s / elapsed time으로 최종 Seed Bit `N`을 결정한다.

---

# 34. 매 단계 Regression Test

모든 Zybo 수정 뒤 동일 baseline test를 반복한다.

```text
1. Secure Normal Mode
2. AES-GCM ON
3. Attack OFF
4. 300 frame 이상
5. FPS 측정
6. packet/frame loss 확인
7. RX HDMI 확인
```

Pass 기준:

```text
Target FPS ≥ 29.5
Hard Gate ≥ 29.0

지속적인 loss 누적 없음
세션 불안정 없음
HDMI freeze 없음
```

어느 단계에서 성능이 떨어지면 **그 단계의 변경만 rollback**한다.

---

# 35. V1에서 의도적으로 하지 않을 것

다음 기능은 V1에 넣지 않는다.

- PL cause-specific TAG_FAIL counter 추가
- Replay window RTL 구현
- dual-key seamless rekey
- 자동 periodic rekey
- IV reuse 공격 데모
- Jetson Python 전체 packet relay
- ARP spoof 기반 MITM
- AI attack-type classification
- ECDH private scalar brute-force
- Weak seed/key를 Jetson에 직접 전달
- Weak Mode를 기본 production mode로 사용

이 항목들을 추가하면 범위가 다시 커지고 Vivado/RTL 재검증 가능성이 높아진다.

---

# 36. 무엇이 이제 100% 고정되어야 하는가

다음 항목은 구현 시작 전에 더 이상 바꾸지 않는다.

## 시스템 구조

```text
TX → Jetson 2-NIC bridge → RX
RX → HDMI → Capture → PC
RX → Telemetry → Jetson
TX PetaLinux boot       : Auto Secure Session (Jetson 불필요)
Jetson → TX PetaLinux  : Post-boot Session Control
```

## TX 물리 입력

```text
SW3 OFF = AES-GCM OFF / Plaintext Bypass
SW3 ON  = AES-GCM ON

SW2  = 데모 기능 없음
BTN3 = 데모 기능 없음
```

최초 Secure Session은 TX 부팅 시 자동 생성한다. 그 이후 Secure / Weak Session 선택과 재키는 물리 버튼으로 하지 않고 Jetson 관리 명령으로만 수행한다.

## Packet

```text
1280 packets/frame
1440 B payload
16 B AAD
16 B TAG
1472 B UDP data
```

## Crypto

```text
AES-256-GCM
X25519 static-static + peer public-key pinning
HKDF-SHA256 session wrapping
Normal key = CSPRNG 256-bit
Weak key = SHA-256("ZYBO-SEED-v1" || uint32_be(seed))
```

## Session Control

```text
Boot default:
→ TX auto CREATE/ACTIVATE Secure Session (Jetson 명령 불필요)

Jetson UI label: RETURN TO SECURE SESSION
→ wire command: CREATE_SECURE_SESSION

Weak:
→ CREATE_WEAK_SESSION(seed_bits=N)

ACK:
→ SECURE_SESSION_ACTIVE
→ WEAK_SESSION_ACTIVE
```

최종 Seed Bit `N`은 Jetson 실측 후 결정하며 **100% 고정 항목이 아니다.**

## Tamper

```text
frame-level selection
selected frame 안에서 packet 하나 수정
TAG 유지
checksum 정상화
```

## Replay

```text
same-session old valid full frame injection
GCM PASS
software freshness check REJECT
```

## Telemetry

```text
RX → Jetson
versioned UDP telemetry
5 Hz update
1 s rolling statistics
```

## AI

```text
system behavior anomaly detection
security result counters는 AI 정답 feature로 사용하지 않음
```

---

# 37. 아직 확정하지 않아도 Zybo 작업을 시작할 수 있는 항목

다음은 **Zybo 인터페이스와 분리된 parameter**이므로 나중에 바뀌어도 된다.

- 최종 AI model
- AI anomaly threshold
- AI normalization 방식
- brute-force 최종 seed bit N
- 전시용 5개 brute-force demo point
- CPU/GPU 버튼 구성
- UI layout 세부
- red edge pulse 효과
- anomaly history chart 표현
- Tamper/Replay UI preset 값
- Jetson telemetry 수신 IP의 실제 숫자
- Jetson 내부 fault-injection 구현 방식(tc/eBPF/nftables 등)

즉 이 항목들이 아직 확정되지 않았다는 이유로 **Zybo 수정 작업을 미룰 필요는 없다.**

특히 현재 진행 중인 PC CUDA 1440 B benchmark, Jetson 최종 brute-force throughput, 최종 AI model/threshold는 **Zybo 구현의 선행조건이 아니다.** 이들은 Zybo의 고정된 packet/session/telemetry interface 위에서 병렬로 확정한다.

---

# 38. Zybo 작업 시작 판단

현재까지의 검토를 반영하면 다음 세 가지가 중요하다.

### 1. AES-GCM RTL은 다시 뜯지 않는다.

현재 핵심 암복호화 datapath와 packet format은 이미 데모 요구를 만족한다.

### 2. 신규 기능을 PS software side에 최대한 격리한다.

```text
ECDH
Weak key source
Replay freshness
Telemetry
```

모두 PetaLinux 사용자 공간 변경으로 처리한다.

### 3. 29 fps를 새 목표로 다시 만드는 것이 아니라 기존 성능을 보존한다.

현재 정상 경로가 이미 약 29 fps이므로 매 변경 후 regression을 수행한다.

---

# 39. 최종 데모 전체 동작

## Normal Secure Mode

```text
TX
PetaLinux 부팅 (Jetson 명령 불필요)
        ↓
CSPRNG AES-256 key 생성
        ↓
X25519 + HKDF
        ↓
ECDH protected session capsule
        ↓
RX
        ↓
AES-GCM secure video

TX → Jetson Bridge → RX → PC

AI
NORMAL
```

---

## Tamper Demo

```text
Jetson
Tampered Frame Rate 선택
        ↓
선택 frame 내 ciphertext 수정
        ↓
RX
GCM FAIL
        ↓
Frame Reject
        ↓
PC
실제 영상 update 감소 / freeze

RX Telemetry
        ↓
Jetson AI
NORMAL 또는 ANOMALY
```

공격이 있다는 사실과 AI anomaly는 같은 개념이 아니다.

낮은 공격률에서는 GCM reject가 발생해도 AI는 정상 범위일 수 있다.

---

## Replay Demo

```text
Jetson
Past Valid Frame 저장
        ↓
정상 traffic 중 재주입
        ↓
RX
GCM PASS
        ↓
Freshness Check FAIL
        ↓
Replay Reject
        ↓
PC
과거 frame 표시 방지
```

RX Telemetry를 AI가 분석한다.

---

## Weak-Key Brute-Force Demo

```text
Jetson UI
Seed Bit N 선택
        ↓
CREATE_WEAK_SESSION(N)
        ↓
TX PetaLinux
N-bit seed
        ↓
SHA-256
        ↓
AES-256 demo key
        ↓
정상과 동일한 ECDH session setting
        ↓
RX secure video
        ↓
WEAK_SESSION_ACTIVE ACK
        ↓
Jetson
실제 packet capture
        ↓
START BRUTE FORCE
        ↓
seed 0 ... 2^N-1
        ↓
CPU / CUDA exhaustive search
        ↓
GCM TAG match
        ↓
KEY FOUND

데모 종료
        ↓
Jetson UI
[RETURN TO SECURE SESSION]
        ↓
CREATE_SECURE_SESSION
        ↓
TX CSPRNG AES-256 key
        ↓
동일한 ECDH session setting
        ↓
SECURE_SESSION_ACTIVE
```

핵심 메시지:

> 256-bit AES key 형식을 사용하더라도 키 생성원의 entropy가 N bit라면 실제 exhaustive-search 공간은 `2^N`으로 제한된다.

---

# 40. 이 문서 이후의 변경 관리 규칙

이 문서의 목적은 계속되는 구조 변경을 막는 것이다.

앞으로 새로운 아이디어가 생기더라도 다음 질문을 먼저 확인한다.

```text
이 기능 때문에
AES-GCM RTL을 바꿔야 하는가?

Packet format을 바꿔야 하는가?

TX/RX 29fps hot path를 바꿔야 하는가?

RX telemetry contract를 바꿔야 하는가?

ECDH session protocol을 다시 바꿔야 하는가?
```

하나라도 `YES`라면 V1에는 추가하지 않는 것을 기본 원칙으로 한다.

추가 아이디어는 Jetson/UI 계층에서 해결하거나 V2 항목으로 이동한다.

---

# 41. 최종 확정 상태

```text
Zybo V1 Architecture Freeze      : CONFIRMED
AES-GCM RTL / Video Hot Path     : FREEZE
TX Physical Input                : SW3 ONLY
SW2 / BTN3 Demo Functions        : REMOVED
Boot Secure Session              : TX AUTO / JETSON NOT REQUIRED
Post-boot Secure/Weak Control    : Jetson → TX PetaLinux
Normal/Weak ECDH Session Path    : SAME
Replay Protection                : RX PS software check
RX Telemetry Contract            : FREEZE
AI Final Model                   : PENDING JETSON VALIDATION
Brute-force Final Seed Bit N     : PENDING JETSON BENCHMARK
PC 30-min Dataset Recollection   : NOT REQUIRED
Zybo Work Start                  : READY
```

AI 모델과 brute-force 최종 `N`은 아직 미확정이지만 **의도적으로 Zybo interface 밖에 둔 parameter**이므로 V1 Zybo 구현을 시작할 수 있다.

---

# 42. 최종 판단

현재 정해진 데모는 더 이상 Zybo 설계를 계속 흔들 필요가 없는 수준까지 정리할 수 있다.

핵심은:

```text
기존 AES-GCM + 약 29fps 영상 datapath
           │
           ├── 그대로 보존
           │
           ├── RSA → X25519/HKDF session layer 교체
           │
           ├── RX software replay check 추가
           │
           ├── RX telemetry sender 추가
           │
           ├── TX Weak key source 추가
           │
           ├── TX boot Secure 자동 생성
           │
           └── Jetson → TX post-boot Session Control 추가
                (Secure 재생성 / Weak override, SW2 / BTN3 데모 기능 제거, SW3만 유지)
```

이다.

Jetson의 AI 모델, brute-force bit 선정, UI 표현은 모두 이 interface 위에서 독립적으로 바꿀 수 있다.

따라서 **V1의 Zybo 작업은 위 구조를 기준으로 시작하고, 이후에는 interface contract를 바꾸지 않는 방향으로 진행한다.**
