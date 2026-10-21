"use strict";

const $ = (id) => document.getElementById(id);
const state = {
  token: "",
  snapshot: null,
  selected: null,
  preview: null,
  request: null,
  run: null,
  accepted: false,
  sources: [],
  nextCursor: "",
  busy: false,
  watch: 0,
  selection: 0,
  listing: 0,
  abort: new AbortController(),
  outputSignature: "",
  interactions: new Map(),
};
const pendingKey = "mindwire-handoff-request-v1";
const bytes = (value) => new TextEncoder().encode(value).length;
const enc = encodeURIComponent;
const terminal = (run) => ["done", "error", "cancelled"].includes(run.status);
const uid = () => {
  // randomUUID requires HTTPS on phones; getRandomValues also works on a LAN.
  const data = crypto.getRandomValues(new Uint8Array(16));
  return Array.from(data, (byte) => byte.toString(16).padStart(2, "0")).join(
    "",
  );
};

function element(tag, text, className) {
  const node = document.createElement(tag);
  if (text !== undefined) node.textContent = text;
  if (className) node.className = className;
  return node;
}

function notice(message, error = false) {
  $("notice").textContent = message;
  $("notice").className = error ? "notice error" : "notice";
  $("notice").hidden = !message;
}

async function api(path, method = "GET", body) {
  const response = await fetch(path, {
    method,
    credentials: "omit",
    cache: "no-store",
    signal: state.abort.signal,
    headers: {
      Authorization: `Bearer ${state.token}`,
      ...(body === undefined ? {} : { "Content-Type": "application/json" }),
    },
    ...(body === undefined ? {} : { body: JSON.stringify(body) }),
  });
  const raw = await response.text();
  let data;
  try {
    data = raw ? JSON.parse(raw) : null;
  } catch {
    data = null;
  }
  if (!response.ok) {
    if (response.status === 401)
      throw new Error(
        "Access token rejected. Disconnect and reconnect with this computer’s current token.",
      );
    throw new Error(
      data?.error || `The computer returned HTTP ${response.status}.`,
    );
  }
  return data;
}

function savePending(run = state.run) {
  if (!state.selected || !state.request) return;
  try {
    // The token is never stored. This reviewed request survives a mobile reload.
    sessionStorage.setItem(
      pendingKey,
      JSON.stringify({
        workspaceId: state.snapshot.workspaceId,
        sourceChatId: state.selected.chatId,
        request: state.request,
        run: run
          ? { id: run.id, chatId: run.chatId, status: run.status }
          : null,
      }),
    );
  } catch {
    /* Private browsing may deny storage; in-memory retry still works. */
  }
}

function pending() {
  try {
    const value = JSON.parse(sessionStorage.getItem(pendingKey));
    if (
      value?.workspaceId !== state.snapshot?.workspaceId ||
      !value.sourceChatId ||
      !value.request?.newChatId ||
      !value.request?.requestId ||
      !value.request?.targetAgentId ||
      typeof value.request.task !== "string" ||
      typeof value.request.context !== "string" ||
      bytes(value.request.context) > 32768
    )
      return null;
    return value;
  } catch {
    return null;
  }
}

function controls() {
  const locked = !!state.request;
  for (const id of ["target", "task", "context"])
    $(id).disabled = locked || state.busy;
  for (const button of document.querySelectorAll("[data-task]"))
    button.disabled = locked || state.busy;
  $("start").disabled =
    state.busy ||
    state.accepted ||
    !state.preview ||
    !$("target").value ||
    !$("task").value.trim() ||
    bytes($("task").value.trim()) > 4096 ||
    bytes($("context").value) > 32768;
  $("start").textContent = state.busy
    ? "Starting…"
    : state.accepted
      ? "Handoff started"
      : locked
        ? "Retry handoff"
        : "Start handoff →";
  $("context-size").textContent =
    `${(bytes($("context").value) / 1024).toFixed(1)} KB`;
  const hint =
    bytes($("context").value) > 32768
      ? "Shorten the context to 32 KB before sending."
      : bytes($("task").value.trim()) > 4096
        ? "Shorten the next task before sending."
        : state.preview?.truncated
          ? "These are excerpts. Add any missing decisions or remaining work."
          : state.preview?.historySource === "recorded"
            ? "Using recorded history. Check the context for missing information."
            : "";
  $("context-note").textContent = hint;
}

