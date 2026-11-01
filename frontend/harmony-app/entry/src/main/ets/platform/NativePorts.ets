import { http, webSocket } from '@kit.NetworkKit';
import { asset } from '@kit.AssetStoreKit';
import { cryptoFramework } from '@kit.CryptoArchitectureKit';
import { util } from '@kit.ArkTS';
import { BusinessError } from '@kit.BasicServicesKit';
import { preferences } from '@kit.ArkData';
import { common } from '@kit.AbilityKit';
import { HttpRequest, HttpResponse, Transport, Vault, PreferenceStore, RuntimeClock, SocketPort, SocketCallbacks } from '../core/Ports';
import { DataValue } from '../core/Json';

export class NativeTransport implements Transport {
  async send(request: HttpRequest): Promise<HttpResponse> {
    const client = http.createHttp();
    try {
      const result = await client.request(request.url, {
        method: request.method as http.RequestMethod, header: request.headers,
        extraData: request.method === 'GET' ? undefined : request.body,
        connectTimeout: 15000, readTimeout: 60000, usingCache: false,
        expectDataType: http.HttpDataType.STRING
      });
      const headers = new DataValue(result.header);
      const rawCookie = headers.get('set-cookie');
      let cookies = rawCookie.rows().map((v: DataValue) => v.text(''));
      if (cookies.length === 0 && rawCookie.text('')) cookies = [rawCookie.text('')];
      // Native HTTP exposes cookie pairs separately on some SDK revisions.
      if (cookies.length === 0 && result.cookies) cookies = result.cookies.split(/\r?\n/).filter((v: string) => v.includes('='));
      return { status: result.responseCode, body: result.result as string, cookies: cookies };
    } finally { client.destroy(); }
  }
}

/** Asset chunks keep each secret below 1 KiB. The manifest is committed last. */
export class AssetVault implements Vault {
  private queue: Promise<void> = Promise.resolve();
  private encoder: util.TextEncoder = new util.TextEncoder();
  private decoder: util.TextDecoder = util.TextDecoder.create('utf-8');
  private serial<T>(operation: () => Promise<T>): Promise<T> {
    const task = this.queue.then(operation);
    this.queue = task.then((): void => {}, (): void => {}); return task;
  }
  private async alias(key: string): Promise<Uint8Array> {
    const digest = cryptoFramework.createMd('SHA256'); await digest.update({ data: this.encoder.encodeInto(key) });
    const hash = await digest.digest();
    const hex = Array.from(hash.data).map((value: number) => value.toString(16).padStart(2, '0')).join('');
    return this.encoder.encodeInto('tradetools.harmony.v1.' + hex);
  }
  private async getSecret(key: string): Promise<Uint8Array | null> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>(); query.set(asset.Tag.ALIAS, await this.alias(key)); query.set(asset.Tag.RETURN_TYPE, asset.ReturnType.ALL);
    try {
      const result = await asset.query(query);
      return result.length ? result[0].get(asset.Tag.SECRET) as Uint8Array : null;
    } catch (e) { if ((e as BusinessError).code === 24000002) return null; throw new Error('无法读取安全存储，请解锁设备后重试'); }
  }
  private async putSecret(key: string, value: Uint8Array): Promise<void> {
    const attrs: asset.AssetMap = new Map<asset.Tag, asset.Value>();
    attrs.set(asset.Tag.ALIAS, await this.alias(key)); attrs.set(asset.Tag.SECRET, value);
    attrs.set(asset.Tag.ACCESSIBILITY, asset.Accessibility.DEVICE_UNLOCKED);
    attrs.set(asset.Tag.CONFLICT_RESOLUTION, asset.ConflictResolution.OVERWRITE);
    await asset.add(attrs);
  }
  private async deleteSecret(key: string): Promise<void> {
    const query: asset.AssetMap = new Map<asset.Tag, asset.Value>(); query.set(asset.Tag.ALIAS, await this.alias(key));
    try { await asset.remove(query); } catch (e) { if ((e as BusinessError).code !== 24000002) throw (e as Error); }
  }
  read(key: string): Promise<string> {
    return this.serial(async (): Promise<string> => {
      const manifestBytes = await this.getSecret(key); if (!manifestBytes) return '';
      const manifest = DataValue.parse(this.decoder.decodeWithStream(manifestBytes));
      const count = manifest.get('count').number();
      if (count < 1 || count > 256) throw new Error('安全存储清单不正确');
      const chunks: Uint8Array[] = []; let length = 0;
      for (let i = 0; i < count; i++) {
        const bytes = await this.getSecret(key + '.' + manifest.value('version') + '.' + i);
        if (!bytes) throw new Error('安全存储不完整，未恢复会话或交易请求');
        chunks.push(bytes); length += bytes.length;
      }
      const data = new Uint8Array(length); let offset = 0;
      for (const chunk of chunks) { data.set(chunk, offset); offset += chunk.length; }
      return this.decoder.decodeWithStream(data);
    });
  }
  write(key: string, value: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const bytes = this.encoder.encodeInto(value); const count = Math.max(1, Math.ceil(bytes.length / 1000));
      if (count > 256) throw new Error('安全存储空间不足，请先核对已有请求');
      const oldBytes = await this.getSecret(key); const version = util.generateRandomUUID(true);
      for (let i = 0; i < count; i++) await this.putSecret(key + '.' + version + '.' + i, bytes.slice(i * 1000, (i + 1) * 1000));
      await this.putSecret(key, this.encoder.encodeInto(JSON.stringify({ version: version, count: count })));
      if (oldBytes) {
        const old = DataValue.parse(this.decoder.decodeWithStream(oldBytes));
        for (let i = 0; i < old.get('count').number(); i++) {
          try { await this.deleteSecret(key + '.' + old.value('version') + '.' + i); } catch (_) { /* Old chunks remain inaccessible without their removed manifest. */ }
        }
      }
    });
  }
  remove(key: string): Promise<void> {
    return this.serial(async (): Promise<void> => {
      const bytes = await this.getSecret(key); await this.deleteSecret(key);
      if (!bytes) return;
      const manifest = DataValue.parse(this.decoder.decodeWithStream(bytes));
      for (let i = 0; i < manifest.get('count').number(); i++) await this.deleteSecret(key + '.' + manifest.value('version') + '.' + i);
    });
  }
}

