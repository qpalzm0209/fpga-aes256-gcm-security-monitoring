# Jetson 2-NIC 중간 삽입 재배선·운용 README

## 목적

TX/RX 직결 케이블을 다음 최종 경로로 바꿀 때 참조한다.

```text
PCam
  -> Zybo TX
  -> Jetson 전용 NIC1
  -> Jetson Linux kernel L2 bridge
  -> Jetson 전용 NIC2
  -> Zybo RX
  -> HDMI
  -> USB capture board
  -> PC browser 또는 PC-local preview
```

정상 AES 영상은 Jetson user-space, Python, HTTP, WebSocket을 통과하지 않는다. Jetson은 원래 Ethernet destination MAC을 보존하는 kernel L2 bridge로만 전달한다.

## 절대 바꾸지 않는 값

| 항목 | TX | RX/Jetson |
|---|---|---|
| 영상 IPv4 | `10.10.15.2/24` | RX `10.10.15.3/24` |
| 영상 MAC | `02:00:00:00:00:02` | RX `02:00:00:00:00:03` |
| 영상 UDP | `5602` | `5602` |
| Jetson bridge IP | - | telemetry 사용 시 bridge에만 `10.10.15.1/24` |
| RX telemetry | - | Jetson `10.10.15.1:47000/UDP`, 약 5 Hz |

Session control은 영상 bridge와 별도인 Zybo 2.4 GHz Wi-Fi를 계속 사용한다.

```text
SSID: <SESSION_CONTROL_SSID>
PSK : <SESSION_CONTROL_PSK>
```

TX는 Jetson 없이도 부팅 후 기본 Secure Session을 자동 생성한다. Jetson Web/UI는 이후 Secure 재생성 또는 Weak Session override/control만 수행한다.

## 현재 image 주의

프로젝트 소스에는 유선 generic DHCP를 제거하고 TX `.2`, RX `.3`를 role-static으로 고정했다. release verifier 213개 검사는 PASS했다.

하지만 현재 JTAG로 실행 중인 `image.ub`는 이 수정 전에 만들어진 이미지다. 케이블 link flap 뒤 기존 `udhcpc`가 `.2/.3`를 다시 지울 수 있다. C: 물리 여유가 약 7.3 GB라 fresh TX+RX PetaLinux build는 공간 부족 위험 때문에 아직 시작하지 않았다.

따라서 현재 이미지로 재배선할 때는 케이블 연결 직후와 최종 15초 시험 뒤에 양쪽 주소 존재 여부를 반드시 확인한다.

## 1. 재배선 전 준비

1. Jetson 관리 접속을 Wi-Fi 또는 Tailscale로 먼저 확보한다.
2. Jetson에서 다음을 기록한다.

```bash
ip -br link
ip -br addr
ip -4 route show default
nmcli device status 2>/dev/null || true
```

3. default route 또는 현재 SSH가 걸린 NIC는 bridge port로 선택하지 않는다.
4. `wlP1p1s0`, `tailscale0`, `docker0`, `l4tbr0`, `usb0`, `usb1`은 bridge member가 아니다.
5. 두 개의 전용 물리 Ethernet NIC가 실제로 있어야 한다. 한 개뿐이면 Wi-Fi나 USB gadget을 억지로 두 번째 포트로 쓰지 말고 USB GbE 등 전용 NIC를 추가한다.
6. Zybo는 SW3 AES-GCM ON, SW2/BTN3 미사용, Jetson Attack OFF 상태로 둔다.

## 2. NIC1/NIC2를 이름이 아니라 물리 포트로 식별

`eno1`, `eth0`, `enx...` 같은 이름만 보고 정하지 않는다.

```bash
ip monitor link
```

위 명령을 한 터미널에 띄우고 다음을 수행한다.

1. TX 쪽 케이블 하나만 Jetson 포트에 연결한다.
2. carrier가 `0 -> 1`이 된 NIC를 확인한다.
3. 다시 뽑아 같은 NIC가 `1 -> 0`이 되는지 확인한다.
4. NIC 이름, permanent MAC, driver, bus path를 `NIC1-TX`로 기록한다.
5. RX 쪽도 같은 방법으로 `NIC2-RX`를 기록한다.

