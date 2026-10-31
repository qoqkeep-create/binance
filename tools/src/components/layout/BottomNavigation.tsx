import { useEffect, useRef } from 'react'
import { NavLink } from 'react-router-dom'
import { isStandaloneMode } from '@/shared/lib/device'
import { collectLayoutMetrics, sendLayoutDiagnostics } from '@/shared/lib/layoutDiagnostics'
import { useTradingMode } from '@/shared/hooks/useTradingMode'

function HoldingsIcon({ size = 24 }: { size?: number }) {
  return (
    <svg viewBox="0 0 1024 1024" width={size} height={size} fill="currentColor">
      <path d="M976.896 883.712q0 19.456-6.656 36.352t-18.944 29.696-28.672 19.968-35.84 7.168l-743.424 0q-19.456 0-36.864-7.168t-30.72-19.968-20.992-29.696-7.68-36.352l0-510.976q0-38.912 27.136-66.048t66.048-27.136l743.424 0q38.912 0 66.048 27.136t27.136 66.048l0 139.264-232.448 0q-38.912 0-66.048 26.624t-27.136 65.536q1.024 26.624 11.264 47.104 8.192 17.408 27.136 31.744t54.784 14.336l232.448 0 0 186.368zM837.632 232.448l-464.896 0q55.296-28.672 104.448-55.296 43.008-22.528 84.992-45.056t65.536-34.816q35.84-19.456 64-17.92t47.616 9.728q22.528 11.264 38.912 29.696zM698.368 604.16q0-19.456 13.312-32.768t32.768-13.312 32.768 13.312 13.312 32.768-13.312 33.28-32.768 13.824-32.768-13.824-13.312-33.28z" />
    </svg>
  )
}

function TradingIcon({ size = 24 }: { size?: number }) {
  return (
    <svg viewBox="0 0 1024 1024" width={size} height={size} fill="currentColor">
      <path d="M281.6 414.208H81.92c-22.528 0-40.96 18.432-40.96 40.96V921.6c0 22.528 18.432 40.96 40.96 40.96h199.68c22.528 0 40.96-18.432 40.96-40.96V455.168c0-22.528-18.432-40.96-40.96-40.96zM610.304 61.44H413.696c-22.528 0-40.96 18.432-40.96 40.96v819.2c0 22.528 18.432 40.96 40.96 40.96h196.096c22.528 0 40.96-18.432 40.96-40.96V102.4c0.512-22.528-17.92-40.96-40.448-40.96zM942.08 616.448h-199.68c-22.528 0-40.96 18.432-40.96 40.96V921.6c0 22.528 18.432 40.96 40.96 40.96h199.68c22.528 0 40.96-18.432 40.96-40.96v-264.192c0-22.528-18.432-40.96-40.96-40.96z" />
    </svg>
  )
}

function SignalsIcon({ size = 24 }: { size?: number }) {
  return (
    <svg viewBox="0 0 1024 1024" width={size} height={size} fill="currentColor">
      <path d="M576 64 192 608h236.8L384 960l448-544H595.2L576 64z" />
    </svg>
  )
}

function ProfileIcon({ size = 24 }: { size?: number }) {
  return (
    <svg viewBox="0 0 1024 1024" width={size} height={size} fill="currentColor">
      <path d="M508.995513 0c-281.106911 0-508.995513 227.888602-508.995513 508.995513s227.888602 508.995513 508.995513 508.995512 508.995513-227.888602 508.995512-508.995512c0-281.121049-227.888602-508.995513-508.995512-508.995513z m0 954.946275c-121.550956 0-231.677791-48.679765-312.113221-127.545792 20.359821-133.568906 124.081795-239.623776 256.5196-263.122402-68.827504-23.159296-118.468706-88.084501-118.468706-164.716604 0-96.044625 77.862175-173.892661 173.892661-173.892661 96.044625 0 173.892661 77.862175 173.892662 173.892661 0 76.632102-49.641201 141.557308-118.468706 164.716604 132.536776 23.512765 236.315305 129.694884 256.562016 263.391039-80.407152 78.710501-190.420877 127.277156-311.816306 127.277155z" />
    </svg>
  )
}

export function BottomNavigation() {
  const isLead = useTradingMode() === 'lead'
  const standalone = isStandaloneMode()
  const navRef = useRef<HTMLElement | null>(null)
  const bottomPadding = standalone
    ? 'calc(8px + max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))'
    : 'max(8px, max(var(--app-safe-bottom, 0px), env(safe-area-inset-bottom, 0px)))'

  useEffect(() => {
    const report = (reason: string) => {
      const navHeight = navRef.current?.offsetHeight || 0
      void sendLayoutDiagnostics(reason, collectLayoutMetrics(navHeight))
    }

    report('bottom-nav-mounted')

    const handleLayoutSync = (event: Event) => {
      const detail = (event as CustomEvent<{ reason?: string }>).detail
      report(detail?.reason ? `layout-sync:${detail.reason}` : 'layout-sync')
    }

    const handleResize = () => report('window-resize')

    window.addEventListener('app:layout-sync', handleLayoutSync as EventListener)
    window.addEventListener('resize', handleResize, { passive: true })
    window.visualViewport?.addEventListener('resize', handleResize, { passive: true })

    return () => {
      window.removeEventListener('app:layout-sync', handleLayoutSync as EventListener)
      window.removeEventListener('resize', handleResize)
      window.visualViewport?.removeEventListener('resize', handleResize)
    }
  }, [])

  return (
    <nav
      ref={navRef}
      className="fixed bottom-0 left-0 right-0 border-t pt-0.5 transition-colors bg-t-surface border-t-border"
      style={{ paddingBottom: bottomPadding }}
    >
      <div className="flex justify-around items-center max-w-md mx-auto">
        <NavLink
          to="/holdings"
          replace
          className={({ isActive }) =>
            `flex flex-col items-center gap-0.5 px-4 py-0.5 transition-colors ${isActive ? 'text-[var(--t-brand)]' : 'text-t-text-muted'}`
          }
        >
          <HoldingsIcon size={29} />
          <span className="text-xs">{isLead ? '带单持仓' : '持仓'}</span>
        </NavLink>

        <NavLink
          to="/trading"
          replace
          className={({ isActive }) =>
            `flex flex-col items-center gap-0.5 px-4 py-0.5 transition-colors ${isActive ? 'text-[var(--t-brand)]' : 'text-t-text-muted'}`
          }
        >
          <TradingIcon size={29} />
          <span className="text-xs">{isLead ? '带单开仓' : '开仓'}</span>
        </NavLink>

        {!isLead && <NavLink
          to="/signals"
          replace
          className={({ isActive }) =>
            `flex flex-col items-center gap-0.5 px-4 py-0.5 transition-colors ${isActive ? 'text-[var(--t-brand)]' : 'text-t-text-muted'}`
          }
        >
          <SignalsIcon size={29} />
          <span className="text-xs">信号</span>
        </NavLink>}

        <NavLink
          to="/profile"
          replace
          className={({ isActive }) =>
            `flex flex-col items-center gap-0.5 px-4 py-0.5 transition-colors ${isActive ? 'text-[var(--t-brand)]' : 'text-t-text-muted'}`
          }
        >
          <ProfileIcon size={29} />
          <span className="text-xs">我的</span>
        </NavLink>
      </div>
    </nav>
  )
}
