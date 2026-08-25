# 3-2 AES-GCM 영상 송수신 데모 — TX PL 직결

이 폴더는 3-1의 차분 파일 모음이 아니라 TX, RX, PC UI, Jetson UI, 세션 제어, JTAG 및 SD 산출물을 모두 포함한 독립 프로젝트다.

## 최종 구조

```text
Pcam MIPI
  → TX PL 16-bit YUYV
  → TX PL AES-256-GCM
  → TX VFB Write
  → TX DDR(암호문 프레임)
  → TX PS UDP
  → Jetson NIC 1
  → Jetson Linux kernel bridge
  → Jetson NIC 2
  → RX 유선 LAN
  → RX 인증·복호화·5종 오류 검출
  → RX HDMI → 캡처보드 → PC

RX 5핀 UART → PC 보안/텔레메트리 UI
TX/RX USB Wi-Fi 동글 → KCCI_STC_S 키 교환 전용
Jetson UI → 01 INTEGRITY ATTACK / 02 WEAK-KEY SEARCH
```

TX의 암호화 전 카메라 평문 프레임은 DDR에 기록되지 않는다. 제거된 `axi_dma_gcm_tx`, `S_AXI_ACP`, `/dev/pcam_aes_bridge` 경로를 사용하지 않는다. SW3 plaintext 데모 모드를 명시적으로 선택한 경우만 예외다.

## 자동 시작과 환경 독립성

- TX/RX는 부팅 순서와 무관하게 USB Wi-Fi 인터페이스를 역할과 실제 링크 상태로 찾고 키 교환을 재시도한다.
- TX는 RX의 인증된 counter floor를 받아 더 큰 counter로 새 secure session을 만든다.
- 세션 상태 기본 경로는 루트파일시스템의 `/var/lib/aes-session`이다. SD 라벨, automount 이름, PC 경로에 의존하지 않는다.
- 키 교환은 USB Wi-Fi 인터페이스에만 bind한다. 유선 영상 peer 정보를 키 교환에 재사용하지 않는다.
- 영상망의 `10.10.15.2/24`(TX), `10.10.15.3/24`(RX)와 고정 MAC은 외부 Wi-Fi 환경값이 아니라 Jetson 양쪽 NIC 사이의 폐쇄형 L2 영상망 역할 주소다.
- PC UI는 COM 번호를 고정하지 않고 `ZYBO_RX_V1`, CRC32, `source_role=zybo-rx`를 만족하는 UART를 자동 탐색한다.
- PC가 Jetson에 접속할 때는 Tailscale을 사용할 수 있지만, 실제 영상·RX 텔레메트리 동작은 PC Wi-Fi나 Tailscale에 의존하지 않는다.

## UI 역할

- PC: `RX VIDEO | SECURITY | GEMINI`와 기존 `NORMAL FLOW`
- Jetson: `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH`
- RX 보안 정보는 5핀 UART로 PC에만 보낸다. Jetson 02는 RX 텔레메트리를 기다리지 않고 유선 중계 구간에서 직접 캡처한 TX 암호 패킷으로 동작한다.

## SD 카드

TX와 RX 각각의 `sd_card` 폴더에 있는 아래 8개 파일을 해당 SD 카드의 FAT32 첫 파티션 루트에 모두 복사한다.

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

복사 후 `SHA256SUMS`를 검증한다. 별도 ext4 두 번째 파티션이나 특정 SD 볼륨 이름은 필수가 아니다.

## 주요 경로

- `AES_GCM_TX/`: 3-2 TX PL 직결 Vivado/PetaLinux/JTAG/SD 전체본
- `AES_GCM_RX/`: 5종 오류 검출기가 포함된 RX 전체본
- `PC_RX_UI/`: HDMI 캡처와 RX UART 보안 정보를 표시하는 PC UI
- `Jetson_Dashboard/`: 01/02 공격 전용 Jetson UI와 백엔드
- `session_control/`: TX/RX 공통 세션 프로토콜 기준 소스
- `docs/2026-08-12_3-2_FINAL_JTAG_SD_validation.md`: 최종 빌드·JTAG·SD 검증 기록

## 최종 상태

2026-08-12 실기 검증에서 새 3-2 TX를 JTAG RAM 부팅한 직후 RX counter floor 6을 인증하고 counter 7, secure session `0x8e332bbf`를 생성했다. PC UART에서 29.9~30.9 fps, 인증 거부 0을 확인했다. 이후 Weak Session 생성·라이브 레코드 캡처·CUDA seed 탐색·AES-GCM tag 검증과 secure 복귀도 통과했다.

같은 날 RX 최종 SD도 갱신했다. AP가 클라이언트 브로드캐스트를 막는 환경에서는 현재 DHCP 인터페이스의 주소와 넷마스크로 제한된 유니캐스트 복구를 병행하며, TX/RX 주소를 고정하지 않는다. TX를 켜 둔 채 RX만 SD 재부팅한 실기 시험에서 secure session `0x6244953a`가 자동 생성됐고 PC UI가 역할 프레임으로 `COM12`를 자동 식별해 약 27~31 fps, 현재 인증 거부율 0을 표시했다.

내일 SD로 사용할 때 3-2의 전체 릴리스 검증과 실기 결과가 유지되면 이 폴더를 사용한다. 문제가 생기면 완전히 별도로 보존된 3-1 SD 산출물을 사용한다.
