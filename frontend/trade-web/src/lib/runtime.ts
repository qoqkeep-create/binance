/** Resolve the integrated API beside the Vite app, including /integrated deployments. */
function appPrefix(): string {
  if (typeof window === "undefined") return "";
  const configured = (import.meta as ImportMeta & { env?: Record<string, string | undefined> }).env?.VITE_API_BASE_URL;
  if (configured) return configured.replace(/\/$/, "").replace(/\/api$/, "");
  const marker = "/market/";
  const index = window.location.pathname.indexOf(marker);
  return index >= 0 ? window.location.pathname.slice(0, index) : "";
}

export function apiPath(path: string): string {
  return `${appPrefix()}/api${path}`;
}

export function v1Path(path: string): string {
  return `${appPrefix()}/v1${path}`;
}

export function websocketPath(): string {
  if (typeof window === "undefined") return "ws://localhost/ws/v1";
  const configured = (import.meta as ImportMeta & { env?: Record<string, string | undefined> }).env?.VITE_WS_URL;
  if (configured) return configured;
  const protocol = window.location.protocol === "https:" ? "wss:" : "ws:";
  return `${protocol}//${window.location.host}${appPrefix()}/ws/v1`;
}
