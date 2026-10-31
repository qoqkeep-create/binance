/* global self, caches, fetch, URL */

// Upgrade independently of optional assets; an incomplete precache must never
// leave the previous HTML in control of future navigations.
self.addEventListener('install', event => {
  event.waitUntil(self.skipWaiting())
})
self.addEventListener('activate', event => {
  event.waitUntil(self.clients.claim())
})

async function cachedAssetOrNetwork(request) {
  try {
    const cached = await caches.match(request)
    if (cached) return cached
  } catch {
    // Storage availability must not prevent a normal network request.
  }
  return fetch(request)
}

self.addEventListener('fetch', event => {
  const { request } = event
  const url = new URL(request.url)
  if (request.method !== 'GET' || url.origin !== self.location.origin) return
  if (request.mode === 'navigate') {
    event.respondWith(fetch(request, { cache: 'no-store' }))
    return
  }
  if (!/^\/assets\/[^/]+-[\w-]+\.(js|css)$/.test(url.pathname)) return

  // Preserve old immutable chunks for pages already open during a rollout.
  // APIs and every write bypass this cache; new assets use HTTP caching.
  event.respondWith(cachedAssetOrNetwork(request))
})
