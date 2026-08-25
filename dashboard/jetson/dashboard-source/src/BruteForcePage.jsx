import { useEffect, useMemo, useState } from "react";
import { CheckCircle, Play, ShieldCheck, Stop, Trash } from "@phosphor-icons/react";
import {
  COMPUTE_ENGINES,
  SEED_BIT_OPTIONS,
  comparisonRuns,
  comparisonXAxisMax,
  comparisonYAxisMax,
  formatCandidateCount,
  formatDuration,
  formatFullScanEstimate,
  formatRate,
  prepareProgress,
  searchResultLabel,
  seedHex,
  seedSearchSpace,
} from "./bruteforce-model.js";
import "./bruteforce.css";

const PREPARE_STEPS = ["TX WEAK SEED", "AES-256 DERIVE", "X25519 / HKDF", "RX COMMIT", "PACKET CAPTURE"];
const EMPTY_VLM_STATE = { phase: "idle", result: null, error: "" };

function axisLabel(value) {
  if (value >= 1_000_000) return `${Math.round(value / 1_000_000)}M`;
  if (value >= 1_000) return `${Math.round(value / 1_000)}K`;
  return String(Math.round(value));
}

function timeAxisLabel(seconds) {
  if (seconds < 60) return `${Math.round(seconds)}s`;
  return `${(seconds / 60).toFixed(seconds >= 600 ? 0 : 1)}m`;
}

function SourceEntropySubtitle({ bits }) {
  return <p className="bf-source-subtitle">
    <span>WEAK KEY SOURCE · {bits}-bit seed → SHA-256 → AES-256</span>
    <small>AES-256 unchanged · effective search space = 2^{bits}</small>
  </p>;
}

function ChoiceGroup({ step, title, guide, children }) {
  return <section className="bf-choice-group"><header><b>{step}</b><span>{title}</span>{guide && <em>{guide}</em>}</header>{children}</section>;
}

function SessionReadiness({ phase, prepareStep, prepareStatus, ready, bits, preparedBits }) {
  const preparing = phase === "weak-preparing";
  const failed = phase === "error";
  const status = preparing ? "PREPARING" : failed ? "FAILED" : ready ? "READY" : preparedBits === null ? "SECURE BASELINE" : "UPDATE REQUIRED";
  const progress = prepareProgress(prepareStatus, prepareStep);
  const currentStep = Math.max(0, Math.min(PREPARE_STEPS.length - 1, progress.step));
  return <section className="bf-session-readiness">
    <header><span>SESSION STATUS</span><strong className={ready ? "ready" : failed ? "failed" : ""}>{status}</strong></header>
    <div className="bf-prepare-pipeline" aria-live="polite">
      {PREPARE_STEPS.map((step, index) => {
        const state = ready || (preparing && index < currentStep) ? "done"
          : preparing && index === currentStep ? "active" : "";
        return <span className={state} key={step}><CheckCircle weight="fill" /><small>{step}</small></span>;
      })}
    </div>
    <p>{preparing ? progress.detail : ready ? `${bits}-bit weak session ready / session ACK and matching authenticated packet verified` : preparedBits !== null ? `Prepared ${preparedBits}-bit session does not match the selected ${bits}-bit profile.` : "Prepare creates the controlled weak session and captures one authenticated stream packet."}</p>
  </section>;
}

