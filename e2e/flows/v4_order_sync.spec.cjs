'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DEPARTMENT = 'GROCERY';
const ORDERED = [PRODUCTS[0], PRODUCTS[2]];
const WRITE_CHANNEL = /^http:\/\/127\.0\.0\.1:\d+\/google\.firestore\.v1\.Firestore\/Write\/channel/;
const HOLD_MS = 12000;

function equal(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function ordersOfVisit(db, visitId) {
  return (await db.list('orders')).filter((o) => o.visitId === visitId);
}

async function visitOf(db, retailer) {
  return db.waitForQuery('visits', (v) => v.marketplace === retailer.name, { label: `visit for ${retailer.name}` });
}

async function buildOrder(s, db, retailer) {
  for (const visit of await db.list('visits')) await db.del('visits', visit.id);
  await mobile.planVisitToday(s.page, retailer.name);
  const visit = await visitOf(db, retailer);
  await mobile.openPlannedVisit(s.page, retailer.name);
  await mobile.selectProducts(s.page, DEPARTMENT, ORDERED.map((p) => p.name));
  await mobile.continueToSignature(s.page);
  await mobile.signOrder(s.page, DEPARTMENT, ORDERED.length);
  return visit;
}

function gateFirestoreWrites(page, evidence, label) {
  const gate = { open: false, held: 0, passed: 0, log: [] };
  let release;
  const released = new Promise((resolve) => { release = resolve; });
  gate.release = () => { gate.open = true; release(); };
  gate.ready = page.route(WRITE_CHANNEL, async (route) => {
    const request = route.request();
    if (request.method() !== 'POST' || gate.open || !/ORD-P1-/.test(request.postData() || '')) {
      gate.passed += 1;
      return route.continue().catch(() => null);
    }
    gate.held += 1;
    gate.log.push({ at: Date.now(), bytes: (request.postData() || '').length });
    try {
      await released;
      return await route.continue();
    } catch (error) {
      gate.log.push({ at: Date.now(), error: String(error.message).split('\n')[0] });
      return null;
    }
  });
  gate.snapshot = () => { evidence.gates[label] = { held: gate.held, passed: gate.passed, log: gate.log }; };
  return gate;
}

module.exports = {
  name: 'v4_order_sync',
  async run(t) {
    const { db, accounts, seed } = t;
    const out = path.join(E.OUTPUT_DIR, 'v4_order_sync');
    const evidence = { latencyMs: {}, gates: {}, orders: {}, notes: [], completed: false };
    let adminS;
    try {
      await t.step('admin opens All Orders before any order exists', async () => {
        adminS = await t.session('admin');
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        await admin.goToPage(adminS.page, 'All Orders');
        await adminS.page.getByRole('button', { name: /^Status: / }).first().waitFor({ timeout: 30000 });
        equal((await db.list('orders')).length, 0, 'orders before the flow');
        await t.shot(adminS, 'orders-empty');
      });

      const first = RETAILERS[1];
      let firstOrderId;
      await t.step('salesperson submits an order; the open dashboard shows the same id without a reload', async () => {
        const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-live' });
        await B.loginMobile(s.page, s.url, accounts.salesman.email);
        await mobile.waitForHome(s.page);
        const visit = await buildOrder(s, db, first);
        await t.shot(s, 'signed');

        const marker = await adminS.page.evaluate(() => { window.__e2eSyncMarker = Math.random().toString(36).slice(2); return window.__e2eSyncMarker; });
        const tappedAt = await mobile.tapSubmit(s.page);
        const confirmedOrderId = await mobile.readConfirmedOrderId(s.page);
        const confirmedAt = Date.now();
        firstOrderId = confirmedOrderId;

        const order = await db.waitForDoc('orders', firstOrderId, (o) => o.status === 'submitted');
        const storedAt = Date.now();
        equal(order.orderId, firstOrderId, 'orderId field');
        equal(order.visitId, visit.id, 'order.visitId');
        equal(order.retailerId, first.id, 'retailerId');
        equal(order.salesmanUid, seed.uids.salesman, 'salesmanUid');
        equal((await ordersOfVisit(db, visit.id)).length, 1, 'orders for the visit');
        const serverSubmittedAt = order.submittedAt ? Date.parse(order.submittedAt) : null;

        const dashboardAt = await admin.waitForOrderRow(adminS.page, firstOrderId, { timeout: 60000 });
        equal(await adminS.page.evaluate(() => window.__e2eSyncMarker), marker, 'dashboard page was not reloaded');
        equal(await admin.orderRowCount(adminS.page, firstOrderId), 1, 'dashboard rows for the order');
        await B.see(adminS.page, `Order submitted by ${accounts.salesman.name} for ${first.name}.`, { timeout: 30000 });

        evidence.latencyMs.submitTapToMobileConfirmation = confirmedAt - tappedAt;
        evidence.latencyMs.submitTapToFirestoreVisibleToHarness = storedAt - tappedAt;
        evidence.latencyMs.submitTapToDashboardRowVisible = dashboardAt - tappedAt;
        evidence.latencyMs.confirmationToDashboardRowVisible = dashboardAt - confirmedAt;
        evidence.latencyMs.serverTimestampToDashboardRowVisible = serverSubmittedAt ? dashboardAt - serverSubmittedAt : null;
        evidence.orders.live = { orderId: firstOrderId, visitId: visit.id, retailerId: first.id, dashboardReload: false };
        await t.shot(adminS, 'dashboard-live-row');
      });

      const second = RETAILERS[0];
      await t.step('delayed Firestore write: pending state, no duplicate, one order after release', async () => {
        const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-delayed' });
        await B.loginMobile(s.page, s.url, accounts.salesman.email);
        await mobile.waitForHome(s.page);
        const visit = await buildOrder(s, db, second);
        const gate = gateFirestoreWrites(s.page, evidence, 'delayed');
        await gate.ready;

        const tappedAt = await mobile.tapSubmit(s.page);
        await B.see(s.page, /Submission is still pending/, { timeout: 30000 });
        const pendingAfter = Date.now() - tappedAt;
        evidence.latencyMs.delayedSubmitTapToPendingNotice = pendingAfter;
        if (gate.held === 0) throw new Error('no Firestore Write/channel request was held: the route pattern did not match');
        equal((await ordersOfVisit(db, visit.id)).length, 0, 'orders at the server while the write is held');
        await t.shot(s, 'pending');
        equal(await s.page.getByText(/Order sent/).count(), 0, 'confirmation shown before acknowledgement');

        await s.page.getByRole('button', { name: 'Check Submission', exact: true }).waitFor({ timeout: 10000 });
        await mobile.tapSubmit(s.page, 'Check Submission');
        await B.see(s.page, /Submission is still pending/, { timeout: 30000 });
        equal((await ordersOfVisit(db, visit.id)).length, 0, 'orders at the server after a second tap while held');

        const remaining = HOLD_MS - (Date.now() - tappedAt);
        if (remaining > 0) await sleep(remaining);
        const releasedAt = Date.now();
        gate.release();
        const order = await db.waitForQuery('orders', (o) => o.retailerId === second.id, { timeout: 60000, label: 'order after release' });
        evidence.latencyMs.releaseToOrderStored = Date.now() - releasedAt;
        evidence.latencyMs.delayedSubmitTapToOrderStored = Date.now() - tappedAt;
        equal(order.visitId, visit.id, 'delayed order visitId');
        await sleep(2000);
        const stored = await ordersOfVisit(db, visit.id);
        equal(stored.length, 1, 'orders for the visit after release');
        equal(stored[0].id, order.id, 'the single order id');
        await admin.waitForOrderRow(adminS.page, order.id, { timeout: 60000 });
        equal(await admin.orderRowCount(adminS.page, order.id), 1, 'dashboard rows for the delayed order');
        gate.snapshot();
        evidence.orders.delayed = { orderId: order.id, visitId: visit.id, retailerId: second.id, heldRequests: gate.held };
        await t.shot(adminS, 'dashboard-after-delay');
      });

      const reloadCases = [
        { key: 'reloadWhileHeld', retailer: RETAILERS[1], title: 'page reloaded while the write is held, then resubmitted: one order, one dashboard row', hold: true },
        { key: 'reloadRightAfterTap', retailer: RETAILERS[0], title: 'page reloaded straight after the tap with the network open, then resubmitted if offered: one order, one dashboard row', hold: false },
      ];
      for (const c of reloadCases) {
        await t.step(c.title, async () => {
          const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: `mobile-${c.key}` });
          await B.loginMobile(s.page, s.url, accounts.salesman.email);
          await mobile.waitForHome(s.page);
          const visit = await buildOrder(s, db, c.retailer);
          const gate = c.hold ? gateFirestoreWrites(s.page, evidence, c.key) : null;
          if (gate) await gate.ready;

          const tappedAt = await mobile.tapSubmit(s.page);
          if (gate) {
            while (gate.held === 0) await sleep(100);
            await sleep(1500);
            equal((await ordersOfVisit(db, visit.id)).length, 0, 'orders at the server while the write is held');
            await t.shot(s, `${c.key}-unacknowledged`);
          }
          equal(await s.page.getByText(/Order sent/).count(), 0, 'confirmation shown before the reload');
          await s.page.reload({ waitUntil: 'domcontentloaded' });
          if (gate) gate.release();
          await B.enableSemantics(s.page);
          await mobile.waitForHome(s.page);
          const card = s.page.getByRole('button', { name: new RegExp(`^Personal plan[^]*${c.retailer.name}`) });
          await card.first().waitFor({ timeout: 60000 });
          await sleep(3000);
          const atServerAfterReload = (await ordersOfVisit(db, visit.id)).map((o) => o.id);
          evidence.orders[c.key] = { visitId: visit.id, atServerAfterReload };
          await t.shot(s, `${c.key}-after-reload`);

          const cardText = (await card.count()) ? ((await card.first().getAttribute('aria-label')) || (await card.first().textContent()) || '') : '';
          const offered = /In Progress|not sent yet|not confirmed/.test(cardText);
          if (!atServerAfterReload.length && !offered) {
            throw new Error(`no order at the server and the visit card does not offer to finish it: ${cardText}`);
          }
          evidence.orders[c.key].cardText = cardText;
          evidence.orders[c.key].resubmitOffered = offered;
          let orderId;
          if (offered) {
            await mobile.openPlannedVisit(s.page, c.retailer.name);
            const check = s.page.getByRole('button', { name: 'Check Submission', exact: true });
            const submit = s.page.getByRole('button', { name: 'Submit Order', exact: true });
            await check.or(submit).first().waitFor({ timeout: 30000 });
            const label = (await check.count()) ? 'Check Submission' : 'Submit Order';
            evidence.orders[c.key].resubmitButton = label;
            await t.shot(s, `${c.key}-restored-draft`);
            const resubmitAt = await mobile.tapSubmit(s.page, label);
            orderId = await mobile.readConfirmedOrderId(s.page, { timeout: 60000 });
            evidence.latencyMs[`${c.key}ResubmitTapToConfirmation`] = Date.now() - resubmitAt;
          }
          const order = await db.waitForQuery('orders', (o) => o.visitId === visit.id, { timeout: 30000, label: `order for ${c.key}` });
          await sleep(2000);
          const stored = await ordersOfVisit(db, visit.id);
          equal(stored.length, 1, 'orders for the visit after the resubmit');
          equal(stored[0].id, order.id, 'the single order id');
          if (orderId) equal(orderId, order.id, 'confirmation order id');
          evidence.orders[c.key].orderId = order.id;
          evidence.latencyMs[`${c.key}FirstTapToOrderStored`] = Date.now() - tappedAt;
          await admin.waitForOrderRow(adminS.page, order.id, { timeout: 60000 });
          equal(await admin.orderRowCount(adminS.page, order.id), 1, 'dashboard rows for the order');
          if (gate) gate.snapshot();
          await t.shot(adminS, `dashboard-${c.key}`);
        });
      }
    } finally {
      fs.mkdirSync(out, { recursive: true });
      fs.writeFileSync(path.join(out, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    }
  },
};
