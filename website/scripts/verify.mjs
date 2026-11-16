import assert from 'node:assert/strict'
import { mkdirSync, readFileSync, realpathSync, statSync, writeFileSync } from 'node:fs'
import { dirname, isAbsolute, join, relative, sep } from 'node:path'
import { fileURLToPath, pathToFileURL } from 'node:url'
import { chromium } from 'playwright-core'

const ROOT = dirname(dirname(fileURLToPath(import.meta.url)))
const OUT = join(ROOT, 'qa-output')
const STATIC = process.argv.includes('--static')
const MODE = STATIC ? 'static' : 'live'
const BASE = 'http://127.0.0.1:4317/'
const FOLDER = join(ROOT, 'site-static')
const ROUTES = ['/', '/product', '/intelligence', '/context', '/privacy', '/terms', '/delete-account']
const GROUPS = {
  workday: ['Plan', 'Brief', 'Visit', 'Order', 'Follow-up'],
  'copilot-example': ['Next stop', 'Visit brief', 'My orders'],
  'team-role': ['Salesperson', 'Administrator', 'Supervisor', 'Branch manager'],
}
const AXE = readFileSync(join(ROOT, 'node_modules/axe-core/axe.min.js'), 'utf8')
const checkedAssets = new Set()
const report = { mode: MODE, started: new Date().toISOString(), command: STATIC ? 'npm run export:static' : 'npm run verify', checks: [], accessibility: [], errors: [] }
mkdirSync(OUT, { recursive: true })
let browser
let current = 'startup'

function step(label) {
  current = label
  console.log(`CHECK ${label}`)
}

function save() {
  writeFileSync(join(OUT, `${MODE}-report.json`), JSON.stringify(report, null, 2) + '\n')
  writeFileSync(join(OUT, `${MODE}-summary.txt`), [
    `${MODE}: ${report.errors.length ? 'FAIL' : 'PASS'}${report.finished ? '' : ' (interrupted)'}`,
    `Started: ${report.started}`, `Command: ${report.command}`,
    `${report.checks.length} completed checks; ${report.accessibility.length} axe audits.`,
    ...report.errors.map((error) => `${error.check}: ${error.message}`),
    'PNG captures are bounded viewports or panel slices (maximum 1600px high).',
  ].join('\n') + '\n')
}

const watchdog = setTimeout(() => {
  report.errors.push({ check: current, message: 'Verifier exceeded 8 minutes' })
  save()
  browser?.close().finally(() => process.exit(1))
  setTimeout(() => process.exit(1), 3000)
}, 8 * 60 * 1000)

async function bounded(promise, label, milliseconds = 20000) {
  let timer
  try {
    return await Promise.race([promise, new Promise((_, reject) => {
      timer = setTimeout(() => reject(new Error(`${label} exceeded ${milliseconds}ms`)), milliseconds)
    })])
  } finally { clearTimeout(timer) }
}

function urlFor(route) {
  return STATIC ? pathToFileURL(join(FOLDER, route === '/' ? 'index.html' : route.slice(1) + '.html')).href : new URL(route, BASE).href
}

function observe(page, { javaScriptEnabled = true } = {}) {
  page.on('pageerror', (error) => report.errors.push({ check: current, message: error.message, url: page.url() }))
  page.on('console', (message) => {
    if (message.type() === 'error' && !message.text().startsWith('Failed to load resource:')) report.errors.push({ check: current, message: message.text(), url: page.url() })
  })
  page.on('requestfailed', (request) => {
    if (!javaScriptEnabled && request.resourceType() === 'script' && request.failure()?.errorText === 'csp') return
    if (request.isNavigationRequest() && request.failure()?.errorText === 'net::ERR_ABORTED') return
    report.errors.push({ check: current, message: `${request.failure()?.errorText}: ${request.url()}` })
  })
  page.on('response', (response) => {
    if (response.status() < 400) return
    if (response.status() === 404 && response.request().isNavigationRequest() && new URL(response.url()).pathname === '/__qa_unknown_route__') return
    report.errors.push({ check: current, message: `HTTP ${response.status()}: ${response.url()}` })
  })
}

