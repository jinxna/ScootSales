'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');
const { PASSWORD } = require('../lib/emulator.cjs');

const ORDER_ID = 'ORD-PRIVATE-001';

module.exports = {
  name: 'mobile_session_history',
  async run(t) {
    const { db, accounts, seed } = t;

    await t.step('seed one submitted order for the salesperson', async () => {
      const uid = seed.uids.salesman;
      await db.put('orders', ORDER_ID, {
        orderId: ORDER_ID, retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
        outlet: RETAILERS[0].name, branchId: 'B1', uid, userUid: uid, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code,
        status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 123.45,
        items: [{ productId: 'prod-1', name: 'Private order product', qty: 1, price: 123.45 }],
        submittedAt: new Date(), createdAt: new Date(),
      });
    });

    await t.step('after the idle lock, another user cannot see the open order', async () => {
      const s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await s.page.clock.install();
      await B.loginMobile(s.page, s.url, accounts.salesman.email);
      await mobile.waitForHome(s.page);
      await s.page.getByRole('button', { name: /^Orders/ }).click();
      await B.semantic(s.page, ORDER_ID).click();
      await B.see(s.page, 'Order Details');
      await s.page.clock.fastForward('02:01:00');
      const different = s.page.getByRole('button', { name: 'Sign in as a different user' });
      await different.waitFor({ timeout: 15000 });
      await t.shot(s, 'locked');
      await different.click();
      const previousOrderShown = [];
      for (const until = Date.now() + 3000; Date.now() < until;) {
        previousOrderShown.push(await B.semantic(s.page, ORDER_ID).count() + await B.semantic(s.page, 'Order Details').count());
      }
      await s.page.getByRole('button', { name: /^Sign in$/ }).waitFor({ timeout: 15000 });
      expectEqual(Math.max(...previousOrderShown), 0, `previous order visible at any moment after "Sign in as a different user" (${previousOrderShown.length} samples)`);
      expectEqual(await B.semantic(s.page, ORDER_ID).count(), 0, 'previous order visible after "Sign in as a different user"');
      expectEqual(await B.semantic(s.page, 'Order Details').count(), 0, 'order details visible after "Sign in as a different user"');
      await t.shot(s, 'after-different-user');
    });

    let m;
    await t.step('the Rejected status hides a submitted order at once', async () => {
      m = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(m.page, m.url, accounts.salesman.email);
      await mobile.waitForHome(m.page);
      await m.page.getByRole('button', { name: /^Orders/ }).click();
      await B.see(m.page, ORDER_ID);
      await B.semantic(m.page, /^Rejected$/).click();
      await m.page.waitForTimeout(1000);
      expectEqual(await B.semantic(m.page, ORDER_ID).count(), 0, 'submitted order shown under Rejected');
      await t.shot(m, 'rejected-filter');
    });

    await t.step('back from an order keeps the history list working', async () => {
      await B.semantic(m.page, /^All$/).click();
      await B.semantic(m.page, ORDER_ID).click();
      await B.see(m.page, 'Order Details');
      await m.page.mouse.click(34, 38);
      await B.see(m.page, ORDER_ID);
      await m.page.waitForTimeout(1500);
      await t.shot(m, 'history-after-back');
    });

    await t.step('the same user unlocks with the password', async () => {
      const u = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await u.page.clock.install();
      await B.loginMobile(u.page, u.url, accounts.salesman.email);
      await mobile.waitForHome(u.page);
      await u.page.clock.fastForward('02:01:00');
      await u.page.getByRole('button', { name: 'Sign in as a different user' }).waitFor({ timeout: 15000 });
      await B.fillField(u.page, u.page.locator('input').last(), PASSWORD);
      await u.page.getByRole('button', { name: 'Unlock' }).click();
      await u.page.getByRole('button', { name: /^Orders/ }).waitFor({ timeout: 15000 });
      expectEqual(await B.semantic(u.page, 'Session locked').count(), 0, 'lock still shown after unlock');
      await t.shot(u, 'after-unlock');
    });
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
