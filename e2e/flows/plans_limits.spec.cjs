'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const { BRANCH, PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'plans_limits');
const PLAN = 'E2EONE';
const LIMITS = { salesmen: 2, supervisors: 3, managers: 4, products: 3 };
const HIDDEN_PRODUCT = { id: 'prod-hidden', name: 'E2E HIDDEN SHELF PRODUCT', dept: 'GROCERY', price: 5 };
const NEW_PRODUCT = {
  department: 'E2E SNACKS', category: 'E2E CRACKERS', name: 'LIMIT TEST CRACKER', brand: 'TENTEN',
  code: 'R910-SNK-001', price: '7.50',
};
const RETAILER = RETAILERS[1];
const ORDERED = [PRODUCTS[0], PRODUCTS[2]];
const SALESMAN_FULL = 'Your plan allows 2 salesmen. Remove or suspend one first, or ask to upgrade.';
const SALESMAN_FULL_1 = 'Your plan allows 1 salesman. Remove or suspend one first, or ask to upgrade.';
const PRODUCTS_FULL = 'Your plan allows 3 products. Hide or remove one first, or ask to upgrade.';

const canonical = (value) => JSON.stringify(value, (_, v) => (v && typeof v === 'object' && !Array.isArray(v)
  ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => (a < b ? -1 : 1))) : v));

