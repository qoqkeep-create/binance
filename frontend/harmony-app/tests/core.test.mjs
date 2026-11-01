import test from 'node:test';
import assert from 'node:assert/strict';
import { Decimal, amount, validPositive } from '../entry/src/main/ets/core/Decimal.ts';
import { DataValue, unwrap } from '../entry/src/main/ets/core/Json.ts';
import { Session, normalizeOrigin } from '../entry/src/main/ets/core/Session.ts';
import { Commands } from '../entry/src/main/ets/core/Commands.ts';
import { Candle, CandleStore, ema, rsi, mainIndicators } from '../entry/src/main/ets/core/Market.ts';

class Vault {
  values = new Map();
  async read(key) { return this.values.get(key) || ''; }
  async write(key, value) { this.values.set(key, value); }
  async remove(key) { this.values.delete(key); }
}
const response = (data, status = 200, cookies = []) => ({ status, cookies, body: JSON.stringify({ code: status, data }) });
const makeSession = (handler, vault = new Vault()) => {
  const transport = { calls: [], async send(req) { this.calls.push(req); return handler(req); } };
  const session = new Session(transport, vault);
  session.token = 'test-access'; session.user = DataValue.object({ id: 'test-user', email: 'qa@example.invalid' });
  session.bindingIdentity = 'fixture-binding';
  return { session, transport, vault };
};
const clock = () => ({ time: 0, sequence: 0, now() { return this.time; }, async delay(ms) { this.time += ms; }, id() { return 'fixture-' + ++this.sequence; } });

