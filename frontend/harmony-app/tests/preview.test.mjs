import test from 'node:test';
import assert from 'node:assert/strict';
import { PreviewTransport, PreviewVault, PreviewPreferences } from './fixtures/PreviewPorts.ts';

test('offline UI preview rejects external origins and all account/trading/capital writes', async () => {
  const transport = new PreviewTransport();
  await assert.rejects(transport.send({ url: 'https://real.example.invalid/v1/account/info', method: 'GET', body: '', headers: {} }), /external origins/);
  for (const path of ['api/auth/login', 'v1/auth/password-reset/request', 'api/commands', 'v1/trade/capital/normalize', 'v1/api/bind']) {
    await assert.rejects(transport.send({ url: 'https://preview.example.invalid/' + path, method: 'POST', body: '{}', headers: {} }), /禁止/);
  }
  const result = await transport.send({ url: 'https://preview.example.invalid/api/market/symbols', method: 'GET', body: '', headers: {} });
  assert.ok(JSON.parse(result.body).data.symbols.includes('NEWUSDT'));
});
test('preview storage is ephemeral and cannot persist fake credentials or preferences into another runtime', async () => {
  const first = new PreviewVault(); const second = new PreviewVault();
  await first.write('private-ui-value', 'fixture-only');
  assert.equal(await second.read('private-ui-value'), '');
  const prefs = new PreviewPreferences(); prefs.write('fixture-pref', 'one');
  assert.equal(new PreviewPreferences().read('fixture-pref', 'absent'), 'absent');
});

test('chart fixture permits only local EMA/precheck simulations and still blocks command/transfer writes', async () => {
  for (const scene of ['chart', 'chart-held', 'chart-error']) {
    const transport = new PreviewTransport(scene);
    for (const path of ['v1/trade/ema-check', 'v1/trade/capital/precheck']) {
      const result = await transport.send({ url: 'https://preview.example.invalid/' + path, method: 'POST', body: '{"stop_loss_price":"90"}', headers: {} });
      assert.equal(result.status,200);
    }
    for (const path of ['api/commands', 'v1/trade/open', 'v1/trade/capital/normalize', 'v1/api/bind']) await assert.rejects(transport.send({ url: 'https://preview.example.invalid/' + path, method: 'POST', body: '{}', headers: {} }), /禁止/);
    await assert.rejects(transport.send({ url: 'https://real.example.invalid/v1/trade/ema-check', method: 'POST', body: '{}', headers: {} }), /external origins/);
  }
});