async function goto(page, route, width = 1440) {
  await page.setViewportSize({ width, height: 960 })
  const response = await page.goto(urlFor(route), { waitUntil: 'load' })
  if (!STATIC) assert.equal(response.status(), 200, `${route}: HTTP status`)
  await bounded(page.evaluate(() => document.fonts.ready), 'Font loading')
  if (await page.locator('[data-choice-group]').count()) await page.waitForFunction(() => [...document.querySelectorAll('[data-choice-tabs]')].every((tabs) => !tabs.hidden && tabs.getAttribute('role') === 'tablist'))
}

async function images(page) {
  const broken = await bounded(page.evaluate(async () => (await Promise.all([...document.images].map(async (image) => {
    image.loading = 'eager'
    try { await image.decode() } catch { return image.getAttribute('src') || '(missing image src)' }
    return image.naturalWidth > 0 ? null : image.getAttribute('src') || '(missing image src)'
  }))).filter(Boolean)), 'Image decoding')
  assert.deepEqual(broken, [], 'Broken images')
}

async function structure(page, route) {
  assert.equal(await page.locator('main').count(), 1, 'Exactly one main landmark')
  assert.equal(await page.locator('h1').count(), 1, 'Exactly one h1')
  assert.equal(await page.locator('main h1').count(), 1, 'The h1 belongs in main')
  assert.ok((await page.title()).trim(), 'Page title')
  assert.ok((await page.locator('meta[name="description"]').getAttribute('content'))?.trim(), 'Page description')
  assert.ok(await page.locator('link[rel~="icon"]').count(), 'Favicon')
  const dimensions = await page.evaluate(() => ({ viewport: document.documentElement.clientWidth, content: Math.max(document.documentElement.scrollWidth, document.body.scrollWidth) }))
  assert.ok(dimensions.content <= dimensions.viewport + 1, `Horizontal overflow: ${JSON.stringify(dimensions)}`)
  await images(page)
  if (route === '/privacy' || route === '/terms') {
    const sections = await page.locator('main .legal-section').evaluateAll((nodes) => nodes.map((section) => ({
      title: section.querySelector('h2')?.textContent.trim(),
      en: section.querySelector('p[lang="en"]')?.textContent.trim(),
      ms: section.querySelector('p[lang="ms"]')?.textContent.trim(),
    })))
    assert.ok(sections.length, `${route}: legal sections must not be empty`)
    assert.ok(sections.every((section) => section.title && section.en && section.ms), `${route}: every legal section needs English and Malay text`)
  }
}

async function audit(page, label) {
  await page.evaluate(AXE)
  await bounded(page.evaluate(async () => {
    for (;;) {
      await new Promise(requestAnimationFrame)
      const finite = document.getAnimations().filter((animation) =>
        (animation.playState === 'running' || animation.pending) && animation.effect?.getComputedTiming().iterations !== Infinity)
      if (!finite.length) return
      await Promise.all(finite.map((animation) => animation.finished.catch(() => {})))
    }
  }), `Visual state before axe ${label}`, 5000)
  const violations = await bounded(page.evaluate(async () => (await window.axe.run(document, { resultTypes: ['violations'] })).violations.map((item) => ({
    id: item.id, impact: item.impact, help: item.help,
    nodes: item.nodes.map((node) => ({ target: node.target, summary: node.failureSummary })),
  }))), `axe ${label}`)
  report.accessibility.push({ label, violations })
  assert.deepEqual(violations.filter((item) => ['serious', 'critical'].includes(item.impact)), [], `${label}: serious/critical axe violations`)
}

async function screenshot(page, name, locator) {
  const options = { path: join(OUT, `${MODE}-${name}.png`), animations: 'disabled', timeout: 15000 }
  if (locator) {
    await locator.scrollIntoViewIfNeeded()
    const box = await locator.boundingBox()
    assert.ok(box, `Missing screenshot target ${name}`)
    options.clip = { x: Math.max(0, box.x), y: Math.max(0, box.y), width: Math.min(box.width, page.viewportSize().width - Math.max(0, box.x)), height: Math.min(box.height, 1600) }
  }
  await page.screenshot(options)
}

const normalize = (text) => text.toLowerCase().replace(/[^a-z0-9]/g, '')

