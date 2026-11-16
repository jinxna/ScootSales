'use strict';

const fs = require('node:fs');
const path = require('node:path');
const crypto = require('node:crypto');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DEPARTMENT = 'GROCERY';
const ORDERED = [PRODUCTS[0]];
const RETAILER = RETAILERS[0];
const SUPPORT_EMAIL = staff.STAFF_ROLE_EMAILS.support;
const RESTRICTED_BANNER = /is suspended\. The workspace is read-only/;

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

function check(condition, label) {
  if (!condition) throw new Error(label);
}

const isoSeconds = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');

async function signIn(email) {
  const { authBase } = E.requireEmulators();
  const response = await fetch(`${authBase}/accounts:signInWithPassword?key=fake-api-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ email, password: E.PASSWORD, returnSecureToken: true }),
  });
  const body = await response.json();
  return { ok: response.ok, idToken: body.idToken, error: body.error && body.error.message };
}

async function asUser(token, method, docPath, fields) {
  const { firestoreBase } = E.requireEmulators();
  const mask = fields ? `?${Object.keys(fields).map((f) => `updateMask.fieldPaths=${f}`).join('&')}` : '';
  const response = await fetch(`${firestoreBase}/${docPath}${mask}`, {
    method, headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${token}` },
    body: fields ? JSON.stringify({ fields: E.toFields(fields) }) : undefined,
  });
  return response.status;
}

