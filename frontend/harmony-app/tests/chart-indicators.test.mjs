import test from 'node:test';
import assert from 'node:assert/strict';
import { readFile } from 'node:fs/promises';
import { createHash } from 'node:crypto';
import { Candle, mainIndicators, panelIndicators } from '../entry/src/main/ets/core/Market.ts';
import { DataValue } from '../entry/src/main/ets/core/Json.ts';
import { IndicatorParameters, OVERLAYS } from '../entry/src/main/ets/core/ChartSettings.ts';
const fixture = JSON.parse(await readFile(new URL('./fixtures/ios-chart-reference.json', import.meta.url)));
test('reference fixture hashes match the current iOS calculator sources', async () => {
  for (const [file, hash] of Object.entries(fixture.source_sha256)) assert.equal(createHash('sha256').update(await readFile(new URL('../../ios-app/TradeTool/' + file, import.meta.url))).digest('hex'), hash, file);
});
for (const scene of ['contiguous', 'gap']) for (const [kind, expected] of Object.entries(fixture[scene].series)) test('Swift numerical parity: ' + scene + ' / ' + kind, () => {
  const candles = fixture[scene].candles.map(c => Candle.from(DataValue.object(c)));
  const actual = (OVERLAYS.includes(kind) ? mainIndicators : panelIndicators)(candles, kind, new IndicatorParameters(), 60000);
  assert.equal(actual.length, expected.length);
  for (let line = 0; line < expected.length; line++) for (let i = 0; i < candles.length; i++) {
    if (expected[line][i] === null) assert.ok(Number.isNaN(actual[line].values[i]), `${kind} ${line} ${i}: expected missing, actual ${actual[line].values[i]}`);
    else assert.ok(Number.isFinite(actual[line].values[i]) && Math.abs(actual[line].values[i] - expected[line][i]) <= 1e-9 * Math.max(1, Math.abs(expected[line][i])), `${kind} ${line} ${i}: expected ${expected[line][i]}, actual ${actual[line].values[i]}`);
  }
});
test('live candle replacements cannot cumulatively alter committed indicator history', () => {
  const candles = fixture.contiguous.candles.map(c => Candle.from(DataValue.object(c)));
  const initial = mainIndicators(candles, 'SUPER')[0].values;
  candles.at(-1).close += 1; candles.at(-1).high += 1;
  const next = mainIndicators(candles, 'SUPER')[0].values;
  assert.deepEqual(next.slice(0,-1), initial.slice(0,-1)); assert.deepEqual(next, mainIndicators(candles, 'SUPER')[0].values);
});
