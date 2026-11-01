/** Wire values stay strings for money. Only chart coordinates convert to number. */
export class DataValue {
  raw: Object | null;
  constructor(raw: Object | null = null) { this.raw = raw; }
  static parse(text: string): DataValue { return new DataValue(JSON.parse(text) as Object); }
  static object(fields: Record<string, Object | null> = {}): DataValue { return new DataValue(fields); }
  get(key: string): DataValue {
    if (this.raw === null || typeof this.raw !== 'object' || Array.isArray(this.raw)) return new DataValue();
    const value = (this.raw as Record<string, Object | null>)[key];
    return new DataValue(value === undefined ? null : value);
  }
  text(fallback: string = '--'): string {
    if (this.raw === null || this.raw === undefined) return fallback;
    if (typeof this.raw === 'string' || typeof this.raw === 'number') return String(this.raw);
    if (typeof this.raw === 'boolean') return this.raw ? '是' : '否';
    return fallback;
  }
  value(key: string, fallback: string = '--'): string { return this.get(key).text(fallback); }
  number(fallback: number = 0): number {
    const n = Number(this.text(''));
    return this.raw !== null && this.text('') !== '' && Number.isFinite(n) ? n : fallback;
  }
  flag(): boolean { return this.raw === true; }
  empty(): boolean { return this.raw === null || (typeof this.raw === 'object' && Object.keys(this.raw).length === 0); }
  rows(): DataValue[] {
    if (!Array.isArray(this.raw)) return [];
    return (this.raw as Object[]).map((v: Object) => new DataValue(v));
  }
  items(): DataValue[] {
    if (Array.isArray(this.raw)) return this.rows();
    for (const key of ['items', 'records', 'logs', 'tickers', 'candles']) {
      const value = this.get(key);
      if (Array.isArray(value.raw)) return value.rows();
    }
    return [];
  }
  fields(): Record<string, Object | null> {
    if (this.raw === null || typeof this.raw !== 'object' || Array.isArray(this.raw)) return {};
    return this.raw as Record<string, Object | null>;
  }
  json(): string { return JSON.stringify(this.raw); }
}

export class ApiError extends Error {
  code: number;
  constructor(message: string, code: number = 0) { super(message); this.name = 'ApiError'; this.code = code; }
}

export function unwrap(body: string, status: number): DataValue {
  let root: DataValue;
  try { root = DataValue.parse(body); } catch (_) { throw new ApiError('服务响应格式不正确', status); }
  const code = root.value('code', String(status));
  const message = root.value('message', root.value('msg', '请求失败'));
  if (status < 200 || status >= 300) throw new ApiError(message, status);
  const success = root.get('success');
  if ((success.raw !== null && !success.flag()) || !['0', '200', 'OK', 'SUCCESS'].includes(code.toUpperCase())) {
    throw new ApiError(message, Number(code));
  }
  return root.get('data');
}

export function errorText(error: Error): string { return error.message || '请求失败，请稍后重试'; }
