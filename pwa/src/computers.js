// The computers this page can reach. A browser cannot scan a tailnet or call a plain-http helper from an https page, so the page's own
// server (pwa/server.mjs, or `tailscale serve` in front of it) lists the helpers it forwards to: GET /computers.json, and each one is
// reached under /helper/<id>/. Pairing is per computer.

/** Where one computer's helper is, from this page. */
export function helperBase(id) {
  return `./helper/${encodeURIComponent(id)}`;
}

/** Reads /computers.json. Returns { computers: [{ id, name }], error } and never throws. */
export async function discover(fetchImpl) {
  try {
    const response = await fetchImpl('./computers.json', { cache: 'no-store' });
    if (!response.ok) return { computers: [], error: `The page's server answered ${response.status} to the computer list.` };
    const body = await response.json();
    const computers = (Array.isArray(body.computers) ? body.computers : [])
      .filter((c) => typeof c?.id === 'string' && /^[a-z0-9_-]{1,32}$/.test(c.id))
      .map((c) => ({ id: c.id, name: String(c.name ?? c.id).slice(0, 60) }));
    return { computers, error: computers.length ? null : 'This page lists no computers. Start it with `make pwa-serve`, or set GREENFIELD_PWA_HELPERS.' };
  } catch {
    return { computers: [], error: 'The page could not load its list of computers. Are you online?' };
  }
}
