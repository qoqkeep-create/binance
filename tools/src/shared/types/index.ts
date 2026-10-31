// ============ API 响应类型 ============

export interface ApiResponse<T = unknown> {
  code: number
  message: string
  data: T
}

// ============ 分页 ============

export interface PaginationParams {
  page: number
  pageSize: number
}

export interface PaginatedResponse<T> {
  list: T[]
  total: number
  page: number
  pageSize: number
}

// ============ 通用类型 ============

export type OrderSide = 'long' | 'short'
export type OrderType = 'market' | 'limit'
export type OrderStatus = 'pending' | 'filled' | 'cancelled' | 'failed'

// ============ API 配置 ============

export interface APIConfig {
  id: string
  apiKey: string
  secretKey: string
  passphrase: string
  alias: string
  isActive: boolean
  createdAt: number
}

// ============ 策略 ============

export interface StrategyLevel {
  profitRR: number
  reducePosition: number
  stopLossType: 'none' | 'fixedRR' | 'absoluteRR'
  stopLossRR?: number
  stopLossAbsoluteRR?: number
}

export interface Strategy {
  id: string
  name: string
  levels: StrategyLevel[]
  createdAt?: number
}

// ============ 持仓 ============

export interface Holding {
  id: string
  symbol: string
  side: OrderSide
  size: number
  entryPrice: number
  markPrice: number
  unrealizedPnl: number
  unrealizedPnlPercent: number
  leverage: number
  liquidationPrice: number | null
  margin: number
  createdAt: number
}

// ============ 订单 ============

export interface Order {
  id: string
  symbol: string
  side: OrderSide
  type: OrderType
  status: OrderStatus
  price: number
  size: number
  filledSize: number
  createdAt: number
  updatedAt: number
}

// ============ 账户 ============

export interface Account {
  balance: number
  availableBalance: number
  totalPnl: number
  todayPnl: number
}
