# AES-GCM 수신부 복호화 및 HDMI 출력 설계 요구사항 — 최신본

## 0. 결론

송신부의 최종 UDP packet은 다음과 같다.

```text
[Exact AAD/Header 16 B]
[Plaintext 또는 Ciphertext Payload 1440 B]
[TAG Field 16 B]
= UDP Data 1472 B
```

수신부는 이 packet을 PetaLinux에서 수신·정렬한 뒤 AXI DMA로 PL의 AES-GCM RX에 전달한다. AES-GCM RX가 만든 **인증 완료 평문 프레임만 DDR 표시 버퍼에 저장**하고, AXI VDMA MM2S가 그 평문 프레임을 HDMI 타이밍으로 읽는다.

```text
Ethernet
→ PS PetaLinux UDP 수신
→ 1280 packet/frame 수신·정렬
→ Network Packet Frame Buffer
→ AXI DMA MM2S
→ AES-GCM RX / Plaintext bypass
→ AXI DMA S2MM
→ Authenticated Plaintext Frame Buffer
→ AXI VDMA MM2S
→ YUYV-to-RGB
→ HDMI
```

VDMA는 암호 packet을 처리하는 DMA가 아니라, **완성된 평문 영상 프레임을 DDR에서 연속적으로 읽어 HDMI로 출력하는 마지막 구간**에 사용한다.

---

# 1. 수신 UDP packet 처리

## 1.1 입력 packet

| 구간 | 크기 |
|---|---:|
| Exact AAD/Header | 16 B |
| Payload | 1440 B |
| TAG Field | 16 B |
| UDP Data 합계 | 1472 B |
| 128-bit block 수 | 92 blocks |

128-bit 기준 packet 배치는 다음과 같다.

```text
block 0      : AAD 128 bit
block 1~90   : Payload 90 × 128 bit
block 91     : TAG 128 bit
```

## 1.2 AAD/Header 해석

```text
magic         32 bit
session_id    32 bit
frame_id      32 bit
packet_index  16 bit
flags         16 bit
```

수신 프로그램은 다음 항목을 검사한다.

- `magic` 일치
- `packet_index`가 0~1279 범위
- 같은 frame의 `session_id`, `frame_id`, mode가 동일
- packet 중복 및 누락 여부
- UDP Data 길이가 정확히 1472 B
- `flags.encrypted`가 표시하는 TX 전송 mode가 같은 frame 내에서 일관되는지

96-bit Nonce는 송신부와 동일하게 재구성한다.

```text
Nonce = session_id | frame_id | zero_extend(packet_index)
```

## 1.3 프레임 수신 버퍼

PetaLinux는 packet을 `packet_index` 위치에 정렬한다.

```text
packet_record_address
= frame_base + packet_index × 1472 B
```

한 frame의 network packet record 크기는 다음과 같다.

```text
1280 × 1472 B
= 1,884,160 B/frame
```

한 frame의 1280개 packet이 모두 수신된 경우에만 PL 복호화 단계로 넘긴다. 누락 packet이 있는 frame은 폐기한다.

---

# 2. 수신부 DMA와 VDMA 역할

## 2.1 Network DDR → AES-GCM RX

Network packet record는 AAD와 TAG가 포함된 일반 packet 데이터이며 영상 프레임이 아니다. 따라서 이 구간에는 AXI DMA MM2S를 사용한다.

```text
Network Packet Frame Buffer
1,884,160 B
→ AXI DMA MM2S
→ AES-GCM RX
```

AXI DMA MM2S는 packet record 1280개를 128-bit AXI4-Stream으로 공급한다.

## 2.2 AES-GCM RX → Plaintext DDR

AES-GCM RX의 출력은 packet당 정확히 1440 B이다.

```text
1280 × 1440 B
= 1,843,200 B/frame
```

출력은 AXI DMA S2MM을 통해 평문 표시용 DDR frame buffer에 기록한다.

```text
AES-GCM RX Plaintext AXIS
→ AXI DMA S2MM
→ Plaintext Frame Buffer
```

## 2.3 Plaintext DDR → HDMI

완성되고 유효하다고 판정된 평문 frame만 AXI VDMA MM2S가 읽는다.

