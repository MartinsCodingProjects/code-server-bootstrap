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

// Changes need the X-Agent-Dashboard header (the server refuses cross-site requests without it).
async function send(method, path, body) {
  const r = await fetch(path, {
    method, credentials: "same-origin", body: JSON.stringify(body),
    headers: { "Content-Type": "application/json", "X-Agent-Dashboard": "1" },
  });
  if (!r.ok) throw new Error(`${r.status} ${await r.text()}`);
  return r.json();
}

function toast(text, bad = false) {
  const el = h("div", { class: "toast" + (bad ? " bad" : "") }, text);
  document.body.append(el);
  setTimeout(() => el.remove(), bad ? 9000 : 4000);
}

async function startSessions(folders, resume = false) {
  const res = await send("POST", "api/sessions/start", { folders, resume });
  const failed = res.results.filter((r) => !r.ok);
  if (failed.length) toast(failed.map((r) => `${r.folder}: ${r.output}`).join("\n"), true);
  else toast(res.results.map((r) => r.output).join("\n"));
  scheduleOverview(300);
  return res;
}

async function stopSession(folder) {
  if (!confirm(`Claude in „${folder}“ beenden? Das Gespräch lässt sich später fortsetzen.`)) return;
  const r = await send("POST", "api/sessions/stop", { folder });
  toast(r.output || "gestoppt", !r.ok);
  scheduleOverview(300);
}

// A second Claude in a folder where one already runs by hand: ask first.
function guardExternal(c) {
  return !c.external || confirm(`In „${c.project}“ läuft bereits ein Claude außerhalb des Dashboards. Trotzdem eine zweite Session starten?`);
}

const termUrl = (name) => `term/?arg=${encodeURIComponent(name)}`;

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
    c.external ? h("div", { class: "note muted small" },
      "Läuft außerhalb des Dashboards (von Hand gestartetes claude, z. B. im code-server-Terminal): kein Web-Terminal, Stopp nur dort.") : null,
    h("div", { class: "actions" }, cardActions(c, histLink)));
}

