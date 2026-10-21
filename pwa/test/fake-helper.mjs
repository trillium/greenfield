// A stand-in for a computer's helper, for tests: it keeps what it was asked and answers as the real helpers do about the parts the page
// uses. A request that carries X-Forwarded-For is not "the person at that computer": it gets in only with a token it issued.
import http from 'node:http';

export function startFakeHelper() {
  const seen = [];
  const tokens = new Set();
  let code = null;
  const server = http.createServer((req, res) => {
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const raw = Buffer.concat(chunks).toString();
      const body = raw ? JSON.parse(raw) : {};
      seen.push({ method: req.method, url: req.url, headers: req.headers, body });
      const reply = (status, object) => { res.writeHead(status, { 'Content-Type': 'application/json' }); res.end(JSON.stringify(object)); };
      const token = req.headers['x-greenfield-token'];
      if (req.method === 'POST' && req.url === '/pair') {
        if (code && body.code === code) {
          code = null;
          const issued = `tok-${tokens.size + 1}`;
          tokens.add(issued);
          return reply(200, { ok: true, token: issued, device: { id: `dev${tokens.size}`, name: body.device }, expires_in_s: 86400, name: 'Fake computer' });
        }
        return reply(401, { ok: false, error: 'pair_refused' });
      }
      if (token && !tokens.has(token)) return reply(401, { ok: false, error: 'invalid_token' });
      if (!token) return reply(503, { ok: false, error: 'identity_unavailable' });
      if (req.method === 'GET' && req.url === '/status') return reply(200, { ok: true, version: '0.4.0', accessibility: true, screen_locked: false, secure_input: false });
      if (req.method === 'POST' && req.url === '/text') return reply(200, { ok: true, id: body.id, chars: body.text.length, method: 'type', delivery: 'unconfirmed' });
      if (req.method === 'POST' && req.url === '/pair/revoke') { tokens.delete(token); return reply(200, { ok: true, revoked: 1 }); }
      return reply(404, { ok: false, error: 'not_found' });
    });
  });
  return new Promise((resolve) => server.listen(0, '127.0.0.1', () => resolve({
    server, seen, tokens, url: `http://127.0.0.1:${server.address().port}`,
    issueCode: () => (code = 'ABCD-EFGH'),
    close: () => new Promise((done) => { server.closeAllConnections(); server.close(done); }),
  })));
}
