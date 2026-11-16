'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const { chromium } = require('playwright-core');
const E = require('./emulator.cjs');

const CACHE = path.resolve(__dirname, '..', '.cache');
const allowFonts = () => process.env.E2E_ALLOW_FONTS === '1';
const FONT_HOSTS = new Set(['fonts.gstatic.com', 'fonts.googleapis.com']);
const SDK_URL = /^https:\/\/www\.gstatic\.com\/firebasejs\/([0-9][^/]*)\/(firebase-[a-z-]+\.js)$/;

function firebaseSdkDir(version) {
  const dir = path.join(CACHE, `firebase-${version}`);
  const pkg = path.join(dir, 'package');
  if (fs.existsSync(path.join(pkg, 'firebase-app.js'))) return pkg;
  fs.mkdirSync(dir, { recursive: true });
  const args = ['pack', `firebase@${version}`, '--pack-destination', dir, '--silent'];
  if (process.platform === 'win32' && !process.env.npm_execpath) {
    throw new Error('Firebase SDK packaging on Windows requires npm_execpath. Start the harness through npm run e2e.');
  }
  const out = process.platform === 'win32'
    ? execFileSync(process.execPath, [process.env.npm_execpath, ...args], { encoding: 'utf8', windowsHide: true })
    : execFileSync('npm', args, { encoding: 'utf8', windowsHide: true });
  const tgz = path.join(dir, out.trim().split('\n').pop());
  execFileSync('tar', ['-xzf', tgz, '-C', dir], { windowsHide: true });
  return pkg;
}

function launchBrowser() {
  const executablePath = process.env.E2E_CHROMIUM_PATH || undefined;
  return chromium.launch({ headless: true, executablePath, args: ['--no-sandbox'] });
}

async function newSession(browser, { viewport = { width: 1600, height: 1000 }, name = 'page', persistence = false, ...opts } = {}) {
  const timezone = process.env.E2E_TIMEZONE ? { timezoneId: process.env.E2E_TIMEZONE } : {};
  const context = await browser.newContext({ viewport, serviceWorkers: 'block', ...timezone, ...opts });
  if (persistence) {
    await context.addInitScript(() => {
      try { window.localStorage.setItem('e2e_persistence', '1'); } catch {}
    });
  }
  const logs = [];
  const blocked = [];
  const hermetic = async (route) => {
    const url = route.request().url();
    const parsed = new URL(url);
    if (['127.0.0.1', 'localhost'].includes(parsed.hostname) || parsed.protocol === 'data:' || parsed.protocol === 'blob:') {
      return route.continue();
    }
    if (/^(identitytoolkit|securetoken)\.googleapis\.com$/.test(parsed.hostname)) {
      const host = process.env.FIREBASE_AUTH_EMULATOR_HOST;
      if (host && ['127.0.0.1', 'localhost'].includes(host.split(':')[0])) {
        const target = `http://${host}/${parsed.hostname}${parsed.pathname}${parsed.search}`;
        try {
          return await route.fulfill({ response: await route.fetch({ url: target }) });
        } catch (error) {
          logs.push(`[${name}] auth forward failed: ${error.message}`);
        }
      }
    }
    if (allowFonts() && FONT_HOSTS.has(parsed.hostname)) return route.continue();
    const m = SDK_URL.exec(url);
    if (m) {
      const file = path.join(firebaseSdkDir(m[1]), m[2]);
      if (fs.existsSync(file)) {
        return route.fulfill({ status: 200, contentType: 'text/javascript; charset=utf-8', body: fs.readFileSync(file) });
      }
    }
    blocked.push(url);
    return route.fulfill({ status: 404, body: '' });
  };
  await context.route('**/*', (route) => hermetic(route).catch((error) => {
    if (!/already handled|has been closed/.test(error.message)) throw error;
  }));
  await context.addInitScript(() => {
    const style = document.createElement('style');
    style.textContent = '.firebase-emulator-warning{display:none !important;pointer-events:none !important}';
    document.addEventListener('DOMContentLoaded', () => document.head.appendChild(style));
  });
  const page = await context.newPage();
  const noise = /fonts\.gstatic\.com|Failed to load font|Failed to load resource: the server responded with a status of 404/;
  page.on('console', (m) => { if (!noise.test(m.text())) logs.push(`[${name}] ${m.type()}: ${m.text().slice(0, 500)}`); });
  page.on('response', (r) => { if (r.status() === 404 && /^https?:\/\/(127\.0\.0\.1|localhost)[:/]/.test(r.url())) logs.push(`[${name}] http404: ${r.url()}`); });
  page.on('pageerror', (e) => logs.push(`[${name}] pageerror: ${String(e.message).slice(0, 500)}`));
  return { context, page, logs, blocked };
}

