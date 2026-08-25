> [!IMPORTANT]
> **역사 자료 — V1 최종 동결 문서에 의해 대체됨**
>
> 이 문서는 초기 RSA/SW2/BTN3 기반 적용 검토 기록이다. 현재 구현·운용 규칙은 [`ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md`](./ZYBO_Jetson_보안데모_V1_FINAL_FREEZE_20260809.md)를 따른다. 특히 X25519/HKDF, TX 부팅 시 Secure 자동 생성, Jetson의 이후 Secure 재생성/Weak override, SW3-only 규칙이 이 문서보다 우선한다.

# EU CRA Jetson GPU 데모 적용 검토

## 결론

이 데모는 현재 통합 기준본을 기반으로 구현할 수 있다. 다만 **Zybo의 안정화된 영상·AES-GCM·무선 RSA 경로는 유지하고, Weak Demo Profile과 Jetson 캡처/CUDA/UI를 별도 데모 계층으로 추가**해야 한다.

- 현재 기준본에서 그대로 재사용할 수 있는 핵심: 1280×720 YUYV 영상, 유선 UDP 전송, PL AES-256-GCM, RX 인증 실패 프레임 차단, N150UA RSA 세션키 교환, SW2 재키잉, BTN3 종료·해제 재시작
- 새로 필요한 핵심: 의도적으로 제한된 키 공간, Jetson 패킷 캡처·재조립, CUDA 후보 키 검증, 복구 키 영상 표시, 실제 텔레메트리, 통제된 변조·Replay 시험
- 권장 개발 방식: Secure 기준본을 직접 약화하지 않고 `${TOP}`에서 별도 `CRA_JETSON_DEMO` 파생본을 만든다.
- 권장 1차 목표: TX가 숨겨진 20~24비트 seed로 Weak 세션을 만들고, Jetson이 실제 패킷으로 키를 복구해 영상을 연 뒤, 기존 RSA 재키잉으로 Secure 세션에 전환하여 이전 키 접근 실패를 보여준다.

외부 원본 시나리오 문서와 HTML 프로토타입은 이 검토에서 수정하지 않았다.

## 1. 현재 기준본에서 재사용 가능한 항목

### 1.1 Secure 세션 키와 무선 제어 평면

현재 TX는 세션마다 Linux entropy로 seed된 OpenSSL private DRBG를 사용해 AES-256 키를 새로 생성한다.

- 구현: `${TOP}/session_control/aes_session_agent.c`
- 키 생성: `RAND_priv_bytes_ex(..., 256)`
- RSA: RSA-2048 OAEP-SHA256
- 확인 절차: HMAC-SHA256 `READY` → `COMMIT` → `DONE`
- 종료 절차: HMAC-SHA256 `TERMINATE` → `TERMINATED`
- 무선 포트: discovery UDP 46099, session TCP 46100

따라서 시나리오의 Secure Production Profile과 Corrective Action은 기존 제어 경로를 그대로 사용할 수 있다.

### 1.2 영상 데이터 평면

영상은 N150UA가 아니라 유선 Ethernet으로 전송한다. 현재 패킷 규격은 다음과 같다.

| 항목 | 현재 값 |
|---|---:|
| 해상도/포맷 | 1280×720 YUYV |
| 영상 크기 | 1,843,200B/frame |
| 패킷 수 | 1280 packets/frame |
| AAD | 16B |
| 영상 payload | 1440B |
| GCM TAG | 16B |
| UDP data | 1472B |
| IPv4 + UDP 포함 | 1500B |
| UDP 포트 | 5602 |

AAD는 다음 16바이트다.

```text
magic[32] | session_id[32] | frame_id[32] | packet_index[16] | flags[16]
```

Nonce는 다음과 같이 결정적으로 복원할 수 있다.

```text
session_id[32] | frame_id[32] | 0x0000[16] | packet_index[16]
```

근거 소스는 다음이다.

