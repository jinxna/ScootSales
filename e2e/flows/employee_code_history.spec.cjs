'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS, BRANCH, putPerson } = require('../lib/seed.cjs');

const CASE_SUPERVISOR = { email: 'e2e.case.sup@example.test', name: 'E2E Case Supervisor', role: 'supervisor', code: 'SUP-CASE', branch: BRANCH.id };
const CASE_SALES = { email: 'e2e.case.sales@example.test', name: 'E2E Case Salesperson', role: 'salesman', code: 's0002', branch: BRANCH.id };
const CASE_ORDER_ID = 'ORD-E2E-CODE-CASE';
const CASE_SHOP_ID = 'R-E2E-CODE-CASE';

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

    await t.step('a supervisor change keeps a lower-case code exactly as stored on the person and every roster', async () => {
      const oldSupervisorUid = seed.uids.supervisor;
      const newSupervisorUid = await putPerson(db, CASE_SUPERVISOR);
      const caseUid = await putPerson(db, CASE_SALES, { supervisorUid: oldSupervisorUid, supervisorCode: accounts.supervisor.code });
      const roster = [sales.code, CASE_SALES.code];
      await db.put('user_access', oldSupervisorUid, { ...(await db.get('user_access', oldSupervisorUid)), assignedSalesmanCodes: roster });
      await db.put('users', accounts.supervisor.email, { ...(await db.get('users', accounts.supervisor.email)), assignedSalesmanCodes: roster });
      const retailer = RETAILERS[0];
      const product = PRODUCTS[0];
      await db.put('orders', CASE_ORDER_ID, {
        orderId: CASE_ORDER_ID, uid: caseUid, userUid: caseUid, salesmanUid: caseUid, salesmanEmail: CASE_SALES.email,
        salesmanName: CASE_SALES.name, salesmanCode: CASE_SALES.code, staffId: CASE_SALES.code, branchId: CASE_SALES.branch,
        retailerId: retailer.id, retailerName: retailer.name, status: 'submitted',
        items: [{ productId: product.id, name: product.name, productName: product.name, quantity: 1, price: product.price }],
        totalProducts: 1, totalBoxes: 1, totalPrice: product.price, submittedAt: new Date(), createdAt: new Date(),
      });
      await db.put('retailers', CASE_SHOP_ID, {
        retailerId: CASE_SHOP_ID, retailerName: 'E2E Case Shop', name: 'E2E Case Shop', area: 'Kuching',
        branchId: CASE_SALES.branch, assignedSalesmanId: CASE_SALES.code, status: 'active',
      });

      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, CASE_SALES.code);
      await B.see(adminS.page, CASE_SALES.name);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await admin.scrollFormTop(adminS.page);
      expectEqual(await B.focusedValue(adminS.page.getByRole('textbox').nth(0)), CASE_SALES.code, 'code field after Edit');
      const current = adminS.page.getByRole('button', { name: new RegExp(`^${accounts.supervisor.name} \\(`) }).first();
      await B.scrollIntoView(adminS.page, current, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await current.click();
      await adminS.page.getByRole('menuitem', { name: new RegExp(`^${CASE_SUPERVISOR.name} \\(`) }).first().click();
      await B.see(adminS.page, new RegExp(`^${CASE_SUPERVISOR.name} \\(`));
      await t.shot(adminS, 'case-supervisor-picked');
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, `Saved changes to ${CASE_SALES.name}.`, { timeout: 30000 });
      await t.shot(adminS, 'case-supervisor-saved');

      const access = await db.waitForDoc('user_access', caseUid, (a) => a.supervisorUid === newSupervisorUid, { timeout: 30000, label: 'case salesperson moved' });
      expectEqual(access.employeeCode, CASE_SALES.code, 'user_access employeeCode after the supervisor change');
      expectEqual(access.userId, CASE_SALES.code, 'user_access userId after the supervisor change');
      const profile = await db.get('users', CASE_SALES.email);
      expectEqual(profile.employeeCode, CASE_SALES.code, 'users employeeCode after the supervisor change');
      expectEqual(profile.supervisorId, CASE_SUPERVISOR.code, 'users supervisorId after the supervisor change');
      expectEqual((await db.get('orders', CASE_ORDER_ID)).salesmanCode, access.employeeCode, 'order code matches the stored code');
      expectEqual((await db.get('retailers', CASE_SHOP_ID)).assignedSalesmanId, access.employeeCode, 'shop code matches the stored code');
      expectEqual((await db.get('user_access', oldSupervisorUid)).assignedSalesmanCodes, [sales.code], 'old supervisor access roster');
      expectEqual((await db.get('users', accounts.supervisor.email)).assignedSalesmanCodes, [sales.code], 'old supervisor profile roster');
      expectEqual((await db.get('user_access', newSupervisorUid)).assignedSalesmanCodes, [CASE_SALES.code], 'new supervisor access roster');
      expectEqual((await db.get('users', CASE_SUPERVISOR.email)).assignedSalesmanCodes, [CASE_SALES.code], 'new supervisor profile roster');
      const spellings = [];
      for (const collection of ['users', 'user_access']) {
        for (const doc of await db.list(collection)) {
          for (const code of doc.assignedSalesmanCodes || []) {
            if (String(code).toUpperCase() === CASE_SALES.code.toUpperCase()) spellings.push(`${collection}/${doc.id}:${code}`);
          }
        }
      }
      expectEqual(spellings.sort(), [`user_access/${newSupervisorUid}:${CASE_SALES.code}`, `users/${CASE_SUPERVISOR.email}:${CASE_SALES.code}`].sort(), 'every roster entry for the code');
      await B.see(adminS.page, new RegExp(`example\\.test\\s+\\S\\s+${CASE_SALES.code}(?![0-9A-Za-z])`));
      await B.see(adminS.page, `Supervisor: ${CASE_SUPERVISOR.code}`);
      await t.shot(adminS, 'case-directory-row');
    });
  },
};
