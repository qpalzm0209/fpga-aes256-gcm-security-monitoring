const video = document.querySelector("#video");
const deviceSelect = document.querySelector("#deviceSelect");
const startButton = document.querySelector("#startButton");
const liveStatus = document.querySelector("#liveStatus");
const videoMessage = document.querySelector("#videoMessage");
const deviceName = document.querySelector("#deviceName");
const inputFormat = document.querySelector("#inputFormat");
const captureStatus = document.querySelector("#captureStatus");

let stream;

function stopStream() {
  stream?.getTracks().forEach((track) => track.stop());
  stream = undefined;
  video.srcObject = null;
}

function setState(state, message) {
  liveStatus.textContent = state;
  liveStatus.className = `status-badge ${state === "LIVE" ? "live" : state === "ERROR" ? "error" : ""}`;
  captureStatus.textContent = state === "LIVE" ? "ACTIVE" : state;
  captureStatus.className = state === "LIVE" ? "active" : state === "ERROR" ? "error" : "";
  videoMessage.textContent = message;
  videoMessage.classList.toggle("hidden", state === "LIVE");
}

async function loadDevices(selectedId = deviceSelect.value) {
  const devices = (await navigator.mediaDevices.enumerateDevices()).filter(
    (device) => device.kind === "videoinput",
  );

  deviceSelect.replaceChildren();

  for (const [index, device] of devices.entries()) {
    const option = document.createElement("option");
    option.value = device.deviceId;
    option.textContent = device.label || `VIDEO INPUT ${index + 1}`;
    deviceSelect.append(option);
  }

  const preferred = devices.find((device) => device.deviceId === selectedId)
    || devices.find((device) => /usb3.*capture/i.test(device.label));

  if (preferred) deviceSelect.value = preferred.deviceId;
  startButton.disabled = devices.length === 0;
  if (devices.length === 0) setState("ERROR", "NO VIDEO INPUT DEVICE");
}

function formatInput(settings) {
  const width = settings.width || video.videoWidth;
  const height = settings.height || video.videoHeight;
  const frameRate = Number(settings.frameRate);
  const size = width && height ? `${width} × ${height}` : "UNKNOWN";
  return Number.isFinite(frameRate) ? `${size} @ ${frameRate.toFixed(2)} fps` : size;
}

async function startCapture() {
  startButton.disabled = true;
  setState("WAITING", "OPENING VIDEO INPUT");

  try {
    stopStream();
    const deviceId = deviceSelect.value;
    stream = await navigator.mediaDevices.getUserMedia({
      video: {
        ...(deviceId && { deviceId: { exact: deviceId } }),
        width: { ideal: 1280 },
        height: { ideal: 720 },
      },
      audio: false,
    });

    video.srcObject = stream;
    await video.play();

    const track = stream.getVideoTracks()[0];
    const settings = track.getSettings();
    await loadDevices(settings.deviceId);

    deviceName.textContent = track.label || deviceSelect.selectedOptions[0]?.textContent || "VIDEO INPUT";
    inputFormat.textContent = formatInput(settings);
    setState("LIVE", "");

    track.addEventListener("ended", () => {
      stopStream();
      setState("ERROR", "VIDEO INPUT DISCONNECTED");
    }, { once: true });
  } catch (error) {
    stopStream();
    const denied = error.name === "NotAllowedError" || error.name === "SecurityError";
    setState("ERROR", denied ? "CAMERA PERMISSION DENIED" : "VIDEO INPUT COULD NOT BE OPENED");
    console.error(error);
  } finally {
    startButton.disabled = deviceSelect.options.length === 0;
  }
}

startButton.addEventListener("click", startCapture);
deviceSelect.addEventListener("change", () => {
  if (stream) startCapture();
});
window.addEventListener("pagehide", stopStream);

if (!navigator.mediaDevices?.getUserMedia) {
  startButton.disabled = true;
  setState("ERROR", "GETUSERMEDIA REQUIRES LOCALHOST OR HTTPS");
} else {
  loadDevices().catch(() => setState("ERROR", "VIDEO INPUT LIST UNAVAILABLE"));
}
