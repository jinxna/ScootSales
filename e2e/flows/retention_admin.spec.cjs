'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

module.exports = {
  name: 'retention_admin',
  async run(t) {
    const { db, accounts } = t;
    let s;

    await t.step('an administrator finds Order retention and sees no developer controls', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'System Governance');
      await B.see(s.page, 'Order retention');
      await t.shot(s, 'retention-admin-before');
      if (await s.page.getByText('Run purge now…').count()) throw new Error('administrator sees Run purge now');
      if (await s.page.getByText('Danger zone').count()) throw new Error('administrator sees the danger zone');
    });

    await t.step('choosing 6 months and saving stores 6 months', async () => {
      await admin.pickDropdown(s.page, /Keep final orders for/, '6 months');
      await s.page.getByRole('button', { name: 'Save', exact: true }).click();
      await B.see(s.page, 'Order retention saved.');
      await t.shot(s, 'retention-admin-saved');
      const stored = await db.get('system_settings', 'order_purge');
      if (!stored || stored.retentionMonths !== 6) throw new Error('stored value is ' + JSON.stringify(stored));
    });
  },
};
