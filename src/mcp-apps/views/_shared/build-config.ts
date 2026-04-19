import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const SHARED_ROOT = dirname(fileURLToPath(import.meta.url));
const VIEWS_ROOT = resolve(SHARED_ROOT, "..");
const OUT_DIR = resolve(
  VIEWS_ROOT,
  "..",
  "..",
  "..",
  "dist",
  "mcp-apps",
  "views",
);

export function createViewConfig(viewName: string, entryHtml = `${viewName}.html`) {
  const viewRoot = resolve(VIEWS_ROOT, viewName);
  return defineConfig({
    root: viewRoot,
    plugins: [
      react(),
      viteSingleFile({
        removeViteModuleLoader: true,
      }),
    ],
    build: {
      outDir: OUT_DIR,
      emptyOutDir: false,
      assetsInlineLimit: 100000000,
      cssCodeSplit: false,
      target: "es2020",
      sourcemap: false,
      minify: "esbuild",
      reportCompressedSize: false,
      rollupOptions: {
        input: resolve(viewRoot, entryHtml),
      },
    },
  });
}
