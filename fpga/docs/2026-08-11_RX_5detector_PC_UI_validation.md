# RX 5종 PL detector + PC/Jetson UI 역할 분리 검증

작성일: 2026-08-11 KST

## 범위

이번 릴리스는 두 작업을 합친다.

1. RX의 단순 오류 상태를 과거 RSA 완성본에서 검증한 5종 detector로 교체하고, 그 결과를 Jetson이 아니라 PC로 직접 전송한다.
2. PC는 수신·감시·설명 콘솔, Jetson은 공격 제어 콘솔로 UI 역할을 분리한다.

TX의 `Pcam → PL 직접 수신/암호화 → PS` 재구성은 사용자가 지정한 다음 별도 작업이며 이번 RX 릴리스에 포함하지 않는다.

실제 Vivado 작업 위치는 이 PC의 D drive worktree 아래 다음 상대 경로다.

```text
git/vivado_25.2_win/aes/AES_GCM_RX_ECC_DEMO_260811/vivado
```

## RX 5종 detector

원본은 다음 과거 RSA 완성본의 `gcm_rx_error_detector.sv`이다.

```text
Desktop archive/3. 1차변형_RSA_구현_완성본_260805_2111_error_detector_txcamera/2. 1차변형_RSA_구현_완성본_260805_2111_error_detector/2. 1차변형_RSA_세션키_완성본
```

현재 ECC RX의 active session/key 경로에 맞춰 연결만 조정했고 판정 종류와 의미는 유지했다.

| flag/code | 실제 이름 | 판정 source |
|---:|---|---|
| bit 0 / 1 | TAG | AES-GCM core의 실제 `auth_fail_pulse` |
| bit 1 / 2 | REPLAY | 같은 frame의 packet index 재사용 또는 완료 frame 이하 재사용 |
| bit 2 / 3 | SEQUENCE | 기대 packet index 불일치 또는 미완료 frame 뒤 새 SOF |
| bit 3 / 4 | SESSION | active session 불일치, frame 중간 session 변경, magic 불일치 |
| bit 4 / 5 | TIMEOUT | key/engine 준비 상태에서 제한 시간 동안 packet 완료 없음 |

detector는 AXI4-Stream 입력을 tap으로 관찰하므로 payload, `tready`, 인증/복호, VDMA publish hot path를 구동하지 않는다. sticky flag, 5개 누계, 마지막 frame/packet/session context를 유지한다. COMMIT/CLEAR re-key 창에서는 오탐 TIMEOUT을 억제한다.

`AES_GCM_RX_bd.tcl`은 `rx_error_gpio`를 GP0 `0x41220000`에 배치한다. GPIO channel 2의 view selector로 status, 각 5종 누계, 마지막 frame/packet, 마지막 session을 읽는다.

## 전송 경로 계약과 재현성

```text
RX HDMI → USB Capture Board → PC browser video
TX/RX USB Wi-Fi → KCCI_STC_S → X25519/HKDF/capsule key exchange only
TX wired LAN → Jetson 2-NIC kernel bridge → RX wired LAN → encrypted video
RX ttyPS0 → 5-pin USB-UART → PC telemetry/event
PC_RX_UI → http://127.0.0.1:8765/ (선호값, 충돌 시 다음 빈 포트)
PC backend → JETSON_DASHBOARD_URL → Jetson actual telemetry/API
Jetson local attack console → http://127.0.0.1:4173/
```

PC telemetry wire 형식은 `ZYBO_RX_V1 <T|E> <CRC32> <JSON>`이다. PC backend는 COM 후보를 반복 열거하고 frame prefix, kind, CRC32, `source_role=zybo-rx`, `transport=uart`를 모두 통과한 장치만 RX로 채택한다. `PC_RX_UART_PORT`는 진단 override일 뿐 기본값은 자동 식별이며, `PC_RX_UART_BAUD`, `PC_RX_UI_HOST`, `PC_RX_UI_PORT`, `JETSON_DASHBOARD_URL`만 환경변수로 조정한다.

RX Linux bootargs에서 `console=ttyPS0`와 `earlycon`을 제거하고 `sysvinit-inittab`에서 `ttyPS0` getty를 제거했다. U-Boot는 계속 UART로 조작할 수 있지만 `bootm` 이후에는 RX telemetry daemon 하나만 UART를 사용한다. JTAG helper도 `bootm` 직후 COM을 닫으므로 SD/JTAG 운용이 동일하다.

Session agent는 Wi-Fi helper가 기록한 실제 wireless interface만 허용하고 ECDH discovery receiver, announcer, TCP listener/client를 그 인터페이스에 bind한다. 영상에서 학습한 wired peer 파일은 session에 사용하지 않는다. Wi-Fi가 준비되지 않으면 키 교환과 영상 활성화를 기다렸다 자동 재시도하며, 성공해 active session이 만들어진 뒤에만 영상과 UART telemetry가 유효하다.

## PC 최종 UI

1920×1080 한 화면 기준:

```text
Header 46 px
Top 320 px: RX VIDEO | SECURITY / SESSION / ATTACK / 5 DETECTORS | GEMINI
Remaining: 기존 Jetson Page 01 NORMAL FLOW
```

