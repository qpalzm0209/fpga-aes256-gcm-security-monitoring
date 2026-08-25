# 3-2 TX PL 직결 최종 상태

기준 시각: 2026-08-12 12:44 KST

## 최종 판정

3-2 TX PL 직결 경로의 RTL 수정, 전체 빌드, JTAG 실기 검증 및 TX/RX SD 부팅 파일 패키징을 완료했다.
PC HDMI 캡처 화면은 사용자가 직접 정상 영상을 확인했다. 3-1은 변경하지 않은 fallback이다.

## 영상 깨짐 원인과 수정

- 원인: 고정 속도 MIPI 카메라에 AES-GCM backpressure가 전파되어 CSI line buffer가 넘치고 프레임 경계가 깨졌다.
- 수정: packer와 AES-GCM 사이에 8192x128-bit PL Block-RAM AXI FIFO를 추가했다.
- 평문은 PL 내부 FIFO에만 머물며 PS/DDR로 우회하지 않는다.
- FIFO/프레임 경계 오류를 AXI GPIO health status로 감시한다.
- reset 직후 AXI FIFO의 일시적인 `prog_full` 펄스를 near-full 오류로 잘못 기록하던 문제는 실제 occupancy 임계값으로 판정하도록 수정했다.

## 최종 Vivado 결과

- Vivado 2025.2 전체 합성/구현 성공
- error 0, critical warning 0, DRC error 0
- setup WNS `+0.095 ns`, hold WHS `+0.024 ns`
- BIT SHA-256: `9c50c60cb06552c60bebe374727e7912345e3aaa05ed93040f9a9fece745e367`
- XSA SHA-256: `0521cfe7ee6612f3d3e64ab58af223e3b17b4ccf2516d5fd870a049763f71940`

## 실기 검증

- 보드 식별: PCam 장착 TX = cable `210351BE7DF5A`, COM9
- TX JTAG RAM boot: `SPACE=1 BOOTARGS=1 BOOTM=1 LOGIN=1 READY=1 PCAM_CHECKED=1 PCAM=1`
- RX UART 자동 식별: COM12
- TX PL-direct 연속 처리: 약 `29.9~30.0 fps`
- PC UI valid FPS: 약 `29.75~29.94 fps`
- 현재 auth reject rate: `0.0 fps`
- pipeline health: `0x00008000` (상위 sticky error nibble 0)
- MIPI ISR: `0x00020000` (line-buffer-full 및 frame-sync-error 0)
- PC HDMI 캡처: 1280x720 단일 정상 프레임, 분할/조립 깨짐 없음 확인

## 부팅·네트워크 독립성

- TX/RX 세션 상태는 SD 장치명·볼륨명·automount 경로에 의존하지 않는다.
- USB Wi-Fi 동글 hot-unplug 시 살아 남은 세션 agent를 health monitor가 종료하고, 재삽입된 인터페이스를 다시 탐색해 세션을 자동 재시작한다.
- RX 주소는 고정하지 않고 인터페이스/peer discovery로 찾는다.
- PC 대시보드는 COM 번호를 고정하지 않고 RX UART role frame으로 보드를 식별한다.

## 최종 SD 산출물

- TX PetaLinux: 6,167/6,167 tasks 성공
- TX BOOT.BIN SHA-256: `ea2d3f8cf12d10044bad3bbe2578d0f24bf8856ec16cbe7152fbede95c36c1a7`
- TX image.ub SHA-256: `90d215a0cc8f523a631d8b4b208bc295a09f2fda4c325ecb55aa66ef6549dd25`
- RX PetaLinux: 6,165/6,165 tasks 성공
- RX BOOT.BIN SHA-256: `839d02de97fd45eea3478108c9650a5b9b71cf5d046a2f099ba87835c98cd124`
- RX image.ub SHA-256: `c1a3c80ab869a2826fa1a4f83a98b562dc7b35f5160d7d68c68e520e2da5b758`
- RX 단독 SD 재부팅 후 DHCP 서브넷 유니캐스트 복구로 secure session `0x6244953a` 자동 체결
- PC UART 자동 식별: `COM12`, 실측 valid FPS `27~31`, 현재 auth reject rate `0.0`
- 전체 릴리스 검증: `RELEASE_VERIFY_PASS`, 257 checks
