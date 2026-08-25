# Zybo RX telemetry receiver

This directory contains only the lightweight UDP receiver used to verify the
Zybo RX 5 Hz telemetry stream. It does not provide an API, Dashboard backend,
database, service, or video processing.

## Run on Jetson

```sh
cd /home/jetson/projects/zybo-security-demo/telemetry
python3 receiver.py --duration 30 \
  --save-samples samples/normal-30s.json
```

The receiver binds to `10.10.15.1:47000` by default. Use `--bind 0.0.0.0` only
when listening on every Jetson interface is intentionally required. A duration
of `0` runs until Ctrl+C.

It validates the required JSON contract, protocol version, increasing sequence
number, and increasing RX monotonic timestamp. The final console summary reports
packet count, frequency, interval range, sequence gaps, metric means, and summed
delta counters.

`frame_drop_ratio` is the rolling valid-frame-ID loss divided by accepted frames
plus that loss. Replay rejections are not included. Rate and jitter fields use
an approximately one-second rolling window. Loss, queue, stale, and status
deltas cover the previous non-overlapping 200 ms telemetry interval.

`queue_overrun_delta` and `stale_drop_delta` expose the existing RX queue
counters. The current RX queue blocks for a free slot and has no increment site
for either counter, so both remain actual zero-by-design until that queue policy
changes.
