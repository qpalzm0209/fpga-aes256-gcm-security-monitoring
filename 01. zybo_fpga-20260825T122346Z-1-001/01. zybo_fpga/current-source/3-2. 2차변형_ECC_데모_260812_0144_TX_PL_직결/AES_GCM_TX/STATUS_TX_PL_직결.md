# 3-2 TX PL 직결 작업 상태

최종 목표는 Pcam의 YUV422 스트림을 TX의 PL에서 즉시 AES-256-GCM 처리한 뒤,
DDR에는 암호문(또는 SW3으로 명시적으로 선택한 평문 데모 모드)만 기록하는 것이다.

## 보안 불변조건

- SW3 암호화 모드에서는 카메라 평문 프레임을 TX DDR에 기록하지 않는다.
- 데이터 경로는 `MIPI RX -> PL AES-GCM -> Frame Buffer Write -> DDR -> PS UDP`이다.
- PS는 암호화 연산이나 평문 변환을 하지 않고, PL이 만든 프레임과 메타데이터만 전송한다.
- 세션 전환 중 이전 세션의 프레임은 새 세션으로 잘못 전송하지 않고 폐기한다.
- RX/PC 프로토콜과 30 fps급 실시간 동작은 3-1 기준보다 낮아지지 않아야 한다.

## 기준본

- `3-1. 2차변형_ECC_데모_260810_2259_수정`은 실기기 검증된 복구용 기준본으로 동결한다.
- 이 `3-2` 폴더는 차분 모음이 아니라 독립적으로 빌드·배포 가능한 전체 프로젝트다.
- 릴리스 안의 Vivado 기준 위치는 `AES_GCM_TX/vivado`이며, 호스트의 절대 경로에
  의존하지 않는다. Windows 260자 제한은 빌드 스크립트가 임시 짧은 드라이브를
  자동 할당해 피한다.

## 완료 판정

아래 항목을 모두 통과하기 전에는 TX PL 직결 완료로 판정하지 않는다.

1. 16-bit 영상 AXIS와 128-bit GCM AXIS 사이의 pack/unpack RTL 시뮬레이션
2. AES-GCM 엔진 포함 Vivado 합성·구현·DRC·타이밍 통과
3. 새 XSA 기반 PetaLinux 빌드
4. JTAG RAM 부팅 후 TX/RX 정상 영상 30 fps급 확인
5. SW3 암호화 모드에서 RX 인증 성공 및 영상 복원 확인
6. Jetson 무결성 공격 시 RX의 5종 에러 디텍터와 PC UI 카운터 반응 확인
7. 재부팅·느린 부팅·Wi-Fi 재연결 뒤 자동 복구 확인

## 현재 상태 (2026-08-11 20:06 KST)

- 3-1 기준 데모, PC UI, Jetson 2기능 UI 및 실제 공격 검증: 완료
- 3-2 전체 독립 복사와 Vivado 작업 디렉터리 생성: 완료
- 16↔128-bit frame width 변환, backpressure, SOF 재동기화 xsim: PASS
- Vivado block design 검증 및 AXI DMA/ACP 제거 확인: PASS
- TX PL 직결 PS 송신기 엄격 host compile 및 session 단위시험: PASS
- 카메라/V4L2 runtime reset과 PL crypto frame 경계 연동: 반영 완료
- Vivado 2025.2 합성·구현: PASS (`WNS +0.127 ns`, `WHS +0.022 ns`,
  fully routed, DRC error 0, bus-skew constraint PASS)
- TX bitstream SHA-256:
  `AA0F45E4124D28C68366BC666276C005ECBCE85B5F45C81CCC20E10B59678CDC`
- TX XSA SHA-256:
  `46787F63ECE9C201067B4BCD52C4FEF600E149936D1822EA6C08A13168A4D184`
- PetaLinux 2025.2: PASS (6167/6167 tasks, BOOT.BIN/JTAG RAM/SD 산출물 생성)
- 최종 DT/rootfs: 구 AXI DMA/bridge 없음, PL-direct TX 서비스와 물리 유선 NIC
  자동 선택 포함, SD SHA256SUMS 검증 PASS
- Jetson 실화면: `01 INTEGRITY ATTACK`, `02 WEAK-KEY SEARCH` 번호와 2탭 구성 확인
- 새 비트스트림 JTAG 실기기 영상·인증·공격·재시작 검증: 미완료

따라서 현재 SD 카드용 안전 기준은 3-1이며, 3-2는 위 완료 판정을 통과한 뒤에만
대체한다.
