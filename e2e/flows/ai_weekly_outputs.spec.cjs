'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const { RETAILERS, PRODUCTS, putPerson } = require('../lib/seed.cjs');

const ROOT = path.resolve(__dirname, '..', '..');
const OUT = path.join(E.OUTPUT_DIR, 'ai_weekly_outputs');
const RUNNER_PROJECT = 'demo-fyp-a';
const OUTPUT_COLLECTIONS = ['retailer_priority_rankings', 'visit_briefs', 'ai_insights', 'retailer_memory', 'weekly_ai_summaries'];
const WIDE = { width: 2000, height: 1100 };
const RETAILER = RETAILERS[0];
const DAY_MS = 86400000;
const UNRANKED = { email: 'e2e.sales0@example.test', name: 'E2E New Salesperson', role: 'salesman', code: 'S000', branch: 'B1' };
const NOT_SET_UP = /forecasting is not set up/i;

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function runRunner() {
  const result = spawnSync(
    process.env.E2E_PYTHON || (process.platform === 'win32' ? 'python' : 'python3'),
    ['-m', 'forecasting.ai_service.cli', '--project', 'demo', '--apply', '--confirm', `APPLY-${RUNNER_PROJECT}`],
    { cwd: ROOT, encoding: 'utf8', windowsHide: true, env: { ...process.env, PYTHONWARNINGS: 'ignore', PYTHONIOENCODING: 'utf-8' } },
  );
  const lines = result.stdout.split('\n').filter((line) => line.startsWith('{')).map((line) => JSON.parse(line));
  const completed = lines.find((line) => line.event === 'ai_runner_completed');
  if (result.status !== 0 || !completed) {
    throw new Error(`the runner failed (exit ${result.status}):\n${result.stderr || result.stdout}`);
  }
  return completed;
}

async function snapshot(db) {
  const out = {};
  for (const name of [...OUTPUT_COLLECTIONS, 'ai_runs']) out[name] = (await db.list(name)).map((row) => row.id).sort();
  return out;
}

async function openRetailerWindow(page, label) {
  await B.see(page, RETAILER.name, { timeout: 30000 });
  const button = page.getByRole('button', { name: `${label} ${RETAILER.name}`, exact: true });
  await button.first().waitFor({ timeout: 30000 });
  await page.waitForTimeout(800);
  await button.first().click();
}

