import { beforeEach, describe, expect, it } from 'vitest'
import { tokenManager } from '@/shared/lib/api'
import { useAuthStore } from './authStore'
import { useTradingStore } from './tradingStore'

describe('tradingStore account isolation', () => {
  beforeEach(() => {
    useAuthStore.getState().logout()
    localStorage.clear()
    useTradingStore.getState().resetAccountState()
  })

  it('uses the same generated id for the first API config and active selection', () => {
    useTradingStore.getState().addApiConfig({
      alias: 'primary',
      apiKey: 'must-not-persist',
      secretKey: 'must-not-persist',
      passphrase: '',
    })

    const state = useTradingStore.getState()
    expect(state.apiConfigs).toHaveLength(1)
    expect(state.activeApiId).toBe(state.apiConfigs[0].id)
    expect(state.apiConfigs[0].apiKey).toBe('')
    expect(state.apiConfigs[0].secretKey).toBe('')
  })

  it('clears account state only when the authenticated user changes', () => {
    useTradingStore.getState().activateAccount('7')
    useTradingStore.getState().setStopLossAmount(80)
    useTradingStore.getState().setSelectedPair('BTCUSDT')

    useTradingStore.getState().activateAccount('7')
    expect(useTradingStore.getState().stopLossAmount).toBe(80)
    expect(useTradingStore.getState().selectedPair).toBe('BTCUSDT')

    useTradingStore.getState().activateAccount('8')
    expect(useTradingStore.getState().accountUserId).toBe('8')
    expect(useTradingStore.getState().stopLossAmount).toBe(120)
    expect(useTradingStore.getState().selectedPair).toBe('')
    expect(useTradingStore.getState().apiConfigs).toEqual([])
  })

  it('clears the current account state and caches on logout', () => {
    useAuthStore.getState().login({ id: '7', email: 'user@example.com' }, 'access-token')
    useTradingStore.getState().setStopLossAmount(80)
    localStorage.setItem('tradetools:holdings:positions:v3:7', '[{"id":1}]')
    localStorage.setItem('tradetools:holdings:positions:v3:8', '[{"id":2}]')

    useAuthStore.getState().logout()

    expect(tokenManager.get()).toBeNull()
    expect(useAuthStore.getState().user).toBeNull()
    expect(useTradingStore.getState().accountUserId).toBeNull()
    expect(useTradingStore.getState().stopLossAmount).toBe(120)
    expect(localStorage.getItem('tradetools:holdings:positions:v3:7')).toBeNull()
    expect(localStorage.getItem('tradetools:holdings:positions:v3:8')).not.toBeNull()
  })
})
