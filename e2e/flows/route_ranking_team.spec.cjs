'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { ACCOUNTS, BRANCH, PRODUCTS, RETAILERS, putPerson } = require('../lib/seed.cjs');

const DAY = 86400e3;
const KL = 8 * 3600e3;
const WEEKDAYS = ['Monday', 'Tuesday', 'Wednesday', 'Thursday', 'Friday', 'Saturday'];
const SECOND = { email: 'e2e.sales2@example.test', name: 'E2E Second Rep', role: 'salesman', code: 'S002', branch: BRANCH.id };
const SECOND_SHOPS = [
  { id: 'ret-s2-1', name: 'Second Rep Mart One', area: 'Satok', lat: 1.5521, lng: 110.3352 },
  { id: 'ret-s2-2', name: 'Second Rep Mart Two', area: 'Satok', lat: 1.5562, lng: 110.3391 },
];
const MATANG = Array.from({ length: 18 }, (_, i) => ({
  id: `ret-rk-${String(i + 1).padStart(2, '0')}`,
  name: `Rank Shop ${String(i + 1).padStart(2, '0')}`,
  area: 'Matang',
  lat: 1.56 + (i % 6) * 0.004,
  lng: 110.3 + Math.floor(i / 6) * 0.006,
}));
const LEFT_OUT = MATANG[16];
const ZERO = { ...MATANG[17], name: 'Zero Score Shop' };
const NO_PIN = { id: 'ret-rk-nopin', name: 'Rank Shop No Pin', area: 'Matang' };
const RANKED = [...MATANG.slice(0, 16), RETAILERS[0], RETAILERS[1], LEFT_OUT];
const OVERDUE = RANKED[1];
const AREA_REP = { email: 'e2e.sales3@example.test', name: 'E2E Third Rep', role: 'salesman', code: 'S003', branch: BRANCH.id };
const ORDER_DAY_REP = { email: 'e2e.sales4@example.test', name: 'E2E Fourth Rep', role: 'salesman', code: 'S004', branch: BRANCH.id };
const FOLLOW_UP_REP = { email: 'e2e.sales5@example.test', name: 'E2E Fifth Rep', role: 'salesman', code: 'S005', branch: BRANCH.id };
const matangShop = (id, name, i) => ({ id, name, area: 'Matang', lat: 1.561 + (i % 6) * 0.003, lng: 110.305 + Math.floor(i / 6) * 0.004 });
const tabuanShop = (id, name, i) => ({ id, name, area: 'Tabuan', lat: 1.521 + i * 0.003, lng: 110.38 });
const AREA = {
  a1: matangShop('ret-ar-a1', 'Area Order Matang First', 0),
  b2: tabuanShop('ret-ar-b2', 'Area Order Tabuan Second', 0),
  a3: matangShop('ret-ar-a3', 'Area Order Matang Third', 1),
  b4: tabuanShop('ret-ar-b4', 'Area Order Tabuan Fourth', 1),
  a5: matangShop('ret-ar-a5', 'Area Order Matang Fifth', 2),
  noRow: matangShop('ret-ar-u1', 'Area Order Matang No Row', 3),
  zero: matangShop('ret-ar-u2', 'Area Order Matang Zero', 4),
};
const ORDER_DAY = Array.from({ length: 6 }, (_, i) => matangShop(`ret-od-${i + 1}`, `Order Day Shop ${i + 1}`, i));
const FOLLOW_UP = Array.from({ length: 19 }, (_, i) => matangShop(`ret-fu-${String(i + 1).padStart(2, '0')}`, `Follow Shop ${String(i + 1).padStart(2, '0')}`, i));
const OTHERS_ONLY_REP = { email: 'e2e.sales6@example.test', name: 'E2E Sixth Rep', role: 'salesman', code: 'S006', branch: BRANCH.id };
const OTHERS_ONLY = Array.from({ length: 3 }, (_, i) => matangShop(`ret-oo-${i + 1}`, `Others Only Shop ${i + 1}`, i));
const NOT_USED_LINE = "The weekly ranking for this week has none of this salesperson's shops, so it was not used.";
const FOLLOW_UP_NO_PIN = { id: 'ret-fu-nopin', name: 'Follow Shop No Pin', area: 'Matang' };
const AREA_LINE_RE = /Days follow area\. Areas are ordered by their best-ranked shop\./;
const NEAREST_REASON = 'Not in the weekly ranking. Placed with the nearest shops.';
const ZERO_ROW = { expectedOrderValueRm: 0, opportunityPerRouteDay: 0, components: { expectedValueRm: 0, adjustedValueRm: 0, travelMinutes: 20, serviceMinutes: 20, routeTimeDays: 0.1, coverageBoost: 0, adjustedScore: 0 } };

function klMonday(date) {
  const kl = new Date(date.getTime() + KL);
  const dow = (kl.getUTCDay() + 6) % 7;
  return Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate() - dow) - KL;
}

function weekKey(ms) {
  const d = new Date(ms + KL);
  const thursday = Date.UTC(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate() + 3);
  const year = new Date(thursday).getUTCFullYear();
  const jan4 = Date.UTC(year, 0, 4);
  const week = 1 + Math.floor((thursday - jan4 + ((new Date(jan4).getUTCDay() + 6) % 7) * DAY) / (7 * DAY));
  return `${year}-W${String(week).padStart(2, '0')}`;
}

function row(retailer, rank, extra = {}) {
  const value = 600 - rank * 10;
  return {
    retailerId: retailer.id, retailerName: retailer.name, rank,
    expectedOrderValueRm: value, opportunityPerRouteDay: value * 10, routeTimeDays: 0.1,
    travelMinutes: 20, serviceMinutes: 20, daysSinceLastVisit: 10 + rank,
    chosen: true, exploitOrExplore: 'exploit', selectionProbability: 1,
    coverageBasis: 'last_observed_order', forecastPairCount: 4, observedBaselinePairCount: 4,
    components: { expectedValueRm: value, adjustedValueRm: value, travelMinutes: 20, serviceMinutes: 20, routeTimeDays: 0.1, coverageBoost: 0, adjustedScore: value * 10 },
    ...extra,
  };
}