function expectEqual(actual, expected, what) {
  if (canonical(actual) !== canonical(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'plans_limits',
  async run(t) {
    const { db, accounts, seed } = t;
    const key = platform.ensureKey();
    const plans = (steps) => directory.planAdmin([key], steps);
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const evidence = { plan: PLAN, limits: LIMITS, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const usage = async () => {
      const doc = await db.get('config', 'usage');
      return {
        salesmen: doc.seats.salesmen,
        supervisors: doc.seats.supervisors,
        managers: doc.usageSchemaVersion === 2
          ? doc.seats.admins + doc.seats.branchManagers : doc.seats.managers,
        products: doc.products,
      };
    };
    const waitUsage = async (predicate, what) => {
      const end = Date.now() + 20000;
      let last;
      while (Date.now() < end) {
        last = await usage();
        if (predicate(last)) return last;
        await new Promise((r) => setTimeout(r, 200));
      }
      throw new Error(`${what}: counters were ${JSON.stringify(last)}`);
    };
    const semantics = async (page) => (await admin.semanticsLines(page));

    let tabA;
    let tabB;
    let winnerEmail;

    try {
      await t.step('the company is on a small plan, one salesman seat short of full', async () => {
        await db.put('products', HIDDEN_PRODUCT.id, {
          productId: HIDDEN_PRODUCT.id, itemCode: 'R999-HID-001', productCode: 'R999-HID-001',
          itemName: HIDDEN_PRODUCT.name, productName: HIDDEN_PRODUCT.name,
          barcode: '9555592209999', itemBarcode: '9555592209999',
          unitPrice: HIDDEN_PRODUCT.price, brandName: 'TENTEN', brand: 'TENTEN',
          departmentName: HIDDEN_PRODUCT.dept, mainCategoryName: HIDDEN_PRODUCT.dept,
          sortOrder: 0, isVisible: false, status: 'hidden',
        });
        plans([
          { op: 'private_plan', planId: PLAN, limits: LIMITS },
          { op: 'subscribe', planId: PLAN, status: 'active', reseed: true },
          { op: 'usage' },
        ]);
        const projected = await db.get('config', 'plan');
        expectEqual(projected.planId, PLAN, 'config/plan planId');
        expectEqual(projected.limits, LIMITS, 'config/plan limits');
        expectEqual(await usage(), { salesmen: 1, supervisors: 1, managers: 2, products: 3 }, 'starting counters');
        note('starting state', { plan: PLAN, usage: await usage() });
      });

      await t.step('two admins log in on the dashboard in two tabs', async () => {
        tabA = await t.session('admin', { name: 'admin-tab-a', ...admin.grantClipboard });
        tabB = await t.session('admin', { name: 'admin-tab-b', ...admin.grantClipboard });
        for (const tab of [tabA, tabB]) {
          await B.loginAdmin(tab.page, tab.url, accounts.admin.email);
          await admin.waitForShell(tab.page);
        }
      });

      await t.step('a. both tabs invite a salesman at once: one invitation, one refusal', async () => {
        await admin.fillUserForm(tabA.page, { name: 'E2E Race One', email: 'e2e.race1@example.test', code: 'S801', branchName: BRANCH.name });
        await admin.fillUserForm(tabB.page, { name: 'E2E Race Two', email: 'e2e.race2@example.test', code: 'S802', branchName: BRANCH.name });
        const buttonA = await admin.createUserButton(tabA.page);
        const buttonB = await admin.createUserButton(tabB.page);
        const clickedAt = Date.now();
        await Promise.all([buttonA.click(), buttonB.click()]);
        const outcome = (page) => Promise.race([
          B.see(page, 'Invitation created', { timeout: 30000 }).then(() => 'created'),
          B.see(page, SALESMAN_FULL, { timeout: 30000 }).then(() => 'refused'),
        ]);
        const results = await Promise.all([outcome(tabA.page), outcome(tabB.page)]);
        const settledIn = Date.now() - clickedAt;
        expectEqual([...results].sort(), ['created', 'refused'], 'outcomes of the two tabs');
        const [winner, loser] = results[0] === 'created' ? [tabA, tabB] : [tabB, tabA];
        winnerEmail = results[0] === 'created' ? 'e2e.race1@example.test' : 'e2e.race2@example.test';
        await t.shot(loser, 'a-refused');
        await t.shot(winner, 'a-created');
        await admin.closeInvitationDialog(winner.page);

        const created = (await db.list('users')).filter((u) => ['S801', 'S802'].includes(u.employeeCode));
        expectEqual(created.length, 1, 'profiles created by the two requests');
        const invitations = (await platformDb.list('invitations')).filter((i) => i.tenantId === directory.HARNESS_TENANT);
        expectEqual(invitations.length, 1, 'invitation records for the company');
        expectEqual((await usage()).salesmen, LIMITS.salesmen, 'config/usage seats.salesmen after the race');
        note('a. race', { outcomes: results, settledInMs: settledIn, winnerEmail, usage: await usage() });
      });

      await t.step('b. Show on a hidden product at the product limit is refused and it stays hidden', async () => {
        await admin.setProductVisibility(tabA.page, HIDDEN_PRODUCT.name, 'Show', { expectToast: PRODUCTS_FULL });
        await t.shot(tabA, 'b-show-refused');
        const product = await db.get('products', HIDDEN_PRODUCT.id);
        expectEqual([product.isVisible, product.status], [false, 'hidden'], 'hidden product after the refused Show');
        expectEqual((await usage()).products, LIMITS.products, 'products counter after the refused Show');
        note('b. show refused', { text: PRODUCTS_FULL, counters: await usage() });
      });

      await t.step('b. Add product with Visible on is saved hidden, with the message', async () => {
        await admin.createProduct(tabA.page, NEW_PRODUCT, { expectToast: 'Product saved, but hidden' });
        await t.shot(tabA, 'b-saved-hidden');
        const product = await db.waitForQuery('products', (p) => p.productCode === NEW_PRODUCT.code, { label: 'new product' });
        expectEqual([product.isVisible, product.status], [false, 'hidden'], 'new product visibility');
        expectEqual((await usage()).products, LIMITS.products, 'products counter after the hidden save');
        note('b. saved hidden', { productId: product.id, counters: await usage() });
      });

      let beforeDowngrade;
      await t.step('c. a downgrade below current usage keeps every user and product', async () => {
        const snapshot = async () => ({
          access: (await db.list('user_access')).map((a) => `${a.id}:${a.status}:${a.seatHeld}`).sort(),
          products: (await db.list('products')).map((p) => `${p.id}:${p.isVisible}:${p.status}`).sort(),
        });
        beforeDowngrade = await snapshot();
        plans([
          { op: 'private_plan', planId: 'E2EDOWN', limits: { salesmen: 1, supervisors: 1, managers: 1, products: 1 } },
          { op: 'subscribe', planId: 'E2EDOWN', status: 'active', reseed: true },
        ]);
        const projected = await db.get('config', 'plan');
        expectEqual(projected.planId, 'E2EDOWN', 'config/plan after the downgrade');
        expectEqual(await snapshot(), beforeDowngrade, 'users and products after the downgrade');
        note('c. downgrade', { plan: 'E2EDOWN', usage: await usage(), usersAndProducts: beforeDowngrade.access.length + beforeDowngrade.products.length });
      });

      let mobileS;
      await t.step('c. a salesman can still submit an order on the phone', async () => {
        mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
        await B.loginMobile(mobileS.page, mobileS.url, accounts.salesman.email);
        await mobile.waitForHome(mobileS.page);
        await mobile.planVisitToday(mobileS.page, RETAILER.name);
        await mobile.openPlannedVisit(mobileS.page, RETAILER.name);
        await mobile.selectProducts(mobileS.page, 'GROCERY', ORDERED.map((p) => p.name));
        await mobile.continueToSignature(mobileS.page);
        const orderId = await mobile.signAndSubmit(mobileS.page, 'GROCERY', ORDERED.length);
        const order = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
        expectEqual(order.salesmanUid, seed.uids.salesman, 'order salesman');
        await t.shot(mobileS, 'c-order-submitted');
        note('c. order on a downgraded plan', { orderId });
      });

      await t.step('c. inviting is refused on the downgraded plan', async () => {
        await admin.fillUserForm(tabA.page, { name: 'E2E Over Limit', email: 'e2e.over@example.test', code: 'S803', branchName: BRANCH.name });
        await admin.submitUserForm(tabA.page);
        await B.see(tabA.page, SALESMAN_FULL_1, { timeout: 30000 });
        await t.shot(tabA, 'c-invite-refused');
        expectEqual((await db.list('users')).filter((u) => u.employeeCode === 'S803').length, 0, 'profiles created while over the limit');
        note('c. invite refused', { text: SALESMAN_FULL_1 });
      });

      await t.step('c. back on the small plan for the rest of the flow', async () => {
        plans([{ op: 'subscribe', planId: PLAN, status: 'active', reseed: true }]);
        expectEqual((await db.get('config', 'plan')).planId, PLAN, 'config/plan restored');
      });

      await t.step('d. the reconciler reports a planted counter mismatch and corrects nothing', async () => {
        const clean = plans([{ op: 'reconcile' }])[0];
        expectEqual(clean.mismatch, false, 'mismatch before planting');
        const before = await db.get('config', 'usage');
        const planted = { ...before, seats: { ...before.seats, salesmen: before.seats.salesmen + 3 }, products: before.products + 1 };
        await db.put('config', 'usage', planted);
        const report = plans([{ op: 'reconcile' }])[0];
        expectEqual(report.mismatch, true, 'mismatch after planting');
        expectEqual(report.recorded.salesmen, report.expected.salesmen + 3, 'recorded vs expected salesmen');
        expectEqual(report.recorded.products, report.expected.products + 1, 'recorded vs expected products');
        expectEqual(report.expected, { salesmen: 2, supervisors: 1, admins: 1, branchManagers: 1, products: 3 }, 'expected canonical recount');
        const stored = (await platformDb.list('usage_reports')).filter((r) => r.tenantId === directory.HARNESS_TENANT && r.mismatch === true);
        expectEqual(stored.length, 1, 'usage_reports with a mismatch');
        expectEqual(await db.get('config', 'usage'), planted, 'config/usage after the report (report only)');
        note('d. reconciler', { recorded: report.recorded, expected: report.expected, anomalies: report.anomalies });
        plans([{ op: 'usage' }]);
        expectEqual(plans([{ op: 'reconcile' }])[0].mismatch, false, 'mismatch after the recount');
      });

      await t.step('e. the Account page asks for the password, then shows the plan and usage', async () => {
        await admin.goToPage(tabA.page, 'Account');
        await B.see(tabA.page, 'Enter your password to see your plan and usage.');
        await t.shot(tabA, 'e-account-locked');
        await B.fillField(tabA.page, tabA.page.locator('input[type="password"]').first(), E.PASSWORD);
        await tabA.page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(tabA.page, `Plan: ${PLAN}`, { timeout: 30000 });
        await B.see(tabA.page, 'Status: Active');
        await B.see(tabA.page, 'Salespeople: 2 of 2');
        await B.see(tabA.page, 'Supervisors: 1 of 3');
        await B.see(tabA.page, 'Managers: 2 of 4');
        await B.see(tabA.page, 'Products: 3 of 3');
        await B.see(tabA.page, 'Invoices: none yet');
        await B.see(tabA.page, 'Export: available');
        await B.see(tabA.page, 'Download tenant export');
        await t.shot(tabA, 'e-account');
        note('e. account', { lines: (await semantics(tabA.page)).filter((l) => /^(Plan|Status|Salespeople|Supervisors|Managers|Products|Invoices|Export)/.test(l)) });
      });

      await t.step('e. Plans: Monthly shows From MYR 100 per month; Yearly shows From MYR 80 per month, billed MYR 960', async () => {
        plans(['E2EPRICE1', 'E2EPRICE2'].map((planId) => ({
          op: 'public_plan', planId, limits: LIMITS,
          prices: { currency: 'MYR', monthly: 100, yearly: 960 },
        })));
        await tabA.page.getByRole('button', { name: 'Change plan', exact: true }).click();
        await B.see(tabA.page, 'Choose a plan');
        await B.see(tabA.page, 'Save up to 20%');
        await B.see(tabA.page, 'From MYR 100 per month');
        const monthly = await semantics(tabA.page);
        expectEqual(monthly.includes('From MYR 100 per month'), true, 'Monthly price line');
        expectEqual(monthly.some((l) => l.startsWith("Billed yearly")), false, 'a yearly line while Monthly is selected');
        await t.shot(tabA, 'e-plans-monthly');

        await tabA.page.getByRole('button', { name: 'Yearly', exact: true }).click();
        await B.see(tabA.page, 'Billed yearly MYR 960');
        const yearly = await semantics(tabA.page);
        expectEqual(yearly.includes('From MYR 80 per month'), true, 'Yearly per-month price');
        expectEqual(yearly.filter((l) => l === 'Billed yearly MYR 960').length, 2, 'Billed yearly lines (two explicit priced fixtures)');
        await t.shot(tabA, 'e-plans-yearly');
        note('e. plans', { monthly: monthly.filter((l) => l.startsWith("From ")), yearly: yearly.filter((l) => ["From ", "Billed", "Save"].some((p) => l.startsWith(p))) });
      });

      await t.step('e. Request this plan sends a request that staff can see', async () => {
        await tabA.page.getByRole('button', { name: 'Request the E2EPRICE2 plan' }).first().click();
        await B.see(tabA.page, 'Request sent. The Scoot Sales team will contact you to arrange payment.');
        await t.shot(tabA, 'e-plan-requested');
        const request = await platformDb.waitForQuery('plan_requests', (r) => r.tenantId === directory.HARNESS_TENANT, { label: 'plan_requests' });
        expectEqual([request.planId, request.interval, request.status], ['E2EPRICE2', 'yearly', 'requested'], 'plan request');
        note('e. plan request', { planId: request.planId, interval: request.interval, status: request.status });
      });

      const person = { code: accounts.salesman.code, name: accounts.salesman.name };
      await t.step('f. Suspend frees a seat and Activate takes it back', async () => {
        expectEqual((await usage()).salesmen, 2, 'salesmen before Suspend');
        await admin.setUserStatus(tabB.page, person, 'Suspend');
        const access = await db.waitForDoc('user_access', seed.uids.salesman, (a) => a.status === 'suspended');
        expectEqual(access.seatHeld, false, 'seatHeld after Suspend');
        expectEqual((await waitUsage((u) => u.salesmen === 1, 'after Suspend')).salesmen, 1, 'salesmen after Suspend');
        await t.shot(tabB, 'f-suspended');
        await admin.setUserStatus(tabB.page, person, 'Activate');
        const back = await db.waitForDoc('user_access', seed.uids.salesman, (a) => a.status === 'active');
        expectEqual(back.seatHeld, true, 'seatHeld after Activate');
        expectEqual((await waitUsage((u) => u.salesmen === 2, 'after Activate')).salesmen, 2, 'salesmen after Activate');
        note('f. suspend and activate', { counters: await usage() });
      });

      await t.step('f. Activate when the plan is full is refused', async () => {
        await admin.setUserStatus(tabB.page, person, 'Suspend');
        await waitUsage((u) => u.salesmen === 1, 'after the second Suspend');
        await admin.createUser(tabB.page, { name: 'E2E Seat Taker', email: 'e2e.taker@example.test', code: 'S804', branchName: BRANCH.name });
        await waitUsage((u) => u.salesmen === 2, 'after the seat is taken');
        await admin.setUserStatus(tabB.page, person, 'Activate', { expectToast: SALESMAN_FULL });
        await t.shot(tabB, 'f-activate-refused');
        const access = await db.get('user_access', seed.uids.salesman);
        expectEqual([access.status, access.seatHeld], ['suspended', false], 'salesman after the refused Activate');
        expectEqual((await usage()).salesmen, 2, 'salesmen after the refused Activate');
        note('f. activate refused', { text: SALESMAN_FULL, counters: await usage() });
      });
    } finally {
      evidence.winnerEmail = winnerEmail;
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    }
  },
};