```bash
ethtool -P <NIC>
ethtool -i <NIC>
readlink -f /sys/class/net/<NIC>/device
udevadm info -q property -p /sys/class/net/<NIC>
```

관리 NIC가 flap하면 즉시 중단한다.

## 3. Jetson runtime bridge 설정

아래는 이번 실기용 runtime 설정이다. `<NIC1-TX>`, `<NIC2-RX>`를 실제로 확인한 이름으로 바꾼 뒤 Jetson 로컬 콘솔 또는 Wi-Fi/Tailscale SSH에서 실행한다. 기존 NetworkManager persistent profile과 섞지 않는다.

```bash
TX_PORT=<NIC1-TX>
RX_PORT=<NIC2-RX>
BR=br0

[ "$TX_PORT" != "$RX_PORT" ] || { echo 'same port'; exit 1; }
for p in "$TX_PORT" "$RX_PORT"; do
  [ -d "/sys/class/net/$p" ] || { echo "missing $p"; exit 1; }
  case "$p" in
    wl*|tailscale*|docker*|l4t*|usb*)
      echo "forbidden management/virtual port: $p"
      exit 1
      ;;
  esac
  ip route show default dev "$p" | grep -q . && {
    echo "default route uses $p"
    exit 1
  }
done

ip link show "$BR" >/dev/null 2>&1 && {
  echo "$BR already exists; inspect it instead of deleting it"
  exit 1
}

sudo nmcli device set "$TX_PORT" managed no 2>/dev/null || true
sudo nmcli device set "$RX_PORT" managed no 2>/dev/null || true

sudo ip link set dev "$TX_PORT" down
sudo ip link set dev "$RX_PORT" down
sudo ip -4 addr flush dev "$TX_PORT"
sudo ip -4 addr flush dev "$RX_PORT"

sudo ip link add name "$BR" type bridge \
  stp_state 0 forward_delay 0 vlan_filtering 0
sudo ip link set dev "$BR" mtu 1500
sudo ip link set dev "$TX_PORT" mtu 1500 master "$BR"
sudo ip link set dev "$RX_PORT" mtu 1500 master "$BR"
sudo ip link set dev "$TX_PORT" up
sudo ip link set dev "$RX_PORT" up

# RX telemetry를 Jetson에서 받을 때만 bridge에 둔다.
sudo ip addr replace 10.10.15.1/24 dev "$BR"
sudo ip link set dev "$BR" up
```

물리 member port에는 `.1/.2/.3`, DHCP, gateway를 두지 않는다. `10.10.15.1/24`는 필요할 때 bridge 자체에만 둔다. NAT, masquerade, proxy ARP, routing, MAC rewrite, VLAN filtering, bond/team, user-space relay를 쓰지 않는다.

Attack OFF baseline에서는 `br0`에 걸린 nftables bridge hook, ebtables, tc/netem/mirred, XDP/BPF 변조·drop 규칙이 없어야 한다. Docker/관리망을 망가뜨릴 수 있으므로 전역 `nft flush ruleset`이나 전체 firewall flush는 금지한다.

패킷 1:1 분석 또는 공격 모듈 개발 때만 두 전용 NIC의 GRO/LRO/GSO/TSO를 끄는 것을 검토한다. 먼저 정상 bridge 성능을 측정하고, 지원 여부를 `ethtool -k`로 기록한 뒤 적용한다. Zybo TX의 raw checksum 설정은 바꾸지 않는다.

## 4. 케이블 연결 순서

1. Jetson `br0`가 올라온 것을 먼저 확인한다.
2. 기존 TX↔RX 직결 케이블을 뺀다.
3. `Zybo TX wired -> Jetson NIC1-TX`로 연결한다.
4. `Jetson NIC2-RX -> Zybo RX wired`로 연결한다.
5. `Zybo RX HDMI -> capture board HDMI IN`을 유지한다.
6. `capture board USB -> PC`를 유지한다.
7. 두 Jetson port가 `Link detected: yes`, `1000Mb/s`, `Full`인지 확인한다.

