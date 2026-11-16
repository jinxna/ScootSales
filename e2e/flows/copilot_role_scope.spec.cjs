'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson } = require('../lib/seed.cjs');

module.exports = {
  name: 'copilot_role_scope',
  async run(t) {
    const { db, accounts, seed } = t;
    const outside = { email: 'e2e.outside@example.test', name: 'Outside Person', role: 'salesman', code: 'S909', branch: 'B-OTHER' };
    const order = (id, branchId, uid, name, code) => db.put('orders', id, {
      orderId: id, uid, userUid: uid, salesmanUid: uid, salesmanId: code, salesmanCode: code, salesmanName: name,
      submittedByUid: uid, createdByUid: uid, branchId, supervisorId: '', retailerId: 'ret-scope', retailerName: 'Scope Shop',
      status: 'submitted', items: [], totalPrice: 10, submittedAt: new Date(), createdAt: new Date(),
    });
    let s;
    const page = () => s.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const ask = async (text, re) => {
      const before = await find(re).count();
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
      const end = Date.now() + 30000;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) return;
        await page().waitForTimeout(150);
      }
      throw new Error(`after "${text}" expected ${re}`);
    };

    await t.step('seed an outside salesperson with an order', async () => {
      const uid = await putPerson(db, outside);
      await order('ORD-E2E-SCOPE-OUT', 'B-OTHER', uid, outside.name, outside.code);
      await order('ORD-E2E-SCOPE-IN', accounts.salesman.branch, seed.uids.salesman, accounts.salesman.name, accounts.salesman.code);
    });
    await t.step('supervisor sees only the assigned salesperson', async () => {
      s = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(page(), s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(page());
      await page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await ask('orders this month', /\b1 order/);
      await ask(`orders from ${outside.name}`, new RegExp(`find "${outside.name}" among the records your role can see`));
      await ask('orders from Nobody Atall', /find "Nobody Atall" among the records your role can see/);
    });
    await t.step('branch manager: route requests are view only', async () => {
      s = await t.session('admin', { name: 'branch-manager' });
      await B.loginAdmin(page(), s.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(page());
      await page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await ask('create a route for next week', /Route Planner is view only for your role/);
    });
  },
};
