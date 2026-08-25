# RX 최종 SD 갱신 및 부팅 독립성 검증

검증 시각: 2026-08-12 13:43~13:53 KST

## 변경 사항

- RX가 단독 재부팅됐을 때 보내는 `CREATE_SECURE_SESSION` 복구 요청에 DHCP 서브넷 기반 유니캐스트 fallback을 추가했다.
- 특정 TX IP, RX IP, COM 번호를 제품 코드에 고정하지 않았다.
- USB Wi-Fi 동글의 ifindex가 재삽입 후 바뀌어도 health monitor가 session agent와 링크를 다시 시작한다.

## 빌드 및 파일 검증

- PetaLinux 2025.2: 6,165/6,165 tasks 성공
- BOOT.BIN: `839d02de97fd45eea3478108c9650a5b9b71cf5d046a2f099ba87835c98cd124`
- image.ub: `c1a3c80ab869a2826fa1a4f83a98b562dc7b35f5160d7d68c68e520e2da5b758`
- system.bit: `665ee9179722a338d145c80525b337b49a48f1de9b4b76e841fba69217af3928`
- 실제 RX SD에서 `SHA256SUMS` 7/7 통과 후 clean unmount 및 재부팅
- 갱신 전 실제 SD 전체 백업: `/var/backups/rx-sd-before-20260812-1349-final`
- 전체 release verifier: `RELEASE_VERIFY_PASS`, 257 checks

## 실기 재부팅 검증

1. TX는 계속 동작시킨 채 RX만 최종 SD로 재부팅했다.
2. RX가 Wi-Fi DHCP 주소 `192.168.5.212`를 받은 뒤 복구 요청을 재전송했다.
3. 새 secure session `0x6244953a`, counter 3이 commit/confirm됐다.
4. RX는 TX의 유선 영상 경로 `10.10.15.2:5602`를 다시 학습했다.
5. RX 로그에서 1280x720 YUYV 약 27~31 fps, queue overrun 0, replay reject 0을 확인했다.
6. PC UI는 고정 COM 설정 없이 RX 역할/CRC 프레임을 검사해 `COM12`를 자동 선택했다.
7. PC UI 실측 예: valid FPS `27.693`, auth reject rate `0.0`, session `0x6244953a`.

결론: 최종 RX SD는 TX보다 늦게 부팅해도 자동으로 새 인증 세션을 만들고 영상·UART 텔레메트리를 복구한다.