module.exports = {
  name: 'ai_weekly_outputs',
  async run(t) {
    const { db, accounts, seed } = t;
    const runnerDb = E.client(RUNNER_PROJECT);
    const evidence = { runnerProject: RUNNER_PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const save = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'runner-evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    };

    let reachable = true;
    await runnerDb.reset().catch(() => { reachable = false; });
    if (reachable) await runnerDb.put('orders', 'probe', { probe: true }).catch(() => { reachable = false; });
    if (!reachable) {
      console.log('  skipped: needs a second Firebase project in the emulator (firebase.e2e.alt.json, see e2e/README.md)');
      return;
    }
    await runnerDb.reset();

    let route;
    let planner;
    let firstRun;
    let briefs;
    let rankings;
    let insights;
    let memory;
    let supervisor;
    const { forecastingUrl, ...servicesWithoutForecasting } = platform.SERVICES;
    const workspace = JSON.stringify(platform.signRecord({ ...platform.harnessRecord(), services: servicesWithoutForecasting }, platform.ensureKey()));
    let workspaceReads = 0;
    const openDashboard = async (name) => {
      const s = await t.session('admin', { name, viewport: WIDE });
      await s.context.route('**/workspace.json', (route) => {
        workspaceReads += 1;
        return route.fulfill({ contentType: 'application/json', body: workspace });
      });
      return s;
    };
    const shown = async (page) => (await admin.semanticsLines(page)).join('\n');
    const pickSalesman = async (page, name) => {
      await page.getByRole('button', { name: 'Plan', exact: true }).click();
      await admin.pickDropdown(page, /E2E (New )?Salesperson/, name);
      await page.getByRole('button', { name: 'Priorities', exact: true }).click();
    };
    try {
      await t.step('seed the retailer history, outcomes and people the runner reads', async () => {
        const monday = new Date();
        monday.setUTCHours(2, 0, 0, 0);
        monday.setUTCDate(monday.getUTCDate() - ((monday.getUTCDay() + 6) % 7));
        for (const collection of ['users', 'retailers', 'products']) {
          for (const row of await db.list(collection)) {
            const { id, ...data } = row;
            await runnerDb.put(collection, id, data);
          }
        }
        const price = Object.fromEntries(PRODUCTS.map((p) => [p.id, p.price]));
        let n = 0;
        for (let k = 1; k <= 9; k += 1) {
          const when = new Date(monday.getTime() - k * 7 * DAY_MS + 2 * DAY_MS);
          const plan = [[RETAILER.id, 'prod-1', 6 + (k % 3)], [RETAILERS[1].id, 'prod-1', 4]];
          if (k >= 5) plan.push([RETAILER.id, 'prod-2', 5]);
          if (k % 2 === 0) plan.push([RETAILERS[1].id, 'prod-3', 8]);
          for (const [retailerId, productId, qty] of plan) {
            n += 1;
            await runnerDb.put('orders', `ord-hist-${n}`, {
              orderId: `ord-hist-${n}`, retailerId, status: 'approved', submittedAt: when,
              salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: 'B1',
              items: [{ productId, qty, price: price[productId] }],
            });
          }
        }
        const outcomes = [
          [RETAILER.id, 'price_too_high', 'prod-2', 'Owner said the competitor undercut our price on this line.', 3],
          [RETAILER.id, 'competitor_promotion', 'prod-2', 'A rival brand ran a buy two get one free promotion in store.', 4],
        ];
        for (const [i, [retailerId, reasonCode, productId, text, daysAgo]] of outcomes.entries()) {
          const submittedAt = new Date(Date.now() - daysAgo * DAY_MS);
          const doc = {
            outcomeId: `outcome-hist-${i}`, salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: 'B1',
            retailerId, reasonCode, note: text, productId, issueKey: `low_sell_through:${productId}`, submittedAt, clientCreatedAt: submittedAt,
          };
          await runnerDb.put('conversation_outcomes', doc.outcomeId, doc);
          await db.put('conversation_outcomes', doc.outcomeId, doc);
        }
        note('seeded', { orders: n, outcomes: outcomes.length, demoFlagged: false });
      });

      await t.step('the runner applies and records a completed run with rankings, briefs, insights and memory', async () => {
        firstRun = runRunner();
        const runs = await runnerDb.list('ai_runs');
        expectEqual(runs.filter((r) => r.status === 'completed').length, 1, 'completed ai_runs');
        const counts = await snapshot(runnerDb);
        for (const name of OUTPUT_COLLECTIONS) {
          if (!counts[name].length) throw new Error(`the runner wrote no ${name}`);
        }
        note('first run', { counts: Object.fromEntries(Object.entries(counts).map(([k, v]) => [k, v.length])), summary: { visitBriefs: firstRun.visitBriefs, retailerMemory: firstRun.retailerMemory, rankings: firstRun.retailerPriorityRankings } });
      });

      await t.step('a second run changes no document count and adds no duplicate', async () => {
        const before = await snapshot(runnerDb);
        runRunner();
        const after = await snapshot(runnerDb);
        for (const name of OUTPUT_COLLECTIONS) expectEqual(after[name], before[name], `${name} document ids`);
        expectEqual(after.ai_runs.length, before.ai_runs.length + 1, 'ai_runs after a second run');
        note('second run', { sameIds: true });
      });

      await t.step('the run output is real, not demo, and is copied to the company project', async () => {
        for (const name of OUTPUT_COLLECTIONS) {
          for (const row of await runnerDb.list(name)) {
            if (row.isDemo === true) throw new Error(`${name}/${row.id} is demo-flagged`);
            const { id, ...data } = row;
            await db.put(name, id, data);
          }
        }
        briefs = (await db.list('visit_briefs')).filter((b) => b.retailerId === RETAILER.id && b.salesmanUid === seed.uids.salesman);
        rankings = (await db.list('retailer_priority_rankings')).filter((r) => r.salesmanUid === seed.uids.salesman);
        if (!briefs.length) throw new Error(`no visit brief for ${RETAILER.id}`);
        if (!rankings.length) throw new Error('no ranking for the salesperson');
        const ids = rankings.flatMap((r) => r.ranking.map((row) => row.retailerId));
        if (!ids.includes(RETAILER.id)) throw new Error(`the ranking does not list ${RETAILER.id}: ${ids}`);
        for (const row of await runnerDb.list('ai_runs')) {
          const { id, ...data } = row;
          await db.put('ai_runs', id, data);
        }
        insights = (await db.list('ai_insights')).filter((i) => i.salesmanCode === accounts.salesman.code && i.reason);
        memory = await db.get('retailer_memory', RETAILER.id);
        if (!insights.length) throw new Error('no sales insight with a reason for the salesperson');
        if (!memory || !memory.outcomeCount) throw new Error(`no retailer memory with outcomes for ${RETAILER.id}`);
        note('copied', { briefId: briefs[0].id, rankingIds: rankings.map((r) => r.id), rankedRetailers: ids });
      });

      await t.step('phone: the guided visit shows the visit brief and the retailer memory', async () => {
        const uid = seed.uids.salesman;
        const now = new Date();
        const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
        await db.put('route_plans', 'plan-ai-weekly', {
          planId: 'plan-ai-weekly', createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
          salesmanName: accounts.salesman.name, branchId: 'B1',
          weekStart: new Date(noon.getTime() - 6 * DAY_MS), weekEnd: new Date(noon.getTime() + DAY_MS),
          publishedAt: now, status: 'published', source: 'dashboard', totalStops: 1, stopIds: ['stop-1'],
          stopRetailerIds: { 'stop-1': RETAILER.id },
          days: [{
            dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 3.5,
            stops: [{
              stopId: 'stop-1', dayId: 'day-1', retailerId: RETAILER.id, retailerName: RETAILER.name, address: `${RETAILER.area}, Kuching`,
              lat: RETAILER.lat, lng: RETAILER.lng, sequence: 1, estimatedArrival: '09:00', estimatedDeparture: '09:20',
              priorityReason: 'E2E fixture', status: 'not_started', travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
            }],
          }],
        });
        const profile = await db.get('users', accounts.salesman.email);
        await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });

        route = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
        await B.fakeGeolocation(route.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
        await B.loginMobile(route.page, route.url, accounts.salesman.email);
        await mobile.waitForHome(route.page);
        await mobile.openAssignedRoute(route.page);
        await B.see(route.page, RETAILER.name);
        await mobile.acceptAndStartRoute(route.page);
        await mobile.selectStop(route.page);
        const brief = briefs[0];
        const attention = brief.routeIntelligence;
        if (!attention) throw new Error('the brief has no route priority');
        await B.see(route.page, `${attention.priority.toUpperCase()} • ${attention.attentionScore}/100`, { timeout: 30000 });
        await B.see(route.page, 'Sales Visit Scout', { timeout: 30000 });
        await route.page.mouse.move(215, 600);
        await route.page.mouse.wheel(0, 480);
        await route.page.waitForTimeout(800);
        await t.shot(route, 'route-stop-brief-card');
        await route.page.mouse.wheel(0, -3000);
        await route.page.waitForTimeout(500);
        const open = route.page.getByRole('button', { name: 'Open visit', exact: true }).first();
        await B.scrollIntoView(route.page, open, { minHeight: 20, pointerY: 0.8 });
        await open.click();
        await B.see(route.page, 'Retailer memory', { timeout: 30000 });
        await B.see(route.page, /2 outcome\(s\)/, { timeout: 30000 });
        await B.see(route.page, /price too high/);
        await B.see(route.page, "Today's focus");
        const focus = (brief.focusItems || [])[0];
        const expected = focus ? (focus.signal || focus.title || focus.productName) : brief.emptyStateHeadline;
        if (!expected) throw new Error('the brief has neither a focus item text nor an empty-state headline');
        await B.see(route.page, expected.slice(0, 60), { timeout: 30000 });
        const restock = (brief.replenishment || []).find((row) => row.suggestedQty != null);
        if (!restock || !restock.productName) throw new Error('the brief has no replenishment row with a product name');
        await B.see(route.page, restock.productName, { timeout: 30000 });
        await t.shot(route, 'guided-visit-brief-and-memory');
        note('phone', { retailer: RETAILER.name, memoryShown: '2 outcome(s), price too high', briefTextShown: expected.slice(0, 60), priorityShown: `${attention.priority} ${attention.attentionScore}/100`, replenishmentShown: restock.productName });
      });

      await t.step('dashboard route planner, company without a forecasting address: a salesman with no ranking is named and the Salesman box is pointed to', async () => {
        if (!forecastingUrl || workspace.includes('forecastingUrl')) throw new Error('the workspace record still has a forecasting address');
        await putPerson(db, UNRANKED);
        planner = await openDashboard('planner');
        await B.loginAdmin(planner.page, planner.url, accounts.admin.email);
        await admin.waitForShell(planner.page);
        if (!workspaceReads) throw new Error('the dashboard did not read the workspace record without a forecasting address');
        await planner.page.getByRole('button', { name: 'Route Planner', exact: true }).first().click();
        await pickSalesman(planner.page, UNRANKED.name);
        await B.see(planner.page, `No ranking for ${UNRANKED.name} yet`, { timeout: 30000 });
        await B.see(planner.page, /choose one in the Salesman box on the Plan tab/);
        const text = await shown(planner.page);
        if (NOT_SET_UP.test(text)) throw new Error(`the planner says forecasting is not set up:\n${text}`);
        await t.shot(planner, 'planner-salesman-without-ranking');
        note('planner without ranking', { forecastingUrl: false, workspaceReads, salesman: UNRANKED.name, notSetUpShown: false });
      });

      await t.step('dashboard route planner: the weekly priority panel shows the ranked list, not the legacy note', async () => {
        await pickSalesman(planner.page, accounts.salesman.name);
        await B.see(planner.page, `This week's priorities for ${accounts.salesman.name}`, { timeout: 30000 });
        await B.see(planner.page, /Ranked by expected order-value opportunity per route-day/, { timeout: 30000 });
        await B.see(planner.page, new RegExp(`week ${rankings[0].weekKey}`));
        await B.see(planner.page, RETAILER.name);
        const text = await planner.page.evaluate(() => [...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || n.textContent || '').join('\n'));
        if (/legacy 0\.\.1 composite|No RM\/day ranking has been published/.test(text)) throw new Error('the legacy note is shown');
        if (NOT_SET_UP.test(text)) throw new Error(`the planner says forecasting is not set up:\n${text}`);
        await t.shot(planner, 'planner-weekly-priorities');
        note('planner', { weekKey: rankings[0].weekKey, legacyNote: false });
      });

      await t.step('dashboard Scout, company without a forecasting address: it explains the rank of a retailer', async () => {
        const copilot = await openDashboard('copilot');
        await B.loginAdmin(copilot.page, copilot.url, accounts.admin.email);
        await admin.waitForShell(copilot.page);
        await copilot.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
        const question = `why is ${RETAILER.name} top priority?`;
        await B.fillField(copilot.page, copilot.page.getByRole('textbox').last(), question);
        await copilot.page.keyboard.press('Enter');
        const answer = `${RETAILER.name} is #${rankings[0].ranking.find((row) => row.retailerId === RETAILER.id).rank} of ${rankings[0].ranking.length} for salesperson ${accounts.salesman.code} in week ${rankings[0].weekKey}`;
        await B.see(copilot.page, answer, { timeout: 30000 });
        const text = await shown(copilot.page);
        if (NOT_SET_UP.test(text) || /There is no retailer ranking to explain/.test(text)) throw new Error(`Scout refused to explain the rank:\n${text}`);
        await t.shot(copilot, 'copilot-explains-rank');
        note('copilot', { asked: question, answered: answer });
      });

      await t.step('dashboard retailers: the Memory window shows the snapshot from the weekly run', async () => {
        await admin.goToPage(planner.page, 'Retailers');
        await openRetailerWindow(planner.page, 'Memory');
        await B.see(planner.page, `Retailer memory — ${RETAILER.name}`, { timeout: 30000 });
        await B.see(planner.page, /AI memory snapshot \(from the last AI update\)/, { timeout: 30000 });
        await B.see(planner.page, `${memory.outcomeCount} outcome(s)`);
        await B.see(planner.page, /Price too high/i);
        await B.see(planner.page, /Weekly insights · updated/);
        const issueProduct = PRODUCTS.find((p) => p.id === 'prod-2').name;
        await B.see(planner.page, `Low Sell Through · ${issueProduct} — Price Too High`);
        const shown = (await admin.semanticsLines(planner.page)).join('\n');
        if (/low_sell_through|prod-2|Offline insights/.test(shown)) throw new Error(`the Memory window shows a raw key or the old chip wording:\n${shown}`);
        await t.shot(planner, 'retailers-memory-window');
        await planner.page.keyboard.press('Escape');
        note('retailers memory', { retailer: RETAILER.name, outcomeCount: memory.outcomeCount, source: 'retailer_memory', issueShown: `Low Sell Through · ${issueProduct}`, chip: 'Weekly insights' });
      });

      await t.step('dashboard retailers: the Replenishment window names the restock product from the brief, also when it left the catalogue', async () => {
        const restock = (briefs[0].replenishment || []).find((row) => row.suggestedQty != null && row.productName);
        if (!restock) throw new Error('the brief has no replenishment row with a product name');
        const product = await db.get('products', restock.productId);
        await db.del('products', restock.productId);
        try {
          await openRetailerWindow(planner.page, 'Replenishment');
          await B.see(planner.page, `Replenishment — ${RETAILER.name}`, { timeout: 30000 });
          await B.see(planner.page, 'AI visit brief', { timeout: 30000 });
          await B.see(planner.page, /Suggested \d+/, { timeout: 30000 });
          await t.shot(planner, 'retailers-replenishment-window');
          await B.see(planner.page, restock.productName);
          await B.see(planner.page, /Weekly insights · updated/);
          await planner.page.keyboard.press('Escape');
        } finally {
          await db.put('products', restock.productId, product);
        }
        note('retailers replenishment', { retailer: RETAILER.name, productShown: restock.productName, productInCatalogue: false });
      });

      await t.step('dashboard reports: the Weekly AI tab shows the weekly summary and the insight counts', async () => {
        await admin.goToPage(planner.page, 'Reports');
        await planner.page.getByRole('tab', { name: /Weekly AI/ }).click();
        await B.see(planner.page, /^Week of /, { timeout: 30000 });
        await B.see(planner.page, /Unresolved insights/);
        await B.see(planner.page, /Based on the [1-9]\d* insight\(s\) currently visible/, { timeout: 30000 });
        await t.shot(planner, 'reports-weekly-ai');
        note('weekly ai', { insights: insights.length });
      });

      await t.step('supervisor Action Center: the sales insights for the team are listed with their reason', async () => {
        supervisor = await openDashboard('supervisor');
        await B.loginAdmin(supervisor.page, supervisor.url, accounts.supervisor.email);
        await admin.waitForSupervisorShell(supervisor.page);
        await admin.goToPage(supervisor.page, 'Action Center');
        await B.see(supervisor.page, 'Supervisor Action Center', { timeout: 30000 });
        const insight = insights.find((i) => i.retailerId === RETAILER.id) || insights[0];
        await B.see(supervisor.page, insight.reason.slice(0, 60), { timeout: 30000 });
        await B.see(supervisor.page, `${insight.retailerName} - `);
        await t.shot(supervisor, 'supervisor-action-center-insights');
        note('action center', { insightId: insight.id, retailer: insight.retailerName, reasonShown: insight.reason.slice(0, 60) });
      });
    } finally {
      save();
    }
  },
};
