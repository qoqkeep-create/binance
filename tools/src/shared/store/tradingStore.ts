import { create } from 'zustand'
import { persist, devtools } from 'zustand/middleware'
import { generateId } from '@/shared/lib/utils'
import type { APIConfig, Strategy, StrategyLevel } from '@/shared/types'
import { getTradingMode, type TradingMode } from '@/shared/lib/tradingMode'

export type { APIConfig, Strategy, StrategyLevel }

interface TradingState {
  accountUserId: string | null
  accountMode: TradingMode

  // API 配置
  apiConfigs: APIConfig[]
  activeApiId: string | null

  // 策略
  strategies: Strategy[]
  activeStrategyId: string | null

  // 交易设置
  stopLossAmount: number
  defaultLeverage: number
  selectedPair: string
  tradeDraft: {
    orderType: 'market' | 'limit'
    takeProfitMode: 'manual' | 'strategy'
    stopLossPrice: string
    limitPrice: string
    includeFeesInStopLoss: boolean
  }

  // Computed getters
  getActiveApi: () => APIConfig | undefined
  getActiveStrategy: () => Strategy | undefined

  // API 配置 Actions
  addApiConfig: (config: Omit<APIConfig, 'id' | 'isActive' | 'createdAt'>) => void
  replaceApiConfigs: (configs: APIConfig[]) => void
  clearApiConfigs: () => void
  removeApiConfig: (id: string) => void
  setActiveApi: (id: string) => void

  // 策略 Actions
  addStrategy: (strategy: Omit<Strategy, 'id' | 'createdAt'>) => void
  removeStrategy: (id: string) => void
  updateStrategy: (id: string, updates: Partial<Omit<Strategy, 'id' | 'createdAt'>>) => void
  replaceStrategies: (strategies: Strategy[]) => void
  setActiveStrategy: (id: string | null) => void

  // 设置 Actions
  setStopLossAmount: (amount: number) => void
  setDefaultLeverage: (leverage: number) => void
  setSelectedPair: (pair: string) => void
  updateTradeDraft: (draft: Partial<TradingState['tradeDraft']>) => void
  resetTradeDraft: () => void
  activateAccount: (userId: string) => void
  resetAccountState: () => void
}

const defaultTradeDraft: TradingState['tradeDraft'] = {
  orderType: 'market',
  takeProfitMode: 'strategy',
  stopLossPrice: '',
  limitPrice: '',
  includeFeesInStopLoss: false,
}

// API credentials are used only during the bind request and are never part of
// client state or persisted browser storage.
const sanitizeApiConfigs = (configs: unknown): APIConfig[] =>
  Array.isArray(configs)
    ? configs
        .filter(config => Boolean(config) && typeof config === 'object')
        .map(config => ({
          ...(config as APIConfig),
          apiKey: '',
          secretKey: '',
          passphrase: '',
        }))
    : []

// ============ 预设策略 ============

export const PRESET_STRATEGIES: Record<string, Omit<Strategy, 'id' | 'createdAt'>> = {
  stable: {
    name: '稳健通用',
    levels: [
      { profitRR: 1.5, reducePosition: 40, stopLossType: 'fixedRR', stopLossRR: 1.5 },
      { profitRR: 2.0, reducePosition: 30, stopLossType: 'fixedRR', stopLossRR: 1 },
      { profitRR: 3.0, reducePosition: 30, stopLossType: 'none' },
    ],
  },
  aggressive: {
    name: '趋势友好，反回撤',
    levels: [
      { profitRR: 2.0, reducePosition: 25, stopLossType: 'fixedRR', stopLossRR: 1 },
      { profitRR: 3.5, reducePosition: 25, stopLossType: 'fixedRR', stopLossRR: 2 },
      { profitRR: 5.0, reducePosition: 50, stopLossType: 'none' },
    ],
  },
  fast: {
    name: '快动剁，适合高波动',
    levels: [
      { profitRR: 1.0, reducePosition: 50, stopLossType: 'fixedRR', stopLossRR: 0.5 },
      { profitRR: 1.5, reducePosition: 30, stopLossType: 'fixedRR', stopLossRR: 1 },
      { profitRR: 2.5, reducePosition: 20, stopLossType: 'none' },
    ],
  },
}

// ============ Store ============

