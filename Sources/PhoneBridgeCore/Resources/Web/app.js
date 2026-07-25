const state = {
  token: localStorage.getItem("phonebridge.token") || "",
  pendingCall: null,
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

validatePairing();
