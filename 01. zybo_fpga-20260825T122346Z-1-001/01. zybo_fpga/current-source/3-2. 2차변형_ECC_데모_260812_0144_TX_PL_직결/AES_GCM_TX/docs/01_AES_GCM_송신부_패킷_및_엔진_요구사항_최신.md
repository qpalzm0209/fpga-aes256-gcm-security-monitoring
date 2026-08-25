# AES-GCM 송신부 패킷 및 암호화 엔진 설계 요구사항 — 최신본

## 0. 현재 1차 구조도 검토 결과

현재 구조도의 주 데이터 경로는 송신부 요구사항과 일치한다.

```text
Pcam
→ CSI-2 RX
→ YUYV AXI4-Stream
→ SW3 선택형 AES-GCM TX
   ├─ SW3 OFF: Plaintext bypass
   └─ SW3 ON : AES-256-GCM Ciphertext 생성
→ Video Frame Buffer Write
→ AXI HP0
→ DDR
→ V4L2
→ PetaLinux UDP 송신기
→ GEM0
→ Ethernet
```

SW3는 세션 시작/복구 제어가 아니다. OFF/ON 모드 모두 RSA 교환으로 설치된 active session, `key_ready=1`, session ID 일치 및 frame ACQUIRE가 선행되어야 영상 DMA를 시작한다. SW3 OFF는 이 세션 gate를 우회하지 않고 AES/GHASH payload 처리만 bypass한다. BTN3를 누르고 있거나 키가 없으면 SW3 위치와 무관하게 새 프레임을 시작하지 않는다.

SW3에 따라 DDR에 저장되는 내용은 다음과 같다.

| SW3 | Frame Buffer Write 입력 | DDR/V4L2 버퍼의 실제 내용 | 한 프레임 크기 |
|---|---|---|---:|
| OFF | YUYV Plaintext | 실제 YUYV 평문 영상 | 1,843,200 B |
| ON | Ciphertext byte stream | 형식상 YUYV 버퍼로 관리되는 암호문 배열 | 1,843,200 B |

다음 항목은 현재 구조도에서 최신 요구사항으로 수정해야 한다.

1. PetaLinux UDP 송신기는 AAD를 독립적으로 새로 만들지 않고, **PL이 TAG 계산에 실제 사용한 AAD 16 B와 TAG 16 B를 metadata buffer에서 그대로 취득**한다.
2. 기존 사용자 헤더에는 `session_id`가 없으므로, 96-bit Nonce를 재구성할 수 있도록 **AAD/Header 16 B의 필드 구성을 최종 확정**해야 한다.
3. TAG만 저장하면 프레임당 20,480 B지만, 권장 구조처럼 `AAD 16 B + TAG 16 B`를 함께 저장하면 **metadata는 프레임당 40,960 B**이다.
4. 평문 모드도 UDP parser를 동일하게 유지하기 위해 TAG 영역 16 B를 유지하고 `0`으로 채운다.

---

# 1. 송신부 영상 경로와 Frame Buffer Write

## 1.1 AES-GCM 삽입 위치

AES-GCM TX는 CSI RX가 출력한 YUYV 영상 스트림과 Video Frame Buffer Write 사이에 배치한다.

```text
CSI RX
→ YUYV 16-bit AXI4-Stream
→ 16→128-bit 변환
→ AES-GCM TX Wrapper
→ 128→16-bit 변환
→ Video Frame Buffer Write
```

메인 AXI4-Stream에는 평문 또는 Ciphertext payload만 출력한다. AAD와 TAG는 Frame Buffer Write로 전달하지 않는다.

```text
메인 영상 경로:
Plaintext 또는 Ciphertext

별도 metadata 경로:
AAD + TAG + valid/status
```

## 1.2 영상 프레임 크기

720p YUYV 한 프레임은 다음과 같다.

```text
1280 × 720 × 2 B
= 1,843,200 B
```

한 라인은 다음과 같다.

```text
1280 × 2 B
= 2,560 B
```

암호화 모드에서도 AES-CTR에 의해 payload 길이가 유지되므로 Frame Buffer Write와 V4L2의 프레임 크기는 변하지 않는다.

## 1.3 영상 AXI 프레이밍

| 신호 | 영상 의미 | 요구사항 |
|---|---|---|
| `TUSER` | 한 영상 프레임 시작 | 암호화 지연 후에도 첫 출력 블록과 정렬 |
| `TLAST` | 한 영상 라인 끝 | 2,560 B 라인 끝과 정렬 |
| `TKEEP` | 유효 바이트 | 입력과 동일하게 보존 |
| `TVALID/TREADY` | AXI handshake | 데이터와 sideband를 함께 정지·진행 |

GCM packet 경계는 `TLAST`가 아니라 1440 B마다 발생한다. 영상 라인은 2,560 B이므로 packet 경계와 line 경계는 일반적으로 일치하지 않으며, `TLAST`는 별도 sideband로 보존한다.

---

# 2. 최종 AES-GCM 및 UDP 패킷 구조

## 2.1 GCM payload 단위

현재 AES-GCM payload는 128-bit 블록 90개로 구성한다.

