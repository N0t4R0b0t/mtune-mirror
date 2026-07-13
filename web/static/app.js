"use strict";
const $ = (id) => document.getElementById(id);
const esc = (s) => String(s ?? "").replace(/[&<>"]/g, (c) => ({ "&": "&amp;", "<": "&lt;", ">": "&gt;", '"': "&quot;" }[c]));

let evtSource = null;
let lastData = null;

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

function fmtTime(sec) {
  if (!sec) return "—";
  const d = new Date(sec * 1000);
  return d.toLocaleString();
}
function fmtTimer(v) {
  if (!v) return "—";
  const s = String(v).trim();
  if (/^\d+$/.test(s)) { // microseconds since epoch
    const n = parseInt(s, 10);
    return n > 0 ? new Date(n / 1000).toLocaleString() : "—";
  }
  return s; // systemd may already give a human-readable timestamp
}

function lastBuildBadge(lb) {
  if (!lb) return '<span class="badge muted">never built</span>';
  const cls = lb.status === "ok" ? "ok" : lb.status === "failed" ? "err" : "muted";
  return `<span class="badge ${cls}">last: ${esc(lb.status)}</span> <span class="meta">${fmtTime(lb.end)}</span>`;
}

async function load() {
  let data;
  try {
    data = await api("GET", "/api/status");
  } catch (e) {
    $("status-line").textContent = "error: " + e.message;
    return;
  }
  lastData = data;
  if (location.hash === "#help") openHelp();
  $("status-line").textContent = data.arches.length + " arch(es), " + (data.groups || []).length + " group(s)";
  $("disk").textContent = (data.disk || "").split("\n").slice(-1)[0] || "";
  // pause state
  $("paused-badge").style.display = data.paused ? "" : "none";
  $("pause-btn").textContent = data.paused ? "Resume" : "Pause";
  $("pause-btn").className = data.paused ? "primary" : "";
  renderGroups(data.groups || []);
  const root = $("arches");
  root.innerHTML = "";
  for (const a of data.arches) root.appendChild(renderArch(a, data.groups || []));
}

function renderGroups(groups) {
  const el = $("groups");
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
  el.className = "panel";
  el.innerHTML = `
    <div class="head"><h2>Package groups</h2>
      <span class="grow"></span>
      <div class="inline-form">
        <input type="text" id="new-group" placeholder="new group name">
        <input type="text" id="new-group-desc" placeholder="description (optional)">
        <button onclick="groupCreate()">Create group</button>
      </div>
    </div>
    ${rows || '<div class="group muted">no groups defined</div>'}`;
}

function renderArch(a, allGroups) {
  const el = document.createElement("section");
  el.className = "arch";
  const chroot = a.chroot_ready
    ? '<span class="badge ok">chroot ready</span>'
    : '<span class="badge err">no chroot</span>';
  const rows = (a.packages || []).map((p) => pkgRow(a.name, p)).join("") ||
    `<tr><td colspan="6" class="muted">no packages configured</td></tr>`;

  const enabled = a.enabled_groups || [];
  const enabledChips = enabled.map((g) =>
    `<span class="chip enabled">${esc(g)}
       <button title="build this group" onclick="build('${a.name}',{group:'${g}'})">▶</button>
       <button title="disable" onclick="archGroup('${a.name}','${g}',false)">×</button></span>`
  ).join("");
  const avail = (allGroups || []).map((g) => g.name).filter((n) => !enabled.includes(n));
  const enableForm = avail.length
    ? `<span class="inline-form"><select id="geno-${a.name}">${avail.map((n) => `<option>${esc(n)}</option>`).join("")}</select>
       <button onclick="archGroupEnable('${a.name}')">Enable group</button></span>` : "";

  el.innerHTML = `
    <div class="head">
      <span class="name">${esc(a.name)}</span>
      <span class="meta">${esc(a.base)} · ${esc(a.cflags)}</span>
      ${chroot} ${lastBuildBadge(a.last_build)}
      <span class="meta">next: ${fmtTimer(a.timer_next)}</span>
      <div class="actions">
        <button class="primary" onclick="build('${a.name}',{})">Build all</button>
        <button onclick="updateCheck('${a.name}')">Update-check</button>
        <button onclick="bootstrap('${a.name}')">Re-bootstrap chroot</button>
      </div>
    </div>
    <div class="groupbar">
      <span class="lbl">groups</span>
      ${enabledChips || '<span class="muted">none</span>'}
      <span class="grow"></span>
      ${enableForm}
    </div>
    <table>
      <thead><tr><th>Package</th><th>Origin</th><th>Source</th><th>Repo</th><th>PKGBUILD</th><th></th></tr></thead>
      <tbody>${rows}</tbody>
    </table>
    <div class="addform">
      <input type="text" id="add-${a.name}" placeholder="extra package name">
      <select id="src-${a.name}"><option value="upstream">upstream</option><option value="local">local</option></select>
      <button onclick="addPkg('${a.name}')">Add extra package</button>
    </div>`;
  return el;
}

function pkgRow(arch, p) {
  const due = p.due ? '<span class="badge warn">DUE</span>' : '<span class="badge ok">ok</span>';
  const src = p.local ? (p.source_version || "—") : "(upstream)";
  const editBtn = p.local
    ? `<button onclick="editPkgbuild('${arch}','${p.name}')">Edit</button>` : "";
  return `<tr>
    <td>${esc(p.name)} ${due}</td>
    <td class="mono">${esc(p.origin || "")}</td>
    <td>${esc(p.source)}</td>
    <td class="mono">${esc(p.repo_version || "—")}</td>
    <td class="mono">${esc(src)}</td>
    <td><div class="rowact">
      <button onclick="build('${arch}',{pkg:'${p.name}',force:true})">Build</button>
      ${editBtn}
      <button class="danger" onclick="removePkg('${arch}','${p.name}')">Remove</button>
    </div></td>
  </tr>`;
}

// ---- groups + pause ops ----
async function groupCreate() {
  const name = $("new-group").value.trim();
  if (!name) return;
  try { await api("POST", "/api/groups", { name, description: $("new-group-desc").value }); load(); }
  catch (e) { alert("create failed: " + e.message); }
}
async function groupAdd(g) {
  const name = $("gadd-" + g).value.trim();
  if (!name) return;
  try { await api("POST", `/api/groups/${g}/packages/${name}`); load(); }
  catch (e) { alert("add failed: " + e.message); }
}
async function groupRemove(g, pkg) {
  try { await api("DELETE", `/api/groups/${g}/packages/${pkg}`); load(); }
  catch (e) { alert("remove failed: " + e.message); }
}
async function archGroupEnable(arch) {
  const g = $("geno-" + arch).value;
  if (!g) return;
  archGroup(arch, g, true);
}
async function archGroup(arch, g, enable) {
  try { await api(enable ? "POST" : "DELETE", `/api/arches/${arch}/groups/${g}`); load(); }
  catch (e) { alert("failed: " + e.message); }
}
async function togglePause() {
  const paused = lastData && lastData.paused;
  try { await api("POST", paused ? "/api/resume" : "/api/pause"); load(); }
  catch (e) { alert("failed: " + e.message); }
}
async function stopBuilds() {
  if (!confirm("Stop all running builds now?")) return;
  try { await api("POST", "/api/stop"); load(); }
  catch (e) { alert("failed: " + e.message); }
}

// ---- operations ----
async function build(arch, opts) {
  try {
    const r = await api("POST", "/api/build", { arch, ...opts });
    openConsole(`build ${arch}` + (opts.pkg ? ` · ${opts.pkg}` : opts.tier ? ` · ${opts.tier}` : ""), r.unit);
  } catch (e) { alert("build failed: " + e.message); }
}
async function bootstrap(arch) {
  if (!confirm(`Re-bootstrap the ${arch} chroot? This rebuilds it from scratch.`)) return;
  try {
    const r = await api("POST", `/api/chroot/${arch}/bootstrap`);
    openConsole(`bootstrap ${arch}`, r.unit);
  } catch (e) { alert("bootstrap failed: " + e.message); }
}
async function updateCheck(arch) {
  openConsole(`update-check ${arch}`, null);
  try {
    $("console-out").textContent = await api("POST", `/api/update-check/${arch}`);
    $("console-state").textContent = "done";
    $("console-state").className = "badge ok";
  } catch (e) { $("console-out").textContent = "error: " + e.message; }
}
async function addPkg(arch) {
  const name = $("add-" + arch).value.trim();
  if (!name) return;
  try {
    await api("POST", `/api/packages/${arch}`, { name, source: $("src-" + arch).value });
    await load();
  } catch (e) { alert("add failed: " + e.message); }
}
async function removePkg(arch, name) {
  if (!confirm(`Remove ${name} from ${arch}?`)) return;
  try { await api("DELETE", `/api/packages/${arch}/${name}`); await load(); }
  catch (e) { alert("remove failed: " + e.message); }
}

// ---- console (SSE) ----
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
  evtSource.onmessage = (e) => {
    out.textContent += e.data + "\n";
    out.scrollTop = out.scrollHeight;
  };
  evtSource.addEventListener("done", () => {
    st.textContent = "done"; st.className = "badge ok";
    evtSource.close(); evtSource = null;
    load();
  });
  evtSource.onerror = () => { st.textContent = "stream ended"; st.className = "badge muted"; };
}
function closeConsole() {
  if (evtSource) { evtSource.close(); evtSource = null; }
  $("console").classList.remove("show");
}

// ---- PKGBUILD editor ----
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
  try {
    await api("PUT", `/api/pkgbuild/${editArch}/${editPkg}`, $("editor-text").value);
    closeEditor(); load();
  } catch (e) { alert("save failed: " + e.message); }
}
function closeEditor() { $("editor").classList.remove("show"); }

