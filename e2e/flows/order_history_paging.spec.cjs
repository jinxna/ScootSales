'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RECENT = 120;
const id = (n) => `ORD-PG-${String(n).padStart(3, '0')}`;
const OLD_ID = 'ORD-PG-OLD';
const OTHER_ID = 'ORD-PG-OTHER';

function countText(page, re) {
  return page.evaluate(([source]) => {
    const pattern = new RegExp(source);
    return Array.from(document.querySelectorAll('flt-semantics'))
      .filter((n) => pattern.test((n.getAttribute('aria-label') || n.textContent || '').trim())).length;
  }, [re.source]);
}

const exact = (orderId) => new RegExp(`${orderId}(?![0-9])`);

async function scrollToFooter(page, label) {
  const button = page.getByRole('button', { name: label });
  await B.scrollIntoView(page, button, { maxSteps: 80, step: 400, bottomInset: 60 });
  return button;
}

module.exports = {
  name: 'order_history_paging',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    let page;

    await t.step('seed 120 recent own orders, one old own order and another salesperson order', async () => {
      const now = Date.now();
      const retailer = RETAILERS[0];
      const order = (orderId, ownerUid, code, at) => db.put('orders', orderId, {
        orderId, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name, branchId: 'B1',
        uid: ownerUid, userUid: ownerUid, salesmanUid: ownerUid, salesmanCode: code, salesmanId: code,
        status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10, items: [],
        submittedAt: new Date(at), createdAt: new Date(at),
      });
      for (let n = 1; n <= RECENT; n += 1) {
        await order(id(n), uid, accounts.salesman.code, now - n * 3 * 3600 * 1000);
      }
      await order(OLD_ID, uid, accounts.salesman.code, now - 200 * 86400 * 1000);
      await order(OTHER_ID, 'uid-another-salesperson', 'S777', now - 3600 * 1000);
    });

    await t.step('salesperson opens Order History: newest order first', async () => {
      const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      page = s.page;
      await B.loginMobile(page, s.url, accounts.salesman.email);
      await mobile.waitForHome(page);
      await B.semantic(page, /^Orders$/).click();
      await B.see(page, exact(id(1)));
      await t.shot(s, 'first-page');
    });

    await t.step('page 1 ends at order 50 with "Load older orders"', async () => {
      await scrollToFooter(page, 'Load older orders');
      await B.see(page, exact(id(50)));
      if (await countText(page, exact(id(51)))) throw new Error('order 51 was loaded with the first page');
    });

    await t.step('"Load older orders" adds orders 51-100, none skipped or doubled', async () => {
      await page.getByRole('button', { name: 'Load older orders' }).click();
      await B.see(page, exact(id(51)));
      if ((await countText(page, exact(id(50)))) > (await countText(page, exact(id(51))))) throw new Error('order 50 is shown twice');
      await scrollToFooter(page, 'Load older orders');
      await B.see(page, exact(id(100)));
      if (await countText(page, exact(id(101)))) throw new Error('order 101 was loaded with page 2');
    });

    await t.step('the last recent page ends at order 120, then "Show older orders"', async () => {
      await page.getByRole('button', { name: 'Load older orders' }).click();
      await scrollToFooter(page, 'Show older orders');
      await B.see(page, exact(id(RECENT)));
      if (await countText(page, /^Load older orders$/)) throw new Error('"Load older orders" stayed after the last page');
    });

    await t.step('"Show older orders" reveals the order older than the retention window', async () => {
      await page.getByRole('button', { name: 'Show older orders' }).click();
      await B.see(page, exact(id(1)));
      for (let i = 0; i < 6 && !(await countText(page, exact(OLD_ID))); i += 1) {
        try {
          await scrollToFooter(page, 'Load older orders');
        } catch (_) {
          break;
        }
        await page.getByRole('button', { name: 'Load older orders' }).click();
        await page.waitForTimeout(800);
      }
      for (let i = 0; i < 30 && !(await countText(page, exact(OLD_ID))); i += 1) {
        await page.mouse.wheel(0, 600);
        await page.waitForTimeout(200);
      }
      await B.see(page, exact(OLD_ID));
    });

    await t.step("another salesperson's order never appears", async () => {
      if (await countText(page, exact(OTHER_ID))) throw new Error("another salesperson's order is in the list");
    });
  },
};