function DemoControl({ bits, setBits, engineId, setEngineId, phase, prepareStep, prepareStatus, preparedBits, profileRates, pending, blocked, onPrepare, onStart, onStop, onReset, onReturnSecure }) {
  const busy = blocked || pending || ["weak-preparing", "searching", "returning-secure"].includes(phase);
  const ready = preparedBits === bits && !["secure", "weak-preparing", "returning-secure"].includes(phase);
  const canPrepare = !busy && preparedBits !== bits;
  const canStart = !busy && ready && ["weak-ready", "key-found"].includes(phase);
  return <article className="bf-control panel">
    <header className="bf-section-header"><div><span>A / DEMO CONTROL</span><h2>Choose Difficulty and Attacker Compute</h2></div><strong>ONE CONTROL POINT</strong></header>
    <div className="bf-control-body">
      <ChoiceGroup step="01" title="SELECT WEAK-SEED ENTROPY" guide="BITS">
        <div className="bf-bit-choices">{SEED_BIT_OPTIONS.map((value) => <button key={value} className={bits === value ? "active" : ""} disabled={busy} onClick={() => setBits(value)}><strong>{value}</strong></button>)}</div>
      </ChoiceGroup>
      <ChoiceGroup step="02" title="SELECT COMPUTE PROFILE">
        <div className="bf-engine-choices">{COMPUTE_ENGINES.map((engine) => <button key={engine.id} className={`${engine.id === engineId ? "active" : ""} engine-${engine.id}`} disabled={busy} onClick={() => setEngineId(engine.id)}><strong>{engine.short}</strong><small>{profileRates[engine.id] ? `${formatRate(profileRates[engine.id])} keys/s` : "BENCHMARK REQUIRED"}</small></button>)}</div>
      </ChoiceGroup>
      <SessionReadiness phase={phase} prepareStep={prepareStep} prepareStatus={prepareStatus} ready={ready} bits={bits} preparedBits={preparedBits} />
    </div>
    <div className="bf-control-actions">
      <button className="prepare" disabled={!canPrepare} onClick={onPrepare}><span>03</span>{phase === "weak-preparing" ? "PREPARING..." : "PREPARE WEAK SESSION"}</button>
      <button className="start" disabled={!canStart} onClick={onStart}><Play weight="fill" /><span>04</span>START SEARCH</button>
      <button disabled={phase !== "searching"} onClick={onStop}><Stop weight="fill" />STOP</button>
      <button disabled={phase === "searching"} onClick={onReset}><Trash />RESET COMPARISON</button>
      <button disabled={busy || preparedBits === null} onClick={onReturnSecure}><ShieldCheck />RETURN SECURE</button>
    </div>
  </article>;
}

function currentRunSummary(run, bits, engine) {
  const matchesSelection = run?.bits === bits && run?.engineId === engine.id;
  if (matchesSelection) return {
    bits: run.bits,
    space: run.space,
    engine: run.engineLabel,
    rate: run.rate,
    source: "JETSON LIVE",
    elapsed: run.elapsed,
    tested: run.tested,
    status: run.status,
  };
  return { bits, space: seedSearchSpace(bits), engine: engine.label, rate: 0, source: "JETSON LIVE", elapsed: 0, tested: 0, status: "configured" };
}

function downsample(samples, limit = 720) {
  if (samples.length <= limit) return samples;
  const step = Math.ceil(samples.length / limit);
  const reduced = samples.filter((_, index) => index % step === 0);
  if (reduced.at(-1) !== samples.at(-1)) reduced.push(samples.at(-1));
  return reduced;
}

