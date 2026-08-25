# TX PL 직결 720p30 경로

## 실제 데이터 경로

```text
Pcam 5C / OV5640 MIPI CSI-2
  -> MIPI CSI-2 RX (PL, 16-bit YUV422 AXIS)
  -> 16-bit 영상 AXIS를 128-bit 프레임 AXIS로 pack
  -> AES-256-GCM TX engine (PL)
  -> 128-bit 프레임 AXIS를 16-bit 영상 AXIS로 unpack
  -> Video Frame Buffer Write
  -> V4L2 MMAP/DMA-BUF (DDR에는 이미 PL 처리된 프레임)
  -> PS raw UDP 송신
  -> Jetson bridge
  -> RX
```

SW3 ON에서는 MIPI 카메라 평문이 DDR에 기록되기 전에 AES-GCM 처리된다.
SW3 OFF는 의도적으로 보이는 평문 데모 모드이며 동일한 PL 경로에서 암호 연산만
bypass한다. 두 모드 모두 유효한 session과 `key_ready=1`이 필요하다.

## 제거한 경로

3-1까지 사용한 아래 왕복 경로는 3-2에 존재하지 않는다.

```text
V4L2 plaintext DDR -> AXI DMA MM2S -> AES-GCM -> AXI DMA S2MM
                    -> 별도 CMA output buffer -> UDP
```

따라서 새 XSA에는 `axi_dma_gcm_tx`, PS `S_AXI_ACP` 연결 및
`aes-gcm-bridge` 디바이스가 없다. PetaLinux 이미지에도
`pcam-aes-bridge` 커널 모듈을 넣지 않는다.

## 프레임 경계와 재시작 복구

- 입력 Pcam TLAST는 1280 pixel마다 오는 end-of-line이다.
- packer는 8 pixel을 한 개의 128-bit beat로 만들고, 115200번째 beat에만
  GCM용 end-of-frame TLAST를 만든다.
- unpacker는 GCM 출력에서 frame SOF TUSER와 1280-pixel line TLAST를 다시 만든다.
- 초기화 시에는 실제 Pcam TUSER가 올 때까지 잔여 partial line을 버린다.
- V4L2 frame-buffer runtime reset은 packer/GCM/unpacker/metadata writer도 함께
  reset하므로 서비스가 프레임 중간에 죽어도 다음 시작에서 경계가 다시 맞는다.

## PS 송신기

`pcam-gcm-udp-tx.c`는 `/dev/pcam_aes_bridge`나 별도 CMA output을 열지 않는다.

1. V4L2 MMAP 버퍼 4개를 DMA-BUF로 export한다.
2. PL metadata completion과 V4L2 `buffer.sequence`를 같은 프레임으로 맞춘다.
3. metadata frame ID와 V4L2 sequence의 초기 offset이 유지되는지 검사한다.
4. PL active session과 metadata session이 다르거나 rekey 중이면 그 프레임은 버린다.
5. 전송 중에는 session frame reservation을 잡아 old/new session 경합을 막는다.
6. `DMA_BUF_IOCTL_SYNC` READ 구간에서 PL 처리된 버퍼를 UDP로 보낸다.

진단 덤프는 `/tmp/tx_pl_direct_frame.bin`과
`/tmp/tx_pl_direct_meta.bin`만 생성한다. 암호화 모드에서 평문 덤프는 존재하지 않는다.

## 검증 명령

```sh
grep -E 'TX_PL_DIRECT|frame=.*path=PL_DIRECT|TIMING' /var/log/pcam-gcm-tx.log
v4l2-ctl -d /dev/video0 --all
media-ctl -d /dev/media0 -p
aes-session-check
```

정상 시작 로그에는 아래가 있어야 한다.

```text
TX_PL_DIRECT=1 path=MIPI->PL_AES_GCM->V4L2_DDR->PS_UDP
PLAINTEXT_DDR_PRE_GCM=0
TX_PL_DIRECT_ALIGN ...
```

## 완료 기준

- 폭 변환/백프레셔/SOF 재동기화 xsim PASS
- Vivado synth/implementation/DRC/timing PASS
- 최종 DT에 `dma@40400000`과 `aes-gcm-bridge`가 없음
- JTAG 실기기에서 SW3 ON AES-GCM 인증 성공과 29~30 fps 영상 복원
- 서비스 kill/restart 및 두 보드 cold boot 뒤 수동 조작 없이 자동 복구
- Jetson tamper/replay 시 RX 5종 detector와 PC SECURITY UI가 함께 반응

실기기 항목까지 통과하기 전에는 3-1을 SD 카드용 안전 기준으로 사용한다.
