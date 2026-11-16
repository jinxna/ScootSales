'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');

const fragment = (page) => new URL(page.url()).hash;
function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

async function pageBrightness(page) {
  const { width, height } = page.viewportSize();
  const png = await page.screenshot({ clip: { x: Math.round(width * 0.8), y: Math.round(height * 0.85), width: 24, height: 24 } });
  return page.evaluate(async (bytes) => {
    const bitmap = await createImageBitmap(new Blob([new Uint8Array(bytes)], { type: 'image/png' }));
    const canvas = new OffscreenCanvas(bitmap.width, bitmap.height);
    const context = canvas.getContext('2d');
    context.drawImage(bitmap, 0, 0);
    const data = context.getImageData(0, 0, bitmap.width, bitmap.height).data;
    let sum = 0;
    for (let i = 0; i < data.length; i += 4) sum += (data[i] + data[i + 1] + data[i + 2]) / 3;
    return sum / (data.length / 4);
  }, [...png]);
}

async function expectTheme(page, theme, what) {
  await page.waitForTimeout(800);
  const brightness = await pageBrightness(page);
  const actual = brightness < 128 ? 'dark' : 'light';
  if (actual !== theme) throw new Error(`${what}: expected a ${theme} page, got ${actual} (brightness ${brightness.toFixed(0)})`);
}

async function chooseTheme(page, accountName, theme) {
  await page.getByRole('button', { name: accountName }).first().click();
  await B.semantic(page, /^Appearance/).click();
  await B.semantic(page, new RegExp(`^${theme}$`)).click();
  await page.waitForTimeout(700);
  await page.keyboard.press('Escape');
  await page.waitForTimeout(600);
}

const STRANGER = 'e2e.google.stranger@example.test';
const GOOGLE_AUTH_HOSTS = /^https:\/\/(identitytoolkit|securetoken)\.googleapis\.com\//;

async function authCall(path, body) {
  const response = await fetch(`${E.requireEmulators().authBase}/projects/${E.PROJECT}/${path}`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
    body: JSON.stringify(body),
  });
  if (!response.ok) throw new Error(`${path}: ${response.status} ${await response.text()}`);
  return response.json();
}

async function authAccounts(email) {
  return (await authCall('accounts:lookup', { email: [email] })).users || [];
}

async function restoreAccount(account) {
  await authCall('accounts:update', {
    localId: account.localId, deleteProvider: ['google.com'], password: E.PASSWORD,
    emailVerified: Boolean(account.emailVerified),
    ...(account.displayName ? { displayName: account.displayName } : { deleteAttribute: ['DISPLAY_NAME'] }),
  });
}

async function googleSignIn(s, email, name) {
  await s.context.route(/^https:\/\/apis\.google\.com\//, (route) => route.continue());
  const popupOpened = s.page.waitForEvent('popup', { timeout: 30000 });
  await s.page.getByRole('button', { name: 'Continue with Google' }).click();
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

async function signOut(page, accountName) {
  await page.getByRole('button', { name: accountName }).first().click();
  await B.semantic(page, /^Sign out$/).click();
  await B.see(page, /Sign In/);
}

module.exports = {
  name: 'login_landing',
  async run(t) {
    const { accounts } = t;
    let s;

    await t.step('admin opens All Orders; a refresh keeps the page', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'All Orders');
      expectEqual(fragment(s.page), '#/all_orders', 'fragment after navigation');
      await s.page.reload();
      await B.enableSemantics(s.page);
      await admin.waitForShell(s.page);
      expectEqual(fragment(s.page), '#/all_orders', 'fragment after refresh');
    });

    await t.step('the admin chooses the dark theme', async () => {
      await expectTheme(s.page, 'light', 'admin before choosing a theme');
      await chooseTheme(s.page, /E2E Admin/, 'Dark');
      await expectTheme(s.page, 'dark', 'admin after choosing Dark');
      await t.shot(s, 'admin_dark');
    });

    await t.step('sign-out clears the page from the address bar', async () => {
      await signOut(s.page, /E2E Admin/);
      expectEqual(fragment(s.page), '', 'fragment on the login screen');
      await expectTheme(s.page, 'light', 'login screen after the admin signs out');
    });

    await t.step('a supervisor logging in lands on Team Overview, not All Orders', async () => {
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
      expectEqual(fragment(s.page), '#/dashboard', 'supervisor landing fragment');
      await expectTheme(s.page, 'light', 'supervisor after the admin chose Dark');
      await t.shot(s, 'supervisor_landing');
    });

    await t.step('Back never opens the previous account\'s page', async () => {
      await s.page.goBack();
      await s.page.waitForTimeout(500);
      await admin.waitForSupervisorShell(s.page);
      expectEqual(fragment(s.page), '#/dashboard', 'fragment after Back');
    });

    await t.step('each account keeps its own theme across sign-in and reload', async () => {
      await signOut(s.page, /E2E Supervisor/);
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await expectTheme(s.page, 'dark', 'admin signing in again');
      await s.page.reload();
      await B.enableSemantics(s.page);
      await admin.waitForShell(s.page);
      await expectTheme(s.page, 'dark', 'admin after a reload');
      await signOut(s.page, /E2E Admin/);
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
      await expectTheme(s.page, 'light', 'supervisor signing in again');
    });

    await t.step('Continue with Google refuses an email with no company access and leaves no account', async () => {
      await signOut(s.page, /E2E Supervisor/);
      await googleSignIn(s, STRANGER, 'E2E Stranger');
      await B.see(s.page, /This Google account has no access to this company\./);
      expectEqual((await authAccounts(STRANGER)).length, 0, 'Auth accounts for the refused Google email');
      await t.shot(s, 'google_stranger_refused');
    });

    await t.step('an existing admin continues with Google, keeps one account, and a reload never calls Google servers', async () => {
      const [before] = await authAccounts(accounts.admin.email);
      try {
        await googleSignIn(s, accounts.admin.email, before.displayName || 'E2E Admin');
        await admin.waitForShell(s.page);
        const [after] = await authAccounts(accounts.admin.email);
        expectEqual(after.localId, before.localId, 'admin uid after Google');
        expectEqual(after.providerUserInfo.map((p) => p.providerId).sort().join(','),
          before.emailVerified ? 'google.com,password' : 'google.com', 'admin providers after Google');
        const leaks = [];
        await s.page.route(GOOGLE_AUTH_HOSTS, (route) => {
          leaks.push(route.request().url());
          return route.fulfill({ status: 404, body: '' });
        });
        await s.page.reload();
        await B.enableSemantics(s.page);
        await admin.waitForShell(s.page);
        expectEqual(leaks.length, 0, 'requests to Google sign-in servers after a reload');
        await s.page.unroute(GOOGLE_AUTH_HOSTS);
        await t.shot(s, 'admin_google_signed_in');
        await signOut(s.page, /E2E Admin/);
      } finally {
        await restoreAccount(before);
      }
      await B.loginAdmin(s.page, s.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(s.page);
    });

    await t.step('supervisor narrow screen loads every asset (compact header logo)', async () => {
      await B.expectAssetsLoad(
        s.page,
        () => s.page.setViewportSize({ width: 390, height: 844 }),
        'Open menu',
      );
      await t.shot(s, 'supervisor_compact');
    });
  },
};
