/* RigReady service worker: opens with no signal, always prefers the newest app files when online */
const CACHE = 'rigready-v1';
const APP = ['./', './index.html', './config.js', './jsqr.js', './icon.svg', './manifest.webmanifest'];
const LIBS = ['cdn.jsdelivr.net', 'fonts.googleapis.com', 'fonts.gstatic.com'];

const LIB_FILES = ['https://cdn.jsdelivr.net/npm/@supabase/supabase-js@2.45.4'];   // keep in step with index.html
self.addEventListener('install', e => {
  self.skipWaiting();
  e.waitUntil(caches.open(CACHE).then(async c => {
    await c.addAll(APP).catch(() => {});
    for (const u of LIB_FILES) { try { const r = await fetch(u, { mode: 'cors' }); if (r.ok) await c.put(u, r); } catch {} }
  }));
});
self.addEventListener('activate', e => e.waitUntil((async () => {
  for (const k of await caches.keys()) if (k !== CACHE) await caches.delete(k);
  await self.clients.claim();
})()));

const timeout = (p, ms) => Promise.race([p, new Promise((_, rej) => setTimeout(() => rej(new Error('timeout')), ms))]);

self.addEventListener('fetch', e => {
  const req = e.request; if (req.method !== 'GET') return;
  const url = new URL(req.url);
  if (url.origin === location.origin) {
    if (url.pathname.endsWith('/version.json')) return;                    // always live
    e.respondWith((async () => {                                            // app files: network first, saved copy if no signal
      const c = await caches.open(CACHE);
      try {
        const res = await timeout(fetch(req), 5000);
        if (res.ok) c.put(req, res.clone());
        return res;
      } catch {
        return (await c.match(req, { ignoreSearch: true })) || (req.mode === 'navigate' ? c.match('./index.html') : Response.error());
      }
    })());
  } else if (LIBS.includes(url.hostname)) {                                 // pinned libraries & fonts: saved copy first
    e.respondWith((async () => {
      const c = await caches.open(CACHE), hit = await c.match(req);
      if (hit) return hit;
      const res = await fetch(req);
      if (res.ok || res.type === 'opaque') c.put(req, res.clone());
      return res;
    })());
  }
  // Database requests (supabase.co) are never cached here.
});