- `${TOP}/AES_GCM_TX/vivado/rtl/aes256_gcm/gcm_protocol_pkg.sv`
- `${TOP}/AES_GCM_RX/vivado/rtl/aes256_gcm/gcm_protocol_pkg.sv`
- `${TOP}/AES_GCM_TX/petalinux/project-spec/meta-user/recipes-apps/pcam-gcm-tx/files/pcam-gcm-udp-tx.c`
- `${TOP}/AES_GCM_RX/petalinux/project-spec/meta-user/recipes-apps/aes-gcm-rx/files/aes-gcm-rx.c`

Jetson은 AAD, nonce, ciphertext, TAG를 모두 패킷에서 얻을 수 있으므로 표준 AES-GCM 구현으로 후보 키를 검증할 수 있다. 복구 후 1280개 payload를 packet index 순으로 이어 붙이면 실제 1280×720 YUYV 한 프레임이 된다.

30fps의 순수 영상 payload는 약 442.368Mbps이고 Ethernet preamble/IFG까지 포함한 실제 선로 사용량은 약 472Mbps다. 이 수치 때문에 영상은 계속 유선 경로에 두고 N150UA는 RSA·상태·로그 같은 저속 제어에만 사용해야 한다.

### 1.3 RX의 현재 보안 동작

RX PL은 다음을 이미 검사한다.

- 수신 session ID와 PL active session ID 일치
- magic/version/SOF/EOF/packet index 순서
- AES-GCM TAG
- 프레임 전체 형식과 마지막 packet 경계

실패가 하나라도 있으면 해당 프레임은 HDMI 표시 대상으로 승인하지 않는다. 따라서 다음 두 시험의 기반은 이미 있다.

- 암호문 변조 후 TAG/format 실패 프레임 폐기
- 재키잉 전 session ID 패킷을 새 session에서 거부

단, 현재 소프트웨어가 내보내는 `authentication_failures`는 **프레임 단위 통합 실패 수치**다. TAG 실패, session 불일치, 형식 실패를 각각 분리한 카운터는 아직 없다.

## 2. 원본 시나리오와 현재 구현의 차이

### 2.1 1440패킷 표기는 현재 규격과 다름

현재 규격은 `1440 packets × 1280B`가 아니라 다음이다.

```text
1280 packets × 1440B video payload
UDP data = 16B AAD + 1440B video + 16B TAG = 1472B
```

따라서 Replay 화면의 `Old session packets: 1,440`은 `1,280`으로 해석해야 한다.

### 2.2 재키잉 때 frame counter는 리셋되지 않음

현재 TX RTL에서 key commit은 AES round key만 갱신하며 frame ID를 0으로 되돌리지 않는다. frame ID는 프레임 완료마다 계속 증가하고 packet index만 매 프레임 0으로 돌아간다.

이 동작은 새 session ID가 nonce에 포함되므로 보안상 문제가 없다. 데모 문구는 다음처럼 쓰는 것이 정확하다.

```text
새 session ID와 새 key 적용
frame ID는 연속 증가
packet index는 각 프레임에서 0부터 재시작
```

### 2.3 양쪽 동시 commit은 아님

현재 절차는 다음 순서다.

```text
RX PENDING 내구 저장
→ RX PL 원자적 commit
→ RX DONE 증명
→ TX가 DONE 검증
→ TX PL 원자적 commit
```

각 보드 내부의 키 교체는 안전한 스트림 경계에서 원자적이지만 TX와 RX가 같은 클럭에 동시에 바뀌는 구조는 아니다. UI에는 `two-phase coordinated commit` 또는 `RX commit 확인 후 TX commit`으로 표시해야 한다.

절대 동시 전환과 제어망 장애 중 무중단 암호 영상을 보장하려면 old/new dual-key 슬롯과 적용 frame ID가 추가로 필요하며, 이는 별도의 큰 RTL·프로토콜 변경이다.

### 2.4 Replay 방어 범위를 구분해야 함

현재 구현은 **이전 session ID** 패킷을 새 active session에서 거부한다. 따라서 시나리오의 `S-0001 패킷을 S-0002에 재주입`하는 시험은 가능하다.

