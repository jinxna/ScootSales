'use strict';

const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'account_deletion_refused',
  platformMail: true,
  platformScheduler: true,
  async run(t) {
    const { db, accounts, seed } = t;
    const sup = accounts.supervisor;
    const uid = seed.uids.supervisor;
    const signIn = async () => {
      const response = await fetch(`${db.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: sup.email, password: E.PASSWORD, returnSecureToken: true }),
      });
      return (await response.json()).error?.message || 'OK';
    };
    let adminS;
    const assigned = (await db.get('user_access', uid)).assignedSalesmanCodes;

    await t.step('a supervisor who still has salespeople asks for deletion and is turned off', async () => {
      await db.put('user_access', uid, { ...(await db.get('user_access', uid)), assignedSalesmanCodes: [] });
      await db.put('privacy_deletion_requests', uid, { requestType: 'account_deletion', status: 'submitted', createdAt: new Date() });
      await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.status === 'reviewing' && r.purgeAfter, { timeout: 60000, label: 'accepted request' });
      expectEqual(await signIn(), 'USER_DISABLED', 'sign-in after the request');
    });

    await t.step('the administrator chooses Delete now; the purge is refused', async () => {
      await db.put('user_access', uid, { ...(await db.get('user_access', uid)), assignedSalesmanCodes: assigned });
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Role Assignment');
      await adminS.page.getByRole('button', { name: /Account deletion requests/ }).first().click();
      const deleteNow = adminS.page.getByRole('button', { name: 'Delete now', exact: true });
      await deleteNow.first().waitFor({ timeout: 20000 });
      await deleteNow.first().click();
      await B.see(adminS.page, 'Delete this account now?');
      await deleteNow.last().click();
      const shortened = await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.status === 'reviewing' && r.purgeAfter && r.purgeAfter - Date.now() < 7.5 * 86400000, { timeout: 90000, label: 'request shortened to the restore window' });
      await db.put('privacy_deletion_requests', uid, { ...shortened, purgeAfter: new Date(Date.now() - 60000) });
      const request = await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.status === 'rejected' && r.serverNote, { timeout: 90000, label: 'refused request' });
      if (!/salespeople/.test(request.serverNote)) throw new Error(`serverNote: ${request.serverNote}`);
    });

    await t.step('the supervisor can sign in again and keeps the account', async () => {
      const access = await db.waitForDoc('user_access', uid, (a) => !(a.disabledReasons || []).includes('deletion_requested'), { timeout: 60000, label: 'access restored' });
      expectEqual(access.disabledReasons || [], [], 'disabledReasons');
      await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.restoredAt, { timeout: 60000, label: 'sign-in restored' });
      expectEqual(await signIn(), 'OK', 'sign-in after the refused purge');
    });
  },
};
