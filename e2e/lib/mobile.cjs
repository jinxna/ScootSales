'use strict';

const { see, scrollIntoView, fillField, openApp } = require('./browser.cjs');

const MOBILE_VIEWPORT = { width: 430, height: 900 };

async function waitForHome(page) {
  await page.getByRole('button', { name: 'Planner', exact: true }).waitFor({ timeout: 60000 });
}

async function planVisitToday(page, retailerName, purpose = 'E2E order visit') {
  await page.getByRole('button', { name: 'Planner', exact: true }).click();
  await page.getByRole('button', { name: 'Add Visit', exact: true }).click();
  await page.getByRole('button', { name: 'Choose a date' }).click();
  await page.getByRole('button', { name: /, Today$/ }).click();
  await page.getByRole('button', { name: 'OK', exact: true }).click();
  await page.getByRole('button', { name: 'Choose a retailer' }).click();
  await page.getByRole('menuitem', { name: retailerName }).click();
  await fillField(page, page.getByRole('textbox').first(), purpose);
  await page.getByRole('button', { name: 'Save plan' }).click();
  await page.getByRole('button', { name: /^Mon|^Tue|^Wed|^Thu|^Fri|^Sat|^Sun/ }).first().waitFor({ timeout: 20000 });
  await page.getByRole('button', { name: 'Back' }).click();
}

async function openPlannedVisit(page, retailerName) {
  await page.getByRole('button', { name: new RegExp(`^Personal plan[^]*${retailerName}`) }).click();
}

async function selectProducts(page, department, productNames) {
  await page.locator(`[aria-label="${department}"]`).first().click();
  for (const name of productNames) {
    await page.getByRole('checkbox', { name: new RegExp(`^(?:[^\\n·]+ · )?${name.replace(/[()]/g, '\\$&')}`) }).click();
  }
  await page.getByRole('button', { name: new RegExp(`^Add to Cart \\(${productNames.length}\\)`) }).click();
  await page.getByRole('button', { name: 'Start counting' }).click();
}

async function continueToSignature(page) {
  await page.getByRole('button', { name: 'Continue to Signature' }).click();
}

async function signAndSubmit(page, department, lineCount) {
  await signAndTapSubmit(page, department, lineCount);
  await see(page, /Order sent/, { timeout: 30000 });
  const confirmation = await see(page, /ORD-[A-Za-z0-9._-]+ has been submitted/);
  const label = (await confirmation.getAttribute('aria-label')) || (await confirmation.textContent());
  const match = /(ORD-[A-Za-z0-9._-]+) has been submitted/.exec(label);
  if (!match) throw new Error('confirmation screen did not show an order id: ' + label);
  return match[1];
}

async function signAndTapSubmit(page, department, lineCount) {
  for (let i = 0; i < lineCount; i += 1) {
    await page.getByRole('button', { name: 'Select Ordered Batch Expiry' }).first().click();
    await page.getByRole('button', { name: 'OK', exact: true }).click();
  }
  const pad = page.getByRole('group', { name: new RegExp(`${department} Authorization`) });
  const box = await scrollIntoView(page, pad, { minHeight: 150 });
  const clear = await pad.getByRole('button', { name: 'Clear Signature' }).boundingBox();
  const cx = box.x + box.width / 2;
  const cy = clear.y - 10 - 55;
  await page.mouse.move(cx - 100, cy - 10);
  await page.mouse.down();
  await page.mouse.move(cx, cy + 15, { steps: 8 });
  await page.mouse.move(cx + 100, cy - 10, { steps: 8 });
  await page.mouse.up();
  await see(page, /Signed on /);
  await page.getByRole('button', { name: 'Submit Order' }).click();
}

async function signOrder(page, department, lineCount) {
  for (let i = 0; i < lineCount; i += 1) {
    await page.getByRole('button', { name: 'Select Ordered Batch Expiry' }).first().click();
    await page.getByRole('button', { name: 'OK', exact: true }).click();
  }
  const pad = page.getByRole('group', { name: new RegExp(`${department} Authorization`) });
  const box = await scrollIntoView(page, pad, { minHeight: 150 });
  const clear = await pad.getByRole('button', { name: 'Clear Signature' }).boundingBox();
  const cx = box.x + box.width / 2;
  const cy = clear.y - 10 - 55;
  await page.mouse.move(cx - 100, cy - 10);
  await page.mouse.down();
  await page.mouse.move(cx, cy + 15, { steps: 8 });
  await page.mouse.move(cx + 100, cy - 10, { steps: 8 });
  await page.mouse.up();
  await see(page, /Signed on /);
}

