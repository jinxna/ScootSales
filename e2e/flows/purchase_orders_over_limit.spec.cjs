'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const BACKLOG = 500;
const EARLY = 20;
const MISSING_ORDER_ID = 'ORD-OVER-NOPO';
const RACED_ORDER_ID = 'ORD-OVER-RACE';
const DUPLICATE_ORDER_ID = 'ORD-OVER-DUP';
const ALREADY_EXISTS_TOAST = /A purchase order already exists for this order\./;
const MINUTE = 60 * 1000;
const DAY = 24 * 60 * MINUTE;
const MISSING_NOTICE = /approved orders? ha(s|ve) no purchase order\./;

const pad = (n) => String(n).padStart(3, '0');
const backlogId = (i) => `ORD-OVER-B-${pad(i)}`;
const earlyId = (i) => `ORD-OVER-E-${pad(i)}`;

function mondayOf(date) {
  const midnight = new Date(date.getFullYear(), date.getMonth(), date.getDate());
  midnight.setDate(midnight.getDate() - ((midnight.getDay() + 6) % 7));
  return midnight;
}

function atLocal(day, hour) {
  return new Date(day.getFullYear(), day.getMonth(), day.getDate(), hour);
}

function poNumber(issuedAt, orderId) {
  const ymd = `${issuedAt.getFullYear()}${String(issuedAt.getMonth() + 1).padStart(2, '0')}${String(issuedAt.getDate()).padStart(2, '0')}`;
  return `PO-${ymd}-${orderId}`;
}

async function inChunks(items, size, work) {
  for (let start = 0; start < items.length; start += size) {
    await Promise.all(items.slice(start, start + size).map(work));
  }
}

async function missingNoticeText(page) {
  const text = (await admin.semanticsLines(page)).join('\n');
  return (text.match(/\d+ approved orders? ha(?:s|ve) no purchase order\./) || [''])[0];
}

async function scrollList(page, dy) {
  const size = page.viewportSize();
  await page.mouse.move(size.width * 0.6, size.height * 0.6);
  await page.mouse.wheel(0, dy);
  await page.waitForTimeout(400);
}

async function seeCountAtListEnd(page, shown, total) {
  const wanted = `${shown} of ${total} purchase orders`;
  const deadline = Date.now() + 60000;
  let counts = [];
  let rows = 0;
  while (Date.now() < deadline) {
    await scrollList(page, 30000);
    const lines = (await admin.semanticsLines(page)).flatMap((label) => label.split(String.fromCodePoint(10)).map((line) => line.trim()));
    counts = lines.filter((line) => /^\d+ of \d+ purchase orders/.test(line));
    rows = lines.filter((line) => line.startsWith('Purchase order PO-')).length;
    if (counts.some((line) => line.startsWith(wanted))) return;
  }
  throw new Error(`expected the page to say "${wanted}", it says ${JSON.stringify(counts)} with ${rows} purchase order rows on screen`);
}

