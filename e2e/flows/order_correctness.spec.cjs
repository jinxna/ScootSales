'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const B = require('../lib/browser.cjs');
const { PROJECT } = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

module.exports = {
  name: 'order_correctness',
  async run(t) {
    const retailer = RETAILERS[1];
    const variants = [
      { id: 'same-name-a', pack: 'SMALL PACK', price: 12.5, barcode: '012345678905', qty: 1 },
      { id: 'same-name-b', pack: 'LARGE PACK', price: 37.25, barcode: '036000291452', qty: 2 },
    ];
    let s;
    await t.step('seed same-name products and an archived product', async () => {
      const availability = (app) => fs.readFileSync(`${app}/lib/utils/catalogue_product_availability.dart`, 'utf8').replace(/\r\n/g, '\n');
      assert.equal(availability('flutter_mobile_app'), availability('admin_dashboard'), 'both apps keep identical availability rules');
      const template = await t.db.get('products', PRODUCTS[0].id);
      for (const p of variants) await t.db.put('products', p.id, {
        ...template, productId: p.id, productCode: p.id, itemCode: p.id,
        itemName: 'IDENTICAL NAME', productName: 'IDENTICAL NAME',
        packingSize: p.pack, itemBarcode: p.barcode, barcode: p.barcode,
        unitPrice: p.price, status: 'active',
      });
      await t.db.put('products', 'archived-product', {
        ...template, productId: 'archived-product', itemName: 'ARCHIVED SAMPLE',
        productName: 'ARCHIVED SAMPLE', status: 'archived', isVisible: true,
      });
      const sheet = await t.db.get('retailer_score_sheet_settings', retailer.id);
      await t.db.put('retailer_score_sheet_settings', retailer.id, { ...sheet, visibleProductIds: [] });
    });
    await t.step('select both same-name products independently', async () => {
      s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await mobile.installFakeScanner(s);
      await B.loginMobile(s.page, s.url, t.accounts.salesman.email);
      await mobile.waitForHome(s.page);
      await mobile.planVisitToday(s.page, retailer.name);
      await mobile.openPlannedVisit(s.page, retailer.name);
      await s.page.locator('[aria-label="GROCERY"]').first().click();
      assert.equal(await s.page.getByRole('checkbox', { name: /ARCHIVED SAMPLE/ }).count(), 0);
      await mobile.scanBarcode(s.page, '0012345678905');
      await s.page.getByRole('button', { name: /^Add to Cart \(1\)/ }).waitFor();
      await mobile.scanBarcode(s.page, '012345678905');
      await s.page.getByRole('button', { name: /^Add to Cart \(1\)/ }).waitFor();
      const template = await t.db.get('products', variants[0].id);
      await t.db.put('products', 'barcode-collision', { ...template, productId: 'barcode-collision', itemName: 'BARCODE COLLISION', productName: 'BARCODE COLLISION' });
      await s.page.getByRole('checkbox', { name: /BARCODE COLLISION/ }).waitFor();
      await mobile.scanBarcode(s.page, '012345678905');
      await B.see(s.page, 'Choose scanned product');
      await t.shot(s, 'duplicate-barcode-choice');
      await s.page.getByRole('button', { name: /IDENTICAL NAME.*same-name-a/ }).click();
      const p = variants[1];
      await s.page.getByRole('checkbox', { name: new RegExp(`IDENTICAL NAME[\\s\\S]*${p.barcode}`) }).click();
      await s.page.getByRole('button', { name: /^Add to Cart \(2\)/ }).click();
      await B.see(s.page, /2 products selected\. One order holds up to 5/);
      await s.page.getByRole('button', { name: 'Start counting' }).click();
      await t.shot(s, 'distinct-products-count');
    });
    await t.step('order lines retain exact identity, pack and price', async () => {
      await mobile.continueToSignature(s.page);
      const increase = s.page.getByRole('button', { name: 'Increase order quantity', exact: true }).nth(1);
      await B.scrollIntoView(s.page, increase, { minHeight: 20 });
      await increase.click();
      await s.page.getByRole('button', { name: 'Save Draft', exact: true }).click();
      const draftPrefix = `flutter.project_storage_v1.${Buffer.from(PROJECT).toString('base64url')}.${Buffer.from(t.seed.uids.salesman).toString('base64url')}.cart_draft.`;
      await s.page.waitForFunction((prefix) => Object.entries(localStorage)
        .filter(([key]) => key.startsWith(prefix))
        .map(([, value]) => {
          const encoded = JSON.parse(value);
          const envelope = typeof encoded === 'string' ? JSON.parse(encoded) : encoded;
          return JSON.parse(envelope.data);
        })
        .some((d) => d.progress === 4 && d.items.some((i) => i.productId === 'same-name-b' && i.qty === 2)), draftPrefix);
      await B.openApp(s.page, s.url);
      await mobile.waitForHome(s.page);
      await mobile.openPlannedVisit(s.page, retailer.name);
      await B.see(s.page, /Total \(2 products, 3 boxes\)/);
      await t.shot(s, 'same-name-draft-restored');
      await s.page.evaluate((prefix) => {
        const original = Storage.prototype.setItem;
        window.restoreDraftStorage = () => { Storage.prototype.setItem = original; };
        Storage.prototype.setItem = function (key, value) {
          if (key.startsWith(prefix) && /ORD-P1-[0-9a-f]{32}/.test(value)) {
            window.blockedOrderId = /ORD-P1-[0-9a-f]{32}/.exec(value)[0];
            throw new DOMException('Disposable storage failure', 'QuotaExceededError');
          }
          return original.call(this, key, value);
        };
      }, draftPrefix);
      await mobile.signAndTapSubmit(s.page, 'GROCERY', 2);
      await B.see(s.page, /Order was not queued because its retry identity could not be saved/);
      assert.equal((await t.db.list('orders')).length, 0, 'failed identity persistence must prevent queueing');
      const id = await s.page.evaluate(() => { window.restoreDraftStorage(); return window.blockedOrderId; });
      assert.match(id, /^ORD-P1-[0-9a-f]{32}$/);
      await t.shot(s, 'storage-failure-blocks-queue');
      await s.page.getByRole('button', { name: 'Check Submission', exact: true }).click();
      await B.see(s.page, `${id} has been submitted`);
      const order = await t.db.waitForDoc('orders', id, (o) => o.status === 'submitted');
      assert.equal(order.items.length, 2);
      for (const p of variants) {
        const line = order.items.find((i) => i.productId === p.id);
        assert.ok(line, `missing ${p.id}`);
        assert.equal(line.name, 'IDENTICAL NAME');
        assert.equal(line.price, p.price);
        assert.equal(line.packingSize, p.pack);
        assert.equal(line.uom, 'ctn', 'legacy catalogue default unit is snapshotted');
        assert.equal(line.qty, p.qty, 'same-name draft quantities stay attached to their product IDs');
      }
      await t.shot(s, 'distinct-products-submitted');
    });
  },
};
