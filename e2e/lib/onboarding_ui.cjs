'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('./browser.cjs');
const E = require('./emulator.cjs');
const platform = require('./platform.cjs');
const directory = require('./platform_api.cjs');
const staff = require('./staff.cjs');
const { startMailSink } = require('./mail_sink.cjs');

const EMAILS = { owner: 'e2e.owner@example.test', operator: 'e2e.operator@example.test', engineer: 'e2e.engineer@example.test', support: 'e2e.support@example.test' };
const WIDTHS = [[390, 844], [2000, 1100]];
const STEP_KEYS = ['details', 'project', 'people', 'package', 'payment', 'admin', 'rules', 'open'];

const iso = (date) => `${date.toISOString().slice(0, 19)}Z`;
const klMidnightUtc = () => {
  const kl = new Date(Date.now() + 8 * 3600000);
  return iso(new Date(Date.UTC(kl.getUTCFullYear(), kl.getUTCMonth(), kl.getUTCDate()) - 8 * 3600000));
};
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function expectTrue(value, what) {
  if (!value) throw new Error(`${what}: expected a true value, got ${JSON.stringify(value)}`);
}

async function startWalk(t, { outName, project }) {
  const outDir = path.join(E.OUTPUT_DIR, outName);
  fs.mkdirSync(outDir, { recursive: true });
  const key = platform.ensureKey();
  await directory.resetDirectory();
  directory.planAdmin([key], [{ op: 'catalogue' }]);
  const sink = await startMailSink();
  await sink.clear();
  process.env.PLATFORM_EMULATOR_PROJECTS = [E.PROJECT, project].join(',');
  const service = await staff.startStaffApi(key, { roleEmails: EMAILS, browserSignIn: true, scheduler: false, e2eReaders: true });
  const platformDb = E.client(directory.PLATFORM_PROJECT);
  const seenMail = new Set();
  const sessions = {};
  const lines = [];
  const report = { outDir, lines, sessions };

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

  const open = async (role) => {
    const s = await t.session('admin', { name: `control-${role}` });
    sessions[role] = s;
    await s.context.route('**/staff/v1/**', async (route) => {
      const request = route.request();
      const url = new URL(request.url());
      const response = await route.fetch({ url: `${service.url}${url.pathname}${url.search}`, headers: { ...request.headers(), host: new URL(t.urls.admin).host } }).catch(() => null);
      if (!response) return route.abort('failed').catch(() => null);
      return route.fulfill({ response });
    });
    await B.openApp(s.page, t.urls.admin);
    await staff.signInControlCentre(s.page, EMAILS[role], sink, seenMail);
    return s;
  };

  const button = (s, name) => s.page.getByRole('button', { name, exact: typeof name === 'string' });
  const dialogButton = (s, name) => s.page.getByRole('button', { name, exact: true }).last();
  const text = (s, value) => s.page.getByText(value, { exact: typeof value === 'string' });

  const shoot = async (s, label) => {
    const original = s.page.viewportSize();
    for (const [width, height] of WIDTHS) {
      await s.page.setViewportSize({ width, height });
      await s.page.waitForTimeout(900);
      await t.shot(s, `${label}-${width}px`);
    }
    await s.page.setViewportSize(original);
    await s.page.waitForTimeout(500);
  };

  const view = async (draftId) => api('owner', 'GET', `/onboarding-drafts/${draftId}`);
  const stateWord = (step) => (step.unknown ? `${step.state}?` : step.state);

  const record = async (draftId, label, pressed, expectGreen, nextButton) => {
    const v = await view(draftId);
    const states = v.steps.map((step) => `${step.n}.${step.key}=${stateWord(step)}`).join(' ');
    const head = `${label} | pressed: ${pressed} | ${v.doneCount} of ${v.total} green | next: ${v.next ? `${v.next.n} ${v.next.button ? v.next.button.label : '-'}` : 'none'} | kind ${v.kind} | phase ${v.phase}`;
    lines.push(head, `    ${states}`);
    fs.writeFileSync(path.join(outDir, 'steps.txt'), `${lines.join('\n')}\n`);
    console.log(`${head}\n    ${states}`);
    const green = v.steps.filter((step) => step.state === 'green').map((step) => step.n);
    expectEqual(green, expectGreen, `${label}: green steps (a step after the first red one is not read)`);
    if (nextButton !== undefined) expectEqual(v.next && v.next.button ? v.next.button.label : null, nextButton, `${label}: next button`);
    return v;
  };

  const expectPage = async (s, v) => {
    await text(s, `${v.doneCount} of ${v.total} steps done`).first().waitFor({ timeout: 30000 });
    if (v.next) {
      await text(s, `Next: step ${v.next.n}, ${v.next.label}`).first().waitFor({ timeout: 15000 });
      if (v.next.button) await button(s, v.next.button.label).first().waitFor({ timeout: 15000 });
    } else {
      await text(s, /^All steps are green\./).first().waitFor({ timeout: 15000 });
    }
  };

  const openChecklist = async (s, legalName) => {
    if (await button(s, /^Inbox/).count()) {
      await button(s, /^Inbox/).click();
      await button(s, 'Refresh').click();
    } else {
      await button(s, 'Companies').click();
    }
    await s.page.waitForTimeout(1500);
    await button(s, /^Onboarding(,|$)/).click();
    await button(s, `Open checklist for ${legalName}`).click();
    await text(s, 'Checklist').first().waitFor({ timeout: 25000 });
  };

  const stop = async () => {
    await service.stop();
    await sink.stop().catch(() => null);
  };

  return { api, open, button, dialogButton, text, shoot, view, record, expectPage, openChecklist, stop, platformDb, service, key, report, outDir, lines };
}

