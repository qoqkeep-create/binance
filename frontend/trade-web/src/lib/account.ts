import { apiPath } from "./runtime.js";

export interface AccountUser {
  id: string;
  email: string | null;
  username: string;
  displayName: string;
  role: "user" | "guest";
}

export interface AccountSession {
  user: AccountUser | null;
  csrfToken: string | null;
}

export type AccountSettings = Record<string, unknown>;
export interface SettingsResponse {
  settings: AccountSettings;
  version: number;
  updatedAt: string | number | null;
}

export const preferenceKeys = ["theme", "activeNav", "marketGroup", "selectedSymbol", "marketQuery", "showInsightPanel", "assistantTopInterval", "chart"] as const;

export class AccountApiError extends Error {
  readonly status: number;
  readonly data: Record<string, unknown>;

  constructor(status: number, data: Record<string, unknown>) {
    super(typeof data.message === "string" ? data.message : status === 429 ? "操作较频繁，请稍后再试。" : "账户服务暂时不可用，请重试。");
    this.name = "AccountApiError";
    this.status = status;
    this.data = data;
  }
}

export function sanitizeSettings(value: unknown): AccountSettings {
  if (!value || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(preferenceKeys.filter((key) => Object.prototype.hasOwnProperty.call(value, key))
    .map((key) => [key, (value as AccountSettings)[key]]));
}

export function isPreferenceObject(value: unknown): value is Record<string, unknown> {
  return !!value && typeof value === "object" && !Array.isArray(value);
}

/** Chart fields are independent preferences, so another device's field survives. */
export function mergePreferenceSettings(base: AccountSettings, patch: AccountSettings): AccountSettings {
  const merged = { ...base, ...patch };
  if (isPreferenceObject(base.chart) && isPreferenceObject(patch.chart)) merged.chart = { ...base.chart, ...patch.chart };
  return merged;
}

export function preferencePatch(key: string, previous: unknown, next: unknown): AccountSettings {
  if (key !== "chart" || !isPreferenceObject(next)) return { [key]: next };
  const prior = isPreferenceObject(previous) ? previous : {};
  const changed = Object.fromEntries(Object.entries(next).filter(([field, value]) => value !== undefined && JSON.stringify(value) !== JSON.stringify(prior[field])));
  return Object.keys(changed).length ? { chart: changed } : {};
}

/** Only clear values still equal to the request; newer local edits remain dirty. */
export function acknowledgePreferencePatch(pending: AccountSettings, sent: AccountSettings): AccountSettings {
  const remaining = { ...pending };
  for (const [key, value] of Object.entries(sent)) {
    if (key === "chart" && isPreferenceObject(value) && isPreferenceObject(remaining.chart)) {
      const chart = { ...remaining.chart };
      for (const [field, setting] of Object.entries(value)) if (JSON.stringify(chart[field]) === JSON.stringify(setting)) delete chart[field];
      if (Object.keys(chart).length) remaining.chart = chart;
      else delete remaining.chart;
    } else if (JSON.stringify(remaining[key]) === JSON.stringify(value)) delete remaining[key];
  }
  return remaining;
}

const ACCESS_TOKEN_KEY = "trade-web.access-token";
let accessToken: string | null = null;
try { accessToken = window.localStorage.getItem(ACCESS_TOKEN_KEY); } catch { /* storage can be unavailable in private contexts */ }

function setAccessToken(token: string | null) {
  accessToken = token;
  try {
    if (token) window.localStorage.setItem(ACCESS_TOKEN_KEY, token);
    else window.localStorage.removeItem(ACCESS_TOKEN_KEY);
  } catch { /* an in-memory session remains usable when storage is blocked */ }
}

export function getAccessToken() { return accessToken; }

type RequestOptions = { method?: string; body?: unknown; csrfToken?: string | null; signal?: AbortSignal; retryAuth?: boolean };

function apiUrl(path: string) {
  return apiPath(path);
}

function envelope<T>(value: unknown, status: number): T {
  if (!value || typeof value !== "object") throw new AccountApiError(status, { message: "服务返回异常，请稍后重试。" });
  const response = value as { code?: unknown; message?: unknown; data?: unknown };
  if (response.code !== 200) {
    throw new AccountApiError(status, {
      message: typeof response.message === "string" ? response.message : "账户服务暂时不可用，请重试。",
      code: response.code,
      data: response.data,
    });
  }
  return response.data as T;
}

function normalizeUser(value: unknown): AccountUser {
  if (!value || typeof value !== "object") throw new AccountApiError(502, { message: "账户返回异常，请重新登录。" });
  const item = value as Record<string, unknown>;
  const email = typeof item.email === "string" ? item.email : null;
  const displayName = typeof item.displayName === "string" && item.displayName ? item.displayName : email?.split("@")[0] ?? "账户";
  const username = typeof item.username === "string" && item.username ? item.username : email?.split("@")[0] ?? String(item.id ?? "user");
  if (typeof item.id !== "string" || !item.id) throw new AccountApiError(502, { message: "账户返回异常，请重新登录。" });
  return { id: item.id, email, username, displayName, role: item.role === "guest" ? "guest" : "user" };
}

function sessionPayload(value: unknown, status: number): AccountSession {
  if (!value || typeof value !== "object") throw new AccountApiError(status, { message: "账户返回异常，请重新登录。" });
  const data = value as { accessToken?: unknown; user?: unknown };
  const token = typeof data?.accessToken === "string" && data.accessToken ? data.accessToken : null;
  if (token) setAccessToken(token);
  if (!data?.user) return { user: null, csrfToken: token };
  return { user: normalizeUser(data.user), csrfToken: token ?? accessToken };
}

async function refreshToken(signal?: AbortSignal): Promise<string> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  signal?.addEventListener("abort", abort, { once: true });
  try {
    const response = await fetch(apiUrl("/auth/refresh"), {
      method: "POST", credentials: "include", cache: "no-store", signal: controller.signal,
      headers: { Accept: "application/json", "Content-Type": "application/json" }, body: "{}",
    });
    let data: unknown;
    try { data = await response.json(); } catch { throw new AccountApiError(response.status, {}); }
    const payload = envelope<{ accessToken?: unknown }>(data, response.status);
    if (typeof payload?.accessToken !== "string" || !payload.accessToken) throw new AccountApiError(401, { message: "登录状态已过期，请重新登录。" });
    setAccessToken(payload.accessToken);
    return payload.accessToken;
  } finally { signal?.removeEventListener("abort", abort); }
}