반면 현재 RX에는 같은 active session 안에서 이미 인증한 과거 frame ID를 기억하는 replay window가 없다. 따라서 다음처럼 주장 범위를 나눠야 한다.

- 현재 그대로 가능: `OLD_SESSION_DROP`, 과거 세션 격리
- 추가 구현 필요: 같은 세션의 중복 frame/packet Replay 방어와 replay window

완성형에서는 인증 성공 후 최고 frame ID와 bitmap window를 갱신하고, 이전/중복 frame은 HDMI publish 전에 폐기해야 한다.

### 2.5 96.4M candidates/s는 아직 실측값이 아님

HTML과 시나리오의 `96.4M candidates/s`는 UI 예시 값이다. 현재 한 레코드는 `AAD 16B + ciphertext 1440B + TAG 16B`이고 ciphertext는 128비트 블록 90개다. 후보 키로 **TAG만 검증**할 때의 최소 연산은 AES-256 key expansion, `H = AES_K(0^128)` 1블록, `E_K(J0)` 1블록, 그리고 `AAD 1 + ciphertext 90 + length 1 = GHASH 92블록`이다. 후보마다 payload를 복호화하는 CTR AES 90블록은 필요하지 않으며, TAG가 맞은 최종 후보의 영상 확인 단계에서만 수행하면 된다.

| 후보 판정 레코드 | 후보당 최소 핵심 연산 | 정합성 |
|---|---|---|
| 현재 1440B 영상 레코드 전체 TAG | key expansion + AES 2블록 + GHASH 92블록 | 실제 영상 레코드를 직접 검증하므로 최종 판정 가능 |
| 별도 `AAD 16B + ciphertext 16B` `CRACK_CHECK` | key expansion + AES 2블록 + GHASH 3블록 | 같은 세션 키와 별도 고유 nonce로 생성하고 실제 영상 TAG로 최종 재확인 필요 |
| 별도 `AAD 0B + ciphertext 16B` 검사 레코드 | key expansion + AES 2블록 + GHASH 2블록 | 프로토콜에 명시한 별도 검사 레코드일 때만 가능 |
| AAD·ciphertext가 모두 빈 검사값 | key expansion + 사실상 `E_K(J0)` | GCM 영상 검증이라기보다 노골적인 key-check value가 되므로 권장하지 않음 |

- 실제 CUDA 측정 전에는 30비트를 수초 내 복구한다고 고정하지 않는다.
- 우선 20~24비트에서 측정한다.
- 화면에는 반드시 실측 `candidates/s`와 그 값으로 다시 계산한 예상 시간을 사용한다.
- 현재 영상 레코드는 모두 `AAD 16B + ciphertext 1440B + TAG 16B`로 길이가 같다. 따라서 캡처한 영상 패킷에서 ciphertext 앞 16~32B만 잘라 기존 TAG로 검증할 수 없다. GCM TAG는 AAD, ciphertext 전체와 각 길이를 인증하기 때문이다.
- 전체 영상 레코드 검증이 너무 느리면 Weak profile에서만 같은 세션 키와 **별도의 고유 nonce**로 생성한 16B짜리 명시적 `CRACK_CHECK` GCM 레코드를 추가한다. 이 레코드로 후보를 1차 판정하고, 실제 1440B 영상 패킷 TAG와 복호화 영상으로 최종 재확인한다.
- 다른 대안은 영상의 고정 위치에 16B known-plaintext marker를 넣어 AES-CTR 한 블록으로 대부분의 후보를 먼저 거르는 것이다. 이 경우에도 최종 합격은 전체 GCM TAG로만 판정한다.
- NVIDIA의 SHA-256 단독 처리량을 혼합 워크로드의 속도로 대입하지 않는다. 실제 커널은 KDF, AES-256 key schedule, CTR 또는 GCM 검증을 함께 수행하므로 별도 벤치마크가 필요하다.

### 2.6 KDF 비용은 줄일 수 있지만 사실과 다르게 설명하면 안 됨

