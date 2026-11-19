'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS, PRODUCTS } = require('../lib/seed.cjs');
const fake = require('../lib/copilot_server.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'scout_conversation');
const DAY = 86400e3;
const KL = 8 * 3600e3;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEKDAYS = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
const BAR_LABEL = /^Week of \d+ \w+: (?:1 carton|[\d.]+ cartons)$/;
const esc = (s) => s.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function klMonday(date) {
  const kl = new Date(date.getTime() + KL);
  const dow = (kl.getUTCDay() + 6) % 7;
  return Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate() - dow) - KL;
}
const klDay = (ms) => new Date(ms + KL);
const dm = (ms) => `${klDay(ms).getUTCDate()} ${MONTHS[klDay(ms).getUTCMonth()]}`;
const wd = (ms) => WEEKDAYS[(klDay(ms).getUTCDay() + 6) % 7];
const weekKey = (ms) => {
  const d = klDay(ms);
  const thursday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 3);
  const year = new Date(thursday).getUTCFullYear();
  const jan4 = Date.UTC(year, 0, 4);
  const week = 1 + Math.floor((thursday - jan4 + ((new Date(jan4).getUTCDay() + 6) % 7) * DAY) / (7 * DAY));
  return `${year}-W${String(week).padStart(2, '0')}`;
};

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