export class NativePreferences implements PreferenceStore {
  private storage: preferences.Preferences;
  constructor(context: common.UIAbilityContext) { this.storage = preferences.getPreferencesSync(context, { name: 'tradetools-harmony' }); }
  read(key: string, fallback: string): string { return this.storage.getSync(key, fallback) as string; }
  write(key: string, value: string): void { this.storage.putSync(key, value); this.storage.flush().catch(() => {}); }
}
export class NativeClock implements RuntimeClock {
  now(): number { return Date.now(); }
  delay(ms: number): Promise<void> { return new Promise<void>((resolve: () => void) => { setTimeout(resolve, ms); }); }
  id(): string { return util.generateRandomUUID(true); }
}
export class NativeSocket implements SocketPort {
  private connection: webSocket.WebSocket | null = null;
  connect(url: string, headers: Record<string, string>, callbacks: SocketCallbacks): void {
    this.close(); const socket = webSocket.createWebSocket(); this.connection = socket;
    socket.on('open', (): void => { if (this.connection === socket) callbacks.opened(); });
    socket.on('message', (error: BusinessError, value: string | ArrayBuffer): void => {
      if (this.connection === socket && (!error || error.code === 0) && typeof value === 'string') callbacks.message(value);
    });
    socket.on('close', (error: BusinessError, value: webSocket.CloseResult): void => { if (this.connection === socket) callbacks.closed(value ? value.code : 0); });
    socket.on('error', (): void => { if (this.connection === socket) callbacks.closed(0); });
    socket.connect(url, { header: headers }).catch((): void => { if (this.connection === socket) callbacks.closed(0); });
  }
  send(value: string): void { this.connection?.send(value).catch(() => {}); }
  close(): void {
    const socket = this.connection; this.connection = null;
    if (socket) { socket.off('open'); socket.off('message'); socket.off('close'); socket.off('error'); socket.close().catch(() => {}); }
  }
}
