// One-time pairing with a computer's helper (docs/pwa.md): the person at the computer runs `greenfield-inserter pair` and reads a short
// code; this page exchanges it for a scoped token that only sends text, lasts a day, belongs to this browser and can be revoked.
// The token is kept on this device only, sent only to that computer, and never written to a log or a page.

export const TOKEN_HEADER = 'X-Greenfield-Token';

/** The code as the helper compares it: upper case, no spaces or dashes. Shown as ABCD-EFGH. */
export function normalizeCode(code) {
  return String(code ?? '').toUpperCase().replace(/[^\p{L}\p{N}]/gu, '');
}

/** A code looks complete: eight symbols. The helper decides whether it is right. */
export function looksLikeCode(code) {
  return /^[A-Z0-9]{8}$/.test(normalizeCode(code));
}

/** "ABCD-EFGH" while typing. */
export function formatCode(code) {
  const c = normalizeCode(code).slice(0, 8);
  return c.length > 4 ? `${c.slice(0, 4)}-${c.slice(4)}` : c;
}

/** A name for this browser in the helper's list (`pair --list`), from the user agent: "iPhone, Safari". */
export function deviceLabel(userAgent = '') {
  const device = /iPhone/.test(userAgent) ? 'iPhone' : /iPad/.test(userAgent) ? 'iPad' : /Android/.test(userAgent) ? 'Android'
    : /Macintosh/.test(userAgent) ? 'Mac' : /Windows/.test(userAgent) ? 'Windows' : /Linux/.test(userAgent) ? 'Linux' : 'Browser';
  const browser = /Edg\//.test(userAgent) ? 'Edge' : /(Chrome|CriOS)\//.test(userAgent) ? 'Chrome' : /Firefox|FxiOS/.test(userAgent) ? 'Firefox'
    : /Safari\//.test(userAgent) ? 'Safari' : 'web app';
  return `${device}, ${browser} (PWA)`;
}

/** The request that exchanges a code for a token, for `fetch(base + path, init)`. */
export function pairRequest(code, device) {
  return {
    path: '/pair',
    init: { method: 'POST', headers: { 'Content-Type': 'application/json' }, body: JSON.stringify({ code: formatCode(code), device }) },
  };
}

/**
 * What the helper said, in plain words. `reply` is { status, body } or { networkError }.
 * Returns { ok: true, token, deviceId, name, expiresAt } or { ok: false, message }.
 */
export function interpretPair(reply, now = Date.now()) {
  if (reply.networkError) return { ok: false, message: 'That computer could not be reached. Check that you are online and that its helper is running.' };
  const { status, body = {} } = reply;
  if (status === 200 && typeof body.token === 'string' && body.token) {
    const seconds = Number.isFinite(body.expires_in_s) ? body.expires_in_s : 24 * 3600;
    return { ok: true, token: body.token, deviceId: body.device?.id ?? '', name: body.name ?? '', expiresAt: now + seconds * 1000 };
  }
  switch (status) {
    case 401: return { ok: false, message: 'That code is wrong, already used or out of time. Run "greenfield-inserter pair" on the computer for a new one.' };
    case 429: return { ok: false, message: 'Too many tries. Wait a minute, then ask the computer for a new code.' };
    case 400: return { ok: false, message: 'Type the 8 letters and numbers the computer showed.' };
    case 404: return { ok: false, message: 'That computer\'s helper is too old to pair a browser. Update it.' };
    default: return { ok: false, message: body.message || `The computer answered with an error (${status}).` };
  }
}

/** The computers this browser has paired with: id -> { name, token, deviceId, pairedAt, expiresAt }. Tokens never leave this store. */
export class PairedComputers {
  constructor(store, now = Date.now) {
    this.store = store;
    this.now = now;
  }

  all() {
    const saved = this.store.get('greenfield.paired', {});
    const live = Object.fromEntries(Object.entries(saved).filter(([, p]) => p.expiresAt > this.now()));
    if (Object.keys(live).length !== Object.keys(saved).length) this.store.set('greenfield.paired', live);
    return live;
  }

  get(id) {
    return this.all()[id] ?? null;
  }

  save(id, { token, deviceId, name, expiresAt }) {
    this.store.set('greenfield.paired', { ...this.all(), [id]: { token, deviceId, name, pairedAt: this.now(), expiresAt } });
  }

  forget(id) {
    const { [id]: _gone, ...rest } = this.all();
    this.store.set('greenfield.paired', rest);
  }

  /** The computer that gets the next submit; the first paired one until another is chosen. */
  activeId() {
    const live = this.all();
    const chosen = this.store.get('greenfield.active');
    return chosen && live[chosen] ? chosen : Object.keys(live)[0] ?? null;
  }

  setActive(id) {
    this.store.set('greenfield.active', id);
  }
}
