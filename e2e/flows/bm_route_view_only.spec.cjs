'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

const ROUTE_WRITE_CONTROLS = /^(Publish|Approve|Create route|New route|Save draft)/i;

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'bm_route_view_only',
  async run(t) {
    const { accounts } = t;
    let bmS;

    await t.step('branch manager logs in on the dashboard and lands on the branch shell', async () => {
      bmS = await t.session('admin');
      await B.loginAdmin(bmS.page, bmS.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(bmS.page);
      await t.shot(bmS, 'bm-home');
    });

    await t.step('the route item is labelled view only', async () => {
      await admin.goToPage(bmS.page, 'Branch Routes (view only)');
      await B.see(bmS.page, 'View only');
      await t.shot(bmS, 'bm-routes');
    });

    await t.step('no route write control is enabled for the branch manager', async () => {
      const controls = bmS.page.getByRole('button', { name: ROUTE_WRITE_CONTROLS });
      const count = await controls.count();
      for (let i = 0; i < count; i += 1) {
        const control = controls.nth(i);
        if (!(await control.isVisible())) continue;
        expectEqual(await control.isDisabled(), true, `route write control ${i} enabled`);
      }
      await t.shot(bmS, 'bm-routes-controls');
    });
  },
};
