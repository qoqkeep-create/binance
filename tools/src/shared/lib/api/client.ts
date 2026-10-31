import axios, {
  AxiosError,
  AxiosInstance,
  AxiosRequestConfig,
  InternalAxiosRequestConfig,
} from 'axios'
import { getTradingMode, getTradingModeRevision, trackTradingMutation, type TradingMode } from '../tradingMode'

// ============ 类型定义 ============

/** API 响应格式 */
interface ApiResponse<T = unknown> {
  code: number
  message: string
  data: T
}

interface ConnectionErrorDetail {
  message: string
  code: number
}

interface ApiRequestConfig extends AxiosRequestConfig {
  _tradingMode?: TradingMode
  _tradingModeRevision?: number
  suppressConnectionError?: boolean
  showConnectionError?: boolean
  disableRetry?: boolean
  /** 匿名认证请求不得携带内存中的旧 access token。 */
  skipAuth?: boolean
  /** 仅供调用方确认可安全重放的请求；交易和资金写操作不得开启。 */
  retryTransient?: boolean
  _retriedAfterRefresh?: boolean
  _authSessionRevision?: number
}

/** API 错误类 */
export class ApiError extends Error {
  code: number
  originalError?: AxiosError

  constructor(message: string, code: number, originalError?: AxiosError) {
    super(message)
    this.name = 'ApiError'
    this.code = code
    this.originalError = originalError
  }
}

function emitConnectionError(detail: ConnectionErrorDetail) {
  if (typeof window === 'undefined') return
  if (document.visibilityState === 'hidden') return
  const now = Date.now()
  const lastAt = Number(window.sessionStorage.getItem('tradetools:last-connection-error-at') || '0')
  if (now - lastAt < 6000) return
  window.sessionStorage.setItem('tradetools:last-connection-error-at', String(now))
  window.dispatchEvent(new CustomEvent<ConnectionErrorDetail>('app:connection-error', { detail }))
}

function emitConnectionOk() {
  if (typeof window === 'undefined') return
  window.dispatchEvent(new CustomEvent('app:connection-ok'))
}

function responseErrorMessage(data: unknown, status: number): string {
  if (data && typeof data === 'object' && 'message' in data) {
    const message = (data as { message?: unknown }).message
    if (typeof message === 'string' && message.trim()) return message
  }
  if (status >= 500) return '服务连接暂时不稳定，请稍后重试'
  return '请求失败'
}

const API_BIND_ERROR_HINTS = [
  '需先绑定 Binance Futures 实盘 API',
  '未绑定交易所API',
  '请先绑定API',
]

export function isApiBindRequiredError(error: unknown): boolean {
  const message =
    typeof error === 'string'
      ? error
      : error instanceof ApiError
        ? error.message
        : error instanceof Error
          ? error.message
          : ''

  return API_BIND_ERROR_HINTS.some((hint) => message.includes(hint))
}

export function isConnectionIssue(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false
  if (error.code === -1 || error.code === -2) return true
  const status = error.originalError?.response?.status ?? error.code
  if (status === 502 || status === 503 || status === 504) return true
  return false
}

// ============ Token 管理 ============

const LEGACY_TOKEN_KEY = 'auth_token'
const LEGACY_REFRESH_TOKEN_KEY = 'auth_refresh_token'

function takeLegacyToken(key: string): string | null {
  if (typeof window === 'undefined') return null
  try {
    const value = window.localStorage.getItem(key)
    window.localStorage.removeItem(key)
    return value
  } catch {
    return null
  }
}

let accessToken = takeLegacyToken(LEGACY_TOKEN_KEY)
let legacyRefreshToken = takeLegacyToken(LEGACY_REFRESH_TOKEN_KEY)
let authSessionRevision = 0

export const tokenManager = {
  get: (): string | null => accessToken,

  getRevision: (): number => authSessionRevision,

  set: (token: string): void => {
    authSessionRevision += 1
    accessToken = token
  },

  remove: (): void => {
    authSessionRevision += 1
    accessToken = null
  },

  replaceIfCurrent: (token: string, expectedRevision: number): boolean => {
    if (authSessionRevision !== expectedRevision) return false
    accessToken = token
    return true
  },

  removeIfCurrent: (expectedRevision: number): boolean => {
    if (authSessionRevision !== expectedRevision) return false
    authSessionRevision += 1
    accessToken = null
    return true
  },
}

