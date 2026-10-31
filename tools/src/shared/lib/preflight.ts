export const PREFLIGHT_INTERVAL_MS = 3 * 60 * 60 * 1000

export function parsePreflightTimestamp(value?: string | null): number {
  if (!value) return 0
  const parsed = Date.parse(value)
  return Number.isFinite(parsed) ? parsed : 0
}

export function isPreflightDue(lastCompletedAt?: string | null, now = Date.now()): boolean {
  const last = parsePreflightTimestamp(lastCompletedAt)
  if (!last) return true
  return now - last >= PREFLIGHT_INTERVAL_MS
}

export function getPreflightRemainingMs(lastCompletedAt?: string | null, now = Date.now()): number {
  const last = parsePreflightTimestamp(lastCompletedAt)
  if (!last) return 0
  return Math.max(0, PREFLIGHT_INTERVAL_MS - (now - last))
}
