from __future__ import annotations

import argparse
import json
import os
import socket
import threading
import time
import urllib.error
import urllib.request
import webbrowser
import zlib
from collections import deque
from functools import partial
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

import serial
from serial.tools import list_ports


ROOT = Path(__file__).resolve().parent
WEB_ROOT = ROOT / "web"
UART_FRAME_PREFIX = b"ZYBO_RX_V1"
UART_BAUD = int(os.environ.get("PC_RX_UART_BAUD", "115200"))
UART_PORT_OVERRIDE = os.environ.get("PC_RX_UART_PORT", "").strip()
UART_PROBE_SECONDS = float(os.environ.get("PC_RX_UART_PROBE_SECONDS", "1.5"))
ONLINE_SECONDS = float(os.environ.get("PC_TELEMETRY_ONLINE_SECONDS", "1.5"))
SECURITY_WINDOW_SECONDS = 1.0
JETSON_DASHBOARD_URL = os.environ.get(
    "JETSON_DASHBOARD_URL", "http://100.72.159.6:4173"
).rstrip("/")
GEMINI_API_KEY = os.environ.get("GEMINI_API_KEY", "").strip()
GEMINI_BASE_URL = os.environ.get(
    "GEMINI_BASE_URL", "https://generativelanguage.googleapis.com/v1beta"
).rstrip("/")
GEMINI_MODEL = os.environ.get("GEMINI_MODEL", "gemini-3.6-flash").strip()
GEMINI_TIMEOUT_SECONDS = float(os.environ.get("GEMINI_TIMEOUT_SECONDS", "45"))
GEMINI_SYSTEM_INSTRUCTION = (
    "당신은 AES-256-GCM 보안 영상 수신 시스템의 분석 보조자입니다. "
    "제공된 현재 대시보드 스냅샷과 sessionEvents만 근거로 한국어로 간결하게 답하세요. "
    "context.video가 영상 상태의 유일한 기준입니다. deviceConnected, streamActive, frameAlive가 true일 때만 "
    "영상 입력이 정상이라고 말하고, false와 null(확인 불가)을 절대 혼동하지 마세요. "
    "VIDEO LIVE 상태에서 NO_DEVICE, disconnected, inactive라고 답하지 마세요. "
    "공격 상태는 context.jetson.connected와 context.jetson.attack.active/type/ratePercent만 기준으로 판단하세요. "
    "attack.active가 true이면 공격 비활성이라고 말하지 마세요. "
    "context.answerEvidence가 있으면 그 목록의 각 관측값을 빠뜨리지 말고 답변 본문에서 같은 숫자와 단위로 언급하세요. "
    "0도 관측값이며, 정의되지 않은 임계값으로 정상·위험을 임의 판정하지 마세요. "
    "현재 질문은 observedAt의 최신 스냅샷을, 과거 질문은 제공된 sessionEvents를 근거로 답하세요. "
    "PC/UI 관측과 RX 보드 결론을 구분하고, 관측되지 않은 사실은 추측하지 마세요. "
    "한국어 입력의 경미한 오타와 띄어쓰기 오류는 주변 문맥으로 자연스럽게 해석하고, 의미가 분명하면 재질문하지 마세요."
)


class GeminiRequestError(RuntimeError):
    """A safe, user-visible diagnostic for an upstream Gemini request failure."""

    def __init__(self, message: str, diagnostics: dict[str, Any]) -> None:
        super().__init__(message)
        self.diagnostics = diagnostics


def _gemini_context_prompt(context: Any) -> str:
    value = context if isinstance(context, dict) else {
        "pc": {"available": False},
        "rx": {"online": False},
    }
    return (
        "다음은 현재 대시보드의 관측 스냅샷입니다. RX가 오프라인이어도 PC/UI 관측은 "
        "유효하며, 두 출처를 혼동하지 마세요.\n\n"
        + json.dumps(value, ensure_ascii=False, indent=2)
    )


def build_gemini_interaction(
    kind: str, body: dict[str, Any], model: str | None = None
) -> dict[str, Any]:
    context = _gemini_context_prompt(body.get("context"))
    if kind == "chat":
        message = str(body.get("message", "")).strip()
        if not message:
            raise ValueError("Gemini 질문을 입력하세요.")
        prompt = f"사용자 질문:\n{message}\n\n{context}"
    else:
        task = str(body.get("task", "summary"))
        directives = {
            "summary": "현재 보안 상태를 3문장 이내로 요약하세요.",
            "risk": "현재 관측된 보안 위험과 그 근거를 짧게 설명하세요.",
            "correlation": (
                "Jetson 공격 관측과 RX 보안 이벤트의 연관성을 분석하세요. "
                "한쪽 자료가 없으면 연관성을 판단할 수 없다고 명시하세요."
            ),
        }
        prompt = f"{directives.get(task, directives['summary'])}\n\n{context}"

    result: dict[str, Any] = {
        "model": model or GEMINI_MODEL,
        "input": prompt,
        "system_instruction": GEMINI_SYSTEM_INSTRUCTION,
        "generation_config": {"thinking_level": "low"},
    }
    previous = str(body.get("previousInteractionId", "")).strip()
    if previous:
        result["previous_interaction_id"] = previous
    return result