test('money is exact for fractional inputs, large balances, and repeated addition', () => {
  assert.equal(new Decimal('0.1').add(new Decimal('0.2')).toString(), '0.3');
  assert.equal(new Decimal('99999999999999999999.99').add(new Decimal('0.01')).toString(), '100000000000000000000');
  assert.equal(new Decimal('-12.34').subtract(new Decimal('-14')).toString(), '1.66');
  assert.equal(new Decimal('1.2345').multiply(new Decimal('0.002')).toString(), '0.002469');
});
test('money handles negative zero, decimal rounding, and division without floats', () => {
  assert.equal(amount('-0.004'), '0.00'); assert.equal(amount('-0.005'), '-0.01');
  assert.equal(amount('9.999'), '10.00'); assert.equal(new Decimal('1').divide(new Decimal('3'), 8).toString(), '0.33333333');
  assert.equal(new Decimal('0.00000001').divide(new Decimal('2'), 12).toString(), '0.000000005');
  assert.throws(() => new Decimal('1').divide(new Decimal('0')));
});
test('money rejects invalid, exponent, nonfinite, and overlong inputs', () => {
  for (const value of ['', 'NaN', 'Infinity', '1e8', '0x20', '1.2.3', '1'.repeat(161)]) assert.throws(() => new Decimal(value));
  assert.equal(validPositive('-1'), false); assert.equal(validPositive('0.00001'), true); assert.equal(amount('null'), '--');
});
test('envelopes support business codes and missing values never become zero money', () => {
  assert.equal(unwrap('{"code":"200","data":{"a":"0"}}', 200).value('a'), '0');
  assert.throws(() => unwrap('{"code":409,"message":"rejected"}', 200), /rejected/);
  assert.throws(() => unwrap('html', 502), /格式/);
  assert.equal(DataValue.object().value('missing'), '--'); assert.equal(DataValue.object().get('missing').number(NaN).toString(), 'NaN');
});
test('server origins reject credentials, query strings, http, and path injection', () => {
  assert.equal(normalizeOrigin('https://api.example.invalid/integrated'), 'https://api.example.invalid/integrated/');
  for (const value of ['http://example.invalid', 'https://u:p@example.invalid/', 'https://example.invalid/?token=x', 'https://example.invalid/../']) assert.throws(() => normalizeOrigin(value));
});
test('login saves access token and refresh cookie in vault, sends agreement', async () => {
  const { session, transport, vault } = makeSession(() => response({ accessToken: 'new-token', user: { id: 'u' } }, 200, ['riskon_refresh=refresh-fixture; HttpOnly; Secure; Path=/integrated/']));
  await session.authenticate('test@example.invalid', 'fixture-password', false);
  assert.equal(session.cookie, 'riskon_refresh=refresh-fixture'); assert.equal(session.token, 'new-token');
  assert.equal(JSON.parse(transport.calls[0].body).agreed, true); assert.match(await vault.read('session'), /refresh-fixture/);
});
test('parallel 401s perform one refresh and retry with the rotated cookie', async () => {
  let refreshes = 0;
  const { session } = makeSession(async (req) => {
    if (req.url.endsWith('auth/refresh')) { refreshes++; await new Promise(r => setImmediate(r)); return response({ accessToken: 'fresh' }, 200, ['riskon_refresh=rotated; Secure']); }
    return req.headers.Authorization === 'Bearer fresh' ? response({ value: 1 }) : response(null, 401);
  });
  session.cookie = 'riskon_refresh=old';
  await Promise.all([session.request('/one'), session.request('/two'), session.request('/three')]);
  assert.equal(refreshes, 1); assert.equal(session.cookie, 'riskon_refresh=rotated');
});
test('a late response cannot cross a mode change', async () => {
  let finish;
  const { session } = makeSession(() => new Promise(resolve => finish = resolve));
  const task = session.request('/account'); session.setMode('lead'); finish(response({ secret: 'old-account' }));
  await assert.rejects(task, /切换/);
});
test('a late refresh cannot restore a logged-out session', async () => {
  let finish;
  const { session, vault } = makeSession(() => new Promise(resolve => finish = resolve));
  const task = session.refresh(); await session.clear(); finish(response({ accessToken: 'stale' }));
  await assert.rejects(task, /切换/); assert.equal(session.token, ''); assert.equal(await vault.read('session'), '');
});
test('authorization retry is bounded to once', async () => {
  const { session, transport } = makeSession(req => req.url.endsWith('auth/refresh') ? response({ accessToken: 'fresh' }) : response(null, 401));
  await assert.rejects(session.request('/account')); assert.equal(transport.calls.length, 3);
});
test('a trading intent is persisted before network submission', async () => {
  const vault = new Vault();
  const { session } = makeSession(req => {
    assert.match(vault.values.get('pending-commands') || '', /fixture-1/);
    return response({ id: 'command-1', status: 'SUCCEEDED' });
  }, vault);
  const commands = new Commands(session, vault, clock());
  await commands.submit('position-close', DataValue.object({ position_id: 8 }));
  assert.equal(commands.pending().length, 0);
});
test('storage failure prevents any trading request', async () => {
  const vault = new Vault(); vault.write = async () => { throw new Error('storage-failed'); };
  const { session, transport } = makeSession(() => response({}), vault);
  await assert.rejects(new Commands(session, vault, clock()).submit('open', DataValue.object({ symbol: 'BTCUSDT' })), /storage-failed/);
  assert.equal(transport.calls.length, 0);
});
test('unknown submit survives restart and reuses the same idempotency key', async () => {
  let failures = true; const keys = []; const vault = new Vault();
  const { session } = makeSession(req => { keys.push(req.headers['Idempotency-Key']); if (failures) throw new Error('timeout'); return response({ id: 'cmd', status: 'SUCCEEDED' }); }, vault);
  const payload = DataValue.object({ position_id: 8 });
  await assert.rejects(new Commands(session, vault, clock()).submit('position-close', payload), /timeout/);
  failures = false;
  const restored = new Commands(session, vault, clock()); await restored.submit('position-close', payload);
  assert.deepEqual(keys, ['fixture-1', 'fixture-1']);
});
test('unknown requests freeze action and parameters', async () => {
  const { session, transport, vault } = makeSession(() => { throw new Error('timeout'); });
  const commands = new Commands(session, vault, clock());
  await assert.rejects(commands.submit('open', DataValue.object({ symbol: 'BTCUSDT' })));
  await assert.rejects(commands.submit('open', DataValue.object({ symbol: 'ETHUSDT' })), /核对原请求/);
  assert.equal(transport.calls.length, 1);
});
test('known command identities are queried without resubmitting an exchange action', async () => {
  const { session, transport, vault } = makeSession(req => response({ id: 'cmd', status: req.method === 'POST' ? 'UNKNOWN' : 'SUCCEEDED' }));
  const commands = new Commands(session, vault, clock());
  await commands.submit('position-close', DataValue.object({ position_id: 8 }));
  await commands.resume(commands.pending()[0].key);
  assert.deepEqual(transport.calls.map(req => req.method), ['POST', 'GET']);
});
test('pending intent is isolated from another trading mode', async () => {
  const { session, vault } = makeSession(() => { throw new Error('timeout'); }); const commands = new Commands(session, vault, clock());
  await assert.rejects(commands.submit('open', DataValue.object({ symbol: 'BTCUSDT' })));
  session.setMode('lead'); session.bindingIdentity = 'fixture-lead'; assert.equal(commands.pending().length, 0);
});
const candle = (time, close, eventTime = time, closed = false, live = false) => Candle.from(DataValue.object({ openTime: time, eventTime, openPrice: '100', highPrice: '150', lowPrice: '50', closePrice: String(close), volume: '1', closed }), live);
test('late historical snapshots do not overwrite fresher live candles', () => {
  const store = new CandleStore(); store.merge([candle(60000, 120, 90000, false, true)]); store.merge([candle(60000, 110, 80000)]);
  assert.equal(store.candles[0].close, 120);
});
test('closed candles never reopen and history is deduplicated without filling gaps', () => {
  const store = new CandleStore(); store.merge([candle(60000, 120, 120000, true), candle(180000, 130)]);
  store.merge([candle(60000, 110, 130000, false, true)]);
  assert.equal(store.candles.length, 2); assert.equal(store.candles[0].close, 120);
});
test('invalid OHLC values are rejected', () => {
  const store = new CandleStore(); store.merge([candle(60000, NaN), candle(120000, 200), candle(180000, -1)]); assert.equal(store.candles.length, 0);
});
test('EMA, RSI and indicator warmup are deterministic', () => {
  assert.deepEqual(ema([1, 2, 3], 3), [1, 1.5, 2.25]);
  assert.equal(rsi(Array.from({ length: 20 }, () => 1))[19], 50);
  assert.equal(rsi(Array.from({ length: 20 }, (_, i) => i + 1))[19], 100);
  const boll = mainIndicators(Array.from({ length: 25 }, (_, i) => candle((i + 1) * 60000, 100)), 'BOLL');
  assert.equal(Number.isNaN(boll[0].values[18]), true); assert.equal(boll[1].values[24], 100);
});