후보마다 SHA-256을 계산하면 비용이 추가된다는 지적은 맞다. 그러나 구현은 단순 패딩인데 발표에서는 SHA-256 KDF라고 설명하는 방식은 등가 구현이 아니며 재현성과 데모 신뢰성을 깨므로 사용하지 않는다.

권장 우선순위:

1. 먼저 문서에 정의한 `SHA-256("CRA-WEAK-V1" || N || seed)`를 그대로 구현하고 실측한다.
2. 메시지가 SHA-256 한 블록에 들어가므로 CUDA에서는 고정 prefix·padding을 사전 구성하고 정확한 SHA-256 라운드만 후보별로 수행한다.
3. 처리량이 부족하면 `key = fixed_prefix || zero_padding || seed` 같은 단순 공개 매핑으로 바꿀 수 있으나, 이를 SHA-256의 최적화 또는 등가 구현이라고 부르지 않는다. 후보 공간의 개수가 `2^N`이라는 점만 같을 뿐, 후보당 작업량·키 분포·충돌 성질·보안 의미는 다르다.
4. 어떤 KDF를 사용해도 입력 seed가 N비트면 실질 키 공간은 최대 `2^N`이라는 교육 메시지는 유지된다.
5. 경량 매핑을 쓰면 `DEMO-KDF-v1`처럼 별도 이름과 profile version을 부여하고 정확한 비트 매핑을 공개한다. 후보 키 테이블 사전 계산을 사용했다면 사전 계산 시간과 메모리를 검색 시간과 분리해 화면·보고서에 함께 표시한다.

## 3. Weak Demo Profile 권장 구조

### 3.1 hidden seed 방식

관객이 입력한 패스프레이즈를 공격 프로그램인 Jetson이 직접 받으면 Jetson이 이미 원본 비밀을 아는 문제가 생긴다. 따라서 MVP는 다음 구조가 더 설득력 있다.

```text
관객: N비트 난이도만 선택
  ↓
TX: CSPRNG로 균일한 숨겨진 N비트 seed 생성
  ↓
AES key = SHA-256("CRA-WEAK-V1" || N || seed)
  ↓
기존 RSA/HMAC 절차로 RX에 AES key 전달
  ↓
Jetson: N과 공개된 KDF만 알고 0..2^N-1 후보 탐색
```

MVP 기본값은 20~24비트로 시작하고 실제 Jetson 처리량을 측정한 뒤 전시 시간에 맞춰 조정한다. Weak seed와 AES key 자체는 Zybo 로그, WebSocket, HTML에 출력하지 않는다. 키 복구 성공 후에도 화면에는 후보 번호나 일부 fingerprint만 표시하는 것이 좋다.

CUDA 구현 전 CPU/OpenSSL 기준 구현에서 다음 세 처리량을 따로 측정한다.

- KDF만 수행한 후보/s
- KDF + `CRACK_CHECK` 한 레코드 검증 후보/s
- KDF + 실제 1440B 영상 레코드 전체 TAG 검증 후보/s

화면의 예상 시간은 실제 데모에서 선택한 판정 경로의 두 번째 또는 세 번째 수치로 계산한다.

### 3.2 Secure 기본, Weak 별도 파생

Weak 모드는 제품 기능이 아니라 교육용 취약 설정이다. 다음 조건을 지켜야 한다.

- Secure profile이 부팅 기본값
- Weak profile은 별도 데모 파생본 또는 `ENABLE_CRA_WEAK_DEMO` 빌드에서만 허용
- 일반 운용 이미지에는 Weak profile 진입 명령을 포함하지 않음
- Weak 상태를 UI에 항상 크게 표시
- 격리된 소유 시험망에서만 사용
- Jetson 도구는 `10.10.15.2 → 10.10.15.3`, UDP 5602, `PCAM` magic으로 대상을 제한
- RSA를 공격한다고 표현하지 않음. 데모 대상은 의도적으로 줄인 AES 키 생성원의 엔트로피임

## 4. Jetson 연결 토폴로지

### 4.1 일반 공유기 또는 unmanaged switch의 한계

