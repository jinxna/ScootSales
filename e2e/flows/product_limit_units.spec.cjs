'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[1];
const PRODUCT = {
  department: 'E2E TOOLS', category: 'E2E TOOL SETS', name: 'SOCKET WRENCH', brand: 'TENTEN',
  code: 'R901-SET-001', price: '20.00', uom: 'set', maxQty: 12,
};

module.exports = {
  name: 'product_limit_units',
  platformScheduler: true,
  async run(t) {
    const { db, accounts, seed } = t;
    let adminS;
    let mobileS;
    let productId;
    let orderId;

    await t.step('retailer score sheet allows the whole catalogue', async () => {
      const sheet = await db.get('retailer_score_sheet_settings', RETAILER.id);
      await db.put('retailer_score_sheet_settings', RETAILER.id, { ...sheet, visibleProductIds: [], visibleProductCount: 0 });
    });

    await t.step('admin creates a product with UOM set and Max order qty 12', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Products');
      const page = adminS.page;
      await page.getByRole('button', { name: 'Add product' }).click();
      const box = (label) => page.getByRole('textbox', { name: new RegExp(`^${label}\\b`) }).first();
      const fill = async (label, value) => {
        await B.scrollIntoView(page, box(label), { minHeight: 30, bottomInset: 0 });
        await B.fillField(page, box(label), value);
      };
      await fill('Department', PRODUCT.department);
      await fill('Main Category', PRODUCT.category);
      await fill('Product', PRODUCT.name);
      await fill('Brand', PRODUCT.brand);
      await fill('Product Code', PRODUCT.code);
      await fill('Unit Price', PRODUCT.price);
      await fill('UOM', PRODUCT.uom);
      await fill('Max order qty', String(PRODUCT.maxQty));
      await page.getByRole('button', { name: 'Save', exact: true }).click();
      await B.see(page, 'Product item saved.');
      const product = await db.waitForQuery('products', (p) => p.productCode === PRODUCT.code, { label: 'new product' });
      productId = product.id;
      expectEqual(product.uom, PRODUCT.uom, 'uom');
      expectEqual(product.maxOrderQty, PRODUCT.maxQty, 'maxOrderQty');
    });

    await t.step('salesperson adds the product to the cart', async () => {
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(mobileS.page, mobileS.url, accounts.salesman.email);
      await mobile.waitForHome(mobileS.page);
      await mobile.planVisitToday(mobileS.page, RETAILER.name);
      await mobile.openPlannedVisit(mobileS.page, RETAILER.name);
      const page = mobileS.page;
      await page.locator(`[aria-label="${PRODUCT.category}"]`).first().click();
      await page.getByRole('checkbox', { name: new RegExp(`^(?:[^\\n·]+ · )?${PRODUCT.name}`) }).click();
      await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).click();
      await page.getByRole('button', { name: 'Start counting' }).click();
      await B.see(page, PRODUCT.name);
      await B.see(page, 'Batch Qty (Sets)');
      await mobile.continueToSignature(page);
      await B.see(page, 'Total (1 product, 1 set)');
    });

    await t.step('12 sets are accepted and a 13th is refused with the limit', async () => {
      const page = mobileS.page;
      const qty = page.getByRole('textbox', { name: 'Order quantity' });
      const limitOk = page.getByRole('button', { name: 'OK', exact: true });
      const typeQty = async (text, done) => {
        for (let attempt = 0; attempt < 5; attempt += 1) {
          if (attempt > 0) await limitOk.click({ timeout: 2000 }).catch(() => {});
          await B.focusedValue(qty);
          await page.keyboard.press('Control+A');
          await page.keyboard.type(text, { delay: 30 });
          if (await B.see(page, done, { timeout: 3000 }).then(() => true, () => false)) return;
        }
        await B.see(page, done);
      };
      await typeQty('12', 'Total (1 product, 12 sets)');
      await B.see(page, '12 sets');
      await page.getByRole('button', { name: 'Increase order quantity' }).click();
      await B.see(page, 'The maximum order quantity is 12.');
      await page.getByRole('button', { name: 'OK', exact: true }).click();
      await typeQty('13', 'Maximum order quantity is 12.');
      await t.shot(mobileS, 'limit-12-sets');
      await page.getByRole('button', { name: 'OK', exact: true }).click();
      await B.see(page, 'Total (1 product, 12 sets)');
    });

    await t.step('the submitted order keeps qty 12 and uom set', async () => {
      orderId = await mobile.signAndSubmit(mobileS.page, PRODUCT.department, 1);
      const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
      expectEqual(order.salesmanUid, seed.uids.salesman, 'salesmanUid');
      expectEqual(order.items.length, 1, 'item count');
      expectEqual(order.items[0].productId, productId, 'item productId');
      expectEqual(order.items[0].qty, PRODUCT.maxQty, 'item qty');
      expectEqual(order.items[0].uom, PRODUCT.uom, 'item uom');
    });

    await t.step('admin sees 12 sets in the order details and approves', async () => {
      await admin.goToPage(adminS.page, 'All Orders');
      await admin.openOrder(adminS.page, orderId);
      await B.see(adminS.page, '12 sets');
      await t.shot(adminS, 'order-12-sets');
      await admin.approveOpenOrder(adminS.page);
      await db.waitForDoc('orders', orderId, (o) => o.status === 'approved');
      await admin.waitForRowStatus(adminS.page, orderId, 'approved');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