$("connect-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  $("connect").disabled = true;
  $("connect").textContent = "Connecting…";
  notice("");
  state.abort.abort();
  state.abort = new AbortController();
  state.token = $("token").value.trim();
  try {
    const health = await api("/healthz");
    if (!(health.crossAgentHandoffVersion >= 1))
      throw new Error(
        "Update this computer’s Mindwire service to use agent handoffs.",
      );
    state.snapshot = await api("/workspace");
    $("token").value = "";
    $("connect-panel").hidden = true;
    $("workspace").hidden = false;
    $("disconnect").hidden = false;
    $("connection-state").textContent = "Connected";
    $("connection-state").parentElement.classList.add("connected");
    $("recover").hidden = !pending();
    await loadSources();
  } catch (error) {
    state.token = "";
    notice(error.message, true);
  } finally {
    $("connect").disabled = false;
    $("connect").textContent = "Connect ↗";
  }
});

$("disconnect").addEventListener("click", () => {
  state.abort.abort();
  state.watch++;
  state.selection++;
  state.listing++;
  state.token = "";
  state.snapshot = null;
  state.selected = null;
  state.preview = null;
  state.request = null;
  state.run = null;
  state.accepted = false;
  state.sources = [];
  state.interactions.clear();
  $("workspace").hidden = true;
  $("connect-panel").hidden = false;
  $("disconnect").hidden = true;
  $("connection-state").textContent = "Not connected";
  $("connection-state").parentElement.classList.remove("connected");
  for (const id of ["sources", "run-output", "run-interactions", "target"])
    $(id).replaceChildren();
  for (const id of ["task", "context", "search"]) $(id).value = "";
  $("handoff-form").hidden = true;
  $("selection-hint").hidden = false;
  $("run-content").hidden = true;
  $("run-empty").hidden = false;
  try {
    sessionStorage.removeItem(pendingKey);
  } catch {
    /* Storage is optional. */
  }
  notice("");
  $("token").focus();
});

function sourceMetadata(item) {
  const chat = state.snapshot.chats.find((chat) => chat.id === item.chatId);
  const profile = state.snapshot.agents.find(
    (agent) => agent.id === (item.agentId || chat?.agentId),
  );
  const project = state.snapshot.projects.find(
    (project) => project.id === (item.projectId || chat?.projectId),
  );
  return {
    ...item,
    title: item.title || chat?.title || "Untitled conversation",
    agentId: profile?.id,
    agentType: item.agentType || profile?.agentType,
    agentName: item.agentName || profile?.name || item.agentType || "Agent",
    projectName: item.projectName || project?.name,
    cwd: item.cwd || project?.path,
  };
}

async function loadSources(refresh = false, append = false) {
  const generation = ++state.listing;
  $("refresh").disabled = true;
  $("load-more").disabled = true;
  const search = $("search").value.trim();
  try {
    const query = new URLSearchParams({ limit: "30", search });
    if (refresh) query.set("refresh", "true");
    if (append && state.nextCursor) query.set("cursor", state.nextCursor);
    const page = await api(`/workspace/conversations?${query}`);
    if (generation !== state.listing) return;
    const items = page.items.map(sourceMetadata);
    state.sources = append ? state.sources.concat(items) : items;
    if (!append) {
      const linked = new Set(
        state.sources.map((item) => item.chatId).filter(Boolean),
      );
      for (const chat of state.snapshot.chats) {
        if (
          !linked.has(chat.id) &&
          (!search || chat.title.toLowerCase().includes(search.toLowerCase()))
        ) {
          state.sources.push(
            sourceMetadata({ chatId: chat.id, title: chat.title }),
          );
        }
      }
    }
    state.nextCursor = page.nextCursor || "";
    $("load-more").hidden = !state.nextCursor;
    renderSources();
    if (page.issues?.length)
      notice(
        "Some conversation history could not be loaded. You can use the available conversations or try Refresh.",
      );
  } catch (error) {
    if (generation === state.listing && error.name !== "AbortError")
      notice(error.message, true);
  } finally {
    if (generation === state.listing) {
      $("refresh").disabled = false;
      $("load-more").disabled = false;
    }
  }
}

