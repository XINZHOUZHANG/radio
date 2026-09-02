import { deriveWebSocketUrl, RadioClient } from "./radio-client.js";


const SESSION_TOKEN_KEY = "remote-radio-test-token";
const DEVICE_ID = "web-test";
const CONNECTION_LABELS = {
  disconnected: "未连接",
  connecting: "正在连接",
  authenticating: "正在认证",
  ready: "已连接",
  reconnecting: "正在重连",
};
const LIFECYCLE_LABELS = {
  offline: "离线",
  connecting: "连接电台",
  discovering: "读取能力",
  ready: "接收就绪",
  degraded: "连接降级",
  faulted: "连接故障",
  closing: "正在关闭",
};


export function formatFrequency(frequencyHz) {
  if (!Number.isSafeInteger(frequencyHz) || frequencyHz < 0) return "—";
  const megahertz = Math.floor(frequencyHz / 1_000_000);
  const remainder = String(frequencyHz % 1_000_000).padStart(6, "0");
  return `${megahertz}.${remainder.slice(0, 3)}.${remainder.slice(3)}`;
}


export function snapshotView(snapshot) {
  const meters = snapshot?.meters;
  const swr = meters !== null && typeof meters === "object" ? meters.SWR : null;
  return {
    revision: Number.isSafeInteger(snapshot?.revision) ? snapshot.revision : 0,
    lifecycle:
      typeof snapshot?.lifecycle === "string" ? snapshot.lifecycle : "offline",
    frequencyText: formatFrequency(snapshot?.frequency_hz),
    modeText:
      typeof snapshot?.mode === "string" && snapshot.mode.trim() !== ""
        ? snapshot.mode
        : "—",
    swrText:
      typeof swr === "number" && Number.isFinite(swr) ? swr.toFixed(1) : "—",
  };
}


export function memoryCommand(element) {
  const frequencyText = element?.dataset?.frequencyHz;
  const modeText = element?.dataset?.mode;
  if (
    typeof frequencyText !== "string"
    || !/^\d+$/.test(frequencyText)
    || typeof modeText !== "string"
    || modeText.trim() === ""
  ) {
    throw new TypeError("memory data is invalid");
  }
  const frequencyHz = Number(frequencyText);
  if (!Number.isSafeInteger(frequencyHz) || frequencyHz <= 0) {
    throw new TypeError("memory frequency is invalid");
  }
  return { frequencyHz, mode: modeText.trim() };
}


