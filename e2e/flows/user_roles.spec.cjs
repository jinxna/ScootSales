'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { seedFullSupervisor } = require('../lib/seed.cjs');
const E = require('../lib/emulator.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const BRANCH_NAME = 'E2E Miri Branch';
const BRANCH_ID = 'e2e_miri_branch';
const NEW_CODE = 'S778';
const RETRY_CODE = 'S779';
const NEW_USER = { name: 'E2E New Salesman', email: 'e2e.new.sales@example.test', code: 'S777' };

module.exports = {
  name: 'user_roles',
  platformMail: true,
  async run(t) {
    const { db, accounts, seed } = t;
    const sink = await startMailSink();
    let adminS;
    let uid;
    let invite;

    await t.step('admin logs in on the dashboard', async () => {
      adminS = await t.session('admin', admin.grantClipboard);
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
    });

    await t.step('admin creates a branch', async () => {
      await admin.createBranch(adminS.page, BRANCH_NAME);
      const branch = await db.waitForDoc('branches', BRANCH_ID, (b) => b.branchName === BRANCH_NAME);
      expectEqual(branch.status, 'active', 'branch status');
      await B.see(adminS.page, BRANCH_NAME);
      await t.shot(adminS, 'branch-created');
    });

    await t.step('a corrected field stops showing its old error', async () => {
      await admin.createUser(adminS.page, {
        name: NEW_USER.name, email: 'not-an-email', code: NEW_USER.code, expectDialog: false,
      });
      await B.see(adminS.page, 'Enter a valid email address');
      await admin.scrollFormTop(adminS.page);
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').nth(2), NEW_USER.email);
      await adminS.page.waitForTimeout(500);
      expectEqual(await B.semantic(adminS.page, 'Enter a valid email address').count(), 0, 'old email error after correction');
    });

    await t.step('admin invites a salesman in that branch under the supervisor', async () => {
      const supervisorAccess = await db.get('user_access', seed.uids.supervisor);
      await db.put('user_access', seed.uids.supervisor, { ...supervisorAccess, branchId: BRANCH_ID, branch_id: BRANCH_ID });
      const supervisorProfile = await db.get('users', accounts.supervisor.email);
      await db.put('users', accounts.supervisor.email, { ...supervisorProfile, branchId: BRANCH_ID, branch_id: BRANCH_ID });
      invite = await admin.createUser(adminS.page, {
        name: NEW_USER.name, email: NEW_USER.email, code: NEW_USER.code,
        branchName: BRANCH_NAME, supervisorOption: new RegExp(`^${accounts.supervisor.name}`),
        keepDialog: true,
      });
      if (!/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(invite.code)) throw new Error('invitation code shape: ' + invite.code);
      await t.shot(adminS, 'invitation-created');
      await admin.closeInvitationDialog(adminS.page);
      await admin.collapseInvitations(adminS.page);
    });

    await t.step('users doc and v2 user_access record are stored (pending until redeemed)', async () => {
      const profile = await db.waitForDoc('users', NEW_USER.code, (u) => !u.provisioningState);
      expectEqual(profile.email, NEW_USER.email, 'profile email');
      expectEqual(profile.role, 'salesman', 'profile role');
      expectEqual(profile.branchId, BRANCH_ID, 'profile branchId');
      expectEqual(profile.supervisorId, accounts.supervisor.code, 'profile supervisorId');
      uid = profile.uid;
      if (!uid) throw new Error('profile has no auth uid');
      const access = await db.waitForDoc('user_access', uid, (a) => a.accessVersion === 2);
      expectEqual(access.role, 'salesman', 'access role');
      expectEqual(access.branchId, BRANCH_ID, 'access branchId');
      expectEqual(access.supervisorUid, seed.uids.supervisor, 'access supervisorUid');
      expectEqual(access.employeeCode, NEW_USER.code, 'access employeeCode');
      expectEqual(access.status, 'suspended', 'access status before redeem');
      expectEqual(access.isActive, false, 'access isActive before redeem');
      expectEqual(access.invitationState, 'pending', 'access invitationState before redeem');
    });

    await t.step("the supervisor's assigned salesman codes gained the code", async () => {
      const supervisorAccess = await db.waitForDoc('user_access', seed.uids.supervisor, (a) => (a.assignedSalesmanCodes || []).includes(NEW_USER.code));
      expectEqual((supervisorAccess.assignedSalesmanCodes || []).slice().sort().join(), ['S001', NEW_USER.code].sort().join(), 'supervisor access codes');
      const supervisorProfile = await db.waitForDoc('users', accounts.supervisor.email, (u) => (u.assignedSalesmanCodes || []).includes(NEW_USER.code));
      expectEqual(supervisorProfile.assignedSalesmanCodes.length, 2, 'supervisor profile code count');
    });

    let mobileS;
    await t.step('the new salesman redeems the code on mobile and reaches the overview', async () => {
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-new' });
      await mobile.redeemInvitation(mobileS.page, mobileS.url, { code: invite.code, check: NEW_USER.email, password: E.PASSWORD });
      await B.submitEmailCode(mobileS.page, await sink.waitForEmailCode(NEW_USER.email));
      await mobile.finishRedeem(mobileS.page);
      const access = await db.waitForDoc('user_access', uid, (a) => a.status === 'active');
      expectEqual(access.isActive, true, 'access isActive after redeem');
      await B.see(mobileS.page, /Good (morning|afternoon|evening|night), E2E/);
      await t.shot(mobileS, 'home');
    });

    await t.step('admin suspends the salesman after confirming', async () => {
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.searchDirectory(adminS.page, NEW_USER.code);
      await adminS.page.getByRole('button', { name: 'Suspend', exact: true }).first().click();
      await B.see(adminS.page, `Suspend ${NEW_USER.name}?`);
      await B.see(adminS.page, 'They will be signed out and blocked until reactivated.');
      await t.shot(adminS, 'suspend-dialog');
      await adminS.page.getByRole('button', { name: 'Suspend', exact: true }).last().click();
      await B.see(adminS.page, `${NEW_USER.name} is suspended and blocked from signing in.`);
      const access = await db.waitForDoc('user_access', uid, (a) => a.status === 'suspended');
      expectEqual(access.isActive, false, 'access isActive');
      const profile = await db.get('users', NEW_USER.code);
      expectEqual(profile.status, 'suspended', 'profile status');
    });

    let blockedS;
    await t.step("the suspended salesman's next mobile sign-in is refused", async () => {
      blockedS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-suspended' });
      await B.loginMobile(blockedS.page, blockedS.url, NEW_USER.email);
      await B.see(blockedS.page, /disabled|suspended|no longer active/i, { timeout: 40000 });
      expectEqual(await blockedS.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner buttons visible to a suspended salesman');
      await t.shot(blockedS, 'blocked');
    });

    await t.step('a full supervisor (5/5) cannot take a 6th salesman', async () => {
      const full = await seedFullSupervisor(db);
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await adminS.page.getByRole('button', { name: 'Not linked' }).last().click();
      const option = adminS.page.getByRole('menuitem', { name: new RegExp(`${full.supervisor.name} \\(5/5\\) - full`) });
      await option.waitFor({ timeout: 20000 });
      await option.click({ force: true });
      await adminS.page.waitForTimeout(500);
      await adminS.page.keyboard.press('Escape');
      await adminS.page.waitForTimeout(300);
      expectEqual(await adminS.page.getByRole('button', { name: new RegExp(`^${full.supervisor.name}`) }).count(), 0, 'full supervisor selected');
      await adminS.page.getByRole('button', { name: 'Not linked' }).last().waitFor({ timeout: 5000 });
      await t.shot(adminS, 'supervisor-full');
    });

    await t.step('demoting a supervisor who still has salesmen is refused and changes nothing', async () => {
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.searchDirectory(adminS.page, accounts.supervisor.code);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await adminS.page.getByRole('button', { name: 'Supervisor', exact: true }).first().click();
      await adminS.page.getByRole('menuitem', { name: 'Admin', exact: true }).click();
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, 'Move the team first');
      await B.see(adminS.page, /salesmen are still assigned to this supervisor/);
      await t.shot(adminS, 'supervisor-demotion-refused');
      await adminS.page.getByRole('button', { name: 'OK', exact: true }).click();
      const access = await db.get('user_access', seed.uids.supervisor);
      expectEqual(access.role, 'supervisor', 'supervisor role after the refused demotion');
      const salesman = await db.get('user_access', seed.uids.salesman);
      expectEqual(salesman.supervisorUid, seed.uids.supervisor, 'salesman supervisorUid after the refused demotion');
    });

    await t.step('the edit page changes an existing employee code through the server route', async () => {
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.searchDirectory(adminS.page, NEW_USER.code);
      await B.see(adminS.page, NEW_USER.name);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await admin.scrollFormTop(adminS.page);
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').nth(0), NEW_CODE);
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, `Saved changes to ${NEW_USER.name}.`, { timeout: 30000 });
      const access = await db.waitForDoc('user_access', uid, (a) => a.employeeCode === NEW_CODE);
      expectEqual(access.userId, NEW_CODE, 'access userId');
      const profile = await db.waitForDoc('users', NEW_CODE, (p) => p.employeeCode === NEW_CODE);
      expectEqual(profile.uid, uid, 'profile uid after the code change');
      await t.shot(adminS, 'employee-code-changed');
    });

    await t.step('when the role step fails after the code step, the form keeps the new code and Save again finishes', async () => {
      const failRole = (route) => route.abort('failed');
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.searchDirectory(adminS.page, NEW_CODE);
      await B.see(adminS.page, NEW_USER.name);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await admin.scrollFormTop(adminS.page);
      const codeField = adminS.page.getByRole('textbox').nth(0);
      await B.fillField(adminS.page, codeField, RETRY_CODE);
      await adminS.page.getByRole('button', { name: 'Salesman', exact: true }).first().click();
      await adminS.page.getByRole('menuitem', { name: 'Supervisor', exact: true }).click();
      await adminS.page.route('**/accounts/*/role', failRole);
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, new RegExp(`The employee code is now ${RETRY_CODE}, but the other changes were not saved\\.[^]*Press Update Profile again to finish\\.`), { timeout: 30000 });
      await t.shot(adminS, 'role-step-failed');
      const afterFailure = await db.waitForDoc('user_access', uid, (a) => a.employeeCode === RETRY_CODE);
      expectEqual(afterFailure.role, 'salesman', 'access role after the failed role step');
      await admin.scrollFormTop(adminS.page);
      await t.shot(adminS, 'role-step-failed-form');
      await adminS.page.unroute('**/accounts/*/role', failRole);
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, `Saved changes to ${NEW_USER.name}.`, { timeout: 30000 });
      const access = await db.waitForDoc('user_access', uid, (a) => a.role === 'supervisor');
      expectEqual(access.employeeCode, RETRY_CODE, 'access code after Save again');
      const profile = await db.waitForDoc('users', RETRY_CODE, (p) => p.role === 'supervisor');
      expectEqual(profile.uid, uid, 'profile uid after Save again');
      expectEqual(await db.get('users', NEW_CODE), null, 'old code profile after Save again');
      await t.shot(adminS, 'role-saved-again');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