function cardActions(c, histLink) {
  const live = c.tmux && c.status !== "exited";
  const act = (label, fn, cls = "") => h("button", { class: cls, onclick: (ev) => {
    ev.target.disabled = true;
    fn().catch(showError).finally(() => { ev.target.disabled = false; });
  } }, label);
  return [
    live ? h("a", { href: termUrl(c.name), target: "_blank", rel: "noopener", class: "primary" }, "Terminal") : null,
    !live && c.exists ? act("Starten", async () => { if (guardExternal(c)) await startSessions([c.project]); }, c.external ? "" : "primary") : null,
    !live && c.exists && c.session_id ? act("Fortsetzen", async () => { if (guardExternal(c)) await startSessions([c.project], true); }) : null,
    c.tmux ? act(c.status === "exited" ? "Schließen" : "Stoppen", () => stopSession(c.project), "danger") : null,
    h("a", { href: histLink }, "Verlauf"),
    c.session_id ? h("a", { href: `#/session/${encodeURIComponent(c.session_id)}` }, "Details") : null,
    c.code_server_url ? h("a", { href: c.code_server_url, target: "_blank", rel: "noopener" }, "code-server") : null,
    c.tmux ? h("a", { href: "https://claude.ai/code", target: "_blank", rel: "noopener", title: `Session „${c.name}“` }, "Claude") : null,
  ];
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

// --------------------------------------------------------------------------------- session config

const cfgPage = { folders: [], open: new Set(), filter: "" };

async function renderConfig() {
  main.replaceChildren(h("h1", {}, "Session Config"), h("p", { class: "muted" }, "Lädt …"));
  const res = await api("api/folders");
  cfgPage.folders = res.folders;
  cfgPage.root = res.projects_dir;
  // Folders that are no repository usually hold projects: open them; repositories stay closed
  // unless something inside is selected.
  cfgPage.open = new Set(res.folders.filter((f) => f.depth === 1 && (!f.git ||
    res.folders.some((c) => c.depth === 2 && c.rel.startsWith(f.rel + "/") && c.selected))).map((f) => f.rel));
  drawConfig();
}

function drawConfig() {
  const sel = () => cfgPage.folders.filter((f) => f.selected).map((f) => f.rel);
  const filter = h("input", { type: "search", placeholder: "Ordner filtern …", value: cfgPage.filter });
  filter.addEventListener("input", () => { cfgPage.filter = filter.value; drawList(); });
  const count = h("span", { class: "muted" });
  const save = h("button", { onclick: async () => {
    await send("PUT", "api/selection", { folders: sel() });
    toast("Auswahl gespeichert");
    scheduleOverview(0);
  } }, "Auswahl speichern");
  const start = h("button", { class: "primary", onclick: async () => {
    const folders = sel();
    await send("PUT", "api/selection", { folders });
    const todo = cfgPage.folders.filter((f) => f.selected && !f.running).map((f) => f.rel);
    if (!todo.length) return toast("Alle ausgewählten Ordner laufen schon.");
    start.disabled = true;
    try { await startSessions(todo); } finally { start.disabled = false; }
    renderConfig();
  } }, "Ausgewählte starten");
  const list = h("div", { class: "tree" });

  function updateCount() {
    const n = sel().length;
    count.textContent = n ? `${n} ausgewählt` : "nichts ausgewählt";
  }
  function drawList() {
    const q = cfgPage.filter.toLowerCase();
    list.replaceChildren();
    for (const f of cfgPage.folders) {
      const parent = f.depth === 2 ? f.rel.slice(0, f.rel.indexOf("/")) : null;
      if (q ? !f.rel.toLowerCase().includes(q) : parent && !cfgPage.open.has(parent)) continue;
      const box = h("input", { type: "checkbox", checked: f.selected, id: "f-" + f.rel });
      box.addEventListener("change", () => { f.selected = box.checked; updateCount(); });
      const toggle = f.depth === 1 && f.children
        ? h("button", { class: "twisty", "aria-label": "Unterordner", onclick: () => {
            cfgPage.open.has(f.rel) ? cfgPage.open.delete(f.rel) : cfgPage.open.add(f.rel);
            drawList();
          } }, cfgPage.open.has(f.rel) ? "▾" : "▸")
        : h("span", { class: "twisty" });
      list.append(h("div", { class: `row d${f.depth}` },
        toggle, box,
        h("label", { for: "f-" + f.rel }, q ? f.rel : f.name),
        f.git ? h("span", { class: "tag" }, "git") : null,
        f.running ? h("span", { class: "pill working" }, "läuft") : null,
        f.exited ? h("span", { class: "pill" }, "beendet") : null,
        f.depth === 1 && f.children ? h("span", { class: "muted small" }, `${f.children} Unterordner`) : null));
    }
    if (!list.children.length) list.append(h("div", { class: "empty", style: "border:0" }, "Keine Ordner."));
  }

  main.replaceChildren(
    h("h1", {}, "Session Config"),
    h("p", { class: "muted" }, "Wähle die Ordner, an denen gerade gearbeitet wird (bis zwei Ebenen unter ",
      h("code", {}, cfgPage.root), "). „Ausgewählte starten“ startet für jeden Ordner, der noch nicht läuft, Claude mit Remote Control in einer eigenen tmux-Session."),
    h("div", { class: "filters" }, filter, count, save, start),
    list);
  updateCount();
  drawList();
}

// ----------------------------------------------------------------------------------------- charts
// Plain SVG, sized to the container; hover shows a tooltip (bars: per day, lines: crosshair).

const NS = "http://www.w3.org/2000/svg";
const SLOTS = ["--s1", "--s2", "--s3", "--s4", "--s5", "--s6", "--s7"];
const OTHER = "--s8";
const cssVar = (name) => getComputedStyle(document.documentElement).getPropertyValue(name).trim();

function svg(tag, attrs = {}) {
  const el = document.createElementNS(NS, tag);
  for (const [k, v] of Object.entries(attrs)) el.setAttribute(k, v);
  return el;
}
function niceMax(v) {
  if (!(v > 0)) return 1;
  const p = 10 ** Math.floor(Math.log10(v));
  return [1, 2, 4, 6, 8, 10].map((m) => m * p).find((m) => m >= v);
}
function legend(series) {
  return h("div", { class: "legend" }, series.map((s) => h("span", {}, h("i", { style: `background:var(${s.color})` }), s.label)));
}
function tipBox(chart) {
  const tip = h("div", { class: "tip", hidden: true });
  chart.append(tip);
  return (x, y, content) => {
    if (!content) { tip.hidden = true; return; }
    tip.replaceChildren(...content);
    tip.hidden = false;
    const w = chart.clientWidth;
    tip.style.left = Math.min(Math.max(0, x + 12), w - tip.offsetWidth) + "px";
    tip.style.top = Math.max(0, y - tip.offsetHeight - 8) + "px";
  };
}
const tipRow = (color, label, value) => h("div", { class: "row" },
  h("span", {}, color ? h("i", { style: `background:var(${color})` }) : null, " ", label), h("span", {}, value));

// days: ["YYYY-MM-DD"], series: [{label, color, values: {day: number}}]
function stackedBars(el, days, series, fmt, height = 220) {
  const chart = h("div", { class: "chart" });
  el.replaceChildren(legend(series), chart);
  const draw = () => {
    chart.replaceChildren();
    const W = chart.clientWidth || 600, H = height, L = 46, B = 22, T = 6;
    const totals = days.map((d) => series.reduce((a, s) => a + (s.values[d] || 0), 0));
    const max = niceMax(Math.max(...totals));
    const y = (v) => T + (H - T - B) * (1 - v / max);
    const band = (W - L) / days.length, bw = Math.min(36, band * 0.62);
    const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, height: H, role: "img" });
    for (let i = 0; i <= 4; i++) {
      const v = (max / 4) * i;
      root.append(svg("line", { class: "gridline", x1: L, x2: W, y1: y(v), y2: y(v) }));
      const t = svg("text", { x: L - 6, y: y(v) + 4, "text-anchor": "end" }); t.textContent = fmt(v); root.append(t);
    }
    const every = Math.ceil(days.length / Math.max(1, Math.floor((W - L) / 64)));
    const show = tipBox(chart);
    days.forEach((d, i) => {
      const x = L + band * i + (band - bw) / 2;
      let acc = 0;
      const segs = series.filter((s) => s.values[d] > 0);
      segs.forEach((s, j) => {
        const v = s.values[d], y0 = y(acc), y1 = y(acc + v);
        acc += v;
        const top = j === segs.length - 1, hgt = Math.max(0, y0 - y1 - (j ? 2 : 0));
        const r = top ? Math.min(4, hgt, bw / 2) : 0;
        const yy = y1, x2 = x + bw, yb = yy + hgt;
        root.append(svg("path", { fill: `var(${s.color})`, d: r
          ? `M${x},${yb}V${yy + r}Q${x},${yy} ${x + r},${yy}H${x2 - r}Q${x2},${yy} ${x2},${yy + r}V${yb}Z`
          : `M${x},${yb}V${yy}H${x2}V${yb}Z` }));
      });
      if (i % every === 0 || i === days.length - 1) {
        const t = svg("text", { x: x + bw / 2, y: H - 6, "text-anchor": "middle" });
        t.textContent = new Date(d + "T12:00").toLocaleDateString("de-DE", { day: "2-digit", month: "2-digit" });
        root.append(t);
      }
      const hit = svg("rect", { class: "hit", x: L + band * i, y: T, width: band, height: H - T - B });
      const tip = () => [h("b", {}, new Date(d + "T12:00").toLocaleDateString("de-DE", { weekday: "short", day: "2-digit", month: "2-digit" })),
        ...series.filter((s) => s.values[d]).map((s) => tipRow(s.color, s.label, fmt(s.values[d]))),
        tipRow(null, "Summe", fmt(totals[i]))];
      hit.addEventListener("pointermove", () => show(L + band * i + band / 2, y(totals[i]), tip()));
      hit.addEventListener("pointerleave", () => show());
      root.append(hit);
    });
    chart.append(root);
  };
  draw();
  onResize(chart, draw);
}