- 실제 video element는 498×280 px, 정확한 16:9이다.
- USB device discovery, input 선택, START VIDEO, 실제 1280×720 capture 경로를 보존했다.
- Page 01은 기존 Jetson 빌드 번들을 그대로 복사해 iframe에서 render하고 top navigation만 embed CSS로 숨긴다. 내부 카드·그래프·색상·간격·animation은 변경하지 않았고 uniform scale도 적용하지 않았다.
- SECURITY 값은 RX UART와 Jetson global attack state에서만 가져온다. fake 판정은 없다.
- 실제 TAG 누계가 증가할 때만 `GCM AUTH FAIL / FRAME BLOCKED`, REPLAY 누계가 증가할 때만 `REPLAY BLOCKED / OLD FRAME REJECTED` overlay를 약 3.2초 표시한다. 영상 corruption은 합성하지 않는다.
- Jetson 공격 상태는 PC backend가 실제 Jetson API를 poll하여 PC global border, ATTACK/SESSION, Page 01, Gemini context에 동시에 반영한다.

## Gemini 구조

```text
PC browser → PC local backend → Gemini generateContent API
```

`GEMINI_API_KEY`는 backend environment에서만 읽고 frontend bundle로 보내지 않는다. 일반 질문에는 session/encryption/attack/GCM/freshness/FPS/throughput/jitter/entropy/detector/current-event의 실제 측정 context를 전달한다. 영상 질문에서는 사용자가 `ANALYZE VIDEO`를 누른 시점의 현재 한 frame만 `inline_data`로 전달한다. Gemini는 설명만 하고 detector 판정이나 attack control을 만들지 않는다. API key 부재/장애 시 GEMINI 패널만 OFFLINE이며 VIDEO, SECURITY, NORMAL FLOW는 유지된다.

## Jetson UI

- navigation과 기본 화면만 `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH`로 변경했다.
- 기존 NORMAL FLOW component code는 번들에 남기고 Jetson navigation에서만 제거했다.
- Integrity/Weak-Key 내부 component, control, graph, card, typography, spacing, animation, backend attack logic은 변경하지 않았다.
- 실제 서비스 포트는 `4173`이다. 이전 작업 메모의 `8088`은 현재 실행 구성과 다르다.

## 검증 기록

- Vivado xsim detector directed test: TAG/REPLAY/SEQUENCE/SESSION/TIMEOUT, sticky clear, re-key/timeout, `PASS=12, FAIL=0`.
- RX C host compile/link와 `--self-test`: replay freshness, wraparound, duplicate rejection, interleaved frame, timeout, session reset PASS.
- PC backend Python compile/self-test와 frontend JavaScript syntax check PASS.
- UART encoder/decoder self-test에서 정상 CRC frame, 손상 frame 거부, RX 역할 확인, event 중복 제거와 `/api/state` model을 검증했다. 제품 UI에는 fake telemetry generator가 없다.
- Gemini key가 없는 상태에서 API failure를 발생시켜 GEMINI 패널만 실패하고 core UI와 Page 01이 계속 poll/render함을 확인했다.
- PC와 Jetson 01/02 모두 1920×1080에서 body overflow 0, browser console error 0, framework error overlay 0을 확인했다.
- Jetson 실제 `http://100.72.159.6:4173/api/telemetry/latest` 응답과 두 공격 화면 render를 확인했다.

## 최종 릴리스 결과

- RX Vivado implementation: routed/DRC clean, WNS `+0.014 ns`, WHS `+0.015 ns`.
- RX BIT SHA-256: `665EE9179722A338D145C80525B337B49A48F1DE9B4B76E841FBA69217AF3928`.
- RX XSA SHA-256: `E92DDCB64E0B69D52925F7E0DB653007129B4BA308472A978F7605175977B835`.
- TX/RX PetaLinux build와 JTAG RAM boot 완료. TX `10.10.15.2`, RX `10.10.15.3`, session `0x748764a3`에서 actual secure video `29.5~29.9 fps`, queue overrun/stale/status failure `0` 확인.
- 기존 실기 검증의 Wi-Fi/UDP telemetry 결과는 이번 UART 변경 이전 기록이다. 새 RX/TX image는 BitBake, initramfs 추출, host mock까지 통과했으며 UART·Wi-Fi·유선 영상 3경로의 새 실기 검증은 JTAG 배포 후 수행한다.
- Jetson Integrity Attack 20%를 약 20초 실기 실행해 ciphertext packet `160`개 변조, RX TAG detector/auth reject `160` 누적을 확인했다. 공격 중지 후 29 fps class secure video와 ATTACK NONE으로 복귀했다.
- Weak-Key Search는 이전 live weak session의 full 128-bit GCM tag 검증과 recovered 1280×720 frame 표시를 확인했다.
- `verify_release.ps1 -Quiet`: `RELEASE_VERIFY_PASS`, TX/RX coherent, `235` checks.
- session crypto/recovery/init/Wi-Fi test suite, PC backend self-test, Jetson/PC Python compile, frontend JavaScript syntax, 1920×1080 browser layout/console 검증 PASS.
- Jetson HTML은 `no-store`로 제공하고 dashboard 실행 때 local `127.0.0.1:4173` kiosk를 재시작하므로 이전 번들이 화면에 남지 않는다.

## 산출물 화면

- `PC_RX_UI/validation/pc_console_1920x1080.png`
- `PC_RX_UI/validation/jetson_01_integrity_1920x1080.png`
- `PC_RX_UI/validation/jetson_02_weak_key_1920x1080.png`
- `Desktop/PC UI/PC_UI_통합화면.png`
- `Desktop/젯슨 UI/01_INTEGRITY_ATTACK_젯슨실화면.png`
- `Desktop/젯슨 UI/01_INTEGRITY_ATTACK_동작중_젯슨실화면.png`
- `Desktop/젯슨 UI/02_WEAK_KEY_SEARCH_젯슨실화면.png`
