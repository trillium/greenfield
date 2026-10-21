// The page: three screens (Dictate, Computers, Help, named and concepted as in the phone app: docs/concepts.md) over the modules in
// this folder. This file only wires the DOM to them; the rules (what is sent, how an answer is read, when a token is valid) are in the
// modules and are tested without a browser.

import { forSending, isSendable, segments, displayed } from './text.js';
import { PairedComputers, deviceLabel, formatCode, looksLikeCode, pairRequest, interpretPair, TOKEN_HEADER } from './pairing.js';
import { Outbox, call, interpretStatus } from './send.js';
import { Dictation, addPhrases, speechSupport } from './speech.js';
import { discover, helperBase } from './computers.js';
import { browserStore } from './store.js';

const $ = (id) => document.getElementById(id);
const store = browserStore();
const paired = new PairedComputers(store);
const outbox = new Outbox(store);
const SCREENS = ['dictate', 'computers', 'help'];

let computers = [];
let statuses = {};
let pairing = null;
let dictation = null;

/** A DOM element with text and attributes set safely: never HTML from data. */
function el(tag, attrs = {}, ...children) {
  const node = document.createElement(tag);
  for (const [key, value] of Object.entries(attrs)) {
    if (key === 'class') node.className = value;
    else if (key.startsWith('on')) node.addEventListener(key.slice(2), value);
    else if (value === true) node.setAttribute(key, '');
    else if (value !== false && value != null) node.setAttribute(key, value);
  }
  for (const child of children) node.append(child);
  return node;
}

const lookup = (id) => {
  const p = paired.get(id);
  return p ? { base: helperBase(id), token: p.token } : null;
};
const nameOf = (id) => computers.find((c) => c.id === id)?.name ?? paired.get(id)?.name ?? id;

// ---- screens --------------------------------------------------------------------------------------------------------------

function showScreen() {
  const name = SCREENS.includes(location.hash.slice(1)) ? location.hash.slice(1) : 'dictate';
  document.body.dataset.screen = name;
  for (const s of SCREENS) {
    $(`screen-${s}`).hidden = s !== name;
    const tab = $(`tab-${s}`);
    if (s === name) tab.setAttribute('aria-current', 'page');
    else tab.removeAttribute('aria-current');
  }
  if (name === 'help') renderHelp();
}

// ---- Dictate (V1, V2) -----------------------------------------------------------------------------------------------------

/** The mirror behind the text box: the same text, with a return mark in front of each line break. Display only. */
function renderMirror() {
  const mirror = $('mirror');
  const box = $('text');
  mirror.replaceChildren(...segments(box.value).map((s) => (s.marker ? el('span', { class: 'mark' }, s.marker) : document.createTextNode(s.text))));
  // A trailing line break leaves an empty last line in the box; keep the mirror as tall.
  mirror.append(document.createTextNode('​'));
  mirror.scrollTop = box.scrollTop;
  store.set('greenfield.draft', box.value);
}

function renderTarget() {
  const select = $('target');
  const livePaired = paired.all();
  const ids = Object.keys(livePaired);
  select.replaceChildren(...(ids.length ? ids.map((id) => el('option', { value: id }, nameOf(id))) : [el('option', { value: '' }, 'No computer paired yet')]));
  select.value = paired.activeId() ?? '';
  select.disabled = !ids.length;
  const active = paired.activeId();
  $('submit').textContent = `Submit to ${active ? nameOf(active) : 'a computer'}`;
  const line = $('ready-line');
  if (!active) {
    line.textContent = 'Pair a computer on the Computers screen to send text.';
    line.className = 'status level-unpaired';
  } else {
    const s = statuses[active];
    line.textContent = s ? `${symbol(s.level)} ${s.text}` : 'Checking…';
    line.className = `status ${s ? `level-${s.level}` : ''}`;
  }
}

const symbol = (level) => ({ ready: '✓', attention: '!', unpaired: '!', problem: '✕' })[level] ?? '';

async function submit() {
  const note = $('send-note');
  const text = $('text').value;
  if (!isSendable(text)) return void (note.textContent = 'Nothing to send yet.');
  const active = paired.activeId();
  if (!active) {
    note.textContent = 'Pair a computer first.';
    location.hash = '#computers';
    return;
  }
  const item = outbox.add(forSending(text), active, nameOf(active));
  $('text').value = '';
  renderMirror();
  note.textContent = 'Sending…';
  const verdict = await outbox.deliver(item.id, lookup, fetch.bind(globalThis));
  note.textContent = verdict.sent ? `Sent to ${nameOf(active)}.` : `${verdict.message} It is saved under Computers > Waiting to send.`;
  if (verdict.kind === 'unpaired') statuses[active] = { level: 'unpaired', text: 'Pairing ended: pair again' };
  renderAll();
}