```text
90 × 128 bit
= 90 × 16 B
= 1,440 B
```

영상과의 관계는 다음과 같다.

| 항목 | 값 |
|---|---:|
| 한 GCM payload | 1,440 B |
| 한 영상 라인 | 2,560 B |
| line/packet 경계 | 9 lines = 16 packets = 23,040 B마다 재정렬 |
| 한 영상 프레임 | 1,843,200 B |
| 프레임당 packet | 1,280개 |
| packet index | 0~1279 |

모든 packet의 payload 길이는 1440 B로 동일하며 마지막 packet 예외 처리가 없다.

## 2.2 최종 UDP Data 형식

평문과 암호화 모드 모두 동일한 UDP Data 크기를 사용한다.

```text
[AAD/Header 16 B]
[Plaintext 또는 Ciphertext Payload 1440 B]
[TAG Field 16 B]
```

| 모드 | Payload | TAG Field |
|---|---|---|
| SW3 OFF | Plaintext 1440 B | 16 B 전체를 0으로 설정 |
| SW3 ON | Ciphertext 1440 B | 계산된 GCM TAG 16 B |

총길이는 다음과 같다.

```text
16 B + 1440 B + 16 B
= UDP Data 1472 B
```

네트워크 계층을 포함하면 다음과 같다.

```text
IPv4 Header  20 B
UDP Header    8 B
UDP Data   1472 B
-----------------
IPv4 Packet 1500 B
```

Ethernet MTU 1500 B 기준 여유는 다음과 같다.

```text
1500 B - 1500 B
= 0 B
```

Ethernet header와 FCS까지 포함한 선로상의 Ethernet frame 크기는 다음과 같다. 단, preamble, SFD, IFG는 제외한 값이다.

```text
Ethernet Header 14 B
IPv4 Packet    1500 B
Ethernet FCS      4 B
--------------------
Ethernet Frame 1518 B
```

## 2.3 최종 AAD/Header 16 B

현재 고정 규격은 720p YUYV, payload 1440 B, packet 1280개이므로 `packet_count`와 `payload_bytes`를 매 packet마다 반복 전송할 필요가 없다.

권장 최종 AAD/Header는 다음과 같다.

```text
magic         32 bit
session_id    32 bit
frame_id      32 bit
packet_index  16 bit
flags         16 bit
--------------------
합계         128 bit = 16 B
```

| 필드 | 용도 |
|---|---|
| `magic` | 프로토콜 및 packet 식별 |
| `session_id` | 세션 구분 및 Nonce 재사용 방지 |
| `frame_id` | 영상 프레임 순번 |
| `packet_index` | 프레임 내 0~1279 |
| `flags` | encrypted, SOF, EOF, protocol version 등 |

전송 바이트 순서는 network byte order로 고정한다. GCM이 인증하는 AAD는 **실제로 UDP에 들어가는 이 16바이트 배열과 완전히 동일해야 한다.**

## 2.4 Nonce 구성

96-bit Nonce는 packet마다 다음과 같이 재구성한다.

```text
Nonce[95:64] = session_id
Nonce[63:32] = frame_id
Nonce[31:0]  = zero_extend(packet_index)
```

따라서 Nonce 12 B는 UDP packet에 별도로 넣지 않는다.

같은 AES key를 유지하는 동안 `session_id`, `frame_id`, `packet_index` 조합이 반복되지 않아야 한다. 보드 재부팅 또는 새 전송 세션에서는 `session_id`를 변경한다.

## 2.5 Metadata record

PL은 packet마다 다음 metadata를 별도 출력한다.

```text
Exact AAD/Header 16 B
GCM TAG          16 B
---------------------
Metadata record  32 B
```

AAD 안에 `session_id`, `frame_id`, `packet_index`, `flags`가 포함되므로 동일 필드를 다시 중복 저장할 필요는 없다. FIFO 또는 metadata buffer의 sideband로 `valid`, `error`, `frame_done` 등을 둘 수 있다.

한 프레임 metadata 크기는 다음과 같다.

```text
1280 × 32 B
= 40,960 B/frame
```

TAG만 계산한 값은 20,480 B/frame이지만, UDP 송신기가 PL과 정확히 같은 AAD를 사용하도록 하려면 AAD와 TAG를 함께 저장하는 것이 안전하다.

---

# 3. AES-GCM TX 모듈 구성 및 성능 요구사항

## 3.1 최종 RTL 계층

```text
video_aes_gcm_tx_top
├─ sw3_mode_controller
├─ video_packet_controller
├─ bypass_path
├─ aad_nonce_generator
├─ gcm_tx_engine
│  ├─ aes256_core
│  ├─ ghash_engine
│  └─ tag_generator
├─ video_payload_output
└─ metadata_output
```

## 3.2 모듈별 역할

