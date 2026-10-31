import { act, fireEvent, render, screen, waitFor } from '@testing-library/react'
import { MemoryRouter, Route, Routes } from 'react-router-dom'
import { beforeEach, describe, expect, it, vi } from 'vitest'
import { StrategyEditorPage } from './StrategyEditorPage'
import { api } from '@/shared/lib/api'
import { useAuthStore, useTradingStore } from '@/shared/store'
import { setTradingMode } from '@/shared/lib/tradingMode'

vi.mock('@/shared/lib/device', async original => ({
  ...await original<typeof import('@/shared/lib/device')>(),
  isStandaloneMode: () => false,
}))

const strategy = {
  id: 7, name: '服务器策略', is_active: false,
  levels: [{ profitRR: 3, reducePosition: 100, stopLossType: 'none' as const }],
}

function deferred<T>() {
  let resolve!: (value: T) => void
  const promise = new Promise<T>(done => { resolve = done })
  return { promise, resolve }
}

function renderEditor(id = '7') {
  return render(<MemoryRouter initialEntries={[`/strategy-management/edit/${id}`]}><Routes>
    <Route path="/strategy-management/edit/:id?" element={<StrategyEditorPage />} />
    <Route path="/strategy-management" element={<p>策略列表</p>} />
  </Routes></MemoryRouter>)
}

describe('strategy editor server identity', () => {
  beforeEach(() => {
    localStorage.clear()
    setTradingMode('ordinary')
    useTradingStore.getState().resetAccountState()
    useAuthStore.getState().login({ id: '1', email: 'editor@example.com' }, 'placeholder-token')
  })

  it('loads an existing route without a cache and saves the requested server ID', async () => {
    const request = deferred<typeof strategy[]>()
    const get = vi.spyOn(api, 'get').mockReturnValue(request.promise)
    const post = vi.spyOn(api, 'post').mockResolvedValue(strategy)
    renderEditor()
    await waitFor(() => expect(get).toHaveBeenCalledWith('/strategy/list', expect.any(Object)))
    expect(screen.queryByRole('button', { name: '确定' })).not.toBeInTheDocument()
    await act(async () => request.resolve([strategy]))
    expect(screen.getByRole('heading', { name: strategy.name })).toBeInTheDocument()
    expect(screen.getAllByRole('textbox')[0]).toHaveValue('3')
    fireEvent.click(screen.getByRole('button', { name: '确定' }))
    await waitFor(() => expect(post).toHaveBeenCalledWith('/strategy/save', {
      strategy_id: 7, name: strategy.name,
      levels: [{ ...strategy.levels[0], stopLossRR: undefined, stopLossAbsoluteRR: undefined }],
    }))
  })

  it('uses the server version rather than an existing cached form', async () => {
    useTradingStore.getState().replaceStrategies([{ ...strategy, id: '7', name: '旧缓存', levels: [{ ...strategy.levels[0], profitRR: 1 }] }])
    const request = deferred<typeof strategy[]>()
    vi.spyOn(api, 'get').mockReturnValue(request.promise)
    renderEditor()
    expect(screen.queryByRole('button', { name: '确定' })).not.toBeInTheDocument()
    await act(async () => request.resolve([strategy]))
    expect(screen.getByRole('heading', { name: strategy.name })).toBeInTheDocument()
    expect(screen.getAllByRole('textbox')[0]).toHaveValue('3')
  })

  it('reports a missing strategy and never turns the edit into creation', async () => {
    vi.spyOn(api, 'get').mockResolvedValue([])
    const post = vi.spyOn(api, 'post')
    renderEditor()
    expect(await screen.findByRole('alert')).toHaveTextContent('策略不存在')
    expect(screen.queryByRole('button', { name: '确定' })).not.toBeInTheDocument()
    expect(post).not.toHaveBeenCalled()
  })

  it('ignores delayed data from an earlier user session', async () => {
    const previous = deferred<typeof strategy[]>()
    vi.spyOn(api, 'get').mockReturnValueOnce(previous.promise).mockResolvedValue([{ ...strategy, name: '当前用户策略' }])
    renderEditor()
    act(() => useAuthStore.getState().login({ id: '2', email: 'other-editor@example.com' }, 'placeholder-token'))
    expect(await screen.findByRole('heading', { name: '当前用户策略' })).toBeInTheDocument()
    await act(async () => previous.resolve([strategy]))
    expect(screen.getByRole('heading', { name: '当前用户策略' })).toBeInTheDocument()
    expect(screen.queryByText(strategy.name)).not.toBeInTheDocument()
  })

  it('reloads and ignores a delayed response after switching trading modes', async () => {
    const previous = deferred<typeof strategy[]>()
    vi.spyOn(api, 'get').mockReturnValueOnce(previous.promise).mockResolvedValue([{ ...strategy, name: '当前模式策略' }])
    renderEditor()
    act(() => setTradingMode('lead'))
    expect(await screen.findByRole('heading', { name: '当前模式策略' })).toBeInTheDocument()
    await act(async () => previous.resolve([strategy]))
    expect(screen.getByRole('heading', { name: '当前模式策略' })).toBeInTheDocument()
  })

  it('keeps a new strategy as an explicit creation without a list request', async () => {
    const get = vi.spyOn(api, 'get')
    renderEditor('')
    expect(screen.getByRole('heading', { name: '策略1' })).toBeInTheDocument()
    expect(get).not.toHaveBeenCalled()
  })
})
