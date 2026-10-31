import { afterEach, describe, expect, it } from 'vitest'
import { getTradingMode, getTradingModeRevision, hasActiveTradingMutation, setTradingMode, trackTradingMutation, type TradingMode } from './tradingMode'
import { scopedAccountCacheKey } from './accountBalanceState'
import { useTradingStore } from '@/shared/store/tradingStore'

afterEach(() => {
  setTradingMode('ordinary')
  useTradingStore.getState().resetAccountState()
})

describe('trading mode isolation', () => {
  it('resets credentials, risk amount and drafts when the same user changes modes', () => {
    useTradingStore.getState().activateAccount('7')
    useTradingStore.getState().setStopLossAmount(100)
    useTradingStore.getState().updateTradeDraft({ stopLossPrice: '90000' })
    useTradingStore.getState().replaceApiConfigs([{ id: 'ordinary-api', alias: 'ordinary', apiKey: '', secretKey: '', passphrase: '', isActive: true, createdAt: 1 }])
    const ordinaryKey = scopedAccountCacheKey('balance', '7')
    setTradingMode('lead')
    useTradingStore.getState().activateAccount('7')
    expect(useTradingStore.getState().apiConfigs).toEqual([])
    expect(useTradingStore.getState().stopLossAmount).toBe(0)
    expect(useTradingStore.getState().tradeDraft.stopLossPrice).toBe('')
    expect(scopedAccountCacheKey('balance', '7')).not.toBe(ordinaryKey)
    setTradingMode('ordinary')
    useTradingStore.getState().activateAccount('7')
    expect(useTradingStore.getState().accountMode).toBe('ordinary')
    expect(useTradingStore.getState().apiConfigs).toEqual([])
  })

  it('blocks switching until a submitted operation completes, including failures', async () => {
    let finish!: () => void
    const pending = trackTradingMutation(() => new Promise<void>(resolve => { finish = resolve }))
    expect(() => setTradingMode('lead')).toThrow('当前操作尚未结束')
    expect(getTradingMode()).toBe('ordinary')
    finish()
    await pending
    expect(hasActiveTradingMutation()).toBe(false)
    await expect(trackTradingMutation(() => { throw new Error('failed') })).rejects.toThrow('failed')
    expect(hasActiveTradingMutation()).toBe(false)
    setTradingMode('lead')
    expect(getTradingMode()).toBe('lead')
  })

  it('rejects invalid runtime values and distinguishes a rapid round trip', () => {
    const revision = getTradingModeRevision()
    expect(() => setTradingMode('typo' as TradingMode)).toThrow('交易模式无效')
    setTradingMode('lead')
    setTradingMode('ordinary')
    expect(getTradingModeRevision()).toBe(revision + 2)
  })
})
