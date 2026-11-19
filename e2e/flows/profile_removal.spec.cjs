'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');

const ORPHAN = { email: 'e2e.orphan.bm@example.test', name: 'E2E Orphan Manager', role: 'branch_manager', code: 'BM9' };
const TYPED = '9xjxcnqc6s0a';
const SHOWN = '9XJX-CNQC-6S0A';

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function typeCode(page, input, text) {
  await input.click();
  await page.keyboard.press('Control+A');
  await page.keyboard.press('Backspace');
  await page.keyboard.type(text, { delay: 20 });
}

async function checkCodeBox(t, s, input, label) {
  await typeCode(s.page, input, TYPED);
  expectEqual(await input.inputValue(), SHOWN, `${label}: typed lower case without dashes`);
  await t.shot(s, `${label}-code-typed`);
  await typeCode(s.page, input, '9xjx-cnqc 6s0a');
  expectEqual(await input.inputValue(), SHOWN, `${label}: typed with a dash and a space`);
  await typeCode(s.page, input, `${TYPED}zzzz`);
  expectEqual(await input.inputValue(), SHOWN, `${label}: longer than 12 characters`);
  await s.page.keyboard.press('Backspace');
  expectEqual(await input.inputValue(), '9XJX-CNQC-6S0', `${label}: one backspace`);
  await s.page.keyboard.press('Backspace');
  await s.page.keyboard.press('Backspace');
  await s.page.keyboard.press('Backspace');
  expectEqual(await input.inputValue(), '9XJX-CNQC', `${label}: backspace over the dash`);
  await s.page.keyboard.press('Backspace');
  expectEqual(await input.inputValue(), '9XJX-CNQ', `${label}: backspace after the dash`);
  await s.page.keyboard.type('c6s0a', { delay: 20 });
  expectEqual(await input.inputValue(), '9XJX-CNQC-6S0A', `${label}: typing again after deleting`);
  await s.page.keyboard.press('Home');
  await s.page.keyboard.press('ArrowRight');
  await s.page.keyboard.press('ArrowRight');
  await s.page.keyboard.press('ArrowRight');
  await s.page.keyboard.press('ArrowRight');
  await s.page.keyboard.press('ArrowRight');
  await s.page.keyboard.press('Backspace');
  expectEqual(await input.inputValue(), '9XJC-NQC6-S0A', `${label}: backspace over a dash in the middle removes the character before it`);
  await s.page.keyboard.type('x', { delay: 20 });
  expectEqual(await input.inputValue(), '9XJX-CNQC-6S0A', `${label}: typing in the middle puts the character at the cursor`);
  await typeCode(s.page, input, TYPED);
  await t.shot(s, `${label}-code-final`);
}

module.exports = {
  name: 'profile_removal',
  async run(t) {
    const { db, accounts, seed } = t;
    let adminS;

    await t.step('seed a branch manager profile with no sign-in, linked to the branch and the supervisor roster', async () => {
      await db.put('users', ORPHAN.email, {
        name: ORPHAN.name, fullName: ORPHAN.name, email: ORPHAN.email, role: ORPHAN.role, user_group: ORPHAN.role,
        employeeCode: ORPHAN.code, branchId: seed.branch.id, status: 'active', isActive: true, uid: '',
      });
      const supervisor = await db.get('users', accounts.supervisor.email);
      supervisor.assignedSalesmanCodes = [...supervisor.assignedSalesmanCodes, ORPHAN.code.toLowerCase()];
      await db.put('users', accounts.supervisor.email, supervisor);
      const branch = await db.get('branches', seed.branch.id);
      await db.put('branches', seed.branch.id, { ...branch, branchManagerId: ORPHAN.code });
      expectEqual(Boolean((await db.get('users', ORPHAN.email)).uid), false, 'orphan has no uid');
    });

    await t.step('admin opens Role Assignment and finds the profile with no sign-in', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, ORPHAN.code);
      await B.see(adminS.page, ORPHAN.name);
      await t.shot(adminS, 'orphan-found');
    });

    await t.step('Remove Profile on it shows Profile removed.', async () => {
      await adminS.page.getByRole('button', { name: 'Remove Profile', exact: true }).first().click();
      await B.see(adminS.page, `Type ${ORPHAN.name} to confirm`);
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').last(), ORPHAN.name);
      await t.shot(adminS, 'remove-dialog');
      await adminS.page.getByRole('button', { name: 'Delete', exact: true }).click();
      await B.see(adminS.page, 'Profile removed.', { timeout: 30000 });
      await t.shot(adminS, 'profile-removed');
    });

    await t.step('the store agrees: profile gone, roster and branch link cleaned', async () => {
      expectEqual(await db.get('users', ORPHAN.email), null, 'users doc after removal');
      const supervisor = await db.get('users', accounts.supervisor.email);
      const roster = (supervisor.assignedSalesmanCodes || []).map((c) => String(c).toLowerCase());
      if (roster.includes(ORPHAN.code.toLowerCase())) throw new Error(`roster still lists the code: ${JSON.stringify(supervisor.assignedSalesmanCodes)}`);
      if (!roster.includes(accounts.salesman.code.toLowerCase())) throw new Error('roster lost the other salesperson');
      const branch = await db.get('branches', seed.branch.id);
      if ('branchManagerId' in branch) throw new Error(`branch still names the manager: ${JSON.stringify(branch.branchManagerId)}`);
    });

    await t.step('dashboard: the Invitation code box shows capitals and dashes while typing', async () => {
      const anon = await t.session('admin', { name: 'admin-redeem' });
      await admin.openRedeemForm(anon.page, anon.url);
      await checkCodeBox(t, anon, anon.page.locator('input').nth(0), 'dashboard');
    });

    await t.step('phone: the Invitation code box shows capitals and dashes while typing', async () => {
      const phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'phone-redeem' });
      await B.openApp(phone.page, phone.url);
      await phone.page.getByRole('button', { name: 'I have an invitation code' }).waitFor({ timeout: 60000 });
      await phone.page.getByRole('button', { name: 'I have an invitation code' }).click();
      const input = phone.page.locator('input').nth(0);
      await input.waitFor({ timeout: 20000 });
      await phone.page.waitForTimeout(300);
      await checkCodeBox(t, phone, input, 'phone');
    });
  },
};
