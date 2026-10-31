import React from 'react';
import ReactDOM from 'react-dom/client';
import { registerSW } from 'virtual:pwa-register';
import App from './app/App';
import './styles/index.css';

declare global {
  interface Window {
    __appBootSyncStarted?: boolean
    __lastHiddenAt?: number
    __lastResumeEmittedAt?: number
  }
}

const APP_LAYOUT_CACHE_KEY = 'tradetools:app-layout-cache:v1'
const FALLBACK_HEIGHT_MIN_GAP = 60
const FALLBACK_HEIGHT_MAX_GAP = 220
const CACHE_DEGRADE_TOLERANCE = 24
const SERVICE_WORKER_UPDATE_INTERVAL_MS = 5 * 60 * 1000

interface CachedLayoutSnapshot {
  height: number
  width: number
  updatedAt: number
}

function getViewportHeight() {
  const viewport = window.visualViewport?.height || 0
  const inner = window.innerHeight || 0
  const client = document.documentElement.clientHeight || 0
  return Math.max(viewport, inner, client)
}

function getBootstrapViewportCandidate(rawHeight: number): number {
  const outerHeight = window.outerHeight || 0
  const screenHeight = window.screen?.height || 0
  const clientHeight = document.documentElement.clientHeight || 0
  const visualHeight = window.visualViewport?.height || 0
  const candidate = Math.max(outerHeight, screenHeight)
  const gap = candidate - rawHeight
  const collapsedViewport =
    rawHeight > 0 &&
    rawHeight === clientHeight &&
    rawHeight === visualHeight

  if (!collapsedViewport) return 0
  if (gap < FALLBACK_HEIGHT_MIN_GAP || gap > FALLBACK_HEIGHT_MAX_GAP) return 0
  return candidate
}

function readCachedLayout(): CachedLayoutSnapshot | null {
  try {
    const raw = window.localStorage.getItem(APP_LAYOUT_CACHE_KEY)
    if (!raw) return null
    const parsed = JSON.parse(raw) as CachedLayoutSnapshot
    if (!parsed || parsed.height <= 0 || parsed.width <= 0) return null
    return parsed
  } catch {
    return null
  }
}

function writeCachedLayout(height: number, width: number) {
  if (height <= 0 || width <= 0) return
  try {
    const current = readCachedLayout()
    if (current && current.height === height && current.width === width) return

    // Keep the last known good full-height viewport stable. Route transitions,
    // keyboard animations, and iOS WebView toolbar changes can briefly report a
    // smaller height; those transient values should not overwrite the cache.
    if (current && Math.abs(current.width - width) <= 2) {
      if (height + CACHE_DEGRADE_TOLERANCE < current.height) {
        return
      }

      if (height < current.height) {
        height = current.height
      }
    }

    window.localStorage.setItem(
      APP_LAYOUT_CACHE_KEY,
      JSON.stringify({
        height,
        width,
        updatedAt: Date.now(),
      } satisfies CachedLayoutSnapshot)
    )
  } catch {
    // ignore storage failures
  }
}

function resolveAppHeight(rawHeight: number) {
  const width = window.innerWidth || document.documentElement.clientWidth || 0
  const cached = readCachedLayout()
  const gap = cached ? cached.height - rawHeight : 0
  const canUseCachedHeight =
    Boolean(cached) &&
    Math.abs((cached?.width || 0) - width) <= 2 &&
    gap >= FALLBACK_HEIGHT_MIN_GAP &&
    gap <= FALLBACK_HEIGHT_MAX_GAP

  if (canUseCachedHeight && cached) {
    return {
      height: cached.height,
      source: 'cached-good-height',
      cachedHeight: cached.height,
    }
  }

  const bootstrapCandidate = getBootstrapViewportCandidate(rawHeight)
  if (bootstrapCandidate > 0) {
    return {
      height: bootstrapCandidate,
      source: 'bootstrap-viewport',
      cachedHeight: cached?.height || 0,
    }
  }

  return {
    height: rawHeight,
    source: 'live-viewport',
    cachedHeight: cached?.height || 0,
  }
}

