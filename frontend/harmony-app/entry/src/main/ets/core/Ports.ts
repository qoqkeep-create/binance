export interface HttpRequest {
  url: string;
  method: string;
  headers: Record<string, string>;
  body: string;
}
export interface HttpResponse {
  status: number;
  body: string;
  cookies: string[];
}
export interface Transport { send(request: HttpRequest): Promise<HttpResponse>; }
export interface Vault {
  read(key: string): Promise<string>;
  write(key: string, value: string): Promise<void>;
  remove(key: string): Promise<void>;
}
export interface PreferenceStore {
  read(key: string, fallback: string): string;
  write(key: string, value: string): void;
}
export interface RuntimeClock { now(): number; delay(ms: number): Promise<void>; id(): string; }
export interface SocketCallbacks {
  opened(): void;
  message(data: string): void;
  closed(code: number): void;
}
export interface SocketPort {
  connect(url: string, headers: Record<string, string>, callbacks: SocketCallbacks): void;
  send(value: string): void;
  close(): void;
}
export interface ChangeListener { changed(): void; }
