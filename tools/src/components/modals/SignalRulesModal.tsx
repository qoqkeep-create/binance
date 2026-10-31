interface SignalRulesModalProps {
  isOpen: boolean
  onClose: () => void
}

const RULE_GROUPS: { title: string; items: string[] }[] = [
  {
    title: '监控范围',
    items: [
      '币种池：DOGE / BTC / ETH / XAU / SOL / XRP / ADA / BCH / SUI / XLM / HBAR / ALGO / TAO / ZEC（USDT 永续合约，共 14 个）',
      '周期：15 分钟、1 小时、4 小时、1 天',
      '仅在「已收盘确认」的K线上判定，每分钟轮询一次，同一信号只提醒一次',
    ],
  },
  {
    title: '趋势判定（SuperTrend）',
    items: [
      '使用 SuperTrend 指标：ATR 系数 6、ATR 长度 10（Wilder 平滑），源价取 (最高+最低)/2',
      '趋势切换做多：SuperTrend 方向由空翻多 → 静默进入等待做多状态，不发送提醒',
      '趋势切换做空：SuperTrend 方向由多翻空 → 静默进入等待做空状态，不发送提醒',
      '每次趋势切换会清空反向的等待状态',
    ],
  },
  {
    title: '入场信号（EMA55 / EMA144）',
    items: [
      '多头过滤：EMA21 在 EMA55 之上；15 分钟周期放宽为 EMA55 在 EMA144 之上亦可',
      '空头过滤：EMA55 在 EMA144 之下；15 分钟周期放宽为 EMA21 在 EMA55 之下亦可',
      '做多入场：等待做多期间，出现阳线且整根K线（含影线）触碰/穿过 EMA55 或 EMA144 → 触发「做多入场EMA55/144」，对应等待随即消耗',
      '做空入场：等待做空期间，出现阴线且整根K线（含影线）触碰/穿过 EMA55 或 EMA144 → 触发「做空入场EMA55/144」，对应等待随即消耗',
      '趋势切换当根K线不允许触发入场；等待消耗后需等待下一次趋势切换才会重新等待',
    ],
  },
  {
    title: '提醒出口',
    items: [
      '触发后同步推送到企业微信群，并展示在本页信号列表',
      '信号由自有服务器基于币安公开行情计算，不依赖任何第三方平台',
    ],
  },
]

export function SignalRulesModal({ isOpen, onClose }: SignalRulesModalProps) {
  if (!isOpen) return null

  return (
    <div className="fixed inset-0 z-[120] flex items-center justify-center p-4">
      <div className="absolute inset-0 bg-black/60 backdrop-blur-sm" onClick={onClose} />
      <div className="relative flex flex-col max-w-sm w-full max-h-[80vh] rounded-2xl p-6 shadow-2xl bg-t-modal">
        <div className="flex items-center justify-between mb-3">
          <h3 className="text-lg font-bold text-t-text">信号规则</h3>
          <button
            onClick={onClose}
            className="w-8 h-8 flex items-center justify-center rounded-full transition-colors text-t-text-muted hover:bg-t-surface-hover"
          >
            <svg width="16" height="16" viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth="2" strokeLinecap="round" strokeLinejoin="round">
              <line x1="18" y1="6" x2="6" y2="18" /><line x1="6" y1="6" x2="18" y2="18" />
            </svg>
          </button>
        </div>
        <div className="flex-1 min-h-0 overflow-y-auto hide-scrollbar -mx-1 px-1 space-y-4 text-sm">
          {RULE_GROUPS.map(group => (
            <div key={group.title}>
              <div className="mb-1.5 font-medium text-[#F0B90B]">{group.title}</div>
              <ul className="space-y-1.5">
                {group.items.map(item => (
                  <li key={item} className="flex gap-2 leading-relaxed text-t-text-secondary">
                    <span className="mt-[7px] w-1 h-1 shrink-0 rounded-full bg-t-text-muted" />
                    <span>{item}</span>
                  </li>
                ))}
              </ul>
            </div>
          ))}
        </div>
        <button
          onClick={onClose}
          className="mt-4 w-full py-3 rounded-xl font-medium transition-all active:scale-[0.98] bg-gradient-to-r from-[#F0B90B] to-[#D9A70A] text-black hover:shadow-lg hover:shadow-[#F0B90B]/30"
        >
          我知道了
        </button>
      </div>
    </div>
  )
}
