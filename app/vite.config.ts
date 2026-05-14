import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import wasm from 'vite-plugin-wasm';
import topLevelAwait from 'vite-plugin-top-level-await';
import path from 'path';

export default defineConfig({
  plugins: [react(), wasm(), topLevelAwait()],
  server: {
    port: 3000,
    // In dev mode the frontend runs on Vite (3000) but the CLI HTTP server
    // (which owns `/api/analyze`, `/api/audit`, `/api/files`, …) lives on
    // 3099. Without this proxy every fetch falls through Vite's SPA
    // fallback and returns `index.html`, blowing up `response.json()` with
    // `Unexpected token '<', "<!DOCTYPE "...`. Override the upstream with
    // `FLOWSCOPE_API_PROXY=http://localhost:9099` if you run the CLI on a
    // different port.
    proxy: {
      '/api': process.env.FLOWSCOPE_API_PROXY ?? 'http://localhost:3099',
    },
  },
  resolve: {
    alias: {
      '@pondpilot/flowscope-core': path.resolve(__dirname, '../packages/core/src'),
      '@pondpilot/flowscope-react': path.resolve(__dirname, '../packages/react/src'),
      '@': path.resolve(__dirname, './src'),
    },
  },
  optimizeDeps: {
    exclude: ['@pondpilot/flowscope-core', '@pondpilot/flowscope-react'],
  },
  build: {
    target: 'esnext',
  },
  worker: {
    format: 'es',
  },
});
