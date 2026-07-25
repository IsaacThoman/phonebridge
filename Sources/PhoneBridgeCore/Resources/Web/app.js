const state = {
  token: localStorage.getItem("phonebridge.token") || "",
  pendingCall: null,
  peerConnection: null,
  localStream: null,
  mediaSessionID: null,
  diagnosticAudio: null,
  callPollTimer: null,
};

const elements = {
  connection: document.querySelector("#connectionStatus"),
  searchForm: document.querySelector("#searchForm"),
  searchInput: document.querySelector("#contactSearch"),
  searchButton: document.querySelector("#searchForm button"),
  results: document.querySelector("#contactResults"),
  resultsTitle: document.querySelector("#resultsTitle"),
  empty: document.querySelector("#emptyState"),
  hostBadge: document.querySelector("#hostBadge"),
  pairDialog: document.querySelector("#pairDialog"),
  pairForm: document.querySelector("#pairForm"),
  pairToken: document.querySelector("#pairToken"),
  pairError: document.querySelector("#pairError"),
  callDialog: document.querySelector("#callDialog"),
  callForm: document.querySelector("#callForm"),
  callName: document.querySelector("#callName"),
  callDetail: document.querySelector("#callDetail"),
  toast: document.querySelector("#toast"),
  mediaButton: document.querySelector("#mediaButton"),
  mediaStatus: document.querySelector("#mediaStatus"),
  remoteAudio: document.querySelector("#remoteAudio"),
  liveCallPanel: document.querySelector("#liveCallPanel"),
  liveCallList: document.querySelector("#liveCallList"),
  callControlStatus: document.querySelector("#callControlStatus"),
};

async function api(path, options = {}) {
  const headers = new Headers(options.headers || {});
  if (state.token) headers.set("Authorization", `Bearer ${state.token}`);
  if (options.body && !headers.has("Content-Type")) {
    headers.set("Content-Type", "application/json");
  }
  const response = await fetch(path, { ...options, headers });
  const payload = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(payload.error || `Request failed (${response.status})`);
    error.status = response.status;
    throw error;
  }
  return payload;
}

function setPaired(paired, label = "") {
  if (!paired) {
    window.clearInterval(state.callPollTimer);
    state.callPollTimer = null;
    elements.liveCallPanel.hidden = true;
  }
  elements.connection.classList.toggle("online", paired);
  elements.connection.querySelector("span:last-child").textContent = paired
    ? label || "Connected to Mac"
    : "Pairing required";
  elements.searchInput.disabled = !paired;
  elements.searchButton.disabled = !paired;
  const transportOnly = new URLSearchParams(window.location.search).has("transport-only");
  elements.mediaButton.disabled =
    !paired || (!transportOnly && !navigator.mediaDevices?.getUserMedia);
}

async function validatePairing() {
  if (!state.token) {
    setPaired(false);
    elements.pairDialog.showModal();
    return;
  }
  try {
    const capabilities = await api("/api/capabilities");
    setPaired(true, `Connected · ${capabilities.callHost}`);
    elements.hostBadge.textContent = `${capabilities.callHost} · ${capabilities.version}`;
    elements.empty.querySelector("p").textContent =
      "Search by name, number, or email. Contact data never leaves your Mac.";
    if (capabilities.callControl) {
      elements.liveCallPanel.hidden = false;
      await refreshCalls();
      startCallPolling();
    }
    elements.searchInput.focus();
  } catch (error) {
    state.token = "";
    localStorage.removeItem("phonebridge.token");
    setPaired(false);
    elements.pairDialog.showModal();
  }
}

function startCallPolling() {
  window.clearInterval(state.callPollTimer);
  state.callPollTimer = window.setInterval(refreshCalls, 2000);
}

async function refreshCalls() {
  if (!state.token || elements.liveCallPanel.hidden) return;
  try {
    const snapshot = await api("/api/calls");
    elements.callControlStatus.textContent = snapshot.calls.length
      ? `${snapshot.calls.length} active`
      : "Ready";
    renderLiveCalls(snapshot.calls);
  } catch (error) {
    elements.callControlStatus.textContent = "Unavailable";
  }
}

