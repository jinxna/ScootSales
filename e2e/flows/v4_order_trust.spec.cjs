'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const { PROJECT } = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DEPARTMENT = 'GROCERY';
const [VINEGAR, , OAT] = PRODUCTS;
const money = (value) => value.toFixed(2);
const cents = (value) => Math.round(value * 100);

async function setOverride(db, retailerId, productId, unitPrice) {
  const sheet = await db.get('retailer_score_sheet_settings', retailerId);
  const overrides = { ...(sheet.productOverrides || {}) };
  overrides[productId] = { ...(overrides[productId] || {}), unitPrice, price: unitPrice };
  await db.put('retailer_score_sheet_settings', retailerId, { ...sheet, productOverrides: overrides, updatedAt: new Date() });
}

async function setMasterPrice(db, productId, unitPrice) {
  const product = await db.get('products', productId);
  await db.put('products', productId, { ...product, unitPrice });
}

async function clearVisits(db) {
  for (const visit of await db.list('visits')) await db.del('visits', visit.id);
}

async function ordersFor(db, retailerId) {
  return (await db.list('orders')).filter((o) => o.retailerId === retailerId);
}

async function orderUpToCount(page, retailer, names) {
  await mobile.planVisitToday(page, retailer.name);
  await mobile.openPlannedVisit(page, retailer.name);
  await mobile.selectProducts(page, DEPARTMENT, names);
}

async function home(page, url) {
  await B.openApp(page, url);
  await mobile.waitForHome(page);
}

