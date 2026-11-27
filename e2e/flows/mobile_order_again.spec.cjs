'use strict';

const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const { PROJECT } = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DEPARTMENT = 'GROCERY';
const [VINEGAR, , OAT] = PRODUCTS;
const RETAILER = RETAILERS[0];
const PAST_A = 'ORD-OA-PASTA';
const PAST_B = 'ORD-OA-PASTB';
const QTY_A = 3;
const QTY_B = 2;
const PHONE = { width: 390, height: 844 };
const WRITES = /google\.firestore\.v1\.Firestore\/Write\/channel/;
const dropWrites = (route) => route.abort('connectionreset');

module.exports = {
  name: 'mobile_order_again',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const s = await t.session('mobile', { viewport: PHONE, persistence: true });
    const page = s.page;

    const draft = async () => {
      const drafts = (await mobile.savedDrafts(page, PROJECT, uid)).filter((d) => d.retailerId === RETAILER.id);
      assert.equal(drafts.length, 1, 'one saved cart for the shop');
      return drafts[0];
    };
    const waitForDraft = async (check, label) => {
      const deadline = Date.now() + 20000;
      let last = null;
      while (Date.now() < deadline) {
        const drafts = (await mobile.savedDrafts(page, PROJECT, uid)).filter((d) => d.retailerId === RETAILER.id);
        last = drafts[0] || null;
        if (last && check(last)) return last;
        await page.waitForTimeout(250);
      }
      throw new Error(`${label}: saved cart was ${JSON.stringify(last && { items: last.items.map((i) => [i.productId, i.qty]), pendingOrderId: last.pendingOrderId })}`);
    };
    const lines = (d) => d.items.map((i) => [i.productId, i.qty]);
    const gone = (text) => B.semantic(page, text).waitFor({ state: 'detached', timeout: 15000 });
    const openPastOrder = async (id) => {
      await mobile.openTab(page, 'Orders');
      await page.getByRole('button', { name: new RegExp(id) }).click();
      await page.getByRole('button', { name: 'Reuse order', exact: true }).waitFor({ timeout: 20000 });
    };
    const tapReuse = () => page.getByRole('button', { name: 'Reuse order', exact: true }).click();
    const reload = async () => {
      await B.openApp(page, s.url);
      await mobile.waitForHome(page);
    };

    await t.step('seed two past orders with different products for the salesperson at the first shop', async () => {
      const at = new Date(Date.now() - 2 * 86400 * 1000);
      const past = (id, product, qty) => db.put('orders', id, {
        orderId: id, retailerId: RETAILER.id, retailerName: RETAILER.name, outlet: RETAILER.name, branchId: 'B1',
        uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code,
        status: 'submitted', totalProducts: 1, totalBoxes: qty, totalPrice: product.price * qty,
        items: [{
          name: product.name, productId: product.id, barcode: product.barcode, packingSize: '24 X 500ML',
          department: DEPARTMENT, qty, price: product.price, shelfBatches: [],
        }],
        submittedAt: at, createdAt: at,
      });
      await past(PAST_A, OAT, QTY_A);
      await past(PAST_B, VINEGAR, QTY_B);
      assert.equal((await db.get('orders', PAST_A)).items[0].productId, OAT.id);
      assert.equal((await db.get('orders', PAST_B)).items[0].productId, VINEGAR.id);
    });

    await t.step('Reuse order on a shop with no cart opens the cart with no question and saves it unsent', async () => {
      await B.loginMobile(page, s.url, accounts.salesman.email);
      await mobile.waitForHome(page);
      await openPastOrder(PAST_A);
      await t.shot(s, 'past-order-a');
      await tapReuse();
      await B.see(page, `Product ID: ${OAT.id}`, { timeout: 30000 });
      assert.equal(await B.semantic(page, 'Replace the unsent order?').count(), 0, 'no question when the shop has no cart');
      await B.see(page, 'Saved');
      const saved = await waitForDraft((d) => d.items.length === 1 && d.items[0].productId === OAT.id && d.items[0].qty === QTY_A, 'unsent cart');
      assert.equal(saved.pendingOrderId || '', '', 'the cart has not been sent');
      await t.shot(s, 'unsent-cart');
      await reload();
    });

    await t.step('Reuse order on another past order asks before replacing the unsent cart', async () => {
      await openPastOrder(PAST_B);
      await t.shot(s, 'past-order-b');
      await tapReuse();
      await B.see(page, 'Replace the unsent order?');
      await B.see(page, 'This shop already has an unsent order.');
      await page.getByRole('button', { name: 'Keep it', exact: true }).waitFor({ timeout: 10000 });
      await page.getByRole('button', { name: 'Replace', exact: true }).waitFor({ timeout: 10000 });
      await t.shot(s, 'replace-question');
    });

    await t.step('Keep it closes the question and leaves the cart as it was', async () => {
      await page.getByRole('button', { name: 'Keep it', exact: true }).click();
      await gone('Replace the unsent order?');
      await page.getByRole('button', { name: 'Reuse order', exact: true }).waitFor({ timeout: 10000 });
      assert.equal(await B.semantic(page, `Product ID: ${VINEGAR.id}`).count(), 0, 'the cart did not open');
      assert.deepEqual(lines(await draft()), [[OAT.id, QTY_A]]);
      await t.shot(s, 'kept-answer');
      await reload();
    });

    await t.step('Replace opens the cart with the other past order items', async () => {
      await openPastOrder(PAST_B);
      await tapReuse();
      await B.see(page, 'Replace the unsent order?');
      await page.getByRole('button', { name: 'Replace', exact: true }).click();
      await gone('Replace the unsent order?');
      await B.see(page, `Product ID: ${VINEGAR.id}`, { timeout: 30000 });
      assert.equal(await B.semantic(page, `Product ID: ${OAT.id}`).count(), 0, 'the old cart item is gone');
      const replaced = await waitForDraft((d) => d.items.length === 1 && d.items[0].productId === VINEGAR.id, 'replaced cart');
      assert.deepEqual(lines(replaced), [[VINEGAR.id, QTY_B]]);
      await t.shot(s, 'replaced-cart');
    });

    await t.step('a cart sent but not yet uploaded is never replaced', async () => {
      try {
        await mobile.continueToSignature(page);
        await mobile.signOrder(page, DEPARTMENT, 1);
        await page.route(WRITES, dropWrites);
        await mobile.tapSubmit(page);
        await B.see(page, /Submission is still pending/, { timeout: 40000 });
        const waiting = await draft();
        assert.match(waiting.pendingOrderId, /^ORD-P1-[0-9a-f]{32}$/);
        await t.shot(s, 'sent-waiting');
        await reload();
        await openPastOrder(PAST_A);
        await tapReuse();
        await B.see(page, 'An order for this shop is still waiting to send.', { timeout: 20000 });
        await B.see(page, "Open this shop's order to check it first.");
        assert.equal(await B.semantic(page, 'Replace the unsent order?').count(), 0, 'no replace question for a sent order');
        assert.equal(await B.semantic(page, `Product ID: ${OAT.id}`).count(), 0, 'the cart did not open');
        await page.getByRole('button', { name: 'Reuse order', exact: true }).waitFor({ timeout: 10000 });
        const after = await draft();
        assert.equal(after.pendingOrderId, waiting.pendingOrderId, 'the waiting order keeps its id');
        assert.deepEqual(lines(after), [[VINEGAR.id, QTY_B]]);
        await t.shot(s, 'sent-waiting-refused');
      } finally {
        await page.unroute(WRITES, dropWrites);
      }
    });
  },
};