function renderLiveCalls(calls) {
  elements.liveCallList.replaceChildren();
  if (!calls.length) {
    const empty = document.createElement("p");
    empty.className = "no-live-calls";
    empty.textContent = "No active calls. Incoming phone and FaceTime Audio calls appear here.";
    elements.liveCallList.append(empty);
    return;
  }

  for (const call of calls) {
    const row = document.createElement("article");
    row.className = `live-call${call.canAnswer ? " incoming" : ""}`;
    const details = document.createElement("div");
    const name = document.createElement("h3");
    name.textContent = call.displayName;
    const status = document.createElement("p");
    status.textContent = call.canAnswer
      ? "Incoming call"
      : call.onHold
        ? "On hold"
        : call.muted
          ? "Connected · muted"
          : "Connected";
    details.append(name, status);

    const actions = document.createElement("div");
    actions.className = "call-control-actions";
    const controls = call.canAnswer
      ? [["answer", "Answer"], ["hang_up", "Decline"]]
      : [
          [call.onHold ? "resume" : "hold", call.onHold ? "Resume" : "Hold"],
          [call.muted ? "unmute" : "mute", call.muted ? "Unmute" : "Mute"],
          ["hang_up", "End"],
        ];
    for (const [action, label] of controls) {
      const button = document.createElement("button");
      button.type = "button";
      button.className = `control-button ${action.replace("_", "-")}`;
      button.textContent = label;
      button.addEventListener("click", () => controlCall(action, call.id, button));
      actions.append(button);
    }
    row.append(details, actions);
    if (call.supportsDTMF && !call.canAnswer) {
      const keypad = document.createElement("div");
      keypad.className = "dtmf-pad";
      for (const digit of ["1", "2", "3", "4", "5", "6", "7", "8", "9", "*", "0", "#"]) {
        const key = document.createElement("button");
        key.type = "button";
        key.className = "dtmf-key";
        key.textContent = digit;
        key.setAttribute("aria-label", `Send DTMF ${digit}`);
        key.addEventListener("click", () => controlCall("send_dtmf", call.id, key, digit));
        keypad.append(key);
      }
      row.append(keypad);
    }
    elements.liveCallList.append(row);
  }
}

async function controlCall(action, callID, button, dtmf = null) {
  button.disabled = true;
  try {
    await api("/api/calls/control", {
      method: "POST",
      body: JSON.stringify({ action, callID, ...(dtmf ? { dtmf } : {}) }),
    });
    showToast(`${button.textContent} sent to the Mac.`);
    if (action === "send_dtmf") {
      button.disabled = false;
    } else {
      window.setTimeout(refreshCalls, 350);
    }
  } catch (error) {
    showToast(`Call control failed: ${error.message}`);
    button.disabled = false;
  }
}

elements.pairForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const candidate = elements.pairToken.value.trim();
  if (!candidate) return;
  state.token = candidate;
  elements.pairError.textContent = "";
  try {
    await api("/api/capabilities");
    localStorage.setItem("phonebridge.token", state.token);
    elements.pairDialog.close();
    await validatePairing();
  } catch (error) {
    state.token = "";
    elements.pairError.textContent = "That token was not accepted by this Mac.";
    elements.pairToken.select();
  }
});

elements.searchForm.addEventListener("submit", async (event) => {
  event.preventDefault();
  const query = elements.searchInput.value.trim();
  if (!query) return;
  elements.results.parentElement.setAttribute("aria-busy", "true");
  elements.resultsTitle.textContent = `Searching for “${query}”`;
  elements.results.replaceChildren();
  elements.empty.hidden = true;
  try {
    const contacts = await api(`/api/contacts?q=${encodeURIComponent(query)}&limit=30`);
    renderContacts(contacts, query);
  } catch (error) {
    elements.resultsTitle.textContent = "Search unavailable";
    elements.empty.hidden = false;
    elements.empty.querySelector("p").textContent = error.message;
  } finally {
    elements.results.parentElement.setAttribute("aria-busy", "false");
  }
});