def extract_gemini_text(payload: dict[str, Any]) -> str:
    direct = payload.get("output_text")
    if isinstance(direct, str) and direct.strip():
        return direct.strip()

    texts: list[str] = []
    for container_name in ("outputs", "steps"):
        containers = payload.get(container_name)
        if not isinstance(containers, list):
            continue
        for item in containers:
            content = item.get("content", []) if isinstance(item, dict) else []
            if isinstance(content, dict):
                content = [content]
            for part in content if isinstance(content, list) else []:
                text = part.get("text") if isinstance(part, dict) else None
                if isinstance(text, str) and text.strip():
                    texts.append(text.strip())
    if texts:
        return "\n".join(texts)

    candidates = payload.get("candidates")
    if isinstance(candidates, list):
        for candidate in candidates:
            content = candidate.get("content", {}) if isinstance(candidate, dict) else {}
            parts = content.get("parts", []) if isinstance(content, dict) else []
            for part in parts if isinstance(parts, list) else []:
                text = part.get("text") if isinstance(part, dict) else None
                if isinstance(text, str) and text.strip():
                    texts.append(text.strip())
    return "\n".join(texts)


def request_gemini(kind: str, body: dict[str, Any]) -> dict[str, Any]:
    if not GEMINI_API_KEY:
        raise RuntimeError("GEMINI_API_KEY가 설정되지 않았습니다.")
    request_started = time.perf_counter()
    context_bytes = len(json.dumps(
        body.get("context", {}), ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8"))
    request_payload = build_gemini_interaction(kind, body)
    request_bytes = len(json.dumps(
        request_payload, ensure_ascii=False, separators=(",", ":")
    ).encode("utf-8"))

    def diagnostics(phase: str) -> dict[str, Any]:
        client = body.get("clientDiagnostics")
        trace = client if isinstance(client, dict) else {}
        return {
            "phase": phase,
            "contextBytes": context_bytes,
            "requestBytes": request_bytes,
            "geminiHttpMs": round((time.perf_counter() - request_started) * 1000),
            "timeoutMs": round(GEMINI_TIMEOUT_SECONDS * 1000),
            "snapshotMs": trace.get("snapshotMs"),
            "evidenceMs": trace.get("evidenceMs"),
        }
    while True:
        request = urllib.request.Request(
            f"{GEMINI_BASE_URL}/interactions",
            data=json.dumps(request_payload, ensure_ascii=False).encode("utf-8"),
            headers={
                "x-goog-api-key": GEMINI_API_KEY,
                "content-type": "application/json",
            },
            method="POST",
        )
        try:
            with urllib.request.urlopen(
                request, timeout=GEMINI_TIMEOUT_SECONDS
            ) as response:
                payload = json.loads(response.read(2 * 1024 * 1024).decode("utf-8"))
            break
        except urllib.error.HTTPError as error:
            if error.code != 400 or "previous_interaction_id" not in request_payload:
                raise
            request_payload.pop("previous_interaction_id")
        except urllib.error.URLError as error:
            if isinstance(error.reason, TimeoutError) or "timed out" in str(error.reason).lower():
                raise GeminiRequestError("The read operation timed out", diagnostics("gemini_http_timeout")) from error
            raise
        except TimeoutError as error:
            raise GeminiRequestError("The read operation timed out", diagnostics("gemini_http_timeout")) from error
    if not isinstance(payload, dict):
        raise RuntimeError("Gemini 응답 형식이 올바르지 않습니다.")
    text = extract_gemini_text(payload)
    if not text:
        raise RuntimeError("Gemini 응답이 비어 있습니다.")
    return {
        "text": text,
        "model": GEMINI_MODEL,
        "interactionId": payload.get("id"),
        "diagnostics": diagnostics("gemini_completed"),
    }


class TelemetryStore:
    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._telemetry: dict[str, Any] | None = None
        self._telemetry_received = 0.0
        self._source = ""
        self._events: deque[dict[str, Any]] = deque(maxlen=32)
        self._auth_fail_samples: deque[tuple[float, int]] = deque(maxlen=64)
        self._replay_reject_samples: deque[tuple[float, int]] = deque(maxlen=64)
        self._health_totals = {
            "network_loss_total": 0,
            "queue_overrun_total": 0,
            "stale_drop_total": 0,
            "status_failure_total": 0,
        }
        self._last_health_sequence: int | None = None
        self._invalid_packets = 0

    @staticmethod
    def _record_counter_sample(
        samples: deque[tuple[float, int]], now: float, value: Any
    ) -> None:
        """Keep a short monotonic history for a real cumulative RX counter."""
        try:
            total = int(value)
            if total < 0:
                raise ValueError("negative counter")
        except (TypeError, ValueError):
            return
        if samples and total < samples[-1][1]:
            samples.clear()  # RX reboot/counter reset: never manufacture a delta.
        samples.append((now, total))
        while samples and samples[0][0] < now - 5.0:
            samples.popleft()

    def ingest(self, payload: bytes, source: tuple[str, int], kind: str) -> bool:
        try:
            value = json.loads(payload.decode("utf-8"))
            if not isinstance(value, dict):
                raise ValueError("JSON root must be an object")
            if int(value.get("protocol_version", 0)) < 1:
                raise ValueError("unsupported telemetry protocol")
            if value.get("source_role") != "zybo-rx":
                raise ValueError("telemetry is not from the RX board")
            if value.get("transport") != "uart":
                raise ValueError("RX telemetry did not arrive over UART")
        except (UnicodeDecodeError, ValueError, TypeError, json.JSONDecodeError):
            with self._lock:
                self._invalid_packets += 1
            return False

        now = time.monotonic()
        value["_received_monotonic"] = now
        value["_source"] = source[0]
        with self._lock:
            if kind == "telemetry":
                self._telemetry = value
                self._telemetry_received = now
                self._source = source[0]
                self._record_counter_sample(
                    self._auth_fail_samples, now,
                    value.get("authentication_failures_total"),
                )
                self._record_counter_sample(
                    self._replay_reject_samples, now,
                    value.get("replay_reject_total"),
                )
                try:
                    sequence = int(value["seq"])
                except (KeyError, TypeError, ValueError):
                    sequence = None
                if sequence != self._last_health_sequence:
                    for source_name, state_name in (
                        ("network_loss_delta", "network_loss_total"),
                        ("queue_overrun_delta", "queue_overrun_total"),
                        ("stale_drop_delta", "stale_drop_total"),
                        ("status_failure_delta", "status_failure_total"),
                    ):
                        try:
                            delta = int(value.get(source_name, 0))
                            if delta < 0:
                                raise ValueError("negative health delta")
                        except (TypeError, ValueError):
                            continue
                        self._health_totals[state_name] += delta
                    self._last_health_sequence = sequence
            else:
                event_key = (
                    value.get("event_seq"),
                    value.get("event_type"),
                    value.get("frame_id"),
                )
                duplicate = any(
                    (
                        item.get("event_seq"),
                        item.get("event_type"),
                        item.get("frame_id"),
                    ) == event_key
                    for item in self._events
                )
                if not duplicate:
                    self._events.appendleft(value)
        return True

    def snapshot(self) -> dict[str, Any]:
        now = time.monotonic()
        with self._lock:
            telemetry = dict(self._telemetry) if self._telemetry else None
            age_ms = (
                round((now - self._telemetry_received) * 1000.0)
                if self._telemetry_received
                else None
            )
            security_state = self._security_state(telemetry, now)
            return {
                "online": age_ms is not None and age_ms <= ONLINE_SECONDS * 1000,
                "age_ms": age_ms,
                "source": self._source,
                "telemetry": telemetry,
                "security_state": security_state,
                "events": list(self._events),
                "invalid_packets": self._invalid_packets,
                "transport": "uart",
                "serial_port": self._source,
                "serial_baud": UART_BAUD,
            }

    def _security_state(
        self, telemetry: dict[str, Any] | None, now: float
    ) -> dict[str, Any]:
        def counter(name: str) -> int | None:
            try:
                value = int((telemetry or {})[name])
                return value if value >= 0 else None
            except (KeyError, TypeError, ValueError):
                return None

        def recent_count(total: int | None, samples: deque[tuple[float, int]]) -> int | None:
            if total is None:
                return None
            baseline = next(
                (sample for sample in reversed(samples)
                 if sample[0] <= now - SECURITY_WINDOW_SECONDS),
                None,
            )
            # The first valid sample means zero observed events in this window,
            # not "unknown". A dash is reserved for genuinely missing telemetry.
            return 0 if baseline is None or total < baseline[1] else total - baseline[1]

        auth_total = counter("authentication_failures_total")
        replay_total = counter("replay_reject_total")
        auth_last_1s = recent_count(auth_total, self._auth_fail_samples)
        replay_last_1s = recent_count(replay_total, self._replay_reject_samples)
        def rate(name: str, fallback: int | None) -> float | None:
            try:
                value = float((telemetry or {})[name])
                return value if value >= 0 else None
            except (KeyError, TypeError, ValueError):
                return float(fallback) if fallback is not None else None
        return {
            "gcm_auth_fail_last_1s": auth_last_1s,
            "gcm_auth_fail_rate_per_sec": rate("auth_reject_rate", auth_last_1s),
            "gcm_auth_fail_rate_1s": rate("auth_reject_rate", auth_last_1s),
            "gcm_auth_fail_total": auth_total,
            "replay_reject_last_1s": replay_last_1s,
            "replay_reject_rate_per_sec": rate("replay_reject_rate", replay_last_1s),
            "replay_reject_rate_1s": rate("replay_reject_rate", replay_last_1s),
            "replay_reject_total": replay_total,
            "sequence_error_total": counter("detector_sequence_total"),
            "session_error_total": counter("detector_session_total"),
            "timeout_total": counter("detector_timeout_total"),
            **self._health_totals,
            "processed_total": counter("processed_frames_total"),
            "processed_unit": "frames",
        }


class OccLockState:
    """Track OCC access without opening a second handle to the RX UART."""

    def __init__(self) -> None:
        self._lock = threading.Lock()
        self._locked = True
        self._connected = False
        self._port = ""
        self._verdict = "WAITING"
        self._credential: str | None = None
        self._unlock_source: str | None = None
        self._last_event_at: int | None = None
        self._error: str | None = None

    def mark_connected(self, port: str) -> None:
        with self._lock:
            self._connected = True
            self._port = port
            self._error = None

    def mark_disconnected(self, port: str) -> None:
        with self._lock:
            if not self._port or self._port == port:
                self._connected = False

    def ingest_line(self, raw: bytes, port: str) -> bool:
        parts = raw.decode("ascii", errors="replace").strip().split()
        command = parts[0].upper() if parts else ""
        if len(parts) != 2 or command not in {"OPEN", "DENY"}:
            return False
        verdict = "PASS" if command == "OPEN" else "FAIL"
        with self._lock:
            self._connected = True
            self._port = port
            # The keyboard master unlock remains authoritative until J/K/L explicitly relocks it.
            if self._unlock_source == "QWE":
                return True
            self._verdict = verdict
            self._credential = parts[1]
            self._last_event_at = int(time.time() * 1000)
            self._error = None
            if verdict == "PASS":
                self._locked = False
                self._unlock_source = "OCC"
        return True

    def emergency_unlock(self, keys: Any) -> dict[str, Any]:
        chord = "".join(sorted(str(key).lower() for key in keys)) \
            if isinstance(keys, list) else ""
        if chord != "eqw":
            raise ValueError("invalid emergency key chord")
        with self._lock:
            self._locked = False
            self._verdict = "PASS"
            self._credential = None
            self._unlock_source = "QWE"
            self._last_event_at = int(time.time() * 1000)
            self._error = None
        return self.snapshot()

    def keyboard_lock(self, keys: Any) -> dict[str, Any]:
        chord = "".join(sorted(str(key).lower() for key in keys)) \
            if isinstance(keys, list) else ""
        if chord != "jkl":
            raise ValueError("invalid lock key chord")
        with self._lock:
            self._locked = True
            self._verdict = "WAITING"
            self._credential = None
            self._unlock_source = None
            self._last_event_at = int(time.time() * 1000)
            self._error = None
        return self.snapshot()

    def snapshot(self) -> dict[str, Any]:
        with self._lock:
            return {
                "locked": self._locked,
                "connected": self._connected,
                "port": self._port or None,
                "baud": UART_BAUD,
                "verdict": self._verdict,
                "credential": self._credential,
                "unlockSource": self._unlock_source,
                "lastEventAt": self._last_event_at,
                "error": self._error,
            }


class JetsonTelemetry:
    """Cache only the dedicated Jetson attacker-side status contract."""

    def __init__(self, base_url: str) -> None:
        self.base_url = base_url.rstrip("/")
        self._lock = threading.Lock()
        self._attack_status: dict[str, Any] | None = None
        self._received = 0.0
        self._error = "waiting"

    def poll_once(self, timeout: float = 0.8) -> bool:
        request = urllib.request.Request(
            f"{self.base_url}/api/attack/status",
            headers={"Accept": "application/json", "Cache-Control": "no-store"},
        )
        try:
            with urllib.request.urlopen(request, timeout=timeout) as response:
                value = json.load(response)
            value = sanitize_attack_status(value)
        except (OSError, ValueError, urllib.error.URLError, json.JSONDecodeError) as error:
            with self._lock:
                self._error = str(error)
            return False
        with self._lock:
            self._attack_status = value
            self._received = time.monotonic()
            self._error = ""
        return True

    def run(self, stop_event: threading.Event) -> None:
        while not stop_event.is_set():
            started = time.monotonic()
            self.poll_once()
            stop_event.wait(max(0.05, 0.2 - (time.monotonic() - started)))

    def snapshot(self) -> dict[str, Any]:
        now = time.monotonic()
        with self._lock:
            age_ms = round((now - self._received) * 1000.0) if self._received else None
            online = age_ms is not None and age_ms <= 1500
            return {
                "online": online,
                "age_ms": age_ms,
                "url": self.base_url,
                "attack_status": dict(self._attack_status)
                if online and self._attack_status else None,
                "error": self._error,
            }


def sanitize_attack_status(value: Any) -> dict[str, Any]:
    """Whitelist the attacker contract so Page 01 monitoring cannot leak into PC UI."""
    if not isinstance(value, dict):
        raise ValueError("Jetson attack status must be an object")
    if value.get("source_role") != "jetson-attacker":
        raise ValueError("unexpected Jetson status role")
    mode = str(value.get("mode") or "none").lower()
    if mode not in {"none", "tamper", "replay"}:
        raise ValueError("unsupported Jetson attack mode")

    def optional_int(source: dict[str, Any], key: str) -> int | None:
        raw = source.get(key)
        if raw is None:
            return None
        return int(raw)

    active = bool(value.get("active"))
    target_raw = value.get("last_target")
    target = None
    if isinstance(target_raw, dict) and target_raw.get("frame_id") is not None:
        target = {"frame_id": int(target_raw["frame_id"])}
        if mode == "tamper" and target_raw.get("packet_id") is not None:
            target["packet_id"] = int(target_raw["packet_id"])
    result = {
        "schema_version": int(value.get("schema_version") or 1),
        "source_role": "jetson-attacker",
        "active": active,
        "mode": mode,
        "rate": optional_int(value, "rate"),
        "count": max(0, int(value.get("count") or 0)),
        "runtime_ms": max(0, int(value.get("runtime_ms") or 0)),
    }
    if target is not None:
        result["last_target"] = target
    return result


def encode_uart_frame(kind: str, payload: bytes) -> bytes:
    if kind not in {"T", "E"}:
        raise ValueError("UART frame kind must be T or E")
    checksum = zlib.crc32(payload) & 0xFFFFFFFF
    return UART_FRAME_PREFIX + f" {kind} {checksum:08x} ".encode() + payload + b"\n"


def decode_uart_frame(line: bytes) -> tuple[str, bytes] | None:
    parts = line.rstrip(b"\r\n").split(b" ", 3)
    if len(parts) != 4 or parts[0] != UART_FRAME_PREFIX:
        return None
    try:
        kind = parts[1].decode("ascii")
        expected = int(parts[2], 16)
    except (UnicodeDecodeError, ValueError):
        return None
    if kind not in {"T", "E"} or len(parts[2]) != 8:
        return None
    payload = parts[3]
    if zlib.crc32(payload) & 0xFFFFFFFF != expected:
        return None
    return ("telemetry" if kind == "T" else "event"), payload


def uart_candidates() -> list[str]:
    if UART_PORT_OVERRIDE:
        return [value.strip() for value in UART_PORT_OVERRIDE.split(",") if value.strip()]
    return sorted({item.device for item in list_ports.comports()})


def receive_uart_port(
    port: str,
    store: TelemetryStore,
    occ: OccLockState,
    stop_event: threading.Event,
    port_stop_event: threading.Event,
) -> None:
    """Read one candidate until it disappears; identify its role from traffic."""
    while not stop_event.is_set() and not port_stop_event.is_set():
        identified = False
        buffer = bytearray()
        deadline = time.monotonic() + max(0.5, UART_PROBE_SECONDS)
        try:
            with serial.Serial(
                port=port,
                baudrate=UART_BAUD,
                bytesize=serial.EIGHTBITS,
                parity=serial.PARITY_NONE,
                stopbits=serial.STOPBITS_ONE,
                timeout=0.2,
                write_timeout=0.2,
                xonxoff=False,
                rtscts=False,
                dsrdtr=False,
            ) as connection:
                while not stop_event.is_set() and not port_stop_event.is_set():
                    if not identified and time.monotonic() >= deadline:
                        break
                    chunk = connection.read(max(1, min(4096, connection.in_waiting)))
                    if not chunk:
                        continue
                    buffer.extend(chunk)
                    if len(buffer) > 32768:
                        del buffer[:-8192]
                    while b"\n" in buffer:
                        raw, _, remainder = buffer.partition(b"\n")
                        buffer = bytearray(remainder)
                        if occ.ingest_line(raw, port):
                            identified = True
                            deadline = float("inf")
                            continue
                        decoded = decode_uart_frame(raw)
                        if decoded is None:
                            continue
                        kind, payload = decoded
                        if store.ingest(payload, (port, UART_BAUD), kind):
                            identified = True
                            deadline = float("inf")
        except (OSError, serial.SerialException):
            pass
        if not stop_event.is_set() and not port_stop_event.is_set():
            port_stop_event.wait(0.25)
    occ.mark_disconnected(port)


def receive_uart(
    store: TelemetryStore, occ: OccLockState, stop_event: threading.Event
) -> None:
    """Monitor every candidate so RX telemetry and OCC can use separate UARTs."""
    workers: dict[str, tuple[threading.Thread, threading.Event]] = {}
    try:
        while not stop_event.is_set():
            candidates = set(uart_candidates())
            for port, (thread, port_stop_event) in list(workers.items()):
                if port not in candidates:
                    port_stop_event.set()
                if not thread.is_alive():
                    workers.pop(port, None)
            for port in sorted(candidates):
                if port in workers:
                    continue
                port_stop_event = threading.Event()
                thread = threading.Thread(
                    target=receive_uart_port,
                    args=(port, store, occ, stop_event, port_stop_event),
                    daemon=True,
                    name=f"uart-{port}",
                )
                workers[port] = (thread, port_stop_event)
                thread.start()
            stop_event.wait(0.25)
    finally:
        for _, port_stop_event in workers.values():
            port_stop_event.set()
        for thread, _ in workers.values():
            thread.join(timeout=0.75)


class DashboardHandler(SimpleHTTPRequestHandler):
    store: TelemetryStore
    jetson: JetsonTelemetry
    occ: OccLockState

    def end_headers(self) -> None:
        if self.path.endswith((".html", ".js", ".css")) or self.path == "/":
            self.send_header("Cache-Control", "no-store")
        super().end_headers()

    def log_message(self, _format: str, *_args: object) -> None:
        return

    def send_json(self, value: Any, status: int = 200) -> None:
        payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(payload)))
        self.end_headers()
        self.wfile.write(payload)

    def do_GET(self) -> None:
        path = self.path.split("?", 1)[0]
        jetson = self.jetson.snapshot()
        if path == "/api/state":
            state = self.store.snapshot()
            state["jetson_attack"] = jetson
            state["occ"] = self.occ.snapshot()
            self.send_json(state)
            return
        if path == "/api/occ/status":
            self.send_json(self.occ.snapshot())
            return
        if path == "/api/ai/status":
            self.send_json({
                "configured": bool(GEMINI_API_KEY),
                "provider": "Gemini",
                "model": GEMINI_MODEL if GEMINI_API_KEY else None,
            })
            return
        super().do_GET()

    def do_POST(self) -> None:
        path = self.path.split("?", 1)[0]
        occ_paths = {"/api/occ/emergency-unlock", "/api/occ/keyboard-lock"}
        ai_paths = {"/api/ai/analyze", "/api/ai/chat"}
        if path not in occ_paths | ai_paths:
            self.send_json({"error": "not found"}, 404)
            return
        try:
            length = int(self.headers.get("Content-Length", "0"))
            limit = 128 * 1024 if path in ai_paths else 4096
            if length < 0 or length > limit:
                raise ValueError("invalid content length")
            body = json.loads(self.rfile.read(length) or b"{}")
            if not isinstance(body, dict):
                raise ValueError("JSON object required")
            if path in ai_paths:
                if not GEMINI_API_KEY:
                    self.send_json({"error": "GEMINI_API_KEY가 설정되지 않았습니다."}, 503)
                    return
                kind = "chat" if path.endswith("/chat") else "analysis"
                try:
                    self.send_json(request_gemini(kind, body))
                except GeminiRequestError as error:
                    self.send_json({"error": str(error), "diagnostics": error.diagnostics}, 504)
                except urllib.error.HTTPError as error:
                    message = f"Gemini API 오류 ({error.code})"
                    try:
                        remote = json.loads(error.read(256 * 1024).decode("utf-8"))
                        message = remote.get("error", {}).get("message") or message
                    except (UnicodeDecodeError, json.JSONDecodeError, AttributeError):
                        pass
                    self.send_json({"error": message}, 502)
                except (urllib.error.URLError, TimeoutError, OSError, RuntimeError) as error:
                    self.send_json({"error": str(error)}, 502)
                return
            result = self.occ.emergency_unlock(body.get("keys")) \
                if path.endswith("emergency-unlock") \
                else self.occ.keyboard_lock(body.get("keys"))
            self.send_json(result)
        except (ValueError, TypeError, json.JSONDecodeError) as error:
            self.send_json({"error": str(error)}, 400)


