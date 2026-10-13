const $ = (id) => document.getElementById(id);
// The pairing (this browser's key for one device) is kept so the site reconnects on its own.
const PAIRING_KEY = 'asenaizer.device';
function loadPairing() {
  try { return JSON.parse(localStorage.getItem(PAIRING_KEY)) || null; } catch { return null; }
}
function savePairing(pairing) {
  try { localStorage.setItem(PAIRING_KEY, JSON.stringify(pairing)); } catch { /* the pairing then lasts for this tab only */ }
}
function clearPairing() {
  try { localStorage.removeItem(PAIRING_KEY); } catch { /* nothing stored */ }
}
const saved = loadPairing();
const state = {
  token: saved?.key || '',
  port: Number(saved?.port) || 47615,
  device: saved?.device || '',
  paused: false, // "Disconnect" stops using the device but keeps the pairing
  status: null, config: null, busy: false, abort: null,
  currentDraft: '', currentResult: '', modelOpen: false
};
// The local app listens on the first free port of 47615..47624 (app/internal/launcher/main.go
// listenPreferred). 127.0.0.1 is always the visitor's own computer, so every user shares this range.
const PORT_BASE = 47615;
const PORT_SPAN = 10;
const PROBE_TIMEOUT_MS = 2500;

function localURL(path) { return `http://127.0.0.1:${state.port}${path}`; }
function message(id, value, kind = '') {
  const el = $(id); el.textContent = value; el.className = id === 'model-message' ? `model-message ${kind}` : `message ${kind}`;
}
async function api(path, method = 'GET', body, signal) {
  const options = { method, mode: 'cors', cache: 'no-store', targetAddressSpace: 'loopback', signal,
    headers: { Authorization: `Bearer ${state.token}` } };
  if (body !== undefined) { options.headers['Content-Type'] = 'application/json'; options.body = JSON.stringify(body); }
  const response = await fetch(localURL(path), options);
  const data = await response.json().catch(() => ({}));
  if (!response.ok) {
    const error = new Error(data.error?.message || data.error || `HTTP ${response.status}`);
    error.status = response.status;
    error.code = data.error?.code;
    throw error;
  }
  return data;
}
// Streams a llama.cpp /completion response and reports the text as it arrives.
async function streamCompletion(body, signal, onText) {
  const response = await fetch(localURL('/bridge/completion'), {
    method: 'POST', mode: 'cors', cache: 'no-store', targetAddressSpace: 'loopback', signal,
    headers: { Authorization: `Bearer ${state.token}`, 'Content-Type': 'application/json' },
    body: JSON.stringify({ ...body, stream: true })
  });
  if (!response.ok || !response.body) {
    const data = await response.json().catch(() => ({}));
    throw new Error(data.error?.message || data.error || `HTTP ${response.status}`);
  }
  const reader = response.body.pipeThrough(new TextDecoderStream()).getReader();
  let text = '', pending = '';
  for (;;) {
    const { value, done } = await reader.read();
    if (done) break;
    pending += value;
    const lines = pending.split('\n');
    pending = lines.pop();
    for (const line of lines) {
      if (!line.startsWith('data: ')) continue;
      const event = JSON.parse(line.slice(6));
      if (event.content) { text += event.content; onText(text); }
    }
  }
  return text;
}
// The model card's rule: about 2.5x the draft's tokens, between 256 and the chosen limit.
// Without it a very short draft can run to the full limit before the model stops.
function outputBudget(draft, limit) {
  const draftTokens = Math.ceil(draft.length / 3.5);
  return Math.max(256, Math.min(limit, Math.ceil(draftTokens * 2.5)));
}
// Live diff while the model writes: added words turn green as they arrive. Removed words are
// only struck through on the draft at the end, because a draft word that is not used yet may
// still come later in the rewrite. Rendering is throttled; the word diff is O(draft x result).
const LIVE_DIFF_MS = 120;
const live = { draft: '', text: '', frame: 0, last: 0 };
function startLive(draft) {
  cancelAnimationFrame(live.frame);
  Object.assign(live, { draft, text: '', frame: 0, last: 0 });
}
function showLive(text) {
  live.text = text;
  if (!live.frame) live.frame = requestAnimationFrame(renderLive);
}
function renderLive(now) {
  live.frame = 0;
  if (now - live.last < LIVE_DIFF_MS) { live.frame = requestAnimationFrame(renderLive); return; }
  live.last = now;
  const target = $('result-diff');
  const body = target.parentElement;
  const atBottom = body.scrollHeight - body.scrollTop - body.clientHeight < 40;
  const diff = wordDiff(live.draft, live.text);
  const kept = new Set(diff.keptB);
  if (diff.b.length && !/\s$/.test(live.text)) kept.add(diff.b.length - 1); // word still being written
  renderDiff(target, live.text, diff.b, kept);
  target.classList.add('result-diff');
  $('result-placeholder').hidden = true; target.hidden = false;
  if (atBottom) body.scrollTop = body.scrollHeight;
}
function missingNumbers(draft, result) {
  const original = draft.match(/\d+(?:[.,]\d+)*/g) || [];
  const output = new Set(result.match(/\d+(?:[.,]\d+)*/g) || []);
  return [...new Set(original.filter((number) => !output.has(number)))];
}
function unexpectedChinese(draft, result) {
  const cjk = (text) => (text.match(/[\u3400-\u9fff]/g) || []).length;
  return cjk(draft) < 4 && /[A-Za-z]/.test(draft) && cjk(result) > 5;
}
function copyRate(draft, result) {
  const grams = (text) => {
    const words = text.toLowerCase().split(/\s+/).filter(Boolean);
    return Array.from({ length: Math.max(0, words.length - 4) }, (_, i) => words.slice(i, i + 5).join(' '));
  };
  const output = grams(result);
  if (output.length < 8) return 0;
  const source = new Set(grams(draft));
  return output.filter((gram) => source.has(gram)).length / output.length;
}
function showModels(open = !state.modelOpen) {
  state.modelOpen = open;
  $('model-popover').hidden = !open;
  $('model-trigger').setAttribute('aria-expanded', String(open));
}
function renderModels() {
  const st = state.status;
  if (!st) return;
  const list = $('model-list');
  list.replaceChildren(...(st.tiers || []).map((tier) => {
    const row = document.createElement('div'); row.className = 'model-row' + (st.tier === tier.id ? ' selected' : '');
    const main = document.createElement('div'); main.className = 'model-row-main';
    const title = document.createElement('div'); title.className = 'model-row-title';
    const name = document.createElement('span'); name.textContent = tier.label;
    const size = document.createElement('span'); size.className = 'model-size'; size.textContent = `${tier.approx_gb} GB`;
    title.append(name, size);
    const desc = document.createElement('div'); desc.className = 'model-row-desc';
    desc.textContent = st.tier === tier.id && st.phase === 'ready' ? 'Ready on this device' :
      tier.downloaded ? 'Downloaded' : tier.fits ? 'Available to download' : 'May need more memory';
    main.append(title, desc);
    const actions = document.createElement('div'); actions.className = 'model-row-actions';
    const use = document.createElement('button'); use.type = 'button';
    use.textContent = st.tier === tier.id && st.phase === 'ready' ? 'In use' : tier.downloaded ? 'Use' : 'Download';
    use.disabled = state.busy || (st.tier === tier.id && ['ready', 'starting', 'downloading'].includes(st.phase));
    use.onclick = async () => {
      try {
        await api('/bridge/setup', 'POST', { tier: tier.id, endpoint: st.endpoint || 'hf' });
        message('model-message', `Preparing ${tier.label}…`, 'good'); await refresh();
      } catch (error) { message('model-message', error.message, 'error'); }
    };
    actions.append(use);
    if (st.tier === tier.id && ['ready', 'starting'].includes(st.phase)) {
      const stop = document.createElement('button'); stop.type = 'button'; stop.textContent = 'Unload';
      stop.title = 'Free GPU memory. The model loads again on the next rewrite.';
      stop.onclick = async () => { try { await api('/bridge/model/unload', 'POST', {}); await refresh(); }
        catch (error) { message('model-message', error.message, 'error'); } };
      actions.append(stop);
    }
    if (tier.downloaded) {
      const del = document.createElement('button'); del.type = 'button'; del.className = 'delete'; del.textContent = 'Delete';
      del.disabled = st.tier === tier.id && ['ready', 'starting', 'downloading'].includes(st.phase);
      del.onclick = async () => {
        if (!window.confirm(`Delete the ${tier.label} model file from this device?`)) return;
        try { await api('/bridge/model/delete', 'POST', { tier: tier.id }); await refresh(); }
        catch (error) { message('model-message', error.message, 'error'); }
      };
      actions.append(del);
    }
    row.append(main, actions); return row;
  }));
  const dl = st.download;
  $('download-progress').hidden = !dl;
  if (dl) {
    const percent = dl.total ? Math.min(100, Math.floor(dl.received / dl.total * 100)) : 0;
    $('download-label').textContent = `${dl.file || dl.tier} · ${dl.stage}`;
    $('download-percent').textContent = `${percent}%`;
    $('download-bar').value = percent;
  }
}
function render() {
  const st = state.status;
  const connected = !!state.token && !!st && !state.paused;
  $('connect-screen').hidden = connected;
  $('workspace').hidden = !connected;
  $('connection-status').classList.toggle('connected', connected);
  $('connection-status').disabled = !state.token;
  $('connection-label').textContent = connected ? state.device : state.token ? 'Disconnected' : 'Not connected';
  $('device-name').textContent = state.device || '—';
  $('disconnect').hidden = !connected;
  $('reconnect-box').hidden = connected || !state.token || state.pairingOther;
  $('pair-form').hidden = !!state.token && !state.pairingOther;
  $('reconnect-name').textContent = state.device || 'your device';
  if (!connected) return;
  const active = (st.tiers || []).find((tier) => tier.id === st.tier);
  $('selected-model').textContent = active ? active.label : 'Choose a model';
  // 'stopped' = the device unloaded an idle model; the next rewrite loads it again (a few seconds).
  const standby = st.phase === 'stopped' && st.tiers?.some((tier) => tier.id === st.tier && tier.downloaded);
  $('model-hint').textContent = st.phase === 'ready' ? 'Ready on this device' : standby ? 'Standby · loads on rewrite' :
    st.phase === 'downloading' ? 'Downloading model…' : st.phase === 'starting' ? 'Starting model…' : 'Select a model to begin';
  $('rewrite').disabled = !(st.phase === 'ready' || standby) || !!st.external?.enabled || state.busy || !$('draft').value.trim();
  $('cancel').hidden = !state.busy;
  $('copy').disabled = !state.currentResult;
  renderModels();
}
async function refresh() {
  if (!state.token || state.paused) return;
  try {
    state.status = await api('/bridge/status');
    if (!state.config) state.config = await api('/bridge/config');
    if (state.config.instr + '\n\nX' + state.config.sep !== state.config.probe) throw new Error('Model prompt format mismatch');
  } catch (error) {
    state.status = null;
    if (error.status === 403 && error.code === 'disconnected') {
      // The device's tray chose Disconnect. Stay paired; Reconnect asks the device to resume.
      state.paused = true;
      state.disconnectedByDevice = true;
      message('connect-message', `${state.device || 'The device'} disconnected this browser. Select Reconnect to use it again.`);
    } else if (error.status === 401) {
      forgetLocally();
      message('connect-message', 'This browser was removed from the device. Enter a new code from the app.', 'error');
    } else {
      // The app may have restarted on another port of the range.
      const port = await findDevice();
      if (port && port !== state.port) { state.port = port; savePairing({ ...loadPairing(), port }); }
      message('connect-message', `Cannot reach ${state.device || 'the device'}. Is the Asenaizer app running?`, 'error');
    }
  }
  render();
}
function forgetLocally() {
  clearPairing();
  state.token = ''; state.device = ''; state.status = null; state.config = null; state.paused = false;
}
function words(text) { return [...text.matchAll(/\S+/g)].map((match) => ({ text: match[0], start: match.index, end: match.index + match[0].length })); }
function wordDiff(draft, result) {
  const a = words(draft), b = words(result), width = b.length + 1;
  const table = new Uint16Array((a.length + 1) * width);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      const pos = i * width + j;
      table[pos] = a[i].text === b[j].text ? table[pos + width + 1] + 1 :
        Math.max(table[pos + width], table[pos + 1]);
    }
  }
  const keptA = new Set(), keptB = new Set();
  let i = 0, j = 0;
  while (i < a.length && j < b.length) {
    if (a[i].text === b[j].text) { keptA.add(i); keptB.add(j); i++; j++; }
    else if (table[(i + 1) * width + j] >= table[i * width + j + 1]) i++;
    else j++;
  }
  return { a, b, keptA, keptB };
}
function renderDiff(target, text, tokens, kept) {
  const fragment = document.createDocumentFragment();
  let cursor = 0;
  tokens.forEach((token, index) => {
    if (token.start > cursor) fragment.append(document.createTextNode(text.slice(cursor, token.start)));
    if (kept.has(index)) fragment.append(document.createTextNode(token.text));
    else { const mark = document.createElement('mark'); mark.textContent = token.text; fragment.append(mark); }
    cursor = token.end;
  });
  if (cursor < text.length) fragment.append(document.createTextNode(text.slice(cursor)));
  target.replaceChildren(fragment);
}
function showResult(draft, result) {
  cancelAnimationFrame(live.frame); live.frame = 0; // a pending live frame must not overwrite the final diff
  state.currentDraft = draft; state.currentResult = result;
  const diff = wordDiff(draft, result);
  renderDiff($('draft-diff'), draft, diff.a, diff.keptA);
  renderDiff($('result-diff'), result, diff.b, diff.keptB);
  $('draft-diff').classList.add('draft-diff'); $('result-diff').classList.add('result-diff');
  $('draft').hidden = true; $('draft-diff').hidden = false; $('edit-draft').hidden = false;
  $('result-placeholder').hidden = true; $('result-diff').hidden = false;
}
function editDraft() { $('draft').hidden = false; $('draft-diff').hidden = true; $('edit-draft').hidden = true; $('draft').focus(); }

