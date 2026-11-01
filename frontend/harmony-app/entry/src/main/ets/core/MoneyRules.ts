import { Decimal } from './Decimal';
/** Matches accounts.services.round_up_stop_loss; server remains authoritative. */
export function stopLossPreview(balance: string, percentage: string): string {
  if (!/^\d+$/.test(percentage) || Number(percentage) < 1 || Number(percentage) > 25) throw new Error('请输入1至25之间的整数百分比');
  const total = new Decimal(balance); if (!total.positive()) throw new Error('账户总资产尚未读取');
  const raw = total.multiply(new Decimal(percentage)).multiply(new Decimal('0.01'));
  const step = new Decimal(raw.compare(new Decimal('20')) < 0 ? '1' : raw.compare(new Decimal('100')) < 0 ? '5' : '10');
  let units = raw.divide(step, 0);
  if (units.multiply(step).compare(raw) < 0) units = units.add(new Decimal('1'));
  if (!units.positive()) units = new Decimal('1');
  return units.multiply(step).toString();
}