function renderSources() {
  $("sources").replaceChildren();
  if (!state.sources.length)
    $("sources").append(
      element(
        "p",
        "No conversations found. Start a conversation with one of your agents on this computer, then refresh.",
        "empty-list",
      ),
    );
  for (const item of state.sources) {
    const button = element("button", undefined, "conversation");
    const selected =
      !!state.selected &&
      (item.chatId
        ? item.chatId === state.selected.chatId
        : item.id === state.selected.id);
    button.classList.toggle("selected", selected);
    button.setAttribute("aria-pressed", String(selected));
    button.append(element("strong", item.title));
    const meta = element("span", undefined, "meta");
    meta.append(
      element("span", undefined, "agent-dot"),
      element(
        "span",
        [item.agentName, item.projectName].filter(Boolean).join(" · "),
      ),
    );
    button.append(meta);
    button.disabled = state.busy;
    button.addEventListener("click", () => selectSource(item));
    $("sources").append(button);
  }
}

function targets(source) {
  $("target").replaceChildren();
  const profiles = state.snapshot.agents.filter(
    (agent) =>
      agent.agentType !== source.agentType && agent.installation !== "missing",
  );
  for (const profile of profiles) {
    const option = element(
      "option",
      `${profile.name} · ${profile.agentTypeName || profile.agentType}`,
    );
    option.value = profile.id;
    $("target").append(option);
  }
  $("target-hint").textContent = profiles.length
    ? "A different agent, with its own settings and approvals."
    : "Connect another agent on this computer, then refresh the page to continue.";
}

async function selectSource(item) {
  if (state.busy) return;
  const generation = ++state.selection;
  state.preview = null;
  state.request = null;
  state.accepted = false;
  state.run = null;
  state.watch++;
  state.interactions.clear();
  $("run-interactions").replaceChildren();
  $("run-content").hidden = true;
  $("run-empty").hidden = false;
  $("handoff-form").hidden = true;
  $("selection-hint").hidden = false;
  $("selection-hint").textContent = "Reading conversation context…";
  notice("");
  try {
    if (!item.chatId) {
      const opened = await api("/workspace/conversations/open", "POST", {
        id: item.id,
        ...(item.agentId ? { agentId: item.agentId } : {}),
      });
      if (generation !== state.selection) return;
      state.snapshot = opened.snapshot;
      item.chatId = opened.chatId;
    }
    state.selected = sourceMetadata(item);
    const latest = await api(`/chats/${enc(item.chatId)}/run`);
    if (generation !== state.selection) return;
    if (latest?.status === "running") {
      $("selection-hint").textContent =
        "This conversation is working. Follow its activity, then select it again when the turn finishes.";
      renderSources();
      showRun(latest, false);
      return;
    }
    const preview = await api(`/chats/${enc(item.chatId)}/handoff`);
    if (generation !== state.selection) return;
    state.selected = sourceMetadata(item);
    state.preview = preview;
    state.run = null;
    state.watch++;
    state.outputSignature = "";
    state.interactions.clear();
    $("run-interactions").replaceChildren();
    $("run-content").hidden = true;
    $("run-empty").hidden = false;
    $("run-status").textContent = "Ready when you are";
    $("run-status").className = "status-pill";
    $("source-title").textContent = state.selected.title;
    $("source-detail").textContent = [
      state.selected.agentName,
      state.selected.projectName,
    ]
      .filter(Boolean)
      .join(" · ");
    $("context").value = preview.context;
    $("task").value = "";
    targets(state.selected);
    $("selection-hint").hidden = true;
    $("handoff-form").hidden = false;
    controls();
    renderSources();
    if (matchMedia("(max-width: 680px)").matches)
      $("handoff-panel").scrollIntoView({ behavior: "smooth", block: "start" });
    // Reading an existing handoff's latest run never restarts it.
    const chat = state.snapshot.chats.find((chat) => chat.id === item.chatId);
    if (chat?.handoffFrom) {
      if (generation === state.selection && latest) showRun(latest, false);
    }
  } catch (error) {
    if (generation === state.selection && error.name !== "AbortError") {
      $("selection-hint").textContent =
        "This conversation is not ready for a handoff. Choose another or wait for its current turn to finish.";
      notice(error.message, true);
    }
  }
}

