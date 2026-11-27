'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson } = require('../lib/seed.cjs');

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'bm_hierarchy',
  async run(t) {
    const { db, accounts, seed } = t;
    let bmS;
    let adminS;

    await t.step('seed a second supervisor, an unassigned salesperson and another branch', async () => {
      const sup2 = { email: 'e2e.hier.sup2@example.test', name: 'E2E Hier Supervisor', role: 'supervisor', code: 'SUP-H2', branch: seed.branch.id };
      const sup2Uid = await putPerson(db, sup2, { assignedSalesmanCodes: ['s777', 'S001'] });
      await putPerson(db, { email: 'e2e.hier.s777@example.test', name: 'E2E Hier Seven', role: 'salesman', code: 'S777', branch: seed.branch.id }, { supervisorUid: sup2Uid, supervisorCode: sup2.code });
      await putPerson(db, { email: 'e2e.hier.s888@example.test', name: 'E2E Hier Unassigned', role: 'salesman', code: 'S888', branch: seed.branch.id });
      await db.put('branches', 'B2', { branchId: 'B2', name: 'E2E Other Branch', branchName: 'E2E Other Branch', status: 'active' });
      await putPerson(db, { email: 'e2e.other.sup@example.test', name: 'E2E Other Branch Supervisor', role: 'supervisor', code: 'SUP-B2', branch: 'B2' }, { assignedSalesmanCodes: ['S999'] });
    });

    await t.step('branch manager opens Branch Team and sees the tree', async () => {
      bmS = await t.session('admin');
      await B.loginAdmin(bmS.page, bmS.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(bmS.page);
      await admin.goToPage(bmS.page, 'Branch Team');
      await B.see(bmS.page, 'E2E Branch Manager (you)');
      await B.see(bmS.page, 'E2E Supervisor');
      await B.see(bmS.page, 'E2E Hier Supervisor');
      await t.shot(bmS, 'bm-hierarchy');
    });

    await t.step('a salesperson listed under two supervisors appears once in the tree', async () => {
      const tree = bmS.page.getByText(/E2E Salesperson\s+·\s+S001/);
      expectEqual(await tree.count(), 1, 'S001 tree entries');
    });

    await t.step('a code stored in another letter case shows the person\'s own code', async () => {
      await B.see(bmS.page, /E2E Hier Seven\s+·\s+S777/);
    });

    await t.step('salespeople without a supervisor are counted as a warning', async () => {
      await B.see(bmS.page, '1 salesperson in your branch has no supervisor.');
    });

    await t.step('other branches never appear', async () => {
      expectEqual(await bmS.page.getByText('E2E Other Branch Supervisor').count(), 0, 'other branch supervisor entries');
    });

    await t.step('View Team lists the branch salespeople and supervisors, not the same-branch admin', async () => {
      await admin.goToPage(bmS.page, 'View Team');
      await B.see(bmS.page, 'E2E Hier Seven', { timeout: 30000 });
      await B.see(bmS.page, 'E2E Hier Supervisor');
      expectEqual(await bmS.page.getByText(accounts.admin.email).count(), 0, 'same-branch admin email in View Team');
      expectEqual(await bmS.page.getByText('E2E Admin', { exact: true }).count(), 0, 'same-branch admin name in View Team');
      expectEqual(await bmS.page.getByText('E2E Other Branch Supervisor').count(), 0, 'other branch supervisor in View Team');
      await t.shot(bmS, 'view-team');
    });

    await t.step('branch manager narrow screen loads every asset (compact header logo)', async () => {
      await B.expectAssetsLoad(
        bmS.page,
        () => bmS.page.setViewportSize({ width: 390, height: 844 }),
        'Open menu',
      );
      await t.shot(bmS, 'bm-compact');
    });

    await t.step('editing a salesperson whose supervisor is in another branch is refused and changes nothing', async () => {
      const crossed = { email: 'e2e.hier.s889@example.test', name: 'E2E Hier Crossed', role: 'salesman', code: 'S889', branch: seed.branch.id };
      const otherSupervisor = await db.waitForQuery('user_access', (a) => a.employeeCode === 'SUP-B2');
      await putPerson(db, crossed, { supervisorUid: otherSupervisor.uid, supervisorCode: 'SUP-B2' });
      adminS = await t.session('admin', { name: 'admin-crossed' });
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, crossed.code);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, 'That supervisor is in another branch. Choose a supervisor in the same branch.', { timeout: 30000 });
      const stored = await db.get('users', crossed.email);
      expectEqual(stored.supervisorId, 'SUP-B2', 'stored supervisorId after the refused edit');
      expectEqual(stored.branchId, seed.branch.id, 'stored branchId after the refused edit');
      const otherAccess = await db.get('user_access', otherSupervisor.uid);
      expectEqual((otherAccess.assignedSalesmanCodes || []).slice().sort().join(), 'S999', 'SUP-B2 access codes after the refused edit');
      const otherProfile = await db.get('users', 'e2e.other.sup@example.test');
      expectEqual((otherProfile.assignedSalesmanCodes || []).slice().sort().join(), 'S999', 'SUP-B2 profile codes after the refused edit');
      await t.shot(adminS, 'crossed-supervisor-refused');
    });

    await t.step('moving a supervisor who still has a team to another branch is refused and changes nothing', async () => {
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, 'SUP-H2');
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await admin.scrollFormTop(adminS.page);
      const branchTrigger = adminS.page.getByRole('button', { name: seed.branch.name }).first();
      await B.scrollIntoView(adminS.page, branchTrigger, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await branchTrigger.click();
      await adminS.page.getByRole('menuitem', { name: 'E2E Other Branch', exact: true }).first().click();
      const updateProfile = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, updateProfile, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await updateProfile.click();
      await B.see(adminS.page, 'Move the team first');
      await B.see(adminS.page, /still assigned to this supervisor/);
      await t.shot(adminS, 'supervisor-branch-move-refused');
      await adminS.page.getByRole('button', { name: 'OK', exact: true }).click();
      const stored = await db.get('users', 'e2e.hier.sup2@example.test');
      expectEqual(stored.branchId, seed.branch.id, 'SUP-H2 stored branchId after the refused move');
      const access = await db.get('user_access', stored.uid);
      expectEqual(access.branchId, seed.branch.id, 'SUP-H2 access branchId after the refused move');
    });
  },
};
