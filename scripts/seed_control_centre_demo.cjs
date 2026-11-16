'use strict';

const crypto = require('node:crypto');
const E = require('../e2e/lib/emulator.cjs');
const platform = require('../e2e/lib/platform.cjs');
const directory = require('../e2e/lib/platform_api.cjs');
const staff = require('../e2e/lib/staff.cjs');
const { acceptFirstAdminInvitation } = require('../e2e/lib/onboarding_ui.cjs');

const ROLE_EMAILS = { owner: 'owner@scoot.test', operator: 'ali@scoot.test', engineer: 'daniel@scoot.test' };
const PEOPLE = { cassie: 'owner', ali: 'operator', daniel: 'engineer' };
const MARKER = 'control_centre_demo_v1';
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);
const DAY = 86400000;

const USAGE = { usageSchemaVersion: 2, products: 0, activeAdmins: 0,
  seats: { salesmen: 0, supervisors: 0, admins: 0, branchManagers: 0 } };

const PACKAGES = [
  { planId: 'STARTER', name: 'Starter', edition: 'basic', sortOrder: 10, prices: [75, 900], then: [80, 960],
    limits: { salesmen: 5, supervisors: 1, admins: 1, branchManagers: 1, products: 100 } },
  { planId: 'STANDARD', name: 'Standard', edition: 'basic', sortOrder: 20, prices: [300, 3000],
    limits: { salesmen: 10, supervisors: 2, admins: 1, branchManagers: 2, products: 500 } },
  { planId: 'PROFESSIONAL', name: 'Professional', edition: 'advanced', sortOrder: 30, prices: [600, 6000],
    limits: { salesmen: 20, supervisors: 4, admins: 2, branchManagers: 3, products: 2000 } },
  { planId: 'ENTERPRISE', name: 'Enterprise', edition: 'advanced', sortOrder: 40, prices: [null, null],
    limits: { salesmen: 40, supervisors: 8, admins: 2, branchManagers: 5, products: 5000 } },
];

const COMPANIES = [
  { slug: 'santubong', name: 'Santubong Retail', plan: 'STANDARD', interval: 'yearly', age: 100, email: 'accounts@santubong.example.test', story: 'paid' },
  { slug: 'tabuan', name: 'Tabuan Jaya Store', plan: 'STANDARD', interval: 'monthly', age: 45, email: 'tan@tabuanjaya.example.test', story: 'overdue' },
  { slug: 'lundu', name: 'Lundu Village Shop', plan: 'STARTER', interval: 'monthly', age: 30, email: 'lundu.shop@example.test', story: 'cancelled' },
  { slug: 'serian', name: 'Serian Trading Co', plan: 'STARTER', interval: 'monthly', age: 25, email: 'office@seriantrading.example.test', story: 'suspended' },
  { slug: 'hardware', name: 'Hardware Client', plan: 'STANDARD', interval: 'monthly', age: 20, email: null, story: 'renewal' },
  { slug: 'miri', name: 'Miri Daily Needs', plan: 'PROFESSIONAL', interval: 'monthly', age: 20, email: 'mei@miridaily.example.test', story: 'credit' },
  { slug: 'satok', name: 'Satok Grocer', plan: 'STARTER', interval: 'monthly', age: 12, email: 'hello@satokgrocer.example.test', story: 'suspend-asked' },
  { slug: 'bau-family', name: 'Bau Family Mart', plan: 'STARTER', interval: 'monthly', age: 8, email: 'bau.family@example.test', story: 'void-then-paid' },
  { slug: 'samarahan', name: 'Samarahan Fresh Mart', plan: 'STARTER', interval: 'monthly', age: 6, email: null, story: 'paid-cassie' },
  { slug: 'kuching-mart', name: 'Kuching Mart', plan: 'STANDARD', interval: 'monthly', age: 4, email: null, story: 'first-draft' },
  { slug: 'kenyalang', name: 'Kenyalang Mini Market', plan: 'STANDARD', interval: 'monthly', age: 3.05, email: 'kenyalang@example.test', story: 'unchecked-ali' },
  { slug: 'sarawak-prov', name: 'Sarawak Provision Trading', plan: 'ENTERPRISE', interval: 'yearly', age: 2, email: 'procurement@sarawakprov.example.test', story: 'quote' },
  { slug: 'everrise', name: 'Everrise Supermarket', plan: 'STARTER', interval: 'yearly', age: 1, email: 'susan@everrise.example.test', story: 'unchecked-cassie' },
];

