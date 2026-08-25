# 3-2 TX PL 직결 최종 JTAG/SD 검증

검증 시각: 2026-08-12 00:47~01:14 KST

## RTL과 시뮬레이션

- 키 commit pulse가 runtime reset보다 먼저 끝난 경우를 재현하도록 backpressure testbench를 확장했다.
- `session_key_valid && !crypto_ready`이면 AES key schedule을 자동 재생성하도록 수정했다.
- 독립 AXI data/meta backpressure에서 1,280 packet, 115,200 encrypted payload block을 검증했다.

## 구현

- Vivado 2025.2 implementation: setup WNS `+0.121 ns`, hold WHS `+0.015 ns`
- bitgen 성공, DRC error 0
- BIT: `F1CC57FBE2FF1A66863D371CA41C5DF4907BC26113AF8395BE5D0C4B2DF1E588`
- XSA: `8DC586999DE1EBA439184843B7CA67ADCF53A3AE93B3EC504AAE5E8D9AEB3F59`

## PetaLinux/SD

- PetaLinux 2025.2: 6,167/6,167 tasks 성공
- 새 XSA와 BIT로 BOOT.BIN을 다시 생성했다.
- BOOT.BIN: `DADD7F0A60F64FFC3F40D5927E24B03B563C03CCE34B4866218C7177817AF7EF`
- image.ub: `7BEC7A96B4813AF3DF155970CD2A8C0D9BE10F0D33CD7CC27B8FB809F2BF2357`
- `SHA256SUMS` 7/7 통과
- DTB에 MIPI/VFB path가 있고 legacy DMA bridge가 없음을 확인했다.
- initramfs에 PL-direct TX, session agent, counter-floor 복구가 있고 고정 SD automount 의존이 없음을 확인했다.

## 실기 JTAG

1. TX를 새 BIT/DTB/image.ub로 JTAG RAM 부팅했다.
2. `/dev/media0`, `/dev/video0` 존재와 legacy bridge 부재를 확인했다.
3. TX가 `KCCI_STC_S` USB Wi-Fi에서 RX를 동적으로 발견했다.
4. 인증된 RX counter floor 6을 받아 counter 7, secure session `0x8e332bbf`를 commit/confirm했다.
5. PC UART에서 29.9~30.9 fps, auth/replay reject 0을 5회 연속 확인했다.
6. Weak Session `0xc6f84cc9`를 만들고 Jetson이 실제 유선 packet을 캡처했다.
7. CUDA 탐색이 seed를 찾고 AES-GCM tag를 독립 검증했다.
8. secure session `0x34d81792`로 복귀 후 약 29.9 fps, reject 0을 확인했다.

## UI 공격 기능

- 01 tamper 5% 실행에서 modified frame/packet counter 증가, stop/reset 성공
- 02 prepare가 RX telemetry를 기다리지 않고 TX packet session ID로 `weak-ready` 진입
- 02 seed search `tag_verified=true`, secure 복귀 성공

## 결론

3-2는 새 RTL의 최초 secure session과 이후 rekey 모두 인증 영상 30 fps급으로 동작했다. SD용 8개 파일은 실기 검증한 동일 BIT/XSA/PetaLinux 빌드에서 생성됐다.

전체 release verifier도 TX/RX/UI/JTAG/SD/세션 일관성 257개 검사를 통과했다.
