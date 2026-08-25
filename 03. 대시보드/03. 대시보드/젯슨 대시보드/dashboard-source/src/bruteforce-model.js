export const SEED_BIT_OPTIONS = [20, 21, 22, 23, 24, 25, 26];

export const FULL_GCM_VERIFICATION = "AES-256-GCM_FULL_TAG";

export const COMPUTE_ENGINES = [
  { id: "cpu-multi", kind: "cpu", label: "CPU MULTI", short: "CPU MULTI", rate: 0, source: "JETSON LIVE", parallelism: "HOST THREAD POOL", searchWidth: null },
  { id: "cuda-low", kind: "cuda", label: "CUDA LOW", short: "CUDA LOW", rate: 0, source: "JETSON LIVE", parallelism: "LOW", searchWidth: 4_096 },
  { id: "cuda-mid", kind: "cuda", label: "CUDA MID", short: "CUDA MID", rate: 0, source: "JETSON LIVE", parallelism: "MEDIUM", searchWidth: 16_384 },
  { id: "cuda-max", kind: "cuda", label: "CUDA MAX", short: "CUDA MAX", rate: 0, source: "JETSON LIVE", parallelism: "MAX", searchWidth: 65_536 },
];

export function buildSearchRequest(bits, engine) {
  return {
    keySourceBits: bits,
    algorithm: FULL_GCM_VERIFICATION,
    engineId: engine.id,
    backend: engine.kind,
    parallelism: engine.parallelism,
    searchWidth: engine.searchWidth,
  };
}

export function comparisonRuns(runs, showCpuReference = false) {
  return showCpuReference ? runs : runs.filter((run) => run.engineId !== "cpu-multi");
}

export function seedSearchSpace(bits) {
  return 2 ** bits;
}

export function formatCandidateCount(value) {
  if (value >= 1_000_000_000) return `${(value / 1_000_000_000).toFixed(2)} B`;
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)} M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(1)} K`;
  return Math.round(value).toLocaleString();
}

export function formatRate(value) {
  if (value >= 1_000_000) return `${(value / 1_000_000).toFixed(2)} M`;
  if (value >= 1_000) return `${(value / 1_000).toFixed(0)} K`;
  return Math.round(value).toString();
}

export function formatDuration(seconds) {
  if (!Number.isFinite(seconds)) return "--:--";
  if (seconds >= 3600) return `${(seconds / 3600).toFixed(1)} h`;
  const minutes = Math.floor(seconds / 60);
  const remainder = seconds - minutes * 60;
  return `${String(minutes).padStart(2, "0")}:${remainder.toFixed(1).padStart(4, "0")}`;
}

export function worstCaseSearchSeconds(bits, rate) {
  return rate > 0 ? seedSearchSpace(bits) / rate : Infinity;
}

export function formatFullScanEstimate(seconds) {
  if (!Number.isFinite(seconds)) return "--";
  if (seconds < 1) return `≈ ${seconds.toFixed(2)} s`;
  if (seconds < 60) return `≈ ${seconds.toFixed(1)} s`;
  if (seconds < 3600) return `≈ ${(seconds / 60).toFixed(1)} min`;
  return `≈ ${(seconds / 3600).toFixed(1)} h`;
}

export function fullScanCategory(seconds) {
  if (!Number.isFinite(seconds)) return "AWAITING RATE";
  if (seconds < 1) return "VERY FAST";
  if (seconds < 10) return "FAST";
  if (seconds < 30) return "DEMO RANGE";
  if (seconds < 60) return "LONGER RUN";
  return "EXTENDED RUN";
}

export function comparisonYAxisMax(spaces) {
  const largest = Math.max(...spaces, 1);
  const quantum = largest <= 2_000_000 ? 500_000
    : largest <= 5_000_000 ? 1_000_000
      : largest <= 10_000_000 ? 2_000_000
        : largest <= 20_000_000 ? 5_000_000
          : 10_000_000;
  return Math.ceil(largest / quantum) * quantum;
}

export function comparisonXAxisMax(elapsedValues) {
  const largest = Math.max(10, ...elapsedValues, 0);
  if (largest <= 60) return Math.ceil(largest / 10) * 10;
  if (largest <= 300) return Math.ceil(largest / 30) * 30;
  return Math.ceil(largest / 60) * 60;
}

export function seedHex(seed, bits) {
  return `0x${Math.max(0, seed).toString(16).toUpperCase().padStart(Math.ceil(bits / 4), "0")}`;
}

export function searchResultLabel({ bits, engineId, elapsed }) {
  const engine = engineId === "cpu-multi" ? "CPU" : engineId.toUpperCase().replaceAll("-", " ");
  const time = elapsed < 10 ? `${elapsed.toFixed(1)}s` : elapsed < 60 ? `${Math.round(elapsed)}s` : `${(elapsed / 60).toFixed(elapsed >= 600 ? 0 : 1)}m`;
  return `${bits}-BIT · ${engine} / ${time}`;
}

export function prepareProgress(status, prepareStep = 0) {
  if (status === "retrying") {
    return prepareStep >= 4
      ? { step: 4, detail: "Session ACK verified · retrying the matching packet capture" }
      : { step: 0, detail: "Retrying the same weak-session request ID · waiting for the TX/RX ACK" };
  }
  const observed = {
    queued: { step: 0, detail: "Weak-session preparation queued on Jetson" },
    "checking-live-stream": { step: 0, detail: "Checking the live AES-GCM ciphertext stream" },
    "requesting-session": { step: 0, detail: "Weak-session request sent · waiting for the TX/RX ACK" },
    "capturing-matching-packet": { step: 4, detail: "Session ACK verified · capturing a matching authenticated packet" },
    ready: { step: 4, detail: "Session ACK and matching authenticated packet verified" },
  };
  return observed[status] || {
    step: prepareStep >= 4 ? 4 : 0,
    detail: "Waiting for an observed session-preparation state",
  };
}
