import test from 'node:test';
import assert from 'node:assert/strict';
import { MarketSort, sortedMarketSymbols, pairPickerSymbols, reorderedWatchlist, marketNumber, marketTurnover } from '../entry/src/main/ets/core/MarketList.ts';
import { AppStore } from '../entry/src/main/ets/core/AppStore.ts';
import { Session } from '../entry/src/main/ets/core/Session.ts';
import { Ticker } from '../entry/src/main/ets/core/Market.ts';
import { DataValue } from '../entry/src/main/ets/core/Json.ts';

const ticker = (symbol, price, volume, change) => Ticker.from(DataValue.object({ symbol, lastPrice: price, quoteVolume24h: volume, priceChangePercent24h: change }));
test('market sorting cycles both directions then restores manual order, with stable equal-value ties', () => {
  const manual = ['SOLUSDT', 'ETHUSDT', 'BTCUSDT', 'NEWUSDT'];
  const data = [ticker('BTCUSDT', '100', 50, 2), ticker('ETHUSDT', '20', 50, -1), ticker('SOLUSDT', '3', 10, 1)];
  let sort = new MarketSort().next('volume');
  assert.deepEqual(sortedMarketSymbols(manual, data, sort), ['BTCUSDT','ETHUSDT','SOLUSDT','NEWUSDT']);
  sort = sort.next('volume');
  assert.deepEqual(sortedMarketSymbols(manual, data, sort), ['SOLUSDT','BTCUSDT','ETHUSDT','NEWUSDT']);
  assert.deepEqual(sortedMarketSymbols(manual, data, sort.next('volume')), manual);
  assert.deepEqual(sortedMarketSymbols(manual, data, sort.next('price')), ['BTCUSDT','ETHUSDT','SOLUSDT','NEWUSDT']);
  assert.deepEqual(sortedMarketSymbols(manual, data, sort.next('symbol')), ['BTCUSDT','ETHUSDT','NEWUSDT','SOLUSDT']);
});
test('picker uses catalog rather than ticker availability and keeps favorites first during normalized search', () => {
  const catalog = ['BTCUSDT','ETHUSDT','SOLUSDT','NEWUSDT'];
  assert.deepEqual(pairPickerSymbols(catalog, ['SOLUSDT','REMOVEDUSDT','BTCUSDT'], ''), ['SOLUSDT','BTCUSDT','ETHUSDT','NEWUSDT']);
  assert.deepEqual(pairPickerSymbols(catalog, [], ' btc/usdt '), ['BTCUSDT']);
  assert.deepEqual(pairPickerSymbols(catalog, [], 'new'), ['NEWUSDT']);
  assert.deepEqual(reorderedWatchlist(catalog, 2, 0), ['SOLUSDT','BTCUSDT','ETHUSDT','NEWUSDT']);
  assert.deepEqual(reorderedWatchlist(catalog, -1, 1), catalog);
});
test('market display matches iOS decimal bands and carry, separate from transaction precision', () => {
  for (const [input, expected] of [['12345.678','12345.68'],['12.3456','12.346'],['0.123456','0.1235'],['0.0000123456','0.00001235'],['99.9999','100.00'],['0','0'],['-0.00000001','-0.00000001']]) assert.equal(marketNumber(input), expected);
  assert.equal(marketNumber('1.2', true), '+1.200');
  assert.equal(marketNumber('1e-8'), '0.00000001');
  assert.equal(marketTurnover(123456789), '1.235亿');
});

