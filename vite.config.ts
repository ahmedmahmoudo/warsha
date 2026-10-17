import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { fileURLToPath } from 'node:url'
import { defineConfig } from 'vite'
import { API_PORT, WEB_PORT } from './shared/ports'

export default defineConfig({
  plugins: [react(), tailwindcss()],
  resolve: { alias: { '@': fileURLToPath(new URL('./src', import.meta.url)) } },
  server: {
    port: WEB_PORT,
    strictPort: true,
    proxy: { '/api': `http://127.0.0.1:${API_PORT}` },
  },
})
