#!/usr/bin/env python3
"""Minimal standalone Jetson image-to-text test UI.

This app is intentionally independent from the AES-GCM/weak-key demo.  It
accepts one user-selected image and calls a local llama.cpp VLM server only
when /api/analyze is explicitly requested.
"""

from __future__ import annotations

import argparse
import base64
import cgi
import json
import os
import re
import subprocess
import threading
import time
import urllib.error
import urllib.request
from collections import deque
from http import HTTPStatus
from http.server import SimpleHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any


ROOT = Path(__file__).resolve().parent
WEB_ROOT = ROOT / "web"
RUNTIME = ROOT / "runtime"
DATA = ROOT / "data"
MAX_IMAGE_BYTES = 12 * 1024 * 1024
MODEL_API = os.environ.get("VLM_MODEL_API", "http://127.0.0.1:4190").rstrip("/")
MODEL_NAME = os.environ.get("VLM_MODEL_NAME", "NVIDIA Cosmos-Reason2-2B Q4_K_M")
MODEL_LOG = Path(os.environ.get("VLM_MODEL_LOG", str(RUNTIME / "model-server.log")))
INFERENCE_LOCK = threading.Lock()

PROMPT = """/no_think
제공된 이미지만 분석하십시오.
보이는 장면을 객관적으로 설명하고, 사람과 주요 객체를 식별하십시오.
이미지에서 직접 확인되지 않는 내용은 추측하지 마십시오.
추론 과정이나 chain-of-thought를 출력하지 마십시오.
모든 JSON 값은 자연스럽고 간결한 한국어로 작성하십시오.
scene은 짧은 한 문장, 나머지 세 목록은 짧은 사실 표현으로 작성하십시오.
장면 설명을 목록에 반복하지 말고 네 필드를 모두 채우십시오.
people에 사람이 보이지 않으면 정확히 "사람이 보이지 않음"만 쓰십시오.
objects에는 중요한 객체의 이름만 쓰고 장면 문장을 반복하지 마십시오.
objects 목록에서 같은 객체를 여러 번 반복하지 마십시오.
potentially_sensitive_information에는 실제로 보이는 얼굴, 이름표, 문서, 화면 내용, 주소, 표식 같은 식별 정보만 쓰십시오.
조명, 천장, 벽 같은 일반적인 실내 요소는 이 필드에 쓰지 마십시오.
식별 정보가 보이지 않으면 potentially_sensitive_information에 정확히 "보이는 식별 정보 없음"만 쓰십시오.
키 이름은 바꾸지 말고 다음 JSON 객체만 반환하십시오:
{
  "scene": "보이는 장면을 설명하는 짧은 한국어 문장",
  "people": ["보이는 사람 또는 사람이 보이지 않음"],
  "objects": ["눈에 띄는 주요 객체"],
  "potentially_sensitive_information": ["실제로 보이는 식별 정보 또는 보이는 식별 정보 없음"]
}
"""

MIME_BY_SIGNATURE = (
    (b"\xff\xd8\xff", "image/jpeg", ".jpg"),
    (b"\x89PNG\r\n\x1a\n", "image/png", ".png"),
    (b"RIFF", "image/webp", ".webp"),
)


def send_json(handler: SimpleHTTPRequestHandler, value: Any, status: int = 200) -> None:
    payload = json.dumps(value, ensure_ascii=False, separators=(",", ":")).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json; charset=utf-8")
    handler.send_header("Cache-Control", "no-store")
    handler.send_header("X-Content-Type-Options", "nosniff")
    handler.send_header("Content-Length", str(len(payload)))
    handler.end_headers()
    handler.wfile.write(payload)


def local_json_request(path: str, payload: dict[str, Any] | None = None,
                       timeout: float = 5.0) -> dict[str, Any]:
    body = None if payload is None else json.dumps(payload).encode("utf-8")
    request = urllib.request.Request(
        MODEL_API + path,
        data=body,
        headers={"Content-Type": "application/json"} if body is not None else {},
        method="POST" if body is not None else "GET",
    )
    with urllib.request.urlopen(request, timeout=timeout) as response:
        raw = response.read()
    try:
        value = json.loads(raw)
    except json.JSONDecodeError as error:
        excerpt = raw[:6000].decode("utf-8", errors="replace")
        raise RuntimeError(
            f"model API returned invalid JSON ({error}); raw response: {excerpt}"
        ) from error
    if not isinstance(value, dict):
        raise RuntimeError(f"model API returned {type(value).__name__}, not an object")
    return value