function panelContent(panels) {
  return panels.map((panel) => ({
    copy: [...panel.querySelectorAll('h2,h3,h4,p,li')].map((node) => node.textContent.trim()).filter(Boolean),
    images: [...panel.querySelectorAll('img')].map((node) => ({ src: node.getAttribute('src'), alt: node.alt })),
    captions: [...panel.querySelectorAll('figcaption')].map((node) => node.textContent.trim()),
  }))
}

async function choiceState(group, selected, expected) {
  const state = await group.evaluate((element) => {
    const tabs = [...element.querySelectorAll('[data-choice-tabs] button')]
    const panels = [...element.querySelectorAll('[data-choice-panel]')]
    const active = document.activeElement
    const errors = []
    if (tabs.filter((tab) => tab.getAttribute('aria-selected') === 'true').length !== 1) errors.push('expected one selected tab')
    if (document.documentElement.scrollWidth > document.documentElement.clientWidth + 1) errors.push('selected panel causes horizontal overflow')
    tabs.forEach((tab, index) => {
      const panel = panels[index]
      const selected = tab.getAttribute('aria-selected') === 'true'
      if (tab.getAttribute('role') !== 'tab' || tab.tabIndex !== (selected ? 0 : -1)) errors.push('tab role/tabindex ' + index)
      if (tab.getAttribute('aria-controls') !== panel.id || panel.getAttribute('aria-labelledby') !== tab.id || panel.getAttribute('role') !== 'tabpanel') errors.push('panel relationship ' + index)
      if (panel.hidden === selected || (getComputedStyle(panel).display === 'none') === selected) errors.push('panel visibility ' + index)
      if (!selected) {
        for (const control of [panel, ...panel.querySelectorAll('a[href],button,input,select,textarea,[tabindex]')]) {
          control.focus()
          if (document.activeElement === control) errors.push('hidden control received focus ' + index)
        }
      }
    })
    active?.focus()
    return { errors, selected: tabs.findIndex((tab) => tab.getAttribute('aria-selected') === 'true') }
  })
  assert.deepEqual(state.errors, [], 'Choice ARIA, roving focus and hidden-panel isolation')
  assert.equal(state.selected, selected, 'Selected tab')
  assert.deepEqual(await group.locator('[data-choice-panel]').evaluateAll(panelContent), expected, 'Whole panel copy, image and caption must stay together')
  const panel = group.locator('[data-choice-panel]').nth(selected)
  assert.equal(await panel.isVisible(), true)
  const visibleCopy = (await panel.innerText()).replace(/\s+/g, ' ')
  for (const copy of expected[selected].copy) assert.ok(visibleCopy.includes(copy.replace(/\s+/g, ' ')), `Selected panel copy is visible: ${copy}`)
  for (const node of await panel.locator('p,img,figcaption').all()) assert.equal(await node.isVisible(), true, 'Selected copy/image/caption is visible')
}

async function choices(page, label) {
  assert.equal(await page.locator('[data-choice-group]').count(), 3, 'Homepage has three choice groups')
  for (const [id, names] of Object.entries(GROUPS)) {
    const group = page.locator(`[data-choice-group="${id}"]`)
    const tabs = group.locator('[data-choice-tabs] button')
    assert.deepEqual((await tabs.allTextContents()).map(normalize), names.map(normalize), `${id}: tab labels`)
    const expected = await group.locator('[data-choice-panel]').evaluateAll(panelContent)
    assert.equal(expected.length, names.length, `${id}: panel count`)
    assert.ok(expected.every((panel) => panel.copy.length && panel.images.every((image) => image.src && image.alt) && panel.captions.every(Boolean)), `${id}: panels need complete copy and labelled captures`)
    if (id !== 'copilot-example') assert.ok(expected.every((panel) => panel.images.length && panel.captions.length), `${id}: every panel needs an image and caption`)
    assert.equal(new Set(expected.map((panel) => JSON.stringify(panel))).size, names.length, `${id}: panels need distinct content`)
    for (let index = 0; index < names.length; index++) {
      console.log(`CHECK ${MODE} ${label}: ${id} / ${names[index]}`)
      assert.equal(await tabs.nth(index).getAttribute('id'), `${id}-tab-${index}`)
      assert.equal(await tabs.nth(index).getAttribute('aria-controls'), `${id}-panel-${index}`)
      await tabs.nth(index).click()
      await choiceState(group, index, expected)
      await images(page)
      await audit(page, `${label}-${id}-${index}`)
      if (id === 'team-role') await screenshot(page, `${label}-${id}-${index}`, group.locator('[data-choice-panel]').nth(index))
    }
    await tabs.first().focus()
    await tabs.first().press('Enter')
    let selected = 0
    for (const key of ['ArrowLeft', 'ArrowRight', 'End', 'Home', 'ArrowDown', 'ArrowUp']) {
      selected = key === 'Home' ? 0 : key === 'End' ? names.length - 1 : (selected + (['ArrowRight', 'ArrowDown'].includes(key) ? 1 : -1) + names.length) % names.length
      await page.keyboard.press(key)
      assert.equal(await tabs.nth(selected).evaluate((tab) => document.activeElement === tab), true, `${id}: ${key} moves focus`)
      await choiceState(group, selected, expected)
    }
    await page.keyboard.press('Tab')
    assert.equal(await group.locator('[data-choice-panel]').nth(selected).evaluate((panel) => panel === document.activeElement || panel.contains(document.activeElement)), true, 'Tab enters only the selected panel')
    console.log(`PASS ${MODE} ${label}: ${id} choices and keyboard`)
  }
}