class DashboardHTTPServer(ThreadingHTTPServer):
    """Bind one dashboard process exclusively, especially on Windows.

    ThreadingHTTPServer enables address reuse on some Python/OS combinations.
    That can let two local dashboards claim the same port and makes requests
    nondeterministic.  Exclusive bind turns an occupied preferred port into a
    reliable error so create_server can select the next free port.
    """

    allow_reuse_address = False
    allow_reuse_port = False
    daemon_threads = True

    def server_bind(self) -> None:
        if os.name == "nt" and hasattr(socket, "SO_EXCLUSIVEADDRUSE"):
            self.socket.setsockopt(socket.SOL_SOCKET, socket.SO_EXCLUSIVEADDRUSE, 1)
        super().server_bind()

def self_test() -> int:
    store = TelemetryStore()
    telemetry = {
        "protocol_version": 2,
        "source_role": "zybo-rx",
        "transport": "uart",
        "seq": 7,
        "valid_frame_rate": 29.9,
        "detector_tag_total": 1,
        "authentication_failures_total": 10,
        "replay_reject_total": 5,
        "network_loss_delta": 2,
        "queue_overrun_delta": 0,
        "stale_drop_delta": 1,
        "status_failure_delta": 0,
    }
    event = {
        "protocol_version": 2,
        "source_role": "zybo-rx",
        "transport": "uart",
        "event_seq": 3,
        "event_type": "gcm_auth_fail",
        "frame_id": 6954,
        "packet_id": 0,
    }
    telemetry_payload = json.dumps(telemetry, separators=(",", ":")).encode()
    event_payload = json.dumps(event, separators=(",", ":")).encode()
    decoded = decode_uart_frame(encode_uart_frame("T", telemetry_payload))
    assert decoded == ("telemetry", telemetry_payload)
    damaged = bytearray(encode_uart_frame("T", telemetry_payload))
    damaged[-3] ^= 1
    assert decode_uart_frame(bytes(damaged)) is None
    assert store.ingest(telemetry_payload, ("COM_AUTO_RX", UART_BAUD), "telemetry")
    assert store.ingest(event_payload, ("COM_AUTO_RX", UART_BAUD), "event")
    assert store.ingest(event_payload, ("COM_AUTO_RX", UART_BAUD), "event")
    assert not store.ingest(b"not-json", ("COM_AUTO_RX", UART_BAUD), "telemetry")
    state = store.snapshot()
    assert state["online"]
    assert state["telemetry"]["detector_tag_total"] == 1
    with store._lock:
        store._auth_fail_samples.appendleft((time.monotonic() - 1.01, 4))
        store._replay_reject_samples.appendleft((time.monotonic() - 1.01, 2))
    assert store.snapshot()["security_state"]["gcm_auth_fail_last_1s"] == 6
    assert store.snapshot()["security_state"]["gcm_auth_fail_total"] == 10
    assert store.snapshot()["security_state"]["replay_reject_last_1s"] == 3
    assert store.snapshot()["security_state"]["network_loss_total"] == 2
    assert store.snapshot()["security_state"]["stale_drop_total"] == 1
    assert state["events"][0]["event_type"] == "gcm_auth_fail"
    assert len(state["events"]) == 1
    assert state["invalid_packets"] == 1
    store._telemetry_received = time.monotonic() - (ONLINE_SECONDS + 0.1)
    assert not store.snapshot()["online"]
    store._telemetry_received = time.monotonic()
    attack = sanitize_attack_status({
        "schema_version": 1,
        "source_role": "jetson-attacker",
        "active": True,
        "mode": "tamper",
        "rate": 20,
        "count": 5,
        "runtime_ms": 4250,
        "last_target": {"frame_id": 6954, "packet_id": 0},
        "stream_analysis": {"entropy": 7.87},
    })
    assert attack["last_target"] == {"frame_id": 6954, "packet_id": 0}
    assert attack["count"] == 5
    assert "stream_analysis" not in attack
    assert "tamper" not in attack and "replay" not in attack
    jetson = JetsonTelemetry("http://100.72.159.6:4173")
    jetson._attack_status = attack
    jetson._received = time.monotonic() - 2.0
    stale = jetson.snapshot()
    assert not stale["online"] and stale["attack_status"] is None
    jetson._received = time.monotonic()
    fresh = jetson.snapshot()
    assert fresh["online"] and fresh["attack_status"]["count"] == 5
    assert state["transport"] == "uart"
    assert state["serial_port"] == "COM_AUTO_RX"
    occ = OccLockState()
    assert occ.snapshot()["locked"]
    assert not occ.ingest_line(b"OPEN", "COM_AUTO_RX")
    assert occ.snapshot()["locked"]
    assert occ.ingest_line(b"DENY 1357", "COM_AUTO_RX")
    assert occ.snapshot()["locked"] and occ.snapshot()["verdict"] == "FAIL"
    assert occ.ingest_line(b"OPEN 2468", "COM_AUTO_RX")
    assert not occ.snapshot()["locked"] and occ.snapshot()["credential"] == "2468"
    assert occ.keyboard_lock(["l", "k", "j"])["locked"]
    assert not occ.emergency_unlock(["q", "w", "e"])["locked"]
    assert occ.ingest_line(b"DENY 1357", "COM_AUTO_RX")
    assert not occ.snapshot()["locked"] and occ.snapshot()["unlockSource"] == "QWE"
    assert occ.keyboard_lock(["l", "k", "j"])["locked"]
    assert occ.ingest_line(b"DENY 1357", "COM_AUTO_RX") and occ.snapshot()["verdict"] == "FAIL"
    print("PASS: RX UART, OCC lock, and isolated Jetson attack-status contracts")
    return 0