일반 공유기의 LAN switch는 TX→RX 유니캐스트 MAC을 학습하면 해당 RX 포트로만 전달한다. Jetson을 빈 LAN 포트에 꽂는 것만으로는 영상 패킷이 Jetson에 복제되지 않는다.

또한 N150UA/AP를 영상 캡처 경로로 쓰는 것은 현재 약 472Mbps 선로 트래픽과 검증된 N150UA 처리량 차이 때문에 불가능하다.

### 4.2 수동 캡처 권장: 관리형 switch SPAN

키 탐색과 비인가 복호화까지만 시연할 때는 관리형 switch의 port mirroring/SPAN이 가장 안정적이다.

```text
Zybo TX ──┐
          ├─ Managed Gigabit switch ── Zybo RX
          └─ SPAN mirror ───────────── Jetson
```

장점:

- Zybo TX/RX 소스와 주소를 바꾸지 않음
- 30fps 기준 경로에 사용자 공간 relay를 넣지 않음
- Jetson 캡처 프로그램이 중단돼도 RX 영상은 계속 동작

한계:

- 원본 패킷을 대체하는 능동 변조에는 부적합
- Replay 주입은 가능해도 원본과 충돌하지 않도록 정밀한 타이밍이 필요

### 4.3 능동 변조·Replay 권장: Jetson 2-NIC 인라인

변조와 Replay까지 신뢰성 있게 시연하려면 Jetson에 Gigabit NIC 두 개를 사용하고 Linux kernel bridge로 TX와 RX 사이에 둔다.

```text
Zybo TX ── Jetson NIC 1 ── kernel bridge ── Jetson NIC 2 ── Zybo RX
```

- 정상 포워딩은 Linux kernel bridge가 수행한다.
- Python/사용자 공간에서 472Mbps 전체를 relay하지 않는다.
- 시험 코드는 지정된 UDP 5602 PCAM 레코드만 관찰한다.
- 1비트 변조 시 UDP checksum도 다시 계산한 패킷으로 대체해야 한다. checksum이 틀리면 Linux UDP 계층이 먼저 폐기하여 GCM 검출 시험이 되지 않는다.
- Replay는 정상 S-0002 스트림을 계속 전달하면서 프레임 경계에 저장한 S-0001 한 프레임을 삽입해야 한다.

Jetson의 두 bridge port에는 IP를 두지 않고 관리·UI 접속은 Jetson Wi-Fi 또는 별도 관리 포트를 사용하면 공격 경로와 제어 경로를 분리할 수 있다. 정상 전달은 kernel bridge가 맡기고, 선택한 시험 패킷만 nftables/TC/XDP 계층에서 표시·복제·폐기·변조하도록 설계한다.

### 4.4 현재 기준본에서는 일반 ARP spoof MITM이 성립하지 않음

일반적인 동적 ARP 기반 IP/UDP 송신기라면 ARP spoofing으로 같은 L2 망에서 MITM을 구성할 수 있다. 그러나 현재 TX 시작 스크립트는 부팅 순서에 따른 ARP race를 없애려고 RX의 `10.10.15.3 → 02:00:00:00:00:03` neighbour를 `nud permanent`로 고정한다. 이어서 30fps 경로는 일반 UDP 송신이 아니라 AF_PACKET RAW 송신이며, 시작할 때 `SIOCGARP`로 그 목적지 MAC을 한 번 읽어 `raw_sender.destination_mac`에 저장한 뒤 모든 Ethernet header에 계속 재사용한다.

소스 근거는 `${TOP}/AES_GCM_TX/petalinux/project-spec/meta-user/recipes-apps/pcam-gcm-tx/files/pcam-gcm-tx`의 permanent neighbour 설정과 `${TOP}/AES_GCM_TX/petalinux/project-spec/meta-user/recipes-apps/pcam-gcm-tx/files/pcam-gcm-udp-tx.c`의 `setup_raw_sender()`, TX ring/sendmmsg Ethernet header 생성부다.

따라서 현재 기준본에서는 다음 제약이 있다.

