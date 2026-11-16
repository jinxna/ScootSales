'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'copilot_rank_why');
const WEEK = '2026-W43';
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const CHOICE = RETAILERS[0];
const EMART = RETAILERS[1];

function row(retailerId, retailerName, rank, extra) {
  return {
    retailerId, retailerName, rank,
    expectedOrderValueRm: 0, opportunityPerRouteDay: 0, routeTimeDays: 0.1,
    travelMinutes: 0, serviceMinutes: 0, daysSinceLastVisit: null,
    chosen: true, exploitOrExplore: 'exploit', selectionProbability: 1,
    coverageBasis: 'last_observed_order', forecastPairCount: 4, observedBaselinePairCount: 4,
    ...extra,
  };
}

function ranking(id, { salesmanUid, salesmanCode, branchId, weekKey, generatedAt, rows, isDemo = false }) {
  return {
    rankingId: id, scopeKey: `salesman:${salesmanCode}`, salesmanUid, salesmanCode, branchId,
    weekKey, status: 'active', policyVersion: 'route-policy/1.0.0', rankingVersion: 'ranking/1.0.0',
    expectedOrderValueVersion: 'expected-order-value/1.0.0', coverageBasis: 'last_observed_order',
    targetSize: 2, retailerCount: rows.length, chosenCount: rows.filter((r) => r.chosen).length,
    isDemo, generatedAt, ranking: rows, decisionLog: [],
  };
}

