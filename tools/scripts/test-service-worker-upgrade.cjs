// Run after a build, with an earlier production dist as the first argument.
// Requires Playwright on NODE_PATH; all HTTP/API traffic stays on localhost.
const http = require('node:http')
const fs = require('node:fs')
const path = require('node:path')
const os = require('node:os')
const assert = require('node:assert/strict')
const { chromium, webkit } = require('playwright')

assert.ok(process.argv[2], 'Usage: node scripts/test-service-worker-upgrade.cjs /path/to/previous-dist [current-dist]')
const previous = path.resolve(process.argv[2])
const current = path.resolve(process.argv[3] || 'dist')
const entryOf = dir => fs.readFileSync(path.join(dir, 'index.html'), 'utf8').match(/src="(\/assets\/[^\"]+\.js)"/)[1]
const oldEntry = entryOf(previous)
const newEntry = entryOf(current)
let release = 0
let blockOptionalAsset = false
const requests = []

const server = http.createServer((req, res) => {
  const pathname = new URL(req.url, 'http://localhost').pathname
  requests.push({ pathname, release })
  res.setHeader('Cache-Control', 'no-store')
  // A local CSP blocks external calls without browser routing that alters caches.
  res.setHeader('Content-Security-Policy', "default-src 'self'; script-src 'self' 'unsafe-inline'; style-src 'self' 'unsafe-inline'; img-src 'self' data:; connect-src 'self'")
  if (pathname === '/fixture.html') {
    res.setHeader('Content-Type', 'text/html')
    return res.end('<!doctype html><html><body>Isolated upgrade fixture</body></html>')
  }
  if (/^\/(api|v1)\//.test(pathname)) {
    let data = null
    const route = pathname.replace(/^\/(api|v1)/, '')
    if (route === '/auth/refresh') data = { token: 'fixture-token' }
    else if (route === '/api/info') data = { alias: '升级测试', status: 1 }
    else if (route === '/account/version') data = { version: 'FIXTURE', lead_trading_enabled: true }
    else if (route === '/account/profile') data = { bound: true, display_name: '升级测试' }
    else if (route === '/account/info') data = { balance: '600', stop_loss_amount: '120' }
    else if (route === '/account/capital-collect-account') data = { account_type: 'sub' }
    else if (route === '/account/transfer-history') data = { items: [], summary: {}, pagination: { total: 0 } }
    res.setHeader('Content-Type', 'application/json')
    return res.end(JSON.stringify({ code: 0, data, release }))
  }
  if (blockOptionalAsset && /assets\/StrategyEditorPage-/.test(pathname)) {
    res.writeHead(503)
    return res.end('simulated optional asset outage')
  }
  const dir = release === 0 ? previous : current
  let file = path.join(dir, pathname)
  if (pathname === '/' || !path.extname(pathname)) file = path.join(dir, 'index.html')
  if (!file.startsWith(dir + path.sep) || !fs.existsSync(file)) {
    res.writeHead(404)
    return res.end('not found')
  }
  res.setHeader('Content-Type', file.endsWith('.js') ? 'application/javascript' : file.endsWith('.css') ? 'text/css' : file.endsWith('.html') ? 'text/html; charset=utf-8' : 'application/octet-stream')
  if (file.endsWith('index.html') && release === 3) {
    return res.end(fs.readFileSync(file, 'utf8').replace('<head>', '<head><meta name="upgrade-fixture" content="third-release">'))
  }
  if (pathname === '/sw.js' && release >= 2) {
    return res.end(fs.readFileSync(file, 'utf8') + '\n/* next-worker-release */')
  }
  res.end(fs.readFileSync(file))
})

