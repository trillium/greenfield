// Sending text to a computer's helper with the same contract as the phone app (docs/mac-contract.md): POST /text with
// { id, text, source }. The id is made once per submitted text and reused on every resend, so a helper that already typed it
// answers "duplicate" instead of typing it twice. Only a 200 counts as delivered; everything else keeps the text queued.
// Exactly one computer per submit: the one chosen on Computers. Nothing here broadcasts or falls back to another computer.

import { forSending } from './text.js';
import { TOKEN_HEADER } from './pairing.js';

export const SOURCE = 'greenfield-pwa';
export const KEEP_SENT = 20;

/** The request for one queued text, for `fetch(base + path, init)`. `token` goes in a header, never in the URL. */
export function textRequest(item, token) {
  return {
    path: '/text',
    init: {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', [TOKEN_HEADER]: token },
      body: JSON.stringify({ id: item.id, text: forSending(item.text), source: SOURCE }),
    },
  };
}

/**
 * What a /text answer means. `reply` is { status, body } or { networkError }.
 * `kind`: sent | unpaired | refused | unreachable. Only `sent` is delivered.
 */
export function interpretSend(reply) {
  if (reply.networkError) {
    return { sent: false, kind: 'unreachable', message: 'Could not reach the computer. The text may or may not have arrived; sending again is safe.' };
  }
  const { status, body = {} } = reply;
  const code = body.error;
  if (status === 200) return { sent: true, kind: 'sent', duplicate: body.duplicate === true, delivery: body.delivery ?? null, message: 'Sent.' };
  if (status === 401 && code === 'invalid_token') return unpaired('This browser is no longer paired with that computer.');
  if (status === 401 || (status === 503 && code === 'identity_unavailable')) {
    return unpaired('That computer will not take text from this browser. Pair it again on the Computers screen.');
  }
  switch (status) {
    case 409: return refused('A password field is focused on that computer. Nothing was typed.');
    case 423: return refused('That computer\'s screen is locked. Nothing was typed.');
    case 503: return refused(code === 'accessibility_not_granted'
      ? 'That computer needs Accessibility approval (or the app in front runs as administrator) before it can type.'
      : 'That computer is not set up to take text yet.');
    case 502: return code === 'helper_unreachable'
      ? { sent: false, kind: 'unreachable', message: 'The page could not reach that computer\'s helper. Is it running?' }
      : refused('The keys were sent but the focused field did not change. Nothing was inserted.');
    case 413: return refused('That text is too large to send in one go.');
    case 429: return refused('The computer is busy; try again in a moment.');
    default: return refused(body.message || `The computer refused the text (${status}).`);
  }
}

const unpaired = (message) => ({ sent: false, kind: 'unpaired', message });
const refused = (message) => ({ sent: false, kind: 'refused', message });

/**
 * What GET /status says about the link to one computer, as one line with a word, not only a colour.
 * `level`: ready | attention | problem | unpaired.
 */
export function interpretStatus(reply) {
  if (reply.networkError) return { level: 'problem', text: 'Cannot be reached' };
  const { status, body = {} } = reply;
  if (status === 200) {
    if (body.accessibility === false) return { level: 'attention', text: 'Needs approval on that computer' };
    if (body.screen_locked) return { level: 'attention', text: 'Ready, but its screen is locked' };
    if (body.secure_input) return { level: 'attention', text: 'Ready, but a password field is focused' };
    return { level: 'ready', text: body.version ? `Ready (helper ${body.version})` : 'Ready' };
  }
  if (status === 401 && body.error === 'invalid_token') return { level: 'unpaired', text: 'Pairing ended: pair again' };
  if (status === 401 || (status === 503 && body.error === 'identity_unavailable')) return { level: 'unpaired', text: 'Not paired with this browser' };
  if (status === 502 && body.error === 'helper_unreachable') return { level: 'problem', text: 'Its helper is not running' };
  return { level: 'problem', text: `Unexpected answer (${status})` };
}

/** `fetch` against one computer's base path, answering { status, body } or { networkError }; never throws. */
export async function call(fetchImpl, base, request, timeoutMs = 10_000) {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);
  try {
    const response = await fetchImpl(base + request.path, { ...request.init, signal: controller.signal, cache: 'no-store' });
    let body = {};
    try {
      body = await response.json();
    } catch {
      body = {};
    }
    return { status: response.status, body };
  } catch (error) {
    return { networkError: String(error?.message ?? error) };
  } finally {
    clearTimeout(timer);
  }
}

/** The texts, newest first, saved so nothing is lost when the page closes or the network drops. */
export class Outbox {
  constructor(store, { now = () => Date.now(), newId = () => crypto.randomUUID() } = {}) {
    this.store = store;
    this.now = now;
    this.newId = newId;
  }

  items() {
    return this.store.get('greenfield.outbox', []);
  }

  pending() {
    return this.items().filter((i) => i.status === 'pending');
  }

  /** Queues the box's text for one computer and returns the item; its id is final. */
  add(text, targetId, targetName = '') {
    const item = { id: this.newId(), text, targetId, targetName, createdAt: this.now(), status: 'pending', attempts: 0, lastError: null };
    this.save([item, ...this.items()]);
    return item;
  }

  update(id, change) {
    this.save(this.items().map((i) => (i.id === id ? { ...i, ...change(i) } : i)));
  }

  /** Drops what is sent beyond the newest KEEP_SENT; a text that was not delivered is never dropped. */
  save(items) {
    let sent = 0;
    this.store.set('greenfield.outbox', items.filter((i) => i.status !== 'sent' || ++sent <= KEEP_SENT));
  }

  /** Sends one item to its computer. `lookup(targetId)` gives { base, token } or null. Returns the verdict. */
  async deliver(id, lookup, fetchImpl) {
    const item = this.items().find((i) => i.id === id);
    if (!item) return null;
    const target = lookup(item.targetId);
    if (!target) {
      const verdict = unpaired('This browser is not paired with that computer. Pair it on the Computers screen, then send again.');
      this.update(id, (i) => ({ attempts: i.attempts + 1, lastError: verdict.message }));
      return verdict;
    }
    const verdict = interpretSend(await call(fetchImpl, target.base, textRequest(item, target.token)));
    this.update(id, (i) => (verdict.sent
      ? { status: 'sent', attempts: i.attempts + 1, lastError: null, sentAt: this.now(), delivery: verdict.delivery }
      : { attempts: i.attempts + 1, lastError: verdict.message }));
    return verdict;
  }

  /** Every waiting text again, oldest first, each to the computer it was meant for, with its own id. */
  async resendAll(lookup, fetchImpl) {
    const results = [];
    for (const item of this.pending().reverse()) results.push(await this.deliver(item.id, lookup, fetchImpl));
    return results;
  }
}
