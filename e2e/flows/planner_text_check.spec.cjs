'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const MASH = "iewry34789u82772979279uewdii93289upi['[P[]';[';[";
const REFUSED = /Purpose can use only letters, numbers, spaces and basic punctuation/;
const GOOD = 'Restock and check shelf space';

module.exports = {
  name: 'planner_text_check',
  async run(t) {
    const { db, accounts, seed } = t;
    let m;

    const visitsWith = async (purpose) =>
      (await db.list('visits')).filter((v) => v.purpose === purpose && v.salesmanUid === seed.uids.salesman);

    await t.step('salesperson opens a new visit plan for today', async () => {
      m = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(m.page, m.url, accounts.salesman.email);
      await mobile.waitForHome(m.page);
      await m.page.getByRole('button', { name: 'Planner', exact: true }).click();
      await m.page.getByRole('button', { name: 'Add Visit', exact: true }).click();
      await m.page.getByRole('button', { name: 'Choose a date' }).click();
      await m.page.getByRole('button', { name: /, Today$/ }).click();
      await m.page.getByRole('button', { name: 'OK', exact: true }).click();
      await m.page.getByRole('button', { name: 'Choose a retailer' }).click();
      await m.page.getByRole('menuitem', { name: RETAILERS[0].name }).click();
    });

    await t.step('a keyboard mash as purpose is refused and nothing is saved', async () => {
      await B.fillField(m.page, m.page.getByRole('textbox').first(), MASH);
      await t.shot(m, 'mash-typed');
      await m.page.getByRole('button', { name: 'Save plan' }).click();
      await B.see(m.page, REFUSED);
      await t.shot(m, 'mash-refused');
      await m.page.waitForTimeout(1500);
      if ((await visitsWith(MASH)).length !== 0) throw new Error('the refused purpose was saved');
    });

    await t.step('a plain purpose saves the visit', async () => {
      await B.fillField(m.page, m.page.getByRole('textbox').first(), GOOD);
      await m.page.getByRole('button', { name: 'Save plan' }).click();
      await m.page.getByRole('button', { name: /^Mon|^Tue|^Wed|^Thu|^Fri|^Sat|^Sun/ }).first().waitFor({ timeout: 20000 });
      await t.shot(m, 'plain-saved');
      const deadline = Date.now() + 20000;
      while ((await visitsWith(GOOD)).length !== 1) {
        if (Date.now() > deadline) throw new Error('the plain purpose visit was not saved once');
        await m.page.waitForTimeout(300);
      }
    });
  },
};
