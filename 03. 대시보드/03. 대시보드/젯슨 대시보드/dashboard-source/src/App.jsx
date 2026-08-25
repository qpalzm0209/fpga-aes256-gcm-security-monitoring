import { useEffect, useRef, useState } from "react";
import "@fontsource-variable/inter";
import "@fontsource/jetbrains-mono/400.css";
import { ArrowCounterClockwise, ArrowDown, ArrowRight, CheckCircle, Play, ShieldCheck, Stop } from "@phosphor-icons/react";
import { WINDOW_SECONDS } from "./telemetry-model.js";
import { BruteForcePage } from "./BruteForcePage.jsx";
import "./attack.css";

const PAGE01_METRICS = [
  { key: "throughput", label: "LINK THROUGHPUT", unit: "Mbps", decimals: 1, domain: [350, 550], scale: "350-550 Mbps" },
  { key: "packetRate", label: "PACKET RATE", unit: "kpps", decimals: 1, domain: [0, 50], scale: "0-50 kpps", tone: "rate" },
  { key: "packetJitter", label: "PACKET TIMING JITTER", unit: "µs", decimals: 2, domain: [0, 1], valueScale: 1000, adaptiveDomain: true, showYAxis: true, tone: "jitter" },
  { key: "dropDelta", label: "NIC DROP Δ", unit: "/ 30 SEC", decimals: 0, domain: [0, 10], scale: "0-10 / 30 sec", shape: "step", tone: "drop" },
  { key: "power", label: "BOARD POWER", unit: "W", decimals: 2, domain: [0, 15], scale: "0-15 W", tone: "power" },
];

function clamp(value, min, max) {
  return Math.min(max, Math.max(min, value));
}

function niceAxisCeiling(value, minimum = 1) {
  const target = Math.max(minimum, Number(value) * 1.15 || 0);
  const magnitude = 10 ** Math.floor(Math.log10(target));
  const normalized = target / magnitude;
  const step = normalized <= 1 ? 1 : normalized <= 2 ? 2 : normalized <= 5 ? 5 : 10;
  return step * magnitude;
}

function formatAxisValue(value) {
  if (value >= 10) return value.toFixed(0);
  if (value >= 1) return value.toFixed(1).replace(/\.0$/, "");
  return value.toFixed(2).replace(/0+$/, "").replace(/\.$/, "");
}

function Status({ tone = "ok", children }) {
  return <span className={`status status-${tone}`}><CheckCircle weight="fill" />{children}</span>;
}

function Packet({ encrypted, delay }) {
  return (
    <span className={`packet packet-${encrypted ? "encrypted" : "plain"}`} style={{ "--packet-delay": `${delay}s` }} aria-hidden="true">
      {encrypted ? <><i>AAD</i><b>CIPHERTEXT</b><em>TAG</em></> : <strong>YUYV</strong>}
    </span>
  );
}

function FlowLink({ encrypted, offset = 0 }) {
  return (
    <div className="flow-link">
      <div className="flow-track" />
      <Packet encrypted={encrypted} delay={offset} />
      <ArrowRight className="flow-arrow" weight="thin" aria-hidden="true" />
    </div>
  );
}

function DeviceNode({ name, role, image, jetson = false }) {
  return (
    <div className={`device-node device-${role.toLowerCase()} ${jetson ? "device-jetson" : ""}`}>
      <img src={image} alt={`${name} board`} />
      <div>
        <span>{role}</span><strong>{name}</strong>
        {jetson && <small className="observer-live"><i />INLINE OBSERVER</small>}
      </div>
    </div>
  );
}

function PacketSummary({ encrypted, frameId, packetId }) {
  const latestFrameId = Number.isInteger(frameId) ? String(frameId) : "—";
  const latestPacketId = Number.isInteger(packetId) ? String(packetId) : "—";
  return (
    <div
      className={`packet-summary ${encrypted ? "packet-summary-encrypted" : "packet-summary-plain"}`}
      aria-label="Packet format reference"
      data-metadata-source="latest-observed-packet"
      data-metadata-sample-ms="200"
    >
      <strong>PACKET FORMAT REFERENCE</strong>
      <div className="packet-summary-fields">
        {encrypted ? <>
          <span className="field-aad"><b>AAD</b><small>16 B</small></span>
          <span className="field-cipher"><b>CIPHERTEXT</b><small>1440 B</small></span>
          <span className="field-tag"><b>TAG</b><small>16 B</small></span>
        </> : <span className="field-plain"><b>YUYV PAYLOAD</b><small>1440 B</small></span>}
      </div>
      <dl className="packet-summary-meta">
        <div><dt>FRAME ID</dt><dd>{latestFrameId}</dd></div>
        <div><dt>PACKET ID</dt><dd>{latestPacketId}</dd></div>
        <div><dt>SIZE</dt><dd>{encrypted ? "1472 B" : "1440 B"}</dd></div>
        <div><dt>LAYOUT</dt><dd className={encrypted ? "valid" : "raw"}>{encrypted ? "AES-GCM" : "RAW YUYV"}</dd></div>
      </dl>
    </div>
  );
}

