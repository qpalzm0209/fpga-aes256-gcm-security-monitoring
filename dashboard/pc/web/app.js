const $ = (selector) => document.querySelector(selector);
const $$ = (selector) => [...document.querySelectorAll(selector)];
const video = $("#video");
const deviceSelect = $("#deviceSelect");
const startButton = $("#startButton");
const videoMessage = $("#videoMessage");
const securityOverlay = $("#securityOverlay");
const history = [];
const recentCounterSamples = { auth: [], replay: [] };
const previousCounters = {};
const recentReject = { tag: 0, replay: 0 };
const recentDetectorEvents = {};
const detectorNames = ["tag", "replay", "sequence", "session", "timeout"];
const DETECTOR_ALERT_HOLD_MS = 1400;
const TIMELINE_WINDOW_MS = 60000;
const VIDEO_FRAME_TIMEOUT_MS = 1000;
const OCC_PASS_HOLD_MS = 1000;
const OCC_DOOR_MS = 360;
const timelineRows = ["attack", ...detectorNames];
const timelineEvents = [];
const timelineSegments = [];
const sessionEvents = [];
const aiMessages = [];
const timelineKnownRxEvents = new Map();
const timelineHoverTargets = [];
const keyChord = new Set();
let stream;
let overlayTimer;
let latestState = null;
let latestAttack = null;
let occWasLocked = true;
let occPhase = "locked";
let occPassTimer;
let occDoorTimer;
let occMasterSequence = "";
let occMasterTimer;
let aiConfigured = false;
let aiPending = false;
let aiInteractionId = null;
let speechRecognition = null;
let speechSubmitted = false;
let aiVoiceState = "IDLE";
let aiVoiceTranscript = "";
let aiFocusTimer;
let aiFocusTask = null;
let aiVisibleEvidence = [];
let aiAllEvidence = [];
let aiEvidenceWindow = null;
let aiStatusLabel = "GEMINI 확인 중";
let aiStatusPrompt = "Gemini 연결 상태를 확인하는 중입니다";
let rxWasOnline = false;
let timelinePreviousAttack = null;
let timelinePreviousRxOnline = false;
let timelineEventId = 0;
let sessionEventId = 0;
let sessionEventFilter = "all";
const sessionStartedAt = Date.now();
let sessionPreviousVideoState = null;
let sessionPreviousRxOnline = null;
let videoDeviceConnected = null;
let videoLastFrameAt = null;
let videoFrameCallbackId = null;
let videoFrameMonitorTimer = null;
let videoLogState = null;
let sessionPreviousJetsonOnline = null;
let sessionPreviousGeminiOnline = null;
let latestCanonicalState = null;
let eventLogRenderTimer = null;

function shortcutKey(event) {
  const match = /^Key([A-Z])$/.exec(event.code || "");
  return match ? match[1].toLowerCase() : event.key.toLowerCase();
}

function resetOccMasterSequence() {
  clearTimeout(occMasterTimer);
  occMasterSequence = "";
}

function valueFrom(object, ...keys) {
  for (const key of keys) {
    if (object && object[key] !== undefined && object[key] !== null) return object[key];
  }
  return undefined;
}

function finiteValue(object, ...keys) {
  const raw = valueFrom(object, ...keys);
  const value = Number(raw);
  return raw === undefined || raw === null || !Number.isFinite(value) ? null : value;
}

function formatNumber(value, digits = 2, suffix = "") {
  return Number.isFinite(value) ? `${value.toFixed(digits)}${suffix}` : "—";
}

function formatInteger(value) {
  return Number.isFinite(value) ? Math.round(value).toLocaleString() : "—";
}

function formatRuntime(milliseconds) {
  return Number.isFinite(milliseconds) ? `${(milliseconds / 1000).toFixed(1)} s` : "—";
}

function recentCounterDelta(name, total) {
  if (!Number.isFinite(total)) return null;
  const now = Date.now();
  const samples = recentCounterSamples[name];
  if (samples.length && total < samples.at(-1).total) samples.length = 0;
  if (!samples.length || samples.at(-1).total !== total || now - samples.at(-1).timestamp >= 200) {
    samples.push({ timestamp: now, total });
  }
  while (samples.length && samples[0].timestamp < now - 5000) samples.shift();
  const baseline = [...samples].reverse().find((sample) => sample.timestamp <= now - 1000);
  return baseline ? Math.max(0, total - baseline.total) : 0;
}

function securityState(state, data, rxOnline) {
  const source = state?.security_state || {};
  const number = (name, ...fallback) => {
    const value = finiteValue(source, name);
    return value != null ? value : fallback.length ? finiteValue(data, ...fallback) : null;
  };
  const gcmAuthFailTotal = rxOnline ? number("gcm_auth_fail_total", "authentication_failures_total") : null;
  const replayRejectTotal = rxOnline ? number("replay_reject_total", "replay_reject_total", "replay_failures_total") : null;
  const gcmAuthFailLast1s = rxOnline
    ? number("gcm_auth_fail_last_1s") ?? recentCounterDelta("auth", gcmAuthFailTotal) : null;
  const replayRejectLast1s = rxOnline
    ? number("replay_reject_last_1s") ?? recentCounterDelta("replay", replayRejectTotal) : null;
  return {
    gcmAuthFailLast1s,
    gcmAuthFailRate1s: rxOnline ? number("gcm_auth_fail_rate_per_sec", "gcm_auth_fail_rate_1s", "auth_reject_rate") ?? gcmAuthFailLast1s : null,
    gcmAuthFailTotal,
    replayRejectLast1s,
    replayRejectRate1s: rxOnline ? number("replay_reject_rate_per_sec", "replay_reject_rate_1s", "replay_reject_rate") ?? replayRejectLast1s : null,
    replayRejectTotal,
    sequenceErrorTotal: rxOnline ? number("sequence_error_total", "detector_sequence_total") : null,
    sessionErrorTotal: rxOnline ? number("session_error_total", "detector_session_total") : null,
    timeoutTotal: rxOnline ? number("timeout_total", "detector_timeout_total") : null,
    processedTotal: rxOnline ? number("processed_total", "processed_frames_total") : null,
    processedUnit: source.processed_unit || "frames",
    networkLossTotal: rxOnline ? number("network_loss_total") : null,
    queueOverrunTotal: rxOnline ? number("queue_overrun_total") : null,
    staleDropTotal: rxOnline ? number("stale_drop_total") : null,
    statusFailureTotal: rxOnline ? number("status_failure_total") : null,
  };
}

function detectorTypeFromEvent(event) {
  const type = String(valueFrom(event, "event_type") || "").toLowerCase();
  if (/gcm_auth|tag/.test(type)) return "tag";
  if (/replay/.test(type)) return "replay";
  if (/sequence/.test(type)) return "sequence";
  if (/session/.test(type)) return "session";
  return /timeout/.test(type) ? "timeout" : null;
}

function setChip(element, tone, text) {
  if (!element) return;
  element.textContent = text;
  element.className = element.classList.contains("mini-status")
    ? `mini-status ${tone}` : `status-chip ${tone}`;
}

function showSecurityOverlay(title, detail) {
  clearTimeout(overlayTimer);
  securityOverlay.querySelector("strong").textContent = title;
  securityOverlay.querySelector("span").textContent = detail;
  securityOverlay.classList.add("visible");
  overlayTimer = setTimeout(() => securityOverlay.classList.remove("visible"), 3200);
}

function stopStream() {
  stopVideoFrameMonitor();
  stream?.getTracks().forEach((track) => track.stop());
  stream = undefined;
  video.srcObject = null;
}

function stopVideoFrameMonitor() {
  if (videoFrameCallbackId != null && typeof video.cancelVideoFrameCallback === "function") {
    video.cancelVideoFrameCallback(videoFrameCallbackId);
  }
  clearInterval(videoFrameMonitorTimer);
  videoFrameCallbackId = null;
  videoFrameMonitorTimer = null;
}

function startVideoFrameMonitor(expectedStream) {
  stopVideoFrameMonitor();
  let lastMediaTime = video.currentTime;
  const isCurrentStream = () => stream === expectedStream && expectedStream.active && video.srcObject === expectedStream;
  const markFrame = () => {
    if (!isCurrentStream()) return;
    videoLastFrameAt = Date.now();
    videoFrameCallbackId = video.requestVideoFrameCallback(markFrame);
  };
  if (typeof video.requestVideoFrameCallback === "function") {
    videoFrameCallbackId = video.requestVideoFrameCallback(markFrame);
  }
  videoFrameMonitorTimer = window.setInterval(() => {
    if (!isCurrentStream()) return stopVideoFrameMonitor();
    if (video.readyState >= 2 && !video.paused && video.currentTime !== lastMediaTime) {
      lastMediaTime = video.currentTime;
      videoLastFrameAt = Date.now();
    }
  }, 250);
}

function canonicalVideoState() {
  const streamActive = stream ? Boolean(stream.active) : videoDeviceConnected == null ? null : false;
  const frameAgeMs = videoLastFrameAt == null ? null : Math.max(0, Date.now() - videoLastFrameAt);
  const frameAlive = streamActive === true && frameAgeMs != null ? frameAgeMs < VIDEO_FRAME_TIMEOUT_MS : null;
  const status = videoDeviceConnected == null ? "UNKNOWN"
    : videoDeviceConnected === false ? "NO_DEVICE"
      : streamActive !== true || frameAlive !== true ? "WAIT" : "LIVE";
  return {
    statusKnown: videoDeviceConnected != null,
    status,
    deviceConnected: streamActive ? true : videoDeviceConnected,
    streamActive,
    deviceName: streamActive ? (stream?.getVideoTracks()[0]?.label || null) : (videoDeviceConnected === true ? (deviceSelect.value ? $("#deviceName").textContent : null) : null),
    captureFps: streamActive ? Number(stream?.getVideoTracks()[0]?.getSettings().frameRate) || null : null,
    lastFrameAt: videoLastFrameAt,
    lastFrameAgeMs: frameAgeMs,
    frameAlive,
  };
}

function setVideoState(state, message = "") {
  setChip($("#videoStatus"), state === "LIVE" ? "live" : state === "ERROR" ? "error" : "", `VIDEO ${state}`);
  $("#videoLiveLabel").textContent = state;
  videoMessage.textContent = message;
  videoMessage.classList.toggle("hidden", state === "LIVE");
  sessionPreviousVideoState = state;
}

function syncCanonicalVideoState() {
  const current = canonicalVideoState();
  if (current.status === "LIVE") setVideoState("LIVE");
  else if (current.status === "NO_DEVICE") setVideoState("WAIT", "NO VIDEO INPUT DEVICE");
  else if (current.status === "WAIT") setVideoState("WAIT", "VIDEO FRAME WAITING");
  if (videoLogState !== current.status) {
    const previous = videoLogState;
    if (current.status === "LIVE") {
      pushSessionEvent({ category: "video", source: "VIDEO", type: previous === "WAIT" ? "VIDEO_STREAM_RECOVERED" : "VIDEO_STREAM_STARTED" });
    } else if (current.status === "WAIT" && previous === "LIVE") {
      pushSessionEvent({ category: "video", source: "VIDEO", type: "VIDEO_FRAME_TIMEOUT", tone: "warn" });
    } else if (current.status === "NO_DEVICE" && previous && previous !== "NO_DEVICE") {
      pushSessionEvent({ category: "video", source: "VIDEO", type: "VIDEO_DEVICE_DISCONNECTED", tone: "auth" });
    } else if (current.deviceConnected === true && (previous === "UNKNOWN" || previous === "NO_DEVICE")) {
      pushSessionEvent({ category: "video", source: "VIDEO", type: "VIDEO_DEVICE_CONNECTED" });
    }
    videoLogState = current.status;
  }
  return current;
}

function buildCanonicalSystemState(state = latestState || {}) {
  const data = state.telemetry || {};
  const rxOnline = Boolean(state.online && state.telemetry);
  const attack = latestAttack || normalizeAttack(state);
  const security = securityState(state, data, rxOnline);
  return {
    observedAt: new Date().toISOString(),
    video: syncCanonicalVideoState(),
    rx: {
      connected: rxOnline,
      validFps: rxOnline ? finiteValue(data, "valid_frame_rate") : null,
      attemptedFps: rxOnline ? finiteValue(data, "frame_attempt_rate") : null,
      frameDropPercent: rxOnline && finiteValue(data, "frame_drop_ratio") != null ? finiteValue(data, "frame_drop_ratio") * 100 : null,
      frameJitterMs: rxOnline ? finiteValue(data, "frame_jitter_ms") : null,
      processedFramesTotal: security.processedTotal,
      gcmAuthFailLast1s: security.gcmAuthFailLast1s,
      gcmAuthFailRatePerSec: security.gcmAuthFailRate1s,
      gcmAuthFailTotal: security.gcmAuthFailTotal,
      replayRejectLast1s: security.replayRejectLast1s,
      replayRejectRatePerSec: security.replayRejectRate1s,
      replayRejectTotal: security.replayRejectTotal,
    },
    jetson: {
      connected: attack.connected,
      attack: { active: attack.active, type: attack.name, ratePercent: attack.rate, startedAt: attack.active ? Date.now() - (attack.runtimeMs || 0) : null },
    },
  };
}