async function tapSubmit(page, label = 'Submit Order') {
  const button = page.getByRole('button', { name: label, exact: true });
  const tappedAt = Date.now();
  await button.click();
  return tappedAt;
}

async function readConfirmedOrderId(page, { timeout = 30000 } = {}) {
  await see(page, /Order sent/, { timeout });
  const confirmation = await see(page, /ORD-[A-Za-z0-9._-]+ has been submitted/);
  const label = (await confirmation.getAttribute('aria-label')) || (await confirmation.textContent());
  const match = /(ORD-[A-Za-z0-9._-]+) has been submitted/.exec(label);
  if (!match) throw new Error('confirmation screen did not show an order id: ' + label);
  return match[1];
}

async function routeDayForSunday(db, planId) {
  const today = new Date();
  if (today.getDay() !== 0) return;
  const DAY_MS = 24 * 60 * 60 * 1000;
  const sameDate = (a, b) => a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  const isYesterday = (value) => value instanceof Date && sameDate(new Date(value.getTime() + DAY_MS), today);
  const moveDay = (value) => new Date(value.getTime() + DAY_MS);
  const plan = await db.get('route_plans', planId);
  if (plan.days.some((day) => day.date instanceof Date && sameDate(day.date, today))) return;
  if (!plan.days.some((day) => isYesterday(day.date))) throw new Error(`route ${planId} has no Saturday to move to today`);
  const days = plan.days.map((day) => (isYesterday(day.date) ? { ...day, date: moveDay(day.date) } : day));
  const weekEnd = isYesterday(plan.weekEnd) ? moveDay(plan.weekEnd) : plan.weekEnd;
  await db.put('route_plans', planId, { ...plan, days, weekEnd });
}

async function openAssignedRoute(page) {
  await page.getByRole('button', { name: /^Route$/ }).click();
  await see(page, /stop\(s\)/, { timeout: 30000 });
}

async function acceptAndStartRoute(page) {
  const accept = page.getByRole('button', { name: 'Accept route' });
  await scrollIntoView(page, accept, { minHeight: 20 });
  await accept.click();
  const start = page.getByRole('button', { name: 'Start route' });
  await start.waitFor({ timeout: 20000 });
  await page.waitForFunction(() => !document.querySelector('[aria-label="Accept route"][aria-disabled="false"]'), null, { timeout: 20000 }).catch(() => null);
  await start.click();
}

async function selectStop(page) {
  const go = page.getByRole('button', { name: 'Go to this stop' }).first();
  await scrollIntoView(page, go, { minHeight: 20, pointerY: 0.8 });
  await go.click();
  await page.getByRole('button', { name: 'Selected destination' }).first().waitFor({ timeout: 20000 });
}

async function markArrived(page) {
  const arrive = page.getByRole('button', { name: 'Selected destination' }).first().locator('xpath=following-sibling::*[@role="button"][1]');
  const name = ((await arrive.getAttribute('aria-label')) || (await arrive.textContent()) || '').trim();
  if (name !== 'Mark arrived') throw new Error(`expected "Mark arrived" after the selected stop, found "${name}"`);
  await scrollIntoView(page, arrive, { minHeight: 20, pointerY: 0.8 });
  await arrive.click();
}

async function redeemInvitation(page, url, { code, check, password }, { open = true } = {}) {
  if (open) {
    await openApp(page, url);
    await page.getByRole('button', { name: 'I have an invitation code' }).waitFor({ timeout: 60000 });
    await page.getByRole('button', { name: 'I have an invitation code' }).click();
  }
  const inputs = page.locator('input');
  await inputs.nth(3).waitFor({ timeout: 20000 });
  await page.waitForTimeout(300);
  await fillField(page, inputs.nth(0), code);
  await fillField(page, inputs.nth(1), check);
  await fillField(page, inputs.nth(2), password);
  await fillField(page, inputs.nth(3), password);
  await page.getByRole('button', { name: 'Redeem invitation', exact: true }).click();
}

async function finishRedeem(page) {
  await see(page, 'Invitation accepted', { timeout: 30000 });
  const lines = await page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
    .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));
  const signInId = lines.find((l) => /^\S+@\S+$/.test(l)) || null;
  await page.getByRole('button', { name: 'Continue', exact: true }).click();
  await waitForHome(page);
  return signInId;
}