function setupDictation() {
  const support = speechSupport(window);
  const button = $('dictate');
  if (!support.supported) {
    $('speech-note').textContent = support.reason;
    $('speech-note').hidden = false;
    button.disabled = true;
    return;
  }
  dictation = new Dictation(support.Recognition, {
    phrase: (phrase) => {
      $('text').value = addPhrases($('text').value, [phrase]);
      renderMirror();
    },
    interim: (text) => void ($('interim').textContent = text ? `Hearing: ${text}` : ''),
    state: (state) => {
      const on = state === 'listening';
      button.setAttribute('aria-pressed', String(on));
      button.textContent = on ? 'Stop' : 'Dictate';
      $('listen-state').textContent = on ? 'Listening… keep this page open and in front.' : '';
      keepAwake(on);
    },
    error: (message) => {
      $('speech-note').textContent = message;
      $('speech-note').hidden = false;
    },
  }, { lang: navigator.language || 'en-US' });
  button.addEventListener('click', () => {
    $('speech-note').hidden = true;
    if (dictation.listening) dictation.stop();
    else dictation.start();
  });
}

let wakeLock = null;
async function keepAwake(on) {
  try {
    if (on && navigator.wakeLock) wakeLock = await navigator.wakeLock.request('screen');
    else if (!on) await wakeLock?.release();
  } catch {
    wakeLock = null; // the screen may lock; dictation then stops, and the page says so
  }
}

// ---- Computers (C1, C2, C3, C5, C7) ---------------------------------------------------------------------------------------

function renderComputers() {
  const list = $('computer-list');
  const active = paired.activeId();
  list.replaceChildren(...computers.map((c) => {
    const isPaired = !!paired.get(c.id);
    const s = statuses[c.id];
    const status = isPaired ? (s ? `${symbol(s.level)} ${s.text}` : 'Checking…') : '! Not paired';
    const actions = el('div', { class: 'actions' });
    if (isPaired && c.id !== active) actions.append(el('button', { type: 'button', onclick: () => { paired.setActive(c.id); renderAll(); } }, `Use ${c.name}`));
    actions.append(el('button', { type: 'button', onclick: () => openPair(c.id) }, isPaired ? 'Pair again' : 'Pair'));
    if (isPaired) actions.append(el('button', { type: 'button', class: 'danger', onclick: () => forget(c.id) }, 'Forget'));
    return el('li', {}, el('div', { class: 'name' }, c.name, c.id === active && isPaired ? el('span', { class: 'active-word' }, ' ✓ Active') : ''),
      el('div', { class: `status level-${isPaired ? s?.level ?? '' : 'unpaired'}` }, status), actions);
  }));
}

function openPair(id) {
  pairing = id;
  $('pair-title').textContent = `Pair with ${nameOf(id)}`;
  $('pair-code').value = '';
  $('pair-note').textContent = `On ${nameOf(id)}, run: greenfield-inserter pair`;
  $('pair-form').hidden = false;
  $('pair-code').focus();
}

async function submitPair(event) {
  event.preventDefault();
  const note = $('pair-note');
  if (!looksLikeCode($('pair-code').value)) return void (note.textContent = 'Type the 8 letters and numbers the computer showed.');
  $('pair-go').disabled = true;
  note.textContent = 'Pairing…';
  const reply = await call(fetch.bind(globalThis), helperBase(pairing), pairRequest($('pair-code').value, deviceLabel(navigator.userAgent)));
  const result = interpretPair(reply);
  $('pair-go').disabled = false;
  if (!result.ok) return void (note.textContent = result.message);
  paired.save(pairing, result);
  if (!paired.activeId() || !store.get('greenfield.active')) paired.setActive(pairing);
  $('pair-form').hidden = true;
  $('pair-code').value = '';
  pairing = null;
  statuses = {};
  renderAll();
  refreshStatuses();
}

/** Forgets one computer: ends the token on that computer when it can be reached, and drops it here either way. */
async function forget(id) {
  const p = paired.get(id);
  if (p) await call(fetch.bind(globalThis), helperBase(id), { path: '/pair/revoke', init: { method: 'POST', headers: { 'Content-Type': 'application/json', [TOKEN_HEADER]: p.token }, body: '{}' } }, 5000);
  paired.forget(id);
  delete statuses[id];
  renderAll();
}