- 현재 그대로는 permanent neighbour 때문에 일반 ARP poison이 적용되지 않는다. 커널 neighbour를 별도로 바꾸더라도 이미 시작된 TX 프로세스는 목적지 MAC을 다시 조회하지 않으므로 기존 영상 흐름은 바뀌지 않는다.
- ARP MITM을 쓰려면 별도 데모 파생본에서 permanent neighbour를 제거하고 poison된 neighbour가 설치된 뒤 RAW sender를 시작하거나, TX가 neighbour 변경을 안전하게 다시 읽도록 수정해야 한다. 이는 현재 기준본을 그대로 공격하는 시연이 아니라 **의도적으로 네트워크 동작을 바꾼 파생 모드**다.
- TX 네트워크 hot path를 수정하면 이미 검증한 약 29.5fps와 손실 0 기준을 다시 검증해야 한다.
- 약 472Mbps·38,400 packet/s를 Python Scapy 사용자 공간 relay로 전부 중계하는 방식은 라이브 데모 주 경로로 사용하지 않는다.

따라서 **수동 관찰·키 복구는 관리형 switch SPAN**, **능동 변조·Replay는 Jetson 2-NIC 투명 kernel bridge**로 역할을 나누는 것이 맞다. 투명 bridge는 원래 RX 목적지 MAC을 보존해 전달하므로 TX의 고정 neighbour와 충돌하지 않는다. ARP MITM은 배선 변경 없는 공격 스토리에는 매력적이지만 현재 기준본의 기능으로 주장하지 않고, 필요할 때만 명확히 표시한 별도 실험 모드로 둔다.

## 5. 변경량과 빌드 영향

### 5.1 MVP

| 구성 | 예상 신규/변경량 | 주요 내용 |
|---|---:|---|
| TX Weak profile + 호스트 테스트 | 약 150~250 LOC | hidden seed, KDF, Secure 기본, profile 선택 |
| Jetson 패킷 파서 + CPU 기준 구현 | 약 250~450 LOC | libpcap/AF_PACKET, AAD/nonce, OpenSSL golden check |
| CUDA 탐색 | 약 500~900 LOC | AES-256 key expansion, GCM 검증, batching, benchmark |
| YUYV 표시 + backend + WebSocket/UI 연결 | 약 400~800 LOC | 프레임 재조립, GStreamer/OpenCV, 실제 이벤트 전달 |
| 테스트·설정·보고서 | 약 150~300 LOC | test vector, 자동 결과, manifest |
| 합계 | 약 1,500~3,000 LOC | 기존 PL 영상 엔진 재사용 |

MVP 빌드 영향:

- Vivado/bitstream 변경: 필요 없음
- PetaLinux: Weak profile을 포함한 데모용 TX 이미지 재빌드 필요
- 공유 session agent의 동일 버전을 유지하려면 RX PetaLinux도 함께 재빌드·manifest하는 것을 권장
- Jetson: 별도 aarch64/CUDA 애플리케이션 빌드 필요

### 5.2 완성형

MVP에 다음이 추가된다.

| 추가 구성 | 예상 신규/변경량 | 빌드 영향 |
|---|---:|---|
| 2-NIC 통제 relay·변조·Replay | 약 300~700 LOC | Jetson만 빌드, 네트워크 설정 추가 |
| RX 원인별 카운터와 same-session replay window | 약 300~700 LOC + 검증 | RX C 또는 RX RTL/AXI register 변경 |
| PL TAG_OK/TAG_FAIL/OLD_SESSION/REPLAY 카운터 | RTL·TB 약 300~600 LOC | RX Vivado→XSA→PetaLinux 전체 재빌드 |
| 자동 시나리오·보고서·UI hardening | 약 400~800 LOC | Jetson/UI 재빌드 |

완성형 전체는 약 3,000~5,500 LOC 규모로 보는 것이 현실적이다. PL 원인별 카운터를 추가하면 RX Vivado 구현, timing/DRC, XSA, PetaLinux, JTAG/SD 실기 검증을 모두 다시 수행해야 한다.

## 6. 예상 파일·컴포넌트