async function loadDevices(selectedId = deviceSelect.value) {
  const devices = (await navigator.mediaDevices.enumerateDevices()).filter((device) => device.kind === "videoinput");
  videoDeviceConnected = devices.length > 0;
  deviceSelect.replaceChildren();
  devices.forEach((device, index) => {
    const option = document.createElement("option");
    option.value = device.deviceId;
    option.textContent = device.label || `VIDEO INPUT ${index + 1}`;
    deviceSelect.append(option);
  });
  const preferred = devices.find((device) => device.deviceId === selectedId)
    || devices.find((device) => /usb3.*capture|capture|hdmi/i.test(device.label));
  if (preferred) deviceSelect.value = preferred.deviceId;
  startButton.disabled = devices.length === 0;
  if (!devices.length) setVideoState("ERROR", "NO VIDEO INPUT DEVICE");
  syncCanonicalVideoState();
}

function formatInput(settings) {
  const width = settings.width || video.videoWidth;
  const height = settings.height || video.videoHeight;
  const fps = Number(settings.frameRate);
  const size = width && height ? `${width} × ${height}` : "UNKNOWN";
  return Number.isFinite(fps) ? `${size} @ ${fps.toFixed(2)} FPS` : size;
}

async function startCapture() {
  startButton.disabled = true;
  setVideoState("WAIT", "OPENING VIDEO INPUT");
  try {
    stopStream();
    stream = await navigator.mediaDevices.getUserMedia({
      video: {
        ...(deviceSelect.value && { deviceId: { exact: deviceSelect.value } }),
        width: { ideal: 1280 }, height: { ideal: 720 }, frameRate: { ideal: 30 },
      },
      audio: false,
    });
    video.srcObject = stream;
    await video.play();
    const track = stream.getVideoTracks()[0];
    const settings = track.getSettings();
    videoDeviceConnected = true;
    videoLastFrameAt = Date.now();
    startVideoFrameMonitor(stream);
    await loadDevices(settings.deviceId);
    $("#deviceName").textContent = track.label || "VIDEO INPUT";
    $("#inputFormat").textContent = formatInput(settings);
    setVideoState("LIVE");
    track.addEventListener("ended", () => {
      videoDeviceConnected = false;
      stopStream();
      setVideoState("ERROR", "VIDEO INPUT DISCONNECTED");
    }, { once: true });
  } catch (error) {
    stopStream();
    const denied = error.name === "NotAllowedError" || error.name === "SecurityError";
    setVideoState("ERROR", denied ? "CAMERA PERMISSION DENIED" : "VIDEO INPUT COULD NOT BE OPENED");
    console.error(error);
  } finally {
    startButton.disabled = !deviceSelect.options.length;
  }
}

function normalizeAttack(state) {
  const connected = Boolean(state?.jetson_attack?.online);
  const raw = state?.jetson_attack?.attack_status || {};
  const mode = connected ? String(raw.mode || "none").toLowerCase() : "none";
  const target = connected && raw.last_target ? raw.last_target : null;
  return {
    connected,
    active: connected && Boolean(raw.active),
    mode,
    name: mode === "none" ? "NONE" : mode.toUpperCase(),
    rate: connected && raw.rate != null ? Number(raw.rate) : null,
    count: connected ? Number(raw.count || 0) : null,
    runtimeMs: connected ? Number(raw.runtime_ms || 0) : null,
    startedAt: Number.isFinite(Number(raw.started_at ?? raw.startedAt)) ? Number(raw.started_at ?? raw.startedAt) : null,
    targetFrame: target?.frame_id ?? null,
    targetPacket: target?.packet_id ?? null,
  };
}

function attackPresentation(attack) {
  if (!attack.connected) return { state: "offline", label: "공격", badge: "오프라인" };
  if (attack.active) return { state: "active", label: "공격 진행", badge: "진행" };
  if (attack.mode !== "none") return { state: "last", label: "최근 공격", badge: "유지" };
  return { state: "none", label: "공격", badge: "없음" };
}

function createTimelineEvent({ timestamp = Date.now(), source, type, delta = null, total = null, mode = null, rate = null, runtimeMs = null, frameId = null, packetId = null }) {
  return { id: ++timelineEventId, timestamp, source, type, delta, total, mode, rate, runtimeMs, frameId, packetId };
}

function pushTimelineEvent(fields) {
  const event = createTimelineEvent(fields);
  timelineEvents.push(event);
  pushSessionEvent(sessionEventFromTimeline(event));
  return event;
}

function latestOpenTimelineSegment() {
  for (let index = timelineSegments.length - 1; index >= 0; index -= 1) {
    const segment = timelineSegments[index];
    if (segment.end == null && segment.interruptedAt == null) return segment;
  }
  return null;
}

function startTimelineAttack(attack, timestamp) {
  const event = pushTimelineEvent({ timestamp, source: "jetson", type: "attack-start", mode: attack.mode, rate: attack.rate });
  timelineSegments.push({
    id: event.id,
    start: timestamp,
    end: null,
    interruptedAt: null,
    observedUntil: timestamp,
    mode: attack.mode,
    rate: attack.rate,
    runtimeMs: attack.runtimeMs,
  });
}

function stopTimelineAttack(previous, current, timestamp) {
  const segment = latestOpenTimelineSegment();
  if (segment) {
    segment.end = timestamp;
    segment.observedUntil = timestamp;
    segment.runtimeMs = current.runtimeMs;
  }
  pushTimelineEvent({ timestamp, source: "jetson", type: "attack-stop", mode: previous.mode, rate: previous.rate, runtimeMs: current.runtimeMs });
}

function keepTimelineAttackRunning(attack, timestamp) {
  let segment = latestOpenTimelineSegment();
  if (segment && segment.mode !== attack.mode) {
    stopTimelineAttack({ mode: segment.mode, rate: segment.rate }, attack, timestamp);
    segment = null;
  }
  if (!segment) {
    // A current controller heartbeat saying RUNNING is authoritative. Resume a
    // same-mode observer interruption instead of turning an injection gap into
    // a second/closed attack interval.
    segment = [...timelineSegments].reverse().find((item) => (
      item.end == null && item.interruptedAt != null && item.mode === attack.mode
    ));
    if (segment) segment.interruptedAt = null;
    else {
      startTimelineAttack(attack, timestamp);
      segment = latestOpenTimelineSegment();
    }
  }
  segment.observedUntil = timestamp;
  segment.runtimeMs = attack.runtimeMs;
}

function pruneTimeline(timestamp) {
  const cutoff = timestamp - TIMELINE_WINDOW_MS;
  while (timelineEvents.length && timelineEvents[0].timestamp < cutoff) timelineEvents.shift();
  while (timelineSegments.length) {
    const segment = timelineSegments[0];
    const visibleEnd = segment.end ?? segment.interruptedAt ?? segment.observedUntil;
    if (visibleEnd >= cutoff) break;
    timelineSegments.shift();
  }
  timelineKnownRxEvents.forEach((seenAt, key) => {
    if (seenAt < cutoff) timelineKnownRxEvents.delete(key);
  });
}

function updateSecurityTimeline(state, data, attack, rxOnline, security) {
  const timestamp = Date.now();
  const previous = timelinePreviousAttack;

  if (attack.connected) {
    if (attack.active) {
      keepTimelineAttackRunning(attack, timestamp);
      if (previous?.connected && previous.active && previous.mode === attack.mode && previous.rate !== attack.rate) {
        pushSessionEvent({ category: "attack", source: "JETSON", type: "ATTACK_RATE_CHANGE", detail: `RATE ${attack.rate ?? "—"}%`, timestamp, tone: attack.mode === "replay" ? "replay" : "auth" });
      }
    } else if (previous?.connected && previous.active) {
      stopTimelineAttack(previous, attack, timestamp);
    }
  } else if (previous?.connected && previous.active) {
    const openSegment = latestOpenTimelineSegment();
    if (openSegment) {
      openSegment.interruptedAt = openSegment.observedUntil || timestamp;
      openSegment.observedUntil = openSegment.interruptedAt;
    }
  }
  timelinePreviousAttack = {
    connected: attack.connected,
    active: attack.active,
    mode: attack.mode,
    rate: attack.rate,
    runtimeMs: attack.runtimeMs,
  };

  if (rxOnline) {
    const currentMonotonic = finiteValue(data, "monotonic_ms");
    const events = Array.isArray(state.events) ? [...state.events].reverse() : [];
    events.forEach((event) => {
      const type = detectorTypeFromEvent(event);
      const eventSequence = valueFrom(event, "event_seq");
      const key = eventSequence == null ? null : `${type}:${eventSequence}`;
      if (!type || key == null || timelineKnownRxEvents.has(key)) return;
      const eventMonotonic = finiteValue(event, "monotonic_ms");
      const eventTimestamp = Number.isFinite(currentMonotonic) && Number.isFinite(eventMonotonic)
        ? timestamp - Math.max(0, currentMonotonic - eventMonotonic) : timestamp;
      pushTimelineEvent({
        timestamp: eventTimestamp,
        source: "rx",
        type,
        delta: 1,
        total: type === "tag" ? security.gcmAuthFailTotal
          : type === "replay" ? security.replayRejectTotal
            : finiteValue(data, `detector_${type}_total`),
        frameId: valueFrom(event, "frame_id"),
        packetId: valueFrom(event, "packet_id", "packet_index"),
      });
      timelineKnownRxEvents.set(key, eventTimestamp);
    });
  }
  timelinePreviousRxOnline = rxOnline;
  pruneTimeline(timestamp);
}

function timelineTime(timestamp) {
  return new Date(timestamp).toLocaleTimeString("en-GB", {
    hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit", fractionalSecondDigits: 3,
  });
}

function sessionEventFromTimeline(event) {
  if (event.source === "jetson") {
    const mode = String(event.mode || "attack").toUpperCase();
    return {
      category: "attack", source: "JETSON", type: `${mode}_${event.type === "attack-start" ? "START" : "STOP"}`,
      detail: event.type === "attack-start" ? `RATE ${event.rate ?? "—"}%` : `RUNTIME ${formatRuntime(event.runtimeMs)}`,
      timestamp: event.timestamp, tone: event.mode === "replay" ? "replay" : "auth",
    };
  }
  const names = { tag: "GCM_AUTH_FAIL", replay: "REPLAY_REJECT", sequence: "SEQUENCE_ERROR", session: "SESSION_ERROR", timeout: "TIMEOUT" };
  const ids = [event.frameId == null ? null : `FRAME ${event.frameId}`, event.packetId == null ? null : `PACKET ${event.packetId}`].filter(Boolean);
  return {
    category: "security", source: "RX", type: names[event.type] || String(event.type || "SECURITY_EVENT").toUpperCase(),
    detail: ids.join(" · ") || null, timestamp: event.timestamp, tone: event.type === "replay" ? "replay" : "auth",
  };
}

function pushSessionEvent(event) {
  if (!event) return null;
  const item = { id: ++sessionEventId, timestamp: event.timestamp ?? Date.now(), category: event.category, source: event.source, type: event.type, detail: event.detail || null, tone: event.tone || "" };
  sessionEvents.push(item);
  scheduleSessionEventLogRender();
  return item;
}

function scheduleSessionEventLogRender() {
  // Keep collecting the complete session history, but never rebuild its DOM
  // while the drawer is closed. Page 02 receives RX events at high rate.
  if ($("#eventLogDrawer")?.hidden) return;
  if (eventLogRenderTimer != null) return;
  eventLogRenderTimer = window.setTimeout(() => {
    eventLogRenderTimer = null;
    if (!$("#eventLogDrawer")?.hidden) renderSessionEventLog();
  }, 200);
}

function sessionEventTime(timestamp) {
  return new Date(timestamp).toLocaleTimeString("en-GB", {
    hour12: false, hour: "2-digit", minute: "2-digit", second: "2-digit", fractionalSecondDigits: 3,
  });
}

function getCurrentSystemState() { return latestCanonicalState || buildCanonicalSystemState(); }
function getVideoState() { return getCurrentSystemState().video; }
function getAttackState() { return getCurrentSystemState().jetson; }
function getSecuritySnapshot() { return getCurrentSystemState().rx; }
function getRecentEvents(seconds = 60) { return getSessionEvents(Date.now() - seconds * 1000); }
function getSessionEvents(startTime = 0, endTime = Date.now(), category = "all") {
  return sessionEvents.filter((event) => event.timestamp >= startTime && event.timestamp <= endTime && (category === "all" || event.category === category));
}

function aggregateEventLog(events) {
  const groups = [];
  events.forEach((event) => {
    const second = Math.floor(event.timestamp / 1000);
    const current = groups.at(-1);
    if (event.category === "security" && current && current.category === "security" && current.source === event.source && current.type === event.type && current.second === second) {
      current.events.push(event);
    } else {
      groups.push({ ...event, second, events: [event] });
    }
  });
  return groups;
}

