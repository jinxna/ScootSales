import assert from 'node:assert/strict'
import { spawn } from 'node:child_process'
import { cpSync, existsSync, mkdirSync, realpathSync, rmSync, writeFileSync } from 'node:fs'
import { createServer } from 'node:net'
import { dirname, isAbsolute, join, relative, resolve, sep } from 'node:path'
import { fileURLToPath } from 'node:url'
import { chromium } from 'playwright-core'
import { initMarketing } from '../src/lib/marketing.js'

const ROOT = realpathSync(dirname(dirname(fileURLToPath(import.meta.url))))
const OUT = resolve(ROOT, 'site-static')
const PORT = 4318
const BASE = `http://127.0.0.1:${PORT}/`
const ROUTES = ['/', '/product', '/intelligence', '/context', '/privacy', '/terms', '/delete-account']
const names = Object.fromEntries(ROUTES.map((route) => [route, route === '/' ? 'index.html' : route.slice(1) + '.html']))
const entry = join(ROOT, '.output/server/index.mjs')
assert.ok(existsSync(entry), 'No production build found. Run npm run build first.')
let server
let browser
let verifier
let serverError
let serverLog = ''
const watchdog = setTimeout(() => {
  console.error('Static export exceeded 12 minutes')
  verifier?.kill()
  server?.kill()
  browser?.close().finally(() => process.exit(1))
  setTimeout(() => process.exit(1), 3000)
}, 12 * 60 * 1000)
const sleep = (ms) => new Promise((done) => setTimeout(done, ms))

for (const signal of ['SIGINT', 'SIGTERM']) process.once(signal, () => {
  verifier?.kill()
  server?.kill()
  browser?.close().finally(() => process.exit(signal === 'SIGINT' ? 130 : 143))
  setTimeout(() => process.exit(signal === 'SIGINT' ? 130 : 143), 3000)
})

async function fetchText(url) {
  const response = await fetch(url, { signal: AbortSignal.timeout(10000) })
  assert.ok(response.ok, `${url}: HTTP ${response.status}`)
  return response.text()
}

async function requireFreePort() {
  const probe = createServer()
  await new Promise((done, reject) => { probe.once('error', reject); probe.listen({ port: PORT, host: '127.0.0.1', exclusive: true }, done) })
  await new Promise((done, reject) => probe.close((error) => error ? reject(error) : done()))
}

async function waitForServer() {
  const deadline = Date.now() + 25000
  while (Date.now() < deadline) {
    if (serverError) throw serverError
    if (server.exitCode !== null) throw new Error(`Export server exited: ${serverLog}`)
    try {
      const response = await fetch(BASE, { signal: AbortSignal.timeout(1500) })
      if (response.ok) return
    } catch {}
    await sleep(200)
  }
  throw new Error(`Export server did not start on ${BASE}: ${serverLog}`)
}

function localURL(value, base = BASE) {
  if (!value || value.startsWith('#')) return value
  const url = new URL(value, base)
  if (url.origin !== new URL(BASE).origin) return value
  const route = url.pathname.replace(/\/$/, '') || '/'
  return (names[route] || url.pathname.slice(1)) + url.search + url.hash
}

