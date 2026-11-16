'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const directory = require('../lib/platform_api.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'account_deletion');
const ORDER_ID = 'ORD-E2E-DELETION';

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'account_deletion',
  platformMail: true,
  platformScheduler: true,
  async run(t) {
    const { db, accounts, seed } = t;
    const sales = accounts.salesman;
    const uid = seed.uids.salesman;
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const evidence = { project: E.PROJECT, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    fs.mkdirSync(OUT, { recursive: true });
    const sink = await startMailSink();
    const signIn = async () => {
      const response = await fetch(`${db.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email: sales.email, password: E.PASSWORD, returnSecureToken: true }),
      });
      return (await response.json()).error?.message || 'OK';
    };
    let adminS;
    let mobileS;

    try {
      await t.step('the mail sink starts empty and the salesperson has an order and GPS records', async () => {
        await sink.clear();
        const retailer = RETAILERS[0];
        const product = PRODUCTS[0];
        await db.put('orders', ORDER_ID, {
          orderId: ORDER_ID, uid, userUid: uid, salesmanUid: uid, salesmanEmail: sales.email, salesmanName: sales.name,
          submittedByName: sales.name, createdByName: sales.name, salesmanCode: sales.code, branchId: sales.branch,
          retailerId: retailer.id, retailerName: retailer.name, status: 'submitted',
          items: [{ productId: product.id, name: product.name, productName: product.name, quantity: 1, price: product.price }],
          totalProducts: 1, totalBoxes: 1, totalPrice: product.price, submittedAt: new Date(), createdAt: new Date(),
        });
        await db.put('gps_tracking', 'E2E-GPS-1', { uid, salesmanUid: uid, latitude: 1.55, longitude: 110.35, timestamp: new Date() });
        await db.put('live_tracking', uid, { uid, latitude: 1.55, longitude: 110.35, updatedAt: new Date() });
        expectEqual((await sink.messages()).length, 0, 'messages in the sink');
      });

      await t.step('admin sees the order under the salesperson name', async () => {
        adminS = await t.session('admin');
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        await admin.goToPage(adminS.page, 'All Orders');
        await admin.waitForOrderRow(adminS.page, ORDER_ID);
        await B.see(adminS.page, sales.name);
      });

      await t.step('the salesperson requests deletion on the phone and is signed out', async () => {
        mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
        await B.loginMobile(mobileS.page, mobileS.url, sales.email);
        await mobile.waitForHome(mobileS.page);
        await mobile.openTab(mobileS.page, 'Profile');
        const row = mobileS.page.getByRole('button', { name: 'Delete account', exact: true });
        await B.scrollIntoView(mobileS.page, row, { minHeight: 20, bottomInset: 0 });
        await row.click();
        await B.see(mobileS.page, 'What the company keeps');
        await t.shot(mobileS, 'delete-account');
        await B.fillField(mobileS.page, mobileS.page.locator('input').last(), E.PASSWORD);
        await mobileS.page.getByRole('button', { name: 'Request deletion', exact: true }).click();
        await B.see(mobileS.page, 'Request sent');
        await t.shot(mobileS, 'request-sent');
        await mobileS.page.getByRole('button', { name: 'OK', exact: true }).click();
        await mobileS.page.getByRole('button', { name: /^Sign in$/ }).waitFor({ timeout: 30000 });
        const request = await db.get('privacy_deletion_requests', uid);
        expectEqual([request.requestType, ['submitted', 'reviewing'].includes(request.status)], ['account_deletion', true], 'request document');
      });

      await t.step('the scheduler turns the account off and marks it for deletion', async () => {
        const access = await db.waitForDoc('user_access', uid, (a) => (a.disabledReasons || []).includes('deletion_requested'),
          { timeout: 60000, label: 'deletion_requested on the access record' });
        expectEqual(access.disabledReasons, ['deletion_requested'], 'disabledReasons');
        const request = await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.status === 'reviewing' && r.purgeAfter,
          { timeout: 60000, label: 'accepted request' });
        const days = Math.round((request.purgeAfter - request.createdAt) / 86400000);
        expectEqual(days, 30, 'days until the automatic deletion');
        expectEqual(await signIn(), 'USER_DISABLED', 'Auth sign-in after the request');
        note('requested', { purgeAfter: request.purgeAfter, days });
      });

      await t.step('the next phone sign-in is refused', async () => {
        const blocked = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-blocked' });
        await B.loginMobile(blocked.page, blocked.url, sales.email);
        await B.see(blocked.page, /disabled/i, { timeout: 40000 });
        expectEqual(await blocked.page.getByRole('button', { name: 'Planner', exact: true }).count(), 0, 'Planner buttons visible');
        await t.shot(blocked, 'blocked');
      });

      await t.step('the administrator mail reaches the sink without the salesperson name', async () => {
        const hits = await sink.waitForMessage(accounts.admin.email);
        const message = await sink.message(hits[0].ID);
        fs.writeFileSync(path.join(OUT, 'admin-mail.txt'), message.Text);
        fs.writeFileSync(path.join(OUT, 'admin-mail.html'), message.HTML);
        if (!/Account deletion request in /.test(message.Subject)) throw new Error(`subject: ${message.Subject}`);
        if (!/Their sign-in is turned off now/.test(message.Text)) throw new Error(`text: ${message.Text}`);
        for (const part of [message.Subject, message.Text, message.HTML]) {
          if (part.includes(sales.name) || part.includes(sales.email)) throw new Error('the mail names the salesperson');
        }
        const job = await platformDb.waitForQuery('mail_jobs', (j) => j.kind === 'account_deletion_notice' && j.status === 'sent',
          { timeout: 60000, label: 'sent account_deletion_notice job' });
        note('mail', { subject: message.Subject, jobId: job.jobId });
      });

      await t.step('the dashboard shows "Deletion requested"', async () => {
        await admin.goToPage(adminS.page, 'Role Assignment');
        await B.see(adminS.page, /Deletion requested/, { timeout: 40000 });
        await t.shot(adminS, 'deletion-requested');
      });

      await t.step('admin chooses "Delete now" and confirms', async () => {
        await adminS.page.getByRole('button', { name: /Account deletion requests/ }).first().click();
        const deleteNow = adminS.page.getByRole('button', { name: 'Delete now', exact: true });
        await deleteNow.first().waitFor({ timeout: 20000 });
        await deleteNow.first().click();
        await B.see(adminS.page, 'Delete this account now?');
        await t.shot(adminS, 'delete-now-dialog');
        await deleteNow.last().click();
      });

      await t.step('after Delete now the sign-in stays off at once and the account can be restored for 7 days', async () => {
        const request = await db.waitForDoc('privacy_deletion_requests', uid, (r) => r.status === 'reviewing' && r.purgeAfter && r.purgeAfter - Date.now() < 7.5 * 86400000,
          { timeout: 90000, label: 'request shortened to the 7 day restore window' });
        expectEqual(await signIn(), 'USER_DISABLED', 'Auth sign-in after Delete now');
        const access = await db.get('user_access', uid);
        expectEqual(access.disabledReasons, ['deletion_requested'], 'disabledReasons after Delete now');
        expectEqual(request.purgedAt, undefined, 'purgedAt inside the restore window');
        expectEqual((await db.get('users', sales.email)) !== null, true, 'users profile kept during the restore window');
        expectEqual((await db.get('gps_tracking', 'E2E-GPS-1')) !== null, true, 'gps_tracking kept during the restore window');
        note('restore_window', { purgeAfter: request.purgeAfter });
      });

      await t.step('orders still carry the real name until the 7 days end', async () => {
        const order = await db.get('orders', ORDER_ID);
        expectEqual([order.salesmanName, order.totalPrice], [sales.name, PRODUCTS[0].price], 'order during the restore window');
        note('orders', { orderId: ORDER_ID, salesmanName: order.salesmanName });
      });
    } finally {
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
      await sink.close();
    }
  },
};
