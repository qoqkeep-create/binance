/** Match trade-form prices; small prices retain four significant digits. */
export function formatChartPrice(price: number): string {
  if (!Number.isFinite(price) || price === 0) return String(price)
  const abs = Math.abs(price)
  if (abs >= 100) return String(Number(price.toFixed(2)))
  if (abs >= 1) return String(Number(price.toFixed(3)))
  return String(Number(price.toPrecision(4)))
}
