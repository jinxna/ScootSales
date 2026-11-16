'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const dashboard = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');

const SUPPORT_EMAIL = staff.STAFF_ROLE_EMAILS.support;
const REASON = 'Investigate synchronisation delay';

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

function check(condition, label) {
  if (!condition) throw new Error(label);
}

module.exports = {
  name: 'v4_support_consent',
  async run(t) {
    const out = path.join(E.OUTPUT_DIR, 'v4_support_consent');
    fs.mkdirSync(out, { recursive: true });
    const trusted = platform.ensureKey();
    const record = platform.harnessRecord();
    const evidence = { checks: [] };
    const note = (text) => evidence.checks.push(text);
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    let adminSession;
    let grant;
    const grants = () => platformDb.list('support_grants');

    try {
      await t.step('the company is on Starter and no support grant exists', async () => {
        directory.planAdmin([trusted], [{ op: 'subscribe', planId: 'STARTER', reseed: true }, { op: 'usage' }]);
        equal((await grants()).length, 0, 'no grant before consent');
        note('one central service and the Starter company ready; no grant exists');
      });

      await t.step('client admin grants 45-minute diagnostics access from the Account page', async () => {
        adminSession = await t.session('admin');
        await B.loginAdmin(adminSession.page, `${adminSession.url}/w/${record.workspace}`, t.accounts.admin.email);
        await dashboard.waitForShell(adminSession.page);
        await dashboard.goToPage(adminSession.page, 'Account');
        await B.see(adminSession.page, 'Enter your password to see your plan and usage.');
        await B.fillField(adminSession.page, adminSession.page.locator('input[type="password"]').first(), E.PASSWORD);
        await adminSession.page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(adminSession.page, /Plan: Starter/);
        const email = adminSession.page.getByRole('textbox', { name: 'Support staff email', exact: true });
        await B.scrollIntoView(adminSession.page, email, { minHeight: 40, bottomInset: 0 });
        await B.fillField(adminSession.page, email, SUPPORT_EMAIL);
        const reason = adminSession.page.getByRole('textbox', { name: 'Reason', exact: true });
        await B.scrollIntoView(adminSession.page, reason, { minHeight: 40, bottomInset: 0 });
        await B.fillField(adminSession.page, reason, REASON);
        const submit = adminSession.page.getByRole('button', { name: 'Grant 45-minute diagnostics access', exact: true });
        await B.scrollIntoView(adminSession.page, submit, { minHeight: 40, bottomInset: 0 });
        await submit.click();
        await B.see(adminSession.page, 'Diagnostics access is active for 45 minutes or until revoked.');
        await B.see(adminSession.page, new RegExp(`${SUPPORT_EMAIL.replace(/\./g, '\\.')} · expires`));
        await adminSession.page.getByRole('button', { name: 'Revoke support access', exact: true }).waitFor();
        await t.shot(adminSession, 'grant-active');

        const rows = await grants();
        equal(rows.length, 1, 'one grant in the central database');
        grant = rows[0];
        check(/^grant_[0-9a-f]{64}$/.test(grant.id), `grant id ${grant.id}`);
        equal(grant.tenantId, record.tenantId, 'grant tenant');
        equal(grant.staffEmail, SUPPORT_EMAIL, 'grant staff email');
        equal(grant.scope, 'diagnostics', 'grant scope');
        equal(grant.reason, REASON, 'grant reason');
        equal(grant.status, 'active', 'grant status');
        equal(grant.revision, 1, 'grant revision');
        equal(grant.createdBy, t.seed.uids.admin, 'grant created by the signed-in client admin');
        const minutes = (grant.expiresAt - grant.createdAt) / 60000;
        check(minutes > 44.5 && minutes <= 45.1, `grant lifetime ${minutes} minutes`);
        check(grant.expiresAt > new Date(), 'grant expiry is in the future');
        equal((await platformDb.list('support_grant_receipts')).length, 1, 'idempotency receipt');
        equal((await t.db.list('support_grants')).length, 0, 'nothing written to the company database');
        note(`grant ${grant.id} stored in the central database, lifetime ${minutes.toFixed(2)} minutes, createdBy client admin uid`);
      });

      await t.step('client admin revokes the grant', async () => {
        const page = adminSession.page;
        const revoke = page.getByRole('button', { name: 'Revoke support access', exact: true });
        await B.scrollIntoView(page, revoke, { minHeight: 40, bottomInset: 0 });
        await revoke.click();
        await B.see(page, 'Diagnostics access was revoked.');
        await page.getByRole('button', { name: 'Grant 45-minute diagnostics access', exact: true }).waitFor();
        await t.shot(adminSession, 'grant-revoked');

        const stored = await platformDb.get('support_grants', grant.id);
        equal(stored.status, 'revoked', 'stored status');
        equal(stored.revision, 2, 'revision raised');
        equal(stored.revokedBy, t.seed.uids.admin, 'revoked by the client admin');
        check(stored.revokedAt instanceof Date, 'revokedAt recorded');
        equal((await grants()).length, 1, 'no second grant');

        note('revocation sets status revoked revision 2');
      });

    } finally {
      fs.writeFileSync(path.join(out, 'support-consent-evidence.json'), JSON.stringify(evidence, null, 2));
    }
  },
};
