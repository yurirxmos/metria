const CONFIG_KEY = "metriaPwaConfig";
const SNAPSHOT_KEY = "metriaPwaSnapshot";
let eventSource;
let activeCryptoKey;
let snapshotPollingTimer;
let activeConfig;

const setup = document.querySelector("#setup");
const dashboard = document.querySelector("#dashboard");
const form = document.querySelector("#topicForm");
const serverInput = document.querySelector("#serverInput");
const phraseInput = document.querySelector("#phraseInput");
const pairingError = document.querySelector("#pairingError");
const connectionIndicator = document.querySelector("#connectionIndicator");
const connectionLabel = document.querySelector("#connectionLabel");
const providerGrid = document.querySelector("#providerGrid");
const emptyState = document.querySelector("#emptyState");
const lastUpdated = document.querySelector("#lastUpdated");
const scanButton = document.querySelector("#scanButton");
const cameraUnavailable = document.querySelector("#cameraUnavailable");
const scannerOverlay = document.querySelector("#scannerOverlay");
const scannerVideo = document.querySelector("#scannerVideo");
const scannerCanvas = document.querySelector("#scannerCanvas");
const scannerError = document.querySelector("#scannerError");
const scannerCancel = document.querySelector("#scannerCancel");
const notificationButton = document.querySelector("#notificationButton");

function setStatus(label, state) {
  connectionLabel.textContent = label;
  const colors = {
    idle: "bg-[#636366]",
    connecting: "bg-[#ff9f0a]",
    live: "bg-[#30d158]",
    offline: "bg-[#ff453a]"
  };
  connectionIndicator.className = `h-2 w-2 rounded-full ${colors[state]}`;
}

function normalizeServer(server) {
  const normalizedServer = server.replace(/\/+$/, "");
  const url = new URL(normalizedServer);
  if (url.protocol !== "https:") throw new Error("The ntfy server must use HTTPS.");
  return normalizedServer;
}

function renderSnapshot(snapshot) {
  const providers = Array.isArray(snapshot?.providers) ? snapshot.providers : [];
  providerGrid.innerHTML = providers.map((provider) => {
    const percent = Math.max(0, Math.min(100, Number(provider.percent) || 0));
    const logo = providerLogo(provider.name);
    const spend = spendText(provider);
    return `<article class="rounded-2xl border border-white/10 bg-black p-5">
      <div class="flex items-center justify-between gap-4"><div class="flex min-w-0 items-center gap-3">${logo ? `<img src="${logo}" alt="" class="h-6 w-6 shrink-0 object-contain">` : ""}<span class="truncate text-base font-medium">${escapeHtml(provider.name)}</span></div><strong class="shrink-0 text-[28px] font-medium tracking-[-0.05em]" style="color: ${usageColor(percent)}">${Math.round(percent)}%</strong></div>
      <div class="mt-5 h-[5px] overflow-hidden rounded-full bg-[#2c2c2e]"><div class="h-full rounded-full" style="width: ${percent}%; background-color: ${usageColor(percent)}"></div></div>
      <p class="mb-0 mt-3 flex items-baseline justify-between gap-3 text-xs text-[#8e8e93]"><span>${provider.resetDate ? `Resets ${formatDate(provider.resetDate)}` : "No reset date"}</span>${spend ? `<span class="shrink-0 font-mono">${escapeHtml(spend)}</span>` : ""}</p>
    </article>`;
  }).join("");
  emptyState.hidden = providers.length > 0;
  if (snapshot?.updatedAt) {
    lastUpdated.textContent = `Updated ${formatDate(snapshot.updatedAt)}`;
  }
}

/** Cursor is the only provider that reports what a cycle costs, and it reports cents.
 * Whole dollars drop the decimals, matching the desktop apps' "$130 / $250". */
function spendText(provider) {
  const used = Number(provider.usedCents);
  const limit = Number(provider.limitCents);
  if (!Number.isFinite(used) || !Number.isFinite(limit)) return "";
  const amount = (cents) => `$${Number.isInteger(cents / 100) ? (cents / 100).toFixed(0) : (cents / 100).toFixed(2)}`;
  return `${amount(used)} / ${amount(limit)}`;
}

function usageColor(percent) {
  if (percent >= 85) return "#ff453a";
  if (percent >= 65) return "#ff9f0a";
  if (percent >= 40) return "#ffd60a";
  return "#30d158";
}

