import test, { after, before } from 'node:test';
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { FORWARDED, parseHelpers, start } from '../server.mjs';
import { startFakeHelper } from './fake-helper.mjs';
import { Outbox, call, interpretStatus } from '../src/send.js';
import { PairedComputers, interpretPair, pairRequest } from '../src/pairing.js';
import { discover, helperBase } from '../src/computers.js';
import { createStore } from '../src/store.js';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..');
let helper;
let server;
let base;

before(async () => {
  helper = await startFakeHelper();
  server = await start({ port: 0, helpers: [{ id: 'mac', name: 'Studio Mac', url: helper.url }], root, version: '0.0.0-test' });
  base = `http://127.0.0.1:${server.address().port}`;
});
after(async () => {
  server.closeAllConnections();
  await new Promise((done) => server.close(done));
  await helper.close();
});

const get = (p, init) => fetch(base + p, init);

test('helpers: the default is this computer on the project port; a list is Name=url, and a malformed one is an error', () => {
  assert.deepEqual(parseHelpers('', 47821), [{ id: 'local', name: 'This computer', url: 'http://127.0.0.1:47821' }]);
  assert.deepEqual(parseHelpers('Studio Mac=http://studio.tail1234.ts.net:47821, Office PC=http://pc:47821'), [
    { id: 'studio-mac', name: 'Studio Mac', url: 'http://studio.tail1234.ts.net:47821' },
    { id: 'office-pc', name: 'Office PC', url: 'http://pc:47821' },
  ]);
  for (const bad of ['nope', 'A=ftp://x', 'A=http://x/path', '=http://x', 'A=http://x:1?q=1']) assert.throws(() => parseHelpers(bad), /GREENFIELD_PWA_HELPERS/);
  assert.equal(parseHelpers('A=http://a:1,A=http://b:1').map((h) => h.id).length, 2);
});

test('the app is served with a strict policy, and nothing outside it', async () => {
  const page = await get('/');
  assert.equal(page.status, 200);
  assert.match(await page.text(), /<title>Greenfield<\/title>/);
  assert.match(page.headers.get('content-security-policy'), /default-src 'self'/);
  assert.equal(page.headers.get('x-content-type-options'), 'nosniff');
  for (const p of ['/server.mjs', '/test/fake-helper.mjs', '/../server.mjs', '/%2e%2e/server.mjs', '/src/../server.mjs', '/.env', '/%zz']) {
    const r = await get(p);
    assert.ok([400, 404].includes(r.status), `${p} -> ${r.status}`);
  }
  assert.equal((await get('/sw.js')).headers.get('content-type'), 'text/javascript; charset=utf-8');
  assert.equal((await get('/manifest.webmanifest')).headers.get('content-type'), 'application/manifest+json');
  assert.equal((await get('/x', { method: 'POST' })).status, 405);
});

test('the computer list and the version', async () => {
  assert.deepEqual(await (await get('/computers.json')).json(), { computers: [{ id: 'mac', name: 'Studio Mac' }] });
  assert.deepEqual(await (await get('/version.json')).json(), { version: '0.0.0-test' });
  const found = await discover((u, i) => fetch(base + u.replace('./', '/'), i));
  assert.deepEqual(found.computers, [{ id: 'mac', name: 'Studio Mac' }]);
  assert.equal(found.error, null);
});

test('discovery says why when there is nothing', async () => {
  const none = await discover(async () => ({ ok: true, json: async () => ({ computers: [] }) }));
  assert.match(none.error, /lists no computers/);
  const down = await discover(async () => { throw new Error('offline'); });
  assert.match(down.error, /could not load/);
  const bad = await discover(async () => ({ ok: true, json: async () => ({ computers: [{ id: '../x', name: 'bad' }, { id: 'ok', name: 'Fine' }] }) }));
  assert.deepEqual(bad.computers, [{ id: 'ok', name: 'Fine' }]);
});

test('only the routes the page needs are forwarded', async () => {
  assert.deepEqual([...FORWARDED].sort(), ['GET /status', 'POST /pair', 'POST /pair/revoke', 'POST /text']);
  for (const [method, route] of [['POST', '/pair/code'], ['GET', '/pair/devices'], ['GET', '/logs'], ['GET', '/peers'], ['GET', '/assist/windows'], ['GET', '/health'], ['GET', '/text']]) {
    const before = helper.seen.length;
    const r = await get(`/helper/mac${route}`, { method });
    assert.equal(r.status, 404, `${method} ${route}`);
    assert.equal(helper.seen.length, before, `${route} must not reach the helper`);
  }
  assert.equal((await get('/helper/nobody/status')).status, 404);
});

