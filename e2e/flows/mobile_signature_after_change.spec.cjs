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
const RETAILER = RETAILERS[0];
const CHANGED = 'Changed after signing. Ask the shop to sign again.';

function signedAt(text) {
  const match = /^(\d{2})\/(\d{2})\/(\d{4})\s+(\d{2}):(\d{2}):(\d{2})$/.exec(text || '');
  if (!match) throw new Error(`signature time has an unexpected form: ${JSON.stringify(text)}`);
  const [, day, month, year, hour, minute, second] = match.map(Number);
  return new Date(year, month - 1, day, hour, minute, second).getTime();
}

async function toTop(page) {
  const size = page.viewportSize();
  await page.mouse.move(size.width / 2, size.height / 2);
  await page.mouse.wheel(0, -10000);
  await page.waitForTimeout(400);
}

module.exports = {
  name: 'mobile_signature_after_change',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, persistence: true });
    const page = s.page;
    const submit = () => page.getByRole('button', { name: 'Submit Order', exact: true });
    const draftSignature = async () => {
      const drafts = (await mobile.savedDrafts(page, PROJECT, uid)).filter((d) => d.retailerId === RETAILER.id);
      assert.equal(drafts.length, 1, 'one saved sign-off draft');
      return drafts[0].signatures[DEPARTMENT];
    };
    const expectUnsigned = async (label) => {
      await B.see(page, CHANGED);
      await B.see(page, /1 department still needs a signature/);
      assert.equal(await B.semantic(page, /Signed on /).count(), 0, `${label}: the old signature time is still shown`);
      assert.equal(await submit().isEnabled(), false, `${label}: Submit Order must wait for a new signature`);
      const saved = await draftSignature();
      assert.equal(saved.signed, false, `${label}: the saved draft still says signed`);
      assert.equal(saved.points.length, 0, `${label}: the saved draft still holds the old signature`);
    };
    const signAgain = async (label) => {
      await mobile.signOrder(page, DEPARTMENT, 0);
      assert.equal(await B.semantic(page, CHANGED).count(), 0, `${label}: the notice stays after the new signature`);
      assert.equal(await submit().isEnabled(), true, `${label}: Submit Order is ready after the new signature`);
    };
    const result = {};
    let lastChangeAt = 0;

    await t.step('salesperson signs an order with two lines in one department', async () => {
      await B.loginMobile(page, s.url, accounts.salesman.email);
      await mobile.waitForHome(page);
      for (const visit of await db.list('visits')) await db.del('visits', visit.id);
      await mobile.planVisitToday(page, RETAILER.name);
      await mobile.openPlannedVisit(page, RETAILER.name);
      await mobile.selectProducts(page, DEPARTMENT, [VINEGAR.name, OAT.name]);
      await mobile.continueToSignature(page);
      await mobile.signOrder(page, DEPARTMENT, 2);
      assert.equal(await submit().isEnabled(), true, 'a signed order can be submitted');
      assert.equal((await draftSignature()).signed, true);
      await t.shot(s, 'signed');
    });

    await t.step('pressing + after the signature clears it and blocks Submit', async () => {
      await toTop(page);
      await page.getByRole('button', { name: 'Increase order quantity' }).first().click();
      lastChangeAt = Date.now();
      await expectUnsigned('plus');
      await t.shot(s, 'changed-after-signing');
      await signAgain('plus');
    });

    await t.step('typing a quantity after the signature clears it', async () => {
      const field = page.getByRole('textbox', { name: 'Order quantity' }).nth(1);
      await toTop(page);
      await B.scrollIntoView(page, field, { minHeight: 20 });
      await B.fillField(page, field, '4');
      lastChangeAt = Date.now();
      await expectUnsigned('typed quantity');
      await signAgain('typed quantity');
    });

    await t.step('taking a line down to zero after the signature clears it', async () => {
      await toTop(page);
      const minus = page.getByRole('button', { name: 'Decrease order quantity' }).first();
      await minus.click();
      await expectUnsigned('first minus');
      await minus.click();
      lastChangeAt = Date.now();
      await B.see(page, /Total \(2 products, 4 boxes\)/);
      await expectUnsigned('line at zero');
      await page.waitForTimeout(1500);
      await signAgain('line at zero');
    });

    await t.step('the order is stored with the changed lines and the new signature time', async () => {
      await mobile.tapSubmit(page);
      const orderId = await mobile.readConfirmedOrderId(page);
      const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
      assert.deepEqual(order.items.map((i) => i.qty), [4], 'one line of four boxes is stored');
      assert.equal(order.totalBoxes, 4);
      const stored = signedAt(order.signatureTimestamps[DEPARTMENT]);
      assert.ok(stored > lastChangeAt - 1000, `signature time ${order.signatureTimestamps[DEPARTMENT]} is not later than the last change`);
      result.order = { orderId, items: order.items.map(({ productId, qty }) => ({ productId, qty })), signedAt: order.signatureTimestamps[DEPARTMENT], lastChangeAt: new Date(lastChangeAt).toISOString() };
      await t.shot(s, 'submitted');
    });

    const out = path.join(__dirname, '..', 'output', 'mobile_signature_after_change');
    fs.mkdirSync(out, { recursive: true });
    fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(result, null, 2));
  },
};