const stamp = (date) => `${date.toISOString().slice(0, 19)}Z`;

function requireLocal(service) {
  E.requireEmulators();
  const host = new URL(service.url).hostname;
  if (!LOOPBACK.has(host) && !LOOPBACK.has(`[${host}]`)) throw new Error(`Refusing to seed: the staff API at ${service.url} is not on a loopback address.`);
  if (!directory.PLATFORM_PROJECT.startsWith('demo-')) throw new Error('Refusing to seed: the platform project is not a demo project.');
}

function pythonEnv(key) {
  return {
    ...process.env, PYTHONUTF8: '1', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT,
    PLATFORM_PUBLIC_KEYS: platform.publicKeysText(key), PLATFORM_SIGNING_KEY_ID: key.keyId, PLATFORM_SIGNING_KEY: key.seed,
    ...directory.mailEnv(), PLATFORM_EMULATOR_PROJECTS: 'cos40005,hardware-client-sales',
  };
}

async function startDemoStaffApi(key, { port, browserSignIn = false }) {
  const overrides = { ...directory.mailEnv(), PLATFORM_FINANCE_EMAIL: 'finance@scootsales.example.test' };
  const keep = Object.fromEntries(Object.keys(overrides).map((name) => [name, process.env[name]]));
  Object.assign(process.env, overrides);
  try {
    return await staff.startStaffApi(key, { port, roleEmails: ROLE_EMAILS, browserSignIn, scheduler: false, e2eReaders: true });
  } finally {
    for (const [name, value] of Object.entries(keep)) {
      if (value === undefined) delete process.env[name];
      else process.env[name] = value;
    }
  }
}