async function probe(port, signal) {
  const response = await fetch(`http://127.0.0.1:${port}/bridge/ping`,
    { mode: 'cors', cache: 'no-store', targetAddressSpace: 'loopback', signal });
  const data = await response.json();
  if (data.app !== 'asenaizer') throw new Error('not asenaizer');
  return port;
}
// Probes the whole range in parallel and resolves with the first port that answers.
async function findDevice() {
  const ports = [...new Set([state.port, ...Array.from({ length: PORT_SPAN }, (_, i) => PORT_BASE + i)])];
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), PROBE_TIMEOUT_MS);
  try { return await Promise.any(ports.map((port) => probe(port, controller.signal))); }
  catch { return null; }
  finally { clearTimeout(timer); controller.abort(); }
}
function normalizeCode(value) { return value.toUpperCase().replace(/[^A-HJ-NP-Z2-9]/g, '').slice(0, 6); }
function browserLabel() {
  const ua = navigator.userAgent;
  const browser = /Edg\//.test(ua) ? 'Edge' : /OPR\//.test(ua) ? 'Opera' : /Firefox\//.test(ua) ? 'Firefox' :
    /Chrome\//.test(ua) ? 'Chrome' : /Safari\//.test(ua) ? 'Safari' : 'Browser';
  const os = /Windows/.test(ua) ? 'Windows' : /Android/.test(ua) ? 'Android' : /iPhone|iPad/.test(ua) ? 'iOS' :
    /Mac OS X/.test(ua) ? 'macOS' : /Linux/.test(ua) ? 'Linux' : '';
  return os ? `${browser} on ${os}` : browser;
}
$('pair-code').addEventListener('input', () => {
  const code = normalizeCode($('pair-code').value);
  $('pair-code').value = code.length > 3 ? `${code.slice(0, 3)}-${code.slice(3)}` : code;
});
$('pair-form').onsubmit = async (event) => {
  event.preventDefault();
  const code = normalizeCode($('pair-code').value);
  if (code.length !== 6) { message('connect-message', 'Enter the 6-character code shown in the app.', 'error'); return; }
  $('connect').disabled = true;
  message('connect-message', 'Looking for the Asenaizer app…');
  try {
    const port = await findDevice();
    if (!port) throw new Error('Could not find the Asenaizer app on this computer. Start it, then try again.');
    const response = await fetch(`http://127.0.0.1:${port}/bridge/pair`, {
      method: 'POST', mode: 'cors', cache: 'no-store', targetAddressSpace: 'loopback',
      headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code, name: browserLabel() })
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok) throw new Error(data.error?.message || `HTTP ${response.status}`);
    savePairing({ key: data.key, port, device: data.device, browserId: data.browser?.id });
    Object.assign(state, { token: data.key, port, device: data.device, paused: false, pairingOther: false, status: null, config: null });
    $('pair-code').value = '';
    message('connect-message', `Connected to ${data.device}.`, 'good');
    await refresh();
  } catch (error) {
    message('connect-message', error.message, 'error');
  } finally { $('connect').disabled = false; }
};
$('reconnect').onclick = async () => {
  if (state.disconnectedByDevice) {
    try { await api('/bridge/resume', 'POST', {}); state.disconnectedByDevice = false; }
    catch (error) { message('connect-message', error.message, 'error'); return; }
  }
  state.paused = false;
  message('connect-message', `Connecting to ${state.device}…`);
  await refresh();
};
$('use-other').onclick = () => { state.pairingOther = true; render(); $('pair-code').focus(); };

