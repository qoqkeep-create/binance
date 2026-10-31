import { getTradingMode } from './tradingMode'

export function parseOptionalBalance(value: unknown): number | null {
  if (value === null || value === undefined) return null
  if (typeof value !== 'string' && typeof value !== 'number') return null
  if (typeof value === 'string' && (!value.trim() || value.trim() === '--')) return null
  const parsed = Number(value)
  return Number.isFinite(parsed) ? parsed : null
}

export function scopedAccountCacheKey(prefix: string, userId: string): string | null {
  const normalizedUserId = String(userId || '').trim()
  const modePrefix = getTradingMode() === 'lead' ? `${prefix}:lead` : prefix
  return normalizedUserId ? `${modePrefix}:${normalizedUserId}` : null
}

let accountSessionRevision = 0
export const ACCOUNT_BINDING_CHANGED_EVENT = 'tradetools:api-binding-changed'

export function getAccountSessionRevision(): number {
  return accountSessionRevision
}

export function advanceAccountSessionRevision(): number {
  accountSessionRevision += 1
  return accountSessionRevision
}

export function isCurrentAccountScope(requestUserId: string, currentUserId: string): boolean {
  const requested = String(requestUserId || '').trim()
  return Boolean(requested) && requested === String(currentUserId || '').trim()
}

export function isCurrentAccountSession(
  requestUserId: string,
  currentUserId: string,
  requestSessionRevision: number,
  currentSessionRevision: number,
): boolean {
  return requestSessionRevision === currentSessionRevision
    && isCurrentAccountScope(requestUserId, currentUserId)
}

export function isCurrentAccountRequestScope(
  requestUserId: string,
  currentUserId: string,
  requestId: number,
  currentRequestId: number,
  requestSessionRevision: number,
  currentSessionRevision: number,
): boolean {
  return isCurrentAccountSession(
    requestUserId,
    currentUserId,
    requestSessionRevision,
    currentSessionRevision,
  )
    && requestId === currentRequestId
}

export function shouldThrottleAccountRequest(
  requestUserId: string,
  inFlightUserId: string,
  lastStartedUserId: string,
  elapsedMs: number,
  throttleMs = 2_500,
): boolean {
  const requested = String(requestUserId || '').trim()
  if (!requested) return true
  if (requested === String(inFlightUserId || '').trim()) return true
  return !inFlightUserId
    && requested === String(lastStartedUserId || '').trim()
    && elapsedMs >= 0
    && elapsedMs < throttleMs
}

export function clearAccountScopedCaches(userId: string): void {
  const normalizedUserId = String(userId || '').trim()
  if (!normalizedUserId || typeof window === 'undefined') return

  const suffix = `:${normalizedUserId}`
  try {
    const keys = Array.from({ length: window.localStorage.length }, (_, index) =>
      window.localStorage.key(index),
    )
    for (const key of keys) {
      if (key?.startsWith('tradetools:') && key.endsWith(suffix)) {
        window.localStorage.removeItem(key)
      }
    }
  } catch {
    // Browser storage is an optional performance cache.
  }
}
