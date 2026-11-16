'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { seedLegacyCompany, PRODUCTS } = require('../lib/legacy_company_fixture.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'hardware_adoption');
const HW_PROJECT = E.PROJECT;
const HARNESS_TENANT = 't_cos40005';
const WORKSPACE = 'hardware';
const COMPANY_NAME = 'Hardware Client Sdn Bhd';
const EMAILS = { owner: 'e2e.owner@example.test', operator: 'e2e.operator@example.test', engineer: 'e2e.engineer@example.test', support: 'e2e.support@example.test' };
const NEW_PRICE = 15.75;
const NEW_PHONE = '0198765432';
const NEW_SALESMAN = { name: 'Hardware New Sales', email: 'hw.new.sales@example.test', code: 'S0003' };
const SHAPES = ['uidProfileOnly', 'userGroupRole', 'inactive'];
const PEOPLE_KEYS = ['admin', 'sup', 's1', 's2', ...SHAPES];

const iso = (d) => `${d.toISOString().slice(0, 19)}Z`;
const klMidnightUtc = () => {
  const kl = new Date(Date.now() + 8 * 3600000);
  return iso(new Date(Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate()) - 8 * 3600000));
};

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function expectTrue(value, what) {
  if (!value) throw new Error(`${what}: expected a true value, got ${JSON.stringify(value)}`);
}

async function authUserCount() {
  const { authBase } = E.requireEmulators();
  const response = await fetch(`${authBase}/projects/${E.PROJECT}/accounts:batchGet?maxResults=1000`, {
    headers: { Authorization: 'Bearer owner', Connection: 'close' },
  });
  if (!response.ok) throw new Error(`auth user list -> ${response.status} ${await response.text()}`);
  return ((await response.json()).users || []).length;
}

async function passwordSignIn(email, password) {
  const { authBase } = E.requireEmulators();
  const response = await fetch(`${authBase}/accounts:signInWithPassword?key=fake-api-key`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Connection: 'close' },
    body: JSON.stringify({ email, password, returnSecureToken: true }),
  });
  const body = await response.json();
  if (!response.ok) throw new Error(`sign-in ${email} -> ${response.status} ${JSON.stringify(body)}`);
  return body.localId;
}

const savedAuthUsers = (page) => page.evaluate(() => new Promise((resolve) => {
  const prefix = 'firebase:authUser:';
  const found = [];
  for (const store of [sessionStorage, localStorage]) {
    for (const key of Object.keys(store)) {
      if (key.startsWith(prefix)) found.push(JSON.parse(store.getItem(key)));
    }
  }
  const open = indexedDB.open('firebaseLocalStorageDb');
  open.onerror = () => resolve(found);
  open.onsuccess = () => {
    const db = open.result;
    if (!db.objectStoreNames.contains('firebaseLocalStorage')) { db.close(); resolve(found); return; }
    const read = db.transaction('firebaseLocalStorage').objectStore('firebaseLocalStorage').getAll();
    read.onsuccess = () => {
      db.close();
      for (const row of read.result) if (String(row.fbase_key || '').startsWith(prefix)) found.push(row.value);
      resolve(found);
    };
    read.onerror = () => { db.close(); resolve(found); };
  };
}));

async function signedInUid(page) {
  const deadline = Date.now() + 15000;
  for (;;) {
    const users = await savedAuthUsers(page);
    const uids = [...new Set(users.map((u) => u && u.uid).filter(Boolean))];
    if (uids.length === 1) return uids[0];
    if (uids.length > 1) throw new Error(`the page holds several signed-in users: ${uids.join(', ')}`);
    if (Date.now() > deadline) throw new Error('the page holds no signed-in user');
    await page.waitForTimeout(300);
  }
}

const pageLines = async (page) => (await admin.semanticsLines(page));

