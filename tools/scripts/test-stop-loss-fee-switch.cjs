// Requires Playwright on NODE_PATH. Starts an isolated local Vite server and mocks all APIs.
const assert = require('node:assert/strict')
const path = require('node:path')
const { chromium, webkit } = require('playwright')

async function main() {
  const { createServer } = await import('vite')
  const server = await createServer({
    root: path.resolve(__dirname, '..'),
    server: { host: '127.0.0.1', port: 0, strictPort: true },
    logLevel: 'error',
  })
  let browser
  try {
    await server.listen()
    const origin = `http://127.0.0.1:${server.httpServer.address().port}`
    const useWebKit = process.env.SWITCH_BROWSER === 'webkit'
    browser = await (useWebKit ? webkit : chromium).launch({
      headless: true,
      ...(!useWebKit && { executablePath: process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }),
    })
    const page = await browser.newPage({ viewport: { width: 390, height: 844 }, serviceWorkers: 'block' })
    await page.route('**/*', async route => {
      const url = new URL(route.request().url())
      if (url.origin !== origin) return route.abort()
      if (!/^\/(api|v1)\//.test(url.pathname)) return route.continue()
      const endpoint = url.pathname.replace(/^\/(api|v1)/, '')
      const fixtures = {
        '/auth/refresh': { token: 'fixture-token' },
        '/api/info': { alias: '测试', status: 1 },
        '/account/version': { version: 'FIXTURE', lead_trading_enabled: true },
        '/account/info': { balance: '600', stop_loss_amount: '120' },
        '/strategy/list': [],
        '/trade/symbols': ['BTCUSDT'],
        '/trade/symbol/info': { symbol: 'BTCUSDT', current_price: '100', max_leverage: 100 },
      }
      assert.ok(Object.hasOwn(fixtures, endpoint), `Unexpected API request: ${endpoint}`)
      await route.fulfill({ json: { code: 0, data: fixtures[endpoint] } })
    })
    await page.addInitScript(() => {
      localStorage.setItem('auth-storage', JSON.stringify({
        state: { user: { id: 'fixture', email: 'fixture@example.com' }, isAuthenticated: true }, version: 0,
      }))
    })
    await page.goto(origin + '/trading')
    const toggle = page.getByText('止损含手续费', { exact: true }).locator('..').locator('button')
    await toggle.waitFor()
    const failures = []
    for (const width of [320, 390, 1280]) {
      await page.setViewportSize({ width, height: 844 })
      for (const theme of ['light', 'dark']) {
        await page.evaluate(theme => document.documentElement.classList.toggle('dark', theme === 'dark'), theme)
        for (const [index, enabled] of [false, true, false].entries()) {
          // Measure after the real CSS transition settles, without disabling animations.
          const geometry = await toggle.evaluate(async button => {
            const knob = button.firstElementChild
            await new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve)))
            await Promise.all(knob.getAnimations().map(animation => animation.finished))
            const track = button.getBoundingClientRect()
            const thumb = knob.getBoundingClientRect()
            return {
              trackWidth: track.width, trackHeight: track.height,
              thumbWidth: thumb.width, thumbHeight: thumb.height,
              left: thumb.left - track.left, right: track.right - thumb.right,
              top: thumb.top - track.top, bottom: track.bottom - thumb.bottom,
            }
          })
          console.log(JSON.stringify({ width, theme, enabled, ...geometry }))
          const near = (actual, expected, edge) => {
            if (Math.abs(actual - expected) >= 0.5) {
              failures.push(`${width}px ${theme} ${enabled ? 'on' : 'off'} ${edge}: expected ${expected}px, got ${actual}px`)
            }
          }
          near(geometry.trackWidth, 48, 'track width')
          near(geometry.trackHeight, 28, 'track height')
          near(geometry.thumbWidth, 24, 'thumb width')
          near(geometry.thumbHeight, 24, 'thumb height')
          near(enabled ? geometry.right : geometry.left, 2, 'active edge inset')
          near(geometry.top, 2, 'top inset')
          near(geometry.bottom, 2, 'bottom inset')
          if (geometry.left < 0 || geometry.right < 0) failures.push('Thumb must stay inside the track')
          if (index < 2) await toggle.click()
        }
      }
    }
    assert.deepEqual(failures, [], 'Switch geometry must stay aligned in both states')
  } finally {
    await browser?.close()
    await server.close()
  }
}

main().catch(error => {
  console.error(error)
  process.exitCode = 1
})
