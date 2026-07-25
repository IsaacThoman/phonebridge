const state = {
  token: localStorage.getItem("phonebridge.token") || "",
  pendingCall: null,
  peerConnection: null,
  localStream: null,
  mediaSessionID: null,
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
  elements.connection.classList.toggle("online", paired);
  elements.connection.querySelector("span:last-child").textContent = paired
    ? label || "Connected to Mac"
    : "Pairing required";
  elements.searchInput.disabled = !paired;
  elements.searchButton.disabled = !paired;
  elements.mediaButton.disabled = !paired || !navigator.mediaDevices?.getUserMedia;
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
    elements.searchInput.focus();
  } catch (error) {
    state.token = "";
    localStorage.removeItem("phonebridge.token");
    setPaired(false);
    elements.pairDialog.showModal();
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
  if (!navigator.mediaDevices?.getUserMedia) {
    elements.mediaStatus.textContent =
      "Microphone access requires HTTPS, except when using localhost on the Mac.";
    return;
  }

  elements.mediaButton.disabled = true;
  const transportOnly = new URLSearchParams(window.location.search).has("transport-only");
  elements.mediaStatus.textContent = transportOnly
    ? "Starting transport-only diagnostic…"
    : "Requesting microphone access…";
  try {
    const peer = new RTCPeerConnection();
    state.peerConnection = peer;
    if (transportOnly) {
      peer.addTransceiver("audio", { direction: "sendrecv" });
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
      elements.mediaStatus.textContent = `WebRTC · ${peer.connectionState}`;
      if (["failed", "closed"].includes(peer.connectionState)) disconnectMedia();
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

validatePairing();