function Histogram({ bins, encrypted }) {
  const peak = Math.max(0, ...bins);
  return (
    <div className={`histogram histogram-${encrypted ? "encrypted" : "plain"}`} role="img" aria-label="Current stream byte distribution">
      <div className="bars">
        {bins.map((value, index) => <i key={index} style={{ "--bar-height": `${peak ? (value / peak) * 100 : 0}%` }} />)}
      </div>
      <div className="histogram-axis"><span>00</span><b>BYTE DISTRIBUTION</b><span>FF</span></div>
    </div>
  );
}

function TrendChart({ label, values, unit, decimals, domain, scale, shape = "line", tone = "default", markerIndex = null, showPeak = false, displayValue = null, secondaryText = null, labelHint = null, valueScale = 1, adaptiveDomain = false, showYAxis = false }) {
  const width = 1600;
  const height = 60;
  const displayedValues = values.map((value) => value * valueScale).filter(Number.isFinite);
  const floor = adaptiveDomain ? 0 : domain[0];
  const ceiling = adaptiveDomain ? niceAxisCeiling(Math.max(0, ...displayedValues)) : domain[1];
  const range = ceiling - floor || 1;
  const plottedValues = displayedValues.length ? displayedValues : [floor];
  const coordinates = plottedValues.map((value, index) => {
    const x = plottedValues.length === 1 ? width - 4 : 4 + (index / (plottedValues.length - 1)) * (width - 8);
    const normalized = clamp((value - floor) / range, 0, 1);
    const y = 6 + (height - 12) * (1 - normalized);
    return [x, y];
  });
  const path = coordinates.reduce((result, [x, y], index) => {
    if (index === 0) return `M ${x.toFixed(1)} ${y.toFixed(1)}`;
    return shape === "step" ? `${result} H ${x.toFixed(1)} V ${y.toFixed(1)}` : `${result} L ${x.toFixed(1)} ${y.toFixed(1)}`;
  }, "");
  const current = displayedValues.at(-1);
  const peak = displayedValues.length ? Math.max(...displayedValues) : null;
  const [currentX, currentY] = coordinates.at(-1);
  const currentTop = clamp((currentY / height) * 100, 16, 84);
  const markerX = Number.isInteger(markerIndex) && markerIndex >= 0 && markerIndex < coordinates.length
    ? coordinates[markerIndex][0]
    : null;
  const areaPath = `${path} L ${coordinates.at(-1)[0].toFixed(1)} ${(height - 6).toFixed(1)} L ${coordinates[0][0].toFixed(1)} ${(height - 6).toFixed(1)} Z`;
  const shownScale = adaptiveDomain ? `0–${formatAxisValue(ceiling)} ${unit} · AUTO` : scale;

  return (
    <article className={`trend-row trend-${tone} ${displayValue ? "trend-compact-value" : ""} ${showYAxis ? "trend-with-y-axis" : ""}`}>
      <div className="trend-label">
        <span>{label}{(showPeak || labelHint) && <em>{labelHint ?? "CURRENT"}</em>}</span>
        <div className="trend-value-stack">
          <strong>{displayValue ?? (current == null ? "—" : current.toFixed(decimals))}<small>{unit}</small></strong>
          {showPeak && <span className="trend-peak">30S PEAK {peak == null ? "—" : peak.toFixed(decimals)}{unit}</span>}
          {secondaryText && <span className="trend-peak">{secondaryText}</span>}
        </div>
      </div>
      <div className="trend-chart" role="img" aria-label={`${label}, ${adaptiveDomain ? "adaptive" : "fixed"} ${floor} to ${ceiling} ${unit}, rolling ${WINDOW_SECONDS} second trend`}>
        <svg viewBox={`0 0 ${width} ${height}`} preserveAspectRatio="xMidYMid meet" aria-hidden="true">
          <g className="trend-grid"><line x1="0" y1="15" x2="1600" y2="15" /><line x1="0" y1="45" x2="1600" y2="45" /></g>
          {markerX !== null && <g className="attack-marker">
            <line x1={markerX} y1="2" x2={markerX} y2={height - 2} />
            <text x={Math.min(markerX + 10, width - 170)} y="13">ATTACK START</text>
          </g>}
          <path className="trend-area" d={areaPath} />
          <path d={path} />
          <circle className="trend-current" cx={currentX} cy={currentY} r="4" />
        </svg>
        {showYAxis && <div className="trend-y-axis" aria-hidden="true">
          <span>{formatAxisValue(ceiling)}</span>
          <span>{formatAxisValue(ceiling / 2)}</span>
          <span>0</span>
        </div>}
        <span className="trend-scale">{shownScale}</span>
        <span className="trend-end-value" style={{ "--value-y": `${currentTop}%` }}>
          {current == null ? "—" : current.toFixed(decimals)}<small>{unit}</small>
        </span>
        <div className="trend-time"><span>-{WINDOW_SECONDS}s</span><span>NOW</span></div>
      </div>
    </article>
  );
}