let refreshState: { revision: number; promise: Promise<string> } | null = null
const runtimeBaseUrl =
  import.meta.env.VITE_API_BASE_URL ||
  '/api'

export async function endServerSession(): Promise<void> {
  const payload = legacyRefreshToken ? { refresh_token: legacyRefreshToken } : {}
  try {
    await axios.post(`${runtimeBaseUrl}/auth/logout`, payload, {
      timeout: 10000,
      withCredentials: true,
    })
  } finally {
    legacyRefreshToken = null
  }
}

// ============ API 客户端 ============

const createApiClient = (): AxiosInstance => {
  const instance = axios.create({
    baseURL: runtimeBaseUrl,
    timeout: 30000,
    withCredentials: true,
    headers: {
      'Content-Type': 'application/json',
    },
  })

  const refreshAccessToken = async (revision: number): Promise<string> => {
    if (tokenManager.getRevision() !== revision) throw new Error('stale auth session')
    if (refreshState?.revision === revision) return refreshState.promise
    const payload = legacyRefreshToken ? { refresh_token: legacyRefreshToken } : {}
    const promise = axios
      .post<ApiResponse<{ token: string }>>(`${runtimeBaseUrl}/auth/refresh`, payload, {
        timeout: 15000,
        withCredentials: true,
      })
      .then(response => {
        const token = response.data?.data?.token
        if (!token) throw new Error('refresh response missing token')
        if (!tokenManager.replaceIfCurrent(token, revision)) throw new Error('stale auth session')
        legacyRefreshToken = null
        return token
      })
      .finally(() => {
        if (refreshState?.promise === promise) refreshState = null
      })
    refreshState = { revision, promise }
    return promise
  }

  // 请求拦截器 - 添加认证 Token
  instance.interceptors.request.use(
    (config: InternalAxiosRequestConfig & ApiRequestConfig) => {
      config._authSessionRevision = tokenManager.getRevision()
      config._tradingMode ??= getTradingMode()
      config._tradingModeRevision ??= getTradingModeRevision()
      if (config._tradingModeRevision !== getTradingModeRevision()) {
        throw new ApiError('交易模式已切换，已取消上一模式的请求', -3)
      }
      config.headers['X-Trading-Mode'] = config._tradingMode
      const token = tokenManager.get()
      if (token && config.headers && !config.skipAuth) {
        config.headers.Authorization = `Bearer ${token}`
      }
      return config
    },
    error => Promise.reject(error)
  )

  // 响应拦截器 - 统一错误处理
  instance.interceptors.response.use(
    response => {
      if ((response.config as ApiRequestConfig)._tradingModeRevision !== getTradingModeRevision()) {
        throw new ApiError('交易模式已切换，已忽略上一模式的响应', -3)
      }
      emitConnectionOk()
      const data = response.data as ApiResponse

      // 如果返回的是标准格式
      if (data !== null && typeof data === 'object' && 'code' in data) {
        if (data.code !== 0 && data.code !== 200) {
          throw new ApiError(data.message || '请求失败', data.code)
        }
        return data.data as typeof response
      }

      // 非标准格式直接返回
      return response.data
    },
    async (error: AxiosError<ApiResponse>) => {
      if (error instanceof ApiError) throw error
      const modeRevision = (error.config as ApiRequestConfig | undefined)?._tradingModeRevision
      if (modeRevision !== undefined && modeRevision !== getTradingModeRevision()) {
        throw new ApiError('交易模式已切换，已忽略上一模式的响应', -3)
      }
      if (error.response) {
        const { status, data } = error.response
        const requestConfig = error.config as (InternalAxiosRequestConfig & ApiRequestConfig) | undefined

        // 401 - 未授权
        if (status === 401 && !requestConfig?.skipAuth) {
          const isRefreshRequest = String(requestConfig?.url || '').includes('/auth/refresh')
          const requestRevision = requestConfig?._authSessionRevision
          const isCurrentSession = requestRevision !== undefined
            && tokenManager.getRevision() === requestRevision
          if (requestConfig && isCurrentSession && !requestConfig._retriedAfterRefresh && !isRefreshRequest) {
            try {
              const token = await refreshAccessToken(requestRevision)
              requestConfig._retriedAfterRefresh = true
              requestConfig.headers.Authorization = `Bearer ${token}`
              return instance.request(requestConfig)
            } catch {
              // Fall through to a full logout when refresh is invalid or unavailable.
            }
          }
          if (requestRevision !== undefined && tokenManager.removeIfCurrent(requestRevision)) {
            legacyRefreshToken = null
            window.dispatchEvent(new CustomEvent('auth:unauthorized'))
          }
        }

        const responseCode = data && typeof data === 'object' && 'code' in data
          ? Number((data as { code?: unknown }).code) || status
          : status
        const apiError = new ApiError(responseErrorMessage(data, status), responseCode, error)
        if (isConnectionIssue(apiError) && requestConfig?.showConnectionError && !requestConfig?.suppressConnectionError) {
          emitConnectionError({
            message: '无法连接服务器，请检查网络后重试',
            code: apiError.code,
          })
        }
        throw apiError
      }

      if (error.code === 'ECONNABORTED') {
        const apiError = new ApiError('请求超时，请稍后重试', -1, error)
        const requestConfig = error.config as (InternalAxiosRequestConfig & { suppressConnectionError?: boolean; showConnectionError?: boolean }) | undefined
        if (requestConfig?.showConnectionError && !requestConfig?.suppressConnectionError) emitConnectionError({
          message: '请求超时，请检查网络后重试',
          code: apiError.code,
        })
        throw apiError
      }

      const requestConfig = error.config as ApiRequestConfig | undefined
      const apiError = new ApiError('网络连接失败，请检查网络', -2, error)
      if (requestConfig?.showConnectionError && !requestConfig?.suppressConnectionError) emitConnectionError({
        message: '无法连接服务器，请检查网络后重试',
        code: apiError.code,
      })
      throw apiError
    }
  )

  return instance
}