def create_server(
    host: str, requested_port: int, handler: Any, strict_port: bool
) -> tuple[ThreadingHTTPServer, int]:
    candidates = [requested_port] if strict_port else range(requested_port, requested_port + 20)
    last_error: OSError | None = None
    for port in candidates:
        try:
            return DashboardHTTPServer((host, port), handler), port
        except OSError as error:
            last_error = error
            if error.errno not in {48, 98, 10048}:
                raise
    raise OSError(f"no available PC UI port near {requested_port}: {last_error}")


def main() -> int:
    parser = argparse.ArgumentParser(description="ZYBO RX PC monitoring console")
    parser.add_argument("--host", default=os.environ.get("PC_RX_UI_HOST", "127.0.0.1"))
    parser.add_argument(
        "--port", type=int, default=int(os.environ.get("PC_RX_UI_PORT", "8765"))
    )
    parser.add_argument("--strict-port", action="store_true")
    parser.add_argument("--no-browser", action="store_true")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args()
    if args.self_test:
        return self_test()

    store = TelemetryStore()
    occ = OccLockState()
    jetson = JetsonTelemetry(JETSON_DASHBOARD_URL)
    stop_event = threading.Event()
    listeners = [
        threading.Thread(
            target=receive_uart,
            args=(store, occ, stop_event),
            daemon=True,
            name="rx-uart-telemetry",
        ),
        threading.Thread(
            target=jetson.run,
            args=(stop_event,),
            daemon=True,
            name="jetson-telemetry-proxy",
        ),
    ]
    for thread in listeners:
        thread.start()

    DashboardHandler.store = store
    DashboardHandler.jetson = jetson
    DashboardHandler.occ = occ
    handler = partial(DashboardHandler, directory=str(WEB_ROOT))
    server, selected_port = create_server(args.host, args.port, handler, args.strict_port)
    url = f"http://{args.host}:{selected_port}/"
    print(f"PC RX Console: {url}")
    if selected_port != args.port:
        print(f"Port {args.port} was busy; selected {selected_port} automatically")
    override = UART_PORT_OVERRIDE or "auto role detection"
    print(f"RX UART: {override} at {UART_BAUD} baud")
    print(f"Jetson attack source: {JETSON_DASHBOARD_URL}/api/attack/status")
    if not args.no_browser:
        threading.Timer(0.5, webbrowser.open, args=(url,)).start()
    try:
        server.serve_forever(poll_interval=0.25)
    except KeyboardInterrupt:
        pass
    finally:
        stop_event.set()
        server.server_close()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