module.exports = {
  name: 'hardware_adoption',
  platformApi: true,
  async run(t) {
    fs.mkdirSync(OUT, { recursive: true });
    const evidence = { steps: {} };
    const record = (key, value) => { evidence.steps[key] = value; fs.writeFileSync(path.join(OUT, 'evidence.json'), JSON.stringify(evidence, null, 2)); };
    const key = platform.ensureKey();
    const hdb = E.client(HW_PROJECT);
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    let service;
    let tenant;
    let draftId;
    let seeded;
    let authCountAtStart;

    const api = async (who, method, route, body, idem) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, {
        method,
        headers: { 'Content-Type': 'application/json', Connection: 'close', ...service.headers(who), Origin: service.url, 'Sec-Fetch-Site': 'same-origin', ...(idem ? { 'Idempotency-Key': idem } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${route} -> ${response.status} ${text}`);
      return text ? JSON.parse(text) : {};
    };

    const stateOf = (view, name) => view.steps.find((step) => step.key === name).state;

    const storeOf = async () => ({ users: await hdb.list('users'), access: await hdb.list('user_access') });

    await t.step('1. seed the legacy company project and record every uid', async () => {
      for (const claim of await platformDb.list('company_claims')) {
        if (claim.tenantId === HARNESS_TENANT) await platformDb.del('company_claims', claim.id);
      }
      await platformDb.del('companies', HARNESS_TENANT);
      seeded = await seedLegacyCompany(hdb, hdb, { shapes: SHAPES });
      authCountAtStart = await authUserCount();
      record('1 seed', { uids: seeded.uids, authUsersAtStart: authCountAtStart, products: PRODUCTS.map((p) => p.id) });
      for (const product of await hdb.list('products')) {
        expectTrue(!('barcode' in product) && !('itemBarcode' in product), `${product.id} has no barcode field`);
        expectEqual([product.unitPrice, product.priceGuide], [product.price, product.price], `${product.id} price triple`);
      }
      expectEqual((await hdb.list('products')).length, 4, 'product count');
    });

    await t.step('2. Control Centre: add company hardware as byo on that project with no services', async () => {
      directory.planAdmin([key], [{ op: 'catalogue' }]);
      process.env.PLATFORM_EMULATOR_PROJECTS = HW_PROJECT;
      process.env.PLATFORM_INVITE_SECRET = require('node:crypto').randomBytes(32).toString('base64url');
      service = await staff.startStaffApi(key, { roleEmails: EMAILS, browserSignIn: false, scheduler: false, e2eReaders: true });
      const draft = await api('operator', 'POST', '/onboarding-drafts', {
        legalName: COMPANY_NAME, workspace: WORKSPACE, planId: 'STANDARD', billingInterval: 'monthly',
        billingEmail: 'hw.billing@example.test', adminName: seeded.people.admin.name, adminEmail: seeded.people.admin.email, adminEmployeeCode: seeded.people.admin.code,
      }, 'hwa-draft-0001');
      draftId = draft.draftId;
      const done = await api('engineer', 'POST', `/onboarding-drafts/${draftId}/connect`, { projectId: HW_PROJECT });
      expectTrue(!done.refusal, `connect refusal: ${done.refusal}`);
      const connected = await api('operator', 'GET', `/onboarding-drafts/${draftId}`);
      tenant = connected.tenantId;
      expectTrue(tenant, 'tenant id');
      expectEqual([stateOf(connected, 'project'), connected.kind], ['green', 'existing'], 'project step and kind after Connect');
      const company = await platformDb.get('companies', tenant);
      expectEqual([company.workspace, company.status], [WORKSPACE, 'lead'], 'company record');
      record('2 company', { tenant, draftId, connected });
    });

    await t.step('3. Prepare: the dry run writes nothing and has no blockers; apply keeps every uid', async () => {
      const before = await storeOf();
      const dry = await api('owner', 'POST', `/companies/${tenant}/prepare-data`, {});
      expectEqual(dry.blockers, [], 'dry run blockers');
      expectTrue(dry.ready, 'dry run ready');
      expectEqual(dry.prepared, false, 'dry run prepared flag');
      expectEqual(await storeOf(), before, 'store after the dry run');
      const applied = await api('owner', 'POST', `/companies/${tenant}/prepare-data`, { apply: true });
      expectEqual(applied.blockers, [], 'apply blockers');
      expectTrue(applied.prepared, 'apply prepared flag');
      const after = await storeOf();
      const uidsWithAccessRow = PEOPLE_KEYS.filter((key) => key !== 'uidProfileOnly').map((key) => seeded.uids[key]);
      expectEqual(after.access.map((row) => row.id).sort(), uidsWithAccessRow.sort(), 'access documents keep their uid ids');
      for (const row of after.access) expectEqual(row.uid, row.id, `access row ${row.id} uid field`);
      for (const key of PEOPLE_KEYS) {
        const person = seeded.people[key];
        const profile = after.users.find((row) => row.id === person.code || row.id === person.uid);
        expectTrue(profile, `${person.code} profile exists after Prepare`);
        expectEqual(profile.uid, person.uid, `${person.code} profile uid after Prepare`);
        if (key === 'uidProfileOnly') {
          expectEqual(profile.id, person.uid, 'the uid-only profile keeps its uid document id');
          continue;
        }
        const access = after.access.find((row) => row.id === person.uid);
        expectTrue(access, `${person.code} access row exists under the old uid`);
        expectEqual(access.uid, person.uid, `${person.code} access row uid field after Prepare`);
      }
      expectEqual((await hdb.get('user_access', seeded.uids.inactive)).isActive, false, 'inactive person stays inactive');
      const usage = await hdb.get('config', 'usage');
      expectTrue(usage, 'config/usage written');
      record('3 prepare', { dryRun: dry, applied, usage });
    });

    await t.step('4. package, first invoice, payment checked, active, open access; the old accounts are untouched (P3)', async () => {
      expectEqual(stateOf(await api('operator', 'GET', `/onboarding-drafts/${draftId}`), 'package'), 'red', 'package step before the package is applied');
      await api('operator', 'POST', `/companies/${tenant}/package`, { planId: 'STANDARD', billingInterval: 'monthly', expectedRevision: 0, reason: 'Hardware first package' }, 'hwa-package-0001');
      const quote = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: tenant, reason: 'Hardware agreed price', params: { amountMinor: 50000, billingInterval: 'monthly' } }, 'hwa-quote-0001');
      await api('owner', 'POST', `/approvals/${quote.approvalId}/approve`);
      const invoiceDraft = await api('operator', 'POST', `/companies/${tenant}/invoices`, {}, 'hwa-invoice-0001');
      expectEqual((await api('operator', 'GET', `/onboarding-drafts/${draftId}`)).next.button.id, 'issue_invoice', 'next button is Issue invoice while the invoice is a draft');
      const invoice = await api('operator', 'POST', `/invoices/${invoiceDraft.invoiceId}/issue`);
      expectEqual((await api('operator', 'GET', `/onboarding-drafts/${draftId}`)).next.button.id, 'record_payment', 'next button is Record payment once the invoice is issued');
      const paid = await api('operator', 'POST', `/companies/${tenant}/payments`, {
        amountMinor: invoice.amountMinor, currency: 'MYR', externalReference: 'HW/ADOPTION-001', invoiceId: invoice.invoiceId, receivedAt: klMidnightUtc(), reason: 'Bank statement checked',
      }, 'hwa-payment-0001');
      await api('owner', 'POST', `/companies/${tenant}/payments/${paid.entryId}/check`);
      const granted = await api('operator', 'POST', `/onboarding-drafts/${draftId}/first-admin`, {});
      expectEqual([granted.state, granted.uid], ['active', seeded.uids.admin], 'the old admin account keeps its uid and becomes the administrator');
      const ready = await api('operator', 'GET', `/onboarding-drafts/${draftId}`);
      expectEqual(ready.next.button.id, 'make_active', 'all seven earlier steps are green');
      await api('operator', 'PUT', `/companies/${tenant}/lifecycle`, { state: 'active', expectedRevision: (await api('operator', 'GET', `/companies/${tenant}/lifecycle`)).lifecycle.revision, paymentEntryId: paid.entryId, reason: 'Coverage verified for activation', ticket: 'HW-ADOPTION' }, 'hwa-lifecycle-0001');
      const finalView = await api('operator', 'GET', `/onboarding-drafts/${draftId}`);
      expectEqual([finalView.doneCount, finalView.total, finalView.phase], [8, 8, 'working'], 'all eight steps green after Open');
      const lifecycle = await hdb.get('config', 'lifecycle');
      expectEqual([lifecycle.state, lifecycle.access], ['active', 'open'], 'projected lifecycle');
      const served = await (await fetch(`${platform.PLATFORM_API_URL}/v1/companies/${WORKSPACE}`)).json();
      const payload = JSON.parse(served.payload);
      expectEqual([payload.workspace, payload.locationKind, payload.location.projectId, payload.services], [WORKSPACE, 'byo', HW_PROJECT, {}], 'served company record');
      expectEqual(await authUserCount(), authCountAtStart, 'Auth user count after open access');
      const listed = await fetch(`${E.requireEmulators().authBase}/projects/${E.PROJECT}/accounts:batchGet?maxResults=1000`, {
        headers: { Authorization: 'Bearer owner', Connection: 'close' },
      });
      const found = ((await listed.json()).users || []).filter((u) => u.email === seeded.people.admin.email);
      expectEqual(found.map((u) => u.localId), [seeded.uids.admin], 'accounts holding the admin email');
      for (const person of PEOPLE_KEYS.map((k) => seeded.people[k])) {
        expectEqual(await passwordSignIn(person.email, person.password), person.uid, `${person.code} old password signs in with the old uid`);
      }
      expectEqual(await authUserCount(), authCountAtStart, 'Auth user count after the sign-in checks');
      record('4 open access', { steps: finalView.steps, lifecycle, authUsersAtStart: authCountAtStart, adminUid: seeded.uids.admin });
    });

    let adminS;
    const adminRequests = [];
    await t.step('5a. the admin signs in at /w/hardware with the old email and password and keeps the same uid', async () => {
      adminS = await t.session('admin', { name: 'hw-admin', viewport: { width: 2000, height: 1200 }, ...admin.grantClipboard });
      adminS.page.on('request', (request) => adminRequests.push(request.url()));
      const person = seeded.people.admin;
      await B.loginAdmin(adminS.page, `${t.urls.admin}/w/${WORKSPACE}`, person.email, person.password);
      await admin.waitForShell(adminS.page);
      expectEqual(await signedInUid(adminS.page), person.uid, 'dashboard signed-in uid');
      await t.shot(adminS, 'signed-in-home');
    });

    const phones = {};
    const phoneSignIn = async (personKey) => {
      const person = seeded.people[personKey];
      const phone = await t.session('mobile', { name: `hw-phone-${person.code}`, viewport: mobile.MOBILE_VIEWPORT, persistence: true });
      await B.openApp(phone.page, phone.url);
      await B.see(phone.page, 'Enter your company code to start.');
      await phone.page.getByRole('button', { name: 'Change company', exact: true }).click();
      await B.fillField(phone.page, phone.page.getByRole('textbox').first(), WORKSPACE);
      await phone.page.getByRole('button', { name: 'Continue', exact: true }).click();
      await B.see(phone.page, `Company: ${COMPANY_NAME}`);
      await B.loginMobile(phone.page, phone.url, person.email, person.password);
      await mobile.waitForHome(phone.page);
      expectEqual(await signedInUid(phone.page), person.uid, `${person.code} phone signed-in uid`);
      await t.shot(phone, `signed-in-home-${person.code}`);
      phones[personKey] = phone;
    };
    await t.step('5b. S0001 (access row v2) signs in on the phone with company code hardware, old password, same uid', async () => phoneSignIn('s1'));
    await t.step('5c. S0002 (legacy access row) signs in on the phone with company code hardware, old password, same uid', async () => phoneSignIn('s2'));

    let productLines;
    await t.step('6a. products page: searching each product ID finds that product', async () => {
      await admin.goToPage(adminS.page, 'Products');
      for (const product of PRODUCTS) await B.see(adminS.page, new RegExp(product.name));
      await adminS.page.waitForTimeout(800);
      productLines = await pageLines(adminS.page);
      fs.writeFileSync(path.join(OUT, 'products-page-semantics.txt'), productLines.join('\n'));
      await t.shot(adminS, 'products');
      const search = adminS.page.getByRole('textbox', { name: /Search products/ }).first();
      for (const product of PRODUCTS) {
        await B.fillField(adminS.page, search, product.id);
        await B.see(adminS.page, new RegExp(`^Product ${product.name}`));
        await adminS.page.waitForTimeout(500);
        const visible = [];
        for (const other of PRODUCTS) {
          if (await adminS.page.getByRole('button', { name: new RegExp(`^Product ${other.name}`) }).count()) visible.push(other.id);
        }
        expectEqual(visible, [product.id], `search by product ID ${product.id} finds only that product`);
      }
      await t.shot(adminS, 'products-search-by-id');
      await B.fillField(adminS.page, search, '');
    });

    await t.step('6b. edit the price of HW-0001: unitPrice, price and priceGuide all take the new value', async () => {
      const name = PRODUCTS[0].name;
      const row = adminS.page.getByRole('button', { name: new RegExp(`^Product ${name}`) }).first();
      await row.waitFor({ timeout: 20000 });
      await row.hover();
      await adminS.page.getByRole('button', { name: new RegExp(`^Edit ${name}`) }).click();
      await B.fillField(adminS.page, adminS.page.getByRole('textbox', { name: /^Unit Price\b/ }).first(), String(NEW_PRICE));
      await t.shot(adminS, 'product-edit');
      await adminS.page.getByRole('button', { name: 'Save', exact: true }).click();
      await B.see(adminS.page, 'Product item saved.');
      const stored = await hdb.waitForDoc('products', PRODUCTS[0].id, (p) => Math.abs((p.unitPrice || 0) - NEW_PRICE) < 0.001, { label: 'saved price' });
      expectEqual([stored.unitPrice, stored.price, stored.priceGuide], [NEW_PRICE, NEW_PRICE, NEW_PRICE], 'stored price triple');
      expectEqual([stored.sku, stored.itemCode, stored.isVisible], [PRODUCTS[0].id, PRODUCTS[0].id, true], 'other product fields kept');
      expectTrue(!('barcode' in stored) || !stored.barcode, 'product still has no barcode');
      await t.shot(adminS, 'product-saved');
      record('6b price', { unitPrice: stored.unitPrice, price: stored.price, priceGuide: stored.priceGuide });
    });

    let pickerLines;
    let orderId;
    await t.step('7a. S0001 opens the product picker, adds HW-0001 and sends an order; the admin sees it', async () => {
      const pg = phones.s1.page;
      await mobile.planVisitToday(pg, seeded.retailer.name);
      await mobile.openPlannedVisit(pg, seeded.retailer.name);
      await pg.getByRole('checkbox', { name: new RegExp(PRODUCTS[0].name) }).waitFor({ timeout: 30000 });
      await pg.waitForTimeout(800);
      pickerLines = await pageLines(pg);
      fs.writeFileSync(path.join(OUT, 'phone-picker-semantics.txt'), pickerLines.join('\n'));
      await t.shot(phones.s1, 'product-picker');
      await pg.getByRole('checkbox', { name: new RegExp(PRODUCTS[0].name) }).click();
      await pg.getByRole('button', { name: /^Add to Cart \(1\)/ }).click();
      await pg.getByRole('button', { name: 'Start counting' }).click();
      await B.see(pg, `Product ID: ${PRODUCTS[0].id}`, { timeout: 30000 });
      await B.see(pg, new RegExp(PRODUCTS[0].name));
      const cartLines = await pageLines(pg);
      fs.writeFileSync(path.join(OUT, 'phone-cart-semantics.txt'), cartLines.join('\n'));
      expectEqual(cartLines.filter((line) => /Barcode:/.test(line)), [], 'cart Barcode line');
      await t.shot(phones.s1, 'cart');
      await mobile.continueToSignature(pg);
      orderId = await mobile.signAndSubmit(pg, 'Hardware', 1);
      await t.shot(phones.s1, 'order-sent');
      const order = await hdb.waitForDoc('orders', orderId, (o) => o.status === 'submitted');
      expectEqual([order.salesmanCode, order.branchId, order.totalPrice], ['S0001', 'HW1', NEW_PRICE], 'stored order');
      await admin.goToPage(adminS.page, 'All Orders');
      await admin.waitForOrderRow(adminS.page, orderId);
      await t.shot(adminS, 'order-seen');
      record('7a order', { orderId, totalPrice: order.totalPrice });
    });

    await t.step('8a. P2: the admin creates a new salesperson', async () => {
      const invite = await admin.createUser(adminS.page, {
        name: NEW_SALESMAN.name, email: NEW_SALESMAN.email, code: NEW_SALESMAN.code,
        branchName: seeded.branch.name, supervisorOption: new RegExp(`^${seeded.people.sup.name}`), keepDialog: true,
      });
      expectTrue(/^[0-9A-Z]{4}-[0-9A-Z]{4}-[0-9A-Z]{4}$/.test(invite.code), 'invitation code shape');
      await t.shot(adminS, 'new-salesperson-invitation');
      await admin.closeInvitationDialog(adminS.page);
      const profile = await hdb.waitForDoc('users', NEW_SALESMAN.code, (u) => !u.provisioningState);
      expectEqual([profile.email, profile.role, profile.branchId, profile.supervisorId], [NEW_SALESMAN.email, 'salesman', 'HW1', 'SV0001'], 'new profile');
      const access = await hdb.waitForDoc('user_access', profile.uid, (a) => a.accessVersion === 2);
      expectEqual([access.role, access.employeeCode, access.supervisorUid, access.invitationState], ['salesman', NEW_SALESMAN.code, seeded.uids.sup, 'pending'], 'new access row');
      record('8a new salesperson', { uid: profile.uid });
    });

    await t.step('8b. P2: the admin suspends and restores S0002 (legacy row)', async () => {
      const person = seeded.people.s2;
      await admin.setUserStatus(adminS.page, { code: person.code, name: person.name }, 'Suspend');
      await t.shot(adminS, 's0002-suspended');
      const suspended = await hdb.waitForDoc('user_access', person.uid, (a) => a.status === 'suspended');
      expectEqual(suspended.isActive, false, 'suspended access isActive');
      expectEqual((await hdb.get('users', person.code)).status, 'suspended', 'suspended profile status');
      await admin.setUserStatus(adminS.page, { code: person.code, name: person.name }, 'Activate');
      await t.shot(adminS, 's0002-restored');
      const restored = await hdb.waitForDoc('user_access', person.uid, (a) => a.status === 'active');
      expectEqual(restored.isActive, true, 'restored access isActive');
      expectEqual((await hdb.get('users', person.code)).status, 'active', 'restored profile status');
      expectEqual(await passwordSignIn(person.email, person.password), person.uid, 'S0002 old password after restore');
    });

    await t.step('8c. P2: the admin edits one field of the S0002 staff row', async () => {
      const person = seeded.people.s2;
      await admin.goToPage(adminS.page, 'Branches');
      await admin.goToPage(adminS.page, 'Role Assignment');
      await admin.collapseInvitations(adminS.page);
      await admin.searchDirectory(adminS.page, person.code);
      await B.see(adminS.page, person.name);
      await adminS.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await admin.scrollFormTop(adminS.page);
      await B.fillField(adminS.page, adminS.page.getByRole('textbox').nth(3), NEW_PHONE);
      const update = adminS.page.getByRole('button', { name: 'Update Profile', exact: true });
      await B.scrollIntoView(adminS.page, update, { minHeight: 20, bottomInset: 0, pointerY: 0.8 });
      await update.click();
      await B.see(adminS.page, `Saved changes to ${person.name}.`, { timeout: 30000 });
      await t.shot(adminS, 's0002-edited');
      const profile = await hdb.waitForDoc('users', person.code, (u) => u.contactNumber === NEW_PHONE, { label: 'edited phone number' });
      expectEqual([profile.uid, profile.employeeCode, profile.role], [person.uid, person.code, 'salesman'], 'edited profile keeps its identity');
      const access = await hdb.get('user_access', person.uid);
      expectEqual([access.uid, access.employeeCode, access.status], [person.uid, person.code, 'active'], 'edited access row keeps its identity');
    });

    await t.step('8d. the admin hides HW-0002 and shows it again; the phone picker follows each change', async () => {
      const target = PRODUCTS[1];
      const phone = phones.s1;
      const pickerShows = async (name) => {
        await mobile.reopenHome(phone.page, phone.url);
        await phone.page.getByRole('button', { name: new RegExp(`^Personal plan[^]*${seeded.retailer.name}`) }).first().click();
        await phone.page.getByRole('checkbox', { name: new RegExp(PRODUCTS[0].name) }).waitFor({ timeout: 30000 });
        await phone.page.waitForTimeout(1500);
        const category = phone.page.locator(`flt-semantics[aria-label="${target.category}"]`).first();
        if (await category.count()) {
          const box = await category.boundingBox();
          await phone.page.mouse.click(box.x + box.width / 2, box.y + box.height / 2);
          await phone.page.waitForTimeout(800);
        }
        return (await phone.page.getByRole('checkbox', { name: new RegExp(name) }).count()) > 0;
      };
      expectEqual(await pickerShows(target.name), true, `picker shows ${target.id} before hiding`);
      await admin.setProductVisibility(adminS.page, target.name, 'Hide');
      const hidden = await hdb.waitForDoc('products', target.id, (p) => p.isVisible === false);
      expectEqual(hidden.status, 'hidden', `${target.id} stored status after hiding`);
      await B.see(adminS.page, new RegExp(`Product ${target.name}, [^]*Hidden`));
      await t.shot(adminS, 'hw0002-hidden');
      expectEqual(await pickerShows(target.name), false, `picker hides ${target.id} after hiding`);
      await t.shot(phone, 'picker-hw0002-hidden');
      await admin.setProductVisibility(adminS.page, target.name, 'Show');
      const shown = await hdb.waitForDoc('products', target.id, (p) => p.isVisible === true);
      expectEqual(shown.status, 'active', `${target.id} stored status after showing`);
      await t.shot(adminS, 'hw0002-shown');
      expectEqual(await pickerShows(target.name), true, `picker shows ${target.id} again after showing`);
      await t.shot(phone, 'picker-hw0002-shown');
    });

    const ERROR_TEXT = /error|failed|something went wrong|could not|unavailable|exception|not found/i;
    const noErrorText = async (session, label) => {
      await session.page.waitForTimeout(2500);
      const lines = await pageLines(session.page);
      fs.writeFileSync(path.join(OUT, `semantics-${label.replace(/\W+/g, '-').toLowerCase()}.txt`), lines.join('\n'));
      expectEqual(lines.filter((line) => ERROR_TEXT.test(line)), [], `error text on ${label}`);
      return lines;
    };

    await t.step('9. P7: with no services the dashboard Scout panel, Reports page and phone Scout show no error and nothing calls a cos40005 service', async () => {
      await admin.goToPage(adminS.page, 'Dashboard');
      const labels = await admin.sidebarLabels(adminS.page, { railWidth: 280 });
      const intelligencePages = labels.filter((label) => /forecast|insight|intelligence|\bAI\b/i.test(label));
      record('9 sidebar', { labels, intelligencePages });
      expectTrue(labels.some((label) => /^Reports(,|$)/.test(label)), `the sidebar lists Reports: ${JSON.stringify(labels)}`);
      await adminS.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await adminS.page.getByRole('group', { name: /^Scout panel/ }).waitFor({ timeout: 15000 });
      const scoutLines = await noErrorText(adminS, 'dashboard Scout panel');
      record('9 dashboard scout', { lines: scoutLines });
      expectTrue(scoutLines.some((line) => line.includes('Basic commands only')), 'dashboard Scout shows its basic-commands state');
      await t.shot(adminS, 'dashboard-scout-panel');
      await adminS.page.keyboard.press('Escape');
      for (const label of ['Reports', ...intelligencePages]) {
        await admin.goToPage(adminS.page, label);
        await noErrorText(adminS, `dashboard ${label}`);
        await t.shot(adminS, `panel-${label.replace(/\W+/g, '-').toLowerCase()}`);
      }
      const phone = phones.s1;
      await mobile.reopenHome(phone.page, phone.url);
      await phone.page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click({ timeout: 15000 });
      await phone.page.getByRole('textbox', { name: /Ask or say a command/ }).waitFor({ timeout: 15000 });
      const phoneScout = await noErrorText(phone, 'phone Scout');
      record('9 phone scout', { lines: phoneScout });
      expectTrue(phoneScout.some((line) => line.includes('Ask about your route, orders and visit briefs.')), 'phone Scout shows its welcome text');
      await t.shot(phone, 'phone-scout');
      const serviceHosts = Object.values(platform.SERVICES).map((url) => new URL(url).host);
      const calls = adminRequests.filter((url) => serviceHosts.includes(new URL(url).host) || /cos40005/.test(new URL(url).hostname));
      expectEqual(calls, [], 'admin requests to cos40005 service hosts');
      const blocked = [...adminS.blocked, ...Object.values(phones).flatMap((phone) => phone.blocked)];
      expectEqual(blocked.filter((url) => /cos40005/.test(url)), [], 'blocked requests naming cos40005');
    });

    await t.step('10a. the phone picker search finds a product by its product ID', async () => {
      const phone = phones.s1;
      const target = PRODUCTS[2];
      await mobile.reopenHome(phone.page, phone.url);
      await phone.page.getByRole('button', { name: new RegExp(`^Personal plan[^]*${seeded.retailer.name}`) }).first().click();
      await phone.page.getByRole('checkbox', { name: new RegExp(PRODUCTS[0].name) }).waitFor({ timeout: 30000 });
      const search = phone.page.getByRole('textbox', { name: /Search SKU or product/ }).first();
      await B.fillField(phone.page, search, target.id);
      await phone.page.getByRole('checkbox', { name: new RegExp(target.name) }).waitFor({ timeout: 15000 });
      await phone.page.waitForTimeout(800);
      const visible = [];
      for (const other of PRODUCTS) {
        if (await phone.page.getByRole('checkbox', { name: new RegExp(other.name) }).count()) visible.push(other.id);
      }
      expectEqual(visible, [target.id], `phone search by product ID ${target.id} finds only that product`);
      await t.shot(phone, 'picker-search-by-id');
    });

    const ROUTE_RETAILERS = [
      { id: 'hw-route-1', name: 'Kuching Hardware North', latitude: 1.5312, longitude: 110.3609 },
      { id: 'hw-route-2', name: 'Kuching Hardware South', latitude: 1.5535, longitude: 110.3593 },
    ];
    let routePlanId;
    let routeStopId;
    let routeSupervisor;
    const routeProgressId = () => `${routePlanId}_${seeded.uids.s2}`;

    await t.step('10b. P6: the supervisor drafts, approves and publishes a route for S0002 (legacy row)', async () => {
      for (const retailer of ROUTE_RETAILERS) {
        await hdb.put('retailers', retailer.id, {
          retailerId: retailer.id, retailerName: retailer.name, name: retailer.name, area: 'Kuching', branchId: seeded.branch.id,
          status: 'active', address: 'Kuching', latitude: retailer.latitude, longitude: retailer.longitude,
          coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
          assignedSalesmanId: 'S0002', assignedSalesmanCode: 'S0002', assignedSalesmanUid: seeded.uids.s2,
        });
      }
      const supervisor = seeded.people.sup;
      routeSupervisor = await t.session('admin', { name: 'hw-supervisor', viewport: { width: 2000, height: 1200 } });
      await B.loginAdmin(routeSupervisor.page, `${t.urls.admin}/w/${WORKSPACE}`, supervisor.email, supervisor.password);
      await admin.waitForSupervisorShell(routeSupervisor.page);
      expectEqual(await signedInUid(routeSupervisor.page), supervisor.uid, 'supervisor signed-in uid');
      const page = routeSupervisor.page;
      await admin.goToPage(page, 'Team Route Planner');
      await admin.pickDropdown(page, seeded.people.s1.name, seeded.people.s2.name);
      await B.see(page, /2 retailer\(s\) with coordinates/);
      await t.shot(routeSupervisor, 'route-planner');
      const weekLabel = async () => {
        const button = page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} – \d{1,2} [A-Z][a-z]{2}$/ });
        await button.waitFor({ timeout: 10000 });
        return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
      };
      const before = await weekLabel();
      await page.getByRole('button', { name: 'Previous week' }).click();
      for (let i = 0; i < 50 && (await weekLabel()) === before; i += 1) await page.waitForTimeout(200);
      expectTrue((await weekLabel()) !== before, 'the planner week changed');
      await page.getByRole('button', { name: 'Generate draft route' }).click();
      await page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
      await B.see(page, /Stops: [1-9]/);
      await B.see(page, ROUTE_RETAILERS[0].name);
      await t.shot(routeSupervisor, 'route-draft');
      await page.getByRole('button', { name: 'Save draft' }).click();
      const plan = await hdb.waitForQuery('route_plans', (p) => p.salesmanCode === 'S0002', { label: 'route_plans' });
      routePlanId = plan.id;
      expectEqual([plan.status, plan.salesmanUid, plan.createdByRole, plan.branchId], ['draft', seeded.uids.s2, 'supervisor', seeded.branch.id], 'saved plan');
      const stopRetailers = plan.days.flatMap((d) => d.stops || []).map((s) => s.retailerId);
      expectTrue(ROUTE_RETAILERS.every((r) => stopRetailers.includes(r.id)), `plan stops include both retailers: ${JSON.stringify(stopRetailers)}`);
      await page.getByRole('button', { name: 'Approve', exact: true }).click();
      const approved = await hdb.waitForDoc('route_plans', routePlanId, (p) => p.status === 'approved');
      expectTrue(approved.approvedAt, 'approved plan has approvedAt');
      await page.getByRole('button', { name: 'Publish', exact: true }).click();
      await B.see(page, 'Publish this route?');
      await page.getByRole('button', { name: 'Publish', exact: true }).last().click();
      const published = await hdb.waitForDoc('route_plans', routePlanId, (p) => p.status === 'published', { timeout: 30000 });
      expectTrue(published.publishedAt, 'published plan has publishedAt');
      const publication = await hdb.waitForQuery('route_plan_publication_keys', (k) => k.planId === routePlanId, { label: 'publication key' });
      expectEqual([publication.active, publication.salesmanUid], [true, seeded.uids.s2], 'publication key');
      await B.see(page, /Published and assigned|assigned to/);
      await t.shot(routeSupervisor, 'route-published');
      record('10b route plan', { planId: routePlanId, status: published.status });
    });

    await t.step('10c. P6: S0002 sees the published route on the phone, works one stop, and the stores hold the progress', async () => {
      const phone = phones.s2;
      const retailer = ROUTE_RETAILERS[0];
      await mobile.routeDayForSunday(hdb, routePlanId);
      await B.fakeGeolocation(phone.context, { latitude: retailer.latitude, longitude: retailer.longitude, accuracy: 10 });
      const person = seeded.people.s2;
      await B.loginMobile(phone.page, phone.url, person.email, person.password);
      await mobile.waitForHome(phone.page);
      expectEqual(await signedInUid(phone.page), person.uid, 'S0002 phone signed-in uid after the restore');
      await mobile.openAssignedRoute(phone.page);
      await B.see(phone.page, /\d+ stop\(s\)/);
      await B.semantic(phone.page, /^Week$/).click();
      for (const r of ROUTE_RETAILERS) await B.see(phone.page, r.name);
      await t.shot(phone, 'route-on-phone');
      await mobile.acceptAndStartRoute(phone.page);
      const started = await hdb.waitForDoc('route_plan_progress', routeProgressId(), (p) => p.status === 'in_progress', { label: 'route_plan_progress' });
      expectEqual([started.planId, started.salesmanUid], [routePlanId, seeded.uids.s2], 'route_plan_progress owner');
      await mobile.selectStop(phone.page);
      const selected = await hdb.waitForDoc('route_plan_progress', routeProgressId(), (p) => Boolean(p.selectedStopId), { label: 'selected stop' });
      routeStopId = selected.selectedStopId;
      const plan = await hdb.get('route_plans', routePlanId);
      const stopOfPlan = plan.days.flatMap((d) => d.stops || []).find((s) => s.stopId === routeStopId);
      expectTrue(stopOfPlan, `selected stop ${routeStopId} is in the plan`);
      const stopRetailer = ROUTE_RETAILERS.find((r) => r.id === stopOfPlan.retailerId);
      await B.moveDevice(phone.page, { latitude: stopRetailer.latitude, longitude: stopRetailer.longitude, accuracy: 10 });
      await mobile.markArrived(phone.page);
      const stopDocId = `${routePlanId}_${seeded.uids.s2}_${routeStopId}`;
      const stop = await hdb.waitForDoc('route_stop_progress', stopDocId, (s) => s.status === 'arrived', { label: 'route_stop_progress arrival' });
      expectEqual([stop.planId, stop.stopId, stop.salesmanUid, stop.retailerId], [routePlanId, routeStopId, seeded.uids.s2, stopOfPlan.retailerId], 'route_stop_progress identity');
      await B.see(phone.page, 'Arrival: GPS verified');
      await t.shot(phone, 'route-arrived');
      const progress = await hdb.get('route_plan_progress', routeProgressId());
      expectEqual([progress.status, progress.salesmanUid, progress.selectedStopId], ['in_progress', seeded.uids.s2, routeStopId], 'route_plan_progress after arrival');
      record('10c progress', { progressId: routeProgressId(), stopDocId, stopStatus: stop.status });
    });

    await t.step('10d. P6: the supervisor dashboard shows the progress of the route', async () => {
      const page = routeSupervisor.page;
      await admin.goToPage(page, 'Team Overview');
      await admin.goToPage(page, 'Team Route Planner');
      await admin.pickDropdown(page, seeded.people.s1.name, seeded.people.s2.name);
      await page.getByRole('button', { name: /^Saved plans/ }).click();
      await page.waitForTimeout(4000);
      await t.shot(routeSupervisor, 'route-saved-plans');
      await B.see(page, /Mobile status: In Progress/, { timeout: 30000 });
      await t.shot(routeSupervisor, 'route-progress-dashboard');
    });

    await t.step('10e. the products page shows no "Missing barcode" text and the picker shows each product ID next to its name', async () => {
      expectEqual(productLines.filter((line) => /missing barcode/i.test(line)), [], 'Missing barcode text on the products page');
      const named = pickerLines.filter((line) => line.includes(PRODUCTS[0].name));
      expectTrue(named.some((line) => line.includes(PRODUCTS[0].id)), `phone picker line with name and ID: ${JSON.stringify(named)}`);
    });

    await service.stop();
  },
};