test('binding epochs persist across restarts and explicit rebind isolates old commands', async () => {
  const vault = new Vault(); const { session } = makeSession(() => response({}), vault);
  const binding = DataValue.object({ alias: 'qa-binding', status: 1 });
  await session.observeBinding(binding); const identity = session.bindingIdentity; const generation = session.generation;
  await session.observeBinding(DataValue.object({ alias: 'qa-binding', status: 0 }));
  assert.equal(session.bindingIdentity, identity); assert.equal(session.generation, generation);
  const restored = makeSession(() => response({}), vault).session; restored.bindingIdentity = '';
  await restored.observeBinding(binding); assert.equal(restored.bindingIdentity, identity);
  await restored.observeBinding(binding, true); assert.notEqual(restored.bindingIdentity, identity);
});
test('rejected refresh removes local credentials', async () => {
  const { session, vault } = makeSession(() => response(null, 401));
  await assert.rejects(session.refresh()); assert.equal(session.authenticated, false); assert.equal(await vault.read('session'), '');
});
test('persist failure on an earlier attempt cannot allow a later unpersisted trade', async () => {
  const vault = new Vault(); vault.write = async () => { throw new Error('storage-failed'); };
  const { session, transport } = makeSession(() => response({ id: 'cmd', status: 'SUCCEEDED' }), vault);
  const commands = new Commands(session, vault, clock()); const payload = DataValue.object({ position_id: 8 });
  await assert.rejects(commands.submit('position-close', payload));
  await assert.rejects(commands.submit('position-close', payload)); assert.equal(transport.calls.length, 0);
});
import { CapitalWorkflow, BulkClose } from '../entry/src/main/ets/core/Workflows.ts';
test('unknown capital normalization survives restart and prevents repeat of original plan', async () => {
  const vault = new Vault(); const { session, transport } = makeSession(() => { throw new Error('timeout'); }, vault);
  const preview = DataValue.object({ status: 'normalization_required', plan_token: 'fixture-plan' });
  await assert.rejects(new CapitalWorkflow(session, vault).confirm(preview), /timeout/);
  await assert.rejects(new CapitalWorkflow(session, vault).confirm(preview), /结果未知/);
  assert.equal(transport.calls.length, 1);
});
test('capital preview recovers a collection id, subsequent requests use only that id', async () => {
  const vault = new Vault(); const payloads = [];
  const { session } = makeSession(req => {
    const body = JSON.parse(req.body); payloads.push(body);
    if (req.url.endsWith('precheck')) return response({ status: 'collection_pending', collection_id: 42 });
    assert.equal(JSON.parse(vault.values.get('capital:' + session.baseUrl + ':test-user:ordinary:fixture-binding')).id, 42);
    return response({ status: 'ready', reason: 'normalization_completed' });
  }, vault);
  const workflow = new CapitalWorkflow(session, vault); const preview = await workflow.preview(); await workflow.confirm(preview);
  assert.equal(payloads[1].collection_id, 42); assert.equal(payloads[1].expected_plan, undefined); assert.equal((await workflow.pending()).empty(), true);
});
test('capital storage failure prevents a transfer from being sent', async () => {
  const vault = new Vault(); vault.write = async () => { throw new Error('disk-full'); };
  const { session, transport } = makeSession(() => response({}), vault);
  await assert.rejects(new CapitalWorkflow(session, vault).confirm(DataValue.object({ status: 'normalization_required', plan_token: 'fixture' })), /disk-full/);
  assert.equal(transport.calls.length, 0);
});
test('bulk close stops on UNKNOWN and resumes the exact target keys after restart', async () => {
  const vault = new Vault(); const calls = []; let unknown = true;
  const { session } = makeSession(req => { const payload = JSON.parse(req.body); calls.push({ key: req.headers['Idempotency-Key'], id: payload.payload?.position_id, method: req.method }); if (unknown) throw new Error('timeout'); return response({ id: 'cmd-' + payload.payload?.position_id, status: 'SUCCEEDED' }); }, vault);
  const commands = new Commands(session, vault, clock()); const bulk = new BulkClose(session, commands, vault, clock());
  await bulk.prepare([DataValue.object({ id: 8, symbol: 'BTCUSDT' }), DataValue.object({ id: 9, symbol: 'ETHUSDT' })]);
  await assert.rejects(bulk.run(), /timeout/); assert.equal(calls.length, 1);
  unknown = false; await new BulkClose(session, new Commands(session, vault, clock()), vault, clock()).run();
  assert.deepEqual(calls.map(v => v.id), [8, 8, 9]); assert.equal(calls[0].key, calls[1].key); assert.notEqual(calls[1].key, calls[2].key);
});
test('bulk close skips already confirmed targets when writing cursor failed', async () => {
  const vault = new Vault(); const methods = []; let breakCursor = true; const originalWrite = vault.write.bind(vault);
  vault.write = async (key, value) => { if (key.startsWith('bulk-close:') && JSON.parse(value).cursor === 1 && breakCursor) throw new Error('cursor-disk-failure'); return originalWrite(key, value); };
  const { session } = makeSession(req => { methods.push(req.method); return response({ id: 'cmd', status: 'SUCCEEDED' }); }, vault);
  const bulk = new BulkClose(session, new Commands(session, vault, clock()), vault, clock());
  await bulk.prepare([DataValue.object({ id: 8 })]); await assert.rejects(bulk.run(), /cursor-disk-failure/);
  breakCursor = false; await new BulkClose(session, new Commands(session, vault, clock()), vault, clock()).run();
  assert.deepEqual(methods, ['POST', 'GET']);
});
test('live candles retain newly attached statistics without accepting old history prices', () => {
  const store = new CandleStore(); store.merge([candle(60000, 120, 90000, false, true)]);
  const old = candle(60000, 110, 80000); old.statistics = DataValue.object({ openInterest: '123' }); store.merge([old]);
  assert.equal(store.candles[0].close, 120); assert.equal(store.candles[0].statistics.value('openInterest'), '123');
});
import { panelIndicators } from '../entry/src/main/ets/core/Market.ts';
test('every advertised chart indicator produces named series, missing statistics stay missing', () => {
  const candles = Array.from({ length: 180 }, (_, i) => candle((i + 1) * 60000, 100 + i / 10));
  for (const kind of ['MA', 'EMA', 'BOLL', 'SAR', 'AVL', 'SUPER']) assert.ok(mainIndicators(candles, kind).length, kind);
  for (const kind of ['VOL', 'MACD', 'RSI', 'KDJ', 'OBV', 'WR', 'StochRSI', 'ATR', 'O.I.', 'L.S Acco.', 'L.S Posit.', 'L.S Ratio', 'B.S Vol.', 'Basis']) assert.ok(panelIndicators(candles, kind).length, kind);
  assert.ok(panelIndicators(candles, 'O.I.')[0].values.every(Number.isNaN));
  assert.ok(Number.isFinite(panelIndicators(candles, 'StochRSI')[0].values[179]));
  assert.deepEqual(panelIndicators(candles, 'not-an-indicator'), []);
});
import { StrategyLevel, strategyPayload } from '../entry/src/main/ets/core/Strategy.ts';
test('strategy validation enforces ordered R, total reduction, and stop movement boundaries', () => {
  const a = new StrategyLevel(); const b = new StrategyLevel(); b.profit = '2'; a.reduce = '50'; b.reduce = '50';
  assert.equal(strategyPayload('qa', [a,b]).get('levels').rows().length, 2);
  b.profit = '1'; assert.throws(() => strategyPayload('qa', [a,b]), /递增/); b.profit = '2';
  b.reduce = '50.00000001'; assert.throws(() => strategyPayload('qa', [a,b]), /100/); b.reduce = '50';
  a.stopType = 'absoluteRR'; a.stopValue = '-1'; assert.throws(() => strategyPayload('qa', [a,b]), /-1/);
  a.stopValue = '-0.9999'; assert.doesNotThrow(() => strategyPayload('qa', [a,b]));
});
import { stopLossPreview } from '../entry/src/main/ets/core/MoneyRules.ts';
test('stop loss preview uses exact total assets, ceiling and 1/5/10 USDT steps', () => {
  assert.equal(stopLossPreview('123.4567', '2'), '3');
  assert.equal(stopLossPreview('1000.00001', '2'), '25');
  assert.equal(stopLossPreview('5000.00001', '2'), '110');
  assert.equal(stopLossPreview('0.01', '1'), '1');
  for (const value of ['0', '26', '2.5']) assert.throws(() => stopLossPreview('100', value));
  assert.throws(() => stopLossPreview('--', '2'));
});
test('a distinct stable batch key cannot take over an earlier unknown command', async () => {
  const { session, transport, vault } = makeSession(() => { throw new Error('timeout'); });
  const commands = new Commands(session, vault, clock()); const payload = DataValue.object({ position_id: 8 });
  await assert.rejects(commands.submit('position-close', payload));
  await assert.rejects(commands.submit('position-close', payload, 'other-batch-key'), /原请求/);
  assert.equal(transport.calls.length, 1);
});
test('bulk prepare rejects an unresolved manual intent before persisting another batch', async () => {
  const { session, vault } = makeSession(() => { throw new Error('timeout'); }); const commands = new Commands(session, vault, clock());
  await assert.rejects(commands.submit('position-close', DataValue.object({ position_id: 8 })));
  const bulk = new BulkClose(session, commands, vault, clock());
  await assert.rejects(bulk.prepare([DataValue.object({ id: 8 })]), /待确认/); assert.equal((await bulk.pending()).empty(), true);
});
test('bulk recovery does not send remaining targets after an account mode switch', async () => {
  const vault = new Vault(); let calls = 0;
  const { session } = makeSession(() => { calls++; session.setMode('lead'); session.bindingIdentity = 'lead-binding'; return response({ id: 'cmd', status: 'SUCCEEDED' }); }, vault);
  const bulk = new BulkClose(session, new Commands(session, vault, clock()), vault, clock());
  await bulk.prepare([DataValue.object({ id: 8 }), DataValue.object({ id: 9 })]); await assert.rejects(bulk.run(), /切换/);
  assert.equal(calls, 1); assert.equal((await bulk.pending()).empty(), true);
});
test('switching account while an intent is being persisted prevents any network submission', async () => {
  const vault = new Vault(); const originalWrite = vault.write.bind(vault); let switched = false;
  const { session, transport } = makeSession(() => response({ id: 'cmd', status: 'SUCCEEDED' }), vault);
  vault.write = async (key, value) => { await originalWrite(key, value); if (!switched && key === 'pending-commands') { switched = true; session.setMode('lead'); session.bindingIdentity = 'lead-binding'; } };
  await assert.rejects(new Commands(session, vault, clock()).submit('position-close', DataValue.object({ position_id: 8 })), /切换/);
  assert.equal(transport.calls.length, 0);
});
