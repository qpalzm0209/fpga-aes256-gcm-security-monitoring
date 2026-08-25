const clamp = (value, minimum, maximum) => Math.min(maximum, Math.max(minimum, value));
export const ANOMALY_THRESHOLD = 0.35;
export const ANOMALY_MODEL_NAME = "Candidate Anomaly Detector";
export const RX_WINDOW_FRAMES = 30;

export function nextAttackLevel(current, { active, intensity }) {
  const target = active ? clamp(intensity / 60, 0, 1) : 0;
  const response = active ? 0.3 : 0.14;
  return clamp(current + (target - current) * response, 0, 1);
}

export function applyAttackTelemetry(normal, { level, mode, tick }) {
  if (level < 0.001) return normal;
  const replay = mode === "replay";
  const wave = Math.sin(tick * 0.78);
  const spike = Math.abs(Math.sin(tick * 1.47));

  return {
    fps: clamp(normal.fps - level * (replay ? 4.8 : 7.2) + wave * level * 0.16, 18, 30),
    throughput: clamp(normal.throughput - level * (replay ? 18 : 28) + wave * level * 1.1, 70, 130),
    drop: clamp(normal.drop + level * (replay ? 24 : 38) + spike * level * 1.8, 0, 50),
    jitter: clamp(normal.jitter + level * (replay ? 6.4 : 8.6) + spike * level * 2.2, 0, 18),
    power: clamp(normal.power + level * (replay ? 0.34 : 0.58) + wave * level * 0.04, 7, 11),
  };
}

export function nextAnomalyScore(current, level) {
  const target = 0.08 + Math.pow(level, 1.08) * 0.86;
  const response = target > current ? 0.34 : 0.13;
  return clamp(current + (target - current) * response, 0.08, 0.94);
}

export function createAttackWindow({ active, mode, frameRate, attemptedFrames = RX_WINDOW_FRAMES }) {
  const selectedFrames = active && frameRate > 0
    ? Math.max(1, Math.round(attemptedFrames * frameRate / 100))
    : 0;
  const tamper = mode === "tamper";
  const gcmRejectRate = tamper ? selectedFrames : 0;
  const replayRejectRate = tamper ? 0 : selectedFrames;
  const validFrameRate = tamper ? attemptedFrames - gcmRejectRate : attemptedFrames;
  const frameDropRatio = tamper && attemptedFrames ? (gcmRejectRate / attemptedFrames) * 100 : 0;

  return {
    attemptedFrames,
    selectedFrames,
    modifiedFrames: tamper ? selectedFrames : 0,
    modifiedPackets: tamper ? selectedFrames : 0,
    replayedFrames: tamper ? 0 : selectedFrames,
    replayInjections: tamper ? 0 : selectedFrames,
    forwardedPackets: attemptedFrames,
    gcmRejectRate,
    replayRejectRate,
    validFrameRate,
    frameDropRatio,
  };
}

export function createAiReading(score, { active, stableTicks }) {
  const status = score >= ANOMALY_THRESHOLD ? "ANOMALY DETECTED" : "NORMAL";

  return {
    model: ANOMALY_MODEL_NAME,
    score,
    threshold: ANOMALY_THRESHOLD,
    status,
    description: "Deviation from learned normal RX behavior",
  };
}
