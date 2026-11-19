'use strict';

const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, putPerson } = require('../lib/seed.cjs');

const DAY_MS = 86400000;
const KL_OFFSET_MS = 8 * 3600000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const QUANTITIES = [6, 6, 5, 6, 6, 6, 0, 0];
const STOPPED_SHOP = { id: 'ret-stopped', name: 'E2E Stopped Shop' };
const PIN_SHOP = { id: 'ret-pin', name: 'E2E Unverified Pin Shop' };
const SECOND_SALESPERSON = { email: 'e2e.sales2@example.test', name: 'E2E Second Salesperson', role: 'salesman', code: 'S002', branch: 'B1' };
const PRODUCT = PRODUCTS[1];

function klToday() {
  const local = new Date(Date.now() + KL_OFFSET_MS);
  return Date.UTC(local.getUTCFullYear(), local.getUTCMonth(), local.getUTCDate());
}

function dateKey(utcMidnight) {
  return new Date(utcMidnight).toISOString().slice(0, 10);
}

function dayLabel(utcMidnight) {
  const d = new Date(utcMidnight);
  return `${d.getUTCDate()} ${MONTHS[d.getUTCMonth()]}`;
}

function planningWeek() {
  let day = klToday();
  if (new Date(day).getUTCDay() === 0) day += DAY_MS;
  const monday = day - ((new Date(day).getUTCDay() + 6) % 7) * DAY_MS;
  return { monday, sunday: monday + 6 * DAY_MS };
}

async function plannerOpeningWeek(page) {
  const monday = await page.evaluate(() => {
    const next = new Date(Date.now() + 7 * 86400000);
    const day = Date.UTC(next.getFullYear(), next.getMonth(), next.getDate());
    return day - ((new Date(day).getUTCDay() + 6) % 7) * 86400000;
  });
  return { monday, saturday: monday + 5 * DAY_MS };
}

function lastCompletedWeekStarts() {
  const today = klToday();
  const thisMonday = today - ((new Date(today).getUTCDay() + 6) % 7) * DAY_MS;
  return Array.from({ length: 8 }, (_, i) => thisMonday - (8 - i) * 7 * DAY_MS);
}

function longDayLabel(utcMidnight) {
  return `${dayLabel(utcMidnight)} ${new Date(utcMidnight).getUTCFullYear()}`;
}

function middayUtc(utcMidnight) {
  return new Date(utcMidnight + 4 * 3600000);
}

const asKualaLumpurMidnight = (utcMidnight) => new Date(utcMidnight - KL_OFFSET_MS);

async function lines(page) {
  return admin.semanticsLines(page);
}

async function barLabels(page) {
  return (await lines(page)).filter((line) => /^Week of \d+ \w+: [\d.]+ cartons$/.test(line));
}

