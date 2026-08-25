from __future__ import annotations

import ctypes
import json
import os
import sys
import time
import traceback
from collections import deque
from pathlib import Path

import cv2
import numpy as np


HERE = Path(__file__).resolve().parent
WINDOW = "ZYBO RX HDMI LIVE - USB3.0 Capture - Q/ESC: close  S: save"


def record_unhandled(exception_type, exception, trace) -> None:
    (HERE / "last_error.txt").write_text(
        "".join(traceback.format_exception(exception_type, exception, trace)),
        encoding="utf-8",
    )


sys.excepthook = record_unhandled
(HERE / "last_error.txt").unlink(missing_ok=True)


def fail(message: str) -> None:
    (HERE / "last_error.txt").write_text(message + "\n", encoding="utf-8")
    ctypes.windll.user32.MessageBoxW(0, message, "ZYBO capture error", 0x10)
    raise SystemExit(message)


def write_metrics(path: Path, values: dict) -> None:
    temporary = path.with_suffix(".tmp")
    temporary.write_text(
        json.dumps(values, ensure_ascii=False, indent=2) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def write_image(path: Path, image: np.ndarray) -> None:
    temporary = path.with_name(path.stem + ".tmp" + path.suffix)
    if not cv2.imwrite(str(temporary), image):
        raise RuntimeError(f"이미지 저장 실패: {temporary}")
    for attempt in range(20):
        try:
            temporary.replace(path)
            return
        except PermissionError:
            if attempt == 19:
                raise
            time.sleep(0.01)


mjpg = cv2.VideoWriter_fourcc(*"MJPG")
capture = cv2.VideoCapture(
    0,
    cv2.CAP_DSHOW,
    [
        cv2.CAP_PROP_FOURCC,
        mjpg,
        cv2.CAP_PROP_FRAME_WIDTH,
        1280,
        cv2.CAP_PROP_FRAME_HEIGHT,
        720,
        cv2.CAP_PROP_FPS,
        60,
    ],
)
if not capture.isOpened():
    fail("USB3. 0 capture 장치를 열 수 없습니다.")

ok, frame = capture.read()
if not ok or frame is None:
    capture.release()
    fail("캡처보드에서 첫 프레임을 읽지 못했습니다.")

height, width = frame.shape[:2]
if (width, height) != (1280, 720):
    capture.release()
    fail(f"예상 해상도 1280x720, 실제 {width}x{height}")

fourcc_number = int(capture.get(cv2.CAP_PROP_FOURCC))
fourcc = "".join(chr((fourcc_number >> (8 * i)) & 0xFF) for i in range(4))

cv2.namedWindow(WINDOW, cv2.WINDOW_NORMAL)
cv2.resizeWindow(WINDOW, 1280, 720)
cv2.moveWindow(WINDOW, 20, 20)
cv2.setWindowProperty(WINDOW, cv2.WND_PROP_TOPMOST, 1)

start = time.perf_counter()
frame_times: deque[float] = deque()
change_times: deque[float] = deque()
previous_probe = None
last_change = start
last_persist = 0.0
frame_count = 0
read_failures = 0
pixel_delta = 0.0
moving_percent = 0.0
max_pixel_delta = 0.0

try:
    while True:
        ok, frame = capture.read()
        now = time.perf_counter()
        if not ok or frame is None:
            read_failures += 1
            if read_failures >= 30:
                fail("연속 프레임 읽기 실패가 발생했습니다.")
            continue

        frame_count += 1
        frame_times.append(now)
        while frame_times and frame_times[0] < now - 2.0:
            frame_times.popleft()
        capture_fps = (
            (len(frame_times) - 1) / (frame_times[-1] - frame_times[0])
            if len(frame_times) > 1
            else 0.0
        )

        probe = cv2.resize(
            cv2.cvtColor(frame, cv2.COLOR_BGR2GRAY),
            (320, 180),
            interpolation=cv2.INTER_AREA,
        )
        probe = cv2.GaussianBlur(probe, (5, 5), 0)
        if previous_probe is not None:
            difference = cv2.absdiff(probe, previous_probe)
            pixel_delta = float(difference.mean())
            moving_percent = float(np.count_nonzero(difference >= 8)) * 100.0 / difference.size
            if pixel_delta >= 0.35 or moving_percent >= 0.05:
                last_change = now
                change_times.append(now)
                max_pixel_delta = max(max_pixel_delta, pixel_delta)
        previous_probe = probe
        while change_times and change_times[0] < now - 2.0:
            change_times.popleft()
        change_rate = len(change_times) / 2.0
        seconds_since_change = now - last_change
        live = seconds_since_change < 1.0

        display = frame.copy()
        color = (0, 255, 0) if live else (0, 0, 255)
        state = "PIXELS CHANGING" if live else "PIXELS STATIC"
        cv2.rectangle(display, (0, 0), (width, 112), (0, 0, 0), -1)
        cv2.putText(
            display,
            f"HDMI CARRIER  {width}x{height} MJPG  {capture_fps:5.1f} fps  {state}",
            (22, 34),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.78,
            color,
            2,
            cv2.LINE_AA,
        )
        cv2.putText(
            display,
            f"pixel delta={pixel_delta:5.2f}  moving pixels={moving_percent:5.2f}%  change events={change_rate:5.1f}/s",
            (22, 69),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.68,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )
        cv2.putText(
            display,
            f"frames={frame_count}  read failures={read_failures}  no-change={seconds_since_change:4.2f}s",
            (22, 101),
            cv2.FONT_HERSHEY_SIMPLEX,
            0.65,
            (255, 255, 255),
            2,
            cv2.LINE_AA,
        )

        if now - last_persist >= 0.5:
            write_metrics(
                HERE / "live_metrics.json",
                {
                    "device": "USB3. 0 capture",
                    "resolution": f"{width}x{height}",
                    "fourcc": fourcc,
                    "capture_fps_2s": round(capture_fps, 3),
                    "frames": frame_count,
                    "read_failures": read_failures,
                    "pixel_delta_mean": round(pixel_delta, 4),
                    "moving_pixels_percent": round(moving_percent, 4),
                    "change_events_per_second_2s": round(change_rate, 3),
                    "max_pixel_delta_mean": round(max_pixel_delta, 4),
                    "seconds_since_pixel_change": round(seconds_since_change, 4),
                    "pixel_stream_live": live,
                    "automatic_image_saves": False,
                    "preview_window": WINDOW,
                    "preview_visible": True,
                    "pid": os.getpid(),
                },
            )
            last_persist = now

        cv2.imshow(WINDOW, display)
        key = cv2.waitKey(1) & 0xFF
        if key in (27, ord("q"), ord("Q")):
            break
        if key in (ord("s"), ord("S")):
            stamp = time.strftime("%Y%m%d_%H%M%S")
            write_image(HERE / f"manual_{stamp}.png", frame)
finally:
    capture.release()
    cv2.destroyAllWindows()
