import { defineConfig } from 'vitest/config'
import { loadEnv } from 'vite'
import path from 'path'
import { fileURLToPath } from 'url'
import tailwindcss from '@tailwindcss/vite'
import react from '@vitejs/plugin-react'
import { VitePWA } from 'vite-plugin-pwa'

const __dirname = path.dirname(fileURLToPath(import.meta.url))

export default defineConfig(({ mode }) => {
  const env = loadEnv(mode, __dirname, '')
  const apiProxyTarget = process.env.DEV_API_PROXY_TARGET || env.DEV_API_PROXY_TARGET || 'http://127.0.0.1:8000'

  return {
    plugins: [
      react(),
      tailwindcss(),
      // HTML follows the server's no-store policy. Only immutable legacy chunks
      // use SW caches, so one failed optional download cannot block an upgrade.
      VitePWA({
        strategies: 'injectManifest',
        srcDir: 'src',
        filename: 'sw.js',
        registerType: 'autoUpdate',
        manifest: false,
        injectManifest: {
          injectionPoint: undefined,
        },
      }),
    ],
    resolve: {
      alias: {
        '@': path.resolve(__dirname, './src'),
      },
    },
    build: {
      target: 'es2020',
      rollupOptions: {
        output: {
          manualChunks: {
            'vendor-react': ['react', 'react-dom', 'react-router-dom'],
            'vendor-query': ['@tanstack/react-query', 'zustand'],
            'vendor-ui': ['lucide-react', '@mui/material'],
            'vendor-charts': ['recharts'],
            'vendor-core': ['axios', 'dayjs', 'decimal.js', 'zod'],
          },
        },
      },
    },
    server: {
      port: 5173,
      proxy: {
        '/api': {
          target: apiProxyTarget,
          changeOrigin: true,
          rewrite: path => path.replace(/^\/api/, '/v1'),
        },
        '/v1': {
          target: apiProxyTarget,
          changeOrigin: true,
        },
      },
    },
    test: {
      environment: 'jsdom',
      setupFiles: ['./src/test/setup.ts'],
      clearMocks: true,
      restoreMocks: true,
    },
  }
})