// ---- help / client setup ----
function copyPre(btn) {
  const pre = btn.parentElement;
  const text = pre.querySelector("code").textContent;
  navigator.clipboard.writeText(text).then(() => { btn.textContent = "copied"; setTimeout(() => btn.textContent = "copy", 1200); });
}
function openHelp() {
  const host = location.host;
  const arches = (lastData && lastData.arches) || [];
  const blocks = arches.map((a) => {
    const conf = `[${a.name}-local]\nServer = http://${host}/repos/${a.name}\nSigLevel = Optional TrustAll`;
    return `<h4>${esc(a.name)} — for ${esc(a.base)} clients</h4>
      <pre><button onclick="copyPre(this)">copy</button><code>${esc(conf)}</code></pre>`;
  }).join("");
  $("help-body").innerHTML = `
    <h3>Using the dashboard</h3>
    <ul>
      <li><span class="b">Package groups</span> — reusable named lists of packages (e.g. <code>essentials</code>). Define a group once, then <span class="b">enable</span> it on the arches that should build it. An arch's build set = its enabled groups + any per-arch extras. Use the Groups panel to create groups and add/remove members.</li>
      <li><span class="b">Build all</span> — build the arch's whole effective set. The <span class="b">▶</span> on a group chip builds just that group. Both run in the background; the console streams live logs.</li>
      <li><span class="b">Per-package Build</span> — rebuild a single package (forced, even if up to date).</li>
      <li><span class="b">Origin</span> column — which group a package comes from, or <code>individual</code> for a per-arch extra.</li>
      <li><span class="b">Update-check</span> — list which packages are out of date (repo vs source version).</li>
      <li><span class="b">Re-bootstrap chroot</span> — rebuild that arch's build chroot from scratch.</li>
      <li><span class="b">Add extra package</span> — an arch-specific package beyond the groups. <code>source=local</code> scaffolds an override <code>PKGBUILD</code> to <span class="b">Edit</span> (patch deps, bump <code>pkgrel</code>).</li>
      <li><span class="b">Pause / Resume</span> (top bar) — pause halts all builds and stops any in progress, freeing the box (e.g. to shut it down or reclaim cores); it persists across reboots until you resume. <span class="b">Stop builds</span> kills running builds without pausing.</li>
      <li><span class="b">DUE</span> badge — a local package whose PKGBUILD version differs from the repo, or a package never built.</li>
    </ul>
    <p class="muted">Builds also run automatically on a daily systemd timer per arch (see each card's “next”). Within an arch, packages build in parallel (configurable concurrency).</p>

    <h3>Installing the repo on a client machine</h3>
    <ol>
      <li>Add the block for the client's architecture to <code>/etc/pacman.conf</code>, <span class="b">above</span> the official <code>[core]</code>/<code>[extra]</code> repos so pacman prefers the tuned local builds (and falls back to official ones otherwise):</li>
    </ol>
    ${blocks || '<p class="muted">No arches configured yet.</p>'}
    <ol start="2">
      <li>Refresh and install: <code>sudo pacman -Sy</code>, then <code>sudo pacman -S &lt;package&gt;</code> or <code>sudo pacman -Syu</code>.</li>
      <li>Use the block matching the client CPU — i686 machines use the i686 repo, x86_64 machines the x86_64 one.</li>
    </ol>
    <p class="muted"><code>SigLevel = Optional TrustAll</code> accepts these unsigned local packages; the repo is intended for a trusted LAN.</p>`;
  $("help").classList.add("show");
}
function closeHelp() { $("help").classList.remove("show"); }

load();
setInterval(() => { if (!$("console").classList.contains("show")) load(); }, 15000);
