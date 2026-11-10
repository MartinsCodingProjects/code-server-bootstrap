// Agent dashboard frontend: hash routes (#/sessions, #/history?project=...), live updates over SSE.
"use strict";

const $ = (sel, el = document) => el.querySelector(sel);
const main = $("#main");
const state = { meta: null, overview: null, route: "", listeners: new Set() };

// ---------------------------------------------------------------------------------------- helpers

function h(tag, attrs = {}, ...children) {
  const el = document.createElement(tag);
  for (const [k, v] of Object.entries(attrs)) {
    if (v == null || v === false) continue;
    if (k === "class") el.className = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else el.setAttribute(k, v === true ? "" : v);
  }
  for (const c of children.flat()) if (c != null && c !== false) el.append(c instanceof Node ? c : String(c));
  return el;
}

async function api(path) {
  const r = await fetch(path, { credentials: "same-origin" });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

const fmtTime = (ts) => new Date(ts).toLocaleTimeString("de-DE", { hour: "2-digit", minute: "2-digit", second: "2-digit" });
const fmtDay = (ts) => new Date(ts).toLocaleDateString("de-DE", { weekday: "long", day: "2-digit", month: "2-digit", year: "numeric" });
const fmtClock = (epoch) => new Date(epoch * 1000).toLocaleString("de-DE", { weekday: "short", hour: "2-digit", minute: "2-digit" });
const fmtNum = (n) => n == null ? "–" : n >= 1e6 ? (n / 1e6).toFixed(1) + " M" : n >= 1e3 ? Math.round(n / 1e3) + " k" : String(n);
const fmtUsd = (n) => n == null ? "–" : n.toFixed(2) + " $";
const fmtDur = (ms) => {
  if (ms == null) return "–";
  const m = Math.round(ms / 60000);
  return m < 60 ? `${m} min` : `${Math.floor(m / 60)} h ${m % 60} min`;
};
function ago(ts) {
  if (!ts) return "";
  const s = Math.max(0, (Date.now() - new Date(ts)) / 1000);
  if (s < 60) return "gerade eben";
  if (s < 3600) return `vor ${Math.floor(s / 60)} min`;
  if (s < 86400) return `vor ${Math.floor(s / 3600)} h`;
  return `vor ${Math.floor(s / 86400)} d`;
}
function bar(pct) {
  const p = Math.max(0, Math.min(100, pct || 0));
  return h("div", { class: "bar" + (p >= 90 ? " bad" : p >= 70 ? " warn" : "") }, h("span", { style: `width:${p}%` }));
}
function parseHash() {
  const [path, query = ""] = location.hash.replace(/^#\/?/, "").split("?");
  return { route: path || "sessions", params: new URLSearchParams(query) };
}
function setParams(params) {
  const q = params.toString();
  history.replaceState(null, "", `#/${state.route}${q ? "?" + q : ""}`);
}

// ------------------------------------------------------------------------------------ live stream

function connect() {
  const live = $("#live");
  const es = new EventSource("api/stream");
  es.onopen = () => live.classList.add("on");
  es.onerror = () => live.classList.remove("on");
  es.onmessage = (m) => {
    const e = JSON.parse(m.data);
    for (const fn of state.listeners) fn(e);
  };
}

// ----------------------------------------------------------------------------------------- limits

function renderLimits(limits) {
  const el = $("#limits");
  el.replaceChildren();
  if (!limits) return;
  for (const [key, label] of [["five_hour", "5h"], ["seven_day", "7d"]]) {
    const l = limits[key];
    if (!l) continue;
    el.append(h("span", { class: "limit", title: `${label}-Fenster, Reset ${l.resets_at ? fmtClock(l.resets_at) : "?"}` },
      h("b", {}, label), bar(l.used_percentage), `${Math.round(l.used_percentage)} %`,
      l.resets_at ? h("span", { class: "reset muted" }, "↻ " + fmtClock(l.resets_at)) : null));
  }
}

// --------------------------------------------------------------------------------------- sessions

let overviewTimer = null;
async function loadOverview() {
  state.overview = await api("api/overview");
  renderLimits(state.overview.limits);
  if (state.route === "sessions") renderSessions();
}
function scheduleOverview(delay = 400) {
  clearTimeout(overviewTimer);
  overviewTimer = setTimeout(() => loadOverview().catch(showError), delay);
}

function card(c) {
  const attn = ["permission", "trust", "input", "error"].includes(c.status);
  const g = c.git;
  const histLink = `#/history?project=${encodeURIComponent(c.project)}`;
  return h("article", { class: "card" + (attn ? " attn" : "") },
    h("div", { class: "card-head" },
      h("div", {},
        h("div", { class: "card-title" }, c.project),
        h("div", { class: "card-sub" }, c.session_name ? `${c.name} · ${c.session_name}` : c.name)),
      h("span", { class: `pill ${c.status}`, title: c.status_ts ? `seit ${fmtTime(c.status_ts)}` : "" }, c.status_label)),
    h("dl", { class: "kv" },
      g ? [h("dt", {}, "Git"), h("dd", {}, `${g.repo ? g.repo + " · " : ""}${g.branch}${g.changed ? ` · ${g.changed} geändert` : ""}`)]
        : [h("dt", {}, "Git"), h("dd", { class: "muted" }, c.exists ? "kein Repository" : "Ordner fehlt")],
      c.model ? [h("dt", {}, "Modell"), h("dd", {}, c.model + (c.effort ? ` · ${c.effort}` : ""))] : null,
      c.context_pct != null ? [h("dt", {}, "Kontext"), h("dd", {},
        h("div", { style: "display:flex;align-items:center;gap:8px" }, bar(c.context_pct),
          `${Math.round(c.context_pct)} % · ${fmtNum(c.context_tokens)}`))] : null,
      c.cost_usd != null ? [h("dt", {}, "Verbrauch"), h("dd", {},
        `${fmtUsd(c.cost_usd)} (Schätzung) · ${fmtDur(c.duration_ms)}` +
        (c.lines_added != null ? ` · +${c.lines_added}/−${c.lines_removed}` : ""))] : null,
      c.pr && c.pr.number ? [h("dt", {}, "PR"), h("dd", {},
        h("a", { href: c.pr.url, target: "_blank", rel: "noopener" }, `#${c.pr.number}`), c.pr.state ? ` · ${c.pr.state}` : "")] : null,
      c.tmux ? [h("dt", {}, "tmux"), h("dd", {}, `seit ${fmtTime(c.tmux.started)}` +
        (c.tmux.attached ? ` · ${c.tmux.attached} Terminal(s) verbunden` : ""))] : null),
    c.last_summary ? h("div", { class: "last" }, c.last_summary, " ", h("span", { class: "muted" }, ago(c.last_ts))) : null,
    h("div", { class: "actions" },
      h("a", { href: histLink }, "Verlauf"),
      c.code_server_url ? h("a", { href: c.code_server_url, target: "_blank", rel: "noopener" }, "code-server") : null,
      c.tmux ? h("a", { href: "https://claude.ai/code", target: "_blank", rel: "noopener", title: `Session „${c.name}“` }, "Claude") : null));
}

function renderSessions() {
  const o = state.overview;
  main.replaceChildren(h("h1", {}, "Sessions"));
  if (!o) return main.append(h("p", { class: "muted" }, "Lädt …"));
  if (!o.cards.length) {
    return main.append(h("div", { class: "empty" },
      "Keine Sessions. Starte eine im code-server-Terminal mit ", h("code", {}, "agent-start <ordner>"), "."));
  }
  main.append(h("div", { class: "cards" }, o.cards.map(card)));
}

// ---------------------------------------------------------------------------------------- history

const HIDDEN_BY_DEFAULT = ["api"];
const hist = { events: [], more: false, params: null, expanded: new Set() };

function histFilters(params) {
  const cats = params.get("cat");
  return {
    project: params.get("project") || "",
    session: params.get("session") || "",
    cat: cats != null ? cats : Object.keys(state.meta.categories).filter((c) => !HIDDEN_BY_DEFAULT.includes(c)).join(","),
    q: params.get("q") || "",
    since: params.get("since") || "",
    until: params.get("until") || "",
  };
}
function query(f, extra = {}) {
  const p = new URLSearchParams();
  for (const [k, v] of Object.entries({ ...f, ...extra })) {
    if (!v) continue;
    // the date inputs hold local time without a zone; the server compares UTC
    p.set(k, k === "since" || k === "until" ? new Date(v).toISOString() : v);
  }
  return p.toString();
}
function matches(e, f) {
  if (f.project && e.project !== f.project && !(e.project || "").startsWith(f.project + "/")) return false;
  if (f.session && e.session_id !== f.session) return false;
  if (f.cat && !f.cat.split(",").includes(e.category)) return false;
  if (f.q && !`${e.summary} ${e.event} ${e.project}`.toLowerCase().includes(f.q.toLowerCase())) return false;
  if (f.until) return false; // a closed time range does not grow
  return true;
}

async function loadHistory(append = false) {
  const f = histFilters(hist.params);
  const last = hist.events[hist.events.length - 1];
  const res = await api("api/events?" + query(f, append && last ? { before: `${last.ts}|${last.id}` } : {}));
  hist.events = append ? hist.events.concat(res.events) : res.events;
  hist.more = res.more;
  renderTimeline();
}

function eventRow(e, fresh = false) {
  const row = h("div", { class: "ev" + (fresh ? " fresh" : ""), "data-id": e.id },
    h("time", { datetime: e.ts }, fmtTime(e.ts)),
    h("span", { class: `dot ${e.category}`, title: state.meta.categories[e.category] || e.category }),
    h("div", { class: "ev-main" },
      h("div", {}, e.summary || e.event),
      h("div", { class: "ev-meta" },
        e.project ? h("span", { class: "tag proj", title: "nach Projekt filtern",
          onclick: (ev) => { ev.stopPropagation(); setFilter("project", e.project); } }, e.project) : null,
        h("span", {}, e.event),
        e.source === "otel" ? h("span", {}, "Telemetrie") : null,
        e.session_id ? h("a", { href: "#", title: "nur diese Session",
          onclick: (ev) => { ev.preventDefault(); ev.stopPropagation(); setFilter("session", e.session_id); } },
          "Session " + e.session_id.slice(0, 8)) : null)));
  row.addEventListener("click", () => toggleDetail(row, e.id));
  return row;
}

async function toggleDetail(row, id) {
  const pre = $("pre", row);
  if (pre) { pre.remove(); hist.expanded.delete(id); return; }
  hist.expanded.add(id);
  const full = await api(`api/events/${id}`);
  row.append(h("pre", {}, JSON.stringify(full.data, null, 2)));
}

function renderTimeline() {
  const tl = $("#timeline");
  if (!tl) return;
  tl.replaceChildren();
  if (!hist.events.length) {
    tl.append(h("div", { class: "empty", style: "border:0" }, "Keine Ereignisse für diese Filter."));
  }
  let day = "";
  for (const e of hist.events) {
    const d = fmtDay(e.ts);
    if (d !== day) { tl.append(h("div", { class: "day" }, d)); day = d; }
    tl.append(eventRow(e));
  }
  const more = $("#more");
  more.hidden = !hist.more;
}

function prependEvent(e) {
  const tl = $("#timeline");
  hist.events.unshift(e);
  const first = tl.firstElementChild;
  const d = fmtDay(e.ts);
  if (!first || !first.classList.contains("day") || first.textContent !== d) {
    if (first && first.classList.contains("empty")) first.remove();
    tl.prepend(h("div", { class: "day" }, d));
  }
  tl.firstElementChild.after(eventRow(e, true));
}

function setFilter(key, value) {
  if (value) hist.params.set(key, value); else hist.params.delete(key);
  setParams(hist.params);
  renderHistory();
}

function renderHistory() {
  hist.params = parseHash().params;
  const f = histFilters(hist.params);
  const cats = f.cat.split(",").filter(Boolean);
  const projects = state.meta.projects;

  const search = h("input", { type: "search", placeholder: "Suchen …", value: f.q });
  search.addEventListener("change", () => setFilter("q", search.value.trim()));
  const proj = h("select", { "aria-label": "Projekt" },
    h("option", { value: "" }, "Alle Projekte"),
    projects.map((p) => h("option", { value: p, selected: p === f.project }, p)));
  proj.addEventListener("change", () => setFilter("project", proj.value));
  const since = h("input", { type: "datetime-local", value: f.since, "aria-label": "von", title: "von" });
  since.addEventListener("change", () => setFilter("since", since.value));
  const until = h("input", { type: "datetime-local", value: f.until, "aria-label": "bis", title: "bis" });
  until.addEventListener("change", () => setFilter("until", until.value));

  const chips = Object.entries(state.meta.categories).map(([key, label]) =>
    h("button", { class: "chip" + (cats.includes(key) ? " on" : ""), onclick: () => {
      const next = cats.includes(key) ? cats.filter((c) => c !== key) : cats.concat(key);
      hist.params.set("cat", next.join(","));
      setParams(hist.params);
      renderHistory();
    } }, label));

  const exportLink = (fmt) => h("a", { href: `api/events/export?${query(f, { format: fmt })}` }, fmt.toUpperCase());

  main.replaceChildren(
    h("h1", {}, "Verlauf"),
    h("div", { class: "filters" }, proj, search, since, until),
    h("div", { class: "chips" }, chips,
      h("button", { class: "chip", onclick: () => { hist.params.delete("cat"); setParams(hist.params); renderHistory(); } }, "Standard")),
    h("div", { class: "active-filters muted" },
      f.session ? h("span", {}, `Session ${f.session.slice(0, 8)} `,
        h("a", { href: "#", onclick: (ev) => { ev.preventDefault(); setFilter("session", ""); } }, "✕")) : null,
      h("span", {}, "Export: ", exportLink("jsonl"), " · ", exportLink("csv"))),
    h("div", { class: "timeline", id: "timeline" }, h("p", { class: "muted", style: "padding:12px" }, "Lädt …")),
    h("button", { class: "more", id: "more", hidden: true, onclick: () => loadHistory(true).catch(showError) }, "Ältere laden"));
  hist.events = [];
  loadHistory().catch(showError);
}

// ----------------------------------------------------------------------------------------- router

function showError(err) {
  console.error(err);
  main.prepend(h("div", { class: "empty", style: "color:var(--bad);margin-bottom:12px" }, String(err.message || err)));
}

function route() {
  const { route } = parseHash();
  state.route = route;
  for (const a of document.querySelectorAll(".sidebar a")) a.classList.toggle("active", a.dataset.route === route);
  $("#sidebar").classList.remove("open");
  if (route === "history") renderHistory();
  else { state.route = "sessions"; renderSessions(); }
}

state.listeners.add((e) => {
  scheduleOverview();
  if (state.route === "history" && hist.params && matches(e, histFilters(hist.params))) prependEvent(e);
  if (e.project && !state.meta.projects.includes(e.project)) state.meta.projects.push(e.project);
});

$("#menu-toggle").addEventListener("click", () => {
  const open = $("#sidebar").classList.toggle("open");
  $("#menu-toggle").setAttribute("aria-expanded", open);
});
window.addEventListener("hashchange", route);
document.addEventListener("visibilitychange", () => { if (!document.hidden) scheduleOverview(0); });

(async function start() {
  try {
    state.meta = await api("api/meta");
    if (state.meta.user) $("#user").textContent = state.meta.user;
    route();
    await loadOverview();
    connect();
    setInterval(() => scheduleOverview(0), 30000); // tmux and git change without events
  } catch (err) { showError(err); }
})();
