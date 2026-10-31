import { describe, expect, it } from 'vitest'
import {
  advanceAccountSessionRevision,
  clearAccountScopedCaches,
  getAccountSessionRevision,
  isCurrentAccountRequestScope,
  isCurrentAccountSession,
  isCurrentAccountScope,
  parseOptionalBalance,
  scopedAccountCacheKey,
  shouldThrottleAccountRequest,
} from './accountBalanceState'

describe('account balance state', () => {
  it('keeps unavailable exchange values distinct from a real zero balance', () => {
    expect(parseOptionalBalance('--')).toBeNull()
    expect(parseOptionalBalance('')).toBeNull()
    expect(parseOptionalBalance(undefined)).toBeNull()
    expect(parseOptionalBalance(false)).toBeNull()
    expect(parseOptionalBalance([])).toBeNull()
    expect(parseOptionalBalance('0')).toBe(0)
    expect(parseOptionalBalance('123.45')).toBe(123.45)
  })

  it('scopes cached account data to the authenticated user', () => {
    expect(scopedAccountCacheKey('account-cache', '7')).toBe('account-cache:7')
    expect(scopedAccountCacheKey('account-cache', '')).toBeNull()
  })

  it('rejects stale or anonymous account request scopes', () => {
    expect(isCurrentAccountScope('7', '7')).toBe(true)
    expect(isCurrentAccountScope('7', '8')).toBe(false)
    expect(isCurrentAccountScope('', '')).toBe(false)
  })

  it('rejects an older request after the account switches away and back', () => {
    const revision = getAccountSessionRevision()
    expect(isCurrentAccountRequestScope('7', '7', 12, 13, revision, revision)).toBe(false)
    expect(isCurrentAccountRequestScope('7', '7', 13, 13, revision, revision)).toBe(true)
    expect(isCurrentAccountRequestScope('7', '8', 13, 13, revision, revision)).toBe(false)
  })

  it('rejects an old response after the same account starts a new login session', () => {
    const oldRevision = getAccountSessionRevision()
    const currentRevision = advanceAccountSessionRevision()

    expect(isCurrentAccountRequestScope('7', '7', 13, 13, oldRevision, currentRevision)).toBe(false)
    expect(isCurrentAccountRequestScope('7', '7', 13, 13, currentRevision, currentRevision)).toBe(true)
    expect(isCurrentAccountSession('7', '7', oldRevision, currentRevision)).toBe(false)
    expect(isCurrentAccountSession('7', '7', currentRevision, currentRevision)).toBe(true)
  })

  it('allows a fresh request when switching back while another account is loading', () => {
    expect(shouldThrottleAccountRequest('7', '7', '7', 100)).toBe(true)
    expect(shouldThrottleAccountRequest('7', '', '7', 100)).toBe(true)
    expect(shouldThrottleAccountRequest('7', '8', '7', 100)).toBe(false)
    expect(shouldThrottleAccountRequest('7', '', '7', 3_000)).toBe(false)
  })

  it('clears only the selected user account caches', () => {
    localStorage.setItem('tradetools:profile:account:v2:7', '{}')
    localStorage.setItem('tradetools:holdings:positions:v3:7', '[]')
    localStorage.setItem('tradetools:profile:account:v2:8', '{}')
    localStorage.setItem('theme-storage', '{}')

    clearAccountScopedCaches('7')

    expect(localStorage.getItem('tradetools:profile:account:v2:7')).toBeNull()
    expect(localStorage.getItem('tradetools:holdings:positions:v3:7')).toBeNull()
    expect(localStorage.getItem('tradetools:profile:account:v2:8')).toBe('{}')
    expect(localStorage.getItem('theme-storage')).toBe('{}')
  })
})
