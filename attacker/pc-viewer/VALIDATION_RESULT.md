# 2026-08-09 ZYBO 직결 HDMI 실제 화면 재검증

## 최종 판정

TX PCam → TX AES-GCM → 직결 Ethernet → RX AES-GCM → HDMI → USB 캡처보드 → PC의 **실제 영상 픽셀 갱신을 확인했다**.

처음 확인했을 때는 HDMI carrier만 약 59 fps로 들어오고 원본 픽셀이 완전히 같은 **실제 정지 화면**이었다. 보드 로그만으로 정상이라고 했던 이전 판정은 잘못이었다. 원인은 직결 케이블 link flap 뒤 양쪽의 DHCP client가 유선 고정 주소 `10.10.15.2/24`, `10.10.15.3/24`를 삭제한 것이었다.

중복 주소가 없음을 확인한 뒤 TX/RX 주소만 다시 추가했고, 서비스 재시작이나 보드 reset 없이 영상이 즉시 재개됐다.

아래 PNG들은 검증 당시 직접 열어 decoded pixel 차이를 확인하고 SHA-256/수치를 이 문서에 기록한 뒤, 사용자 지시에 따라 모두 삭제했다. 현재 폴더에는 캡처 사진 찌꺼기가 남아 있지 않다.

## 실제 PC 화면 증거

`preview.py`는 캡처한 decoded BGR 픽셀을 Windows 창에 직접 표시하며 다음을 함께 측정한다.

- USB 캡처: 1280×720 MJPG, HDMI carrier 약 58.5~60.0 fps
- read failure: 0
- 정상 복구 뒤 decoded pixel change event: 약 29.0~29.5회/s
- 자동 변화 증거 이미지는 최대 20장만 보존

정지 구간의 5초 간격 원본 두 장은 SHA-256이 완전히 같았다.

```text
before_recovery_start.png
926B3C5ED41B622333FF0002084F0436A781EBA703DBCFCDBA160F49B90F91E3

before_recovery_after_5s.png
926B3C5ED41B622333FF0002084F0436A781EBA703DBCFCDBA160F49B90F91E3
```

복구 뒤 TX PCam의 `Color bars w/ rolling bar` 패턴을 양쪽 active subdevice에 잠시 켰다. 4초 간격 PC 원본에는 rolling bar 위치가 실제로 달랐고 해시도 달랐다.

```text
rolling_pattern_a.png
D4C0747B1A827110C23B4038D6E0EFFC87A60A181D9AA19627AA502411FEB1D7

rolling_pattern_b.png
76072FD69C826ED456D4DFA5112016901DCA736297ACAF87A2F5E79F49DCC7DB
```

`rolling_pattern_preview_a.png`, `rolling_pattern_preview_b.png`에는 PC에 표시한 실제 프레임과 측정 오버레이가 함께 남아 있다. 시험 뒤 두 subdevice 모두 `test_pattern: 0 (Disabled)`을 UART로 재확인했다.

두 원본의 OpenCV decoded-pixel 비교도 `exact_equal=False`, 평균 BGR 절대차 `9.378456`, 임계값 8 이상 변화 픽셀 `43,538 / 921,600 (4.7242%)`였다. 이는 파일 metadata나 JPEG byte 차이가 아니라 화면 픽셀과 rolling bar 위치가 실제로 달라졌다는 뜻이다.

## 보드 측 교차검증

주소 복구 뒤 15초 연속 관찰 결과:

```text
RX processed: 207960 -> 208410
증가: 450 frames / 15 s = 30.0 fps
auth_fail=0
replay_reject=0
status_fail=0
queue_overrun=0
stale=0
lost total: 811 -> 811
```

TX→RX ping은 3/3 성공했고, RX UDP endpoint는 `10.10.15.3:5602 <-> 10.10.15.2:5602`를 유지했다. VDMA PARK와 HDMI frame status도 다시 전진했다.

`lost total=811`은 케이블 교체/주소 유실 구간의 과거 누계이며 위 안정 구간에서 증가하지 않았다.

## 원인과 현재 주의

양쪽 `/etc/network/interfaces`의 generic Ethernet DHCP 동작 때문에 `udhcpc`가 살아 있고, link flap 뒤 애플리케이션 init이 넣은 고정 주소를 제거할 수 있었다. 프로젝트 소스에는 TX `10.10.15.2`, RX `10.10.15.3` role-static `init-ifupdown` override와 유선 DHCP 금지 release gate를 추가했고 `verify_release.ps1 -Quiet`의 213개 검사를 통과했다.

현재 실행 중인 보드는 주소를 복구해 정상이나, 실행 중인 `image.ub`는 이 수정 전에 만들어진 파일이다. 새 TX/RX PetaLinux image를 빌드·부팅하기 전에는 케이블 재연결 시 재발할 수 있다.

이 PC의 PetaLinux 2025.2 도구와 입력은 확인됐지만 WSL VHDX가 있는 C: 물리 여유가 약 7.3 GB뿐이라 fresh TX+RX Yocto build는 공간 부족 위험이 높다. 기존 정상 BOOT/image 산출물을 혼합 상태로 만들지 않기 위해 이번 현장 검증 중에는 full rebuild를 시작하지 않았다.

재발 확인은 다음 두 주소가 실제 유선 인터페이스에 남아 있는지 보면 된다.

```text
TX: 10.10.15.2/24
RX: 10.10.15.3/24
```

PC 미리보기 창에서 carrier 숫자만 보지 말고, 실제 장면 또는 rolling bar가 움직이는지와 `PIXELS CHANGING`을 함께 확인한다.
