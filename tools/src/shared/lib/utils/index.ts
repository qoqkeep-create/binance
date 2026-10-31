import { clsx, type ClassValue } from 'clsx'
import { twMerge } from 'tailwind-merge'

/** 合并 Tailwind 类名 */
export function cn(...inputs: ClassValue[]) {
  return twMerge(clsx(inputs))
}

/** 格式化金额 */
export function formatMoney(value: number, decimals = 2): string {
  return value.toLocaleString('en-US', {
    minimumFractionDigits: decimals,
    maximumFractionDigits: decimals,
  })
}

/** 智能格式化金额：>=1 显示2位小数(整数不显示小数)，<1 显示4位有效数字 */
export function formatSmartAmount(value: number | string): string {
  const num = typeof value === 'string' ? parseFloat(value) : value
  if (isNaN(num) || num === 0) return '0'
  const abs = Math.abs(num)
  const sign = num < 0 ? '-' : ''
  if (abs >= 1) {
    // >=1: 2位小数，如果是整数则不显示小数
    const fixed = abs.toFixed(2)
    // 去掉末尾的 .00
    if (fixed.endsWith('.00')) {
      return sign + fixed.slice(0, -3)
    }
    // 去掉末尾单个0 (如 1.50 -> 1.5)
    if (fixed.endsWith('0') && !fixed.endsWith('.0')) {
      return sign + fixed.slice(0, -1)
    }
    return sign + fixed
  }
  // <1: 4位有效数字
  const formatted = abs.toPrecision(4)
  // 去掉不必要的尾随0
  const cleaned = parseFloat(formatted).toString()
  return sign + cleaned
}

/** 格式化百分比 */
export function formatPercent(value: number, decimals = 2): string {
  return `${value >= 0 ? '+' : ''}${value.toFixed(decimals)}%`
}

/** 脱敏显示（如 API Key）*/
export function maskString(str: string, visibleStart = 4, visibleEnd = 4): string {
  if (str.length <= visibleStart + visibleEnd) {
    return '****'
  }
  return `${str.slice(0, visibleStart)}****${str.slice(-visibleEnd)}`
}

/** 安全解析数字 */
export function safeParseNumber(input: string | number, fallback = 0): number {
  if (typeof input === 'number') {
    return isNaN(input) ? fallback : input
  }
  const cleaned = input.replace(/[^\d.-]/g, '')
  const num = parseFloat(cleaned)
  return isNaN(num) ? fallback : num
}

/** 防抖 */
export function debounce<T extends (...args: unknown[]) => unknown>(
  fn: T,
  delay: number
): (...args: Parameters<T>) => void {
  let timer: ReturnType<typeof setTimeout> | null = null

  return (...args: Parameters<T>) => {
    if (timer) clearTimeout(timer)
    timer = setTimeout(() => {
      fn(...args)
      timer = null
    }, delay)
  }
}

/** 节流 */
export function throttle<T extends (...args: unknown[]) => unknown>(
  fn: T,
  limit: number
): (...args: Parameters<T>) => void {
  let lastCall = 0

  return (...args: Parameters<T>) => {
    const now = Date.now()
    if (now - lastCall >= limit) {
      lastCall = now
      fn(...args)
    }
  }
}

/** 生成唯一 ID */
export function generateId(): string {
  const cryptoObject = globalThis.crypto
  if (cryptoObject?.randomUUID) {
    return cryptoObject.randomUUID()
  }

  const bytes = new Uint8Array(16)
  if (cryptoObject?.getRandomValues) {
    cryptoObject.getRandomValues(bytes)
  } else {
    for (let index = 0; index < bytes.length; index += 1) {
      bytes[index] = Math.floor(Math.random() * 256)
    }
  }

  bytes[6] = (bytes[6] & 0x0f) | 0x40
  bytes[8] = (bytes[8] & 0x3f) | 0x80

  const hex = Array.from(bytes, byte => byte.toString(16).padStart(2, '0'))
  return [
    hex.slice(0, 4).join(''),
    hex.slice(4, 6).join(''),
    hex.slice(6, 8).join(''),
    hex.slice(8, 10).join(''),
    hex.slice(10, 16).join(''),
  ].join('-')
}

/** 复制到剪贴板 */
export async function copyToClipboard(text: string): Promise<boolean> {
  try {
    await navigator.clipboard.writeText(text)
    return true
  } catch {
    // 降级方案
    const textarea = document.createElement('textarea')
    textarea.value = text
    textarea.style.position = 'fixed'
    textarea.style.opacity = '0'
    document.body.appendChild(textarea)
    textarea.select()
    const success = document.execCommand('copy')
    document.body.removeChild(textarea)
    return success
  }
}
