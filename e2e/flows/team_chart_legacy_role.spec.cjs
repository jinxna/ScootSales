'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'team_chart_legacy_role');
const LEGACY_ROLE = 'Sales Representative';
const CHART_SUP = { email: 'e2e.legacy.sup@example.test', name: 'E2E Legacy Target Supervisor', role: 'supervisor', code: 'SUP-LT' };
const ON_ROSTER = { email: 'e2e.legacy.one@example.test', name: 'E2E Legacy Rep One', role: 'salesman', code: 'SR1' };
const NO_TEAM = { email: 'e2e.legacy.two@example.test', name: 'E2E Legacy Rep Two', role: 'salesman', code: 'SR2' };

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'team_chart_legacy_role',
  async run(t) {
    const { db, accounts, seed } = t;
    const evidence = { project: E.PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const uids = {};
    let s;

    const legacyProfile = async (person) => {
      const profile = await db.get('users', person.email);
      await db.put('users', person.email, { ...profile, role: LEGACY_ROLE, user_group: LEGACY_ROLE, supervisorId: '', supervisor_id: '' });
    };
    const reportsTo = async (person, expected) => {
      const label = `${person.name}, Salesman`;
      await B.see(s.page, label);
      const rowText = await s.page.evaluate(({ label: wanted, email }) => {
        const rows = [...document.querySelectorAll('flt-semantics')]
          .map((node) => node.textContent || '')
          .filter((text) => text.includes(wanted) && text.includes(email))
          .sort((a, b) => a.length - b.length);
        return rows[0] || '';
      }, { label, email: person.email });
      if (!new RegExp(`Salesman\\s*${expected}`).test(rowText)) throw new Error(`Users row for ${person.name} reads "${rowText}", expected Reports to "${expected}"`);
    };
    const moveTo = async (person, target) => {
      await s.page.getByRole('button', { name: `Move ${person.name} to...` }).click();
      await s.page.getByRole('menuitem', { name: new RegExp(target.name) }).click();
      await B.see(s.page, `Move ${person.name}?`);
      await t.shot(s, `confirm-${person.code.toLowerCase()}`);
      await s.page.getByRole('button', { name: 'Move', exact: true }).click();
      await B.see(s.page, `${person.name} now reports to ${target.name}.`);
    };
    const rosterHolders = async (code) => {
      const holders = [];
      for (const collection of ['users', 'user_access']) {
        for (const row of await db.list(collection)) {
          const codes = Array.isArray(row.assignedSalesmanCodes) ? row.assignedSalesmanCodes : [];
          if (codes.includes(code)) holders.push(`${collection}/${row.employeeCode || row._id || row.id}`);
        }
      }
      return holders.sort();
    };

    await t.step('seed two salespeople stored with the older role spelling, one on a roster in lower case', async () => {
      uids.supervisor = (await db.waitForQuery('user_access', (a) => a.employeeCode === accounts.supervisor.code)).uid;
      uids.target = await putPerson(db, { ...CHART_SUP, branch: seed.branch.id });
      uids.onRoster = await putPerson(db, { ...ON_ROSTER, branch: seed.branch.id });
      uids.noTeam = await putPerson(db, { ...NO_TEAM, branch: seed.branch.id });
      await legacyProfile(ON_ROSTER);
      await legacyProfile(NO_TEAM);
      const supervisorProfile = await db.get('users', accounts.supervisor.email);
      const supervisorAccess = await db.get('user_access', uids.supervisor);
      const roster = [accounts.salesman.code, ON_ROSTER.code.toLowerCase()];
      await db.put('users', accounts.supervisor.email, { ...supervisorProfile, assignedSalesmanCodes: roster });
      await db.put('user_access', uids.supervisor, { ...supervisorAccess, assignedSalesmanCodes: roster });
      expectEqual((await db.get('users', ON_ROSTER.email)).role, LEGACY_ROLE, 'stored role of the rostered salesperson');
      expectEqual((await db.get('users', NO_TEAM.email)).role, LEGACY_ROLE, 'stored role of the salesperson with no team');
      note('seeded', { roster, legacyRole: LEGACY_ROLE });
    });

    await t.step('admin opens Users and sees both people by name in the table and the Team chart', async () => {
      s = await t.session('admin', { viewport: { width: 1600, height: 1700 } });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Users');
      await B.see(s.page, 'Team chart');
      await t.shot(s, 'users-before');
      await B.see(s.page, /E2E Legacy Rep One\s+·\s+SR1/);
      expectEqual(await B.semantic(s.page, /E2E Legacy Rep One\s+·\s+sr1/).count(), 0, 'chart rows that show the roster spelling instead of the profile code');
      await B.see(s.page, /E2E Legacy Rep Two\s+·\s+SR2/);
      expectEqual(await s.page.getByText(/no visible profile/).count(), 0, 'chart rows without a visible profile');
      await reportsTo(ON_ROSTER, 'Not linked');
      await reportsTo(NO_TEAM, 'Not linked');
      note('both people show by name in the chart and as salespeople in the table');
    });

    await t.step('admin moves each person to the target supervisor with the move button', async () => {
      await moveTo(ON_ROSTER, CHART_SUP);
      await db.waitForDoc('user_access', uids.onRoster, (a) => a.supervisorUid === uids.target, { label: 'rostered link', timeout: 30000 });
      await moveTo(NO_TEAM, CHART_SUP);
      await db.waitForDoc('user_access', uids.noTeam, (a) => a.supervisorUid === uids.target, { label: 'no-team link', timeout: 30000 });
      await B.see(s.page, /E2E Legacy Target Supervisor\s+·\s+SUP-LT\s+·\s+2 of 5/);
      await t.shot(s, 'chart-after-moves');
    });

    await t.step('the stored records hold the new link and only the target rosters hold the codes', async () => {
      for (const person of [ON_ROSTER, NO_TEAM]) {
        const profile = await db.get('users', person.email);
        expectEqual([profile.supervisorId, profile.supervisorUid], [CHART_SUP.code, uids.target], `${person.code} profile link`);
        expectEqual(profile.role, LEGACY_ROLE, `${person.code} stored role unchanged`);
        const holders = await rosterHolders(person.code);
        expectEqual(holders, ['user_access/SUP-LT', 'users/SUP-LT'], `${person.code} roster holders`);
        await reportsTo(person, CHART_SUP.code);
      }
      expectEqual((await db.get('users', accounts.supervisor.email)).assignedSalesmanCodes, [accounts.salesman.code], 'old supervisor profile roster');
      expectEqual((await db.get('user_access', uids.supervisor)).assignedSalesmanCodes, [accounts.salesman.code], 'old supervisor access roster');
      await t.shot(s, 'users-after');
      note('links and rosters stored', { target: (await db.get('user_access', uids.target)).assignedSalesmanCodes });
    });

    fs.mkdirSync(OUT, { recursive: true });
    fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
  },
};
