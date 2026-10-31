// This page is served outside the existing worker's navigation fallback.
// Keep all cookies, storage and caches; only retire this application's worker.
const retryButton = document.getElementById('retry')
const statusText = document.getElementById('status')

async function refreshFrontend() {
  retryButton.disabled = true
  try {
    if ('serviceWorker' in navigator) {
      const registrations = await navigator.serviceWorker.getRegistrations()
      const appScope = new URL('/', location.origin).href
      const appScript = new URL('/sw.js', location.origin).href
      await Promise.all(registrations.filter(registration =>
        registration.scope === appScope &&
        [registration.active, registration.waiting, registration.installing]
          .some(worker => worker?.scriptURL === appScript)
      ).map(registration => registration.unregister()))
    }
    location.replace('/profile')
  } catch {
    statusText.textContent = '自动更新未完成，请点击下方按钮重试。'
    retryButton.hidden = false
    retryButton.disabled = false
  }
}

retryButton.addEventListener('click', refreshFrontend)
void refreshFrontend()
