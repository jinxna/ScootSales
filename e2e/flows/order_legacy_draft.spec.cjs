'use strict';
const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

module.exports = {
  name: 'order_legacy_draft',
  async run(t) {
    const original = await t.db.get('products', PRODUCTS[0].id);
    await t.db.put('products', 'duplicate-legacy-name', { ...original, productId: 'duplicate-legacy-name', unitPrice: 99 });
    for (const [index, ambiguous] of [false, true].entries()) {
      for (const visit of await t.db.list('visits')) await t.db.del('visits', visit.id);
      const retailer = RETAILERS[index];
      const product = ambiguous ? PRODUCTS[0] : PRODUCTS[2];
      const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: ambiguous ? 'ambiguous-draft' : 'unique-draft' });
      await t.step(`open ${ambiguous ? 'ambiguous' : 'unique'} names-only saved draft`, async () => {
        await B.loginMobile(s.page, s.url, t.accounts.salesman.email);
        await mobile.waitForHome(s.page);
        await mobile.planVisitToday(s.page, retailer.name);
        const visit = await t.db.waitForQuery('visits', (v) => v.marketplace === retailer.name);
        await t.db.put('visits', visit.id, {
          ...visit, progress: 2, draftStage: 2, status: 'counting',
          cartDraftItems: [{ name: product.name, price: product.price, department: 'GROCERY', qty: 1, stock: 0, shelfBatches: [] }],
        });
        await B.openApp(s.page, s.url);
        await mobile.waitForHome(s.page);
        await B.see(s.page, new RegExp(`Personal plan[^]*${retailer.name}[^]*Counting Items`), { timeout: 30000 });
        await mobile.openPlannedVisit(s.page, retailer.name);
        if (ambiguous) {
          await B.see(s.page, /Legacy draft: ambiguous product/);
          assert.equal(await s.page.getByRole('button', { name: 'Continue to Signature' }).isEnabled(), false);
        } else {
          await B.see(s.page, /Legacy draft:.*matched by name/);
          await mobile.continueToSignature(s.page);
          const id = await mobile.signAndSubmit(s.page, 'GROCERY', 1);
          const order = await t.db.waitForDoc('orders', id, (o) => o.status === 'submitted');
          assert.equal(order.items[0].productId, product.id);
          assert.equal(order.items[0].price, product.price);
        }
        await t.shot(s, ambiguous ? 'ambiguity-blocked' : 'legacy-name-resolved');
      });
    }
  },
};
