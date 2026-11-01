import test from 'node:test';
import assert from 'node:assert/strict';
import { Realtime } from '../entry/src/main/ets/core/Realtime.ts';
import { Session } from '../entry/src/main/ets/core/Session.ts';
import { DataValue } from '../entry/src/main/ets/core/Json.ts';
class ManualClock {
  time = 1000; sequence = 0; waits = [];
  now() { return this.time; }
  id() { return 'ping-' + ++this.sequence; }
  delay(ms) { return new Promise(resolve => this.waits.push({ due: this.time + ms, resolve })); }
  async advance(ms) {
    this.time += ms;
    for (let i = 0; i < 8; i++) { const ready = this.waits.filter(v => v.due <= this.time); this.waits = this.waits.filter(v => v.due > this.time); ready.forEach(v => v.resolve()); await Promise.resolve(); }
  }
}
const fixture = () => {
  const session = new Session({ async send() { throw new Error('unexpected-http'); } }, { async read() { return ''; }, async write() {}, async remove() {} });
  session.baseUrl = 'https://qa.example.invalid/integrated/'; session.user = DataValue.object({ id: 'qa' }); session.token = 'fixture';
  const socket = { callbacks: [], sent: [], closes: 0, connect(url, headers, cb) { this.url = url; this.headers = headers; this.callbacks.push(cb); cb.opened(); }, send(v) { this.sent.push(JSON.parse(v)); }, close() { this.closes++; } };
  const clock = new ManualClock(); return { session, socket, clock, live: new Realtime(session, socket, clock) };
};
const ready = (socket, capabilities = []) => socket.callbacks.at(-1).message(JSON.stringify({ type: 'ready', data: { capabilities } }));
test('native WSS uses bearer header and waits for ready capability before history subscription', () => {
  const { live, socket } = fixture(); live.setChart('BTCUSDT', '1h'); live.start();
  assert.equal(socket.url, 'wss://qa.example.invalid/integrated/ws/v1'); assert.equal(socket.headers.Authorization, 'Bearer fixture'); assert.equal(socket.sent.length, 0);
  ready(socket); assert.equal(socket.sent[0].subscriptions.some(v => v.channel === 'market.history'), false);
  live.stop(); live.start(); ready(socket, ['market.history']);
  assert.equal(socket.sent.at(-2).subscriptions.some(v => v.channel === 'market.history'), true);
  live.stop();
});
test('closing chart unsubscribes optional channels only when negotiated', () => {
  const { live, socket } = fixture(); live.start(); ready(socket); live.setChart('', '1h');
  const unsub = socket.sent.find(v => v.type === 'unsubscribe'); assert.deepEqual(unsub.subscriptions.map(v => v.channel), ['market.kline']); live.stop();
});
test('stale socket messages cannot cross mode switches or stop/background', () => {
  const { live, socket, session } = fixture(); const received = []; live.onEvent = v => received.push(v); live.start(); ready(socket);
  const old = socket.callbacks[0]; session.setMode('lead'); old.message('{"type":"event","data":{"old":true}}');
  assert.equal(received.length, 1); live.stop(); old.message('{"type":"ready"}'); assert.equal(received.length, 1);
});
test('latency allows one pending ping, ignores mismatched pong, and reconnects after silence', async () => {
  const { live, socket, clock } = fixture(); live.start(); ready(socket);
  let pings = socket.sent.filter(v => v.type === 'ping'); assert.equal(pings.length, 1);
  await clock.advance(2000); assert.equal(socket.sent.filter(v => v.type === 'ping').length, 1);
  socket.callbacks[0].message('{"type":"pong","requestId":"wrong"}'); assert.equal(live.latency, -1);
  socket.callbacks[0].message(JSON.stringify({ type: 'pong', requestId: pings[0].requestId })); assert.equal(live.latency, 2000);
  await clock.advance(250); pings = socket.sent.filter(v => v.type === 'ping'); assert.equal(pings.length, 2);
  await clock.advance(3250); assert.equal(live.latency, -1);
  await clock.advance(61000); await clock.advance(1000); assert.ok(socket.callbacks.length >= 2);
  live.stop(); const connections = socket.callbacks.length; await clock.advance(60000); assert.equal(socket.callbacks.length, connections);
});
