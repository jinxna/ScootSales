'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];
const DAY_MS = 86400000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const FOCUS_NAME = 'Instant Baby Oat';
const OTHER_NAME = 'Regular Rolled Oat';
const SIGNAL = 'Orders dropped three weeks in a row.';
const QUESTIONS = ['Is the shelf space smaller now?', 'Did another brand take the space?'];
const RATIONALE = 'Run-rate 0.5/day projects 6 units over the gap';
const WEEKLY = [6, 6, 5, 6, 6, 6, 0, 0];
const VALUE_AT_RISK = 120;
const NEWER_TOTAL = 284.4;
const NEWER_DAYS = 12;
const BRIEF_ID = 'brief-e2e-mobile-brief';
const PLAN_ID = 'plan-e2e-mobile-brief';

const dayLabel = (d) => `${d.getDate()} ${MONTHS[d.getMonth()]}`;
const isoDate = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const escapeRegex = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

const allText = (page) => page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
  .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));

async function expectNone(page, patterns, where) {
  const texts = await allText(page);
  if (texts.length < 5) throw new Error(`${where}: the page has almost no readable text (${texts.length} nodes)`);
  for (const re of patterns) {
    const hit = texts.find((x) => re.test(x));
    if (hit) throw new Error(`${where}: found ${re} in "${hit.slice(0, 140)}"`);
  }
}

const FORBIDDEN = [/\bAI\b/, /prod-\d/, /Run-rate/i, /Reason when planned/, /ready to prefill/];

