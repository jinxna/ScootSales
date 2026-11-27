'use strict';

const B = require('../lib/browser.cjs');

const WIDTHS = [1440, 900, 700, 470, 340];
const CONTROLS = [/^(All dates|\d\d\/\d\d\/\d{4})/, /^Mark all as read/, /^All \d+/, /^System \d+/];
const CHIPS = CONTROLS.slice(2);
const NOTIFICATIONS_ENTRY = /^Notifications(, \d+ (or more )?unread)?(, current page)?$/;

module.exports = {
  name: 'notifications_toolbar',
  async run(t) {
    const { db, accounts } = t;
    let s;

    await t.step('seed system notifications', async () => {
      const now = Date.now();
      for (let i = 0; i < 4; i += 1) {
        await db.put('dashboard_notifications', `ntf-${i}`, {
          title: `Forecast refreshed ${i}`, message: `Forecast refreshed ${i}`,
          type: 'system', roleTarget: 'all', createdAt: new Date(now - i * 3600000),
        });
      }
    });

    await t.step('admin opens Notifications', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await s.page.getByRole('button', { name: NOTIFICATIONS_ENTRY }).first().click();
      await B.see(s.page, /^System \d+/);
    });

    await t.step('sidebar entries survive being scrolled away and back', async () => {
      await s.page.setViewportSize({ width: 1440, height: 420 });
      await s.page.waitForTimeout(600);
      await s.page.mouse.move(120, 300);
      for (const dy of [5000, -5000, 5000, -5000]) {
        await s.page.mouse.wheel(0, dy);
        await s.page.waitForTimeout(500);
      }
      await s.page.getByRole('button', { name: NOTIFICATIONS_ENTRY }).first().waitFor({ state: 'attached' });
    });

    for (const width of WIDTHS) {
      await t.step(`toolbar is one row inside the viewport at ${width}px`, async () => {
        await s.page.setViewportSize({ width, height: 900 });
        await s.page.waitForTimeout(600);
        const boxes = [];
        for (const name of CONTROLS) {
          const loc = s.page.getByRole('button', { name }).first();
          await loc.waitFor({ state: 'attached', timeout: 10000 });
          boxes.push(await loc.boundingBox());
        }
        const chipBoxes = boxes.slice(CONTROLS.length - CHIPS.length);
        const top = Math.min(...chipBoxes.map((b) => b.y));
        const bottom = Math.max(...chipBoxes.map((b) => b.y + b.height));
        expectEqual(bottom - top <= 40, true, `the filter chips share one row (spread ${bottom - top}px)`);
        expectEqual(boxes.every((b) => b.x >= 0 && b.x + b.width <= width + 1), true, 'controls fit the viewport');
        const doc = await s.page.evaluate(() => document.documentElement.scrollWidth);
        expectEqual(doc <= width + 1, true, `no horizontal scroll (${doc} > ${width})`);
        await t.shot(s, `toolbar-${width}`);
      });
    }
  },
};

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
