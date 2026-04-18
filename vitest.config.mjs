import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    include: ["src/mcp-apps/**/*.{test,spec}.{js,mjs,ts,tsx}"],
    environment: "node",
    testTimeout: 10000,
  },
});
