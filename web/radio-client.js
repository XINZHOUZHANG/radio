const SNAPSHOT_INTERVAL_MS = 500;
const REQUEST_TIMEOUT_MS = 3000;
const MAX_REQUEST_ID_BYTES = 128;


export function deriveWebSocketUrl(locationLike, port = 8765) {
  const protocol = locationLike.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${locationLike.hostname}:${port}/radio`;
}


export function reconnectDelayMs(attempt) {
  return Math.min(500 * (2 ** attempt), 5000);
}


export class RadioClient {
  constructor({
    url,
    deviceId,
    token,
    socketFactory = (socketUrl) => new globalThis.WebSocket(socketUrl),
    setTimeoutFn = globalThis.setTimeout.bind(globalThis),
    clearTimeoutFn = globalThis.clearTimeout.bind(globalThis),
    setIntervalFn = globalThis.setInterval.bind(globalThis),
    clearIntervalFn = globalThis.clearInterval.bind(globalThis),
    idFactory,
    onConnectionState = () => {},
    onCapabilities = () => {},
    onSnapshot = () => {},
    onCommandResult = () => {},
    onAuthenticationFailed = () => {},
  }) {
    if (typeof url !== "string" || url.trim() === "") {
      throw new TypeError("url must be non-empty text");
    }
    if (typeof deviceId !== "string" || deviceId.trim() === "") {
      throw new TypeError("deviceId must be non-empty text");
    }
    if (typeof token !== "string" || token === "") {
      throw new TypeError("token must be non-empty text");
    }
    if (typeof socketFactory !== "function") {
      throw new TypeError("socketFactory must be a function");
    }
    this.url = url;
    this.deviceId = deviceId;
    this._token = token;
    this._socketFactory = socketFactory;
    this._setTimeout = setTimeoutFn;
    this._clearTimeout = clearTimeoutFn;
    this._setInterval = setIntervalFn;
    this._clearInterval = clearIntervalFn;
    let sequence = 0;
    this._idFactory = idFactory || (() => `web-${Date.now().toString(36)}-${++sequence}`);
    this._onConnectionState = onConnectionState;
    this._onCapabilities = onCapabilities;
    this._onSnapshot = onSnapshot;
    this._onCommandResult = onCommandResult;
    this._onAuthenticationFailed = onAuthenticationFailed;
    this._state = "disconnected";
    this._socket = null;
    this._manualDisconnect = false;
    this._reconnectAttempt = 0;
    this._reconnectTimer = null;
    this._snapshotTimer = null;
    this._highestRevision = -1;
    this._pendingCommands = new Map();
  }

  connect() {
    if (!this._token) {
      throw new Error("a connection token is required");
    }
    if (this._socket !== null) {
      return;
    }
    this._manualDisconnect = false;
    this._clearReconnectTimer();
    this._setState("connecting");
    const socket = this._socketFactory(this.url);
    this._socket = socket;
    socket.onopen = () => this._socketOpened(socket);
    socket.onmessage = (event) => this._socketMessage(socket, event);
    socket.onclose = (event) => this._socketClosed(socket, event);
    socket.onerror = () => {};
  }

  disconnect() {
    this._manualDisconnect = true;
    this._clearReconnectTimer();
    this._stopSnapshotPolling();
    this._clearPendingCommands();
    const socket = this._socket;
    this._socket = null;
    if (socket !== null && socket.readyState !== 3) {
      socket.close(1000);
    }
    this._setState("disconnected");
  }

  requestCapabilities() {
    this._requireReady();
    this._send({ type: "rig.capabilities" });
  }

  requestSnapshot() {
    this._requireReady();
    this._send({ type: "rig.snapshot" });
  }

  setFrequency(frequencyHz) {
    if (!Number.isSafeInteger(frequencyHz) || frequencyHz <= 0) {
      throw new TypeError("frequency must be a positive integer in hertz");
    }
    return this._sendCommand("set_frequency", { frequency_hz: frequencyHz });
  }

  setMode(mode, passbandHz = 0) {
    if (typeof mode !== "string" || mode.trim() === "") {
      throw new TypeError("mode must be non-empty text");
    }
    if (!Number.isSafeInteger(passbandHz) || passbandHz < 0) {
      throw new TypeError("passband must be a non-negative integer in hertz");
    }
    return this._sendCommand("set_mode", {
      mode: mode.trim(),
      passband_hz: passbandHz,
    });
  }

  _socketOpened(socket) {
    if (socket !== this._socket || this._manualDisconnect) return;
    this._setState("authenticating");
    this._send({
      type: "auth",
      device_id: this.deviceId,
      token: this._token,
    });
  }

  _socketMessage(socket, messageEvent) {
    if (socket !== this._socket || typeof messageEvent?.data !== "string") return;
    let event;
    try {
      event = JSON.parse(messageEvent.data);
    } catch {
      return;
    }
    if (event === null || typeof event !== "object" || Array.isArray(event)) return;

    if (event.type === "auth.ok" && this._state === "authenticating") {
      this._reconnectAttempt = 0;
      this._setState("ready");
      this.requestCapabilities();
      this.requestSnapshot();
      this._startSnapshotPolling();
      return;
    }
    if (
      event.type === "error"
      && event.code === "authentication_failed"
      && this._state === "authenticating"
    ) {
      this._authenticationFailed();
      return;
    }
    if (this._state !== "ready") return;

    if (event.type === "rig.capabilities") {
      this._onCapabilities(event);
      return;
    }
    if (event.type === "rig.snapshot") {
      if (!Number.isSafeInteger(event.revision) || event.revision < 0) return;
      if (event.revision < this._highestRevision) return;
      this._highestRevision = event.revision;
      this._onSnapshot(event);
      return;
    }
    if (event.type === "rig.command_result") {
      this._acceptCommandResult(event);
      return;
    }
    if (event.type === "error" && typeof event.request_id === "string") {
      this._acceptCommandError(event);
    }
  }

  _socketClosed(socket, closeEvent) {
    if (socket !== this._socket) return;
    const previousState = this._state;
    this._socket = null;
    this._stopSnapshotPolling();
    this._clearPendingCommands();
    if (this._manualDisconnect) {
      this._setState("disconnected");
      return;
    }
    if (previousState === "authenticating" && closeEvent?.code === 1008) {
      this._authenticationFailed();
      return;
    }
    this._setState("reconnecting");
    const delay = reconnectDelayMs(this._reconnectAttempt);
    this._reconnectAttempt += 1;
    this._reconnectTimer = this._setTimeout(() => {
      this._reconnectTimer = null;
      if (!this._manualDisconnect && this._token) {
        this.connect();
      }
    }, delay);
  }

  _authenticationFailed() {
    this._token = "";
    this._manualDisconnect = true;
    this._clearReconnectTimer();
    this._stopSnapshotPolling();
    this._clearPendingCommands();
    const socket = this._socket;
    this._socket = null;
    if (socket !== null && socket.readyState !== 3) {
      socket.close(1000);
    }
    this._setState("disconnected");
    this._onAuthenticationFailed();
  }

  _startSnapshotPolling() {
    this._stopSnapshotPolling();
    this._snapshotTimer = this._setInterval(() => {
      if (this._state === "ready") {
        this.requestSnapshot();
      }
    }, SNAPSHOT_INTERVAL_MS);
  }

  _stopSnapshotPolling() {
    if (this._snapshotTimer !== null) {
      this._clearInterval(this._snapshotTimer);
      this._snapshotTimer = null;
    }
  }

  _sendCommand(command, fields) {
    this._requireReady();
    const requestId = this._newRequestId();
    const timeout = this._setTimeout(() => {
      const pending = this._pendingCommands.get(requestId);
      if (pending === undefined) return;
      this._pendingCommands.delete(requestId);
      this._onCommandResult({
        type: "rig.command_result",
        request_id: requestId,
        command: pending.command,
        status: "timeout",
        message: "request timed out",
      });
    }, REQUEST_TIMEOUT_MS);
    this._pendingCommands.set(requestId, { command, timeout });
    this._send({
      type: "rig.command",
      request_id: requestId,
      command,
      ...fields,
    });
    return requestId;
  }

  _acceptCommandResult(event) {
    if (typeof event.request_id !== "string") return;
    const pending = this._pendingCommands.get(event.request_id);
    if (pending === undefined || pending.command !== event.command) return;
    this._clearTimeout(pending.timeout);
    this._pendingCommands.delete(event.request_id);
    this._onCommandResult(event);
  }

  _acceptCommandError(event) {
    const pending = this._pendingCommands.get(event.request_id);
    if (pending === undefined) return;
    this._clearTimeout(pending.timeout);
    this._pendingCommands.delete(event.request_id);
    this._onCommandResult({
      type: "rig.command_result",
      request_id: event.request_id,
      command: pending.command,
      status: "error",
      message: typeof event.message === "string" ? event.message : "request failed",
      code: event.code,
    });
  }

  _newRequestId() {
    const requestId = this._idFactory();
    if (typeof requestId !== "string" || requestId.trim() === "") {
      throw new TypeError("request ID must be non-empty text");
    }
    if (new TextEncoder().encode(requestId).length > MAX_REQUEST_ID_BYTES) {
      throw new RangeError("request ID exceeds 128 UTF-8 bytes");
    }
    if (this._pendingCommands.has(requestId)) {
      throw new Error("request ID must be unique");
    }
    return requestId;
  }

  _send(document) {
    if (this._socket === null || this._socket.readyState !== 1) {
      throw new Error("WebSocket is not open");
    }
    this._socket.send(JSON.stringify(document));
  }

  _requireReady() {
    if (this._state !== "ready") {
      throw new Error("radio client is not ready");
    }
  }

  _clearReconnectTimer() {
    if (this._reconnectTimer !== null) {
      this._clearTimeout(this._reconnectTimer);
      this._reconnectTimer = null;
    }
  }

  _clearPendingCommands() {
    for (const pending of this._pendingCommands.values()) {
      this._clearTimeout(pending.timeout);
    }
    this._pendingCommands.clear();
  }

  _setState(state) {
    if (state === this._state) return;
    this._state = state;
    this._onConnectionState(state);
  }
}
