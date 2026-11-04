#!/usr/bin/env python3
"""Generate numerical fixtures from the actual Swift calculators, without an iOS simulator.
Only presentation-only type dependencies are removed. Calculator source is copied verbatim.
Requires the local Xcode Swift toolchain; outputs public synthetic data, never account data.
"""
import hashlib, json, pathlib, subprocess
root = pathlib.Path(__file__).resolve().parents[1]
ios = root.parent / 'ios-app/TradeTool'
work = root / '.local-build/swift-chart-reference'
work.mkdir(parents=True, exist_ok=True)
hashes = {}
def read(relative):
    text = (ios / relative).read_text()
    hashes[relative] = hashlib.sha256(text.encode()).hexdigest()
    return text
parts = [read('Core/Models/MarketKline.swift'), read('Core/Presentation/DisplayNumber.swift')]
candle = read('Features/ChartEngine/Domain/ChartCandle.swift')
parts.append(candle[candle.index('enum ChartCandleClosure'):candle.index('extension ChartCandle')])
panel = read('Features/ChartEngine/Scene/PanelLayout.swift')
parts.append(panel[:panel.index('struct ChartPanelRect')])
plugin = read('Features/ChartEngine/Indicators/ChartIndicatorPlugin.swift').split('struct ChartIndicatorRegistry')[0]
a = plugin.index('  var color: ChartColor {'); b = plugin.index('\nstruct ChartIndicatorParameterDescriptor', a)
plugin = plugin[:a] + '}\n' + plugin[b:]
parts.append(plugin)
for name in ['EMAIndicator','MACDIndicator','SuperTrendIndicator','SimpleMovingAverageIndicator','BollingerBandsIndicator','ParabolicSARIndicator','AveragePriceIndicator','RSIIndicator','VolumeIndicator','TechnicalPanelIndicators','TradingDataPanelIndicators']:
    parts.append(read('Features/ChartEngine/Indicators/' + name + '.swift'))