function ComparisonGraph({ runs, bits, currentRunId, showCpuReference, onToggleCpuReference }) {
  const width = 1500;
  const height = 360;
  const left = 82;
  const right = 28;
  const top = 24;
  const bottom = 44;
  const plotWidth = width - left - right;
  const plotHeight = height - top - bottom;
  const plottedRuns = comparisonRuns(runs, showCpuReference);
  const cpuRuns = runs.filter((run) => run.engineId === "cpu-multi");
  const cpuReference = cpuRuns.at(-1);
  const yMax = comparisonYAxisMax([...plottedRuns.map((run) => run.space), seedSearchSpace(bits)]);
  const xMax = comparisonXAxisMax(plottedRuns.map((run) => run.elapsed));
  const yTicks = Array.from({ length: 5 }, (_, index) => yMax * index / 4);
  const xTicks = Array.from({ length: 6 }, (_, index) => xMax * index / 5);
  const selectedMaxY = top + plotHeight * (1 - seedSearchSpace(bits) / yMax);

  const pointsFor = (run) => downsample(run.samples).map((sample) => {
    const x = left + Math.min(1, sample.t / xMax) * plotWidth;
    const y = top + plotHeight * (1 - Math.min(1, sample.tested / yMax));
    return [x, y];
  });

  return <div className="bf-comparison-chart" role="img" aria-label="Elapsed time versus cumulative candidates tested for all search runs">
    <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="xMidYMid meet" aria-hidden="true">
      <g className="bf-chart-grid">
        {yTicks.map((value) => {
          const y = top + plotHeight * (1 - value / yMax);
          return <g key={value}><line x1={left} y1={y} x2={width - right} y2={y} /><text x={left - 14} y={y + 4} textAnchor="end">{axisLabel(value)}</text></g>;
        })}
        {xTicks.map((value) => {
          const x = left + plotWidth * value / xMax;
          return <g key={value}><line x1={x} y1={top} x2={x} y2={height - bottom} /><text x={x} y={height - 15} textAnchor="middle">{timeAxisLabel(value)}</text></g>;
        })}
      </g>
      <text className="bf-axis-title y" x="18" y={top + plotHeight / 2} transform={`rotate(-90 18 ${top + plotHeight / 2})`} textAnchor="middle">CUMULATIVE CANDIDATES TESTED [KEYS]</text>
      <text className="bf-axis-title x" x={left + plotWidth / 2} y={height - 1} textAnchor="middle">ELAPSED TIME</text>
      <line className="bf-current-maximum" x1={left} y1={selectedMaxY} x2={width - right} y2={selectedMaxY} />
      <text className="bf-current-maximum-label" x={width - right - 7} y={Math.max(top + 12, selectedMaxY - 7)} textAnchor="end">TOTAL CANDIDATES / 2^{bits} = {formatCandidateCount(seedSearchSpace(bits))}</text>
      {plottedRuns.map((run) => {
        const points = pointsFor(run);
        const path = points.map(([x, y], index) => `${index ? "L" : "M"} ${x.toFixed(1)} ${y.toFixed(1)}`).join(" ");
        const last = points.at(-1) || [left, height - bottom];
        const current = run.id === currentRunId;
        return <g className={`bf-run engine-${run.engineId} ${current ? "current" : "history"} status-${run.status}`} key={run.id}>
          <path d={path} />
          <circle cx={last[0]} cy={last[1]} r={current ? 5 : 3.5} />
          {run.status === "found" && <><circle className="found-ring" cx={last[0]} cy={last[1]} r="10" /><text className="found-label" x={Math.min(last[0] + 14, width - 240)} y={Math.max(top + 14, last[1] - 10)}>{searchResultLabel(run)}</text></>}
        </g>;
      })}
      {plottedRuns.length === 0 && <text className="bf-empty-chart" x={left + plotWidth / 2} y={top + plotHeight / 2} textAnchor="middle">{cpuRuns.length ? "CPU REFERENCE IS HIDDEN / ENABLE SHOW CPU REFERENCE TO PLOT IT" : "RUN A SEARCH TO BUILD THE COMPARISON LIVE"}</text>}
    </svg>
    <div className="bf-comparison-footer">
      <div className="bf-run-legend">
        {plottedRuns.length ? plottedRuns.map((run) => <span className={`engine-${run.engineId} ${run.id === currentRunId ? "current" : ""}`} key={run.id}><i />R{runs.indexOf(run) + 1} · {run.engineLabel}{run.id === currentRunId ? " · CURRENT" : ""}</span>) : <span className="empty">RUN A SEARCH TO BUILD THE LIVE GRAPH</span>}
      </div>
      <div className="bf-cpu-reference-summary">
        <span>CPU REFERENCE{cpuRuns.length ? ` / ${cpuRuns.length} RUN${cpuRuns.length > 1 ? "S" : ""} ${showCpuReference ? "SHOWN" : "HIDDEN"}` : ""}</span>
        <strong>{cpuReference ? `LATEST R${runs.indexOf(cpuReference) + 1} / ${cpuReference.bits} BIT / ${formatRate(cpuReference.rate)} keys/s / ${formatDuration(cpuReference.elapsed)} / ${cpuReference.status.toUpperCase()}` : "NOT RUN"}</strong>
        <button type="button" className={showCpuReference ? "active" : ""} disabled={!cpuRuns.length} onClick={onToggleCpuReference}>{showCpuReference ? "HIDE CPU REFERENCE" : "SHOW CPU REFERENCE"}</button>
      </div>
    </div>
  </div>;
}