def model_status() -> dict[str, Any]:
    started = time.perf_counter()
    try:
        health = local_json_request("/health", timeout=2.0)
        models = local_json_request("/v1/models", timeout=2.0)
        items = models.get("data") if isinstance(models, dict) else None
        loaded = items[0].get("id") if isinstance(items, list) and items else MODEL_NAME
        return {
            "loaded": health.get("status") == "ok",
            "health": health,
            "model": loaded,
            "endpoint": "LOCAL / JETSON",
            "probe_ms": round((time.perf_counter() - started) * 1000, 1),
        }
    except Exception as error:
        return {
            "loaded": False,
            "model": MODEL_NAME,
            "endpoint": "LOCAL / JETSON",
            "error": f"{type(error).__name__}: {error}",
        }


def tail_model_log(limit: int = 12000) -> str:
    try:
        with MODEL_LOG.open("rb") as stream:
            stream.seek(0, os.SEEK_END)
            size = stream.tell()
            stream.seek(max(0, size - limit))
            return stream.read().decode("utf-8", errors="replace")
    except OSError as error:
        return f"model log unavailable: {error}"


class TegraStatsSampler:
    SAMPLE = re.compile(
        r"RAM\s+(?P<ram>\d+)/(?P<ram_total>\d+)MB.*?"
        r"GR3D_FREQ\s+(?P<gpu>\d+)%.*?VDD_IN\s+(?P<power>\d+)mW"
    )

    def __init__(self) -> None:
        self.process: subprocess.Popen[str] | None = None
        self.samples: deque[dict[str, float]] = deque(maxlen=2000)
        self.thread: threading.Thread | None = None

    def start(self) -> None:
        self.process = subprocess.Popen(
            ["/usr/bin/tegrastats", "--interval", "250"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            bufsize=1,
        )
        self.thread = threading.Thread(target=self._read, daemon=True)
        self.thread.start()

    def _read(self) -> None:
        assert self.process is not None and self.process.stdout is not None
        for line in self.process.stdout:
            match = self.SAMPLE.search(line)
            if match:
                self.samples.append({
                    "ram_used_mb": float(match.group("ram")),
                    "ram_total_mb": float(match.group("ram_total")),
                    "gpu_util_percent": float(match.group("gpu")),
                    "board_power_w": float(match.group("power")) / 1000.0,
                })

    def stop(self) -> dict[str, Any]:
        if self.process is not None and self.process.poll() is None:
            self.process.terminate()
            try:
                self.process.wait(timeout=2.0)
            except subprocess.TimeoutExpired:
                self.process.kill()
                self.process.wait(timeout=1.0)
        if self.thread is not None:
            self.thread.join(timeout=1.0)
        values = list(self.samples)
        if not values:
            return {"samples": 0, "error": "tegrastats produced no parseable samples"}

        def summarize(name: str) -> dict[str, float]:
            column = [sample[name] for sample in values]
            return {
                "before": round(column[0], 2),
                "mean": round(sum(column) / len(column), 2),
                "peak": round(max(column), 2),
            }

        return {
            "samples": len(values),
            "ram_used_mb": summarize("ram_used_mb"),
            "ram_total_mb": values[-1]["ram_total_mb"],
            "gpu_util_percent": summarize("gpu_util_percent"),
            "board_power_w": summarize("board_power_w"),
        }


def detect_image(data: bytes) -> tuple[str, str]:
    for signature, mime, suffix in MIME_BY_SIGNATURE:
        if data.startswith(signature):
            if mime == "image/webp" and data[8:12] != b"WEBP":
                break
            return mime, suffix
    raise ValueError("Only valid JPEG, PNG, or WebP images are accepted")


def strip_reasoning(text: str) -> str:
    value = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL | re.IGNORECASE)
    value = value.strip()
    if value.startswith("```"):
        value = re.sub(r"^```(?:json)?\s*", "", value, flags=re.IGNORECASE)
        value = re.sub(r"\s*```$", "", value)
    return value.strip()