function makeStore(handler, prefs = new Map()) {
  const vault = { async read() { return ''; }, async write() {}, async remove() {} };
  const session = new Session({ async send(req) { return { status: 200, cookies: [], body: JSON.stringify({ code: 200, data: await handler(req) }) }; } }, vault);
  session.user = DataValue.object({ id: 'fixture-a' }); session.token = 'fixture-token';
  const realtime = { start() {}, stop() {}, setChart() {}, onChange() {}, onEvent() {} };
  const clock = { now() { return 1000; }, async delay() { await new Promise(r => setImmediate(r)); }, id() { return 'fixture'; } };
  const preferences = { read(k, fallback) { return prefs.get(k) ?? fallback; }, write(k, v) { prefs.set(k, v); } };
  const store = new AppStore(session, { async load() {} }, realtime, preferences, clock, {}, {});
  // Start market state without account/network timers, using the same restore path as start().
  store.restoreWatchlist();
  return { store, session, prefs };
}
test('local edits made while defaults load survive the response and later sync the newest order', async () => {
  let resolveDefaults; const writes = [];
  const { store, prefs } = makeStore(req => {
    if (req.method === 'POST') { writes.push(JSON.parse(req.body).symbols); return {}; }
    if (req.url.endsWith('/defaults')) return new Promise(r => { resolveDefaults = r; });
    return { items: [] };
  });
  const pending = store.loadTickers();
  while (!resolveDefaults) await new Promise(r => setImmediate(r));
  store.addWatch('SOLUSDT'); store.addWatch('BTCUSDT'); store.moveWatch(1, 0);
  resolveDefaults({ symbols: ['ETHUSDT'], isCustomized: true }); await pending;
  await new Promise(r => setImmediate(r)); await new Promise(r => setImmediate(r));
  assert.deepEqual(store.watchlist, ['BTCUSDT','SOLUSDT']);
  assert.deepEqual(writes.at(-1), store.watchlist);
  assert.equal(prefs.get(store.userKey('watchlist-dirty')), 'false');
});
test('failed sync remains persisted and empty customized watchlist is restored after restart', async () => {
  const prefs = new Map();
  const first = makeStore(() => { throw new Error('offline'); }, prefs);
  first.store.addWatch('BTCUSDT'); first.store.removeWatch('BTCUSDT');
  await new Promise(r => setImmediate(r)); await new Promise(r => setImmediate(r));
  assert.equal(prefs.get(first.store.userKey('watchlist-dirty')), 'true');
  const second = makeStore(req => req.url.endsWith('/defaults') ? { symbols: ['ETHUSDT'] } : { items: [] }, prefs);
  await second.store.loadTickers(); assert.deepEqual(second.store.watchlist, []);
});
test('catalog late responses cannot cross users and unavailable catalog can be retried', async () => {
  let resolve; const { store, session } = makeStore(() => new Promise(r => { resolve = r; }));
  const request = store.loadCatalog();
  session.user = DataValue.object({ id: 'fixture-b' }); session.generation++;
  store.restoreWatchlist(); resolve({ quoteAsset: 'USDT', symbols: ['BTCUSDT'] }); await request;
  assert.deepEqual(store.catalogSymbols, []); assert.equal(store.catalogLoading, false);
  const retry = makeStore(() => ({ quoteAsset: 'USDT', symbols: [' btcusdt ', 'BTCUSDT', '../bad', 'ETHUSDC'] }));
  await retry.store.loadCatalog(); assert.deepEqual(retry.store.catalogSymbols, ['BTCUSDT']);
});
test('a previous session cannot release the newer watchlist sync flight', async () => {
  const pending = [];
  const { store, session } = makeStore(req => new Promise(resolve => pending.push({ resolve, symbols: JSON.parse(req.body).symbols })));
  const flush = () => new Promise(resolve => setImmediate(resolve));
  store.addWatch('BTCUSDT'); await flush();
  assert.equal(pending.length, 1);
  session.generation++;
  store.addWatch('ETHUSDT'); await flush();
  assert.equal(pending.length, 2, 'the new session starts its own scoped sync');
  pending[0].resolve({}); await flush();
  store.addWatch('SOLUSDT'); await flush();
  assert.equal(pending.length, 2, 'the old session completion must not unlock the newer flight');
  pending[1].resolve({}); await flush();
  assert.equal(pending.length, 3);
  assert.deepEqual(pending[2].symbols, ['BTCUSDT', 'ETHUSDT', 'SOLUSDT']);
  pending[2].resolve({}); await flush();
  assert.equal(store.preferences.read(store.userKey('watchlist-dirty'), ''), 'false');
});
test('a failed ticker request from an old account cannot replace the new account notice', async () => {
  let reject;
  const { store, session } = makeStore(() => new Promise((_resolve, fail) => { reject = fail; }));
  const request = store.loadTickers();
  session.user = DataValue.object({ id: 'fixture-b' }); session.generation++;
  store.restoreWatchlist(); store.notice = 'new-account-message';
  reject(new Error('old-account-network-failure')); await request;
  assert.equal(store.notice, 'new-account-message');
  assert.equal(store.marketRefreshing, false);
});