async function shiftDeviceClock(context, offsetMs) {
  await context.addInitScript((offset) => {
    const RealDate = Date;
    class ShiftedDate extends RealDate {
      constructor(...args) {
        if (args.length === 0) super(RealDate.now() + offset);
        else super(...args);
      }
      static now() { return RealDate.now() + offset; }
    }
    window.Date = ShiftedDate;
  }, offsetMs);
}

async function fakeGeolocation(context, { latitude, longitude, accuracy = 10 }) {
  await context.grantPermissions(['geolocation']);
  await context.setGeolocation({ latitude, longitude, accuracy });
  await context.addInitScript((start) => {
    window.__fakeGeo = start;
    const position = () => ({
      coords: { latitude: window.__fakeGeo.latitude, longitude: window.__fakeGeo.longitude, accuracy: window.__fakeGeo.accuracy, altitude: null, altitudeAccuracy: null, heading: null, speed: null },
      timestamp: Date.now(),
    });
    const watchers = new Map();
    let nextId = 1;
    navigator.geolocation.getCurrentPosition = (ok) => { setTimeout(() => ok(position()), 20); };
    navigator.geolocation.watchPosition = (ok) => {
      const id = nextId++;
      setTimeout(() => ok(position()), 20);
      watchers.set(id, setInterval(() => ok(position()), 2000));
      return id;
    };
    navigator.geolocation.clearWatch = (id) => { clearInterval(watchers.get(id)); watchers.delete(id); };
  }, { latitude, longitude, accuracy });
}

async function moveDevice(page, { latitude, longitude, accuracy = 10 }) {
  await page.context().setGeolocation({ latitude, longitude, accuracy });
  await page.evaluate((to) => { window.__fakeGeo = to; }, { latitude, longitude, accuracy });
}

async function enableSemantics(page) {
  await page.waitForSelector('flutter-view', { timeout: 60000 });
  await page.waitForSelector('flt-semantics-placeholder, flt-semantics-host *', { state: 'attached', timeout: 60000 });
  const placeholder = page.locator('flt-semantics-placeholder');
  if (await placeholder.count()) await placeholder.first().evaluate((node) => node.click(), undefined, { timeout: 2000 }).catch(() => {});
  await page.locator('flt-semantics-host *').first().waitFor({ state: 'attached', timeout: 30000 });
}

async function openApp(page, url) {
  await page.goto(url, { waitUntil: 'domcontentloaded', timeout: 60000 });
  await enableSemantics(page);
}

async function fillField(page, locator, value) {
  for (let attempt = 0; attempt < 5; attempt += 1) {
    await locator.click();
    await page.keyboard.press('Control+A');
    await page.keyboard.press('Backspace');
    await page.keyboard.type(value, { delay: 20 });
    if ((await locator.inputValue()) === value) return;
    await page.waitForTimeout(400);
  }
  throw new Error('could not enter text into the field reliably');
}

async function focusedValue(locator, { timeout = 5000 } = {}) {
  await locator.click();
  const deadline = Date.now() + timeout;
  let value = await locator.inputValue();
  while (value === '' && Date.now() < deadline) {
    await new Promise((resolve) => setTimeout(resolve, 250));
    value = await locator.inputValue();
  }
  return value;
}

async function loginMobile(page, url, email, password = E.PASSWORD) {
  await openApp(page, url);
  const inputs = page.locator('input');
  await inputs.nth(1).waitFor({ timeout: 60000 });
  await page.waitForTimeout(500);
  await fillField(page, inputs.nth(0), email);
  await fillField(page, inputs.nth(1), password);
  await page.getByRole('button', { name: /^Sign in$/ }).click();
}

async function loginAdmin(page, url, email, password = E.PASSWORD) {
  await openApp(page, url);
  const inputs = page.locator('input');
  await inputs.nth(1).waitFor({ timeout: 60000 });
  await page.waitForTimeout(500);
  await fillField(page, inputs.nth(0), email);
  await fillField(page, inputs.nth(1), password);
  await page.getByRole('button', { name: /^Sign In$/ }).click();
}

