import test from 'node:test';
import assert from 'node:assert/strict';
import { DataValue } from '../entry/src/main/ets/core/Json.ts';
import { Session } from '../entry/src/main/ets/core/Session.ts';
import { Commands } from '../entry/src/main/ets/core/Commands.ts';
import { EntryDraft, EntryFlow, ChartAccount, heldPositions, leverageOptions } from '../entry/src/main/ets/core/ChartTrading.ts';
const value = data => DataValue.object(data);
const response = data => ({ status: 200, body: JSON.stringify({ code: 200, data }), cookies: [] });
const draft = () => Object.assign(new EntryDraft(), { symbol: 'BTCUSDT', orderType: 'limit', price: '100', limit: '100', stop: '90', risk: '10' });
function setup(handler = () => undefined) {
  const calls = [], saved = new Map(); let now = 1000, nextId = 0;
  const clock = { now: () => now, id: () => 'intent-' + ++nextId, delay: async ms => { now += ms; } };
  const vault = { read: async key => saved.get(key) || '', write: async (key, val) => { saved.set(key, val); }, remove: async key => { saved.delete(key); } };
  const session = new Session({ send: async req => {
    calls.push(req); const custom = await handler(req); if (custom !== undefined) return custom;
    if (req.url.endsWith('position/list')) return response([]);
    if (req.url.endsWith('capital/precheck')) return response({ status: 'ready' });
    if (req.url.endsWith('ema-check')) return response({ check_id: 'ema-fixture', symbol: 'BTCUSDT', side: 'long', stop_loss_price: '90', has_any_matching_interval: true, expires_at: new Date(now + 180000).toISOString() });
    if (req.url.endsWith('api/commands')) { assert.ok(saved.get('pending-commands')); return response({ id: 'c', status: 'SUCCEEDED' }); }
    throw new Error('Unexpected route');
  } }, vault);
  session.token = 'fixture'; session.user = value({ id: 'test' }); session.bindingIdentity = 'bound:fixture';
  const commands = new Commands(session, vault, clock), account = new ChartAccount(), flow = new EntryFlow(session, commands, clock, account);
  let current = draft(); const context = { active: true, bound: true };
  return { flow, session, commands, account, calls, context, current: () => current, replace: d => { current = d; }, advance: confirm => flow.advance(() => current, () => context, confirm || (async () => true)), elapse: ms => { now += ms; } };
}
const commands = s => s.calls.filter(r => r.url.endsWith('api/commands'));
test('entry estimates are exact Decimal and fee applies to both order types; payload preserves raw prices', () => {
  const d = draft(); d.includeFee = true; assert.equal(d.estimate(), '99.009900990099009900990099');
  assert.equal(d.payload(value({})).value('stop_loss_price'), '90');
  d.orderType = 'market'; assert.equal(d.estimate(), '99.009900990099009900990099');
  assert.equal(d.payload(value({ check_id: 'ema' })).get('include_fee').flag(), true);
  assert.equal(d.payload(value({})).get('strategy_id').empty(), true);
  d.strategy = value({ id: '7', name: 'snapshot', levels: [{ profitRR: '2', reducePosition: '100' }] }); d.leverage = 20;
  const copy = d.copy(); d.strategy.fields().name = 'changed'; assert.equal(copy.strategy.value('name'), 'snapshot');
  assert.equal(copy.payload(value({})).get('leverage').number(), 20);
});
test('leverage capacities sort as Decimal and never perform an account mutation', () => {
  const opts = leverageOptions(value({ brackets: [{ leverage: 10, max_open_amount: '99999999999999999999.99' }, { leverage: 20, max_open_amount: '100000000000000000000' }, { leverage: 5, max_open_amount: '100000000000000000000' }, { leverage: 3, max_open_amount: '-1' }, { leverage: 2, max_open_amount: 'NaN' }] }));
  assert.deepEqual(opts.map(o => o.get('leverage').number()), [5, 20, 10]);
});
test('only current symbol active nonzero positions are held', () => {
  assert.equal(heldPositions([value({ symbol: 'BTCUSDT', status: 0, size: '1' }), value({ symbol: 'BTCUSDT', status: 1, size: '1' }), value({ symbol: 'ETHUSDT', status: 0, size: '1' }), value({ symbol: 'BTCUSDT', size: '0' })], 'BTCUSDT').length, 1);
});
test('cancelled entry confirms without sending a command', async () => { const s = setup(); await s.advance(async () => false); assert.equal(commands(s).length, 0); assert.equal(s.flow.submitted, false); });
test('successful limit submission uses one frozen persisted intent', async () => { const s = setup(); await s.advance(); assert.equal(commands(s).length, 1); assert.equal(commands(s)[0].headers['Idempotency-Key'], 'intent-1'); await s.advance(); assert.equal(commands(s).length, 1); });
for (const field of ['stop', 'limit', 'risk', 'includeFee', 'leverage', 'strategy']) test('confirmation rejects changed ' + field, async () => {
  const s = setup(); await s.advance(async () => { s.current()[field] = field === 'includeFee' ? true : field === 'leverage' ? 20 : field === 'strategy' ? value({ id: 'new' }) : '95'; return true; });
  assert.equal(commands(s).length, 0); assert.match(s.flow.notice, /变化/);
});
test('same-side market quote updates preserve intent; side changes invalidate it', () => {
  const a = draft(); a.orderType = 'market'; const b = a.copy(); b.price = '101'; assert.ok(a.matches(b)); b.price = '80'; assert.equal(a.matches(b), false);
});
test('market entry performs EMA first, then preflight and explicit confirmation', async () => {
  const s = setup(); s.current().orderType = 'market'; await s.advance(); assert.equal(commands(s).length, 0); assert.equal(s.calls.some(r => r.url.endsWith('capital/precheck')), false);
  await s.advance(); assert.equal(commands(s).length, 1); assert.equal(JSON.parse(commands(s)[0].body).payload.ema_check_id, 'ema-fixture');
});
test('EMA expiry during confirmation prevents submission', async () => {
  const s = setup(); s.current().orderType = 'market'; await s.advance(); await s.advance(async () => { s.elapse(180001); return true; }); assert.equal(commands(s).length, 0); assert.match(s.flow.notice, /过期/);
});
test('late account responses never cross scope and errors block new entry', async () => {
  let release; const s = setup(r => r.url.endsWith('position/list') ? new Promise(resolve => { release = resolve; }) : undefined);
  const task = s.account.refresh(s.session, true); s.session.setMode('lead'); release(response([{ symbol: 'BTCUSDT', size: '1' }])); await task;
  assert.equal(s.account.ready, false); assert.deepEqual(s.account.positions('BTCUSDT', s.session.scope), []);
  const f = setup(r => { if (r.url.endsWith('position/list')) throw new Error('offline'); }); await f.advance(); assert.equal(commands(f).length, 0); assert.equal(f.account.ready, false);
});
test('a newly detected holding after confirmation prevents a new order', async () => {
  let held = false; const s = setup(r => r.url.endsWith('position/list') ? response(held ? [{ symbol: 'BTCUSDT', status: 0, size: '1' }] : []) : undefined);
  await s.advance(async () => { held = true; return true; }); assert.equal(commands(s).length, 0);
});
test('leaving the page or changing account during confirmation prevents submission', async () => {
  for (const action of [s => { s.context.active = false; }, s => s.session.setMode('lead')]) { const s = setup(); await s.advance(async () => { action(s); return true; }); assert.equal(commands(s).length, 0); }
});
test('unresolved durable command blocks a second intent after returning to chart', async () => {
  const s = setup(r => r.url.endsWith('api/commands') ? response({ status: 'UNKNOWN' }) : undefined); await s.advance();
  const next = new EntryFlow(s.session, s.commands, { now: () => 1000, id: () => 'new', delay: async () => {} }, s.account);
  await next.advance(s.current, () => s.context, async () => true); assert.equal(commands(s).length, 1); assert.equal(next.submitted, true);
});

test('malformed position responses cannot turn an unknown account into empty holdings', async () => {
  for (const data of [{ items: [] }, [{ symbol: 'BTCUSDT', status: 0 }], [{ symbol: 'BTCUSDT', size: 'NaN' }]]) {
    const s = setup(r => r.url.endsWith('position/list') ? response(data) : undefined); await s.advance();
    assert.equal(s.account.ready, false); assert.equal(commands(s).length, 0);
  }
});
