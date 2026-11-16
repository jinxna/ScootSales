'use strict';

const B = require('../lib/browser.cjs');
const assert = require('node:assert/strict');
const { PROJECT } = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DEPARTMENT = 'GROCERY';
const NON_ASSORTMENT = {
  productId: 'sr-non-assortment', itemName: 'SR NON ASSORTMENT CABLE', productName: 'SR NON ASSORTMENT CABLE', departmentName: DEPARTMENT,
  mainCategoryName: DEPARTMENT, unitPrice: 5, uom: 'ctn', isVisible: true, status: 'active',
};

async function orderUpToSignature(page, retailer) {
  await mobile.planVisitToday(page, retailer.name);
  await mobile.openPlannedVisit(page, retailer.name);
  await mobile.selectProducts(page, DEPARTMENT, [PRODUCTS[0].name]);
  await mobile.continueToSignature(page);
}

module.exports = {
  name: 'special_request_delivery',
  async run(t) {
    const { db, accounts } = t;

    await t.step('seed a product the retailer cannot order, for the request picker', async () => {
      await db.put('products', NON_ASSORTMENT.productId, NON_ASSORTMENT);
      await db.put('products', 'sr-globally-hidden', { ...NON_ASSORTMENT, productId: 'sr-globally-hidden', itemName: 'GLOBALLY HIDDEN REQUEST', isVisible: false, status: 'hidden' });
      for (const retailer of RETAILERS) {
        const settings = await db.get('retailer_score_sheet_settings', retailer.id);
        await db.put('retailer_score_sheet_settings', retailer.id, { ...settings, hiddenProductIds: [NON_ASSORTMENT.productId] });
      }
    });

    await t.step('Retry sends a refused request after the order is confirmed', async () => {
      const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(s.page, s.url, accounts.salesman.email);
      await mobile.waitForHome(s.page);
      await orderUpToSignature(s.page, RETAILERS[0]);
      await B.scrollIntoView(s.page, s.page.getByRole('button', { name: 'Special request' }));
      await s.page.getByRole('button', { name: 'Special request' }).click();
      await B.semantic(s.page, 'Other (describe)').click();
      assert.equal(await B.semantic(s.page, '[sr-globally-hidden]').count(), 0, 'globally hidden products are not offered');
      await B.semantic(s.page, `[${NON_ASSORTMENT.productId}]`).click();
      await s.page.getByRole('button', { name: 'Save' }).click();
      await db.del('products', NON_ASSORTMENT.productId);
      const orderId = await mobile.signAndSubmit(s.page, DEPARTMENT, 1);
      const retry = s.page.getByRole('button', { name: 'Retry' });
      await retry.waitFor({ timeout: 20000 });
      await t.shot(s, 'request-refused');
      await db.put('products', NON_ASSORTMENT.productId, NON_ASSORTMENT);
      await retry.click();
      const request = await db.waitForDoc('special_requests', orderId, (r) => r.selectedProductId === NON_ASSORTMENT.productId, { label: 'request after Retry' });
      if (request.status !== 'pending_supervisor') throw new Error(`request status: ${request.status}`);
    });

    await t.step('an offline submit keeps the order and its request unsent until the salesperson submits online', async () => {
      for (const visit of await db.list('visits')) await db.del('visits', visit.id);
      const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(s.page, s.url, accounts.salesman.email);
      await mobile.waitForHome(s.page);
      await orderUpToSignature(s.page, RETAILERS[1]);
      await B.scrollIntoView(s.page, s.page.getByRole('button', { name: 'Special request' }));
      await s.page.getByRole('button', { name: 'Special request' }).click();
      await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Other item (describe)' }), 'Offline cable');
      await s.page.getByRole('button', { name: 'Save' }).click();
      await s.page.context().setOffline(true);
      await mobile.signAndTapSubmit(s.page, DEPARTMENT, 1);
      await B.see(s.page, /was saved on this device and was not sent/, { timeout: 40000 });
      const drafts = (await mobile.savedDrafts(s.page, PROJECT, t.seed.uids.salesman)).filter((d) => d.retailerId === RETAILERS[1].id);
      assert.equal(drafts.length, 1, 'the offline order is one durable draft');
      assert.equal(drafts[0].pendingOrderId || '', '', 'an offline attempt is not a submission');
      assert.equal(drafts[0].items[0].productId, PRODUCTS[0].id);
      assert.equal(drafts[0].specialRequest?.description, 'Offline cable');
      await t.shot(s, 'offline-kept-as-draft');
      await s.page.context().setOffline(false);
      await s.page.waitForTimeout(15000);
      assert.equal((await db.list('orders')).filter((o) => o.retailerId === RETAILERS[1].id).length, 0, 'reconnecting sends no order');
      assert.equal((await db.list('special_requests')).filter((r) => r.requestedItem === 'Offline cable').length, 0, 'reconnecting sends no request');
      const orderId = await mobile.signAndSubmit(s.page, DEPARTMENT, 0);
      const matchingOrders = (await db.list('orders')).filter((o) => o.retailerId === RETAILERS[1].id);
      assert.deepEqual(matchingOrders.map((o) => o.id), [orderId]);
      await db.waitForDoc('special_requests', orderId, (r) => r.requestedItem === 'Offline cable', { timeout: 30000, label: 'request after explicit submit' });
    });
  },
};
