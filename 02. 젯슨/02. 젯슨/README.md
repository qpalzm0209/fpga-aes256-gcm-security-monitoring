# 02. Jetson 중간자 공격 모듈

Jetson Orin Nano를 Zybo TX/RX 사이의 투명한 2-NIC L2 브리지로 삽입하고, 정상 패킷 관찰과 보안 공격 시연을 수행하기 위한 자료다.

## 시스템에서의 역할

```text
Zybo TX -> Jetson NIC 1 -> Linux L2 bridge -> Jetson NIC 2 -> Zybo RX
```

- 정상 모드: 원래 Ethernet 목적지 MAC을 유지한 채 UDP 5602 암호 패킷 전달
- Tamper: ciphertext 비트 변경 후 기존 GCM TAG 유지
- Replay: 정상 패킷을 캡처한 뒤 라이브 흐름에 재주입
- Weak-Key: 교육용 Weak Session 패킷을 대상으로 제한된 시드 공간 검색

공격 엔진은 Dashboard backend와 함께 배포되므로 현재 실행 소스는 상위 `03. 대시보드/젯슨 대시보드`의 `tamper/`, `replay/`, `bruteforce/`에 있다. 이 폴더는 공격자가 통신 경로에 들어가기 위한 브리지 구성과 PC 연결 절차를 담당한다.

## 현재 운용 자료

- `1. jetson_bridge`: Zybo TX/RX 사이의 현재 2-NIC L2 브리지 구성과 적용·복구 스크립트
- `2. jetson_to_pc`: Zybo RX HDMI 영상을 Windows PC에서 확인하는 현재 미리보기 도구
- 최신 Dashboard와 공격 엔진: 상위 `03. 대시보드/젯슨 대시보드`
- 현재 FPGA 기준본: 상위 `01. zybo_fpga/3-3. 2차변형_ECC_데모_260812_0144_TX_PL_직결_최종본.7z`

## 과거 계보

`00. 초기 통합 및 AI 실험 계보`는 2026-08-09~11 Jetson 초기 통합, 실제 보드 측정, PC AI 모델 비교와 CUDA brute-force 사전검증 기록이다. 현재 운용본을 덮어쓰는 소스가 아니며, 결과·판단 근거를 추적할 때만 참고한다.

가상환경, 캐시, 중복 해제본은 보관하지 않는다. 재현에 필요한 버전과 체크포인트는 계보 폴더의 README와 requirements에 기록한다.
