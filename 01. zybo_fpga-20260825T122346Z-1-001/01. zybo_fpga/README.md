# 01. FPGA 암호화 엔진 및 Linux

Zybo Z7-20 송신·수신 보드의 AES-256-GCM RTL과 PetaLinux 구성을 보관합니다.

## 현재 기준본

GitHub에서 소스를 바로 확인할 수 있도록 `4-2. 2차변형_ECC_데모_260812_0144_TX_PL_직결.7z`를 `current-source/`에 풀었습니다. 원본 압축 백업과 빌드 산출물은 `.gitignore`로 제외합니다.

```text
current-source/
└─ 3-2. 2차변형_ECC_데모_260812_0144_TX_PL_직결/
   ├─ AES_GCM_TX/       # PCam 입력, PL 암호화, UDP 전송
   ├─ AES_GCM_RX/       # 인증, 복호화, 오류 검출, HDMI 출력
   ├─ session_control/  # ECDH 기반 세션 제어 공통 소스
   ├─ docs/             # 실기 검증과 설계 기록
   ├─ build_vivado_both.ps1
   ├─ build_petalinux_both.sh
   └─ verify_release.ps1
```

## 주요 RTL

TX/RX의 `vivado/rtl/aes256_gcm/`에는 다음 소스가 있습니다.

- AES-256 iterative core와 key expansion
- SubBytes, ShiftRows, MixColumns, AddRoundKey
- GHASH 곱셈기와 GCM protocol package
- TX/RX video AES-GCM top
- AXI-Stream frame processor와 packet buffer

PetaLinux의 `project-spec/meta-user/`에는 카메라·영상 송수신 애플리케이션, 디바이스 트리, OV5640/PCam 커널 패치와 세션 에이전트 레시피가 있습니다.

## 빌드

Vivado 2023.2가 설치된 Windows 환경:

```powershell
./build_vivado_both.ps1
./verify_release.ps1
```

PetaLinux 2023.2 환경:

```bash
./build_petalinux_both.sh
```

보드별 세부 절차와 SD/JTAG 운용은 기준본의 `README_한글.md`, `AES_GCM_TX/README*`, `AES_GCM_RX/README.md`를 참고하세요.

## 비밀정보와 산출물

실제 `wpa.conf`, 개인키, 부트 이미지, bitstream, XSA/ELF/DTB, Vivado/PetaLinux 빌드 디렉터리는 저장소에 포함하지 않습니다. 세션 키는 `session_control/generate_rx_demo_keys.sh`를 이용해 환경별로 새로 생성하세요.

