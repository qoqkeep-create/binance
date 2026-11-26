// 图表右键复制的横线价格 → 交易面板止损价粘贴，会话内共享。
let copied: string | null = null;

export function setCopiedPrice(value: string) {
  copied = value;
}

export function getCopiedPrice(): string | null {
  return copied;
}