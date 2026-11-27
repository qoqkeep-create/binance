import { calculatePositionMetrics, defaultPositionToolDefaults, isPositionTool, type PositionTool } from "../src/lib/positionTools.js";

function assert(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
const long: PositionTool = { id: "long", direction: "long", startTime: 1000, endTime: 1600, entryPrice: 100, targetPrice: 110, stopPrice: 95, createdAt: 1 };
const short: PositionTool = { ...long, id: "short", direction: "short", targetPrice: 90, stopPrice: 105 };
const longMetrics = calculatePositionMetrics(long, 100, defaultPositionToolDefaults);
const shortMetrics = calculatePositionMetrics(short, 100, defaultPositionToolDefaults);
assert(isPositionTool(long) && isPositionTool(short), "data-coordinate tools pass validation");
assert(!isPositionTool({ ...long, endTime: 900 }), "endTime before startTime is rejected");
assert(!isPositionTool({ ...long, entryPrice: 0 }), "non-positive prices are rejected");
assert(longMetrics.entryPrice === 100 && longMetrics.targetPrice === 110 && longMetrics.stopPrice === 95, "metrics read stored prices without pixel mapping");
assert(longMetrics.profitPercent > 0 && longMetrics.lossPercent > 0, "long tool exposes target and stop distances");
assert(shortMetrics.profitPercent > 0 && shortMetrics.lossPercent > 0, "short tool exposes target and stop distances");
assert(Math.abs(longMetrics.riskReward - shortMetrics.riskReward) < 0.000001, "mirrored long and short plans have the same risk reward");
assert(longMetrics.profitPnl > 0 && longMetrics.lossPnl < 0, "long pnl signs are correct");
assert(shortMetrics.profitPnl > 0 && shortMetrics.lossPnl < 0, "short pnl signs are correct");
assert(calculatePositionMetrics(long, 105, defaultPositionToolDefaults).openPnl > 0, "price above long entry is a profit");
assert(calculatePositionMetrics(short, 105, defaultPositionToolDefaults).openPnl < 0, "price above short entry is a loss");
console.log("positionTools: data-coordinate long and short measurement checks passed");