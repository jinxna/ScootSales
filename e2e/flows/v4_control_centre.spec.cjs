'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const BILLING = 'e2e.billing@example.test';
const INVOICE_OUT = path.join(E.OUTPUT_DIR, 'v4_control_centre');

async function mailedPdf(sink, recipient, subject) {
  const deadline = Date.now() + 30000;
  while (Date.now() < deadline) {
    const hit = (await sink.messages()).find((m) => m.Subject.startsWith(subject) && m.To.some((to) => to.Address === recipient));
    if (hit) {
      const message = await sink.message(hit.ID);
      const [attached] = message.Attachments;
      if (!attached) throw new Error(`${subject} has no attachment`);
      const bytes = fs.readFileSync(attached.file);
      const digest = require('node:crypto').createHash('sha256').update(bytes).digest('hex');
      if (bytes.subarray(0, 5).toString() !== '%PDF-' || digest !== attached.sha256 || bytes.length !== attached.size) {
        throw new Error(`attachment of ${subject} does not match its record`);
      }
      const sent = message.Stub.request.attachment || [];
      if (sent.length !== 1 || sent[0].name !== attached.name || Buffer.from(sent[0].content, 'base64').compare(bytes) !== 0) {
        throw new Error(`the Brevo payload of ${subject} does not carry the same PDF`);
      }
      fs.mkdirSync(INVOICE_OUT, { recursive: true });
      fs.copyFileSync(attached.file, path.join(INVOICE_OUT, `${subject.split(' ')[0].toLowerCase()}-${attached.name}`));
      return attached;
    }
    await new Promise((resolve) => setTimeout(resolve, 250));
  }
  throw new Error(`no "${subject}" mail reached ${recipient}`);
}

const EMAILS = { owner: 'e2e.owner@example.test', operator: 'e2e.operator@example.test', engineer: 'e2e.engineer@example.test', support: 'e2e.support@example.test' };

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