$("handoff-form").addEventListener("submit", async (event) => {
  event.preventDefault();
  if (state.busy || state.accepted || !state.selected || $("start").disabled)
    return;
  state.request ||= {
    newChatId: uid(),
    requestId: uid(),
    targetAgentId: $("target").value,
    task: $("task").value.trim(),
    context: $("context").value,
  };
  state.busy = true;
  state.run = null;
  state.watch++;
  controls();
  renderSources();
  savePending();
  notice("");
  const sourceID = state.selected.chatId;
  try {
    const result = await api(
      `/chats/${enc(sourceID)}/handoff`,
      "POST",
      state.request,
    );
    if (
      result.chatId !== state.request.newChatId ||
      result.run.chatId !== result.chatId
    )
      throw new Error(
        "Unexpected handoff response. Retry to recover your task.",
      );
    state.snapshot = result.snapshot;
    showRun(result.run);
    notice(
      "Handoff started. You can leave this page; the task continues on your computer.",
    );
    $("run-panel").scrollIntoView({ behavior: "smooth", block: "start" });
  } catch (error) {
    if (error.name !== "AbortError") {
      notice(
        `${error.message} Retry uses the same destination and request.`,
        true,
      );
      $("recover").hidden = !pending();
    }
  } finally {
    state.busy = false;
    controls();
    renderSources();
  }
});

function showRun(run, ownHandoff = true) {
  state.run = run;
  state.outputSignature = "";
  state.interactions.clear();
  $("run-interactions").replaceChildren();
  $("run-output").replaceChildren();
  $("run-empty").hidden = true;
  $("run-content").hidden = false;
  $("open-result").hidden = !ownHandoff;
  state.accepted = ownHandoff;
  if (ownHandoff) {
    savePending(run);
    $("recover").hidden = true;
    controls();
  }
  watchRun(run);
}

async function watchRun(run) {
  const generation = ++state.watch;
  $("resume-watch").hidden = true;
  while (generation === state.watch && state.token) {
    try {
      const snapshot = await api(`/runs/${enc(run.id)}/snapshot`);
      if (generation !== state.watch) return;
      state.run = snapshot.run;
      const labels = {
        running: "Working",
        done: "Finished",
        error: "Needs attention",
        cancelled: "Stopped",
      };
      const waiting = (snapshot.parts || []).some(
        (part) => part.interaction?.needsResponse && !part.interaction.response,
      );
      $("run-status").textContent = waiting
        ? "Your input needed"
        : labels[snapshot.run.status] || snapshot.run.status;
      $("run-status").className = `status-pill ${snapshot.run.status}`;
      $("cancel-run").hidden = terminal(snapshot.run);
      $("open-result").disabled = !terminal(snapshot.run);
      const chat = state.snapshot.chats.find(
        (chat) => chat.id === snapshot.run.chatId,
      );
      const profile = state.snapshot.agents.find(
        (agent) => agent.id === (chat?.agentId || state.request?.targetAgentId),
      );
      const project = state.snapshot.projects.find(
        (project) => project.id === chat?.projectId,
      );
      $("run-detail").textContent = [
        profile?.name || snapshot.run.agent || "Agent",
        project?.name,
      ]
        .filter(Boolean)
        .join(" · ");
      renderOutput(snapshot.parts || [], snapshot.run);
      renderInteractions(
        (snapshot.parts || [])
          .filter(
            (part) =>
              part.interaction?.needsResponse && !part.interaction.response,
          )
          .map((part) => part.interaction),
      );
      if (snapshot.run.error) notice(snapshot.run.error, true);
      if (terminal(snapshot.run)) return;
    } catch (error) {
      if (generation !== state.watch || error.name === "AbortError") return;
      notice(
        `Activity disconnected. ${error.message} Your task may still be running.`,
        true,
      );
      $("resume-watch").hidden = false;
      return;
    }
    await new Promise((resolve) =>
      setTimeout(resolve, document.hidden ? 4000 : 1200),
    );
  }
}