module.exports = {
  name: 'home_decisions_shop_chart',
  async run(t) {
    const { db, accounts, seed } = t;
    const week = planningWeek();
    const weekStarts = lastCompletedWeekStarts();
    const wideViewport = { width: 2000, height: 1100 };
    const s = await t.session('admin', { viewport: wideViewport });
    const plannerWeek = await plannerOpeningWeek(s.page);
    const sentences = {
      routes: `1 route for the week of ${dayLabel(plannerWeek.monday)} is not planned.`,
      followUps: '1 follow-up is due this week.',
      pins: `1 shop pin is not verified: arrival at ${PIN_SHOP.name} will be unverified.`,
      stopped: `${STOPPED_SHOP.name} ordered no ${PRODUCT.name} in the 2 weeks to ${longDayLabel(weekStarts[7] + 6 * DAY_MS)}.`,
    };
    const shopOrders = {
      older: { id: 'e2e-decisions-order-older', total: 111, daysAgo: 10 },
      newer: { id: 'e2e-decisions-order-newer', total: 321.5, daysAgo: 3 },
      undated: { id: 'e2e-decisions-order-undated', total: 999, daysAgo: null },
    };
    const expectedBars = weekStarts.map((start, i) => `Week of ${dayLabel(start)}: ${QUANTITIES[i]} cartons`);

    await t.step('seed one unplanned week, one open dated follow-up, one unverified pin and one stopped product with 8 weeks of orders', async () => {
      await putPerson(db, SECOND_SALESPERSON, { supervisorUid: seed.uids.supervisor, supervisorCode: accounts.supervisor.code });
      const shopFields = {
        branchId: seed.branch.id, status: 'active', area: 'Kuching', address: 'Kuching',
        assignedSalesmanId: accounts.salesman.code, assignedSalesmanCode: accounts.salesman.code,
        assignedSalesmanUid: seed.uids.salesman, latitude: 1.54, longitude: 110.35,
      };
      await db.put('retailers', STOPPED_SHOP.id, {
        ...shopFields, retailerId: STOPPED_SHOP.id, retailerName: STOPPED_SHOP.name, name: STOPPED_SHOP.name,
        coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
      });
      await db.put('retailers', PIN_SHOP.id, {
        ...shopFields, retailerId: PIN_SHOP.id, retailerName: PIN_SHOP.name, name: PIN_SHOP.name,
        coordinateStatus: 'candidate',
      });
      await db.put('route_plans', 'e2e-decisions-plan', {
        planId: 'e2e-decisions-plan', status: 'draft', isDemo: false,
        weekStart: asKualaLumpurMidnight(week.monday), weekEnd: new Date(asKualaLumpurMidnight(week.sunday).getTime() + DAY_MS - 1000),
        salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: seed.branch.id,
        totalStops: 1, stopIds: ['stop-1'], stopRetailerIds: { 'stop-1': PIN_SHOP.id },
        days: [{ date: dateKey(week.monday), stops: [{ stopId: 'stop-1', retailerId: PIN_SHOP.id, retailerName: PIN_SHOP.name }] }],
        createdAt: new Date(), updatedAt: new Date(),
      });
      await db.put('route_plans', 'e2e-decisions-plan-planning', {
        planId: 'e2e-decisions-plan-planning', status: 'draft', isDemo: false,
        weekStart: asKualaLumpurMidnight(plannerWeek.monday), weekEnd: new Date(asKualaLumpurMidnight(plannerWeek.monday + 6 * DAY_MS).getTime() + DAY_MS - 1000),
        salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: seed.branch.id,
        totalStops: 0, stopIds: [], stopRetailerIds: {}, days: [],
        createdAt: new Date(), updatedAt: new Date(),
      });
      await db.put('conversation_outcomes', 'e2e-decisions-followup', {
        outcomeId: 'e2e-decisions-followup', retailerId: STOPPED_SHOP.id, retailerName: STOPPED_SHOP.name,
        productId: PRODUCT.id, productName: PRODUCT.name, reasonCode: 'retailer_busy', note: 'Ask about shelf space',
        salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: seed.branch.id,
        followUpDate: dateKey(klToday()), followUpStatus: 'open', isDemo: false, submittedAt: new Date(),
      });
      const orderBase = {
        uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
        salesmanEmail: accounts.salesman.email, salesmanName: accounts.salesman.name,
        salesmanId: accounts.salesman.code, salesmanCode: accounts.salesman.code, salesman_code: accounts.salesman.code,
        submittedByUid: seed.uids.salesman, createdByUid: seed.uids.salesman, branchId: seed.branch.id,
        retailerId: STOPPED_SHOP.id, retailerName: STOPPED_SHOP.name, status: 'submitted',
        totalProducts: 1, totalBoxes: 1, isDemo: false,
        items: [{ productId: PRODUCT.id, name: PRODUCT.name, quantity: 1, price: PRODUCT.price }],
      };
      for (const order of Object.values(shopOrders)) {
        const { id, total, daysAgo } = order;
        const at = daysAgo === null ? {} : { submittedAt: middayUtc(klToday() - daysAgo * DAY_MS), createdAt: middayUtc(klToday() - daysAgo * DAY_MS) };
        await db.put('orders', id, { ...orderBase, orderId: id, totalPrice: total, ...at });
      }
      await db.put('retailer_item_patterns', 'e2e-decisions-pattern', {
        patternId: 'e2e-decisions-pattern', retailerId: STOPPED_SHOP.id, productId: PRODUCT.id,
        retailerName: STOPPED_SHOP.name, productName: PRODUCT.name,
        salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code, branchId: seed.branch.id,
        weekStarts: weekStarts.map(dateKey), weeklyQuantities: QUANTITIES, trend: 'stopped', isDemo: false,
      });
      await db.put('ai_insights', 'e2e-decisions-insight', {
        issueId: 'e2e-decisions-insight', type: 'stopped_product', retailerId: STOPPED_SHOP.id, retailerName: STOPPED_SHOP.name,
        productId: PRODUCT.id, productName: PRODUCT.name, salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code,
        branchId: seed.branch.id, priority: 'high', confidence: 'high', status: 'new', autoState: 'active', isDemo: false,
        latestEvidence: { weekStarts: weekStarts.map(dateKey), weeklyQuantities: QUANTITIES },
        updatedAt: new Date(), createdAt: new Date(),
      });
    });

    await t.step('the admin home page shows each sentence with the right count', async () => {
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      for (const sentence of Object.values(sentences)) await B.see(s.page, sentence, { timeout: 45000 });
      const shown = (await lines(s.page)).join('\n');
      assert.ok(!/follow-ups? (is|are) overdue/.test(shown), 'no follow-up is overdue, so no overdue sentence');
      assert.ok(!/completed stops? (has|have) no order/.test(shown), 'no completed stop exists, so no stop sentence');
      assert.ok(!shown.includes('could not be read') && !shown.includes('Could not read'), 'no read failed');
      await B.shotAtWidths(t, s, 'home-decisions');
    });

    await t.step('the unplanned sentence names the week the planner opens on', async () => {
      await s.page.getByRole('button', { name: 'Open planner', exact: true }).first().click();
      const header = `${dayLabel(plannerWeek.monday)} – ${dayLabel(plannerWeek.saturday)}`;
      await B.see(s.page, header, { timeout: 30000 });
      await B.shotAtWidths(t, s, 'planner-week');
      await admin.goToPage(s.page, 'Dashboard');
      await B.see(s.page, sentences.routes, { timeout: 45000 });
    });

    await t.step('the stopped sentence opens the shop panel with the eight stored weeks', async () => {
      await s.page.getByRole('button', { name: 'Open shop', exact: true }).first().click();
      await B.see(s.page, `No ${PRODUCT.name} ordered in the 2 weeks to ${longDayLabel(weekStarts[7] + 6 * DAY_MS)}`, { timeout: 30000 });
      await B.see(s.page, expectedBars[0], { timeout: 30000 });
      assert.deepEqual(await barLabels(s.page), expectedBars);
      const shown = (await lines(s.page)).join('\n');
      assert.ok(shown.includes('No orders (2 weeks)'), 'the legend marks the two empty weeks');
      assert.ok(shown.includes(accounts.salesman.name), 'the panel names the salesperson');
      assert.ok(shown.includes('Ask about shelf space'), 'the panel shows the open follow-up');
      assert.ok(shown.includes(`Due ${longDayLabel(klToday())}`), 'the follow-up date has the day, month and year');
      assert.ok(!/Due \d{4}-\d{2}-\d{2}/.test(shown), 'the follow-up date is not the raw key');
      const newerLabel = `RM 321.50, ${longDayLabel(klToday() - shopOrders.newer.daysAgo * DAY_MS)}`;
      assert.ok(shown.includes(newerLabel), `Last order shows the newer order: ${newerLabel}`);
      assert.ok(!shown.includes('RM 111.00'), 'the older order is not shown as the last order');
      assert.ok(!shown.includes('RM 999.00'), 'the order without a date is not shown as the last order');
      assert.ok(!shown.includes('Could not read the alerts'), 'the alerts were read');
      await B.shotAtWidths(t, s, 'shop-panel');
    });

    await t.step('the supervisor sees only the team scope: the second salesperson is not counted', async () => {
      const sup = await t.session('admin', { name: 'supervisor', viewport: wideViewport });
      await B.loginAdmin(sup.page, sup.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(sup.page);
      await B.see(sup.page, sentences.pins, { timeout: 45000 });
      await B.see(sup.page, sentences.followUps);
      const shown = (await lines(sup.page)).join('\n');
      assert.ok(!shown.includes('is not planned.'), 'the unplanned week belongs to a salesperson outside this team');
    });
  },
};
