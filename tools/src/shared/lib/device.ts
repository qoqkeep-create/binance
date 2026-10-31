interface NavigatorWithStandalone extends Navigator {
  standalone?: boolean
}

export function isStandaloneMode(): boolean {
  if (typeof window === 'undefined') return false
  return (
    window.matchMedia('(display-mode: standalone)').matches ||
    (window.navigator as NavigatorWithStandalone).standalone === true
  )
}

function getBestViewportHeight(): number {
  if (typeof window === 'undefined') return 0
  return Math.max(
    window.visualViewport?.height || 0,
    window.innerHeight || 0,
    document.documentElement.clientHeight || 0,
    window.outerHeight || 0,
    window.screen?.height || 0,
  )
}

export function requestAppLayoutSync(reason = 'manual'): void {
  if (typeof window === 'undefined') return
  window.dispatchEvent(
    new CustomEvent('app:layout-sync', {
      detail: { reason, at: Date.now() },
    })
  )
}

export async function primeAppViewport(reason = 'viewport-prime'): Promise<void> {
  if (typeof window === 'undefined') return

  let bestHeight = getBestViewportHeight()
  const startedAt = Date.now()

  const waitFrame = () =>
    new Promise<void>((resolve) => requestAnimationFrame(() => resolve()))

  for (let i = 0; i < 8; i += 1) {
    await waitFrame()
    await new Promise((resolve) => window.setTimeout(resolve, 40))
    bestHeight = Math.max(bestHeight, getBestViewportHeight())
    document.documentElement.style.setProperty('--app-height', `${bestHeight}px`)
    document.documentElement.style.setProperty('--app-height-raw', `${bestHeight}px`)
    document.documentElement.style.setProperty('--app-height-source', reason)
    document.documentElement.style.setProperty('--app-height-cached', `${bestHeight}px`)
    requestAppLayoutSync(`${reason}-${i + 1}`)

    if (Date.now() - startedAt > 420) break
  }
}
