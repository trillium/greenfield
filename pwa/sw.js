// The service worker: keeps the app's own files so the app opens with no connection, and nothing else. It never touches /helper/ or
// /computers.json (those must be live), and it caches no answer from a helper, so no token or text ever lands in a cache.
// Bump VERSION when a file in SHELL changes; the test in pwa/test checks that SHELL lists exactly the files the page loads.
const VERSION = 'greenfield-pwa-1';
const SHELL = [
  './', './index.html', './app.css', './manifest.webmanifest',
  './src/app.js', './src/computers.js', './src/pairing.js', './src/send.js', './src/speech.js', './src/store.js', './src/text.js',
  './icons/icon-192.png', './icons/icon-512.png', './icons/icon-maskable-512.png', './icons/apple-touch-icon.png',
];

self.addEventListener('install', (event) => {
  event.waitUntil(caches.open(VERSION).then((cache) => cache.addAll(SHELL)).then(() => self.skipWaiting()));
});

self.addEventListener('activate', (event) => {
  event.waitUntil(
    caches.keys()
      .then((keys) => Promise.all(keys.filter((k) => k !== VERSION).map((k) => caches.delete(k))))
      .then(() => self.clients.claim()),
  );
});

self.addEventListener('fetch', (event) => {
  const { request } = event;
  const url = new URL(request.url);
  if (request.method !== 'GET' || url.origin !== self.location.origin) return;
  const scope = new URL(self.registration.scope).pathname;
  const route = url.pathname.slice(scope.length - 1);
  if (route.startsWith('/helper/') || route === '/computers.json' || route === '/version.json') return;
  // Cached copy first, refreshed in the background, so a changed file shows on the next open.
  event.respondWith(
    caches.open(VERSION).then(async (cache) => {
      const cached = await cache.match(request, { ignoreSearch: true });
      const fresh = fetch(request).then((response) => {
        if (response.ok && SHELL.some((f) => new URL(f, self.registration.scope).href === url.href)) cache.put(request, response.clone());
        return response;
      }).catch(() => cached);
      return cached ?? fresh;
    }),
  );
});