export function initializeDashboard(documentLike, windowLike) {
  const root = documentLike.getElementById("rr-widget-v3");
  if (root === null || root.dataset.initialized === "true") return;
  root.dataset.initialized = "true";

  const connectionForm = documentLike.getElementById("connection-form");
  const tokenInput = documentLike.getElementById("device-token");
  const connectionState = documentLike.getElementById("connection-state");
  const connectionDetail = documentLike.getElementById("connection-detail");
  const frequency = documentLike.getElementById("rr-frequency-v3");
  const rigState = documentLike.getElementById("rr-rig-state-v3");
  const modeSelect = documentLike.getElementById("mode-select");
  const swrValue = documentLike.getElementById("swr-value");
  const revisionValue = documentLike.getElementById("snapshot-revision");
  const activity = documentLike.getElementById("activity-message");
  const refreshButton = documentLike.getElementById("refresh-state");
  const memoryButtons = Array.from(
    documentLike.querySelectorAll("[data-frequency-hz][data-mode]"),
  );

  let client = null;
  let clientState = "disconnected";
  let capabilities = null;
  let confirmedSnapshot = null;
  const requestOwners = new Map();

  function readSessionToken() {
    try {
      return windowLike.sessionStorage.getItem(SESSION_TOKEN_KEY);
    } catch {
      return null;
    }
  }

  function storeSessionToken(token) {
    try {
      windowLike.sessionStorage.setItem(SESSION_TOKEN_KEY, token);
    } catch {
      // A private browser session may deny storage; the in-memory token still works.
    }
  }

  function clearSessionToken() {
    try {
      windowLike.sessionStorage.removeItem(SESSION_TOKEN_KEY);
    } catch {
      // Storage denial does not prevent clearing the in-memory client token.
    }
  }

  function showConnectionForm(show) {
    connectionForm.hidden = !show;
    connectionForm.setAttribute("aria-hidden", show ? "false" : "true");
  }

  function setActivity(message, tone = "neutral") {
    activity.textContent = message;
    activity.dataset.tone = tone;
  }

  function advertisedModes() {
    if (!Array.isArray(capabilities?.modes)) return [];
    return capabilities.modes.filter(
      (mode) => typeof mode === "string" && mode.trim() !== "",
    );
  }

  function controlsAreReady() {
    return (
      clientState === "ready"
      && confirmedSnapshot?.lifecycle === "ready"
      && capabilities !== null
    );
  }

  function syncControlAvailability() {
    const ready = controlsAreReady();
    const modes = advertisedModes();
    modeSelect.disabled = !ready || modes.length === 0;
    refreshButton.disabled = clientState !== "ready";
    for (const button of memoryButtons) {
      button.disabled = !ready || !modes.includes(button.dataset.mode);
    }
  }

  function renderConnectionState(state) {
    clientState = state;
    connectionState.textContent = CONNECTION_LABELS[state] || state;
    connectionState.dataset.state = state;
    root.dataset.connection = state;
    if (state === "ready") {
      showConnectionForm(false);
      tokenInput.value = "";
      connectionDetail.textContent = "控制面已认证 · 等待电台快照";
    } else if (state === "reconnecting") {
      capabilities = null;
      confirmedSnapshot = null;
      connectionDetail.textContent = "网络中断，正在按退避策略重连";
    } else if (state === "connecting" || state === "authenticating") {
      connectionDetail.textContent = "令牌仅保留在当前浏览器会话";
    }
    if (state !== "ready") {
      for (const owner of requestOwners.values()) {
        owner.removeAttribute("aria-busy");
      }
      requestOwners.clear();
    }
    syncControlAvailability();
  }

  function populateModes(event) {
    capabilities = event;
    const modes = advertisedModes();
    while (modeSelect.firstChild !== null) {
      modeSelect.removeChild(modeSelect.firstChild);
    }
    if (modes.length === 0) {
      const option = documentLike.createElement("option");
      option.textContent = "后台未报告模式";
      option.value = "";
      modeSelect.appendChild(option);
    } else {
      for (const mode of modes) {
        const option = documentLike.createElement("option");
        option.value = mode;
        option.textContent = mode;
        modeSelect.appendChild(option);
      }
    }
    const model = event?.identity?.model;
    connectionDetail.textContent =
      typeof model === "string" ? `Hamlib ${model} · 能力已加载` : "能力已加载";
    if (
      typeof confirmedSnapshot?.mode === "string"
      && modes.includes(confirmedSnapshot.mode)
    ) {
      modeSelect.value = confirmedSnapshot.mode;
    }
    syncControlAvailability();
  }

  function renderSnapshot(event) {
    confirmedSnapshot = event;
    const view = snapshotView(event);
    frequency.textContent = view.frequencyText;
    swrValue.textContent = view.swrText;
    revisionValue.textContent = String(view.revision);
    rigState.textContent = `${LIFECYCLE_LABELS[view.lifecycle] || view.lifecycle} · ${view.modeText}`;
    root.dataset.lifecycle = view.lifecycle;
    const modes = advertisedModes();
    if (typeof event.mode === "string" && modes.includes(event.mode)) {
      modeSelect.value = event.mode;
    }
    for (const button of memoryButtons) {
      const command = memoryCommand(button);
      button.classList.toggle(
        "rr-active",
        command.frequencyHz === event.frequency_hz && command.mode === event.mode,
      );
    }
    syncControlAvailability();
  }

  function trackRequest(requestId, owner) {
    requestOwners.set(requestId, owner);
    owner.setAttribute("aria-busy", "true");
  }

  function renderCommandResult(event) {
    const owner = requestOwners.get(event.request_id);
    requestOwners.delete(event.request_id);
    if (owner !== undefined && !Array.from(requestOwners.values()).includes(owner)) {
      owner.removeAttribute("aria-busy");
    }
    const status = typeof event.status === "string" ? event.status : "error";
    const message = typeof event.message === "string" ? event.message : "请求失败";
    setActivity(`${status} · ${message}`, status === "confirmed" ? "success" : "error");
  }

  function authenticationFailed() {
    clearSessionToken();
    capabilities = null;
    confirmedSnapshot = null;
    showConnectionForm(true);
    tokenInput.value = "";
    connectionDetail.textContent = "认证失败，请重新输入启动令牌";
    setActivity("authentication_failed · 连接令牌无效", "error");
    syncControlAvailability();
    tokenInput.focus();
  }

  function connectWithToken(token) {
    if (client !== null) client.disconnect();
    capabilities = null;
    confirmedSnapshot = null;
    client = new RadioClient({
      url: deriveWebSocketUrl(windowLike.location),
      deviceId: DEVICE_ID,
      token,
      onConnectionState: renderConnectionState,
      onCapabilities: populateModes,
      onSnapshot: renderSnapshot,
      onCommandResult: renderCommandResult,
      onAuthenticationFailed: authenticationFailed,
    });
    setActivity("正在建立认证 WebSocket…");
    client.connect();
  }

  connectionForm.addEventListener("submit", (event) => {
    event.preventDefault();
    const token = tokenInput.value.trim();
    if (token === "") {
      setActivity("请输入启动时显示的临时令牌", "error");
      return;
    }
    storeSessionToken(token);
    connectWithToken(token);
  });

  refreshButton.addEventListener("click", () => {
    if (clientState !== "ready" || client === null) return;
    try {
      client.requestSnapshot();
      setActivity("已请求最新电台快照");
    } catch (error) {
      setActivity(error.message, "error");
    }
  });

  modeSelect.addEventListener("change", () => {
    if (client === null || modeSelect.disabled) return;
    const requestedMode = modeSelect.value;
    const confirmedMode = confirmedSnapshot?.mode;
    try {
      const requestId = client.setMode(requestedMode, 0);
      trackRequest(requestId, modeSelect);
      setActivity(`正在请求模式 ${requestedMode}，等待后端确认…`);
    } catch (error) {
      setActivity(error.message, "error");
    } finally {
      if (typeof confirmedMode === "string") modeSelect.value = confirmedMode;
    }
  });

  for (const button of memoryButtons) {
    button.addEventListener("click", () => {
      if (client === null || button.disabled) return;
      try {
        const command = memoryCommand(button);
        trackRequest(client.setFrequency(command.frequencyHz), button);
        trackRequest(client.setMode(command.mode, 0), button);
        setActivity("频率与模式已发送，等待确认快照…");
      } catch (error) {
        setActivity(error.message, "error");
      }
    });
  }

  showConnectionForm(true);
  renderConnectionState("disconnected");
  setActivity("输入服务启动时输出的临时令牌");
  syncControlAvailability();
  const sessionToken = readSessionToken();
  if (typeof sessionToken === "string" && sessionToken !== "") {
    connectWithToken(sessionToken);
  }
}


if (typeof document !== "undefined" && typeof window !== "undefined") {
  const start = () => initializeDashboard(document, window);
  if (document.readyState === "loading") {
    document.addEventListener("DOMContentLoaded", start, { once: true });
  } else {
    start();
  }
}
