'use strict';

const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const seed = require('../../scripts/seed_control_centre_demo.cjs');
const staff = require('../lib/staff.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const STAFF_PORT = 18892;
const FIRST_ADDRESS = 'kuching.accounts@example.test';
const CORRECTED_ADDRESS = 'kuching.corrected@example.test';
const THIRD_ADDRESS = 'kuching.third@example.test';
const FOURTH_ADDRESS = 'kuching.fourth@example.test';
const FINANCE_ADDRESS = 'finance@scootsales.example.test';
const WIDTHS = [390, 2000];
const DESKTOP = { width: 1600, height: 1000 };
const DAY = 86400000;

const equal = (actual, expected, label) => {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
};

const dayOf = (value) => new Date(value).toISOString().slice(0, 10);

module.exports = {
  name: 'p1_billing',
  platformApi: false,
  async run(t) {
    const outDir = path.join(E.OUTPUT_DIR, 'p1_billing');
    fs.mkdirSync(outDir, { recursive: true });
    const key = platform.ensureKey();
    await directory.resetDirectory();
    const sink = await startMailSink();
    await sink.clear();
    const service = await seed.startDemoStaffApi(key, { port: STAFF_PORT, browserSignIn: true });
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const seenCodeMails = new Set();
    let owner;
    const api = async (person, method, route, body, idempotencyKey) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, {
        method,
        headers: { 'Content-Type': 'application/json', Connection: 'close', ...service.headers(seed.PEOPLE[person]),
          Origin: service.url, 'Sec-Fetch-Site': 'same-origin', ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body),
      });
      const text = await response.text();
      if (!response.ok) throw new Error(`${person} ${method} ${route} -> ${response.status} ${text.slice(0, 400)}`);
      return text ? JSON.parse(text) : {};
    };
    const company = (slug) => seed.COMPANIES.find((c) => c.slug === slug);
    const text = async () => (await admin.semanticsLines(owner.page)).join('\n');
    const mustSee = async (label, pattern, timeout = 20000) => {
      const end = Date.now() + timeout;
      let body = '';
      while (Date.now() < end) {
        body = await text();
        if (pattern.test(body)) return body;
        await owner.page.waitForTimeout(400);
      }
      throw new Error(`${label}: ${pattern} not on screen:\n${body.slice(0, 2500)}`);
    };
    const mustNotSee = async (label, pattern) => {
      const body = await text();
      if (pattern.test(body)) throw new Error(`${label}: ${pattern} is on screen`);
    };
    const press = async (name, { exact = false, last = false } = {}) => {
      const buttons = owner.page.getByRole('button', { name, exact });
      const target = last ? buttons.last() : buttons.first();
      await target.click({ timeout: 15000 });
      await owner.page.waitForTimeout(900);
    };
    const shoot = async (label) => {
      for (const width of WIDTHS) {
        await owner.page.setViewportSize({ width, height: width < 800 ? 900 : 1100 });
        await owner.page.waitForTimeout(1200);
        await t.shot(owner, `${label}-${width}`);
      }
      await owner.page.setViewportSize(DESKTOP);
      await owner.page.waitForTimeout(1000);
    };
    const invoiceDoc = (invoiceId) => platformDb.get('invoices', invoiceId);
    const changeBillingEmail = async (c, address, label) => {
      const ask = await api('ali', 'POST', '/approvals', { action: 'billing_email.change', tenantId: c.tenantId,
        reason: 'Client asked for this billing address', params: { billingEmail: address } }, `p1-email-${label}`);
      await api('cassie', 'POST', `/approvals/${ask.approvalId}/approve`);
    };
    const gotoInvoices = async () => {
      await press(/^Inbox(,|$)/);
      await press(/^Invoices(,|$)/);
      await owner.page.waitForTimeout(1200);
    };
    const jobsFor = async (address) => (await platformDb.list('mail_jobs')).filter((job) => job.kind === 'invoice' && job.recipient === address);
    const helperEnv = () => ({ ...process.env, PYTHONUTF8: '1', PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT,
      PLATFORM_PUBLIC_KEYS: platform.publicKeysText(key), PLATFORM_SIGNING_KEY_ID: key.keyId, PLATFORM_SIGNING_KEY: key.seed,
      ...directory.mailEnv(), PLATFORM_FINANCE_EMAIL: FINANCE_ADDRESS, PLATFORM_EMULATOR_PROJECTS: 'cos40005,hardware-client-sales' });
    const timeHelper = (command, args = {}) => JSON.parse(execFileSync(platform.PYTHON, ['scripts/control_centre_demo_time.py', command], {
      cwd: platform.ROOT, input: JSON.stringify(args), encoding: 'utf8', env: helperEnv(), windowsHide: true,
    }).trim().split(/\r?\n/).pop());
    const runJobs = async (names) => {
      for (const name of names) await platformDb.del('scheduler_leases', name).catch(() => {});
      return timeHelper('jobs', { jobs: names });
    };
    const brevoEvent = async (event, address, job, reason) => {
      const response = await fetch(`${service.url}/v1/mail/brevo-events`, {
        method: 'POST',
        headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${directory.MAIL_WEBHOOK_SECRET}`, Connection: 'close' },
        body: JSON.stringify([{ event, email: address, 'message-id': job.providerMessageId, ...(reason ? { reason } : {}) }]),
      });
      equal([response.status, (await response.json()).accepted], [200, 1], `${event} event accepted`);
    };
    const mustGoWithout = async (label, pattern, timeout) => {
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        if (!pattern.test(await text())) return;
        await owner.page.waitForTimeout(1000);
      }
      throw new Error(`${label}: ${pattern} is still on screen after ${timeout} ms without a refresh`);
    };
    const toSendCount = async () => {
      let count = 0;
      for (const row of await platformDb.list('invoices')) {
        if (row.status !== 'issued') continue;
        if (!row.sendRequestedAt) { count += 1; continue; }
        const view = await api('ali', 'GET', `/invoices/${row.invoiceId}`);
        if (view.delivery && view.delivery.state === 'not_delivered') count += 1;
      }
      return count;
    };
    const openCompanyTab = async (name, tab) => {
      await press(/^Companies(,|$)/);
      await press(new RegExp(`^${name}`));
      await press(new RegExp(`^${tab}`), { last: true });
    };
    const mailTo = async (address, timeout = 20000) => {
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        const hit = (await sink.messages()).find((m) => m.To.some((to) => to.Address === address) && m.Subject.startsWith("Invoice "));
        if (hit) return sink.message(hit.ID);
        await new Promise((resolve) => setTimeout(resolve, 300));
      }
      throw new Error(`no invoice mail reached ${address}`);
    };
    let kuching;
    let invoiceId;
    try {
      await t.step('load the demo data through the staff API', async () => {
        await seed.seedDemo({ service, key, log: () => {} });
        kuching = company('kuching-mart');
        await changeBillingEmail(kuching, FIRST_ADDRESS, 'first');
        const pending = (await api('cassie', 'GET', '/approvals?status=requested')).approvals;
        for (const approval of pending.filter((row) => row.action === 'lifecycle.suspend')) {
          await api('cassie', 'POST', `/approvals/${approval.approvalId}/reject`, { reason: 'Cleared before the billing check' });
        }
      });
      await t.step('the owner signs in to the Control Centre', async () => {
        owner = await t.session('admin', { name: 'control-owner' });
        await owner.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          const response = await route.fetch({
            url: `${service.url}${url.pathname}${url.search}`,
            headers: { ...request.headers(), host: new URL(t.urls.admin).host },
          });
          return route.fulfill({ response });
        });
        await B.openApp(owner.page, t.urls.admin);
        await staff.signInControlCentre(owner.page, service.emails.owner, sink, seenCodeMails);
        await owner.page.getByText('Control Centre', { exact: false }).first().waitFor({ timeout: 45000 });
      });

      await t.step('issue the Kuching Mart draft and ask to send it: the dialog names the billing address', async () => {
        await press(/^Invoices(,|$)/);
        await press(/^Drafts/);
        await press(/Kuching Mart/);
        await press('Issue invoice', { exact: true });
        await press('Issue invoice', { exact: true, last: true });
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('issued', /Issued/);
        const issued = (await api('ali', 'GET', `/invoices?tenantId=${kuching.tenantId}`)).invoices.find((row) => row.status === 'issued');
        invoiceId = issued.invoiceId;
        await press('Send invoice', { exact: true });
        await mustSee('confirm', /Send this invoice\?/);
        await mustSee('address', new RegExp(FIRST_ADDRESS.replace(/\./g, '\\.')));
        await shoot('send-confirm');
      });
      await t.step('after Send the invoice shows Sending, with no due date and a queued mail', async () => {
        await press('Send invoice', { exact: true, last: true });
        await mustSee('sending', /Sending/);
        await mustSee('note', /waiting to be sent/);
        await mustNotSee('not sent yet', /\bSent\b[^\n]*Kuching/);
        const stored = await invoiceDoc(invoiceId);
        equal([stored.status, stored.deliveredAt ?? null, stored.dueAt ?? null], ['issued', null, null], 'stored invoice while sending');
        const jobs = await jobsFor(FIRST_ADDRESS);
        equal(jobs.map((job) => job.status), ['queued'], 'mail job waiting');
        await shoot('invoice-sending');
      });
      await t.step('the Inbox row for the Sending invoice says it is waiting to go out', async () => {
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        const body = await mustSee('inbox row', /Kuching Mart[\s\S]*Sending: the email is waiting to go out/);
        if (/Issued, ready to send[\s\S]{0,200}Kuching|Kuching[\s\S]{0,200}Issued, ready to send/.test(body)) throw new Error('Inbox still says ready to send');
        await shoot('inbox-sending-row');
        const tick = service.deliverMail();
        if (!(tick.sent >= 1)) throw new Error(`mail tick sent ${JSON.stringify(tick)}`);
        await mustGoWithout('the Sending row leaves the Inbox by itself', /Kuching Mart[\s\S]*Sending: the email is waiting to go out/, 45000);
        await shoot('inbox-sending-row-cleared');
      });
      await t.step('the mail worker delivers it: the invoice shows Sent with a due date, and the mail carries the same date', async () => {
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('sent', /Sent/);
        await mustSee('due', /Due /);
        const stored = (await api('ali', 'GET', `/invoices/${invoiceId}`));
        equal([stored.status, stored.delivery.state], ['sent', 'delivered'], 'stored invoice after delivery');
        equal(new Date(stored.dueAt) - new Date(stored.deliveredAt), 14 * DAY, 'due date is 14 days after delivery');
        const message = await mailTo(FIRST_ADDRESS);
        const jobs = await jobsFor(FIRST_ADDRESS);
        equal(jobs.map((job) => [job.status, job.payload.dueAt]), [['sent', dayOf(new Date(stored.dueAt).getTime() + 8 * 3600000)]], 'mailed due date');
        if (!message.Text.includes(jobs[0].payload.invoiceNumber)) throw new Error('the mail does not carry the invoice number');
        await shoot('invoice-sent');
      });
      await t.step('the provider reports a hard bounce: the invoice shows Not delivered with the reason and no due date', async () => {
        const [job] = await jobsFor(FIRST_ADDRESS);
        const response = await fetch(`${service.url}/v1/mail/brevo-events`, {
          method: 'POST',
          headers: { 'Content-Type': 'application/json', Authorization: `Bearer ${directory.MAIL_WEBHOOK_SECRET}`, Connection: 'close' },
          body: JSON.stringify([{ event: 'hard_bounce', email: FIRST_ADDRESS, 'message-id': job.providerMessageId, reason: 'mailbox does not exist' }]),
        });
        equal([response.status, (await response.json()).accepted], [200, 1], 'bounce event accepted');
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('badge', /Not delivered/);
        await mustSee('reason', /Not delivered:[\s\S]*mailbox does not exist[\s\S]*due date has not started/);
        await mustSee('send again', /Send again/);
        const stored = await invoiceDoc(invoiceId);
        equal([stored.status, stored.deliveredAt ?? null, stored.dueAt ?? null], ['issued', null, null], 'stored invoice after the bounce');
        await shoot('invoice-not-delivered');
      });
      await t.step('the company Invoices tab says Not delivered instead of Open, and the Inbox row says Not delivered with the reason', async () => {
        await openCompanyTab('Kuching Mart', 'Invoices');
        await mustSee('invoice row', /INV-2026-\d+/);
        const row = await api('ali', 'GET', `/invoices/${invoiceId}`);
        equal(row.delivery.state, 'not_delivered', 'the invoice the tab lists is Not delivered');
        await shoot('company-invoices-not-delivered');
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustSee('inbox row', /Not delivered[\s\S]*mailbox does not exist/);
        await shoot('inbox-not-delivered-row');
      });
      await t.step('the staff digest counts the Not delivered invoice as one that needs staff', async () => {
        const expected = await toSendCount();
        if (expected < 1) throw new Error('the Not delivered invoice is not counted by the API');
        timeHelper('digest');
        const tick = service.deliverMail();
        if (!(tick.sent >= 1)) throw new Error(`digest tick ${JSON.stringify(tick)}`);
        const end = Date.now() + 20000;
        let seen = null;
        while (Date.now() < end && seen === null) {
          const hit = (await sink.messages()).find((m) => m.To.some((to) => to.Address === FINANCE_ADDRESS));
          if (hit) seen = /Invoices to send: (\d+)/.exec((await sink.message(hit.ID)).Text);
          if (seen === null) await new Promise((resolve) => setTimeout(resolve, 400));
        }
        if (seen === null) throw new Error('no staff digest reached the finance address');
        equal(Number(seen[1]), expected, 'digest count of invoices to send');
      });
      await t.step('three days pass, the billing email is corrected and Send again names and mails the corrected address', async () => {
        timeHelper('age', { tenantId: kuching.tenantId, days: 3 });
        await changeBillingEmail(kuching, CORRECTED_ADDRESS, 'corrected');
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await press('Send again', { exact: true });
        await mustSee('confirm', /Send this invoice again\?/);
        await mustSee('corrected address', new RegExp(CORRECTED_ADDRESS.replace(/\./g, '\\.')));
        await shoot('send-again-confirm');
        await press('Send again', { exact: true, last: true });
        await mustSee('sending', /Sending/);
        equal((await jobsFor(CORRECTED_ADDRESS)).map((job) => job.status), ['queued'], 'resend queued to the corrected address');
        const tick = service.deliverMail();
        if (!(tick.sent >= 1)) throw new Error(`mail tick sent ${JSON.stringify(tick)}`);
        const message = await mailTo(CORRECTED_ADDRESS);
        const stored = await api('ali', 'GET', `/invoices/${invoiceId}`);
        const [resent] = await jobsFor(CORRECTED_ADDRESS);
        equal([stored.status, stored.delivery.state], ['sent', 'delivered'], 'invoice after the resend is delivered');
        equal(resent.payload.dueAt, dayOf(new Date(stored.dueAt).getTime() + 8 * 3600000), 'resent due date matches the stored one');
        const [first] = await jobsFor(FIRST_ADDRESS);
        equal((new Date(resent.payload.dueAt) - new Date(first.payload.dueAt)) / DAY, 3, 'the resend three days later carries a due date three days later');
        if (!message.Text.includes(resent.payload.invoiceNumber)) throw new Error('the resent mail does not carry the invoice number');
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('sent again', /Sent/);
        await shoot('invoice-sent-again');
      });
      await t.step('a soft bounce shows Not delivered with the delay, then a delivered event shows Sent with the due date', async () => {
        const [job] = await jobsFor(CORRECTED_ADDRESS);
        await brevoEvent('soft_bounce', CORRECTED_ADDRESS, job, 'mailbox full');
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('delayed', /Not delivered:[\s\S]*delivery was delayed/);
        let stored = await invoiceDoc(invoiceId);
        equal([stored.status, stored.dueAt ?? null], ['issued', null], 'stored invoice after the soft bounce');
        await shoot('invoice-soft-bounce');
        await brevoEvent('delivered', CORRECTED_ADDRESS, job);
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await mustSee('due', /Due /);
        await mustSee('Kuching Mart is Sent', /Kuching Mart INV-2026-\d+ Sent/);
        stored = await invoiceDoc(invoiceId);
        equal(stored.status, 'sent', 'stored invoice after the delivered event');
        await shoot('invoice-delivered-event');
      });
      await t.step('Retry on the company Emails tab mails the current billing address with a due date 14 days from the retry', async () => {
        const [job] = await jobsFor(CORRECTED_ADDRESS);
        await brevoEvent('hard_bounce', CORRECTED_ADDRESS, job, 'mailbox closed');
        await changeBillingEmail(kuching, THIRD_ADDRESS, 'third');
        await gotoInvoices();
        await press(/^Sent/);
        await press(/Kuching Mart/);
        await press('Send again', { exact: true });
        await press('Send again', { exact: true, last: true });
        await mustSee('sending', /Sending/);
        const rejected = timeHelper('mail', { reject: { [THIRD_ADDRESS]: { retryable: false } } });
        if (!(rejected.failed >= 1)) throw new Error(`reject tick ${JSON.stringify(rejected)}`);
        await changeBillingEmail(kuching, FOURTH_ADDRESS, 'fourth');
        await openCompanyTab('Kuching Mart', 'Emails');
        await mustSee('failed mail', new RegExp(`Retry mail to ${THIRD_ADDRESS.replace(/\./g, '\\.')}`));
        await shoot('company-emails-failed-invoice');
        await press(`Retry mail to ${THIRD_ADDRESS}`);
        await mustSee('retry dialog', /Retry mail/);
        await press('Retry mail', { exact: true, last: true });
        await owner.page.waitForTimeout(1500);
        const tick = service.deliverMail();
        if (!(tick.sent >= 1)) throw new Error(`retry tick ${JSON.stringify(tick)}`);
        const message = await mailTo(FOURTH_ADDRESS);
        const stored = await api('ali', 'GET', `/invoices/${invoiceId}`);
        const [retried] = await jobsFor(FOURTH_ADDRESS);
        equal([stored.status, stored.delivery.state], ['sent', 'delivered'], 'invoice after the Emails tab retry');
        equal(retried.payload.dueAt, dayOf(new Date(stored.dueAt).getTime() + 8 * 3600000), 'retried due date matches the stored one');
        if (!message.Text.includes(retried.payload.invoiceNumber)) throw new Error('the retried mail does not carry the invoice number');
        await openCompanyTab('Kuching Mart', 'Invoices');
        await mustSee('invoice row', /INV-2026-\d+/);
        await shoot('company-invoices-after-retry');
      });

      await t.step('the check-by banner on the payments tab', async () => {
        await press(/^Companies(,|$)/);
        await press(/^Kenyalang Mini Market/);
        await press(/^Payments/, { last: true });
        await mustSee('banner', /A payment is waiting to be checked/);
        await mustSee('date', /Check it against the bank statement by \d{1,2} \w+ \d{4}\. An unchecked payment gives at most 7 days of cover/);
        await shoot('company-payments-check-by');
      });
      await t.step('the unchecked payment is not checked for seven days: the company is past due and the page says why', async () => {
        const kenyalang = company('kenyalang');
        timeHelper('age', { tenantId: kenyalang.tenantId, days: 5 });
        await runJobs(['past_due']);
        equal((await platformDb.get('lifecycle', kenyalang.tenantId)).state, 'past_due', 'the scheduler made Kenyalang past due');
        await press(/^Companies(,|$)/);
        await press(/^Kenyalang Mini Market/);
        await mustSee('reason', /Past due since[\s\S]*Reason: A payment has not been checked against the bank statement\. Cover from unchecked payments ended on/);
        await shoot('company-past-due-unchecked');
      });
      await t.step('the owner checks the payment and the company returns to Active on its own, with an audit entry', async () => {
        const kenyalang = company('kenyalang');
        await press(/^Payments/, { last: true });
        await press('Matches bank statement');
        await press('Matches bank statement', { exact: true, last: true });
        await mustSee('checked', /Checked|checked by/i);
        await runJobs(['past_due']);
        const lifecycle = await platformDb.get('lifecycle', kenyalang.tenantId);
        equal(lifecycle.state, 'active', 'the scheduler returned Kenyalang to active');
        const moved = (await api('ali', 'GET', `/audit-events?tenantId=${kenyalang.tenantId}&limit=200`)).events.filter((row) =>
          row.action === 'lifecycle.transitioned' && row.refs && row.refs.previousState === 'past_due');
        equal(moved.map((row) => row.refs.state), ['active'], 'one audit event for the automatic return');
        await press(/^Inbox(,|$)/);
        await press(/^Companies(,|$)/);
        await press(/^Kenyalang Mini Market/);
        await mustSee('active', /Active/);
        await mustNotSee('no past due text', /Past due since/);
        await shoot('company-active-again');
      });

      await t.step('a quote asked for one package is refused once the company is on another package', async () => {
        const sarawak = company('sarawak-prov');
        const body = (name) => ({ name, edition: 'advanced', limits: { salesmen: 40, supervisors: 8, admins: 2, branchManagers: 5, products: 5000 },
          quotaSchemaVersion: 2, features: {}, notes: '', prices: { currency: 'MYR', monthly: null, yearly: null }, tagline: '', highlights: [],
          sortOrder: 50, visibility: 'public', reason: 'A second package priced by quote' });
        let refusal = '';
        const fresh = { name: 'Enterprise Plus', edition: 'advanced', limits: { salesmen: 40, supervisors: 8, admins: 2, branchManagers: 5, products: 5000 },
          quotaSchemaVersion: 2, features: {}, tagline: '', highlights: [], sortOrder: 50, notes: '', prices: { currency: 'MYR', monthly: 100, yearly: 1000 } };
        try {
          await api('ali', 'POST', '/approvals', { action: 'package.price', reason: 'Create a package by approval', params: { planId: 'ENTERPRISE2', version: fresh } }, 'p1-newplan-ask');
        } catch (error) { refusal = error.message; }
        if (!/403/.test(refusal) || !/Only the owner can create a new package through a price approval/.test(refusal)) {
          throw new Error(`the operator was not refused a new package: ${refusal}`);
        }
        await api('cassie', 'PUT', '/plans/ENTERPRISE2', body('Enterprise Plus'), 'p1-plan-enterprise2');
        const revision = (await api('ali', 'GET', `/companies/${sarawak.tenantId}/subscription`)).effective.revision;
        await api('ali', 'POST', `/companies/${sarawak.tenantId}/package`,
          { planId: 'ENTERPRISE2', billingInterval: 'yearly', expectedRevision: revision, reason: 'Moved to the other quoted package' }, 'p1-package-sarawak');
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustSee('quote request', /Sarawak Provision Trading/);
        await press('Approve', { exact: true });
        await mustSee('dialog', /Approve this change/);
        await press('Approve', { exact: true, last: true });
        await mustSee('refusal', /The package changed since this was requested\. Send a new request\./);
        await shoot('quote-other-package-refusal');
        const quotes = (await platformDb.list('quotes')).filter((quote) => quote.tenantId === sarawak.tenantId);
        equal(quotes.length, 0, 'no quote was recorded for the other package');
        await press('Cancel', { exact: true });
        const pending = (await api('cassie', 'GET', '/approvals?status=requested')).approvals.filter((row) => row.action === 'quote.price');
        for (const approval of pending) await api('cassie', 'POST', `/approvals/${approval.approvalId}/reject`, { reason: 'Replaced by a new request' });
      });

      await t.step('a price-only request is approved on screen and changes only the prices; one that also changes limits is refused when asked', async () => {
        const before = (await api('ali', 'GET', '/plans')).plans.find((plan) => plan.planId === 'STARTER').current;
        const kept = ['name', 'edition', 'limits', 'quotaSchemaVersion', 'features', 'tagline', 'highlights', 'sortOrder', 'notes'];
        const version = Object.fromEntries(kept.filter((name) => before[name] !== undefined).map((name) => [name, before[name]]));
        let refusal = '';
        try {
          await api('ali', 'POST', '/approvals', { action: 'package.price', reason: 'Price review with a limit change', params: {
            planId: 'STARTER', version: { ...version, limits: { ...version.limits, salesmen: version.limits.salesmen + 5 }, prices: { currency: 'MYR', monthly: 79, yearly: 940 } } } }, 'p1-price-limits');
        } catch (error) { refusal = error.message; }
        if (!/limits/.test(refusal)) throw new Error(`a price request that changes limits was not refused naming the field: ${refusal}`);
        await api('ali', 'POST', '/approvals', { action: 'package.price', reason: 'Price review', params: {
          planId: 'STARTER', version: { ...version, prices: { currency: 'MYR', monthly: 79, yearly: 940 } } } }, 'p1-price-ask');
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustSee('price request', /STARTER/);
        await press('Approve', { exact: true });
        await mustSee('dialog', /Approve this change/);
        await shoot('price-approve-confirm');
        await press('Approve', { exact: true, last: true });
        await mustSee('approved', /Approved\./);
        const after = (await api('ali', 'GET', '/plans')).plans.find((plan) => plan.planId === 'STARTER').current;
        equal([after.prices.monthly, after.prices.yearly], [79, 940], 'prices after the approval');
        equal(after.limits, before.limits, 'limits after the price approval');
      });

      await t.step('an old quote with no package does not price another package: the renewal waits in the Inbox for a new quote, then drafts', async () => {
        const samarahan = company('samarahan');
        timeHelper('age', { tenantId: samarahan.tenantId, days: 12 });
        const revision = (await api('ali', 'GET', `/companies/${samarahan.tenantId}/subscription`)).effective.revision;
        await api('ali', 'POST', `/companies/${samarahan.tenantId}/package`,
          { planId: 'ENTERPRISE2', billingInterval: 'monthly', expectedRevision: revision, reason: 'Moved to the quoted package' }, 'p1-package-samarahan');
        await platformDb.put('quotes', 'legacy-samarahan-quote', { quoteId: 'legacy-samarahan-quote', tenantId: samarahan.tenantId,
          amountMinor: 1500000, currency: 'MYR', billingInterval: 'monthly', planId: null, status: 'approved', approvalId: 'legacy',
          requestedBy: 'ali', approvedBy: 'cassie', reason: 'Quote from before the rule', createdAt: new Date(Date.now() - 20 * DAY) });
        await runJobs(['invoice_drafts']);
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustSee('blocked renewal', /Renewal not drafted[\s\S]*new quote/);
        await shoot('inbox-renewal-not-drafted');
        const drafts = (await platformDb.list('invoices')).filter((row) => row.tenantId === samarahan.tenantId && row.status === 'draft');
        equal(drafts.length, 0, 'no renewal draft was made from the old quote');
        await api('ali', 'POST', '/approvals', { action: 'quote.price', tenantId: samarahan.tenantId, reason: 'New quote for the new package',
          params: { amountMinor: 1500000, billingInterval: 'monthly' } }, 'p1-quote-samarahan');
        await press('Refresh');
        await mustSee('quote request', /Samarahan Fresh Mart/);
        await press('Approve', { exact: true });
        await mustSee('dialog', /Approve this change/);
        await press('Approve', { exact: true, last: true });
        await mustSee('approved', /Approved\./);
        await runJobs(['invoice_drafts']);
        const made = (await platformDb.list('invoices')).filter((row) => row.tenantId === samarahan.tenantId && row.status === 'draft');
        equal(made.length, 1, 'the renewal draft exists after the new quote');
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustNotSee('block cleared', /Renewal not drafted/);
        await shoot('inbox-renewal-drafted');
      });

      await t.step('voiding the only payment makes the company past due and the page says the payment was voided', async () => {
        const santubong = company('santubong');
        const entries = (await api('ali', 'GET', `/companies/${santubong.tenantId}/payments`)).entries.filter((entry) => entry.type === 'payment');
        equal(entries.length, 1, 'Santubong has one payment');
        await api('ali', 'POST', '/approvals', { action: 'payment.void', tenantId: santubong.tenantId,
          reason: 'Wrong bank line', params: { receiptId: entries[0].entryId } }, 'p1-void-ask');
        await press(/^Inbox(,|$)/);
        await press('Refresh');
        await mustSee('void request', /Santubong Retail/);
        await press('Approve', { exact: true });
        await mustSee('dialog', /Approve this change/);
        await shoot('void-approve-confirm');
        await press('Approve', { exact: true, last: true });
        await mustSee('approved', /Approved\./);
        await runJobs(['past_due']);
        const lifecycle = await platformDb.get('lifecycle', santubong.tenantId);
        equal(lifecycle.state, 'past_due', 'the scheduler made the company past due');
        await press(/^Companies(,|$)/);
        await press(/^Santubong Retail/);
        await mustSee('status', /Past due since[\s\S]*Reason: Invoice INV-2026-\d+ is unpaid 14 days after delivery\. Its payment was voided\./);
        await shoot('company-past-due-reason');
      });
      await t.step('the correct payment is recorded and checked: the company returns to Active', async () => {
        const santubong = company('santubong');
        await press(/^Payments/, { last: true });
        await press('Record payment', { exact: true });
        await B.fillField(owner.page, owner.page.getByRole('textbox', { name: 'Bank reference', exact: true }), 'E2E/SANTUBONG-RIGHT');
        await B.fillField(owner.page, owner.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Right bank line');
        await press('Record payment', { exact: true, last: true });
        await mustSee('recorded', /Bank ref E2E\/SANTUBONG-RIGHT/);
        const entry = (await platformDb.list('payment_entries')).find((row) => row.tenantId === santubong.tenantId && row.externalReference === 'E2E/SANTUBONG-RIGHT');
        await api('ali', 'POST', `/companies/${santubong.tenantId}/payments/${entry.entryId}/check`);
        await runJobs(['past_due']);
        equal((await platformDb.get('lifecycle', santubong.tenantId)).state, 'active', 'the scheduler returned Santubong to active');
        await press(/^Inbox(,|$)/);
        await press(/^Companies(,|$)/);
        await press(/^Santubong Retail/);
        await mustSee('active', /Active/);
        await mustNotSee('no voided text', /Its payment was voided/);
        await shoot('company-active-after-correct-payment');
      });
    } finally {
      await service.stop();
      await sink.close();
    }
  },
};
