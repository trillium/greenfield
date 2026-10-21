// concept: V2 (Submit sends the whole box to the chosen computer) / C5 (outbox and retry) / C7 (link health)
import test from 'node:test';
import assert from 'node:assert/strict';
import { Outbox, SOURCE, call, interpretSend, interpretStatus, textRequest, KEEP_SENT } from '../src/send.js';
import { createStore } from '../src/store.js';
import { TOKEN_HEADER } from '../src/pairing.js';

const reply = (status, body = {}) => ({ status, body });
const fakeFetch = (...answers) => {
  const seen = [];
  const f = async (url, init) => {
    seen.push({ url, init });
    const next = answers.length > 1 ? answers.shift() : answers[0];
    if (next instanceof Error) throw next;
    return { status: next.status, json: async () => next.body ?? {} };
  };
  f.seen = seen;
  return f;
};

test('the request is the helper contract: id, text, source, token in a header', () => {
  const r = textRequest({ id: 'id-1', text: '  hello\nworld\n ' }, 'secret-token');
  assert.equal(r.path, '/text');
  assert.equal(r.init.method, 'POST');
  assert.equal(r.init.headers[TOKEN_HEADER], 'secret-token');
  assert.deepEqual(JSON.parse(r.init.body), { id: 'id-1', text: 'hello\nworld\n', source: SOURCE });
  assert.ok(!JSON.stringify(r).includes('?'), 'no query string, so the token is never in a URL');
  assert.ok(SOURCE.length <= 16 && /^[a-z0-9_-]+$/.test(SOURCE), 'the helper logs a source of up to 16 lowercase letters, digits, - and _');
});

test('line breaks go as line feeds, with empty lines and a trailing newline kept', () => {
  const body = JSON.parse(textRequest({ id: 'x', text: 'a\r\n\r\nb\n' }, 't').init.body);
  assert.equal(body.text, 'a\n\nb\n');
});

test('only a 200 counts as sent, and a duplicate counts too', () => {
  assert.deepEqual(interpretSend(reply(200, { ok: true, delivery: 'confirmed' })), { sent: true, kind: 'sent', duplicate: false, delivery: 'confirmed', message: 'Sent.' });
  assert.equal(interpretSend(reply(200, { ok: true, duplicate: true })).duplicate, true);
});

test('every refusal of the contract has its words, and none counts as sent', () => {
  const cases = [
    [reply(401, { error: 'invalid_token' }), 'unpaired', /no longer paired/],
    [reply(401, { error: 'unauthorized' }), 'unpaired', /will not take text/],
    [reply(503, { error: 'identity_unavailable' }), 'unpaired', /will not take text/],
    [reply(503, { error: 'accessibility_not_granted' }), 'refused', /Accessibility/],
    [reply(503, { error: 'key_not_configured' }), 'refused', /not set up/],
    [reply(409, { error: 'secure_input' }), 'refused', /password field/],
    [reply(423, { error: 'screen_locked' }), 'refused', /locked/],
    [reply(413, { error: 'too_large' }), 'refused', /too large/],
    [reply(400, { error: 'bad_request', message: 'text is required' }), 'refused', /text is required/],
    [reply(500, { error: 'insert_failed' }), 'refused', /refused the text \(500\)|could not/],
    [reply(502, { error: 'not_delivered' }), 'refused', /did not change/],
    [reply(502, { error: 'helper_unreachable' }), 'unreachable', /helper/],
    [reply(429, { error: 'rate_limited' }), 'refused', /busy/],
    [{ networkError: 'Failed to fetch' }, 'unreachable', /sending again is safe/],
  ];
  for (const [r, kind, words] of cases) {
    const v = interpretSend(r);
    assert.equal(v.sent, false, JSON.stringify(r));
    assert.equal(v.kind, kind, JSON.stringify(r));
    assert.match(v.message, words, JSON.stringify(r));
  }
});

test('the link line has a word for every state', () => {
  assert.deepEqual(interpretStatus(reply(200, { version: '0.4.0' })), { level: 'ready', text: 'Ready (helper 0.4.0)' });
  assert.equal(interpretStatus(reply(200, { accessibility: false })).level, 'attention');
  assert.match(interpretStatus(reply(200, { screen_locked: true })).text, /locked/);
  assert.match(interpretStatus(reply(200, { secure_input: true })).text, /password/);
  assert.equal(interpretStatus(reply(401, { error: 'invalid_token' })).level, 'unpaired');
  assert.equal(interpretStatus(reply(503, { error: 'identity_unavailable' })).level, 'unpaired');
  assert.match(interpretStatus(reply(502, { error: 'helper_unreachable' })).text, /not running/);
  assert.equal(interpretStatus({ networkError: 'x' }).text, 'Cannot be reached');
});