export const useTradingStore = create<TradingState>()(
  devtools(
    persist(
      (set, get) => ({
        accountUserId: null,
        accountMode: getTradingMode(),
        apiConfigs: [],
        activeApiId: null,
        strategies: [],
        activeStrategyId: null,
        stopLossAmount: getTradingMode() === 'lead' ? 0 : 120,
        defaultLeverage: 100,
        selectedPair: '',
        tradeDraft: defaultTradeDraft,

        // Computed
        getActiveApi: () => {
          const { apiConfigs, activeApiId } = get()
          return apiConfigs.find(api => api.id === activeApiId)
        },

        getActiveStrategy: () => {
          const { strategies, activeStrategyId } = get()
          return strategies.find(s => s.id === activeStrategyId)
        },

        // API Actions
        addApiConfig: config =>
          set(state => {
            const id = generateId()
            const isActive = state.apiConfigs.length === 0
            return {
              apiConfigs: [
                ...state.apiConfigs,
                {
                  ...config,
                  apiKey: '',
                  secretKey: '',
                  passphrase: '',
                  id,
                  isActive,
                  createdAt: Date.now(),
                },
              ],
              activeApiId: isActive ? id : state.activeApiId,
            }
          }),

        replaceApiConfigs: configs => {
          const safeConfigs = sanitizeApiConfigs(configs)
          set({
            apiConfigs: safeConfigs,
            activeApiId: safeConfigs.find(c => c.isActive)?.id || safeConfigs[0]?.id || null,
          })
        },

        clearApiConfigs: () =>
          set({
            apiConfigs: [],
            activeApiId: null,
          }),

        removeApiConfig: id =>
          set(state => {
            const newConfigs = state.apiConfigs.filter(api => api.id !== id)
            return {
              apiConfigs: newConfigs,
              activeApiId: state.activeApiId === id ? (newConfigs[0]?.id || null) : state.activeApiId,
            }
          }),

        setActiveApi: id =>
          set(state => ({
            apiConfigs: state.apiConfigs.map(api => ({
              ...api,
              isActive: api.id === id,
            })),
            activeApiId: id,
          })),

        // Strategy Actions
        addStrategy: strategy =>
          set(state => ({
            strategies: [
              ...state.strategies,
              { ...strategy, id: generateId(), createdAt: Date.now() },
            ],
          })),

        removeStrategy: id =>
          set(state => ({
            strategies: state.strategies.filter(s => s.id !== id),
            activeStrategyId: state.activeStrategyId === id ? null : state.activeStrategyId,
          })),

        updateStrategy: (id, updates) =>
          set(state => ({
            strategies: state.strategies.map(s => (s.id === id ? { ...s, ...updates } : s)),
          })),

        replaceStrategies: (strategies) =>
          set(state => ({
            strategies,
            // 服务器列表为准：本地记住的当前策略若已不在列表中（如被删除重建），
            // 清空选中而不是保留失效编号，否则开仓会带着旧编号报"策略不存在"。
            activeStrategyId: strategies.find((s) => s.id === state.activeStrategyId)?.id ?? null,
          })),

        setActiveStrategy: id => set({ activeStrategyId: id }),

        // Settings Actions
        setStopLossAmount: amount => set({ stopLossAmount: Math.max(0, amount) }),

        setDefaultLeverage: leverage =>
          set({ defaultLeverage: Math.min(Math.max(1, leverage), 125) }),

        setSelectedPair: pair => set({ selectedPair: pair }),

        updateTradeDraft: draft =>
          set(state => ({
            tradeDraft: {
              ...state.tradeDraft,
              ...draft,
            },
          })),

        resetTradeDraft: () => set({ tradeDraft: defaultTradeDraft }),

        activateAccount: userId =>
          set(state => {
            const normalizedUserId = String(userId || '').trim()
            if (normalizedUserId && state.accountUserId === normalizedUserId && state.accountMode === getTradingMode()) return state
            return {
              accountUserId: normalizedUserId || null,
              accountMode: getTradingMode(),
              apiConfigs: [],
              activeApiId: null,
              strategies: [],
              activeStrategyId: null,
              stopLossAmount: getTradingMode() === 'lead' ? 0 : 120,
              defaultLeverage: 100,
              selectedPair: '',
              tradeDraft: defaultTradeDraft,
            }
          }),

        resetAccountState: () =>
          set({
            accountUserId: null,
            accountMode: getTradingMode(),
            apiConfigs: [],
            activeApiId: null,
            strategies: [],
            activeStrategyId: null,
            stopLossAmount: getTradingMode() === 'lead' ? 0 : 120,
            defaultLeverage: 100,
            selectedPair: '',
            tradeDraft: defaultTradeDraft,
          }),
      }),
      {
        name: 'trading-storage',
        partialize: state => ({
          ...state,
          apiConfigs: sanitizeApiConfigs(state.apiConfigs),
        }),
        merge: (persisted, current) => {
          const state = persisted as Partial<TradingState> | undefined
          return {
            ...current,
            ...state,
            apiConfigs: sanitizeApiConfigs(state?.apiConfigs || []),
          }
        },
      }
    ),
    { name: 'TradingStore', enabled: import.meta.env.VITE_ENABLE_DEVTOOLS === 'true' }
  )
)
