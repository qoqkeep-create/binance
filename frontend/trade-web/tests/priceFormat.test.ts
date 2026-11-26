import { priceScaleFormatter, minMoveFor } from "../src/lib/priceFormat.js";

const cases: Array<[number, string]> = [
  [0.0000123, "0.00001230"],
  [0.00012, "0.000120"],
  [0.001234, "0.001234"],
  [0.5, "0.5000"],
  [71.1, "71.100"],
  [486.34095, "486.34"],
  [108432.1, "108432.1"],
];
for (const [price, expected] of cases) {
  const got = priceScaleFormatter(price);
  if (got !== expected) throw new Error(`formatter(${price}) = ${got}, expected ${expected}`);
}
if (priceScaleFormatter(0.0000123) === "0.0000") throw new Error("tiny price must not collapse to zero");
if (minMoveFor(0.0000123) !== 0.00000001) throw new Error("tiny minMove must be 1e-8");
if (minMoveFor(0.0012) !== 0.000001) throw new Error("sub-0.01 minMove must be 1e-6");
if (minMoveFor(71.1) !== 0.0001) throw new Error("normal minMove stays 1e-4");

console.log("priceFormat tier tests passed");