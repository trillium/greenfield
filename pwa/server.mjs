// The PWA's own small server: no dependencies, nothing to build, runs on the Mac with `make pwa-serve`.
//   - serves the files in this directory (the app, its service worker, manifest and icons);
//   - GET /computers.json lists the helpers it forwards to;
//   - /helper/<id>/<route> forwards a few routes of that computer's helper (status, text, pair, revoke), so the page and the helper
//     share one origin: no CORS, and no plain-http call from an https page (which a browser refuses).
// It listens on loopback only. To reach it from a phone use `tailscale serve` (docs/pwa.md); that keeps it on the tailnet.
// Every forwarded request is marked with X-Forwarded-For, and the helpers never treat a marked request as coming from the person at
// that computer: it gets in only with the token of a paired browser. The token is never read, logged or stored here.

import http from 'node:http';
import { readFile, stat } from 'node:fs/promises';
import { execFileSync } from 'node:child_process';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const here = path.dirname(fileURLToPath(import.meta.url));

export const DEFAULT_PWA_PORT = 47830;
export const DEFAULT_HELPER_PORT = 47821;
const MAX_BODY = 1024 * 1024;

/** The helper routes the page may use. Asking for a code, listing devices, logs, peers and the assist tools are never forwarded. */
export const FORWARDED = new Set(['GET /status', 'POST /text', 'POST /pair', 'POST /pair/revoke']);

const TYPES = {
  '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.mjs': 'text/javascript; charset=utf-8',
  '.css': 'text/css; charset=utf-8', '.json': 'application/json', '.webmanifest': 'application/manifest+json',
  '.png': 'image/png', '.svg': 'image/svg+xml', '.ico': 'image/x-icon',
};

/** The security headers for every answer. The page loads nothing from anywhere else. */
export const SECURITY_HEADERS = {
  'Content-Security-Policy': "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; manifest-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'",
  'X-Content-Type-Options': 'nosniff',
  'Referrer-Policy': 'no-referrer',
  'Permissions-Policy': 'microphone=(self), camera=(), geolocation=()',
};

/**
 * `GREENFIELD_PWA_HELPERS` is "Name=http://host:port, Name2=http://host2:port". Without it the one helper is this computer's own,
 * on GREENFIELD_PORT. Returns [{ id, name, url }]; a malformed entry is an error, never skipped silently.
 */
export function parseHelpers(spec, defaultPort = DEFAULT_HELPER_PORT) {
  if (!spec || !spec.trim()) return [{ id: 'local', name: 'This computer', url: `http://127.0.0.1:${defaultPort}` }];
  const seen = new Set();
  return spec.split(',').map((raw) => raw.trim()).filter(Boolean).map((entry, index) => {
    const eq = entry.indexOf('=');
    const name = eq > 0 ? entry.slice(0, eq).trim() : '';
    const url = eq > 0 ? entry.slice(eq + 1).trim() : '';
    let parsed;
    try {
      parsed = new URL(url);
    } catch {
      throw new Error(`GREENFIELD_PWA_HELPERS: "${entry}" is not Name=http://host:port`);
    }
    if (!name || !/^https?:$/.test(parsed.protocol) || parsed.pathname !== '/' || parsed.search) {
      throw new Error(`GREENFIELD_PWA_HELPERS: "${entry}" is not Name=http://host:port`);
    }
    let id = name.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-|-$/g, '').slice(0, 24) || `c${index}`;
    while (seen.has(id)) id = `${id}-${index}`;
    seen.add(id);
    return { id, name, url: parsed.origin };
  });
}

function send(res, status, body, headers = {}) {
  res.writeHead(status, { ...SECURITY_HEADERS, 'Cache-Control': 'no-store', ...headers });
  res.end(body);
}

function sendJson(res, status, object) {
  send(res, status, JSON.stringify(object), { 'Content-Type': 'application/json' });
}

async function serveFile(root, urlPath, res) {
  const clean = path.normalize(decodeURIComponent(urlPath)).replace(/^([/\\])+/, '');
  const relative = clean === '' ? 'index.html' : clean;
  const file = path.join(root, relative);
  // Only the app's own files: not a parent directory, not the server, not the tests, not hidden files.
  const top = relative.split(path.sep)[0];
  const allowed = relative === 'index.html' || ['src', 'icons'].includes(top) || ['app.css', 'sw.js', 'manifest.webmanifest'].includes(relative);
  if (!file.startsWith(root + path.sep) || !allowed) return sendJson(res, 404, { ok: false, error: 'not_found' });
  try {
    if (!(await stat(file)).isFile()) throw new Error('not a file');
    send(res, 200, await readFile(file), { 'Content-Type': TYPES[path.extname(file)] ?? 'application/octet-stream', 'Cache-Control': 'no-cache' });
  } catch {
    sendJson(res, 404, { ok: false, error: 'not_found' });
  }
}

