import { readFileSync } from "node:fs";
import { defineConfig } from "vite";

const { version } = JSON.parse(readFileSync(new URL("./package.json", import.meta.url), "utf8")) as { version: string };

// Tauri expects a fixed dev port and a relative base for the bundled files.
export default defineConfig({
  clearScreen: false,
  base: "./",
  define: { __APP_VERSION__: JSON.stringify(version) },
  server: { port: 1420, strictPort: true },
  // One ~600 KB bundle (CodeMirror + Markdown) loads from disk, not the network.
  build: { target: "es2022", outDir: "dist", emptyOutDir: true, chunkSizeWarningLimit: 1000 },
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