module.exports = {
  name: 'route_ranking_team',
  async run(t) {
    const { db, accounts, seed } = t;
    const thisMonday = klMonday(new Date());
    const PLANNER_WEEK = weekKey(thisMonday + 7 * DAY);
    const WEEK_BEFORE = weekKey(thisMonday);
    const TWO_WEEKS_OLD = weekKey(thisMonday - 7 * DAY);
    const RANK_ONE = 'rank-route-team-s001';
    const RANK_TWO = 'rank-route-team-s002';
    const owned = [];
    const put = async (collection, id, doc) => {
      await db.put(collection, id, doc);
      owned.push([collection, id]);
    };
    const plansOf = async (code) => (await db.list('route_plans')).filter((p) => p.salesmanCode === code);
    const stopsOf = (plan) => plan.days.flatMap((d) => d.stops || []);
    const dayOf = (plan, retailerId) => plan.days.findIndex((d) => (d.stops || []).some((st) => st.retailerId === retailerId));
    const openPlanner = async (name) => {
      const s = await t.session('admin', { name });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Route Planner');
      await s.page.getByRole('button', { name: 'Generate draft route', exact: true }).waitFor({ timeout: 60000 });
      return s;
    };
    const people = () => [accounts.salesman, SECOND, AREA_REP, ORDER_DAY_REP, FOLLOW_UP_REP, OTHERS_ONLY_REP].map((p) => p.name.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
    const pickPerson = async (page, name) => {
      await admin.pickDropdown(page, new RegExp(`(^|\\s)(${people().join('|')})$`), name);
    };
    const openTeamAction = async (page) => {
      await page.getByRole('button', { name: 'Saved plans', exact: true }).click();
      await page.getByRole('button', { name: 'Draft routes for everyone without one', exact: true }).click();
      await B.see(page, 'Draft routes for everyone without one?');
    };
    const closeTeamResults = async (page) => {
      await page.getByRole('button', { name: 'Close', exact: true }).click();
      await page.getByRole('button', { name: 'Plan', exact: true }).click();
    };
    const planTheWeek = async (page) => {
      await openTeamAction(page);
      await B.see(page, /^This makes up to \d+ draft routes?, one for each salesperson with no route for the week of /);
      await page.getByRole('button', { name: 'Make drafts', exact: true }).click();
    };
    const generate = async (s, label = 'Generate draft route') => {
      await s.page.getByRole('button', { name: label, exact: true }).click();
      await s.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
    };
    const shop = (r, salesman, uid, extra = {}) => ({
      retailerId: r.id, retailerName: r.name, name: r.name, area: r.area,
      branchId: BRANCH.id, status: 'active', address: `${r.area}, Kuching`,
      ...(r.lat == null
        ? { coordinateStatus: 'missing' }
        : { latitude: r.lat, longitude: r.lng, coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review' }),
      assignedSalesmanId: salesman.code, assignedSalesmanCode: salesman.code, assignedSalesmanUid: uid,
      ...extra,
    });
    const ranking = (id, person, uid, week, rows) => ({
      rankingId: id, scopeKey: `salesman:${person.code}`, salesmanUid: uid, salesmanCode: person.code, branchId: BRANCH.id,
      weekKey: week, status: 'active', policyVersion: 'route-policy/1.0.0', rankingVersion: 'ranking/1.0.0',
      expectedOrderValueVersion: 'expected-order-value/1.0.0', coverageBasis: 'last_observed_order',
      targetSize: rows.length, retailerCount: rows.length, chosenCount: rows.length, isDemo: false,
      generatedAt: new Date(Date.now() - 3600e3), updatedAt: new Date(Date.now() - 3600e3), decisionLog: [], ranking: rows,
    });
    const insight = (id, retailer, type, weekMs, extra = {}) => ({
      issueId: id, issueKey: id, type, priority: 'high', confidence: 'high', confidenceScore: 0.9, status: 'new', autoState: 'active',
      retailerId: retailer.id, retailerName: retailer.name, productId: PRODUCTS[1].id, productName: PRODUCTS[1].name,
      salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: BRANCH.id,
      reason: 'E2E insight', recommendation: 'E2E', isDemo: false,
      lastObservedWeekStart: new Date(weekMs), updatedAt: new Date(), createdAt: new Date(), generatedAt: new Date(),
      ...extra,
    });

    let secondUid;
    let planner;
    let firstDraftId;
    let planId;
    let othersS;
    let othersPlanId;

    try {
      await t.step('seed: 21 shops for the first salesperson, a ranking with 20 ranked shops and one zero-score shop, three insights, a second salesperson with a ranking of the week before', async () => {
        secondUid = await putPerson(db, SECOND, { supervisorUid: seed.uids.supervisor, supervisorCode: ACCOUNTS.supervisor.code });
        owned.push(['users', SECOND.email], ['user_access', secondUid]);
        for (const r of MATANG.slice(0, 16)) await put('retailers', r.id, shop(r, accounts.salesman, seed.uids.salesman));
        await put('retailers', LEFT_OUT.id, shop(LEFT_OUT, accounts.salesman, seed.uids.salesman, { monthlyValue: 90000 }));
        await put('retailers', ZERO.id, shop(ZERO, accounts.salesman, seed.uids.salesman, { monthlyValue: 99000 }));
        await put('retailers', NO_PIN.id, shop(NO_PIN, accounts.salesman, seed.uids.salesman));
        for (const r of SECOND_SHOPS) await put('retailers', r.id, shop(r, SECOND, secondUid));
        await put('retailer_priority_rankings', RANK_ONE, ranking(RANK_ONE, accounts.salesman, seed.uids.salesman, PLANNER_WEEK, [
          ...RANKED.map((r, i) => row(r, i + 1)),
          row(NO_PIN, 20),
          row(ZERO, 21, { expectedOrderValueRm: 0, opportunityPerRouteDay: 0, components: { expectedValueRm: 0, adjustedValueRm: 0, travelMinutes: 20, serviceMinutes: 20, routeTimeDays: 0.1, coverageBoost: 0, adjustedScore: 0 } }),
        ]));
        await put('retailer_priority_rankings', RANK_TWO, ranking(RANK_TWO, SECOND, secondUid, WEEK_BEFORE, SECOND_SHOPS.map((r, i) => row(r, i + 1))));
        await put('ai_insights', 'ins-route-team-overdue', insight('ins-route-team-overdue', OVERDUE, 'overdue_reorder', thisMonday - 7 * DAY, {
          latestEvidence: { reorderIntervalDays: 14, daysSinceLastOrder: 30, overdueByDays: 16, orderCount: 6 },
        }));
        await put('ai_insights', 'ins-route-team-stopped', insight('ins-route-team-stopped', LEFT_OUT, 'stopped_product', thisMonday - 7 * DAY));
        await put('ai_insights', 'ins-route-team-stale', insight('ins-route-team-stale', ZERO, 'stopped_product', thisMonday - 14 * DAY));
      });

      await t.step('18 places and 19 ranked shops with a pin: the draft holds ranks 1 to 18 in rank order, and the two warning lines name the rest', async () => {
        planner = await openPlanner('ranked-draft');
        expectEqual((await plansOf(accounts.salesman.code)).length, 0, `plans of ${accounts.salesman.name} before the first draft`);
        expectEqual((await plansOf(SECOND.code)).length, 0, `plans of ${SECOND.name} before the first draft`);
        for (let i = 0; i < 3; i += 1) await planner.page.getByRole('button', { name: 'Fewer max stops per day' }).click();
        await generate(planner);
        await B.see(planner.page, `Ranked for week ${PLANNER_WEEK}`);
        await B.see(planner.page, `2 ranked shops left out: ${LEFT_OUT.name} (no place left this week), ${NO_PIN.name} (no coordinates).`);
        await planner.page.getByRole('button', { name: 'Open Coordinate Review', exact: true }).waitFor({ timeout: 10000 });
        await B.see(planner.page, 'Flagged, not on this route:');
        await planner.page.getByRole('button', { name: `Add ${LEFT_OUT.name}`, exact: true }).waitFor({ timeout: 10000 });
        await expectAbsent(planner.page, new RegExp(`Add ${ZERO.name}`), 'an Add button for a shop whose insight is from an older job week');
        await t.shot(planner, 'ranked-draft');
        await planner.page.getByRole('button', { name: 'Save draft' }).click();
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code && p.status === 'draft', { label: 'ranked draft' });
        firstDraftId = plan.id;
        expectEqual(plan.selectionMethod, 'ranking-order-v1', 'selection method');
        expectEqual(plan.rankingId, RANK_ONE, 'ranking id on the plan');
        expectEqual(plan.rankingWeekKey, PLANNER_WEEK, 'ranking week on the plan');
        const inDraft = stopsOf(plan).map((st) => st.retailerId).sort();
        expectEqual(JSON.stringify(inDraft), JSON.stringify(RANKED.slice(0, 18).map((r) => r.id).sort()), 'shops in the draft (ranks 1 to 18)');
        RANKED.slice(0, 18).forEach((r, i) => expectEqual(dayOf(plan, r.id), Math.floor(i / 3), `day of rank ${i + 1} (${r.name})`));
        const overdue = stopsOf(plan).find((st) => st.retailerId === OVERDUE.id);
        expectEqual(
          overdue.reason,
          `Reorder overdue: ${PRODUCTS[1].name}, usually orders every 14 days, last order 30 days ago. Expected order RM ${600 - 2 * 10}.`,
          'reason of the stop with an overdue insight',
        );
        for (const st of stopsOf(plan)) {
          if (/W\d\d|week/i.test(st.reason)) throw new Error(`the reason of ${st.retailerName} names a week: ${st.reason}`);
          if (st.reason.startsWith('Prioritised:')) throw new Error(`the reason of ranked ${st.retailerName} is the formula text: ${st.reason}`);
        }
        const first = stopsOf(plan).find((st) => st.retailerId === RANKED[0].id);
        expectEqual(first.reason, `Expected order RM ${600 - 10}. Last order 11 days ago.`, 'reason of rank 1');
      });

      await t.step('"Add" on the flagged line puts the shop on the route with its insight as the reason', async () => {
        await planner.page.getByRole('button', { name: `Add ${LEFT_OUT.name}`, exact: true }).click();
        await B.see(planner.page, `1 ranked shop left out: ${NO_PIN.name} (no coordinates).`);
        await expectAbsent(planner.page, /Flagged, not on this route/, 'the flagged line after the shop was added');
        await planner.page.getByRole('button', { name: 'Save changes' }).click();
        const plan = await db.waitForDoc('route_plans', firstDraftId, (p) => stopsOf(p).some((st) => st.retailerId === LEFT_OUT.id), { label: 'flagged shop saved' });
        const added = stopsOf(plan).find((st) => st.retailerId === LEFT_OUT.id);
        expectEqual(added.reason, `Stopped product: ${PRODUCTS[1].name}. Added by the manager.`, 'reason of the added shop');
        expectEqual(new Set(plan.stopIds).size, plan.stopIds.length, 'unique stop ids after the add');
      });

      await t.step('"Move to" moves a stop to another day, and both days are ordered and timed again', async () => {
        const before = await db.get('route_plans', firstDraftId);
        const moved = RANKED[0];
        const from = dayOf(before, moved.id);
        const to = 3;
        expectEqual(from, 0, 'day of rank 1 before the move');
        const fromCount = before.days[from].stops.length;
        const toCount = before.days[to].stops.length;
        await planner.page.getByRole('button', { name: `Move ${moved.name} to another day` }).click();
        await planner.page.getByRole('menuitem', { name: `Move to ${WEEKDAYS[to]}`, exact: true }).click();
        await B.see(planner.page, `${moved.name} moved to ${WEEKDAYS[to]}.`);
        await t.shot(planner, 'after-move');
        await planner.page.getByRole('button', { name: 'Save changes' }).click();
        const plan = await db.waitForDoc('route_plans', firstDraftId, (p) => dayOf(p, moved.id) === to, { label: 'moved stop saved' });
        expectEqual(plan.days[from].stops.length, fromCount - 1, 'stops on the day the stop left');
        expectEqual(plan.days[to].stops.length, toCount + 1, 'stops on the day the stop joined');
        for (const index of [from, to]) {
          const day = plan.days[index];
          expectEqual(JSON.stringify(day.stops.map((st) => st.sequence)), JSON.stringify(day.stops.map((_, i) => i + 1)), `sequence numbers on ${day.dayLabel}`);
          expectEqual(day.totalRetailers, day.stops.length, `stop count on ${day.dayLabel}`);
          expectEqual(day.orderMethod, 'exact-v1', `order method on ${day.dayLabel}`);
          expectNear(day.totalDistanceKm, pathKm(day.stops), 0.06, `distance of ${day.dayLabel}`);
          expectNear(day.totalDistanceKm, shortestKm(day.stops), 0.06, `distance of ${day.dayLabel} against the shortest order`);
          expectEqual(day.stops[0].arrival, '09:00', `first arrival on ${day.dayLabel}`);
          for (const st of day.stops) expectEqual(st.dayId, WEEKDAYS[index].toLowerCase(), `day id of ${st.retailerName}`);
        }
        expectNear(plan.totalDistanceKm, plan.days.reduce((sum, d) => sum + d.totalDistanceKm, 0), 0.001, 'plan distance after the move');
        expectEqual(new Set(plan.stopIds).size, plan.stopIds.length, 'unique stop ids after the move');
        expectEqual(plan.totalStops, 19, 'stops in the plan after the move');
      });

      await t.step('"Things to check" names the over-full Thursday and the straight-line days; moving the stop back to Monday clears the Thursday line', async () => {
        const page = planner.page;
        const moved = RANKED[0];
        const before = await db.get('route_plans', firstDraftId);
        expectEqual(dayOf(before, moved.id), 3, `day of ${moved.name} before the check`);
        const lines = checkLines(before, 3);
        const thursday = `Thursday has ${before.days[3].stops.length} stops. The most is 3.`;
        if (!lines.includes(thursday)) throw new Error(`expected "${thursday}" among ${JSON.stringify(lines)}`);
        if (!lines.some((line) => /^Distances on .* are straight-line estimates\.$/.test(line))) throw new Error(`no estimate line among ${JSON.stringify(lines)}`);
        await B.see(page, `Things to check (${lines.length})`);
        for (const line of lines) await B.see(page, line);
        await t.shot(planner, 'things-to-check');
        await expectAbsent(page, new RegExp(`^Move ${moved.name} to another day$`), `the move button of ${moved.name} while Monday is open`);
        await page.getByRole('button', { name: 'Show Thursday', exact: true }).first().click();
        await page.getByRole('button', { name: `Move ${moved.name} to another day` }).click({ timeout: 10000 });
        await page.getByRole('menuitem', { name: `Move to ${WEEKDAYS[0]}`, exact: true }).click();
        await B.see(page, `${moved.name} moved to ${WEEKDAYS[0]}.`);
        await page.getByRole('button', { name: 'Save changes' }).click();
        const after = await db.waitForDoc('route_plans', firstDraftId, (p) => dayOf(p, moved.id) === 0, { label: 'stop moved back to Monday' });
        if (after.days[3].stops.length > 3) throw new Error(`Thursday still has ${after.days[3].stops.length} stops after the move back`);
        const left = checkLines(after, 3);
        await expectAbsent(page, new RegExp(`^${thursday.replace(/\./g, '\\.')}$`), 'the Thursday line after the stop went back to Monday');
        await B.see(page, left.length ? `Things to check (${left.length})` : 'Nothing to check.');
        for (const line of left) await B.see(page, line);
        await t.shot(planner, 'things-to-check-after-fix');
      });

      await t.step('with the draft open at 390 and 2000 px wide, the checks box, the day row, the first stop and the map are there and no text is cut at the right edge', async () => {
        const page = planner.page;
        const original = page.viewportSize();
        const lines = checkLines(await db.get('route_plans', firstDraftId), 3);
        for (const [width, height] of [[390, 844], [2000, 1100]]) {
          await page.setViewportSize({ width, height });
          await page.waitForTimeout(900);
          const parts = [
            ['the box title', B.semantic(page, lines.length ? `Things to check (${lines.length})` : 'Things to check')],
            ['the day row', page.getByRole('button', { name: /^(Mon|Tues|Wednes|Thurs|Fri|Satur)day .* kilometres$/ }).first()],
            ['the first stop row', page.getByRole('button', { name: /^Remove / }).first()],
            ['a stop on the map', page.getByRole('button', { name: /^Stop \d+, / }).first()],
            ...lines.map((line) => [`the line "${line}"`, page.getByText(line, { exact: true }).first()]),
          ];
          for (const [what, locator] of parts) {
            try {
              await locator.waitFor({ state: 'attached', timeout: 10000 });
            } catch {
              throw new Error(`${what} is not on the page at ${width} px`);
            }
          }
          for (const [what, locator] of parts.filter(([what]) => what !== 'a stop on the map')) {
            const box = await locator.boundingBox();
            if (!box) throw new Error(`${what} has no box at ${width} px`);
            if (box.x < 0 || box.x + box.width > width + 0.5) {
              throw new Error(`${what} is cut by the ${width} px viewport: x=${box.x}, right edge ${box.x + box.width}`);
            }
          }
          await t.shot(planner, `draft-${width}px`);
        }
        await page.setViewportSize(original);
        await page.waitForTimeout(600);
      });

      await t.step('the manager fixes every line it can: each removed extra stop takes one line off the count, and only the straight-line estimate line stays (the E2E build has no road service)', async () => {
        const page = planner.page;
        const overLimit = /^(\w+day) has \d+ stops\. The most is 3\.$/;
        const estimate = /^Distances on .* are straight-line estimates\.$/;
        const nearest = /^(.+) was put on (\w+day) with the nearest shops\. Check that the day suits it\.$/;
        const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
        const start = checkLines(await db.get('route_plans', firstDraftId), 3);
        const unfixable = start.filter((line) => !overLimit.test(line) && !nearest.test(line) && !estimate.test(line));
        if (unfixable.length) throw new Error(`lines this step has no fix for: ${JSON.stringify(start)}`);
        const overLine = start.find((line) => overLimit.test(line));
        if (!overLine) throw new Error(`no over-limit line to fix among ${JSON.stringify(start)}`);
        const fullDay = overLimit.exec(overLine)[1];
        const fullIndex = WEEKDAYS.indexOf(fullDay);
        for (const line of start.filter((l) => nearest.test(l))) {
          const [, name, dayLabel] = nearest.exec(line);
          const count = checkLines(await db.get('route_plans', firstDraftId), 3).length;
          await page.getByRole('button', { name: `Show ${dayLabel}`, exact: true }).first().click();
          await page.getByRole('button', { name: `Move ${name} to another day` }).click({ timeout: 10000 });
          await page.getByRole('menuitem', { name: `Move to ${fullDay}`, exact: true }).click();
          await B.see(page, `${name} moved to ${fullDay}.`);
          await expectAbsent(page, new RegExp(`^${escapeRegex(line)}$`), `"${line}" after the manager moved the shop`);
          await B.see(page, `Things to check (${count - 1})`);
          await page.getByRole('button', { name: 'Save changes' }).click();
          const saved = await db.waitForDoc('route_plans', firstDraftId, (p) => (p.days[fullIndex].stops || []).some((st) => st.retailerName === name), { label: `${name} moved to ${fullDay}` });
          const movedStop = saved.days[fullIndex].stops.find((st) => st.retailerName === name);
          if (movedStop.reason.includes('Placed with the nearest shops.')) throw new Error(`the stored reason of ${name} still says nearest shops: ${movedStop.reason}`);
          if (!movedStop.reason.endsWith('Placed by the manager.')) throw new Error(`the stored reason of ${name} does not say the manager placed it: ${movedStop.reason}`);
        }
        await page.getByRole('button', { name: `Show ${fullDay}`, exact: true }).first().click();
        for (;;) {
          const current = await db.get('route_plans', firstDraftId);
          const stops = current.days[fullIndex].stops;
          if (stops.length <= 3) break;
          const count = checkLines(current, 3).length;
          const line = `${fullDay} has ${stops.length} stops. The most is 3.`;
          const extra = stops[stops.length - 1];
          await page.getByRole('button', { name: `Remove ${extra.retailerName}`, exact: true }).click({ timeout: 10000 });
          await expectAbsent(page, new RegExp(`^${escapeRegex(line)}$`), `"${line}" after the extra stop was removed`);
          await B.see(page, stops.length - 1 > 3 ? `${fullDay} has ${stops.length - 1} stops. The most is 3.` : `Things to check (${count - 1})`);
          await page.getByRole('button', { name: 'Save changes' }).click();
          await db.waitForDoc('route_plans', firstDraftId, (p) => p.days[fullIndex].stops.length === stops.length - 1, { label: `${fullDay} after the extra stop was removed` });
        }
        const remaining = checkLines(await db.get('route_plans', firstDraftId), 3);
        expectEqual(remaining.length, 1, `lines left after the fixes (${JSON.stringify(remaining)})`);
        if (!estimate.test(remaining[0])) throw new Error(`the line left is not the estimate line: ${remaining[0]}`);
        await B.see(page, 'Things to check (1)');
        await page.getByText(remaining[0], { exact: true }).first().waitFor({ state: 'attached', timeout: 10000 });
        await t.shot(planner, 'things-to-check-all-fixed');
      });

      await t.step('24 places: every ranked shop with a pin is in, and the zero-score shop comes after with "Not in the weekly ranking"', async () => {
        await planner.page.getByRole('button', { name: 'Plan settings' }).click();
        await planner.page.getByRole('button', { name: 'More max stops per day' }).click();
        await generate(planner);
        await B.see(planner.page, `1 ranked shop left out: ${NO_PIN.name} (no coordinates).`);
        await expectAbsent(planner.page, /Flagged, not on this route/, 'the flagged line when the flagged shop is on the route');
        await planner.page.getByRole('button', { name: 'Save draft' }).click();
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code && p.totalStops === 20, { label: 'draft with 20 stops' });
        planId = plan.id;
        await db.del('route_plans', firstDraftId);
        const stops = stopsOf(plan);
        for (const r of RANKED) {
          const st = stops.find((x) => x.retailerId === r.id);
          if (!st) throw new Error(`${r.name} is ranked and has a pin, but it is not in the draft`);
          if (st.reason.startsWith('Not in the weekly ranking')) throw new Error(`${r.name} is ranked, but its reason says it is not`);
        }
        const zero = stops.find((x) => x.retailerId === ZERO.id);
        if (!zero) throw new Error('the zero-score shop is not in the draft');
        if (!zero.reason.startsWith('Not in the weekly ranking.')) throw new Error(`the zero-score reason is: ${zero.reason}`);
        expectEqual(zero.reason, NEAREST_REASON, 'reason of the zero-score shop');
        const roomDays = plan.days
          .map((d, index) => ({ index, stops: (d.stops || []).filter((st) => st.retailerId !== ZERO.id) }))
          .filter((d) => d.stops.length > 0 && d.stops.length < 4);
        const nearest = roomDays
          .map((d) => ({ index: d.index, km: Math.min(...d.stops.map((st) => km(ZERO, st))) }))
          .sort((a, b) => a.km - b.km)[0];
        expectEqual(dayOf(plan, ZERO.id), nearest.index, 'day of the zero-score shop (the day with room whose shops are nearest)');
        for (const d of plan.days) {
          if ((d.stops || []).length > 4) throw new Error(`${d.dayLabel} has ${(d.stops || []).length} stops, more than the maximum of 4`);
        }
        await t.shot(planner, 'all-ranked-and-zero');
      });

      await t.step('approve and publish one person: the plan stores who approved and who published, and the page names them', async () => {
        await planner.page.getByRole('button', { name: 'Approve', exact: true }).click();
        const approved = await db.waitForDoc('route_plans', planId, (p) => p.status === 'approved', { label: 'approved plan' });
        expectEqual(approved.approvedByUid, seed.uids.admin, 'approvedByUid');
        await B.see(planner.page, `Approved by ${accounts.admin.name}`);
        await planner.page.getByRole('button', { name: 'Publish', exact: true }).click();
        await B.see(planner.page, 'Publish this route?');
        await planner.page.getByRole('button', { name: 'Publish', exact: true }).last().click();
        const published = await db.waitForDoc('route_plans', planId, (p) => p.status === 'published', { timeout: 30000, label: 'published plan' });
        expectEqual(published.publishedByUid, seed.uids.admin, 'publishedByUid');
        expectEqual(published.approvedByUid, seed.uids.admin, 'approvedByUid after publish');
        expectEqual(published.rankingId, RANK_ONE, 'ranking id after publish');
        await B.see(planner.page, new RegExp(`Published by ${accounts.admin.name}, \\d+ \\w+ \\d{4}, \\d\\d:\\d\\d`));
        expectEqual(published.totalStops, 20, 'stops of the published plan');
        await planner.page.getByRole('button', { name: `Next: ${SECOND.name}`, exact: true }).waitFor({ timeout: 10000 });
        await t.shot(planner, 'published-with-names');
      });

      let secondPlanId;
      await t.step('"Draft routes for everyone without one": the person with a published route is skipped by name, the other gets a saved draft from the ranking of the week before', async () => {
        const before = await plansOf(accounts.salesman.code);
        await openTeamAction(planner.page);
        await planner.page.getByRole('button', { name: 'Cancel', exact: true }).last().click();
        expectEqual((await plansOf(SECOND.code)).length, 0, 'plans of the second salesperson after "Cancel"');
        await planTheWeek(planner.page);
        await B.see(planner.page, 'Already has a published route.', { timeout: 60000 });
        await B.see(planner.page, 'Draft made.');
        await B.see(planner.page, SECOND.name);
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === SECOND.code, { label: 'draft of the second salesperson' });
        secondPlanId = plan.id;
        expectEqual(plan.status, 'draft', 'status of the team draft');
        expectEqual(plan.salesmanUid, secondUid, 'salesperson of the team draft');
        expectEqual(plan.createdByUid, seed.uids.admin, 'creator of the team draft');
        expectEqual(plan.rankingId, RANK_TWO, 'ranking id of the team draft');
        expectEqual(plan.rankingWeekKey, WEEK_BEFORE, 'ranking week of the team draft (the week before the planner week)');
        expectEqual(JSON.stringify(stopsOf(plan).map((st) => st.retailerId).sort()), JSON.stringify(SECOND_SHOPS.map((r) => r.id).sort()), 'shops of the team draft');
        const after = await plansOf(accounts.salesman.code);
        expectEqual(JSON.stringify(after.map((p) => [p.id, p.status]).sort()), JSON.stringify(before.map((p) => [p.id, p.status]).sort()), 'plans of the skipped person');
        expectEqual((await plansOf(SECOND.code)).length, 1, 'plans of the second salesperson');
        expectEqual(plan.totalStops, 2, 'stops of the team draft');
        await t.shot(planner, 'plan-the-week');
        await closeTeamResults(planner.page);
      });

      await t.step('"Draft routes for everyone without one" a second time replaces nothing: both people are skipped by name', async () => {
        await planTheWeek(planner.page);
        await B.see(planner.page, 'Already has a draft route.', { timeout: 60000 });
        await B.see(planner.page, 'Already has a published route.');
        expectEqual((await plansOf(SECOND.code)).length, 1, 'plans of the second salesperson after the second run');
        await closeTeamResults(planner.page);
      });

      await t.step('"Next: <name>" opens the saved draft of the next person, with Approve and Publish for that one person', async () => {
        await planner.page.getByRole('button', { name: `Next: ${SECOND.name}`, exact: true }).click();
        for (const r of SECOND_SHOPS) await B.see(planner.page, r.name);
        await B.see(planner.page, `Ranked for week ${WEEK_BEFORE}`);
        await planner.page.getByRole('button', { name: 'Approve', exact: true }).click();
        const approved = await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'approved', { label: 'second plan approved' });
        expectEqual(approved.approvedByUid, seed.uids.admin, 'approvedByUid of the second plan');
        expectEqual((await db.get('route_plans', planId)).status, 'published', 'the first plan after the second was approved');
      });

      await t.step('"Back to draft" removes who approved; "Withdraw to edit" keeps the two ids in the store, a draft never shows them, and the next approve and publish write them again', async () => {
        const page = planner.page;
        const publish = async () => {
          await page.getByRole('button', { name: 'Publish', exact: true }).click();
          await B.see(page, 'Publish this route?');
          await page.getByRole('button', { name: 'Publish', exact: true }).last().click();
          return db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'published', { timeout: 30000, label: 'second plan published' });
        };
        await B.see(page, `Approved by ${accounts.admin.name}`);
        await page.getByRole('button', { name: 'Back to draft', exact: true }).click();
        const draft = await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'draft', { label: 'second plan back to draft' });
        for (const key of ['approvedByUid', 'approvedAt']) {
          if (draft[key] != null) throw new Error(`a route moved back to draft still stores ${key}: ${JSON.stringify(draft[key])}`);
        }
        await expectAbsent(page, /Approved by/, 'the approver line on a draft');
        await page.getByRole('button', { name: 'Approve', exact: true }).click();
        const approved = await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'approved', { label: 'second plan approved again' });
        expectEqual(approved.approvedByUid, seed.uids.admin, 'approvedByUid after the second approve');
        const published = await publish();
        expectEqual(published.publishedByUid, seed.uids.admin, 'publishedByUid of the second plan');
        await page.getByRole('button', { name: 'Withdraw to edit', exact: true }).click();
        const withdrawn = await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'draft', { label: 'second plan withdrawn' });
        for (const key of ['approvedAt', 'publishedAt']) {
          if (withdrawn[key] != null) throw new Error(`a withdrawn route still stores ${key}: ${JSON.stringify(withdrawn[key])}`);
        }
        expectEqual(withdrawn.approvedByUid, seed.uids.admin, 'approvedByUid kept by withdraw (the rules allow four changed keys)');
        expectEqual(withdrawn.publishedByUid, seed.uids.admin, 'publishedByUid kept by withdraw (the rules allow four changed keys)');
        await expectAbsent(page, /Approved by/, 'the approver line on a withdrawn draft');
        await expectAbsent(page, /Published by/, 'the publisher line on a withdrawn draft');
        await t.shot(planner, 'withdrawn-draft-without-names');
        const { id: _docId, ...stored } = withdrawn;
        await db.put('route_plans', secondPlanId, { ...stored, approvedByUid: 'uid-earlier-approver', publishedByUid: 'uid-earlier-publisher' });
        await page.getByRole('button', { name: 'Approve', exact: true }).click();
        const again = await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'approved', { label: 'withdrawn plan approved' });
        expectEqual(again.approvedByUid, seed.uids.admin, 'approvedByUid written again by the approve after a withdraw');
        const republished = await publish();
        expectEqual(republished.publishedByUid, seed.uids.admin, 'publishedByUid written again by the publish after a withdraw');
        expectEqual(republished.approvedByUid, seed.uids.admin, 'approvedByUid after the publish that follows a withdraw');
      });

      await t.step('"Delete draft": a published plan offers none; a saved draft asks first, names the salesperson and the week, and is gone from Saved plans and the store', async () => {
        const page = planner.page;
        const plannerMonday = new Date(thisMonday + 7 * DAY + KL);
        const mondayLabel = `${plannerMonday.getUTCDate()} ${['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][plannerMonday.getUTCMonth()]}`;
        await page.getByRole('button', { name: 'Saved plans', exact: true }).click();
        await B.see(page, 'Saved plans for this salesman');
        await expectAbsent(page, /^Delete draft$/, 'a delete button beside a published plan');
        await page.getByRole('button', { name: 'Plan', exact: true }).click();
        await page.getByRole('button', { name: 'Withdraw to edit', exact: true }).click();
        await db.waitForDoc('route_plans', secondPlanId, (p) => p.status === 'draft', { label: 'second plan withdrawn before the delete' });
        await page.getByRole('button', { name: 'Saved plans', exact: true }).click();
        await page.getByRole('button', { name: 'Delete draft', exact: true }).first().click();
        await B.see(page, 'Delete this draft?');
        await B.see(page, SECOND.name);
        await B.see(page, new RegExp(`^${mondayLabel} – `));
        await page.getByRole('button', { name: 'Keep draft', exact: true }).click();
        expectEqual((await db.get('route_plans', secondPlanId))?.status, 'draft', 'the draft after "Keep draft"');
        await page.getByRole('button', { name: 'Delete draft', exact: true }).first().click();
        await B.see(page, 'Delete this draft?');
        await page.getByRole('button', { name: 'Delete draft', exact: true }).last().click();
        await B.see(page, 'Draft deleted.', { timeout: 20000 });
        const end = Date.now() + 20000;
        while ((await db.get('route_plans', secondPlanId)) !== null) {
          if (Date.now() > end) throw new Error('the deleted draft is still in the store');
          await page.waitForTimeout(200);
        }
        await B.see(page, 'No saved plans yet');
        await expectAbsent(page, /^Delete draft$/, 'a delete button after the draft was deleted');
        await t.shot(planner, 'draft-deleted');
      });

      await t.step('a ranking two weeks older than the planner week counts as no ranking', async () => {
        const stale = await db.get('retailer_priority_rankings', RANK_TWO);
        await db.put('retailer_priority_rankings', RANK_TWO, { ...stale, weekKey: TWO_WEEKS_OLD });
        await db.del('route_plans', secondPlanId);
        const s = await openPlanner('stale-ranking');
        expectEqual((await plansOf(SECOND.code)).length, 0, `plans of ${SECOND.name} before the draft with a stale ranking`);
        await pickPerson(s.page, SECOND.name);
        await generate(s);
        for (const r of SECOND_SHOPS) await B.see(s.page, r.name);
        await expectAbsent(s.page, /Ranked for week/, 'the ranked-for-week line with a ranking two weeks old');
        await s.page.getByRole('button', { name: 'Save draft' }).click();
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === SECOND.code && p.status === 'draft', { label: 'draft with no ranking' });
        owned.push(['route_plans', plan.id]);
        for (const key of ['selectionMethod', 'rankingId', 'rankingWeekKey']) {
          if (plan[key] != null) throw new Error(`a plan made with no ranking stores ${key}: ${JSON.stringify(plan[key])}`);
        }
        for (const st of stopsOf(plan)) {
          if (!st.reason.startsWith('Prioritised: ')) throw new Error(`with no ranking the reason must be the formula text, got: ${st.reason}`);
        }
        expectEqual(JSON.stringify(stopsOf(plan).map((st) => st.retailerId).sort()), JSON.stringify(SECOND_SHOPS.map((r) => r.id).sort()), 'shops of the draft with no ranking');
        await t.shot(s, 'stale-ranking');
      });

      const person = async (rep) => {
        const uid = await putPerson(db, rep, { supervisorUid: seed.uids.supervisor, supervisorCode: ACCOUNTS.supervisor.code });
        owned.push(['users', rep.email], ['user_access', uid]);
        return uid;
      };
      const draftFor = async (rep, name) => {
        const s = await openPlanner(name);
        expectEqual((await plansOf(rep.code)).length, 0, `plans of ${rep.name} before the draft`);
        await pickPerson(s.page, rep.name);
        for (let i = 0; i < 3; i += 1) await s.page.getByRole('button', { name: 'Fewer max stops per day' }).click();
        await generate(s);
        return s;
      };
      const savedDraft = async (s, rep) => {
        await s.page.getByRole('button', { name: 'Save draft' }).click();
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === rep.code && p.status === 'draft', { label: `draft of ${rep.name}` });
        owned.push(['route_plans', plan.id]);
        return plan;
      };
      const plannerDay = (index) => new Date(thisMonday + (7 + index) * DAY + KL).toISOString().slice(0, 10);

      await t.step('rank order across areas: areas come in the order of their best-ranked shop, and a shop with no rank never moves a ranked shop to a later day', async () => {
        const uid = await person(AREA_REP);
        for (const r of [AREA.a1, AREA.b2, AREA.a3, AREA.b4, AREA.a5]) await put('retailers', r.id, shop(r, AREA_REP, uid));
        for (const r of [AREA.noRow, AREA.zero]) await put('retailers', r.id, shop(r, AREA_REP, uid, { monthlyValue: 99000 }));
        await put('retailer_priority_rankings', 'rank-route-team-s003', ranking('rank-route-team-s003', AREA_REP, uid, PLANNER_WEEK, [
          row(AREA.a1, 1), row(AREA.b2, 2), row(AREA.a3, 3), row(AREA.b4, 4), row(AREA.a5, 5), row(AREA.zero, 6, ZERO_ROW),
        ]));
        const s = await draftFor(AREA_REP, 'area-order');
        await B.see(s.page, `Ranked for week ${PLANNER_WEEK}`);
        await B.see(s.page, AREA_LINE_RE);
        await t.shot(s, 'area-order');
        const plan = await savedDraft(s, AREA_REP);
        expectEqual(plan.totalStops, 7, 'stops of the area-order draft');
        for (const [key, day] of [['a1', 0], ['a3', 0], ['a5', 0], ['b2', 1], ['b4', 1]]) {
          expectEqual(dayOf(plan, AREA[key].id), day, `day of ${AREA[key].name}`);
        }
        expectEqual(JSON.stringify([dayOf(plan, AREA.noRow.id), dayOf(plan, AREA.zero.id)].sort()), JSON.stringify([1, 2]), 'days of the two shops with no rank (Monday is full, so the first joins the Tabuan day, which then is full too)');
        for (const d of plan.days) {
          if ((d.stops || []).length > 3) throw new Error(`${d.dayLabel} has ${(d.stops || []).length} stops, more than the maximum of 3`);
        }
        for (const key of ['noRow', 'zero']) {
          const st = stopsOf(plan).find((x) => x.retailerId === AREA[key].id);
          expectEqual(st.reason, NEAREST_REASON, `the reason of ${AREA[key].name}`);
        }
      });

      await t.step('usual order day in rank order: a ranked shop takes its usual day from a lower-ranked stop that is there only by area, and never from a higher-ranked one', async () => {
        const uid = await person(ORDER_DAY_REP);
        for (const r of ORDER_DAY) await put('retailers', r.id, shop(r, ORDER_DAY_REP, uid));
        await put('retailer_priority_rankings', 'rank-route-team-s004', ranking('rank-route-team-s004', ORDER_DAY_REP, uid, PLANNER_WEEK, ORDER_DAY.map((r, i) => row(r, i + 1))));
        for (const [index, weekday] of [[1, 2], [3, 1], [4, 1]]) {
          const r = ORDER_DAY[index];
          await put('visit_briefs', `brief-route-team-${r.id}`, {
            briefId: `brief-route-team-${r.id}`, retailerId: r.id, retailerName: r.name,
            salesmanUid: uid, salesmanCode: ORDER_DAY_REP.code, branchId: BRANCH.id, status: 'active', isActive: true,
            insightCount: 0, highPriorityCount: 0, totalValueAtRiskRm: 0, isDemo: false, updatedAt: new Date(), generatedAt: new Date(),
            emptyStateHeadline: '', emptyStateBody: '', focusItems: [], replenishment: [],
            usualOrderWeekday: weekday, usualOrderWeekdayVersion: 'order-day/1.0.0',
          });
        }
        const s = await draftFor(ORDER_DAY_REP, 'usual-order-day');
        await t.shot(s, 'usual-order-day');
        const plan = await savedDraft(s, ORDER_DAY_REP);
        [0, 1, 0, 0, 1, 1].forEach((day, i) => expectEqual(dayOf(plan, ORDER_DAY[i].id), day, `day of rank ${i + 1} (${ORDER_DAY[i].name})`));
        const reasonOf = (i) => stopsOf(plan).find((x) => x.retailerId === ORDER_DAY[i].id).reason;
        if (!reasonOf(1).includes('Usual order day: Tuesday')) throw new Error(`the reason of rank 2 is: ${reasonOf(1)}`);
        if (!reasonOf(3).includes('Usual order day: Monday')) throw new Error(`the reason of rank 4 is: ${reasonOf(3)}`);
        if (!reasonOf(4).includes('Usual order day: Monday')) throw new Error(`the reason of rank 5 is: ${reasonOf(4)}`);
      });

      await t.step('19 due follow-ups and 18 places: the follow-up beyond the places, and one for a shop with no pin, are named with "Place" and "Leave out", and the choice is saved', async () => {
        const uid = await person(FOLLOW_UP_REP);
        const last = FOLLOW_UP[18];
        for (const r of [...FOLLOW_UP, FOLLOW_UP_NO_PIN]) await put('retailers', r.id, shop(r, FOLLOW_UP_REP, uid));
        await put('retailer_priority_rankings', 'rank-route-team-s005', ranking('rank-route-team-s005', FOLLOW_UP_REP, uid, PLANNER_WEEK, FOLLOW_UP.map((r, i) => row(r, i + 1))));
        const followUp = (r, dayIndex) => put('conversation_outcomes', `fu-route-team-${r.id}`, {
          outcomeId: `fu-route-team-${r.id}`, retailerId: r.id, retailerName: r.name,
          productId: PRODUCTS[1].id, productName: PRODUCTS[1].name, reasonCode: 'retailer_busy', note: 'Come back',
          salesmanUid: uid, salesmanCode: FOLLOW_UP_REP.code, branchId: BRANCH.id,
          followUpDate: plannerDay(dayIndex), followUpStatus: 'open', isDemo: false, submittedAt: new Date(),
        });
        for (let i = 0; i < 18; i += 1) await followUp(FOLLOW_UP[i], Math.floor(i / 3));
        await followUp(last, 2);
        await followUp(FOLLOW_UP_NO_PIN, 3);
        const s = await draftFor(FOLLOW_UP_REP, 'follow-up-beyond-places');
        await B.see(s.page, /2 follow-ups not placed: /);
        for (const r of [last, FOLLOW_UP_NO_PIN]) {
          await s.page.getByRole('button', { name: `Place ${r.name}`, exact: true }).waitFor({ timeout: 10000 });
          await s.page.getByRole('button', { name: `Leave out ${r.name} this week`, exact: true }).waitFor({ timeout: 10000 });
        }
        await t.shot(s, 'follow-ups-not-placed');
        await s.page.getByRole('button', { name: `Place ${FOLLOW_UP_NO_PIN.name}`, exact: true }).click();
        await B.see(s.page, `${FOLLOW_UP_NO_PIN.name} is not an active shop with coordinates.`);
        await s.page.getByRole('button', { name: `Leave out ${last.name} this week`, exact: true }).click();
        await B.see(s.page, /1 follow-up not placed: /);
        await B.see(s.page, /Follow-up left out this week: /);
        const plan = await savedDraft(s, FOLLOW_UP_REP);
        expectEqual(JSON.stringify(stopsOf(plan).map((st) => st.retailerId).sort()), JSON.stringify(FOLLOW_UP.slice(0, 18).map((r) => r.id).sort()), 'shops on the plan (the 18 best-ranked follow-ups)');
        FOLLOW_UP.slice(0, 18).forEach((r, i) => expectEqual(dayOf(plan, r.id), Math.floor(i / 3), `day of ${r.name} (its follow-up date)`));
        const decisions = [...(plan.followUpsNotPlaced || [])].sort((a, b) => a.retailerId.localeCompare(b.retailerId));
        expectEqual(
          JSON.stringify(decisions.map((d) => [d.retailerId, d.retailerName, d.followUpDate, d.choice == null ? '' : d.choice])),
          JSON.stringify([
            [last.id, last.name, plannerDay(2), 'left_out'],
            [FOLLOW_UP_NO_PIN.id, FOLLOW_UP_NO_PIN.name, plannerDay(3), ''],
          ]),
          'saved follow-up decisions',
        );
      });

      await t.step('a ranking for the week that holds only the shops of other people counts as no ranking, and the page says so in one line', async () => {
        const uid = await person(OTHERS_ONLY_REP);
        for (const r of OTHERS_ONLY) await put('retailers', r.id, shop(r, OTHERS_ONLY_REP, uid));
        await put('retailer_priority_rankings', 'rank-route-team-s006', ranking('rank-route-team-s006', OTHERS_ONLY_REP, uid, PLANNER_WEEK, [
          ...SECOND_SHOPS.map((r, i) => row(r, i + 1)),
          row(OTHERS_ONLY[0], 3, ZERO_ROW),
        ]));
        const s = await draftFor(OTHERS_ONLY_REP, 'ranking-of-other-shops');
        for (const r of OTHERS_ONLY) await B.see(s.page, r.name);
        await B.see(s.page, NOT_USED_LINE);
        await expectAbsent(s.page, /Ranked for week/, 'the ranked-for-week line with a ranking of other shops');
        await expectAbsent(s.page, AREA_LINE_RE, 'the area-order line with a ranking of other shops');
        await expectAbsent(s.page, /ranked shops? left out/, 'the left-out line with a ranking of other shops');
        await t.shot(s, 'ranking-of-other-shops');
        const plan = await savedDraft(s, OTHERS_ONLY_REP);
        for (const key of ['selectionMethod', 'rankingId', 'rankingWeekKey']) {
          if (plan[key] != null) throw new Error(`a plan made with a ranking of other shops stores ${key}: ${JSON.stringify(plan[key])}`);
        }
        expectEqual(JSON.stringify(stopsOf(plan).map((st) => st.retailerId).sort()), JSON.stringify(OTHERS_ONLY.map((r) => r.id).sort()), 'shops of the draft');
        for (const st of stopsOf(plan)) {
          if (st.reason.startsWith('Not in the weekly ranking')) throw new Error(`the reason of ${st.retailerName} is: ${st.reason}`);
          if (!st.reason.startsWith('Prioritised: ')) throw new Error(`the reason must be the formula text, got: ${st.reason}`);
        }
        othersS = s;
        othersPlanId = plan.id;
      });

      await t.step('while "Save changes" waits for the store, the stop list offers no remove or move, and afterwards the store holds the plan on the screen', async () => {
        const page = othersS.page;
        const lone = OTHERS_ONLY[0];
        const remove = page.getByRole('button', { name: `Remove ${lone.name}`, exact: true });
        const move = page.getByRole('button', { name: `Move ${lone.name} to another day` });
        await remove.waitFor({ timeout: 10000 });
        await move.waitFor({ timeout: 10000 });
        const held = [];
        let holding = true;
        const writes = (url) => url.pathname.includes('/google.firestore.v1.Firestore/Write/channel');
        const hold = async (route) => {
          if (holding && route.request().method() === 'POST') await new Promise((release) => held.push(release));
          await route.fallback();
        };
        await page.route(writes, hold);
        try {
          await page.getByRole('button', { name: 'Save changes', exact: true }).click();
          const end = Date.now() + 20000;
          while (held.length === 0) {
            if (Date.now() > end) throw new Error('the save sent no write to the store');
            await page.waitForTimeout(100);
          }
          await B.see(page, lone.name);
          await remove.waitFor({ state: 'detached', timeout: 10000 })
            .catch(() => { throw new Error(`"Remove ${lone.name}" offered while the save waits for the store`); });
          await move.waitFor({ state: 'detached', timeout: 10000 })
            .catch(() => { throw new Error(`"Move ${lone.name} to another day" offered while the save waits for the store`); });
          await t.shot(othersS, 'save-in-progress');
        } finally {
          holding = false;
          for (const release of held.splice(0)) release();
          await page.unroute(writes, hold);
        }
        await remove.waitFor({ timeout: 20000 });
        const stored = await db.get('route_plans', othersPlanId);
        expectEqual(JSON.stringify(stopsOf(stored).map((st) => st.retailerId).sort()), JSON.stringify(OTHERS_ONLY.map((r) => r.id).sort()), 'shops of the stored draft after the save');
        for (const r of OTHERS_ONLY) await B.see(page, r.name);
      });

      await t.step('a Scout request for another salesperson while "Save changes" waits for the store waits too: the save finishes for the first person, then the planner opens the other one', async () => {
        const page = othersS.page;
        const lone = OTHERS_ONLY[0];
        const remove = page.getByRole('button', { name: `Remove ${lone.name}`, exact: true });
        const secondSelected = page.getByRole('button', { name: new RegExp(`(^|\\s)${SECOND.name}$`) });
        await remove.waitFor({ timeout: 10000 });
        await page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
        const scoutBox = page.getByRole('textbox').last();
        await scoutBox.waitFor({ timeout: 20000 });
        const before = await db.get('route_plans', othersPlanId);
        const held = [];
        let holding = true;
        const writes = (url) => url.pathname.includes('/google.firestore.v1.Firestore/Write/channel');
        const hold = async (route) => {
          if (holding && route.request().method() === 'POST') await new Promise((release) => held.push(release));
          await route.fallback();
        };
        await page.route(writes, hold);
        try {
          await page.getByRole('button', { name: 'Save changes', exact: true }).click();
          const end = Date.now() + 20000;
          while (held.length === 0) {
            if (Date.now() > end) throw new Error('the save sent no write to the store');
            await page.waitForTimeout(100);
          }
          const opened = await page.getByText(/Opened Route Planner/).or(page.getByLabel(/Opened Route Planner/)).count();
          await B.fillField(page, scoutBox, `plan next week for ${SECOND.name}`);
          await page.keyboard.press('Enter');
          const asked = Date.now() + 30000;
          while ((await page.getByText(/Opened Route Planner/).or(page.getByLabel(/Opened Route Planner/)).count()) <= opened) {
            if (Date.now() > asked) throw new Error('Scout did not answer "Opened Route Planner" while the save waits for the store');
            await page.waitForTimeout(150);
          }
          await page.waitForTimeout(1000);
          await B.see(page, lone.name);
          expectEqual((await admin.semanticsLines(page)).some((line) => line.endsWith(OTHERS_ONLY_REP.name)), true, `${OTHERS_ONLY_REP.name} still selected while the save waits for the store`);
          expectEqual(await secondSelected.count(), 0, `${SECOND.name} selected while the save of ${OTHERS_ONLY_REP.name} waits for the store`);
          await expectAbsent(page, new RegExp(SECOND_SHOPS[0].name), `a shop of ${SECOND.name} while the save of ${OTHERS_ONLY_REP.name} waits for the store`);
          expectEqual(await page.getByRole('button', { name: 'Try again', exact: true }).count(), 0, '"Try again" offered while the save waits for the store');
          await t.shot(othersS, 'scout-request-during-save');
        } finally {
          holding = false;
          for (const release of held.splice(0)) release();
          await page.unroute(writes, hold);
        }
        await secondSelected.first().waitFor({ timeout: 20000 });
        await expectAbsent(page, new RegExp(`^Remove ${lone.name}$`), `the plan of ${OTHERS_ONLY_REP.name} shown with ${SECOND.name} selected after the save`);
        await expectAbsent(page, new RegExp(OTHERS_ONLY[1].name), `a shop of ${OTHERS_ONLY_REP.name} shown with ${SECOND.name} selected after the save`);
        await page.getByRole('button', { name: 'Generate draft route', exact: true }).waitFor({ timeout: 10000 });
        const stored = await db.get('route_plans', othersPlanId);
        expectEqual(stored.salesmanUid, before.salesmanUid, 'salesperson of the stored draft after the save');
        expectEqual(stored.salesmanCode, OTHERS_ONLY_REP.code, 'salesperson code of the stored draft after the save');
        expectEqual(stored.status, 'draft', 'status of the stored draft after the save');
        expectEqual(JSON.stringify(stopsOf(stored).map((st) => [st.retailerId, st.dayId, st.sequence])), JSON.stringify(stopsOf(before).map((st) => [st.retailerId, st.dayId, st.sequence])), 'stops of the stored draft after the save');
        expectEqual((await plansOf(OTHERS_ONLY_REP.code)).length, 1, `plans of ${OTHERS_ONLY_REP.name} after the save`);
        await t.shot(othersS, 'scout-request-applied-after-save');
      });

      await t.step('a ranking read that cannot be read in full is an error on the page, and no route is generated', async () => {
        for (let i = 0; i < 200; i += 1) {
          const id = `rank-route-team-fill-${i}`;
          await put('retailer_priority_rankings', id, ranking(id, { code: `S9${String(i).padStart(3, '0')}` }, `uid-fill-${i}`, PLANNER_WEEK, [row(SECOND_SHOPS[0], 1)]));
        }
        const before = (await db.list('route_plans')).length;
        const s = await openPlanner('ranking-read-failed');
        await B.see(s.page, 'Could not read the weekly ranking. No route can be generated until it is read.', { timeout: 30000 });
        await s.page.getByRole('button', { name: 'Generate draft route', exact: true }).click();
        await B.see(s.page, 'The weekly ranking could not be read. Retry it before you generate a route.');
        await expectAbsent(s.page, /^Save draft$/, 'a draft made while the ranking could not be read');
        await planTheWeek(s.page);
        await B.see(s.page, /The weekly ranking could not be read, so no route was planned\./);
        expectEqual((await db.list('route_plans')).length, before, 'route plans after the failed ranking read');
        await t.shot(s, 'ranking-read-failed');
      });
    } finally {
      for (const plan of [...(await plansOf(accounts.salesman.code)), ...(await plansOf(SECOND.code))]) {
        if (!owned.some(([collection, id]) => collection === 'route_plans' && id === plan.id)) owned.push(['route_plans', plan.id]);
      }
      for (const key of await db.list('route_plan_publication_keys')) {
        if (key.salesmanCode === accounts.salesman.code || key.salesmanCode === SECOND.code) owned.push(['route_plan_publication_keys', key.id]);
      }
      for (const [collection, id] of owned) {
        await db.del(collection, id).catch((e) => { throw new Error(`cleanup ${collection}/${id}: ${e.message}`); });
      }
    }
  },
};