function renderSessionEventLog() {
  const list = $("#eventLogList");
  if (!list) return;
  const filtered = getSessionEvents(0, Date.now(), sessionEventFilter);
  $("#eventLogSessionDate").textContent = new Date(sessionStartedAt).toLocaleDateString("ko-KR");
  $("#eventLogSessionStart").textContent = `세션 시작 · ${new Date(sessionStartedAt).toLocaleTimeString("en-GB", { hour12: false })}`;
  $("#eventLogCount").textContent = `이벤트 ${sessionEvents.length.toLocaleString()}건`;
  list.replaceChildren();
  if (!filtered.length) {
    const empty = document.createElement("p"); empty.className = "event-log-empty"; empty.textContent = "이 범주의 실제 세션 이벤트가 아직 없습니다."; list.append(empty); return;
  }
  aggregateEventLog(filtered).reverse().forEach((event) => {
    const row = document.createElement("article"); row.className = `event-log-row ${event.category} ${event.tone}`;
    const dot = document.createElement("i");
    const main = document.createElement("div"); main.className = "event-log-row-main";
    const line = document.createElement("div");
    const type = document.createElement("strong"); type.textContent = event.events.length > 1 ? `${event.type} × ${event.events.length}` : event.type;
    const time = document.createElement("time"); time.dateTime = new Date(event.timestamp).toISOString(); time.textContent = sessionEventTime(event.timestamp);
    const raw = event.events;
    const detail = document.createElement("small"); detail.textContent = [event.source, raw.length > 1 ? `${sessionEventTime(raw[0].timestamp)} ~ ${sessionEventTime(raw.at(-1).timestamp)}` : event.detail].filter(Boolean).join(" · ");
    line.append(type, time); main.append(line); if (detail.textContent) main.append(detail); row.append(dot, main); list.append(row);
    if (raw.length > 1) {
      const details = document.createElement("details"); details.className = "event-log-details";
      const summary = document.createElement("summary"); summary.textContent = `상세 ${raw.length}건`;
      const entries = document.createElement("div");
      [...raw].reverse().forEach((item) => {
        const entry = document.createElement("small"); entry.textContent = `${sessionEventTime(item.timestamp)}  ${item.detail || item.source}`; entries.append(entry);
      });
      details.append(summary, entries); main.append(details);
    }
  });
}

function timelineTooltipLines(target) {
  if (target.kind === "segment") {
    const segment = target.segment;
    const lines = [
      String(segment.mode).toUpperCase(),
      `RATE ${segment.rate ?? "—"}%`,
      `STATUS ${target.status}`,
      `START ${timelineTime(segment.start)}`,
    ];
    if (target.status === "COMPLETED") lines.push(`STOP ${timelineTime(segment.end)}`);
    if (target.status === "INTERRUPTED") lines.push(`LAST OBSERVED ${timelineTime(segment.interruptedAt)}`);
    lines.push(`RUNTIME ${formatRuntime(segment.runtimeMs)}`);
    return lines;
  }
  const event = target.event;
  if (event.type === "attack-start") return [`${String(event.mode).toUpperCase()} START`, timelineTime(event.timestamp), `RATE ${event.rate ?? "—"}%`];
  if (event.type === "attack-stop") return [`${String(event.mode).toUpperCase()} STOP`, timelineTime(event.timestamp), `RUNTIME ${formatRuntime(event.runtimeMs)}`];
  const lines = [`${event.type.toUpperCase()} EVENT`, timelineTime(event.timestamp), `발생 ×${event.delta}`];
  if (event.total != null) lines.push(`누적 ${formatInteger(event.total)}`);
  return lines;
}

function drawSecurityTimeline(attack, rxOnline) {
  const canvas = $("#securityTimeline");
  if (!canvas) return;
  const rect = canvas.getBoundingClientRect();
  if (rect.width < 4 || rect.height < 4) return;
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const width = Math.floor(rect.width * dpr);
  const height = Math.floor(rect.height * dpr);
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const w = rect.width;
  const h = rect.height;
  const plot = { left: 112, right: 22, top: 12, bottom: 30 };
  const plotWidth = Math.max(1, w - plot.left - plot.right);
  const rowHeight = (h - plot.top - plot.bottom) / timelineRows.length;
  const now = Date.now();
  const cutoff = now - TIMELINE_WINDOW_MS;
  const colors = {
    attack: "#ff736f",
    tag: "#ff736f",
    replay: "#e0b45a",
    sequence: "#67bdd1",
    session: "#9b8cd9",
    timeout: "#d88b52",
  };
  const xFor = (timestamp) => plot.left + Math.max(0, Math.min(1, (timestamp - cutoff) / TIMELINE_WINDOW_MS)) * plotWidth;
  const yFor = (row) => plot.top + (timelineRows.indexOf(row) + .5) * rowHeight;
  ctx.clearRect(0, 0, w, h);
  timelineHoverTargets.length = 0;

  ctx.font = "13px JetBrains";
  timelineRows.forEach((row) => {
    const y = yFor(row);
    ctx.fillStyle = row === "attack" ? "#dce6e9" : colors[row];
    ctx.fillText(row.toUpperCase(), 12, y + 3);
    ctx.strokeStyle = "#1b2a32";
    ctx.lineWidth = 1;
    ctx.beginPath(); ctx.moveTo(plot.left, y); ctx.lineTo(w - plot.right, y); ctx.stroke();
  });

  [0, .5, 1].forEach((ratio) => {
    const x = plot.left + plotWidth * ratio;
    ctx.strokeStyle = "#16242b";
    ctx.beginPath(); ctx.moveTo(x, plot.top); ctx.lineTo(x, h - plot.bottom + 2); ctx.stroke();
  });
  ctx.fillStyle = "#60727c";
  ctx.font = "12px JetBrains";
  ctx.fillText("-60s", plot.left, h - 6);
  ctx.textAlign = "center"; ctx.fillText("-30s", plot.left + plotWidth / 2, h - 6);
  ctx.textAlign = "right"; ctx.fillText("NOW", w - plot.right, h - 6); ctx.textAlign = "left";

  timelineSegments.forEach((segment) => {
    const isActive = segment.end == null
      && segment.interruptedAt == null
      && attack.connected
      && attack.active
      && segment.mode === attack.mode;
    const status = isActive ? "ACTIVE" : segment.end != null ? "COMPLETED" : "INTERRUPTED";
    const visibleEnd = segment.end ?? segment.interruptedAt ?? (isActive ? now : segment.observedUntil);
    if (visibleEnd < cutoff || segment.start > now) return;
    const x1 = xFor(Math.max(segment.start, cutoff));
    const x2 = xFor(Math.min(visibleEnd, now));
    const y = yFor("attack");
    const activeColor = segment.mode === "replay" ? "#e0b45a" : "#ff736f";
    const color = isActive ? activeColor : status === "COMPLETED" ? "#71828a" : "#9a7741";
    ctx.strokeStyle = color;
    ctx.lineWidth = isActive ? 3 : 2;
    ctx.beginPath(); ctx.moveTo(x1, y); ctx.lineTo(x2, y); ctx.stroke();
    ctx.fillStyle = color;
    if (segment.start >= cutoff) { ctx.beginPath(); ctx.arc(x1, y, 7, 0, Math.PI * 2); ctx.fill(); }
    if (segment.end != null) { ctx.beginPath(); ctx.arc(x2, y, 7, 0, Math.PI * 2); ctx.fill(); }
    if (x2 - x1 > 104) {
      ctx.fillStyle = isActive ? activeColor : "#a6b3b8";
      ctx.font = "12px JetBrains";
      ctx.textAlign = "center";
      ctx.fillText(`${segment.mode.toUpperCase()}${segment.rate == null ? "" : ` · ${segment.rate}%`} · ${status}`, (x1 + x2) / 2, y - 5);
      ctx.textAlign = "left";
    }
    timelineHoverTargets.push({ kind: "segment", x1, x2, y, segment, status });
  });

  const lastDeltaLabelRight = {};
  timelineEvents.forEach((event) => {
    if (event.timestamp < cutoff || event.timestamp > now) return;
    const row = event.source === "jetson" ? "attack" : event.type;
    const x = xFor(event.timestamp);
    const y = yFor(row);
    const color = colors[row] || "#67bdd1";
    ctx.strokeStyle = color;
    ctx.fillStyle = color;
    ctx.lineWidth = 2;
    if (row === "attack") {
      ctx.beginPath(); ctx.arc(x, y, 7, 0, Math.PI * 2); ctx.fill();
    } else {
      ctx.beginPath(); ctx.moveTo(x, y - 9); ctx.lineTo(x, y + 9); ctx.stroke();
      ctx.fillRect(x - 4, y - 4, 8, 8);
      if (event.delta > 1) {
        const label = `×${event.delta}`;
        ctx.font = "12px JetBrains";
        const labelWidth = ctx.measureText(label).width;
        let labelX = x + 7;
        if (labelX + labelWidth + 5 > w - plot.right) labelX = x - labelWidth - 8;
        if (labelX > (lastDeltaLabelRight[row] ?? -Infinity) + 7) {
          ctx.fillStyle = "#071014";
          ctx.fillRect(labelX - 3, y - 6, labelWidth + 6, 12);
          ctx.fillStyle = color;
          ctx.fillText(label, labelX, y + 3);
          lastDeltaLabelRight[row] = labelX + labelWidth;
        }
      }
    }
    timelineHoverTargets.push({ kind: "event", x, y, radius: event.delta > 1 ? 16 : 10, event });
  });

  drawAiTimelineEvidence(ctx, { w, h, plot, xFor, yFor, cutoff, now });

  const hasRecent = timelineEvents.some((event) => event.timestamp >= cutoff)
    || timelineSegments.some((segment) => (segment.end ?? segment.interruptedAt ?? segment.observedUntil) >= cutoff);
  $("#timelineEmpty").classList.toggle("hidden", hasRecent);
  const status = $("#timelineStatus");
  status.className = `semantic-key ${attack.connected && rxOnline ? "live" : "warn"}`;
  status.textContent = !attack.connected && !rxOnline ? "SOURCES OFFLINE" : !attack.connected ? "JETSON OFFLINE" : !rxOnline ? "RX OFFLINE" : "RX + JETSON LIVE";

  if (!attack.connected) { ctx.fillStyle = "#e0b45a"; ctx.font = "12px JetBrains"; ctx.fillText("JETSON OFFLINE", plot.left + 8, yFor("attack") - 5); }
  if (!rxOnline) { ctx.fillStyle = "#e0b45a"; ctx.font = "12px JetBrains"; ctx.fillText("RX OFFLINE", plot.left + 8, yFor("sequence") - 5); }
}

function handleTimelineHover(event) {
  const canvas = $("#securityTimeline");
  const tooltip = $("#timelineTooltip");
  const rect = canvas.getBoundingClientRect();
  const x = event.clientX - rect.left;
  const y = event.clientY - rect.top;
  const target = timelineHoverTargets.find((item) => item.kind === "event"
    ? Math.hypot(item.x - x, item.y - y) <= item.radius
    : Math.abs(item.y - y) <= 7 && x >= item.x1 && x <= item.x2);
  if (!target) { tooltip.classList.add("hidden"); return; }
  const lines = timelineTooltipLines(target);
  const title = document.createElement("strong");
  title.textContent = lines[0];
  tooltip.replaceChildren(title, ...lines.slice(1).map((line) => {
    const span = document.createElement("span"); span.textContent = line; return span;
  }));
  tooltip.style.left = `${Math.min(rect.width - 164, Math.max(4, x + 12))}px`;
  tooltip.style.top = `${Math.min(rect.height - 84, Math.max(4, y - 28))}px`;
  tooltip.classList.remove("hidden");
}

function detectorSnapshot(data, rxOnline, security) {
  const now = performance.now();
  return detectorNames.map((name) => {
    const rawTotal = rxOnline ? Number(data[`detector_${name}_total`] || 0) : null;
    const sourceTotal = name === "tag" ? security.gcmAuthFailTotal
      : name === "replay" ? security.replayRejectTotal : rawTotal;
    const previous = previousCounters[name];
    const eventObserved = sourceTotal != null && previous !== undefined && sourceTotal > previous;
    if (eventObserved) recentDetectorEvents[name] = now;
    if (sourceTotal != null) previousCounters[name] = sourceTotal;
    return {
      name,
      eventObserved,
      // detector_sticky is deliberately not a CURRENT STATE source: the PL
      // register preserves historical bits. A current alert is a real newly
      // observed cumulative-counter increment held briefly for human viewing.
      alert: rxOnline && Number.isFinite(recentDetectorEvents[name])
        && now - recentDetectorEvents[name] <= DETECTOR_ALERT_HOLD_MS,
      total: sourceTotal,
    };
  });
}