현재 기준본에서 변경 가능성이 있는 파일:

- `${TOP}/session_control/aes_session_agent.c`
- `${TOP}/session_control/aes-session-tx.init`
- `${TOP}/session_control/Makefile`
- `${TOP}/AES_GCM_TX/petalinux/build_petalinux.sh`
- `${TOP}/AES_GCM_TX/petalinux/project-spec/meta-user/recipes-apps/aes-session-agent/`

Weak 코드는 기존 production crypto에 뒤섞지 않고 다음처럼 분리하는 것이 좋다.

```text
${TOP}/CRA_JETSON_DEMO/
├─ common/pcam_gcm_protocol.*
├─ zybo/demo_weak_profile.*
├─ jetson/capture/pcam_gcm_capture.*
├─ jetson/cuda/aes256_gcm_search.cu
├─ jetson/crypto/reference_verify.*
├─ jetson/display/yuyv_viewer.*
├─ jetson/relay/controlled_fault_injector.*
├─ backend/
├─ ui/
└─ tests/
```

완성형 텔레메트리에서만 변경할 후보:

- `${TOP}/AES_GCM_RX/petalinux/project-spec/meta-user/recipes-apps/aes-gcm-rx/files/aes-gcm-rx.c`
- `${TOP}/AES_GCM_RX/vivado/rtl/aes256_gcm/video_aes_gcm_rx_top.sv`
- `${TOP}/AES_GCM_RX/vivado/rtl/rx/axis_gcm_rx_frame_processor_v2.sv`
- RX block-design Tcl과 새 AXI 상태 레지스터

## 7. 권장 구현 순서

1. 현재 Secure 기준본의 Vivado/PetaLinux/JTAG 실기 검증과 manifest를 먼저 완료한다.
2. 기준본을 복사해 별도 `CRA_JETSON_DEMO` 파생을 만든다.
3. Jetson CPU 기준 파서로 실제 UDP 레코드의 AAD/nonce/TAG를 검증한다.
4. TX PS에 Secure 기본의 hidden 20~24bit Weak profile을 추가하고 호스트 테스트한다.
5. 기존 RSA/HMAC 교환을 그대로 사용해 Weak key를 RX PL에 적용한다.
6. CUDA 결과를 CPU/OpenSSL 결과와 KAT로 비교하고 실제 `candidates/s`를 측정한다.
7. 복구한 키로 1280개 레코드를 복호화·재조립해 실제 YUYV 영상을 Jetson에 표시한다.
8. 기존 SW2 또는 BTN3 해제 흐름으로 새 256비트 Secure 세션을 만들고 이전 키 실패를 확인한다.
9. HTML 시뮬레이션 값을 실제 Jetson WebSocket 이벤트로 교체한다.
10. 2차 단계에서 checksum을 보존한 1비트 변조와 old-session Replay를 추가한다.
11. 필요할 때만 RX 원인별 PL 카운터와 same-session replay window를 추가한다.

## 8. 완료 판정

### 8.1 MVP 완료 조건

- Secure 부팅 기본값이며 명시적 데모 명령 없이는 Weak 모드가 되지 않는다.
- TX가 선택한 N비트 hidden seed/key가 로그와 UI에 노출되지 않는다.
- Weak 세션도 기존 RSA READY/COMMIT/DONE을 통해 TX/RX에 동일하게 적용된다.
- Jetson CPU 기준 구현이 실제 캡처한 레코드의 TAG를 검증한다.
- CUDA 결과가 CPU 기준값 및 독립 test vector와 일치한다.
- 화면의 후보 수와 처리량은 시뮬레이션 값이 아니라 실제 측정값이다.
- 복구 키로 최소 한 프레임이 아니라 연속 실제 YUYV 영상이 표시된다.
- Secure 재키잉 후 session ID가 바뀌고 이전 복구 키의 TAG 검증이 실패한다.
- Secure 재키잉 중 Zybo RX HDMI 영상이 정상 복구되고 기존 30fps 경로에 지속적인 성능 저하가 없다.
- 보고서에 프로파일, 실제 entropy, 실측 rate, session 전환, 소프트웨어 버전, bit/XSA hash가 기록된다.

