'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

module.exports = {
  name: 'copilot_language',
  async run(t) {
    const { db, accounts } = t;
    let s;
    const page = () => s.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const ask = async (text, re) => {
      const before = await find(re).count();
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
      const end = Date.now() + 30000;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) return;
        await page().waitForTimeout(150);
      }
      throw new Error(`after "${text}" expected a reply matching ${re}`);
    };
    const writeCount = async () => (await db.list('route_plans')).length + (await db.list('orders')).length;

    await t.step('admin opens the Scout panel', async () => {
      s = await t.session('admin');
      await B.loginAdmin(page(), s.url, accounts.admin.email);
      await admin.waitForShell(page());
      await page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await B.see(page(), 'Scout panel');
    });

    const writes = await writeCount();
    await t.step('small talk and ranges', async () => {
      await ask('how are you doing', /I am doing well/);
      await ask('whats on my order page for the past few weeks', /past 28 days/);
      await ask('check my orders for the month of september', /September 20\d\d/);
      await ask('check the order for Tejo in september', /September 20\d\d|find "Tejo"/);
    });
    await t.step('a typo in "page" still opens the page', async () => {
      await ask('open notification apge', /Opened Notifications/);
    });
    await t.step('progress opens the activity page', async () => {
      await ask('check my salesman progress today', /Opened (Team|Salesman) Activity/);
    });
    await t.step('route and approve requests only point to the page', async () => {
      await ask('create a route for my salesman Tejo for next week', /Opened Route Planner|find "Tejo"/);
      await ask('approve it all', /waiting for approval/);
      if ((await writeCount()) !== writes) throw new Error('a request wrote data');
    });
    await t.step('top retailers and products', async () => {
      await ask('check the top retailers in september', /Top retailers|no top retailers/);
      await ask('what is the top product sold this month', /Top products|no top products/);
    });
    await t.step('an unknown name gets the fixed reply', async () => {
      await ask('orders from Zzyzx Qwerty', /find "Zzyzx Qwerty" among the records your role can see/);
    });
  },
};