function SystemSnapshot({ metrics, frozen }) {
  return <div className="bf-system-snapshot">
    <header><span>SYSTEM SNAPSHOT</span><strong>{frozen ? "LAST RUN" : "LIVE"}</strong></header>
    <span><b>GPU UTIL</b><strong>{metrics?.gpu_util_percent == null ? "--" : `${metrics.gpu_util_percent.toFixed(1)} %`}</strong></span>
    <span><b>CPU UTIL</b><strong>{metrics?.cpu_util_percent == null ? "--" : `${metrics.cpu_util_percent.toFixed(1)} %`}</strong></span>
    <span><b>MEMORY</b><strong>{metrics?.memory_used_mb == null ? "--" : `${(metrics.memory_used_mb / 1024).toFixed(1)} / ${(metrics.memory_total_mb / 1024).toFixed(1)} GB`}</strong></span>
    <span><b>BOARD POWER</b><strong>{metrics?.board_power_w == null ? "--" : `${metrics.board_power_w.toFixed(2)} W`}</strong></span>
    <span><b>GPU TEMP</b><strong>{metrics?.gpu_temp_c == null ? "--" : `${metrics.gpu_temp_c.toFixed(1)} °C`}</strong></span>
    <span><b>CPU TEMP</b><strong>{metrics?.cpu_temp_c == null ? "--" : `${metrics.cpu_temp_c.toFixed(1)} °C`}</strong></span>
  </div>;
}

function ComparisonPanel({ runs, bits, engine, metrics, currentRunId, showCpuReference, onToggleCpuReference }) {
  const currentRun = runs.find((run) => run.id === currentRunId) || runs.at(-1);
  const summary = currentRunSummary(currentRun, bits, engine);
  const fullScanSeconds = summary.rate > 0 ? summary.space / summary.rate : Infinity;
  const snapshotMetrics = currentRun?.metrics || metrics;
  const snapshotFrozen = Boolean(currentRun && currentRun.status !== "searching");
  return <article className="bf-comparison panel">
    <header className="bf-section-header"><div><span>B / LIVE SEARCH</span><h2>{bits} BIT · {engine.label}</h2></div><div className="bf-data-badges"><b>FULL 128-BIT GCM TAG</b><b>JETSON LIVE</b></div></header>
    <div className="bf-current-run-strip">
      <div><span>TOTAL CANDIDATES</span><strong>{formatCandidateCount(summary.space)}</strong></div>
      <div title={summary.source}><span>SEARCH SPEED</span><strong>{formatRate(summary.rate)}<small> keys/s</small></strong></div>
      <div className="bf-full-scan"><span>ESTIMATED FULL SCAN TIME</span><strong>{formatFullScanEstimate(fullScanSeconds)}</strong></div>
      <div><span>ELAPSED</span><strong>{formatDuration(summary.elapsed)}</strong></div>
      <div><span>CANDIDATES TESTED</span><strong>{formatCandidateCount(summary.tested)}</strong></div>
      <div><span>STATUS</span><b className={`bf-run-status status-${summary.status}`}>{summary.status.toUpperCase()}</b></div>
    </div>
    <ComparisonGraph runs={runs} bits={bits} currentRunId={currentRunId} showCpuReference={showCpuReference} onToggleCpuReference={onToggleCpuReference} />
    <SystemSnapshot metrics={snapshotMetrics} frozen={snapshotFrozen} />
  </article>;
}

function SearchFlow() {
  return <footer className="bf-search-flow panel">SEED → SHA-256 → AES-256 KEY → FULL GCM TAG VERIFY</footer>;
}

function LastAttackResult({ run, bits, engine, source }) {
  const found = run?.status === "found";
  const searching = run?.status === "searching";
  const status = searching ? "SEARCHING" : found ? "KEY RECOVERED ✓" : run ? run.status.toUpperCase() : "AWAITING SEARCH";
  const shownBits = run?.bits ?? bits;
  const shownEngine = run?.engineLabel ?? engine.label;
  const shownSource = run?.inputSource || source || "NO LIVE RECORD";
  return <section className={`bf-last-result ${found ? "found" : ""}`} aria-live="polite">
    <header><span>{searching ? "CURRENT SEARCH" : "LAST ATTACK RESULT"}</span><strong>{status}</strong></header>
    <div>
      <span><b>SEED ENTROPY</b><strong>{shownBits} bit</strong></span>
      <span><b>COMPUTE</b><strong>{shownEngine}</strong></span>
      <span><b>SEARCH SPEED</b><strong>{run ? formatRate(run.rate) : "--"}<small> keys/s</small></strong></span>
      <span><b>ELAPSED</b><strong>{run ? formatDuration(run.elapsed) : "--"}</strong></span>
      <span><b>CANDIDATES TESTED</b><strong>{run ? formatCandidateCount(run.tested) : "--"}</strong></span>
      <span><b>RECOVERED SEED</b><strong>{found ? seedHex(run.foundSeed, run.bits) : "--"}</strong></span>
      <span><b>GCM TAG</b><strong>{found && run.tagVerified ? "VERIFIED ✓" : searching ? "PENDING" : "--"}</strong></span>
      <span className="source"><b>SOURCE</b><strong>{shownSource === "CAPTURED FROM LIVE STREAM" ? "LIVE CAPTURE" : shownSource}</strong></span>
    </div>
  </section>;
}

