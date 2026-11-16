'use strict';
const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson, PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

module.exports = {
  name: 'access_scope_refresh',
  async run(t) {
    const { db, accounts, seed } = t;
    const oldOrder = 'ORD-E2E-ACCESS-OLD';
    const newOrder = 'ORD-E2E-ACCESS-NEW';
    const replacement = {
      ...accounts.salesman, email: 'e2e.replacement@example.test',
      name: 'E2E Replacement Salesman', code: 'S902',
    };
    let s;
    let signIns = 0;
    let access;
    let profile;

    await t.step('seed an order for each of the old and replacement teams', async () => {
      const newUid = await putPerson(db, replacement, {
        supervisorUid: seed.uids.supervisor, supervisorCode: accounts.supervisor.code,
      });
      for (const [id, person, uid] of [
        [oldOrder, accounts.salesman, seed.uids.salesman],
        [newOrder, replacement, newUid],
      ]) {
        await db.put('orders', id, {
          orderId: id, uid, userUid: uid, salesmanUid: uid,
          salesmanEmail: person.email, salesmanName: person.name,
          salesmanId: person.code, salesmanCode: person.code, salesman_code: person.code,
          submittedByUid: uid, createdByUid: uid, branchId: person.branch,
          retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
          status: 'submitted', totalPrice: PRODUCTS[0].price, totalProducts: 1, totalBoxes: 1,
          items: [{ productId: PRODUCTS[0].id, name: PRODUCTS[0].name,
            quantity: 1, price: PRODUCTS[0].price }],
          submittedAt: new Date(), createdAt: new Date(),
        });
      }
      access = await db.get('user_access', seed.uids.supervisor);
      profile = await db.get('users', accounts.supervisor.email);
    });

    await t.step('supervisor sees only the original team order', async () => {
      s = await t.session('admin');
      s.page.on('request', (request) => {
        if (request.url().includes('accounts:signInWithPassword')) signIns += 1;
      });
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
      await admin.goToPage(s.page, 'Team Orders');
      await s.page.getByRole('button', { name: new RegExp(`^${oldOrder}`) }).waitFor();
      assert.equal(await B.semantic(s.page, newOrder).count(), 0);
      await s.page.evaluate(() => { window.__accessScopeSession = 'same-supervisor-session'; });
      await t.shot(s, 'before-team-change');
    });

    await t.step('a network drop keeps the confirmed dashboard on screen', async () => {
      await s.context.setOffline(true);
      await s.page.waitForTimeout(15000);
      assert.equal(await s.page.getByRole('button', { name: new RegExp(`^${oldOrder}`) }).count(), 1);
      await t.shot(s, 'offline-dashboard-kept');
      await s.context.setOffline(false);
      await s.page.getByRole('button', { name: new RegExp(`^${oldOrder}`) }).waitFor();
      assert.equal(await s.page.evaluate(() => window.__accessScopeSession), 'same-supervisor-session');
    });

    await t.step('access-only team change replaces old rows without reload or another sign-in', async () => {
      await db.put('user_access', seed.uids.supervisor, {
        ...access, assignedSalesmanCodes: [replacement.code], updatedAt: new Date(),
      });
      await s.page.getByRole('button', { name: new RegExp(`^${newOrder}`) }).waitFor({ timeout: 30000 });
      await B.semantic(s.page, oldOrder).waitFor({ state: 'hidden', timeout: 10000 });
      assert.equal(await s.page.evaluate(() => window.__accessScopeSession), 'same-supervisor-session');
      assert.equal(signIns, 1, 'team refresh must preserve the authenticated session');
      await t.shot(s, 'after-team-change');
    });

    await t.step('linked users profile updates are observed without restoring its stale team', async () => {
      await db.put('users', accounts.supervisor.email, { ...profile, name: 'E2E Updated Supervisor' });
      await B.see(s.page, 'E2E Updated Supervisor');
      await s.page.getByRole('button', { name: new RegExp(`^${newOrder}`) }).waitFor({ timeout: 20000 });
      assert.equal(await B.semantic(s.page, oldOrder).count(), 0);
      await t.shot(s, 'linked-profile-refreshed');
    });

    await t.step('suspension removes the shell and cached order dialog', async () => {
      await admin.openOrder(s.page, newOrder);
      await db.put('user_access', seed.uids.supervisor, {
        ...access, assignedSalesmanCodes: [replacement.code], status: 'suspended', isActive: false,
      });
      await B.see(s.page, 'Account Suspended', { timeout: 30000 });
      await B.semantic(s.page, newOrder).waitFor({ state: 'hidden', timeout: 10000 });
      assert.equal(await s.page.getByRole('button', { name: 'Team Orders', exact: true }).count(), 0);
      await t.shot(s, 'suspended-without-reload');
    });

    await t.step('role change replaces navigation while the display role stays stale', async () => {
      await db.put('user_access', seed.uids.supervisor, {
        ...access, role: 'branch_manager', status: 'active', assignedSalesmanCodes: [],
      });
      await admin.waitForBranchManagerShell(s.page);
      assert.equal(await s.page.getByRole('button', { name: 'Team Orders', exact: true }).count(), 0);
      assert.equal(await s.page.evaluate(() => window.__accessScopeSession), 'same-supervisor-session');
      await t.shot(s, 'role-navigation-refreshed');
    });

    await t.step('removed access does not revive the stale display profile', async () => {
      await db.del('users', accounts.supervisor.email);
      await B.semantic(s.page, 'E2E Updated Supervisor').waitFor({ state: 'hidden', timeout: 10000 });
      await admin.waitForBranchManagerShell(s.page);
      await db.del('user_access', seed.uids.supervisor);
      await B.see(s.page, 'No Profile Found', { timeout: 30000 });
      assert.equal(await s.page.getByRole('button', { name: /Branch Routes/ }).count(), 0);
      assert.equal(signIns, 1);
      await t.shot(s, 'removed-access');
      await t.collectEvidence('PASSED');
    });
  },
};
