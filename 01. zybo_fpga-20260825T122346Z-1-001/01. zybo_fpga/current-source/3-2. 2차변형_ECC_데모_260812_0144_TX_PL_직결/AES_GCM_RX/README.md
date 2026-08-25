# AES_GCM_RX — PL 5종 오류 검출 + PC 01 UI

기본 영상·세션 계약은 [`../docs/ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md`](../docs/ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md)를 따르고, 최신 RX detector/telemetry 계약은 [`../docs/2026-08-11_RX_5detector_PC_UI_validation.md`](../docs/2026-08-11_RX_5detector_PC_UI_validation.md)를 우선한다.

session Wi-Fi SSID는 `KCCI_STC_S`이며 PSK는 image의 `wpa.conf`에 해시로 저장한다.

## 고정 동작

- 영상: 1280×720 YUYV, 30 fps class(실제 약 29~30 fps).
- packet 입력: AAD 1 + ciphertext 90 + TAG 1 = 92개의 128-bit block.
- crypto: AES-256-GCM, X25519 static-static ECDH + pinned TX public key, HKDF-SHA256, AES-GCM session capsule.
- session: TX 부팅이 Jetson 없이 Secure Session을 자동 생성하고 RX는 READY/COMMIT/DONE 뒤 안전 경계에서 원자적으로 활성화한다.
- 물리 입력: RX `SW2`/`BTN3`는 데모 제어로 사용하지 않는다. 기존 RX SW3 복호/bypass 기능만 유지한다.

Jetson의 post-boot `CREATE_SECURE_SESSION` 또는 `CREATE_WEAK_SESSION(seed_bits=N)` 요청은 TX에서 새 Session을 만들며, RX는 같은 X25519/HKDF/capsule 경로로 이를 적용한다. 최초 Secure Session에는 Jetson 명령이 필요 없다.

## 출력과 Capture Board

```text
TX → Jetson 2-NIC kernel bridge → RX
RX HDMI → Capture Board → PC
```

HDMI 반송 타이밍은 `1280×720p60`이다. 실제 영상 내용은 약 `29~30 fps`로 갱신되며, 60 fps carrier를 영상 처리율로 보고하지 않는다.

## PL 5종 오류 검출과 PC telemetry

`vivado/rtl/rx/gcm_rx_error_detector.sv`는 stream을 변경하지 않는 입력 전용 tap이다. TAG, REPLAY, SEQUENCE, SESSION, TIMEOUT 5종을 개별 계수하고 sticky/last context를 AXI GPIO `0x41220000`으로 제공한다. 같은 Session의 과거 valid full frame에 대한 기존 PetaLinux `(session_id, frame_id)` freshness 검사도 함께 유지한다.

RX는 Jetson이 아니라 PC에 versioned UDP telemetry v2를 약 5 Hz로 보낸다. 목적지는 고정 PC IP가 아닌 `239.77.77.77:47000`, security event는 `:47001`이며 TTL은 1이다. 따라서 PC와 RX가 같은 Wi-Fi에 연결되면 DHCP 주소와 부팅 순서가 달라도 동작한다.

PC에서 `../PC_RX_UI/run_pc_ui.bat`를 실행한다. 기본 주소는 `http://127.0.0.1:8765/`이고 충돌 시 다음 빈 포트를 자동 선택한다. USB HDMI capture 영상과 valid FPS, 5종 누계, session/마지막 오류 context를 한 화면에서 확인한다. Jetson `http://100.72.159.6:4173/`은 `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH` 역할만 유지한다.

## SD 카드

`AES_GCM_RX/sd_card`의 다음 **정확히 8개 파일을 전부** FAT32 첫 파티션 루트에 복사한다.

```text
BOOT.BIN  boot.cmd  boot.scr  image.ub
system.bit  system.dtb  README.md  SHA256SUMS
```

두 번째 ext4 파티션도 유지한다. RX는 `/run/media/rootfs-mmcblk0p2/var/lib/aes-session`에 인증된 capsule, counter, session ID와 phase를 root 전용 권한으로 보존해 RX 단독 재부팅 뒤 같은 Session을 복구한다. JTAG/RAM 부팅 또는 ext4 부재 시에는 휘발성 fallback만 사용한다.

고정 부팅 계약:

```text
image.ub=0x10000000
system.dtb=0x00100000
mem=384M
bootm_low=0x00000000
bootm_size=0x18000000
initrd_high=0x16ffffff
fdt_high=0x17ffffff
```

파일 일부만 복사하거나 `boot.cmd`/`boot.scr`, 주소, DMA 예약 영역을 바꾸지 않는다.

## JTAG RAM 부팅

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File ".\AES_GCM_RX\petalinux\JTAG_RAM_BOOT\run_jtag_boot.ps1"
```

현장 기본값은 cable `210351BE7D5BA`, `COM12`, `10.10.15.3/24`, 유선 MAC `02:00:00:00:00:03`이다. loader 주소도 `system.dtb=0x00100000`, `image.ub=0x10000000`으로 고정한다.

RX 영상 Ethernet은 `10.10.15.3/24` role-static이며 유선 `en*`에 generic DHCP를 실행하지 않는다. Jetson bridge 경유와 TX `10.10.15.2/24` 직결 모두 동일한 주소/MAC 계약을 사용한다.

Jetson NIC1/NIC2 사이에 다시 배선할 때는 `../docs/JETSON_2NIC_중간삽입_재배선_운용README.md`의 bridge/FDB/주소/300-frame gate를 따른다.

주요 경로:

- SD 배포물: `AES_GCM_RX/sd_card`
- JTAG RAM 부팅: `AES_GCM_RX/petalinux/JTAG_RAM_BOOT`
- PetaLinux 재빌드: `AES_GCM_RX/petalinux/build_petalinux.sh`
- Vivado 재빌드: `AES_GCM_RX/vivado/tcl/build_aes_gcm_rx.tcl`
- 5종 detector 단위시험: `AES_GCM_RX/vivado/sim/tb_gcm_rx_error_detector.sv`
- 하드웨어 산출물: `AES_GCM_RX/vivado/artifacts/AES_GCM_RX.bit`, `AES_GCM_RX/vivado/artifacts/AES_GCM_RX.xsa`