async function main() {
  await new Promise(resolve => server.listen(0, '127.0.0.1', resolve))
  const origin = `http://127.0.0.1:${server.address().port}`
  const useWebKit = process.env.SW_BROWSER === 'webkit'
  // Use regular disk-backed storage, like ordinary Safari, throughout the test.
  const browserProfile = fs.mkdtempSync(path.join(os.tmpdir(), 'tradetools-sw-browser-'))
  const context = await (useWebKit ? webkit : chromium).launchPersistentContext(browserProfile, {
    headless: true,
    ...(!useWebKit && { executablePath: process.env.CHROME_EXECUTABLE || '/Applications/Google Chrome.app/Contents/MacOS/Google Chrome' }),
    serviceWorkers: 'allow', viewport: { width: 390, height: 844 }, isMobile: true, hasTouch: true,
  })
  try {
    await context.addCookies([{ name: 'auth-fixture', value: 'preserved', url: origin, httpOnly: true }])
    await context.addInitScript(() => {
      const initialController = navigator.serviceWorker.controller
      navigator.serviceWorker.addEventListener('controllerchange', () => {
        window.fixtureUpgraded = !!initialController && navigator.serviceWorker.controller !== initialController
      })
    })
    const page = await context.newPage()
    const errors = []
    page.on('pageerror', error => errors.push(error.message))
    const reload = async () => {
      try {
        await page.reload()
      } catch (error) {
        // The old app's own update-triggered reload can replace our navigation.
        // Every caller still verifies the actual document and rendered app below.
        if (!/Navigation canceled by policy check|net::ERR_ABORTED/.test(error.message)) throw error
        await page.waitForLoadState('domcontentloaded')
      }
    }
    await page.goto(origin + '/fixture.html')
    await page.evaluate(() => {
      localStorage.setItem('auth-storage', JSON.stringify({ state: { user: { id: 'fixture', email: 'fixture@example.com' }, isAuthenticated: true }, version: 0 }))
      sessionStorage.setItem('upgrade-fixture', 'preserved')
    })
    await page.goto(origin + '/profile')
    await page.getByRole('heading', { name: '升级测试', exact: true }).waitFor()
    await page.evaluate(() => navigator.serviceWorker.ready)
    await page.waitForFunction(() => !!navigator.serviceWorker.controller)
    await reload()
    await page.waitForFunction(entry => !!document.querySelector(`script[src="${entry}"]`), oldEntry)

    // Do not replace the user's cache or call the manual recovery endpoint.
    release = 1
    blockOptionalAsset = true
    await reload()
    // Existing pages cannot replace their HTML retroactively. Once their normal
    // startup installs the replacement worker, the next normal visit must be fresh.
    await page.waitForFunction(entry => (window.fixtureUpgraded && navigator.serviceWorker.controller?.state === 'activated') || !!document.querySelector(`script[src="${entry}"]`), newEntry, { timeout: 15000 })
    if (!(await page.locator(`script[src="${newEntry}"]`).count())) await reload()
    try {
      await page.waitForFunction(entry => !!document.querySelector(`script[src="${entry}"]`), newEntry, { timeout: 15000 })
    } catch (error) {
      console.error(JSON.stringify({ errors, requests: requests.slice(-30), state: await page.evaluate(async () => ({ scripts: Array.from(document.scripts).map(script => script.src), controller: navigator.serviceWorker.controller?.state, registrations: (await navigator.serviceWorker.getRegistrations()).map(registration => ({ active: registration.active?.state, installing: registration.installing?.state, waiting: registration.waiting?.state })) })) }))
      throw error
    }
    await page.getByRole('heading', { name: '升级测试', exact: true }).waitFor()

    // Updating a worker must not reload a live form or interrupt an operation.
    release = 2
    await page.evaluate(async () => {
      document.body.dataset.openForm = 'preserved'
      window.fixtureController = navigator.serviceWorker.controller
      await (await navigator.serviceWorker.getRegistration()).update()
    })
    await page.waitForFunction(() => navigator.serviceWorker.controller !== window.fixtureController && navigator.serviceWorker.controller?.state === 'activated')
    await page.evaluate(() => new Promise(resolve => requestAnimationFrame(() => requestAnimationFrame(resolve))))
    assert.equal(await page.evaluate(() => document.body.dataset.openForm), 'preserved')

    // An HTML-only deployment must work even when sw.js itself has not changed.
    release = 3
    await reload()
    await page.waitForFunction(() => document.querySelector('meta[name="upgrade-fixture"]')?.content === 'third-release', null, { timeout: 5000 })
    await page.getByRole('heading', { name: '升级测试', exact: true }).waitFor()
    const privateResponse = await page.evaluate(() => fetch('/api/private-fixture').then(r => r.json()))
    assert.equal(privateResponse.release, 3)
    const oldChunk = '/assets/' + fs.readdirSync(path.join(previous, 'assets')).find(name => name.startsWith('StrategyEditorPage-'))
    assert.equal(await page.evaluate(url => fetch(url).then(response => response.status), oldChunk), 200)
    assert.ok((await context.cookies()).some(cookie => cookie.name === 'auth-fixture' && cookie.value === 'preserved'))
    assert.ok(await page.evaluate(() => localStorage.getItem('auth-storage')?.includes('fixture@example.com')))
    assert.equal(await page.evaluate(() => sessionStorage.getItem('upgrade-fixture')), 'preserved')
    assert.deepEqual(errors, [])
    assert.ok(!requests.some(request => request.pathname.includes('frontend-refresh')))
    assert.ok(!requests.some(request => request.release > 0 && /assets\/StrategyEditorPage-/.test(request.pathname)))
    console.log(JSON.stringify({ result: 'PASS', browser: useWebKit ? 'webkit' : 'chromium', oldEntry, newEntry, ordinaryOpenUpgraded: true, optionalAssetOutageTolerated: true, livePageNotReloaded: true, nextReleaseHtml: true, oldChunkPreserved: true, accountStatePreserved: true }))
  } finally {
    await context.close()
    fs.rmSync(browserProfile, { recursive: true, force: true })
    server.close()
  }
}

main().catch(error => { console.error(error); server.close(); process.exitCode = 1 })