async function seedDemo({ service, key, log = console.log }) {
  requireLocal(service);
  const platformDb = E.client(directory.PLATFORM_PROJECT);
  const env = pythonEnv(key);
  const helper = (command, args) => {
    const out = platform.python(['scripts/control_centre_demo_time.py', command], { input: JSON.stringify(args), env });
    return JSON.parse(out.trim().split(/\r?\n/).pop());
  };
  const call = async (person, method, route, body, idempotencyKey) => {
    const response = await fetch(`${service.url}/staff/v1${route}`, {
      method,
      headers: { 'Content-Type': 'application/json', ...service.headers(PEOPLE[person]),
        Origin: service.url, 'Sec-Fetch-Site': 'same-origin', ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
      body: body === undefined ? undefined : JSON.stringify(body),
    });
    const text = await response.text();
    if (!response.ok) {
      const refusal = /"refusal":"([^"]*)"/.exec(text);
      throw new Error(`${person} ${method} ${route} -> ${response.status} ${refusal ? `refused: ${refusal[1]} ` : ''}${text.slice(0, 400)}`);
    }
    return text ? JSON.parse(text) : {};
  };
  const once = async (name, work) => {
    const done = await platformDb.get('demo_seed', name.replace(/[^A-Za-z0-9_-]/g, '_'));
    if (done) return JSON.parse(done.result);
    const result = (await work()) ?? null;
    await platformDb.put('demo_seed', name.replace(/[^A-Za-z0-9_-]/g, '_'), { result: JSON.stringify(result), at: new Date() });
    return result;
  };
  const ask = (person, action, tenantId, reason, params, idempotencyKey) =>
    call(person, 'POST', '/approvals', { action, ...(tenantId ? { tenantId } : {}), reason, params }, idempotencyKey);
  const decide = (person, approval) => call(person, 'POST', `/approvals/${approval.approvalId}/approve`);

  if (await platformDb.get('demo_seed', MARKER)) {
    log('Control Centre demo data is already in place. Nothing was added.');
    return summarise({ call, platformDb });
  }

  const bankDate = () => {
    const kl = new Date(Date.now() + 8 * 3600000);
    return stamp(new Date(Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate()) - 8 * 3600000));
  };

  await once('packages', async () => {
    for (const pack of PACKAGES) {
      const body = (prices) => ({
        name: pack.name, edition: pack.edition, limits: pack.limits, quotaSchemaVersion: 2, features: {}, notes: '',
        prices: { currency: 'MYR', monthly: prices[0], yearly: prices[1] }, tagline: '', highlights: [],
        sortOrder: pack.sortOrder, visibility: 'public', reason: `Create the ${pack.name} package`,
      });
      const key = pack.planId.toLowerCase();
      const raise = async (prices, note, creating = false) => {
        const { visibility, reason, ...version } = body(prices);
        const [asker, decider] = creating ? ['cassie', 'ali'] : ['ali', 'cassie'];
        const request = await ask(asker, 'package.price', null, note, { planId: pack.planId, version, visibility }, `demo-price-${key}-${prices[0]}`);
        await decide(decider, request);
      };
      try {
        await call('cassie', 'PUT', `/plans/${pack.planId}`, body(pack.prices), `demo-plan-${key}`);
        if (pack.then) await raise(pack.then, 'New price list from 1 December');
      } catch (error) {
        if (!/package\.price/.test(error.message)) throw error;
        await raise(pack.then || pack.prices, 'Set the price list for the first invoices', true);
      }
    }
    for (const planId of ['GROWTH', 'PRO', 'SCALE']) {
      await call('cassie', 'POST', `/plans/${planId}/retire`, { reason: 'Replaced by the four current packages' }, `demo-retire-${planId.toLowerCase()}`)
        .catch((error) => { if (!/404/.test(error.message)) throw error; });
    }
  });
  log('  packages: Starter, Standard, Professional, Enterprise');

  const lifecycleOf = async (c) => (await call('ali', 'GET', `/companies/${c.tenantId}/lifecycle`).catch(() => null));
  const invoiceView = (invoice) => ({ id: invoice.invoiceId, periodEnd: stamp(new Date(invoice.periodEnd)), amount: invoice.amountMinor });
  const billInvoice = async (c, name, { send = true, periodStart } = {}) => {
    const draft = await call('ali', 'POST', `/companies/${c.tenantId}/invoices`, periodStart ? { periodStart } : {}, `demo-${c.slug}-${name}-draft`);
    const issued = await call('ali', 'POST', `/invoices/${draft.invoiceId}/issue`);
    const sent = send && c.email ? await call('ali', 'POST', `/invoices/${draft.invoiceId}/send`) : issued;
    return invoiceView(sent);
  };
  const pay = async (c, name, invoice, recorder, reference) => {
    const entry = await call(recorder, 'POST', `/companies/${c.tenantId}/payments`, {
      amountMinor: invoice.amount, currency: 'MYR', externalReference: reference, invoiceId: invoice.id,
      receivedAt: bankDate(), reason: 'Bank statement checked',
    }, `demo-${c.slug}-${name}-pay`);
    return entry.entryId;
  };
  const activate = async (c, person, entryId) => {
    await call('ali', 'POST', `/onboarding-drafts/${c.draftId}/first-admin`, {});
    if (!(await acceptFirstAdminInvitation(E.client(`demo-cc-${c.slug}`), `demo-cc-${c.slug}`, `admin@${c.slug}.example.test`))) {
      throw new Error(`No pending administrator invitation for ${c.name}`);
    }
    const state = await lifecycleOf(c);
    const revision = state && state.lifecycle ? state.lifecycle.revision : 0;
    await call(person, 'PUT', `/companies/${c.tenantId}/lifecycle`, {
      state: 'active', expectedRevision: revision, paymentEntryId: entryId, reason: 'First payment received', ticket: null,
    }, `demo-${c.slug}-active`);
  };
  const lifecycleRevision = async (c) => (await lifecycleOf(c)).lifecycle.revision;
  const reference = (c, name) => {
    const code = { santubong: 'PBB', tabuan: 'MBB', lundu: 'HLB', serian: 'RHB', hardware: 'MBB', miri: 'CIMB', satok: 'BSN',
      'bau-family': 'RHB', samarahan: 'AMB', 'kuching-mart': 'MBB', kenyalang: 'CIMB', 'sarawak-prov': 'HSBC', everrise: 'MBB' }[c.slug];
    const digits = parseInt(crypto.createHash('sha256').update(`${c.slug}-${name}`).digest('hex').slice(0, 6), 16) % 90000 + 10000;
    return `${code}-${digits}`;
  };

  const ages = {};
  for (const c of COMPANIES) {
    const result = await once(`company-${c.slug}`, async () => {
      const db = E.client(`demo-cc-${c.slug}`);
      await db.reset();
      await db.put('config', 'usage', USAGE);
      const draft = await call('ali', 'POST', '/onboarding-drafts', {
        legalName: c.name, workspace: c.slug, planId: c.plan, billingInterval: c.interval,
        adminName: `${c.name} Administrator`, adminEmployeeCode: 'ADM001', adminEmail: `admin@${c.slug}.example.test`,
        billingEmail: c.email || `billing.pending@${c.slug}.example.test`,
      }, `demo-draft-${c.slug}`);
      const connected = await call('daniel', 'POST', `/onboarding-drafts/${draft.draftId}/connect`, { projectId: `demo-cc-${c.slug}` });
      const tenantId = (await call('cassie', 'GET', `/onboarding-drafts/${draft.draftId}`)).tenantId;
      if (!tenantId) throw new Error(`No company was created for ${c.name}`);
      c.tenantId = tenantId;
      c.draftId = draft.draftId;
      if (!c.email) {
        const clear = await ask('ali', 'billing_email.change', tenantId, 'The client has not given a billing address', { billingEmail: null }, `demo-${c.slug}-no-billing-email`);
        await decide('cassie', clear);
      }
      const prepared = await call('cassie', 'POST', `/companies/${tenantId}/prepare-data`, { apply: true });
      if (!prepared.prepared) throw new Error(`Company data was not prepared for ${c.name}`);
      await call('ali', 'POST', `/companies/${tenantId}/package`,
        { planId: c.plan, billingInterval: c.interval, expectedRevision: 0, reason: 'New company' }, `demo-package-${c.slug}`);
      const out = { tenantId, invoices: {} };
      const { story } = c;
      if (['paid', 'paid-cassie', 'overdue', 'cancelled', 'suspended', 'renewal', 'credit', 'suspend-asked'].includes(story)) {
        const invoice = await billInvoice(c, 'first');
        const recorder = story === 'paid-cassie' ? 'cassie' : 'ali';
        const entry = await pay(c, 'first', invoice, recorder, reference(c, 'first'));
        await call(recorder === 'ali' ? 'cassie' : 'ali', 'POST', `/companies/${c.tenantId}/payments/${entry}/check`);
        await activate(c, 'ali', entry);
        out.invoices.first = invoice;
      }
      if (story === 'overdue') {
        const second = await billInvoice(c, 'renewal', { periodStart: out.invoices.first.periodEnd });
        out.invoices.renewal = second;
      }
      if (story === 'void-then-paid') {
        const invoice = await billInvoice(c, 'first');
        const wrong = await pay(c, 'wrong', invoice, 'ali', `${reference(c, 'wrong')}-X`);
        const voided = await ask('ali', 'payment.void', c.tenantId, 'Wrong bank reference typed', { receiptId: wrong }, `demo-${c.slug}-void`);
        await decide('cassie', voided);
        const entry = await pay(c, 'right', invoice, 'ali', reference(c, 'right'));
        await call('cassie', 'POST', `/companies/${c.tenantId}/payments/${entry}/check`);
        await activate(c, 'ali', entry);
        out.invoices.first = invoice;
      }
      if (story === 'unchecked-ali' || story === 'unchecked-cassie') {
        const recorder = story === 'unchecked-ali' ? 'ali' : 'cassie';
        const first = await billInvoice(c, 'first');
        const entry = await pay(c, 'first', first, recorder, reference(c, 'first'));
        await call(recorder === 'ali' ? 'cassie' : 'ali', 'POST', `/companies/${c.tenantId}/payments/${entry}/check`);
        await activate(c, 'ali', entry);
        helper('age', { tenantId: c.tenantId, days: Math.ceil((new Date(first.periodEnd).getTime() - Date.now()) / DAY) });
        const aged = await call('ali', 'GET', `/invoices/${first.id}`);
        const renewal = await billInvoice(c, 'renewal', { periodStart: aged.periodEnd });
        await pay(c, 'renewal', renewal, recorder, story === 'unchecked-ali' ? 'CIMB-120934' : 'MBB-88213');
        out.invoices.first = first;
        out.invoices.renewal = renewal;
      }
      if (story === 'first-draft') {
        const draft = await call('ali', 'POST', `/companies/${c.tenantId}/invoices`, {}, `demo-${c.slug}-first-draft`);
        out.invoices.first = { id: draft.invoiceId };
      }
      return out;
    });
    c.tenantId = result.tenantId;
    c.result = result;
    ages[c.tenantId] = c.age;
  }
  log(`  companies: ${COMPANIES.length} created through the staff API`);

  for (const c of COMPANIES) {
    await once(`age-${c.slug}`, async () => {
      const invoiceDays = {};
      if (c.story === 'overdue') invoiceDays[c.result.invoices.renewal.id] = 16;
      helper('age', { tenantId: c.tenantId, days: c.age, invoiceDays });
    });
  }
  log('  time: payments, invoices and statuses moved back to match each story');

  await once('requests', async () => {
    const hardware = COMPANIES.find((c) => c.slug === 'hardware');
    await platformDb.put('plan_requests', 'req_democontrolcentre01', {
      tenantId: hardware.tenantId, planId: 'PROFESSIONAL', interval: 'monthly', status: 'requested',
      requestedBy: 'demo-company-administrator', createdAt: new Date(Date.now() - 2 * 3600000) });
    const sarawak = COMPANIES.find((c) => c.slug === 'sarawak-prov');
    await ask('ali', 'quote.price', sarawak.tenantId, 'Quote agreed on a call with the buyer',
      { amountMinor: 2400000, billingInterval: 'yearly' }, 'demo-sarawak-quote');
    const satok = COMPANIES.find((c) => c.slug === 'satok');
    await ask('ali', 'lifecycle.suspend', satok.tenantId, 'Two invoices unpaid and no answer from the company',
      { expectedRevision: await lifecycleRevision(satok) }, 'demo-satok-suspend');
  });
  await once('endings', async () => {
    for (const [slug, action, label, why] of [
      ['lundu', 'lifecycle.cancel', 'cancel', 'The company closed its shop'],
      ['serian', 'lifecycle.suspend', 'suspend', 'Unpaid for two months'],
    ]) {
      const c = COMPANIES.find((item) => item.slug === slug);
      const request = await ask('ali', action, c.tenantId, why, { expectedRevision: await lifecycleRevision(c) }, `demo-${slug}-${label}`);
      await decide('cassie', request);
    }
  });
  log('  approvals: price change, cancel and suspend decided; suspend and quote waiting for Cassie');

  await once('drafts', async () => {
    const open = [
      { slug: 'penrissen', name: 'Penrissen Wholesale', plan: 'STANDARD', interval: 'monthly', email: 'accounts@penrissen.example.test', admin: 'Rose Anak Jimbun' },
      { slug: 'stutong', name: 'Stutong Mini Mart', plan: 'STARTER', interval: 'yearly', email: null, admin: null },
      { slug: 'sibu-central', name: 'Sibu Central Grocer', plan: 'PROFESSIONAL', interval: 'monthly', email: 'finance@sibucentral.example.test', admin: null },
    ];
    for (const d of open) {
      await call('ali', 'POST', '/onboarding-drafts', {
        legalName: d.name, workspace: d.slug, planId: d.plan, billingInterval: d.interval,
        ...(d.email ? { billingEmail: d.email } : {}),
        ...(d.admin ? { adminName: d.admin, adminEmail: `admin@${d.slug}.example.test` } : {}),
      }, `demo-draft-${d.slug}`);
    }
  });
  log('  onboarding: three open drafts at different stages');

  await once('scheduler', async () => helper('jobs', { jobs: ['past_due', 'invoice_drafts'] }));
  log('  scheduler: past due and renewal drafts run on the real jobs');

  await once('mail-first', async () => {
    const everrise = COMPANIES.find((c) => c.slug === 'everrise');
    helper('enqueue', { tenantId: everrise.tenantId, key: 'demo-everrise-invitation', kind: 'invitation',
      recipient: 'sales.admin@everrise.example.test', actor: ROLE_EMAILS.engineer,
      payload: { tenantId: everrise.tenantId, companyName: everrise.name, inviteUrl: 'https://dashboard.scootsales.test/invite#invite=demo',
        expiresAt: '2030-01-01T00:00:00Z' } });
    helper('mail', { reject: { 'sales.admin@everrise.example.test': { retryable: true, rounds: 5 } } });
    helper('agemail', { tenantId: everrise.tenantId, kind: 'invitation', hours: 5 });
  });

  await once('miri', async () => {
    const c = COMPANIES.find((item) => item.slug === 'miri');
    const invoices = (await call('ali', 'GET', `/invoices?tenantId=${c.tenantId}`)).invoices;
    const draft = invoices.find((invoice) => invoice.status === 'draft');
    if (!draft) throw new Error('The renewal draft for Miri Daily Needs was not created.');
    await call('ali', 'POST', `/invoices/${draft.invoiceId}/issue`);
    await call('ali', 'POST', `/invoices/${draft.invoiceId}/send`);
    const credit = await ask('ali', 'invoice.credit_note', c.tenantId, 'Goodwill credit for a late delivery',
      { invoiceId: draft.invoiceId, amountMinor: 5000 }, 'demo-miri-credit');
    await decide('cassie', credit);
    helper('mail', { reject: { [c.email]: { retryable: false, rounds: 1 } } });
    helper('agemail', { tenantId: c.tenantId, kind: 'invoice', hours: 20 });
  });
  log('  mail: queued mail delivered locally; one invitation and one invoice email failed');

  await once('audit', async () => {
    const result = helper('audit', { ages, default: 14 });
    if (result.broken.length) throw new Error(`The audit chain is broken on ${result.broken.join(', ')}`);
    return result;
  });
  await platformDb.put('demo_seed', MARKER, { at: new Date() });
  log('  audit: events spread over the weeks and the hash chain re-verified');
  return summarise({ call, platformDb });
}

