import { render, screen } from '@testing-library/react'
import { describe, expect, it, vi } from 'vitest'

import { StopLossSettingsModal } from './StopLossSettingsModal'
import { api } from '@/shared/lib/api'

describe('StopLossSettingsModal', () => {
  it('portals the modal above the bottom navigation layer', () => {
    vi.spyOn(window, 'scrollTo').mockImplementation(() => undefined)
    vi.spyOn(api, 'get').mockResolvedValueOnce({
      current_amount: '20',
      pending_amount: null,
      pending_from_amount: null,
      pending_effective_at: null,
      countdown_seconds: 0,
      balance: '100',
      total_balance: '100',
    })

    render(
      <StopLossSettingsModal
        isOpen
        onClose={vi.fn()}
        accountBalance={100}
        currentStopLoss={20}
      />,
    )

    const modalLayer = screen.getByRole('heading', { name: '止损设置' }).closest('.fixed')
    expect(modalLayer).toHaveClass('z-[130]')
    expect(modalLayer?.parentElement).toBe(document.body)
  })
})
