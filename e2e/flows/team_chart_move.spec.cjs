'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson, seedFullSupervisor, FULL_SUPERVISOR } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'team_chart_move');
const CHART_SUP = { email: 'e2e.chart.sup@example.test', name: 'E2E Chart Supervisor', role: 'supervisor', code: 'SUP-C2' };
const FAR_SUP = { email: 'e2e.far.sup@example.test', name: 'E2E Far Supervisor', role: 'supervisor', code: 'SUP-FAR', branch: 'B2' };

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'team_chart_move',
  async run(t) {
    const { db, accounts, seed } = t;
    const evidence = { project: E.PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const uids = {};
    let s;

    const access = async (uid) => db.get('user_access', uid);
    const waitAccess = (uid, predicate, label) => db.waitForDoc('user_access', uid, predicate, { label, timeout: 30000 });
    const smallestBox = async (pattern) => {
      const nodes = s.page.getByLabel(pattern).or(s.page.getByText(pattern));
      await nodes.first().waitFor({ state: 'attached', timeout: 20000 });
      const boxes = (await Promise.all((await nodes.all()).map((node) => node.boundingBox()))).filter(Boolean);
      if (!boxes.length) throw new Error(`no box for ${pattern}`);
      return boxes.sort((a, b) => a.width * a.height - b.width * b.height)[0];
    };
    const moveViaMenu = async (target) => {
      await s.page.getByRole('button', { name: 'Move E2E Salesperson to...' }).click();
      await s.page.getByRole('menuitem', { name: new RegExp(target) }).click();
      await B.see(s.page, 'Move E2E Salesperson?');
    };
    const dragOnto = async (headerText) => {
      const from = await smallestBox(/E2E Salesperson\s+·\s+S001/);
      const to = await smallestBox(new RegExp(headerText));
      if (!from || !to) throw new Error(`no box to drag from or to (${headerText})`);
      await s.page.mouse.move(from.x + 20, from.y + from.height / 2);
      await s.page.mouse.down();
      for (let i = 1; i <= 12; i += 1) {
        await s.page.mouse.move(
          from.x + 20 + ((to.x + 30 - from.x - 20) * i) / 12,
          from.y + from.height / 2 + ((to.y + to.height / 2 - from.y - from.height / 2) * i) / 12,
        );
        await s.page.waitForTimeout(40);
      }
      await t.shot(s, `drag-over-${headerText.replace(/\W+/g, '-').toLowerCase()}`);
      await s.page.mouse.up();
    };
    const unchanged = async (label) => {
      const record = await access(uids.salesman);
      expectEqual(record.supervisorUid, uids.chart, `${label}: salesperson supervisor`);
      expectEqual((await access(uids.chart)).assignedSalesmanCodes, ['S001'], `${label}: chart supervisor list`);
      expectEqual((await access(uids.full)).assignedSalesmanCodes.length, 5, `${label}: full supervisor list size`);
      expectEqual((await access(uids.far)).assignedSalesmanCodes, [], `${label}: other branch list`);
    };

    await t.step('seed a second supervisor, a full one, another branch and two routes in progress', async () => {
      uids.salesman = (await db.waitForQuery('user_access', (a) => a.employeeCode === accounts.salesman.code)).uid;
      uids.supervisor = (await db.waitForQuery('user_access', (a) => a.employeeCode === accounts.supervisor.code)).uid;
      uids.chart = await putPerson(db, { ...CHART_SUP, branch: seed.branch.id });
      uids.full = (await seedFullSupervisor(db)).uid;
      await db.put('branches', 'B2', { branchId: 'B2', name: 'E2E Far Branch', branchName: 'E2E Far Branch', status: 'active' });
      uids.far = await putPerson(db, FAR_SUP);
      for (const planId of ['chart-plan-1', 'chart-plan-2']) {
        await db.put('route_plan_progress', `${planId}_${uids.salesman}`, {
          planId, salesmanUid: uids.salesman, salesmanCode: 'S001', branchId: seed.branch.id,
          status: 'in_progress', updatedAt: new Date(),
        });
      }
    });

    await t.step('admin opens the team chart on the Users page', async () => {
      s = await t.session('admin', { viewport: { width: 1600, height: 1700 } });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Role Assignment');
      await s.page.getByRole('button', { name: /Team chart/ }).click();
      await B.see(s.page, /Branch E2E Kuching Branch\s+·\s+E2E Branch Manager/);
      await B.see(s.page, /E2E Supervisor\s+·\s+SUP-E2E\s+·\s+1 of 5/);
      await B.see(s.page, /E2E Chart Supervisor\s+·\s+SUP-C2\s+·\s+0 of 5/);
      await B.see(s.page, /Branch E2E Far Branch\s+·\s+no branch manager/);
      await t.shot(s, 'chart-before');
      note('chart shows branch, branch manager, supervisors and salespeople');
    });

    await t.step('Move to... asks first and shows the routes in progress', async () => {
      await moveViaMenu('E2E Chart Supervisor');
      await B.see(s.page, 'From E2E Supervisor to E2E Chart Supervisor.');
      await B.see(s.page, '2 routes in progress. They stay with E2E Salesperson.');
      await t.shot(s, 'confirm-routes-in-progress');
      await s.page.getByRole('button', { name: 'Move', exact: true }).click();
      await B.see(s.page, 'E2E Salesperson now reports to E2E Chart Supervisor.');
      note('confirmation showed 2 routes in progress');
    });

    await t.step('the stored assignment moved and the chart updated live', async () => {
      await waitAccess(uids.salesman, (a) => a.supervisorUid === uids.chart && a.supervisorId === CHART_SUP.code, 'salesperson link');
      await waitAccess(uids.chart, (a) => JSON.stringify(a.assignedSalesmanCodes) === '["S001"]', 'new supervisor list');
      await waitAccess(uids.supervisor, (a) => JSON.stringify(a.assignedSalesmanCodes) === '[]', 'old supervisor list');
      const profile = await db.get('users', CHART_SUP.email);
      expectEqual(profile.assignedSalesmanCodes, ['S001'], 'new supervisor profile list');
      await B.see(s.page, /E2E Chart Supervisor\s+·\s+SUP-C2\s+·\s+1 of 5/);
      await B.see(s.page, /E2E Supervisor\s+·\s+SUP-E2E\s+·\s+0 of 5/);
      await t.shot(s, 'chart-after-menu-move');
      note('menu move stored', { salesman: await access(uids.salesman), chart: (await access(uids.chart)).assignedSalesmanCodes });
    });

    await t.step('the Move to... menu offers only supervisors that can take the salesperson', async () => {
      await s.page.getByRole('button', { name: 'Move E2E Salesperson to...' }).click();
      await s.page.getByRole('menuitem', { name: /E2E Supervisor/ }).first().waitFor({ timeout: 15000 });
      const offered = (await s.page.getByRole('menuitem').evaluateAll((nodes) => nodes.map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()))).filter(Boolean);
      await t.shot(s, 'menu-offers-only-open-supervisors');
      await s.page.keyboard.press('Escape');
      expectEqual(offered.some((label) => label.includes(FULL_SUPERVISOR.name)), false, 'full supervisor offered in the menu');
      expectEqual(offered.some((label) => label.includes(FAR_SUP.name)), false, 'other-branch supervisor offered in the menu');
      expectEqual(offered.some((label) => label.includes('E2E Supervisor')), true, 'open supervisor offered in the menu');
      await unchanged('after reading the menu');
      note('full and other-branch supervisors are not offered', { offered });
    });

    await t.step('dragging onto a full or other-branch supervisor is not accepted', async () => {
      await dragOnto('E2E Far Supervisor');
      await s.page.waitForTimeout(500);
      expectEqual(await s.page.getByText('Move E2E Salesperson?').count(), 0, 'confirmation after a drag onto another branch');
      await unchanged('after the other-branch drag');
      await dragOnto(`${FULL_SUPERVISOR.name}\\s+·`);
      await s.page.waitForTimeout(500);
      expectEqual(await s.page.getByText('Move E2E Salesperson?').count(), 0, 'confirmation after a drag onto a full supervisor');
      await unchanged('after the full-supervisor drag');
      note('drops on a full or other-branch supervisor are not accepted');
    });

    await t.step('dragging back onto the first supervisor moves the salesperson', async () => {
      await dragOnto('E2E Supervisor\\s+·\\s+SUP-E2E');
      await B.see(s.page, 'From E2E Chart Supervisor to E2E Supervisor.');
      await s.page.getByRole('button', { name: 'Move', exact: true }).click();
      await waitAccess(uids.salesman, (a) => a.supervisorUid === uids.supervisor, 'salesperson link after drag');
      await waitAccess(uids.supervisor, (a) => JSON.stringify(a.assignedSalesmanCodes) === '["S001"]', 'list after drag');
      await waitAccess(uids.chart, (a) => JSON.stringify(a.assignedSalesmanCodes) === '[]', 'chart list after drag');
      await B.see(s.page, /E2E Supervisor\s+·\s+SUP-E2E\s+·\s+1 of 5/);
      await t.shot(s, 'chart-after-drag-move');
      note('drag move stored', { salesman: await access(uids.salesman) });
    });

    await t.step('a branch manager has no move controls', async () => {
      const bm = await t.session('admin', { name: 'bm' });
      await B.loginAdmin(bm.page, bm.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(bm.page);
      await admin.goToPage(bm.page, 'Branch Team');
      await B.see(bm.page, 'E2E Branch Manager (you)');
      expectEqual(await bm.page.getByRole('button', { name: /^Move .* to\.\.\.$/ }).count(), 0, 'move buttons for a branch manager');
      note('branch manager tree stays read-only');
    });

    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
  },
};