async function pickPackage(s, name) {
  await s.page.getByRole('button', { name: /^Package\b/ }).first().click();
  await s.page.getByRole('menuitem', { name, exact: true }).first().click();
}

async function createDraftOnPage(walk, s, fields, plan) {
  await walk.button(s, /^Onboarding(,|$)/).click();
  await walk.button(s, 'Add company').first().click();
  for (const [label, value] of Object.entries(fields)) {
    await B.fillField(s.page, s.page.getByRole('textbox', { name: label, exact: true }), value);
  }
  await pickPackage(s, plan);
  await walk.button(s, 'Create draft').click();
  await walk.text(s, 'Draft created').waitFor({ timeout: 30000 });
}

async function packageAndPayment(t, walk, { owner, operator, draftId, tenant, legalName, tag, moneyBase, afterPayment }) {
  const paid = afterPayment || { green: [...moneyBase, 4, 5], next: 'Give access' };
  const { button, dialogButton, text, api } = walk;
  await t.step('4. owner applies the package and the package step turns green', async () => {
    await button(owner, 'Apply package').click();
    await B.fillField(owner.page, owner.page.getByRole('textbox', { name: 'Reason', exact: true }), 'First package');
    await walk.shoot(owner, '04a-package-dialog');
    await dialogButton(owner, 'Apply package').click();
    await text(owner, 'Package changed.').first().waitFor({ timeout: 60000 });
    const v = await walk.record(draftId, 'after Apply package', 'Apply package (owner)', [...moneyBase, 4], 'Create first invoice');
    await walk.expectPage(owner, v);
    await walk.shoot(owner, '04-package-green');
  });

  await t.step('5a. owner creates the first invoice from the checklist', async () => {
    const quote = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: tenant, reason: 'Agreed price', params: { amountMinor: 50000, billingInterval: 'monthly' } }, `${tag}-quote`);
    await api('owner', 'POST', `/approvals/${quote.approvalId}/approve`);
    await button(owner, 'Create first invoice').click();
    await dialogButton(owner, 'Create invoice').click();
    await text(owner, 'The invoice was created.').first().waitFor({ timeout: 30000 });
    const v = await walk.record(draftId, 'after Create first invoice', 'Create first invoice (owner)', [...moneyBase, 4], 'Issue invoice');
    await walk.expectPage(owner, v);
    await walk.shoot(owner, '05a-invoice-created');
  });

  await t.step('5b. owner issues the draft invoice from the checklist', async () => {
    await button(owner, 'Issue invoice').click();
    await walk.shoot(owner, '05b-issue-invoice-dialog');
    await dialogButton(owner, 'Issue invoice').click();
    await text(owner, 'The invoice was issued.').first().waitFor({ timeout: 30000 });
    const v = await walk.record(draftId, 'after Issue invoice', 'Issue invoice (owner)', [...moneyBase, 4], 'Record payment');
    await walk.expectPage(owner, v);
    await walk.shoot(owner, '05b-invoice-issued');
  });

  await t.step('5c. operator records the payment', async () => {
    await walk.openChecklist(operator, legalName);
    await button(operator, 'Record payment').click();
    await B.fillField(operator.page, operator.page.getByRole('textbox', { name: 'Bank reference', exact: true }), `ONB/${tag.toUpperCase()}-001`);
    await B.fillField(operator.page, operator.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Bank statement checked');
    await walk.shoot(operator, '05c-record-payment-form');
    await button(operator, 'Record payment').last().click();
    await text(operator, 'A payment is recorded. A second person must check it.').first().waitFor({ timeout: 40000 });
    const v = await walk.record(draftId, 'after Record payment', 'Record payment (operator)', [...moneyBase, 4], 'Check payment');
    await walk.expectPage(operator, v);
    await walk.shoot(operator, '05-payment-recorded');
  });

  await t.step('5d. owner checks the payment and the payment step turns green', async () => {
    await walk.openChecklist(owner, legalName);
    await button(owner, 'Check payment').click();
    await walk.shoot(owner, '05d-check-payment-dialog');
    await dialogButton(owner, 'Matches bank statement').click();
    await text(owner, 'A checked payment covers today.').first().waitFor({ timeout: 40000 });
    const v = await walk.record(draftId, 'after Check payment', 'Check payment (owner)', paid.green, paid.next);
    await walk.expectPage(owner, v);
    await walk.shoot(owner, '05-payment-green');
  });

}

async function acceptFirstAdminInvitation(db, project, email) {
  const rows = await db.list('user_access');
  const row = rows.find((r) => r.invitationState === 'pending' && r.role === 'admin');
  if (!row) return false;
  const change = { status: 'active', isActive: true, invitationState: 'redeemed' };
  await db.put('user_access', row.id, { ...stripId(row), ...change });
  if (row.userDocId) await db.put('users', row.userDocId, { ...stripId(await db.get('users', row.userDocId)), ...change });
  const usage = await db.get('config', 'usage');
  await db.put('config', 'usage', { ...stripId(usage), activeAdmins: (usage.activeAdmins || 0) + 1 });
  const enabled = await fetch(`${db.authBase}/projects/${project}/accounts:update`, {
    method: 'POST', headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner', Connection: 'close' },
    body: JSON.stringify({ localId: row.id, disableUser: false, emailVerified: true }),
  });
  if (!enabled.ok) throw new Error(`could not enable ${email}: ${enabled.status} ${await enabled.text()}`);
  return true;
}

function stripId(row) {
  const { id, ...rest } = row;
  return rest;
}

module.exports = { packageAndPayment, acceptFirstAdminInvitation, EMAILS, WIDTHS, STEP_KEYS, klMidnightUtc, escaped, expectEqual, expectTrue, startWalk, pickPackage, createDraftOnPage };
