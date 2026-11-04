// Creates an isolated, offline UI build. Normal source and signing configuration stay untouched.
import { cp, mkdir, readFile, readdir, writeFile } from 'node:fs/promises';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
const root = fileURLToPath(new URL('../', import.meta.url));
const [scene = 'market', theme = 'dark', registration = 'open'] = process.argv.slice(2);
if (!['auth', 'market', 'chart', 'chart-held', 'chart-error'].includes(scene) || !['light', 'dark'].includes(theme) || !['open', 'closed', 'unavailable'].includes(registration)) throw new Error('Usage: prepare-preview.mjs [auth|market|chart|chart-held|chart-error] [light|dark] [open|closed|unavailable]');
const preview = path.join(root, '.local-build/preview-project');
const signing = await readFile(path.join(root, '.local-build/project/build-profile.json5'));
await mkdir(preview, { recursive: true, mode: 0o700 });
const ignored = new Set(['.git', '.local-build', '.hvigor', '.idea', 'node_modules', 'oh_modules', 'build', 'local.properties']);
for (const name of await readdir(root)) {
  if (ignored.has(name) || name.startsWith('signing')) continue;
  await cp(path.join(root, name), path.join(preview, name), { recursive: true, force: true, filter: source => !ignored.has(path.basename(source)) });
}
await writeFile(path.join(preview, 'build-profile.json5'), signing, { mode: 0o600 });
await writeFile(path.join(preview, '.gitignore'), '*\n');
for (const [source, target] of [['PreviewRuntime.ets', 'Runtime.ets'], ['PreviewPorts.ts', 'PreviewPorts.ts']]) {
  let text = await readFile(path.join(root, 'tests/fixtures', source), 'utf8');
  text = text.replaceAll('../../entry/src/main/ets/', '../').replace("PREVIEW_SCENE = 'market'", `PREVIEW_SCENE = '${scene}'`).replace("PREVIEW_THEME = 'dark'", `PREVIEW_THEME = '${theme}'`).replace("PREVIEW_REGISTRATION = 'open'", `PREVIEW_REGISTRATION = '${registration}'`);
  await writeFile(path.join(preview, 'entry/src/main/ets/platform', target), text);
}
console.log(`Offline UI preview: ${scene}, ${theme}, registration=${registration}. Build with scripts/build-debug.sh --preview. Restore the normal signed app after checking.`);