def parse_analysis(raw: str) -> tuple[dict[str, str], str | None]:
    cleaned = strip_reasoning(raw)
    start = cleaned.find("{")
    if start < 0:
        raise ValueError("model output did not contain a JSON object")
    value, _ = json.JSONDecoder().raw_decode(cleaned[start:])
    if not isinstance(value, dict):
        raise ValueError("model output JSON was not an object")
    aliases = {
        "scene": "scene",
        "people": "people",
        "objects": "objects",
        "potentially_sensitive_information": "potentially_sensitive_information",
        "potentially sensitive information": "potentially_sensitive_information",
        "sensitive_information": "potentially_sensitive_information",
    }
    result = {
        "scene": "분석 결과 없음",
        "people": "식별된 사람 없음",
        "objects": "식별된 객체 없음",
        "potentially_sensitive_information": "보이는 식별 정보 없음",
    }
    for key, item in value.items():
        normalized = aliases.get(str(key).strip().lower())
        if normalized:
            if isinstance(item, list):
                entries = []
                seen = set()
                for entry in item:
                    text = re.sub(r"\s+", " ", str(entry)).strip()
                    dedupe_key = text.casefold()
                    if text and dedupe_key not in seen:
                        entries.append(text)
                        seen.add(dedupe_key)
                result[normalized] = ", ".join(entries) or "확인된 내용 없음"
            else:
                result[normalized] = str(item).strip() or "확인된 내용 없음"
    return result, None


def run_inference(image: bytes, mime: str) -> dict[str, Any]:
    status = model_status()
    if not status.get("loaded"):
        raise RuntimeError(f"local VLM is not loaded: {status.get('error', status)}")
    encoded = base64.b64encode(image).decode("ascii")
    model_id = str(status.get("model") or MODEL_NAME)
    payload = {
        "model": model_id,
        "messages": [{
            "role": "user",
            "content": [
                {"type": "text", "text": PROMPT},
                {"type": "image_url", "image_url": {"url": f"data:{mime};base64,{encoded}"}},
            ],
        }],
        "temperature": 0.0,
        "top_p": 0.9,
        "max_tokens": 256,
        "stream": False,
        "reasoning_effort": "none",
        "chat_template_kwargs": {"enable_thinking": False},
        "json_schema": {
            "type": "object",
            "properties": {
                "scene": {"type": "string", "minLength": 1, "maxLength": 140},
                "people": {
                    "type": "array", "minItems": 1, "maxItems": 2,
                    "items": {"type": "string", "minLength": 1, "maxLength": 48}
                },
                "objects": {
                    "type": "array", "minItems": 1, "maxItems": 4,
                    "items": {"type": "string", "minLength": 1, "maxLength": 56}
                },
                "potentially_sensitive_information": {
                    "type": "array", "minItems": 1, "maxItems": 2,
                    "items": {"type": "string", "minLength": 1, "maxLength": 80}
                },
            },
            "required": [
                "scene", "people", "objects", "potentially_sensitive_information"
            ],
            "additionalProperties": False,
        },
    }
    started = time.perf_counter()
    response = local_json_request("/v1/chat/completions", payload, timeout=240.0)
    request_sec = time.perf_counter() - started
    choices = response.get("choices") if isinstance(response, dict) else None
    if not isinstance(choices, list) or not choices:
        raise RuntimeError(f"local VLM returned no choices: {response}")
    raw = str((choices[0].get("message") or {}).get("content") or "").strip()
    if not raw:
        raise RuntimeError(f"local VLM returned an empty message: {response}")
    parsed, parse_warning = parse_analysis(raw)
    timings = response.get("timings") if isinstance(response.get("timings"), dict) else {}
    usage = response.get("usage") if isinstance(response.get("usage"), dict) else {}
    return {
        "analysis": parsed,
        "raw_output": raw,
        "parse_warning": parse_warning,
        "model": model_id,
        "execution": "LOCAL / JETSON",
        "model_request_sec": round(request_sec, 3),
        "timings": timings,
        "usage": usage,
    }