module.exports = {
  name: 'scout_conversation',
  async run(t) {
    const { db, accounts, seed } = t;
    const CHOICE = RETAILERS[0];
    const EMART = RETAILERS[1];
    const PERSON = accounts.salesman.name;
    const FIRST = PERSON.split(/\s+/)[0];
    const answers = [];
    let s;
    let server = null;
    const page = () => s.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const ask = async (text, re) => {
      const before = await find(re).count();
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
      const end = Date.now() + 30000;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) {
          const seen = await find(re).last().evaluate((n) => n.getAttribute('aria-label') || n.textContent);
          answers.push({ asked: text, seen });
          return;
        }
        await page().waitForTimeout(150);
      }
      throw new Error(`after "${text}" expected ${re}`);
    };
    const see = (re) => B.see(page(), re);
    const barLabels = async () => (await admin.semanticsLines(page())).filter((line) => BAR_LABEL.test(line));
    const expectBars = async (expected, why) => {
      const end = Date.now() + 20000;
      let seen = [];
      while (Date.now() < end) {
        seen = (await barLabels()).slice(-expected.length);
        if (JSON.stringify([...seen].sort()) === JSON.stringify([...expected].sort())) return;
        await page().waitForTimeout(200);
      }
      throw new Error(`${why}: expected bars ${JSON.stringify(expected)}, saw ${JSON.stringify(seen)}`);
    };
    const plannerWeek = (mondayMs) => new RegExp(`${esc(dm(mondayMs))} – ${esc(dm(mondayMs + 5 * DAY))}`);
    const absent = async (re, why) => {
      if ((await find(re).count()) !== 0) throw new Error(`unexpected text ${re}: ${why}`);
    };
    const openCopilot = () => page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
    const save = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'answers.json'), `${JSON.stringify(answers, null, 2)}\n`);
    };

    if (process.env.E2E_EDITION === 'basic') {
      await t.step('basic edition: the new abilities are not offered', async () => {
        s = await t.session('admin', { name: 'admin' });
        await B.loginAdmin(page(), s.url, accounts.admin.email);
        await admin.waitForShell(page());
        await openCopilot();
        await ask('who is due?', /not in this edition/);
        await ask(`why is ${CHOICE.name} on ${PERSON}'s route`, /not in this edition/);
        await ask(`plan next week for ${PERSON}`, /not in this edition/);
        await ask('who has no route next week?', /not in this edition/);
        await t.shot(s, 'basic-not-offered');
      });
      save();
      return;
    }

    const thisMonday = klMonday(new Date());
    const nextMonday = thisMonday + 7 * DAY;
    const lastMonday = thisMonday - 7 * DAY;
    const olderMonday = thisMonday - 14 * DAY;
    const tuesday = nextMonday + DAY;
    const wednesday = nextMonday + 2 * DAY;
    const RANK_ID = 'rank-scout-conv';
    const PLAN_ID = 'plan-scout-conv';
    const ARCHIVED_PLAN_ID = 'plan-scout-conv-archived';
    const THIS_WEEK_PLAN_ID = 'plan-scout-conv-this-week';
    const STOPPED_A = PRODUCTS[0];
    const STOPPED_B = PRODUCTS[2];
    const OAT = PRODUCTS[1];
    const QTY_A = [7, 6, 8, 5, 6, 0, 0, 0];
    const QTY_B = [3, 2, 4, 3, 1, 1, 0, 0];
    const QTY_OAT = [2, 3, 2, 4, 3, 5, 4, 6];
    const weekStarts = Array.from({ length: 8 }, (_, i) => thisMonday - (8 - i) * 7 * DAY);
    const bars = (quantities) => weekStarts.map((ms, i) => `Week of ${dm(ms)}: ${quantities[i]} ${quantities[i] === 1 ? 'carton' : 'cartons'}`);
    const dateKey = (ms) => klDay(ms).toISOString().slice(0, 10);
    const thursday = nextMonday + 3 * DAY;
    const BRIEF_ID = 'brief-scout-conv';
    const WEEK = weekKey(thisMonday);
    const SIGNAL = 'E2E scout signal: oats slowed down';
    const REASON = `E2E reason saved with the stop: ${PRODUCTS[0].name} orders stopped`;
    const ARCHIVED_REASON = 'E2E reason from the archived plan';
    const owned = [];
    const put = async (collection, id, doc) => {
      await db.put(collection, id, doc);
      owned.push([collection, id]);
    };

    try {
      await t.step('seed: a ranking, a plan for next week, two alerts in different job weeks, a visit brief', async () => {
        const now = new Date();
        const s001 = { salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: accounts.salesman.branch };
        await put('retailer_priority_rankings', RANK_ID, {
          rankingId: RANK_ID, scopeKey: `salesman:${s001.salesmanCode}`, ...s001, weekKey: WEEK, status: 'active',
          policyVersion: 'route-policy/1.0.0', rankingVersion: 'ranking/1.0.0', expectedOrderValueVersion: 'expected-order-value/1.0.0',
          coverageBasis: 'last_observed_order', targetSize: 2, retailerCount: 3, chosenCount: 2, isDemo: false,
          generatedAt: new Date(now.getTime() - 3600e3), decisionLog: [],
          ranking: [
            row(CHOICE.id, CHOICE.name, 1, {
              expectedOrderValueRm: 1234.5, opportunityPerRouteDay: 12345, travelMinutes: 30, serviceMinutes: 18, daysSinceLastVisit: 9,
              components: { expectedValueRm: 1234.5, adjustedValueRm: 1300, travelMinutes: 30, serviceMinutes: 18, routeTimeDays: 0.1, coverageBoost: 0.05, adjustedScore: 13650 },
            }),
            row(EMART.id, EMART.name, 2, {
              expectedOrderValueRm: 800, opportunityPerRouteDay: 8000, travelMinutes: 20, serviceMinutes: 28, daysSinceLastVisit: 20,
              components: { expectedValueRm: 800, adjustedValueRm: 840, travelMinutes: 20, serviceMinutes: 28, routeTimeDays: 0.1, coverageBoost: 0.1, adjustedScore: 9240 },
            }),
            row('ret-plain', 'Kedai Tiada Komponen', 3, { chosen: false, exploitOrExplore: 'not_selected', selectionProbability: 0, expectedOrderValueRm: 55.25 }),
          ],
        });
        const stop = (id, retailer, sequence, dayId, reason) => ({
          stopId: id, dayId, retailerId: retailer.id, retailerName: retailer.name, address: `${retailer.area}, Kuching`,
          lat: retailer.lat, lng: retailer.lng, sequence, estimatedArrival: '09:00', estimatedDeparture: '09:20',
          priorityReason: reason, status: 'not_started', travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
        });
        const plan = (planId, status, weekMs, days) => ({
          planId, createdByUid: seed.uids.admin, ...s001, salesmanName: PERSON, branchId: 'B1',
          weekStart: new Date(weekMs), weekEnd: new Date(weekMs + 6 * DAY), status, source: 'dashboard',
          totalStops: days.reduce((n, d) => n + d.stops.length, 0),
          stopIds: days.flatMap((d) => d.stops.map((x) => x.stopId)),
          stopRetailerIds: Object.fromEntries(days.flatMap((d) => d.stops.map((x) => [x.stopId, x.retailerId]))),
          days,
        });
        await put('route_plans', ARCHIVED_PLAN_ID, plan(ARCHIVED_PLAN_ID, 'archived', nextMonday, [
          { dayId: 'arch-day-1', dayLabel: 'Thu', date: new Date(thursday), totalDistanceKm: 7, stops: [
            stop('arch-stop-1', CHOICE, 1, 'arch-day-1', ARCHIVED_REASON),
            stop('arch-stop-2', EMART, 2, 'arch-day-1', ARCHIVED_REASON),
          ] },
        ]));
        await put('route_plans', THIS_WEEK_PLAN_ID, plan(THIS_WEEK_PLAN_ID, 'published', thisMonday, [
          { dayId: 'this-day-1', dayLabel: 'Mon', date: new Date(thisMonday), totalDistanceKm: 3.5, stops: [
            stop('this-stop-1', EMART, 1, 'this-day-1', ''),
          ] },
        ]));
        await put('route_plans', PLAN_ID, {
          planId: PLAN_ID, createdByUid: seed.uids.admin, ...s001, salesmanName: PERSON, branchId: 'B1',
          weekStart: new Date(nextMonday), weekEnd: new Date(nextMonday + 6 * DAY), status: 'draft', source: 'dashboard',
          totalStops: 2, stopIds: ['scout-stop-1', 'scout-stop-2'],
          stopRetailerIds: { 'scout-stop-1': CHOICE.id, 'scout-stop-2': EMART.id },
          days: [
            { dayId: 'scout-day-1', dayLabel: 'Tue', date: new Date(tuesday), totalDistanceKm: 3.5, stops: [stop('scout-stop-1', CHOICE, 1, 'scout-day-1', REASON)] },
            { dayId: 'scout-day-2', dayLabel: 'Wed', date: new Date(wednesday), totalDistanceKm: 3.5, stops: [stop('scout-stop-2', EMART, 1, 'scout-day-2', '')] },
          ],
        });
        const insight = (id, retailer, observed) => ({
          issueId: id, issueKey: id, type: 'overdue_reorder', priority: 'high', status: 'new', autoState: 'active', confidence: 'high',
          ...s001, retailerId: retailer.id, retailerName: retailer.name, isDemo: false,
          reason: 'E2E overdue reorder', recommendation: 'Visit this week',
          lastObservedWeekStart: new Date(observed), generatedAt: now, updatedAt: now, createdAt: now,
        });
        await put('ai_insights', 'scout-conv-new', insight('scout-conv-new', CHOICE, lastMonday));
        await put('ai_insights', 'scout-conv-old', insight('scout-conv-old', EMART, olderMonday));
        const mean = (values) => (values.length ? Math.round((values.reduce((a, b) => a + b, 0) / values.length) * 100) / 100 : 0);
        const stopped = (id, product, quantities) => ({
          ...insight(id, CHOICE, lastMonday), type: 'stopped_product', productId: product.id, productName: product.name, reason: 'E2E stopped buying',
          latestEvidence: {
            weekStarts: weekStarts.map(dateKey), weeklyQuantities: quantities, weeklyOrderCounts: quantities.map((q) => (q > 0 ? 1 : 0)),
            baselineAverage: mean(quantities.slice(0, -2)), recentAverage: mean(quantities.slice(-3)),
          },
        });
        await put('ai_insights', 'scout-conv-stopped-a', stopped('scout-conv-stopped-a', STOPPED_A, QTY_A));
        await put('ai_insights', 'scout-conv-stopped-b', stopped('scout-conv-stopped-b', STOPPED_B, QTY_B));
        const pattern = (id, retailer, product, quantities) => ({
          patternId: id, retailerId: retailer.id, retailerName: retailer.name, productId: product.id, productName: product.name,
          ...s001, weekStarts: weekStarts.map(dateKey), weeklyQuantities: quantities, trend: 'steady', isDemo: false,
        });
        await put('retailer_item_patterns', 'scout-conv-pattern-a', pattern('scout-conv-pattern-a', CHOICE, STOPPED_A, QTY_A));
        await put('retailer_item_patterns', 'scout-conv-pattern-b', pattern('scout-conv-pattern-b', CHOICE, STOPPED_B, QTY_B));
        await put('retailer_item_patterns', 'scout-conv-pattern-oat', pattern('scout-conv-pattern-oat', EMART, OAT, QTY_OAT));
        await put('visit_briefs', BRIEF_ID, {
          briefId: BRIEF_ID, retailerId: EMART.id, retailerName: EMART.name, ...s001, status: 'active', isActive: true,
          insightCount: 1, highPriorityCount: 1, totalValueAtRiskRm: 120, isDemo: false, updatedAt: now, generatedAt: now,
          emptyStateHeadline: '', emptyStateBody: '',
          focusItems: [{
            issueId: 'issue-scout', issueKey: 'low_sell_through:prod-2', type: 'low_sell_through', priority: 'high', confidence: 'high',
            productId: 'prod-2', productName: 'INSTANT BABY OAT', signal: SIGNAL, action: 'Ask about shelf space.',
            questions: [], valueAtRiskRm: 120, occurrenceCount: 1, autoState: 'active',
          }],
          replenishment: [],
        });
      });

      await t.step('admin: why a shop is ranked, then follow-ups resolve from memory', async () => {
        s = await t.session('admin', { name: 'admin', viewport: { width: 2000, height: 1100 } });
        await B.loginAdmin(page(), s.url, accounts.admin.email);
        await admin.waitForShell(page());
        await openCopilot();
        await ask(`why is ${CHOICE.name} ranked first`, /The weekly ranking puts it at number 1, with an expected order of RM 1,234\.50\./);
        await absent(/a little less|because it is expected/, 'the ranking answer states stored numbers, not causes');
        await see(new RegExp(`${esc(CHOICE.name)} is #1 of 3 for salesperson ${accounts.salesman.code} in week ${WEEK}\\.`));
        await see(/Data used: retailer_priority_rankings · document rank-scout-conv/);
        await see(/Details/);
        await ask(`and ${EMART.name}?`, new RegExp(`${esc(EMART.name)} is #2 of 3 for salesperson ${accounts.salesman.code}`));
        await ask('and that shop?', new RegExp(`${esc(EMART.name)} is #2 of 3`));
        await ask('why is Kedai Tiada Komponen ranked first', /The weekly ranking did not pick it this week\./);
        await see(new RegExp(`Kedai Tiada Komponen is not on the route plan for the week of ${esc(dm(thisMonday))} \\(plan status: published\\)\\.`));
        await absent(/so it is not on the route|falls below the cut-off/, 'the ranking does not know the route');
        await t.shot(s, 'rank-follow-up');
      });

      await t.step('admin: route stop answer, follow-ups by name, pronoun and brief from memory', async () => {
        await ask(`why is ${CHOICE.name} on ${PERSON}'s route`,
          new RegExp(`${esc(CHOICE.name)} is on ${esc(PERSON)}'s route for the week of ${esc(dm(nextMonday))}: ${wd(tuesday)} ${esc(dm(tuesday))}, stop 1 \\(plan status: draft\\)`));
        await see(new RegExp(`The reason saved with the stop: ${esc(REASON)}`));
        await absent(new RegExp(ARCHIVED_REASON), 'an archived plan must not answer');
        await absent(new RegExp(`${esc(wd(thursday))} ${esc(dm(thursday))}, stop`), 'an archived plan must not answer');
        await expectBars(bars(QTY_A), 'a stopped product named in the stop reason shows its eight weeks');
        await see(new RegExp(`In the weekly ranking \\(week ${WEEK}\\) it is #1 of 3`));
        await see(new RegExp(`Data used: route_plans · document ${PLAN_ID} · week of ${esc(dm(nextMonday))}`));
        await ask(`and ${EMART.name}?`,
          new RegExp(`${esc(EMART.name)} is on ${esc(PERSON)}'s route for the week of ${esc(dm(nextMonday))}: ${wd(wednesday)} ${esc(dm(wednesday))}, stop 1`));
        await see(/No reason is saved with this stop\./);
        await ask('what should he say there?', new RegExp(`Visit brief · ${esc(EMART.name)}`));
        await see(new RegExp(`${esc(SIGNAL)}\\. Next step: Ask about shelf space\\.`));
        await expectBars(bars(QTY_OAT), 'the brief shows the weekly cartons of its product');
        await ask('And what should he say there?', new RegExp(`Visit brief · ${esc(EMART.name)}`));
        await expectBars(bars(QTY_OAT), 'a leading "and" does not change the match');
        await see(/Data used: visit_briefs · document brief-scout-conv/);
        await t.shot(s, 'route-and-brief');
      });

      await t.step('admin: a question in other words goes to the model and shows the same stored facts', async () => {
        server = await fake.start();
        const spoken = `what made you put ${CHOICE.name} on ${PERSON}'s route`;
        const picked = fake.ANSWERS[spoken.toLowerCase()];
        if (!picked || picked.name !== 'route_why') throw new Error('the fake server does not map this sentence to route_why');
        const requestsBefore = server.requests.length;
        await ask(spoken,
          new RegExp(`${esc(CHOICE.name)} is on ${esc(PERSON)}'s route for the week of ${esc(dm(nextMonday))}: ${wd(tuesday)} ${esc(dm(tuesday))}, stop 1 \\(plan status: draft\\)`));
        if (server.requests.length !== requestsBefore + 1 || server.requests.at(-1).text.toLowerCase() !== spoken.toLowerCase()) {
          throw new Error(`expected exactly one model request for "${spoken}", saw ${JSON.stringify(server.requests.slice(requestsBefore))}`);
        }
        const modelAnswer = answers.at(-1).seen;
        const reasonLine = new RegExp(`The reason saved with the stop: ${esc(REASON)}`);
        const sourceLine = new RegExp(`Data used: route_plans · document ${PLAN_ID} · week of ${esc(dm(nextMonday))}`);
        if (!reasonLine.test(modelAnswer) || !sourceLine.test(modelAnswer)) {
          throw new Error(`the model answer must show the same stored facts: ${JSON.stringify(modelAnswer)}`);
        }
        await absent(new RegExp(ARCHIVED_REASON), 'an archived plan must not answer');
        await t.shot(s, 'model-route-why');
      });

      await t.step('admin: next-week visits show the stored numbers and a planner button', async () => {
        await ask(`who should ${PERSON} visit next week`, new RegExp(`The weekly ranking \\(week ${WEEK}\\) puts these shops first for ${esc(PERSON)}`));
        await see(new RegExp(`1\\. ${esc(CHOICE.name)} · expected order RM 1,234\\.50 · 9 days since the last visit`));
        await see(new RegExp(`2\\. ${esc(EMART.name)} · expected order RM 800\\.00 · 20 days since the last visit`));
        await absent(/Kedai Tiada Komponen · expected order/, 'a shop the policy did not choose');
        await see(/Data used: retailer_priority_rankings · document rank-scout-conv/);
        await page().getByRole('button', { name: new RegExp(`^Open the planner for ${esc(FIRST)}`) }).click();
        await see(/Opened Route Planner/);
        await see(plannerWeek(nextMonday), { timeout: 30000 });
        await see(new RegExp(esc(PERSON)));
        await t.shot(s, 'visits-planner-button');
      });

      await t.step('admin: a Scout request is used once; the sidebar then opens the planner on its normal week', async () => {
        await ask(`plan this week for ${PERSON}`, /Opened Route Planner/);
        await see(plannerWeek(thisMonday), { timeout: 30000 });
        await admin.goToPage(page(), 'Visit Logs');
        await see(/Follow-up/, { timeout: 30000 });
        await absent(plannerWeek(thisMonday), 'the planner is closed');
        await admin.goToPage(page(), 'Route Planner');
        await see(plannerWeek(nextMonday), { timeout: 30000 });
        await absent(plannerWeek(thisMonday), 'the sidebar must not reopen the week Scout asked for');
        await t.shot(s, 'planner-from-sidebar-normal-week');
      });

      await t.step('admin: the same Scout request a second time applies again after a manual week change', async () => {
        await ask(`plan this week for ${PERSON}`, /Opened Route Planner/);
        await see(plannerWeek(thisMonday), { timeout: 30000 });
        await page().getByRole('button', { name: 'Next week', exact: true }).click();
        await see(plannerWeek(nextMonday), { timeout: 30000 });
        await absent(plannerWeek(thisMonday), 'the manual week change took effect');
        await ask(`plan this week for ${PERSON}`, /Opened Route Planner/);
        await see(plannerWeek(thisMonday), { timeout: 30000 });
        await absent(plannerWeek(nextMonday), 'the second identical request must move the planner back');
        await t.shot(s, 'same-request-twice');
      });

      await t.step('admin: who is due counts only the newest job week', async () => {
        await ask('who is due?', /1 shop is due or has stopped buying in the newest weekly run/);
        await see(new RegExp(`${esc(CHOICE.name)} · .*reorder overdue`));
        await see(new RegExp(`stopped buying ${esc(STOPPED_A.name)}`));
        await absent(new RegExp(`${esc(EMART.name)} · reorder overdue`), 'an alert from an older job week');
        await see(new RegExp(`Data used: ai_insights · week of ${esc(dm(lastMonday))}`));
        await expectBars([...bars(QTY_A), ...bars(QTY_B)], 'one shop with two stopped products shows both charts');
        const overdueBefore = await find(/reorder overdue/).count();
        await ask('which shops stopped buying?', /1 shop has stopped buying in the newest weekly run/);
        if ((await find(/reorder overdue/).count()) !== overdueBefore) throw new Error('"stopped buying" listed a reorder-overdue reason');
        await t.shot(s, 'due');
      });

      await t.step('admin: plan next week opens the planner, and the no-route list is correct', async () => {
        await ask(`plan this week for ${PERSON}`, /Opened Route Planner/);
        await see(plannerWeek(thisMonday), { timeout: 30000 });
        await ask(`who should ${PERSON} visit next week`, new RegExp(`The weekly ranking \\(week ${WEEK}\\) puts these shops first for ${esc(PERSON)}`));
        await page().getByRole('button', { name: new RegExp(`^Open the planner for ${esc(FIRST)}`) }).last().click();
        await see(plannerWeek(nextMonday), { timeout: 30000 });
        await ask(`plan next week for ${PERSON}`, /Opened Route Planner/);
        await ask('who has no route next week?', /Every salesperson has a published route|No plan yet|Draft, not approved/);
        await see(/Draft, not approved/);
        await see(new RegExp(`Data used: route_plans · week of ${esc(dm(nextMonday))}`));
        await t.shot(s, 'no-route');
      });

      await t.step('admin: help has no greeting; a pronoun resolves to the remembered person', async () => {
        await ask('help', /Here is what I can do\./);
        await absent(/I am doing well/, 'help must not greet');
        await ask('plan next week for her', /Opened Route Planner/);
        await t.shot(s, 'help');
      });

      await t.step('admin: a rude phrase and a general question get the calm line and open no page', async () => {
        const url = page().url();
        const requests = server.requests.length;
        await ask('U ASS', /I am here for questions about this company's orders, routes, shops and team\. Try one of these\./);
        await absent(/Opened Users/, 'a rude phrase must not open a page');
        await ask('who is mark zuckerberg', /I can only answer questions about this company's orders, routes, shops and team, so I cannot answer that\./);
        if (page().url() !== url) throw new Error(`the page changed from ${url} to ${page().url()}`);
        if (server.requests.length !== requests) throw new Error('fixed rules must answer these phrases without a model request');
        await t.shot(s, 'calm-line');
      });

      await t.step('admin: phrases the model sends to Users reach the guard, are refused with the fixed line and open no page', async () => {
        const LOST = /I did not understand that\. Try one of these\./;
        const GUARDED = [
          'go to hell you stupid bot',
          'open your eyes you dumb bot',
          'show me your worst joke please',
          'where is my money you fool',
          'take me to your leader now',
          'users are confusing; do not open them',
          `who is ${FIRST.toLowerCase()}`,
        ];
        for (const phrase of GUARDED) fake.ANSWERS[phrase] = { name: 'navigate_to_page', args: { page: 'user_directory' } };
        try {
          const url = page().url();
          const OFF_TOPIC = /I can only answer questions about this company's orders, routes, shops and team, so I cannot answer that\./;
          const offTopicBefore = await find(OFF_TOPIC).count();
          for (const phrase of GUARDED) {
            const requests = server.requests.length;
            await ask(phrase, LOST);
            await absent(/Opened Users/, `"${phrase}" must not open a page`);
            if (page().url() !== url) throw new Error(`"${phrase}" changed the page from ${url} to ${page().url()}`);
            const sent = server.requests.slice(requests).map((request) => request.text);
            if (sent.length !== 1 || sent[0] !== phrase) {
              throw new Error(`"${phrase}" must be asked of the model once, the model was asked ${JSON.stringify(sent)}`);
            }
          }
          if ((await find(OFF_TOPIC).count()) !== offTopicBefore) {
            throw new Error(`"who is ${FIRST}" names a seeded salesperson and must not be refused as off topic`);
          }
          await t.shot(s, 'guarded-model-pages');
        } finally {
          for (const phrase of GUARDED) delete fake.ANSWERS[phrase];
        }
      });
    } finally {
      if (server) await server.close();
      for (const [collection, id] of owned) {
        await db.del(collection, id).catch((e) => { throw new Error(`cleanup ${collection}/${id}: ${e.message}`); });
      }
      save();
    }
  },
};
