import { describe, expect, it, vi } from 'vitest'
import {
  EMPTY_TRADE_REQUEST_IDENTITY,
  resolveTradeRequestIdentity,
} from './tradeRequestIdentity'

describe('resolveTradeRequestIdentity', () => {
  it('reuses the request id while the order payload is unchanged', () => {
    const createId = vi.fn().mockReturnValue('request-1')
    const payload = { symbol: 'BTCUSDT', stop_loss_price: '59000' }

    const first = resolveTradeRequestIdentity(EMPTY_TRADE_REQUEST_IDENTITY, payload, createId)
    const second = resolveTradeRequestIdentity(first, payload, createId)

    expect(second.requestId).toBe('request-1')
    expect(createId).toHaveBeenCalledTimes(1)
  })

  it('creates a new request id after any order parameter changes', () => {
    const createId = vi.fn()
      .mockReturnValueOnce('request-1')
      .mockReturnValueOnce('request-2')
    const first = resolveTradeRequestIdentity(
      EMPTY_TRADE_REQUEST_IDENTITY,
      { symbol: 'BTCUSDT', stop_loss_price: '59000' },
      createId,
    )

    const second = resolveTradeRequestIdentity(
      first,
      { symbol: 'BTCUSDT', stop_loss_price: '59500' },
      createId,
    )

    expect(second.requestId).toBe('request-2')
    expect(createId).toHaveBeenCalledTimes(2)
  })
})