async function summarise({ call, platformDb }) {
  const companies = (await call('daniel', 'GET', '/companies')).companies;
  const states = {};
  for (const company of companies) {
    const state = (await call('ali', 'GET', `/companies/${company.tenantId}/lifecycle`).catch(() => ({ lifecycle: { state: 'not_started' } })))
      .lifecycle.state;
    states[state] = (states[state] || 0) + 1;
  }
  const invoices = (await call('ali', 'GET', '/invoices')).invoices;
  const byStatus = {};
  for (const invoice of invoices) byStatus[invoice.status] = (byStatus[invoice.status] || 0) + 1;
  const waiting = (await call('ali', 'GET', '/payments/to-check')).payments.length;
  const approvals = (await call('cassie', 'GET', '/approvals?status=requested')).approvals.length;
  const audit = await call('ali', 'GET', '/audit-events?limit=200');
  const summary = { companies: companies.length, lifecycle: states, invoices: byStatus, paymentsToCheck: waiting,
    approvalsWaiting: approvals, auditEventsInRange: audit.events.length };
  console.log(`Control Centre demo data: ${JSON.stringify(summary)}`);
  return summary;
}

module.exports = { ROLE_EMAILS, PEOPLE, COMPANIES, MARKER, startDemoStaffApi, seedDemo };

if (require.main === module) {
  (async () => {
    const key = platform.ensureKey();
    E.requireEmulators();
    const service = await startDemoStaffApi(key, { port: Number(process.env.DEMO_STAFF_PORT || 18797) });
    try {
      await seedDemo({ service, key });
    } finally {
      await service.stop();
    }
  })().catch((error) => {
    console.error(error.message);
    process.exit(1);
  });
}
