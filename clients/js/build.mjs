import * as esbuild from "esbuild";
import { execSync } from "child_process";
import { mkdirSync } from "fs";

mkdirSync("dist", { recursive: true });

// ESM bundle
await esbuild.build({
  entryPoints: ["src/core.ts"],
  bundle: true,
  format: "esm",
  target: "es2020",
  outfile: "dist/monlight.esm.js",
  minify: true,
  sourcemap: false,
  treeShaking: true,
});

// UMD/IIFE bundle for script tag usage
await esbuild.build({
  entryPoints: ["src/core.ts"],
  bundle: true,
  format: "iife",
  globalName: "MonlightSDK",
  target: "es2020",
  outfile: "dist/monlight.min.js",
  minify: true,
  sourcemap: false,
});

// Generate TypeScript declarations
execSync("npx tsc --emitDeclarationOnly", { stdio: "inherit" });

console.log("Build complete:");
console.log("  dist/monlight.esm.js  — ES module bundle");
console.log("  dist/monlight.min.js  — UMD/IIFE bundle for script tag");
console.log("  dist/monlight.d.ts    — TypeScript declarations");
