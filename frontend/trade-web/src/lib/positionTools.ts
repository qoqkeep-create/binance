export type PositionDirection = "long" | "short";
export type PositionRiskMode = "percent" | "currency";

// 锚定图表数据坐标（时间+价格），随 K 线缩放/平移同层伸缩，而非浮层固定像素。
export interface PositionTool {
  id: string;
  direction: PositionDirection;
  startTime: number;
  endTime: number;
  entryPrice: number;
  targetPrice: number;
  stopPrice: number;
  createdAt: number;
}

export interface PositionToolDefaults {
  accountSize: number;
  riskMode: PositionRiskMode;
  riskValue: number;
  lotSize: number;
  leverage: number;
  qtyPrecision: number;
  priceRangePercent: number;
}

export interface PositionMetrics {
  entryPrice: number;
  targetPrice: number;
  stopPrice: number;
  currentPrice: number;
  profitPercent: number;
  lossPercent: number;
  riskReward: number;
  quantity: number;
  profitPnl: number;
  lossPnl: number;
  openPnl: number;
  riskAmount: number;
}

export const defaultPositionToolDefaults: PositionToolDefaults = {
  accountSize: 10000,
  riskMode: "percent",
  riskValue: 1,
  lotSize: 1,
  leverage: 1,
  qtyPrecision: 3,
  priceRangePercent: 30,
};

const finite = (value: unknown): value is number => typeof value === "number" && Number.isFinite(value);

export function isPositionTool(value: unknown): value is PositionTool {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const item = value as Partial<PositionTool>;
  if (typeof item.id !== "string" || item.id.length === 0 || item.id.length > 80 || (item.direction !== "long" && item.direction !== "short")) return false;
  const numbers = [item.startTime, item.endTime, item.entryPrice, item.targetPrice, item.stopPrice, item.createdAt];
  if (!numbers.every(finite)) return false;
  const [startTime, endTime, entryPrice, targetPrice, stopPrice] = numbers as [number, number, number, number, number, number];
  return startTime < endTime && entryPrice > 0 && targetPrice > 0 && stopPrice > 0;
}

export function isPositionToolDefaults(value: unknown): value is PositionToolDefaults {
  if (!value || typeof value !== "object" || Array.isArray(value)) return false;
  const defaults = value as Partial<PositionToolDefaults>;
  return finite(defaults.accountSize) && defaults.accountSize > 0
    && (defaults.riskMode === "percent" || defaults.riskMode === "currency")
    && finite(defaults.riskValue) && defaults.riskValue > 0
    && finite(defaults.lotSize) && defaults.lotSize > 0
    && finite(defaults.leverage) && defaults.leverage > 0
    && finite(defaults.qtyPrecision) && Number.isInteger(defaults.qtyPrecision) && defaults.qtyPrecision >= 0 && defaults.qtyPrecision <= 8
    && finite(defaults.priceRangePercent) && defaults.priceRangePercent > 0 && defaults.priceRangePercent <= 200;
}

export function calculatePositionMetrics(position: PositionTool, currentPrice: number, defaults: PositionToolDefaults): PositionMetrics {
  const entryPrice = position.entryPrice;
  const targetPrice = position.targetPrice;
  const stopPrice = position.stopPrice;
  const directionSign = position.direction === "long" ? 1 : -1;
  const profitDistance = Math.max(0, (targetPrice - entryPrice) * directionSign);
  const lossDistance = Math.max(0.00000001, (entryPrice - stopPrice) * directionSign);
  const profitPercent = profitDistance / entryPrice * 100;
  const lossPercent = lossDistance / entryPrice * 100;
  const riskAmount = defaults.riskMode === "percent" ? defaults.accountSize * defaults.riskValue / 100 : defaults.riskValue;
  const quantityByRisk = riskAmount / (lossDistance * defaults.lotSize);
  const quantityByLeverage = defaults.accountSize * defaults.leverage / (entryPrice * defaults.lotSize);
  const quantity = Math.max(0, Math.min(quantityByRisk, quantityByLeverage));
  const multiplier = quantity * defaults.lotSize;
  const profitPnl = profitDistance * multiplier;
  const lossPnl = -lossDistance * multiplier;
  const openPnl = (currentPrice - entryPrice) * directionSign * multiplier;
  return {
    entryPrice, targetPrice, stopPrice, currentPrice,
    profitPercent, lossPercent,
    riskReward: profitDistance / lossDistance,
    quantity, profitPnl, lossPnl, openPnl, riskAmount,
  };
}