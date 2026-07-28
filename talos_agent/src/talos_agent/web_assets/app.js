// Talos Agent — Web UI
// Vanilla JS SPA. Non-streaming (SSE deferred — asynchttpserver limitation).

const API = {
  async chat(message, sessionId) {
    const resp = await fetch("/api/chat", {
      method: "POST",
      headers: { "Content-Type": "application/json" },
      body: JSON.stringify({ message, sessionId: sessionId || "" }),
    });
    if (!resp.ok) {
      const err = await resp.json();
      throw new Error(err.error || resp.statusText);
    }
    return resp.json();
  },

  async sessions() {
    const resp = await fetch("/api/sessions");
    return resp.json();
  },

  async sessionHistory(id) {
    const resp = await fetch("/api/sessions/" + id);
    return resp.json();
  },

  async search(query) {
    const resp = await fetch("/api/search?q=" + encodeURIComponent(query));
    return resp.json();
  },
};

// --- DOM refs ---
const messagesEl = document.getElementById("messages");
const inputEl = document.getElementById("user-input");
const sendBtn = document.getElementById("send-btn");
const sessionSelect = document.getElementById("session-select");
const searchToggle = document.getElementById("search-toggle");
const searchPanel = document.getElementById("search-panel");
const searchInput = document.getElementById("search-input");
const searchResults = document.getElementById("search-results");

// Tracks which backend session the next chat message resumes. Empty
// means "start a new session" — set from a chat response's sessionId,
// or when the user explicitly picks a past session to continue.
let currentSessionId = "";

// --- Helpers ---
function escapeHtml(s) {
  const div = document.createElement("div");
  div.textContent = s;
  return div.innerHTML;
}

