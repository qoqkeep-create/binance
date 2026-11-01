// Source/config checks only. This is deliberately NOT an ArkTS compiler.
import { readFile, readdir, access } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import assert from 'node:assert/strict';
const root = fileURLToPath(new URL('../', import.meta.url));
const ignored = new Set(['.local-build', '.hvigor', '.idea', 'node_modules', 'oh_modules', 'build', '.git']);
async function walk(dir) {
  const result = [];
  for (const file of await readdir(dir, { withFileTypes: true })) {
    if (ignored.has(file.name)) continue;
    const full = path.join(dir, file.name);
    if (file.isDirectory()) result.push(...await walk(full)); else result.push(full);
  }
  return result;
}
const files = await walk(root);
const json = new Map();
for (const file of files.filter(v => /\.json5?$/.test(v))) json.set(path.relative(root, file), JSON.parse(await readFile(file, 'utf8')));
assert.equal(json.get('AppScope/app.json5').app.bundleName, 'com.waibao2025.trade.harmony');
assert.equal(json.get('build-profile.json5').app.products[0].runtimeOS, 'HarmonyOS');
assert.equal(json.get('build-profile.json5').app.products[0].targetSdkVersion, '6.0.0(20)');
assert.equal(json.get('build-profile.json5').app.signingConfigs, undefined, 'public project must not contain signing credentials');
const module = json.get('entry/src/main/module.json5').module;
assert.equal(module.type, 'entry'); assert.equal(module.mainElement, 'EntryAbility');
assert.deepEqual(module.requestPermissions.map(v => v.name).sort(), ['ohos.permission.GET_NETWORK_INFO', 'ohos.permission.INTERNET']);
for (const page of json.get('entry/src/main/resources/base/profile/main_pages.json').src) await access(path.join(root, 'entry/src/main/ets', page + '.ets'));
const resourceKeys = new Set();
for (const file of files) {
  const match = file.match(/resources\/base\/media\/([^/.]+)\./); if (match) resourceKeys.add('media.' + match[1]);
}
for (const type of ['color', 'string']) for (const value of json.get(`entry/src/main/resources/base/element/${type}.json`)[type]) resourceKeys.add(type + '.' + value.name);
let imports = 0;
for (const file of files.filter(v => /\.(ets|ts)$/.test(v))) {
  const text = await readFile(file, 'utf8');
  for (const match of text.matchAll(/from\s+['"]([^'"]+)['"]/g)) {
    if (!match[1].startsWith('.')) continue;
    const target = path.resolve(path.dirname(file), match[1]);
    assert.ok(files.includes(target + '.ets') || files.includes(target + '.ts'), `missing import in ${path.relative(root,file)}: ${match[1]}`); imports++;
  }
  for (const match of text.matchAll(/\$r\(['"]app\.([^'"]+)['"]\)/g)) assert.ok(resourceKeys.has(match[1]), `missing resource ${match[1]}`);
  assert.ok(!/-----BEGIN (?:RSA |EC |OPENSSH )?PRIVATE KEY-----/.test(text), 'private key found');
}
for (const file of files) assert.ok(!/\.(p12|p7b|jks|keystore|key|pem|cer)$/.test(file), 'signing file outside ignored workspace');
const colors = json.get('entry/src/main/resources/base/element/color.json').color.map(v => v.name).sort();
assert.deepEqual(json.get('entry/src/main/resources/dark/element/color.json').color.map(v => v.name).sort(), colors);
console.log(`PASS: ${json.size} configurations, ${imports} imports, ${resourceKeys.size} resources; no signing material in public project.`);
console.log('ArkTS/native APIs, HAP packaging, signing, UI and phone execution require DevEco SDK validation.');
