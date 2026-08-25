# Jetson Local VLM Test Results

Tested on 2026-08-12. This standalone app did not import, modify, or call the AES-GCM / weak-key demo.

## Environment

- Device: Jetson Orin Nano 8GB, 25W mode
- L4T: R36.5.2
- CUDA: 12.6
- Runtime: CUDA-enabled llama.cpp, commit `0b1bad14ff204627636aeb1de22ddcd5acb859d4`
- Model: NVIDIA Cosmos-Reason2-2B, Q4_K_M GGUF, 2,031,739,904 parameters
- Model SHA-256: `3ed011641891e81fe654328071de251718832e7deafef579033485d33082e4fd`
- Vision projector SHA-256: `8d3284c340d6a9c9237d56f2fc42f2df50d3761f539f3f01be964cefb0b73916`
- Model API: `127.0.0.1:4190` only
- UI: port `4188`, configurable with `VLM_TEST_PORT`
- Cloud API: none

The runtime/model choice follows NVIDIA's published Orin Nano 8GB example using Cosmos Reason2 2B Q4_K_M with llama.cpp. The full Transformers path was not selected because NVIDIA's Cosmos repository lists 24 GB minimum GPU memory for the 2B model.

## Input

- File: `01_INTEGRITY_ATTACK_젯슨실화면_260812.png`
- Resolution: 1920 x 1080 PNG
- Size: 224,410 bytes
- SHA-256: `1cab053b22d50479662a18f740c8f8fed0328abff346ef32970d274e8f811967`

## Model load

- Multimodal model and projector loaded successfully.
- CUDA libraries loaded: `libggml-cuda.so` and NVIDIA `libcuda.so.1.1`.
- Server-reported model-load time: 5.64 sec.
- Startup script ready time: 6 sec.
- One inference slot is used to avoid unnecessary image-cache growth on the 8 GB device.

## Final cold run

- Model request: 16.298 sec
- End-to-end response: 17.915 sec
- Prompt: 2,197 tokens at 196.34 token/sec
- Generation: 101 tokens at 20.46 token/sec
- GPU utilization: 86.81% mean / 99% peak
- RAM: 5,461 MB before / 5,893 MB peak
- Board power: 12.31 W mean / 16.36 W peak

## Final warm run

- Model request: 6.445 sec
- End-to-end response: 7.218 sec
- Generation: 132 tokens at 21.46 token/sec
- GPU utilization: 90.15% mean / 99% peak
- RAM: 5,849 MB before / 5,910 MB peak
- Board power: 14.37 W mean / 16.12 W peak

## Quality assessment

- Correct: recognized a secure/live video dashboard, integrity-attack context, live telemetry, and no visible people.
- Partly correct: detected the ZYBO TX circuit-board area and several dashboard labels in earlier runs.
- Weak: security-sensitive-information explanation was shallow and often repeated general dashboard phrases.
- Repetition: repeated `none`, `secure video dashboard`, and `live telemetry connection` in the warm run.
- Completion: native llama.cpp JSON-schema constraints made all four fields complete and parseable; earlier unconstrained output could consume the token limit before closing JSON.
- Practical conclusion: latency is acceptable for a user-triggered, one-image demo with a visible progress state, not for continuous analysis. The 2B Q4 model is adequate for coarse scene recognition but is not yet reliable enough for a polished security-exposure narrative without further model/prompt evaluation.

Exact machine-readable cold and warm responses are in `test-results/`.

## References

- NVIDIA Jetson memory-efficiency example: https://developer.nvidia.com/blog/maximizing-memory-efficiency-to-run-bigger-models-on-nvidia-jetson/
- NVIDIA Cosmos Reason2: https://github.com/nvidia-cosmos/cosmos-reason2
- llama.cpp: https://github.com/ggml-org/llama.cpp