function updateDetectors(data, rxOnline, security) {
  const values = detectorSnapshot(data, rxOnline, security);
  const detectorCount = (name, total) => {
    if (total == null) return "—";
    if (name === "tag") return `FAIL ${formatInteger(total)}`;
    if (name === "replay") return `REJECT ${formatInteger(total)}`;
    return `ERROR ${formatInteger(total)}`;
  };
  values.forEach(({ name, alert, total, eventObserved }) => {
    $$(`[data-detector="${name}"]`).forEach((row) => {
      row.classList.toggle("alert", alert);
      const status = row.querySelector("strong");
      const count = row.querySelector("span");
      if (status) status.textContent = !rxOnline ? "대기" : alert ? "경고" : "정상";
      if (count) count.textContent = detectorCount(name, total);
    });
    if (eventObserved) {
      if (name === "tag") {
        recentReject.tag = performance.now();
        showSecurityOverlay("GCM AUTH FAIL", "FRAME BLOCKED");
      } else if (name === "replay") {
        recentReject.replay = performance.now();
        showSecurityOverlay("REPLAY BLOCKED", "OLD FRAME REJECTED");
      }
    }
  });

  const list = $("#analysisDetectorList");
  list.replaceChildren(...values.map(({ name, alert, total }) => {
    const row = document.createElement("div");
    row.className = alert ? "alert" : "";
    row.dataset.detector = name;
    const label = document.createElement("b");
    const status = document.createElement("strong");
    const count = document.createElement("span");
    label.textContent = name.toUpperCase();
    status.textContent = !rxOnline ? "대기" : alert ? "경고" : "정상";
    count.textContent = detectorCount(name, total);
    row.append(label, status, count);
    return row;
  }));
  return values;
}

function latestEvent(state) {
  return Array.isArray(state.events) && state.events.length ? state.events[0] : null;
}

function eventFields(state, data) {
  const event = latestEvent(state);
  const type = String(valueFrom(event, "event_type") || "WAITING").toUpperCase();
  const outcome = /GCM_AUTH_FAIL/.test(type) ? "인증 실패 · DROP"
    : /REPLAY_REJECT/.test(type) ? "재전송 거부 · DROP"
      : event ? "RX 기록됨" : "—";
  return {
    event,
    type,
    frame: valueFrom(event, "frame_id") ?? valueFrom(data, "last_error_frame", "detector_last_frame16") ?? null,
    packet: valueFrom(event, "packet_id", "packet_index") ?? valueFrom(data, "last_error_packet", "detector_last_packet") ?? null,
    session: valueFrom(event, "session_id") ?? valueFrom(data, "last_error_session", "detector_last_session") ?? null,
    outcome,
  };
}

function setOccPhase(phase) {
  occPhase = phase;
  $$(".occ-lock").forEach((layer) => {
    layer.classList.remove("locked", "pass", "fail", "opening", "unlocked");
    layer.classList.add(phase);
  });
  document.body.classList.toggle("occ-locked", phase !== "unlocked");
}

function clearOccTimers() {
  clearTimeout(occPassTimer);
  clearTimeout(occDoorTimer);
}

function beginOccUnlock() {
  clearOccTimers();
  setOccPhase("pass");
  occPassTimer = setTimeout(() => {
    setOccPhase("opening");
    occDoorTimer = setTimeout(() => setOccPhase("unlocked"), OCC_DOOR_MS);
  }, OCC_PASS_HOLD_MS);
}

function renderOcc(occ = {}) {
  const locked = occ.locked !== false;
  const authorizedUnlock = !locked && occ.verdict === "PASS"
    && (occ.unlockSource === "QWE" || (occ.unlockSource === "OCC" && Number.isFinite(Number(occ.lastEventAt))));
  $("#occConnection").textContent = occ.connected ? `${occ.port || "UART"} CONNECTED` : "UART WAIT";
  $("#occCredential").textContent = occ.credential || "----";
  $("#occVerdict").textContent = occ.verdict || "WAITING";
  $("#occTitle").textContent = occ.verdict === "PASS" ? "PASS · ACCESS GRANTED"
    : occ.verdict === "FAIL" ? "FAIL · ACCESS DENIED" : "OCC PASSWORD AUTHENTICATION";
  $("#occDetail").textContent = occ.unlockSource === "QWE" ? "DEVELOPMENT MASTER UNLOCK"
    : occ.connected ? "RX BOARD IS THE CREDENTIAL AUTHORITY" : "WAITING FOR RX BOARD VERDICT";
  const interfaceLocked = locked || !authorizedUnlock;
  if (interfaceLocked) {
    clearOccTimers();
    setOccPhase(occ.verdict === "FAIL" ? "fail" : "locked");
  } else if (occWasLocked || occPhase === "locked" || occPhase === "fail") {
    beginOccUnlock();
  }
  occWasLocked = interfaceLocked;
}

function renderLive(state, data, attack, rxOnline, detectors) {
  const event = eventFields(state, data);
  const sessionId = valueFrom(data, "session_id", "active_session_id");
  const sessionMode = rxOnline ? String(valueFrom(data, "session_mode", "security_mode") || "SECURE").toUpperCase() : "WAITING";
  const valid = finiteValue(data, "valid_frame_rate");
  const attempt = finiteValue(data, "frame_attempt_rate");
  const activeAlerts = detectors.some((item) => item.alert);
  const presentation = attackPresentation(attack);
  const hasAttackResult = attack.connected && attack.mode !== "none";

  $("#attackPanelTitle").textContent = presentation.label;
  $("#attackMode").textContent = attack.connected ? attack.name : "OFFLINE";
  $("#attackActivity").textContent = presentation.state === "none" ? "NO ATTACK" : presentation.label;
  $("#attackCaption").textContent = attack.active ? "LIVE JETSON ATTACK"
    : attack.mode !== "none" ? "LAST ATTACK RESULT RETAINED" : attack.connected ? "NO ATTACK HISTORY" : "JETSON DISCONNECTED";
  $("#attackRate").textContent = !hasAttackResult || attack.rate == null ? "—" : `${attack.rate} %`;
  $("#attackCountLabel").textContent = attack.mode === "tamper" ? "MODIFIED" : attack.mode === "replay" ? "INJECTED" : "COUNT";
  $("#attackCount").textContent = !hasAttackResult || attack.count == null ? "—" : attack.count.toLocaleString();
  $("#attackRuntime").textContent = hasAttackResult ? formatRuntime(attack.runtimeMs) : "—";
  $("#attackTarget").textContent = !hasAttackResult || attack.targetFrame == null ? "—" : attack.targetPacket == null
    ? `FRAME ${attack.targetFrame}` : `F ${attack.targetFrame} / P ${attack.targetPacket}`;
  $(".attack-summary").classList.toggle("is-active", attack.active);
  $(".attack-summary").classList.toggle("is-history", presentation.state === "last");
  setChip($("#attackBadge"), presentation.state === "offline" ? "warn" : presentation.state === "active" ? "error" : presentation.state === "last" ? "history" : "live", presentation.badge);

  $("#sessionState").textContent = sessionMode;
  $("#sessionId").textContent = sessionId == null ? "—" : String(sessionId);
  $("#validFps").textContent = formatNumber(valid, 2, " FPS");
  $("#attemptFps").textContent = `ATTEMPT ${formatNumber(attempt, 2)}`;
  setChip($("#securityVerdict"), !rxOnline ? "warn" : activeAlerts ? "error" : "live", !rxOnline ? "WAITING" : activeAlerts ? "ALERT" : "PROTECTED");

  $("#eventType").textContent = rxOnline ? event.type : "WAITING";
  $("#eventFrame").textContent = rxOnline && event.frame != null ? event.frame : "—";
  $("#eventPacket").textContent = rxOnline && event.packet != null ? event.packet : "—";
  $("#eventSession").textContent = rxOnline && event.session != null ? event.session : "—";
  $("#eventOutcome").textContent = rxOnline ? event.outcome : "—";
}

function appendHistory(data, rxOnline, security) {
  const point = {
    timestamp: Date.now(),
    valid: rxOnline ? finiteValue(data, "valid_frame_rate") : null,
    attempt: rxOnline ? finiteValue(data, "frame_attempt_rate") : null,
    drop: rxOnline && finiteValue(data, "frame_drop_ratio") != null ? finiteValue(data, "frame_drop_ratio") * 100 : null,
    jitter: rxOnline ? finiteValue(data, "frame_jitter_ms") : null,
    // Same canonical backend state as the two KPI cards: RX's actual one-second
    // rate when supplied, otherwise the sampled one-second integer count.
    auth: rxOnline ? security.gcmAuthFailRate1s : null,
    replay: rxOnline ? security.replayRejectRate1s : null,
  };
  history.push(point);
  const cutoff = point.timestamp - 30000;
  while (history.length && history[0].timestamp < cutoff) history.shift();
}

function drawChart(canvas, series, options = {}) {
  const rect = canvas.getBoundingClientRect();
  if (rect.width < 4 || rect.height < 4) return;
  const dpr = Math.max(1, window.devicePixelRatio || 1);
  const width = Math.floor(rect.width * dpr);
  const height = Math.floor(rect.height * dpr);
  if (canvas.width !== width || canvas.height !== height) { canvas.width = width; canvas.height = height; }
  const ctx = canvas.getContext("2d");
  ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
  const w = rect.width;
  const h = rect.height;
  const pad = { left: options.leftPad || 52, right: 18, top: 18, bottom: 31 };
  ctx.clearRect(0, 0, w, h);
  ctx.strokeStyle = "#1b2a32";
  ctx.lineWidth = 1;
  ctx.fillStyle = "#60727c";
  ctx.font = "13px JetBrains";
  for (let i = 0; i <= 3; i += 1) {
    const y = pad.top + ((h - pad.top - pad.bottom) * i / 3);
    ctx.beginPath(); ctx.moveTo(pad.left, y); ctx.lineTo(w - pad.right, y); ctx.stroke();
  }
  ctx.fillText("-30s", pad.left, h - 7);
  ctx.textAlign = "right"; ctx.fillText("NOW", w - pad.right, h - 7); ctx.textAlign = "left";
  drawAiGraphEvidence(ctx, canvas, pad, w, h);
  const values = series.flatMap((item) => history.map((point) => point[item.key])).filter(Number.isFinite);
  if (!values.length) {
    ctx.fillStyle = "#65757d"; ctx.textAlign = "center"; ctx.fillText("WAITING FOR LIVE RX TELEMETRY", w / 2, h / 2); ctx.textAlign = "left"; return;
  }
  const min = options.min != null ? options.min : Math.min(...values);
  const maxRaw = options.max != null ? options.max : Math.max(...values);
  const span = Math.max(options.minSpan || .01, maxRaw - min);
  const max = min + span;
  ctx.fillStyle = "#60727c";
  const axisSuffix = options.axisSuffix || "";
  ctx.fillText(`${max.toFixed(options.axisDigits ?? 1)}${axisSuffix}`, 5, pad.top + 4);
  ctx.fillText(`${min.toFixed(options.axisDigits ?? 1)}${axisSuffix}`, 5, h - pad.bottom);
  const start = Date.now() - 30000;
  for (const item of series) {
    ctx.strokeStyle = item.color;
    ctx.lineWidth = 1.5;
    ctx.beginPath();
    let drawing = false;
    history.forEach((point) => {
      const value = point[item.key];
      if (!Number.isFinite(value)) { drawing = false; return; }
      const x = pad.left + Math.max(0, Math.min(1, (point.timestamp - start) / 30000)) * (w - pad.left - pad.right);
      const y = pad.top + (1 - (value - min) / (max - min)) * (h - pad.top - pad.bottom);
      if (!drawing) { ctx.moveTo(x, y); drawing = true; } else ctx.lineTo(x, y);
    });
    ctx.stroke();
  }
  drawAiGraphFocusLines(ctx, canvas, series, pad, w, h, min, max, start);
}

