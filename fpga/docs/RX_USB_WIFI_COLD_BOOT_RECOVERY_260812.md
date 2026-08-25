# RX USB Wi-Fi 냉부팅 복구 기록

## 결론

RX의 MT7601U USB Wi-Fi 동글은 완전히 고장 난 상태가 아니었다. 냉부팅 직후
Zybo USB 호스트에서 펌웨어 응답과 USB 트랜잭션이 실패하면서 `wl*` 네트워크
인터페이스가 생성되지 않는 경우가 원인이었다. 동일 동글은 USB 호스트를
재초기화하면 정상 인식, AP 연결, DHCP, TX/RX 키 교환까지 수행했다.

관찰한 커널 오류는 다음과 같다.

- `MCU resp urb failed: -75`
- USB protocol error `-71`
- `mt7601u_mcu_wait_resp timed out`
- `probe with driver mt7601u failed with error -110`

따라서 SSID, 비밀번호, DHCP 주소 또는 PC 텔레메트리 설정 문제가 아니다.

## 적용한 복구

`/etc/init.d/aes-session-wifi`는 부팅 후 `wl*` 인터페이스가 일정 시간 나타나지
않으면 `ci_hdrc.0` USB 호스트를 한 번 재초기화하고 정상 인터페이스 검색을
계속한다.

- 이미 호스트 드라이버에 붙어 있으면 `unbind -> bind`
- 호스트가 이미 unbind된 상태면 즉시 `bind`
- 정상 인식된 동글은 건드리지 않음
- 인터페이스명과 DHCP 주소를 고정하지 않음
- 드라이버/장치 경로와 대기 횟수는 환경 변수로 변경 가능

USB Wi-Fi는 TX/RX 키 교환 전용이다. RX가 PC로 보내는 텔레메트리는 5핀
UART(COM12)이며 영상은 RX HDMI 캡처 경로이다.

## 검증

- RX/TX PetaLinux 최종 이미지 빌드 성공
- 세션/암호/감독 프로세스/Wi-Fi 호스트 테스트 모두 통과
- 3-2 릴리스 257개 일관성 검사 통과
- 두 실제 SD에 기록 전후 SHA-256 검증 통과
- RX에서 USB 호스트를 강제로 unbind한 실기 시험 통과
- 로그에서 자동 호스트 리셋 후 `wlx705dccf1e097` 재인식 및 기존 세션 복구 확인
- PC UI COM12 온라인, 약 30 FPS 복귀 확인

최종 SD `image.ub` SHA-256:

- RX: `a3150fee59e7248cc06b4ecbe456b5515fbd590d94f25efc5abcccf1c624541a`
- TX: `141b80d0b7e019ba20129bc33baa700623ff011c831fff01bb236501ddcfe7a9`

자동 재시도 뒤에도 반복적으로 USB 장치가 나타나지 않으면 동글, USB 커넥터,
5 V 전원 품질을 확인하고 동글 교체 시험을 한다.