// points: [{ts, <key>: number}], series: [{key, label, color}], y fixed 0..yMax
function lineChart(el, points, series, fmt, yMax = 100, height = 200) {
  const chart = h("div", { class: "chart" });
  el.replaceChildren(series.length > 1 ? legend(series) : "", chart);
  const draw = () => {
    chart.replaceChildren();
    if (!points.length) { chart.append(h("p", { class: "muted" }, "Noch keine Daten.")); return; }
    const W = chart.clientWidth || 600, H = height, L = 40, B = 22, T = 6, R = 8;
    const t0 = new Date(points[0].ts).getTime(), t1 = Math.max(t0 + 60000, new Date(points[points.length - 1].ts).getTime());
    const x = (ts) => L + (W - L - R) * (new Date(ts).getTime() - t0) / (t1 - t0);
    const y = (v) => T + (H - T - B) * (1 - v / yMax);
    const root = svg("svg", { viewBox: `0 0 ${W} ${H}`, height: H, role: "img" });
    for (let i = 0; i <= 4; i++) {
      const v = (yMax / 4) * i;
      root.append(svg("line", { class: "gridline", x1: L, x2: W - R, y1: y(v), y2: y(v) }));
      const t = svg("text", { x: L - 6, y: y(v) + 4, "text-anchor": "end" }); t.textContent = fmt(v); root.append(t);
    }
    const spanDays = (t1 - t0) / 86400000;
    for (let i = 0; i <= 4; i++) {
      const ts = t0 + (t1 - t0) * i / 4;
      const t = svg("text", { x: L + (W - L - R) * i / 4, y: H - 6, "text-anchor": i === 0 ? "start" : i === 4 ? "end" : "middle" });
      t.textContent = new Date(ts).toLocaleString("de-DE", spanDays > 2
        ? { day: "2-digit", month: "2-digit" } : { hour: "2-digit", minute: "2-digit" });
      root.append(t);
    }
    for (const s of series) {
      const pts = points.filter((p) => p[s.key] != null);
      if (!pts.length) continue;
      root.append(svg("polyline", { fill: "none", stroke: `var(${s.color})`, "stroke-width": 2, "stroke-linejoin": "round",
        points: pts.map((p) => `${x(p.ts).toFixed(1)},${y(Math.min(yMax, p[s.key])).toFixed(1)}`).join(" ") }));
    }
    const cross = svg("line", { class: "cross", y1: T, y2: H - B, visibility: "hidden" });
    const dots = series.map((s) => svg("circle", { r: 4, fill: `var(${s.color})`, stroke: "var(--surface)", "stroke-width": 2, visibility: "hidden" }));
    root.append(cross, ...dots);
    const show = tipBox(chart);
    const hit = svg("rect", { class: "hit", x: L, y: T, width: W - L - R, height: H - T - B });
    hit.addEventListener("pointermove", (ev) => {
      const box = root.getBoundingClientRect();
      const px = (ev.clientX - box.left) * (W / box.width);
      let best = points[0];
      for (const p of points) if (Math.abs(x(p.ts) - px) < Math.abs(x(best.ts) - px)) best = p;
      const bx = x(best.ts);
      cross.setAttribute("x1", bx); cross.setAttribute("x2", bx); cross.setAttribute("visibility", "visible");
      series.forEach((s, i) => {
        const v = best[s.key];
        dots[i].setAttribute("visibility", v == null ? "hidden" : "visible");
        if (v != null) { dots[i].setAttribute("cx", bx); dots[i].setAttribute("cy", y(Math.min(yMax, v))); }
      });
      show(bx, y(Math.max(...series.map((s) => best[s.key] ?? 0))),
        [h("b", {}, new Date(best.ts).toLocaleString("de-DE", { weekday: "short", hour: "2-digit", minute: "2-digit" })),
          ...series.filter((s) => best[s.key] != null).map((s) => tipRow(s.color, s.label, fmt(best[s.key])))]);
    });
    hit.addEventListener("pointerleave", () => {
      cross.setAttribute("visibility", "hidden"); dots.forEach((d) => d.setAttribute("visibility", "hidden")); show();
    });
    root.append(hit);
    chart.append(root);
  };
  draw();
  onResize(chart, draw);
}

