'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const directory = require('../lib/platform_api.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'google_export');
const WIDTH = Number(process.env.E2E_ACCOUNT_WIDTH || 1600);

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function authCall(route, body) {
  const response = await fetch(`${E.requireEmulators().authBase}/projects/${E.PROJECT}/${route}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${route}: ${response.status} ${await response.text()}`);
  return response.json();
}

async function googlePopup(s, trigger, email, name) {
  await s.context.route(/^https:\/\/apis\.google\.com\//, (route) => route.continue());
  const popupOpened = s.page.waitForEvent('popup', { timeout: 30000 });
  await trigger();
  const popup = await popupOpened;
  await popup.waitForLoadState('domcontentloaded');
  const known = popup.locator('.js-reuse-account', { hasText: email });
  if (await known.count()) {
    await known.first().click();
  } else {
    await popup.locator('#add-account-button').click();
    await popup.locator('#email-input').fill(email);
    await popup.locator('#display-name-input').fill(name);
    await popup.locator('#sign-in').click();
  }
  await popup.waitForEvent('close', { timeout: 30000 }).catch(() => {});
}

module.exports = {
  name: 'google_export',
  async run(t) {
    const { accounts } = t;
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    fs.mkdirSync(OUT, { recursive: true });
    let s;

    await t.step('an admin who signs in with Google only (no password) opens Account', async () => {
      s = await t.session('admin', { acceptDownloads: true });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await s.page.getByRole('button', { name: accounts.admin.name }).first().click();
      await B.semantic(s.page, /^Sign out$/).click();
      await B.see(s.page, /Sign In/);
      await googlePopup(s, () => s.page.getByRole('button', { name: 'Continue with Google' }).click(), accounts.admin.email, accounts.admin.name);
      await admin.waitForShell(s.page);
      const lookup = await authCall('accounts:lookup', { email: [accounts.admin.email] });
      await authCall('accounts:update', { localId: lookup.users[0].localId, deleteProvider: ['password'] });
      await s.page.reload();
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Account');
      await B.see(s.page, 'Confirm with Google to see your plan and usage.');
      expectEqual(await s.page.locator('input[type="password"]').count(), 0, 'password fields shown to a Google-only admin');
      await B.shotAtWidths(t, s, 'google-only-locked');
    });

    await t.step('Confirm with Google opens the account page and the export downloads', async () => {
      await s.page.setViewportSize({ width: WIDTH, height: WIDTH < 800 ? 844 : 1100 });
      await s.page.waitForTimeout(1500);
      await googlePopup(s, () => s.page.getByRole('button', { name: 'Confirm with Google' }).last().click(), accounts.admin.email, accounts.admin.name);
      await B.see(s.page, /Plan: /, { timeout: 30000 });
      const exportButton = s.page.getByRole('button', { name: 'Download tenant export' });
      await B.scrollIntoView(s.page, exportButton, { minHeight: 36 });
      const [download] = await Promise.all([s.page.waitForEvent('download', { timeout: 60000 }), exportButton.click()]);
      await download.saveAs(path.join(OUT, 'google-export.zip'));
      await B.see(s.page, 'The tenant export download started.');
      const audit = await platformDb.list('export_audit');
      expectEqual(audit.length, 1, 'export audit rows');
      await t.shot(s, 'google-export-done-' + WIDTH);
    });
  },
};
