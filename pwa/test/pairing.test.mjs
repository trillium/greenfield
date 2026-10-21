// concept: C3 (authentication: a one-time code for a scoped token)
import test from 'node:test';
import assert from 'node:assert/strict';
import { PairedComputers, deviceLabel, formatCode, interpretPair, looksLikeCode, normalizeCode, pairRequest, TOKEN_HEADER } from '../src/pairing.js';
import { createStore } from '../src/store.js';

test('a code is read forgivingly and shown with its dash', () => {
  assert.equal(normalizeCode(' abcd-ef gh '), 'ABCDEFGH');
  assert.equal(formatCode('abcdefgh'), 'ABCD-EFGH');
  assert.equal(formatCode('abc'), 'ABC');
  assert.equal(formatCode('abcdefghijkl'), 'ABCD-EFGH');
  assert.ok(looksLikeCode('abcd-efgh'));
  assert.ok(!looksLikeCode('abcd'));
  assert.ok(!looksLikeCode(null));
});

test('the pairing request carries the code and a device name, and no token', () => {
  const r = pairRequest('abcdefgh', 'iPhone, Safari (PWA)');
  assert.equal(r.path, '/pair');
  assert.equal(r.init.method, 'POST');
  assert.deepEqual(JSON.parse(r.init.body), { code: 'ABCD-EFGH', device: 'iPhone, Safari (PWA)' });
  assert.equal(r.init.headers[TOKEN_HEADER], undefined);
});

test('devices are named for the helper\'s list', () => {
  assert.equal(deviceLabel('Mozilla/5.0 (iPhone; CPU iPhone OS 17_0 like Mac OS X) AppleWebKit/605 Version/17 Mobile Safari/604'), 'iPhone, Safari (PWA)');
  assert.equal(deviceLabel('Mozilla/5.0 (Windows NT 10.0) Chrome/120 Safari/537 Edg/120'), 'Windows, Edge (PWA)');
  assert.equal(deviceLabel(''), 'Browser, web app (PWA)');
});

test('a good answer gives the token and when it ends', () => {
  const r = interpretPair({ status: 200, body: { ok: true, token: 'tok', device: { id: 'a1' }, expires_in_s: 100, name: 'Mac' } }, 1000);
  assert.deepEqual(r, { ok: true, token: 'tok', deviceId: 'a1', name: 'Mac', expiresAt: 1000 + 100_000 });
});

test('every refusal is in plain words and says what to do', () => {
  for (const [reply, word] of [
    [{ status: 401, body: { error: 'pair_refused' } }, 'greenfield-inserter pair'],
    [{ status: 429, body: {} }, 'Wait a minute'],
    [{ status: 400, body: {} }, '8 letters'],
    [{ status: 404, body: {} }, 'too old'],
    [{ networkError: 'x' }, 'could not be reached'],
    [{ status: 200, body: {} }, 'error \\(200\\)'],
  ]) {
    const r = interpretPair(reply);
    assert.equal(r.ok, false);
    assert.match(r.message, new RegExp(word));
  }
});

test('paired computers are kept per computer, expire, and are forgotten', () => {
  let now = 1_000;
  const paired = new PairedComputers(createStore(null), () => now);
  assert.equal(paired.activeId(), null);
  paired.save('mac', { token: 't1', deviceId: 'd1', name: 'Mac', expiresAt: 5_000 });
  paired.save('pc', { token: 't2', deviceId: 'd2', name: 'PC', expiresAt: 9_000 });
  assert.equal(paired.get('mac').token, 't1');
  assert.equal(paired.activeId(), 'mac', 'the first paired computer is active until another is chosen');
  paired.setActive('pc');
  assert.equal(paired.activeId(), 'pc');
  now = 6_000;
  assert.equal(paired.get('mac'), null, 'an expired token is gone');
  assert.deepEqual(Object.keys(paired.all()), ['pc']);
  paired.forget('pc');
  assert.equal(paired.activeId(), null);
});

test('a chosen computer that is no longer paired is not the active one', () => {
  const paired = new PairedComputers(createStore(null), () => 0);
  paired.save('a', { token: 't', deviceId: '', name: 'A', expiresAt: 10 });
  paired.save('b', { token: 't', deviceId: '', name: 'B', expiresAt: 10 });
  paired.setActive('b');
  paired.forget('b');
  assert.equal(paired.activeId(), 'a');
});

test('the token is only ever in the store under the paired computers, and storage failures never throw', () => {
  const broken = { getItem() { throw new Error('denied'); }, setItem() { throw new Error('denied'); }, removeItem() { throw new Error('denied'); } };
  const paired = new PairedComputers(createStore(broken), () => 0);
  assert.doesNotThrow(() => paired.save('a', { token: 't', deviceId: '', name: 'A', expiresAt: 10 }));
  assert.equal(paired.get('a'), null);
});
