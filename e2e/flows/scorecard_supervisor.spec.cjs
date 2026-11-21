'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[1];
const ORDERED = [PRODUCTS[0], PRODUCTS[2]];
const DEPARTMENT = 'GROCERY';

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'scorecard_supervisor',
  async run(t) {
    const { db, accounts, seed } = t;
    let phone;
    let orderId;

    await t.step('salesperson places an order through the phone', async () => {
      phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
      await mobile.waitForHome(phone.page);
      await mobile.planVisitToday(phone.page, RETAILER.name);
      await mobile.openPlannedVisit(phone.page, RETAILER.name);
      await mobile.selectProducts(phone.page, DEPARTMENT, ORDERED.map((p) => p.name));
      await mobile.continueToSignature(phone.page);
      orderId = await mobile.signAndSubmit(phone.page, DEPARTMENT, ORDERED.length);
      await t.shot(phone, 'order-submitted');
    });

    await t.step('the stored order carries the salesperson code the phone writes and no staffId', async () => {
      const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
      expectEqual(order.salesmanUid, seed.uids.salesman, 'salesmanUid');
      expectEqual(order.salesmanCode, accounts.salesman.code, 'salesmanCode');
      expectEqual('staffId' in order, false, 'staffId present on a phone order');
      expectEqual((await db.list('orders')).length, 1, 'orders in the company');
    });

    await t.step('the supervisor of that salesperson sees the order counted on the coaching scorecard', async () => {
      const sup = await t.session('admin');
      await B.loginAdmin(sup.page, sup.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(sup.page);
      await admin.goToPage(sup.page, 'Team Activity');
      const tab = await B.see(sup.page, /^Coaching Scorecard$/, { timeout: 60000 });
      await B.scrollIntoView(sup.page, tab, { step: -400, minHeight: 15, bottomInset: 0 });
      await tab.click();
      await B.see(sup.page, accounts.salesman.name, { timeout: 30000 });
      await sup.page.waitForTimeout(1500);
      const text = (await admin.semanticsLines(sup.page)).join('\n');
      await t.shot(sup, 'supervisor-scorecard');
      if (/could not be read[^\n]*orders/i.test(text)) throw new Error(`the orders signal could not be read:\n${text}`);
      if (/Incomplete.*counts, rates and coaching are unavailable/i.test(text)) throw new Error(`the scorecard is incomplete:\n${text}`);
      if (!/Orders \(8 wk\)\s*1(\s|$)/.test(text)) throw new Error(`expected "Orders (8 wk)" to show 1:\n${text}`);
      const rail = await admin.sidebarLabels(sup.page);
      for (const label of ['Trust & Impact', 'Retailers']) {
        if (rail.some((name) => name === label || name.startsWith(`${label},`))) throw new Error(`a supervisor must not have "${label}" in the sidebar: ${rail.join(' | ')}`);
      }
    });

    await t.step('the weekly job wrote a brief that suggested three products to that shop before the order', async () => {
      await db.put('visit_briefs', 'brief-scorecard-supervisor', {
        retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanCode: accounts.salesman.code, salesmanUid: seed.uids.salesman,
        branchId: 'B1', generatedAt: new Date(Date.now() - 2 * 3600000),
        replenishment: PRODUCTS.map((p) => ({ productId: p.id, productName: p.name, suggestedQty: 4, suggestionStatus: 'suggested' })),
      });
    });

    await t.step('Trust & Impact counts the two suggested products the phone order holds, read from orders', async () => {
      const a = await t.session('admin', { name: 'trust-admin', viewport: { width: 1600, height: 1000 } });
      await B.loginAdmin(a.page, a.url, accounts.admin.email);
      await admin.waitForShell(a.page);
      await admin.goToPage(a.page, 'Trust & Impact');
      await B.see(a.page, 'Suggested products ordered', { timeout: 60000 });
      await a.page.waitForTimeout(1500);
      const text = (await admin.semanticsLines(a.page)).join('\n');
      await t.shot(a, 'trust-impact-suggested-ordered');
      if (/Could not read:[^\n]*orders/.test(text)) throw new Error(`Trust & Impact could not read orders:\n${text}`);
      if (!/(^|\n)Retailers with recommendations\nSuggested products ordered\n1 of 2\n2 of 3\n50\.0% · 2 evaluated\n66\.7% · 3 evaluated\n/.test(text)) {
        throw new Error(`expected "Suggested products ordered" to show "2 of 3" and "66.7% · 3 evaluated" beside "1 of 2" retailers:\n${text}`);
      }
      await admin.goToPage(a.page, 'Retailers');
      const coverage = await B.see(a.page, /^Coverage$/, { timeout: 30000 });
      await coverage.first().click();
      await B.see(a.page, 'Coverage & Lifecycle', { timeout: 30000 });
      await B.see(a.page, /retailer\(s\) need attention/, { timeout: 30000 });
      const lifecycle = (await admin.semanticsLines(a.page)).join('\n');
      await t.shot(a, 'retailer-coverage-lifecycle');
      if (/Incomplete — lifecycle and visit counts/.test(lifecycle)) throw new Error(`the lifecycle panel is incomplete:\n${lifecycle}`);
      if (!/New: 1\nOrder history incomplete: 1\nLong-uncovered: 12 retailer\(s\) need attention/.test(lifecycle)) {
        throw new Error(`expected the ordering shop as New and the other shop with no order read:\n${lifecycle}`);
      }
    });
  },
};