function portableCSS(css, url) {
  return css.replace(/url\(\s*(['"]?)(.*?)\1\s*\)/g, (_, quote, value) => `url(${quote}${localURL(value, url)}${quote})`)
}

try {
  console.log(`CHECK export server: ${BASE}`)
  await requireFreePort()
  server = spawn(process.execPath, [entry], { cwd: ROOT, env: { ...process.env, PORT: String(PORT), HOST: '127.0.0.1' }, stdio: ['ignore', 'pipe', 'pipe'], windowsHide: true })
  server.on('error', (error) => { serverError = error })
  for (const stream of [server.stdout, server.stderr]) stream.on('data', (chunk) => { serverLog = (serverLog + chunk).slice(-4000) })
  await waitForServer()
  console.log('PASS export server ready; opening detached HTML parser')
  browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
  const page = await browser.newPage()
  page.setDefaultTimeout(15000)
  const pages = []
  for (const route of ROUTES) {
    console.log(`CHECK export ${route}: fetch, inline CSS, rewrite references`)
    const html = await fetchText(new URL(route, BASE))
    const stylesheets = await page.evaluate((html) => [...new DOMParser().parseFromString(html, 'text/html').querySelectorAll('link[rel="stylesheet"]')].map((link) => link.getAttribute('href')), html)
    assert.ok(stylesheets.length, `${route}: missing built stylesheet`)
    const css = {}
    for (const href of stylesheets) {
      const url = new URL(href, BASE)
      assert.equal(url.origin, new URL(BASE).origin, 'Stylesheets must be local')
      css[href] = portableCSS(await fetchText(url), url)
    }
    const markup = await page.evaluate(({ html, css, names, base, controller }) => {
      const doc = new DOMParser().parseFromString(html, 'text/html')
      const rewrite = (value) => {
        if (!value || value.startsWith('#')) return value
        const url = new URL(value, base)
        if (url.origin !== new URL(base).origin) return value
        const route = url.pathname.replace(/\/$/, '') || '/'
        return (names[route] || url.pathname.slice(1)) + url.search + url.hash
      }
      const rewriteCSS = (text) => text.replace(/url\(\s*(['"]?)(.*?)\1\s*\)/g, (_, quote, value) => `url(${quote}${rewrite(value)}${quote})`)
      doc.querySelectorAll('script,link[rel="preload"],link[rel="modulepreload"],link[rel="prefetch"],base').forEach((node) => node.remove())
      doc.querySelectorAll('link[rel="stylesheet"]').forEach((link) => {
        const style = doc.createElement('style')
        style.textContent = css[link.getAttribute('href')]
        link.replaceWith(style)
      })
      doc.querySelectorAll('[href],[src],[poster],[srcset],[style],style').forEach((node) => {
        for (const attribute of ['href', 'src', 'poster']) {
          if (node.hasAttribute(attribute)) node.setAttribute(attribute, rewrite(node.getAttribute(attribute)))
        }
        if (node.hasAttribute('srcset')) {
          const value = node.getAttribute('srcset')
          if (!value.startsWith('data:')) node.setAttribute('srcset', value.split(',').map((candidate) => {
            const [url, ...descriptor] = candidate.trim().split(/\s+/)
            return [rewrite(url), ...descriptor].join(' ')
          }).join(', '))
        }
        if (node.hasAttribute('style')) node.setAttribute('style', rewriteCSS(node.getAttribute('style')))
        if (node.tagName === 'STYLE' && !Object.values(css).includes(node.textContent)) node.textContent = rewriteCSS(node.textContent)
      })
      if (doc.querySelectorAll('main h1').length !== 1) throw new Error('Export requires exactly one main h1')
      if (doc.querySelector('script,link[rel="stylesheet"]')) throw new Error('Unremoved hydration or stylesheet')
      const script = doc.createElement('script')
      script.textContent = `(${controller})(document);`
      doc.body.append(script)
      return '<!DOCTYPE html>\n' + doc.documentElement.outerHTML + '\n'
    }, { html, css, names, base: BASE, controller: initMarketing.toString() })
    pages.push([names[route], markup])
    console.log(`PASS export ${route}: HTML prepared`)
  }
  await browser.close()
  browser = undefined

  assert.equal(relative(ROOT, OUT), 'site-static', 'Unsafe export destination')
  const resolvedTarget = existsSync(OUT) ? realpathSync(OUT) : resolve(realpathSync(dirname(OUT)), 'site-static')
  const targetRelative = relative(ROOT, resolvedTarget)
  assert.ok(targetRelative && !isAbsolute(targetRelative) && !targetRelative.startsWith('..' + sep) && targetRelative !== '..', 'Export target escapes website')
  assert.equal(resolvedTarget, OUT, 'Refusing to remove a redirected export folder')
  rmSync(resolvedTarget, { recursive: true, force: true })
  mkdirSync(OUT, { recursive: true })
  cpSync(join(ROOT, 'public/product'), join(OUT, 'product'), { recursive: true })
  cpSync(join(ROOT, 'public/icon.svg'), join(OUT, 'icon.svg'))
  cpSync(join(ROOT, 'public/.well-known'), join(OUT, '.well-known'), { recursive: true })
  const assets = join(ROOT, '.output/public/assets')
  if (existsSync(assets)) cpSync(assets, join(OUT, 'assets'), { recursive: true, filter: (file) => !/\.(?:[cm]?js|map|css)$/i.test(file) })
  for (const [name, html] of pages) {
    writeFileSync(join(OUT, name), html)
    console.log(`${name}: ${Buffer.byteLength(html)} bytes`)
  }
  server.kill()
  console.log('CHECK export: starting file:// browser verification')
  await new Promise((done, reject) => {
    verifier = spawn(process.execPath, [join(ROOT, 'scripts/verify.mjs'), '--static'], { cwd: ROOT, stdio: 'inherit', windowsHide: true })
    verifier.once('error', reject)
    verifier.once('exit', (code, signal) => code === 0 ? done() : reject(new Error(`Static browser verification failed (${signal || code})`)))
  })
  console.log(`Portable six-page export verified: ${OUT}`)
} finally {
  verifier?.kill()
  server?.kill()
  if (browser) await Promise.race([browser.close(), sleep(5000)])
  clearTimeout(watchdog)
}
