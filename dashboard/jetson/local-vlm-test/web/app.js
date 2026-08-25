const $ = (selector) => document.querySelector(selector);
const input = $("#imageInput");
const preview = $("#preview");
const imageStage = $("#imageStage");
const imageMessage = $("#imageMessage");
const analyzeButton = $("#analyzeButton");
const modelBadge = $("#modelBadge");
let selectedFile = null;
let modelReady = false;
let previewUrl = null;

function setHidden(element, hidden) {
  element.classList.toggle("hidden", hidden);
}

function resetResult() {
  for (const id of ["scene", "people", "objects", "sensitive", "inferenceTime",
    "totalTime", "gpuUsage", "ramUsage", "powerUsage", "tokens"]) {
    $("#" + id).textContent = "—";
  }
  $("#modelName").textContent = modelReady ? modelBadge.dataset.model || "READY" : "—";
  $("#rawOutput").textContent = "No inference has run.";
  $("#resultState").textContent = "WAITING FOR USER";
  setHidden($("#errorBox"), true);
}

async function refreshStatus() {
  try {
    const response = await fetch("/api/status", { cache: "no-store" });
    const value = await response.json();
    modelReady = Boolean(value.model_server?.loaded);
    modelBadge.textContent = modelReady ? "MODEL READY" : "MODEL NOT READY";
    modelBadge.className = `badge ${modelReady ? "ready" : "error-badge"}`;
    modelBadge.dataset.model = value.model_server?.model || "";
    $("#modelName").textContent = value.model_server?.model || "—";
    modelBadge.title = value.model_server?.error || value.model_server?.model || "";
  } catch (error) {
    modelReady = false;
    modelBadge.textContent = "APP OFFLINE";
    modelBadge.className = "badge error-badge";
    modelBadge.title = String(error);
  }
  analyzeButton.disabled = !selectedFile || !modelReady;
}

input.addEventListener("change", () => {
  selectedFile = input.files?.[0] || null;
  if (previewUrl) URL.revokeObjectURL(previewUrl);
  if (!selectedFile) {
    preview.removeAttribute("src");
    imageStage.classList.add("empty");
    imageMessage.textContent = "SELECT A JPEG, PNG, OR WEBP IMAGE";
    $("#fileName").textContent = "NO IMAGE SELECTED";
  } else {
    previewUrl = URL.createObjectURL(selectedFile);
    preview.src = previewUrl;
    imageStage.classList.remove("empty");
    imageMessage.textContent = "";
    $("#fileName").textContent = `${selectedFile.name} · ${(selectedFile.size / 1024).toFixed(1)} KB`;
  }
  resetResult();
  analyzeButton.disabled = !selectedFile || !modelReady;
});

function metricPair(value, suffix, decimals = 1) {
  if (!value || !Number.isFinite(value.mean) || !Number.isFinite(value.peak)) return "—";
  return `${value.mean.toFixed(decimals)} / ${value.peak.toFixed(decimals)} ${suffix}`;
}

function ramPair(value) {
  const item = value?.ram_used_mb;
  if (!item || !Number.isFinite(item.before) || !Number.isFinite(item.peak)) return "—";
  return `${item.before.toFixed(0)} / ${item.peak.toFixed(0)} MB`;
}

analyzeButton.addEventListener("click", async () => {
  if (!selectedFile || !modelReady || analyzeButton.disabled) return;
  analyzeButton.disabled = true;
  input.disabled = true;
  setHidden($("#progress"), false);
  setHidden($("#errorBox"), true);
  $("#resultState").textContent = "RUNNING";
  $("#rawOutput").textContent = "Waiting for local model output...";
  const body = new FormData();
  body.append("image", selectedFile, selectedFile.name);
  try {
    const response = await fetch("/api/analyze", { method: "POST", body });
    const value = await response.json();
    if (!response.ok) throw Object.assign(new Error(value.error || `HTTP ${response.status}`), { value });
    $("#scene").textContent = value.analysis?.scene || "Not provided";
    $("#people").textContent = value.analysis?.people || "Not provided";
    $("#objects").textContent = value.analysis?.objects || "Not provided";
    $("#sensitive").textContent = value.analysis?.potentially_sensitive_information || "Not provided";
    $("#inferenceTime").textContent = `${value.model_request_sec.toFixed(2)} sec`;
    $("#totalTime").textContent = `${value.total_response_sec.toFixed(2)} sec`;
    $("#gpuUsage").textContent = metricPair(value.metrics?.gpu_util_percent, "%");
    $("#ramUsage").textContent = ramPair(value.metrics);
    $("#powerUsage").textContent = metricPair(value.metrics?.board_power_w, "W", 2);
    $("#modelName").textContent = value.model || "—";
    $("#execution").textContent = value.execution || "LOCAL / JETSON";
    $("#tokens").textContent = value.usage?.completion_tokens == null
      ? "—" : `${value.usage.completion_tokens} output`;
    $("#rawOutput").textContent = value.raw_output || "(empty)";
    $("#resultState").textContent = "COMPLETE";
  } catch (error) {
    const value = error.value || {};
    $("#resultState").textContent = "FAILED";
    $("#errorBox").textContent = String(error.message || error);
    setHidden($("#errorBox"), false);
    $("#rawOutput").textContent = value.model_log_tail || String(error.stack || error);
    $("#gpuUsage").textContent = metricPair(value.metrics?.gpu_util_percent, "%");
    $("#ramUsage").textContent = ramPair(value.metrics);
    $("#powerUsage").textContent = metricPair(value.metrics?.board_power_w, "W", 2);
  } finally {
    setHidden($("#progress"), true);
    input.disabled = false;
    analyzeButton.disabled = !selectedFile || !modelReady;
  }
});

refreshStatus();
window.setInterval(refreshStatus, 5000);