async function menu(page) {
  const details = page.locator('details.mobile-menu')
  const summary = details.locator('summary')
  assert.equal(await summary.isVisible(), true, 'Mobile menu trigger')
  await summary.focus()
  await page.keyboard.press('Enter')
  assert.equal(await details.getAttribute('open'), '', 'Enter opens native menu')
  await audit(page, 'mobile-menu-expanded')
  await page.keyboard.press('Tab')
  assert.equal(await details.locator('a').evaluateAll((links) => links.includes(document.activeElement)), true, 'Tab reaches menu links')
  await page.keyboard.press('Escape')
  assert.equal(await details.getAttribute('open'), null, 'Escape closes mobile menu')
  assert.equal(await summary.evaluate((node) => document.activeElement === node), true, 'Escape restores trigger focus')
  await summary.press('Enter')
  const destination = new URL(urlFor('/product')).pathname
  const link = details.locator('a').filter({ hasText: /product/i }).first()
  assert.equal(await link.isVisible(), true, 'Product menu link')
  await link.focus()
  await Promise.all([page.waitForURL((url) => url.pathname === destination), page.keyboard.press('Enter')])
  assert.equal(new URL(page.url()).pathname, destination, 'Menu navigates to product page')
  assert.equal(await page.locator('details.mobile-menu').getAttribute('open'), null, 'Navigation closes menu')
  await structure(page, '/product')
}

async function faq(page, label) {
  const items = page.locator('main details')
  const toggles = page.locator('main button[aria-controls][aria-expanded]')
  assert.ok(await items.count() + await toggles.count(), `${label}: expandable FAQ/details`)
  for (let index = 0; index < await toggles.count(); index++) {
    const toggle = toggles.nth(index)
    const panel = page.locator(`[id="${await toggle.getAttribute('aria-controls')}"]`)
    await toggle.focus()
    await page.keyboard.press('Enter')
    assert.equal(await toggle.getAttribute('aria-expanded'), 'true', 'FAQ keyboard expansion')
    assert.equal(await panel.isVisible(), true, 'Expanded FAQ answer is visible')
    assert.ok((await panel.textContent()).trim(), 'FAQ answer is nonempty')
    await page.keyboard.press('Enter')
    assert.equal(await toggle.getAttribute('aria-expanded'), 'false', 'FAQ keyboard collapse')
    assert.equal(await panel.isVisible(), false, 'Collapsed FAQ answer is hidden')
  }
  if (await toggles.count() > 1) {
    await toggles.first().focus()
    await page.keyboard.press('ArrowDown')
    assert.equal(await toggles.nth(1).evaluate((node) => node === document.activeElement), true, 'FAQ arrow key moves focus')
    await toggles.first().click()
  }
  for (let index = 0; index < await items.count(); index++) {
    const item = items.nth(index)
    const summary = item.locator('summary')
    await item.evaluate((node) => { node.open = false })
    await summary.focus()
    await page.keyboard.press('Enter')
    assert.equal(await item.getAttribute('open'), '', 'FAQ keyboard expansion')
    const body = item.locator('p,ul,ol').first()
    assert.equal(await body.isVisible(), true, 'Expanded FAQ answer is visible')
    assert.ok((await body.textContent()).trim(), 'FAQ answer is nonempty')
    await page.keyboard.press('Enter')
    assert.equal(await item.getAttribute('open'), null, 'FAQ keyboard collapse')
  }
  if (await items.count()) await items.first().locator('summary').click()
  await audit(page, `${label}-faq-expanded`)
}