test('call never throws: a network failure and a timeout are answers', async () => {
  assert.deepEqual(await call(fakeFetch(new Error('offline')), './helper/a', { path: '/status', init: {} }), { networkError: 'offline' });
  const hang = (_url, init) => new Promise((_resolve, reject) => init.signal.addEventListener('abort', () => reject(new Error('aborted'))));
  assert.deepEqual(await call(hang, './helper/a', { path: '/status', init: {} }, 10), { networkError: 'aborted' });
});

const makeOutbox = () => {
  let n = 0;
  let t = 0;
  return new Outbox(createStore(null), { newId: () => `id-${++n}`, now: () => ++t });
};
const target = { base: './helper/mac', token: 'tok' };

test('a text is queued once with a fixed id and sent to the computer it was made for', async () => {
  const outbox = makeOutbox();
  const item = outbox.add('hello', 'mac', 'Mac');
  const f = fakeFetch(reply(200, { ok: true, delivery: 'unconfirmed' }));
  const verdict = await outbox.deliver(item.id, () => target, f);
  assert.equal(verdict.sent, true);
  assert.equal(f.seen[0].url, './helper/mac/text');
  assert.equal(JSON.parse(f.seen[0].init.body).id, 'id-1');
  assert.equal(outbox.items()[0].status, 'sent');
  assert.equal(outbox.pending().length, 0);
});

test('a text that was not delivered stays queued and is resent with the same id', async () => {
  const outbox = makeOutbox();
  const item = outbox.add('hello', 'mac', 'Mac');
  const f = fakeFetch(reply(423, { error: 'screen_locked' }), reply(200, { ok: true }));
  assert.equal((await outbox.deliver(item.id, () => target, f)).sent, false);
  assert.equal(outbox.pending().length, 1);
  assert.match(outbox.pending()[0].lastError, /locked/);
  assert.equal((await outbox.deliver(item.id, () => target, f)).sent, true);
  const ids = f.seen.map((s) => JSON.parse(s.init.body).id);
  assert.deepEqual(ids, ['id-1', 'id-1']);
  assert.equal(outbox.items()[0].attempts, 2);
});

test('a text for a computer that is no longer paired is kept, not sent anywhere else', async () => {
  const outbox = makeOutbox();
  const item = outbox.add('hello', 'mac', 'Mac');
  const f = fakeFetch(reply(200));
  const verdict = await outbox.deliver(item.id, () => null, f);
  assert.equal(verdict.kind, 'unpaired');
  assert.equal(f.seen.length, 0, 'it never falls back to another computer');
  assert.equal(outbox.pending().length, 1);
});

test('retry all sends every waiting text, oldest first, each to its own computer', async () => {
  const outbox = makeOutbox();
  outbox.add('first', 'mac', 'Mac');
  outbox.add('second', 'pc', 'PC');
  const f = fakeFetch(reply(200, { ok: true }));
  const bases = { mac: { base: './helper/mac', token: 'a' }, pc: { base: './helper/pc', token: 'b' } };
  const results = await outbox.resendAll((id) => bases[id], f);
  assert.equal(results.every((r) => r.sent), true);
  assert.deepEqual(f.seen.map((s) => [s.url, JSON.parse(s.init.body).text]), [['./helper/mac/text', 'first'], ['./helper/pc/text', 'second']]);
  assert.equal(outbox.pending().length, 0);
});

test('sent texts are trimmed to the newest few; an undelivered one is never dropped', async () => {
  const outbox = makeOutbox();
  const stuck = outbox.add('stuck', 'mac', 'Mac');
  const f = fakeFetch(reply(200, { ok: true }));
  for (let i = 0; i < KEEP_SENT + 5; i++) {
    const item = outbox.add(`t${i}`, 'mac', 'Mac');
    await outbox.deliver(item.id, () => target, f);
  }
  assert.equal(outbox.items().filter((i) => i.status === 'sent').length, KEEP_SENT);
  assert.ok(outbox.items().some((i) => i.id === stuck.id));
});

test('the queue survives a reload: it is read back from the store', () => {
  const store = createStore(null);
  new Outbox(store, { newId: () => 'a', now: () => 1 }).add('keep me', 'mac', 'Mac');
  assert.equal(new Outbox(store).pending()[0].text, 'keep me');
});