function renderContacts(contacts, query) {
  elements.results.replaceChildren();
  elements.resultsTitle.textContent = contacts.length
    ? `${contacts.length} result${contacts.length === 1 ? "" : "s"} for “${query}”`
    : `No matches for “${query}”`;
  elements.empty.hidden = contacts.length > 0;
  if (!contacts.length) {
    elements.empty.querySelector("p").textContent =
      "Try a full name, phone number, or email address.";
    return;
  }

  const fragment = document.createDocumentFragment();
  for (const contact of contacts) {
    const article = document.createElement("article");
    article.className = "contact-card";
    const name = document.createElement("h3");
    name.className = "contact-name";
    name.textContent = contact.displayName;
    article.append(name);

    for (const endpoint of contact.endpoints) {
      const row = document.createElement("div");
      row.className = "endpoint";
      const details = document.createElement("div");
      const label = document.createElement("div");
      label.className = "endpoint-label";
      label.textContent = endpoint.label || endpoint.kind;
      const value = document.createElement("p");
      value.className = "endpoint-value";
      value.textContent = endpoint.value;
      details.append(label, value);

      const actions = document.createElement("div");
      actions.className = "call-actions";
      for (const service of endpoint.services) {
        const button = document.createElement("button");
        button.type = "button";
        button.className = "call-button";
        button.textContent = service === "cellular" ? "Phone" : "FaceTime";
        button.addEventListener("click", () => {
          prepareCall(contact.displayName, endpoint.value, service);
        });
        actions.append(button);
      }
      row.append(details, actions);
      article.append(row);
    }
    fragment.append(article);
  }
  elements.results.append(fragment);
}

function prepareCall(name, target, service) {
  state.pendingCall = { name, target, service };
  elements.callName.textContent = `Call ${name}?`;
  elements.callDetail.textContent = `${service === "cellular" ? "Cellular" : "FaceTime Audio"} · ${target}`;
  elements.callDialog.showModal();
}

elements.callForm.addEventListener("submit", async (event) => {
  const submitter = event.submitter;
  if (!state.pendingCall || submitter?.value === "cancel") {
    state.pendingCall = null;
    return;
  }
  event.preventDefault();
  const request = {
    service: state.pendingCall.service,
    target: state.pendingCall.target,
  };
  const label = state.pendingCall.name;
  elements.callDialog.close();
  state.pendingCall = null;
  try {
    await api("/api/calls", {
      method: "POST",
      body: JSON.stringify(request),
    });
    showToast(`Call handed to the Mac for ${label}.`);
  } catch (error) {
    showToast(`Could not start call: ${error.message}`);
  }
});

let toastTimer;
function showToast(message) {
  window.clearTimeout(toastTimer);
  elements.toast.textContent = message;
  elements.toast.classList.add("visible");
  toastTimer = window.setTimeout(() => elements.toast.classList.remove("visible"), 4200);
}

elements.mediaButton.addEventListener("click", async () => {
  if (state.peerConnection) {
    await disconnectMedia();
    return;
  }
  const transportOnly = new URLSearchParams(window.location.search).has("transport-only");
  if (!transportOnly && !navigator.mediaDevices?.getUserMedia) {
    elements.mediaStatus.textContent =
      "Microphone access requires HTTPS, except when using localhost on the Mac.";
    return;
  }

  elements.mediaButton.disabled = true;
  elements.mediaStatus.textContent = transportOnly
    ? "Starting transport-only diagnostic…"
    : "Requesting microphone access…";
  try {
    const iceServerURL = new URLSearchParams(window.location.search).get("ice-server");
    const validIceServer =
      iceServerURL && /^(stun|stuns|turn|turns):/i.test(iceServerURL) ? iceServerURL : null;
    const peer = new RTCPeerConnection({
      iceServers: validIceServer ? [{ urls: validIceServer }] : [],
    });
    state.peerConnection = peer;
    if (transportOnly) {
      const context = new AudioContext();
      const oscillator = new OscillatorNode(context, { frequency: 440 });
      const gain = new GainNode(context, { gain: 0.04 });
      const destination = context.createMediaStreamDestination();
      oscillator.connect(gain).connect(destination);
      oscillator.start();
      await context.resume();
      state.diagnosticAudio = { context, oscillator };
      peer.addTrack(destination.stream.getAudioTracks()[0], destination.stream);
    } else {
      const stream = await withTimeout(
        navigator.mediaDevices.getUserMedia({
          audio: {
            echoCancellation: true,
            noiseSuppression: true,
            autoGainControl: true,
          },
          video: false,
        }),
        15000,
        "Microphone permission timed out.",
      );
      state.localStream = stream;
      for (const track of stream.getTracks()) peer.addTrack(track, stream);
    }
    peer.addEventListener("track", (event) => {
      elements.remoteAudio.srcObject = event.streams[0] || new MediaStream([event.track]);
    });
    peer.addEventListener("connectionstatechange", () => {
      updateMediaConnectionStatus(peer, transportOnly);
      if (["failed", "closed"].includes(peer.connectionState)) disconnectMedia();
    });
    peer.addEventListener("iceconnectionstatechange", () => {
      updateMediaConnectionStatus(peer, transportOnly);
    });

    const offer = await peer.createOffer();
    await peer.setLocalDescription(offer);
    await waitForIceGathering(peer);
    const answer = await api("/api/webrtc/sessions", {
      method: "POST",
      body: JSON.stringify({
        type: peer.localDescription.type,
        sdp: peer.localDescription.sdp,
      }),
    });
    state.mediaSessionID = answer.sessionID;
    await peer.setRemoteDescription({ type: answer.type, sdp: answer.sdp });
    await waitForPeerConnection(peer, 20000);
    elements.mediaButton.textContent = "Disconnect audio";
    elements.mediaButton.classList.add("connected");
    elements.mediaButton.disabled = false;
    if (transportOnly) {
      elements.mediaStatus.textContent = `WebRTC · ${peer.connectionState} · transport-only`;
    }
  } catch (error) {
    await disconnectMedia(false);
    elements.mediaStatus.textContent = `Audio connection failed: ${error.message}`;
    elements.mediaButton.disabled = false;
  }
});

