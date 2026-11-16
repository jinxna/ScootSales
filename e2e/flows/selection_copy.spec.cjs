'use strict';

const fs = require('node:fs');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

module.exports = {
  name: 'selection_copy',
  async run(t) {
    const { accounts } = t;
    let s;

    await t.step('admin opens a table page', async () => {
      s = await t.session('admin', { permissions: ['clipboard-read', 'clipboard-write'] });
      const font = ['C:/Windows/Fonts/arial.ttf', '/Library/Fonts/Arial.ttf', '/System/Library/Fonts/Supplemental/Arial.ttf', '/usr/share/fonts/truetype/dejavu/DejaVuSans.ttf'].find((f) => fs.existsSync(f));
      if (!font) throw new Error('no local TTF font found to serve to the page; selection cannot be tested without glyphs');
      await s.context.route(/fonts\.gstatic\.com/, (r) => r.fulfill({ path: font, contentType: 'font/ttf', headers: { 'access-control-allow-origin': '*' } }));
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'All Orders');
    });

    await t.step('a drag across page text selects it and Ctrl+C copies the visible text', async () => {
      const heading = await B.semantic(s.page, 'Order list').first().boundingBox();
      if (!heading) throw new Error('the "Order list" heading is not on the page');
      const y = heading.y + heading.height / 2;
      await s.page.evaluate(() => navigator.clipboard.writeText('E2E-CLIPBOARD-SENTINEL'));
      await s.page.mouse.move(heading.x + 1, y);
      await s.page.mouse.down();
      await s.page.waitForTimeout(100);
      for (let i = 1; i <= 30; i += 1) {
        await s.page.mouse.move(heading.x + 1 + (heading.width * i) / 30, y);
        await s.page.waitForTimeout(20);
      }
      await s.page.mouse.up();
      await t.shot(s, 'selected');
      await s.page.keyboard.press('Control+C');
      await s.page.waitForTimeout(500);
      const copied = (await s.page.evaluate(() => navigator.clipboard.readText())).trim();
      if (copied !== 'Order list') throw new Error(`Ctrl+C should copy the dragged heading "Order list", clipboard: ${JSON.stringify(copied)}`);
      await admin.goToPage(s.page, 'Dashboard');
    });

    await t.step('the Scout composer still accepts typing', async () => {
      await s.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      const box = s.page.getByRole('textbox').last();
      await B.fillField(s.page, box, 'hello');
      const value = await box.inputValue();
      if (value !== 'hello') throw new Error(`composer text: ${value}`);
    });
  },
};