function PacketAnatomy({ tampered = false }) {
  return <div className={`story-packet ${tampered ? "tampered" : ""}`}><span>AAD</span><b>{tampered ? "CIPHERTEXT*" : "CIPHERTEXT"}</b><em>TAG</em></div>;
}

function formatRuntime(seconds) {
  const minutes = Math.floor(seconds / 60);
  return `${String(minutes).padStart(2, "0")}:${String(seconds % 60).padStart(2, "0")}`;
}

function AttackFlowStrip({ attack }) {
  const tamper = attack.mode === "tamper";
  return (
    <article className={`attack-network panel ${attack.active ? "active" : ""}`}>
      <div className="attack-network-body">
        <div className="network-node"><img src="/assets/zybo-z7-20-official.png" alt="Zybo TX board" /><div><span>ENCRYPTED SOURCE</span><strong>ZYBO TX</strong></div></div>
        <FlowLink encrypted offset={0} />
        <div className={`network-node jetson-relay ${attack.active ? "incident" : ""}`}><img src="/assets/jetson-orin-nano-official.jpg" alt="Jetson Orin Nano relay" /><div><span>INLINE MIDDLE NODE</span><strong>JETSON RELAY</strong><small>{attack.active ? (tamper ? "TAMPERING" : "REPLAYING") : "FORWARDING UNCHANGED"}</small></div></div>
        <FlowLink encrypted offset={-3.5} />
        <div className="network-node"><img src="/assets/zybo-z7-20-official.png" alt="Zybo RX board" /><div><span>VERIFY / DISPLAY</span><strong>ZYBO RX</strong></div></div>
        <div className="attacker-boundary">ATTACKER-SIDE OBSERVATION / CONTROL ONLY</div>
      </div>
    </article>
  );
}

