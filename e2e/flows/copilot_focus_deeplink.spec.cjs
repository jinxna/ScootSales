'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

module.exports = {
  name: 'copilot_focus_deeplink',
  async run(t) {
    const { accounts, db } = t;
    let s;
    const page = () => s.page;
    const input = () => page().getByRole('textbox').last();
    const focused = () => page().evaluate(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName));
    const focusReturns = async () => {
      try {
        await page().waitForFunction(() => ['INPUT', 'TEXTAREA'].includes(document.activeElement?.tagName), null, { timeout: 3000 });
        return true;
      } catch {
        return false;
      }
    };

    await t.step('open the panel; the input has focus', async () => {
      await db.put('products', 'prod-noprice', { name: 'E2E PRODUCT WITHOUT PRICE', dept: 'GROCERY', department: 'GROCERY', code: 'E2E-NOPRICE', price: 0, unitPrice: 0 });
      s = await t.session('admin');
      await B.loginAdmin(page(), s.url, accounts.admin.email);
      await admin.waitForShell(page());
      await page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await B.see(page(), 'Scout panel');
      if (!(await focused())) throw new Error('input should be focused when the panel opens');
    });
    await t.step('after a send the input is still focused and typing works', async () => {
      await B.fillField(page(), input(), 'What needs my attention today?');
      await page().keyboard.press('Enter');
      await B.see(page(), /items need attention most/);
      if (!(await focusReturns())) throw new Error('input lost focus after a send');
      await page().keyboard.type('explain the first item');
      await page().keyboard.press('Enter');
      await B.see(page(), /Suggested action:/);
      if (!(await focusReturns())) throw new Error('input lost focus after the second send');
    });
    await t.step('tapping a briefing row opens its page or says it is unavailable', async () => {
      await page().getByText(/Missing product price/).first().click();
      await B.see(page(), /Opened .+|not available to your role/);
      if (!(await focusReturns())) throw new Error('input lost focus after a row tap');
    });
    await t.step('Escape closes the panel', async () => {
      await page().keyboard.press('Escape');
      await page().getByLabel('Scout panel').waitFor({ state: 'detached', timeout: 10000 });
    });
  },
};
