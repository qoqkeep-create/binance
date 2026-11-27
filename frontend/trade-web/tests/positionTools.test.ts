import { calculatePositionMetrics, defaultPositionToolDefaults, priceAtChartY, type PositionTool } from "../src/lib/positionTools.js";

function assert(condition: unknown, message: string): asserts condition { if (!condition) throw new Error(message); }
const long: PositionTool = { id: "long", direction: "long", left: .2, right: .8, entryY: .5, targetY: .2, stopY: .8, createdAt: 1 };
const short: PositionTool = { ...long, id: "short", direction: "short", targetY: .8, stopY: .2 };
const longMetrics = calculatePositionMetrics(long, 100, defaultPositionToolDefaults);
const shortMetrics = calculatePositionMetrics(short, 100, defaultPositionToolDefaults);
assert(priceAtChartY(.2, 100, 30) > priceAtChartY(.8, 100, 30), "chart y maps to a higher price above the entry");
assert(longMetrics.profitPercent > 0 && longMetrics.lossPercent > 0, "long tool exposes target and stop distances");
assert(shortMetrics.profitPercent > 0 && shortMetrics.lossPercent > 0, "short tool exposes target and stop distances");
assert(Math.abs(longMetrics.riskReward - shortMetrics.riskReward) < 0.000001, "mirrored long and short plans have the same risk reward");
assert(longMetrics.profitPnl > 0 && longMetrics.lossPnl < 0, "long pnl signs are correct");
assert(shortMetrics.profitPnl > 0 && shortMetrics.lossPnl < 0, "short pnl signs are correct");
console.log("positionTools: long and short measurement checks passed");

