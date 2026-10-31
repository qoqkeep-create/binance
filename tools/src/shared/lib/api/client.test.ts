import axios from 'axios'
import AxiosMockAdapter from 'axios-mock-adapter'
import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest'

import apiClient, { api, tokenManager } from './client'
import { setTradingMode, hasActiveTradingMutation } from '../tradingMode'

describe('API access-token refresh', () => {
  let apiMock: AxiosMockAdapter
  let authMock: AxiosMockAdapter

  beforeEach(() => {
    apiMock = new AxiosMockAdapter(apiClient)
    authMock = new AxiosMockAdapter(axios)
    tokenManager.set('expired-access-token')
  })

  afterEach(() => {
    apiMock.restore()
    authMock.restore()
    tokenManager.remove()
  })

  it('shares one refresh request across concurrent 401 responses', async () => {
    authMock.onPost(/\/api\/auth\/refresh$/).reply(200, {
      code: 0,
      message: 'ok',
      data: { token: 'fresh-access-token' },
    })
    apiMock.onGet('/protected').reply(config => {
      if (config.headers?.Authorization === 'Bearer fresh-access-token') {
        return [200, { code: 0, message: 'ok', data: { value: 1 } }]
      }
      return [401, { code: 401, message: 'expired', data: null }]
    })

    const [first, second] = await Promise.all([
      api.get<{ value: number }>('/protected'),
      api.get<{ value: number }>('/protected'),
    ])

    expect(first).toEqual({ value: 1 })
    expect(second).toEqual({ value: 1 })
    expect(authMock.history.post).toHaveLength(1)
    expect(tokenManager.get()).toBe('fresh-access-token')
  })

  it('clears the session and emits unauthorized when refresh fails', async () => {
    const onUnauthorized = vi.fn()
    window.addEventListener('auth:unauthorized', onUnauthorized)
    authMock.onPost(/\/api\/auth\/refresh$/).reply(401, {
      code: 401,
      message: 'invalid refresh token',
      data: null,
    })
    apiMock.onGet('/protected').reply(401, {
      code: 401,
      message: 'expired',
      data: null,
    })

    await expect(api.get('/protected')).rejects.toMatchObject({ code: 401 })

    expect(tokenManager.get()).toBeNull()
    expect(onUnauthorized).toHaveBeenCalledTimes(1)
    window.removeEventListener('auth:unauthorized', onUnauthorized)
  })

  it('does not let an old refresh overwrite a newly logged-in session', async () => {
    let finishRefresh: ((value: [number, object]) => void) | undefined
    authMock.onPost(/\/api\/auth\/refresh$/).reply(() => new Promise(resolve => {
      finishRefresh = resolve
    }))
    apiMock.onGet('/protected').reply(401, {
      code: 401,
      message: 'expired',
      data: null,
    })

    const oldRequest = api.get('/protected')
    await vi.waitFor(() => expect(authMock.history.post).toHaveLength(1))
    tokenManager.set('new-login-access-token')
    finishRefresh?.([200, {
      code: 0,
      message: 'ok',
      data: { token: 'old-refreshed-access-token' },
    }])

    await expect(oldRequest).rejects.toMatchObject({ code: 401 })
    expect(tokenManager.get()).toBe('new-login-access-token')
  })

  it('does not clear a new session when an old refresh fails', async () => {
    const onUnauthorized = vi.fn()
    window.addEventListener('auth:unauthorized', onUnauthorized)
    let finishRefresh: ((value: [number, object]) => void) | undefined
    authMock.onPost(/\/api\/auth\/refresh$/).reply(() => new Promise(resolve => {
      finishRefresh = resolve
    }))
    apiMock.onGet('/protected').reply(401, {
      code: 401,
      message: 'expired',
      data: null,
    })

    const oldRequest = api.get('/protected')
    await vi.waitFor(() => expect(authMock.history.post).toHaveLength(1))
    tokenManager.set('new-login-access-token')
    finishRefresh?.([401, {
      code: 401,
      message: 'invalid refresh token',
      data: null,
    }])

    await expect(oldRequest).rejects.toMatchObject({ code: 401 })
    expect(tokenManager.get()).toBe('new-login-access-token')
    expect(onUnauthorized).not.toHaveBeenCalled()
    window.removeEventListener('auth:unauthorized', onUnauthorized)
  })

  it('returns a null success body without trying to inspect response fields', async () => {
    apiMock.onGet('/empty-success').reply(200, null)

    await expect(api.get('/empty-success')).resolves.toBeNull()
  })
})