function PacketOperation({ mode, active, sourceFrameId }) {
  const tamper = mode === "tamper";
  const verdict = tamper
    ? ["EXPECTED RECEIVER EFFECT", "CIPHERTEXT CHANGED", "TAG UNCHANGED", "AUTHENTICATION SHOULD FAIL"]
    : ["EXPECTED RECEIVER EFFECT", "CIPHERTEXT / TAG UNCHANGED", "GCM CAN PASS", "FRESHNESS SHOULD REJECT"];
  return (
    <div className={`packet-operation ${active ? "active" : ""}`}>
      <span className="operation-kicker">WHAT JETSON IS DOING</span>
      {tamper ? <div className="tamper-sequence" aria-label="TX packet enters Jetson, ciphertext is modified, and the packet is forwarded to RX">
        <div className="tamper-endpoint source">
          <div className="tamper-endpoint-heading"><strong className="tamper-role-badge tx">TX</strong><small>ORIGINAL ENCRYPTED PACKET</small></div>
          <PacketAnatomy />
        </div>
        <div className="tamper-motion-line">
          <span className="tamper-jetson-label">JETSON · CIPHERTEXT MODIFICATION</span>
          <ArrowDown weight="thin" />
          <div className={`tamper-travel-token ${active ? "running" : "preview"}`}><PacketAnatomy /></div>
          <div className="bit-flip-marker"><b>BIT 0 → 1</b><small>CIPHERTEXT ONLY</small></div>
          <div className="tag-unchanged-marker">TAG UNCHANGED</div>
        </div>
        <div className="tamper-endpoint destination">
          <div className="tamper-endpoint-heading"><strong className="tamper-role-badge rx">RX</strong><small>MODIFIED PACKET FORWARDED</small></div>
          <PacketAnatomy tampered />
        </div>
      </div> : <div className={`replay-animation ${active ? "running" : "preview"}`} aria-label="Jetson stores one valid frame while live traffic continues, then reinjects it unchanged">
        <div className="replay-live-lane">
          <small>NORMAL LIVE ENCRYPTED STREAM CONTINUES</small>
          <div className="replay-live-rail">
            {[0, 1, 2].map((index) => <div className="live-packet-token" style={{ "--live-delay": `${index * -1.15}s` }} key={index}><PacketAnatomy /></div>)}
          </div>
        </div>
        <div className="replay-storage"><small>JETSON FRAME STORAGE</small><strong>{sourceFrameId == null ? "STORED FRAME —" : `STORED FRAME #${sourceFrameId}`}</strong><span>AAD + CIPHERTEXT + TAG · UNCHANGED</span></div>
        <div className="replay-captured-token"><span>{sourceFrameId == null ? "VALID FRAME" : `FRAME #${sourceFrameId}`}</span><PacketAnatomy /></div>
        <div className="capture-label">CAPTURE / STORE</div>
        <div className="reinject-label">RE-INJECT LATER</div>
        <div className="replay-stage-progress" aria-label="Replay attack stages: capture, store, re-inject">
          <span className="capture"><b>1</b><em>CAPTURE</em></span>
          <span className="store"><b>2</b><em>STORE</em></span>
          <span className="reinject"><b>3</b><em>RE-INJECT</em></span>
        </div>
      </div>}
      <div className={`operation-verdict ${tamper ? "tamper" : "replay"}`} aria-label={verdict.join(" then ")}>
        {verdict.map((step, index) => <span key={step}><strong>{step}</strong>{index < verdict.length - 1 && <ArrowRight weight="thin" />}</span>)}
      </div>
    </div>
  );
}

function AttackControl({ attack, setMode, setIntensity, onStart, onStop, onReset }) {
  const tamper = attack.mode === "tamper";
  const locked = attack.status !== "idle";
  const lastTarget = tamper
    ? attack.lastModifiedFrameId == null
      ? "—"
      : `F ${attack.lastModifiedFrameId} / P ${attack.lastModifiedPacketId ?? "—"}`
    : attack.lastReplayedFrameId == null ? "—" : `FRAME ${attack.lastReplayedFrameId}`;
  const stats = tamper ? [
    ["ELIGIBLE FRAMES", attack.eligibleFrames],
    ["FRAMES MODIFIED", attack.modifiedFrames],
    ["PACKETS MODIFIED", attack.modifiedPackets],
    ["LAST TARGET", lastTarget],
    ["RUN ID", attack.runId ?? "—"],
    ["ATTACK RUNTIME", formatRuntime(attack.runtime)],
  ] : [
    ["ELIGIBLE FRAMES", attack.eligibleFrames],
    ["FRAMES INJECTED", attack.replayedFrames],
    ["LAST REPLAYED FRAME", lastTarget],
    ["OBSERVED SESSION", attack.observedSessionId ?? "—"],
    ["RUN ID", attack.runId ?? "—"],
    ["ATTACK RUNTIME", formatRuntime(attack.runtime)],
  ];
  return (
    <aside className="attack-control">
      <div className="attack-mode-tabs" aria-label="Attack mode">
        <button className={tamper ? "active" : ""} disabled={locked} onClick={() => setMode("tamper")}>TAMPER</button>
        <button className={!tamper ? "active" : ""} disabled={locked} onClick={() => setMode("replay")}>REPLAY</button>
      </div>
      <div className="frame-rate-control">
        <div><span>{tamper ? "TAMPERED FRAME RATE" : "REPLAY INJECTION RATE"}</span><strong>{attack.frameRate}<small>%</small></strong></div>
        <p>{tamper ? `${attack.frameRate}% of frames selected; one packet modified per frame` : `${attack.frameRate} replay injections per 100 normal frame opportunities`}</p>
        <div className="intensity-options">
          {[5, 10, 20, 40, 60].map((value) => <button key={value} disabled={locked} className={attack.frameRate === value ? "active" : ""} onClick={() => setIntensity(value)}>{value}%</button>)}
        </div>
      </div>
      <div className="attack-stats" aria-label="Jetson attack statistics">
        <span>JETSON ATTACK STATS · ACTUAL ENGINE VALUES</span>
        <dl>
          {stats.map(([label, value]) => <div key={label}><dt>{label}</dt><dd>{typeof value === "number" ? value.toLocaleString() : value}</dd></div>)}
        </dl>
      </div>
      <div className="attack-actions">
        <button className="start" onClick={onStart} disabled={locked || attack.pending || attack.frameRate === 0}><Play weight="fill" />{attack.pending ? "PREPARING..." : "START ATTACK"}</button>
        <button onClick={onStop} disabled={!attack.page2Owned || !locked || attack.pending}><Stop weight="fill" />STOP</button>
        <button onClick={onReset} disabled={attack.pending || attack.externalBusy}><ArrowCounterClockwise />RESET</button>
      </div>
      {attack.error && <p className="attack-control-error">{attack.error}</p>}
    </aside>
  );
}