async function waitForPeerConnection(peer, timeoutMilliseconds) {
  if (["connected", "completed"].includes(peer.iceConnectionState)) return;
  await withTimeout(
    new Promise((resolve, reject) => {
      const cleanup = () => {
        peer.removeEventListener("iceconnectionstatechange", inspect);
        peer.removeEventListener("connectionstatechange", inspect);
      };
      const inspect = () => {
        if (["connected", "completed"].includes(peer.iceConnectionState)) {
          cleanup();
          resolve();
        } else if (["failed", "closed"].includes(peer.iceConnectionState)) {
          cleanup();
          reject(new Error(`WebRTC ICE ${peer.iceConnectionState}.`));
        }
      };
      peer.addEventListener("iceconnectionstatechange", inspect);
      peer.addEventListener("connectionstatechange", inspect);
      inspect();
    }),
    timeoutMilliseconds,
    "WebRTC could not establish an audio path. A TURN server may be required.",
  );
}

async function withTimeout(promise, timeoutMilliseconds, message) {
  let timer;
  try {
    return await Promise.race([
      promise,
      new Promise((_, reject) => {
        timer = window.setTimeout(() => reject(new Error(message)), timeoutMilliseconds);
      }),
    ]);
  } finally {
    window.clearTimeout(timer);
  }
}

function updateMediaConnectionStatus(peer, transportOnly) {
  const connected = ["connected", "completed"].includes(peer.iceConnectionState);
  const status = connected ? "connected" : peer.connectionState;
  elements.mediaStatus.textContent =
    `WebRTC · ${status}${transportOnly ? " · transport-only" : ""}`;
}

async function waitForIceGathering(peer) {
  if (peer.iceGatheringState === "complete") return;
  await new Promise((resolve) => {
    const timeout = window.setTimeout(resolve, 3000);
    peer.addEventListener(
      "icegatheringstatechange",
      () => {
        if (peer.iceGatheringState === "complete") {
          window.clearTimeout(timeout);
          resolve();
        }
      },
      { once: false },
    );
  });
}

async function disconnectMedia(notifyServer = true) {
  const sessionID = state.mediaSessionID;
  state.mediaSessionID = null;
  state.peerConnection?.close();
  state.peerConnection = null;
  for (const track of state.localStream?.getTracks() || []) track.stop();
  state.localStream = null;
  state.diagnosticAudio?.oscillator.stop();
  state.diagnosticAudio?.context.close();
  state.diagnosticAudio = null;
  elements.remoteAudio.srcObject = null;
  elements.mediaButton.textContent = "Connect audio";
  elements.mediaButton.classList.remove("connected");
  elements.mediaButton.disabled = !state.token;
  elements.mediaStatus.textContent =
    "Connect this browser’s microphone and speaker to the Mac over WebRTC.";
  if (notifyServer && sessionID) {
    await api(`/api/webrtc/sessions/${encodeURIComponent(sessionID)}`, {
      method: "DELETE",
    }).catch(() => {});
  }
}

window.addEventListener("pagehide", () => {
  if (!state.mediaSessionID) return;
  fetch(`/api/webrtc/sessions/${encodeURIComponent(state.mediaSessionID)}`, {
    method: "DELETE",
    headers: { Authorization: `Bearer ${state.token}` },
    keepalive: true,
  }).catch(() => {});
});

validatePairing();