describe('API transient retry policy', () => {
  let apiMock: AxiosMockAdapter

  beforeEach(() => {
    apiMock = new AxiosMockAdapter(apiClient)
    tokenManager.set('stale-access-token')
  })

  afterEach(() => {
    apiMock.restore()
    tokenManager.remove()
  })

  it('omits stale authorization from public authentication requests', async () => {
    apiMock.onPost('/auth/login').reply(200, {
      code: 0,
      message: 'ok',
      data: { token: 'new-access-token' },
    })

    await api.post('/auth/login', {}, { skipAuth: true })

    expect(apiMock.history.post[0].headers?.Authorization).toBeUndefined()
  })

  it('recovers a replay-safe post after two transient gateway failures', async () => {
    apiMock
      .onPost('/auth/login')
      .replyOnce(503, { code: 9001, message: 'upstream unavailable', data: null })
      .onPost('/auth/login')
      .replyOnce(504, {})
      .onPost('/auth/login')
      .reply(200, {
        code: 0,
        message: 'ok',
        data: { token: 'new-access-token' },
      })

    const result = await api.post<{ token: string }>('/auth/login', {}, {
      retryTransient: true,
      skipAuth: true,
    })

    expect(result).toEqual({ token: 'new-access-token' })
    expect(apiMock.history.post).toHaveLength(3)
  })

  it('does not retry a rejected login response', async () => {
    apiMock.onPost('/auth/login').reply(400, {
      code: 400,
      message: '账号或密码错误',
      data: null,
    })

    await expect(api.post('/auth/login', {}, {
      retryTransient: true,
      skipAuth: true,
    })).rejects.toMatchObject({ code: 400, message: '账号或密码错误' })
    expect(apiMock.history.post).toHaveLength(1)
  })

  it('limits a dropped GET request to three total attempts', async () => {
    apiMock.onGet('/private-read').networkError()

    await expect(api.get('/private-read')).rejects.toMatchObject({ code: -2 })

    expect(apiMock.history.get).toHaveLength(3)
  })
})

describe('API trading mode requests', () => {
  let mock: AxiosMockAdapter
  beforeEach(() => { mock = new AxiosMockAdapter(apiClient); setTradingMode('ordinary') })
  afterEach(() => { mock.restore(); setTradingMode('ordinary') })

  it('ignores a delayed response after switching away and back', async () => {
    let finish!: (result: [number, object]) => void
    mock.onGet('/account/info').reply(() => new Promise(resolve => { finish = resolve }))
    const result = expect(api.get('/account/info')).rejects.toMatchObject({ code: -3 })
    await vi.waitFor(() => expect(mock.history.get).toHaveLength(1))
    setTradingMode('lead')
    setTradingMode('ordinary')
    finish([200, { code: 0, data: { balance: 'old' } }])
    await result
  })

  it('cancels an old read retry instead of dispatching against another mode', async () => {
    mock.onGet('/account/info').networkError()
    const result = expect(api.get('/account/info')).rejects.toMatchObject({ code: -3 })
    await vi.waitFor(() => expect(mock.history.get).toHaveLength(1))
    setTradingMode('lead')
    await result
    expect(mock.history.get).toHaveLength(1)
  })

  it('sends writes with the selected mode and prevents switching while pending', async () => {
    setTradingMode('lead')
    let finish!: (result: [number, object]) => void
    mock.onPost('/trade/open').reply(() => new Promise(resolve => { finish = resolve }))
    const result = api.post('/trade/open', { client_request_id: 'test' })
    expect(hasActiveTradingMutation()).toBe(true)
    expect(() => setTradingMode('ordinary')).toThrow()
    await vi.waitFor(() => expect(mock.history.post).toHaveLength(1))
    expect(mock.history.post[0].headers?.['X-Trading-Mode']).toBe('lead')
    finish([200, { code: 0, data: { position_id: 1 } }])
    await expect(result).resolves.toEqual({ position_id: 1 })
    expect(hasActiveTradingMutation()).toBe(false)
  })
})
