const $ = (id) => document.getElementById(id);
const gb = (bytes) => `${(bytes / (1024 ** 3)).toFixed(2)} GB`;
const mbToGb = (mb) => `${(mb / 1024).toFixed(1)} GB`;
const STATUS_POLL_MS = 3000;
const GPU_POLL_MS = 2000;
const BUSY = ['ready', 'starting', 'downloading'];

// window.ipc exists only inside the tray's webview; in a normal browser tab these are no-ops.
const ipc = (message) => window.ipc?.postMessage(message);

function showTab(tab) {
  const home = tab === 'home';
  $('home-panel').hidden = !home;
  $('models-panel').hidden = home;
  $('tab-home').classList.toggle('active', home);
  $('tab-models').classList.toggle('active', !home);
  $('tab-home').setAttribute('aria-selected', String(home));
  $('tab-models').setAttribute('aria-selected', String(!home));
  if (home) refreshGPU(); else refresh();
}

async function request(path, data) {
  const response = await fetch(path, data === undefined ? { cache: 'no-store' } : {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Humanizer': '1' }, body: JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok) {
    const error = new Error(result.error?.message || result.error || `HTTP ${response.status}`);
    error.code = result.error?.code || result.code;
    throw error;
  }
  return result;
}

function showModelError(message) {
  $('model-error').hidden = !message;
  $('model-error').textContent = message || '';
}

async function act(path, data) {
  try { await request(path, data); showModelError(''); }
  catch (error) { showModelError(error.message); }
  await refresh();
}

function setPill(tone, label) {
  $('state-pill').dataset.tone = tone;
  $('state-text').textContent = label;
}

// A browser counts as connected while it polls the bridge (every 3 s) and is not paused.
const SITE_GONE_MS = 90_000;
let browsers = [];
const isConnected = (b) => !b.paused && Date.now() - new Date(b.last_seen).getTime() < SITE_GONE_MS;
const connectedBrowser = () => browsers.find(isConnected) || null;

function openSite(code) {
  if (window.ipc) ipc(code ? `pair:${code}` : 'open-site');
  else window.open(`https://kaanalper.github.io/Asenaizer/${code ? `#pair=${code}` : ''}`, '_blank', 'noopener');
}

function setHeroActions(primary, secondary) {
  $('hero-action').hidden = !primary;
  if (primary) { $('hero-action').firstChild.textContent = `${primary.label} `; $('hero-action').onclick = primary.run; }
  $('hero-site').hidden = !secondary;
  if (secondary) { $('hero-site').textContent = secondary.label; $('hero-site').onclick = secondary.run; }
}

// The home screen leads with the connection: what the user has to do next, or who is connected.
function renderHome(status) {
  const active = connectedBrowser();
  const paused = browsers.length > 0 && browsers.every((b) => b.paused);
  const modelLine = status.phase === 'ready' ? 'The model is loaded on the GPU.'
    : status.phase === 'starting' ? 'Loading the model…'
    : status.phase === 'downloading' ? 'Downloading the model…'
    : status.phase === 'error' ? 'The model needs attention. See Models.'
    : status.tier ? 'The model loads on the next rewrite.' : 'Choose a model in Models.';
  const openSiteAction = { label: 'Open website ↗', run: () => openSite() };
  if (active) {
    $('home-title').textContent = 'Connected';
    $('home-description').textContent = `${active.name} is using this computer. ${modelLine}`;
    setHeroActions(null, openSiteAction);
  } else if (!browsers.length) {
    $('home-title').textContent = 'Not connected';
    $('home-description').textContent = 'Connect a browser to rewrite with this computer\'s GPU.';
    setHeroActions({ label: 'Connect a browser', run: startPairing }, null);
  } else if (paused) {
    $('home-title').textContent = 'Disconnected';
    $('home-description').textContent = 'You disconnected the website. Reconnect when you need it.';
    setHeroActions({ label: 'Reconnect', run: reconnect }, null);
  } else {
    $('home-title').textContent = 'Not connected';
    $('home-description').textContent = 'Open the website on a paired browser and it reconnects on its own.';
    setHeroActions({ label: 'Open website', run: () => openSite() }, { label: 'Connect a browser', run: startPairing });
  }
  if (status.phase === 'error') setPill('bad', 'Error');
  else if (status.phase === 'downloading') setPill('warn', 'Downloading');
  else if (active) setPill('ok', 'Connected');
  else setPill('idle', 'Not connected');
}

function button(label, onClick, secondary = false, disabled = false) {
  const el = document.createElement('button');
  el.type = 'button';
  el.className = secondary ? 'btn secondary' : 'btn';
  el.textContent = label;
  el.disabled = disabled;
  el.onclick = onClick;
  return el;
}

// Versions are Hugging Face revisions of the model repo (main and tags). Lists load when the
// Models tab opens; the user's pick survives the 3 s re-render.
const versionsByTier = {};
const chosenVersion = {};
let modelJobs = {};
async function loadVersions(tierId, fresh = false) {
  try {
    const data = await request(`/app/models/versions?tier=${encodeURIComponent(tierId)}${fresh ? '&refresh=1' : ''}`);
    versionsByTier[tierId] = data.versions;
  } catch (error) { versionsByTier[tierId] = { error: error.message }; }
}
const versionLabel = (v) => `${v.names.join(' / ')}${v.latest ? ' · latest' : ''}${v.installed ? ' · installed' : ''}`;
function versionRow(tier) {
  const row = el('div', 'version-row');
  const versions = versionsByTier[tier.id];
  const job = modelJobs[tier.id];
  if (job && ['downloading', 'waiting', 'installing', 'hashing'].includes(job.state)) {
    const p = job.progress;
    const percent = p?.total ? Math.floor(p.received / p.total * 100) : 0;
    row.append(el('span', 'version-progress', job.state === 'downloading' ? `Downloading version · ${percent}%` : job.state === 'installing' ? 'Installing version…' : 'Verifying…'));
    return row;
  }
  if (!versions) { row.append(el('span', 'version-note', 'Loading versions…')); return row; }
  if (versions.error) { row.append(el('span', 'version-note', 'Versions unavailable')); return row; }
  const select = el('select', 'version-select');
  select.setAttribute('aria-label', `${tier.label} version`);
  for (const v of versions) {
    const option = el('option', '', versionLabel(v));
    option.value = v.revision;
    select.append(option);
  }
  const installed = versions.find((v) => v.installed);
  select.value = chosenVersion[tier.id] || installed?.revision || versions[0]?.revision || '';
  const install = button('Install', async () => {
    const pick = versions.find((v) => v.revision === select.value);
    if (!pick || !confirm(`Install ${pick.names[0]} of ${tier.label}? The current file is replaced after the new one is verified.`)) return;
    delete chosenVersion[tier.id];
    await act('/app/models/install', { tier: tier.id, revision: pick.revision });
  }, true, !select.value || select.value === installed?.revision);
  select.onchange = () => {
    chosenVersion[tier.id] = select.value;
    install.disabled = select.value === installed?.revision;
  };
  row.append(el('span', 'version-note', 'Version'), select, install);
  if (versions.length === 1 && installed) select.disabled = true;
  return row;
}

function modelCard(tier, status) {
  const current = status.tier === tier.id;
  const busy = current && BUSY.includes(status.phase);
  const card = document.createElement('article');
  card.className = `model${current ? ' active' : ''}`;
  const title = document.createElement('div'); title.className = 'title';
  const name = document.createElement('span'); name.textContent = tier.label;
  const approx = document.createElement('small'); approx.textContent = `${tier.approx_gb} GB`;
  title.append(name, approx);
  const info = document.createElement('p');
  const where = !tier.downloaded ? 'Not downloaded'
    : !current ? 'Downloaded'
    : ['ready', 'starting'].includes(status.phase) ? 'Default · loaded on GPU' : 'Default · loads when the website connects';
  info.textContent = `${where} · ${tier.fits ? 'Fits memory' : 'May need more memory'}`;
  const actions = document.createElement('div'); actions.className = 'actions';
  // The model loads only while the website is connected, so the tray just picks the default.
  if (!tier.downloaded) {
    actions.append(button('Download', () => act('/app/setup', { tier: tier.id, endpoint: status.endpoint }),
      false, current && status.phase === 'downloading'));
  } else if (!current) {
    actions.append(button('Make default', () => act('/app/setup', { tier: tier.id, endpoint: status.endpoint })));
  }
  if (tier.downloaded) {
    actions.append(button('Delete', () => {
      if (confirm(`Delete the ${tier.label} model file?`)) act('/app/model/delete', { tier: tier.id });
    }, true, busy));
  }
  card.append(title, info, actions);
  if (tier.downloaded) card.append(versionRow(tier));
  return card;
}

function renderDownload(status) {
  const dl = status.download;
  $('download').hidden = !dl;
  if (!dl) return;
  const percent = dl.total ? Math.min(100, Math.floor(dl.received / dl.total * 100)) : 0;
  const paused = status.phase === 'paused';
  $('download-label').textContent = dl.stage === 'verify' ? 'Verifying model' : `${paused ? 'Paused' : 'Downloading'} ${dl.file}`;
  $('download-percent').textContent = `${percent}%`;
  $('progress').value = percent;
  $('download-bytes').textContent = dl.total ? `${gb(dl.received)} / ${gb(dl.total)}` : gb(dl.received);
  $('download-speed').textContent = dl.speed ? `${(dl.speed / (1024 ** 2)).toFixed(1)} MB/s · ${Math.ceil(dl.eta || 0)}s left` : '';
  $('pause-download').hidden = dl.stage === 'verify';
  $('pause-download').textContent = paused ? 'Resume download' : 'Pause download';
  $('pause-download').onclick = paused
    ? () => act('/app/setup', { tier: dl.tier, endpoint: status.endpoint })
    : () => act('/app/download/pause', {});
}

async function refresh() {
  if (!shown) return;
  try {
    const [status, pairings] = await Promise.all([request('/app/status'), request('/app/pairings')]);
    browsers = pairings.browsers;
    renderHome(status);
    renderConnection();
    $('app-version').textContent = status.version || '—';
    $('active-model').textContent = status.tiers.find((tier) => tier.id === status.tier)?.label || 'None selected';
    if (!$('models-panel').hidden) {
      try { modelJobs = Object.fromEntries((await request('/app/update')).models.map((m) => [m.tier, m])); } catch { modelJobs = {}; }
      for (const tier of status.tiers) if (tier.downloaded && !versionsByTier[tier.id]) loadVersions(tier.id).then(refresh);
      // A finished install changes which version is installed.
      for (const [id, job] of Object.entries(modelJobs)) if (job.state === 'done') { loadVersions(id).then(refresh); request('/app/update/model-ack', { tier: id }).catch(() => {}); }
    }
    $('models').replaceChildren(...status.tiers.map((tier) => modelCard(tier, status)));
    renderDownload(status);
    $('unload').hidden = !['ready', 'starting'].includes(status.phase);
  } catch (error) {
    setPill('bad', 'Offline');
    $('home-title').textContent = 'Service offline';
    $('home-description').textContent = `Cannot reach the local service: ${error.message}`;
    setHeroActions(null, null);
  }
}

// Laptop GPUs throttle around 87 °C; desktop cards run cooler.
function tempTone(celsius) {
  if (celsius >= 85) return 'bad';
  if (celsius >= 75) return 'warn';
  return 'ok';
}

function el(tag, className, text) {
  const node = document.createElement(tag);
  if (className) node.className = className;
  if (text !== undefined) node.textContent = text;
  return node;
}

// One card per graphics card. Cards are kept by UUID and updated in place so the
// VRAM bars animate between polls instead of being rebuilt.
const gpuCards = new Map();

function createGPUCard() {
  const card = el('article', 'gpu');
  const head = el('div', 'gpu-head');
  const title = el('div');
  const label = el('p', 'label');
  const name = el('strong', 'gpu-name');
  const temp = el('span', 'temp');
  title.append(label, name);
  head.append(title, temp);
  const bar = el('div', 'vram-bar');
  bar.setAttribute('role', 'img');
  const ours = el('span', 'ours');
  const other = el('span', 'other');
  bar.append(ours, other);
  const legend = el('div', 'legend');
  const legendItem = (swatch, caption) => {
    const item = el('span');
    const value = el('b');
    if (swatch) item.append(el('i', `sw ${swatch}`));
    item.append(`${caption} `, value);
    legend.append(item);
    return { item, value };
  };
  const oursText = legendItem('ours', 'Asenaizer').value;
  const otherText = legendItem('other', 'Other').value;
  const free = legendItem('', 'Free');
  free.item.className = 'free';
  const metrics = el('dl', 'metrics');
  const metric = (caption) => {
    const box = el('div');
    const value = el('dd', '', '—');
    box.append(el('dt', '', caption), value);
    metrics.append(box);
    return value;
  };
  const vram = metric('VRAM');
  const load = metric('GPU load');
  card.append(head, bar, legend, metrics);
  return { card, label, name, temp, bar, ours, other, oursText, otherText, freeText: free.value, vram, load };
}

function updateGPUCard(view, gpu, index, count) {
  const total = Math.max(gpu.mem_total_mb, 1);
  const ours = Math.min(gpu.engine_mem_mb, gpu.mem_used_mb);
  const other = Math.max(gpu.mem_used_mb - ours, 0);
  view.label.textContent = count > 1 ? `Graphics · GPU ${index}` : 'Graphics';
  view.name.textContent = gpu.name.replace(/^NVIDIA\s+/, '');
  view.temp.textContent = `${gpu.temp_c} °C`;
  view.temp.dataset.tone = tempTone(gpu.temp_c);
  view.ours.style.width = `${ours / total * 100}%`;
  view.other.style.width = `${other / total * 100}%`;
  view.oursText.textContent = mbToGb(ours);
  view.otherText.textContent = mbToGb(other);
  view.freeText.textContent = mbToGb(Math.max(total - gpu.mem_used_mb, 0));
  view.bar.setAttribute('aria-label', `Video memory: Asenaizer ${mbToGb(ours)}, other ${mbToGb(other)} of ${mbToGb(total)}`);
  view.vram.textContent = `${mbToGb(gpu.mem_used_mb)} / ${mbToGb(total)}`;
  view.load.textContent = `${gpu.util_pct}%`;
}

function showGPUMessage(text) {
  gpuCards.clear();
  const card = el('article', 'gpu');
  card.append(el('p', 'label', 'Graphics'), el('strong', 'gpu-name', text));
  $('gpu-list').replaceChildren(card);
}

// Inside the tray the page keeps running while its window is hidden. Polling then would
// keep waking the graphics card, so all polling pauses until the window is shown again.
// In a normal browser tab (no tray) the page counts as shown.
let shown = window.asenaizerTrayShown ?? true;
window.asenaizerTrayVisible = (visible) => {
  shown = visible;
  if (visible) { refresh(); refreshGPU(); refreshUpdate(); }
};

async function refreshGPU() {
  if (!shown || $('home-panel').hidden) return;
  let data;
  try { data = await request('/app/gpu'); } catch { data = { gpus: [], error: 'unavailable' }; }
  $('engine-ram').textContent = data.engine_ram_mb ? mbToGb(data.engine_ram_mb) : 'Not loaded';
  const gpus = data.gpus || [];
  if (gpus.length && gpus.every((gpu) => gpu.asleep)) {
    gpuCards.clear();
    const items = gpus.map((gpu) => {
      const card = el('article', 'gpu asleep');
      const head = el('div', 'gpu-head');
      const title = el('div');
      title.append(el('p', 'label', 'Graphics'), el('strong', 'gpu-name', gpu.name.replace(/^NVIDIA\s+/, '')));
      head.append(title, el('span', 'temp', 'Asleep'));
      card.append(head, el('p', 'sleep-note', 'Powered down to save energy. It wakes when the website connects.'));
      return card;
    });
    $('gpu-list').replaceChildren(...items);
    return;
  }
  if (!gpus.length) {
    showGPUMessage(data.error ? 'No NVIDIA GPU detected' : 'Unavailable');
    return;
  }
  const seen = new Set();
  const cards = gpus.map((gpu, index) => {
    const key = gpu.uuid || String(index);
    seen.add(key);
    if (!gpuCards.has(key)) gpuCards.set(key, createGPUCard());
    const view = gpuCards.get(key);
    updateGPUCard(view, gpu, index, gpus.length);
    return view.card;
  });
  for (const key of gpuCards.keys()) if (!seen.has(key)) gpuCards.delete(key);
  const list = $('gpu-list');
  const unchanged = list.children.length === cards.length && cards.every((card, i) => list.children[i] === card);
  if (!unchanged) list.replaceChildren(...cards);
}

$('tab-home').onclick = () => showTab('home');
$('tab-models').onclick = () => showTab('models');
$('hide').onclick = () => ipc('hide');

// Pairing: the tray shows a short code that the website types in. Polls until a browser pairs.
let pairTimer = null;
let currentCode = '';
function closePairing() {
  clearInterval(pairTimer); pairTimer = null;
  $('pair-overlay').hidden = true;
}
function formatCode(code) { return code ? `${code.slice(0, 3)}-${code.slice(3)}` : '––– –––'; }
async function pollPairing() {
  let st;
  try { st = await request('/app/pair/state'); } catch { return; }
  if (st.paired) {
    clearInterval(pairTimer); pairTimer = null;
    $('pair-waiting').hidden = true; $('pair-done').hidden = false;
    $('pair-done-name').textContent = st.paired.name;
    refresh();
    setTimeout(closePairing, 2200);
    return;
  }
  if (!st.code) { $('pair-code').textContent = formatCode(''); $('pair-expiry').textContent = 'The code expired.'; return; }
  $('pair-code').textContent = formatCode(st.code);
  currentCode = st.code;
  const minutes = Math.floor(st.expires_in / 60), seconds = String(st.expires_in % 60).padStart(2, '0');
  $('pair-expiry').textContent = `Expires in ${minutes}:${seconds}`;
}
async function startPairing() {
  $('pair-waiting').hidden = false; $('pair-done').hidden = true;
  $('pair-overlay').hidden = false;
  refreshLAN();
  try { await request('/app/pair/start', {}); } catch (error) { $('pair-expiry').textContent = error.message; return; }
  clearInterval(pairTimer);
  pollPairing();
  pairTimer = setInterval(pollPairing, 1000);
}
$('pair-start').onclick = startPairing;
$('pair-open-site').onclick = () => { if (currentCode) openSite(currentCode); };
$('pair-new').onclick = startPairing;
$('pair-cancel').onclick = async () => { closePairing(); try { await request('/app/pair/cancel', {}); } catch { /* the code expires anyway */ } };

function ago(iso) {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 90) return 'just now';
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} d ago`;
}
async function reconnect() {
  try { await request('/app/pairings/resume', {}); } catch { /* the site still reconnects from its own button */ }
  openSite();
  refresh();
}
async function disconnect() {
  try { await request('/app/pairings/disconnect', {}); } catch (error) { $('conn-detail').textContent = error.message; }
  await refresh();
  refreshGPU();
}
$('conn-reconnect').onclick = reconnect;
$('conn-disconnect').onclick = disconnect;

// Settings: connection state, paired browsers and their state.
function renderConnection() {
  const active = connectedBrowser();
  const paused = browsers.length > 0 && browsers.every((b) => b.paused);
  const card = $('conn-dot').parentElement;
  card.dataset.state = active ? 'connected' : paused ? 'paused' : 'idle';
  $('conn-title').textContent = active ? 'Connected' : paused ? 'Disconnected' : 'Not connected';
  $('conn-detail').textContent = active ? `${active.name} · using this computer`
    : paused ? 'The website is blocked until you reconnect.'
    : browsers.length ? 'No paired browser has the website open.' : 'No browser paired yet.';
  $('conn-disconnect').hidden = !active;
  $('conn-reconnect').hidden = !browsers.length || !!active;
  const items = browsers.map((browser) => {
    const li = el('li');
    const who = el('div', 'who');
    const state = isConnected(browser) ? el('span', 'state-on', 'Connected now')
      : browser.paused ? el('span', 'state-paused', 'Disconnected')
      : el('span', '', `Last used ${ago(browser.last_seen)}`);
    who.append(el('strong', '', browser.name), state);
    li.append(who, button('Remove', async () => {
      if (!confirm(`Remove ${browser.name}? It will need a new code to connect again.`)) return;
      try { await request('/app/pairings/remove', { id: browser.id }); } catch { /* the next refresh shows the state */ }
      refresh();
    }, true));
    return li;
  });
  if (!items.length) items.push(el('li', 'empty', 'No browser paired yet'));
  $('browser-list').replaceChildren(...items);
}

function showSettings(open) {
  $('main-view').hidden = open;
  $('settings-panel').hidden = !open;
  $('settings-open').setAttribute('aria-expanded', String(open));
  if (open) { refresh(); refreshLAN(); refreshUpdate(); }
}
$('settings-open').onclick = () => showSettings($('settings-panel').hidden);
$('settings-back').onclick = () => showSettings(false);

function renderThemeChoice() {
  const choice = document.documentElement.dataset.themeChoice || 'system';
  for (const option of document.querySelectorAll('[data-theme-choice]')) {
    option.setAttribute('aria-checked', String(option.dataset.themeChoice === choice));
  }
}
for (const option of document.querySelectorAll('[data-theme-choice]')) {
  option.onclick = () => { window.asenaizerSetTheme?.(option.dataset.themeChoice); renderThemeChoice(); };
}
renderThemeChoice();
for (const link of document.querySelectorAll('[data-open-site]')) link.onclick = () => openSite();

$('unload').onclick = async () => {
  $('unload').disabled = true;
  try { await request('/app/model/unload', {}); }
  catch (error) { $('home-description').textContent = error.message; }
  $('unload').disabled = false;
  await refresh();
  refreshGPU();
};
document.addEventListener('keydown', (event) => {
  if (event.key !== 'Escape') return;
  if (!$('update-overlay').hidden) { if (!$('update-later').disabled && !$('update-later').hidden) $('update-later').click(); }
  else if (!$('pair-overlay').hidden) $('pair-cancel').click();
  else if (!$('settings-panel').hidden) showSettings(false);
  else ipc('hide');
});
$('titlebar').addEventListener('mousedown', (event) => {
  if (event.button === 0 && !event.target.closest('button')) ipc('drag');
});
// Other computers on this network (lan.go): the service serves the website on its own port, and
// a browser there pairs with a code like any other.
let lan = null;
async function refreshLAN() {
  try { lan = await request('/app/lan'); } catch { return; }
  renderLAN();
}
function renderLAN() {
  if (!lan) return;
  $('lan-toggle').checked = lan.enabled;
  $('lan-toggle').disabled = !lan.site;
  $('lan-detail').textContent = !lan.site ? 'This build cannot serve the website to other computers.'
    : lan.enabled ? (lan.addresses.length ? 'Other computers on this network can open:' : 'On, but this computer has no network address right now.')
    : lan.error || 'Let a browser on another computer in this network use this GPU.';
  $('lan-addresses').hidden = !lan.enabled || !lan.addresses.length;
  $('lan-addresses').replaceChildren(...lan.addresses.map((address) => {
    const li = el('li');
    const text = el('div', 'addr');
    text.append(el('code', '', address.url.replace(/\/$/, '')), el('small', '', address.interface));
    li.append(text, button('Copy', async (event) => {
      const copy = event.currentTarget;
      try { await navigator.clipboard.writeText(address.url); copy.textContent = 'Copied'; setTimeout(() => { copy.textContent = 'Copy'; }, 1400); }
      catch { /* the address can still be selected and copied by hand */ }
    }, true));
    return li;
  }));
  $('lan-warning').hidden = !lan.enabled;
  const first = lan.enabled ? lan.addresses[0] : null;
  $('pair-lan').hidden = !first;
  if (first) $('pair-lan-url').textContent = first.url.replace(/\/$/, '');
}
$('lan-toggle').onchange = async () => {
  const enabled = $('lan-toggle').checked;
  $('lan-toggle').disabled = true;
  try { lan = await request('/app/lan', { enabled }); } catch (error) { $('lan-detail').textContent = error.message; }
  $('lan-toggle').disabled = false;
  renderLAN();
};

// Updates (update.go, update_asenaizer.go): the service checks GitHub Releases. Installing
// downloads and checks the package, then the release's own installer replaces the app, which
// closes this window and opens it again on the new version; that version reports the result.
let update = null;
let updateFlow = false; // Install and restart was chosen in this window
let applying = false;
let manualCheck = false;
let dialogMode = 'offer'; // offer | result
const offered = new Set(); // versions already offered while this window lived
const UPDATE_ERRORS = {
  busy: 'A rewrite is running. Try again when it has finished.',
  offline: 'Could not reach GitHub. Check the connection and try again.',
  rate_limited: 'GitHub is limiting requests right now. Try again later.',
  network: 'The download stopped. Check the connection and try again.',
  not_package: 'The download was not an Asenaizer package. A network sign-in page may have replaced it.',
  no_package: 'This release has no package for this system yet.',
  unsupported: 'This copy cannot update itself. Download the new version from GitHub.',
  not_ready: 'The update is not downloaded yet.',
};
const updateError = (code, message) => UPDATE_ERRORS[code] || message || 'Something went wrong.';
// GitHub's generated release notes as plain text: no markup, no "by @user in <link>".
function notesText(markdown) {
  return (markdown || '').replace(/\r/g, '').replace(/<!--[\s\S]*?-->/g, '')
    .replace(/^\*\*Full Changelog\*\*.*$/gim, '').replace(/^#{1,6}\s*/gm, '')
    .replace(/\*\*(.+?)\*\*/g, '$1').replace(/\[([^\]]+)\]\([^)]+\)/g, '$1')
    .replace(/ by @\S+ in \S+/g, '').replace(/^\s*[*-]\s+/gm, '• ')
    .replace(/\n{3,}/g, '\n\n').trim();
}

async function refreshUpdate() {
  try { update = await request('/app/update'); }
  catch {
    // The service exits to install the update; the window stays on "Installing" until it closes.
    if (updateFlow && applying && !$('update-overlay').hidden) showInstalling();
    return;
  }
  renderUpdate();
}
function showInstalling() {
  $('update-kicker').textContent = 'Restarting';
  $('update-progress').hidden = false;
  $('update-stage').textContent = 'Installing. This window closes and opens again on the new version.';
  $('update-percent').textContent = '';
  $('update-bar').removeAttribute('value');
  $('update-bytes').textContent = '';
  $('update-speed').textContent = '';
  $('update-error').hidden = true;
  $('update-install').disabled = true;
  $('update-later').disabled = true;
}
function renderUpdate() {
  const u = update;
  if (!u) return;
  const app = u.app, latest = app.latest;
  const available = !u.dev && app.available && !!latest;
  $('update-title').textContent = `Asenaizer ${u.current}`;
  $('update-auto').checked = u.auto;
  $('update-auto').disabled = u.dev;
  $('update-check').disabled = u.dev || u.checking;
  $('update-check').textContent = u.checking ? 'Checking…' : 'Check now';
  $('update-detail').textContent = u.dev ? 'Development build · updates are off'
    : u.checking ? 'Checking GitHub…'
    : available ? `Version ${latest.version} is available`
    : u.error ? updateError(u.error)
    : u.last_ok ? `Up to date · checked ${ago(u.last_ok)}` : 'Not checked yet';
  $('update-open').hidden = !available;
  if (available) $('update-open').textContent = `Update to ${latest.version}`;

  if (u.result) { showUpdateResult(u.result); return; }
  if (dialogMode === 'result') return;
  if (manualCheck && !u.checking) { manualCheck = false; if (available) openUpdate(); }
  if (!available) { if (!updateFlow) $('update-overlay').hidden = true; return; }
  // A new version is offered once per window; Later keeps it quiet until the next version.
  if (shown && u.dismissed !== latest.version && !offered.has(latest.version)) { offered.add(latest.version); openUpdate(); }
  if (updateFlow && app.state === 'ready' && !applying) {
    applying = true;
    request('/app/update/app-apply', {}).catch((error) => { applying = false; updateFlow = false; showUpdateError(error); });
  }
  if (app.state === 'error') { updateFlow = false; applying = false; }
  if (!$('update-overlay').hidden) renderUpdateDialog();
}
function showUpdateError(error) {
  $('update-error').hidden = false;
  $('update-error').textContent = updateError(error.code, error.message);
}
function openUpdate() {
  if (!update?.app?.latest) return;
  dialogMode = 'offer';
  $('update-overlay').hidden = false;
  $('update-later').hidden = false;
  renderUpdateDialog();
  $('update-install').focus();
}
function renderUpdateDialog() {
  const u = update, app = u.app, latest = app.latest;
  if (!latest || dialogMode !== 'offer') return;
  // Downloaded and Install and restart chosen: the apply request is on its way.
  const st = updateFlow && applying && app.state === 'ready' ? 'preparing' : app.state;
  const p = app.progress;
  const busy = ['downloading', 'preparing', 'restarting'].includes(st);
  $('update-kicker').textContent = st === 'restarting' ? 'Restarting' : 'Update available';
  $('update-dialog-title').textContent = `Asenaizer ${latest.version}`;
  $('update-sub').textContent = `You have ${u.current}${latest.size ? ` · ${Math.round(latest.size / 1024 ** 2)} MB download` : ''}`;
  $('update-notes').textContent = notesText(latest.notes);
  $('update-progress').hidden = !busy && st !== 'paused';
  if (st === 'downloading' || st === 'paused') {
    const percent = p?.total ? Math.floor(p.received / p.total * 100) : 0;
    $('update-stage').textContent = st === 'paused' ? 'Download paused' : p?.stage === 'verify' ? 'Checking the download…' : 'Downloading';
    $('update-percent').textContent = `${percent}%`;
    $('update-bar').value = percent;
    $('update-bytes').textContent = p?.total ? `${gb(p.received)} / ${gb(p.total)}` : '';
    $('update-speed').textContent = st === 'downloading' && p?.speed ? `${(p.speed / 1024 ** 2).toFixed(1)} MB/s` : '';
  } else if (busy) {
    $('update-stage').textContent = st === 'preparing' ? 'Preparing the update…' : 'Installing. This window closes and opens again on the new version.';
    $('update-percent').textContent = '';
    $('update-bar').removeAttribute('value'); // indeterminate
    $('update-bytes').textContent = '';
    $('update-speed').textContent = '';
  }
  const err = app.error;
  if (err) {
    $('update-error').hidden = false;
    $('update-error').textContent = err.code === 'prepare_failed' ? `The update could not be prepared: ${err.message}` : updateError(err.code, err.message);
  } else if (busy) $('update-error').hidden = true;
  const manual = app.mode === 'manual' || app.mode === 'none';
  $('update-install').textContent = manual ? 'Download from GitHub' : st === 'paused' ? 'Resume and install' : err ? 'Try again' : 'Install and restart';
  $('update-install').disabled = busy;
  $('update-later').textContent = st === 'downloading' ? 'Cancel' : 'Later';
  $('update-later').disabled = st === 'preparing' || st === 'restarting';
}
// The new version (or the old one after a failed install) shows how the last update went.
function showUpdateResult(result) {
  dialogMode = 'result';
  updateFlow = false;
  $('update-overlay').hidden = false;
  $('update-kicker').textContent = result.ok ? 'Updated' : 'Update failed';
  $('update-dialog-title').textContent = result.ok ? `Asenaizer ${result.to}` : `Still on Asenaizer ${result.from}`;
  $('update-sub').textContent = result.ok ? `Updated from ${result.from}.` : '';
  $('update-notes').textContent = result.ok && update.app.latest?.version === result.to ? notesText(update.app.latest.notes) : '';
  $('update-progress').hidden = true;
  $('update-error').hidden = result.ok;
  $('update-error').textContent = result.error || '';
  $('update-install').textContent = 'OK';
  $('update-install').disabled = false;
  $('update-later').hidden = true;
}
async function installUpdate() {
  if (dialogMode === 'result') {
    try { await request('/app/update/ack', {}); } catch { /* shown again next time */ }
    dialogMode = 'offer';
    update.result = null;
    $('update-overlay').hidden = true;
    $('update-later').hidden = false;
    return;
  }
  const app = update?.app;
  if (!app) return;
  if (app.mode === 'manual' || app.mode === 'none') {
    if (window.ipc) ipc('open-releases'); else window.open('https://github.com/KaanAlper/Asenaizer/releases', '_blank', 'noopener');
    return;
  }
  updateFlow = true;
  applying = app.state === 'ready';
  $('update-error').hidden = true;
  try { await request(applying ? '/app/update/app-apply' : '/app/update/app-download', {}); }
  catch (error) { updateFlow = false; applying = false; showUpdateError(error); }
  await refreshUpdate();
}
async function laterUpdate() {
  const app = update?.app;
  updateFlow = false;
  if (app?.state === 'downloading') { try { await request('/app/update/app-cancel', {}); } catch { /* the next poll shows the state */ } }
  else if (app?.latest) { try { await request('/app/update/dismiss', { version: app.latest.version }); } catch { /* asked again later */ } }
  $('update-overlay').hidden = true;
  refreshUpdate();
}
$('update-install').onclick = installUpdate;
$('update-later').onclick = laterUpdate;
$('update-open').onclick = openUpdate;
$('update-check').onclick = async () => {
  manualCheck = true;
  try { await request('/app/update/check', {}); } catch (error) { manualCheck = false; $('update-detail').textContent = updateError(error.code, error.message); return; }
  refreshUpdate();
};
$('update-auto').onchange = async () => {
  try { await request('/app/update/auto', { auto: $('update-auto').checked }); } catch { /* the next refresh shows the saved choice */ }
  refreshUpdate();
};
// The tray menu's "Install update" item opens the window on the update.
window.asenaizerShowUpdate = () => { refreshUpdate().then(() => { if (update?.app?.available) openUpdate(); }); };
setInterval(() => { if (shown && (updateFlow || manualCheck || update?.checking || !$('update-overlay').hidden)) refreshUpdate(); }, 1000);
setInterval(() => { if (shown) refreshUpdate(); }, 60_000);

$('service-port').textContent = `127.0.0.1:${location.port}`;

showTab(location.hash === '#models' ? 'models' : 'home');
if (location.hash === '#settings') showSettings(true);
refresh();
refreshUpdate();
refreshLAN();
request('/app/pair/state').then((st) => { $('device-name').textContent = st.device || '—'; }).catch(() => {});
setInterval(refresh, STATUS_POLL_MS);
setInterval(refreshGPU, GPU_POLL_MS);