function renderOutput(parts, run) {
  const visible = parts.filter(
    (part) => part.type === "text" || part.type === "tool",
  );
  const signature = JSON.stringify([visible, run.status]);
  if (signature === state.outputSignature) return;
  state.outputSignature = signature;
  const output = $("run-output");
  const follow =
    output.scrollHeight - output.scrollTop - output.clientHeight < 60;
  output.replaceChildren();
  for (const part of visible) {
    if (part.type === "text")
      output.append(element("p", part.text || "", "output-text"));
    else if (part.tool) {
      const card = element("details", undefined, "tool-card");
      card.append(
        element(
          "summary",
          part.tool.action?.title || part.tool.name || "Tool activity",
        ),
      );
      if (part.tool.output) card.append(element("pre", part.tool.output));
      output.append(card);
    }
  }
  if (!visible.length)
    output.append(
      element(
        "p",
        terminal(run)
          ? "The task ended without visible text output."
          : "Waiting for the agent’s first response…",
        "muted",
      ),
    );
  if (follow) output.scrollTop = output.scrollHeight;
}

function renderInteractions(interactions) {
  const wanted = new Set(interactions.map((item) => item.id));
  for (const [id, node] of state.interactions) {
    if (!wanted.has(id)) {
      node.remove();
      state.interactions.delete(id);
    }
  }
  for (const interaction of interactions) {
    if (!interaction.id || state.interactions.has(interaction.id)) continue;
    const form = element("form", undefined, "interaction");
    form.append(element("h3", interaction.title || "Your input is needed"));
    if (interaction.detail) form.append(element("p", interaction.detail));
    const error = element("p");
    error.setAttribute("role", "alert");
    const originRun = state.run;
    const submit = async (reply) => {
      if (state.run?.id !== originRun.id) return;
      for (const button of form.querySelectorAll("button"))
        button.disabled = true;
      error.textContent = "";
      try {
        await api(
          `/runs/${enc(interaction.runId || originRun.id)}/respond`,
          "POST",
          { interactionId: interaction.id, ...reply },
        );
        if (state.run?.id !== originRun.id) return;
        form.remove();
        state.interactions.delete(interaction.id);
        const latest = await api(`/chats/${enc(originRun.chatId)}/run`);
        if (state.run?.id !== originRun.id) return;
        if (latest?.id && latest.id !== state.run.id) showRun(latest);
        else watchRun(state.run);
      } catch (failure) {
        error.textContent = failure.message;
        for (const button of form.querySelectorAll("button"))
          button.disabled = false;
      }
    };
    if (
      ["approval", "plan"].includes(interaction.kind) &&
      !interaction.questions?.length
    ) {
      for (const option of interaction.options || []) {
        const button = element("button", option.label, "secondary");
        button.type = "button";
        button.addEventListener("click", () => submit({ decision: option.id }));
        form.append(button);
      }
      form.addEventListener("submit", (event) => event.preventDefault());
    } else {
      const questions = interaction.questions?.length
        ? interaction.questions
        : [
            {
              id: interaction.id,
              title: "Your answer",
              options: interaction.options || [],
              multiSelect: interaction.kind === "select",
              allowOther: true,
            },
          ];
      const fields = questions.map((question) => {
        const fieldset = element("fieldset");
        fieldset.append(element("legend", question.title));
        const group = uid();
        const choices = (question.options || []).map((option) => {
          const label = element("label");
          const input = element("input");
          input.type = question.multiSelect ? "checkbox" : "radio";
          input.name = group;
          input.value = option.id;
          label.append(
            input,
            element(
              "span",
              option.label +
                (option.description ? ` — ${option.description}` : ""),
            ),
          );
          fieldset.append(label);
          return input;
        });
        let text;
        if (!choices.length || question.allowOther) {
          text = element("textarea");
          text.rows = 2;
          text.placeholder = "Type your answer…";
          text.setAttribute("aria-label", question.title);
          text.required = !choices.length;
          fieldset.append(text);
        }
        form.append(fieldset);
        return { question, choices, text };
      });
      const button = element("button", "Send answer", "primary");
      button.type = "submit";
      form.append(button);
      form.addEventListener("submit", (event) => {
        event.preventDefault();
        const answers = Object.fromEntries(
          fields.map(({ question, choices, text }) => [
            question.id,
            {
              options: choices
                .filter((input) => input.checked)
                .map((input) => input.value),
              ...(text?.value.trim() ? { text: text.value.trim() } : {}),
            },
          ]),
        );
        if (interaction.questions?.length) submit({ answers });
        else submit(answers[interaction.id]);
      });
    }
    form.append(error);
    state.interactions.set(interaction.id, form);
    $("run-interactions").append(form);
  }
}