두 bridge port를 같은 공유기나 같은 switch에 함께 꽂아 물리 loop를 만들면 안 된다.

```bash
bridge link show
for p in "$TX_PORT" "$RX_PORT"; do
  ethtool "$p" | grep -E 'Speed:|Duplex:|Link detected:'
  ip -br addr show dev "$p"
done
ip -4 -br addr show dev "$BR"
ip route show dev "$BR"
```

기대값:

- 두 slave 모두 `state forwarding`
- 두 slave의 IPv4 없음
- telemetry 사용 시 `br0`에만 `10.10.15.1/24`
- `10.10.15.0/24` connected route만 있고 `via`/default route 없음

## 5. link flap 직후 Zybo 주소 gate

실제 wired interface는 역할 MAC으로 찾는다. 현재 실기에서 이름이 `enx000a35001e53`였어도 이름을 영구 하드코딩하지 않는다.

```sh
for i in /sys/class/net/*; do
  printf '%s ' "${i##*/}"
  cat "$i/address"
done
```

TX 기대:

```text
MAC       02:00:00:00:00:02
IPv4      10.10.15.2/24
peer      10.10.15.3 -> 02:00:00:00:00:03 PERMANENT
route     10.10.15.0/24 scope link, via 없음
```

RX 기대:

```text
MAC       02:00:00:00:00:03
IPv4      10.10.15.3/24
route     10.10.15.0/24 scope link, via 없음
```

주소가 사라졌으면 VDMA/HDMI 고장으로 판단하거나 서비스를 재시작하지 않는다. 현재 old image의 DHCP deconfig 문제일 수 있다. 먼저 gate를 멈추고 중복 주소가 없는지 확인한 뒤, 필요한 역할 주소 한 줄만 복구한다.

```sh
# TX에서 .2가 없을 때만
ip addr add 10.10.15.2/24 dev <TX_WIRED_IF>

# RX에서 .3이 없을 때만
ip addr add 10.10.15.3/24 dev <RX_WIRED_IF>
```

`ip addr flush`, video/session service restart, `kill -9`, PL/VDMA reset, bitstream 재로딩부터 하지 않는다. 직결 실기에서는 주소 한 줄 복구만으로 기존 socket과 화면이 즉시 재개됐다.

## 6. Jetson L2 전달 확인

```bash
bridge link show
bridge fdb show br "$BR" | grep -Ei '02:00:00:00:00:0[23]'
```

기대 학습 위치:

```text
02:00:00:00:00:02 -> NIC1-TX
02:00:00:00:00:03 -> NIC2-RX
```

`tcpdump`가 있으면 짧게 교차 확인한다.

```bash
sudo timeout 5 tcpdump -p -eni "$TX_PORT" -nn 'arp or udp port 5602'
sudo timeout 5 tcpdump -p -eni "$RX_PORT" -nn 'arp or udp port 5602'
sudo timeout 5 tcpdump -ni "$BR" -nn -A \
  'udp dst host 10.10.15.1 and dst port 47000'
```

영상은 Ethernet `.02 -> .03`, IPv4 `10.10.15.2:5602 -> 10.10.15.3:5602`여야 한다. `any`나 bridge capture는 같은 packet이 중복 관찰될 수 있으므로 loss 계산은 두 physical port의 시작/끝 counter로 한다.

## 7. Session·AES gate

양쪽에서 root 권한으로 확인한다. 일반 사용자의 `kill -0` 권한 실패를 service stopped로 오판하지 않는다.

```sh
aes-session-check tx
aes-session-check rx
```

PASS 조건:

- 양쪽 동일한 nonzero `active_session`
- `key_valid=1`, `key_ready=1`
- `busy=0`, `error=0`, pending/terminate 없음
- TX/RX session agent와 video service running
- session interface는 `wl*`; 유선 bridge와 혼합되지 않음
- SW3 AES-GCM ON, Attack OFF

## 8. 실제 화면 포함 300-frame gate

권장 고정창은 15초다.