async function refs(page, documents) {
  const references = await page.evaluate(() => {
    const refs = [...document.querySelectorAll('[href],[src],[poster],[srcset]')].flatMap((node) => ['href', 'src', 'poster', 'srcset'].flatMap((name) => {
      const value = node.getAttribute(name)
      if (!value) return []
      const values = name === 'srcset' ? (value.startsWith('data:') ? [value] : value.split(',').map((part) => part.trim().split(/\s+/)[0])) : [value]
      return values.map((value) => ({ value, anchor: node.matches('a[href]') && name === 'href' }))
    }))
    for (const style of document.querySelectorAll('style,[style]')) {
      const css = style.tagName === 'STYLE' ? style.textContent : style.getAttribute('style')
      for (const match of css.matchAll(/url\(\s*['"]?([^)'"\s]+)['"]?\s*\)/g)) refs.push({ value: match[1], anchor: false })
    }
    return refs
  })
  for (const reference of references) {
    const target = new URL(reference.value, page.url())
    if (['data:', 'mailto:', 'tel:'].includes(target.protocol)) continue
    if (STATIC) {
      if (reference.anchor && ['http:', 'https:'].includes(target.protocol) && !['127.0.0.1', 'localhost'].includes(target.hostname)) continue
      assert.equal(target.protocol, 'file:', `Static asset/link must be local: ${target.href}`)
      assert.ok(!reference.value.startsWith('/') && !reference.value.startsWith('\\'), `Server-relative static reference: ${reference.value}`)
      const file = fileURLToPath(target)
      const rel = relative(realpathSync(FOLDER), realpathSync(file))
      assert.ok(rel !== '..' && !rel.startsWith('..' + sep) && !isAbsolute(rel), `Static reference escapes export folder: ${file}`)
      assert.ok(statSync(file).isFile(), `Missing static file: ${file}`)
      if (!reference.anchor || !file.endsWith('.html')) continue
    } else {
      if (target.origin !== new URL(BASE).origin) continue
      if (!reference.anchor || !documents.has(target.pathname)) {
        if (reference.anchor) assert.match(target.pathname, /\.[a-z0-9]+$/i, `Unknown internal page link: ${target.href}`)
        if (!checkedAssets.has(target.href)) {
          const response = await fetch(target, { method: 'HEAD', signal: AbortSignal.timeout(10000) })
          assert.ok(response.ok, `Internal asset HTTP ${response.status}: ${target.href}`)
          checkedAssets.add(target.href)
        }
        continue
      }
    }
    const key = STATIC ? fileURLToPath(target) : target.pathname
    const ids = documents.get(key)
    assert.ok(ids, `Unknown internal page link: ${target.href}`)
    if (target.hash) assert.ok(ids.includes(decodeURIComponent(target.hash.slice(1))), `Missing fragment: ${target.href}`)
  }
  if (STATIC) {
    assert.equal(await page.locator('script').count(), 1, 'Only the shared vanilla enhancement script is exported')
    assert.equal(await page.locator('script[src],link[rel="modulepreload"],link[rel="preload"]').count(), 0, 'No hydration scripts/preloads')
  }
}

