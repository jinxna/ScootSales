'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');
const { klMidnightUtc } = require('../lib/onboarding_ui.cjs');

const PLAN_ID = 'PLAN-SKIP-E2E';
const STOP_ID = 'stop-skip-1';

module.exports = {
  name: 'visit_logs_skipped',
  async run(t) {
    const { db, accounts, seed } = t;
    const retailer = RETAILERS[0];

    await t.step('seed a stop that was skipped after arrival', async () => {
      const uid = seed.uids.salesman;
      const now = Date.now();
      const arrived = new Date(Math.max(now - 10 * 60 * 1000, Date.parse(klMidnightUtc())));
      const skipped = new Date(arrived.getTime() + (now - arrived.getTime()) / 2);
      await db.put('route_stop_progress', `${PLAN_ID}_${uid}_${STOP_ID}`, {
        planId: PLAN_ID, stopId: STOP_ID, salesmanUid: uid, salesmanCode: accounts.salesman.code, branchId: 'B1',
        retailerId: retailer.id, retailerName: retailer.name, lifecycleSchemaVersion: 2, status: 'skipped',
        arrivedAt: arrived, skippedAt: skipped, deviceOccurredAt: skipped, skipReason: 'Shop closed',
        updatedAt: skipped,
      });
    });

    await t.step('Visit Logs shows the stop as skipped', async () => {
      const s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Visit Logs');
      await B.see(s.page, retailer.name);
      await B.see(s.page, /\bskipped\b/);
      await t.shot(s, 'visit-logs-skipped');
    });
  },
};
