#!/usr/bin/env python3
"""Serve the dashboard and the latest validated Zybo RX telemetry."""

from __future__ import annotations

import argparse
from datetime import datetime, timezone
import importlib.util
import json
import os
import re
import secrets
import shutil
import socket
import subprocess
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any, Callable


API_PATH = "/api/telemetry/latest"
ATTACK_STATUS_PATH = "/api/attack/status"
ATTACK_ACTIONS = {
    "/api/attack/prepare": "prepare",
    "/api/attack/start": "start",
    "/api/attack/stop": "stop",
    "/api/attack/reset": "reset",
}
BRUTEFORCE_STATUS_PATH = "/api/bruteforce/status"
BRUTEFORCE_FRAME_PATH = "/api/bruteforce/recovered-frame"
VLM_ANALYZE_PATH = "/api/vlm/analyze"
LOCAL_VLM_ANALYZE_URL = os.environ.get(
    "ZYBO_LOCAL_VLM_ANALYZE_URL", "http://127.0.0.1:4188/api/analyze"
)
VLM_REQUEST_LOCK = threading.Lock()
BRUTEFORCE_ACTIONS = {
    "/api/bruteforce/prepare": "prepare",
    "/api/bruteforce/start": "start",
    "/api/bruteforce/stop": "stop",
    "/api/bruteforce/secure": "secure",
    "/api/bruteforce/reset": "reset",
}
STREAM_CAPTURE_SAMPLE_STRIDE = 256
STREAM_CAPTURE_FILTER = (
    "ether src 02:00:00:00:00:02 and ether dst 02:00:00:00:00:03 "
    "and src host 10.10.15.2 and dst host 10.10.15.3 "
    "and udp src port 5602 and udp dst port 5602 "
    "and udp[4:2] = 1480 and udp[8:4] = 0x5043414d "
    f"and (udp[20:2] & {STREAM_CAPTURE_SAMPLE_STRIDE - 1}) = 0"
)


