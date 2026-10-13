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
  if (home) refreshGPU();
}

async function request(path, data) {
  const response = await fetch(path, data === undefined ? { cache: 'no-store' } : {
    method: 'POST', headers: { 'Content-Type': 'application/json', 'X-Humanizer': '1' }, body: JSON.stringify(data)
  });
  const result = await response.json();
  if (!response.ok) throw new Error(result.error?.message || result.error || `HTTP ${response.status}`);
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

function setState(tone, label, title) {
  $('state-pill').dataset.tone = tone;
  $('state-text').textContent = label;
  $('home-title').textContent = title;
}

function describePhase(status) {
  switch (status.phase) {
    case 'ready': return ['ok', 'Ready', 'Ready to connect.'];
    case 'starting': return ['warn', 'Starting', 'Loading the model…'];
    case 'downloading': return ['warn', 'Downloading', 'Downloading the model…'];
    case 'paused': return ['idle', 'Paused', 'Download paused.'];
    case 'error': return ['bad', 'Error', 'Something needs attention.'];
    case 'stopped': return ['idle', 'Standby', status.tier ? 'Ready to connect.' : 'Choose a model to start.'];
    default: return ['idle', 'No model', 'Choose a model to start.'];
  }
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
    const status = await request('/app/status');
    setState(...describePhase(status));
    $('home-description').innerHTML = status.phase === 'ready'
      ? 'The model is loaded for the connected website. It is unloaded when the site closes.'
      : 'Select <b>Connect a browser</b> and type the code on the website. The model loads only while the site is connected.';
    $('active-model').textContent = status.tiers.find((tier) => tier.id === status.tier)?.label || 'None selected';
    $('models').replaceChildren(...status.tiers.map((tier) => modelCard(tier, status)));
    renderDownload(status);
    $('unload').hidden = !['ready', 'starting'].includes(status.phase);
  } catch (error) {
    setState('bad', 'Offline', 'Service offline.');
    $('home-description').textContent = `Cannot reach the local service: ${error.message}`;
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
  if (visible) { refresh(); refreshGPU(); refreshBrowsers(); }
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
    refreshBrowsers();
    setTimeout(closePairing, 2200);
    return;
  }
  if (!st.code) { $('pair-code').textContent = formatCode(''); $('pair-expiry').textContent = 'The code expired.'; return; }
  $('pair-code').textContent = formatCode(st.code);
  const minutes = Math.floor(st.expires_in / 60), seconds = String(st.expires_in % 60).padStart(2, '0');
  $('pair-expiry').textContent = `Expires in ${minutes}:${seconds}`;
}
async function startPairing() {
  $('pair-waiting').hidden = false; $('pair-done').hidden = true;
  $('pair-overlay').hidden = false;
  try { await request('/app/pair/start', {}); } catch (error) { $('pair-expiry').textContent = error.message; return; }
  clearInterval(pairTimer);
  pollPairing();
  pairTimer = setInterval(pollPairing, 1000);
}
$('pair-start').onclick = startPairing;
$('pair-new').onclick = startPairing;
$('pair-cancel').onclick = async () => { closePairing(); try { await request('/app/pair/cancel', {}); } catch { /* the code expires anyway */ } };

function ago(iso) {
  const seconds = Math.max(0, (Date.now() - new Date(iso).getTime()) / 1000);
  if (seconds < 90) return 'just now';
  if (seconds < 3600) return `${Math.round(seconds / 60)} min ago`;
  if (seconds < 86400) return `${Math.round(seconds / 3600)} h ago`;
  return `${Math.round(seconds / 86400)} d ago`;
}
async function refreshBrowsers() {
  if (!shown) return;
  let data;
  try { data = await request('/app/pairings'); } catch { return; }
  const items = data.browsers.map((browser) => {
    const li = el('li');
    const who = el('div', 'who');
    who.append(el('strong', '', browser.name), el('span', '', `Last used ${ago(browser.last_seen)}`));
    li.append(who, button('Remove', async () => {
      if (!confirm(`Remove ${browser.name}? It will need a new code to connect again.`)) return;
      try { await request('/app/pairings/remove', { id: browser.id }); } catch { /* list refresh shows the state */ }
      refreshBrowsers();
    }, true));
    return li;
  });
  if (!items.length) items.push(el('li', 'empty', 'No browser paired yet'));
  $('browser-list').replaceChildren(...items);
}
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
  if (!$('pair-overlay').hidden) $('pair-cancel').click(); else ipc('hide');
});
$('titlebar').addEventListener('mousedown', (event) => {
  if (event.button === 0 && !event.target.closest('button')) ipc('drag');
});
$('service-port').textContent = `127.0.0.1:${location.port}`;

showTab(location.hash === '#models' ? 'models' : 'home');
refresh();
refreshBrowsers();
setInterval(refreshBrowsers, 30000);
setInterval(refresh, STATUS_POLL_MS);
setInterval(refreshGPU, GPU_POLL_MS);