function displayVlmModel(model) {
  const value = String(model || "");
  if (/cosmos-reason2-2b/i.test(value)) return "NVIDIA COSMOS-REASON2 2B · Q4";
  return value.split(/[\\/]/).at(-1)?.replace(/\.gguf$/i, "") || "LOCAL VLM";
}

function VlmAnalysisPanel({ state, recovered }) {
  const complete = state.phase === "complete";
  const analyzing = state.phase === "analyzing";
  const result = state.result;
  return <aside className={`bf-vlm-analysis phase-${state.phase}`} aria-live="polite" aria-busy={analyzing}>
    <header>
      <span>NVIDIA ON-DEVICE VLM</span>
      <strong>복구 이미지 분석</strong>
      <b>{analyzing ? "VLM 추론 중" : complete ? "VLM 생성 완료" : "VLM 실패"}</b>
    </header>
    {analyzing && <div className="bf-vlm-analyzing">
      <div className="bf-vlm-scan" aria-hidden="true"><i /></div>
      <strong>NVIDIA COSMOS VLM 추론 중<span>...</span></strong>
      <p>IMAGE → VISION-LANGUAGE MODEL → TEXT · LOCAL JETSON</p>
    </div>}
    {complete && <div className="bf-vlm-result">
      <div className="bf-vlm-pipeline" aria-label="Actual on-device VLM inference path">
        <span>RECOVERED FRAME</span><b>→</b><strong>NVIDIA COSMOS VLM</strong><b>→</b><span>GENERATED OUTPUT</span>
      </div>
      <dl className="bf-vlm-meta">
        <div><dt>AI 모델</dt><dd title={result.model}>{displayVlmModel(result.model)}</dd></div>
        <div><dt>VLM 추론 시간</dt><dd>{Number(result.latency_sec).toFixed(2)} s</dd></div>
        <div><dt>입력 이미지</dt><dd>FRAME {result.source_frame ?? recovered.frame_id}</dd></div>
        <div><dt>실행 방식</dt><dd>{result.execution || "LOCAL / JETSON"} · NO CLOUD</dd></div>
      </dl>
      <section><span>장면</span><p>{result.analysis?.scene || "분석 결과 없음"}</p></section>
      <section><span>사람</span><p>{result.analysis?.people || "식별된 사람 없음"}</p></section>
      <section><span>주요 객체</span><p>{result.analysis?.objects || "식별된 객체 없음"}</p></section>
      <section className="sensitive"><span>보이는 식별 정보</span><p>{result.analysis?.potentially_sensitive_information || "보이는 식별 정보 없음"}</p></section>
    </div>}
    {state.phase === "failed" && <div className="bf-vlm-failed">
      <strong>로컬 VLM 분석 실패</strong>
      <p>{state.error || "모델을 사용할 수 없습니다"}</p>
      <small>Weak-Key 이미지 복구 결과는 유효합니다.</small>
    </div>}
  </aside>;
}