function semantic(page, text) {
  return page.getByLabel(text).or(page.getByText(text)).first();
}

async function expectAssetsLoad(page, change, readyText, { quietMs = 750, timeout = 15000 } = {}) {
  const missing = [];
  const inflight = new Set();
  let lastActivity = Date.now();
  const isAsset = (url) => url.includes('/assets/');
  const onRequest = (request) => {
    if (!isAsset(request.url())) return;
    inflight.add(request);
    lastActivity = Date.now();
  };
  const onFinished = (request) => {
    if (inflight.delete(request)) lastActivity = Date.now();
  };
  const onFailed = (request) => {
    if (!inflight.delete(request)) return;
    lastActivity = Date.now();
    missing.push(request.url());
  };
  const onResponse = (response) => {
    if (!isAsset(response.url())) return;
    const html = (response.headers()['content-type'] || '').startsWith('text/html');
    if (html || response.status() >= 400) missing.push(response.url());
  };
  page.on('request', onRequest);
  page.on('requestfinished', onFinished);
  page.on('requestfailed', onFailed);
  page.on('response', onResponse);
  try {
    await change();
    await see(page, readyText, { timeout });
    const deadline = Date.now() + timeout;
    while (inflight.size || Date.now() - lastActivity < quietMs) {
      if (Date.now() > deadline) {
        throw new Error(`asset requests still pending: ${[...inflight].map((r) => r.url()).join(', ')}`);
      }
      await page.waitForTimeout(100);
    }
  } finally {
    page.off('request', onRequest);
    page.off('requestfinished', onFinished);
    page.off('requestfailed', onFailed);
    page.off('response', onResponse);
  }
  if (missing.length) throw new Error(`missing assets: ${missing.join(', ')}`);
}

async function see(page, text, { timeout = 20000 } = {}) {
  const loc = semantic(page, text);
  try {
    await loc.waitFor({ state: 'attached', timeout });
  } catch {
    throw new Error(`expected to see ${text} on the page, but it never appeared`);
  }
  return loc;
}

async function scrollIntoView(page, locator, { step = 300, maxSteps = 25, minHeight = 0, pointerY = 0.5, bottomInset = 140 } = {}) {
  const size = page.viewportSize();
  await page.mouse.move(size.width / 2, size.height * pointerY);
  let last = null;
  let stable = 0;
  for (let i = 0; i < maxSteps; i += 1) {
    const box = (await locator.count()) ? await locator.first().boundingBox() : null;
    const visible = box && box.height >= minHeight && box.y >= 0 && box.y + box.height <= size.height - bottomInset;
    if (visible && last && Math.abs(box.y - last.y) < 1 && Math.abs(box.height - last.height) < 1) {
      stable += 1;
      if (stable >= 2) return box;
    } else {
      stable = 0;
    }
    last = visible ? box : null;
    if (!visible) await page.mouse.wheel(0, box ? (box.y < 0 ? -Math.abs(step) : Math.abs(step)) : step);
    await page.waitForTimeout(300);
  }
  const seen = (await locator.count()) ? await locator.first().boundingBox() : null;
  throw new Error('could not scroll the element into view (count=' + (await locator.count()) + ', box=' + JSON.stringify(seen) + ', minHeight=' + minHeight + ')');
}

async function submitEmailCode(page, code) {
  await page.getByText(/We sent a 6-digit code to /).first().waitFor({ timeout: 30000 });
  await fillField(page, page.locator('input').nth(4), code);
  await page.getByRole('button', { name: /^(Redeem invitation|Set password and sign in)$/ }).click();
}

async function shotAtWidths(t, session, label) {
  const original = session.page.viewportSize();
  for (const [width, height] of [[390, 844], [2000, 1100]]) {
    await session.page.setViewportSize({ width, height });
    await session.page.waitForTimeout(900);
    await t.shot(session, `${label}-${width}px`);
  }
  await session.page.setViewportSize(original);
  await session.page.waitForTimeout(600);
}

module.exports = { shotAtWidths, submitEmailCode, shiftDeviceClock, fakeGeolocation, moveDevice, semantic, see, expectAssetsLoad, scrollIntoView, launchBrowser, newSession, enableSemantics, openApp, fillField, focusedValue, loginMobile, loginAdmin };