function km(a, b) {
  const rad = (deg) => (deg * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return (2 * 6378137 * Math.asin(Math.sqrt(h))) / 1000;
}

function pathKm(stops) {
  let total = 0;
  for (let i = 1; i < stops.length; i += 1) total += km(stops[i - 1], stops[i]);
  return total;
}

function shortestKm(stops) {
  let best = Infinity;
  const permute = (head, rest) => {
    if (!rest.length) {
      best = Math.min(best, pathKm(head));
      return;
    }
    rest.forEach((next, i) => permute([...head, next], [...rest.slice(0, i), ...rest.slice(i + 1)]));
  };
  permute([], stops);
  return best;
}

function checkLines(plan, maxPerDay) {
  const months = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
  const clock = (value) => {
    const [h, m] = String(value || '').split(':').map(Number);
    return Number.isFinite(h) && Number.isFinite(m) ? h * 60 + m : 0;
  };
  const two = (v) => String(v).padStart(2, '0');
  const start = plan.startPoint && Number.isFinite(plan.startPoint.lat) && !(plan.startPoint.lat === 0 && plan.startPoint.lng === 0) ? plan.startPoint : null;
  const lines = [];
  plan.days.forEach((day) => {
    const stops = day.stops || [];
    if (stops.length > maxPerDay) lines.push(`${day.dayLabel} has ${stops.length} stops. The most is ${maxPerDay}.`);
    if (start && stops.length) {
      const back = clock(stops[stops.length - 1].departure) + (day.returnTravelMinutes || 0);
      if (back > 18 * 60) lines.push(`${day.dayLabel} ends at ${two(Math.floor(back / 60))}:${two(back % 60)}, after 18:00.`);
    }
    for (const st of stops) {
      if (String(st.reason || '').includes('Placed with the nearest shops.')) lines.push(`${st.retailerName} was put on ${day.dayLabel} with the nearest shops. Check that the day suits it.`);
    }
  });
  for (const row of plan.followUpsNotPlaced || []) {
    if (row.choice) continue;
    const [, m, d] = String(row.followUpDate).split('-').map(Number);
    lines.push(`The follow-up visit to ${row.retailerName} on ${d && m ? `${d} ${months[m - 1]}` : row.followUpDate} is not on the route.`);
  }
  const estimateDays = plan.days
    .filter((day) => (day.stops || []).length + (start ? 1 : 0) >= 2 && !['geoapify_routing', 'geoapify_matrix'].includes(day.estimateSource))
    .map((day) => day.dayLabel);
  if (estimateDays.length) {
    const names = estimateDays.length < 2 ? estimateDays.join('') : `${estimateDays.slice(0, -1).join(', ')} and ${estimateDays[estimateDays.length - 1]}`;
    lines.push(`Distances on ${names} are straight-line estimates.`);
  }
  return lines;
}

async function expectAbsent(page, pattern, what) {
  const locator = page.getByLabel(pattern).or(page.getByText(pattern));
  for (let i = 0; i < 25; i += 1) {
    if ((await locator.count()) === 0) return;
    await page.waitForTimeout(200);
  }
  throw new Error(`${what} is on the page, it must not be`);
}

function expectNear(actual, expected, tolerance, what) {
  if (typeof actual !== 'number' || Math.abs(actual - expected) > tolerance) {
    throw new Error(`${what}: expected ${expected.toFixed(3)} within ${tolerance}, got ${JSON.stringify(actual)}`);
  }
}

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
