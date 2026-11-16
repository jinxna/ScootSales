'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const E = require('../lib/emulator.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const OWNER = 'e2e.first.owner@example.test';
const PAGES = [
  ['Inbox', 'Nothing is waiting'],
  ['Companies', /No companies|Add company/],
  ['Payments', /No payments/],
  ['Invoices', /No invoices|New invoice/],
  ['Packages', 'No packages'],
  ['Onboarding', 'No company is being set up'],
  ['Staff and access', null],
  ['Audit log', null],
  ['Settings', null],
];
const FAULT_TEXT = /something went wrong|failed to load|could not load|couldn'?t load|not available to your role|access denied|an error occurred|permission[- ]denied/i;

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

module.exports = {
  name: 'first_use_empty',
  platformApi: false,
  async run(t) {
    const key = platform.ensureKey();
    await directory.resetDirectory();
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const sink = await startMailSink();
    await sink.clear();
    const keep = process.env.PLATFORM_STAFF_BOOTSTRAP_OWNERS;
    process.env.PLATFORM_STAFF_BOOTSTRAP_OWNERS = OWNER;
    let service;
    try {
      service = await staff.startStaffApi(key, { roleEmails: {}, extraEmails: { owner: OWNER }, browserSignIn: true, scheduler: false });
    } finally {
      if (keep === undefined) delete process.env.PLATFORM_STAFF_BOOTSTRAP_OWNERS;
      else process.env.PLATFORM_STAFF_BOOTSTRAP_OWNERS = keep;
    }
    const button = (s, name) => s.page.getByRole('button', { name, exact: typeof name === 'string' });
    const text = (s, value) => s.page.getByText(value, { exact: typeof value === 'string' });
    const visibleText = async (s) => s.page.evaluate(() => document.body.innerText || '').catch(() => '');
    let s;
    try {
      await t.step('the project holds no staff, package, company or invoice before the owner signs in', async () => {
        for (const collection of ['staff', 'companies', 'plans', 'invoices', 'payment_entries', 'onboarding_drafts']) {
          const rows = await platformDb.list(collection).catch(() => []);
          equal(rows.length, 0, `${collection} rows before sign-in`);
        }
      });
      await t.step('the owner signs in with password and mailed code and reaches the Control Centre', async () => {
        s = await t.session('admin', { name: 'control-first-owner' });
        await s.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const response = await route.fetch({ url: `${service.url}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host } }).catch(() => null);
          if (!response) return route.abort('failed').catch(() => null);
          return route.fulfill({ response });
        });
        await B.openApp(s.page, t.urls.admin);
        await staff.signInControlCentre(s.page, OWNER, sink, new Set());
        await text(s, 'Control Centre').first().waitFor({ timeout: 25000 });
        await s.page.getByText(OWNER, { exact: false }).first().waitFor({ timeout: 15000 });
        await t.shot(s, 'owner-first-start');
      });
      await t.step('the store holds exactly one active owner, created from the bootstrap list', async () => {
        const rows = await platformDb.list('staff');
        equal(rows.map((r) => [r.email, r.role, r.status]), [[OWNER, 'owner', 'active']], 'staff after first sign-in');
      });
      await t.step('every page opens on its empty state with no error text', async () => {
        for (const [label, expected] of PAGES) {
          await button(s, new RegExp(`^${label}(,|$)`)).first().click({ timeout: 15000 });
          await s.page.waitForTimeout(1500);
          const body = await visibleText(s);
          const lines = (await admin.semanticsLines(s.page)).join('\n');
          const seen = `${body}\n${lines}`;
          if (FAULT_TEXT.test(seen)) throw new Error(`${label} shows an error: ${(FAULT_TEXT.exec(seen) || [])[0]}`);
          if (expected && !(expected instanceof RegExp ? expected.test(seen) : seen.includes(expected))) {
            throw new Error(`${label} does not show its empty state ${expected}`);
          }
          await t.shot(s, `empty-${label.toLowerCase().replace(/[^a-z]+/g, '-')}`);
        }
      });
      await t.step('the owner adds the first package from the Packages page', async () => {
        await button(s, /^Packages(,|$)/).first().click();
        await button(s, 'Add package').click();
        const field = (label, value) => B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
        await field('Package name', 'First Starter');
        for (const [label, value] of [['Salespeople allowed', '5'], ['Supervisors allowed', '1'], ['Admins allowed', '1'],
          ['Branch managers allowed', '1'], ['Products allowed', '100'], ['Monthly price (RM)', '300'],
          ['Yearly price (RM)', '3000'], ['Reason', 'First package of a new project']]) await field(label, value);
        await button(s, 'Add package').last().click();
        await text(s, 'The package was added.').waitFor({ timeout: 40000 });
        await text(s, 'First Starter').first().waitFor({ timeout: 25000 });
        await t.shot(s, 'first-package');
        const plans = await platformDb.list('plans');
        equal(plans.map((p) => p.planId), ['FIRST_STARTER'], 'stored package');
      });
      await t.step('the owner starts the first company draft from Onboarding', async () => {
        await button(s, /^Onboarding(,|$)/).first().click();
        await button(s, 'Add company').first().click();
        for (const [label, value] of Object.entries({ 'Company name': 'First Use Trading', 'Workspace code': 'FIRST-USE',
          'First administrator name': 'First Admin', 'First administrator email': 'first.admin@example.test' })) {
          await B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
        }
        await s.page.getByRole('button', { name: /^Package\b/ }).first().click();
        await s.page.getByRole('menuitem', { name: 'First Starter', exact: true }).first().click();
        await button(s, 'Create draft').click();
        await text(s, 'Draft created').waitFor({ timeout: 30000 });
        await t.shot(s, 'first-draft');
        const drafts = await platformDb.list('onboarding_drafts');
        equal(drafts.map((d) => [d.workspace, d.planId, d.createdBy]), [['first-use', 'FIRST_STARTER', OWNER]], 'stored draft');
        await button(s, 'Open checklist').click();
        await text(s, 'Next: step 1, Company details').waitFor({ timeout: 25000 });
      });
      await t.step('the audit log shows the first owner, the first package and the first draft, all by the owner', async () => {
        await button(s, /^Audit log(,|$)/).first().click();
        await s.page.waitForTimeout(1500);
        const lines = (await admin.semanticsLines(s.page)).join('\n');
        for (const expected of ['The first owner was created from the bootstrap list.', 'Onboarding draft for First Use Trading was started.',
          `${OWNER} started package save.`]) {
          if (!lines.includes(expected)) throw new Error(`the audit log does not show: ${expected}`);
        }
        await t.shot(s, 'audit-after-first-use');
      });
    } finally {
      if (service) await service.stop();
    }
  },
};
