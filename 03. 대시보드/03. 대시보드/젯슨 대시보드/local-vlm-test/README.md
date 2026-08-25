# Jetson Local VLM

Weak-Key 검색으로 복구한 이미지 또는 사용자가 고른 이미지 한 장을 Jetson에서 분석한다.

## 구성

- Jetson Orin Nano 8GB
- NVIDIA Cosmos-Reason2-2B Q4_K_M GGUF
- F16 vision projector GGUF
- CUDA-enabled llama.cpp
- 앱/API 포트 `4188`
- model server 포트 `4190`
- cloud API 없음

## 실행

```bash
cd /home/jetson/local-vlm-test
./start.sh
```

서비스 실행:

```bash
systemctl --user enable --now zybo-local-vlm.service
```

브라우저에서 `http://<Jetson 주소>:4188/`을 열고 이미지를 선택한 뒤 분석 버튼을 누른다. 이미지 선택만으로 inference가 시작되지 않는다.

## 파일

- `app.py`: 이미지 검증, llama.cpp 요청, 결과 정규화, 웹 API
- `web/`: 독립 테스트 UI
- `models/`: Cosmos model과 vision projector
- `runtime/llama.cpp/build/bin/`: 실행에 필요한 llama.cpp CUDA binary와 library
- `start.sh`, `stop.sh`, `start_model.sh`: 수동 실행 스크립트
- `run-vlm-service.sh`, `zybo-local-vlm.service`: 부팅 후 서비스 실행
- `TEST_RESULTS.md`, `test-results/`: 2026-08-12 cold/warm 및 Page 03 recovered-frame 분석 결과
- `samples/`: 검증에 사용한 입력 이미지

환경 변수 `VLM_TEST_PORT`, `VLM_MODEL_PORT`, `VLM_MODEL_API`, `VLM_MODEL_NAME`으로 실행값을 바꿀 수 있다.

## 2026-08-17 실제 Jetson 대조

- 실제 `/home/jetson/local-vlm-test`의 앱, 실행 스크립트, CUDA llama.cpp 구성과 두 GGUF 모델을 이 보관본과 SHA-256으로 비교했다.
- Cosmos model SHA-256은 `3ed011641891e81fe654328071de251718832e7deafef579033485d33082e4fd`다.
- vision projector SHA-256은 `8d3284c340d6a9c9237d56f2fc42f2df50d3761f539f3f01be964cefb0b73916`다.
- 실제 user service는 enabled/active이며 API 4188과 model server 4190이 listening 상태다.
- 실제 Jetson에만 있던 `TEST_RESULTS.md`, 세 JSON 결과와 검증 입력 이미지를 보관본에 회수했다.
