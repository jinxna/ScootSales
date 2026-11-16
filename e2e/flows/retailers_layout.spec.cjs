'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

const VIEWPORT = { width: 1600, height: 1000 };

function expect(cond, what) {
  if (!cond) throw new Error(what);
}

module.exports = {
  name: 'retailers_layout',
  async run(t) {
    const { db, accounts, seed } = t;
    let s;

    await t.step('seed enough retailers that the list needs scrolling', async () => {
      for (let i = 0; i < 40; i += 1) {
        const id = `e2e-layout-${String(i).padStart(2, '0')}`;
        await db.put('retailers', id, {
          retailerId: id, retailerName: `E2E LAYOUT ${String(i).padStart(2, '0')}`,
          area: 'Kuching', branchId: seed.branch.id, status: 'active', address: 'Kuching',
          assignedSalesmanId: accounts.salesman.code,
        });
      }
    });

    await t.step('admin opens Retailers at 1600x1000', async () => {
      s = await t.session('admin', { viewport: VIEWPORT });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Retailers');
      await B.see(s.page, 'Salesperson');
      await t.shot(s, 'retailers-list');
    });

    const headerBox = async () => (await B.semantic(s.page, 'Salesperson').boundingBox());

    await t.step('the table fills at least 60% of the viewport height', async () => {
      const head = await headerBox();
      const rows = s.page.getByRole('button', { name: 'Memory' });
      const count = await rows.count();
      expect(count >= 8, `expected many visible rows, saw ${count}`);
      const last = await rows.nth(count - 1).boundingBox();
      const filled = last.y + last.height - head.y;
      expect(filled >= VIEWPORT.height * 0.6, `table only fills ${filled}px of ${VIEWPORT.height}px`);
    });

    await t.step('the header stays in place while the rows scroll', async () => {
      const before = await headerBox();
      await s.page.mouse.move(VIEWPORT.width / 2, before.y + 200);
      await s.page.mouse.wheel(0, 900);
      await s.page.waitForTimeout(500);
      const after = await headerBox();
      expect(Math.abs(after.y - before.y) < 2, `header moved from ${before.y} to ${after.y}`);
      await t.shot(s, 'retailers-scrolled');
    });

    await t.step('Coverage is a third segment and shows the lifecycle panel', async () => {
      await s.page.getByRole('button', { name: /^Coverage$/ }).click();
      await B.see(s.page, 'Coverage & Lifecycle');
      await s.page.getByRole('button', { name: /^List$/ }).click();
      await B.see(s.page, 'Salesperson');
    });
  },
};