$("recover").addEventListener("click", () => {
  const saved = pending();
  if (!saved || state.busy) return;
  state.selected = sourceMetadata({ chatId: saved.sourceChatId });
  state.preview = { context: saved.request.context };
  state.request = saved.request;
  $("source-title").textContent = state.selected.title;
  $("source-detail").textContent = state.selected.agentName;
  targets(state.selected);
  if (
    !Array.from($("target").options).some(
      (option) => option.value === saved.request.targetAgentId,
    )
  ) {
    const option = element("option", "Previously selected agent");
    option.value = saved.request.targetAgentId;
    $("target").append(option);
  }
  $("target").value = saved.request.targetAgentId;
  $("task").value = saved.request.task;
  $("context").value = saved.request.context;
  $("selection-hint").hidden = true;
  $("handoff-form").hidden = false;
  state.run = null;
  state.accepted = false;
  state.selection++;
  if (saved.run) showRun(saved.run);
  else
    notice(
      "Your previous request is ready to retry. It will recover the same task.",
    );
  controls();
  renderSources();
});

$("cancel-run").addEventListener("click", async () => {
  if (!state.run || !confirm("Stop this agent’s current task?")) return;
  $("cancel-run").disabled = true;
  try {
    await api(`/runs/${enc(state.run.id)}/cancel`, "POST");
    watchRun(state.run);
  } catch (error) {
    notice(error.message, true);
  } finally {
    $("cancel-run").disabled = false;
  }
});
$("resume-watch").addEventListener("click", () => {
  if (state.run) watchRun(state.run);
});
$("open-result").addEventListener("click", () => {
  if (state.run) selectSource(sourceMetadata({ chatId: state.run.chatId }));
});
$("refresh").addEventListener("click", async () => {
  try {
    state.snapshot = await api("/workspace?refresh=true");
    await loadSources(true);
  } catch (error) {
    if (error.name !== "AbortError") notice(error.message, true);
  }
});
$("load-more").addEventListener("click", () => loadSources(false, true));
let searchTimer;
$("search").addEventListener("input", () => {
  clearTimeout(searchTimer);
  searchTimer = setTimeout(() => loadSources(), 300);
});
for (const id of ["task", "context", "target"])
  $(id).addEventListener("input", controls);
for (const button of document.querySelectorAll("[data-task]"))
  button.addEventListener("click", () => {
    $("task").value = button.dataset.task;
    controls();
    $("task").focus();
  });
document.addEventListener("visibilitychange", () => {
  if (!document.hidden && state.token && state.run && !terminal(state.run))
    watchRun(state.run);
});
