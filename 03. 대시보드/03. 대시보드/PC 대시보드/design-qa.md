# PC Dashboard Design QA

## Reference

- Source implementation: `C:\Users\kccistc\Desktop\송수신_암호화엔진 통합 자료\0. 대시보드\pc 프로토타입\web`
- User reference — AI drawer: `C:\Users\kccistc\AppData\Local\Temp\codex-clipboard-aa3d7c48-3cdf-430c-91f9-bacaa1036d62.png`
- User reference — Page 02: `C:\Users\kccistc\AppData\Local\Temp\codex-clipboard-4d1d836c-8fcd-4389-ab7b-a217adf25202.png`
- User reference — Page 01: `C:\Users\kccistc\AppData\Local\Temp\codex-clipboard-6db09986-3895-4198-b28a-de3ffcc0f063.png`
- Evidence-focus failure: `C:\Users\kccistc\AppData\Local\Temp\codex-clipboard-e0876df8-d03f-4965-bcb0-15309a889812.png`

## Implemented fidelity surfaces

- Original Page 01/Page 02 panel layout retained.
- Prototype typography, spacing, top navigation, five quick questions, voice-first composer, and 380–440 px AI drawer retained.
- Purple evidence focus now uses actual dashboard KPI targets, 30-second graph timestamps, and actual timeline events instead of fixed canvas coordinates.
- Gemini connection label is driven by `/api/ai/status`; fake runtime copy is removed.
- Typed, quick, and voice questions share the same evidence classification path.
- `GCM AUTH FAIL` and `REPLAY REJECT` use RX cumulative counters sampled by the backend: the primary KPI is the actual one-second integer delta, and the secondary value is the same counter's cumulative count. The first valid sample is `0건`, not `—`.
- `TAG` displays only the canonical GCM failure total (`FAIL`). The RX/PL path does not currently expose a distinct checked/verification-total counter, so no `CHECK` value is invented. `REPLAY` displays `REJECT`; `SEQUENCE`, `SESSION`, and `TIMEOUT` display their independent `ERROR` totals.
- Receiver Health contains only RX pipeline fields (network loss, queue overrun, stale drop, status failure, processed frames). It no longer repeats authentication or replay totals.
- The event timeline maps only received RX event records to detector rows. It never creates TAG, SEQUENCE, or other markers by differencing cumulative counters.
- Both security KPIs retain three explicit values: actual recent one-second count, cumulative count, and canonical `건/s` rate. The reject-rate graph uses that same canonical rate state.
- The backend accumulates RX delta health fields for the current dashboard session, with telemetry sequence de-duplication. Attack↔RX correlation keeps a two-second real-event observation window, then retains session match/mismatch totals instead of resetting when an attack stops.
- `CODE / FLAGS` was removed because the current UART event contract does not publish a human-readable definition for those debug fields. The event panel now shows only source-confirmed RX outcomes: GCM authentication failure or replay rejection is `DROP`; other received event types are simply marked as recorded.
- Page 02 keeps its card/grid geometry while increasing KPI auxiliary text, detector rows, correlation state/totals, health values, event identifiers, and status badges to readable hierarchy sizes.

## Verification

- `node tests/pc-ui-design-merge.test.js`: PASS
- `node --check app.js`: PASS
- `server.py --self-test`: PASS
- Final same-viewport browser capture: blocked because local preview access was denied during this run.

## Result

`blocked` — code and static/runtime self-tests pass; final same-viewport browser comparison remains required after the preview can be opened.