module.exports = {
  name: 'v4_suspension', platformApi: false, seedPlan: false,
  async run(t) {
    const { db, accounts, seed } = t;
    const out = path.join(E.OUTPUT_DIR, 'v4_suspension');
    fs.mkdirSync(out, { recursive: true });
    const trusted = platform.ensureKey();
    const record = { ...platform.harnessRecord(), planRef: 'STARTER', edition: 'basic' };
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const evidence = { tenantId: record.tenantId, checks: [], lifecycle: [] };
    const note = (text) => evidence.checks.push(text);
    const servers = [];
    const priorEmulatorProjects = process.env.PLATFORM_EMULATOR_PROJECTS;
    let service;
    let payment;
    let phone;
    let adminS;

    const staffCall = async (who, method, route, body, key) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, {
        method, headers: { 'Content-Type': 'application/json', ...service.headers(who),
          Origin: service.url, 'Sec-Fetch-Site': 'same-origin',
          ...(key ? { 'Idempotency-Key': key } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${route} -> ${response.status} ${text}`);
      return text ? JSON.parse(text) : {};
    };
    const operator = (method, tail, body, key) => staffCall('operator', method, `/companies/${record.tenantId}${tail}`, body, key);
    const approved = async (action, params, key) => {
      const request = await staffCall('operator', 'POST', '/approvals', { action, tenantId: record.tenantId,
        reason: `E2E asks for ${action}`, params }, key);
      await staffCall('owner', 'POST', `/approvals/${request.approvalId}/approve`);
    };
    const lifecycle = async (state, expectedRevision, key, { approval = null } = {}) => {
      if (approval === 'suspend') await approved('lifecycle.suspend', { expectedRevision }, key);
      else if (approval === 'reactivate') await approved('lifecycle.reactivate', { expectedRevision, paymentEntryId: payment.entryId }, key);
      else {
        await operator('PUT', '/lifecycle', { state, expectedRevision,
          paymentEntryId: state === 'active' ? payment.entryId : null,
          reason: `E2E moves the company to ${state}`, ticket: null }, key);
      }
      const central = await platformDb.get('lifecycle', record.tenantId);
      const projected = await db.get('config', 'lifecycle');
      equal([central.state, projected.state], [state, state], `${state} central and tenant projection`);
      equal(projected.revision, central.revision, `${state} projected revision`);
      evidence.lifecycle.push({ state, revision: central.revision,
        retentionEndsAt: central.retentionEndsAt ? central.retentionEndsAt.toISOString() : null });
      return central;
    };
    const directoryStatus = async () => {
      const envelope = await (await fetch(`${platform.PLATFORM_API_URL}/v1/companies/${record.companyCode}`)).json();
      equal(JSON.parse(envelope.payload).status, 'live', 'directory record status');
      return ((await db.get('config', 'lifecycle')) || {}).state;
    };
    const reasons = async (uid) => (await db.get('user_access', uid)).disabledReasons || [];
    const ordersFor = async () => (await db.list('orders')).filter((o) => o.retailerId === RETAILER.id);

    try {
      await t.step('company is active with the one central service and the staff routes', async () => {
        await directory.resetDirectory();
        directory.seedDirectory([trusted], [{ record, key: trusted }]);
        servers.push(await directory.startPlatformApi({ origin: [t.urls.admin, t.urls.mobile], keys: [trusted] }));
        directory.planAdmin([trusted], [{ op: 'catalogue' }, { op: 'usage' }]);
        await db.del('config', 'lifecycle');
        process.env.PLATFORM_EMULATOR_PROJECTS = E.PROJECT;
        service = await staff.startStaffApi(trusted);
        servers.push({ stop: () => service.stop() });
        await operator('POST', '/package', { planId: 'STARTER', billingInterval: 'monthly', expectedRevision: 0,
          reason: 'E2E package for invoicing' }, 'suspension-package-0001');
        await approved('quote.price', { amountMinor: 500000, billingInterval: 'monthly' }, 'suspension-quote-0001');
        const draft = await operator('POST', '/invoices', {}, 'suspension-invoice-0001');
        const issued = await staffCall('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);
        payment = await operator('POST', '/payments', {
          amountMinor: issued.amountMinor, currency: 'MYR', externalReference: 'E2E/SUSPEND-001',
          invoiceId: issued.invoiceId, receivedAt: isoSeconds(new Date(Date.now() - 60000)),
          reason: 'Bank statement checked',
        }, 'suspension-payment-0001');
        await staffCall('owner', 'POST', `/companies/${record.tenantId}/payments/${payment.entryId}/check`);
        await lifecycle('active', 0, 'suspension-activate-01');
        equal(await directoryStatus(), 'active', 'company lifecycle');
        equal(await reasons(seed.uids.salesman), [], 'salesperson reasons while active');
        note(`company ${record.tenantId} active at lifecycle revision 1 from payment ${payment.entryId}`);
      });

      let oldSalesToken;
      await t.step('salesperson signs in on the phone and signs an order', async () => {
        phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-sales' });
        await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
        await mobile.waitForHome(phone.page);
        await mobile.planVisitToday(phone.page, RETAILER.name);
        await mobile.openPlannedVisit(phone.page, RETAILER.name);
        await mobile.selectProducts(phone.page, DEPARTMENT, ORDERED.map((p) => p.name));
        await mobile.continueToSignature(phone.page);
        await mobile.signOrder(phone.page, DEPARTMENT, ORDERED.length);
        const token = await signIn(accounts.salesman.email);
        check(token.ok, `salesperson token before suspension: ${token.error}`);
        oldSalesToken = token.idToken;
        equal(await asUser(oldSalesToken, 'GET', `products/${PRODUCTS[0].id}`), 200, 'salesperson product read before suspension');
        await t.shot(phone, 'signed-before-suspension');
        note('salesperson signed in, signed an order and holds an ID token issued before suspension');
      });

      await t.step('operator suspends the company through the staff API', async () => {
        const suspended = await lifecycle('suspended', 1, 'suspension-suspend-01', { approval: 'suspend' });
        const retentionDays = (suspended.retentionEndsAt - suspended.stateSince) / 86400000;
        check(Math.abs(retentionDays - 90) < 0.01, `retention ${retentionDays} days`);
        equal(await reasons(seed.uids.salesman), ['billing_lapse'], 'salesperson reasons');
        equal(await reasons(seed.uids.supervisor), ['billing_lapse'], 'supervisor reasons');
        equal(await reasons(seed.uids.admin), ['lifecycle_readonly'], 'admin reasons');
        equal(await directoryStatus(), 'suspended', 'company lifecycle');
        const paused = await signIn(accounts.salesman.email);
        check(paused.ok, `salesperson sign-in after suspension: ${paused.error}`);
        equal(await asUser(paused.idToken, 'GET', `products/${PRODUCTS[0].id}`), 403, 'new salesperson token product read');
        const supervisor = await signIn(accounts.supervisor.email);
        check(supervisor.ok, `supervisor sign-in after suspension: ${supervisor.error}`);
        check((await signIn(accounts.admin.email)).ok, 'admin sign-in stays enabled');
        const stamp = await db.get('config', 'lifecycle');
        equal(stamp && stamp.access, 'readonly', 'config/lifecycle access');
        const cutAt = new Date(stamp.cutAt).getTime();
        const drainUntil = new Date(stamp.drainUntil).getTime();
        check(Number.isFinite(cutAt) && drainUntil - cutAt === 24 * 60 * 60 * 1000, `drain window ${stamp.cutAt} .. ${stamp.drainUntil}`);
        evidence.lifecycleAfterSuspension = stamp;
        note(`suspended at revision ${suspended.revision}; retention ${retentionDays.toFixed(2)} days; sign-in still works, data reads refused by billing_lapse; access readonly, drain until ${stamp.drainUntil}`);
      });

      await t.step("the phone's order submit with the pre-suspension token is refused by Firestore rules", async () => {
        equal(await asUser(oldSalesToken, 'GET', `products/${PRODUCTS[0].id}`), 403, 'old salesperson token product read');
        await mobile.tapSubmit(phone.page);
        await B.see(phone.page, /This order was saved on this device and was not sent|Could not submit the order/, { timeout: 40000 });
        await new Promise((resolve) => setTimeout(resolve, 3000));
        equal((await ordersFor()).length, 0, 'orders stored after the refused submit');
        await t.shot(phone, 'submit-refused');
        note('old salesperson token: product read 403; the phone submit was refused (its server price check read was denied), the draft was kept and no order was stored');
      });

      await t.step('admin opens the dashboard in restricted mode, exports and grants support', async () => {
        adminS = await t.session('admin', { acceptDownloads: true });
        await B.loginAdmin(adminS.page, `${adminS.url}/w/${record.workspace}`, accounts.admin.email);
        await B.see(adminS.page, RESTRICTED_BANNER, { timeout: 60000 });
        await B.see(adminS.page, 'Enter your password to see your plan and usage.');
        const lines = (await admin.semanticsLines(adminS.page)).join('\n');
        for (const hidden of ['All Orders', 'Product Management', 'Route Planner', 'User Management']) {
          check(!lines.includes(hidden), `restricted dashboard shows ${hidden}`);
        }
        await t.shot(adminS, 'restricted-account');
        await B.fillField(adminS.page, adminS.page.locator('input[type="password"]').first(), E.PASSWORD);
        await adminS.page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(adminS.page, /Plan: Starter/, { timeout: 30000 });
        const exportButton = adminS.page.getByRole('button', { name: 'Download tenant export' });
        await B.scrollIntoView(adminS.page, exportButton, { minHeight: 36 });
        const [download] = await Promise.all([adminS.page.waitForEvent('download', { timeout: 60000 }), exportButton.click()]);
        const zipFile = path.join(out, 'restricted-export.zip');
        await download.saveAs(zipFile);
        await B.see(adminS.page, 'The tenant export download started.');
        const audit = await platformDb.list('export_audit');
        equal(audit.length, 1, 'export audit rows');
        equal(audit[0].actorUid, seed.uids.admin, 'export actor');
        const zip = fs.readFileSync(zipFile);
        equal(crypto.createHash('sha256').update(zip).digest('hex'), audit[0].sha256, 'downloaded export digest');

        const email = adminS.page.getByRole('textbox', { name: 'Support staff email', exact: true });
        await B.fillField(adminS.page, email, SUPPORT_EMAIL);
        const reason = adminS.page.getByRole('textbox', { name: 'Reason', exact: true });
        await B.fillField(adminS.page, reason, 'Check retained data after suspension');
        const grant = adminS.page.getByRole('button', { name: 'Grant 45-minute diagnostics access', exact: true });
        await grant.click();
        await B.see(adminS.page, 'Diagnostics access is active for 45 minutes or until revoked.');
        equal((await platformDb.list('support_grants')).length, 1, 'support grants');
        await t.shot(adminS, 'restricted-export-and-support');
        note(`restricted dashboard: banner shown, only Account; export ${audit[0].sha256.slice(0, 12)} downloaded (${zip.length} bytes, digest matches export_audit); support grant created`);
      });

      await t.step('the admin token reads a product but cannot save one', async () => {
        const adminToken = await signIn(accounts.admin.email);
        check(adminToken.ok, 'admin token');
        equal(await asUser(adminToken.idToken, 'GET', `products/${PRODUCTS[0].id}`), 200, 'admin product read');
        equal(await asUser(adminToken.idToken, 'PATCH', `products/${PRODUCTS[0].id}`, { unitPrice: 99 }), 403, 'admin product save');
        equal(await asUser(adminToken.idToken, 'PATCH', `user_access/${seed.uids.salesman}`, { disabledReasons: [] }), 403, 'admin clearing a lapse reason');
        const centralWrite = await fetch(`${platform.PLATFORM_API_URL}/v1/w/${record.workspace}/products/availability`, {
          method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${adminToken.idToken}`,
            'Idempotency-Key': 'suspension-availability-01' },
          body: JSON.stringify({ changes: [{ productId: PRODUCTS[0].id, visible: false }] }),
        });
        equal(centralWrite.status, 403, 'central product availability change');
        equal(await reasons(seed.uids.salesman), ['billing_lapse'], 'salesperson reasons unchanged');
        note('admin token: product read 200, product save 403, lapse reason clear 403, central availability change 403');
      });

      await t.step('operator reactivates and the salesperson works again', async () => {
        await B.see(phone.page, /Company paused/, { timeout: 60000 });
        await t.shot(phone, 'company-paused');
        await lifecycle('active', 2, 'suspension-reactivate1', { approval: 'reactivate' });
        equal(await reasons(seed.uids.salesman), [], 'salesperson reasons after reactivation');
        equal(await reasons(seed.uids.admin), [], 'admin reasons after reactivation');
        equal(await directoryStatus(), 'active', 'company lifecycle after reactivation');
        const reopened = await db.get('config', 'lifecycle');
        check(reopened && reopened.access === 'open' && reopened.reactivatedAt && reopened.cutAt, `config/lifecycle after reactivation: ${JSON.stringify(reopened)}`);
        evidence.lifecycleAfterReactivation = reopened;
        check((await signIn(accounts.salesman.email)).ok, 'salesperson sign-in after reactivation');

        const checkAgain = phone.page.getByRole('button', { name: 'Check again', exact: true });
        const keptDraft = phone.page.getByText(/Signed, not sent yet - open to submit/).first();
        const reopenDeadline = Date.now() + 90000;
        while ((await keptDraft.count()) === 0) {
          if (Date.now() > reopenDeadline) throw new Error('the phone did not return Home with the kept order after reactivation');
          if ((await checkAgain.count()) > 0) await checkAgain.click();
          await new Promise((resolve) => setTimeout(resolve, 1000));
        }
        await t.shot(phone, 'home-after-reactivation');
        await mobile.openPlannedVisit(phone.page, RETAILER.name);
        const retry = phone.page.getByRole('button', { name: /^(Check Submission|Submit Order)$/ });
        await retry.first().click();
        const orderId = await mobile.readConfirmedOrderId(phone.page, { timeout: 60000 });
        const stored = await db.waitForDoc('orders', orderId, (o) => o.status === 'submitted', { timeout: 30000 });
        equal(stored.salesmanUid, seed.uids.salesman, 'order owner');
        equal((await ordersFor()).length, 1, 'orders after reactivation');
        await t.shot(phone, 'submitted-after-reactivation');

        const fresh = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-fresh' });
        await B.loginMobile(fresh.page, fresh.url, accounts.salesman.email);
        await mobile.waitForHome(fresh.page);
        await t.shot(fresh, 'fresh-sign-in-after-reactivation');

        await adminS.page.goto(`${adminS.url}/w/${record.workspace}`);
        await B.enableSemantics(adminS.page);
        await admin.waitForShell(adminS.page);
        await t.shot(adminS, 'full-dashboard-after-reactivation');
        note(`reactivated: reasons cleared, phone retry stored ${orderId}, fresh phone sign-in reached Home, dashboard shell restored`);
      });
    } finally {
      if (priorEmulatorProjects === undefined) delete process.env.PLATFORM_EMULATOR_PROJECTS;
      else process.env.PLATFORM_EMULATOR_PROJECTS = priorEmulatorProjects;
      fs.writeFileSync(path.join(out, 'suspension-evidence.json'), JSON.stringify(evidence, null, 2));
      for (const server of servers.reverse()) await server.stop();
    }
  },
};