async function request<T>(path: string, options: RequestOptions = {}): Promise<T> {
  const controller = new AbortController();
  const abort = () => controller.abort();
  options.signal?.addEventListener("abort", abort, { once: true });
  if (options.signal?.aborted) controller.abort();
  const timeout = window.setTimeout(abort, 12000);
  try {
    const headers: Record<string, string> = {
      Accept: "application/json",
      ...(options.body === undefined ? {} : { "Content-Type": "application/json" }),
      ...(options.csrfToken || accessToken ? { Authorization: `Bearer ${options.csrfToken || accessToken}` } : {}),
    };
    const response = await fetch(apiUrl(path), {
      method: options.method ?? "GET",
      credentials: "include",
      cache: "no-store",
      signal: controller.signal,
      headers,
      ...(options.body === undefined ? {} : { body: JSON.stringify(options.body) }),
    });
    if (response.status === 204) return undefined as T;
    let data: unknown;
    try { data = await response.json(); } catch { throw new AccountApiError(response.status, { message: "账户服务返回异常，请稍后重试。" }); }
    if (response.status === 401 && options.retryAuth !== false && !path.includes("/auth/refresh") && !path.includes("/auth/login") && !path.includes("/auth/register") && !path.includes("/auth/logout")) {
      try {
        const token = await refreshToken(options.signal);
        return request<T>(path, { ...options, csrfToken: token, retryAuth: false });
      } catch (error) {
        setAccessToken(null);
        throw error;
      }
    }
    if (!response.ok) {
      if (data && typeof data === "object" && "message" in data) throw new AccountApiError(response.status, data as Record<string, unknown>);
      throw new AccountApiError(response.status, { message: "账户服务暂时不可用，请重试。" });
    }
    return envelope<T>(data, response.status);
  } finally {
    window.clearTimeout(timeout);
    options.signal?.removeEventListener("abort", abort);
  }
}

function parseSettings(value: SettingsResponse): SettingsResponse {
  if (!value || !Number.isSafeInteger(value.version) || value.version < 0 || !value.settings || typeof value.settings !== "object" || Array.isArray(value.settings)) {
    throw new AccountApiError(502, { message: "云端设置返回异常，请重试同步。" });
  }
  return { settings: sanitizeSettings(value.settings), version: value.version, updatedAt: value.updatedAt ?? null };
}

export const accountApi = {
  session: async (signal?: AbortSignal): Promise<AccountSession> => {
    if (!accessToken) return { user: null, csrfToken: null };
    try {
      const data = await request<{ user?: unknown }>("/auth/me", { signal });
      return { user: normalizeUser(data?.user ?? data), csrfToken: accessToken };
    } catch (error) {
      if (error instanceof AccountApiError && error.status === 401) setAccessToken(null);
      throw error;
    }
  },
  login: async (identifier: string, password: string, _csrfToken?: string | null, signal?: AbortSignal) => sessionPayload(await request("/auth/login", { method: "POST", body: { account: identifier, password, agreed: true }, signal, retryAuth: false }), 200),
  register: async (body: { email: string; password: string; displayName?: string }, _csrfToken?: string | null, signal?: AbortSignal) => sessionPayload(await request("/auth/register", { method: "POST", body: { account: body.email, password: body.password, confirm_password: body.password, agreed: true }, signal, retryAuth: false }), 201),
  logout: async (_csrfToken: string | null, signal?: AbortSignal) => { try { await request<void>("/auth/logout", { method: "POST", body: {}, signal, retryAuth: false }); } finally { setAccessToken(null); } },
  settings: async (signal?: AbortSignal) => {
    const data = await request<SettingsResponse>("/web/settings", { signal });
    return parseSettings(data);
  },
  saveSettings: async (patch: AccountSettings, baseVersion: number, csrfToken: string, signal?: AbortSignal) => parseSettings(await request<SettingsResponse>("/web/settings", { method: "PATCH", body: { patch, baseVersion }, csrfToken, signal })),
};