function JetsonAttackWorkspace(props) {
  return (
    <article className={`jetson-workspace panel ${props.attack.active ? "active" : ""}`}>
      <header className="panel-header"><div><span>01 / ATTACK &amp; PACKET MANIPULATION</span><h2>{props.attack.mode === "tamper" ? "Ciphertext Tampering" : "Replay Injection"}</h2></div><strong>JETSON ATTACK ENGINE · {props.attack.observedSessionId ?? "SESSION —"}</strong></header>
      <div className="jetson-workspace-body"><PacketOperation mode={props.attack.mode} active={props.attack.active} sourceFrameId={props.attack.sourceFrameId} /><AttackControl {...props} /></div>
    </article>
  );
}

function AttackExplanation({ mode }) {
  const tamper = mode === "tamper";
  const steps = tamper
    ? [
      ["1", "SELECT FRAME", "Choose an eligible live encrypted frame."],
      ["2", "MODIFY ONE PACKET", "Change ciphertext in one packet; keep its tag unchanged."],
      ["3", "FORWARD TO RX", "The modified packet continues toward the receiver."],
    ]
    : [
      ["1", "CAPTURE / STORE", "Copy one valid encrypted frame without changing it."],
      ["2", "LIVE STREAM CONTINUES", "Normal encrypted traffic keeps flowing while the old frame is stored."],
      ["3", "RE-INJECT LATER", "Insert the stored AAD, ciphertext and tag back into the stream unchanged."],
    ];
  return (
    <article className={`attack-explanation panel ${tamper ? "tamper" : "replay"}`}>
      <header className="panel-header"><div><span>02 / ATTACK SEMANTICS</span><h2>{tamper ? "One-packet ciphertext modification" : "Stored valid-frame re-injection"}</h2></div><strong>NO RECEIVER RESULT INFERRED</strong></header>
      <div className="attack-explanation-body">
        <div className="explanation-steps">{steps.map(([index, title, detail]) => <div key={index}><b>{index}</b><span><strong>{title}</strong><small>{detail}</small></span></div>)}</div>
        <div className="expected-effect">
          <span>EXPECTED RECEIVER EFFECT</span>
          <strong>{tamper ? "AUTHENTICATION SHOULD FAIL" : "GCM CAN PASS · FRESHNESS SHOULD REJECT"}</strong>
          <small>Actual receiver decisions and reject counts belong to RX UART on the PC Receiver Console.</small>
        </div>
      </div>
    </article>
  );
}

const emptyPathMetrics = () => ({ throughput: [], ingress: [], egress: [], packetRate: [], packetJitter: [], dropDelta: [], dropTotal: [], power: [] });