async function signOut(page) {
  await page.getByRole('tab', { name: /Profile/ }).or(page.getByRole('button', { name: /^Profile/ })).first().click();
  const signOutButton = page.getByRole('button', { name: 'Sign Out', exact: true });
  await scrollIntoView(page, signOutButton, { minHeight: 20, bottomInset: 0 });
  await signOutButton.click();
  await see(page, 'Sign out?');
  await page.getByRole('button', { name: 'Sign Out', exact: true }).last().click();
  await page.getByRole('button', { name: /^Sign in$/ }).waitFor({ timeout: 30000 });
}

async function savedDrafts(page, project, uid) {
  const prefix = `flutter.project_storage_v1.${Buffer.from(project).toString('base64url')}.${Buffer.from(uid).toString('base64url')}.cart_draft.`;
  return page.evaluate(({ prefix, project, uid }) => Object.entries(localStorage)
    .filter(([key]) => key.startsWith(prefix))
    .map(([, value]) => {
      const encoded = JSON.parse(value);
      const envelope = typeof encoded === 'string' ? JSON.parse(encoded) : encoded;
      if (envelope?.version !== 1 || envelope.projectId !== project || envelope.uid !== uid) return null;
      return JSON.parse(envelope.data);
    })
    .filter(Boolean), { prefix, project, uid });
}

function backendPorts() {
  const port = (value, fallback) => Number(String(value || '').split(':')[1]) || fallback;
  return [
    port(process.env.FIRESTORE_EMULATOR_HOST, 8089),
    port(process.env.FIREBASE_AUTH_EMULATOR_HOST, 9099),
    Number(process.env.PLATFORM_API_PORT) || 18790,
  ];
}

async function blockBackend(page) {
  const ports = backendPorts();
  const handler = (route) => route.abort('internetdisconnected');
  page.__backendBlock = { handler, matcher: (url) => ports.includes(Number(url.port)) && ['127.0.0.1', 'localhost'].includes(url.hostname) };
  await page.route(page.__backendBlock.matcher, handler);
}

async function unblockBackend(page) {
  if (!page.__backendBlock) return;
  await page.unroute(page.__backendBlock.matcher, page.__backendBlock.handler);
  page.__backendBlock = null;
}

async function installFakeScanner(session) {
  await session.context.addInitScript(() => {
    navigator.mediaDevices.getUserMedia = async () => {
      const canvas = document.createElement('canvas');
      canvas.width = 640; canvas.height = 480;
      return canvas.captureStream(10);
    };
  });
  await session.context.route('**/vendor/zxing-library-0.21.3.min.js', (route) => route.fulfill({
    contentType: 'text/javascript',
    body: `window.ZXing = { BrowserMultiFormatReader: class {
      async attachStreamToVideo(stream, video) { this.stream = stream; this.videoElement = video; }
      decodeContinuously(video, callback) { window.deliverScan = (text) => callback({ text, barcodeFormat: 14 }, null); }
      stopContinuousDecode() { delete window.deliverScan; }
      reset() { this.stream = null; }
      isVideoPlaying() { return true; }
    }};`,
  }));
}

async function scanBarcode(page, code) {
  await page.getByRole('button', { name: 'Scan barcode', exact: true }).click();
  await page.waitForFunction(() => typeof window.deliverScan === 'function');
  await page.evaluate((value) => window.deliverScan(value), code);
}

async function goBack(page) {
  await page.getByRole('button', { name: 'Back' }).first().click();
}

async function openTab(page, label) {
  await page.getByRole('tab', { name: new RegExp(`^${label}`) }).or(page.getByRole('button', { name: new RegExp(`^${label}`) })).first().click();
}

async function reopenHome(page, url) {
  await openApp(page, url);
  await waitForHome(page);
}

module.exports = {
  goBack, openTab, reopenHome,
  savedDrafts, blockBackend, unblockBackend, installFakeScanner, scanBarcode,
  signOut, redeemInvitation, finishRedeem,
  selectStop, markArrived, MOBILE_VIEWPORT, waitForHome, planVisitToday, openPlannedVisit, selectProducts,
  continueToSignature, signAndSubmit, signAndTapSubmit, signOrder, tapSubmit, readConfirmedOrderId, routeDayForSunday, openAssignedRoute, acceptAndStartRoute,
};