function onResize(el, fn) {
  let w = el.clientWidth;
  const ro = new ResizeObserver(() => { if (Math.abs(el.clientWidth - w) > 4) { w = el.clientWidth; fn(); } });
  ro.observe(el);
}

const tile = (label, value, sub) => h("div", { class: "tile" },
  h("div", { class: "label" }, label), h("div", { class: "value" }, value), sub ? h("div", { class: "sub" }, sub) : null);
const fmtHours = (s) => s == null ? "–" : s < 3600 ? `${Math.round(s / 60)} min` : `${(s / 3600).toFixed(1)} h`;
const pct = (v) => `${Math.round(v)} %`;

// ------------------------------------------------------------------------------------------ usage

async function renderUsage() {
  const params = parseHash().params;
  const days = Number(params.get("days") || 7), project = params.get("project") || "", measure = params.get("m") || "tokens";
  const set = (k, v) => { if (v) params.set(k, v); else params.delete(k); setParams(params); renderUsage().catch(showError); };

  main.replaceChildren(h("h1", {}, "Verbrauch"), h("p", { class: "muted" }, "Lädt …"));
  const u = await api(`api/usage?${new URLSearchParams({ days, project })}`);
  const t = u.totals;

  const range = h("select", { "aria-label": "Zeitraum" }, [7, 14, 30, 90].map((d) =>
    h("option", { value: d, selected: d === days }, `${d} Tage`)));
  range.addEventListener("change", () => set("days", range.value));
  const proj = h("select", { "aria-label": "Projekt" }, h("option", { value: "" }, "Alle Projekte"),
    state.meta.projects.map((p) => h("option", { value: p, selected: p === project }, p)));
  proj.addEventListener("change", () => set("project", proj.value));
  const seg = h("div", { class: "seg" }, [["tokens", "Tokens"], ["cost", "Kosten"]].map(([k, l]) =>
    h("button", { class: k === measure ? "on" : "", onclick: () => set("m", k === "tokens" ? "" : k) }, l)));

  // up to seven projects keep their own color, the rest is "Andere"
  const top = u.projects.slice(0, 7), rest = u.projects.slice(7);
  const series = top.map((p, i) => ({ label: p, color: SLOTS[i], values: {} }));
  if (rest.length) series.push({ label: `Andere (${rest.length})`, color: OTHER, values: {} });
  for (const d of u.days) {
    for (const [p, v] of Object.entries(u.per_day[d] || {})) {
      const s = series[top.indexOf(p)] || series[series.length - 1];
      if (s) s.values[d] = (s.values[d] || 0) + v[measure];
    }
  }
  const fmtM = measure === "cost" ? (v) => (v >= 10 ? v.toFixed(0) : v.toFixed(2)) + " $" : fmtNum;

  const barsEl = h("div"), limitsEl = h("div");
  const hasData = u.projects.length > 0;
  main.replaceChildren(
    h("h1", {}, "Verbrauch"),
    h("div", { class: "filters" }, range, proj, seg),
    h("div", { class: "tiles" },
      tile("Tokens", fmtNum(t.tokens), t.tokens ? `ein ${fmtNum(t.tokens_input)} · aus ${fmtNum(t.tokens_output)} · Cache ${fmtNum((t.tokens_cacheRead || 0) + (t.tokens_cacheCreation || 0))}` : null),
      tile("Kosten (Schätzung)", fmtUsd(t.cost), "zum Listenpreis; im Abo nicht berechnet"),
      tile("Agent aktiv", fmtHours(t.active_agent_s), `du aktiv: ${fmtHours(t.active_user_s)}`),
      tile("Wartezeit auf Freigaben", fmtHours((t.wait_ms || 0) / 1000), `${t.waits || 0} Freigaben`),
      tile("Zeilen", `+${fmtNum(t.lines_added || 0)} / −${fmtNum(t.lines_removed || 0)}`, `${t.commits || 0} Commits · ${t.pull_requests || 0} PRs`),
      tile("API-Anfragen", fmtNum(t.api_requests || 0), `${t.api_errors || 0} Fehler · Median ${t.api_ms_median != null ? (t.api_ms_median / 1000).toFixed(1) + " s" : "–"}`),
      tile("Cache-Trefferquote", t.cache_hit_ratio != null ? pct(t.cache_hit_ratio * 100) : "–")),
    h("section", { class: "panel" }, h("h2", {}, measure === "cost" ? "Kosten pro Tag" : "Tokens pro Tag"),
      h("p", { class: "note" }, "Aus der Telemetrie der Agent-Sessions (agent-start), nach Projekt."), barsEl),
    h("section", { class: "panel" }, h("h2", {}, "Nutzungslimits"),
      h("p", { class: "note" }, "Anteil des 5-Stunden- und des 7-Tage-Fensters, aus der Statuszeile."), limitsEl),
    h("section", { class: "panel" }, h("h2", {}, "Nach Projekt"), projectTable(u)));
  if (hasData) stackedBars(barsEl, u.days, series, fmtM);
  else barsEl.append(h("p", { class: "muted" }, "Noch keine Telemetrie in diesem Zeitraum."));
  lineChart(limitsEl, u.limits, [{ key: "five_hour", label: "5 Stunden", color: "--s1" }, { key: "seven_day", label: "7 Tage", color: "--s2" }], pct);
}