main = r'''
func scalar(_ value: Double?) -> Any { value.map { $0 as Any } ?? NSNull() }
func fixture(gap: Bool) -> [String: Any] {
  let candles = (0..<180).map { index -> ChartCandle in
    let time = Int64(index + (gap && index >= 90 ? 1 : 0) + 1) * 60000
    let open = 100 + Double(index % 17) * 0.7 + Double(index / 17) * 0.3
    let close = open + Double(index % 7 - 3) * 0.2
    let volume = index % 23 == 0 ? 0 : Double(index % 19 + 10)
    return ChartCandle(openTime: time, closeTime: time + 59999, openPrice: open,
      highPrice: max(open, close) + 0.6, lowPrice: min(open, close) - 0.4,
      closePrice: close, volume: volume, quoteVolume: volume * (open + 0.1),
      tradingData: index % 11 == 0 ? nil : MarketChartTradingData(openInterest: Double(index + 100), openInterestNotional: Double(index + 100) * close,
        topLongAccount: 0.6, topShortAccount: 0.4, topLongShortAccountRatio: 1.5,
        topLongPosition: 0.7, topShortPosition: 0.3, topLongShortPositionRatio: 7.0/3,
        globalLongAccount: 0.55, globalShortAccount: 0.45, globalLongShortAccountRatio: 11.0/9,
        takerBuyVolume: volume * 0.6, takerSellVolume: volume * 0.4,
        basis: 0.3, basisRate: 0.002, futuresPrice: close + 0.4, indexPrice: close + 0.1),
      closure: index == 179 ? .provisional : .closed)
  }
  var result: [String: [[Any]]] = [:]
  for (name, periods) in [("EMA", [21,55,144]), ("MA", [7,25,99])] {
    result[name] = periods.map { period in
      var ema = EMAIndicatorCalculator(period: period, intervalMilliseconds: 60000)!
      var ma = SimpleMovingAverageIndicatorCalculator(period: period, intervalMilliseconds: 60000)!
      return candles.map { c in scalar(name == "EMA" ? (c.closure == .closed ? ema.commit(c).value : ema.provisional(c)?.value) : (c.closure == .closed ? ma.commit(c).value : ma.provisional(c)?.value)) }
    }
  }
  var superCalc = SuperTrendIndicatorCalculator(atrPeriod: 10, multiplier: 6, intervalMilliseconds: 60000)!
  result["SUPER"] = [candles.map { c in scalar(c.closure == .closed ? superCalc.commit(c).value : superCalc.provisional(c)?.value) }]
  var macd = MACDIndicatorCalculator(fastPeriod: 12, slowPeriod: 26, signalPeriod: 9, intervalMilliseconds: 60000)!
  let macdPoints = candles.map { c in c.closure == .closed ? macd.commit(c) : macd.provisional(c)! }
  result["MACD"] = [macdPoints.map { scalar($0.dif) },macdPoints.map { scalar($0.dea) },macdPoints.map { scalar($0.histogram) }]
  let plugins: [(String, any ChartIndicatorPlugin, [String])] = [
    ("BOLL", BollingerBandsChartIndicatorPlugin(), ["middle", "upper", "lower"]),
    ("SAR", ParabolicSARChartIndicatorPlugin(), ["value"]),
    ("AVL", AveragePriceChartIndicatorPlugin(), ["value"]),
    ("VOL", VolumeChartIndicatorPlugin(), ["volume", "fastAverage", "slowAverage"]),
    ("RSI", RSIChartIndicatorPlugin(), ["value"]),
    ("KDJ", TechnicalPanelChartIndicatorPlugin(kind: .kdj), ["k", "d", "j"]),
    ("OBV", TechnicalPanelChartIndicatorPlugin(kind: .obv), ["value"]),
    ("WR", TechnicalPanelChartIndicatorPlugin(kind: .williamsR), ["value"]),
    ("StochRSI", TechnicalPanelChartIndicatorPlugin(kind: .stochasticRSI), ["k", "d"]),
    ("ATR", TechnicalPanelChartIndicatorPlugin(kind: .atr), ["value"]),
    ("O.I.", TradingDataPanelChartIndicatorPlugin(kind: .openInterest), ["openInterest", "notional"]),
    ("L.S Acco.", TradingDataPanelChartIndicatorPlugin(kind: .topAccountRatio), ["total", "long", "ratio"]),
    ("L.S Posit.", TradingDataPanelChartIndicatorPlugin(kind: .topPositionRatio), ["total", "long", "ratio"]),
    ("L.S Ratio", TradingDataPanelChartIndicatorPlugin(kind: .globalAccountRatio), ["total", "long", "ratio"]),
    ("B.S Vol.", TradingDataPanelChartIndicatorPlugin(kind: .buySellVolume), ["buy", "sell"]),
    ("Basis", TradingDataPanelChartIndicatorPlugin(kind: .basis), ["basis", "basisRate", "futuresPremium", "indexPremium"])
  ]
  for (name, plugin, ids) in plugins {
    let config = ChartIndicatorInstanceConfiguration(instanceID: name, pluginID: plugin.descriptor.id, parameters: [:], legendLabel: name, legendRow: 0, legendOrder: 0)!
    var calculator = plugin.makeCalculator(configuration: config, intervalMilliseconds: 60000)!
    let points = candles.map { c in c.closure == .closed ? calculator.commit(c) : calculator.provisional(c) }
    result[name] = ids.map { id in points.map { scalar($0.points[id]?.value) } }
  }
  return ["candles": candles.map { c in ["openTime": c.openTime, "openPrice": c.openPrice, "highPrice": c.highPrice, "lowPrice": c.lowPrice, "closePrice": c.closePrice, "volume": c.volume, "quoteVolume": c.quoteVolume, "tradingData": c.tradingData.map { d in ["openInterest": scalar(d.openInterest), "openInterestNotional": scalar(d.openInterestNotional), "topLongAccount": scalar(d.topLongAccount), "topShortAccount": scalar(d.topShortAccount), "topLongShortAccountRatio": scalar(d.topLongShortAccountRatio), "topLongPosition": scalar(d.topLongPosition), "topShortPosition": scalar(d.topShortPosition), "topLongShortPositionRatio": scalar(d.topLongShortPositionRatio), "globalLongAccount": scalar(d.globalLongAccount), "globalShortAccount": scalar(d.globalShortAccount), "globalLongShortAccountRatio": scalar(d.globalLongShortAccountRatio), "takerBuyVolume": scalar(d.takerBuyVolume), "takerSellVolume": scalar(d.takerSellVolume), "basis": scalar(d.basis), "basisRate": scalar(d.basisRate), "futuresPrice": scalar(d.futuresPrice), "indexPrice": scalar(d.indexPrice)] } as Any? ?? NSNull()] as [String: Any] }, "series": result]
}
let data = try JSONSerialization.data(withJSONObject: ["contiguous":fixture(gap:false), "gap":fixture(gap:true)], options:[.sortedKeys])
print(String(data:data, encoding:.utf8)!)
'''
source = work / 'main.swift'; source.write_text('\n'.join(parts) + main)
binary = work / 'reference'
subprocess.run(['xcrun', 'swiftc', '-O', str(source), '-o', str(binary)], check=True)
result = json.loads(subprocess.check_output([str(binary)]))
result['source_sha256'] = hashes
out = root / 'tests/fixtures/ios-chart-reference.json'
out.write_text(json.dumps(result, ensure_ascii=False, separators=(',', ':'))+'\n')
print('Generated 2 × 180 candles from current Swift sources:', out.relative_to(root))