```text
Authenticated Plaintext Frame Buffer
→ AXI VDMA MM2S
→ AXI4-Stream YUYV
→ YUYV-to-RGB
→ AXI4-Stream to Video Out
→ HDMI
```

VDMA 설정 기준은 다음과 같다.

| 항목 | 값 |
|---|---:|
| HSIZE | 2560 B |
| STRIDE | 2560 B |
| VSIZE | 720 lines |
| Frame size | 1,843,200 B |
| Pixel format | YUYV 16 bit/pixel |

최소 double buffer가 필요하며, 네트워크 지터와 화면 출력의 독립성을 위해 triple buffer가 권장된다.

---

# 3. AES-GCM RX 모듈 구성

## 3.1 최종 RTL 계층

```text
video_aes_gcm_rx_top
├─ rx_packet_parser
├─ mode_controller
├─ aad_nonce_context
├─ plaintext_bypass
├─ gcm_rx_engine
│  ├─ aes256_core
│  ├─ ghash_engine
│  ├─ tag_compare
│  └─ authenticated_packet_buffer
├─ frame_status_controller
└─ plaintext_video_output
```

## 3.2 모듈별 역할

| 모듈 | 역할 |
|---|---|
| `video_aes_gcm_rx_top` | 92-block packet 입력과 90-block 평문 출력 통합 |
| `rx_packet_parser` | AAD, payload, TAG 위치 분리 |
| `mode_controller` | frame 시작에 RX SW3를 래치해 bypass/decrypt 선택 |
| `aad_nonce_context` | AAD 보존 및 96-bit Nonce 재구성 |
| `plaintext_bypass` | 평문 mode의 payload를 그대로 출력 |
| `gcm_rx_engine` | AES-CTR 복호화, GHASH, TAG 검증 |
| `authenticated_packet_buffer` | TAG 판정 전 1440 B 평문 임시 보관 |
| `frame_status_controller` | packet 오류를 frame 단위 valid/fail로 누적 |
| `plaintext_video_output` | packet당 90개의 128-bit 평문 출력 |

수신 보드의 실제 처리 mode는 frame 시작에 래치한 로컬 RX SW3로 결정한다. SW3 OFF는 수신 payload를 bypass하고, ON은 AES-GCM 복호화와 TAG 인증을 수행한다. `flags.encrypted`는 TX가 선택한 전송 mode를 표시하여 packet/frame 일관성 검사에 사용하지만 RX SW3를 대신해 bypass/decrypt를 선택하지는 않는다.

SW3 OFF/ON 모드 모두 RSA 교환으로 설치된 active session, `key_ready=1`, 수신 packet session ID와 PL active session ID의 일치 및 frame ACQUIRE가 선행되어야 영상 DMA를 시작한다. SW3 OFF는 session gate를 우회하는 keyless 평문 fallback이 아니다. BTN3 hold 또는 keyless 상태에서는 새 프레임을 처리하지 않고 VDMA가 마지막 완료 화면을 유지한다.

---

# 4. 평문 및 암호화 mode 동작

## 4.1 평문 mode

```text
AAD block
→ header 검사

Payload 90 blocks
→ 그대로 Plaintext output

TAG Field
→ 16 B zero 여부 확인 또는 무시
```

출력은 packet당 1440 B, frame당 1,843,200 B이다.

## 4.2 암호화 mode

```text
AAD block
→ GHASH AAD 입력

Ciphertext 90 blocks
├─ AES-CTR 복호화
└─ GHASH Ciphertext 입력

TAG block
→ 계산 TAG와 비교
```

GHASH에는 복호화 평문이 아니라 수신된 Ciphertext를 입력한다.

---

# 5. 인증 전 평문 출력 방지

GCM TAG 결과는 packet 마지막에서 확정된다. 따라서 복호화 중간 결과를 즉시 표시용 DDR에 기록하면 안 된다.

packet당 1440 B 평문을 임시 보관한다.

```text
Ciphertext 1440 B
→ AES-CTR decrypt
→ Authenticated Packet Buffer 1440 B
→ TAG compare
```

| 결과 | 출력 |
|---|---|
| `auth_ok` | 보관한 Plaintext 1440 B 출력 |
| `auth_fail` | Plaintext 출력 금지, zero packet 1440 B 출력 및 frame_fail 설정 |