export function App() {
  const [page, setPage] = useState("baseline");
  const [pathMetrics, setPathMetrics] = useState(emptyPathMetrics);
  const [attackMode, setAttackMode] = useState("tamper");
  const [attackIntensity, setAttackIntensity] = useState(20);
  const [attackState, setAttackState] = useState({ active: false, mode: "none", owner: null, rate: null, status: "idle" });
  const [attackControl, setAttackControl] = useState(null);
  const [attackPending, setAttackPending] = useState(false);
  const [attackError, setAttackError] = useState("");
  const [attackEdgeState, setAttackEdgeState] = useState("idle");
  const [rxTelemetry, setRxTelemetry] = useState(null);
  const [rxLive, setRxLive] = useState(false);
  const [streamAnalysis, setStreamAnalysis] = useState(null);
  const [pollErrors, setPollErrors] = useState(0);
  const lastRxSeqRef = useRef(null);
  const lastStreamSnapshotRef = useRef({ updates: null, live: null });
  const encrypted = streamAnalysis?.mode !== "plaintext";
  const bins = Array.isArray(streamAnalysis?.histogram) ? streamAnalysis.histogram : [];
  const entropy = streamAnalysis?.entropy?.mean;
  const correlation = streamAnalysis?.serial_correlation?.lag_4?.mean;
  const streamSourceState = streamAnalysis?.live ? "LIVE" : streamAnalysis ? "STALE" : "WAITING";
  const observedSession = Number.isInteger(streamAnalysis?.latest_session_id)
    ? `0x${streamAnalysis.latest_session_id.toString(16).toUpperCase().padStart(8, "0")}`
    : "NO PACKET";

  useEffect(() => {
    let stopped = false;
    let inFlight = false;

    async function pollTelemetry() {
      if (inFlight) return;
      inFlight = true;
      try {
        const response = await fetch("/api/telemetry/latest", { cache: "no-store" });
        if (!response.ok) throw new Error(`telemetry HTTP ${response.status}`);
        const snapshot = await response.json();
        if (stopped) return;
        setRxLive(Boolean(snapshot.live));
        if (snapshot.attack_state) setAttackState(snapshot.attack_state);
        if (snapshot.attack_control) setAttackControl(snapshot.attack_control);
        const stream = snapshot.stream_analysis;
        if (stream && (
          stream.updates !== lastStreamSnapshotRef.current.updates ||
          Boolean(stream.live) !== lastStreamSnapshotRef.current.live
        )) {
          lastStreamSnapshotRef.current = { updates: stream.updates, live: Boolean(stream.live) };
          setStreamAnalysis(stream);
        }
        const sample = snapshot.telemetry;
        const metricHistory = Array.isArray(snapshot.system_metrics?.history)
          ? snapshot.system_metrics.history.slice(-WINDOW_SECONDS) : [];
        const streamHistory = Array.isArray(stream?.history)
          ? stream.history.slice(-WINDOW_SECONDS) : [];
        if (streamHistory.length || metricHistory.length) {
          const ingress = metricHistory.map((item) => item.link_ingress_mbps).filter(Number.isFinite);
          const egress = metricHistory.map((item) => item.link_egress_mbps).filter(Number.isFinite);
          setPathMetrics({
            throughput: metricHistory.map((item) => item.link_throughput_mbps ?? item.video_throughput_mbps).filter(Number.isFinite),
            ingress,
            egress,
            packetRate: streamHistory.map((item) => item.packet_rate_kpps).filter(Number.isFinite),
            packetJitter: streamHistory.map((item) => item.packet_timing_jitter_ms).filter(Number.isFinite),
            dropDelta: metricHistory.map((item) => item.bridge_nic_drop_delta_30s).filter(Number.isFinite),
            dropTotal: metricHistory.map((item) => item.bridge_nic_drop_error_total).filter(Number.isFinite),
            power: metricHistory.map((item) => item.board_power_w).filter(Number.isFinite),
          });
        }
        if (!sample || sample.seq === lastRxSeqRef.current) return;
        lastRxSeqRef.current = sample.seq;
        setRxTelemetry(sample);
      } catch {
        if (!stopped) {
          setRxLive(false);
          setStreamAnalysis((current) => current ? { ...current, live: false } : null);
          setPollErrors((current) => current + 1);
        }
      } finally {
        inFlight = false;
      }
    }

    pollTelemetry();
    const timer = window.setInterval(pollTelemetry, 200);
    return () => {
      stopped = true;
      window.clearInterval(timer);
    };
  }, []);

  useEffect(() => {
    const shouldShow = Boolean(attackState.active);
    if (shouldShow) {
      setAttackEdgeState("active");
      return undefined;
    }

    setAttackEdgeState((current) => current === "active" ? "fading" : "idle");
    const fadeTimer = window.setTimeout(() => setAttackEdgeState("idle"), 450);
    return () => window.clearTimeout(fadeTimer);
  }, [attackState.active]);

  const page2Owned = attackState.owner === "page2";
  const externalBusy = attackState.status !== "idle" && !page2Owned;
  const currentAttackMode = page2Owned ? attackState.mode : attackMode;
  const currentAttackRate = page2Owned ? attackState.rate : attackIntensity;
  const rawEngine = attackControl?.engine || {};
  const engine = rawEngine.mode === currentAttackMode ? rawEngine : {};
  const jetsonAttackState = {
    mode: currentAttackMode,
    active: page2Owned && Boolean(attackState.active),
    status: attackState.status,
    page2Owned,
    externalBusy,
    pending: attackPending,
    error: attackError || attackControl?.last_error || attackState.last_error || "",
    frameRate: currentAttackRate,
    modifiedFrames: Number(engine.modified_frames_total || 0),
    modifiedPackets: Number(engine.modified_packets_total || 0),
    replayedFrames: Number(engine.injected_frames_total || 0),
    eligibleFrames: Number(engine.eligible_frames_total || 0),
    runtime: Math.floor(Number(attackControl?.elapsed_s || 0)),
    runId: attackState.run_id ?? engine.run_id ?? null,
    observedSessionId: currentAttackMode === "tamper"
      ? engine.last_session_id ?? null : engine.source_session_id ?? null,
    lastModifiedFrameId: Number(engine.modified_frames_total) > 0 && Number.isFinite(Number(engine.last_frame_id))
      ? Number(engine.last_frame_id) : null,
    lastModifiedPacketId: Number(engine.modified_packets_total) > 0 && Number.isFinite(Number(engine.last_packet_index))
      ? Number(engine.last_packet_index) : null,
    lastReplayedFrameId: Number(engine.injected_frames_total) > 0 && Number.isFinite(Number(engine.source_frame_id))
      ? Number(engine.source_frame_id) : null,
    sourceFrameId: Number(engine.source_frame_id) > 0
      ? Number(engine.source_frame_id) : null,
  };
  const rxSourceState = rxLive ? "LIVE" : rxTelemetry ? "STALE" : "WAITING";

  async function attackRequest(action, payload = {}) {
    const response = await fetch(`/api/attack/${action}`, {
      method: "POST", headers: { "Content-Type": "application/json" },
      body: JSON.stringify(payload),
    });
    const result = await response.json();
    if (!response.ok) throw new Error(result.error || `HTTP ${response.status}`);
    setAttackControl(result);
    if (result.attack_state) setAttackState(result.attack_state);
    return result;
  }

  async function startAttack() {
    if (!attackIntensity || attackPending) return;
    setAttackPending(true);
    setAttackError("");
    try {
      await attackRequest("prepare", { mode: attackMode, rate: attackIntensity });
      await attackRequest("start", { mode: attackMode, rate: attackIntensity });
    } catch (error) {
      setAttackError(String(error));
    } finally {
      setAttackPending(false);
    }
  }

  async function stopAttack() {
    setAttackPending(true);
    setAttackError("");
    try { await attackRequest("stop"); }
    catch (error) { setAttackError(String(error)); }
    finally { setAttackPending(false); }
  }

  async function resetAttack() {
    setAttackPending(true);
    setAttackError("");
    try { await attackRequest("reset"); }
    catch (error) { setAttackError(String(error)); }
    finally { setAttackPending(false); }
  }

  const globalAttackLabel = attackState.active
    ? `${attackState.mode === "bruteforce" ? "WEAK-KEY SEARCH" : String(attackState.mode).toUpperCase()} ACTIVE${attackState.rate ? ` · ${attackState.rate}%` : ""}`
    : "ATTACK NONE";

  return (
    <main
      className={`app ${encrypted ? "stream-encrypted" : "stream-plain"}`}
      data-rx-source={rxSourceState}
      data-rx-seq={rxTelemetry?.seq ?? ""}
      data-telemetry-poll-errors={pollErrors}
    >
      <div className={`attack-edge-overlay ${attackEdgeState}`} aria-hidden="true">
        <i className="attack-edge attack-edge-top" />
        <i className="attack-edge attack-edge-right" />
        <i className="attack-edge attack-edge-bottom" />
        <i className="attack-edge attack-edge-left" />
      </div>
      <header className="topbar">
        <span className="brand-mark"><ShieldCheck weight="fill" /></span>
        <div><strong>JETSON SECURE VIDEO MONITOR</strong><small>LIVE DATA FLOW</small></div>
        <span className={`global-attack-indicator ${attackState.active ? "active" : ""}`}>{globalAttackLabel}</span>
        <nav className="page-nav" aria-label="Dashboard pages">
          <button className={page === "baseline" ? "active" : ""} onClick={() => setPage("baseline")}><small>01</small>NORMAL FLOW</button>
          <button className={page === "attack" ? "active" : ""} onClick={() => setPage("attack")}><small>02</small>INTEGRITY ATTACK</button>
          <button className={page === "bruteforce" ? "active" : ""} onClick={() => setPage("bruteforce")}><small>03</small>WEAK-KEY SEARCH</button>
        </nav>
      </header>

      {page === "baseline" ? <section className="dashboard">
        <article className="flow-panel panel">
          <header className="panel-header flow-header flow-header-state-only">
            <div className="flow-controls">
              <div className="flow-state-group">
                <small>SYSTEM STATE</small>
                <div><Status tone={encrypted ? "ok" : "warn"}>{encrypted ? "AES-GCM · OBSERVED" : "PLAINTEXT · OBSERVED"}</Status><Status tone={streamAnalysis?.live ? "ok" : "warn"}>OBSERVED SESSION {observedSession}</Status><Status tone="warn">PACKET FORMAT REF</Status></div>
              </div>
            </div>
          </header>
          <div className="system-flow">
            <DeviceNode name="ZYBO Z7-20" role="TX" image="/assets/zybo-z7-20-official.png" />
            <FlowLink encrypted={encrypted} />
            <DeviceNode name="JETSON ORIN NANO" role="MONITOR" image="/assets/jetson-orin-nano-official.jpg" jetson />
            <FlowLink encrypted={encrypted} offset={-2.6} />
            <DeviceNode name="ZYBO Z7-20" role="RX" image="/assets/zybo-z7-20-official.png" />
          </div>
          <PacketSummary
            encrypted={encrypted}
            frameId={streamAnalysis?.latest_frame_id}
            packetId={streamAnalysis?.latest_packet_id}
          />
        </article>

        <article className="entropy-panel panel">
          <header className="panel-header">
            <div><span>CURRENT STREAM</span><h2>Byte Distribution + Entropy</h2></div>
            <strong className={encrypted ? "stream-state encrypted" : "stream-state plain"}>
              {streamAnalysis?.live
                ? encrypted ? "AES-GCM CIPHERTEXT · LIVE" : "PLAINTEXT YUYV · LIVE"
                : `STREAM SAMPLE · ${streamSourceState}`}
            </strong>
          </header>
          <div className="entropy-content">
            <div className="entropy-readout">
              <span>ENTROPY</span>
              <strong>{Number.isFinite(entropy) ? entropy.toFixed(2) : "—"}<small>/ 8.00</small></strong>
              <p>bits / byte</p>
              <div className="correlation-readout">
                <span>SERIAL CORRELATION (LAG-4)</span>
                <strong>{Number.isFinite(correlation) ? correlation.toFixed(3) : "—"}</strong>
              </div>
            </div>
            <Histogram bins={bins} encrypted={encrypted} />
          </div>
        </article>

        <article className="telemetry-panel panel">
          <header className="panel-header telemetry-header">
            <div><span>JETSON OBSERVATION</span><h2>Inline Traffic + System Metrics</h2></div>
            <strong>{WINDOW_SECONDS} SEC · JETSON OBSERVER {streamSourceState} · {Number.isFinite(pathMetrics.packetRate.at(-1)) ? `${pathMetrics.packetRate.at(-1).toFixed(1)} kpps` : "—"} · DROP Δ {pathMetrics.dropDelta.at(-1) ?? "—"}</strong>
          </header>
          <div className="telemetry-list">
            {PAGE01_METRICS.map(({ key, label, ...metric }) => <TrendChart
              key={key}
              {...metric}
              label={label}
              values={pathMetrics[key]}
              labelHint={key === "throughput" ? "OUT · GRAPH" : null}
              secondaryText={key === "throughput"
                ? Number.isFinite(pathMetrics.ingress.at(-1))
                  ? `IN ${pathMetrics.ingress.at(-1).toFixed(1)} Mbps`
                  : null
                : key === "packetJitter"
                  ? "IAT STD"
                  : key === "dropDelta" && Number.isFinite(pathMetrics.dropTotal.at(-1))
                    ? `TOTAL ${pathMetrics.dropTotal.at(-1).toFixed(0)}`
                    : null}
            />)}
          </div>
        </article>
      </section> : page === "attack" ? <section className="attack-dashboard">
        <header className="attack-page-header panel">
          <div><span>PAGE 02 · CONTROLLED SECURITY DEMONSTRATION</span><h1>Integrity Attack</h1></div>
          <div><strong className={`page-incident ${attackState.active ? "active" : ""}`}>{attackState.active ? `● ${globalAttackLabel}` : "ATTACK ENGINE IDLE"}</strong><span className="sim-label">JETSON ATTACKER-SIDE STATE ONLY</span></div>
        </header>
        <AttackFlowStrip attack={jetsonAttackState} />
        <JetsonAttackWorkspace attack={jetsonAttackState} setMode={setAttackMode} setIntensity={setAttackIntensity} onStart={startAttack} onStop={stopAttack} onReset={resetAttack} />
        <AttackExplanation mode={jetsonAttackState.mode} />
      </section> : <BruteForcePage />}
    </main>
  );
}
