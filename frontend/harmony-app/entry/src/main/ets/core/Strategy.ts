import { DataValue } from './Json';
import { Decimal } from './Decimal';
export class StrategyLevel {
  profit: string = '1';
  reduce: string = '20';
  stopType: string = 'none';
  stopValue: string = '';
  static from(row: DataValue): StrategyLevel {
    const level = new StrategyLevel(); level.profit = row.value('profitRR', '1'); level.reduce = row.value('reducePosition', '20');
    level.stopType = row.value('stopLossType', 'none'); level.stopValue = row.value(level.stopType === 'fixedRR' ? 'stopLossRR' : 'stopLossAbsoluteRR', ''); return level;
  }
  value(): DataValue {
    const row = DataValue.object({ profitRR: this.profit, reducePosition: this.reduce, stopLossType: this.stopType });
    if (this.stopType !== 'none') row.fields()[this.stopType === 'fixedRR' ? 'stopLossRR' : 'stopLossAbsoluteRR'] = this.stopValue;
    return row;
  }
}
export function strategyPayload(name: string, levels: StrategyLevel[], id: DataValue = new DataValue()): DataValue {
  if (!name.trim() || name.trim().length > 100) throw new Error('请输入不超过100字的策略名称');
  if (levels.length < 1 || levels.length > 5) throw new Error('策略需要1至5个层级');
  let previous = new Decimal('0'); let total = new Decimal('0');
  for (const level of levels) {
    const profit = new Decimal(level.profit); const reduce = new Decimal(level.reduce);
    if (profit.compare(previous) <= 0) throw new Error('盈利 R 必须为正数并逐层递增');
    if (reduce.compare(new Decimal('0')) < 0) throw new Error('减仓比例不能小于0');
    if (!['none', 'fixedRR', 'absoluteRR'].includes(level.stopType)) throw new Error('止损移动类型无效');
    if (level.stopType === 'fixedRR' && !new Decimal(level.stopValue).positive()) throw new Error('浮盈回撤 R 必须大于0');
    if (level.stopType === 'absoluteRR' && new Decimal(level.stopValue).compare(new Decimal('-1')) <= 0) throw new Error('移动目标必须大于 -1R');
    previous = profit; total = total.add(reduce);
  }
  if (total.compare(new Decimal('100')) > 0) throw new Error('减仓比例总和不能超过100%');
  const payload = DataValue.object({ name: name.trim(), levels: levels.map((v: StrategyLevel) => v.value().raw) });
  if (!id.empty()) payload.fields()['strategy_id'] = id.raw;
  return payload;
}