function projectTable(u) {
  if (!u.projects.length) return h("p", { class: "muted" }, "Keine Daten.");
  const cols = [["tokens", "Tokens", fmtNum], ["cost", "Kosten", fmtUsd], ["active_agent_s", "Agent aktiv", fmtHours],
    ["wait_ms", "Wartezeit", (v) => fmtHours(v / 1000)], ["lines_added", "+Zeilen", fmtNum], ["commits", "Commits", (v) => String(v)],
    ["api_errors", "API-Fehler", (v) => String(v)]];
  return h("div", { class: "table-wrap" }, h("table", { class: "data" },
    h("thead", {}, h("tr", {}, h("th", {}, "Projekt"), cols.map(([, l]) => h("th", {}, l)))),
    h("tbody", {}, u.projects.map((p) => h("tr", {},
      h("td", {}, h("a", { href: `#/history?project=${encodeURIComponent(p)}` }, p)),
      cols.map(([k, , f]) => h("td", {}, u.per_project[p][k] ? f(u.per_project[p][k]) : "–")))))));
}

// --------------------------------------------------------------------------------- session detail

async function renderSession(id) {
  main.replaceChildren(h("h1", {}, "Session"), h("p", { class: "muted" }, "Lädt …"));
  const d = await api(`api/session/${encodeURIComponent(id)}`);
  const s = d.session, snap = d.snapshot || {}, m = _snap(snap);
  const allCats = Object.keys(state.meta.categories).join(",");
  const chartEl = h("div"), trEl = h("div");
  const loadTranscript = async () => {
    trEl.replaceChildren(h("p", { class: "muted" }, "Lädt …"));
    try {
      const t = await api(`api/session/${encodeURIComponent(id)}/transcript`);
      trEl.replaceChildren(
        t.total > t.items.length ? h("p", { class: "note" }, `Die letzten ${t.items.length} von ${t.total} Einträgen.`) : "",
        h("div", { class: "transcript" }, t.items.map((it) => h("div", { class: `msg ${it.kind === "text" ? it.role : it.kind}${it.error ? " err" : ""}` },
          it.ts ? h("time", {}, fmtTime(it.ts)) : null,
          it.kind === "tool" ? `${it.tool}${it.text ? ": " + it.text : ""}` : it.text))));
    } catch (err) { trEl.replaceChildren(h("p", { class: "muted" }, "Kein Transkript verfügbar.")); }
  };
  const tok = d.tokens || {};
  main.replaceChildren(
    h("p", {}, h("a", { href: "#/sessions" }, "← Sessions")),
    h("h1", {}, s.project || "ohne Projekt", " ", h("span", { class: "muted", style: "font-weight:400" }, m.session_name || "")),
    h("div", { class: "filters" },
      h("span", { class: `pill ${s.status}` }, state.meta.status_labels[s.status] || s.status),
      h("span", { class: "muted small" }, `Session ${s.session_id} · ${fmtDay(s.first_ts)} ${fmtTime(s.first_ts)} bis ${fmtTime(s.last_ts)}`)),
    h("div", { class: "tiles" },
      tile("Modell", m.model || "–", m.effort ? `Effort ${m.effort}` : null),
      tile("Kontext", m.context_pct != null ? pct(m.context_pct) : "–", m.context_tokens ? `${fmtNum(m.context_tokens)} von ${fmtNum(m.context_size)}` : null),
      tile("Kosten (Schätzung)", fmtUsd(m.cost_usd), m.duration_ms ? `Dauer ${fmtDur(m.duration_ms)}` : null),
      tile("Tokens", fmtNum(Object.values(tok).reduce((a, b) => a + b, 0) || null), tok.input ? `ein ${fmtNum(tok.input)} · aus ${fmtNum(tok.output)}` : "nur mit Telemetrie"),
      tile("Ereignisse", fmtNum(Object.values(d.counts).reduce((a, b) => a + b, 0)),
        Object.entries(d.counts).map(([k, n]) => `${state.meta.categories[k] || k} ${n}`).join(" · "))),
    h("section", { class: "panel" }, h("h2", {}, "Kontext über die Zeit"), chartEl),
    h("div", { class: "actions", style: "margin-bottom:16px" },
      h("a", { href: `#/history?session=${encodeURIComponent(id)}&cat=${allCats}` }, "Alle Ereignisse dieser Session"),
      h("button", { onclick: loadTranscript }, "Gespräch anzeigen")),
    h("section", { class: "panel" }, h("h2", {}, "Gespräch"), trEl));
  trEl.append(h("p", { class: "note" }, "Das Transkript wird erst auf Wunsch geladen."));
  lineChart(chartEl, d.series, [{ key: "context_pct", label: "Kontext", color: "--s1" }], pct);
}

function _snap(snap) {
  const cw = snap.context_window || {}, cost = snap.cost || {};
  return {
    model: (snap.model || {}).display_name, effort: (snap.effort || {}).level, session_name: snap.session_name,
    context_pct: cw.used_percentage, context_tokens: (cw.total_input_tokens || 0) + (cw.total_output_tokens || 0),
    context_size: cw.context_window_size, cost_usd: cost.total_cost_usd, duration_ms: cost.total_duration_ms,
  };
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
  else if (route === "config") renderConfig().catch(showError);
  else if (route === "usage") renderUsage().catch(showError);
  else if (route.startsWith("session/")) {
    state.route = "session";
    renderSession(decodeURIComponent(route.slice(8))).catch(showError);
  }
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