def analyze_recovered_frame(image_path: Path, metadata: dict[str, Any]) -> dict[str, Any]:
    image = image_path.read_bytes()
    if not image:
        raise RuntimeError("recovered frame is empty")
    if len(image) > 12 * 1024 * 1024:
        raise RuntimeError("recovered frame exceeds Local VLM input limit")

    boundary = f"----zybo-vlm-{time.time_ns()}"
    prefix = (
        f"--{boundary}\r\n"
        f'Content-Disposition: form-data; name="image"; filename="{image_path.name}"\r\n'
        "Content-Type: image/png\r\n\r\n"
    ).encode("utf-8")
    body = prefix + image + f"\r\n--{boundary}--\r\n".encode("ascii")
    request = urllib.request.Request(
        LOCAL_VLM_ANALYZE_URL,
        data=body,
        headers={
            "Content-Type": f"multipart/form-data; boundary={boundary}",
            "Content-Length": str(len(body)),
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=260.0) as response:
            value = json.loads(response.read())
    except urllib.error.HTTPError as error:
        detail = error.read().decode("utf-8", errors="replace")
        raise RuntimeError(f"Local VLM HTTP {error.code}: {detail[:1200]}") from error
    except urllib.error.URLError as error:
        raise RuntimeError(f"Local VLM unavailable: {error.reason}") from error
    if not isinstance(value, dict):
        raise RuntimeError("Local VLM returned an invalid response")
    if value.get("error"):
        raise RuntimeError(str(value["error"]))
    analysis = value.get("analysis")
    if not isinstance(analysis, dict):
        raise RuntimeError("Local VLM response did not contain analysis")
    return {
        "ok": True,
        "status": "complete",
        "analysis": analysis,
        "model": value.get("model"),
        "execution": value.get("execution", "LOCAL / JETSON"),
        "latency_sec": value.get("total_response_sec"),
        "model_request_sec": value.get("model_request_sec"),
        "source_frame": metadata.get("frame_id"),
        "source_run_id": metadata.get("run_id"),
        "source_sha256": metadata.get("sha256"),
    }


class TelemetryState:
    def __init__(
        self,
        validate_payload: Callable[[Any], list[str]],
        allowed_peer: str,
        live_timeout: float = 1.0,
    ) -> None:
        self.validate_payload = validate_payload
        self.allowed_peer = allowed_peer
        self.live_timeout = live_timeout
        self.lock = threading.Lock()
        self.latest: dict[str, Any] | None = None
        self.latest_received_at: float | None = None
        self.last_seq: int | None = None
        self.last_monotonic_ms: int | None = None
        self.arrivals: deque[float] = deque(maxlen=100)
        self.history: deque[dict[str, Any]] = deque(maxlen=150)
        self.received_packets = 0
        self.invalid_packets = 0
        self.sequence_gaps = 0
        self.source_restarts = 0
        self.rejected_peer_packets = 0

    def accept(
        self,
        packet: bytes,
        peer: tuple[str, int],
        received_at: float | None = None,
    ) -> bool:
        now = time.monotonic() if received_at is None else received_at
        if peer[0] != self.allowed_peer:
            with self.lock:
                self.invalid_packets += 1
                self.rejected_peer_packets += 1
            return False

        try:
            payload = json.loads(packet.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            with self.lock:
                self.invalid_packets += 1
            return False

        errors = self.validate_payload(payload)
        with self.lock:
            sequence_reset = (
                not errors
                and self.last_seq is not None
                and self.last_monotonic_ms is not None
                and payload["seq"] <= self.last_seq
            )
            sender_restarted = (
                sequence_reset
                and payload["monotonic_ms"] > self.last_monotonic_ms
            )
            board_rebooted = (
                sequence_reset
                and payload["monotonic_ms"] < self.last_monotonic_ms
                and self.latest_received_at is not None
                and now - self.latest_received_at > self.live_timeout
            )
            restarted = sender_restarted or board_rebooted
            if restarted:
                self.source_restarts += 1
            elif not errors and self.last_seq is not None:
                if payload["seq"] <= self.last_seq:
                    errors.append("seq did not increase")
            if not restarted and not errors and self.last_monotonic_ms is not None:
                if payload["monotonic_ms"] <= self.last_monotonic_ms:
                    errors.append("monotonic_ms did not increase")
            if errors:
                self.invalid_packets += 1
                return False

            if (not restarted and self.last_seq is not None and
                    payload["seq"] > self.last_seq + 1):
                self.sequence_gaps += payload["seq"] - self.last_seq - 1
            self.last_seq = payload["seq"]
            self.last_monotonic_ms = payload["monotonic_ms"]
            self.latest = payload
            self.history.append(dict(payload))
            self.latest_received_at = now
            self.arrivals.append(now)
            self.received_packets += 1
            return True

    def snapshot(self, now: float | None = None) -> dict[str, Any]:
        current = time.monotonic() if now is None else now
        with self.lock:
            age_ms = (
                None
                if self.latest_received_at is None
                else max(0.0, (current - self.latest_received_at) * 1000.0)
            )
            update_hz = 0.0
            if len(self.arrivals) > 1 and self.arrivals[-1] > self.arrivals[0]:
                update_hz = (len(self.arrivals) - 1) / (
                    self.arrivals[-1] - self.arrivals[0]
                )
            return {
                "live": age_ms is not None and age_ms <= self.live_timeout * 1000.0,
                "age_ms": None if age_ms is None else round(age_ms, 1),
                "received_packets": self.received_packets,
                "invalid_packets": self.invalid_packets,
                "sequence_gaps": self.sequence_gaps,
                "source_restarts": self.source_restarts,
                "rejected_peer_packets": self.rejected_peer_packets,
                "update_hz": round(update_hz, 3),
                "telemetry": None if self.latest is None else dict(self.latest),
                "telemetry_history": list(self.history),
            }


class SecurityEventState:
    EVENT_TYPES = {"gcm_auth_fail", "replay_reject"}

    def __init__(self, allowed_peer: str, max_events: int = 128) -> None:
        self.allowed_peer = allowed_peer
        self.lock = threading.Lock()
        self.recent: deque[dict[str, Any]] = deque(maxlen=max_events)
        self.last_event_seq: int | None = None
        self.received_events = 0
        self.invalid_events = 0
        self.sequence_gaps = 0
        self.source_restarts = 0
        self.rejected_peer_events = 0
        self.last_monotonic_ms: int | None = None

    @staticmethod
    def validate(payload: Any) -> bool:
        if not isinstance(payload, dict):
            return False
        required = {
            "protocol_version", "event_seq", "monotonic_ms", "event_type",
            "session_id", "frame_id",
        }
        if not required.issubset(payload) or payload["protocol_version"] != 1:
            return False
        if payload["event_type"] not in SecurityEventState.EVENT_TYPES:
            return False
        for name in ("event_seq", "monotonic_ms", "frame_id"):
            if not isinstance(payload[name], int) or payload[name] < 0:
                return False
        if not isinstance(payload["session_id"], str):
            return False
        try:
            session = int(payload["session_id"], 16)
        except ValueError:
            return False
        if not 0 <= session <= 0xFFFFFFFF:
            return False
        if payload["event_type"] == "replay_reject":
            last = payload.get("last_accepted_frame_id")
            if not isinstance(last, int) or last < 0:
                return False
        return True

    def accept(self, packet: bytes, peer: tuple[str, int]) -> bool:
        if peer[0] != self.allowed_peer:
            with self.lock:
                self.invalid_events += 1
                self.rejected_peer_events += 1
            return False
        try:
            payload = json.loads(packet.decode("utf-8"))
        except (UnicodeDecodeError, json.JSONDecodeError):
            with self.lock:
                self.invalid_events += 1
            return False
        if not self.validate(payload):
            with self.lock:
                self.invalid_events += 1
            return False
        with self.lock:
            sequence = payload["event_seq"]
            restarted = (
                self.last_event_seq is not None
                and self.last_monotonic_ms is not None
                and sequence <= self.last_event_seq
                and payload["monotonic_ms"] > self.last_monotonic_ms
            )
            if restarted:
                self.source_restarts += 1
            elif self.last_event_seq is not None and sequence <= self.last_event_seq:
                self.invalid_events += 1
                return False
            if (not restarted and self.last_event_seq is not None and
                    sequence > self.last_event_seq + 1):
                self.sequence_gaps += sequence - self.last_event_seq - 1
            self.last_event_seq = sequence
            self.last_monotonic_ms = payload["monotonic_ms"]
            self.recent.append(dict(payload))
            self.received_events += 1
        return True

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            events = [dict(event) for event in self.recent]
            return {
                "received_events": self.received_events,
                "invalid_events": self.invalid_events,
                "sequence_gaps": self.sequence_gaps,
                "source_restarts": self.source_restarts,
                "rejected_peer_events": self.rejected_peer_events,
                "latest": None if not events else events[-1],
                "recent": events,
            }


class StreamAnalysisState:
    def __init__(self, live_timeout: float = 3.0) -> None:
        self.live_timeout = live_timeout
        self.lock = threading.Lock()
        self.latest: dict[str, Any] | None = None
        self.latest_received_at: float | None = None
        self.updates = 0
        self.capture_errors = 0
        self.last_error: str | None = None
        self.history: deque[dict[str, Any]] = deque(maxlen=30)

    def accept(
        self,
        analysis: dict[str, Any],
        capture_ms: float,
        received_at: float | None = None,
    ) -> None:
        now = time.monotonic() if received_at is None else received_at
        value = dict(analysis)
        value["capture_ms"] = round(capture_ms, 1)
        with self.lock:
            self.latest = value
            self.latest_received_at = now
            self.updates += 1
            self.last_error = None
            self.history.append({
                "timestamp_monotonic": now,
                "latest_session_id": value.get("latest_session_id"),
                "latest_frame_id": value.get("latest_frame_id"),
                "latest_packet_id": value.get("latest_packet_id"),
                "packet_rate_kpps": value.get("packet_rate_kpps"),
                "packet_timing_jitter_ms": value.get("packet_timing_jitter_ms"),
            })

    def fail(self, message: str) -> None:
        with self.lock:
            self.capture_errors += 1
            self.last_error = message

    def snapshot(self, now: float | None = None) -> dict[str, Any]:
        current = time.monotonic() if now is None else now
        with self.lock:
            age_ms = (
                None
                if self.latest_received_at is None
                else max(0.0, (current - self.latest_received_at) * 1000.0)
            )
            value = {} if self.latest is None else dict(self.latest)
            history = [dict(sample) for sample in self.history]
            return {
                "live": age_ms is not None and age_ms <= self.live_timeout * 1000.0,
                "age_ms": None if age_ms is None else round(age_ms, 1),
                "updates": self.updates,
                "capture_errors": self.capture_errors,
                "last_error": self.last_error,
                "history": history,
                **value,
            }


class SystemMetricsState:
    def __init__(self, network_interface: str = "eno1") -> None:
        self.lock = threading.Lock()
        self.network_interface = network_interface
        self.latest: dict[str, Any] = {"live": False, "error": "not started"}
        self.process: subprocess.Popen[str] | None = None
        self.history: deque[dict[str, Any]] = deque(maxlen=30)
        self.previous_bridge_network: dict[str, tuple[float, int, int]] = {}
        self.drop_window: deque[tuple[float, int]] = deque()

    def _bridge_nic_drop_state(self) -> tuple[int | None, list[str], dict[str, dict[str, int]]]:
        bridge_ports = Path("/sys/class/net/br-video/brif")
        interfaces = (
            sorted(path.name for path in bridge_ports.iterdir())
            if bridge_ports.is_dir() else [self.network_interface]
        )
        if self.network_interface not in interfaces:
            interfaces.append(self.network_interface)
            interfaces.sort()
        counters: dict[str, dict[str, int]] = {}
        fields = ("rx_dropped", "tx_dropped", "rx_errors", "tx_errors")
        for interface in interfaces:
            statistics_root = Path("/sys/class/net") / interface / "statistics"
            try:
                counters[interface] = {
                    field: int((statistics_root / field).read_text().strip())
                    for field in fields
                }
            except (OSError, ValueError):
                continue
        total = sum(sum(values.values()) for values in counters.values())
        return (total if counters else None), sorted(counters), counters

    def _bridge_nic_byte_state(self) -> dict[str, dict[str, int]]:
        bridge_ports = Path("/sys/class/net/br-video/brif")
        interfaces = (
            sorted(path.name for path in bridge_ports.iterdir())
            if bridge_ports.is_dir() else [self.network_interface]
        )
        counters: dict[str, dict[str, int]] = {}
        for interface in interfaces:
            statistics_root = Path("/sys/class/net") / interface / "statistics"
            try:
                counters[interface] = {
                    "rx_bytes": int((statistics_root / "rx_bytes").read_text().strip()),
                    "tx_bytes": int((statistics_root / "tx_bytes").read_text().strip()),
                }
            except (OSError, ValueError):
                continue
        return counters

    def _bridge_link_rates(self, now: float) -> dict[str, Any]:
        """Measure all L2 bytes on the bridge's physical ingress/egress ports.

        This counter scope is intentionally different from packet-rate capture:
        throughput includes every frame on each selected port, while packet rate
        uses STREAM_CAPTURE_FILTER and counts only observed PCAM AES-GCM UDP 5602
        packets. The Page 01 single-line throughput graph follows egress.
        """
        counters = self._bridge_nic_byte_state()
        rates: dict[str, dict[str, float]] = {}
        for interface, values in counters.items():
            previous = self.previous_bridge_network.get(interface)
            if previous is not None:
                previous_time, previous_rx, previous_tx = previous
                elapsed = now - previous_time
                if elapsed > 0:
                    rates[interface] = {
                        "rx_mbps": max(0, values["rx_bytes"] - previous_rx)
                        * 8.0 / elapsed / 1_000_000.0,
                        "tx_mbps": max(0, values["tx_bytes"] - previous_tx)
                        * 8.0 / elapsed / 1_000_000.0,
                    }
            self.previous_bridge_network[interface] = (
                now, values["rx_bytes"], values["tx_bytes"]
            )

        ingress = max(rates, key=lambda name: rates[name]["rx_mbps"], default=None)
        egress = max(rates, key=lambda name: rates[name]["tx_mbps"], default=None)
        split = ingress is not None and egress is not None and ingress != egress
        ingress_mbps = rates[ingress]["rx_mbps"] if ingress is not None else None
        egress_mbps = rates[egress]["tx_mbps"] if egress is not None else None
        return {
            "link_direction_split": split,
            "link_ingress_interface": ingress if split else None,
            "link_egress_interface": egress if split else None,
            "link_ingress_mbps": ingress_mbps if split else None,
            "link_egress_mbps": egress_mbps if split else None,
            "link_throughput_mbps": (
                egress_mbps if split else ingress_mbps
            ),
            "bridge_nic_byte_rates": rates,
        }

    def _drop_delta_30s(self, now: float, total: int | None) -> int | None:
        if total is None:
            return None
        if self.drop_window and total < self.drop_window[-1][1]:
            self.drop_window.clear()
        self.drop_window.append((now, total))
        while len(self.drop_window) > 1 and now - self.drop_window[0][0] > 30.0:
            self.drop_window.popleft()
        return max(0, total - self.drop_window[0][1])

    def _parse(self, line: str) -> dict[str, Any]:
        def number(pattern: str) -> float | None:
            match = re.search(pattern, line)
            return None if match is None else float(match.group(1))

        cpu_match = re.search(r"CPU \[([^]]+)\]", line)
        cpu_values = [] if cpu_match is None else [
            float(value) for value in re.findall(r"(\d+(?:\.\d+)?)%", cpu_match.group(1))
        ]
        ram = re.search(r"RAM (\d+)/(\d+)MB", line)
        return {
            "live": True,
            "timestamp_monotonic": time.monotonic(),
            "gpu_util_percent": number(r"GR3D_FREQ (\d+(?:\.\d+)?)%"),
            "cpu_util_percent": None if not cpu_values else sum(cpu_values) / len(cpu_values),
            "memory_used_mb": None if ram is None else int(ram.group(1)),
            "memory_total_mb": None if ram is None else int(ram.group(2)),
            "board_power_w": (lambda value: None if value is None else value / 1000.0)(
                number(r"VDD_IN (\d+(?:\.\d+)?)mW")
            ),
            "cpu_temp_c": number(r"cpu@(\d+(?:\.\d+)?)C"),
            "gpu_temp_c": number(r"gpu@(\d+(?:\.\d+)?)C"),
            "raw": line.strip(),
        }

    def run(self, stop: threading.Event) -> None:
        executable = shutil.which("tegrastats") or "/usr/bin/tegrastats"
        try:
            self.process = subprocess.Popen(
                [executable, "--interval", "1000"], text=True,
                stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
            )
            assert self.process.stdout is not None
            while not stop.is_set():
                line = self.process.stdout.readline()
                if not line:
                    break
                value = self._parse(line)
                now = time.monotonic()
                value.update(self._bridge_link_rates(now))
                value["video_throughput_mbps"] = value.get("link_ingress_mbps")
                drop_total, drop_interfaces, drop_counters = self._bridge_nic_drop_state()
                value["bridge_nic_drop_error_total"] = drop_total
                value["bridge_nic_drop_delta_30s"] = self._drop_delta_30s(now, drop_total)
                value["bridge_nic_interfaces"] = drop_interfaces
                value["bridge_nic_counters"] = drop_counters
                with self.lock:
                    self.latest = value
                    self.history.append(dict(value))
        except Exception as error:
            with self.lock:
                self.latest = {"live": False, "error": f"{type(error).__name__}: {error}"}
        finally:
            if self.process is not None and self.process.poll() is None:
                self.process.terminate()
                try:
                    self.process.wait(timeout=2.0)
                except subprocess.TimeoutExpired:
                    self.process.kill()

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            value = dict(self.latest)
            history = [dict(sample) for sample in self.history]
        timestamp = value.pop("timestamp_monotonic", None)
        value["age_ms"] = None if timestamp is None else round(
            max(0.0, time.monotonic() - timestamp) * 1000.0, 1
        )
        if value.get("live") and value["age_ms"] is not None and value["age_ms"] > 3000:
            value["live"] = False
        value["history"] = history
        return value


class GlobalAttackState:
    """Single backend-owned lock shared by Page 2 and Page 3 attacks."""

    def __init__(self) -> None:
        self.lock = threading.RLock()
        self.value: dict[str, Any] = {
            "active": False, "mode": "none", "owner": None, "rate": None,
            "run_id": None, "started_at": None, "status": "idle",
            "last_error": None,
        }

    def reserve(self, mode: str, owner: str, rate: int | None) -> None:
        with self.lock:
            if self.value["status"] != "idle":
                raise RuntimeError(f"ACTIVE ATTACK: {str(self.value['mode']).upper()}")
            self.value = {
                "active": False, "mode": mode, "owner": owner, "rate": rate,
                "run_id": None, "started_at": None, "status": "preparing",
                "last_error": None,
            }

    def prepared(self, owner: str) -> None:
        with self.lock:
            if self.value["owner"] != owner or self.value["status"] != "preparing":
                raise RuntimeError("global attack reservation was lost")
            self.value["status"] = "prepared"

    def running(self, owner: str, run_id: Any) -> None:
        with self.lock:
            if self.value["owner"] != owner or self.value["status"] not in {
                "preparing", "prepared"
            }:
                raise RuntimeError("global attack reservation was lost")
            self.value.update({
                "active": True, "run_id": run_id,
                "started_at": datetime.now(timezone.utc).isoformat(),
                "status": "running", "last_error": None,
            })

    def release(self, owner: str, error: str | None = None) -> None:
        with self.lock:
            if self.value["owner"] not in {None, owner}:
                return
            self.value = {
                "active": False, "mode": "none", "owner": None, "rate": None,
                "run_id": None, "started_at": None, "status": "idle",
                "last_error": error,
            }

    def snapshot(self) -> dict[str, Any]:
        with self.lock:
            return dict(self.value)


def build_page2_attack_status(control: dict[str, Any]) -> dict[str, Any]:
    """Expose the minimum real attacker state required by the PC console."""
    state = control.get("attack_state") if isinstance(control.get("attack_state"), dict) else {}
    engine = control.get("engine") if isinstance(control.get("engine"), dict) else {}
    state_mode = str(state.get("mode") or "none").lower()
    selected_mode = str(control.get("selected_mode") or "none").lower()
    mode = state_mode if state.get("owner") == "page2" and state_mode in {
        "tamper", "replay"
    } else selected_mode
    active = bool(state.get("active")) and state.get("owner") == "page2"
    engine_mode = str(engine.get("mode") or "").lower()
    current_engine = engine if mode in {"tamper", "replay"} and engine_mode == mode else {}

    result: dict[str, Any] = {
        "schema_version": 1,
        "source_role": "jetson-attacker",
        "active": active,
        "mode": mode if mode in {"tamper", "replay"} else "none",
        "rate": int(control.get("selected_rate")) if mode in {"tamper", "replay"}
        and control.get("selected_rate") is not None else None,
        "count": 0,
        "runtime_ms": max(0, round(float(control.get("elapsed_s") or 0.0) * 1000)),
    }
    if mode == "tamper":
        modified_frames = int(current_engine.get("modified_frames_total") or 0)
        modified_packets = int(current_engine.get("modified_packets_total") or 0)
        result["count"] = modified_frames
        if modified_frames > 0 and modified_packets > 0 and \
           current_engine.get("last_frame_id") is not None and \
           current_engine.get("last_packet_index") is not None:
            result["last_target"] = {
                "frame_id": int(current_engine["last_frame_id"]),
                "packet_id": int(current_engine["last_packet_index"]),
            }
    elif mode == "replay":
        injected_frames = int(current_engine.get("injected_frames_total") or 0)
        result["count"] = injected_frames
        if injected_frames > 0 and current_engine.get("source_frame_id") is not None:
            result["last_target"] = {
                "frame_id": int(current_engine["source_frame_id"]),
            }
    return result


class Page2AttackManager:
    MODES = {"tamper", "replay"}
    RATES = {5, 10, 20, 40, 60}
    VIDEO_FILTER = (
        "ether src 02:00:00:00:00:02 and ether dst 02:00:00:00:00:03 "
        "and src host 10.10.15.2 and dst host 10.10.15.3 "
        "and udp src port 5602 and udp dst port 5602 and udp[4:2] = 1480"
    )

    def __init__(self, project: Path, global_state: GlobalAttackState,
                 stream: StreamAnalysisState,
                 stream_interface: str = "eno1") -> None:
        self.project = project
        self.global_state = global_state
        self.stream = stream
        self.stream_interface = stream_interface
        self.runtime = project / "runtime" / "attack"
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.tamperctl = project / "tamper" / "tamperctl"
        self.replay_engine = project / "replay" / "replay_engine"
        self.replay_status = self.runtime / "replay-status.json"
        self.replay_source = self.runtime / "replay-source.pcap"
        self.replay_log = self.runtime / "replay.log"
        self.operation_lock = threading.RLock()
        self.process: subprocess.Popen[str] | None = None
        self.log_stream: Any = None
        self.mode: str | None = None
        self.rate: int | None = None
        self.last_engine: dict[str, Any] | None = None
        self.last_error: str | None = None
        self.started_monotonic: float | None = None
        self.last_elapsed_s = 0.0

    @staticmethod
    def _json_command(command: list[str], timeout: float = 20.0) -> dict[str, Any]:
        completed = subprocess.run(
            command, check=True, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=timeout,
        )
        return json.loads(completed.stdout.strip().splitlines()[-1])

    def _tamper_status(self) -> dict[str, Any]:
        return self._json_command([str(self.tamperctl), "status"], timeout=5.0)

    def _egress_interface(self) -> str:
        bridge_ports = Path("/sys/class/net/br-video/brif")
        candidates = sorted(path.name for path in bridge_ports.iterdir()
                            if path.name != self.stream_interface)
        live = [name for name in candidates if
                (Path("/sys/class/net") / name / "carrier").read_text().strip() == "1"]
        if len(live) != 1:
            raise RuntimeError(f"expected one live RX-facing bridge port, found {live}")
        return live[0]

    def _preflight(self) -> None:
        stream = self.stream.snapshot()
        if not stream.get("live") or stream.get("mode") != "ciphertext":
            raise RuntimeError("live AES-GCM ciphertext stream is required")
        for interface in (self.stream_interface, self._egress_interface()):
            root = Path("/sys/class/net") / interface
            if (root / "operstate").read_text().strip() != "up" or \
               (root / "carrier").read_text().strip() != "1":
                raise RuntimeError(f"{interface} is not UP with carrier")

    def prepare(self, mode: str, rate: int) -> dict[str, Any]:
        if mode not in self.MODES or rate not in self.RATES:
            raise ValueError("mode must be tamper/replay and rate must be 5/10/20/40/60")
        with self.operation_lock:
            self.global_state.reserve(mode, "page2", rate)
            try:
                self._preflight()
                if mode == "tamper":
                    engine = self._tamper_status()
                    if engine.get("active") or engine.get("replay_gate_active"):
                        raise RuntimeError("Tamper engine is not in ATTACK OFF state")
                else:
                    if subprocess.run(
                        ["pgrep", "-x", "replay_engine"], check=False,
                        stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL,
                    ).returncode == 0:
                        raise RuntimeError("Replay engine is already active")
                    self.replay_source.unlink(missing_ok=True)
                    completed = subprocess.run([
                        "/usr/bin/dumpcap", "-q", "-i", self.stream_interface,
                        "-P", "-c", "5000",
                        "-f", self.VIDEO_FILTER, "-w", str(self.replay_source),
                    ], check=False, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE,
                       timeout=15.0)
                    if completed.returncode != 0 or not self.replay_source.is_file():
                        message = completed.stderr.decode("utf-8", "replace").strip()
                        raise RuntimeError(message[-300:] or "Replay source capture failed")
                    engine = {
                        "implementation": "frame-boundary-configurable-replay",
                        "active": False, "mode": "replay", "phase": "prepared",
                        "rate_percent": rate, "source_capture": str(self.replay_source),
                    }
                self.mode, self.rate, self.last_engine = mode, rate, engine
                self.last_elapsed_s = 0.0
                self.last_error = None
                self.global_state.prepared("page2")
                return self.snapshot()
            except Exception as error:
                self.last_error = f"{type(error).__name__}: {error}"
                self.global_state.release("page2", self.last_error)
                raise

    def start(self, mode: str, rate: int) -> dict[str, Any]:
        if mode not in self.MODES or rate not in self.RATES:
            raise ValueError("invalid attack mode or rate")
        with self.operation_lock:
            reserved = self.global_state.snapshot()
            if reserved.get("owner") != "page2" or reserved.get("mode") != mode or \
               reserved.get("rate") != rate or reserved.get("status") != "prepared":
                raise RuntimeError("matching prepared attack is required")
            try:
                if mode == "tamper":
                    engine = self._json_command(
                        [str(self.tamperctl), "start", str(rate)], timeout=5.0
                    )
                    if not engine.get("active"):
                        raise RuntimeError("Tamper engine did not enter active state")
                else:
                    self.replay_status.unlink(missing_ok=True)
                    self.log_stream = self.replay_log.open("w", encoding="utf-8")
                    self.process = subprocess.Popen([
                        str(self.replay_engine), "--rate", str(rate), "--status",
                        str(self.replay_status), "--source", str(self.replay_source),
                        f"{self.stream_interface}:{self._egress_interface()}",
                        "--shots", "0",
                        "--pacing", "original", "--qdisc-bypass", "0",
                        "--priority", "6",
                    ], stdout=self.log_stream, stderr=subprocess.STDOUT, text=True)
                    deadline = time.monotonic() + 8.0
                    engine = {}
                    while time.monotonic() < deadline:
                        if self.process.poll() is not None:
                            raise RuntimeError(f"Replay engine exited {self.process.returncode}")
                        try:
                            engine = json.loads(self.replay_status.read_text(encoding="utf-8"))
                        except (FileNotFoundError, json.JSONDecodeError):
                            time.sleep(0.05)
                            continue
                        if engine.get("active"):
                            break
                        time.sleep(0.05)
                    else:
                        raise RuntimeError("Replay engine did not enter active state")
                self.mode, self.rate, self.last_engine = mode, rate, engine
                self.started_monotonic = time.monotonic()
                self.last_elapsed_s = 0.0
                self.last_error = None
                self.global_state.running("page2", engine.get("run_id"))
                return self.snapshot()
            except Exception as error:
                self.last_error = f"{type(error).__name__}: {error}"
                self._cleanup_engine()
                self.global_state.release("page2", self.last_error)
                raise

    def _cleanup_engine(self) -> None:
        if self.mode == "tamper":
            try:
                self.last_engine = self._json_command(
                    [str(self.tamperctl), "stop"], timeout=5.0
                )
            except Exception as error:
                self.last_error = f"{type(error).__name__}: {error}"
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=5.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=2.0)
        if self.log_stream is not None:
            self.log_stream.close()
            self.log_stream = None
        if self.mode == "replay":
            try:
                self.last_engine = json.loads(self.replay_status.read_text(encoding="utf-8"))
            except (FileNotFoundError, json.JSONDecodeError):
                pass
        self.process = None

    def stop(self) -> dict[str, Any]:
        with self.operation_lock:
            if self.started_monotonic is not None:
                self.last_elapsed_s = max(
                    0.0, time.monotonic() - self.started_monotonic
                )
            self._cleanup_engine()
            self.global_state.release("page2", self.last_error)
            self.started_monotonic = None
            return self.snapshot()

    def reset(self) -> dict[str, Any]:
        with self.operation_lock:
            self.stop()
            self.mode = self.rate = None
            self.last_engine = None
            self.last_error = None
            self.last_elapsed_s = 0.0
            self.replay_status.unlink(missing_ok=True)
            self.replay_source.unlink(missing_ok=True)
            return self.snapshot()

    def snapshot(self) -> dict[str, Any]:
        with self.operation_lock:
            global_value = self.global_state.snapshot()
            if self.mode == "tamper" and global_value.get("owner") == "page2":
                try:
                    self.last_engine = self._tamper_status()
                except Exception as error:
                    self.last_error = f"{type(error).__name__}: {error}"
            elif self.mode == "replay":
                try:
                    self.last_engine = json.loads(
                        self.replay_status.read_text(encoding="utf-8")
                    )
                except (FileNotFoundError, json.JSONDecodeError):
                    pass
                if self.process is not None and self.process.poll() is not None and \
                   global_value.get("owner") == "page2" and global_value.get("active"):
                    self.last_error = f"Replay engine exited {self.process.returncode}"
                    if self.started_monotonic is not None:
                        self.last_elapsed_s = max(
                            0.0, time.monotonic() - self.started_monotonic
                        )
                    self._cleanup_engine()
                    self.global_state.release("page2", self.last_error)
                    self.started_monotonic = None
                    global_value = self.global_state.snapshot()
            elapsed = self.last_elapsed_s if self.started_monotonic is None else max(
                0.0, time.monotonic() - self.started_monotonic
            )
            return {
                "attack_state": global_value,
                "engine": None if self.last_engine is None else dict(self.last_engine),
                "selected_mode": self.mode, "selected_rate": self.rate,
                "elapsed_s": round(elapsed, 3), "last_error": self.last_error,
            }

    def attack_status(self) -> dict[str, Any]:
        return build_page2_attack_status(self.snapshot())


class BruteForceManager:
    PROFILES = {"cpu-multi", "cuda-low", "cuda-mid", "cuda-max"}
    PREPARE_COMMAND_TIMEOUT_S = 3.0
    PREPARE_CAPTURE_TIMEOUT_S = 8.0
    PREPARE_RETRY_DELAY_S = 0.25

    def __init__(self, project: Path, telemetry: TelemetryState,
                 stream: StreamAnalysisState, metrics: SystemMetricsState,
                 global_state: GlobalAttackState,
                 stream_interface: str = "eno1") -> None:
        self.project = project
        self.telemetry = telemetry
        self.stream = stream
        self.metrics = metrics
        self.global_state = global_state
        self.stream_interface = stream_interface
        self.directory = project / "bruteforce"
        self.runtime = project / "runtime" / "bruteforce"
        self.runtime.mkdir(parents=True, exist_ok=True)
        self.status_path = self.runtime / "search-status.json"
        self.record_path = self.runtime / "live-record.bin"
        self.record_metadata_path = self.runtime / "live-record.json"
        self.recovered_metadata_path = self.runtime / "recovered-frame.json"
        self.lock = threading.Lock()
        self.operation_lock = threading.Lock()
        self.process: subprocess.Popen[str] | None = None
        self.log_stream: Any = None
        self.phase = "secure"
        self.prepare_step = -1
        self.prepare_request_id: int | None = None
        self.prepare_bits: int | None = None
        self.prepare_attempt = 0
        self.prepare_status = "idle"
        self.prepare_token = 0
        self.prepare_cancel: threading.Event | None = None
        self.prepare_thread: threading.Thread | None = None
        self.secure_request_id: int | None = None
        self.secure_attempt = 0
        self.secure_status = "idle"
        self.secure_thread: threading.Thread | None = None
        self.session: dict[str, Any] | None = None
        self.record: dict[str, Any] | None = None
        self.last_error: str | None = None
        self.run_id = 0
        self.history: deque[dict[str, Any]] = deque(maxlen=720)
        self.last_history_tested: int | None = None
        self.recovered_frame: dict[str, Any] | None = None
        self.recovery: dict[str, Any] = {"phase": "idle"}
        self.recovery_run_id: int | None = None
        self.status_path.unlink(missing_ok=True)

    def _recover_frame(self, run_id: int, seed: int, session_id: str) -> None:
        try:
            metadata = self._json_command([
                "python3", str(self.directory / "recover_frame.py"),
                "--seed", str(seed), "--session", session_id,
                "--run-id", str(run_id), "--output-dir",
                str(Path.home() / "Desktop" / "Weak-Key-Recovered-Frames"),
                "--metadata", str(self.recovered_metadata_path),
            ], timeout=25.0)
            metadata["url"] = BRUTEFORCE_FRAME_PATH
            with self.lock:
                if self.recovery_run_id == run_id:
                    self.recovered_frame = metadata
                    self.recovery = {"phase": "ready", "run_id": run_id}
        except Exception as error:
            with self.lock:
                if self.recovery_run_id == run_id:
                    self.recovery = {
                        "phase": "error", "run_id": run_id,
                        "error": f"{type(error).__name__}: {error}",
                    }

    def recovered_path(self) -> Path | None:
        with self.lock:
            value = None if self.recovered_frame is None else dict(self.recovered_frame)
        if not value:
            return None
        path = Path(str(value.get("desktop_path", "")))
        return path if path.is_file() else None

    def vlm_source(self, run_id: int, sha256: str) -> tuple[Path, dict[str, Any]]:
        try:
            search = json.loads(self.status_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError) as error:
            raise RuntimeError("Weak-Key search result is unavailable") from error
        with self.lock:
            current_run_id = self.run_id
            phase = self.phase
            recovery = dict(self.recovery)
            metadata = None if self.recovered_frame is None else dict(self.recovered_frame)
        if phase != "found" or search.get("phase") != "found":
            raise RuntimeError("Weak-Key search is not complete")
        if not search.get("tag_verified"):
            raise RuntimeError("GCM TAG verification did not pass")
        if recovery.get("phase") != "ready" or not metadata:
            raise RuntimeError("decrypted image is not ready")
        if run_id != current_run_id or int(metadata.get("run_id", -1)) != run_id:
            raise RuntimeError("requested image is not the current Weak-Key result")
        if not sha256 or str(metadata.get("sha256", "")) != sha256:
            raise RuntimeError("recovered image identity does not match")
        path = Path(str(metadata.get("desktop_path", "")))
        if not path.is_file():
            raise RuntimeError("recovered image file is unavailable")
        return path, metadata

    @staticmethod
    def _json_command(command: list[str], timeout: float = 30.0) -> dict[str, Any]:
        completed = subprocess.run(
            command, check=False, text=True, stdout=subprocess.PIPE,
            stderr=subprocess.PIPE, timeout=timeout,
        )
        if completed.returncode != 0:
            details = completed.stderr.strip().splitlines()
            message = details[-1] if details else f"command exited {completed.returncode}"
            raise RuntimeError(message)
        return json.loads(completed.stdout.strip().splitlines()[-1])

    def _attack_preflight(self) -> None:
        tamper_result = subprocess.run(
            [str(self.project / "tamper" / "tamperctl"), "status"],
            check=False, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        )
        if tamper_result.returncode == 0:
            tamper = json.loads(tamper_result.stdout)
            if tamper.get("active") or tamper.get("replay_gate_active"):
                raise RuntimeError("Tamper or Replay gate is active")
        else:
            link = subprocess.check_output(
                ["ip", "-details", "link", "show", "dev", self.stream_interface],
                text=True,
            )
            if "prog/xdp" in link:
                raise RuntimeError("XDP is attached but Tamper status is unavailable")
        for process_name in ("replay_engine",):
            result = subprocess.run(["pgrep", "-x", process_name], check=False,
                                    stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
            if result.returncode == 0:
                raise RuntimeError(f"{process_name} is active")
        result = subprocess.run(["pgrep", "-f", "ai-data/collector.py"], check=False,
                                stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        if result.returncode == 0:
            raise RuntimeError("AI collector is active")
        bridge_ports = Path("/sys/class/net/br-video/brif")
        peer_interfaces = sorted(
            path.name for path in bridge_ports.iterdir()
            if path.name != self.stream_interface
        )
        if len(peer_interfaces) != 1:
            raise RuntimeError(
                f"expected one RX-facing bridge port, found {peer_interfaces}"
            )
        for interface in (self.stream_interface, peer_interfaces[0]):
            root = Path("/sys/class/net") / interface
            if (root / "operstate").read_text().strip() != "up" or \
               (root / "carrier").read_text().strip() != "1":
                raise RuntimeError(f"{interface} is not UP with carrier")
        stream = self.stream.snapshot()
        if not stream.get("live") or stream.get("mode") != "ciphertext":
            raise RuntimeError("live AES-GCM ciphertext stream is required")

    def _set_failure(self, error: Exception) -> None:
        with self.lock:
            self.phase = "error"
            self.last_error = f"{type(error).__name__}: {error}"

    def _capture_for_session(self, session_id: str, timeout: float = 8.0) -> dict[str, Any]:
        """Capture only after the live TX stream has entered the requested session."""
        deadline = time.monotonic() + timeout
        last_session: Any = None
        last_error: Exception | None = None
        while time.monotonic() < deadline:
            try:
                metadata = self._json_command([
                    "python3", str(self.directory / "capture_record.py"),
                    "--output", str(self.record_path),
                    "--metadata", str(self.record_metadata_path),
                    "--interface", self.stream_interface,
                ], timeout=5.0)
                last_session = metadata.get("session_id")
                if last_session == session_id:
                    return metadata
            except (subprocess.SubprocessError, json.JSONDecodeError, OSError) as error:
                last_error = error
            time.sleep(0.1)
        detail = f"; last capture error: {last_error}" if last_error else \
            f"; last captured session: {last_session}"
        raise RuntimeError(f"live TX stream did not enter session {session_id}{detail}")

    def _request_weak_session(self, bits: int, request_id: int) -> dict[str, Any]:
        return self._json_command([
            "python3", str(self.directory / "session_control.py"),
            "--weak", str(bits), "--request-id", str(request_id),
            "--timeout", str(self.PREPARE_COMMAND_TIMEOUT_S),
        ], timeout=self.PREPARE_COMMAND_TIMEOUT_S + 2.0)

    def _request_secure_session(self, request_id: int) -> dict[str, Any]:
        return self._json_command([
            "python3", str(self.directory / "session_control.py"),
            "--secure", "--request-id", str(request_id),
            "--timeout", str(self.PREPARE_COMMAND_TIMEOUT_S),
        ], timeout=self.PREPARE_COMMAND_TIMEOUT_S + 2.0)

    def _prepare_is_current(self, token: int, cancel: threading.Event) -> bool:
        return self.prepare_token == token and self.prepare_cancel is cancel \
            and not cancel.is_set()

    def _prepare_worker(
        self,
        token: int,
        bits: int,
        request_id: int,
        cancel: threading.Event,
        previous_thread: threading.Thread | None,
    ) -> None:
        if previous_thread is not None and previous_thread is not threading.current_thread():
            while previous_thread.is_alive():
                if cancel.wait(0.05):
                    return

        while not cancel.is_set():
            with self.lock:
                if not self._prepare_is_current(token, cancel):
                    return
                self.prepare_attempt += 1
                self.prepare_status = "checking-live-stream"
            try:
                self._attack_preflight()
                with self.lock:
                    if not self._prepare_is_current(token, cancel):
                        return
                    self.prepare_status = "requesting-session"
                session = self._request_weak_session(bits, request_id)
                if session.get("profile") != "weak" or \
                   session.get("request_id") != request_id or \
                   session.get("seed_bits") != bits or not session.get("session_id"):
                    raise RuntimeError("TX returned mismatched weak-session metadata")
                with self.lock:
                    if not self._prepare_is_current(token, cancel):
                        return
                    # This ACK proves the TX derive, X25519/HKDF, and RX commit.
                    self.prepare_step = 4
                    self.prepare_status = "capturing-matching-packet"
                metadata = self._capture_for_session(
                    str(session["session_id"]),
                    timeout=self.PREPARE_CAPTURE_TIMEOUT_S,
                )
                if metadata.get("session_id") != session.get("session_id"):
                    raise RuntimeError(
                        "captured packet session does not match the acknowledged session"
                    )
                with self.operation_lock:
                    with self.lock:
                        if not self._prepare_is_current(token, cancel):
                            return
                        self.session = session
                        self.record = metadata
                        self.phase, self.prepare_step = "weak-ready", 4
                        self.prepare_status = "ready"
                        self.last_error = None
                        self.prepare_thread = None
                    self.global_state.release("page3")
                return
            except Exception as error:
                with self.lock:
                    if not self._prepare_is_current(token, cancel):
                        return
                    self.prepare_status = "retrying"
                    self.last_error = f"{type(error).__name__}: {error}"
                if cancel.wait(self.PREPARE_RETRY_DELAY_S):
                    return

    def _cancel_prepare(self) -> threading.Thread | None:
        with self.lock:
            previous = self.prepare_thread
            if self.prepare_cancel is not None:
                self.prepare_cancel.set()
            self.prepare_token += 1
            self.prepare_cancel = None
            self.prepare_thread = None
            self.prepare_request_id = None
            self.prepare_bits = None
            self.prepare_attempt = 0
            self.prepare_status = "idle"
            return previous

    def _secure_worker(
        self,
        request_id: int,
        previous_thread: threading.Thread | None,
    ) -> None:
        if previous_thread is not None and previous_thread is not threading.current_thread():
            previous_thread.join()

        current = threading.current_thread()
        while True:
            with self.lock:
                if self.secure_thread is not current:
                    return
                self.secure_attempt += 1
                self.secure_status = "requesting-session"
            try:
                session = self._request_secure_session(request_id)
                if session.get("profile") != "secure" or \
                   session.get("request_id") != request_id or not session.get("session_id"):
                    raise RuntimeError("TX returned mismatched secure-session metadata")
                with self.lock:
                    if self.secure_thread is not current:
                        return
                    self.secure_status = "capturing-matching-packet"
                metadata = self._capture_for_session(
                    str(session["session_id"]),
                    timeout=self.PREPARE_CAPTURE_TIMEOUT_S,
                )
                if metadata.get("session_id") != session.get("session_id"):
                    raise RuntimeError(
                        "captured packet session does not match the secure ACK"
                    )
                with self.operation_lock:
                    with self.lock:
                        if self.secure_thread is not current:
                            return
                        self.phase, self.session, self.record = "secure", session, None
                        self.prepare_step = -1
                        self.prepare_status = "idle"
                        self.secure_status = "ready"
                        self.secure_thread = None
                        self.process = None
                        self.last_error = None
                    self.global_state.release("page3")
                return
            except Exception as error:
                with self.lock:
                    if self.secure_thread is not current:
                        return
                    self.secure_status = "retrying"
                    self.last_error = f"{type(error).__name__}: {error}"
                time.sleep(self.PREPARE_RETRY_DELAY_S)

    def _start_secure_transition(
        self,
        previous_thread: threading.Thread | None,
    ) -> None:
        with self.lock:
            if self.secure_thread is not None and self.secure_thread.is_alive():
                return
        state = self.global_state.snapshot()
        if state.get("owner") not in {None, "page3"}:
            raise RuntimeError(f"ACTIVE ATTACK: {str(state.get('mode')).upper()}")
        if state.get("owner") is None:
            self.global_state.reserve("bruteforce", "page3", None)
        request_id = secrets.randbits(64) or 1
        with self.lock:
            self.phase = "returning-secure"
            self.session = None
            self.record = None
            self.secure_request_id = request_id
            self.secure_attempt = 0
            self.secure_status = "waiting-for-weak-request"
            self.last_error = None
            thread = threading.Thread(
                target=self._secure_worker,
                args=(request_id, previous_thread),
                daemon=True,
                name=f"secure-session-restore-{request_id}",
            )
            self.secure_thread = thread
        thread.start()

    def prepare(self, bits: int) -> dict[str, Any]:
        if bits not in range(20, 27):
            raise ValueError("bits must be 20..26")
        with self.operation_lock:
            with self.lock:
                if self.process is not None and self.process.poll() is None:
                    raise RuntimeError("search is active")
                if self.secure_thread is not None and self.secure_thread.is_alive():
                    raise RuntimeError("secure session recovery is active")
                same_operation = self.phase == "weak-preparing" and \
                    self.prepare_bits == bits and self.prepare_thread is not None and \
                    self.prepare_thread.is_alive()
            if same_operation:
                return self.snapshot()

            previous_thread = self._cancel_prepare()
            self.global_state.release("page3")
            self.global_state.reserve("bruteforce", "page3", None)
            request_id = secrets.randbits(64) or 1
            cancel = threading.Event()
            with self.lock:
                self.prepare_token += 1
                token = self.prepare_token
                self.prepare_cancel = cancel
                self.prepare_request_id = request_id
                self.prepare_bits = bits
                self.prepare_attempt = 0
                self.prepare_status = "queued"
                self.phase, self.prepare_step, self.last_error = "weak-preparing", 0, None
                self.session = None
                self.record = None
                thread = threading.Thread(
                    target=self._prepare_worker,
                    args=(token, bits, request_id, cancel, previous_thread),
                    daemon=True,
                    name=f"weak-session-prepare-{request_id}",
                )
                self.prepare_thread = thread
            thread.start()
            return self.snapshot()

    def start(self, bits: int, profile: str) -> dict[str, Any]:
        if bits not in range(20, 27) or profile not in self.PROFILES:
            raise ValueError("invalid bits or profile")
        with self.operation_lock:
            self.global_state.reserve("bruteforce", "page3", None)
            try:
                self._attack_preflight()
                with self.lock:
                    session = None if self.session is None else dict(self.session)
                    record = None if self.record is None else dict(self.record)
                if not session or session.get("seed_bits") != bits or not record:
                    raise RuntimeError("matching weak session and live record are required")
                metadata = self._capture_for_session(str(session.get("session_id")))
                with self.lock:
                    if self.process is not None and self.process.poll() is None:
                        raise RuntimeError("search is already active")
                    if not self.session or self.session.get("session_id") != session.get("session_id"):
                        raise RuntimeError("weak session changed while capturing a live record")
                    self.record = metadata
                    self.run_id += 1
                    self.history.clear()
                    self.history.append({"t": 0.0, "tested": 0})
                    self.last_history_tested = 0
                    self.recovered_frame = None
                    self.recovery = {"phase": "idle", "run_id": self.run_id}
                    self.recovery_run_id = None
                    self.recovered_metadata_path.unlink(missing_ok=True)
                    self.status_path.unlink(missing_ok=True)
                    log_path = self.runtime / f"search-{self.run_id}.log"
                    self.log_stream = log_path.open("w", encoding="utf-8")
                    self.process = subprocess.Popen([
                        str(self.directory / "weakkey_search"),
                        "--record", str(self.record_path), "--bits", str(bits),
                        "--profile", profile, "--status", str(self.status_path),
                    ], stdout=self.log_stream, stderr=subprocess.STDOUT, text=True)
                    self.phase, self.last_error = "searching", None
                self.global_state.running("page3", self.run_id)
                return self.snapshot()
            except Exception as error:
                self.global_state.release("page3", f"{type(error).__name__}: {error}")
                raise

    def stop(self) -> dict[str, Any]:
        with self.operation_lock:
            with self.lock:
                preparing = self.phase == "weak-preparing"
                securing = self.secure_thread is not None and self.secure_thread.is_alive()
            if securing:
                return self.snapshot()
            if preparing:
                previous_thread = self._cancel_prepare()
                self._start_secure_transition(previous_thread)
                return self.snapshot()
            with self.lock:
                process = self.process
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2.0)
            with self.lock:
                if self.phase == "searching":
                    self.phase = "weak-ready"
            self.global_state.release("page3")
            return self.snapshot()

    def secure(self) -> dict[str, Any]:
        with self.operation_lock:
            state = self.global_state.snapshot()
            if state.get("owner") not in {None, "page3"}:
                raise RuntimeError(f"ACTIVE ATTACK: {str(state.get('mode')).upper()}")
            if state.get("owner") is None:
                self.global_state.reserve("bruteforce", "page3", None)
            with self.lock:
                securing = self.secure_thread is not None and self.secure_thread.is_alive()
            if securing:
                return self.snapshot()
            previous_thread = self._cancel_prepare()
            with self.lock:
                process = self.process
            if process is not None and process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=5.0)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait(timeout=2.0)
            with self.lock:
                self.process = None
                if self.log_stream is not None:
                    self.log_stream.close()
                    self.log_stream = None
            self._start_secure_transition(previous_thread)
            return self.snapshot()

    def reset(self) -> dict[str, Any]:
        with self.operation_lock:
            with self.lock:
                if self.process is not None and self.process.poll() is None:
                    raise RuntimeError("stop the search before reset")
                preparing = self.phase == "weak-preparing"
                securing = self.secure_thread is not None and self.secure_thread.is_alive()
            if preparing:
                previous_thread = self._cancel_prepare()
            with self.lock:
                self.history.clear()
                self.last_history_tested = None
                self.status_path.unlink(missing_ok=True)
                if not preparing and not securing and self.phase in {
                    "found", "not_found", "stopped", "error"
                }:
                    self.phase = "weak-ready" if self.session and self.record else "secure"
                self.last_error = None
            if preparing:
                self._start_secure_transition(previous_thread)
            elif not securing:
                self.global_state.release("page3")
            return self.snapshot()

    def snapshot(self) -> dict[str, Any]:
        search: dict[str, Any] | None = None
        benchmarks: dict[str, Any] = {"profiles": {}}
        try:
            search = json.loads(self.status_path.read_text(encoding="utf-8"))
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        try:
            benchmarks = json.loads(
                (self.directory / "benchmarks.json").read_text(encoding="utf-8")
            )
        except (FileNotFoundError, json.JSONDecodeError):
            pass
        with self.lock:
            if self.process is not None and self.process.poll() is not None:
                if search and search.get("phase") in {"found", "not_found", "stopped"}:
                    self.phase = search["phase"]
                elif self.phase == "searching":
                    self.phase = "error"
                    self.last_error = f"search exited {self.process.returncode}"
                if self.log_stream is not None:
                    self.log_stream.close()
                    self.log_stream = None
                self.process = None
                self.global_state.release("page3", self.last_error)
            if search:
                tested = int(search.get("candidates_tested", 0))
                if tested != self.last_history_tested:
                    self.history.append({"t": float(search.get("elapsed_s", 0.0)),
                                         "tested": tested})
                    self.last_history_tested = tested
                if search.get("phase") == "found" and search.get("tag_verified") and \
                   self.recovery_run_id != self.run_id:
                    self.recovery_run_id = self.run_id
                    self.recovery = {"phase": "recovering", "run_id": self.run_id}
                    threading.Thread(
                        target=self._recover_frame,
                        args=(self.run_id, int(search["found_seed"]),
                              str(self.session["session_id"])),
                        daemon=True,
                        name=f"weak-frame-recovery-{self.run_id}",
                    ).start()
            stream = self.stream.snapshot()
            record_live = bool(
                self.record and self.session and self.session.get("profile") == "weak"
                and self.record.get("session_id") == self.session.get("session_id")
                and stream.get("live") and stream.get("mode") == "ciphertext"
            )
            return {
                "phase": self.phase, "prepare_step": self.prepare_step,
                "prepare_request_id": self.prepare_request_id,
                "prepare_bits": self.prepare_bits,
                "prepare_attempt": self.prepare_attempt,
                "prepare_status": self.prepare_status,
                "secure_request_id": self.secure_request_id,
                "secure_attempt": self.secure_attempt,
                "secure_status": self.secure_status,
                "run_id": self.run_id,
                "last_error": self.last_error,
                "session": None if self.session is None else dict(self.session),
                "record": None if self.record is None else dict(self.record),
                "input_source": "CAPTURED FROM LIVE STREAM" if record_live else "NO LIVE RECORD",
                "search": search, "history": list(self.history),
                "benchmarks": benchmarks,
                "metrics": self.metrics.snapshot(),
                "recovery": dict(self.recovery),
                "recovered_frame": None if self.recovered_frame is None
                else dict(self.recovered_frame),
                "attack_state": self.global_state.snapshot(),
            }


def load_validator(path: Path) -> Callable[[Any], list[str]]:
    spec = importlib.util.spec_from_file_location("zybo_telemetry_receiver", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load telemetry validator: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    validator = getattr(module, "validate_payload", None)
    if not callable(validator):
        raise RuntimeError(f"validate_payload() not found: {path}")
    return validator


def load_stream_analyzer(path: Path) -> Callable[[bytes], dict[str, Any]]:
    spec = importlib.util.spec_from_file_location("zybo_stream_stats", path)
    if spec is None or spec.loader is None:
        raise RuntimeError(f"cannot load stream analyzer: {path}")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    analyzer = getattr(module, "analyze_pcap_bytes", None)
    if not callable(analyzer):
        raise RuntimeError(f"analyze_pcap_bytes() not found: {path}")
    return analyzer


def make_handler(
    dashboard: Path,
    state: TelemetryState,
    stream_state: StreamAnalysisState | None = None,
    brute_force: BruteForceManager | None = None,
    event_state: SecurityEventState | None = None,
    metrics_state: SystemMetricsState | None = None,
    global_attack: GlobalAttackState | None = None,
    page2_attack: Page2AttackManager | None = None,
) -> type[SimpleHTTPRequestHandler]:
    class DashboardHandler(SimpleHTTPRequestHandler):
        def __init__(self, *args: Any, **kwargs: Any) -> None:
            super().__init__(*args, directory=str(dashboard), **kwargs)

        def end_headers(self) -> None:
            path = self.path.partition("?")[0]
            if not path.startswith("/api/") and (
                path in {"/", "/index.html"} or path.endswith(".html")
            ):
                self.send_header("Cache-Control", "no-store, max-age=0")
                self.send_header("Pragma", "no-cache")
            super().end_headers()

        def log_message(self, format: str, *args: Any) -> None:
            if not self.path.partition("?")[0].startswith("/api/"):
                super().log_message(format, *args)

        def send_json(self, value: Any, status: int = 200) -> None:
            body = json.dumps(value, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
            self.send_response(status)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("X-Content-Type-Options", "nosniff")
            self.send_header("Content-Length", str(len(body)))
            self.end_headers()
            self.wfile.write(body)

        def do_GET(self) -> None:
            path = self.path.partition("?")[0]
            if path == ATTACK_STATUS_PATH and page2_attack is not None:
                self.send_json(page2_attack.attack_status())
                return
            if path == BRUTEFORCE_STATUS_PATH and brute_force is not None:
                self.send_json(brute_force.snapshot())
                return
            if path == BRUTEFORCE_FRAME_PATH and brute_force is not None:
                image = brute_force.recovered_path()
                if image is None:
                    self.send_error(404, "recovered frame is not ready")
                    return
                body = image.read_bytes()
                self.send_response(200)
                self.send_header("Content-Type", "image/png")
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.send_header("Content-Length", str(len(body)))
                self.end_headers()
                self.wfile.write(body)
                return
            if path != API_PATH:
                super().do_GET()
                return
            snapshot = state.snapshot()
            snapshot["stream_analysis"] = (
                None if stream_state is None else stream_state.snapshot()
            )
            snapshot["security_events"] = (
                None if event_state is None else event_state.snapshot()
            )
            snapshot["system_metrics"] = (
                None if metrics_state is None else metrics_state.snapshot()
            )
            snapshot["attack_state"] = (
                None if global_attack is None else global_attack.snapshot()
            )
            snapshot["attack_control"] = (
                None if page2_attack is None else page2_attack.snapshot()
            )
            self.send_json(snapshot)

        def do_POST(self) -> None:
            path = self.path.partition("?")[0]
            attack_action = ATTACK_ACTIONS.get(path)
            action = BRUTEFORCE_ACTIONS.get(path)
            vlm_action = path == VLM_ANALYZE_PATH and brute_force is not None
            if not vlm_action and attack_action is None and (action is None or brute_force is None):
                self.send_json({"error": "not found"}, 404)
                return
            if self.headers.get_content_type() != "application/json":
                self.send_json({"error": "application/json required"}, 415)
                return
            try:
                length = int(self.headers.get("Content-Length", "0"))
                if length < 0 or length > 4096:
                    raise ValueError("invalid content length")
                payload = json.loads(self.rfile.read(length) or b"{}")
                if not isinstance(payload, dict):
                    raise ValueError("JSON object required")
                if vlm_action:
                    if not VLM_REQUEST_LOCK.acquire(blocking=False):
                        self.send_json({"error": "Local VLM inference is already running"}, 409)
                        return
                    try:
                        image_path, metadata = brute_force.vlm_source(
                            int(payload.get("run_id", -1)), str(payload.get("sha256", ""))
                        )
                        result = analyze_recovered_frame(image_path, metadata)
                    finally:
                        VLM_REQUEST_LOCK.release()
                elif attack_action is not None:
                    if page2_attack is None:
                        raise RuntimeError("Page 2 attack manager is unavailable")
                    if attack_action == "prepare":
                        result = page2_attack.prepare(
                            str(payload.get("mode", "")), int(payload.get("rate", 0))
                        )
                    elif attack_action == "start":
                        result = page2_attack.start(
                            str(payload.get("mode", "")), int(payload.get("rate", 0))
                        )
                    elif attack_action == "stop":
                        result = page2_attack.stop()
                    else:
                        result = page2_attack.reset()
                elif action == "prepare":
                    result = brute_force.prepare(int(payload.get("bits", 0)))
                elif action == "start":
                    result = brute_force.start(
                        int(payload.get("bits", 0)), str(payload.get("profile", ""))
                    )
                elif action == "stop":
                    result = brute_force.stop()
                elif action == "secure":
                    result = brute_force.secure()
                else:
                    result = brute_force.reset()
                self.send_json(result)
            except (ValueError, TypeError, json.JSONDecodeError) as error:
                self.send_json({"error": str(error)}, 400)
            except Exception as error:
                self.send_json({"error": f"{type(error).__name__}: {error}"}, 409)

        def do_HEAD(self) -> None:
            if self.path.partition("?")[0] not in {
                API_PATH, ATTACK_STATUS_PATH, BRUTEFORCE_STATUS_PATH
            }:
                super().do_HEAD()
                return
            self.send_response(200)
            self.send_header("Content-Type", "application/json; charset=utf-8")
            self.send_header("Cache-Control", "no-store")
            self.send_header("Content-Length", "0")
            self.end_headers()

    return DashboardHandler


def receive_udp(
    receiver: socket.socket, state: TelemetryState, stop: threading.Event
) -> None:
    receiver.settimeout(0.5)
    while not stop.is_set():
        try:
            packet, peer = receiver.recvfrom(65535)
        except socket.timeout:
            continue
        except OSError:
            break
        state.accept(packet, peer)


def expand_sampled_packet_timing(analysis: dict[str, Any]) -> dict[str, Any]:
    """Scale the deterministic packet-index sample back to the full stream."""
    sampled_rate_pps = analysis.get("packet_rate_pps")
    sampled_rate_kpps = analysis.get("packet_rate_kpps")
    sampled_inter_arrival_ms = analysis.get("packet_inter_arrival_ms")
    sampled_timing_jitter_ms = analysis.get("packet_timing_jitter_ms")
    analysis["packet_sample_stride"] = STREAM_CAPTURE_SAMPLE_STRIDE
    analysis["sampled_packet_rate_pps"] = sampled_rate_pps
    analysis["sampled_packet_rate_kpps"] = sampled_rate_kpps
    analysis["sampled_packet_inter_arrival_ms"] = sampled_inter_arrival_ms
    analysis["sampled_packet_timing_jitter_ms"] = sampled_timing_jitter_ms
    analysis["packet_rate_pps"] = (
        None if sampled_rate_pps is None
        else sampled_rate_pps * STREAM_CAPTURE_SAMPLE_STRIDE
    )
    analysis["packet_rate_kpps"] = (
        None if sampled_rate_kpps is None
        else sampled_rate_kpps * STREAM_CAPTURE_SAMPLE_STRIDE
    )
    analysis["packet_inter_arrival_ms"] = (
        None if sampled_inter_arrival_ms is None
        else sampled_inter_arrival_ms / STREAM_CAPTURE_SAMPLE_STRIDE
    )
    # The BPF observes every 256th packet. Normalize each observed interval to
    # a per-packet interval before exposing its population standard deviation
    # (IAT STD). This is measured from capture timestamps; it is not the inverse
    # of packet rate and it is unrelated to RX frame jitter.
    analysis["packet_timing_jitter_ms"] = (
        None if sampled_timing_jitter_ms is None
        else sampled_timing_jitter_ms / STREAM_CAPTURE_SAMPLE_STRIDE
    )
    return analysis


def sample_stream(
    interface: str,
    sample_count: int,
    interval: float,
    analyzer: Callable[[bytes], dict[str, Any]],
    state: StreamAnalysisState,
    stop: threading.Event,
) -> None:
    command = [
        "/usr/bin/dumpcap",
        "-q",
        "-i",
        interface,
        "-p",
        "-s",
        "1600",
        "-P",
        "-c",
        str(sample_count),
        "-f",
        STREAM_CAPTURE_FILTER,
        "-w",
        "-",
    ]
    while not stop.is_set():
        started = time.monotonic()
        try:
            completed = subprocess.run(
                command,
                check=False,
                stdout=subprocess.PIPE,
                stderr=subprocess.PIPE,
                timeout=max(3.0, interval * 3.0),
            )
            if completed.returncode != 0:
                error = completed.stderr.decode("utf-8", "replace").strip()
                state.fail(error[-300:] or f"dumpcap exit {completed.returncode}")
            else:
                analysis = expand_sampled_packet_timing(analyzer(completed.stdout))
                state.accept(analysis, (time.monotonic() - started) * 1000.0)
        except subprocess.TimeoutExpired:
            state.fail("dumpcap sample timed out")
        except Exception as error:
            state.fail(f"{type(error).__name__}: {error}")
        elapsed = time.monotonic() - started
        stop.wait(max(0.0, interval - elapsed))


def parse_args() -> argparse.Namespace:
    project = Path(__file__).resolve().parents[1]
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--udp-bind", default="10.10.15.1")
    parser.add_argument("--udp-port", type=int, default=47000)
    parser.add_argument("--event-bind", default="10.10.15.1")
    parser.add_argument("--event-port", type=int, default=47001)
    parser.add_argument("--peer", default="10.10.15.3")
    parser.add_argument("--http-bind", default="0.0.0.0")
    parser.add_argument("--http-port", type=int, default=4173)
    parser.add_argument("--dashboard", type=Path, default=project / "dashboard")
    parser.add_argument(
        "--validator", type=Path, default=project / "telemetry" / "receiver.py"
    )
    parser.add_argument("--live-timeout", type=float, default=1.0)
    parser.add_argument("--stream-interface", default="eno1")
    parser.add_argument("--stream-samples", type=int, default=16)
    parser.add_argument("--stream-interval", type=float, default=1.0)
    parser.add_argument(
        "--stream-analyzer",
        type=Path,
        default=project / "stream-randomness" / "pcap_stats.py",
    )
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    project = Path(__file__).resolve().parents[1]
    if not args.dashboard.is_dir():
        raise SystemExit(f"dashboard directory not found: {args.dashboard}")
    if not args.validator.is_file():
        raise SystemExit(f"telemetry receiver not found: {args.validator}")
    if not args.stream_analyzer.is_file():
        raise SystemExit(f"stream analyzer not found: {args.stream_analyzer}")
    if (not 0 < args.udp_port <= 65535 or
            not 0 < args.event_port <= 65535 or
            not 0 < args.http_port <= 65535):
        raise SystemExit("ports must be in the range 1..65535")
    if args.live_timeout <= 0:
        raise SystemExit("live timeout must be positive")
    if args.stream_samples <= 0 or args.stream_interval <= 0:
        raise SystemExit("stream sample count and interval must be positive")

    state = TelemetryState(
        load_validator(args.validator), args.peer, args.live_timeout
    )
    receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    receiver.bind((args.udp_bind, args.udp_port))
    stop = threading.Event()
    receiver_thread = threading.Thread(
        target=receive_udp, args=(receiver, state, stop), daemon=True
    )
    receiver_thread.start()

    event_state = SecurityEventState(args.peer)
    event_receiver = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    event_receiver.bind((args.event_bind, args.event_port))
    event_thread = threading.Thread(
        target=receive_udp, args=(event_receiver, event_state, stop), daemon=True
    )
    event_thread.start()

    stream_state = StreamAnalysisState()
    stream_thread = threading.Thread(
        target=sample_stream,
        args=(
            args.stream_interface,
            args.stream_samples,
            args.stream_interval,
            load_stream_analyzer(args.stream_analyzer),
            stream_state,
            stop,
        ),
        daemon=True,
    )
    stream_thread.start()

    metrics_state = SystemMetricsState(args.stream_interface)
    metrics_thread = threading.Thread(
        target=metrics_state.run, args=(stop,), daemon=True
    )
    metrics_thread.start()
    global_attack = GlobalAttackState()
    page2_attack = Page2AttackManager(
        project, global_attack, stream_state, args.stream_interface
    )
    brute_force = BruteForceManager(
        project, state, stream_state, metrics_state, global_attack,
        args.stream_interface,
    )

    server = ThreadingHTTPServer(
        (args.http_bind, args.http_port),
        make_handler(
            args.dashboard, state, stream_state, brute_force, event_state,
            metrics_state, global_attack, page2_attack,
        ),
    )
    print(f"UDP telemetry: {args.udp_bind}:{args.udp_port} peer={args.peer}")
    print(f"UDP security events: {args.event_bind}:{args.event_port} peer={args.peer}")
    print(f"Dashboard: http://{args.http_bind}:{args.http_port}/")
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        print("\nStopped by user")
    finally:
        server.server_close()
        stop.set()
        receiver.close()
        event_receiver.close()
        receiver_thread.join(timeout=1.0)
        event_thread.join(timeout=1.0)
        stream_thread.join(timeout=3.0)
        page2_attack.stop()
        brute_force.stop()
        metrics_thread.join(timeout=3.0)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