export function BruteForcePage({ onSearchingChange }) {
  const [bits, setBits] = useState(24);
  const [engineId, setEngineId] = useState("cuda-max");
  const [showCpuReference, setShowCpuReference] = useState(false);
  const [backend, setBackend] = useState(null);
  const [requestError, setRequestError] = useState("");
  const [pending, setPending] = useState(false);
  const [runs, setRuns] = useState([]);
  const [currentRunId, setCurrentRunId] = useState(null);
  const [dismissedRecoveryId, setDismissedRecoveryId] = useState(null);
  const [vlmState, setVlmState] = useState(() => ({ ...EMPTY_VLM_STATE }));

  useEffect(() => {
    let active = true;
    let timer;
    async function poll() {
      try {
        const response = await fetch("/api/bruteforce/status", { cache: "no-store" });
        if (!response.ok) throw new Error(`status HTTP ${response.status}`);
        const value = await response.json();
        if (active) setBackend(value);
      } catch (error) {
        if (active) setRequestError(String(error));
      } finally {
        if (active) timer = window.setTimeout(poll, 200);
      }
    }
    poll();
    return () => { active = false; window.clearTimeout(timer); };
  }, []);

  const backendPhase = backend?.phase || "secure";
  const phase = backendPhase === "found" ? "key-found"
    : ["stopped", "not_found"].includes(backendPhase) ? "weak-ready" : backendPhase;
  const preparedBits = backend?.session?.profile === "weak" ? backend.session.seed_bits : null;
  const backendPrepareStep = Number.isInteger(backend?.prepare_step) ? backend.prepare_step : 0;
  const prepareStatus = backend?.prepare_status || "idle";
  const prepareStep = phase === "weak-preparing" ? backendPrepareStep
      : backend?.input_source === "CAPTURED FROM LIVE STREAM" ? PREPARE_STEPS.length - 1 : -1;
  const profileRates = Object.fromEntries(Object.entries(backend?.benchmarks?.profiles || {}).map(([id, value]) => [id, Number(value.keys_per_s || value)]));
  const baseEngine = useMemo(() => COMPUTE_ENGINES.find((item) => item.id === engineId) || COMPUTE_ENGINES[0], [engineId]);
  const engine = { ...baseEngine, rate: Number(profileRates[engineId] || backend?.search?.search_rate || 0), source: "JETSON LIVE" };
  useEffect(() => {
    onSearchingChange?.(phase === "searching");
    return () => onSearchingChange?.(false);
  }, [phase, onSearchingChange]);

  useEffect(() => {
    if (!backend?.search || !backend.run_id) return;
    const id = `run-${backend.run_id}`;
    const status = backend.search.phase === "found" ? "found"
      : backend.search.phase === "searching" ? "searching"
        : backend.search.phase === "not_found" ? "not-found" : "stopped";
    const value = {
      id, bits: Number(backend.search.bits), engineId: backend.search.profile,
      engineLabel: String(backend.search.profile).toUpperCase().replaceAll("-", " "),
      rate: Number(backend.search.search_rate || 0), space: Number(backend.search.key_space),
      status, tested: Number(backend.search.candidates_tested || 0),
      elapsed: Number(backend.search.elapsed_s || 0),
      throughput: Number(backend.search.search_rate || 0),
      currentSeed: Number(backend.search.candidates_tested || 0),
      foundSeed: backend.search.found_seed,
      tagVerified: Boolean(backend.search.tag_verified),
      inputSource: backend.input_source,
      metrics: backend.metrics ? { ...backend.metrics } : null,
      samples: backend.history || [],
    };
    setRuns((current) => current.some((run) => run.id === id)
      ? current.map((run) => {
        if (run.id !== id) return run;
        if (run.status !== "searching" && status !== "searching") return run;
        return value;
      })
      : [...current, value]);
    setCurrentRunId(id);
  }, [backend]);

  useEffect(() => {
    if (backend?.recovered_frame?.run_id) setDismissedRecoveryId(null);
    setVlmState({ ...EMPTY_VLM_STATE });
  }, [backend?.recovered_frame?.run_id]);

  function resetVlmState() {
    setVlmState({ ...EMPTY_VLM_STATE });
  }

  async function action(name, payload = {}) {
    setPending(true);
    setRequestError("");
    try {
      const response = await fetch(`/api/bruteforce/${name}`, {
        method: "POST", headers: { "Content-Type": "application/json" },
        body: JSON.stringify(payload),
      });
      const value = await response.json();
      if (!response.ok) throw new Error(value.error || `HTTP ${response.status}`);
      setBackend(value);
      return value;
    } catch (error) {
      setRequestError(String(error));
      return null;
    } finally {
      setPending(false);
    }
  }

  async function prepareWeakSession() {
    resetVlmState();
    await action("prepare", { bits });
  }
  function startSearch() {
    resetVlmState();
    action("start", { bits, profile: engineId });
  }
  function stopSearch() { action("stop"); }
  async function resetComparison() {
    resetVlmState();
    if (await action("reset")) { setRuns([]); setCurrentRunId(null); }
  }
  async function returnSecure() {
    resetVlmState();
    if (await action("secure")) setCurrentRunId(null);
  }
  function selectEngine(nextEngineId) {
    setEngineId(nextEngineId);
    setShowCpuReference(nextEngineId === "cpu-multi");
  }

  const effectivePhase = pending && phase === "secure" ? "weak-preparing" : phase;
  const sourceLabel = requestError || backend?.last_error || backend?.input_source || "NO LIVE RECORD";
  const blocked = backend?.attack_state?.status !== "idle" && backend?.attack_state?.owner !== "page3";
  const currentRun = runs.find((run) => run.id === currentRunId) || runs.at(-1);
  const recovered = backend?.recovered_frame;
  const showRecovered = recovered?.run_id && recovered.run_id !== dismissedRecoveryId;
  const imageUrl = recovered ? `${recovered.url}?run=${recovered.run_id}&sha=${recovered.sha256}` : "";
  const canAnalyze = phase === "key-found"
    && Boolean(backend?.search?.tag_verified)
    && backend?.recovery?.phase === "ready"
    && Boolean(recovered?.run_id && recovered?.sha256 && imageUrl)
    && vlmState.phase !== "analyzing"
    && vlmState.phase !== "complete";
  const vlmPanelOpen = vlmState.phase !== "idle";

  async function analyzeRecoveredFrame() {
    if (!canAnalyze) return;
    setVlmState({ phase: "analyzing", result: null, error: "" });
    try {
      const response = await fetch("/api/vlm/analyze", {
        method: "POST",
        headers: { "Content-Type": "application/json" },
        body: JSON.stringify({ run_id: recovered.run_id, sha256: recovered.sha256 }),
      });
      const value = await response.json();
      if (!response.ok || !value.ok) throw new Error(value.error || `HTTP ${response.status}`);
      setVlmState({ phase: "complete", result: value, error: "" });
    } catch (error) {
      setVlmState({ phase: "failed", result: null, error: String(error).replace(/^Error:\s*/, "") });
    }
  }

  return <section className={`bf-dashboard phase-${effectivePhase}`}>
    <header className="bf-page-header panel">
      <div className="bf-page-identity"><span>PAGE 03 / CONTROLLED WEAK-KEY DEMONSTRATION</span><h1>Weak-Key Brute-Force</h1><SourceEntropySubtitle bits={bits} /></div>
      <LastAttackResult run={currentRun} bits={bits} engine={engine} source={sourceLabel} />
    </header>
    <DemoControl bits={bits} setBits={setBits} engineId={engineId} setEngineId={selectEngine} phase={effectivePhase} prepareStep={prepareStep} prepareStatus={prepareStatus} preparedBits={preparedBits} profileRates={profileRates} pending={pending} blocked={blocked} onPrepare={prepareWeakSession} onStart={startSearch} onStop={stopSearch} onReset={resetComparison} onReturnSecure={returnSecure} />
    <ComparisonPanel runs={runs} bits={bits} engine={engine} metrics={backend?.metrics} currentRunId={currentRunId || runs.at(-1)?.id || null} showCpuReference={showCpuReference} onToggleCpuReference={() => setShowCpuReference((shown) => !shown)} />
    <SearchFlow />
    {showRecovered && <section className="bf-recovered-overlay" role="dialog" aria-modal="true" aria-label="Recovered live video frame">
      <article className={`bf-recovered-dialog panel ${vlmPanelOpen ? "with-vlm" : ""}`}>
        <header>
          <div><span>DECRYPTED FROM LIVE WEAK SESSION</span><strong>Recovered Zybo Video Frame</strong></div>
          <button type="button" onClick={() => setDismissedRecoveryId(recovered.run_id)}>CLOSE</button>
        </header>
        <div className="bf-recovered-content">
          <div className="bf-recovered-media">
            <img src={imageUrl} alt="Decrypted Zybo video frame recovered with the found weak seed" />
            <footer>
              <div>
                <span>{recovered.width}×{recovered.height}</span>
                <span>FRAME {recovered.frame_id}</span>
                <span>SEED {seedHex(recovered.seed, bits)}</span>
                <span>{recovered.filename}</span>
              </div>
              <button className="bf-vlm-button" type="button" disabled={!canAnalyze} onClick={analyzeRecoveredFrame}>
                {vlmState.phase === "analyzing" ? "VLM 추론 중..." : vlmState.phase === "complete" ? "VLM 분석 완료" : vlmState.phase === "failed" ? "VLM 다시 분석" : "NVIDIA VLM으로 분석"}
              </button>
            </footer>
          </div>
          {vlmPanelOpen && <VlmAnalysisPanel state={vlmState} recovered={recovered} />}
        </div>
      </article>
    </section>}
  </section>;
}
