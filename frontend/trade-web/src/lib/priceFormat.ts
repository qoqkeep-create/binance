// 右轴/标签价格分档精度：tiny 价格（<1e-4）必须给足小数位，否则刻度全舍入为 0＝"无价格"。
export function priceScaleFormatter(price: number) {
  const abs = Math.abs(price);
  const digits = abs < 0.0001 ? 8 : abs < 0.01 ? 6 : abs < 1 ? 4 : abs < 100 ? 3 : abs < 10000 ? 2 : 1;
  return price.toFixed(digits);
}

// 价格刻度步长下限：与分档精度匹配，避免 minMove 过粗把 tiny 价格刻度抹平。
export function minMoveFor(price: number) {
  const abs = Math.abs(price);
  return abs < 0.0001 ? 0.00000001 : abs < 0.01 ? 0.000001 : 0.0001;
}