test('a forwarded request is marked as proxied, so a helper never takes it for the person at that computer', async () => {
  helper.seen.length = 0;
  await get('/helper/mac/status', { headers: { 'x-greenfield-token': 'whatever', 'x-dictation-key': 'k', cookie: 'c=1' } });
  const [req] = helper.seen;
  assert.ok(req.headers['x-forwarded-for']);
  assert.equal(req.headers['x-forwarded-proto'], 'http');
  assert.equal(req.headers['x-greenfield-token'], 'whatever');
  assert.equal(req.headers['x-dictation-key'], undefined, 'only the token is passed on');
  assert.equal(req.headers.cookie, undefined);
});

test('a helper that is down is a 502 with a name, never a hang', async () => {
  const dead = await start({ port: 0, helpers: [{ id: 'gone', name: 'Gone', url: 'http://127.0.0.1:1' }], root });
  try {
    const r = await fetch(`http://127.0.0.1:${dead.address().port}/helper/gone/status`);
    assert.equal(r.status, 502);
    assert.equal((await r.json()).error, 'helper_unreachable');
  } finally {
    dead.closeAllConnections();
    await new Promise((done) => dead.close(done));
  }
});

// concept: C3, V2, C5, C7: the whole path of the page's modules through the real server to a helper
test('pair, check, send, resend with the same id, and forget, through the server', async () => {
  const f = (u, i) => fetch(base + u.replace('./', '/'), i);
  const store = createStore(null);
  const paired = new PairedComputers(store);
  const outbox = new Outbox(store);

  // not paired: the helper refuses, the line says so
  assert.equal(interpretStatus(await call(f, helperBase('mac'), { path: '/status', init: {} })).level, 'unpaired');

  // a wrong code, then the right one
  helper.issueCode();
  const wrong = interpretPair(await call(f, helperBase('mac'), pairRequest('ZZZZ-ZZZZ', 'Test browser')));
  assert.equal(wrong.ok, false);
  helper.issueCode();
  const result = interpretPair(await call(f, helperBase('mac'), pairRequest('abcd efgh', 'Test browser')));
  assert.equal(result.ok, true);
  paired.save('mac', result);
  const p = paired.get('mac');
  assert.equal(p.token, 'tok-1');

  const lookup = (id) => (paired.get(id) ? { base: helperBase(id), token: paired.get(id).token } : null);
  assert.equal(interpretStatus(await call(f, helperBase('mac'), { path: '/status', init: { headers: { 'X-Greenfield-Token': p.token } } })).level, 'ready');

  // send: a line break stays a line feed, the id is the queued item's id
  const item = outbox.add('hello\nworld', 'mac', 'Studio Mac');
  helper.seen.length = 0;
  assert.equal((await outbox.deliver(item.id, lookup, f)).sent, true);
  const sent = helper.seen.find((r) => r.url === '/text');
  assert.deepEqual({ ...sent.body }, { id: item.id, text: 'hello\nworld', source: 'greenfield-pwa' });
  assert.equal(sent.headers['x-greenfield-token'], 'tok-1');

  // the helper ends the pairing: the next send says to pair again, and the text stays queued
  helper.tokens.clear();
  const queued = outbox.add('later', 'mac', 'Studio Mac');
  const refused = await outbox.deliver(queued.id, lookup, f);
  assert.equal(refused.kind, 'unpaired');
  assert.equal(outbox.pending().length, 1);
});

test('what the service worker keeps is exactly what the page loads', async () => {
  const sw = await readFile(path.join(root, 'sw.js'), 'utf8');
  const listed = [...sw.match(/const SHELL = \[([\s\S]*?)\];/)[1].matchAll(/'\.\/([^']*)'/g)].map((m) => m[1]).filter(Boolean);
  const html = await readFile(path.join(root, 'index.html'), 'utf8');
  const files = new Set(['index.html', 'app.css', 'manifest.webmanifest']);
  for (const dir of ['src', 'icons']) for (const name of await readdir(path.join(root, dir))) files.add(`${dir}/${name}`);
  assert.deepEqual([...new Set(listed)].sort(), [...files].sort());
  // every file the page names is served by the server and cached
  for (const ref of html.matchAll(/(?:href|src)="([^"#]+)"/g)) assert.ok(files.has(ref[1]), `${ref[1]} is not a shipped file`);
  const manifest = JSON.parse(await readFile(path.join(root, 'manifest.webmanifest'), 'utf8'));
  for (const icon of manifest.icons) assert.ok(files.has(icon.src), icon.src);
  assert.equal(manifest.display, 'standalone');
  assert.ok(manifest.icons.some((i) => i.sizes === '512x512' && i.purpose === 'maskable'));
});

test('every module the page imports is a file that is shipped', async () => {
  for (const name of await readdir(path.join(root, 'src'))) {
    const code = await readFile(path.join(root, 'src', name), 'utf8');
    for (const m of code.matchAll(/from '\.\/([a-z]+\.js)'/g)) assert.ok((await readdir(path.join(root, 'src'))).includes(m[1]), `${name} imports ${m[1]}`);
  }
});
