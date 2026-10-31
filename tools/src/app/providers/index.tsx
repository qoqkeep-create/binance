import { ReactNode } from 'react'
import { ErrorBoundary, FallbackProps } from 'react-error-boundary'
import { Toaster } from 'react-hot-toast'
import { QueryProvider } from './QueryProvider'

interface AppProvidersProps {
  children: ReactNode
}

// 错误回退组件
function ErrorFallback({ error, resetErrorBoundary }: FallbackProps) {
  const chunkLoadFailed = /Failed to fetch dynamically imported module|Importing a module script failed|Loading chunk|error loading dynamically imported module/i.test(error.message || '')
  return (
    <div className="flex min-h-screen flex-col items-center justify-center bg-[#0B0E11] p-4 text-white">
      <div className="w-full max-w-md rounded-lg bg-[#1A1D23] p-6 text-center">
        <h2 className="mb-4 text-xl font-semibold text-[#F6465D]">出错了</h2>
        <p className="mb-4 text-sm text-gray-400">{error.message || '发生了未知错误'}</p>
        <button
          onClick={() => chunkLoadFailed ? window.location.reload() : resetErrorBoundary()}
          className="rounded-lg bg-[#F0B90B] px-6 py-2 font-medium text-black transition-colors hover:bg-[#D9A70A]"
        >
          重试
        </button>
      </div>
    </div>
  )
}

export function AppProviders({ children }: AppProvidersProps) {
  return (
    <ErrorBoundary FallbackComponent={ErrorFallback}>
      <QueryProvider>
        {children}
        <Toaster
          position="top-center"
          toastOptions={{
            duration: 3000,
            style: {
              background: '#1A1D23',
              color: '#fff',
              border: '1px solid #2B2F36',
            },
            success: {
              iconTheme: {
                primary: '#0ECB81',
                secondary: '#fff',
              },
            },
            error: {
              iconTheme: {
                primary: '#F6465D',
                secondary: '#fff',
              },
            },
          }}
        />
      </QueryProvider>
    </ErrorBoundary>
  )
}
