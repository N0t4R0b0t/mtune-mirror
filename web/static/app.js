"use strict";
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

// ---- module state ----------------------------------------------------------
let lastData = null;        // latest /api/status
let evtSource = null;       // console SSE
let pollTimer = null;
let currentView = "dashboard";
let needsFullRender = true; // force a from-scratch render of the active view
let pkgFilter = "";         // Packages view search text
let buildsPage = 1;         // Builds view pagination (1-based)
let buildsData = [];        // last-loaded page of build sweeps (for row expansion)
let pkgAttempts = [];       // attempts loaded into the package modal
const PER = 25;

// ---- api -------------------------------------------------------------------
async function api(method, path, body) {
  const opt = { method };
  if (body !== undefined) {
    opt.headers = { "Content-Type": typeof body === "string" ? "text/plain" : "application/json" };
    opt.body = typeof body === "string" ? body : JSON.stringify(body);
  }
  const r = await fetch(path, opt);
  if (!r.ok) throw new Error((await r.text()) || r.statusText);
  const ct = r.headers.get("content-type") || "";
  return ct.includes("json") ? r.json() : r.text();
}

// ---- formatting ------------------------------------------------------------
function fmtTime(sec) {
  if (!sec) return "—";
  return new Date(sec * 1000).toLocaleString();
}
function fmtTimer(v) {
  if (!v) return "—";
  const s = String(v).trim();
  if (/^\d+$/.test(s)) {
    const n = parseInt(s, 10);
    return n > 0 ? new Date(n / 1000).toLocaleString() : "—";
  }
  return s;
}
function fmtAgo(sec, now) {
  if (!sec) return "—";
  const d = Math.max(0, (now || Date.now() / 1000) - sec);
  if (d < 60) return "just now";
  if (d < 3600) return Math.floor(d / 60) + "m ago";
  if (d < 86400) return Math.floor(d / 3600) + "h ago";
  return Math.floor(d / 86400) + "d ago";
}
function fmtDur(secs) {
  secs = Number(secs) || 0;
  if (secs < 60) return secs + "s";
  const m = Math.floor(secs / 60), s = secs % 60;
  if (m < 60) return `${m}m${s ? " " + s + "s" : ""}`;
  return `${Math.floor(m / 60)}h ${m % 60}m`;
}

// ---- toast notifications ---------------------------------------------------
function toast(msg, type = "err") {
  const t = document.createElement("div");
  t.className = "toast " + type;
  t.textContent = msg;
  $("toasts").appendChild(t);
  setTimeout(() => t.classList.add("show"), 10);
  setTimeout(() => { t.classList.remove("show"); setTimeout(() => t.remove(), 300); }, 4200);
}

// ---- polling (adaptive; independent of the console) ------------------------
// Polls status on a cadence that tightens to 3s while any build runs and relaxes
// to 15s when idle. Crucially it runs regardless of whether the console is open,
// so "Currently building" and the package tables update live without a refresh.
async function poll() {
  try {
    lastData = await api("GET", "/api/status");
  } catch (e) {
    setHeaderError(e.message);
    scheduleNext();
    return;
  }
  renderHeader(lastData);
  refreshView(lastData);
  scheduleNext();
}
function scheduleNext() {
  clearTimeout(pollTimer);
  pollTimer = setTimeout(poll, buildsActive(lastData) ? 3000 : 15000);
}
// A build is "active" if any arch has a live sweep (current.json — written by any
// build.sh) OR a systemd build unit is running. current is the reliable signal:
// `running` only sees systemd-launched builds, so we can't rely on it alone.
function buildsActive(data) {
  if (!data) return false;
  return (data.arches || []).some((a) => a.current) || (data.running || []).length > 0;
}
function activeBuildCount(data) {
  if (!data) return 0;
  return Math.max((data.arches || []).filter((a) => a.current).length, (data.running || []).length);
}
// Fire an immediate status refresh (e.g. right after starting/stopping a build)
// so the UI reacts within one round-trip instead of on the next scheduled tick.
function kick() { clearTimeout(pollTimer); poll(); }

