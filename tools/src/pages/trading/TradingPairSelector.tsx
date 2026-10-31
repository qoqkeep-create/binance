import { useState } from 'react'
import { Search, X } from 'lucide-react'
import { CURATED_TRADING_SYMBOLS, PINNED_TRADING_SYMBOL_SET } from '@/shared/constants'

interface TradingPairSelectorProps {
  isOpen: boolean
  onClose: () => void
  onSelect: (pair: string) => void
  currentPair: string
  pairs?: string[]
}

export function TradingPairSelector({ isOpen, onClose, onSelect, currentPair, pairs }: TradingPairSelectorProps) {
  const [searchTerm, setSearchTerm] = useState('')
  const tradingPairs = pairs && pairs.length > 0 ? pairs : [...CURATED_TRADING_SYMBOLS]

  const filteredPairs = tradingPairs.filter(pair =>
    pair.toLowerCase().includes(searchTerm.toLowerCase())
  )

  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-50 flex items-end">
      <div className="absolute inset-0 bg-black/50" onClick={onClose} />
      <div className="relative w-full max-w-md mx-auto rounded-t-2xl transition-colors bg-t-modal" style={{ height: '65vh' }}>
        <div className="flex items-center justify-between p-4 pb-3">
          <h2 className="text-lg font-medium text-t-text">选择币种</h2>
          <button onClick={onClose} className="p-1.5 rounded-full transition-colors hover:bg-t-surface-hover text-t-text-muted">
            <X size={20} />
          </button>
        </div>

        <div className="px-4 pb-3">
          <div className="flex items-center gap-2 rounded-lg px-4 py-3 transition-colors bg-t-surface-input">
            <Search size={20} className="text-t-text-muted" />
            <input
              type="text"
              placeholder="搜索币种..."
              value={searchTerm}
              onChange={(e) => setSearchTerm(e.target.value)}
              className="flex-1 bg-transparent outline-none placeholder:text-t-text-placeholder text-t-text"
            />
          </div>
        </div>

        <div className="overflow-y-auto px-4 pb-4" style={{ height: 'calc(65vh - 130px)' }}>
          {filteredPairs.map((pair) => (
            <button
              key={pair}
              onClick={() => { onSelect(pair); onClose() }}
              className={`w-full text-left py-4 border-b transition-colors border-t-border hover:bg-t-surface-hover ${
                pair === currentPair ? 'text-[#F0B90B]' : 'text-t-text'
              }`}
            >
              <div className="flex items-center justify-between gap-3">
                <span>{pair}</span>
                {PINNED_TRADING_SYMBOL_SET.has(pair) ? (
                  <span className="rounded-full bg-[#F0B90B]/12 px-2 py-0.5 text-xs font-semibold text-[#B78103]">
                    当前精选
                  </span>
                ) : null}
              </div>
            </button>
          ))}
        </div>
      </div>
    </div>
  )
}