### 8.2 완성형 완료 조건

- 암호문 1비트 변경 패킷의 UDP checksum이 유효한 상태로 RX에 도착한다.
- 변경 전에는 TAG 성공, 변경 후에는 GCM 실패와 프레임 미표시가 확인된다.
- 정상 S-0002 스트림을 유지하면서 S-0001 프레임을 주입하고 이전 세션 거부를 확인한다.
- `TAG_FAIL`, `OLD_SESSION_DROP`, `REPLAY_DROP`가 실제 서로 다른 계측 근거로 집계된다.
- 같은 활성 세션의 중복 frame replay도 window 정책에 따라 거부된다.
- Jetson relay를 종료하거나 CUDA/UI가 실패해도 kernel bridge의 정상 영상 전달이 유지된다.
- 모든 PASS/FAIL은 UI 연출이 아니라 원본 로그·카운터·패킷 캡처와 연결된다.

## 9. 발표 운영 리스크와 사전 조치

| 리스크 | 실제 문제 | 사전 조치 |
|---|---|---|
| 무작위 hidden seed 위치 | 탐색 시간은 거의 즉시부터 최악 `2^N / rate`까지 달라짐 | 평균 시간이 아니라 **최악 시간**이 발표 슬롯 안에 들어오도록 N을 정하고 여러 seed로 리허설 |
| CUDA 최초 실행 | context 생성, 모듈 로드/JIT, 메모리 할당이 첫 측정에 섞임 | 발표 전 동일 바이너리로 warm-up하고 warm-up 시간과 실제 탐색 시간을 분리 표시 |
| Jetson 열·전력 제한 | 장시간 실행 시 clock throttling으로 rate가 달라짐 | 동일 전원·성능 모드·냉각 조건을 고정하고 온도와 실측 rate를 UI에 표시 |
| SPAN 캡처 손실 | mirror oversubscription이나 작은 캡처 버퍼로 프레임 재조립 실패 | Gigabit full-rate SPAN, AF_PACKET ring, sequence/frame 누락 카운터를 사용 |
| inline 장치 장애 | Jetson 재부팅·NIC/bridge 실패가 RX 영상을 끊을 수 있음 | 수동 SPAN 시연을 기본으로 두고, 능동 시연은 별도 리허설 및 즉시 복구용 직결/bypass 배선을 준비 |
| checksum/offload 혼동 | 변조 패킷이 GCM 전에 UDP 계층에서 버려져 원인을 잘못 해석 | IPv4 UDP checksum을 유효하게 재계산하거나 정책상 0으로 설정하고, 실제 wire capture로 확인; GRO/GSO/TSO 조건 고정 |
| UI와 실제 이벤트 불일치 | 임의 애니메이션이 증거처럼 보일 수 있음 | UI 이벤트마다 capture ID, session ID, frame/packet ID, 단조 시각을 실제 로그와 연결 |
| Weak 설정 잔존 | 전시용 저엔트로피 profile이 운영 이미지에 남을 수 있음 | Secure 기본, 별도 데모 빌드, 화면 상시 경고, manifest/hash로 배포 이미지 구분 |

## 10. 발표 범위

이 데모는 다음처럼 설명한다.

> 소유한 격리 시험망에서 의도적으로 제한한 키 생성원의 실질 엔트로피를 Jetson CUDA로 측정하고, 복구한 키로 실제 암호 영상을 열어 위험을 확인한 뒤, 기존 RSA 재키잉으로 안전한 256비트 무작위 세션으로 전환해 이전 키 접근과 통제된 변조·Replay가 차단되는지 재검증한다.

다음 표현은 사용하지 않는다.

- 실제 AES-256 전체 키 공간을 깨뜨렸다.
- RSA를 해킹했다.
- 몇 초 실패로 AES-256의 안전성을 증명했다.
- CRA 전체 적합성 인증을 획득했다.
- 현재 구현이 모든 형태의 Replay를 이미 차단한다.