// ---- header ----------------------------------------------------------------
function setHeaderError(msg) {
  $("stats").innerHTML = `<span class="pill err"><span class="k">status</span>${esc(msg)}</span>`;
}
function renderHeader(data) {
  renderStats(data);
  $("paused-badge").style.display = data.paused ? "" : "none";
  $("pause-btn").textContent = data.paused ? "Resume" : "Pause";
  $("pause-btn").className = data.paused ? "primary" : "";
}
function renderStats(data) {
  const d = data.disk || {};
  const builds = activeBuildCount(data);
  const cpu = data.cpuPct || 0;
  const pills = [];
  if (d.size) {
    const cls = d.pct >= 90 ? "err" : d.pct >= 75 ? "warn" : "";
    pills.push(pill("Disk", `${d.used} / ${d.size} (${d.pct}%) · ${d.avail} free`, cls));
  }
  pills.push(pill("CPU", cpu + "%", cpu >= 90 ? "err" : cpu >= 60 ? "warn" : ""));
  pills.push(pill("Builds", String(builds), builds ? "on" : ""));
  $("stats").innerHTML = pills.join("");
}
function pill(label, value, cls) {
  return `<span class="pill ${cls || ""}"><span class="k">${label}</span>${value}</span>`;
}

// ---- router ----------------------------------------------------------------
function route() {
  const hash = location.hash.replace(/^#\/?/, "");
  const name = hash.split("/")[0] || "dashboard";
  currentView = ["dashboard", "packages", "builds", "settings", "help"].includes(name) ? name : "dashboard";
  document.querySelectorAll("#nav a").forEach((a) =>
    a.classList.toggle("active", a.dataset.view === currentView));
  needsFullRender = true;
  closeDrawer();
  renderCurrent();
}
// ---- drawer menu -----------------------------------------------------------
function toggleDrawer() {
  const open = document.body.classList.toggle("drawer-open");
  $("burger").setAttribute("aria-expanded", open ? "true" : "false");
}
function closeDrawer() {
  document.body.classList.remove("drawer-open");
  $("burger").setAttribute("aria-expanded", "false");
}
document.addEventListener("keydown", (e) => {
  if (e.key !== "Escape") return;
  if (document.body.classList.contains("drawer-open")) return closeDrawer();
  ["pkgmodal", "editor"].forEach((id) => $(id).classList.remove("show"));
});
// Full (re)render of the active view from lastData.
function renderCurrent() {
  const el = $("view"), data = lastData;
  switch (currentView) {
    case "dashboard": renderDashboard(data); break;
    case "packages":  renderPackages(data); break;
    case "builds":    renderBuilds(); break;
    case "settings":  renderSettings(data); break;
    case "help":      el.innerHTML = helpHTML(data); break;
  }
  needsFullRender = false;
}
// Lightweight live update on each poll — never clobbers form inputs in the view.
function refreshView(data) {
  switch (currentView) {
    case "dashboard": renderDashboard(data); break;          // no inputs; cheap
    case "packages":  refreshPackages(data); break;          // updates tbodies only
    case "settings":  if (!inputFocused()) renderSettings(data); break;
    // builds: paged/on-demand, refreshed on nav + page change + build completion
  }
}
function inputFocused() {
  const a = document.activeElement;
  return a && $("view").contains(a) && /^(INPUT|SELECT|TEXTAREA)$/.test(a.tagName);
}
window.addEventListener("hashchange", route);

// ===========================================================================
// DASHBOARD
// ===========================================================================
function renderDashboard(data) {
  if (!data) { $("view").innerHTML = `<p class="muted">loading…</p>`; return; }
  const active = (data.arches || []).filter((a) => a.current && a.current.packages);
  const activeHTML = active.length
    ? `<div class="panel active">
         <div class="head"><h2>Currently building</h2>
           <span class="badge warn">${active.length} active</span></div>
         ${active.map(buildCard).join("")}
       </div>`
    : idleHTML(data);
  // Only replace the recent panel wholesale on a full render, so its fetch isn't
  // re-triggered on every 3s poll.
  const el = $("view");
  if (needsFullRender || !$("dash-active")) {
    el.innerHTML = `<div id="dash-active">${activeHTML}</div>
      <section class="panel" id="recent"><div class="head"><h2>Recent builds</h2>
        <span class="grow"></span><a class="linkbtn" href="#/builds">all builds →</a></div>
        <div id="recent-body" class="muted" style="padding:14px 18px">loading…</div></section>`;
    loadRecent();
  } else {
    $("dash-active").innerHTML = activeHTML;
  }
}
function idleHTML(data) {
  const next = (data.arches || []).map((a) =>
    `<li><span class="mono">${esc(a.name)}</span> <span class="muted">next: ${fmtTimer(a.timer_next)}</span></li>`).join("");
  const paused = data.paused
    ? `<p class="badge err" style="display:inline-block">builds are PAUSED</p>` : "";
  return `<div class="idle">
    <div class="idle-flag">IDLE</div>
    <p class="muted">Nothing is building right now.</p>
    ${paused}
    <ul class="idle-next">${next || '<li class="muted">no arches configured</li>'}</ul>
  </div>`;
}
// one live build sweep card (arch progress + per-package queue)
function buildCard(a) {
  const c = a.current;
  const isDone = (s) => s === "ok" || s === "failed";
  const done = c.packages.filter((p) => isDone(p.status)).length;
  const building = c.packages.filter((p) => p.status === "building").map((p) => p.name);
  const pct = c.total ? Math.round((done / c.total) * 100) : 0;
  const rank = { building: 0, pending: 1, ok: 2, failed: 2 };
  const chips = [...c.packages]
    .sort((x, y) => (rank[x.status] ?? 3) - (rank[y.status] ?? 3))
    .map((p) => `<span class="chip st-${p.status}" onclick="openPkgModal('${esc(a.name)}','${esc(p.name)}')">${esc(p.name)}</span>`).join("");
  const reattach = c.unit
    ? `<button onclick="openConsole('build ${esc(a.name)}','${esc(c.unit)}')">console</button>` : "";
  const now = building.length
    ? `<span class="badge warn">building ${esc(building.join(", "))}</span>`
    : `<span class="badge muted">no package running yet</span>`;
  return `<div class="build">
    <div class="brow">
      <span class="spinner"></span>
      <span class="bname">${esc(a.name)}</span>
      <span class="meta">${esc(c.filter)} · jobs ${c.jobs} · ${done}/${c.total}</span>
      ${now}<span class="grow"></span>${reattach}
    </div>
    <div class="bar-track"><div class="bar-fill" style="width:${pct}%"></div></div>
    <div class="chips queue">${chips}</div>
  </div>`;
}
async function loadRecent() {
  const el = $("recent-body");
  if (!el) return;
  let res;
  try { res = await api("GET", "/api/builds?per=8"); }
  catch (e) { el.innerHTML = `<span class="err">error: ${esc(e.message)}</span>`; return; }
  const rows = (res.builds || []).map(buildRow).join("");
  el.outerHTML = rows
    ? `<table id="recent-body"><thead><tr><th>When</th><th>Arch</th><th>Filter</th><th>Result</th><th>Packages</th></tr></thead><tbody>${rows}</tbody></table>`
    : `<div id="recent-body" class="muted" style="padding:14px 18px">no builds yet</div>`;
}
function buildRow(b) {
  const now = lastData && lastData.now;
  const pkgs = b.packages || [];
  const ok = pkgs.filter((p) => p.result === "ok").length;
  const failed = pkgs.length - ok;
  const st = b.status === "ok"
    ? '<span class="badge ok">ok</span>' : '<span class="badge err">failed</span>';
  const counts = `<span class="ok">${ok} ok</span>${failed ? ` · <span class="err">${failed} failed</span>` : ""}`;
  return `<tr>
    <td title="${esc(fmtTime(b.end || b.start))}">${fmtAgo(b.end || b.start, now)}</td>
    <td class="mono">${esc(b.arch)}</td>
    <td class="mono">${esc(b.filter)}</td>
    <td>${st}</td>
    <td>${counts}</td>
  </tr>`;
}

// ===========================================================================
// PACKAGES
// ===========================================================================
function renderPackages(data) {
  $("view").innerHTML = `
    <div class="toolbar">
      <input type="text" id="pkgfilter" placeholder="filter packages across all arches…"
             value="${esc(pkgFilter)}" oninput="onPkgFilter()">
      <span class="grow"></span>
      <span class="muted" id="pkgcount"></span>
    </div>
    <div id="archlist"></div>`;
  refreshPackages(data);
}
function onPkgFilter() { pkgFilter = $("pkgfilter").value.trim().toLowerCase(); fillPackages(lastData); }
// Ensure the arch sections exist (rebuild only if the arch set changed), then
// fill each tbody + live badges. Filter box and add-forms are never rebuilt here.
function refreshPackages(data) {
  if (!data) return;
  if (!$("archlist")) { renderPackages(data); return; }
  const list = $("archlist");
  const have = [...list.children].map((c) => c.dataset.arch).join(",");
  const want = (data.arches || []).map((a) => a.name).join(",");
  if (have !== want) list.innerHTML = (data.arches || []).map((a) => archSection(a)).join("");
  fillPackages(data);
}
function archSection(a) {
  return `<section class="arch" data-arch="${esc(a.name)}">
    <div class="head">
      <span class="name">${esc(a.name)}</span>
      <span class="meta">${esc(a.base)} · ${esc(a.cflags)}</span>
      <span id="chroot-${esc(a.name)}"></span>
      <span id="bb-${esc(a.name)}"></span>
      <span id="lb-${esc(a.name)}"></span>
      <div class="actions">
        <button class="primary" onclick="build('${esc(a.name)}',{})">Build all</button>
        <button onclick="updateCheck('${esc(a.name)}')">Update-check</button>
      </div>
    </div>
    <table>
      <thead><tr><th>Package</th><th>Origin</th><th>Source</th><th>Repo</th><th>PKGBUILD</th><th>Last build</th><th></th></tr></thead>
      <tbody id="tb-${esc(a.name)}"></tbody>
    </table>
    <div class="addform">
      <input type="text" id="add-${esc(a.name)}" placeholder="extra package name">
      <select id="src-${esc(a.name)}"><option value="upstream">upstream</option><option value="local">local</option></select>
      <button onclick="addPkg('${esc(a.name)}')">Add extra package</button>
    </div>
  </section>`;
}
function fillPackages(data) {
  let shown = 0, total = 0;
  for (const a of data.arches || []) {
    const tb = $("tb-" + a.name);
    if (!tb) continue;
    const pkgs = a.packages || [];
    total += pkgs.length;
    const match = pkgFilter ? pkgs.filter((p) => p.name.toLowerCase().includes(pkgFilter)) : pkgs;
    shown += match.length;
    tb.innerHTML = match.map((p) => pkgRow(a.name, p)).join("")
      || `<tr><td colspan="7" class="muted">${pkgFilter ? "no matches" : "no packages configured"}</td></tr>`;
    $("chroot-" + a.name).outerHTML = a.chroot_ready
      ? `<span id="chroot-${a.name}" class="badge ok">chroot ready</span>`
      : `<span id="chroot-${a.name}" class="badge err">no chroot</span>`;
    $("bb-" + a.name).outerHTML = a.current
      ? `<span id="bb-${a.name}" class="badge warn">● building</span>`
      : `<span id="bb-${a.name}"></span>`;
    $("lb-" + a.name).outerHTML = `<span id="lb-${a.name}">${lastBuildBadge(a.last_build)}</span>`;
  }
  const cnt = $("pkgcount");
  if (cnt) cnt.textContent = pkgFilter ? `${shown} / ${total} shown` : `${total} packages`;
}
function pkgRow(arch, p) {
  const due = p.due ? '<span class="badge warn">DUE</span>' : '<span class="badge ok">ok</span>';
  const src = p.local ? (p.source_version || "—") : "(upstream)";
  const editBtn = p.local ? `<button onclick="editPkgbuild('${arch}','${p.name}')">Edit</button>` : "";
  return `<tr>
    <td>${esc(p.name)} ${due}</td>
    <td class="mono">${esc(p.origin || "")}</td>
    <td>${esc(p.source)}</td>
    <td class="mono">${esc(p.repo_version || "—")}</td>
    <td class="mono">${esc(src)}</td>
    <td class="lastbuild">${lastBuildCell(p)}</td>
    <td><div class="rowact">
      <button onclick="openPkgModal('${arch}','${p.name}')">Details</button>
      <button onclick="build('${arch}',{pkg:'${p.name}',force:true})">Build</button>
      ${editBtn}
      <button class="danger" onclick="removePkg('${arch}','${p.name}')">Remove</button>
    </div></td>
  </tr>`;
}
function lastBuildCell(p) {
  const now = lastData && lastData.now;
  if (!p.last_build) return '<span class="muted">never built</span>';
  const cls = p.last_result === "ok" ? "ok" : "err";
  let s = `<span class="badge ${cls}">${esc(p.last_result || "?")}</span>` +
          ` <span class="meta" title="${esc(fmtTime(p.last_build))}">${fmtAgo(p.last_build, now)}</span>`;
  if (p.last_result !== "ok") {
    s += p.last_ok
      ? ` <span class="meta muted" title="${esc(fmtTime(p.last_ok))}">· ok ${fmtAgo(p.last_ok, now)}</span>`
      : ` <span class="meta muted">· never ok</span>`;
  }
  return s;
}
function lastBuildBadge(lb) {
  if (!lb) return '<span class="badge muted">never built</span>';
  const cls = lb.status === "ok" ? "ok" : lb.status === "failed" ? "err" : "muted";
  return `<span class="badge ${cls}">last: ${esc(lb.status)}</span> <span class="meta">${fmtTime(lb.end)}</span>`;
}

// ===========================================================================
// PACKAGE DETAILS MODAL (build attempts + logs)
// ===========================================================================
async function openPkgModal(arch, pkg) {
  $("pkgmodal").classList.add("show");
  $("pkgmodal-title").textContent = `${arch} / ${pkg}`;
  const body = $("pkgmodal-body");
  body.innerHTML = `<p class="muted">loading history…</p>`;
  // live status, if this package is building right now
  let live = "";
  const a = (lastData && lastData.arches || []).find((x) => x.name === arch);
  const cp = a && a.current && (a.current.packages || []).find((p) => p.name === pkg);
  if (cp) live = `<div class="pkg-live"><span class="spin"></span> currently <span class="badge warn">${esc(cp.status)}</span> in the active sweep</div>`;
  let attempts;
  try { attempts = await api("GET", `/api/history/${arch}/${pkg}`); }
  catch (e) { body.innerHTML = `<p class="err">error: ${esc(e.message)}</p>`; return; }
  pkgAttempts = attempts || [];
  if (!pkgAttempts.length) { body.innerHTML = `${live}<p class="muted">No build attempts recorded yet.</p>`; return; }
  const now = lastData && lastData.now;
  const rows = pkgAttempts.map((at, i) => {
    const cls = at.result === "ok" ? "ok" : "err";
    const logBtn = at.has_log
      ? `<button onclick="toggleLog(${i},'${arch}','${pkg}')">log</button>`
      : `<span class="muted" title="no saved log (older build)">no log</span>`;
    return `<div class="attempt">
      <div class="arow">
        <span class="badge ${cls}">${esc(at.result)}</span>
        <span class="meta" title="${esc(fmtTime(at.sweep_start))}">${fmtAgo(at.start || at.sweep_end, now)}</span>
        <span class="mono muted">${esc(at.version || "—")}</span>
        <span class="meta">${fmtDur(at.seconds)}</span>
        <span class="meta muted">${esc(at.filter || "")}</span>
        <span class="grow"></span>${logBtn}
      </div>
      <pre class="attempt-log" id="log-${i}" style="display:none"></pre>
    </div>`;
  }).join("");
  body.innerHTML = `${live}<div class="attempts">${rows}</div>`;
}
async function toggleLog(i, arch, pkg) {
  const pre = $("log-" + i);
  if (pre.style.display !== "none") { pre.style.display = "none"; return; }
  pre.style.display = "";
  if (pre.dataset.loaded) return;
  pre.textContent = "loading…";
  try {
    pre.textContent = await api("GET", `/api/logs/build/${arch}/${pkg}/${pkgAttempts[i].start}`);
    pre.dataset.loaded = "1";
  } catch (e) { pre.textContent = "error: " + e.message; }
}
function closePkgModal() { $("pkgmodal").classList.remove("show"); }

// ===========================================================================
// BUILDS (paged)
// ===========================================================================
function renderBuilds() {
  $("view").innerHTML = `<section class="panel">
    <div class="head"><h2>Build history</h2><span class="grow"></span>
      <button onclick="loadBuilds()">refresh</button></div>
    <div id="buildstable"><p class="muted" style="padding:14px 18px">loading…</p></div>
    <div class="pager" id="buildspager"></div>
  </section>`;
  loadBuilds();
}
async function loadBuilds() {
  const el = $("buildstable");
  if (!el) return;
  let res;
  try { res = await api("GET", `/api/builds?page=${buildsPage}&per=${PER}`); }
  catch (e) { el.innerHTML = `<p class="err" style="padding:14px 18px">error: ${esc(e.message)}</p>`; return; }
  buildsData = res.builds || [];
  if (!buildsData.length) { el.innerHTML = `<p class="muted" style="padding:14px 18px">no builds recorded</p>`; $("buildspager").innerHTML = ""; return; }
  const now = lastData && lastData.now;
  const rows = buildsData.map((b, i) => {
    const pkgs = b.packages || [];
    const ok = pkgs.filter((p) => p.result === "ok").length;
    const failed = pkgs.length - ok;
    const st = b.status === "ok" ? '<span class="badge ok">ok</span>' : '<span class="badge err">failed</span>';
    return `<tr class="brow-toggle" onclick="toggleBuild(${i})">
        <td>${b.start ? "▸" : ""} <span title="${esc(fmtTime(b.end || b.start))}">${fmtAgo(b.end || b.start, now)}</span></td>
        <td class="mono">${esc(b.arch)}</td>
        <td class="mono">${esc(b.filter)}</td>
        <td>${st}</td>
        <td><span class="ok">${ok} ok</span>${failed ? ` · <span class="err">${failed} failed</span>` : ""}</td>
        <td class="mono muted">${fmtDur((b.end || 0) - (b.start || 0))}</td>
      </tr>
      <tr class="detail" id="bdetail-${i}" style="display:none"><td colspan="6"></td></tr>`;
  }).join("");
  el.innerHTML = `<table><thead><tr><th>When</th><th>Arch</th><th>Filter</th><th>Result</th><th>Packages</th><th>Took</th></tr></thead><tbody>${rows}</tbody></table>`;
  const pages = Math.max(1, Math.ceil(res.total / res.per));
  $("buildspager").innerHTML = `
    <button ${buildsPage <= 1 ? "disabled" : ""} onclick="buildsGo(${buildsPage - 1})">← prev</button>
    <span class="muted">page ${res.page} of ${pages} · ${res.total} builds</span>
    <button ${buildsPage >= pages ? "disabled" : ""} onclick="buildsGo(${buildsPage + 1})">next →</button>`;
}
function buildsGo(p) { buildsPage = p; loadBuilds(); }
function toggleBuild(i) {
  const row = $("bdetail-" + i);
  if (row.style.display !== "none") { row.style.display = "none"; return; }
  const b = buildsData[i];
  const cells = (b.packages || []).map((p) => {
    const cls = p.result === "ok" ? "ok" : "err";
    return `<span class="pkgchip" onclick="openPkgModal('${esc(b.arch)}','${esc(p.name)}')">
      <span class="badge ${cls}">${esc(p.result)}</span> ${esc(p.name)}
      <span class="muted">${p.seconds ? fmtDur(p.seconds) : ""}</span></span>`;
  }).join("") || '<span class="muted">no package detail</span>';
  row.firstElementChild.innerHTML = `<div class="pkgchips">${cells}</div>`;
  row.style.display = "";
}

// ===========================================================================
// SETTINGS (groups + per-arch config + global controls)
// ===========================================================================
function renderSettings(data) {
  if (!data) { $("view").innerHTML = `<p class="muted">loading…</p>`; return; }
  const groups = data.groups || [];
  $("view").innerHTML = `
    ${groupsPanel(groups)}
    <section class="panel">
      <div class="head"><h2>Architectures</h2></div>
      ${(data.arches || []).map((a) => archConfig(a, groups)).join("") || '<div class="group muted">no arches</div>'}
    </section>
    <section class="panel">
      <div class="head"><h2>Global controls</h2></div>
      <div class="group">
        <button class="${data.paused ? "primary" : ""}" onclick="togglePause()">${data.paused ? "Resume builds" : "Pause builds"}</button>
        <button class="danger" onclick="stopBuilds()">Stop running builds</button>
        <p class="muted" style="margin:8px 0 0">Pause halts all builds (and stops any in progress) until resumed; it persists across reboots. Stop kills running builds without pausing.</p>
      </div>
    </section>`;
}
function groupsPanel(groups) {
  const rows = groups.map((g) => {
    const chips = (g.packages || []).map((p) =>
      `<span class="chip">${esc(p)}<button title="remove" onclick="groupRemove('${g.name}','${p}')">×</button></span>`
    ).join("") || '<span class="muted">no packages</span>';
    return `<div class="group">
      <div><span class="gname">${esc(g.name)}</span><span class="gdesc">${esc(g.description || "")}</span></div>
      <div class="chips">${chips}</div>
      <div class="inline-form">
        <input type="text" id="gadd-${g.name}" placeholder="add package to ${esc(g.name)}">
        <button onclick="groupAdd('${g.name}')">Add to group</button>
      </div>
    </div>`;
  }).join("");
  return `<section class="panel">
    <div class="head"><h2>Package groups</h2><span class="grow"></span>
      <div class="inline-form">
        <input type="text" id="new-group" placeholder="new group name">
        <input type="text" id="new-group-desc" placeholder="description (optional)">
        <button onclick="groupCreate()">Create group</button>
      </div>
    </div>
    ${rows || '<div class="group muted">no groups defined</div>'}</section>`;
}
function archConfig(a, allGroups) {
  const enabled = a.enabled_groups || [];
  const enabledChips = enabled.map((g) =>
    `<span class="chip enabled">${esc(g)}
       <button title="build this group" onclick="build('${a.name}',{group:'${g}'})">▶</button>
       <button title="disable" onclick="archGroup('${a.name}','${g}',false)">×</button></span>`
  ).join("") || '<span class="muted">none</span>';
  const avail = (allGroups || []).map((g) => g.name).filter((n) => !enabled.includes(n));
  const enableForm = avail.length
    ? `<span class="inline-form"><select id="geno-${a.name}">${avail.map((n) => `<option>${esc(n)}</option>`).join("")}</select>
       <button onclick="archGroupEnable('${a.name}')">Enable group</button></span>` : "";
  const chroot = a.chroot_ready
    ? '<span class="badge ok">chroot ready</span>' : '<span class="badge err">no chroot</span>';
  return `<div class="group">
    <div class="arow"><span class="gname">${esc(a.name)}</span>
      <span class="meta mono">${esc(a.base)} · ${esc(a.cflags)}</span>
      ${chroot}<span class="meta">next: ${fmtTimer(a.timer_next)}</span>
      <span class="grow"></span>
      <button onclick="bootstrap('${a.name}')">Re-bootstrap chroot</button>
    </div>
    <div class="groupbar"><span class="lbl">groups</span>${enabledChips}
      <span class="grow"></span>${enableForm}</div>
  </div>`;
}

// ===========================================================================
// OPERATIONS
// ===========================================================================
async function build(arch, opts) {
  try {
    const r = await api("POST", "/api/build", { arch, ...opts });
    openConsole(`build ${arch}` + (opts.pkg ? ` · ${opts.pkg}` : opts.group ? ` · ${opts.group}` : ""), r.unit);
    kick();
  } catch (e) { toast("build failed: " + e.message); }
}
async function bootstrap(arch) {
  if (!confirm(`Re-bootstrap the ${arch} chroot? This rebuilds it from scratch.`)) return;
  try { const r = await api("POST", `/api/chroot/${arch}/bootstrap`); openConsole(`bootstrap ${arch}`, r.unit); kick(); }
  catch (e) { toast("bootstrap failed: " + e.message); }
}
async function updateCheck(arch) {
  openConsole(`update-check ${arch}`, null);
  try {
    $("console-out").textContent = await api("POST", `/api/update-check/${arch}`);
    const st = $("console-state"); st.textContent = "done"; st.className = "badge ok";
  } catch (e) { $("console-out").textContent = "error: " + e.message; }
}
async function addPkg(arch) {
  const name = $("add-" + arch).value.trim();
  if (!name) return;
  try { await api("POST", `/api/packages/${arch}`, { name, source: $("src-" + arch).value }); kick(); }
  catch (e) { toast("add failed: " + e.message); }
}
async function removePkg(arch, name) {
  if (!confirm(`Remove ${name} from ${arch}?`)) return;
  try { await api("DELETE", `/api/packages/${arch}/${name}`); kick(); }
  catch (e) { toast("remove failed: " + e.message); }
}
async function groupCreate() {
  const name = $("new-group").value.trim();
  if (!name) return;
  try { await api("POST", "/api/groups", { name, description: $("new-group-desc").value }); needsFullRender = true; kick(); }
  catch (e) { toast("create failed: " + e.message); }
}
async function groupAdd(g) {
  const name = $("gadd-" + g).value.trim();
  if (!name) return;
  try { await api("POST", `/api/groups/${g}/packages/${name}`); needsFullRender = true; kick(); }
  catch (e) { toast("add failed: " + e.message); }
}
async function groupRemove(g, pkg) {
  try { await api("DELETE", `/api/groups/${g}/packages/${pkg}`); needsFullRender = true; kick(); }
  catch (e) { toast("remove failed: " + e.message); }
}
async function archGroupEnable(arch) {
  const g = $("geno-" + arch).value;
  if (g) archGroup(arch, g, true);
}
async function archGroup(arch, g, enable) {
  try { await api(enable ? "POST" : "DELETE", `/api/arches/${arch}/groups/${g}`); needsFullRender = true; kick(); }
  catch (e) { toast("failed: " + e.message); }
}
async function togglePause() {
  const paused = lastData && lastData.paused;
  try { await api("POST", paused ? "/api/resume" : "/api/pause"); needsFullRender = true; kick(); }
  catch (e) { toast("failed: " + e.message); }
}
async function stopBuilds() {
  if (!confirm("Stop all running builds now?")) return;
  try { await api("POST", "/api/stop"); kick(); }
  catch (e) { toast("failed: " + e.message); }
}

// ---- console (SSE) ---------------------------------------------------------
function openConsole(title, unit) {
  $("console").classList.add("show");
  $("console-title").textContent = title;
  $("console-out").textContent = "";
  const st = $("console-state");
  st.textContent = "running"; st.className = "badge warn";
  if (evtSource) { evtSource.close(); evtSource = null; }
  if (!unit) return;
  evtSource = new EventSource(`/api/logs/stream?unit=${encodeURIComponent(unit)}`);
  const out = $("console-out");
  evtSource.onmessage = (e) => { out.textContent += e.data + "\n"; out.scrollTop = out.scrollHeight; };
  evtSource.addEventListener("done", () => {
    st.textContent = "done"; st.className = "badge ok";
    evtSource.close(); evtSource = null;
    kick();
    if (currentView === "builds") loadBuilds();
    if (currentView === "dashboard") loadRecent();
  });
  evtSource.onerror = () => { st.textContent = "stream ended"; st.className = "badge muted"; };
}
function closeConsole() {
  if (evtSource) { evtSource.close(); evtSource = null; }
  $("console").classList.remove("show");
}

// ---- PKGBUILD editor -------------------------------------------------------
let editArch = null, editPkg = null;
async function editPkgbuild(arch, pkg) {
  editArch = arch; editPkg = pkg;
  $("editor-title").textContent = `PKGBUILD — ${arch}/${pkg}`;
  $("editor-text").value = "loading…";
  $("editor").classList.add("show");
  try { $("editor-text").value = await api("GET", `/api/pkgbuild/${arch}/${pkg}`); }
  catch (e) { $("editor-text").value = "# error: " + e.message; }
}
async function savePkgbuild() {
  try { await api("PUT", `/api/pkgbuild/${editArch}/${editPkg}`, $("editor-text").value); closeEditor(); kick(); }
  catch (e) { toast("save failed: " + e.message); }
}
function closeEditor() { $("editor").classList.remove("show"); }

// ---- help ------------------------------------------------------------------
function copyPre(btn) {
  const text = btn.parentElement.querySelector("code").textContent;
  navigator.clipboard.writeText(text).then(() => { btn.textContent = "copied"; setTimeout(() => btn.textContent = "copy", 1200); });
}
function helpHTML(data) {
  const host = location.host;
  const arches = (data && data.arches) || [];
  const blocks = arches.map((a) => {
    const conf = `[${a.name}-local]\nServer = http://${host}/repos/${a.name}\nSigLevel = Optional TrustAll`;
    return `<h4>${esc(a.name)} — for ${esc(a.base)} clients</h4>
      <pre><button onclick="copyPre(this)">copy</button><code>${esc(conf)}</code></pre>`;
  }).join("");
  return `<section class="panel help-body">
    <h3>Using the dashboard</h3>
    <ul>
      <li><span class="b">Dashboard</span> — shows any in-flight builds live (idle when nothing runs) plus the most recent sweeps.</li>
      <li><span class="b">Packages</span> — per-arch package tables. Filter across all arches, <span class="b">Build all</span> or build a single package, and open <span class="b">Details</span> for a package's full build history and logs.</li>
      <li><span class="b">Builds</span> — paged history of every build sweep; expand a row to see per-package results and open a package's logs.</li>
      <li><span class="b">Settings</span> — package groups, per-arch enabled groups + chroot, and global pause/stop.</li>
      <li><span class="b">Groups</span> — reusable named package lists; enable a group on the arches that should build it. An arch's build set = its enabled groups + per-arch extras.</li>
      <li><span class="b">DUE</span> badge — a local package whose PKGBUILD version differs from the repo, or one never built.</li>
    </ul>
    <p class="muted">Builds also run automatically on a daily systemd timer per arch. Within an arch, packages build in parallel (configurable concurrency).</p>
    <h3>Installing the repo on a client machine</h3>
    <ol><li>Add the block for the client's architecture to <code>/etc/pacman.conf</code>, <span class="b">above</span> the official <code>[core]</code>/<code>[extra]</code> repos:</li></ol>
    ${blocks || '<p class="muted">No arches configured yet.</p>'}
    <ol start="2">
      <li>Refresh and install: <code>sudo pacman -Sy</code>, then <code>sudo pacman -S &lt;package&gt;</code>.</li>
      <li>Use the block matching the client CPU — i686 machines use the i686 repo, x86_64 machines the x86_64 one.</li>
    </ol>
    <p class="muted"><code>SigLevel = Optional TrustAll</code> accepts these unsigned local packages; the repo is intended for a trusted LAN.</p>
  </section>`;
}

// ---- boot ------------------------------------------------------------------
route();
poll();
