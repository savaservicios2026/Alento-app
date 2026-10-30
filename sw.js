// Guarda la app en el móvil para que abra rápido y funcione sin conexión.
const CACHE = 'alento-v19';
const SHELL = ['./', './index.html', './manifest.webmanifest', './icons/icon-192.png', './icons/icon-512.png'];
self.addEventListener('install', e => { e.waitUntil(caches.open(CACHE).then(c => c.addAll(SHELL))); self.skipWaiting(); });
self.addEventListener('activate', e => {
  e.waitUntil(caches.keys().then(ks => Promise.all(ks.filter(k => k !== CACHE).map(k => caches.delete(k)))));
  self.clients.claim();
});
self.addEventListener('fetch', e => {
  if (e.request.method !== 'GET') return;
  // Red primero para la app (así llegan las actualizaciones); caché si no hay conexión.
  // La página se pide sin la caché del navegador para que la versión nueva llegue al reabrir la app.
  const req = e.request.mode === 'navigate' ? fetch(e.request.url, { cache:'no-cache' }) : fetch(e.request);
  e.respondWith(req.then(r => {
    const copy = r.clone(); caches.open(CACHE).then(c => c.put(e.request, copy)); return r;
  }).catch(() => caches.match(e.request).then(m => m || caches.match('./index.html'))));
});
