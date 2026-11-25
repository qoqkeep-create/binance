import { execFileSync } from "node:child_process";
import { mkdtempSync, rmSync, symlinkSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { fileURLToPath } from "node:url";

const root = fileURLToPath(new URL("../", import.meta.url));
const output = mkdtempSync(join(tmpdir(), "trade-analysis-tests-"));
try {
  execFileSync(process.execPath, [
    join(root, "node_modules/typescript/bin/tsc"), "--ignoreConfig",
    "--target", "ES2020", "--module", "ESNext", "--moduleResolution", "Bundler",
    "--lib", "ES2020,DOM", "--skipLibCheck", "--outDir", output,
    "tests/contractAnalysis.test.ts", "tests/analysisIndicators.test.ts", "tests/compactIndicators.test.ts", "tests/accountPreferences.test.ts", "tests/networkReliability.test.ts",
  ], { cwd: root, stdio: "inherit" });
  writeFileSync(join(output, "package.json"), '{"type":"module"}');
  symlinkSync(join(root, "node_modules"), join(output, "node_modules"), "dir");
  execFileSync(process.execPath, [join(output, "tests/contractAnalysis.test.js")], { stdio: "inherit" });
  execFileSync(process.execPath, [join(output, "tests/analysisIndicators.test.js")], { stdio: "inherit" });
  execFileSync(process.execPath, [join(output, "tests/compactIndicators.test.js")], { stdio: "inherit" });
  execFileSync(process.execPath, [join(output, "tests/accountPreferences.test.js")], { stdio: "inherit" });
  execFileSync(process.execPath, [join(output, "tests/networkReliability.test.js")], { stdio: "inherit" });
} finally {
  rmSync(output, { recursive: true, force: true });
}
