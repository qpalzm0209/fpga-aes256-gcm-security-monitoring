# Jetson Bridge

Jetson Orin Nano를 Zybo TX와 RX 사이의 투명 L2 중간 노드로 구성하는 파일이다.

## 파일

- `26-08-13_브리지_현재_구성.md`: 네트워크, 패킷 감시, 공격 엔진과 실행 위치
- `scripts/apply_br_video.sh`: 두 유선 NIC를 `br-video`에 연결
- `scripts/rollback_br_video.sh`: `br-video` 연결을 해제하고 유선 NIC를 NetworkManager에 다시 연결

Dashboard와 공격 엔진의 현재 실행 파일은 상위 `03. 대시보드/젯슨 대시보드`에 있다. Zybo TX/RX, PetaLinux와 SD 카드 파일의 현재 기준본은 상위 `01. zybo_fpga/3-3. 2차변형_ECC_데모_260812_0144_TX_PL_직결_최종본.7z`다. 2026-08-09~11 초기 통합과 AI 실측 기록은 형제 폴더 `00. 초기 통합 및 AI 실험 계보`에 분리돼 있다.

## 적용

두 유선 NIC만 연결된 Jetson에서는 인터페이스를 자동 탐색한다.

```bash
sudo ./scripts/apply_br_video.sh
```

유선 NIC가 세 개 이상이면 TX 측과 RX 측 인터페이스를 순서대로 지정한다.

```bash
sudo ./scripts/apply_br_video.sh eno1 enx001122334455
```

설정은 NetworkManager connection profile로 저장되며 다음 부팅부터 자동 연결된다. 인터페이스 이름, USB NIC의 MAC 기반 이름과 관리망 주소를 스크립트에 고정하지 않는다.

## 해제

```bash
sudo ./scripts/rollback_br_video.sh
```
