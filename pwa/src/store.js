// Small saved state (the paired computers, the queued texts, the active computer). Storage can be missing, full or refused (a private
// window, blocked site data), so every read and write is guarded and the page works, without remembering, when it is.

/** A store over any object with getItem / setItem / removeItem, or in memory when there is none. */
export function createStore(backend) {
  const memory = new Map();
  const safe = (fn, fallback) => {
    try {
      return fn();
    } catch {
      return fallback;
    }
  };
  return {
    get(key, fallback = null) {
      const raw = backend ? safe(() => backend.getItem(key), null) : memory.get(key) ?? null;
      if (raw == null) return fallback;
      return safe(() => JSON.parse(raw), fallback);
    },
    set(key, value) {
      const raw = JSON.stringify(value);
      if (!backend) return void memory.set(key, raw);
      safe(() => backend.setItem(key, raw));
    },
    remove(key) {
      if (!backend) return void memory.delete(key);
      safe(() => backend.removeItem(key));
    },
  };
}

/** The browser's localStorage when it works, else in memory. */
export function browserStore(win = globalThis) {
  let backend = null;
  try {
    backend = win.localStorage ?? null;
    backend?.setItem('greenfield.probe', '1');
    backend?.removeItem('greenfield.probe');
  } catch {
    backend = null;
  }
  return createStore(backend);
}