module.exports = {
  name: 'copilot_rank_why',
  async run(t) {
    const { db, accounts, seed } = t;
    const answers = [];
    let s;
    const page = () => s.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const ask = async (who, text, re) => {
      const before = await find(re).count();
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
      const end = Date.now() + 30000;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) {
          const seen = await find(re).last().evaluate((n) => n.getAttribute('aria-label') || n.textContent);
          answers.push({ who, asked: text, seen });
          return;
        }
        await page().waitForTimeout(150);
      }
      throw new Error(`after "${text}" expected ${re}`);
    };
    const see = (re) => B.see(page(), re);
    const openCopilot = () => page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
    const saveAnswers = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'answers.json'), `${JSON.stringify(answers, null, 2)}\n`);
    };

    if (process.env.E2E_FIREBASE_TARGET === 'hardware') {
      await t.step('hardware client: Scout says no ranking is published', async () => {
        s = await t.session('admin', { name: 'admin' });
        await B.loginAdmin(page(), s.url, accounts.admin.email);
        await admin.waitForShell(page());
        await openCopilot();
        await ask('admin', `why is ${CHOICE.name} top priority?`,
          /No retailer ranking is published for the salespeople you can see yet/);
        await t.shot(s, 'hardware-no-ranking');
      });
      saveAnswers();
      return;
    }

    await t.step('seed rankings: S001 newest, S001 older, S001 demo, outside S909', async () => {
      const now = Date.now();
      const s001 = { salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: accounts.salesman.branch };
      await db.put('retailer_priority_rankings', 'rank-s001-new', ranking('rank-s001-new', {
        ...s001, weekKey: WEEK, generatedAt: new Date(now - 3600e3),
        rows: [
          row(CHOICE.id, CHOICE.name, 1, {
            expectedOrderValueRm: 120, opportunityPerRouteDay: 1200, travelMinutes: 30, serviceMinutes: 18, daysSinceLastVisit: 9,
            components: { expectedValueRm: 120, adjustedValueRm: 138, travelMinutes: 30, serviceMinutes: 18, routeTimeDays: 0.1, coverageBoost: 0.05, adjustedScore: 1449 },
          }),
          row(EMART.id, EMART.name, 2, {
            exploitOrExplore: 'explore', selectionProbability: 0.35,
            expectedOrderValueRm: 80, opportunityPerRouteDay: 800, travelMinutes: 20, serviceMinutes: 28,
            components: { expectedValueRm: 80, adjustedValueRm: 96, travelMinutes: 20, serviceMinutes: 28, routeTimeDays: 0.1, coverageBoost: 0.1, adjustedScore: 1056 },
          }),
          row('ret-plain', 'Kedai Tiada Komponen', 3, { chosen: false, exploitOrExplore: 'not_selected', selectionProbability: 0, opportunityPerRouteDay: 500 }),
        ],
      }));
      await db.put('retailer_priority_rankings', 'rank-s001-old', ranking('rank-s001-old', {
        ...s001, weekKey: '2026-W40', generatedAt: new Date(now - 21 * 86400e3),
        rows: [row(CHOICE.id, CHOICE.name, 5, { components: { adjustedValueRm: 1, routeTimeDays: 0.1, adjustedScore: 10 } })],
      }));
      await db.put('retailer_priority_rankings', 'rank-s001-demo', ranking('rank-s001-demo', {
        ...s001, weekKey: '2026-W44', generatedAt: new Date(now), isDemo: true,
        rows: [row(CHOICE.id, CHOICE.name, 9, { components: { adjustedValueRm: 1, routeTimeDays: 0.1, adjustedScore: 1 } })],
      }));
      await db.put('retailer_priority_rankings', 'rank-s909', ranking('rank-s909', {
        salesmanUid: 'uid-outside', salesmanCode: 'S909', branchId: 'B-OTHER', weekKey: WEEK, generatedAt: new Date(now - 3600e3),
        rows: [row('ret-out', 'Outside Mart', 1, { components: { expectedValueRm: 50, adjustedValueRm: 60, travelMinutes: 10, serviceMinutes: 14, routeTimeDays: 0.05, coverageBoost: 0, adjustedScore: 1200 } })],
      }));
    });

    await t.step('admin: top retailer explained step by step from the stored components', async () => {
      s = await t.session('admin', { name: 'admin' });
      await B.loginAdmin(page(), s.url, accounts.admin.email);
      await admin.waitForShell(page());
      await openCopilot();
      await ask('admin', `why is ${CHOICE.name} top priority?`,
        new RegExp(`${esc(CHOICE.name)} is #1 of 3 for salesperson S001 in week ${WEEK}\\. The policy selected it on its score\\.`));
      for (const line of [
        `Why ${CHOICE.name} is #1`,
        'Expected order value: RM120.00',
        'Plus uncertainty allowance: RM18.00 = RM138.00',
        'Route time: 30 min travel + 18 min visit = 0.100 route-days',
        'Adjusted value per route-day: RM138.00 / 0.100 = RM1380.00',
        'Coverage boost: +5.0% (9 days since last contact)',
        'Ranking score: 1449.00 -> rank #1',
        'The rank order uses the ranking score',
      ]) {
        await see(new RegExp(esc(line)));
      }
      await t.shot(s, 'why-choice');
    });

    await t.step('admin: exploration pick named with its selection probability', async () => {
      await ask('admin', `why is ${EMART.name.toLowerCase()} number 1?`,
        /Emart Moyan is #2 of 3 for salesperson S001[^]*exploration pick[^]*selection probability of 35%/);
      await see(/Ranking score: 1056\.00 -> rank #2 \(exploration pick\)/);
      await see(/Coverage boost: \+10\.0% \(no contact on record\)/);
      await t.shot(s, 'why-emart');
    });

    await t.step('admin: a row without components says so; outside salesperson visible; item questions untouched', async () => {
      await ask('admin', 'why is Kedai Tiada Komponen ranked first',
        /Kedai Tiada Komponen is #3 of 3[^]*not selected for this week[^]*stores no score breakdown[^]*RM500\.00 per route-day/);
      await ask('admin', 'why is Outside Mart top priority', /Outside Mart is #1 of 1 for salesperson S909/);
      await ask('admin', 'why is item 2 top priority', /Ask "what needs my attention today" first/);
    });

    await t.step('supervisor: only the assigned salesperson\'s ranking', async () => {
      s = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(page(), s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(page());
      await openCopilot();
      await ask('supervisor', `why is ${CHOICE.name} number 1`, new RegExp(`${esc(CHOICE.name)} is #1 of 3 for salesperson S001`));
      await see(/Ranking score: 1449\.00 -> rank #1/);
      await ask('supervisor', 'why is Outside Mart top priority',
        /"Outside Mart" is not in the current ranking of the salespeople you can see/);
      await t.shot(s, 'supervisor-scope');
    });

    await t.step('branch manager: only the own branch\'s ranking', async () => {
      s = await t.session('admin', { name: 'branch-manager' });
      await B.loginAdmin(page(), s.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(page());
      await openCopilot();
      await ask('branch manager', `why is ${EMART.name} top priority`, /Emart Moyan is #2 of 3 for salesperson S001/);
      await ask('branch manager', 'why is outside mart top priority',
        /"outside mart" is not in the current ranking of the salespeople you can see/);
    });

    saveAnswers();
  },
};
