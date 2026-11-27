import { accountApi, getAccessToken } from "./account.js";
import { apiPath, v1Path } from "./runtime.js";

interface Envelope<T> { code: number; message?: string; data: T }

async function request<T>(url: string, init: RequestInit = {}, retry = true): Promise<T> {
  const headers = new Headers(init.headers);
  headers.set("accept", "application/json");
  // 契约要求显式模式头；web 仅普通合约（带单入口未开放）。
  headers.set("X-Trading-Mode", "ordinary");
  const token = getAccessToken();
  if (token) headers.set("Authorization", `Bearer ${token}`);
  const response = await fetch(url, { ...init, headers, credentials: "include", signal: init.signal ?? AbortSignal.timeout(15_000) });
  if (response.status === 401 && retry) {
    try { await accountApi.session(init.signal ?? undefined); return request<T>(url, init, false); } catch { /* fall through */ }
  }
  let payload: unknown;
  try { payload = await response.json(); } catch { throw new Error(`服务 ${response.status}`); }
  if (!response.ok || !payload || typeof payload !== "object" || (payload as Envelope<unknown>).code !== 200) {
    const message = payload && typeof payload === "object" && typeof (payload as { message?: unknown }).message === "string" ? (payload as { message: string }).message : `服务 ${response.status}`;
    throw new Error(message);
  }
  return (payload as Envelope<T>).data;
}

const get = <T>(path: string, signal?: AbortSignal) => request<T>(v1Path(path), { signal });
const post = <T>(path: string, body: unknown, headers?: Record<string, string>) =>
  request<T>(v1Path(path), { method: "POST", headers: { "Content-Type": "application/json", ...headers }, body: JSON.stringify(body) });

export interface PositionStrategyLevel { profitRR: number; reducePosition: number; stopLossType: string; stopLossRR: number | null; stopLossAbsoluteRR: number | null }
export interface PositionRow {
  id: number; symbol: string; side: number | string; leverage: number; position_amount: number | string;
  margin: number | string; pnl: number | string; pnl_ratio: number | string; open_price: number | string;
  current_price: number | string; market_stop_price: number | string | null; manual_take_profit_price: number | string | null;
  estimated_total_fee: number | string; position_origin: string; opened_at: string; strategy_status?: number;
  strategy_name?: string; strategy_config?: PositionStrategyLevel[] | null;
}
export interface MarginInfo {
  margin_ratio_percent: number | string; liquidation_reached: boolean;
  wallet_balance: number | string; margin_balance: number | string; available_balance: number | string;
}
export interface HistoryRow {
  id: number; symbol: string; side: number | string; pnl: number | string; pnl_ratio: number | string;
  open_price: number | string; close_price: number | string; position_amount: number | string;
  fee: number | string; funding_fee: number | string; opened_at: string; closed_at: string; settlement_status?: string;
}
export interface OrderRow {
  id: number; symbol: string; side: number | string; status_text: string; kind: string; leverage: number;
  price: number | string; stop_price: number | string; amount: number | string; filled_amount: number | string;
  filled_qty: number | string; avg_price: number | string; can_cancel: boolean; can_chase: boolean; created_at: string;
}
export interface AccountInfo {
  balance: number | string; total_balance: number | string; spot_balance: number | string; funding_balance: number | string;
  today_pnl: number | string; stop_loss_amount: number | string;
}
export interface Profile { bound: boolean; display_name: string; position_mode: string; avatar_url: string | null; email?: string; username?: string }
export interface ApiInfo { alias: string; status: number; api_key_masked: string }

// 后端 side 为整数 0=多 1=空；交易所字符串 BUY/SELL、long/short 并存，统一判定。
export const isLongSide = (side: number | string) => ["0", "long", "buy"].includes(String(side).toLowerCase());

export const tradeApi = {
  positions: (signal?: AbortSignal) => get<PositionRow[]>("/position/list", signal),
  margin: (signal?: AbortSignal) => get<MarginInfo>("/position/margin?fresh=1", signal),
  history: (filter: string, page: number, signal?: AbortSignal) =>
    get<{ items: HistoryRow[]; pagination: { page: number; page_size: number; total: number; has_more: boolean } }>(`/position/history?filter=${filter}&page=${page}&page_size=20`, signal),
  orders: (page: number, signal?: AbortSignal) =>
    get<{ items: OrderRow[]; pagination: { page: number; page_size: number; total: number; has_more: boolean } }>(`/trade/order/list?page=${page}&page_size=20`, signal),
  accountInfo: (fresh: boolean, signal?: AbortSignal) => get<AccountInfo>(`/account/info${fresh ? "?fresh=1" : ""}`, signal),
  profile: (signal?: AbortSignal) => get<Profile>("/account/profile", signal),
  apiInfo: (signal?: AbortSignal) => get<ApiInfo>("/api/info", signal),
  setStopLoss: (amount: number) => post<unknown>("/account/stop-loss", { amount: String(amount) }),
  getStopLoss: (signal?: AbortSignal) => get<{ current_amount: string; pending_amount: string | null; pending_from_amount: string | null; pending_effective_at: string | null; countdown_seconds: number; minimum_amount: string; maximum_amount: string }>("/account/stop-loss", signal),
  cancelStopLoss: () => post<unknown>("/account/stop-loss/cancel", {}),
  strategyList: (signal?: AbortSignal) => get<Array<{ id: string; name: string; is_active: boolean; levels: unknown[] }>>("/strategy/list", signal),
  strategySave: (body: { strategy_id?: string; name: string; levels: unknown[] }) => post<unknown>("/strategy/save", body),
  strategyDelete: (strategyId: string) => post<unknown>("/strategy/delete", { strategy_id: strategyId }),
  strategySetActive: (strategyId: string) => post<unknown>("/strategy/set-active", { strategy_id: strategyId }),
  apiBind: (body: { api_key: string; secret_key: string; alias: string }) => post<unknown>("/api/bind", body),
  apiUnbind: () => post<unknown>("/api/unbind", {}),
  async submitCommand(action: string, payload: Record<string, unknown>, idempotencyKey?: string) {
    const key = idempotencyKey ?? `web-${action}-${Date.now()}-${Math.random().toString(36).slice(2, 10)}`;
    const data = await request<{ id: string; status: string }>(apiPath("/commands"), {
      method: "POST",
      headers: { "Content-Type": "application/json", "Idempotency-Key": key },
      body: JSON.stringify({ action, payload }),
    });
    return data.id;
  },
  async pollCommand(id: string, timeoutMs = 20_000) {
    const deadline = Date.now() + timeoutMs;
    while (Date.now() < deadline) {
      const data = await request<{ status: string; result?: { code?: number; message?: string } }>(apiPath(`/commands/${id}`));
      if (data.status === "SUCCEEDED" || data.status === "FAILED") return data;
      await new Promise((resolve) => setTimeout(resolve, 700));
    }
    return { status: "UNKNOWN" as const };
  },
};