const apiClient = createApiClient()

const sleep = (ms: number) => new Promise(resolve => window.setTimeout(resolve, ms))

function shouldRetryTransient(error: unknown): boolean {
  if (!(error instanceof ApiError)) return false
  if (error.code === -1 || error.code === -2) return true
  const status = error.originalError?.response?.status ?? error.code
  if (status >= 500 && status < 600) return true
  return false
}

async function withTransientRetry<T>(request: () => Promise<T>, maxAttempts: number): Promise<T> {
  let attempt = 0
  for (;;) {
    try {
      return await request()
    } catch (error) {
      attempt += 1
      if (attempt >= maxAttempts || !shouldRetryTransient(error)) throw error
      const delay = Math.min(300 * 2 ** (attempt - 1), 1200)
      await sleep(delay)
    }
  }
}

function getWithRetry<T>(url: string, config?: ApiRequestConfig): Promise<T> {
  const scopedConfig = captureMode(config)
  return withTransientRetry(
    () => apiClient.get<T, T>(url, scopedConfig) as Promise<T>,
    config?.disableRetry ? 1 : 3,
  )
}

function postWithRetry<T>(url: string, data?: unknown, config?: ApiRequestConfig): Promise<T> {
  const scopedConfig = captureMode(config)
  return trackTradingMutation(() => withTransientRetry(
    () => apiClient.post<T, T>(url, data, scopedConfig) as Promise<T>,
    config?.retryTransient ? 3 : 1,
  ))
}

function captureMode(config?: ApiRequestConfig): ApiRequestConfig {
  return { ...config, _tradingMode: getTradingMode(), _tradingModeRevision: getTradingModeRevision() }
}

// ============ 导出的请求方法 ============

export const api = {
  get: <T>(url: string, config?: ApiRequestConfig) => getWithRetry<T>(url, config),

  post: <T>(url: string, data?: unknown, config?: ApiRequestConfig) =>
    postWithRetry<T>(url, data, config),

  put: <T>(url: string, data?: unknown, config?: ApiRequestConfig) =>
    trackTradingMutation(() => apiClient.put<T, T>(url, data, captureMode(config))),

  patch: <T>(url: string, data?: unknown, config?: ApiRequestConfig) =>
    trackTradingMutation(() => apiClient.patch<T, T>(url, data, captureMode(config))),

  delete: <T>(url: string, config?: ApiRequestConfig) =>
    trackTradingMutation(() => apiClient.delete<T, T>(url, captureMode(config))),
}

export default apiClient