function renderWaiting() {
  const pending = outbox.pending();
  $('waiting-empty').hidden = pending.length > 0;
  $('retry-all').hidden = pending.length === 0;
  $('retry-all').textContent = pending.length === 1 ? 'Retry all, 1 text' : `Retry all, ${pending.length} texts`;
  const badge = $('queue-badge');
  badge.hidden = pending.length === 0;
  badge.textContent = String(pending.length);
  $('waiting-list').replaceChildren(...pending.map((item) => el('li', {},
    el('div', { class: 'name' }, `To ${item.targetName || nameOf(item.targetId)}`),
    el('div', { class: 'sent-text' }, displayed(item.text)),
    item.lastError ? el('div', { class: 'status level-problem' }, `✕ ${item.lastError}`) : '',
    el('div', { class: 'actions' },
      el('button', { type: 'button', onclick: async () => { await outbox.deliver(item.id, lookup, fetch.bind(globalThis)); renderAll(); } }, 'Send again'),
      el('button', { type: 'button', class: 'danger', onclick: () => { outbox.save(outbox.items().filter((i) => i.id !== item.id)); renderAll(); } }, 'Delete')))));
}

async function refreshStatuses() {
  await Promise.all(computers.map(async (c) => {
    const p = paired.get(c.id);
    if (!p) return;
    statuses[c.id] = interpretStatus(await call(fetch.bind(globalThis), helperBase(c.id), { path: '/status', init: { headers: { [TOKEN_HEADER]: p.token } } }, 6000));
  }));
  renderAll();
}

// ---- Help (SH, H1) --------------------------------------------------------------------------------------------------------

function renderHelp() {
  $('health-list').replaceChildren(...(computers.length ? computers : []).map((c) => {
    const s = paired.get(c.id) ? statuses[c.id] : { level: 'unpaired', text: 'Not paired' };
    return el('li', {}, el('div', { class: 'name' }, c.name), el('div', { class: `status level-${s?.level ?? ''}` }, s ? `${symbol(s.level)} ${s.text}` : 'Not checked yet'));
  }));
}

async function loadVersion() {
  try {
    const { version } = await (await fetch('./version.json', { cache: 'no-store' })).json();
    $('version-line').textContent = `Greenfield web app ${version}. Experimental.`;
  } catch {
    $('version-line').textContent = 'Greenfield web app. Experimental.';
  }
}

// ---- wiring ---------------------------------------------------------------------------------------------------------------

function renderAll() {
  renderTarget();
  renderComputers();
  renderWaiting();
  if (document.body.dataset.screen === 'help') renderHelp();
}

async function start() {
  $('text').value = store.get('greenfield.draft', '') || '';
  $('text').addEventListener('input', renderMirror);
  $('text').addEventListener('scroll', () => void ($('mirror').scrollTop = $('text').scrollTop));
  $('newline').addEventListener('click', () => {
    const box = $('text');
    // Like a tap on Enter: it joins the text at the end, as a dictated phrase would, so the next phrase starts on a fresh line.
    box.value = box.value.replace(/[ \t]+$/u, '') + '\n';
    renderMirror();
    box.focus();
  });
  $('clear').addEventListener('click', () => { $('text').value = ''; renderMirror(); });
  $('submit').addEventListener('click', submit);
  $('target').addEventListener('change', (e) => { paired.setActive(e.target.value); renderAll(); });
  $('pair-form').addEventListener('submit', submitPair);
  $('pair-code').addEventListener('input', (e) => { e.target.value = formatCode(e.target.value); });
  $('pair-cancel').addEventListener('click', () => { $('pair-form').hidden = true; pairing = null; });
  $('retry-all').addEventListener('click', async () => { await outbox.resendAll(lookup, fetch.bind(globalThis)); renderAll(); });
  $('health-check').addEventListener('click', refreshStatuses);
  $('forget-all').addEventListener('click', async () => {
    if (!confirm('Forget every pairing on this device? You will have to pair each computer again.')) return;
    for (const id of Object.keys(paired.all())) await forget(id);
  });
  window.addEventListener('hashchange', showScreen);
  window.addEventListener('online', () => outbox.pending().length && outbox.resendAll(lookup, fetch.bind(globalThis)).then(renderAll));
  setupDictation();
  showScreen();
  renderMirror();
  loadVersion();
  const found = await discover(fetch.bind(globalThis));
  computers = found.computers;
  $('discover-note').hidden = !found.error;
  $('discover-note').textContent = found.error ?? '';
  renderAll();
  refreshStatuses();
  if ('serviceWorker' in navigator && (location.protocol === 'https:' || location.hostname === 'localhost')) {
    navigator.serviceWorker.register('./sw.js').catch(() => {});
  }
  document.body.dataset.ready = 'true';
}

start();