| 모듈 | 역할 |
|---|---|
| `video_aes_gcm_tx_top` | Vivado 영상 경로에 연결되는 통합 top |
| `sw3_mode_controller` | SW3 OFF bypass / SW3 ON encryption 선택 |
| `video_packet_controller` | 90개의 128-bit block을 packet 하나로 관리 |
| `bypass_path` | 1440 B payload를 변경 없이 출력 |
| `aad_nonce_generator` | packet별 exact AAD와 96-bit Nonce 생성 |
| `gcm_tx_engine` | Ciphertext와 TAG 계산 |
| `aes256_core` | AES-256 CTR keystream 계산 |
| `ghash_engine` | AAD와 Ciphertext 인증 계산 |
| `video_payload_output` | Frame Buffer Write 방향으로 payload만 출력 |
| `metadata_output` | exact AAD와 TAG를 별도 출력 |

기존 `aes256_gcm_tx_top`이 `[AAD][Ciphertext][TAG]`를 하나의 스트림으로 직렬 출력한다면, 영상 통합용 top에서는 그 출력을 다음처럼 분리한다.

```text
Video AXI output:
90 × 128-bit Plaintext 또는 Ciphertext

Metadata output:
1 × 128-bit AAD
1 × 128-bit TAG
```

## 3.3 SW3 동작

이 절의 bypass/encrypt 선택은 유효한 active session 내에서만 적용된다. SW3 OFF는 keyless 또는 BTN3 종료 상태의 비상 평문 fallback이 아니다.

```text
SW3 OFF:
입력 YUYV payload
→ bypass
→ 동일 길이 Plaintext 출력
→ exact AAD + zero TAG metadata 생성

SW3 ON:
입력 YUYV payload
→ AES-256-GCM
→ 동일 길이 Ciphertext 출력
→ exact AAD + calculated TAG metadata 생성
```

SW3 상태는 packet 또는 frame 중간에 변경되지 않도록 영상 프레임 시작에서 래치하고 해당 프레임이 끝날 때까지 유지한다.

## 3.4 150 MHz 기준 처리율

720p30 YUYV 평균 데이터율은 다음과 같다.

```text
1280 × 720 × 16 bit × 30 fps
= 442.368 Mbps
```

센서 활성 영상 구간의 순간 입력 요구량은 약 672 Mbps이며, Ethernet은 1GbE이다. 따라서 암호화 엔진의 지속 처리율 목표는 1 Gbps 이상으로 둔다.

128-bit block 처리율은 다음과 같다.

```text
Throughput = 128 bit × Fclk / II
```

| 연산 | II | 150 MHz raw 처리율 |
|---|---:|---:|
| AES-256 iterative | 15 | 1.280 Gbps |
| GHASH | 16 | 1.200 Gbps |

AES와 GHASH를 완전 직렬로 수행하면 `II≈31`이 되어 약 619 Mbps로 떨어진다. 따라서 다음과 같이 중첩한다.

```text
AES:
현재 Plaintext block 처리

GHASH:
이전 Ciphertext block 처리
```

통합 AES-GCM의 목표 II는 다음과 같다.

```text
II ≤ max(15, 16)
II ≤ 16
```

AAD 1블록, Ciphertext 90블록, 길이 블록 1개를 모두 포함한 packet 실효 처리율은 다음과 같다.

```text
1440 B × 8 × 150 MHz / (92 × 16)
≈ 1.174 Gbps
```

| 최종 요구사항 | 값 |
|---|---:|
| AES-GCM 동작 클럭 | 150 MHz |
| packet payload | 1440 B |
| payload block | 90 × 128 bit |
| AES II | 15 이하 |
| GHASH II | 16 이하 |
| 통합 II | 16 이하 |
| packet 실효 처리율 | 약 1.174 Gbps 이상 |
| Ciphertext 출력 길이 | 입력 payload와 동일 |
| TAG | packet당 128 bit 1개 |

## 3.5 PetaLinux UDP 송신기

PetaLinux UDP 송신기는 다음 순서로 동작한다.

```text
1. V4L2에서 1,843,200 B frame dequeue
2. frame을 1440 B 단위로 1280개 분할
3. 동일 frame_id의 metadata record 1280개 취득
4. packet_index별로 payload와 metadata를 대응
5. [Exact AAD 16 B][Payload 1440 B][TAG 16 B] 조립
6. UDP GSO 또는 sendmmsg()로 전송
```

PetaLinux가 AAD를 별도의 counter로 재생성하면 PL의 frame/packet counter와 어긋날 수 있으므로, **metadata buffer에서 exact AAD bytes를 직접 읽는 구조를 기준으로 한다.**

V4L2 frame과 metadata frame의 `frame_id`가 일치하지 않으면 해당 frame을 전송하지 않는다.

## 3.6 현재 구조도에 반영할 최종 문구

### AES-GCM TX에서 PS 방향

```text
Packet Metadata Buffer

record = Exact AAD 16 B + TAG 16 B
1280 records/frame
40,960 B/frame
```

### PetaLinux UDP 송신기 내부

```text
V4L2 frame을 1440 B 단위로 분할
→ exact AAD/TAG metadata 취득
→ [AAD 16 B][Payload 1440 B][TAG 16 B] 조립
→ UDP GSO send()
```

### Ethernet 출력

```text
UDP packet 0
...
UDP packet 1279

UDP Data: 1472 B
IPv4 Packet: 1500 B
MTU 여유: 0 B
```
