import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const component = readFileSync(fileURLToPath(new URL("../src/CompactIndicatorStrip.tsx", import.meta.url)), "utf8");
const styles = readFileSync(fileURLToPath(new URL("../src/compact-indicators.css", import.meta.url)), "utf8");

for (const marker of ["onHeightChange", "role=\"slider\"", "MIN_INDICATOR_HEIGHT = 72", "MAX_INDICATOR_HEIGHT = 260", "saveIndicatorHeight"]) {
  if (!component.includes(marker)) throw new Error(`Compact indicator height contract missing: ${marker}`);
}
if (!styles.includes("cursor: ns-resize") || !styles.includes(".compact-indicator-resize:focus-visible")) {
  throw new Error("Compact indicator resize handle must support pointer and keyboard focus");
}

console.log("indicator layout contract tests passed");
