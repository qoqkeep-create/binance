import { DataValue, ApiError, unwrap } from './Json';
import type { Transport, Vault, HttpResponse, HttpRequest } from './Ports';

export const DEFAULT_API = 'https://47.80.22.243/integrated/';

export function normalizeOrigin(value: string): string {
  const text = value.trim().replace(/\/+$/, '') + '/';
  if (!/^https:\/\/[A-Za-z0-9.-]+(?::\d+)?(?:\/[A-Za-z0-9_-]+)*\/$/.test(text)) {
    throw new Error('服务器地址必须为有效的 HTTPS 地址');
  }
  return text;
}

export class Session {
  baseUrl: string = DEFAULT_API;
  token: string = '';
  cookie: string = '';
  user: DataValue = new DataValue();
  mode: string = 'ordinary';
  generation: number = 0;
  bindingIdentity: string = '';
  private refreshFlight: Promise<void> | null = null;
  private transport: Transport;
  private vault: Vault;
  constructor(transport: Transport, vault: Vault) { this.transport = transport; this.vault = vault; }
  get authenticated(): boolean { return this.token !== '' && this.user.value('id', '') !== ''; }
  get scope(): string { return this.baseUrl + ':' + this.user.value('id', '') + ':' + this.mode + ':' + this.generation; }
  async restore(origin: string): Promise<void> {
    this.baseUrl = normalizeOrigin(origin); const generation = ++this.generation;
    const saved = await this.vault.read('session');
    if (!saved || generation !== this.generation) return;
    const value = DataValue.parse(saved);
    if (value.value('origin', '') !== this.baseUrl) return;
    this.token = value.value('token', ''); this.cookie = value.value('cookie', ''); this.user = value.get('user');
    try { const user = await this.request('/api/auth/me'); this.ensureGeneration(generation); this.user = user; }
    catch (e) { if (generation === this.generation && (e as ApiError).code === 401) await this.clear(); else throw e; }
  }
  private ensureGeneration(value: number): void { if (value !== this.generation) throw new ApiError('会话已切换', -1); }
  private async save(generation: number): Promise<void> {
    this.ensureGeneration(generation);
    await this.vault.write('session', DataValue.object({ origin: this.baseUrl, token: this.token, cookie: this.cookie, user: this.user.raw }).json());
  }
  private captureCookies(response: HttpResponse): void {
    const current: Record<string, string> = {};
    for (const part of this.cookie.split('; ')) { const i = part.indexOf('='); if (i > 0) current[part.slice(0, i)] = part.slice(i + 1); }
    for (const header of response.cookies) {
      const pair = header.split(';')[0]; const i = pair.indexOf('=');
      if (i > 0) current[pair.slice(0, i).trim()] = pair.slice(i + 1);
    }
    this.cookie = Object.keys(current).filter((key: string) => current[key] !== '').map((key: string) => key + '=' + current[key]).join('; ');
  }
  async authenticate(account: string, password: string, register: boolean): Promise<void> {
    if (!account.trim() || password.length < 6) throw new Error('请输入账号和至少六位密码');
    const generation = ++this.generation;
    this.token = ''; this.cookie = ''; this.user = new DataValue(); this.bindingIdentity = '';
    await this.vault.remove('session'); this.ensureGeneration(generation);
    const payload = DataValue.object({ account: account.trim(), password: password, confirm_password: password, agreed: true });
    const response = await this.raw('/api/auth/' + (register ? 'register' : 'login'), 'POST', payload, {}, false);
    this.ensureGeneration(generation);
    const value = unwrap(response.body, response.status);
    this.token = value.value('accessToken', ''); this.user = value.get('user'); this.captureCookies(response);
    if (!this.authenticated) throw new Error('登录响应缺少身份信息');
    try { await this.save(generation); } catch (e) { if (generation === this.generation) { this.token = ''; this.cookie = ''; this.user = new DataValue(); } throw e; }
  }
  async clear(): Promise<void> {
    this.generation++; this.token = ''; this.cookie = ''; this.user = new DataValue(); this.bindingIdentity = ''; this.refreshFlight = null;
    await this.vault.remove('session');
  }
  async logout(): Promise<void> {
    const outgoing = this.raw('/api/auth/logout', 'POST', DataValue.object(), {}, true);
    await this.clear();
    try { await outgoing; } catch (_) { /* Local identity has already been removed. */ }
  }
  setMode(value: string): void {
    if (!['ordinary', 'lead'].includes(value) || this.mode === value) return;
    this.mode = value; this.bindingIdentity = ''; this.generation++;
  }
  async observeBinding(binding: DataValue, force: boolean = false): Promise<boolean> {
    const scope = this.scope;
    const key = this.baseUrl + ':' + this.user.value('id') + ':' + this.mode;
    const saved = await this.vault.read('binding-epochs');
    if (scope !== this.scope) throw new ApiError('账户已切换', -1);
    const records = saved ? DataValue.parse(saved).fields() : {};
    const previous = new DataValue(records[key] || null);
    const alias = binding.empty() ? '' : binding.value('alias', '');
    let epoch = previous.get('epoch').number();
    if (force || alias !== previous.value('alias', '')) {
      epoch++;
      records[key] = DataValue.object({ alias: alias, epoch: epoch }).raw;
      await this.vault.write('binding-epochs', DataValue.object(records).json());
      if (scope !== this.scope) throw new ApiError('账户已切换', -1);
    }
    const identity = binding.empty() ? 'unbound' : 'bound:' + alias + ':' + epoch;
    if (identity === this.bindingIdentity) return false;
    if (this.bindingIdentity !== '') this.generation++;
    this.bindingIdentity = identity;
    return true;
  }
  private raw(path: string, method: string, payload: DataValue, extra: Record<string, string>, authenticated: boolean): Promise<HttpResponse> {
    if (!path.startsWith('/') || path.startsWith('//')) throw new Error('请求路径不正确');
    const headers: Record<string, string> = { 'Content-Type': 'application/json', 'Accept': 'application/json', 'X-Platform': 'harmony', 'X-Trading-Mode': this.mode };
    if (authenticated && this.token) headers['Authorization'] = 'Bearer ' + this.token;
    if (this.cookie) headers['Cookie'] = this.cookie;
    for (const key of Object.keys(extra)) headers[key] = extra[key];
    const request: HttpRequest = { url: this.baseUrl + path.slice(1), method: method, body: method === 'GET' ? '' : payload.json(), headers: headers };
    return this.transport.send(request);
  }
  async refresh(): Promise<void> {
    if (this.refreshFlight) return this.refreshFlight;
    const generation = this.generation;
    const flight = this.performRefresh(generation); this.refreshFlight = flight;
    try { await flight; } catch (e) { if (generation === this.generation && (e as ApiError).code === 401) await this.clear(); throw e; } finally { if (this.refreshFlight === flight) this.refreshFlight = null; }
  }
  private async performRefresh(generation: number): Promise<void> {
    const response = await this.raw('/api/auth/refresh', 'POST', DataValue.object(), {}, false);
    this.ensureGeneration(generation);
    const value = unwrap(response.body, response.status);
    const token = value.value('accessToken', ''); if (!token) throw new ApiError('登录已失效', 401);
    this.token = token; this.captureCookies(response); await this.save(generation);
  }
  async request(path: string, method: string = 'GET', payload: DataValue = DataValue.object(), extra: Record<string, string> = {}, authenticated: boolean = true): Promise<DataValue> {
    const scope = this.scope; const token = this.token;
    let response = await this.raw(path, method, payload, extra, authenticated);
    if (scope !== this.scope) throw new ApiError('账户已切换，已忽略旧响应', -1);
    if (response.status === 401 && authenticated) {
      if (token === this.token) await this.refresh();
      if (scope !== this.scope) throw new ApiError('账户已切换', -1);
      response = await this.raw(path, method, payload, extra, authenticated);
    }
    if (scope !== this.scope) throw new ApiError('账户已切换，已忽略旧响应', -1);
    return unwrap(response.body, response.status);
  }
}
