# 3-2 영상 조각화 원인 분석 및 수정 기록

## 결론

3-2에서만 발생한 열 단위 조각화/프레임 혼합은 PC UI나 RX PS의 재조립
오류가 아니다. TX의 `MIPI CSI-2 RX -> 16/128 packer -> AES-GCM` 직결
경로에서 AES의 순간적인 `TREADY=0`이 카메라 수신단까지 전달되어 MIPI
line buffer가 넘쳤고, 기존 packer가 유실된 실제 SOF/EOL 대신 내부 픽셀
카운터로 프레임 경계를 계속 생성하면서 서로 다른 행/프레임을 한 화면으로
묶은 것이 원인이다.

## 계층별 근거

### PC UI

- live 영상은 단일 `<video>` 요소의 `srcObject`로 표시된다.
- canvas는 Gemini에 보낼 정지 프레임 한 장을 캡처할 때만 사용된다.
- 3-1과 3-2의 `index.html`, `styles.css`, `app.js` SHA-256이 각각 같다.
- 따라서 UI는 영상 크기 조정은 할 수 있어도 열을 재배치하거나 서로 다른
  프레임을 조립하지 않는다.

### RX PS

- 3-1과 3-2의 `aes-gcm-rx.c` SHA-256이 같다.
- RX는 packet index를 검사하고 `index * 1472` 위치에 기록한다.
- 1280x720 YUYV의 stride는 2560 bytes, frame bytes는 1,843,200 bytes로
  TX와 일치한다.
- AES-GCM 인증을 통과한 조각 영상이므로 tag 생성 뒤의 임의 패킷 손상도
  원인이 아니다. 그런 손상은 RX에서 인증 거부되어야 한다.

### TX PS

- V4L2는 1280x720 YUYV, 2560-byte stride로 설정한다.
- frame을 1280개의 1440-byte payload로 순서대로 전송하고 각 payload와
  같은 packet index의 AAD/tag를 묶는다.
- PS는 PL frame buffer가 준 바이트 순서를 변경하지 않는다.

### TX PL 실측

TX JTAG cable `210351BE7DF5A`에서 MIPI CSI-2 RX ISR `0x24`를 읽은 값은
`0x80060002`였다.

- `0x80000000`: Frame Received
- `0x00040000`: Stream Line Buffer Full
- `0x00020000`: Detect Stop State
- `0x00000002`: VC0 Frame Sync Error

`Stream Line Buffer Full`과 `VC0 Frame Sync Error`가 동시에 확인되므로,
직결 경로의 downstream backpressure가 실제 카메라 프레임 경계를 깨뜨린
것이 하드웨어에서 확인됐다.

관련 AMD/Xilinx 정의:

- https://xilinx.github.io/embeddedsw.github.io/csi/doc/html/api/xcsi__hw_8h.html

## 기존 검증의 누락

기존 width-bridge testbench의 입력은 AXI `TREADY`가 내려가면 데이터를
그대로 유지하고 기다리는 이상적인 소스였다. 실제 MIPI 카메라는 제한된
line buffer를 가진 실시간 소스이므로 장시간 멈출 수 없다. 또한 packer,
AES wrapper, unpacker의 `protocol_error` 출력이 AXI GPIO에 연결되지 않아
실패가 software log에 보이지 않았다.

## 수정

- 16->128 packer와 AES-GCM 사이에 8192 x 128-bit AXI4-Stream Data FIFO를
  추가했다.
- FIFO memory는 TX PL block RAM이며 plaintext를 PS/DDR로 우회하지 않는다.
- FIFO는 약 65,536 pixel, 즉 1280-pixel 기준 약 51 active line을 저장한다.
- packer/AES/unpacker protocol error, FIFO near-full, FIFO high-water를 기존
  read-only AXI GPIO channel 1에 연결했다.
- metadata completion channel 2와 UDP packet format은 변경하지 않았다.
- TX PS는 각 V4L2 frame을 보내기 전에 health 상위 오류 비트를 확인한다.
  오류가 있으면 손상된 frame을 인증된 영상처럼 보내지 않고 종료하며,
  기존 init supervisor가 STREAMON과 runtime PL pipeline을 자동 재시작한다.

## 새 실시간 입력 회귀시험

실제 AES-GCM RTL을 사용하면서 다음 조건으로 시험한다.

- 1280x720 한 frame 전체
- 30 fps timing envelope
- active line 동안 매 150-MHz clock마다 pixel 입력
- camera source는 downstream `TREADY`를 기다리지 않음
- video output과 metadata output에 서로 독립적인 stall 삽입
- camera backpressure, FIFO overflow, protocol error가 한 번이라도 발생하면 실패

2026-08-12 결과:

```text
PASS: fixed-rate 720p30 camera survived AES backpressure;
FIFO high-water=82/8192
```

## 2026-08-12 새 RTL 전체 빌드 결과

- Vivado 2025.2 전체 합성: 성공, error 0, critical warning 0
- 구현 후 setup WNS: `+0.036 ns`
- 구현 후 hold WHS: `+0.019 ns`
- 완전 배선 net: 24,867 / 24,867, routing error 0
- bitstream 생성 전 DRC: error 0
- 사용 자원: LUT 12,042, FF 16,416, RAMB36 78, RAMB18 1
- `AES_GCM_TX.bit` SHA-256:
  `0232378e0867a9f5094bfd67c7ef4cc16f3d9e90c0d9baa0b6d2aa31b69cd294`
- 새 XSA를 사용한 PetaLinux 6,167 task: 전부 성공
- `BOOT.BIN`, `image.ub`, `system.dtb`, `system.bit`, `boot.scr` 재생성 및
  `SHA256SUMS` 대조: 성공

아직 남은 항목은 실제 TX 보드에 새 산출물을 올린 뒤 정상 1280x720 한 화면,
29~30 fps, MIPI `Stream Line Buffer Full`/`VC0 Frame Sync Error` 비트 0,
pipeline health 상위 오류 nibble 0을 동시에 확인하는 실기 검증이다.
