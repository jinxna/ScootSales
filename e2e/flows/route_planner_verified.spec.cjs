'use strict';

const B = require('../lib/browser.cjs');
const { ACCOUNTS } = require('../lib/seed.cjs');

const OWNER = { branchId: 'B1', status: 'active', assignedSalesmanCode: ACCOUNTS.salesman.code, assignedSalesmanId: ACCOUNTS.salesman.code };

module.exports = {
  name: 'route_planner_verified',
  async run(t) {
    const { db, accounts } = t;
    let s;

    await t.step('seed verified retailers with varied field spellings', async () => {
      await db.put('retailers', 'ret-v1', { ...OWNER, retailerId: 'ret-v1', retailerName: 'Verified Upper', name: 'Verified Upper', latitude: 1.54, longitude: 110.35, coordinateStatus: 'VERIFIED' });
      await db.put('retailers', 'ret-v2', { ...OWNER, retailerId: 'ret-v2', retailerName: 'Verified Padded', name: 'Verified Padded', lat: '1.55', lng: '110.36', coordinateStatus: ' Verified ' });
      await db.put('retailers', 'ret-v3', { ...OWNER, retailerId: 'ret-v3', retailerName: 'Verified Nested', name: 'Verified Nested', coordinates: { lat: 1.56, lng: 110.37 }, coordinateStatus: 'verified' });
    });

    await t.step('admin opens the planner', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await s.page.getByRole('button', { name: 'Route Planner', exact: true }).first().click();
      await B.see(s.page, 'No plan generated yet');
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'planner');
    });

    await t.step('no coordinate warning is shown for verified retailers', async () => {
      const text = await s.page.evaluate(() => document.body.innerText + [...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || '').join('\n'));
      expectEqual(/missing usable coordinates/.test(text), false, 'missing-coordinates warning');
      expectEqual(/unverified\s+coordinates/.test(text), false, 'unverified-coordinates warning');
    });

    await t.step('a candidate retailer still warns', async () => {
      await db.put('retailers', 'ret-c1', { ...OWNER, retailerId: 'ret-c1', retailerName: 'Candidate One', name: 'Candidate One', latitude: 1.57, longitude: 110.38, coordinateStatus: 'candidate' });
      await B.see(s.page, /unverified\s+coordinates/);
    });

    await t.step('verifying it clears the warning without reloading', async () => {
      await db.put('retailers', 'ret-c1', { ...OWNER, retailerId: 'ret-c1', retailerName: 'Candidate One', name: 'Candidate One', latitude: 1.57, longitude: 110.38, coordinateStatus: 'verified' });
      await s.page.getByText(/unverified\s+coordinates/).first().waitFor({ state: 'detached', timeout: 15000 });
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