function toggleDeviceMenu(open = $('device-menu').hidden) {
  $('device-menu').hidden = !open;
  $('connection-status').setAttribute('aria-expanded', String(open));
}
$('connection-status').onclick = () => { if (state.token) toggleDeviceMenu(); };
document.addEventListener('click', (event) => {
  if (!$('device-menu').hidden && !event.target.closest('.device-menu-wrap')) toggleDeviceMenu(false);
});
document.addEventListener('keydown', (event) => { if (event.key === 'Escape' && !$('device-menu').hidden) toggleDeviceMenu(false); });
$('disconnect').onclick = () => {
  toggleDeviceMenu(false);
  state.paused = true; state.status = null;
  showModels(false); message('connect-message', 'Disconnected. The device frees its GPU shortly.'); render();
};
$('pair-other').onclick = () => {
  toggleDeviceMenu(false);
  state.paused = true; state.pairingOther = true; state.status = null;
  showModels(false); render(); $('pair-code').focus();
};
$('forget-device').onclick = async () => {
  toggleDeviceMenu(false);
  if (!window.confirm(`Forget ${state.device || 'this device'}? You will need a new code to connect again.`)) return;
  try { await api('/bridge/unpair', 'POST', {}); } catch { /* forget locally even if the device is offline */ }
  forgetLocally(); showModels(false);
  message('connect-message', 'Device forgotten. Enter a code to connect again.'); render();
};
// Desktop app download dialog. Defaults to the visitor's operating system.
function selectOS(os) {
  for (const name of ['windows', 'linux']) {
    $(`os-${name}`).setAttribute('aria-selected', String(name === os));
    $(`panel-${name}`).hidden = name !== os;
  }
}
function openDownload() {
  selectOS(/Linux|X11/.test(navigator.userAgent) && !/Android/.test(navigator.userAgent) ? 'linux' : 'windows');
  $('download-dialog').showModal();
}
$('open-download').onclick = openDownload;
if (location.hash === '#download') openDownload(); // shareable link straight to the installers
$('get-app').onclick = openDownload;
$('close-download').onclick = () => $('download-dialog').close();
$('download-dialog').addEventListener('click', (event) => { if (event.target === event.currentTarget) event.currentTarget.close(); });
$('os-windows').onclick = () => selectOS('windows');
$('os-linux').onclick = () => selectOS('linux');
$('copy-command').onclick = async () => {
  try { await navigator.clipboard.writeText($('linux-command').textContent); $('copy-command').textContent = 'Copied'; }
  catch { $('copy-command').textContent = 'Select and copy'; }
  setTimeout(() => { $('copy-command').textContent = 'Copy'; }, 1800);
};
$('model-trigger').onclick = () => showModels();
$('close-models').onclick = () => showModels(false);
document.addEventListener('keydown', (event) => { if (event.key === 'Escape') showModels(false); });
document.addEventListener('pointerdown', (event) => {
  if (state.modelOpen && !$('model-popover').contains(event.target) && !$('model-trigger').contains(event.target)) showModels(false);
});
$('draft').addEventListener('input', () => {
  const value = $('draft').value;
  if (/^\/model\s*$/i.test(value)) { $('draft').value = ''; showModels(true); return; }
  if (state.currentResult) {
    state.currentResult = '';
    $('result-diff').hidden = true;
    $('result-placeholder').hidden = false;
    message('rewrite-message', 'Draft changed. Rewrite again to compare the new version.');
  }
  $('word-count').textContent = `${value.trim().split(/\s+/).filter(Boolean).length} words`;
  render();
});
$('edit-draft').onclick = editDraft;
$('new-draft').onclick = () => {
  if (state.busy) state.abort?.abort();
  $('draft').value = ''; editDraft(); state.currentDraft = ''; state.currentResult = '';
  $('result-diff').replaceChildren(); $('result-diff').hidden = true; $('result-placeholder').hidden = false;
  $('word-count').textContent = '0 words';
  message('rewrite-message', 'Review numbers, dates, names, and claims before using a result.'); render();
};
$('rewrite').onclick = async () => {
  const draft = $('draft').value.trim();
  if (draft.split(/\s+/).length > 1000) { message('rewrite-message', 'This version accepts up to 1,000 words per request.', 'error'); return; }
  state.busy = true; state.abort = new AbortController(); state.currentResult = '';
  $('result-diff').hidden = true; $('result-placeholder').hidden = false;
  message('rewrite-message', 'Rewriting on your device…'); render();
  try {
    const cfg = state.config;
    let selected = null;
    for (let attempt = 1; attempt <= 3; attempt++) {
      startLive(draft);
      const text = await streamCompletion({
        prompt: cfg.instr + '\n\n' + draft + cfg.sep,
        ...cfg.sampling, n_predict: outputBudget(draft, Number($('output-limit').value))
      }, state.abort.signal, showLive);
      const result = text.trim();
      if (!result) throw new Error('The model returned an empty result');
      const missing = missingNumbers(draft, result);
      const wrongLanguage = unexpectedChinese(draft, result);
      const copied = copyRate(draft, result) > 0.5;
      const score = missing.length + (wrongLanguage ? 100 : 0) + (copied ? 10 : 0);
      if (!selected || score < selected.score) selected = { result, missing, wrongLanguage, copied, score };
      if (score === 0) break;
      if (attempt < 3) message('rewrite-message', `Checking another sample (${attempt + 1}/3)…`);
    }
    showResult(draft, selected.result);
    message('rewrite-message', selected.wrongLanguage ? 'The result may be in the wrong language. Review it before use.' :
      selected.missing.length ? `Check these missing numbers: ${selected.missing.join(', ')}` :
      selected.copied ? 'The result closely matches the draft. You may want to try again.' :
      'Changes are highlighted. Check facts and claims against the draft.',
    selected.wrongLanguage || selected.missing.length || selected.copied ? 'error' : 'good');
  } catch (error) {
    message('rewrite-message', error.name === 'AbortError' ? 'Stopped.' : error.message, 'error');
  } finally { state.busy = false; state.abort = null; render(); }
};
$('cancel').onclick = () => state.abort?.abort();
$('copy').onclick = async () => {
  try { await navigator.clipboard.writeText(state.currentResult); message('rewrite-message', 'Copied.', 'good'); }
  catch { message('rewrite-message', 'Could not copy the result.', 'error'); }
};
// The tray's "Open website" button passes its code in the URL fragment. The code is only
// typed into the box; connecting stays the user's choice. The fragment is removed at once.
function prefillPairCode() {
  const match = location.hash.match(/^#pair=([A-Za-z0-9]{6})$/);
  if (!match) return false;
  history.replaceState(null, '', location.pathname + location.search);
  const code = normalizeCode(match[1]);
  if (code.length !== 6) return false;
  state.paused = !!state.token;
  state.pairingOther = !!state.token;
  $('pair-code').value = `${code.slice(0, 3)}-${code.slice(3)}`;
  render();
  message('connect-message', 'Code filled in from the Asenaizer app. Select Connect to pair this browser.', 'good');
  $('connect').focus();
  return true;
}
if (prefillPairCode()) {
  // Waiting for the user to select Connect.
} else if (state.token) {
  message('connect-message', `Reconnecting to ${state.device || 'your device'}…`);
  findDevice().then((port) => { if (port) state.port = port; refresh(); });
}
setInterval(() => { if (state.token && !state.busy && !state.paused) refresh(); }, 3000);
render();
