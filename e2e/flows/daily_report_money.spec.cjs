'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];
const ORDER_TOTAL = 123.45;
const ORDER_TOTAL_TEXT = 'RM 123.45';

module.exports = {
  name: 'daily_report_money',
  async run(t) {
    const { db, accounts, seed } = t;
    let supS;

    await t.step('seed an approved order for today with no visit_logs row and no visit timing', async () => {
      const now = new Date();
      await db.put('orders', 'e2e-daily-money-1', {
        orderId: 'e2e-daily-money-1', salesmanCode: accounts.salesman.code, salesmanUid: seed.uids.salesman,
        retailerId: RETAILER.id, retailerName: RETAILER.name, branchId: seed.branch.id,
        status: 'approved', totalPrice: ORDER_TOTAL, submittedAt: now, createdAt: now,
      });
      const logs = (await db.list('visit_logs')).filter((row) => row.salesmanUid === seed.uids.salesman);
      if (logs.length) throw new Error(`the salesperson already has ${logs.length} visit_logs rows`);
    });

    await t.step('supervisor opens Team Activity and the Daily Salesman Report shows the order total', async () => {
      supS = await t.session('admin');
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Team Activity');
      await B.see(supS.page, 'Daily Salesman Report', { timeout: 30000 });
      await B.see(supS.page, ORDER_TOTAL_TEXT, { timeout: 30000 });
      await t.shot(supS, 'daily-report-money');
    });

    await t.step('the fleet rail says "1 salesperson" for a single salesperson', async () => {
      await B.see(supS.page, /\b1 salesperson\b(?!s)/, { timeout: 30000 });
    });
  },
};