module.exports = {
  name: 'mobile_brief',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const now = new Date();
    const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
    const daysAgo = (n) => new Date(noon.getTime() - n * DAY_MS);
    const thisMonday = daysAgo((noon.getDay() + 6) % 7);
    const weekStarts = WEEKLY.map((_, i) => new Date(thisMonday.getTime() - (WEEKLY.length - i) * 7 * DAY_MS));
    const barLabels = weekStarts.map((d, i) => `Week of ${dayLabel(d)}: ${WEEKLY[i]}`);
    const issue = {
      issueId: 'issue-mobile-brief-1', issueKey: `declining_sales::${RETAILER.id}::prod-2`, type: 'declining_sales',
      priority: 'high', confidence: 'high', productId: 'prod-2', productName: FOCUS_NAME, valueAtRiskRm: VALUE_AT_RISK,
    };
    const brief = ({ updatedAt, withWeeks }) => ({
      briefId: BRIEF_ID, retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanUid: uid,
      salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', insightCount: 1, highPriorityCount: 1,
      totalValueAtRiskRm: VALUE_AT_RISK, isDemo: false, updatedAt, emptyStateHeadline: '', emptyStateBody: '',
      usualOrderWeekday: 2,
      topInsights: [{ ...issue, reason: SIGNAL, recommendation: 'Ask about shelf space.', questions: QUESTIONS }],
      focusItems: [{
        ...issue, signal: SIGNAL, action: 'Ask about shelf space.', questions: QUESTIONS, occurrenceCount: 1, autoState: 'active',
        ...(withWeeks ? { weeklyVersion: 'brief-weekly/1.0.0', weekStarts: weekStarts.map(isoDate), weeklyQuantities: WEEKLY } : {}),
      }],
      retailerMemory: {
        status: 'active', confidence: 'medium', commonReasonCodes: ['price_too_high'],
        replacementProductIds: ['prod-3', 'prod-9'], priceSensitivityScore: 0, seasonalityScore: 0,
      },
      replenishment: [
        {
          retailerId: RETAILER.id, productId: 'prod-2', productName: FOCUS_NAME, suggestedQty: 6, confidence: 0.7, confidenceLabel: 'medium',
          rationale: RATIONALE, inputs: { lastOrderQty: 6, lastOrderDaysAgo: NEWER_DAYS - 2, runRatePerDay: 0.5, patternMeanQty: 6 },
        },
        {
          retailerId: RETAILER.id, productId: 'prod-3', productName: OTHER_NAME, suggestedQty: 4, confidence: 0.4, confidenceLabel: 'low',
          rationale: RATIONALE, inputs: { lastOrderQty: 0, lastOrderDaysAgo: 0, runRatePerDay: 0.2, patternMeanQty: 4 },
        },
      ],
    });
    const lastOrderText = `Last order ${dayLabel(daysAgo(NEWER_DAYS))}, ${NEWER_DAYS} days ago: ${FOCUS_NAME} 6, ${OTHER_NAME} 4. RM ${NEWER_TOTAL.toFixed(2)}.`;
    const updatedText = `Updated ${dayLabel(daysAgo(2))}`;
    const staleText = `This brief is from ${dayLabel(daysAgo(9))}. It may be out of date.`;
    const reorderText = `Suggest 6. Last order 6, ${NEWER_DAYS} days ago.`;
    let s;
    let page;

    const fullBrief = () => page.getByRole('button', { name: 'Full brief', exact: true }).first();
    const openFullBrief = async () => {
      const link = fullBrief();
      await B.scrollIntoView(page, link, { minHeight: 20, pointerY: 0.8 });
      await link.click();
      await B.see(page, `Brief for ${RETAILER.name}`, { timeout: 30000 });
    };
    const seeBriefFacts = async (where) => {
      await B.see(page, SIGNAL, { timeout: 30000 });
      for (const question of QUESTIONS) await B.see(page, question);
      await B.see(page, `RM ${VALUE_AT_RISK} at risk`);
      await B.see(page, 'Usually orders on Tuesday.');
      await B.see(page, lastOrderText, { timeout: 30000 });
      await expectNone(page, FORBIDDEN, where);
    };
    const seeReorders = async (where) => {
      await B.scrollIntoView(page, B.semantic(page, reorderText), { minHeight: 10, pointerY: 0.8 });
      await B.see(page, 'Suggest 4.');
      await expectNone(page, FORBIDDEN, `${where}, reorder lines`);
    };

    await t.step('seed: a route stop with a reason, a brief 2 days old, two own orders and a cancelled newest order', async () => {
      await db.put('route_plans', PLAN_ID, {
        planId: PLAN_ID, createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
        salesmanName: accounts.salesman.name, branchId: 'B1',
        weekStart: daysAgo(6), weekEnd: new Date(noon.getTime() + DAY_MS),
        publishedAt: now, status: 'published', source: 'dashboard', totalStops: 1, stopIds: ['stop-1'],
        stopRetailerIds: { 'stop-1': RETAILER.id },
        days: [{
          dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 3.5,
          stops: [{
            stopId: 'stop-1', dayId: 'day-1', retailerId: RETAILER.id, retailerName: RETAILER.name, address: `${RETAILER.area}, Kuching`,
            lat: RETAILER.lat, lng: RETAILER.lng, sequence: 1, estimatedArrival: '09:00', estimatedDeparture: '09:20',
            priorityReason: 'Prioritised: overdue 14d, high forecast demand, high value.', status: 'not_started',
            travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
          }],
        }],
      });
      await db.put('ai_insights', issue.issueId, {
        ...issue, retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', isDemo: false,
      });
      await db.put('visit_briefs', BRIEF_ID, brief({ updatedAt: daysAgo(2), withWeeks: true }));
      const order = (id, at, total, items, extra = {}) => db.put('orders', id, {
        orderId: id, retailerId: RETAILER.id, retailerName: RETAILER.name, outlet: RETAILER.name, branchId: 'B1',
        uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code,
        status: 'submitted', totalProducts: items.length, totalBoxes: 2, totalPrice: total, items,
        submittedAt: at, createdAt: at, ...extra,
      });
      await order('ORD-BRIEF-OLD', daysAgo(30), 45.05, [{ productId: 'prod-3', name: OTHER_NAME, productName: OTHER_NAME, qty: 5, price: 9.01 }]);
      await order('ORD-BRIEF-NEWER', daysAgo(NEWER_DAYS), NEWER_TOTAL, [
        { productId: 'prod-2', name: FOCUS_NAME, productName: FOCUS_NAME, qty: 6, price: 40.4 },
        { productId: 'prod-3', name: OTHER_NAME, productName: OTHER_NAME, qty: 4, price: 10.5 },
      ]);
      await order('ORD-BRIEF-CANCELLED', daysAgo(1), 999, [{ productId: 'prod-2', name: FOCUS_NAME, productName: FOCUS_NAME, qty: 9, price: 111 }], { status: 'cancelled' });
      const profile = await db.get('users', accounts.salesman.email);
      await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
      await mobile.routeDayForSunday(db, PLAN_ID);
    });

    await t.step('stop card: plain reason, brief date, focus with questions and money, last order, usual day, reorder lines', async () => {
      s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      page = s.page;
      await B.fakeGeolocation(s.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await B.loginMobile(page, s.url, accounts.salesman.email);
      await mobile.waitForHome(page);
      await mobile.openAssignedRoute(page);
      await B.see(page, RETAILER.name);
      await mobile.acceptAndStartRoute(page);
      await mobile.selectStop(page);
      await B.see(page, 'Why this stop: Overdue 14 days. High demand expected. High value shop.', { timeout: 30000 });
      await B.see(page, 'Sales Visit Scout', { timeout: 30000 });
      await B.see(page, updatedText);
      await B.see(page, 'Questions to ask. Check the answers with the shop.');
      await B.see(page, 'What we know about this shop');
      await B.see(page, `Often replaced by ${OTHER_NAME}.`);
      await seeBriefFacts('stop card');
      const records = await page.getByRole('button', { name: 'Record outcome', exact: true }).count();
      if (records !== 1) throw new Error(`expected one "Record outcome" for one focus item, found ${records}`);
      await B.see(page, 'Mark this stop arrived first. Then you can record the outcome.');
      const signalShown = (await allText(page)).filter((x) => x.includes(SIGNAL)).length;
      if (signalShown !== 1) throw new Error(`the focus text is shown ${signalShown} times on the stop card, expected once`);
      if ((await allText(page)).some((x) => /RM 999/.test(x) || /^Last order .*1 day ago/.test(x))) {
        throw new Error('the cancelled order was used as the last order');
      }
      await seeReorders('stop card');
      await B.scrollIntoView(page, fullBrief(), { minHeight: 20, pointerY: 0.8 });
      await t.shot(s, 'stop-card');
    });

    await t.step('full brief page: the same facts, and eight weekly bars that equal the stored numbers', async () => {
      await openFullBrief();
      await B.see(page, updatedText);
      await B.see(page, 'Why this stop');
      await B.see(page, 'Overdue 14 days. High demand expected. High value shop.');
      await seeBriefFacts('full brief page');
      for (const label of barLabels) {
        const bars = (await allText(page)).filter((x) => x === label).length;
        if (bars !== 1) throw new Error(`expected one bar "${label}", found ${bars}`);
      }
      const bars = (await allText(page)).filter((x) => x.startsWith('Week of '));
      if (bars.length !== WEEKLY.length) throw new Error(`expected ${WEEKLY.length} bars, found ${bars.length}: ${bars.join(' | ')}`);
      await B.see(page, /Units ordered each week/);
      await t.shot(s, 'full-brief-page');
      await seeReorders('full brief page');
      await page.mouse.move(215, 600);
      await page.mouse.wheel(0, 900);
      await page.waitForTimeout(600);
      await t.shot(s, 'full-brief-page-lower');
      await mobile.goBack(page);
    });

    await t.step('guided visit: the brief section, the questions under the focus item, and the Full brief link', async () => {
      const open = page.getByRole('button', { name: 'Open visit', exact: true }).first();
      await B.scrollIntoView(page, open, { minHeight: 20, pointerY: 0.8 });
      await open.click();
      await B.see(page, "Today's focus", { timeout: 30000 });
      await B.see(page, updatedText);
      await B.see(page, 'Why this stop: Overdue 14 days. High demand expected. High value shop.');
      await seeBriefFacts('guided visit');
      await t.shot(s, 'guided-visit');
      await seeReorders('guided visit');
      await openFullBrief();
      await B.see(page, barLabels[0]);
      await mobile.goBack(page);
      await B.see(page, "Today's focus");
      await mobile.goBack(page);
    });

    await t.step('after arrival, "Record outcome" on the full brief page writes the outcome', async () => {
      await B.moveDevice(page, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await mobile.markArrived(page);
      await db.waitForQuery('route_stop_progress', (a) => a.planId === PLAN_ID && a.status === 'arrived', { label: 'stop arrival' });
      await openFullBrief();
      const record = page.getByRole('button', { name: 'Record outcome', exact: true }).first();
      await B.scrollIntoView(page, record, { minHeight: 20, pointerY: 0.8 });
      await record.click();
      await B.see(page, new RegExp(`Record outcome • ${escapeRegex(FOCUS_NAME)}`));
      await page.getByLabel('Price too high', { exact: true }).click();
      await page.getByLabel(`Record outcome • ${FOCUS_NAME}`, { exact: true }).waitFor({ state: 'detached', timeout: 20000 });
      await B.see(page, 'Conversation outcome synced.', { timeout: 20000 });
      const outcome = await db.waitForQuery('conversation_outcomes', (o) => o.sourceBriefId === BRIEF_ID && o.reasonCode === 'price_too_high', { label: 'outcome from the brief page' });
      if (outcome.retailerId !== RETAILER.id) throw new Error(`outcome retailer is ${outcome.retailerId}`);
      await t.shot(s, 'outcome-recorded');
      await mobile.goBack(page);
    });

    await t.step('a brief 9 days old that still has its weekly lists says it may be out of date and shows no chart', async () => {
      await db.put('visit_briefs', BRIEF_ID, brief({ updatedAt: daysAgo(9), withWeeks: true }));
      await B.see(page, staleText, { timeout: 30000 });
      await B.scrollIntoView(page, B.semantic(page, reorderText), { minHeight: 10, pointerY: 0.8 });
      await openFullBrief();
      await B.see(page, staleText);
      await B.see(page, SIGNAL);
      await page.waitForTimeout(1500);
      await expectNone(page, [/^Week of /, /ordered each week/, ...FORBIDDEN], 'full brief page of a brief 9 days old with weekly lists');
      await t.shot(s, 'stale-brief-no-chart');
      await mobile.goBack(page);
    });

    await t.step('a brief 2 days old with no weekly lists shows no chart and no out-of-date line', async () => {
      await db.put('visit_briefs', BRIEF_ID, brief({ updatedAt: daysAgo(2), withWeeks: false }));
      await B.see(page, updatedText, { timeout: 30000 });
      await B.scrollIntoView(page, B.semantic(page, reorderText), { minHeight: 10, pointerY: 0.8 });
      await openFullBrief();
      await B.see(page, updatedText);
      await B.see(page, SIGNAL);
      await page.waitForTimeout(1500);
      await expectNone(page, [/^Week of /, /ordered each week/, /may be out of date/, ...FORBIDDEN], 'full brief page of a fresh brief with no weekly lists');
      await t.shot(s, 'fresh-brief-no-lists-no-chart');
      await mobile.goBack(page);
    });

    await t.step('a fresh brief with its weekly lists shows the chart again; with no signal the full brief page still shows the stored brief', async () => {
      await db.put('visit_briefs', BRIEF_ID, brief({ updatedAt: daysAgo(2), withWeeks: true }));
      await B.scrollIntoView(page, B.semantic(page, reorderText), { minHeight: 10, pointerY: 0.8 });
      await openFullBrief();
      await B.see(page, barLabels[0], { timeout: 30000 });
      await mobile.goBack(page);
      await s.context.setOffline(true);
      await page.waitForTimeout(1500);
      await B.scrollIntoView(page, B.semantic(page, reorderText), { minHeight: 10, pointerY: 0.8 });
      await openFullBrief();
      await B.see(page, updatedText);
      await B.see(page, 'Overdue 14 days. High demand expected. High value shop.');
      await seeBriefFacts('full brief page with no signal');
      for (const label of barLabels) {
        const bars = (await allText(page)).filter((x) => x === label).length;
        if (bars !== 1) throw new Error(`with no signal: expected one bar "${label}", found ${bars}`);
      }
      await t.shot(s, 'full-brief-page-no-signal');
      await seeReorders('full brief page with no signal');
      await s.context.setOffline(false);
    });
  },
};