function providerLogo(name) {
  return { Claude: "claude-logo.png", Codex: "codex-logo.png", "OpenCode Go": "opencode-logo.png", Cursor: "cursor-logo.png" }[name] || "";
}

function formatDate(value) {
  const date = new Date(value);
  return Number.isNaN(date.getTime()) ? "recently" : date.toLocaleString([], { dateStyle: "medium", timeStyle: "short" });
}

function escapeHtml(value) {
  return String(value ?? "").replace(/[&<>'"]/g, (character) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", "'": "&#39;", '"': "&quot;" })[character]);
}

// Connects to the ntfy topic derived from the paired secret and decrypts every message
// that arrives. A message that fails to decrypt (wrong key, or forged noise sent by
// someone who merely guessed the topic name) is silently ignored.
async function connect(config) {
  eventSource?.close();
  clearInterval(snapshotPollingTimer);
  activeConfig = config;
  setup.hidden = true;
  dashboard.hidden = false;
  setStatus("Connecting", "connecting");
  void updateNotificationButton(config);

  if (location.protocol === "http:") {
    await restoreLocalSnapshot(config.secretBase64);
    return;
  }

  const secretBytes = window.MetriaPairing.base64UrlToBytes(config.secretBase64);
  const { topic, cryptoKey } = await window.MetriaPairing.deriveFromSecret(secretBytes);
  activeCryptoKey = cryptoKey;

  const streamUrl = `${normalizeServer(config.server)}/${topic}/sse?since=latest`;
  eventSource = new EventSource(streamUrl);
  eventSource.onopen = () => setStatus("Live", "live");
  eventSource.onerror = () => setStatus("Offline", "offline");
  eventSource.onmessage = async (event) => {
    try {
      const message = JSON.parse(event.data);
      const snapshot = await window.MetriaPairing.decryptSnapshot(message.message, activeCryptoKey);
      localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
      renderSnapshot(snapshot);
      setStatus("Live", "live");
    } catch {
      // Not a valid encrypted snapshot for our key — ignore it.
    }
  };
}

async function updateNotificationButton(config) {
  if (!window.isSecureContext || !("serviceWorker" in navigator) || !("PushManager" in window) || !("Notification" in window)) {
    notificationButton.hidden = true;
    return;
  }

  const registration = await navigator.serviceWorker.ready;
  const subscription = await registration.pushManager.getSubscription();
  notificationButton.hidden = false;
  notificationButton.textContent = subscription ? "Refresh notifications" : "Enable notifications";
  notificationButton.disabled = false;
}

async function enableNotifications() {
  if (!activeConfig) return;
  const permission = await Notification.requestPermission();
  if (permission !== "granted") return;

  const registration = await navigator.serviceWorker.ready;
  const keyResponse = await fetch("/api/push-key");
  if (!keyResponse.ok) throw new Error("Notifications are unavailable.");
  const { publicKey } = await keyResponse.json();
  const existingSubscription = await registration.pushManager.getSubscription();
  if (existingSubscription) await existingSubscription.unsubscribe();
  const subscription = await registration.pushManager.subscribe({
    userVisibleOnly: true,
    applicationServerKey: window.MetriaPairing.base64UrlToBytes(publicKey)
  });
  const response = await fetch("/api/subscriptions", {
    method: "POST",
    headers: { "Content-Type": "application/json" },
    body: JSON.stringify({ secret: activeConfig.secretBase64, subscription })
  });
  if (!response.ok) throw new Error("Notifications are unavailable.");
  notificationButton.textContent = "Notifications enabled";
  notificationButton.disabled = false;
}

async function loadLocalSnapshot(secretBase64) {
  try {
    const response = await fetch("snapshot", {
      cache: "no-store",
      headers: { "X-Metria-Secret": secretBase64 }
    });
    if (!response.ok) return false;
    const snapshot = await response.json();
    localStorage.setItem(SNAPSHOT_KEY, JSON.stringify(snapshot));
    renderSnapshot(snapshot);
    setStatus("Current", "live");
    return true;
  } catch {
    return false;
  }
}

async function restoreLocalSnapshot(secretBase64) {
  clearInterval(snapshotPollingTimer);
  for (let attempt = 0; attempt < 20; attempt++) {
    if (await loadLocalSnapshot(secretBase64)) return;
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  setStatus("Offline", "offline");
}

form.addEventListener("submit", async (event) => {
  event.preventDefault();
  pairingError.hidden = true;

  const words = phraseInput.value.trim().toLowerCase().split(/\s+/).filter(Boolean);
  const secretBytes = await window.MetriaPairing.wordsToSecret(words);
  if (!secretBytes) {
    pairingError.textContent = "Those words don't match — check for typos and try again.";
    pairingError.hidden = false;
    return;
  }

  let config;
  try {
    config = {
      secretBase64: window.MetriaPairing.bytesToBase64Url(secretBytes),
      server: normalizeServer(serverInput.value.trim() || "https://ntfy.sh")
    };
  } catch (error) {
    pairingError.textContent = error.message;
    pairingError.hidden = false;
    return;
  }
  await saveAndConnect(config);
});

async function saveAndConnect(config) {
  const connectedConfig = { ...config, server: normalizeServer(config.server) };
  localStorage.setItem(CONFIG_KEY, JSON.stringify(connectedConfig));
  serverInput.value = connectedConfig.server;
  await connect(connectedConfig);
}

document.querySelector("#changeTopic").addEventListener("click", () => {
  eventSource?.close();
  clearInterval(snapshotPollingTimer);
  localStorage.removeItem(CONFIG_KEY);
  dashboard.hidden = true;
  setup.hidden = false;
  setStatus("Not connected", "idle");
  notificationButton.hidden = true;
});

notificationButton.addEventListener("click", async () => {
  try {
    await enableNotifications();
  } catch (error) {
    notificationButton.textContent = error.message;
    notificationButton.disabled = true;
  }
});

// Extracts { secretBase64, server } from a pairing link's fragment, whether that link
// came from the address bar's hash or from a QR code scanned inside the app.
function parsePairingParams(hashString) {
  const params = new URLSearchParams(hashString);
  const secretBase64 = params.get("s");
  if (!secretBase64) return null;
  const server = params.get("server") || "https://ntfy.sh";
  return { secretBase64, server };
}

// Reads a pairing link's fragment (e.g. from opening the QR code in the system Camera
// app). The fragment never reaches any server — it's stripped from the visible URL
// immediately after reading it, so the secret doesn't linger in browser history.
function readPairingFromHash() {
  if (!location.hash) return null;
  const parsed = parsePairingParams(location.hash.slice(1));
  if (parsed) history.replaceState(null, "", location.pathname + location.search);
  return parsed;
}

scanButton?.addEventListener("click", () => {
  scannerError.hidden = true;
  scannerOverlay.hidden = false;
  window.MetriaScanner.startQrScanner({
    video: scannerVideo,
    canvas: scannerCanvas,
    onDecode: async (text) => {
      window.MetriaScanner.stopQrScanner();
      scannerOverlay.hidden = true;
      try {
        const parsed = parsePairingParams(new URL(text).hash.slice(1));
        if (!parsed) throw new Error("not a pairing link");
        await saveAndConnect(parsed);
      } catch {
        pairingError.textContent = "That QR code isn't a Metria pairing code.";
        pairingError.hidden = false;
      }
    },
    onError: (message) => {
      scannerError.textContent = message;
      scannerError.hidden = false;
    }
  });
});

scannerCancel.addEventListener("click", () => {
  window.MetriaScanner.stopQrScanner();
  scannerOverlay.hidden = true;
});

async function init() {
  if (!window.isSecureContext || !navigator.mediaDevices?.getUserMedia) {
    scanButton.hidden = true;
    cameraUnavailable.hidden = false;
  }

  const hashConfig = readPairingFromHash();
  const savedSnapshot = JSON.parse(localStorage.getItem(SNAPSHOT_KEY) || "null");
  if (savedSnapshot) renderSnapshot(savedSnapshot);

  if (hashConfig) {
    try {
      await saveAndConnect(hashConfig);
    } catch (error) {
      pairingError.textContent = error.message;
      pairingError.hidden = false;
    }
    return;
  }

  const savedConfig = JSON.parse(localStorage.getItem(CONFIG_KEY) || "null");
  if (savedConfig?.secretBase64) {
    serverInput.value = savedConfig.server;
    try {
      await saveAndConnect(savedConfig);
    } catch (error) {
      pairingError.textContent = error.message;
      pairingError.hidden = false;
    }
  }
}

init();

if (window.isSecureContext && "serviceWorker" in navigator) navigator.serviceWorker.register("sw.js");
