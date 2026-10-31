import type { StrategyLevel } from '@/shared/types'

function formatNumber(value: number | undefined): string {
  if (value === undefined || Number.isNaN(value)) return '0'
  return Number.isInteger(value) ? String(value) : String(value)
}

export function formatStrategyLevelText(level: StrategyLevel, levelIndex?: number): string {
  const prefix = typeof levelIndex === 'number' ? `L${levelIndex + 1}：` : ''
  const parts: string[] = [`${prefix}当 RR≥${formatNumber(level.profitRR)}`]

  if (level.reducePosition > 0) {
    parts.push(`卖出 ${formatNumber(level.reducePosition)}%`)
  }

  if (level.stopLossType === 'absoluteRR' && level.stopLossAbsoluteRR !== undefined) {
    parts.push(`止损位移动到 ${formatNumber(level.stopLossAbsoluteRR)}R 处`)
  }

  if (level.stopLossType === 'fixedRR' && level.stopLossRR !== undefined) {
    parts.push(`止损位移动到浮盈- ${formatNumber(level.stopLossRR)}R 处`)
  }

  return parts.join('，')
}