class Handler(SimpleHTTPRequestHandler):
    server_version = "JetsonLocalVLMTest/1.0"

    def __init__(self, *args: Any, **kwargs: Any) -> None:
        super().__init__(*args, directory=str(WEB_ROOT), **kwargs)

    def log_message(self, fmt: str, *args: Any) -> None:
        print(f"{self.address_string()} - {fmt % args}", flush=True)

    def do_GET(self) -> None:
        path = self.path.partition("?")[0]
        if path == "/api/status":
            send_json(self, {
                "app": "ready",
                "model_server": model_status(),
                "inference_active": INFERENCE_LOCK.locked(),
                "execution": "LOCAL / JETSON",
            })
            return
        super().do_GET()

    def do_POST(self) -> None:
        if self.path.partition("?")[0] != "/api/analyze":
            send_json(self, {"error": "not found"}, HTTPStatus.NOT_FOUND)
            return
        if not INFERENCE_LOCK.acquire(blocking=False):
            send_json(self, {"error": "an inference is already running"}, HTTPStatus.CONFLICT)
            return
        total_started = time.perf_counter()
        sampler = TegraStatsSampler()
        try:
            content_type = self.headers.get("Content-Type", "")
            if not content_type.startswith("multipart/form-data"):
                raise ValueError("multipart/form-data image upload required")
            length = int(self.headers.get("Content-Length", "0"))
            if length <= 0 or length > MAX_IMAGE_BYTES + 1024 * 1024:
                raise ValueError("image upload is empty or exceeds 12 MB")
            form = cgi.FieldStorage(
                fp=self.rfile,
                headers=self.headers,
                environ={"REQUEST_METHOD": "POST", "CONTENT_TYPE": content_type,
                         "CONTENT_LENGTH": str(length)},
            )
            item = form["image"] if "image" in form else None
            if item is None or not getattr(item, "file", None):
                raise ValueError("image field is required")
            image = item.file.read(MAX_IMAGE_BYTES + 1)
            if len(image) > MAX_IMAGE_BYTES:
                raise ValueError("image exceeds 12 MB")
            mime, suffix = detect_image(image)
            DATA.mkdir(parents=True, exist_ok=True)
            (DATA / f"last-upload{suffix}").write_bytes(image)
            sampler.start()
            time.sleep(0.3)
            result = run_inference(image, mime)
            result["metrics"] = sampler.stop()
            result["total_response_sec"] = round(time.perf_counter() - total_started, 3)
            result["image"] = {"mime": mime, "bytes": len(image)}
            send_json(self, result)
        except (ValueError, urllib.error.HTTPError) as error:
            metrics = sampler.stop()
            detail = error.read().decode("utf-8", errors="replace") if isinstance(
                error, urllib.error.HTTPError
            ) else str(error)
            send_json(self, {
                "error": f"{type(error).__name__}: {detail}",
                "metrics": metrics,
                "model_log_tail": tail_model_log(),
            }, HTTPStatus.BAD_REQUEST if isinstance(error, ValueError) else HTTPStatus.BAD_GATEWAY)
        except Exception as error:
            metrics = sampler.stop()
            send_json(self, {
                "error": f"{type(error).__name__}: {error}",
                "metrics": metrics,
                "model_log_tail": tail_model_log(),
            }, HTTPStatus.BAD_GATEWAY)
        finally:
            INFERENCE_LOCK.release()


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--host", default=os.environ.get("VLM_TEST_HOST", "0.0.0.0"))
    parser.add_argument("--port", type=int, default=int(os.environ.get("VLM_TEST_PORT", "4188")))
    args = parser.parse_args()
    RUNTIME.mkdir(parents=True, exist_ok=True)
    DATA.mkdir(parents=True, exist_ok=True)
    server = ThreadingHTTPServer((args.host, args.port), Handler)
    print(f"Local VLM test UI: http://{args.host}:{args.port}/", flush=True)
    print(f"Model API: {MODEL_API}", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


if __name__ == "__main__":
    main()
