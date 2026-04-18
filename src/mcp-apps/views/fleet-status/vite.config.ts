import { defineConfig } from "vite";
import react from "@vitejs/plugin-react";
import { viteSingleFile } from "vite-plugin-singlefile";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

// Entrypoint is fleet-status.html so the final artifact lands at
// <repo>/dist/mcp-apps/views/fleet-status.html without any post-build rename.
const VIEW_ROOT = dirname(fileURLToPath(import.meta.url));
const OUT_DIR = resolve(VIEW_ROOT, "..", "..", "..", "..", "dist", "mcp-apps", "views");

export default defineConfig({
  root: VIEW_ROOT,
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
      input: resolve(VIEW_ROOT, "fleet-status.html"),
      output: {
        inlineDynamicImports: true,
      },
    },
  },
});
