'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

module.exports = {
  name: 'supervisor_order_scope',
  async run(t) {
    const { db, accounts, seed } = t;
    const sales = accounts.salesman;
    let s;

    const KL = 8 * 3600 * 1000;
    const klNow = new Date(Date.now() + KL);
    const klWeekday = (klNow.getUTCDay() + 6) % 7;
    const monday = klWeekday === 0 ? null
      : new Date(Date.UTC(klNow.getUTCFullYear(), klNow.getUTCMonth(), klNow.getUTCDate() - klWeekday, 0, 30) - KL);

    const order = (id, retailer, salesmanId, at = new Date()) => db.put('orders', id, {
      orderId: id, uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
      salesmanEmail: sales.email, salesmanName: sales.name,
      salesmanId, salesmanCode: sales.code, salesman_code: sales.code,
      submittedByUid: seed.uids.salesman, createdByUid: seed.uids.salesman, branchId: sales.branch,
      retailerId: retailer.id, retailerName: retailer.name, status: 'submitted',
      items: [{ productId: PRODUCTS[0].id, name: PRODUCTS[0].name, productName: PRODUCTS[0].name, quantity: 1, price: PRODUCTS[0].price }],
      totalProducts: 1, totalBoxes: 1, totalPrice: PRODUCTS[0].price,
      submittedAt: at, createdAt: at,
    });

    await t.step('seed two of S001\'s orders: salesmanId = code, and salesmanId = staff ID', async () => {
      await order('ORD-E2E-SCOPE-CODE', RETAILERS[0], sales.code);
      await order('ORD-E2E-SCOPE-STAFF', RETAILERS[1], 'EMP-0001');
      if (monday) {
        await order('ORD-E2E-SCOPE-CODE-MON', RETAILERS[0], sales.code, monday);
        await order('ORD-E2E-SCOPE-STAFF-MON', RETAILERS[1], 'EMP-0001', monday);
      }
    });

    await t.step('the supervisor overview lists both orders under Today\'s Orders', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
      await B.see(s.page, /Orders today: 2\./);
      await B.see(s.page, RETAILERS[0].name);
      await t.shot(s, 'supervisor_overview');
      await B.see(s.page, RETAILERS[1].name, { timeout: 5000 });
    });

    await t.step('Orders this week counts all orders from this week', async () => {
      const expected = 2 + (monday ? 2 : 0);
      await B.semantic(s.page, /^This week$/).click();
      await B.see(s.page, new RegExp('Orders this week[^:]*: ' + expected + '[.]'));
    });
  },
};