zero packet을 출력하는 이유는 한 frame의 AXI DMA S2MM 길이를 항상 1,843,200 B로 유지하기 위해서이다. `frame_fail`이 발생한 destination frame은 표시 대상으로 등록하지 않고 폐기한다.

어떤 경우에도 인증에 실패한 복호화 평문을 VDMA 표시 버퍼로 승인하지 않는다.

---

# 6. 프레임 완성 및 HDMI 표시 조건

수신 frame은 다음 조건을 모두 만족해야 `DISPLAY_READY` 상태가 된다.

```text
1280 packet 모두 수신
AND packet index 중복·누락 없음
AND 모든 암호 packet auth_ok
AND session_id/frame_id/mode 일치
AND AXI DMA S2MM frame write 완료
```

frame state는 다음과 같이 관리한다.

```text
EMPTY
→ RECEIVING
→ DECRYPTING
→ AUTHENTICATED_COMPLETE
→ DISPLAYING
→ EMPTY
```

한 packet이라도 유실되거나 `auth_fail`이면 해당 frame은 폐기하고, VDMA는 직전 정상 frame을 계속 표시한다.

---

# 7. 수신 AES-GCM 처리율 요구사항

수신 AES-GCM은 송신부와 동일한 150 MHz 처리 조건을 적용한다.

| 항목 | 요구조건 |
|---|---:|
| RX 동작 클럭 | 150 MHz |
| 입력 packet | 92 × 128-bit block |
| payload | 90 × 128-bit block |
| AES-256 II | 15 이하 |
| GHASH II | 16 이하 |
| 통합 AES-GCM II | 16 이하 |
| packet 실효 처리율 | 약 1.171 Gbps 이상 |
| 출력 | packet당 1440 B |
| 인증 결과 | packet당 `auth_ok/auth_fail` 1회 |

AES와 GHASH는 다음처럼 중첩한다.

```text
AES-CTR:
현재 Ciphertext block 복호화

GHASH:
이전 Ciphertext block 인증 계산
```

완전 직렬 `AES 15 cycle + GHASH 16 cycle` 구조는 약 619 Mbps로 활성 영상 입력 요구량 약 672 Mbps보다 낮으므로 사용하지 않는다.

---

# 8. 수신부 최종 블록 구조

```text
┌──────────────────────── PS ────────────────────────┐
│ GEM0 / Linux UDP Receiver                         │
│ → UDP Data 1472 B 검사                            │
│ → AAD/Payload/TAG 보존                            │
│ → packet_index 기준 정렬                          │
│ → 1280 records/frame                              │
│ → Network Packet Frame Buffer 1,884,160 B          │
└──────────────────────┬────────────────────────────┘
                       │ AXI DMA MM2S
┌──────────────────────▼────── PL 150 MHz ──────────┐
│ video_aes_gcm_rx_top                              │
│ ├─ AAD/Payload/TAG parser                         │
│ ├─ Plaintext bypass                               │
│ ├─ AES-256 CTR decrypt                            │
│ ├─ GHASH                                          │
│ ├─ TAG compare                                    │
│ ├─ Authenticated Packet Buffer 1440 B             │
│ └─ frame_valid/frame_fail                         │
└──────────────────────┬────────────────────────────┘
                       │ AXI DMA S2MM
┌──────────────────────▼────── DDR ─────────────────┐
│ Authenticated Plaintext Frame A                   │
│ Authenticated Plaintext Frame B                   │
│ Authenticated Plaintext Frame C                   │
└──────────────────────┬────────────────────────────┘
                       │ valid frame only
                 AXI VDMA MM2S
                       │
┌──────────────────────▼────── PL Video ────────────┐
│ YUYV-to-RGB                                       │
│ → AXI4-Stream to Video Out                        │
│ → Video Timing Controller                         │
│ → HDMI                                            │
└───────────────────────────────────────────────────┘
```

## 최종 IP 선택

| 구간 | 데이터 성격 | 적합한 IP |
|---|---|---|
| UDP packet DDR → AES-GCM RX | AAD/Payload/TAG 일반 packet | AXI DMA MM2S |
| AES-GCM RX → 평문 frame DDR | 인증 결과 평문 stream | AXI DMA S2MM |
| 평문 frame DDR → HDMI | 완성된 영상 frame 반복 출력 | AXI VDMA MM2S |
