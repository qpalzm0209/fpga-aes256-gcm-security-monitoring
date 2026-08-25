# 3-1 최종 JTAG / SD 릴리스 검증 — 2026-08-12

## 검증 대상

- RX: `AES_GCM_RX/petalinux/JTAG_RAM_BOOT`
- TX: `AES_GCM_TX/petalinux/JTAG_RAM_BOOT`
- SD 배포: 각 보드 `AES_GCM_*/sd_card`
- PC UI: `PC_RX_UI`, `127.0.0.1:8765`
- Jetson 공격 UI/API: Tailscale 경유 `:4173`

## 정적·호스트 검증

- 새 RX/TX `image.ub`의 FIT initramfs를 직접 추출했다.
- 양쪽 `/usr/bin/aes-session-agent`에 인증된 counter-floor 프로토콜이 포함됨을 확인했다.
- 양쪽 init에 `/run/media/...`, SD 라벨 및 `SD_ROOTFS_MOUNT` 의존성이 없음을 확인했다.
- session crypto, Wi-Fi recovery, init supervision, lost ACK/DONE, process restart 및 TX-only volatile reboot 회귀 시험이 통과했다.
- `verify_release.ps1`: `RELEASE_VERIFY_PASS`, 242개 검사 통과 후 UI cache 수정 검사를 추가했다.

## 실제 보드 JTAG 검증

1. RX 새 3-1 이미지를 JTAG RAM 부팅했다.
2. TX 새 3-1 이미지를 JTAG RAM 부팅했다.
3. PC UI가 RX UART를 COM 번호 고정 없이 `COM12`에서 식별했다.
4. 세션 `0x2869925b`, 29.907~29.942 FPS, UART invalid 0, auth/replay reject 0을 확인했다.
5. Jetson 2-NIC kernel bridge throughput은 약 460 Mb/s였다.
6. RX를 유지한 채 TX만 JTAG RAM 재부팅했다.
7. TX 로그에서 `RX counter floor 1` 인증 수락, counter 2, session `0x33b97b77` COMMIT을 확인했다.
8. 새 세션 영상이 29.855 FPS로 자동 복구됐다.

## 공격·검출기 검증

- 5% tamper 6초: authentication/TAG/SEQUENCE 누계가 각각 0→5로 증가했다.
- stop/reset 후 attack 상태 `idle`, 영상 29.932 FPS로 복구됐다.
- 5% replay 6초: software replay reject 0→8, PL replay detector 0→10240으로 증가했다.
- stop/reset 후 attack 상태 `idle`, 영상 29.938 FPS로 복구됐다.
- SESSION/TIMEOUT 검출기 RTL, register view, telemetry field 및 회귀 시험을 확인했다. 정상 세션을 파괴하는 live fault는 최종 수락 시험에서 주입하지 않았다.

## PC / Jetson 역할과 네트워크

- PC Wi-Fi는 연결 해제 상태였다.
- PC UI는 유선 LAN + RX 5-pin UART로 동작했다.
- PC→Jetson 제어는 유선 LAN 위 Tailscale로 동작했다.
- USB Wi-Fi는 Zybo TX/RX 키 교환에만 사용했다.
- 영상은 TX 유선→Jetson kernel bridge→RX 유선 이외의 경로를 사용하지 않았다.

## Jetson UI 배포 검증

- 배포된 브라우저 cache 때문에 구 3페이지 UI가 남는 문제를 확인했다.
- 새 content-hash asset URL로 교체하여 `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH` 두 페이지만 표시됨을 DOM과 실제 Jetson 화면으로 확인했다.
- RX telemetry가 Jetson에 없을 때도 Jetson throughput/power가 갱신되도록 로컬 지표 갱신 조건을 분리했다.
- 캡처는 PC의 `%USERPROFILE%\Desktop\젯슨 UI`에 저장했다.

## SD 백업 수락 조건

각 `sd_card`는 정확히 다음 8개 파일만 배포 단위로 사용한다.

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

- TX/RX 각각 exact 8/8
- `SHA256SUMS` 7/7
- boot/JTAG/SD `image.ub` 및 `system.dtb` hash 일치
- Vivado BIT와 SD `system.bit` hash 일치
- PetaLinux boot `BOOT.BIN`과 SD `BOOT.BIN` hash 일치

따라서 3-1은 현재 JTAG RAM 실보드 검증본과 내일 SD에 복사할 완전한 백업이 동일한 릴리스다.
