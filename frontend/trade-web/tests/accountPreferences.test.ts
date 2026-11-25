import { acknowledgePreferencePatch, mergePreferenceSettings, preferencePatch, sanitizeSettings } from "../src/lib/account.js";

function equal(actual: unknown, expected: unknown, message: string) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${message}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

const local = preferencePatch("chart", { interval: "15", timeFrame: "2d" }, { interval: "240", timeFrame: "2d" });
equal(local, { chart: { interval: "240" } }, "changing interval does not dirty unchanged chart fields");
equal(preferencePatch("chart", { interval: "15" }, { interval: "15" }), {}, "unchanged defaults produce no patch");
equal(mergePreferenceSettings({ theme: "light", chart: { interval: "15", timeFrame: "1y" } }, local),
  { theme: "light", chart: { interval: "240", timeFrame: "1y" } }, "conflict retry preserves remote timeFrame and unrelated keys");
equal(mergePreferenceSettings({ chart: { interval: "240" } }, { chart: { timeFrame: "6M" } }),
  { chart: { interval: "240", timeFrame: "6M" } }, "pending chart changes coalesce without replacing previous fields");
equal(acknowledgePreferencePatch({ theme: "dark", chart: { interval: "60", timeFrame: "6M" } }, { theme: "dark", chart: { interval: "240" } }),
  { chart: { interval: "60", timeFrame: "6M" } }, "an in-flight acknowledgment retains newer chart values");
equal(acknowledgePreferencePatch({ chart: { interval: "240", timeFrame: "6M" } }, { chart: { interval: "240" } }),
  { chart: { timeFrame: "6M" } }, "acknowledgment clears only fields sent by the request");
equal(acknowledgePreferencePatch({ marketQuery: "SOL", chart: { interval: "60" } }, { marketQuery: "SOL", chart: { interval: "60" } }), {}, "successful write drains matching pending fields");
equal(sanitizeSettings({ theme: "dark", userId: "other", session: "secret", password: "private" }), { theme: "dark" }, "only preference keys are accepted");
console.log("Account preference merge tests passed");