function forward(helper, route, req, res, forwardedFor) {
  const chunks = [];
  let size = 0;
  req.on('data', (chunk) => {
    size += chunk.length;
    if (size > MAX_BODY) return req.destroy();
    chunks.push(chunk);
  });
  req.on('end', () => {
    const body = Buffer.concat(chunks);
    const headers = { 'x-forwarded-for': forwardedFor, 'x-forwarded-host': req.headers.host ?? '', 'x-forwarded-proto': 'http' };
    for (const name of ['content-type', 'x-greenfield-token']) if (req.headers[name]) headers[name] = req.headers[name];
    if (body.length) headers['content-length'] = body.length;
    const upstream = http.request(new URL(route, helper.url), { method: req.method, headers, timeout: 15_000 }, (answer) => {
      const out = { 'Content-Type': answer.headers['content-type'] ?? 'application/json' };
      if (answer.headers['retry-after']) out['Retry-After'] = answer.headers['retry-after'];
      res.writeHead(answer.statusCode ?? 502, { ...SECURITY_HEADERS, 'Cache-Control': 'no-store', ...out });
      answer.pipe(res);
    });
    const fail = () => {
      if (!res.headersSent) sendJson(res, 502, { ok: false, error: 'helper_unreachable', message: 'the helper did not answer' });
    };
    upstream.on('timeout', () => upstream.destroy());
    upstream.on('error', fail);
    upstream.end(body);
  });
}

/** The request handler, with the helpers and the files' directory as arguments so tests can aim it anywhere. */
export function createHandler({ helpers, root = here, version = 'dev' }) {
  const byId = new Map(helpers.map((h) => [h.id, h]));
  const handle = async (req, res) => {
    const url = new URL(req.url, 'http://localhost');
    if (url.pathname === '/computers.json' && req.method === 'GET') {
      return sendJson(res, 200, { computers: helpers.map(({ id, name }) => ({ id, name })) });
    }
    if (url.pathname === '/version.json' && req.method === 'GET') return sendJson(res, 200, { version });
    const match = /^\/helper\/([a-z0-9_-]+)(\/.*)$/.exec(url.pathname);
    if (match) {
      const helper = byId.get(match[1]);
      if (!helper) return sendJson(res, 404, { ok: false, error: 'no_such_computer' });
      if (!FORWARDED.has(`${req.method} ${match[2]}`)) return sendJson(res, 404, { ok: false, error: 'not_found', message: 'that route is not forwarded' });
      return forward(helper, match[2], req, res, req.socket.remoteAddress ?? 'unknown');
    }
    if (req.method !== 'GET' && req.method !== 'HEAD') return sendJson(res, 405, { ok: false, error: 'method_not_allowed' });
    return serveFile(root, url.pathname, res);
  };
  return async (req, res) => {
    try {
      await handle(req, res);
    } catch {
      // A malformed address (bad percent-encoding) is the caller's mistake, never a crash.
      if (!res.headersSent) sendJson(res, 400, { ok: false, error: 'bad_request' });
    }
  };
}

export function resolveVersion(env = process.env) {
  if (env.GREENFIELD_PWA_VERSION) return env.GREENFIELD_PWA_VERSION;
  try {
    return execFileSync(path.join(here, '..', 'scripts', 'version.sh'), ['--full'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'ignore'] }).trim() || 'dev';
  } catch {
    return 'dev';
  }
}

/** Starts listening on loopback. Resolves with the server once it is listening. */
export function start({ port, helpers, root = here, version = 'dev' }) {
  const server = http.createServer(createHandler({ helpers, root, version }));
  return new Promise((resolve, reject) => {
    server.once('error', reject);
    server.listen(port, '127.0.0.1', () => resolve(server));
  });
}

if (process.argv[1] && path.resolve(process.argv[1]) === fileURLToPath(import.meta.url)) {
  const flag = process.argv.indexOf('--port');
  const port = Number(flag > 0 ? process.argv[flag + 1] : process.env.GREENFIELD_PWA_PORT ?? DEFAULT_PWA_PORT);
  if (!Number.isInteger(port) || port < 1 || port > 65535) {
    console.error(`pwa: the port must be 1-65535 (GREENFIELD_PWA_PORT or --port), not "${process.env.GREENFIELD_PWA_PORT ?? process.argv[flag + 1]}"`);
    process.exit(2);
  }
  let helpers;
  try {
    helpers = parseHelpers(process.env.GREENFIELD_PWA_HELPERS, Number(process.env.GREENFIELD_PORT) || DEFAULT_HELPER_PORT);
  } catch (error) {
    console.error(`pwa: ${error.message}`);
    process.exit(2);
  }
  start({ port, helpers, version: resolveVersion() }).then(() => {
    console.log(`Greenfield web app on http://localhost:${port}/ (this computer only)`);
    for (const h of helpers) console.log(`  computer "${h.name}" -> ${h.url}`);
    console.log('For a phone: docs/pwa.md ("tailscale serve" recipe). Ctrl+C stops it.');
  }, (error) => {
    console.error(`pwa: cannot listen on port ${port}: ${error.message} (set GREENFIELD_PWA_PORT)`);
    process.exit(1);
  });
}