function renderAnalysis(state, data, attack, rxOnline, event, security) {
  const valid = rxOnline ? finiteValue(data, "valid_frame_rate") : null;
  const attempt = rxOnline ? finiteValue(data, "frame_attempt_rate") : null;
  const drop = rxOnline && finiteValue(data, "frame_drop_ratio") != null ? finiteValue(data, "frame_drop_ratio") * 100 : null;
  const presentation = attackPresentation(attack);
  const hasAttackResult = attack.connected && attack.mode !== "none";
  $("#kpiAttackLabel").textContent = presentation.label;
  $("#kpiAttack").textContent = hasAttackResult ? `${attack.name}${attack.rate == null ? "" : ` · ${attack.rate}%`}` : attack.connected ? "NONE" : "OFFLINE";
  $("#kpiAttackDetail").textContent = hasAttackResult
    ? `${attack.mode === "tamper" ? "MODIFIED" : "INJECTED"} ${formatInteger(attack.count)} · ${formatRuntime(attack.runtimeMs)}`
    : attack.connected ? "NO ATTACK HISTORY" : "JETSON DISCONNECTED";
  $("#kpiAttack").closest(".kpi").classList.toggle("alert", attack.active);
  $("#kpiValidFps").textContent = formatNumber(valid, 2);
  $("#kpiAttemptFps").textContent = `ATTEMPT ${formatNumber(attempt, 2)}`;
  $("#kpiFrameDrop").textContent = formatNumber(drop, 2, " %");
  $("#kpiAuthRejectCount").textContent = security.gcmAuthFailLast1s == null
    ? "—" : `${formatInteger(security.gcmAuthFailLast1s)}건`;
  $("#kpiAuthRejectDetail").textContent = `누적 ${formatInteger(security.gcmAuthFailTotal)}건`;
  $("#kpiAuthRejectRate").textContent = `${formatNumber(security.gcmAuthFailRate1s, 2)} 건/s`;
  $("#kpiReplayReject").textContent = security.replayRejectLast1s == null
    ? "—" : `${formatInteger(security.replayRejectLast1s)}건`;
  $("#kpiReplayTotal").textContent = `누적 ${formatInteger(security.replayRejectTotal)}건`;
  $("#kpiReplayRate").textContent = `${formatNumber(security.replayRejectRate1s, 2)} 건/s`;

  $("#healthNetwork").textContent = rxOnline ? formatInteger(security.networkLossTotal) : "—";
  $("#healthQueue").textContent = rxOnline ? formatInteger(security.queueOverrunTotal) : "—";
  $("#healthStale").textContent = rxOnline ? formatInteger(security.staleDropTotal) : "—";
  $("#healthStatus").textContent = rxOnline ? formatInteger(security.statusFailureTotal) : "—";
  $("#healthProcessed").textContent = rxOnline ? formatInteger(security.processedTotal) : "—";

  const events = Array.isArray(state.events) ? state.events : [];
  const matched = attack.targetFrame == null ? null : events.find((item) => Number(item.frame_id) === Number(attack.targetFrame));
  $("#corrAttackMode").textContent = attack.mode === "none" ? "—" : attack.name;
  $("#corrAttackFrame").textContent = attack.targetFrame ?? "—";
  $("#corrAttackPacket").textContent = attack.targetPacket ?? "—";
  $("#corrEventType").textContent = rxOnline ? event.type : "—";
  $("#corrEventFrame").textContent = rxOnline ? event.frame ?? "—" : "—";
  $("#corrEventPacket").textContent = rxOnline ? event.packet ?? "—" : "—";
  const correlation = $("#correlationText");
  correlation.className = "";
  const currentStatus = attack.targetFrame == null || !rxOnline ? "pending"
    : matched && (attack.targetPacket == null || valueFrom(matched, "packet_id", "packet_index") == null
      || Number(valueFrom(matched, "packet_id", "packet_index")) === Number(attack.targetPacket)) ? "match" : "mismatch";
  const labels = { match: "일치", mismatch: "불일치", pending: "확인 중" };
  const label = labels[currentStatus] || "대기";
  correlation.textContent = label;
  correlation.classList.add(currentStatus === "match" ? "match" : currentStatus === "mismatch" ? "mismatch" : "pending");

  if ($("#analysisPage").classList.contains("active")) {
    drawChart($("#fpsChart"), [{ key: "attempt", color: "#67bdd1" }, { key: "valid", color: "#70d36c" }], { minSpan: 1 });
    drawChart($("#dropChart"), [{ key: "drop", color: "#e0b45a" }], { min: 0, minSpan: 1 });
    drawChart($("#jitterChart"), [{ key: "jitter", color: "#67bdd1" }], { min: 0, minSpan: .1, axisDigits: 2 });
    drawChart($("#rejectChart"), [{ key: "auth", color: "#ff736f" }, { key: "replay", color: "#e0b45a" }], { min: 0, minSpan: 1, axisSuffix: "/s", leftPad: 52 });
    drawSecurityTimeline(attack, rxOnline);
  }
}

function activeAiEvidence() {
  return aiFocusTask && aiVisibleEvidence.length ? aiVisibleEvidence : [];
}

function drawAiGraphEvidence(ctx, canvas, pad, w, h) {
  if (!activeAiEvidence().some((item) => item.charts?.includes(canvas.id)) || !aiEvidenceWindow) return;
  const start = Date.now() - 30000;
  const plotWidth = w - pad.left - pad.right;
  const xFor = (timestamp) => pad.left + Math.max(0, Math.min(1, (timestamp - start) / 30000)) * plotWidth;
  const x1 = xFor(aiEvidenceWindow.start);
  const x2 = Math.max(x1 + 3, xFor(aiEvidenceWindow.end));
  ctx.save();
  ctx.fillStyle = "rgba(183, 104, 255, .20)";
  ctx.strokeStyle = "#B768FF";
  ctx.lineWidth = 2;
  ctx.fillRect(x1, pad.top, x2 - x1, h - pad.top - pad.bottom);
  ctx.strokeRect(x1 + .5, pad.top + .5, Math.max(1, x2 - x1 - 1), h - pad.top - pad.bottom - 1);
  ctx.fillStyle = "#F2E5FF";
  ctx.font = "700 13px JetBrains";
  ctx.fillText("AI 분석 구간", Math.min(x1 + 6, w - pad.right - 92), pad.top + 15);
  ctx.restore();
}

function drawAiGraphFocusLines(ctx, canvas, series, pad, w, h, min, max, start) {
  if (!activeAiEvidence().some((item) => item.charts?.includes(canvas.id)) || !aiEvidenceWindow) return;
  const plotWidth = w - pad.left - pad.right;
  ctx.save();
  ctx.strokeStyle = "#B768FF";
  ctx.shadowColor = "rgba(183, 104, 255, .75)";
  ctx.shadowBlur = 8;
  ctx.lineWidth = 3.5;
  series.forEach((item) => {
    ctx.beginPath();
    let drawing = false;
    history.forEach((point) => {
      const value = point[item.key];
      if (!Number.isFinite(value) || point.timestamp < aiEvidenceWindow.start || point.timestamp > aiEvidenceWindow.end) { drawing = false; return; }
      const x = pad.left + Math.max(0, Math.min(1, (point.timestamp - start) / 30000)) * plotWidth;
      const y = pad.top + (1 - (value - min) / (max - min)) * (h - pad.top - pad.bottom);
      if (!drawing) { ctx.moveTo(x, y); drawing = true; } else ctx.lineTo(x, y);
    });
    ctx.stroke();
  });
  ctx.restore();
}

function drawAiTimelineEvidence(ctx, geometry) {
  const evidence = activeAiEvidence();
  const interval = (evidence.find((item) => item.timelineFocus?.relatedEventIds?.length)
    || evidence.find((item) => item.timelineFocus))?.timelineFocus;
  if (interval) {
    const visibleEnd = Math.min(interval.endTime ?? geometry.now, geometry.now);
    const x1 = geometry.xFor(Math.max(interval.startTime, geometry.cutoff));
    const x2 = geometry.xFor(visibleEnd);
    const y = geometry.yFor("attack");
    ctx.save();
    ctx.strokeStyle = "#B768FF";
    ctx.fillStyle = "#B768FF";
    ctx.shadowColor = "rgba(183, 104, 255, .85)";
    ctx.shadowBlur = 12;
    ctx.lineWidth = 5;
    ctx.beginPath(); ctx.moveTo(x1, y); ctx.lineTo(x2, y); ctx.stroke();
    ctx.beginPath(); ctx.arc(x1, y, 9, 0, Math.PI * 2); ctx.fill();
    if (interval.active) { ctx.beginPath(); ctx.arc(x2, y, 8, 0, Math.PI * 2); ctx.stroke(); }
    ctx.fillStyle = "#F2E5FF";
    ctx.font = "700 13px JetBrains";
    ctx.fillText("AI 분석 근거", Math.min(x1 + 8, geometry.w - geometry.plot.right - 96), y - 11);
    const related = new Set(interval.relatedEventIds || []);
    timelineEvents.forEach((event) => {
      if (!related.has(event.id) || event.timestamp < geometry.cutoff || event.timestamp > geometry.now) return;
      const x = geometry.xFor(event.timestamp);
      const eventY = geometry.yFor(event.type);
      ctx.lineWidth = 3;
      ctx.beginPath(); ctx.arc(x, eventY, 12, 0, Math.PI * 2); ctx.stroke();
    });
    ctx.restore();
    return;
  }
  const markerEvidence = evidence.find((item) => item.timeline);
  if (!markerEvidence) return;
  const marker = markerEvidence.timeline;
  const matched = [...timelineEvents].reverse().find((event) => (
    (marker.id == null || Number(event.id) === Number(marker.id))
    && (marker.type == null || event.type === marker.type)
    && (marker.frameId == null || event.frameId == null || Number(event.frameId) === Number(marker.frameId))
    && (marker.packetId == null || event.packetId == null || Number(event.packetId) === Number(marker.packetId))
  ));
  if (!matched || matched.timestamp < geometry.cutoff || matched.timestamp > geometry.now) return;
  const x = geometry.xFor(matched.timestamp);
  const y = geometry.yFor(matched.type);
  ctx.save();
  ctx.strokeStyle = "#B768FF";
  ctx.fillStyle = "rgba(183, 104, 255, .24)";
  ctx.shadowColor = "rgba(183, 104, 255, .8)";
  ctx.shadowBlur = 12;
  ctx.lineWidth = 3;
  ctx.setLineDash([3, 3]);
  ctx.beginPath(); ctx.moveTo(x, geometry.plot.top); ctx.lineTo(x, geometry.h - geometry.plot.bottom); ctx.stroke();
  ctx.setLineDash([]);
  ctx.beginPath(); ctx.arc(x, y, 13, 0, Math.PI * 2); ctx.fill(); ctx.stroke();
  ctx.fillStyle = "#F2E5FF";
  ctx.font = "700 13px JetBrains";
  ctx.fillText("AI 분석 근거", Math.min(x + 10, geometry.w - geometry.plot.right - 96), geometry.plot.top + 15);
  ctx.restore();
}

function redrawAnalysisEvidence() {
  if (!latestState || !$("#analysisPage").classList.contains("active")) return;
  const data = latestState.telemetry || {};
  const attack = latestAttack || normalizeAttack(latestState);
  const rxOnline = Boolean(latestState.online && latestState.telemetry);
  drawChart($("#fpsChart"), [{ key: "attempt", color: "#67bdd1" }, { key: "valid", color: "#70d36c" }], { minSpan: 1 });
  drawChart($("#dropChart"), [{ key: "drop", color: "#e0b45a" }], { min: 0, minSpan: 1 });
  drawChart($("#jitterChart"), [{ key: "jitter", color: "#67bdd1" }], { min: 0, minSpan: .1, axisDigits: 2 });
  drawChart($("#rejectChart"), [{ key: "auth", color: "#ff736f" }, { key: "replay", color: "#e0b45a" }], { min: 0, minSpan: 1, axisSuffix: "/s", leftPad: 52 });
  drawSecurityTimeline(attack, rxOnline);
}

function renderState(state) {
  latestState = state;
  const data = state.telemetry || {};
  const rxOnline = Boolean(state.online && state.telemetry);
  const security = securityState(state, data, rxOnline);
  const attack = normalizeAttack(state);
  latestAttack = attack;
  latestCanonicalState = buildCanonicalSystemState(state);
  if (sessionPreviousRxOnline !== rxOnline) {
    pushSessionEvent({ category: "rx", source: "RX", type: rxOnline ? "RX_CONNECTED" : "RX_DISCONNECTED" });
    sessionPreviousRxOnline = rxOnline;
  }
  if (sessionPreviousJetsonOnline !== attack.connected) {
    pushSessionEvent({ category: "system", source: "JETSON", type: attack.connected ? "JETSON_CONNECTED" : "JETSON_DISCONNECTED" });
    sessionPreviousJetsonOnline = attack.connected;
  }
  updateSecurityTimeline(state, data, attack, rxOnline, security);
  if (!rxOnline && rxWasOnline) {
    detectorNames.forEach((name) => {
      delete previousCounters[name];
      delete recentDetectorEvents[name];
    });
  }
  const detectors = updateDetectors(data, rxOnline, security);
  rxWasOnline = rxOnline;
  const event = eventFields(state, data);
  setChip($("#rxStatus"), rxOnline ? "live" : "warn", rxOnline ? "RX LIVE" : "RX WAIT");
  setChip($("#jetsonStatus"), attack.connected ? "live" : "warn", attack.connected ? "JETSON LIVE" : "JETSON WAIT");
  const presentation = attackPresentation(attack);
  const globalText = presentation.state === "active" ? `${attack.name} ACTIVE${attack.rate == null ? "" : ` · ${attack.rate}%`}`
    : presentation.state === "last" ? `LAST ${attack.name}${attack.rate == null ? "" : ` · ${attack.rate}%`}`
      : presentation.state === "offline" ? "JETSON OFFLINE" : "ATTACK NONE";
  setChip($("#globalAttack"), presentation.state === "active" ? "active" : presentation.state === "last" ? "history" : presentation.state === "offline" ? "warn" : "", globalText);
  renderOcc(state.occ || {});
  renderLive(state, data, attack, rxOnline, detectors);
  appendHistory(data, rxOnline, security);
  renderAnalysis(state, data, attack, rxOnline, event, security);
}

