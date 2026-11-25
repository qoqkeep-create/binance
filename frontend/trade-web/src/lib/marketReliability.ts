import { accountApi, getAccessToken } from "./account.js";
import { apiPath } from "./runtime.js";

const restBase = "";
const REQUEST_ATTEMPTS = 3;
const REQUEST_TIMEOUT_MS = 20_000;
const RETRY_DELAYS_MS = [500, 1_000];

function retryAfterMs(response: Response): number | null {
  const value = response.headers.get("Retry-After");
  if (!value) return null;
  const seconds = Number(value);
  if (Number.isFinite(seconds) && seconds >= 0) return seconds * 1_000;
  const date = Date.parse(value);
  return Number.isFinite(date) ? Math.max(0, date - Date.now()) : null;
}

function abortError() {
  return new DOMException("请求已取消", "AbortError");
}

class HttpRequestError extends Error {
  constructor(readonly status: number) {
    super(`行情服务 ${status}`);
    this.name = "HttpRequestError";
  }
}

function retryableStatus(status: number) {
  return status === 408 || status === 425 || status === 429 || status >= 500;
}

function sleepWithAbort(delayMs: number, signal: AbortSignal): Promise<void> {
  if (signal.aborted) return Promise.reject(abortError());
  return new Promise((resolve, reject) => {
    const abort = () => {
      globalThis.clearTimeout(timer);
      reject(abortError());
    };
    const timer = globalThis.setTimeout(() => {
      signal.removeEventListener("abort", abort);
      resolve();
    }, delayMs);
    signal.addEventListener("abort", abort, { once: true });
  });
}

/** Public for deterministic request lifecycle tests; app code should use the hook. */
export async function request<T>(path: string, parentSignal: AbortSignal): Promise<T> {
  let lastError: unknown;
  for (let attempt = 0; attempt < REQUEST_ATTEMPTS; attempt += 1) {
    if (parentSignal.aborted) throw abortError();
    const controller = new AbortController();
    const abort = () => controller.abort();
    parentSignal.addEventListener("abort", abort, { once: true });
    const timeout = globalThis.setTimeout(() => controller.abort(), REQUEST_TIMEOUT_MS);
    let waitMs: number | null = null;
    try {
      const headers: Record<string, string> = { accept: "application/json" };
      const token = getAccessToken();
      if (token) headers.Authorization = `Bearer ${token}`;
      const response = await fetch(`${restBase}${apiPath(path.replace(/^\/api/, ""))}`, { signal: controller.signal, headers, credentials: "include" });
      if (response.ok) {
        const payload = await response.json() as unknown;
        if (payload && typeof payload === "object" && "code" in payload && (payload as { code?: unknown }).code === 200 && "data" in payload) return (payload as { data: T }).data;
        return payload as T;
      }
      if (response.status === 401 && attempt === 0) {
        try { await accountApi.session(parentSignal); await sleepWithAbort(0, parentSignal); continue; } catch { /* handled by normal retry rules */ }
      }
      const retryable = retryableStatus(response.status);
      if (!retryable || attempt === REQUEST_ATTEMPTS - 1) throw new HttpRequestError(response.status);
      waitMs = retryAfterMs(response) ?? RETRY_DELAYS_MS[attempt];
      lastError = new HttpRequestError(response.status);
    } catch (error) {
      if (parentSignal.aborted) throw abortError();
      if (error instanceof HttpRequestError && !retryableStatus(error.status)) throw error;
      lastError = error;
      if (attempt === REQUEST_ATTEMPTS - 1) throw error;
      waitMs ??= RETRY_DELAYS_MS[attempt];
    } finally {
      globalThis.clearTimeout(timeout);
      parentSignal.removeEventListener("abort", abort);
    }
    await sleepWithAbort(waitMs ?? RETRY_DELAYS_MS[attempt], parentSignal);
  }
  throw lastError instanceof Error ? lastError : new Error("行情请求失败");
}

/** Preserve source ordering while keeping market-history concurrency bounded. */
export async function allSettledLimited<T>(tasks: Array<() => Promise<T>>, limit: number): Promise<PromiseSettledResult<T>[]> {
  const results: PromiseSettledResult<T>[] = new Array(tasks.length);
  let next = 0;
  async function worker() {
    while (true) {
      const index = next;
      next += 1;
      if (index >= tasks.length) return;
      try {
        results[index] = { status: "fulfilled", value: await tasks[index]() };
      } catch (reason) {
        results[index] = { status: "rejected", reason };
      }
    }
  }
  await Promise.all(Array.from({ length: Math.min(Math.max(1, limit), tasks.length) }, () => worker()));
  return results;
}
