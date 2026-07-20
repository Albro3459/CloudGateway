import { defineConfig } from "vitest/config";

export default defineConfig({
  test: {
    // Emulator round-trips plus first-run seeding need a little headroom.
    testTimeout: 20000,
    hookTimeout: 30000,
    include: ["tests/**/*.test.ts"],
  },
});