module.exports = {
  name: 'v4_order_trust',
  async run(t) {
    const { db, accounts, seed } = t;
    const only = process.env.V4_ORDER_TRUST_ONLY || '';
    const runs = (name) => !only || only === name;
    const uid = seed.uids.salesman;
    const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, persistence: true });
    await mobile.installFakeScanner(s);
    const result = {};

    await t.step('salesperson logs in', async () => {
      await B.loginMobile(s.page, s.url, accounts.salesman.email);
      await mobile.waitForHome(s.page);
    });

    if (runs('retailer_price')) {
      const retailer = RETAILERS[0];
      const sheetPrice = 25.5;
      let orderId;
      await t.step('retailer_price: the cart shows the retailer sheet price, not the master price', async () => {
        await clearVisits(db);
        await setOverride(db, retailer.id, VINEGAR.id, sheetPrice);
        await orderUpToCount(s.page, retailer, [VINEGAR.name, OAT.name]);
        await B.see(s.page, `Unit Price: RM ${money(sheetPrice)}`);
        assert.equal(await B.semantic(s.page, `Unit Price: RM ${money(VINEGAR.price)}`).count(), 0, 'master price must not replace the retailer price');
        await t.shot(s, 'retailer-price-cart');
      });
      await t.step('retailer_price: the accepted order captures the price and its source', async () => {
        await mobile.continueToSignature(s.page);
        await B.see(s.page, `RM ${money(sheetPrice + OAT.price)}`);
        orderId = await mobile.signAndSubmit(s.page, DEPARTMENT, 2);
        const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
        const vinegar = order.items.find((i) => i.productId === VINEGAR.id);
        const oat = order.items.find((i) => i.productId === OAT.id);
        assert.equal(vinegar.price, sheetPrice);
        assert.equal(vinegar.priceSource, 'retailer_sheet');
        assert.equal(oat.price, OAT.price);
        assert.equal(oat.priceSource, 'master_catalogue');
        assert.equal(cents(order.totalPrice), cents(sheetPrice + OAT.price));
        result.retailerPriceOrder = { orderId, items: order.items.map(({ productId, price, priceSource }) => ({ productId, price, priceSource })), totalPrice: order.totalPrice };
      });
      await t.step('retailer_price: later price changes never rewrite the accepted order', async () => {
        await setOverride(db, retailer.id, VINEGAR.id, 27);
        await setMasterPrice(db, VINEGAR.id, 31);
        await s.page.getByRole('button', { name: /^Home/ }).first().click();
        await s.page.getByRole('button', { name: /^Orders/ }).click();
        await B.see(s.page, new RegExp(`${orderId}[^]*RM ${money(sheetPrice + OAT.price)}`), { timeout: 30000 });
        const order = await db.get('orders', orderId);
        assert.equal(order.items.find((i) => i.productId === VINEGAR.id).price, sheetPrice);
        assert.equal(cents(order.totalPrice), cents(sheetPrice + OAT.price));
        await t.shot(s, 'retailer-price-history-kept');
        await home(s.page, s.url);
      });
    }

    if (runs('price_review')) {
      const retailer = RETAILERS[1];
      let before;
      await t.step('price_review: a signed draft is saved durably on this device', async () => {
        await clearVisits(db);
        before = {
          vinegar: (await db.get('products', VINEGAR.id)).unitPrice,
          oat: (await db.get('products', OAT.id)).unitPrice,
        };
        await orderUpToCount(s.page, retailer, [VINEGAR.name, OAT.name]);
        await mobile.continueToSignature(s.page);
        await mobile.signOrder(s.page, DEPARTMENT, 2);
        await s.page.getByRole('button', { name: 'Save Draft', exact: true }).click();
        await B.see(s.page, /Draft saved/);
        const drafts = (await mobile.savedDrafts(s.page, PROJECT, uid)).filter((d) => d.retailerId === retailer.id);
        assert.equal(drafts.length, 1);
        assert.equal(drafts[0].progress, 4);
        const line = drafts[0].items.find((i) => i.productId === VINEGAR.id);
        assert.equal(line.price, before.vinegar);
        assert.equal(drafts[0].pendingOrderId || '', '', 'a saved draft has not been sent');
        assert.equal((await ordersFor(db, retailer.id)).length, 0);
      });
      await t.step('price_review: sign-out and sign-in of the same owner restores the draft', async () => {
        await home(s.page, s.url);
        await mobile.signOut(s.page);
        await B.loginMobile(s.page, s.url, accounts.salesman.email);
        await mobile.waitForHome(s.page);
        await mobile.openPlannedVisit(s.page, retailer.name);
        await B.see(s.page, /Total \(2 products, 2 boxes\)/);
        await B.see(s.page, `RM ${money(before.vinegar + before.oat)}`);
        assert.equal(await B.semantic(s.page, 'Prices changed since this draft was saved').count(), 0);
        await t.shot(s, 'draft-after-relogin');
      });
      const after = { vinegar: 29.75, oat: 10.5 };
      await t.step('price_review: a reopened draft shows changed prices and blocks submission', async () => {
        await setOverride(db, retailer.id, VINEGAR.id, after.vinegar);
        await setMasterPrice(db, OAT.id, after.oat);
        await home(s.page, s.url);
        await mobile.openPlannedVisit(s.page, retailer.name);
        await B.see(s.page, 'Prices changed since this draft was saved', { timeout: 30000 });
        await B.see(s.page, `${VINEGAR.name}: was RM ${money(before.vinegar)}, now RM ${money(after.vinegar)}`);
        await B.see(s.page, `${OAT.name}: was RM ${money(before.oat)}, now RM ${money(after.oat)}`);
        const submit = s.page.getByRole('button', { name: 'Submit Order' });
        assert.equal(await submit.isEnabled(), false, 'submission waits for the price review');
        await t.shot(s, 'price-review');
      });
      await t.step('price_review: accepting the new prices needs a new signature, then submits them', async () => {
        await s.page.getByRole('button', { name: 'Accept new prices' }).click();
        await B.see(s.page, /1 department still needs a signature/);
        await B.see(s.page, `RM ${money(after.vinegar + after.oat)}`);
        const orderId = await mobile.signAndSubmit(s.page, DEPARTMENT, 0);
        const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
        const vinegar = order.items.find((i) => i.productId === VINEGAR.id);
        const oat = order.items.find((i) => i.productId === OAT.id);
        assert.equal(vinegar.price, after.vinegar);
        assert.equal(vinegar.priceSource, 'retailer_sheet');
        assert.equal(oat.price, after.oat);
        assert.equal(oat.priceSource, 'master_catalogue');
        assert.equal((await ordersFor(db, retailer.id)).length, 1);
        result.priceReviewOrder = { orderId, before, after, totalPrice: order.totalPrice };
        await t.shot(s, 'price-review-submitted');
        await home(s.page, s.url);
      });
    }

    if (runs('offline_submit')) {
      const retailer = RETAILERS[0];
      let existing;
      await t.step('offline_submit: Submit while offline keeps the order as an unsent draft', async () => {
        await clearVisits(db);
        existing = new Set((await ordersFor(db, retailer.id)).map((o) => o.id));
        await orderUpToCount(s.page, retailer, [OAT.name]);
        await mobile.continueToSignature(s.page);
        await mobile.signOrder(s.page, DEPARTMENT, 1);
        await s.context.setOffline(true);
        await mobile.tapSubmit(s.page);
        await B.see(s.page, /was saved on this device and was not sent|Submission is still pending/, { timeout: 40000 });
        await t.shot(s, 'offline-submit');
      });
      await t.step('offline_submit: reconnecting does not send the order', async () => {
        await s.context.setOffline(false);
        const deadline = Date.now() + 25000;
        while (Date.now() < deadline) {
          const arrived = (await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id));
          assert.equal(arrived.length, 0, `order reached the server without an explicit submit: ${arrived.map((o) => o.id)}`);
          await s.page.waitForTimeout(1000);
        }
      });
      await t.step('offline_submit: after reload the draft is still there and still unsent', async () => {
        await home(s.page, s.url);
        await s.page.waitForTimeout(5000);
        assert.equal((await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id)).length, 0);
        const drafts = (await mobile.savedDrafts(s.page, PROJECT, uid)).filter((d) => d.retailerId === retailer.id);
        assert.equal(drafts.length, 1);
        assert.equal(drafts[0].pendingOrderId || '', '', 'an offline attempt is a draft, not a submission');
        await B.see(s.page, new RegExp(`Personal plan[^]*${retailer.name}[^]*Signed, not sent yet - open to submit`), { timeout: 30000 });
        await t.shot(s, 'offline-draft-visit-card');
        await mobile.openPlannedVisit(s.page, retailer.name);
        await s.page.getByRole('button', { name: 'Submit Order' }).waitFor({ timeout: 30000 });
        await t.shot(s, 'offline-draft-after-reload');
      });
      await t.step('offline_submit: the explicit submit sends exactly one order', async () => {
        await mobile.tapSubmit(s.page);
        const orderId = await mobile.readConfirmedOrderId(s.page);
        const arrived = (await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id));
        assert.deepEqual(arrived.map((o) => o.id), [orderId]);
        result.offlineSubmitOrder = orderId;
        await home(s.page, s.url);
      });
    }

    if (runs('lost_ack')) {
      const retailer = RETAILERS[1];
      const writes = /google\.firestore\.v1\.Firestore\/Write\/channel/;
      const dropWrites = (route) => route.abort('connectionreset');
      let existing;
      let pendingId;
      await t.step('lost_ack: an online submit whose acknowledgement never arrives keeps its order id', async () => {
        await clearVisits(db);
        existing = new Set((await ordersFor(db, retailer.id)).map((o) => o.id));
        await orderUpToCount(s.page, retailer, [OAT.name]);
        await mobile.continueToSignature(s.page);
        await mobile.signOrder(s.page, DEPARTMENT, 1);
        await s.page.route(writes, dropWrites);
        await mobile.tapSubmit(s.page);
        await B.see(s.page, /Submission is still pending/, { timeout: 40000 });
        const drafts = (await mobile.savedDrafts(s.page, PROJECT, uid)).filter((d) => d.retailerId === retailer.id);
        assert.equal(drafts.length, 1);
        pendingId = drafts[0].pendingOrderId;
        assert.match(pendingId, /^ORD-P1-[0-9a-f]{32}$/);
        await t.shot(s, 'lost-ack-pending');
      });
      await t.step('lost_ack: after restart the uncertain submission is shown and never resent twice', async () => {
        await home(s.page, s.url);
        await B.see(s.page, new RegExp(`Personal plan[^]*${retailer.name}[^]*Submission not confirmed - open to check`), { timeout: 30000 });
        await t.shot(s, 'lost-ack-visit-card');
        await mobile.openPlannedVisit(s.page, retailer.name);
        await B.see(s.page, new RegExp(`Submission not confirmed[^]*${pendingId}`), { timeout: 30000 });
        await s.page.getByRole('button', { name: 'Check Submission' }).click();
        await B.see(s.page, /Submission is still pending/, { timeout: 30000 });
        await s.page.unroute(writes, dropWrites);
        await s.context.setOffline(true);
        await s.context.setOffline(false);
        await db.waitForDoc('orders', pendingId, (o) => o.status === 'submitted', { timeout: 90000, label: 'uncertain order' });
        await s.page.getByRole('button', { name: 'Check Submission' }).click();
        assert.equal(await mobile.readConfirmedOrderId(s.page), pendingId);
        const arrived = (await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id));
        assert.deepEqual(arrived.map((o) => o.id), [pendingId], 'one order under the original id');
        result.lostAckOrder = pendingId;
        await t.shot(s, 'lost-ack-confirmed');
        await home(s.page, s.url);
      });
    }

    if (runs('offline_pack')) {
      const retailer = RETAILERS[0];
      let existing;
      let sheetPrice;
      await t.step('offline_pack: preparing online caches the catalogue and the retailer sheet', async () => {
        await clearVisits(db);
        existing = new Set((await ordersFor(db, retailer.id)).map((o) => o.id));
        await setOverride(db, retailer.id, VINEGAR.id, 24.4);
        sheetPrice = 24.4;
        await mobile.planVisitToday(s.page, retailer.name);
        await mobile.openPlannedVisit(s.page, retailer.name);
        await s.page.locator(`[aria-label="${DEPARTMENT}"]`).first().click();
        await s.page.getByRole('checkbox', { name: new RegExp(OAT.name.replace(/[()]/g, '\\$&')) }).waitFor({ timeout: 30000 });
        await s.page.waitForTimeout(3000);
      });
      await t.step('offline_pack: a cold start without backend opens the prepared catalogue', async () => {
        await mobile.blockBackend(s.page);
        await home(s.page, s.url);
        await mobile.openPlannedVisit(s.page, retailer.name);
        await B.see(s.page, /Offline catalogue/, { timeout: 30000 });
        await t.shot(s, 'offline-catalogue');
      });
      await t.step('offline_pack: scanning resolves known barcodes from the cache and refuses unknown ones', async () => {
        await mobile.scanBarcode(s.page, OAT.barcode);
        await s.page.getByRole('button', { name: /^Add to Cart \(1\)/ }).waitFor({ timeout: 20000 });
        await mobile.scanBarcode(s.page, '4006381333931');
        await B.see(s.page, 'Barcode 4006381333931 not found for this retailer.');
      });
      await t.step('offline_pack: manual selection without a barcode reaches the cart with the sheet price', async () => {
        const vinegar = s.page.getByRole('checkbox', { name: new RegExp(VINEGAR.name.replace(/[()]/g, '\\$&')) });
        await B.scrollIntoView(s.page, vinegar, { minHeight: 20 });
        await vinegar.click();
        await s.page.getByRole('button', { name: /^Add to Cart \(2\)/ }).click();
        await s.page.getByRole('button', { name: 'Start counting' }).click();
        await B.see(s.page, `Unit Price: RM ${money(sheetPrice)}`, { timeout: 30000 });
        await t.shot(s, 'offline-cart');
      });
      await t.step('offline_pack: an offline submit stays a draft until the salesperson submits online', async () => {
        await mobile.continueToSignature(s.page);
        await mobile.signOrder(s.page, DEPARTMENT, 2);
        await mobile.tapSubmit(s.page);
        await B.see(s.page, /was saved on this device and was not sent/, { timeout: 40000 });
        await mobile.unblockBackend(s.page);
        await s.page.waitForTimeout(15000);
        assert.equal((await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id)).length, 0);
        await mobile.tapSubmit(s.page);
        const orderId = await mobile.readConfirmedOrderId(s.page, { timeout: 60000 });
        const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
        assert.equal(order.items.find((i) => i.productId === VINEGAR.id).price, sheetPrice);
        assert.deepEqual((await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id)).map((o) => o.id), [orderId]);
        result.offlinePackOrder = orderId;
        await t.shot(s, 'offline-pack-submitted');
      });
    }

    if (runs('offline_no_sheet')) {
      const retailer = RETAILERS[1];
      const sheet = await db.get('retailer_score_sheet_settings', retailer.id);
      const unavailable = /score sheet is not available on this device/;
      let existing;
      let masterPrice;
      try {
        await t.step('offline_no_sheet: a retailer without a score sheet is opened online once', async () => {
          await home(s.page, s.url);
          await clearVisits(db);
          existing = new Set((await ordersFor(db, retailer.id)).map((o) => o.id));
          await db.del('retailer_score_sheet_settings', retailer.id);
          masterPrice = (await db.get('products', OAT.id)).unitPrice;
          await mobile.planVisitToday(s.page, retailer.name);
          await mobile.openPlannedVisit(s.page, retailer.name);
          await s.page.locator(`[aria-label="${DEPARTMENT}"]`).first().click();
          await s.page.getByRole('checkbox', { name: new RegExp(OAT.name.replace(/[()]/g, '\\$&')) }).waitFor({ timeout: 30000 });
          assert.equal(await B.semantic(s.page, unavailable).count(), 0, 'online, a missing sheet is not reported as unavailable');
          await s.page.waitForTimeout(3000);
        });
        await t.step('offline_no_sheet: offline, the draft uses master prices instead of failing', async () => {
          await mobile.blockBackend(s.page);
          await home(s.page, s.url);
          await mobile.openPlannedVisit(s.page, retailer.name);
          await B.see(s.page, /Offline catalogue/, { timeout: 30000 });
          assert.equal(await B.semantic(s.page, unavailable).count(), 0, 'offline, a confirmed missing sheet is not reported as unavailable');
          await mobile.selectProducts(s.page, DEPARTMENT, [OAT.name]);
          await B.see(s.page, `Unit Price: RM ${money(masterPrice)}`, { timeout: 30000 });
          await t.shot(s, 'offline-no-sheet-cart');
          await mobile.continueToSignature(s.page);
          await mobile.signOrder(s.page, DEPARTMENT, 1);
          await mobile.tapSubmit(s.page);
          await B.see(s.page, /was saved on this device and was not sent/, { timeout: 40000 });
          const drafts = (await mobile.savedDrafts(s.page, PROJECT, uid)).filter((d) => d.retailerId === retailer.id);
          assert.equal(drafts.length, 1);
          const line = drafts[0].items.find((i) => i.productId === OAT.id);
          assert.equal(line.price, masterPrice);
          assert.equal(line.priceSource, 'master_catalogue');
          result.offlineNoSheetDraft = { retailerId: retailer.id, price: line.price, priceSource: line.priceSource };
          await t.shot(s, 'offline-no-sheet-draft');
        });
        await t.step('offline_no_sheet: back online the draft submits once at the master price', async () => {
          await mobile.unblockBackend(s.page);
          await s.page.waitForTimeout(15000);
          let orderId = null;
          for (let attempt = 0; attempt < 3 && !orderId; attempt += 1) {
            await mobile.tapSubmit(s.page);
            orderId = await mobile.readConfirmedOrderId(s.page, { timeout: 30000 }).catch(() => null);
          }
          assert.ok(orderId, 'the draft was not submitted after three attempts once the backend was reachable');
          const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
          const oat = order.items.find((i) => i.productId === OAT.id);
          assert.equal(oat.price, masterPrice);
          assert.equal(oat.priceSource, 'master_catalogue');
          assert.deepEqual((await ordersFor(db, retailer.id)).filter((o) => !existing.has(o.id)).map((o) => o.id), [orderId]);
          result.offlineNoSheetOrder = orderId;
          await t.shot(s, 'offline-no-sheet-submitted');
        });
      } finally {
        await mobile.unblockBackend(s.page);
        if (sheet) await db.put('retailer_score_sheet_settings', retailer.id, sheet);
      }
    }

    if (runs('order_location')) {
      const retailer = RETAILERS[0];
      const first = { latitude: RETAILERS[0].lat, longitude: RETAILERS[0].lng, accuracy: 10 };
      const moved = { latitude: RETAILERS[1].lat, longitude: RETAILERS[1].lng, accuracy: 10 };
      const near = (actual, expected) => Math.abs(actual - expected) < 1e-6;
      let before;
      const phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'phone-location' });
      await t.step('order_location: location sharing starts a work session with a first position', async () => {
        await clearVisits(db);
        const profile = await db.get('users', accounts.salesman.email);
        await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
        await db.put('tracking_controls', uid, { mode: 'live', revision: 1, updatedByUid: seed.uids.admin, updatedAt: new Date() });
        await B.fakeGeolocation(phone.context, first);
        await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
        await mobile.waitForHome(phone.page);
        before = await db.waitForDoc('live_tracking', uid, (l) => typeof l.latitude === 'number' && l.lastFixSequence >= 1 && l.trackingMode === 'live',
          { timeout: 60000, label: 'first live_tracking position' });
        assert.ok(near(before.latitude, first.latitude) && near(before.longitude, first.longitude), 'the first position is the one the browser reports');
      });
      await t.step('order_location: the submitted order stores the position captured at submit time', async () => {
        await orderUpToCount(phone.page, retailer, [OAT.name]);
        await mobile.continueToSignature(phone.page);
        const orderId = await mobile.signAndSubmit(phone.page, DEPARTMENT, 1);
        await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
        const fix = await db.waitForDoc('gps_tracking', `order_${orderId}`, (d) => typeof d.latitude === 'number',
          { timeout: 30000, label: 'order location record' });
        assert.ok(fix.latitude >= -90 && fix.latitude <= 90 && fix.longitude >= -180 && fix.longitude <= 180, 'coordinates are in range');
        assert.ok(near(fix.latitude, first.latitude) && near(fix.longitude, first.longitude), 'coordinates are the ones the browser reported');
        assert.ok(near(fix.gpsLatitude, fix.latitude) && near(fix.gpsLongitude, fix.longitude), 'gps fields repeat the coordinates');
        assert.ok(near(fix.location.geoPointValue.latitude, fix.latitude) && near(fix.location.geoPointValue.longitude, fix.longitude), 'geo point repeats the coordinates');
        assert.equal(typeof fix.accuracyMeters, 'number');
        assert.ok(fix.accuracyMeters > 0 && fix.accuracyMeters <= 100, 'accuracy is plausible');
        assert.equal(fix.isMocked, false);
        assert.equal(fix.locationVerification, 'device_captured');
        assert.equal(fix.locationEvidence.mode, fix.locationVerification);
        assert.equal(fix.lastOrderId, orderId);
        assert.equal(fix.salesmanUid, uid);
        assert.ok(fix.deviceCapturedAt instanceof Date, 'the device capture time is a timestamp');
        assert.ok(Math.abs(fix.deviceCapturedAt.getTime() - Date.now()) < 10 * 60 * 1000, 'the device capture time is recent');
        assert.ok(fix.locationCapturedAt instanceof Date, 'the server capture time is a timestamp');
        assert.ok(Math.abs(fix.locationCapturedAt.getTime() - Date.now()) < 10 * 60 * 1000, 'the server capture time is recent');
        const profile = await db.waitForDoc('users', accounts.salesman.email, (u) => typeof u.lastLatitude === 'number', { timeout: 30000, label: 'last order position on the profile' });
        assert.ok(near(profile.lastLatitude, fix.latitude) && near(profile.lastLongitude, fix.longitude));
        result.orderLocation = {
          orderId,
          latitude: fix.latitude,
          longitude: fix.longitude,
          accuracyMeters: fix.accuracyMeters,
          locationVerification: fix.locationVerification,
          deviceCapturedAt: fix.deviceCapturedAt.toISOString(),
          locationCapturedAt: fix.locationCapturedAt.toISOString(),
        };
        await t.shot(phone, 'order-location-submitted');
      });
      await t.step('order_location: offline, a new position stays pending on the phone and is not sent', async () => {
        await phone.page.getByRole('button', { name: /^Home/ }).first().click();
        await mobile.openTab(phone.page, 'Profile');
        before = await db.get('live_tracking', uid);
        await phone.context.setOffline(true);
        await B.moveDevice(phone.page, moved);
        await seeWhileScrolling(phone.page, /Location sync is pending/, 150000);
        const during = await db.get('live_tracking', uid);
        assert.equal(during.lastFixSequence, before.lastFixSequence);
        assert.ok(near(during.latitude, before.latitude), 'nothing reached the server while offline');
        await t.shot(phone, 'gps-offline-pending');
      });
      await t.step('order_location: after reconnecting the pending position reaches live_tracking', async () => {
        await phone.context.setOffline(false);
        const live = await db.waitForDoc('live_tracking', uid,
          (l) => l.lastFixSequence > before.lastFixSequence && near(l.latitude, moved.latitude) && near(l.longitude, moved.longitude),
          { timeout: 150000, label: 'live_tracking position after reconnecting' });
        assert.ok(live.deviceCapturedAt.getTime() > before.deviceCapturedAt.getTime(), 'the stored position is newer');
        await seeWhileScrolling(phone.page, /Sharing your current location/, 60000);
        result.gpsAfterReconnect = { sequenceBefore: before.lastFixSequence, sequenceAfter: live.lastFixSequence, latitude: live.latitude, longitude: live.longitude };
        await t.shot(phone, 'gps-after-reconnect');
      });
    }

    const out = path.join(__dirname, '..', 'output', 'v4_order_trust');
    fs.mkdirSync(out, { recursive: true });
    fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify({ only: only || 'all', ...result }, null, 2));
  },
};

async function seeWhileScrolling(page, pattern, timeout) {
  const size = page.viewportSize();
  const deadline = Date.now() + timeout;
  for (let round = 0; Date.now() < deadline; round += 1) {
    if (await B.semantic(page, pattern).count()) return;
    await page.mouse.move(size.width / 2, size.height / 2);
    await page.mouse.wheel(0, round % 8 === 7 ? -10000 : 300);
    await page.waitForTimeout(500);
  }
  throw new Error(`expected to see ${pattern} on the page, but it never appeared`);
}
