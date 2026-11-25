import { allSettledLimited, request } from "../src/lib/marketReliability.js";

function assert(condition: unknown, message: string): asserts condition {
  if (!condition) throw new Error(message);
}

async function withFetch(implementation: typeof fetch, test: () => Promise<void>) {
  const original = globalThis.fetch;
  globalThis.fetch = implementation;
  try { await test(); } finally { globalThis.fetch = original; }
}

const response = (status: number, body: unknown, headers: Record<string, string> = {}) =>
  new Response(JSON.stringify(body), { status, headers: { "Content-Type": "application/json", ...headers } });

await withFetch(async () => response(503, { code: "busy" }), async () => {
  // A transient service error is retried twice at most; this fake always fails.
  let attempts = 0;
  globalThis.fetch = async (_input, _init) => { attempts += 1; return response(503, {}); };
  await request("/test", new AbortController().signal).then(
    () => { throw new Error("503 request unexpectedly succeeded"); },
    () => undefined,
  );
  assert(attempts === 3, `expected 3 total attempts for 503, got ${attempts}`);
});

await withFetch(async () => response(400, { code: "bad" }), async () => {
  let attempts = 0;
  globalThis.fetch = async () => { attempts += 1; return response(400, {}); };
  await request("/test", new AbortController().signal).catch(() => undefined);
  assert(attempts === 1, `non-retryable 4xx should make one attempt, got ${attempts}`);
});

await withFetch(async () => response(429, {}, { "Retry-After": "0" }), async () => {
  let attempts = 0;
  globalThis.fetch = async () => { attempts += 1; return attempts === 1 ? response(429, {}, { "Retry-After": "0" }) : response(200, { ok: true }); };
  const result = await request<{ ok: boolean }>("/test", new AbortController().signal);
  assert(result.ok && attempts === 2, "429 should respect Retry-After and retry successfully");
});

await withFetch(async (_input, init) => new Promise<Response>((_resolve, reject) => {
  init?.signal?.addEventListener("abort", () => reject(new DOMException("aborted", "AbortError")), { once: true });
}), async () => {
  const controller = new AbortController();
  const pending = request("/test", controller.signal).then(
    () => { throw new Error("aborted request unexpectedly succeeded"); },
    (error: unknown) => error,
  );
  setTimeout(() => controller.abort(), 10);
  const error = await pending;
  assert(error instanceof DOMException && error.name === "AbortError", "parent abort must stop retries immediately");
});

let active = 0;
let maximum = 0;
const results = await allSettledLimited(
  Array.from({ length: 9 }, (_, index) => async () => {
    active += 1;
    maximum = Math.max(maximum, active);
    await new Promise((resolve) => setTimeout(resolve, (8 - index) % 4));
    active -= 1;
    return index;
  }),
  3,
);
assert(maximum <= 3, `K-line worker pool exceeded concurrency 3: ${maximum}`);
assert(results.every((result, index) => result.status === "fulfilled" && result.value === index), "limited settlement preserves source ordering");

console.log("network reliability: retries, abort, 4xx behavior and concurrency checks passed");
