import { cp, mkdir, readFile, writeFile, readdir } from 'node:fs/promises';
import { fileURLToPath } from 'node:url';
import path from 'node:path';
const root = fileURLToPath(new URL('../', import.meta.url));
const local = path.join(root, '.local-build', 'project');
await mkdir(local, { recursive: true, mode: 0o700 });
let existing;
try { existing = await readFile(path.join(local, 'build-profile.json5')); } catch (e) { if (e.code !== 'ENOENT') throw e; }
const ignored = new Set(['.git', '.local-build', '.hvigor', '.idea', 'node_modules', 'oh_modules', 'build', 'local.properties']);
for (const name of await readdir(root)) {
  if (ignored.has(name) || name.startsWith('signing')) continue;
  await cp(path.join(root, name), path.join(local, name), { recursive: true, force: true, filter: source => !ignored.has(path.basename(source)) });
}
// DevEco writes signing passwords into build-profile.json5. Preserve them ONLY in this ignored workspace.
if (existing) await writeFile(path.join(local, 'build-profile.json5'), existing, { mode: 0o600 });
await writeFile(path.join(local, '.gitignore'), '*\n');
console.log(local);
