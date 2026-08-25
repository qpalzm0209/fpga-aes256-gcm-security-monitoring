export const WINDOW_SECONDS = 30;

function clamp(value, minimum, maximum) {
  return Math.min(maximum, Math.max(minimum, value));
}

export function createInitialTelemetry() {
  const fps = Array.from({ length: WINDOW_SECONDS }, (_, index) => {
    const dip = index === 10 ? 0.09 : index === 11 ? 0.035 : index === 24 ? 0.05 : 0;
    return 29.94 + Math.sin(index * 0.55) * 0.018 - dip;
  });

  return {
    fps,
    throughput: fps.map((value, index) => 125.3 + (value - 29.94) * 5 + Math.sin(index * 0.46) * 0.46 + Math.cos(index * 0.18) * 0.16),
    drop: Array.from({ length: WINDOW_SECONDS }, (_, index) => index === 17 ? 0.012 : index === 18 ? 0.003 : index === 7 || index === 25 ? 0.001 : 0),
    jitter: Array.from({ length: WINDOW_SECONDS }, (_, index) => 1.16 + Math.abs(Math.sin(index * 0.63)) * 0.22 + (index === 13 ? 0.8 : index === 26 ? 0.42 : 0)),
    power: Array.from({ length: WINDOW_SECONDS }, (_, index) => 8.66 + Math.sin(index * 0.24) * 0.09 + Math.cos(index * 0.08) * 0.03),
  };
}

export function createTelemetrySample(tick, encrypted, random = Math.random) {
  const fpsPhase = tick % 47;
  const fpsDip = fpsPhase === 0 ? 0.12 : fpsPhase === 1 ? 0.045 : 0;
  const fps = clamp(29.94 - fpsDip + (random() - 0.5) * 0.024, 29.8, 30.0);
  const throughputBase = encrypted ? 125.3 : 124.8;
  const throughput = throughputBase + (fps - 29.94) * 5 + Math.sin(tick * 0.34) * 0.45 + (random() - 0.5) * 0.25;

  const dropPhase = tick % 31;
  let drop = 0;
  if (dropPhase === 0) drop = 0.012 + random() * 0.004;
  else if (dropPhase === 1) drop = 0.003 + random() * 0.002;
  else if (random() < 0.03) drop = 0.001 + random() * 0.001;

  const jitterPhase = tick % 37;
  const jitterBurst = jitterPhase === 0 ? 1.15 : jitterPhase === 1 ? 0.42 : 0;
  const jitter = Math.max(0, 1.16 + (random() - 0.5) * 0.36 + jitterBurst);
  const powerBase = encrypted ? 8.66 : 8.02;
  const power = powerBase + Math.sin(tick * 0.24) * 0.09 + Math.cos(tick * 0.08) * 0.03;

  return { fps, throughput, drop, jitter, power };
}
