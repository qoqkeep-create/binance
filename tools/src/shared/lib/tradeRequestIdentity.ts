import { generateId } from '@/shared/lib/utils'

export interface TradeRequestIdentity {
  requestId: string
  payloadSignature: string
}

export const EMPTY_TRADE_REQUEST_IDENTITY: TradeRequestIdentity = {
  requestId: '',
  payloadSignature: '',
}

export function resolveTradeRequestIdentity(
  previous: TradeRequestIdentity,
  payload: Record<string, unknown>,
  createId: () => string = generateId,
): TradeRequestIdentity {
  const payloadSignature = JSON.stringify(payload)
  if (previous.requestId && previous.payloadSignature === payloadSignature) {
    return previous
  }
  return { requestId: createId(), payloadSignature }
}
