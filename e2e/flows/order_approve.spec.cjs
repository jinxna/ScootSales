'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[1];
const ORDERED = [PRODUCTS[0], PRODUCTS[2]];
const DEPARTMENT = 'GROCERY';
const ALTERED_ORDER_ID = 'ORD-E2E-PRICE-MISMATCH';
const DAY_MS = 24 * 60 * 60 * 1000;

module.exports = {
  name: 'order_approve',
  platformScheduler: true,
  async run(t) {
    const { db, accounts, seed } = t;
    let adminS;
    let mobileS;
    let orderId;
    let submitted;

    await t.step('admin logs in on the dashboard', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await B.see(adminS.page, /Admin · B1/);
      await t.shot(adminS, 'shell');
    });

    await t.step('salesperson logs in on the mobile app', async () => {
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(mobileS.page, mobileS.url, accounts.salesman.email);
      await mobile.waitForHome(mobileS.page);
      await B.see(mobileS.page, /Good (morning|afternoon|evening|night), E2E/);
      await t.shot(mobileS, 'home');
    });

    await t.step('salesperson picks the retailer by planning a visit', async () => {
      await mobile.planVisitToday(mobileS.page, RETAILER.name);
      const visit = await db.waitForQuery('visits', (v) => v.marketplace === RETAILER.name, { label: 'visits' });
      expectEqual(visit.ownerUid, seed.uids.salesman, 'visit owner');
      await B.see(mobileS.page, new RegExp(`Personal plan[^]*${RETAILER.name}`));
    });

    await t.step('salesperson adds products to the cart', async () => {
      await mobile.openPlannedVisit(mobileS.page, RETAILER.name);
      await mobile.selectProducts(mobileS.page, DEPARTMENT, ORDERED.map((p) => p.name));
      await B.see(mobileS.page, ORDERED[0].name);
      await B.see(mobileS.page, ORDERED[1].name);
      await t.shot(mobileS, 'count');
    });

    await t.step('salesperson signs and submits the order', async () => {
      await mobile.continueToSignature(mobileS.page);
      orderId = await mobile.signAndSubmit(mobileS.page, DEPARTMENT, ORDERED.length);
      await t.shot(mobileS, 'submitted');
    });

    await t.step('order is stored in Firestore as submitted', async () => {
      const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
      expectEqual(order.retailerId, RETAILER.id, 'retailerId');
      expectEqual(order.salesmanUid, seed.uids.salesman, 'salesmanUid');
      expectEqual(order.branchId, 'B1', 'branchId');
      expectEqual(order.salesmanCode, accounts.salesman.code, 'salesmanCode');
      expectEqual(order.items.map((i) => i.productId).sort().join(), ORDERED.map((p) => p.id).sort().join(), 'item products');
      expectEqual(order.totalBoxes, ORDERED.length, 'totalBoxes');
      expectEqual(Math.round(order.totalPrice * 100), Math.round(ORDERED.reduce((s, p) => s + p.price, 0) * 100), 'totalPrice');
      if (!order.signatureTimestamps[DEPARTMENT]) throw new Error('order has no department signature');
      submitted = order;
    });

    await t.step('the scheduler checks the submitted order against the price list without any CLI call', async () => {
      const order = await db.waitForDoc('orders', orderId, (o) => o.serverPriceCheck, { timeout: 60000, label: 'serverPriceCheck stamp' });
      const check = order.serverPriceCheck;
      expectEqual(check.status, 'ok', 'serverPriceCheck.status');
      expectEqual(check.reason, null, 'serverPriceCheck.reason');
      expectEqual(check.version, 1, 'serverPriceCheck.version');
      expectEqual(check.checkedAt instanceof Date, true, 'serverPriceCheck.checkedAt is a timestamp');
      expectEqual(check.expectedTotalSen, Math.round(ORDERED.reduce((sum, p) => sum + p.price, 0) * 100), 'expectedTotalSen');
      expectEqual(check.submittedTotalSen, check.expectedTotalSen, 'submittedTotalSen');
      expectEqual(check.lines.length, 0, 'mismatched lines');
    });

    await t.step('admin sees the new-order alert', async () => {
      await B.see(adminS.page, `Order submitted by ${accounts.salesman.name} for ${RETAILER.name}.`, { timeout: 30000 });
      await t.shot(adminS, 'alert');
    });

    await t.step('admin opens the order on All Orders', async () => {
      await admin.goToPage(adminS.page, 'All Orders');
      const kit = [/^Status: /, /^Salesman: /, /^Retailer: /, /^Date: /, /^Export CSV$/];
      const boxOf = (name) => adminS.page.getByRole('button', { name }).first().boundingBox();
      const boxes = await Promise.all(kit.map(boxOf));
      for (const b of boxes) {
        if (!b || Math.abs(b.height - 36) > 1) {
          throw new Error(`All Orders filter controls must all be 36px high: ${JSON.stringify(boxes)}`);
        }
      }
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').first(), orderId);
      const clear = await adminS.page.getByRole('button', { name: 'Clear search and filters' }).boundingBox();
      const statusAfter = await boxOf(kit[0]);
      if (Math.abs(clear.height - 36) > 1) throw new Error(`Clear button must be 36px high, got ${clear.height}`);
      if (Math.abs(statusAfter.y - boxes[0].y) > 0.5) {
        throw new Error(`filter row moved ${statusAfter.y - boxes[0].y}px when Clear appeared`);
      }
      await t.shot(adminS, 'orders-filter-active-clear-visible');
      await B.see(adminS.page, 'Price checked', { timeout: 30000 });
      await t.shot(adminS, 'orders-price-checked');
      await admin.openOrder(adminS.page, orderId);
      await B.see(adminS.page, 'REGULAR ROLLED OAT (24P X 450G)');
      expectEqual(await adminS.page.getByRole('button', { name: 'Approve', exact: true }).isEnabled(), true, 'Approve enabled after a clean price check');
      expectEqual(await B.semantic(adminS.page, 'Prices differ from the price list').count(), 0, 'mismatch section on a clean order');
      await B.see(adminS.page, /^Location: /);
      expectEqual(await B.semantic(adminS.page, /GPS captured ·|not retailer-verified/).count(), 0, 'old location wording');
      await t.shot(adminS, 'order');
    });

    await t.step('admin approves the order', async () => {
      await admin.approveOpenOrder(adminS.page);
      const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'approved');
      expectEqual(order.approvedByUid, seed.uids.admin, 'approvedByUid');
      expectEqual(order.approvedByRole, 'admin', 'approvedByRole');
      const po = await db.waitForDoc('purchase_orders', orderId, (p) => p.status === 'issued');
      expectEqual(po.issuedByUid, seed.uids.admin, 'purchase order issuer');
      await admin.waitForRowStatus(adminS.page, orderId, 'approved');
      await t.shot(adminS, 'approved');
    });

    await t.step('salesperson sees the order as Approved in History', async () => {
      await mobileS.page.getByRole('button', { name: /^Home/ }).first().click();
      await mobileS.page.getByRole('button', { name: /^Orders$/ }).click();
      await B.see(mobileS.page, new RegExp(`Approved[^]*${orderId}`), { timeout: 30000 });
      await t.shot(mobileS, 'history-approved');
    });

    const altered = {};
    await t.step('an order whose stored line price was altered after submission is stamped as a price mismatch', async () => {
      const before = new Date(submitted.submittedAt.getTime() - DAY_MS);
      for (const product of PRODUCTS) {
        await db.put('products', product.id, { ...(await db.get('products', product.id)), updatedAt: before });
      }
      await db.put('retailer_score_sheet_settings', RETAILER.id, { ...(await db.get('retailer_score_sheet_settings', RETAILER.id)), updatedAt: before });
      const lines = submitted.commercialLines.map((line) => line.split('~'));
      const [productId, , quantity, unit] = lines[0];
      Object.assign(altered, { productId, quantity: Number(quantity), expectedUnitSen: Number(unit), submittedUnitSen: Number(unit) + 100 });
      lines[0][3] = String(altered.submittedUnitSen);
      const { serverPriceCheck, ...clean } = submitted;
      altered.totalPrice = Math.round(submitted.totalPrice * 100 + altered.quantity * 100) / 100;
      await db.put('orders', ALTERED_ORDER_ID, {
        ...clean,
        orderId: ALTERED_ORDER_ID,
        status: 'submitted',
        totalPrice: altered.totalPrice,
        commercialLines: lines.map((parts) => parts.join('~')),
        items: submitted.items.map((item) => (item.productId === productId ? { ...item, price: altered.submittedUnitSen / 100 } : item)),
      });
      const order = await db.waitForDoc('orders', ALTERED_ORDER_ID, (o) => o.serverPriceCheck, { timeout: 60000, label: 'serverPriceCheck stamp on the altered order' });
      const check = order.serverPriceCheck;
      expectEqual(check.status, 'mismatch', 'serverPriceCheck.status');
      expectEqual(check.reason, 'price_differs', 'serverPriceCheck.reason');
      expectEqual(check.lines.length, 1, 'mismatched lines');
      for (const field of ['productId', 'quantity', 'submittedUnitSen', 'expectedUnitSen']) {
        expectEqual(check.lines[0][field], field === 'productId' ? productId : altered[field], `mismatched line ${field}`);
      }
      expectEqual(check.submittedTotalSen, Math.round(altered.totalPrice * 100), 'submittedTotalSen');
      expectEqual(check.expectedTotalSen, check.submittedTotalSen - 100 * altered.quantity, 'expectedTotalSen');
      altered.check = check;
      expectEqual(order.status, 'submitted', 'the check does not change the order status');
    });

    await t.step('the dashboard shows Price mismatch and the differing line as information; Approve stays open', async () => {
      await admin.goToPage(adminS.page, 'All Orders');
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').first(), ALTERED_ORDER_ID);
      await admin.waitForOrderRow(adminS.page, ALTERED_ORDER_ID);
      await B.see(adminS.page, 'Price mismatch', { timeout: 30000 });
      await t.shot(adminS, 'orders-price-mismatch');
      await admin.openOrder(adminS.page, ALTERED_ORDER_ID);
      await B.see(adminS.page, 'Prices differ from the price list');
      const rm = (sen) => `RM ${(sen / 100).toFixed(2)}`;
      const name = PRODUCTS.find((p) => p.id === altered.productId).name.replace(/[()]/g, '\\$&');
      await B.see(adminS.page, new RegExp(`${name} \u00b7 quantity ${altered.quantity} \u00b7 submitted ${rm(altered.submittedUnitSen)} each \u00b7 expected ${rm(altered.expectedUnitSen)} each`));
      await B.see(adminS.page, new RegExp(`Submitted total ${rm(altered.check.submittedTotalSen)} \u00b7 Expected total ${rm(altered.check.expectedTotalSen)}`));
      expectEqual(await B.semantic(adminS.page, 'Price mismatch: check the prices before approving.').count(), 0, 'old approval block message');
      expectEqual(await adminS.page.getByRole('button', { name: 'Approve', exact: true }).isEnabled(), true, 'Approve enabled on a price mismatch');
      expectEqual(await adminS.page.getByRole('button', { name: 'Reject', exact: true }).isEnabled(), true, 'Reject enabled on a price mismatch');
      expectEqual((await db.get('orders', ALTERED_ORDER_ID)).status, 'submitted', 'order status before a decision');
      await t.shot(adminS, 'order-price-mismatch');
    });

    await t.step('admin can still reject the mismatched order', async () => {
      await adminS.page.getByRole('button', { name: 'Reject', exact: true }).click();
      await B.fillField(adminS.page, adminS.page.getByRole('textbox', { name: /Rejection remark/ }), 'Prices differ from the price list');
      await adminS.page.getByRole('button', { name: 'Reject', exact: true }).last().click();
      const order = await db.waitForDoc('orders', ALTERED_ORDER_ID, (o) => o.status === 'rejected');
      expectEqual(order.rejectedByUid, seed.uids.admin, 'rejectedByUid');
      expectEqual(order.rejectionRemark, 'Prices differ from the price list', 'rejectionRemark');
      expectEqual(order.serverPriceCheck.status, 'mismatch', 'the stamp survives the decision');
      await t.shot(adminS, 'price-mismatch-rejected');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
