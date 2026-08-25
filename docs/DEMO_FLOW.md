# 발표 자료 기준 시연 흐름

이 문서는 `FPGA 암호화 가속기 기반 보안 관제 시스템.pptx`의 발표 순서를 현재 저장소의 실행 모듈에 연결합니다.

## 1. 정상 암·복호화

```text
PCam
  → Zybo TX: PL 영상 입력 및 AES-256-GCM 암호화
  → UDP/1GbE 암호화 전송
  → Jetson: 투명 L2 브리지
  → Zybo RX: 태그 인증 및 복호화
  → HDMI/USB Capture
  → PC 관제 UI
```

정상 모드에서는 RX의 인증 성공 프레임과 HDMI 화면, UI의 처리율·세션·패킷 메타데이터를 함께 확인합니다. TX의 기본 보안 경로에서는 암호화 전 카메라 평문을 DDR에 기록하지 않습니다.

## 2. 패킷 변조 공격

1. Jetson의 `INTEGRITY ATTACK` 화면에서 Tamper를 활성화합니다.
2. 중계 패킷의 ciphertext 일부를 변경하되 기존 GCM TAG는 그대로 둡니다.
3. RX는 태그 불일치를 감지하고 변조된 평문을 외부로 내보내지 않습니다.
4. PC/Jetson UI에서 인증 실패와 공격 이벤트를 확인합니다.

관련 구현:

- `03. 대시보드/03. 대시보드/젯슨 대시보드/tamper/`
- `03. 대시보드/03. 대시보드/젯슨 대시보드/backend/`

## 3. 리플레이 공격

1. Jetson이 정상 암호 패킷을 캡처합니다.
2. 저장한 패킷을 라이브 흐름에 재주입합니다.
3. RX가 session ID, frame ID, packet ID와 순서를 기준으로 재전송을 탐지합니다.
4. 대시보드에서 Replay 단계와 탐지 이벤트를 확인합니다.

관련 구현: `03. 대시보드/03. 대시보드/젯슨 대시보드/replay/`

## 4. 취약 키 검색 시연

1. Dashboard가 TX에 교육용 Weak Session 생성을 요청합니다.
2. request ID, profile, seed bits, session ID가 모두 일치한 패킷만 검색 입력으로 확정합니다.
3. CPU 또는 CUDA 검색기가 제한된 시드 공간을 탐색하고 GCM TAG로 후보 키를 검증합니다.
4. 성공한 키로 데모 프레임을 복구합니다.
5. 사용자가 요청한 경우에만 Jetson 로컬 VLM이 복구 화면을 분석합니다.
6. 종료·초기화 시 Secure Session 복귀를 확인합니다.

관련 구현:

- `03. 대시보드/03. 대시보드/젯슨 대시보드/bruteforce/`
- `03. 대시보드/03. 대시보드/젯슨 대시보드/local-vlm-test/`

이 시나리오는 제한된 시드 엔트로피의 취약성을 보여주기 위한 것으로, 일반적인 AES-256 키 공간에 대한 전수공격 결과가 아닙니다.

## 5. 관제 화면 확인

Jetson Dashboard는 다음 세 화면으로 구성됩니다.

- `NORMAL FLOW`: 패킷 속도, 처리량, 엔트로피, IAT, NIC 오류와 전력
- `INTEGRITY ATTACK`: Tamper/Replay 상태와 공격 결과
- `WEAK-KEY SEARCH`: 세션 준비, 키 검색, 복구 프레임과 VLM 결과

PC Dashboard는 RX HDMI 캡처, RX UART 보안 텔레메트리, 공격 타임라인과 AI 근거를 함께 표시합니다.

## 6. 검증 항목

발표 자료에 기록된 검증 결과는 다음과 같습니다.

| 구분 | 검증 내용 | 결과 |
|---|---|---|
| NIST KAT | AES-256 ECB 코어 및 키 확장 표준 벡터 | 405/405 PASS |
| TX | 1,280개 패킷의 Ciphertext/AAD/TAG, 출력 stall 안정성 | PASS |
| RX | 정상, TAG/Ciphertext 변조, 복귀, Replay, Sequence, Session, Timeout | 8개 시나리오 PASS |
| 시스템 | 실시간 암·복호화 영상, 공격 이벤트, 관제 UI, 로컬 VLM | 실기 확인 |

