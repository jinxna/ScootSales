'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const directory = require('../lib/platform_api.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'invitations');
const PASSWORD = E.PASSWORD;

const MSG = {
  invalid: 'The invitation code or check is not valid.',
  used: 'This invitation was already used.',
  expired: 'This invitation has expired. Ask your administrator for a new one.',
  locked: 'This invitation is locked after too many tries. Ask your administrator for a new one.',
};

const SALESMAN = { name: 'E2E Invited Salesman', code: 'S801', phone: '0123456789', last4: '6789' };
const EXPIRING = { name: 'E2E Expiring Salesman', code: 'S802', phone: '0198887777', last4: '7777' };
const LOCKED = { name: 'E2E Locked Manager', code: 'BM-801', email: 'e2e.locked.bm@example.test', role: 'Branch Manager' };
const SUPERVISOR = { name: 'E2E Invited Supervisor', code: 'SUP-801', email: 'e2e.invited.sup@example.test', role: 'Supervisor' };

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'invitations',
  platformMail: true,
  async run(t) {
    const { db, accounts } = t;
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const sink = await startMailSink();
    const evidence = { project: E.PROJECT, platformProject: directory.PLATFORM_PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const invites = {};
    const branchName = 'E2E Kuching Branch';
    let adminS;
    let salesmanUid;

    const invitationOf = async (displayName) => {
      const hit = (await platformDb.list('invitations')).find((i) => i.displayName === displayName);
      if (!hit) throw new Error(`no invitation record for ${displayName}`);
      return hit;
    };
    const waitInvitation = (displayName, predicate, label) => platformDb.waitForQuery(
      'invitations', (i) => i.displayName === displayName && predicate(i), { label },
    );
    const authSignIn = async (email, password) => {
      const res = await fetch(`${db.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password, returnSecureToken: true }),
      });
      return { ok: res.ok, error: res.ok ? null : (await res.json()).error.message };
    };
    const phone = (name) => t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name });
    const semanticsText = async (s) => (await admin.semanticsLines(s.page)).join('\n');
    const withSignInId = async (displayName, invite) => ({ ...invite, signInId: (await invitationOf(displayName)).signInId });

    try {
      await t.step('a. admin invites a salesman with a phone number; the dialog shows the code', async () => {
        adminS = await t.session('admin', admin.grantClipboard);
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        const result = await admin.createUser(adminS.page, {
          name: SALESMAN.name, code: SALESMAN.code, phone: SALESMAN.phone, branchName, keepDialog: true,
        });
        invites[SALESMAN.code] = await withSignInId(SALESMAN.name, result);
        if (!/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(result.code)) throw new Error('code format: ' + result.code);
        const signInId = invites[SALESMAN.code].signInId || '';
        if (!/^s801@.+\.invalid$/.test(signInId)) throw new Error('sign-in id for a phone-only invite: ' + signInId);
        const text = await semanticsText(adminS);
        for (const needle of ['Invitation created', 'Sign-in ID', 'Expires', 'Second check', 'Copy code', 'Done']) {
          if (!text.includes(needle)) throw new Error(`dialog is missing "${needle}"`);
        }
        if (!/last 4 digits/i.test(text)) throw new Error('dialog does not name the phone second check');
        await t.shot(adminS, 'a-dialog');
        await admin.closeInvitationDialog(adminS.page);
        note('invitation dialog', { signInId, codeShape: 'XXXX-XXXX-XXXX' });
      });

      await t.step('a. the Invitations list shows the invitation as Open', async () => {
        await admin.openInvitations(adminS.page);
        await B.see(adminS.page, new RegExp(`${SALESMAN.name} · Salesman`));
        await B.see(adminS.page, /^Open$/);
        const record = await invitationOf(SALESMAN.name);
        expectEqual(record.status, 'open', 'stored invitation status');
        const access = await db.waitForDoc('user_access', record.uid, (a) => a.accessVersion === 2);
        expectEqual(access.status, 'suspended', 'access status before redeem');
        expectEqual(access.isActive, false, 'access isActive before redeem');
        salesmanUid = record.uid;
        await t.shot(adminS, 'a-list-open');
        note('open invitation', { status: record.status, accessStatus: access.status });
      });

      let phoneS;
      await t.step('b. phone: a wrong last-4 gives the generic message and signs nobody in', async () => {
        phoneS = await phone('phone-salesman');
        const { code } = invites[SALESMAN.code];
        await mobile.redeemInvitation(phoneS.page, phoneS.url, { code, check: '0000', password: PASSWORD });
        await B.see(phoneS.page, MSG.invalid, { timeout: 30000 });
        await t.shot(phoneS, 'b-wrong-last4');
        expectEqual(await phoneS.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner visible after a wrong check');
        await waitInvitationFailures(1);
      });

      await t.step('b. phone: a forwarded code with the email instead of the phone check never signs in', async () => {
        const { code } = invites[SALESMAN.code];
        await mobile.redeemInvitation(phoneS.page, phoneS.url, { code, check: 'someone.else@example.test', password: PASSWORD }, { open: false });
        await waitInvitationFailures(2);
        await B.see(phoneS.page, MSG.invalid);
        expectEqual(await phoneS.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner visible after a wrong check');
        const access = await db.get('user_access', salesmanUid);
        expectEqual(access.isActive, false, 'access isActive after wrong checks');
        expectEqual((await invitationOf(SALESMAN.name)).status, 'open', 'invitation still open');
        note('wrong checks', { failures: 2, message: MSG.invalid });
      });

      async function waitInvitationFailures(n) {
        await waitInvitation(SALESMAN.name, (i) => i.failures === n, `${SALESMAN.name} failures=${n}`);
      }

      await t.step('c. phone: the right last-4 and a new password show "Invitation accepted", Continue opens Home', async () => {
        const { code, signInId } = invites[SALESMAN.code];
        await mobile.redeemInvitation(phoneS.page, phoneS.url, { code, check: SALESMAN.last4, password: PASSWORD }, { open: false });
        await B.see(phoneS.page, 'Invitation accepted', { timeout: 30000 });
        await t.shot(phoneS, 'c-accepted');
        const shown = await mobile.finishRedeem(phoneS.page);
        if (shown !== null) expectEqual(shown, signInId, 'sign-in id on the accepted dialog');
        await t.shot(phoneS, 'c-home');
        const access = await db.waitForDoc('user_access', salesmanUid, (a) => a.status === 'active');
        expectEqual(access.isActive, true, 'access isActive after redeem');
        const record = await waitInvitation(SALESMAN.name, (i) => i.status === 'redeemed', 'redeemed');
        note('redeemed', { status: record.status, accessStatus: access.status, device: record.redeemedDevice });
      });

      await t.step('c. the salesman signs out and signs in again with the sign-in ID and the password', async () => {
        await mobile.signOut(phoneS.page);
        await t.shot(phoneS, 'c-signed-out');
        const again = await phone('phone-salesman-again');
        await B.loginMobile(again.page, again.url, invites[SALESMAN.code].signInId);
        await mobile.waitForHome(again.page);
        await t.shot(again, 'c-signed-in-again');
        note('sign in again', { signInId: invites[SALESMAN.code].signInId });
      });

      await t.step('d. a second redeem of the same code says it was already used', async () => {
        const second = await phone('phone-second-redeem');
        const { code } = invites[SALESMAN.code];
        await mobile.redeemInvitation(second.page, second.url, { code, check: SALESMAN.last4, password: PASSWORD });
        await B.see(second.page, MSG.used, { timeout: 30000 });
        await t.shot(second, 'd-already-used');
        expectEqual(await second.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner visible on a reused code');
        note('second redeem', { message: MSG.used });
      });

      await t.step('e. the admin list shows Redeemed at <time> on <device>', async () => {
        await admin.openInvitations(adminS.page);
        await B.see(adminS.page, /Redeemed at \d{4}-\d{2}-\d{2} \d{2}:\d{2} on .+/);
        await B.see(adminS.page, /^Redeemed$/);
        const line = (await admin.semanticsLines(adminS.page)).find((l) => /Redeemed at /.test(l));
        await t.shot(adminS, 'e-list-redeemed');
        note('redeemed row', { text: line });
      });

      await t.step('f. a branch manager is invited by email', async () => {
        invites[LOCKED.code] = await withSignInId(LOCKED.name, await admin.createUser(adminS.page, {
          name: LOCKED.name, code: LOCKED.code, email: LOCKED.email, role: LOCKED.role, branchName, keepDialog: true,
        }));
        expectEqual(invites[LOCKED.code].signInId, LOCKED.email, 'sign-in id of an email invite');
        const text = await semanticsText(adminS);
        if (!/email/i.test(text)) throw new Error('dialog does not name the email second check');
        await t.shot(adminS, 'f-dialog-email');
        await admin.closeInvitationDialog(adminS.page);
      });

      await t.step('f. five wrong checks: the 5th answer is the locked message, and the right check then fails too', async () => {
        const s = await t.session('admin', { name: 'admin-redeem-locked' });
        await admin.openRedeemForm(s.page, s.url);
        const { code } = invites[LOCKED.code];
        for (let attempt = 1; attempt <= 5; attempt += 1) {
          await admin.submitRedeemForm(s.page, { code, check: `wrong${attempt}@example.test`, password: PASSWORD });
          await waitInvitation(LOCKED.name, (i) => i.failures === attempt, `${LOCKED.name} failures=${attempt}`);
          if (attempt < 5) {
            await B.see(s.page, MSG.invalid);
            expectEqual(await B.semantic(s.page, MSG.locked).count(), 0, `locked message after wrong check ${attempt}`);
          }
        }
        await B.see(s.page, MSG.locked, { timeout: 20000 });
        await t.shot(s, 'f-locked');
        expectEqual((await invitationOf(LOCKED.name)).status, 'locked', 'stored invitation status');
        await admin.submitRedeemForm(s.page, { code, check: LOCKED.email, password: PASSWORD });
        await B.see(s.page, MSG.locked, { timeout: 20000 });
        await s.page.waitForTimeout(1500);
        expectEqual(await s.page.getByRole('button', { name: /Team Overview|Branch Routes|All Orders/ }).count(), 0, 'dashboard shell after the lock');
        const access = await db.get('user_access', (await invitationOf(LOCKED.name)).uid);
        expectEqual(access.isActive, false, 'locked person access isActive');
        await t.shot(s, 'f-locked-right-check');
        note('lock', { failures: 5, message: MSG.locked });
      });

      await t.step('f. the admin list shows the locked invitation', async () => {
        await admin.openInvitations(adminS.page);
        await B.see(adminS.page, /^Locked$/);
        await t.shot(adminS, 'f-list-locked');
      });

      await t.step('g. an expired invitation cannot be redeemed', async () => {
        invites[EXPIRING.code] = await admin.createUser(adminS.page, {
          name: EXPIRING.name, code: EXPIRING.code, phone: EXPIRING.phone, branchName,
        });
        const record = await invitationOf(EXPIRING.name);
        await platformDb.put('invitations', record.id, { ...stripId(record), expiresAt: new Date(Date.now() - 60 * 60 * 1000) });
        const s = await phone('phone-expired');
        await mobile.redeemInvitation(s.page, s.url, { code: invites[EXPIRING.code].code, check: EXPIRING.last4, password: PASSWORD });
        await B.see(s.page, MSG.expired, { timeout: 30000 });
        await t.shot(s, 'g-expired');
        expectEqual(await s.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner visible on an expired code');
        const access = await db.get('user_access', record.uid);
        expectEqual(access.isActive, false, 'expired person access isActive');
        await admin.openInvitations(adminS.page);
        await B.see(adminS.page, /^Expired$/);
        await t.shot(adminS, 'g-list-expired');
        note('expired', { message: MSG.expired });
      });

      await t.step('h. admin revokes the redeemed salesman account after confirming', async () => {
        await admin.openInvitations(adminS.page);
        const revoke = adminS.page.getByRole('button', { name: 'Revoke account', exact: true });
        await revoke.first().waitFor({ timeout: 20000 });
        expectEqual(await revoke.count(), 1, 'Revoke account buttons (only the redeemed salesman)');
        await revoke.first().click();
        await B.see(adminS.page, 'Revoke this account?');
        await t.shot(adminS, 'h-confirm');
        await revoke.last().click();
        await B.see(adminS.page, `The account of ${SALESMAN.name} was revoked.`, { timeout: 30000 });
        const access = await db.waitForDoc('user_access', salesmanUid, (a) => a.status === 'suspended');
        expectEqual(access.isActive, false, 'access isActive after revoke');
        const profile = await db.get('users', SALESMAN.code);
        expectEqual(profile.status, 'suspended', 'profile status after revoke');
        const attempt = await authSignIn(invites[SALESMAN.code].signInId, PASSWORD);
        expectEqual(attempt.error, 'USER_DISABLED', 'Auth sign-in of the revoked account');
        await t.shot(adminS, 'h-revoked');
        note('revoked account', { accessStatus: access.status, auth: attempt.error });
      });

      await t.step('h. the revoked salesman can no longer sign in on the phone', async () => {
        const s = await phone('phone-revoked');
        await B.loginMobile(s.page, s.url, invites[SALESMAN.code].signInId);
        await B.see(s.page, /disabled|suspended|no longer active/i, { timeout: 40000 });
        expectEqual(await s.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner visible to a revoked salesman');
        await t.shot(s, 'h-revoked-sign-in');
      });

      await t.step('i. a supervisor invitation redeemed on the dashboard sign-in page opens the supervisor shell', async () => {
        invites[SUPERVISOR.code] = await admin.createUser(adminS.page, {
          name: SUPERVISOR.name, code: SUPERVISOR.code, email: SUPERVISOR.email, role: SUPERVISOR.role, branchName,
        });
        const s = await t.session('admin', { name: 'admin-redeem-supervisor' });
        await admin.openRedeemForm(s.page, s.url);
        await t.shot(s, 'i-redeem-form');
        await admin.submitRedeemForm(s.page, { code: invites[SUPERVISOR.code].code, check: SUPERVISOR.email, password: PASSWORD });
        await B.submitEmailCode(s.page, await sink.waitForEmailCode(SUPERVISOR.email));
        await admin.waitForSupervisorShell(s.page);
        await t.shot(s, 'i-supervisor-shell');
        const record = await waitInvitation(SUPERVISOR.name, (i) => i.status === 'redeemed', 'supervisor redeemed');
        const access = await db.waitForDoc('user_access', record.uid, (a) => a.status === 'active');
        expectEqual(access.role, 'supervisor', 'access role');
        expectEqual(access.isActive, true, 'access isActive');
        note('dashboard redeem', { role: access.role, status: access.status });
      });
    } finally {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    }
  },
};

function stripId(doc) {
  const { id, ...fields } = doc;
  return fields;
}