module.exports = {
  name: 'v4_control_centre', platformApi: false,
  async run(t) {
    const key = platform.ensureKey();
    const TENANT_PROJECT = 'demo-control-tenant';
    const record = {
      ...platform.harnessRecord(),
      location: {
        ...platform.harnessRecord().location,
        projectId: TENANT_PROJECT,
      },
    };
    await directory.resetDirectory();
    directory.seedDirectory([key], [{ record, key }]);
    const tenantDb = E.client(TENANT_PROJECT);
    await tenantDb.reset();
    await tenantDb.put('config', 'usage', { usageSchemaVersion: 2, products: 0, activeAdmins: 0,
      seats: { salesmen: 0, supervisors: 0, admins: 0, branchManagers: 0 } });
    directory.planAdmin([key], [{ op: 'catalogue' }]);
    const sink = await startMailSink();
    await sink.clear();
    const service = await staff.startStaffApi(key, { roleEmails: EMAILS, browserSignIn: true, scheduler: false, e2eReaders: true });
    const seenCodeMails = new Set();
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const sessions = {};
    let dropped = false;
    let approveDropped = false;
    const approveRequests = [];
    const paymentRequests = [];
    let lifecycleDropped = false;
    const lifecycleRequests = [];
    let packageDropped = false;
    const packageRequests = [];
    const packageStatuses = [];
    const api = async (who, method, route, body, idempotencyKey) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, { method,
        headers: { 'Content-Type': 'application/json', Connection: 'close', ...service.headers(who),
          Origin: service.url, 'Sec-Fetch-Site': 'same-origin',
          ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body) }).catch((error) => { throw new Error(`${method} ${route} could not reach the staff API: ${error.cause && error.cause.code}`); });
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${route} -> ${response.status} ${text}`);
      return text ? JSON.parse(text) : {};
    };
    const open = async (role) => {
      const s = await t.session('admin', { name: `control-${role}` });
      sessions[role] = s;
      s.tenantSdkRequests = [];
      s.page.on('request', (r) => { if (/\/package$/.test(r.url())) packageStatuses.push(`req ${r.method()} ${Date.now() % 100000}`); });
      s.page.on('requestfailed', (r) => { if (/\/package$/.test(r.url())) packageStatuses.push(`failed ${r.failure() && r.failure().errorText}`); });
      s.page.on('request', (request) => {
        if (/firestore\.googleapis/.test(request.url())) {
          s.tenantSdkRequests.push(request.url());
        }
      });
      await s.context.route('**/staff/v1/**', async (route) => {
        const request = route.request();
        const pathname = new URL(request.url()).pathname;
        const response = await route.fetch({ url: `${service.url}${pathname}${new URL(request.url()).search}`,
          headers: { ...request.headers(), host: new URL(t.urls.admin).host } }).catch(() => null);
        if (!response) {
          if (/\/approve$/.test(pathname)) approveRequests.push(`${pathname} not delivered`);
          if (/\/package$/.test(pathname)) packageStatuses.push('not delivered');
          return route.abort('failed').catch(() => null);
        }
        if (role === 'operator' && request.method() === 'POST' && /\/payments$/.test(pathname)) {
          paymentRequests.push({ key: request.headers()['idempotency-key'], body: request.postData() });
          if (!dropped && response.status() === 201) { dropped = true; return route.abort('failed'); }
        }
        if (role === 'operator' && request.method() === 'PUT' && /\/lifecycle$/.test(pathname)) {
          lifecycleRequests.push({ key: request.headers()['idempotency-key'], body: request.postData() });
          if (!lifecycleDropped && response.status() === 200) { lifecycleDropped = true; return route.abort('failed'); }
        }
        if (role === 'operator' && request.method() === 'POST' && /\/package$/.test(pathname)) {
          packageRequests.push({ key: request.headers()['idempotency-key'], body: request.postData() });
          packageStatuses.push(response.status());
          if (!packageDropped && [200, 201, 202].includes(response.status())) { packageDropped = true; return route.abort('failed'); }
        }
        if (role === 'owner' && request.method() === 'POST' && /\/approvals\/[^/]+\/approve$/.test(pathname)) {
          approveRequests.push(`${pathname} ${response.status()}`);
          if (!approveDropped && [200, 202].includes(response.status())) { approveDropped = true; return route.abort('failed'); }
        }
        return route.fulfill({ response });
      });
      await B.openApp(s.page, t.urls.admin);
      await staff.signInControlCentre(s.page, EMAILS[role], sink, seenCodeMails);
      return s;
    };
    const until = async (condition, label, timeout = 25000) => {
      const end = Date.now() + timeout;
      while (!condition()) {
        if (Date.now() > end) throw new Error(`timed out waiting for ${label}`);
        await new Promise((resolve) => setTimeout(resolve, 100));
      }
    };
    const button = (s, name) => s.page.getByRole('button', { name, exact: typeof name === 'string' });
    const text = (s, value) => s.page.getByText(value, { exact: true });
    const iso = (date) => `${date.toISOString().slice(0, 19)}Z`;
    const klMidnightUtc = () => {
      const kl = new Date(Date.now() + 8 * 3600000);
      return iso(new Date(Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate()) - 8 * 3600000));
    };
    const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
    const openCompany = async (s, legalName) => {
      await button(s, 'Companies').click();
      await s.page.waitForTimeout(1500);
      await button(s, new RegExp(`^${escaped(legalName)}, workspace`)).click();
      await text(s, 'Subscription').waitFor({ timeout: 25000 });
    };
    const tab = (s, label) => button(s, label).click();
    const atWidths = async (s, name) => {
      const original = s.page.viewportSize();
      for (const [width, height] of [[390, 844], [2000, 1100]]) {
        await s.page.setViewportSize({ width, height });
        await s.page.waitForTimeout(900);
        await t.shot(s, `${name}-${width}px`);
      }
      await s.page.setViewportSize(original);
      await s.page.waitForTimeout(600);
    };
    try {
      await t.step('separate staff application opens without tenant Firebase login', async () => {
        const s = await open('operator');
        await text(s, 'Control Centre').first().waitFor({ timeout: 15000 });
        await s.page.getByText(EMAILS.operator, { exact: false }).first().waitFor();
        await openCompany(s, record.legalName);
        await t.shot(s, 'operator-company');
      });
      let invoice;
      await t.step('an issued invoice is ready for payment', async () => {
        await api('operator', 'POST', `/companies/${directory.HARNESS_TENANT}/package`,
          { planId: 'STANDARD', billingInterval: 'monthly', expectedRevision: 0, reason: 'E2E package for invoicing' },
          'control-package-first-0001');
        const quoteAsk = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: directory.HARNESS_TENANT,
          reason: 'E2E agreed price', params: { amountMinor: 500000, billingInterval: 'monthly' } }, 'control-quote-ask-0001');
        await api('owner', 'POST', `/approvals/${quoteAsk.approvalId}/approve`);
        const draft = await api('operator', 'POST', `/companies/${directory.HARNESS_TENANT}/invoices`, {}, 'control-invoice-draft-0001');
        invoice = await api('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);
        equal(invoice.status, 'issued', 'invoice status');
      });
      await t.step('lost payment response retries the original frozen intent once', async () => {
        const s = sessions.operator;
        await button(s, /^Inbox/).click();
        await button(s, 'Refresh').click();
        await s.page.waitForTimeout(2000);
        await openCompany(s, record.legalName);
        await button(s, 'Record payment').first().click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Bank reference', exact: true }), 'E2E/CONTROL-001');
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Bank statement checked');
        await button(s, 'Record payment').last().click();
        await button(s, 'Check again').waitFor({ timeout: 25000 });
        await button(s, 'Check again').click();
        await s.page.getByText('Bank ref E2E/CONTROL-001', { exact: false }).first().waitFor({ timeout: 25000 });
        equal(paymentRequests.length, 2, 'HTTP attempts');
        equal(paymentRequests[0], paymentRequests[1], 'retry intent');
        equal(JSON.parse(paymentRequests[0].body), { amountMinor: invoice.amountMinor, currency: 'MYR',
          externalReference: 'E2E/CONTROL-001', invoiceId: invoice.invoiceId, receivedAt: klMidnightUtc(),
          reason: 'Bank statement checked' }, 'payment intent');
        const rows = await platformDb.list('payment_entries');
        equal(rows.length, 1, 'exactly one durable receipt');
        equal(rows[0].createdBy, EMAILS.operator, 'verified actor');
        equal([rows[0].invoiceId, rows[0].amountMinor, rows[0].receivedAt], [invoice.invoiceId, invoice.amountMinor, klMidnightUtc()],
          'invoice, amount and bank date stored');
        await s.page.getByText('You recorded it, so another person checks it.', { exact: true }).first().waitFor();
        await t.shot(s, 'retry-recovered');
      });
      await t.step('operator activates from a covering payment and retries one frozen lifecycle intent', async () => {
        const s = sessions.operator;
        await button(s, 'More actions').click();
        await s.page.getByRole('menuitem', { name: 'Change status…' }).click();
        await s.page.getByRole('button', { name: 'New status' }).first().click();
        for (const label of ['Active', 'Awaiting first payment']) {
          await s.page.getByRole('menuitem', { name: label, exact: true }).waitFor({ timeout: 15000 });
        }
        const offered = async (label) => s.page.getByRole('menuitem', { name: label, exact: true }).count();
        equal([await offered('Awaiting first payment'), await offered('Active'), await offered('Trial')], [1, 1, 0],
          'first states served by the API');
        await s.page.getByRole('menuitem', { name: 'Active', exact: true }).click();
        await admin.pickDropdown(s.page, 'Payment that covers today', /RM /);
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Coverage verified for activation');
        await button(s, 'Apply change').click();
        await button(s, 'Check again').waitFor({ timeout: 25000 });
        await button(s, 'Check again').click();
        await text(s, 'Change status').waitFor({ state: 'detached', timeout: 25000 });
        await text(s, 'Active').first().waitFor({ timeout: 25000 });
        equal(lifecycleRequests.length, 2, 'lifecycle HTTP attempts');
        equal(lifecycleRequests[0], lifecycleRequests[1], 'frozen lifecycle retry');
        const lifecycle = await platformDb.get('lifecycle', directory.HARNESS_TENANT);
        equal([lifecycle.state, lifecycle.revision], ['active', 1], 'central lifecycle');
        const served = await api('operator', 'GET', `/companies/${directory.HARNESS_TENANT}/lifecycle`);
        equal(served.allowedNext, ['cancelled', 'past_due', 'suspended'], 'allowedNext for active');
        await button(s, 'More actions').click();
        await s.page.getByRole('menuitem', { name: 'Change status…' }).click();
        await s.page.getByRole('button', { name: 'New status' }).first().click();
        await s.page.getByRole('menuitem', { name: 'Past due', exact: true }).waitFor();
        equal([await offered('Past due'), await offered('Suspended'), await offered('Cancelled'), await offered('Active'),
          await offered('Awaiting first payment')], [1, 1, 1, 0, 0], 'UI offers only the API transitions');
        await s.page.keyboard.press('Escape');
        await button(s, 'Cancel').click();
        await t.shot(s, 'lifecycle-active');
      });
      await t.step('owner checks the payment and approves a void asked for by the operator', async () => {
        const s = await open('owner');
        await openCompany(s, record.legalName);
        await tab(s, 'Payments');
        await button(s, /^Matches bank statement, /).click();
        await button(s, 'Matches bank statement').click();
        await s.page.getByText(`Checked by ${EMAILS.owner}`, { exact: false }).first().waitFor({ timeout: 25000 });
        const op = sessions.operator;
        await openCompany(op, record.legalName);
        await tab(op, 'Payments');
        await button(op, /^Ask to void payment/).click();
        await B.fillField(op.page, op.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Wrong invoice; replacement requires a new reference');
        await button(op, 'Send for approval').click();
        await op.page.getByText('Sent for approval', { exact: false }).first().waitFor({ timeout: 25000 });
        await button(s, /^Inbox/).click();
        await button(s, 'Refresh').click();
        await button(s, 'Approve').click();
        await button(s, 'Approve').last().click();
        await button(s, 'Check again').waitFor({ timeout: 25000 });
        await button(s, 'Check again').click();
        await until(() => approveRequests.length >= 2, 'the second approve request');
        await button(s, 'Approve').waitFor({ state: 'detached', timeout: 25000 });
        equal(approveRequests.length, 2, `approve HTTP attempts ${JSON.stringify(approveRequests)}`);
        equal((await platformDb.list('payment_entries')).length, 2, 'original plus void');
        await t.shot(s, 'owner-approved-void');
      });

      const NEW_PROJECT = 'demo-control-newco';
      const NEW_NAME = 'E2E New Trading';
      const SECOND_PROJECT = 'demo-control-second';
      const SECOND_NAME = 'E2E Second Trading';
      let newTenant = null;
      let secondTenant = null;
      await t.step('operator starts a company draft and the engineer completes setup', async () => {
        const s = sessions.operator;
        const newDb = E.client(NEW_PROJECT);
        await newDb.reset();
        for (const [uid, role] of [['sup-a', 'supervisor'], ['sup-b', 'supervisor'], ['sales-a', 'salesman']]) {
          await newDb.put('user_access', uid, { uid, role, status: 'active', userDocId: `profile-${uid}` });
          await newDb.put('users', `profile-${uid}`, { uid, role });
        }
        await button(s, /^Onboarding/).click();
        await button(s, 'Add company').first().click();
        for (const [label, value] of Object.entries({ 'Company name': NEW_NAME, 'Workspace code': record.workspace.toUpperCase(),
          'First administrator name': 'First Admin', 'First administrator email': 'first.admin@example.test', 'First administrator employee code': 'ADM001', 'Billing email': 'new.billing@example.test' })) {
          await B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
        }
        await s.page.getByRole('button', { name: /^Package\b/ }).first().click();
        await s.page.getByRole('menuitem', { name: 'Standard', exact: true }).first().waitFor();
        equal(await s.page.getByRole('menuitem', { name: 'Internal', exact: true }).count(), 0, 'private plan hidden');
        await s.page.getByRole('menuitem', { name: 'Standard', exact: true }).first().click();
        await button(s, 'Create draft').click();
        await s.page.getByText('That workspace code is already in use', { exact: false }).waitFor({ timeout: 25000 });
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Workspace code', exact: true }), 'E2E-NEWCO');
        await button(s, 'Create draft').click();
        await text(s, 'Draft created').waitFor({ timeout: 30000 });
        await button(s, 'Open checklist').click();
        await text(s, 'Waiting for the owner: Connect project.').waitFor({ timeout: 25000 });
        equal(await button(s, 'Connect project').isDisabled(), true, 'operator cannot connect the project');
        await t.shot(s, 'draft-checklist');
        const drafts = await platformDb.list('onboarding_drafts');
        const draft = drafts.find((row) => row.workspace === 'e2e-newco');
        equal([draft.status, draft.planId, draft.billingInterval, draft.adminEmail, draft.createdBy],
          ['open', 'STANDARD', 'monthly', 'first.admin@example.test', EMAILS.operator], 'stored draft');
        equal((await platformDb.list('companies')).filter((row) => row.workspace === 'e2e-newco').length, 0,
          'no company record before setup');

        const engineer = await open('engineer');
        await button(engineer, /^Onboarding/).click();
        await button(engineer, `Open checklist for ${NEW_NAME}`).click();
        await button(engineer, 'Connect project').click();
        await B.fillField(engineer.page, engineer.page.getByRole('textbox', { name: 'Firebase project ID', exact: true }), NEW_PROJECT);
        await button(engineer, 'Connect').click();
        await button(engineer, 'Close').waitFor({ timeout: 60000 });
        await button(engineer, 'Close').click();
        await t.shot(engineer, 'setup-completed');

        const company = (await platformDb.list('companies')).find((row) => row.workspace === 'e2e-newco');
        newTenant = company.id;
        equal(await platformDb.get('subscriptions', newTenant) ?? null, null, 'no package while the company data is not prepared');
        equal(company.status, 'lead', 'a new company starts as a lead');
        const created = (await platformDb.list('operations')).find((row) => row.action === 'project.connect' && row.tenantId === newTenant);
        equal(created.actor, EMAILS.engineer, 'creation audit');
        const finished = (await platformDb.list('onboarding_drafts')).find((row) => row.draftId === draft.draftId);
        equal([finished.status, finished.tenantId], ['completed', newTenant], 'draft completed for the company');
        const second = await api('operator', 'POST', '/onboarding-drafts', { legalName: SECOND_NAME, workspace: 'e2e-second',
          planId: 'STANDARD', billingInterval: 'monthly', billingEmail: 'second.billing@example.test',
          adminName: 'Second Admin', adminEmail: 'second.admin@example.test', adminEmployeeCode: 'ADM001' }, 'control-second-draft-0001');
        await E.client(SECOND_PROJECT).reset();
        const done = await api('engineer', 'POST', `/onboarding-drafts/${second.draftId}/connect`, { projectId: SECOND_PROJECT });
        equal(done.refusal, null, 'second company connect refusal');
        secondTenant = (await api('operator', 'GET', `/onboarding-drafts/${second.draftId}`)).tenantId;
        equal(await platformDb.get('subscriptions', secondTenant) ?? null, null, 'second company has no package either');
      });
      await t.step('owner prepares company data and retries the package from the checklist; the other company is not touched', async () => {
        const s = sessions.owner;
        const newDb = E.client(NEW_PROJECT);
        const secondDb = E.client(SECOND_PROJECT);
        await button(s, /^Onboarding/).click();
        await button(s, `Open checklist for ${NEW_NAME}`).click();
        await text(s, 'Next: step 3, People and data').waitFor({ timeout: 25000 });
        await atWidths(s, 'checklist-before-prepare');
        await button(s, 'Prepare company data').first().click();
        await text(s, 'Starter: 2 supervisors, Starter allows 1').waitFor({ timeout: 25000 });
        await text(s, 'Standard: fits').waitFor();
        await atWidths(s, 'prepare-dry-run');
        equal(await newDb.get('config', 'usage') ?? null, null, 'the dry run wrote nothing');
        await button(s, 'Prepare company data').last().click();
        await text(s, 'Company data is prepared.').waitFor({ timeout: 40000 });
        const usage = await newDb.get('config', 'usage');
        equal([usage.usageSchemaVersion, usage.seats.supervisors, usage.seats.salesmen], [2, 2, 1], 'counters written for the first company');
        equal(await secondDb.get('config', 'usage') ?? null, null, 'the other company has no counters');
        equal(await platformDb.get('subscriptions', secondTenant) ?? null, null, 'the other company has no package');
        await text(s, 'Next: step 4, Package').waitFor({ timeout: 25000 });
        await button(s, 'Apply package').click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'First package');
        await button(s, 'Apply package').last().click();
        await text(s, 'Package changed.').waitFor({ timeout: 40000 });
        const subscription = await platformDb.get('subscriptions', newTenant);
        equal([subscription.planId, subscription.planVersion, subscription.billingInterval, subscription.revision],
          ['STANDARD', 1, 'monthly', 1], 'initial subscription');
        equal((await newDb.get('config', 'plan')).planId, 'STANDARD', 'package projected to the company');
        await text(s, 'Next: step 5, First payment').waitFor({ timeout: 25000 });
        await atWidths(s, 'checklist-after');
        const operator = sessions.operator;
        await openCompany(operator, NEW_NAME);
        await text(operator, 'Standard · monthly').first().waitFor({ timeout: 25000 });
        await t.shot(operator, 'company-created');
      });
      await t.step('New invoice and Change package errors name the fix and link to it; a package added on the Packages page is used', async () => {
        const s = sessions.owner;
        const secondDb = E.client(SECOND_PROJECT);
        await button(s, /^Invoices/).click();
        await button(s, 'New invoice').first().click();
        await s.page.getByRole('button', { name: 'Company' }).first().click();
        await s.page.getByRole('menuitem', { name: SECOND_NAME, exact: true }).click();
        await button(s, 'Create draft').click();
        await s.page.getByText(/Step 3 \(People and data\) is not/).first().waitFor({ timeout: 25000 });
        await atWidths(s, 'new-invoice-error');
        await button(s, 'Cancel').click();

        await button(s, /^Packages/).click();
        await button(s, 'Add package').click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Package name', exact: true }), 'E2E Reseller');
        await text(s, 'Package ID: E2E_RESELLER').waitFor();
        for (const [label, value] of [['Salespeople allowed', '12'], ['Supervisors allowed', '3'], ['Admins allowed', '1'],
          ['Branch managers allowed', '2'], ['Products allowed', '300'], ['Monthly price (RM)', '900'],
          ['Yearly price (RM)', '9000'], ['Reason', 'New reseller package']]) {
          await B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
        }
        await atWidths(s, 'add-package');
        await button(s, 'Add package').last().click();
        await text(s, 'The package was added.').waitFor({ timeout: 40000 });
        await text(s, 'E2E Reseller').first().waitFor({ timeout: 25000 });
        const plan = async () => (await api('owner', 'GET', '/plans')).plans.find((row) => row.planId === 'E2E_RESELLER');
        const stored = await plan();
        equal([stored.current.name, stored.current.edition, stored.current.limits.salesmen, stored.current.prices.monthly, stored.current.prices.yearly],
          ['E2E Reseller', 'basic', 12, 900, 9000], 'new package stored');
        await button(s, 'Edit E2E Reseller').click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Salespeople allowed', exact: true }), '15');
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'More salespeople');
        await button(s, 'Save package').click();
        await text(s, 'The package was saved.').waitFor({ timeout: 40000 });
        const edited = await plan();
        equal([edited.current.limits.salesmen, edited.current.prices.monthly], [15, 900], 'edit kept the price and changed the limit');
        await atWidths(s, 'packages-page');

        const changePackage = async () => {
          await button(s, 'More actions').click();
          await s.page.getByRole('menuitem', { name: 'Change package…' }).click();
          await s.page.getByRole('button', { name: 'Package' }).first().click();
          await s.page.getByRole('menuitem', { name: 'E2E Reseller (E2E_RESELLER)', exact: true }).click();
          await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Reseller contract');
          await button(s, 'Apply package').click();
        };
        await openCompany(s, SECOND_NAME);
        await changePackage();
        await s.page.getByText(/Step 3 \(People and data\) is not/).first().waitFor({ timeout: 40000 });
        await atWidths(s, 'change-package-error');
        await button(s, 'Cancel').click();
        equal((await api('owner', 'POST', `/companies/${secondTenant}/prepare-data`, { apply: true })).prepared, true, 'second company prepared');
        const secondUsage = await secondDb.get('config', 'usage');
        equal([secondUsage.usageSchemaVersion, secondUsage.seats.supervisors], [2, 0], 'counters written for the second company');
        await changePackage();
        await text(s, 'Package changed.').waitFor({ timeout: 40000 });
        const secondSubscription = await platformDb.get('subscriptions', secondTenant);
        const firstSubscription = await platformDb.get('subscriptions', newTenant);
        equal([secondSubscription.planId, secondSubscription.revision, firstSubscription.planId, firstSubscription.revision],
          ['E2E_RESELLER', 1, 'STANDARD', 1], 'the second company changed package and the first did not');
        equal((await E.client(NEW_PROJECT).get('config', 'plan')).planId, 'STANDARD', 'the first company project keeps its package');
        await atWidths(s, 'second-company-packaged');
      });
      await t.step('plan request opens an upgrade-only package change with a frozen retry', async () => {
        const s = sessions.operator;
        await platformDb.put('plan_requests', 'req_e2econtrolcentre', { tenantId: newTenant, planId: 'PROFESSIONAL', interval: 'yearly',
          status: 'requested', requestedBy: 'client-admin-uid', createdAt: new Date() });
        await button(s, /^Inbox/).click();
        await button(s, 'Refresh').click();
        await text(s, 'Change package to Professional').waitFor({ timeout: 25000 });
        await text(s, 'Yearly · sent by the company administrator').waitFor();
        await button(s, 'Change package').click();
        await s.page.getByText('Current package: Standard (STANDARD), monthly', { exact: true }).waitFor({ timeout: 25000 });
        await s.page.getByText('Starter (STARTER)', { exact: true }).waitFor();
        for (const sentence of ['Salespeople would drop from 10 to 5.', 'Supervisors would drop from 2 to 1.', 'Branch managers would drop from 2 to 1.', 'Products would drop from 500 to 100.']) {
          await B.semantic(s.page, sentence).waitFor();
        }
        await t.shot(s, 'package-change-not-available');
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Client request approved');
        await button(s, 'Apply package').click();
        await button(s, 'Check again').waitFor({ timeout: 25000 });
        await button(s, 'Check again').click();
        await until(() => packageRequests.length >= 2, 'the second package request');
        await button(s, 'Apply package').waitFor({ state: 'detached', timeout: 25000 });
        await text(s, 'Check again').waitFor({ state: 'detached', timeout: 25000 });
        equal(packageRequests.length, 2, `package HTTP attempts ${JSON.stringify(packageStatuses)}`);
        equal(packageRequests[0], packageRequests[1], 'frozen package retry');
        equal(JSON.parse(packageRequests[0].body), { planId: 'PROFESSIONAL', billingInterval: 'yearly', expectedRevision: 1,
          reason: 'Client request approved' }, 'package intent');
        const subscription = await platformDb.get('subscriptions', newTenant);
        equal([subscription.planId, subscription.planVersion, subscription.billingInterval, subscription.revision],
          ['PROFESSIONAL', 1, 'yearly', 2], 'upgraded subscription');
        await openCompany(s, NEW_NAME);
        await text(s, 'Professional · yearly').first().waitFor({ timeout: 25000 });
        await tab(s, 'Requests');
        await text(s, 'Done').waitFor({ timeout: 25000 });
        await t.shot(s, 'package-upgraded');
      });
      await t.step('operator declines a plan request with a reason', async () => {
        const s = sessions.operator;
        const pending = { tenantId: directory.HARNESS_TENANT, requestId: directory.HARNESS_TENANT, planId: 'PROFESSIONAL', interval: 'monthly',
          status: 'requested', requestedBy: 'client-admin-uid', requesterEmail: 'client.admin@example.test', requestKey: 'e2edeclinekey', createdAt: new Date() };
        await platformDb.put('plan_requests', directory.HARNESS_TENANT, pending);
        await platformDb.put(`plan_requests/${directory.HARNESS_TENANT}/history`, 'e2edeclinekey', pending);
        await button(s, /^Inbox/).click();
        await button(s, 'Refresh').click();
        await button(s, 'Decline…').first().click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Not available for this client yet');
        await button(s, 'Decline request').click();
        await text(s, 'The request was declined.').first().waitFor({ timeout: 25000 });
        const declined = await platformDb.get('plan_requests', directory.HARNESS_TENANT);
        equal([declined.status, declined.declineReason], ['declined', 'Not available for this client yet'], 'declined request');
        await t.shot(s, 'plan-request-declined');
      });
      await t.step('operator retries a tenant operation left pending by a crash', async () => {
        const s = sessions.operator;
        const operationId = `op_${crypto.randomBytes(16).toString('hex')}`;
        const now = new Date();
        await platformDb.put('operations', operationId, { operationId, action: 'subscription.change', actor: EMAILS.operator,
          tenantId: newTenant, reason: 'Interrupted package change', ticket: null,
          fieldNames: ['addOns', 'billingInterval', 'expectedRevision', 'kind', 'planId', 'planVersion', 'renewsAt', 'status', 'trialEndsAt'],
          params: { tenantId: newTenant, requestedBy: EMAILS.operator, change: { kind: 'put', planId: 'ENTERPRISE', planVersion: 1,
            addOns: {}, status: 'trial', billingInterval: 'yearly', renewsAt: null, trialEndsAt: null, expectedRevision: 2 } },
          steps: Object.fromEntries(['write_subscription', 'project_plan', 'resign_record'].map((name) =>
            [name, { status: 'pending', result: null, finishedAt: null }])),
          status: 'pending', outcome: null, error: null, createdAt: now, updatedAt: now, leaseOwner: null, leaseUntil: null });
        await openCompany(s, NEW_NAME);
        await tab(s, 'Activity');
        await text(s, 'Operations needing attention').waitFor({ timeout: 25000 });
        await text(s, 'Package change').first().waitFor();
        await button(s, 'Retry').click();
        await s.page.getByText('The operation completed.', { exact: true }).first().waitFor({ timeout: 25000 });
        await openCompany(s, NEW_NAME);
        await text(s, 'Enterprise · yearly').first().waitFor({ timeout: 25000 });
        equal((await platformDb.get('operations', operationId)).status, 'completed', 'operation completed');
        const subscription = await platformDb.get('subscriptions', newTenant);
        equal([subscription.planId, subscription.revision], ['ENTERPRISE', 3], 'recovered subscription');
        await t.shot(s, 'pending-retried');
      });
      await t.step('owner sees the mail jobs, retries a failed one, handles an uncertain one and changes the billing email with a second person', async () => {
        const s = sessions.owner;
        const tenantId = directory.HARNESS_TENANT;
        const FAILED = 'e2e.mail.failed@example.test';
        const UNCERTAIN = 'e2e.mail.uncertain@example.test';
        const BILLING = 'e2e.billing@example.test';
        const jobId = (name) => crypto.createHash('sha256').update(`${tenantId}\u0000${name}`).digest('hex');
        const seedJob = async (name, recipient, status, failure, ageMinutes) => {
          const at = iso(new Date(Date.now() - ageMinutes * 60000));
          const id = jobId(name);
          await platformDb.put('mail_jobs', id, { jobId: id, tenantId, kind: 'invitation', recipient,
            payload: { tenantId, companyName: record.legalName, inviteUrl: 'https://dashboard.scootsales.test/invite#invite=e2e', expiresAt: '2030-01-01T00:00:00Z' },
            actor: 'e2e-admin', intentHash: `e2e-${name}`, status, attempts: 3, maxAttempts: 5, createdAt: at, updatedAt: at,
            nextAttemptAt: at, providerMessageId: null, lastFailure: failure, leaseToken: null, leaseExpiresAt: null });
          return id;
        };
        const failedId = await seedJob('mail-panel-failed', FAILED, 'failed', 'E2E provider rejected the mail', 120);
        const uncertainId = await seedJob('mail-panel-uncertain', UNCERTAIN, 'uncertain', 'E2E provider did not confirm', 60);
        const reach = async (locator) => {
          await B.scrollIntoView(s.page, locator, { minHeight: 20, bottomInset: 0, pointerY: 0.7 });
          return locator;
        };
        const companyJobs = async () => (await platformDb.list('mail_jobs')).filter((job) => job.tenantId === tenantId);

        await openCompany(s, record.legalName);
        await tab(s, 'Emails');
        await text(s, `Invitation to ${FAILED}`).waitFor({ timeout: 25000 });
        await text(s, `Invitation to ${UNCERTAIN}`).waitFor();
        await reach(text(s, `Invitation to ${FAILED}`));
        equal([(await text(s, 'Failed').count()) >= 1, (await text(s, 'Uncertain').count()) >= 1], [true, true], 'status chips');
        await text(s, 'E2E provider rejected the mail').waitFor();
        await text(s, 'E2E provider did not confirm').waitFor();
        equal(await text(s, 'Retried as a new mail job.').count(), 0, 'nothing retried yet');
        await t.shot(s, 'mail-panel-rows');

        await (await reach(button(s, `Retry mail to ${FAILED}`))).click();
        await button(s, 'Retry mail').waitFor();
        await button(s, 'Retry mail').click();
        await text(s, 'The mail was queued again.').waitFor({ timeout: 25000 });
        await text(s, 'Retried as a new mail job.').waitFor({ timeout: 25000 });
        await text(s, 'Queued').first().waitFor();
        equal(await text(s, `Invitation to ${FAILED}`).count(), 2, 'old failed row plus the new queued row');
        const afterRetry = await companyJobs();
        const replacement = afterRetry.find((job) => job.retryOf === failedId);
        equal([afterRetry.length, replacement.status, replacement.recipient, replacement.attempts, replacement.actor],
          [4, 'queued', FAILED, 0, EMAILS.owner], 'new queued job from the retry (the declined plan request also queued one mail)');
        equal((await platformDb.get('mail_jobs', failedId)).retriedAs, replacement.jobId, 'old job points to the new job');
        await t.shot(s, 'mail-retried-rows');

        await (await reach(button(s, `Retry mail to ${UNCERTAIN}`))).click();
        await text(s, 'Retry mail that may already be sent').waitFor();
        await button(s, 'Retry despite duplicate risk').waitFor();
        await button(s, 'Cancel').click();
        await text(s, 'Retry mail that may already be sent').waitFor({ state: 'detached' });
        equal((await companyJobs()).filter((job) => job.retryOf === uncertainId).length, 0, 'cancel does not queue a duplicate');

        await (await reach(button(s, `Mark mail to ${UNCERTAIN} as handled`))).click();
        await text(s, 'Mark mail as handled').waitFor();
        await button(s, 'Mark handled').click();
        await text(s, 'The mail was marked as handled.').waitFor({ timeout: 25000 });
        await s.page.getByText(`Handled by ${EMAILS.owner}`, { exact: false }).first().waitFor({ timeout: 25000 });
        const handled = await platformDb.get('mail_jobs', uncertainId);
        equal([handled.handledBy, Boolean(handled.handledAt), handled.status, handled.retriedAs || null],
          [EMAILS.owner, true, 'uncertain', null], 'handled job');
        equal((await companyJobs()).length, 4, 'mark handled does not queue a mail');
        await t.shot(s, 'mail-handled');

        await s.page.evaluate(() => window.scrollTo(0, 0));
        await button(s, 'More actions').click();
        await s.page.getByRole('menuitem', { name: /billing email/i }).click();
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Billing email', exact: true }), BILLING);
        await B.fillField(s.page, s.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Client asked for a new billing address');
        await button(s, 'Send for approval').click();
        await text(s, 'Sent for approval').waitFor({ timeout: 25000 });
        equal((await platformDb.get('companies', tenantId)).billingEmail ?? null, null, 'billing email unchanged before approval');

        const op = sessions.operator;
        await button(op, /^Inbox/).click();
        await button(op, 'Refresh').click();
        await button(op, 'Approve').waitFor({ timeout: 25000 });
        await text(op, /^Change the billing email/).waitFor({ timeout: 25000 });
        for (let stable = 0, last = '', tries = 0; stable < 3 && tries < 40; tries += 1) {
          const box = JSON.stringify(await button(op, 'Approve').boundingBox());
          stable = box === last ? stable + 1 : 0;
          last = box;
          await op.page.waitForTimeout(500);
        }
        await button(op, 'Approve').click();
        await button(op, 'Approve').last().click();
        await text(op, 'Approved.').waitFor({ timeout: 25000 });
        equal((await platformDb.get('companies', tenantId)).billingEmail, BILLING, 'companies document billingEmail');
        const served = await api('owner', 'GET', '/companies');
        equal((served.companies || served).find((company) => company.tenantId === tenantId).billingEmail, BILLING,
          'GET companies billingEmail');
        await t.shot(op, 'billing-email-approved');
      });
      await t.step('the invoice mail and the receipt mail carry the invoice as a PDF', async () => {
        const quoteAsk = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: newTenant,
          reason: 'E2E agreed price', params: { amountMinor: 500000, billingInterval: 'yearly' } }, 'control-quote-pdf-0001');
        await api('owner', 'POST', `/approvals/${quoteAsk.approvalId}/approve`);
        const draft = await api('operator', 'POST', `/companies/${newTenant}/invoices`, {}, 'control-invoice-pdf-0001');
        const issued = await api('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);
        const sent = await api('operator', 'POST', `/invoices/${draft.invoiceId}/send`);
        equal([sent.status, sent.delivery.state, sent.dueAt], ['issued', 'sending', null], 'invoice waits for its mail');
        equal(service.deliverMail().sent >= 1, true, 'the mail tick delivered the queued invoice');
        const delivered = await api('operator', 'GET', `/invoices/${draft.invoiceId}`);
        equal([delivered.status, delivered.delivery.state, delivered.dueAt !== null], ['sent', 'delivered', true], 'invoice sent once delivered');
        const attached = await mailedPdf(sink, 'new.billing@example.test', `Invoice ${issued.number}`);
        equal(attached.name, `${issued.number}.pdf`, 'invoice PDF name');
        const jobs = (await platformDb.list('mail_jobs')).filter((job) => job.kind === 'invoice');
        equal(jobs.map((job) => [job.status, job.attachment.name, job.attachment.sha256]), [['sent', attached.name, attached.sha256]],
          'invoice mail job keeps its PDF');
        const paid = await api('operator', 'POST', `/companies/${newTenant}/payments`, {
          amountMinor: issued.amountMinor, currency: 'MYR', externalReference: 'E2E/CONTROL-PDF-001', invoiceId: issued.invoiceId,
          receivedAt: klMidnightUtc(), reason: 'Bank statement checked' }, 'control-payment-pdf-0001');
        await api('owner', 'POST', `/companies/${newTenant}/payments/${paid.entryId}/check`);
        equal(service.deliverMail().sent >= 1, true, 'the mail tick delivered the queued receipt');
        const receipt = await mailedPdf(sink, 'new.billing@example.test', 'Payment receipt');
        equal(receipt.name, `${issued.number}.pdf`, 'receipt PDF name');
      });
      await t.step('Companies counts an expired company record and one expiring within 14 days', async () => {
        const s = sessions.operator;
        const day = 86400000;
        const lapsedName = 'E2E Lapsed Trading';
        const expiringName = 'E2E Expiring Trading';
        const separate = (tenantId, workspace, legalName, projectId, status) => ({
          ...record, tenantId, workspace, companyCode: workspace, legalName, status,
          location: { ...record.location, projectId },
        });
        directory.seedDirectory([key], [
          { record: separate('t_e2elapsed1', 'e2e-lapsed', lapsedName, 'demo-control-lapsed', 'cancelled'), key,
            issuedAt: iso(new Date(Date.now() - 40 * day)), ttlDays: 30 },
          { record: separate('t_e2eexpiring1', 'e2e-expiring', expiringName, 'demo-control-expiring', 'active'), key,
            issuedAt: iso(new Date(Date.now() - 20 * day)), ttlDays: 30 },
        ]);
        const served = await api('operator', 'GET', '/today');
        equal([served.companies.total, served.companies.recordsExpired, served.companies.recordsExpiringWithin14Days], [5, 1, 1],
          'Today counts from the API');
        await button(s, /^Inbox/).click();
        await button(s, 'Refresh').click();
        await s.page.waitForTimeout(2000);
        await button(s, 'Companies').click();
        await s.page.getByText('1 expired, 1 expiring within 14 days', { exact: false }).first().waitFor({ timeout: 25000 });
        await button(s, new RegExp(`^${lapsedName}.*expired record`)).waitFor({ timeout: 25000 });
        equal(await button(s, new RegExp(`^${expiringName}.*expired record`)).count(), 0, 'a record that has not expired is not marked');
        equal(await button(s, new RegExp(`^${record.legalName}.*expired record`)).count(), 0, 'the current company is not marked');
        await t.shot(s, 'companies-expired-flag');
      });
      await t.step('support role lands on Support with a menu of its own and no tenant SDK access', async () => {
        const reason = 'Investigate synchronisation failure';
        const now = Date.now();
        await platformDb.put('support_grants', 'grant_e2e_support_home', {
          tenantId: record.tenantId, staffEmail: EMAILS.support, scope: 'diagnostics', reason, status: 'active',
          revision: 1, createdBy: 'e2e', createdAt: new Date(now), expiresAt: new Date(now + 40 * 60000),
        });
        const s = await open('support');
        await text(s, `${record.legalName} (${record.workspace.toUpperCase()})`).waitFor({ timeout: 25000 });
        await text(s, reason).waitFor({ timeout: 25000 });
        equal(await button(s, 'Support').count(), 1, 'support menu has its own section');
        for (const hidden of ['Inbox', 'Companies', 'Onboarding', 'Invoices', 'Payments', 'Packages', 'Staff and access', 'Audit log', 'Settings']) {
          equal(await button(s, new RegExp(`^${hidden}(,|$)`)).count(), 0, `support menu hides ${hidden}`);
        }
        equal(await button(s, 'Record payment').count(), 0, 'support payment hidden');
        await s.page.getByRole('button', { name: /^Account menu/ }).click();
        await s.page.getByRole('menuitem', { name: 'My account', exact: true }).click();
        await text(s, 'Role').waitFor({ timeout: 25000 });
        for (const session of Object.values(sessions)) {
          if (session.tenantSdkRequests.length) {
            throw new Error('Control Centre attempted tenant Firebase bootstrap');
          }
        }
        await t.shot(s, 'support-home');
      });
    } finally {
      fs.mkdirSync(path.join(E.OUTPUT_DIR, 'v4_control_centre'), { recursive: true });
      await service.stop();
      await sink.close();
    }
  },
};
