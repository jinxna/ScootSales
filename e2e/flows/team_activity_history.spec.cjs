'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson } = require('../lib/seed.cjs');

module.exports = {
  name: 'team_activity_history',
  async run(t) {
    const { db, accounts, seed } = t;
    let supS;

    await t.step('seed a lower-case profile the supervisor lists in upper case', async () => {
      const supAccess = await db.get('user_access', seed.uids.supervisor);
      const codes = [...new Set([...(supAccess.assignedSalesmanCodes || []), 'S0002'])];
      await putPerson(db, accounts.supervisor, { assignedSalesmanCodes: codes });
      await putPerson(db, { email: 'e2e.lower.s0002@example.test', name: 'E2E Lowercase Code', role: 'salesman', code: 's0002', branch: seed.branch.id }, { supervisorUid: seed.uids.supervisor, supervisorCode: accounts.supervisor.code });
      const when = new Date(Date.now() - 3 * 24 * 3600 * 1000);
      await db.put('orders', 'e2e-hist-order-1', {
        orderId: 'e2e-hist-order-1', salesmanCode: accounts.salesman.code, salesmanUid: seed.uids.salesman,
        retailerId: 'ret-1', retailerName: 'Choice Supermarket Tabuan Jaya', branchId: seed.branch.id,
        status: 'submitted', totalPrice: 100, submittedAt: when, createdAt: when,
      });
    });

    await t.step('supervisor opens Team Activity', async () => {
      supS = await t.session('admin');
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Team Activity');
      await B.see(supS.page, 'Possible case mismatch', { timeout: 30000 });
      await B.see(supS.page, 's0002 vs S0002');
      await B.see(supS.page, 'ask an admin to fix');
      await t.shot(supS, 'team-activity-case-mismatch');
    });

    await t.step('with nobody live the page states last activity instead of faking a position', async () => {
      await B.see(supS.page, /No live location today; last activity/, { timeout: 30000 });
      await t.shot(supS, 'team-activity-no-live');
    });
  },
};
