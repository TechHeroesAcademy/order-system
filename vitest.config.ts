import { defineConfig } from "vitest/config";
import react from "@vitejs/plugin-react";
import tsconfigPaths from "vite-tsconfig-paths";
import { fileURLToPath } from "node:url";

export default defineConfig({
  plugins: [tsconfigPaths(), react()],
  resolve: {
    alias: {
      // `import "server-only"` throws outside a React Server Component, so
      // the database layer could not be imported by a test at all — which is
      // how a result-shape bug in src/lib/db/query-builder.ts reached
      // production with 125 tests passing. Next does the same substitution
      // for its server bundle; this makes those modules testable without
      // weakening the guard in the app itself.
      // Resolved by path, not as a subpath import: the package's `exports`
      // field does not expose ./empty.js.
      "server-only": fileURLToPath(
        new URL("./node_modules/server-only/empty.js", import.meta.url),
      ),
    },
  },
  test: {
    environment: "jsdom",
    globals: true,
    setupFiles: ["./vitest.setup.ts"],
    exclude: ["node_modules", ".next", "e2e"],
  },
});
