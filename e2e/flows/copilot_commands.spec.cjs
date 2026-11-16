'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[1];
const OAT = PRODUCTS[2];
const CIDER = PRODUCTS[0];

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function askCopilot(page, text) {
  const input = page.getByRole('textbox', { name: /Ask or say a command/ });
  await B.fillField(page, input, text);
  await page.keyboard.press('Enter');
}

module.exports = {
  name: 'copilot_commands',
  async run(t) {
    const { accounts } = t;
    let s;

    await t.step('salesperson opens a planned visit on mobile', async () => {
      s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(s.page, s.url, accounts.salesman.email);
      await mobile.waitForHome(s.page);
      await mobile.planVisitToday(s.page, RETAILER.name);
      await mobile.openPlannedVisit(s.page, RETAILER.name);
    });

    await t.step('no floating mic: the Scout pill opens the sheet with this screen\'s commands', async () => {
      const page = s.page;
      expectEqual(await page.getByRole('button', { name: /by voice/ }).count(), 0, 'voice buttons');
      await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      const chip = page.getByText(/^Search for /).first();
      await chip.waitFor({ timeout: 15000 });
      const query = (await chip.innerText()).replace(/^Search for /, '').trim().toLowerCase();
      if (!PRODUCTS.some((p) => p.name.toLowerCase().startsWith(query))) {
        throw new Error(`search chip "${query}" is not a seeded product`);
      }
      await t.shot(s, 'sheet-select');
    });

    await t.step('a safe command runs at once and the sheet closes on the result', async () => {
      const page = s.page;
      await askCopilot(page, 'search for rolled oat');
      await page.getByRole('textbox', { name: /Ask or say a command/ }).waitFor({ state: 'detached', timeout: 15000 });
      await B.see(page, /REGULAR ROLLED OAT/);
      await t.shot(s, 'searched');
    });

    await t.step('reach the order sign-off with the oat in the cart', async () => {
      const page = s.page;
      await page.getByRole('checkbox', { name: new RegExp(`^(?:[^\\n·]+ · )?${OAT.name.replace(/[()]/g, '\\$&')}`) }).click();
      await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).click();
      await page.getByRole('button', { name: 'Start counting' }).click();
      await mobile.continueToSignature(page);
      await B.see(page, 'Total (1 product, 1 box)');
    });

    await t.step('a protected command waits on Confirm, then changes the order', async () => {
      const page = s.page;
      await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      await askCopilot(page, 'set rolled oat to 3 boxes');
      await B.see(page, 'Set rolled oat to 3 boxes?');
      await t.shot(s, 'confirm-card');
      await page.getByRole('button', { name: 'Confirm', exact: true }).click();
      await B.see(page, 'Total (1 product, 3 boxes)');
      await t.shot(s, 'confirmed');
    });

    await t.step('submitting by voice stays blocked: no confirmation is offered', async () => {
      const page = s.page;
      await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      await askCopilot(page, 'submit this order');
      await B.see(page, /Do that on the screen/);
      expectEqual(await page.getByRole('button', { name: 'Confirm', exact: true }).count(), 0, 'confirm buttons for submit');
    });

    await t.step('Cancel on a protected command changes nothing', async () => {
      const page = s.page;
      await askCopilot(page, 'set rolled oat to 5 boxes');
      await B.see(page, 'Set rolled oat to 5 boxes?');
      await page.getByRole('button', { name: 'Cancel', exact: true }).click();
      await B.see(page, 'Cancelled. Nothing changed.');
      await page.getByRole('button', { name: 'Close Scout' }).click();
      await B.see(page, 'Total (1 product, 3 boxes)');
      expectEqual(await page.getByText(CIDER.name).count(), 0, 'unrelated product lines');
    });
  },
};
