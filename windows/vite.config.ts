import { defineConfig } from "vite";

// Tauri expects a fixed dev port and a relative base for the bundled files.
export default defineConfig({
  clearScreen: false,
  base: "./",
  server: { port: 1420, strictPort: true },
  // One ~600 KB bundle (CodeMirror + Markdown) loads from disk, not the network.
  build: { target: "es2022", outDir: "dist", emptyOutDir: true, chunkSizeWarningLimit: 1000 },
  test: { environment: "node", include: ["tests/**/*.test.ts"] },
});