module.exports = {
  name: 'purchase_orders_over_limit',
  async run(t) {
    const { db, accounts, seed } = t;
    const now = new Date();
    const oldWeekDay = mondayOf(now);
    oldWeekDay.setDate(oldWeekDay.getDate() - 12);
    const product = PRODUCTS[0];
    let adminS;

    const order = (id, retailer, submittedAt) => ({
      orderId: id, uid: seed.uids.salesman, userUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
      salesmanEmail: accounts.salesman.email, salesmanName: accounts.salesman.name, salesmanId: accounts.salesman.code,
      salesmanCode: accounts.salesman.code, submittedByUid: seed.uids.salesman, createdByUid: seed.uids.salesman,
      branchId: accounts.salesman.branch, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name,
      status: 'approved',
      items: [{
        productId: product.id, name: product.name, productName: product.name, itemName: product.name, quantity: 1, qty: 1, boxes: 1,
        price: product.price, unitPrice: product.price, uom: 'box', department: product.dept, departmentName: product.dept,
      }],
      totalProducts: 1, totalBoxes: 1, totalPrice: product.price, submittedAt, createdAt: submittedAt,
      approvedAt: new Date(submittedAt.getTime() + 60 * MINUTE), approvedByUid: seed.uids.admin, approvedByRole: 'admin',
    });
    const purchaseOrder = (source, issuedAt) => ({
      poNumber: poNumber(issuedAt, source.orderId), orderId: source.orderId, retailerId: source.retailerId,
      retailerName: source.retailerName, salesmanCode: source.salesmanCode, salesmanUid: source.salesmanUid,
      branchId: source.branchId, totalPrice: source.totalPrice, status: 'issued', issuedAt,
      issuedByUid: seed.uids.admin, issuedByRole: 'admin',
    });

    await t.step(`seed ${BACKLOG + EARLY} approved orders that each have a purchase order, and one approved order without`, async () => {
      const pairs = [];
      for (let i = 0; i < BACKLOG; i += 1) {
        const source = order(backlogId(i), RETAILERS[i % 2], new Date(oldWeekDay.getTime() - 10 * DAY - i * MINUTE));
        pairs.push([source, purchaseOrder(source, new Date(now.getTime() - i * 100))]);
      }
      for (let i = 0; i < EARLY; i += 1) {
        const source = order(earlyId(i), RETAILERS[i % 2], new Date(atLocal(oldWeekDay, 10).getTime() + i * MINUTE));
        pairs.push([source, purchaseOrder(source, new Date(atLocal(oldWeekDay, 12).getTime() + i * MINUTE))]);
      }
      await inChunks(pairs, 40, async ([source, po]) => {
        await db.put('orders', source.orderId, source);
        await db.put('purchase_orders', source.orderId, po);
      });
      await db.put('orders', MISSING_ORDER_ID, order(MISSING_ORDER_ID, RETAILERS[0], atLocal(oldWeekDay, 9)));
      expectEqual((await db.get('purchase_orders', earlyId(0))).status, 'issued', 'the oldest purchase orders exist in the store');
      expectEqual(await db.get('purchase_orders', MISSING_ORDER_ID), null, `${MISSING_ORDER_ID} has no purchase order in the store`);
    });

    await t.step('admin opens Purchase Orders: this week says how many it shows and how many there are', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await admin.goToPage(adminS.page, 'Purchase Orders');
      await B.see(adminS.page, /Purchase order PO-/, { timeout: 60000 });
      expectEqual(await missingNoticeText(adminS.page), '', 'missing purchase order notice in this week');
      expectEqual(await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count(), 0, 'Issue PO buttons in this week');
      await t.shot(adminS, 'this-week-past-the-limit');
      await seeCountAtListEnd(adminS.page, 50, BACKLOG);
      await t.shot(adminS, 'this-week-count-and-load-more');
    });

    await t.step('"Load 50 more" shows the next purchase orders of the week', async () => {
      await adminS.page.getByRole('button', { name: 'Load 50 more', exact: true }).click();
      await seeCountAtListEnd(adminS.page, 100, BACKLOG);
      await t.shot(adminS, 'this-week-after-load-more');
    });

    await t.step('the oldest purchase orders are reached by week, and no order that has one is listed as lacking it', async () => {
      await adminS.page.getByRole('button', { name: 'Previous week' }).click();
      await adminS.page.getByRole('button', { name: 'Previous week' }).click();
      await B.see(adminS.page, MISSING_ORDER_ID, { timeout: 30000 });
      await adminS.page.waitForTimeout(3000);
      const notice = await missingNoticeText(adminS.page);
      const issueButtons = await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count();
      const wronglyListed = ((await admin.semanticsLines(adminS.page)).join(String.fromCodePoint(10)).match(/ORD-OVER-E-\d+ · /g) || []).length;
      if (wronglyListed || issueButtons !== 1 || notice !== '1 approved order has no purchase order.') {
        throw new Error(`the page lists ${wronglyListed} orders that have a purchase order as lacking one, offers ${issueButtons} "Issue PO" buttons (1 expected) and says "${notice}"`);
      }
      await t.shot(adminS, 'old-week-one-order-truly-without-purchase-order');
      await seeCountAtListEnd(adminS.page, EARLY, EARLY);
      await t.shot(adminS, 'old-week-count');
      await scrollList(adminS.page, -30000);
    });

    await t.step('the one order that truly has no purchase order can be issued, and the notice goes', async () => {
      await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).click();
      const po = await db.waitForDoc('purchase_orders', MISSING_ORDER_ID, (p) => p.status === 'issued');
      expectEqual(po.issuedByUid, seed.uids.admin, 'purchase order issuer');
      await B.semantic(adminS.page, MISSING_NOTICE).waitFor({ state: 'detached', timeout: 20000 });
      expectEqual(await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count(), 0, 'Issue PO buttons after issue');
      await t.shot(adminS, 'old-week-after-issue');
      await adminS.page.getByRole('button', { name: 'This week' }).click();
      await seeCountAtListEnd(adminS.page, 50, BACKLOG + 1);
      await t.shot(adminS, 'this-week-with-the-new-purchase-order');
    });

    await t.step('a purchase order issued from another session removes the notice and the Issue PO button without a reload', async () => {
      await adminS.page.getByRole('button', { name: 'Previous week' }).click();
      await adminS.page.getByRole('button', { name: 'Previous week' }).click();
      await B.see(adminS.page, /ORD-OVER-E-\d+/, { timeout: 30000 });
      await db.put('orders', RACED_ORDER_ID, order(RACED_ORDER_ID, RETAILERS[1], atLocal(oldWeekDay, 11)));
      await B.see(adminS.page, RACED_ORDER_ID, { timeout: 30000 });
      await B.semantic(adminS.page, MISSING_NOTICE).waitFor({ timeout: 30000 });
      expectEqual(await missingNoticeText(adminS.page), '1 approved order has no purchase order.', 'notice before the other session issues');
      expectEqual(await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count(), 1, 'Issue PO buttons before the other session issues');
      await t.shot(adminS, 'old-week-second-order-without-purchase-order');
      const raced = order(RACED_ORDER_ID, RETAILERS[1], atLocal(oldWeekDay, 11));
      await db.put('purchase_orders', RACED_ORDER_ID, purchaseOrder(raced, new Date()));
      await B.semantic(adminS.page, MISSING_NOTICE).waitFor({ state: 'detached', timeout: 30000 });
      expectEqual(await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count(), 0, 'Issue PO buttons after the other session issues');
      await t.shot(adminS, 'old-week-notice-gone-after-other-session-issued');
    });

    await t.step('issuing an order while another session issues it first says one already exists and keeps the first one', async () => {
      await db.put('orders', DUPLICATE_ORDER_ID, order(DUPLICATE_ORDER_ID, RETAILERS[0], atLocal(oldWeekDay, 8)));
      await B.see(adminS.page, DUPLICATE_ORDER_ID, { timeout: 30000 });
      const issueButton = adminS.page.getByRole('button', { name: 'Issue PO', exact: true });
      await issueButton.waitFor({ timeout: 30000 });
      expectEqual(await issueButton.count(), 1, 'Issue PO buttons before the duplicate attempt');
      const duplicate = order(DUPLICATE_ORDER_ID, RETAILERS[0], atLocal(oldWeekDay, 8));
      const first = purchaseOrder(duplicate, new Date(now.getTime() - MINUTE));
      const transactionRead = /\/documents:batchGet/;
      let otherSessionIssued = false;
      await adminS.page.route(transactionRead, async (route) => {
        if (!otherSessionIssued && (route.request().postData() || '').includes(`/orders/${DUPLICATE_ORDER_ID}`)) {
          otherSessionIssued = true;
          await db.put('purchase_orders', DUPLICATE_ORDER_ID, first);
        }
        await route.continue();
      });
      await issueButton.click();
      await B.see(adminS.page, ALREADY_EXISTS_TOAST, { timeout: 30000 });
      await t.shot(adminS, 'old-week-duplicate-issue-answered');
      await adminS.page.unroute(transactionRead);
      expectEqual(otherSessionIssued, true, 'the other session issued between the click and the first read of the page');
      await B.semantic(adminS.page, MISSING_NOTICE).waitFor({ state: 'detached', timeout: 30000 });
      expectEqual(await adminS.page.getByRole('button', { name: 'Issue PO', exact: true }).count(), 0, 'Issue PO buttons after the duplicate attempt');
      const kept = await db.get('purchase_orders', DUPLICATE_ORDER_ID);
      expectEqual(new Date(kept.issuedAt).getTime(), first.issuedAt.getTime(), 'issue time of the purchase order that was there first');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