function simpleMarkdown(text) {
  let html = escapeHtml(text);
  // Code blocks (``` ... ```)
  html = html.replace(/```(\w*)\n([\s\S]*?)```/g, "<pre><code>$2</code></pre>");
  // Inline code (`...`)
  html = html.replace(/`([^`]+)`/g, "<code>$1</code>");
  // Bold
  html = html.replace(/\*\*([^*]+)\*\*/g, "<strong>$1</strong>");
  // Italic
  html = html.replace(/\*([^*]+)\*/g, "<em>$1</em>");
  // Headers
  html = html.replace(/^### (.+)$/gm, "<h3>$1</h3>");
  html = html.replace(/^## (.+)$/gm, "<h2>$1</h2>");
  html = html.replace(/^# (.+)$/gm, "<h1>$1</h1>");
  // Unordered lists
  html = html.replace(/^- (.+)$/gm, "<li>$1</li>");
  html = html.replace(/(<li>.*<\/li>\n?)+/g, "<ul>$&</ul>");
  // Paragraphs (double newline)
  html = html.replace(/\n\n/g, "</p><p>");
  return "<p>" + html + "</p>";
}

function addMessage(role, content, opts = {}) {
  const div = document.createElement("div");
  div.className = "message " + role;

  if (role !== "user") {
    const label = document.createElement("div");
    label.className = "role-label";
    label.textContent = role === "system" ? "system" : "Talos";
    div.appendChild(label);
  }

  const contentEl = document.createElement("div");
  contentEl.className = "content";
  contentEl.innerHTML = simpleMarkdown(content);
  div.appendChild(contentEl);

  if (opts.toolCalls && opts.toolCalls.length > 0) {
    for (const tc of opts.toolCalls) {
      const tcEl = document.createElement("div");
      tcEl.className = "tool-call";
      tcEl.innerHTML = '<span class="tool-name">' + escapeHtml(tc.name) + '</span>' +
        '<span class="tool-args">' + escapeHtml(tc.arguments) + '</span>';
      div.appendChild(tcEl);
    }
  }

  if (opts.stats) {
    const statsEl = document.createElement("div");
    statsEl.className = "stats";
    statsEl.textContent =
      (opts.stats.totalTurns || 0) + " turns · " +
      (opts.stats.totalTokens || 0) + " tokens";
    div.appendChild(statsEl);
  }

  messagesEl.appendChild(div);
  scrollToBottom();
  return div;
}

function scrollToBottom() {
  const container = document.getElementById("chat-container");
  container.scrollTop = container.scrollHeight;
}

function setLoading(loading) {
  sendBtn.disabled = loading;
  inputEl.disabled = loading;
  if (loading) {
    sendBtn.textContent = "...";
  } else {
    sendBtn.textContent = "Send";
  }
}

// --- Send message ---
async function sendMessage() {
  const text = inputEl.value.trim();
  if (!text) return;
  inputEl.value = "";
  inputEl.style.height = "auto";
  setLoading(true);

  addMessage("user", text);

  // Show loading indicator.
  const loadingEl = document.createElement("div");
  loadingEl.className = "loading-indicator";
  loadingEl.textContent = "Thinking...";
  messagesEl.appendChild(loadingEl);
  scrollToBottom();

  try {
    const result = await API.chat(text, currentSessionId);
    // Remove loading indicator.
    if (loadingEl.parentNode) loadingEl.parentNode.removeChild(loadingEl);

    addMessage("assistant", result.text, {
      stats: result.stats,
    });

    if (result.stopReason && result.stopReason !== "finished") {
      addMessage("system", "Stop reason: " + result.stopReason);
    }
    currentSessionId = result.sessionId || currentSessionId;
    await refreshSessions();
    sessionSelect.value = currentSessionId;
  } catch (e) {
    if (loadingEl.parentNode) loadingEl.parentNode.removeChild(loadingEl);
    addMessage("system", "Error: " + e.message);
  } finally {
    setLoading(false);
  }
}

// --- Session management ---
async function refreshSessions() {
  try {
    const sessions = await API.sessions();
    const currentVal = sessionSelect.value;
    sessionSelect.innerHTML = '<option value="">+ New session</option>';
    for (const s of sessions) {
      const opt = document.createElement("option");
      opt.value = s.id;
      const date = s.updatedAt ? s.updatedAt.slice(0, 16).replace("T", " ") : "";
      opt.textContent = date + " (" + s.messageCount + " msgs)";
      sessionSelect.appendChild(opt);
    }
    sessionSelect.value = currentVal;
  } catch (e) {
    console.error("Failed to load sessions:", e);
  }
}

async function loadSession(id) {
  try {
    const data = await API.sessionHistory(id);
    messagesEl.innerHTML = "";
    for (const msg of data.messages) {
      addMessage(msg.role, msg.content, { toolCalls: msg.toolCalls });
    }
  } catch (e) {
    console.error("Failed to load session:", e);
  }
}

// --- Search ---
let searchVisible = false;

function toggleSearch() {
  searchVisible = !searchVisible;
  searchPanel.classList.toggle("hidden", !searchVisible);
  if (searchVisible) {
    searchInput.focus();
  } else {
    searchResults.innerHTML = "";
    searchInput.value = "";
  }
}

async function doSearch(query) {
  if (!query.trim()) {
    searchResults.innerHTML = "";
    return;
  }
  try {
    const results = await API.search(query);
    searchResults.innerHTML = "";
    for (const r of results) {
      const div = document.createElement("div");
      div.className = "search-result";
      div.innerHTML =
        '<div class="session-id">' + escapeHtml(r.sessionId || "") + " · " + escapeHtml(r.role || "") + '</div>' +
        '<div class="snippet">' + escapeHtml(r.snippet || r.content || "").slice(0, 200) + '</div>';
      div.onclick = () => {
        toggleSearch();
        currentSessionId = r.sessionId || "";
        sessionSelect.value = currentSessionId;
        loadSession(r.sessionId);
      };
      searchResults.appendChild(div);
    }
    if (results.length === 0) {
      searchResults.innerHTML = '<div class="search-result">No results</div>';
    }
  } catch (e) {
    console.error("Search failed:", e);
  }
}

// --- Event listeners ---
sendBtn.addEventListener("click", sendMessage);

inputEl.addEventListener("keydown", (e) => {
  if (e.key === "Enter" && !e.shiftKey) {
    e.preventDefault();
    sendMessage();
  }
});

// Auto-resize textarea.
inputEl.addEventListener("input", () => {
  inputEl.style.height = "auto";
  inputEl.style.height = Math.min(inputEl.scrollHeight, 120) + "px";
});

sessionSelect.addEventListener("change", () => {
  const id = sessionSelect.value;
  currentSessionId = id;
  if (id) {
    loadSession(id);
  } else {
    messagesEl.innerHTML = "";
  }
});

searchToggle.addEventListener("click", toggleSearch);

searchInput.addEventListener("keydown", (e) => {
  if (e.key === "Enter") {
    doSearch(searchInput.value);
  }
});

// --- Init ---
refreshSessions();