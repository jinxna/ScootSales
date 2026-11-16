'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'employee_code_history',
  async run(t) {
    const { db, accounts, seed } = t;
    const sales = accounts.salesman;
    const uid = seed.uids.salesman;
    const ORDER_ID = 'ORD-E2E-CODE-HISTORY';
    let adminS;
    let supS;

    await t.step('the salesperson has an order under the current code', async () => {
      const retailer = RETAILERS[0];
      const product = PRODUCTS[0];
      await db.put('orders', ORDER_ID, {
        orderId: ORDER_ID, uid, userUid: uid, salesmanUid: uid, salesmanEmail: sales.email, salesmanName: sales.name,
        salesmanCode: sales.code, staffId: sales.code, branchId: sales.branch, retailerId: retailer.id, retailerName: retailer.name,
        status: 'submitted', items: [{ productId: product.id, name: product.name, productName: product.name, quantity: 1, price: product.price }],
        totalProducts: 1, totalBoxes: 1, totalPrice: product.price, submittedAt: new Date(), createdAt: new Date(),
      });
    });

    await t.step('the admin tries to change the code and gets a plain refusal', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, sales.code);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      const boxes = adminS.page.getByRole('textbox');
      await B.fillField(adminS.page, boxes.nth(0), 'S999');
      await adminS.page.getByRole('button', { name: /^(Update Profile|Save changes|Update User)$/ }).click();
      await B.see(adminS.page, /cannot change\. This person's orders, visits and routes/, { timeout: 30000 });
      await B.shotAtWidths(t, adminS, 'code-change-refused');
      expectEqual((await db.get('user_access', uid)).employeeCode, sales.code, 'employee code after the refused change');
    });

    await t.step('the supervisor still sees the order', async () => {
      supS = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Team Orders');
      await admin.waitForOrderRow(supS.page, ORDER_ID);
    });
  },
};
