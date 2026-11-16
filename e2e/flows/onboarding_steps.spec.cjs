'use strict';

const crypto = require('node:crypto');
const fs = require('node:fs');
const path = require('node:path');
const E = require('../lib/emulator.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { seedLegacyCompany } = require('../lib/legacy_company_fixture.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'onboarding_steps');
const EXISTING_PROJECT = E.PROJECT;
const NEW_PROJECT = `demo-onbnew-${crypto.randomBytes(3).toString('hex')}`;
const HARNESS_TENANT = 't_cos40005';
const EMAILS = { owner: 'e2e.owner@example.test', operator: 'e2e.operator@example.test', engineer: 'e2e.engineer@example.test', support: 'e2e.support@example.test' };

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


module.exports = {
  name: 'onboarding_steps',
  platformApi: true,
  async run(t) {
    fs.mkdirSync(OUT, { recursive: true });
    const evidence = { walks: {} };
    const lines = [];
    const key = platform.ensureKey();
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    let service;

    const call = async (who, method, route, body, idem) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, {
        method,
        headers: { 'Content-Type': 'application/json', Connection: 'close', ...service.headers(who), Origin: service.url, 'Sec-Fetch-Site': 'same-origin', ...(idem ? { 'Idempotency-Key': idem } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await response.text();
      return { status: response.status, body: text ? JSON.parse(text) : {} };
    };
    const api = async (who, method, route, body, idem) => {
      const reply = await call(who, method, route, body, idem);
      if (reply.status >= 400) throw new Error(`${method} ${route} -> ${reply.status} ${JSON.stringify(reply.body)}`);
      return reply.body;
    };
    const refused = async (what, who, method, route, body, idem, mustInclude) => {
      const reply = await call(who, method, route, body, idem);
      expectEqual(reply.status, 409, `${what}: status`);
      expectTrue(String(reply.body.detail).includes(mustInclude), `${what}: ${JSON.stringify(reply.body)} should include "${mustInclude}"`);
      lines.push(`  refused: ${what} -> ${reply.body.detail}`);
    };

    const show = async (walk, label, draftId) => {
      const view = await api('owner', 'GET', `/onboarding-drafts/${draftId}`);
      const rows = view.steps.map((s) => `  ${s.n}. ${s.label.padEnd(20)} ${s.state.toUpperCase().padEnd(5)} ${s.unknown ? '(unknown) ' : ''}${s.fact}${s.button ? `  [${s.button.label}]` : ''}`);
      const head = `[${walk}] ${label} - ${view.doneCount} of ${view.total} green, phase ${view.phase}, kind ${view.kind}, next: ${view.next ? `${view.next.n} ${view.next.button ? view.next.button.label : '-'}` : 'none'}`;
      lines.push(head, ...rows);
      console.log([head, ...rows].join('\n'));
      (evidence.walks[walk] = evidence.walks[walk] || []).push({ label, view });
      fs.writeFileSync(path.join(OUT, 'evidence.json'), JSON.stringify(evidence, null, 2));
      fs.writeFileSync(path.join(OUT, 'steps.txt'), `${lines.join('\n')}\n`);
      return view;
    };
    const stateOf = (view, key2) => view.steps.find((s) => s.key === key2).state;

    const finishMoney = async (walk, tenant, draftId, tag) => {
      await refused(`${walk} invoice before the package is green`, 'operator', 'POST', `/companies/${tenant}/invoices`, {}, `${tag}-inv-early`, 'Step');
      await api('operator', 'POST', `/companies/${tenant}/package`, { planId: 'STANDARD', billingInterval: 'monthly', expectedRevision: 0, reason: 'First package' }, `${tag}-package`).catch(async (error) => {
        if (!String(error.message).includes('already')) throw error;
      });
      await show(walk, 'after Apply package', draftId);
      const quote = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: tenant, reason: 'Agreed price', params: { amountMinor: 50000, billingInterval: 'monthly' } }, `${tag}-quote`);
      await api('owner', 'POST', `/approvals/${quote.approvalId}/approve`);
        const draft = await api('operator', 'POST', `/companies/${tenant}/invoices`, {}, `${tag}-invoice`);
      const drafted = await show(walk, 'after Create first invoice (draft)', draftId);
      expectEqual(drafted.next.button.id, 'issue_invoice', 'next button is Issue invoice while the invoice is a draft');
      const invoice = await api('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);
      await show(walk, 'after the first invoice', draftId);
      const paid = await api('operator', 'POST', `/companies/${tenant}/payments`, {
        amountMinor: invoice.amountMinor, currency: 'MYR', externalReference: `ONB/${tag}`, invoiceId: invoice.invoiceId, receivedAt: klMidnightUtc(), reason: 'Bank statement checked',
      }, `${tag}-payment`);
      await show(walk, 'after Record payment', draftId);
      await api('owner', 'POST', `/companies/${tenant}/payments/${paid.entryId}/check`);
      return paid;
    };

    try {
    await t.step('1. start the staff service and clear the harness company', async () => {
      for (const claim of await platformDb.list('company_claims')) {
        if (claim.tenantId === HARNESS_TENANT) await platformDb.del('company_claims', claim.id);
      }
      await platformDb.del('companies', HARNESS_TENANT);
      directory.planAdmin([key], [{ op: 'catalogue' }]);
      process.env.PLATFORM_EMULATOR_PROJECTS = EXISTING_PROJECT;
      process.env.PLATFORM_INVITE_SECRET = crypto.randomBytes(32).toString('base64url');
      service = await staff.startStaffApi(key, { roleEmails: EMAILS, browserSignIn: false, scheduler: false, e2eReaders: true });
    });

    await t.step('2. New company: an empty Firebase project, walked step by step', async () => {
      const walk = 'new';
      const newDb = E.client(NEW_PROJECT);
      await newDb.reset();
      const draft = await api('operator', 'POST', '/onboarding-drafts', {
        legalName: 'Onboard New Sdn Bhd', workspace: 'onbnew', planId: 'STANDARD', billingInterval: 'monthly',
        billingEmail: 'billing@onbnew.example', adminName: 'Nina New', adminEmail: 'nina.new@example.test', adminEmployeeCode: 'ADM001',
      }, 'onb-new-draft');
      const draftId = draft.draftId;
      const first = await show(walk, 'draft created', draftId);
      expectEqual([first.doneCount, stateOf(first, 'project')], [1, 'red'], 'a new draft has only the details step green');
      const done = await api('engineer', 'POST', `/onboarding-drafts/${draftId}/connect`, { projectId: NEW_PROJECT });
      expectTrue(!done.refusal, `connect refusal: ${done.refusal}`);
      const tenant = (await api('owner', 'GET', `/onboarding-drafts/${draftId}`)).tenantId;
      expectTrue(tenant, 'the draft names the company after Connect');
      const connected = await show(walk, 'after Connect project', draftId);
      expectEqual([stateOf(connected, 'project'), connected.kind], ['green', 'new'], 'project step and kind after connect');
      await refused('apply the package before people and data are green', 'operator', 'POST', `/companies/${tenant}/package`, { planId: 'STANDARD', billingInterval: 'monthly', expectedRevision: 0, reason: 'Too early' }, 'onb-new-pkg-early', 'steps 1 to 3');
      const prepared = await api('owner', 'POST', `/companies/${tenant}/prepare-data`, { apply: true });
      expectTrue(prepared.prepared, 'prepare reports prepared');
      await show(walk, 'after Prepare company data', draftId);
      await finishMoney(walk, tenant, draftId, 'onbnew');
      const afterCheck = await show(walk, 'after Check payment', draftId);
      expectEqual(stateOf(afterCheck, 'payment'), 'green', 'payment step after the check');
      const invited = await api('operator', 'POST', `/onboarding-drafts/${draftId}/first-admin`, {});
      expectEqual(invited.state, 'invited', 'a new company gets an invitation');
      const afterAdmin = await show(walk, 'after Give access (invitation sent)', draftId);
      expectEqual(stateOf(afterAdmin, 'admin'), 'red', 'admin step waits for the person');
      expectEqual(stateOf(afterAdmin, 'rules'), 'grey', 'rules step is not read while step 6 is red');
      await refused('make active while steps are not green', 'operator', 'PUT', `/companies/${tenant}/lifecycle`, { state: 'active', expectedRevision: 1, paymentEntryId: 'pay_' + '0'.repeat(64), reason: 'Try to open early', ticket: 'ONB-1' }, 'onb-new-open', 'steps 1 to 7');
      const final = await show(walk, 'final', draftId);
      expectEqual(final.phase, 'setup', 'a company with red steps is in Setting up');
    });

    await t.step('3. Existing company: a project with people, kept uids, a swapped row', async () => {
      const walk = 'existing';
      const hdb = E.client(EXISTING_PROJECT);
      const seeded = await seedLegacyCompany(hdb, hdb, { shapes: ['swappedRow'] });
      const draft = await api('operator', 'POST', '/onboarding-drafts', {
        legalName: 'Onboard Existing Sdn Bhd', workspace: 'onbold', planId: 'STANDARD', billingInterval: 'monthly',
        billingEmail: 'billing@onbold.example', adminName: seeded.people.admin.name, adminEmail: seeded.people.admin.email, adminEmployeeCode: seeded.people.admin.code,
      }, 'onb-old-draft');
      const draftId = draft.draftId;
      await show(walk, 'draft created', draftId);
      const done = await api('engineer', 'POST', `/onboarding-drafts/${draftId}/connect`, { projectId: EXISTING_PROJECT });
      expectTrue(!done.refusal, `connect refusal: ${done.refusal}`);
      const tenant = (await api('owner', 'GET', `/onboarding-drafts/${draftId}`)).tenantId;
      expectTrue(tenant, 'the draft names the company after Connect');
      const connected = await show(walk, 'after Connect project', draftId);
      expectEqual([stateOf(connected, 'project'), connected.kind], ['green', 'existing'], 'project step and kind after connect');
      expectEqual(stateOf(connected, 'people'), 'red', 'people step is red for a project with a swapped row');
      expectEqual(connected.next.button.id, 'prepare', 'next button is Prepare company data');
      const prepared = await api('owner', 'POST', `/companies/${tenant}/prepare-data`, { apply: true });
      expectTrue(prepared.prepared, 'prepare reports prepared');
      const afterPrepare = await show(walk, 'after Prepare company data', draftId);
      expectEqual(stateOf(afterPrepare, 'people'), 'green', 'people step after Prepare');
      const paid = await finishMoney(walk, tenant, draftId, 'onbold');
      await show(walk, 'after Check payment', draftId);
      const granted = await api('operator', 'POST', `/onboarding-drafts/${draftId}/first-admin`, {});
      expectEqual([granted.state, granted.uid], ['active', seeded.uids.admin], 'the old admin account keeps its uid and becomes the administrator');
      const afterAdmin = await show(walk, 'after Give access', draftId);
      expectEqual(stateOf(afterAdmin, 'admin'), 'green', 'admin step reads the live access row');
      expectEqual(stateOf(afterAdmin, 'rules'), 'green', 'rules step reads the emulator rules');
      expectEqual(afterAdmin.next.button.id, 'make_active', 'next button is Open the company');
      const lifecycle = await api('operator', 'GET', `/companies/${tenant}/lifecycle`);
      await api('operator', 'PUT', `/companies/${tenant}/lifecycle`, { state: 'active', expectedRevision: lifecycle.lifecycle.revision, paymentEntryId: paid.entryId, reason: 'All steps green', ticket: 'ONB-OLD' }, 'onb-old-open');
      const opened = await show(walk, 'after Open', draftId);
      expectEqual([opened.doneCount, opened.total, opened.phase, stateOf(opened, 'open')], [8, 8, 'working', 'green'], 'all eight steps green and the company open');
    });

    await t.step('4. the list and one draft show the same count', async () => {
      const listed = (await api('owner', 'GET', '/onboarding-drafts')).drafts;
      expectEqual(listed.length, 2, 'two drafts listed');
      for (const row of listed) {
        const single = await api('owner', 'GET', `/onboarding-drafts/${row.draftId}`);
        expectEqual([row.doneCount, row.total], [single.doneCount, single.total], `count for ${row.workspace}`);
      }
    });

    } finally {
      if (service) await service.stop();
    }
  },
};