function syncAppHeight() {
  const rawHeight = getViewportHeight()
  const resolved = resolveAppHeight(rawHeight)

  if (resolved.height > 0) {
    document.documentElement.style.setProperty('--app-height', `${resolved.height}px`)
    document.documentElement.style.setProperty('--app-height-raw', `${rawHeight}px`)
    document.documentElement.style.setProperty('--app-height-source', resolved.source)
    document.documentElement.style.setProperty('--app-height-cached', `${resolved.cachedHeight}px`)
  }

  if (rawHeight > 0 && resolved.source === 'live-viewport') {
    writeCachedLayout(rawHeight, window.innerWidth || document.documentElement.clientWidth || 0)
  }

  const viewport = window.visualViewport
  const visualOffsetTop = viewport?.offsetTop || 0
  const rawInsetBottom = Math.max(0, window.innerHeight - rawHeight - visualOffsetTop)
  document.documentElement.style.setProperty('--app-safe-bottom', `${rawInsetBottom}px`)
}

function scheduleLayoutSync() {
  syncAppHeight()
  requestAnimationFrame(syncAppHeight)
  window.setTimeout(syncAppHeight, 80)
  window.setTimeout(syncAppHeight, 240)
  window.setTimeout(syncAppHeight, 480)
}

function emitAppResume(reason: 'pageshow' | 'visible' | 'online') {
  const now = Date.now()
  const lastHiddenAt = window.__lastHiddenAt || now
  const dormantMs = Math.max(0, now - lastHiddenAt)
  const lastResumeEmittedAt = window.__lastResumeEmittedAt || 0

  if (now - lastResumeEmittedAt < 1500) {
    return
  }
  window.__lastResumeEmittedAt = now

  window.dispatchEvent(
    new CustomEvent('app:resume', {
      detail: { reason, dormantMs },
    })
  )
}

function registerAppServiceWorker() {
  if (!('serviceWorker' in navigator)) return

  let registration: ServiceWorkerRegistration | undefined
  const checkForUpdate = () => {
    if (!registration || !navigator.onLine || document.visibilityState === 'hidden') return
    void registration.update().catch(() => undefined)
  }

  registerSW({
    immediate: true,
    // The worker no longer caches HTML. Normal navigation gets the new build;
    // do not interrupt an open trade form or an in-flight operation to reload.
    onNeedReload: () => undefined,
    onRegisteredSW: (_scriptUrl, nextRegistration) => {
      registration = nextRegistration
      checkForUpdate()
    },
  })

  window.addEventListener('app:resume', checkForUpdate as EventListener)
  window.setInterval(checkForUpdate, SERVICE_WORKER_UPDATE_INTERVAL_MS)
}

if (typeof window !== 'undefined' && !window.__appBootSyncStarted) {
  window.__appBootSyncStarted = true
  window.__lastHiddenAt = Date.now()
  scheduleLayoutSync()

  const onVisibilityChange = () => {
    if (document.visibilityState === 'hidden') {
      window.__lastHiddenAt = Date.now()
      return
    }
    scheduleLayoutSync()
    emitAppResume('visible')
  }

  const onPageShow = () => {
    scheduleLayoutSync()
    emitAppResume('pageshow')
  }

  const onOnline = () => {
    scheduleLayoutSync()
    emitAppResume('online')
  }

  const onLayoutSync = () => {
    scheduleLayoutSync()
  }

  window.addEventListener('resize', syncAppHeight, { passive: true })
  window.addEventListener('orientationchange', syncAppHeight, { passive: true })
  window.visualViewport?.addEventListener('resize', syncAppHeight, { passive: true })
  document.addEventListener('visibilitychange', onVisibilityChange, { passive: true })
  window.addEventListener('pageshow', onPageShow, { passive: true })
  window.addEventListener('online', onOnline, { passive: true })
  window.addEventListener('app:layout-sync', onLayoutSync as EventListener)
}

registerAppServiceWorker()

ReactDOM.createRoot(document.getElementById('root')!).render(
  <React.StrictMode>
    <App />
  </React.StrictMode>,
);

// React 首帧绘制后移除内联闪屏（双 rAF 确保首帧已上屏）
requestAnimationFrame(() => {
  requestAnimationFrame(() => {
    document.getElementById('app-splash')?.remove();
  });
});
