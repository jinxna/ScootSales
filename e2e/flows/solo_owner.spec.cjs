'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { acceptFirstAdminInvitation } = require('../lib/onboarding_ui.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const OWNER = 'e2e.solo.owner@example.test';
const PLAN = 'E2E_SOLO_PACK';
const PLAN_NAME = 'E2E Solo Pack';
const A = { project: 'demo-solo-a', name: 'Solo Alpha Trading', workspace: 'solo-alpha', admin: 'alpha.admin@example.test' };
const B_CO = { project: 'demo-solo-b', name: 'Solo Beta Trading', workspace: 'solo-beta', admin: 'beta.admin@example.test' };
const FIRST = { monthly: 400, yearly: 4000 };
const CHANGED = { monthly: 450, yearly: 4500 };
const PHONE = { width: 390, height: 844 };

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

module.exports = {
  name: 'solo_owner',
  platformApi: false,
  async run(t) {
    const key = platform.ensureKey();
    const record = platform.harnessRecord();
    await directory.resetDirectory();
    directory.seedDirectory([key], [{ record: { ...record, location: { ...record.location, projectId: 'demo-solo-seed' } }, key }]);
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const sink = await startMailSink();
    await sink.clear();
    const keep = process.env.PLATFORM_SOLO_OWNER;
    process.env.PLATFORM_SOLO_OWNER = 'true';
    process.env.PLATFORM_INVITE_SECRET = require('node:crypto').randomBytes(32).toString('base64url');
    let service;
    try {
      service = await staff.startStaffApi(key, { roleEmails: { owner: OWNER }, browserSignIn: true, scheduler: false, e2eReaders: true });
    } finally {
      if (keep === undefined) delete process.env.PLATFORM_SOLO_OWNER;
      else process.env.PLATFORM_SOLO_OWNER = keep;
    }
    const api = async (method, route, body, idempotencyKey) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, { method,
        headers: { 'Content-Type': 'application/json', Connection: 'close', ...service.headers('owner'),
          Origin: service.url, 'Sec-Fetch-Site': 'same-origin',
          ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body) });
      const raw = await response.text();
      if (!response.ok) throw new Error(`${method} ${route} -> ${response.status} ${raw}`);
      return raw ? JSON.parse(raw) : {};
    };
    const button = (s, name) => s.page.getByRole('button', { name, exact: typeof name === 'string' });
    const text = (s, value) => s.page.getByText(value, { exact: typeof value === 'string' });
    const field = (s, label, value) => B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
    const prepareProject = async (project) => {
      const db = E.client(project);
      await db.reset();
      await db.put('config', 'usage', { usageSchemaVersion: 2, products: 0, activeAdmins: 0,
        seats: { salesmen: 0, supervisors: 0, admins: 0, branchManagers: 0 } });
    };
    const inside = async (s, locator, label, width = PHONE.width) => {
      const box = await locator.first().boundingBox();
      if (!box) throw new Error(`${label} has no box at ${width} px`);
      if (box.x < -1 || box.x + box.width > width + 1) throw new Error(`${label} sticks out at ${width} px: x ${Math.round(box.x)}, width ${Math.round(box.width)}`);
    };
    const atPhone = async (s, name, check) => {
      const original = s.page.viewportSize();
      await s.page.setViewportSize(PHONE);
      await s.page.waitForTimeout(1000);
      try {
        await check();
        await t.shot(s, `${name}-390px`);
      } finally {
        await s.page.setViewportSize(original);
        await s.page.waitForTimeout(600);
      }
    };
    const money = (rm) => `RM ${rm.toLocaleString('en-US', { minimumFractionDigits: 2, maximumFractionDigits: 2 })}`;
    let s;
    let tenantA;
    let tenantB;
    const note = [];
    try {
      await t.step('the owner is the only approver and the staff page says solo mode is in use', async () => {
        s = await t.session('admin', { name: 'control-solo-owner' });
        await s.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const began = Date.now();
          const response = await route.fetch({ url: `${service.url}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host, connection: 'close' } }).catch((error) => { console.log(`  staff API ${request.method()} ${url.pathname} failed after ${Date.now() - began} ms: ${error.message.slice(0, 160)}`); return null; });
          if (!response) return route.abort('failed').catch(() => null);
          if (Date.now() - began > 5000) console.log(`  staff API ${request.method()} ${url.pathname} took ${Date.now() - began} ms (status ${response.status()})`);
          return route.fulfill({ response });
        });
        await B.openApp(s.page, t.urls.admin);
        await staff.signInControlCentre(s.page, OWNER, sink, new Set());
        await button(s, /^Staff and access(,|$)/).first().click();
        await text(s, /Solo owner setting: on\. You are the only approver/).first().waitFor({ timeout: 25000 });
        await t.shot(s, 'staff-solo-on');
        const rows = await platformDb.list('staff');
        equal(rows.filter((r) => r.status === 'active').map((r) => [r.email, r.role]), [[OWNER, 'owner']], 'active staff');
      });
      await t.step('an unpriced package exists for the owner to price', async () => {
        const body = (monthly, yearly) => ({ name: PLAN_NAME, edition: 'advanced', limits: { salesmen: 5, supervisors: 1, admins: 1, branchManagers: 1, products: 100 },
          quotaSchemaVersion: 2, features: {}, notes: '', prices: { currency: 'MYR', monthly, yearly }, tagline: '', highlights: [],
          sortOrder: 90, visibility: 'public', reason: 'Create the unpriced package' });
        await api('PUT', `/plans/${PLAN}`, body(null, null), 'solo-plan-0001');
      });
      await t.step('the owner completes setup of the first company alone, with no engineer', async () => {
        await prepareProject(A.project);
        await button(s, /^Onboarding(,|$)/).first().click();
        await button(s, 'Add company').first().click();
        for (const [label, value] of Object.entries({ 'Company name': A.name, 'Workspace code': A.workspace.toUpperCase(),
          'First administrator name': 'Alpha Admin', 'First administrator email': A.admin, 'First administrator employee code': 'ADM001', 'Billing email': 'alpha.billing@example.test' })) await field(s, label, value);
        await s.page.getByRole('button', { name: /^Package\b/ }).first().click();
        await s.page.getByRole('menuitem', { name: PLAN_NAME, exact: true }).first().click();
        await button(s, 'Create draft').click();
        await text(s, 'Draft created').waitFor({ timeout: 30000 });
        await button(s, 'Open checklist').click();
        await button(s, 'Connect project').click();
        await field(s, 'Firebase project ID', A.project);
        await button(s, 'Connect').click();
        await button(s, 'Close').waitFor({ timeout: 60000 });
        await button(s, 'Close').click();
        await t.shot(s, 'setup-completed-by-owner');
        const company = (await platformDb.list('companies')).find((row) => row.workspace === A.workspace);
        tenantA = company.id;
        equal(company.status, 'lead', 'a new company starts as a lead');
        const created = (await platformDb.list('operations')).find((row) => row.action === 'project.connect' && row.tenantId === tenantA);
        equal(created.actor, OWNER, 'setup actor');
      });
      await t.step('company B is set up too, and stays separate from company A', async () => {
        await prepareProject(B_CO.project);
        const draft = await api('POST', '/onboarding-drafts', { legalName: B_CO.name, workspace: B_CO.workspace, planId: PLAN,
          billingInterval: 'monthly', billingEmail: 'beta.billing@example.test', adminName: 'Beta Admin', adminEmail: B_CO.admin, adminEmployeeCode: 'ADM001' }, 'solo-b-draft-0001');
        const done = await api('POST', `/onboarding-drafts/${draft.draftId}/connect`, { projectId: B_CO.project });
        if (done.refusal) throw new Error(`company B connect refused: ${done.refusal}`);
        tenantB = (await api('GET', `/onboarding-drafts/${draft.draftId}`)).tenantId;
        if (!tenantB || tenantB === tenantA) throw new Error('company B did not get its own record');
      });
      await t.step('the owner sets the first price of a package without approval', async () => {
        await button(s, /^Packages(,|$)/).first().click();
        await text(s, PLAN_NAME).first().waitFor({ timeout: 25000 });
        await button(s, `Set price for ${PLAN_NAME}`).click();
        await text(s, `Set the first price of ${PLAN_NAME}`).waitFor();
        await field(s, 'Monthly price (RM)', String(FIRST.monthly));
        await field(s, 'Yearly price (RM)', String(FIRST.yearly));
        await field(s, 'Reason', 'First price list');
        await t.shot(s, 'first-price-dialog');
        await button(s, 'Save price').click();
        await text(s, 'Price saved').first().waitFor({ timeout: 40000 });
        await text(s, money(FIRST.monthly)).first().waitFor({ timeout: 25000 });
        await button(s, `Change price for ${PLAN_NAME}`).waitFor({ timeout: 25000 });
        const stored = (await api('GET', '/plans')).plans.find((p) => p.planId === PLAN);
        equal([stored.current.prices.monthly, stored.current.prices.yearly], [FIRST.monthly, FIRST.yearly], 'stored first price');
        await t.shot(s, 'first-price-saved');
      });
      await t.step('the owner asks for a price change and approves it alone in the Inbox', async () => {
        await button(s, `Change price for ${PLAN_NAME}`).click();
        await text(s, `Change the price of ${PLAN_NAME}`).waitFor();
        await field(s, 'Monthly price (RM)', String(CHANGED.monthly));
        await field(s, 'Yearly price (RM)', String(CHANGED.yearly));
        await field(s, 'Reason', 'Price list from next month');
        await button(s, 'Send for approval').click();
        await text(s, 'Sent for approval. Approve it in Inbox.').first().waitFor({ timeout: 40000 });
        const unchanged = (await api('GET', '/plans')).plans.find((p) => p.planId === PLAN);
        equal(unchanged.current.prices.monthly, FIRST.monthly, 'the price waits for approval');
        await button(s, /^Inbox/).first().click();
        await button(s, 'Refresh').click();
        await text(s, /Price list from next month|price/i).first().waitFor({ timeout: 25000 });
        await atPhone(s, 'inbox-own-price-request', async () => {
          await inside(s, button(s, 'Approve'), 'Approve button in the Inbox');
        });
        await button(s, 'Approve').first().click();
        await button(s, 'Approve').last().click();
        const again = button(s, 'Check again');
        await Promise.race([again.waitFor({ timeout: 20000 }), button(s, 'Approve').waitFor({ state: 'detached', timeout: 20000 })]).catch(() => null);
        if (await again.count()) {
          note.push('the first approve answer was lost; the owner pressed Check again as the screen says');
          await again.click();
        }
        await button(s, 'Approve').waitFor({ state: 'detached', timeout: 60000 });
        let changed;
        for (const deadline = Date.now() + 30000; ; await s.page.waitForTimeout(300)) {
          changed = (await api('GET', '/plans')).plans.find((p) => p.planId === PLAN);
          if (changed.current.prices.monthly === CHANGED.monthly || Date.now() > deadline) break;
        }
        equal([changed.current.prices.monthly, changed.current.prices.yearly], [CHANGED.monthly, CHANGED.yearly], 'stored changed price');
        const solo = (await platformDb.list('approvals')).filter((row) => row.action === 'package.price' && row.soloApproval === true && row.requestedBy === OWNER && row.decidedBy === OWNER);
        equal(solo.length, 1, 'price approvals marked as solo approval by the same owner');
        await button(s, /^Packages(,|$)/).first().click();
        await text(s, money(CHANGED.monthly)).first().waitFor({ timeout: 25000 });
        await t.shot(s, 'changed-price-shown');
      });
      await t.step('the package page shows each package as a card with every action inside a 390 px screen', async () => {
        await atPhone(s, 'packages', async () => {
          await text(s, PLAN_NAME).first().waitFor({ timeout: 15000 });
          await inside(s, text(s, PLAN_NAME), 'package name');
          await inside(s, button(s, `Change price for ${PLAN_NAME}`), 'Change price button');
          await inside(s, button(s, `Edit ${PLAN_NAME}`), 'Edit button');
          await inside(s, text(s, money(CHANGED.monthly)), 'monthly price');
        });
      });
      let invoice;
      await t.step('the changed price reaches the first invoice of company A', async () => {
        const subscription = await platformDb.get('subscriptions', tenantA);
        await api('POST', `/companies/${tenantA}/package`, { planId: PLAN, billingInterval: 'monthly', expectedRevision: subscription ? subscription.revision : 0,
          reason: 'Package for the first invoice' }, 'solo-a-package-0001');
        const draft = await api('POST', `/companies/${tenantA}/invoices`, {}, 'solo-a-invoice-0001');
        invoice = await api('POST', `/invoices/${draft.invoiceId}/issue`);
        equal([invoice.status, invoice.amountMinor], ['issued', CHANGED.monthly * 100], 'issued invoice at the changed price');
      });
      await t.step('the owner records the payment and checks it alone', async () => {
        await button(s, 'Companies').first().click();
        await s.page.waitForTimeout(1500);
        await button(s, new RegExp(`^${A.name}, workspace`)).click();
        await text(s, 'Subscription').waitFor({ timeout: 25000 });
        await button(s, 'Record payment').first().click();
        await field(s, 'Bank reference', 'SOLO/ALPHA-001');
        await field(s, 'Reason', 'Bank statement checked');
        await button(s, 'Record payment').last().click();
        await s.page.getByText('Bank ref SOLO/ALPHA-001', { exact: false }).first().waitFor({ timeout: 40000 });
        await s.page.getByText('You recorded it, so another person checks it.', { exact: true }).waitFor({ state: 'detached', timeout: 3000 })
          .catch(() => { throw new Error('the solo owner is told another person must check the payment'); });
        await button(s, /^Matches bank statement, /).click();
        await button(s, 'Matches bank statement').click();
        await s.page.getByText(`Checked by ${OWNER}`, { exact: false }).first().waitFor({ timeout: 40000 });
        const entry = (await platformDb.list('payment_entries')).find((row) => row.tenantId === tenantA);
        const check = await platformDb.get('payment_checks', entry.entryId);
        equal([entry.createdBy, check && check.checkedBy, check && check.soloApproval], [OWNER, OWNER, true], 'payment checked by the same owner, marked solo');
        await t.shot(s, 'payment-checked-alone');
      });
      await t.step('the owner gives the first administrator access and the person accepts', async () => {
        const draftA = (await platformDb.list('onboarding_drafts')).find((row) => row.tenantId === tenantA);
        const invited = await api('POST', `/onboarding-drafts/${draftA.draftId}/first-admin`, {});
        equal(invited.state, 'invited', 'a new company gets an invitation');
        equal(await acceptFirstAdminInvitation(E.client(A.project), A.project, A.admin), true, 'the invited access row was accepted');
        equal((await api('POST', `/companies/${tenantA}/prepare-data`, { apply: true })).prepared, true, 'prepare counts the new administrator');
        const view = await api('GET', `/onboarding-drafts/${draftA.draftId}`);
        equal([view.next.button.id, view.doneCount], ['make_active', 7], `steps 1 to 7 are green: ${view.steps.map((step) => `${step.n}:${step.state}:${step.fact}`).join(' | ')}`);
      });
      await t.step('Make active turns company A active, and company B is not touched', async () => {
        await button(s, 'Make active').click();
        await admin.pickDropdown(s.page, 'New status', 'Active');
        await admin.pickDropdown(s.page, 'Payment that covers today', /RM /);
        await field(s, 'Reason', 'Covered by the checked payment');
        await t.shot(s, 'make-active-dialog');
        await button(s, 'Apply change').click();
        await text(s, 'Active').first().waitFor({ timeout: 40000 });
        const lifecycle = await platformDb.get('lifecycle', tenantA);
        equal(lifecycle.state, 'active', 'company A lifecycle');
        const other = await platformDb.get('lifecycle', tenantB);
        if (other && other.state === 'active') throw new Error('company B became active with company A');
        equal((await platformDb.list('payment_entries')).filter((row) => row.tenantId === tenantB).length, 0, 'company B payments');
        equal((await platformDb.list('invoices')).filter((row) => row.tenantId === tenantB).length, 0, 'company B invoices');
        await atPhone(s, 'company-active', async () => {
          await text(s, 'Active').first().waitFor({ timeout: 15000 });
        });
      });
      await t.step('the owner sets the recorded rules version to the current build from Edit company record', async () => {
        const listed = async () => (await api('GET', '/companies')).companies.find((c) => c.tenantId === tenantA);
        const stored = async () => JSON.parse((await platformDb.get('companies', tenantA)).payload);
        const first = await listed();
        const current = first.currentRulesVersion;
        if (typeof current !== 'string' || !current) throw new Error(`the server sent no current rules version: ${JSON.stringify(current)}`);
        const fields = ['tenantId', 'workspace', 'legalName', 'companyCode', 'location', 'locationKind', 'clientConfig', 'status', 'planRef',
          'releaseRing', 'rulesVersion', 'services', 'edition'];
        const old = { ...Object.fromEntries(fields.filter((f) => f in first).map((f) => [f, first[f]])), rulesVersion: 'sha-old' };
        await api('PUT', `/companies/${tenantA}`, { record: old, expectedVersion: first.version, reason: 'Record an old rules version for the test' }, 'solo-a-old-rules-0001');
        const before = await listed();
        equal([before.rulesVersion, before.currentRulesVersion], ['sha-old', current], 'the old rules version is recorded and the build value is unchanged');
        equal((await stored()).rulesVersion, 'sha-old', 'stored old rules version');
        await s.page.waitForTimeout(31000);
        await button(s, 'Companies').first().click();
        await s.page.waitForTimeout(1500);
        await button(s, new RegExp(`^${A.name}, workspace`)).click();
        await button(s, 'Technical').click();
        await text(s, /sha-old \(differs from the current build\)/).first().waitFor({ timeout: 25000 });
        await t.shot(s, 'rules-version-differs');
        await button(s, 'More actions').click();
        await s.page.getByRole('menuitem', { name: 'Edit company record…' }).click();
        const box = s.page.getByRole('checkbox', { name: /Set rules version to the current build/ });
        await box.waitFor({ timeout: 15000 });
        equal(await box.isChecked(), false, 'the rules version box starts unticked');
        await box.click();
        await s.page.getByRole('checkbox', { name: /Set rules version to the current build/, checked: true }).waitFor({ timeout: 10000 });
        await field(s, 'Reason', 'Rules version brought to the current build');
        await t.shot(s, 'edit-record-rules-ticked');
        await button(s, 'Save changes').click();
        await text(s, /matches the current build/).first().waitFor({ timeout: 40000 });
        const after = await stored();
        equal([after.rulesVersion, after.legalName, after.status], [current, before.legalName, before.status], 'stored record carries the current rules version only');
        await t.shot(s, 'rules-version-matches');
      });
    } finally {
      if (service) await service.stop();
    }
  },
};
