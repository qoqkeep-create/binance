/** Exact base-10 arithmetic without IEEE-754 money or platform-specific BigInt. */
function clean(value: string): string { return value.replace(/^0+(?=\d)/, '') || '0'; }
function cmp(a: string, b: string): number {
  a = clean(a); b = clean(b);
  return a.length !== b.length ? (a.length > b.length ? 1 : -1) : a === b ? 0 : a > b ? 1 : -1;
}
function plus(a: string, b: string): string {
  let result = ''; let carry = 0;
  for (let i = 0; i < Math.max(a.length, b.length); i++) {
    const n = Number(a.charAt(a.length - 1 - i) || '0') + Number(b.charAt(b.length - 1 - i) || '0') + carry;
    result = String(n % 10) + result; carry = Math.floor(n / 10);
  }
  return (carry ? String(carry) : '') + result;
}
function minus(a: string, b: string): string {
  let result = ''; let borrow = 0;
  for (let i = 0; i < a.length; i++) {
    let n = Number(a.charAt(a.length - 1 - i)) - Number(b.charAt(b.length - 1 - i) || '0') - borrow;
    borrow = n < 0 ? 1 : 0; if (n < 0) n += 10; result = String(n) + result;
  }
  return clean(result);
}
function times(a: string, b: string): string {
  const cells: number[] = new Array(a.length + b.length).fill(0);
  for (let i = a.length - 1; i >= 0; i--) {
    for (let j = b.length - 1; j >= 0; j--) {
      const n = cells[i + j + 1] + Number(a[i]) * Number(b[j]);
      cells[i + j + 1] = n % 10; cells[i + j] += Math.floor(n / 10);
    }
  }
  return clean(cells.join(''));
}
function quotient(a: string, b: string): string {
  if (clean(b) === '0') throw new Error('不能除以零');
  let remainder = '0'; let result = '';
  for (const digit of a) {
    remainder = clean(remainder + digit); let n = 0;
    while (cmp(remainder, b) >= 0) { remainder = minus(remainder, b); n++; }
    result += String(n);
  }
  return clean(result);
}

export class Decimal {
  private digits: string;
  private scale: number;
  private sign: number;
  constructor(value: string) {
    const text = value.trim();
    if (!/^[+-]?\d+(\.\d+)?$/.test(text) || text.length > 160) throw new Error('请输入有效金额');
    this.sign = text[0] === '-' ? -1 : 1;
    const pieces = text.replace(/^[+-]/, '').split('.');
    this.scale = pieces.length === 2 ? pieces[1].length : 0;
    this.digits = clean(pieces.join(''));
    if (this.digits === '0') this.sign = 1;
  }
  private static make(digits: string, scale: number, sign: number): Decimal {
    const text = clean(digits).padStart(scale + 1, '0');
    return new Decimal((sign < 0 ? '-' : '') + (scale ? text.slice(0, -scale) + '.' + text.slice(-scale) : text));
  }
  compare(other: Decimal): number {
    if (this.sign !== other.sign) return this.sign > other.sign ? 1 : -1;
    const scale = Math.max(this.scale, other.scale);
    return this.sign * cmp(this.digits + '0'.repeat(scale - this.scale), other.digits + '0'.repeat(scale - other.scale));
  }
  add(other: Decimal): Decimal {
    const scale = Math.max(this.scale, other.scale);
    const a = this.digits + '0'.repeat(scale - this.scale); const b = other.digits + '0'.repeat(scale - other.scale);
    if (this.sign === other.sign) return Decimal.make(plus(a, b), scale, this.sign);
    return cmp(a, b) >= 0 ? Decimal.make(minus(a, b), scale, this.sign) : Decimal.make(minus(b, a), scale, other.sign);
  }
  subtract(other: Decimal): Decimal { return this.add(Decimal.make(other.digits, other.scale, -other.sign)); }
  multiply(other: Decimal): Decimal { return Decimal.make(times(this.digits, other.digits), this.scale + other.scale, this.sign * other.sign); }
  divide(other: Decimal, places: number = 12): Decimal {
    if (places < 0 || places > 32) throw new Error('精度不正确');
    return Decimal.make(quotient(this.digits + '0'.repeat(other.scale + places), other.digits + '0'.repeat(this.scale)), places, this.sign * other.sign);
  }
  abs(): Decimal { return Decimal.make(this.digits, this.scale, 1); }
  positive(): boolean { return this.compare(new Decimal('0')) > 0; }
  fixed(places: number = 2): string {
    if (places < 0 || places > 32) throw new Error('精度不正确');
    let digits = this.digits;
    if (this.scale > places) {
      const padded = digits.padStart(this.scale + 1, '0');
      const cut = padded.length - this.scale + places;
      digits = padded.slice(0, cut);
      if (Number(padded[cut]) >= 5) digits = plus(digits, '1');
    } else digits += '0'.repeat(places - this.scale);
    digits = clean(digits).padStart(places + 1, '0');
    return (this.sign < 0 && clean(digits) !== '0' ? '-' : '') + (places ? digits.slice(0, -places) + '.' + digits.slice(-places) : digits);
  }
  toString(): string {
    const text = this.digits.padStart(this.scale + 1, '0');
    const body = this.scale ? (text.slice(0, -this.scale) + '.' + text.slice(-this.scale)).replace(/\.?0+$/, '') : text;
    return (this.sign < 0 ? '-' : '') + body;
  }
}

export function amount(text: string, places: number = 2): string {
  try { return new Decimal(text).fixed(places); } catch (_) { return '--'; }
}

export function validPositive(text: string): boolean {
  try { return new Decimal(text).positive(); } catch (_) { return false; }
}