async function pollState() {
  try {
    const response = await fetch("/api/state", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    renderState(await response.json());
  } catch (error) {
    setChip($("#rxStatus"), "error", "BACKEND ERROR");
    setChip($("#jetsonStatus"), "error", "JETSON ERROR");
  }
}

function switchPage(page) {
  $$(".dashboard-page").forEach((section) => section.classList.toggle("active", section.id === `${page}Page`));
  $$(".page-tab").forEach((button) => button.classList.toggle("active", button.dataset.page === page));
  if (page === "analysis" && latestState) renderState(latestState);
}

async function submitOcc(action, keys) {
  const response = await fetch(`/api/occ/${action}`, {
    method: "POST", headers: { "Content-Type": "application/json" }, body: JSON.stringify({ keys }),
  });
  if (!response.ok) throw new Error(`OCC ${action} failed`);
  renderOcc(await response.json());
}

function aiContext(question = "") {
  const state = latestState || {};
  const pastMinutes = /(?:아까|과거|전)\s*(\d+)?\s*분|(?:\d+)\s*분\s*전/.test(String(question))
    ? Number((String(question).match(/(\d+)\s*분/) || [])[1] || 10) : 1;
  const snapshot = buildCanonicalSystemState(state);
  latestCanonicalState = snapshot;
  return {
    ...snapshot,
    pc: {
      page: $("#analysisPage").classList.contains("active") ? "security-analysis" : "live-receiver",
      occ: state.occ || null,
    },
    sources: {
      rxSource: state.source || state.serial_port || null,
      rxEvents: Array.isArray(state.events) ? state.events.slice(0, 12) : [],
    },
    sessionEvents: getSessionEvents(Date.now() - pastMinutes * 60_000).slice(-80),
  };
}

function taskFromQuestion(text) {
  const question = String(text || "").toLowerCase();
  if (/(공격.*(영향|때문|이후|fps|성능|드롭|drop)|(?:tamper|replay).*(영향|때문|fps|성능|드롭|drop))/.test(question)) return "attack-impact";
  if (/(지금|현재|어떤).*(공격|tamper|replay)|(공격|tamper|replay).*(상태|상황|진행)/.test(question)) return "attack";
  if (/관계|연관|상관|공격|correlation/.test(question)) return "correlation";
  if (/타임라인|timeline|최근\s*30\s*초/.test(question)) return "timeline";
  if (/fps|성능|저하|지연|jitter|drop|프레임/.test(question)) return "performance";
  if (/보안|이벤트|인증|리플레이|위험|risk/.test(question)) return "risk";
  return "summary";
}

const QUICK_QUESTIONS = {
  summary: { path: "/api/ai/analyze", body: { task: "summary" }, evidenceTask: "summary" },
  correlation: { path: "/api/ai/analyze", body: { task: "correlation" }, evidenceTask: "correlation" },
  performance: { path: "/api/ai/chat", body: { message: "현재 성능 저하 원인을 분석해줘." }, evidenceTask: "performance" },
  risk: { path: "/api/ai/analyze", body: { task: "risk" }, evidenceTask: "risk" },
  timeline: { path: "/api/ai/chat", body: { message: "최근 30초 Timeline을 요약해줘." }, evidenceTask: "timeline" },
};

function evidenceElement(target) {
  const classTargets = {
    videoPanel: ".video-panel",
    correlationPanel: ".correlation-panel",
    eventPanel: ".event-panel",
    securityTimeline: ".timeline-panel",
    tagDetector: '#analysisDetectorList [data-detector="tag"]',
    replayDetector: '#analysisDetectorList [data-detector="replay"]',
  };
  const element = classTargets[target] ? $(classTargets[target]) : document.getElementById(target);
  if (!element) return null;
  if (element.matches("canvas")) return element.closest(".panel");
  if (element.matches(".kpi strong")) return element.closest(".kpi");
  if (target === "analysisDetectorList") return element.closest(".panel");
  return element;
}

function evidenceElements(items = aiVisibleEvidence) {
  return [...new Set(items.flatMap((item) => item.targets || [])
    .map(evidenceElement).filter(Boolean))];
}

function attackTimelineFocus(attack, now = Date.now()) {
  if (!attack?.connected || attack.mode === "none") return null;
  const segment = [...timelineSegments].reverse().find((item) => item.mode === attack.mode
    && (item.end == null || item.end >= now - TIMELINE_WINDOW_MS));
  if (!segment) return null;
  const end = segment.end ?? segment.interruptedAt ?? (attack.active ? now : segment.observedUntil);
  const start = Math.max(segment.start, now - TIMELINE_WINDOW_MS);
  if (!Number.isFinite(start) || !Number.isFinite(end) || end < now - TIMELINE_WINDOW_MS) return null;
  const detector = attack.mode === "tamper" ? "tag" : attack.mode === "replay" ? "replay" : null;
  const relatedEventIds = detector == null ? [] : timelineEvents
    .filter((event) => event.type === detector && event.timestamp >= start && event.timestamp <= Math.min(end, now))
    .map((event) => event.id);
  return {
    segmentId: segment.id, attackType: attack.mode, ratePercent: attack.rate,
    startTime: start, endTime: attack.active ? null : end, active: attack.active,
    detector, relatedEventIds,
  };
}

function currentEvidence(task, snapshotState = latestState, analysisAt = Date.now()) {
  const state = snapshotState;
  if (!state) return [];
  const data = state.telemetry || {};
  const rxOnline = Boolean(state.online && state.telemetry);
  const security = securityState(state, data, rxOnline);
  const observedAt = analysisAt;
  const evidence = [];
  const add = (text, fields) => evidence.push({ task, priority: "secondary", text, observedAt, ...fields });
  const valid = rxOnline ? finiteValue(data, "valid_frame_rate") : null;
  const attempt = rxOnline ? finiteValue(data, "frame_attempt_rate") : null;
  const drop = rxOnline && finiteValue(data, "frame_drop_ratio") != null
    ? finiteValue(data, "frame_drop_ratio") * 100 : null;
  const jitter = rxOnline ? finiteValue(data, "frame_jitter_ms") : null;
  const lastAuthEvent = [...(Array.isArray(state.events) ? state.events : [])]
    .find((event) => detectorTypeFromEvent(event) === "tag");
  const authTimeline = lastAuthEvent && [...timelineEvents].reverse().find((item) => item.type === "tag"
    && (valueFrom(lastAuthEvent, "event_seq") == null || item.frameId == null
      || Number(item.frameId) === Number(valueFrom(lastAuthEvent, "frame_id"))));
  const addAuthEvidence = () => {
    if (security.gcmAuthFailTotal == null && security.gcmAuthFailLast1s == null) return;
    const recent = security.gcmAuthFailLast1s == null ? "최근 1초 데이터 없음"
      : `최근 1초 ${formatInteger(security.gcmAuthFailLast1s)}건`;
    add(`GCM AUTH FAIL ${recent} · 누적 ${formatInteger(security.gcmAuthFailTotal)}건 · ${formatNumber(security.gcmAuthFailRate1s, 2)} 건/s`, {
      targets: ["kpiAuthRejectCard"], charts: ["rejectChart"],
      priority: Number(security.gcmAuthFailLast1s) > 0 ? "primary" : "secondary",
    });
    add(`TAG detector · FAIL ${formatInteger(security.gcmAuthFailTotal)}`, {
      targets: ["tagDetector"], charts: [],
    });
    if (lastAuthEvent) {
      const frame = valueFrom(lastAuthEvent, "frame_id");
      const packet = valueFrom(lastAuthEvent, "packet_id", "packet_index");
      add(frame == null ? "최근 GCM_AUTH_FAIL 이벤트" : `최근 GCM_AUTH_FAIL · FRAME ${frame}`, {
        targets: ["eventPanel"], charts: [],
        ...(authTimeline && {
          observedAt: authTimeline.timestamp,
          timeline: { id: authTimeline.id, type: "tag", frameId: frame, packetId: packet },
        }),
      });
    }
  };

  const addReplayEvidence = () => {
    if (security.replayRejectTotal == null && security.replayRejectLast1s == null) return;
    const recent = security.replayRejectLast1s == null ? "최근 1초 데이터 없음"
      : `최근 1초 ${formatInteger(security.replayRejectLast1s)}건`;
    add(`REPLAY REJECT ${recent} · 누적 ${formatInteger(security.replayRejectTotal)}건 · ${formatNumber(security.replayRejectRate1s, 2)} 건/s`, {
      targets: ["kpiReplayReject"], charts: ["rejectChart"],
      priority: Number(security.replayRejectLast1s) > 0 ? "primary" : "secondary",
    });
  };

  if (task === "summary") {
    const videoState = buildCanonicalSystemState(state).video;
    if (videoState?.status !== "UNKNOWN") add(`VIDEO ${videoState.status}`, {
      targets: ["videoPanel"], charts: [], priority: "secondary",
    });
    const attack = normalizeAttack(state);
    if (attack.connected && attack.mode !== "none") add(`현재 공격 ${attack.name}${attack.rate == null ? "" : ` · ${attack.rate}%`}${attack.active ? " ACTIVE" : ""}`, {
      targets: ["kpiAttack"], charts: [], priority: "primary",
    });
  }

  if ((task === "summary" || task === "performance") && (Number.isFinite(valid) || Number.isFinite(attempt))) {
    const parts = [];
    if (Number.isFinite(valid)) parts.push("VALID FPS " + formatNumber(valid, 2));
    if (Number.isFinite(attempt)) parts.push("ATTEMPT FPS " + formatNumber(attempt, 2));
    add("현재 RX 텔레메트리: " + parts.join(" · "), {
      targets: ["kpiValidFps"],
      charts: ["fpsChart"],
      priority: "primary",
    });
  }

  if ((task === "summary" || task === "performance") && Number.isFinite(drop)) {
    add("현재 FRAME DROP " + formatNumber(drop, 2, " %"), {
      targets: ["kpiFrameDrop"],
      charts: ["dropChart"],
      priority: "primary",
    });
  }

  if ((task === "summary" || task === "performance") && Number.isFinite(jitter)) {
    add("현재 FRAME JITTER " + formatNumber(jitter, 2, " ms"), {
      targets: [],
      charts: ["jitterChart"],
    });
  }

  if (task === "risk" || task === "summary") {
    addAuthEvidence();
    addReplayEvidence();
  }

  if (task === "attack" || task === "attack-impact") {
    const attack = latestAttack || normalizeAttack(state);
    const focus = attackTimelineFocus(attack);
    const related = focus?.relatedEventIds.length || 0;
    const interval = focus && `${timelineTime(focus.startTime)} ~ ${focus.active ? "NOW" : timelineTime(focus.endTime)}`;
    if (attack.mode !== "none") {
      add(`현재 공격 ${attack.name}${attack.rate == null ? "" : ` · ${attack.rate}%`}`, {
        targets: ["kpiAttack"], charts: [],
      });
    }
    if (focus) {
      add(`ATTACK Timeline · ${attack.name}${attack.rate == null ? "" : ` ${attack.rate}%`} · ${interval}`, {
        targets: [], charts: [], timelineFocus: { ...focus, relatedEventIds: [] }, observedAt: focus.startTime,
      });
      if (related) {
        const detectorLabel = focus.detector === "tag" ? "GCM_AUTH_FAIL / TAG" : "REPLAY_REJECT / REPLAY";
        const changed = (key) => {
          const values = history.filter((point) => point.timestamp >= focus.startTime
            && point.timestamp <= (focus.endTime ?? Date.now()))
            .map((point) => point[key]).filter(Number.isFinite);
          return values.length > 1 && Math.max(...values) !== Math.min(...values);
        };
        const charts = [];
        if (changed("valid") || changed("attempt")) charts.push("fpsChart");
        if (changed("drop")) charts.push("dropChart");
        if (changed(focus.detector === "tag" ? "auth" : "replay")) charts.push("rejectChart");
        if (focus.detector === "replay" && changed("jitter")) charts.push("jitterChart");
        add(`${detectorLabel} · 분석 구간 내 ${related}개 marker`, {
          targets: [focus.detector === "tag" ? "tagDetector" : "replayDetector"], charts,
          timelineFocus: focus, observedAt: focus.startTime,
        });
      }
    }
  }

  if (task === "correlation") {
    const attack = latestAttack || normalizeAttack(state);
    const events = Array.isArray(state.events) ? state.events : [];
    const matched = attack.targetFrame == null ? null : events.find((event) => Number(event.frame_id) === Number(attack.targetFrame));
    const attackText = attack.mode === "none"
      ? "현재 Jetson 공격 상태 NONE"
      : `현재 Jetson 공격 ${attack.name}${attack.rate == null ? "" : ` · ${attack.rate}%`}`;
    evidence.push({
      task,
      text: attackText,
      observedAt: Date.now() - 7200,
      targets: ["kpiAttack"],
      charts: ["fpsChart", "rejectChart"],
      priority: "primary",
    });
    const focus = attackTimelineFocus(attack);
    if (focus) {
      evidence.push({
        task,
        text: `ATTACK Timeline · ${attack.name}${attack.rate == null ? "" : ` ${attack.rate}%`} · ${timelineTime(focus.startTime)} ~ ${focus.active ? "NOW" : timelineTime(focus.endTime)}`,
        observedAt: focus.startTime,
        targets: [], charts: [], timelineFocus: { ...focus, relatedEventIds: [] }, priority: "primary",
      });
      if (focus.relatedEventIds.length) {
        const detectorLabel = focus.detector === "tag" ? "GCM_AUTH_FAIL / TAG" : "REPLAY_REJECT / REPLAY";
        evidence.push({
          task,
          text: `${detectorLabel} · 분석 구간 내 ${focus.relatedEventIds.length}개 marker`,
          observedAt: focus.startTime,
          targets: [focus.detector === "tag" ? "tagDetector" : "replayDetector"],
          charts: ["rejectChart"], timelineFocus: focus, priority: "primary",
        });
      }
    }
    if (matched) {
      const frame = valueFrom(matched, "frame_id");
      evidence.push({
        task,
        text: "현재 스냅샷에서 Jetson 공격 대상 FRAME " + String(attack.targetFrame) + "와 RX 보안 이벤트 FRAME " + String(frame) + "가 일치합니다.",
        observedAt: Date.now() - 7200,
        targets: ["correlationPanel"],
        charts: ["fpsChart", "rejectChart"],
      });
    }
  }

  if (task === "timeline") {
    const event = [...timelineEvents].reverse()[0];
    if (event) {
      const label = event.source === "jetson"
        ? String(event.mode || event.type).toUpperCase() + " 공격 이벤트"
        : String(event.type).toUpperCase() + " 검출 이벤트";
      evidence.push({
        task,
        text: "현재 UI 타임라인에 기록된 " + label,
        observedAt: event.timestamp,
        targets: [],
        charts: [],
        timeline: { id: event.id, type: event.type },
      });
    }
  }

  return evidence;
}

function evidenceWindowFor(items) {
  const timelineFocus = items.find((item) => item.timelineFocus)?.timelineFocus;
  if (timelineFocus) return { start: timelineFocus.startTime, end: timelineFocus.endTime ?? Date.now() };
  const timestamp = Number((items.find((item) => item.timeline && Number.isFinite(item.observedAt))
    || items.find((item) => Number.isFinite(item.observedAt)))?.observedAt);
  const center = Number.isFinite(timestamp) ? timestamp : Date.now();
  return { start: center - 2200, end: center + 2200 };
}

function shouldAutoScroll(metrics, thresholdPx = 80) {
  return metrics.scrollHeight - metrics.clientHeight - metrics.scrollTop <= thresholdPx;
}

function scrollAfterAppend(element, wasPinned) {
  if (wasPinned) element.scrollTop = element.scrollHeight;
}

function createAiMessageMetadata(evidence) {
  if (!evidence.length) return null;
  const details = document.createElement("details");
  details.className = "ai-message-meta";
  const summary = document.createElement("summary");
  summary.textContent = "현재 대시보드 근거 " + evidence.length + "개";
  const links = document.createElement("div");
  evidence.forEach((item) => {
    const button = document.createElement("button");
    button.type = "button";
    button.className = "ai-evidence-link";
    button.textContent = "● " + item.text;
    button.addEventListener("click", () => refocusAiEvidence(item));
    links.append(button);
  });
  details.append(summary, links);
  return details;
}

function selectAutoFocusEvidence(evidence) {
  const primary = evidence.filter((item) => item.priority === "primary");
  return (primary.length ? primary : evidence).slice(0, 5);
}

function activateAiEvidence(evidence, automatic = false) {
  if (!Array.isArray(evidence) || !evidence.length) return;
  clearAiFocus();
  aiAllEvidence = evidence;
  aiVisibleEvidence = automatic ? selectAutoFocusEvidence(evidence) : evidence;
  aiEvidenceWindow = evidenceWindowFor(aiVisibleEvidence);
  aiFocusTask = aiVisibleEvidence[0].task || "summary";
  const targets = evidenceElements(aiVisibleEvidence);
  targets.forEach((element) => element.classList.add("ai-evidence-target"));
  $("#analysisPage").classList.add("ai-focus-mode");
  $("#aiFocusStatus").hidden = false;
  $("#aiClearFocus").disabled = false;
  aiFocusTimer = setTimeout(clearAiFocus, 12000);
  switchPage("analysis");
  const first = targets[0];
  if (first) {
    first.classList.remove("ai-evidence-jump");
    requestAnimationFrame(() => first.classList.add("ai-evidence-jump"));
    setTimeout(() => first.classList.remove("ai-evidence-jump"), 700);
  }
  redrawAnalysisEvidence();
}

function refocusAiEvidence(item) {
  if (!item || !aiAllEvidence.length) return;
  const targets = evidenceElements([item]);
  targets.forEach((element) => {
    element.classList.add("ai-evidence-target");
    element.classList.remove("ai-evidence-jump");
    requestAnimationFrame(() => element.classList.add("ai-evidence-jump"));
    setTimeout(() => element.classList.remove("ai-evidence-jump"), 1400);
  });
  const priorWindow = aiEvidenceWindow;
  aiEvidenceWindow = evidenceWindowFor([item]);
  switchPage("analysis");
  redrawAnalysisEvidence();
  setTimeout(() => { aiEvidenceWindow = priorWindow; redrawAnalysisEvidence(); }, 1400);
}

function setAiVoiceState(state, transcript = aiVoiceTranscript) {
  aiVoiceState = state;
  aiVoiceTranscript = transcript;
  const visible = state === "LISTENING" || state === "TRANSCRIBED" || state === "ANALYZING" ? state : "IDLE";
  const panels = { IDLE: $("#aiVoiceIdle"), LISTENING: $("#aiVoiceListening"), TRANSCRIBED: $("#aiVoiceComplete"), ANALYZING: $("#aiVoiceAnalyzing") };
  Object.entries(panels).forEach(([name, panel]) => { if (panel) panel.hidden = name !== visible; });
  $("#aiVoiceTranscript").textContent = `“${transcript || "말씀해 주세요..."}”`;
  $("#aiVoiceFinalTranscript").textContent = transcript ? `“${transcript}”` : "";
  $("#aiVoiceStage").dataset.state = visible.toLowerCase();
  $("#aiComposer").classList.toggle("listening", state === "LISTENING");
}

function setAiState(state) {
  const labels = { IDLE: aiStatusLabel, LISTENING: "듣는 중", TRANSCRIBED: "질문 인식", ANALYZING: "분석 중", ANSWER: "답변 완료" };
  const prompts = { IDLE: aiStatusPrompt, LISTENING: "● 듣는 중...", TRANSCRIBED: "질문을 인식했습니다", ANALYZING: "Gemini가 시스템 근거를 확인 중입니다", ANSWER: "답변 완료" };
  const tone = state === "ANSWER" || state === "TRANSCRIBED" || (state === "IDLE" && aiConfigured)
    ? "live" : state === "LISTENING" || state === "ANALYZING" ? "warn" : "error";
  setChip($("#aiState"), tone, labels[state] || state);
  $("#aiComposerStatus").textContent = prompts[state] || state;
  setAiVoiceState(state, aiVoiceTranscript);
}

function clearAiFocus() {
  clearTimeout(aiFocusTimer);
  aiFocusTask = null;
  aiVisibleEvidence = [];
  aiAllEvidence = [];
  aiEvidenceWindow = null;
  $$(".ai-evidence-target").forEach((element) => element.classList.remove("ai-evidence-target"));
  $("#analysisPage").classList.remove("ai-focus-mode");
  $("#aiFocusStatus").hidden = true;
  $("#aiClearFocus").disabled = true;
  redrawAnalysisEvidence();
}

function openAiInteraction() {
  $("#aiInteraction").hidden = false;
  $(".workspace").classList.add("ai-drawer-open");
  $("#askAiButton").setAttribute("aria-expanded", "true");
  setAiState("IDLE");
  $("#aiQuestionInput").focus({ preventScroll: true });
}

function closeAiInteraction() {
  speechRecognition?.abort();
  clearAiFocus();
  setAiState("IDLE");
  $("#aiInteraction").hidden = true;
  $(".workspace").classList.remove("ai-drawer-open");
  $("#askAiButton").setAttribute("aria-expanded", "false");
  $("#aiAnalyzingPanel").hidden = true;
}

function appendAiMessage(role, text, id = "", evidence = [], timestamp = Date.now()) {
  const chat = $("#aiChatHistory");
  const wasPinned = shouldAutoScroll(chat);
  $("#aiEmptyConversation")?.remove();
  const message = document.createElement("article");
  message.className = `ai-message-row ${role === "model" || role === "pending" ? "gemini" : role}`;
  message.dataset.timestamp = String(timestamp);
  if (id) message.id = id;
  aiMessages.push({ role, text, timestamp });
  const heading = document.createElement("div");
  heading.className = "ai-message-heading";
  const label = document.createElement("span");
  label.textContent = role === "user" ? "나" : role === "error" ? "ERROR" : "Gemini";
  const time = document.createElement("time");
  time.dateTime = new Date(timestamp).toISOString();
  time.textContent = new Date(timestamp).toLocaleTimeString("en-GB", { hour12: false });
  const content = document.createElement("p");
  content.textContent = text;
  heading.append(label, time);
  message.append(heading, content);
  const metadata = createAiMessageMetadata(evidence);
  if (metadata) message.append(metadata);
  $("#aiConversation").append(message);
  scrollAfterAppend(chat, wasPinned);
  return message;
}

function evidenceMentioned(answer, item) {
  const text = String(answer || "").toLowerCase();
  const label = String(item.text || "").toLowerCase();
  if (label.startsWith("현재 rx 텔레메트리")) return /valid\s*fps|유효\s*fps/.test(text);
  if (label.includes("frame drop")) return /frame\s*drop|프레임\s*드롭/.test(text);
  if (label.includes("frame jitter")) return /frame\s*jitter|프레임\s*지터/.test(text);
  if (label.startsWith("video ")) return /video|영상/.test(text);
  if (label.includes("gcm auth fail")) return /gcm|인증\s*실패/.test(text);
  if (label.includes("tag detector") || label.includes("최근 gcm")) return /tag|gcm|인증\s*실패/.test(text);
  if (label.includes("replay reject")) return /replay|재전송/.test(text);
  if (label.includes("attack timeline")) return /timeline|타임라인/.test(text);
  if (label.startsWith("현재 공격")) return /tamper|replay|공격/.test(text);
  return text.includes(label);
}

function completeAnswerWithEvidence(answer, evidence) {
  const missing = evidence.filter((item) => !evidenceMentioned(answer, item));
  if (!missing.length) return answer;
  return `${String(answer || "").trim()}\n\n추가 관측 근거:\n${missing.map((item) => `- ${item.text}`).join("\n")}`;
}

function setAiBusy(busy) {
  aiPending = busy;
  $$('[data-ai-query]').forEach((button) => { button.disabled = busy || !aiConfigured; });
  $("#aiQuestionInput").disabled = busy || !aiConfigured;
  $("#aiQuestionForm button[type='submit']").disabled = busy || !aiConfigured;
  $("#aiMicButton").disabled = busy || !aiConfigured || !speechRecognition;
}

function renderAiContexts() {
  const state = latestState || {};
  const contexts = [];
  if (state.telemetry) contexts.push("RX TELEMETRY");
  if (Array.isArray(state.events) && state.events.length) contexts.push("SECURITY EVENTS");
  if (latestAttack?.connected) contexts.push("ATTACK STATUS");
  if (timelineEvents.length) contexts.push("EVENT TIMELINE");
  $("#aiContextList").replaceChildren(...contexts.map((text) => {
    const item = document.createElement("li");
    item.className = "used";
    item.textContent = "✓ " + text;
    return item;
  }));
}

async function loadAiStatus() {
  try {
    const response = await fetch("/api/ai/status", { cache: "no-store" });
    if (!response.ok) throw new Error(`HTTP ${response.status}`);
    const status = await response.json();
    aiConfigured = Boolean(status.configured);
    const provider = String(status.provider || "Gemini").toUpperCase();
    const model = status.model == null ? "" : String(status.model);
    aiStatusLabel = aiConfigured ? "대기 중" : "설정 필요";
    aiStatusPrompt = aiConfigured
      ? (model ? provider + " 연결됨 · " + model : provider + " 연결됨")
      : "GEMINI_API_KEY 환경 설정이 필요합니다";
    $("#aiConnectionStatus").textContent = aiConfigured
      ? "● 연결됨 · LIVE CONTEXT"
      : `● ${provider} 설정 필요`;
    setAiState("IDLE");
    if (sessionPreviousGeminiOnline !== aiConfigured) {
      pushSessionEvent({ category: "system", source: "GEMINI", type: aiConfigured ? (sessionPreviousGeminiOnline === false ? "GEMINI_API_RECOVERED" : "GEMINI_API_CONNECTED") : "GEMINI_API_ERROR" });
      sessionPreviousGeminiOnline = aiConfigured;
    }
  } catch (error) {
    aiConfigured = false;
    aiStatusLabel = "GEMINI OFFLINE";
    aiStatusPrompt = "Gemini 연결 상태를 확인할 수 없습니다";
    $("#aiConnectionStatus").textContent = "● GEMINI API OFFLINE";
    setAiState("IDLE");
    if (sessionPreviousGeminiOnline !== false) {
      pushSessionEvent({ category: "system", source: "GEMINI", type: "GEMINI_API_ERROR", detail: error.message || null, tone: "auth" });
      sessionPreviousGeminiOnline = false;
    }
  }
  setAiBusy(false);
}

async function requestAi(path, body, evidenceTask = body.task || taskFromQuestion(body.message)) {
  if (!aiConfigured || aiPending) return;
  setAiBusy(true);
  $("#aiAnalyzingPanel").hidden = false;
  $("#aiContextList").replaceChildren(...["RX Telemetry", "Security Events", "Attack State"].map((text) => {
    const item = document.createElement("li"); item.className = "used"; item.textContent = `✓ ${text}`; return item;
  }));
  renderAiContexts();
  appendAiMessage("pending", "ANALYZING LIVE SECURITY CONTEXT...", "aiPendingMessage");
  const analysisAt = Date.now();
  const snapshotStartedAt = performance.now();
  const analysisSnapshot = aiContext(body.message || body.task || "");
  const snapshotMs = Math.round(performance.now() - snapshotStartedAt);
  const evidenceStartedAt = performance.now();
  const evidence = currentEvidence(evidenceTask, latestState, analysisAt);
  const evidenceMs = Math.round(performance.now() - evidenceStartedAt);
  analysisSnapshot.answerEvidence = evidence.map(({ text, observedAt }) => ({ text, observedAt }));
  const contextBytes = new TextEncoder().encode(JSON.stringify(analysisSnapshot)).length;
  const requestStartedAt = performance.now();
  try {
    const response = await fetch(path, {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({
        ...body,
        context: analysisSnapshot,
        clientDiagnostics: { snapshotMs, evidenceMs, contextBytes },
      }),
    });
    const result = await response.json();
    if (!response.ok) {
      const error = new Error(result.error || `HTTP ${response.status}`);
      error.diagnostics = result.diagnostics || null;
      throw error;
    }
    $("#aiPendingMessage")?.remove();
    $("#aiAnalyzingPanel").hidden = true;
    appendAiMessage("model", completeAnswerWithEvidence(result.text || "EMPTY RESPONSE", evidence), "", evidence, analysisAt);
    if (evidence.length) activateAiEvidence(evidence, true);
    $("#aiLastUpdated").textContent = new Date().toLocaleTimeString("ko-KR", { hour12: false });
    setAiState("ANSWER");
    if (result.interactionId) aiInteractionId = result.interactionId;
  } catch (error) {
    $("#aiPendingMessage")?.remove();
    $("#aiAnalyzingPanel").hidden = true;
    appendAiMessage("error", error.message || "GEMINI REQUEST FAILED");
    const diagnostics = error?.diagnostics || {};
    if (/timed out|timeout/i.test(String(error?.message || "")) || diagnostics.phase === "gemini_http_timeout") {
      const httpMs = Number.isFinite(Number(diagnostics.geminiHttpMs))
        ? diagnostics.geminiHttpMs : Math.round(performance.now() - requestStartedAt);
      const timeoutMs = Number.isFinite(Number(diagnostics.timeoutMs)) ? diagnostics.timeoutMs : null;
      const detail = [
        `PHASE ${diagnostics.phase || "gemini_http_or_network"}`,
        `SNAPSHOT ${snapshotMs} ms`,
        `EVIDENCE ${evidenceMs} ms`,
        `CONTEXT ${diagnostics.contextBytes ?? contextBytes} B`,
        `HTTP ${httpMs} ms`,
        timeoutMs == null ? null : `LIMIT ${timeoutMs} ms`,
      ].filter(Boolean).join(" · ");
      pushSessionEvent({ category: "system", source: "GEMINI", type: "GEMINI_TIMEOUT", detail, tone: "auth" });
    }
    setAiState("IDLE");
  } finally {
    setAiBusy(false);
  }
}

function submitAiChat(text, task = null) {
  const message = String(text || "").trim();
  if (!message || aiPending || !aiConfigured) return;
  const evidenceTask = task || taskFromQuestion(message);
  appendAiMessage("user", message);
  $("#aiQuestionInput").value = "";
  setAiState("ANALYZING");
  requestAi("/api/ai/chat", {
    message,
    previousInteractionId: aiInteractionId,
  }, evidenceTask);
}

function initSpeechRecognition() {
  const SpeechRecognition = window.SpeechRecognition || window.webkitSpeechRecognition;
  if (!SpeechRecognition) {
    $("#aiMicButton").disabled = true;
    $("#aiMicButton").title = "SPEECH RECOGNITION NOT SUPPORTED";
    return;
  }
  speechRecognition = new SpeechRecognition();
  speechRecognition.lang = "ko-KR";
  speechRecognition.continuous = false;
  speechRecognition.interimResults = true;
  speechRecognition.maxAlternatives = 1;
  speechRecognition.onstart = () => {
    speechSubmitted = false;
    $("#aiMicButton").classList.add("listening");
    $("#aiMicButton").setAttribute("aria-label", "Stop microphone input");
    setAiState("LISTENING");
  };
  speechRecognition.onresult = (event) => {
    const finalParts = [];
    const interimParts = [];
    for (let index = event.resultIndex; index < event.results.length; index += 1) {
      const transcript = event.results[index]?.[0]?.transcript || "";
      (event.results[index].isFinal ? finalParts : interimParts).push(transcript);
    }
    const finalText = finalParts.join(" ").trim();
    aiVoiceTranscript = (finalText || interimParts.join(" ")).trim();
    $("#aiQuestionInput").value = aiVoiceTranscript;
    $("#aiVoiceTranscript").textContent = `“${aiVoiceTranscript || "말씀해 주세요..."}”`;
    if (finalText && !speechSubmitted) {
      speechSubmitted = true;
      setAiState("TRANSCRIBED");
    }
  };
  speechRecognition.onend = () => {
    $("#aiMicButton").classList.remove("listening");
    $("#aiMicButton").setAttribute("aria-label", "Start microphone input");
    if (aiVoiceState === "LISTENING") setAiState(aiVoiceTranscript ? "TRANSCRIBED" : "IDLE");
  };
  speechRecognition.onerror = (event) => {
    if (event.error === "aborted") return;
    const messages = {
      "not-allowed": "마이크 권한이 거부되었습니다. 브라우저 권한에서 마이크를 허용하세요.",
      "service-not-allowed": "브라우저 음성 인식 서비스 사용이 허용되지 않았습니다.",
      "audio-capture": "사용 가능한 마이크를 찾지 못했습니다.",
      "no-speech": "음성이 감지되지 않았습니다. 다시 시도하세요.",
      network: "음성 인식 서비스에 연결하지 못했습니다.",
    };
    appendAiMessage("error", messages[event.error] || `VOICE INPUT ERROR (${event.error || "unknown"})`);
    setAiState("IDLE");
  };
}

$$('.page-tab').forEach((button) => button.addEventListener("click", () => switchPage(button.dataset.page)));
function openEventLog() {
  $("#eventLogDrawer").hidden = false;
  $("#eventLogButton").setAttribute("aria-expanded", "true");
  renderSessionEventLog();
}
function closeEventLog() {
  $("#eventLogDrawer").hidden = true;
  $("#eventLogButton").setAttribute("aria-expanded", "false");
}
$("#eventLogButton").addEventListener("click", () => $("#eventLogDrawer").hidden ? openEventLog() : closeEventLog());
$("#eventLogCloseButton").addEventListener("click", closeEventLog);
$$('[data-event-filter]').forEach((button) => button.addEventListener("click", () => {
  sessionEventFilter = button.dataset.eventFilter;
  $$('[data-event-filter]').forEach((item) => item.classList.toggle("active", item === button));
  renderSessionEventLog();
}));
video.addEventListener("loadeddata", () => { videoLastFrameAt = Date.now(); });
video.addEventListener("timeupdate", () => { if (stream?.active) videoLastFrameAt = Date.now(); });
startButton.addEventListener("click", startCapture);
deviceSelect.addEventListener("change", () => stream && startCapture());
$("#askAiButton").addEventListener("click", () => $("#aiInteraction").hidden ? openAiInteraction() : closeAiInteraction());
$("#aiCloseButton").addEventListener("click", closeAiInteraction);
$("#aiClearFocus").addEventListener("click", clearAiFocus);
$$('[data-ai-query]').forEach((button) => button.addEventListener("click", () => {
  const question = QUICK_QUESTIONS[button.dataset.aiQuery];
  if (!question) return;
  appendAiMessage("user", button.textContent.trim());
  setAiState("ANALYZING");
  requestAi(question.path, {
    ...question.body,
    ...(question.path.endsWith("/chat") && { previousInteractionId: aiInteractionId }),
  }, question.evidenceTask);
}));
$("#aiQuestionForm").addEventListener("submit", (event) => {
  event.preventDefault();
  submitAiChat($("#aiQuestionInput").value);
});
$("#aiMicButton").addEventListener("click", () => {
  if (!speechRecognition || aiPending || !aiConfigured) return;
  if (aiVoiceState === "LISTENING") speechRecognition.stop();
  else {
    try { speechRecognition.start(); }
    catch (error) { appendAiMessage("error", error.message || "VOICE INPUT START FAILED"); }
  }
});
$("#aiVoiceStop").addEventListener("click", () => {
  if (aiVoiceTranscript) setAiState("TRANSCRIBED");
  speechRecognition?.stop();
});
$("#aiVoiceRetry").addEventListener("click", () => {
  speechRecognition?.abort();
  aiVoiceTranscript = "";
  $("#aiQuestionInput").value = "";
  setAiState("IDLE");
  $("#aiMicButton").click();
});
$("#aiVoiceSubmit").addEventListener("click", () => submitAiChat($("#aiQuestionInput").value));

window.argosEventLog = { getCurrentSystemState, getVideoState, getAttackState, getSecuritySnapshot, getRecentEvents, getSessionEvents };
renderSessionEventLog();
pushSessionEvent({ category: "system", source: "DASHBOARD", type: "SESSION_STARTED" });
$("#securityTimeline").addEventListener("mousemove", handleTimelineHover);
$("#securityTimeline").addEventListener("mouseleave", () => $("#timelineTooltip").classList.add("hidden"));
window.addEventListener("resize", () => latestState && renderAnalysis(latestState, latestState.telemetry || {}, latestAttack || normalizeAttack(latestState), Boolean(latestState.online && latestState.telemetry), eventFields(latestState, latestState.telemetry || {}), securityState(latestState, latestState.telemetry || {}, Boolean(latestState.online && latestState.telemetry))));
window.addEventListener("pagehide", stopStream);
window.addEventListener("keydown", (event) => {
  if (event.repeat) return;
  const key = shortcutKey(event);
  if (!occWasLocked && /INPUT|SELECT|TEXTAREA/.test(event.target.tagName)) return;
  keyChord.add(key);
  if (occWasLocked && ["q", "w", "e"].includes(key)) {
    event.preventDefault();
    occMasterSequence = `${occMasterSequence}${key}`.slice(-3);
    clearTimeout(occMasterTimer);
    occMasterTimer = setTimeout(resetOccMasterSequence, 1200);
  }
  if (occWasLocked && (["q", "w", "e"].every((value) => keyChord.has(value)) || occMasterSequence === "qwe")) {
    keyChord.clear();
    resetOccMasterSequence();
    submitOcc("emergency-unlock", ["q", "w", "e"]).catch(console.error);
  } else if (["l", "k", "j"].every((key) => keyChord.has(key))) {
    keyChord.clear(); submitOcc("keyboard-lock", ["l", "k", "j"]).catch(console.error);
  }
});
window.addEventListener("keyup", (event) => keyChord.delete(shortcutKey(event)));
window.addEventListener("blur", () => { keyChord.clear(); resetOccMasterSequence(); });

if (!navigator.mediaDevices?.getUserMedia) {
  startButton.disabled = true;
  setVideoState("ERROR", "GETUSERMEDIA REQUIRES LOCALHOST OR HTTPS");
} else {
  loadDevices().catch(() => setVideoState("ERROR", "VIDEO INPUT LIST UNAVAILABLE"));
}

initSpeechRecognition();
loadAiStatus();
pollState();
setInterval(pollState, 200);
