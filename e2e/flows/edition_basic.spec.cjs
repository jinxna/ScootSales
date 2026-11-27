'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const fake = require('../lib/copilot_server.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'edition_basic');
const fragment = (page) => new URL(page.url()).hash;
function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'edition_basic',
  async run(t) {
    if (process.env.E2E_EDITION !== 'basic') {
      console.log('  skipped: needs a basic build (E2E_EDITION=basic, see the header of this file)');
      return;
    }
    const { db, accounts, seed } = t;
    const evidence = { edition: 'basic', checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const saveEvidence = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'dashboard.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    };

    async function deepLink(s, key, shell) {
      await s.page.evaluate((k) => { window.history.pushState(null, '', `#/${k}`); }, key);
      await s.page.reload();
      await B.enableSemantics(s.page);
      await shell(s.page);
      expectEqual(fragment(s.page), '#/dashboard', `fragment after the deep link #/${key}`);
      note('deep link falls back to the dashboard', { key, fragment: fragment(s.page) });
    }
    const buttons = (page, name) => page.getByRole('button', { name });
    const absent = async (loc, what) => expectEqual(await loc.count(), 0, what);

    let s;
    try {
      await t.step('seed forecast and AI data that the advanced edition would show', async () => {
        const now = new Date();
        await db.put('demand_forecasts', 'e2e-fc-1', {
          productId: 'prod-1', productName: 'E2E FORECAST PRODUCT', status: 'ok',
          changePercentage: 40, recommendedAction: 'Increase stock', forecastQuantity: 80,
          periodStart: '2026-10-26', forecastMonth: '2026-10', point: 80, referenceUnits: 40, generatedAt: now,
        });
        await db.put('ai_insights', 'e2e-insight-1', {
          issueId: 'e2e-insight-1', issueKey: 'e2e-insight-1', type: 'overdue_reorder',
          priority: 'high', status: 'new', autoState: 'active', confidence: 'high',
          salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: accounts.salesman.branch,
          retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
          reason: 'E2E overdue reorder', recommendation: 'Visit this week', generatedAt: now, updatedAt: now,
        });
        await db.put('dashboard_notifications', 'e2e-ntf-forecast', {
          type: 'forecast_completed', message: 'E2E forecast run finished', roleTarget: 'admin', createdAt: now,
        });
        await db.put('dashboard_notifications', 'e2e-ntf-ai', {
          type: 'ai_weekly_summary', message: 'E2E weekly AI summary ready', roleTarget: 'admin', createdAt: now,
        });
        await db.put('dashboard_notifications', 'e2e-ntf-import', {
          type: 'import_completed', message: 'E2E import finished', roleTarget: 'admin', createdAt: now,
        });
        await db.put('dashboard_preferences', seed.uids.admin, {
          selectedCards: ['orders_today', 'forecast_alerts', 'overdue_retailers'],
          cardOrder: ['forecast_alerts', 'orders_today', 'overdue_retailers', 'pending_orders', 'active_salesmen',
            'visits_today', 'revenue', 'action_items', 'salesman_summary'],
          defaultTimeframe: 'month',
        });
        await db.put('orders', 'e2e-ord-1', {
          orderId: 'e2e-ord-1', retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name, outlet: RETAILERS[0].name,
          branchId: 'B1', uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
          salesmanCode: accounts.salesman.code, status: 'submitted', totalProducts: 1, totalBoxes: 2, totalPrice: 56.24,
          items: [{ productId: 'prod-1', productName: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)', department: 'GROCERY', qty: 2, unitPrice: 28.12, shelfBatches: [] }],
          submittedAt: now, createdAt: now,
        });
        const lastOrder = new Date(now.getTime() - 20 * 86400000);
        for (let i = 1; i <= 6; i += 1) {
          await db.put('orders', `e2e-overdue-${i}`, {
            orderId: `e2e-overdue-${i}`, retailerId: `e2e-overdue-shop-${i}`, retailerName: `E2E Overdue Shop ${i}`,
            branchId: 'B1', uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
            salesmanCode: accounts.salesman.code, status: 'approved', totalProducts: 1, totalBoxes: 1, totalPrice: 10,
            items: [], submittedAt: lastOrder, createdAt: lastOrder,
          });
        }
      });

      await t.step('admin: the setup checklist has no "Prepare weekly insights" step', async () => {
        s = await t.session('admin');
        await B.loginAdmin(s.page, s.url, accounts.admin.email);
        await admin.waitForShell(s.page);
        await B.see(s.page, /of 9 done/);
        const more = s.page.getByRole('button', { name: /^(Show all|\d+ more open steps)$/ }).first();
        if (await more.count()) await more.click();
        await B.see(s.page, /Publish a first route/);
        await absent(B.semantic(s.page, /Prepare weekly insights/), 'Prepare weekly insights step');
        note('setup checklist', { steps: 9, prepareAiData: false });
      });

      await t.step('admin: sidebar offers no forecast page and no AI badge; Reports stays', async () => {
        await B.see(s.page, 'Reports');
        await absent(buttons(s.page, /^(Prediction|Demand Forecast|Trust & Impact)/), 'forecast sidebar entries');
        await absent(buttons(s.page, /^Notifications.*\d/), 'badge on Notifications');
        note('admin sidebar', { prediction: false, trustImpact: false, notificationsBadge: false });
      });

      await t.step('admin overview: the saved Forecast Alerts card is dropped and the editor does not offer it', async () => {
        await admin.goToPage(s.page, 'Dashboard');
        await B.see(s.page, /Orders/i);
        const overdueTile = await B.see(s.page, /Overdue Retailers: \d+\./, { timeout: 60000 });
        const overdueLabel = await overdueTile.evaluate((n) => n.getAttribute('aria-label') || n.textContent);
        const overdueShown = Number(/Overdue Retailers: (\d+)\./.exec(overdueLabel)[1]);
        if (overdueShown < 6) throw new Error(`Overdue Retailers shows ${overdueShown}, expected at least the 6 seeded overdue shops`);
        note('overdue retailers tile', { shown: overdueShown, seededOverdueShops: 6 });
        await absent(B.semantic(s.page, /Forecast Alerts/), 'Forecast Alerts card');
        await B.semantic(s.page, /^Edit dashboard$/).click();
        await s.page.getByRole('button', { name: 'Save layout' }).waitFor({ state: 'visible', timeout: 15000 });
        await B.see(s.page, 'Salesman Performance Summary');
        await absent(B.semantic(s.page, /Forecast Alerts/), 'Forecast Alerts in the editor');
        await t.shot(s, 'overview-editor');
        await s.page.getByRole('button', { name: 'Close', exact: true }).first().click();
        await s.page.getByRole('button', { name: 'Save layout' }).waitFor({ state: 'detached', timeout: 15000 });
        note('dashboard cards', { forecastAlerts: false, savedSelectionWithHiddenKeyLoaded: true });
      });

      await t.step('admin overview: no Forecast Highlights, Exception Control Tower or Management Action Center', async () => {
        await B.see(s.page, /Needs your decision/);
        await absent(B.semantic(s.page, /Forecast Highlights/), 'Forecast Highlights');
        await absent(B.semantic(s.page, /Exception Control Tower/), 'Exception Control Tower');
        await absent(B.semantic(s.page, /Management Action Center/), 'Management Action Center');
        await absent(B.semantic(s.page, /E2E FORECAST PRODUCT/), 'seeded forecast product');
        await t.shot(s, 'overview-expanded');
        note('overview panels', { forecastHighlights: false, exceptionControlTower: false, managementActionCenter: false });
      });

      await t.step('admin notifications: import events show, forecast and AI events do not', async () => {
        await admin.goToPage(s.page, 'Notifications');
        await B.see(s.page, /E2E import finished/);
        await absent(B.semantic(s.page, /E2E forecast run finished/), 'forecast event');
        await absent(B.semantic(s.page, /E2E weekly AI summary ready/), 'AI summary event');
        await t.shot(s, 'notifications');
        note('notification feed', { importShown: true, forecastShown: false, aiSummaryShown: false });
      });

      await t.step('admin reports: no Weekly Summary tab, Retailer Scorecard is the last tab, no Forecast note', async () => {
        await admin.goToPage(s.page, 'Reports');
        await B.see(s.page, 'Top retailers');
        await B.see(s.page, RETAILERS[0].name);
        await absent(B.semantic(s.page, /Forecast note/), 'Forecast note');
        await absent(s.page.getByRole('tab', { name: /Weekly Summary/ }), 'Weekly Summary tab');
        await s.page.getByRole('tab', { name: /Top Retailers/ }).click();
        await B.semantic(s.page, /Include rejected/).waitFor({ timeout: 10000 });
        await s.page.getByRole('tab', { name: /Data Hygiene/ }).click();
        await s.page.getByRole('tab', { name: /Retailer Scorecard/ }).click();
        await B.semantic(s.page, /Include rejected/).waitFor({ state: 'detached', timeout: 10000 });
        await t.shot(s, 'reports-scorecard');
        await s.page.getByRole('tab', { name: /Monthly Summary/ }).click();
        await B.semantic(s.page, /Include rejected/).waitFor({ timeout: 10000 });
        note('reports tabs', { weeklyAiTab: false, scorecardIsLastTab: true, forecastNote: false });
      });

      await t.step('admin route planner: no Priorities workspace, planning is unchanged', async () => {
        await s.page.getByRole('button', { name: 'Route Planner', exact: true }).first().click();
        await B.see(s.page, 'Saved plans');
        await B.see(s.page, /Coverage & health/);
        await absent(B.semantic(s.page, /^Priorities$/), 'Priorities workspace');
        await t.shot(s, 'route-planner');
        note('route planner', { priorities: false, savedPlans: true });
      });

      await t.step('admin command palette: "forecast" finds no forecast page', async () => {
        await admin.goToPage(s.page, 'Dashboard');
        await s.page.getByRole('button', { name: /Jump to a page/ }).first().click();
        await s.page.getByPlaceholder('Jump to a page…').focus();
        await s.page.keyboard.type('forecast');
        await B.see(s.page, /Import Centre/);
        await absent(B.semantic(s.page, /Demand Forecast|Prediction/), 'forecast page in the palette');
        await t.shot(s, 'palette');
        await s.page.keyboard.press('Escape');
        note('command palette', { forecastPage: false });
      });

      await t.step('admin Scout: no briefing suggestion; briefing and ranking questions are declined; no forecast page opens', async () => {
        const page = s.page;
        const find = (re) => page.getByLabel(re).or(page.getByText(re));
        const answers = [];
        const ask = async (text, re) => {
          const before = await find(re).count();
          await B.fillField(page, page.getByPlaceholder('Ask or say a command'), text);
          await page.keyboard.press('Enter');
          const end = Date.now() + 30000;
          while (Date.now() < end) {
            if ((await find(re).count()) > before) {
              const seen = await find(re).last().evaluate((n) => n.getAttribute('aria-label') || n.textContent);
              answers.push({ asked: text, seen });
              return seen;
            }
            await page.waitForTimeout(150);
          }
          throw new Error(`after "${text}" expected ${re}`);
        };
        await page.getByRole('button', { name: /^Scout(?:\s|$)/ }).first().click();
        await B.see(page, 'Scout panel');
        await B.see(page, 'Show orders waiting for approval');
        await absent(buttons(page, /^Daily briefing$/), 'Daily briefing suggestion');
        await ask('What needs my attention today?', /not in this edition/i);
        await ask(`why is ${RETAILERS[0].name} top priority?`, /not in this edition/i);
        const open = await ask('open demand forecast',
          /^(Opened .+\.|I did not understand that.*|This account cannot open that page\.)/);
        if (/Opened (Prediction|Demand Forecast|Trust)/.test(open)) throw new Error(`Scout opened a hidden page: ${open}`);
        if (/^#\/(prediction|trust_impact)/.test(fragment(page))) throw new Error(`fragment is ${fragment(page)}`);
        await t.shot(s, 'copilot');
        note('copilot', { answers });
      });

      await t.step('admin: deep links to hidden pages land on the dashboard', async () => {
        for (const key of ['prediction', 'trust_impact', 'weekly_ai_summary']) {
          await deepLink(s, key, admin.waitForShell);
        }
        await t.shot(s, 'admin-deep-link');
      });

      let sup;
      await t.step('supervisor: sidebar has no Action Center, Weekly Summary or Demand Forecast', async () => {
        sup = await t.session('admin', { name: 'supervisor' });
        await B.loginAdmin(sup.page, sup.url, accounts.supervisor.email);
        await admin.waitForSupervisorShell(sup.page);
        await B.see(sup.page, 'Team Orders');
        await absent(buttons(sup.page, /^(Action Center|Weekly Summary|Demand Forecast)/), 'AI entries in the supervisor sidebar');
        await t.shot(sup, 'supervisor-sidebar');
        note('supervisor sidebar', { actionCenter: false, weeklyAiSummary: false, demandForecast: false });
      });

      await t.step('supervisor: deep links and admin aliases land on Team Overview', async () => {
        for (const key of ['team_forecast', 'team_action_center', 'team_ai_summary', 'prediction',
          'weekly_ai_summary', 'management_action_center']) {
          await deepLink(sup, key, admin.waitForSupervisorShell);
        }
        await t.shot(sup, 'supervisor-deep-link');
      });

      let bm;
      await t.step('branch manager: no Forecast page; a deep link lands on the overview', async () => {
        bm = await t.session('admin', { name: 'branch-manager' });
        await B.loginAdmin(bm.page, bm.url, accounts.branchManager.email);
        await admin.waitForBranchManagerShell(bm.page);
        await B.see(bm.page, 'Branch Reports');
        await absent(buttons(bm.page, /^Forecast/), 'Forecast entry in the branch sidebar');
        await deepLink(bm, 'prediction', admin.waitForBranchManagerShell);
        await t.shot(bm, 'branch-manager');
        note('branch manager', { forecast: false });
      });
    } finally {
      saveEvidence();
    }

    const RETAILER = RETAILERS[0];
    const SIGNAL = 'E2E-BASIC-SIGNAL orders dropped three weeks in a row';
    const RATIONALE = 'E2E-BASIC-REPLENISH reorder soon';
    const NOT_IN_EDITION = 'Visit briefs are not part of this edition of the app.';
    const mobileEvidence = { edition: 'basic', checks: [] };
    const mnote = (check, detail = {}) => mobileEvidence.checks.push({ check, ...detail });
    const saveMobileEvidence = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'mobile.json'), `${JSON.stringify(mobileEvidence, null, 2)}\n`);
    };
    const allText = (page) => page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
      .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));
    async function expectNone(page, patterns, what) {
      const texts = await allText(page);
      for (const re of patterns) {
        const hit = texts.find((x) => re.test(x));
        if (hit) throw new Error(`${what}: found ${re} in "${hit.slice(0, 120)}"`);
      }
      return texts.length;
    }
    async function waitForReply(page, question, re, timeout = 25000) {
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        const texts = await allText(page);
        const at = texts.lastIndexOf(question);
        const after = at >= 0 ? texts.slice(at + 1) : [];
        const reply = after.find((x) => re.test(x));
        if (reply) return { reply, after };
        await page.waitForTimeout(200);
      }
      throw new Error(`no reply matching ${re} appeared after "${question}"`);
    }
    const AI_ON_CARD = [/today.?s focus/i, /retailer memory/i, /replenishment/i, /visit brief/i, /sales visit copilot/i,
      /outcome\(s\)/, /no confirmed retailer outcomes/i, new RegExp(SIGNAL), new RegExp(RATIONALE),
      /reorder suggestions/i, /full brief/i, /what we know about this shop/i, /^Last order /, /Usually orders on/,
      /You said you would come back/];

    let route;
    let stub;
    try {
      await t.step('mobile seed: a published route with one stop, a visit brief and an outcome for the same retailer', async () => {
        const uid = seed.uids.salesman;
        const now = new Date();
        const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
        await db.put('route_plans', 'plan-e2e-basic', {
          planId: 'plan-e2e-basic', createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
          salesmanName: accounts.salesman.name, branchId: 'B1',
          weekStart: new Date(noon.getTime() - 6 * 86400000), weekEnd: new Date(noon.getTime() + 86400000),
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
        await db.put('visit_briefs', 'brief-e2e-basic', {
          briefId: 'brief-e2e-basic', retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanUid: uid,
          salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', isActive: true, insightCount: 1, highPriorityCount: 1,
          totalValueAtRiskRm: 120, isDemo: false, updatedAt: now, emptyStateHeadline: '', emptyStateBody: '',
          focusItems: [{
            issueId: 'issue-1', issueKey: 'low_sell_through:prod-2', type: 'low_sell_through', priority: 'high', confidence: 'high',
            productId: 'prod-2', productName: 'INSTANT BABY OAT', signal: SIGNAL,
            action: 'Ask about shelf space.', questions: [], valueAtRiskRm: 120, occurrenceCount: 1, autoState: 'active',
          }],
          replenishment: [{
            retailerId: RETAILER.id, productId: 'prod-1', suggestedQty: 4, confidence: 0.7, confidenceLabel: 'medium',
            rationale: RATIONALE, inputs: { lastOrderQty: 3, lastOrderDaysAgo: 20, runRatePerDay: 0.2, patternMeanQty: 3 },
          }],
        });
        await db.put('conversation_outcomes', 'outcome-e2e-basic', {
          outcomeId: 'outcome-e2e-basic', salesmanUid: uid, salesmanCode: accounts.salesman.code, branchId: 'B1',
          retailerId: RETAILER.id, retailerName: RETAILER.name, reasonCode: 'low_sell_through', productId: 'prod-2',
          productName: 'INSTANT BABY OAT', issueKey: 'low_sell_through:prod-2', isDemo: false,
          submittedAt: now, clientCreatedAt: now,
        });
        const profile = await db.get('users', accounts.salesman.email);
        await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
      });

      await t.step('mobile route card: no Today\'s focus, Retailer memory, Replenishment or brief text', async () => {
        route = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
        await B.fakeGeolocation(route.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
        await B.loginMobile(route.page, route.url, accounts.salesman.email);
        await mobile.waitForHome(route.page);
        await mobile.openAssignedRoute(route.page);
        await B.see(route.page, RETAILER.name);
        await B.see(route.page, /1 stop\(s\)/);
        await route.page.waitForTimeout(4000);
        const nodes = await expectNone(route.page, AI_ON_CARD, 'route card before the route starts');
        await mobile.acceptAndStartRoute(route.page);
        await mobile.selectStop(route.page);
        const openVisit = route.page.getByRole('button', { name: 'Open visit', exact: true }).first();
        await B.scrollIntoView(route.page, openVisit, { minHeight: 20, pointerY: 0.8 });
        await openVisit.waitFor({ timeout: 20000 });
        await route.page.waitForTimeout(3000);
        await expectNone(route.page, AI_ON_CARD, 'route card after the route starts');
        await t.shot(route, 'route-card');
        mnote('assigned route card', { retailerShown: true, openVisitShown: true, semanticsNodesRead: nodes, forbidden: AI_ON_CARD.map(String) });
      });

      await t.step('mobile guided visit: Prepare stage renders without Retailer memory or Today\'s focus', async () => {
        const open = route.page.getByRole('button', { name: 'Open visit', exact: true }).first();
        await B.scrollIntoView(route.page, open, { minHeight: 20, pointerY: 0.8 });
        await open.click();
        await B.see(route.page, /Continue to sell|Mark arrived/);
        await B.see(route.page, RETAILER.name);
        await route.page.getByRole('button', { name: 'Mark arrived', exact: true }).last().waitFor({ timeout: 20000 });
        await route.page.waitForTimeout(3000);
        await expectNone(route.page, AI_ON_CARD, 'guided visit Prepare stage');
        await t.shot(route, 'guided-visit-prepare');
        mnote('guided visit prepare', { stageShown: true, retailerShown: true, primaryAction: 'Mark arrived', forbidden: AI_ON_CARD.map(String) });
      });

      await t.step('mobile Scout: the brief question is declined; Help, chips and the hosted request leave briefs out', async () => {
        stub = await fake.start();
        const cs = await t.session('mobile', { name: 'mobile-copilot', viewport: mobile.MOBILE_VIEWPORT });
        const page = cs.page;
        await B.loginMobile(page, cs.url, accounts.salesman.email);
        await mobile.waitForHome(page);
        await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
        await B.see(page, 'Ask about your route and orders.');
        await B.see(page, 'What is my next stop?');
        await page.waitForTimeout(2000);
        await expectNone(page, [/visit brief/i], 'Scout suggestion chips');
        const ask = async (text) => {
          await B.fillField(page, page.getByRole('textbox'), text);
          await page.getByRole('button', { name: 'Send', exact: true }).click();
        };

        const briefQuestion = `show the visit brief for ${RETAILER.name}`;
        await ask(briefQuestion);
        const declined = await waitForReply(page, briefQuestion, new RegExp(NOT_IN_EDITION.replace(/\./g, '\\.')));
        if ((await allText(page)).some((x) => /Visit brief for /.test(x) || new RegExp(SIGNAL).test(x))) {
          throw new Error('Scout showed brief content');
        }
        await t.shot(cs, 'copilot-brief-declined');
        for (const question of [`what should I say at ${RETAILER.name}?`, `when does ${RETAILER.name} usually order?`]) {
          await ask(question);
          await waitForReply(page, question, new RegExp(NOT_IN_EDITION.replace(/\./g, '\\.')));
          if ((await allText(page)).some((x) => /talk about (this|these) point|usually orders on/.test(x) || new RegExp(SIGNAL).test(x))) {
            throw new Error(`Scout showed brief content for "${question}"`);
          }
        }

        await ask('help');
        const help = await waitForReply(page, 'help', /I cannot submit orders, complete visits or record outcomes/);
        const briefText = help.after.find((x) => /brief/i.test(x));
        if (briefText) throw new Error(`Help or its chips mention a brief: "${briefText.slice(0, 120)}"`);
        await t.shot(cs, 'copilot-help');

        await ask('qwzx plorf blimmo');
        const end = Date.now() + 15000;
        while (!stub.requests.length && Date.now() < end) await page.waitForTimeout(200);
        if (!stub.requests.length) throw new Error('the hosted Scout server received no request');
        for (const r of stub.requests) {
          if (!Array.isArray(r.actions) || !r.actions.includes('search_orders')) throw new Error(`unexpected actions ${JSON.stringify(r.actions)}`);
          if (r.actions.includes('brief_retailer')) throw new Error(`brief_retailer was offered to the hosted model: ${JSON.stringify(r.actions)}`);
        }
        mnote('mobile copilot', {
          briefQuestion, declinedWith: declined.reply, helpHasBrief: false, suggestionChipHasVisitBrief: false,
          hostedRequests: stub.requests.map((r) => ({ text: r.text, actions: r.actions })),
        });
      });
    } finally {
      saveMobileEvidence();
      if (stub) await stub.close().catch(() => null);
    }
  },
};