1. RX log의 마지막 `PIPE processed=...`와 `STATS ... lost total`을 시작값으로 기록한다.
2. 15초 뒤 같은 값을 다시 기록한다.
3. PC에서 `<Desktop>\jetson_to_pc\run_preview.bat`을 실행한다.
4. 실제 장면 또는 rolling test bar가 움직이는 것을 눈으로 확인한다.

15초 PASS 기준:

| 항목 | 기준 |
|---|---:|
| RX processed target | `>=443` 증가 (`29.5 fps`) |
| RX processed hard gate | `>=435` 증가 (`29.0 fps`) |
| 최소 frame | `>=300` |
| auth/replay/status/queue/stale delta | 모두 `0` |
| lost total delta | `0` |
| UDP checksum/rcvbuf error delta | `0` |
| Jetson 두 port drop/error delta | `0` |
| HDMI/capture freeze | 없음 |

PC 창의 약 58.5~60 fps는 HDMI 720p60 carrier다. 보안 영상 acceptance는 RX authenticated/display 약 29~30 fps와 실제 decoded pixel 이동으로 판정한다. preview 앱은 자동 PNG를 저장하지 않으며, 사진이 필요할 때만 `S`를 누른다.

VDMA PARK를 교차 확인할 때는 720p60 triple-buffer 주기와 alias되지 않도록 20~37 ms의 불규칙 간격으로 여러 번 읽는다. PC decoded pixel과 RX `processed`가 주 gate다.

## 9. Web/UI를 붙일 때의 경계

```text
Video data plane
Zybo TX -> Jetson kernel L2 bridge -> Zybo RX

Control/observability plane
PC browser <-> Jetson Wi-Fi/management NIC <-> Web/API
RX telemetry -> Jetson br0 10.10.15.1
Jetson management -> TX Session Control

Display plane
Zybo RX HDMI -> PC-local USB capture -> PC display
```

가장 단순한 Web 구성은 Jetson이 HTTPS UI/API를 제공하고, PC browser의 `getUserMedia()`가 PC에 연결된 USB capture를 직접 여는 방식이다. 영상은 PC browser 안에서만 표시하고 Jetson으로 업로드하지 않는다. UI에는 반드시 `PC LOCAL USB CAPTURE`라고 표시한다.

장시간 전시에서 DirectShow MJPG 1280×720 고정, 자동 reopen, watchdog가 더 중요하면 PC-local capture service가 localhost preview를 제공하고 Jetson API만 구독하는 구성을 쓴다.

Web/UI가 표시할 source는 분리한다.

- `JETSON LOCAL`: bridge/attack runtime
- `SESSION CONTROL ACK`: request/session/secure/weak 상태
- `RX FEEDBACK`: telemetry freshness, valid FPS, auth/replay/drop/jitter
- `AI RESULT`: anomaly score/model 결과
- `PC LOCAL`: USB capture carrier와 content update

금지사항:

- 정상 video 전체를 Jetson user-space/WebSocket/HTTP로 relay 또는 재인코딩
- PC USB capture를 PC→Jetson→PC로 왕복
- AES key, X25519 private key, Weak seed, PSK를 HTML/JSON/WebSocket/log에 노출
- HDMI carrier 60 fps를 authenticated video 60 fps로 표시
- ACK 전에 Session 상태를 ACTIVE로 optimistic 표시
- Web 장애가 L2 bridge나 TX boot auto-Secure를 block

## 10. 실패 시 순서

1. Attack OFF를 유지한다.
2. Jetson 두 carrier와 `bridge link/FDB`를 확인한다.
3. TX `.2`, RX `.3` 주소와 on-link route를 확인한다.
4. RX `PIPE processed`가 다시 증가하는지 확인한다.
5. session ID/key 상태를 확인한다.
6. 그 뒤에만 PC capture handle을 닫고 다시 연다.

주소가 없는데 RX service, VDMA, PL부터 재시작하지 않는다. 직접 케이블로 rollback할 때도 주소를 다시 확인한다.

## 관련 문서

- [`2026-08-09_TX_RX_이더넷_직결_실기검증.md`](2026-08-09_TX_RX_이더넷_직결_실기검증.md)
- [`ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md`](ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md)
