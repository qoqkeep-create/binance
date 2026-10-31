import { tokenManager } from '@/shared/lib/api'
import { isStandaloneMode } from '@/shared/lib/device'

type LayoutMetrics = Record<string, string | number | boolean | null>

const ENDPOINT = '/api/account/client-layout-log'
// 这是纯诊断请求，不能与交易/行情请求争用移动端有限的并发连接。
const MIN_INTERVAL_MS = 10_000

let lastSentAt = 0
let sendInFlight = false

function readNumber(value: string): number {
  const parsed = Number.parseFloat(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function collectLayoutMetrics(navHeight = 0): LayoutMetrics {
  const viewport = window.visualViewport
  const rootStyle = getComputedStyle(document.documentElement)

  return {
    innerHeight: window.innerHeight || 0,
    innerWidth: window.innerWidth || 0,
    outerHeight: window.outerHeight || 0,
    screenHeight: window.screen?.height || 0,
    screenWidth: window.screen?.width || 0,
    clientHeight: document.documentElement.clientHeight || 0,
    visualViewportHeight: viewport?.height || 0,
    visualViewportWidth: viewport?.width || 0,
    visualViewportOffsetTop: viewport?.offsetTop || 0,
    visualViewportOffsetLeft: viewport?.offsetLeft || 0,
    appHeight: readNumber(rootStyle.getPropertyValue('--app-height')),
    appHeightRaw: readNumber(rootStyle.getPropertyValue('--app-height-raw')),
    appHeightCached: readNumber(rootStyle.getPropertyValue('--app-height-cached')),
    appHeightSource: rootStyle.getPropertyValue('--app-height-source').trim() || 'unknown',
    appSafeBottom: readNumber(rootStyle.getPropertyValue('--app-safe-bottom')),
    navHeight,
    standalone: isStandaloneMode(),
    visibilityState: document.visibilityState,
  }
}

export async function sendLayoutDiagnostics(reason: string, metrics: LayoutMetrics): Promise<void> {
  const token = tokenManager.get()
  if (!token) return

  const payload = {
    reason,
    path: window.location.pathname,
    standalone: isStandaloneMode(),
    user_agent: navigator.userAgent,
    metrics,
  }

  const now = Date.now()
  // iOS Safari 在地址栏收放、视口动画期间会连续触发 resize，指标指纹会持续变化。
  // 因此必须按时间全局限流，而不能只依赖指纹去重。
  if (sendInFlight || now - lastSentAt < MIN_INTERVAL_MS) {
    return
  }

  lastSentAt = now
  sendInFlight = true

  try {
    await fetch(ENDPOINT, {
      method: 'POST',
      headers: {
        'Content-Type': 'application/json',
        Authorization: `Bearer ${token}`,
      },
      body: JSON.stringify(payload),
      keepalive: true,
    })
  } catch {
    // 诊断日志不影响主流程
  } finally {
    sendInFlight = false
  }
}
