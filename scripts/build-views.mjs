import { build } from "vite";
import { fileURLToPath } from "node:url";
import { dirname, resolve } from "node:path";

const REPO_ROOT = resolve(dirname(fileURLToPath(import.meta.url)), "..");
const VIEW_CONFIGS = [
  "src/mcp-apps/views/fleet-status/vite.config.ts",
  "src/mcp-apps/views/commander/vite.config.ts",
  "src/mcp-apps/views/agent-catalog/vite.config.ts",
];

for (const relativeConfig of VIEW_CONFIGS) {
  const configFile = resolve(REPO_ROOT, relativeConfig);
  process.stdout.write(`[build:views] ${relativeConfig}\n`);
  await build({
    configFile,
    logLevel: "info",
  });
}