try {
  browser = await chromium.launch({ executablePath: process.env.CHROME_PATH || 'C:/Program Files/Google/Chrome/Application/chrome.exe', headless: true })
  const context = await browser.newContext()
  context.setDefaultTimeout(12000)
  context.setDefaultNavigationTimeout(20000)
  const page = await context.newPage()
  observe(page)
  const documents = new Map()
  for (const route of ROUTES) {
    step(`${MODE} ${route} document`)
    await goto(page, route)
    const ids = await page.locator('[id],a[name]').evaluateAll((nodes) => nodes.flatMap((node) => [node.id, node.getAttribute('name')].filter(Boolean)))
    documents.set(STATIC ? fileURLToPath(urlFor(route)) : route, ids)
  }
  for (const width of [390, 768, 1440]) {
    for (const route of ROUTES) {
      step(`${MODE} ${route} ${width}px`)
      await goto(page, route, width)
      await structure(page, route)
      await refs(page, documents)
      await audit(page, current)
      await screenshot(page, `${route === '/' ? 'home' : route.slice(1)}-${width}`)
      report.checks.push(current)
      console.log(`PASS ${current}`)
    }
  }
  for (const width of [390, 1440]) {
    step(`${MODE} choices ${width}px`)
    await goto(page, '/', width)
    await choices(page, `home-${width}`)
    report.checks.push(current)
  }
  step(`${MODE} reduced-motion choices`)
  await page.emulateMedia({ reducedMotion: 'reduce' })
  await goto(page, '/')
  await choices(page, 'reduced-motion')
  assert.equal(await page.evaluate(() => document.getAnimations().filter((animation) => animation.playState === 'running').length), 0, 'No running animations under reduced motion')
  report.checks.push(current)
  await page.emulateMedia({ reducedMotion: 'no-preference' })
  step(`${MODE} mobile menu navigation`)
  await goto(page, '/', 390)
  await menu(page)
  report.checks.push(current)
  for (const route of ['/', '/product', '/intelligence']) {
    step(`${MODE} FAQ ${route}`)
    await goto(page, route, 390)
    await faq(page, route)
    report.checks.push(current)
  }
  if (!STATIC) {
    step('live unknown route 404')
    const response = await page.goto(new URL('/__qa_unknown_route__', BASE).href)
    assert.equal(response.status(), 404, 'Unknown live route must return HTTP 404')
    assert.match(await page.locator('main h1').innerText(), /not found/i)
    await audit(page, current)
    report.checks.push(current)
  }
  step(`${MODE} no-JavaScript content fallback`)
  const fallback = await browser.newContext({ javaScriptEnabled: false, viewport: { width: 390, height: 960 } })
  fallback.setDefaultTimeout(12000)
  fallback.setDefaultNavigationTimeout(20000)
  const plain = await fallback.newPage()
  observe(plain, { javaScriptEnabled: false })
  await plain.goto(urlFor('/'), { waitUntil: 'load' })
  for (const [id, names] of Object.entries(GROUPS)) {
    const group = plain.locator(`[data-choice-group="${id}"]`)
    assert.equal(await group.locator('[data-choice-tabs]').isVisible(), false, 'No-JS tabs stay hidden')
    const panels = group.locator('[data-choice-panel]')
    assert.equal(await panels.count(), names.length)
    for (let index = 0; index < names.length; index++) {
      assert.equal(await panels.nth(index).isVisible(), true, `No-JS ${id} ${names[index]} panel is visible`)
      assert.ok(await panels.nth(index).locator('p').count(), `No-JS ${names[index]} copy`)
      for (const node of await panels.nth(index).locator('p,img,figcaption').all()) assert.equal(await node.isVisible(), true, `No-JS ${names[index]} content`)
    }
  }
  assert.equal(await plain.locator('.ss-faq-answer').first().isVisible(), true, 'No-JS FAQ answers are visible')
  await images(plain)
  await screenshot(plain, 'no-js-home-390')
  report.checks.push(current)
  await fallback.close()
} catch (error) {
  report.errors.push({ check: current, message: error.stack || String(error) })
} finally {
  if (browser) await Promise.race([browser.close(), new Promise((done) => { const timer = setTimeout(done, 5000); timer.unref() })])
  clearTimeout(watchdog)
  report.finished = new Date().toISOString()
  report.durationSeconds = Number(((Date.now() - Date.parse(report.started)) / 1000).toFixed(1))
  save()
}
if (report.errors.length) {
  console.error(report.errors.map((error) => `${error.check}: ${error.message}`).join('\n'))
  process.exitCode = 1
} else console.log(`PASS ${MODE}: ${report.checks.length} checks; report: ${join(OUT, `${MODE}-report.json`)}`)
