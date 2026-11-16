'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const { BRANCH, PRODUCTS, RETAILERS, putPerson } = require('../lib/seed.cjs');

const PLAN = 'V4STARTER_TEST';
const LIMITS = { salesmen: 5, supervisors: 1, admins: 1, branchManagers: 1, products: 100 };
const LEGACY = 'V4LEGACY_TEST';
const LEGACY_LIMITS = { salesmen: 5, supervisors: 1, managers: 2, products: 100 };
const DOWNGRADE = 'V4LEGACY_LOW_TEST';
const DEVELOPER = {
  email: 'e2e.v4.developer@example.test', name: 'E2E V4 Developer',
  code: 'DEV-V4', role: 'developer', branch: BRANCH.id,
};
const RACE = [
  { name: 'E2E V4 Branch One', email: 'e2e.v4.bm1@example.test', code: 'BM-V401' },
  { name: 'E2E V4 Branch Two', email: 'e2e.v4.bm2@example.test', code: 'BM-V402' },
];
const canonical = (value) => JSON.stringify(value, (_, v) => (
  v && typeof v === 'object' && !Array.isArray(v)
    ? Object.fromEntries(Object.entries(v).sort(([a], [b]) => a.localeCompare(b))) : v));

function equal(actual, expected, what) {
  if (canonical(actual) !== canonical(expected)) {
    throw new Error(`${what}: expected ${canonical(expected)}, got ${canonical(actual)}`);
  }
}

module.exports = {
  name: 'v4_packages',
  seedPlan: false,
  async run(t) {
    E.requireEmulators();
    const { db, accounts, seed, platformApi } = t;
    if (!platformApi) throw new Error('v4_packages requires the runner platformApi');
    const key = platform.ensureKey();
    const plans = (steps) => directory.planAdmin([key], steps);
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const workspace = platform.harnessRecord().workspace;
    const out = path.join(E.OUTPUT_DIR, 'v4_packages');
    const evidence = { planId: PLAN, quotaSchemaVersion: 2, limits: LIMITS, checks: [], network: [], completed: false };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    let sequence = 0;
    let token;
    let developerToken;
    let version;
    let tabA;
    let tabB;

    const signIn = async (email) => {
      const response = await fetch(`${db.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
        method: 'POST', headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ email, password: E.PASSWORD, returnSecureToken: true }),
      });
      const body = await response.json();
      return { ok: response.ok, token: body.idToken };
    };
    const api = async (method, suffix, body, bearer = token) => {
      const response = await fetch(`${platformApi.url}/v1/w/${workspace}/${suffix}`, {
        method,
        headers: {
          Authorization: `Bearer ${bearer}`, 'Content-Type': 'application/json',
          Connection: 'close',
          ...(method === 'POST' ? { 'Idempotency-Key': `v4-packages-${++sequence}` } : {}),
        },
        ...(body === undefined ? {} : { body: JSON.stringify(body) }),
      }).catch((error) => {
        throw new Error(`Local API ${method} ${suffix} failed: ${error.cause?.code || error.message}`, { cause: error });
      });
      return { status: response.status, body: await response.json() };
    };
    const invite = (role, code, more = {}) => api('POST', 'invitations', {
      displayName: `E2E ${code}`, employeeCode: code, role, branchId: BRANCH.id,
      email: `e2e.${code.toLowerCase()}@example.test`, ...more,
    });
    const refused = (reply, label) => {
      equal(reply.status, 409, label);
      equal(reply.body.code, 'plan_limit', `${label} code`);
    };
    const rows = async (client, collection) => (await client.list(collection)).sort((a, b) => a.id.localeCompare(b.id));
    const members = async () => ({ access: await rows(db, 'user_access'), users: await rows(db, 'users') });
    const unchangedLegacy = async () => {
      const existing = {};
      for (const plan of await rows(platformDb, 'plans')) {
        if ([PLAN, LEGACY, DOWNGRADE].includes(plan.id)) continue;
        existing[plan.id] = { plan, versions: await rows(platformDb, `plans/${plan.id}/versions`) };
      }
      return {
        plans: existing,
        subscriptions: (await rows(platformDb, 'subscriptions')).filter((s) => s.id !== directory.HARNESS_TENANT),
      };
    };
    const submitOrder = async (name, { retailer = RETAILERS[1], prepared = false } = {}) => {
      const session = await t.session('mobile', { name, viewport: mobile.MOBILE_VIEWPORT });
      await B.loginMobile(session.page, session.url, accounts.salesman.email);
      await mobile.waitForHome(session.page);
      if (!prepared) await mobile.planVisitToday(session.page, retailer.name);
      await mobile.openPlannedVisit(session.page, retailer.name);
      await mobile.selectProducts(session.page, 'GROCERY', [PRODUCTS[0].name]);
      await mobile.continueToSignature(session.page);
      const id = await mobile.signAndSubmit(session.page, 'GROCERY', 1);
      const order = await db.waitForDoc('orders', id, (o) => o.status === 'submitted');
      equal(order.salesmanUid, seed.uids.salesman, `${name} owner`);
      await t.shot(session, name);
      return id;
    };

    try {
      let baseline;
      await t.step('legacy combined capacity and its subscription pin survive the production migration entry point', async () => {
        await putPerson(db, DEVELOPER);
        const adminSignIn = await signIn(accounts.admin.email);
        const devSignIn = await signIn(DEVELOPER.email);
        equal([adminSignIn.ok, devSignIn.ok], [true, true], 'fixture sign-in');
        token = adminSignIn.token;
        developerToken = devSignIn.token;
        const [, created] = plans([
          { op: 'catalogue' },
          { op: 'private_plan', planId: LEGACY, limits: LEGACY_LIMITS, prices: null },
        ]);
        plans([{ op: 'subscribe', planId: LEGACY, planVersion: created.version, status: 'active' }]);
        plans([{ op: 'usage' }]);
        const subscription = await platformDb.get('subscriptions', directory.HARNESS_TENANT);
        equal(subscription.planVersion, created.version, 'explicit legacy pin (planAdmin must forward it)');
        const oldVersion = await platformDb.get(`plans/${LEGACY}/versions`, String(created.version));
        const before = await members();
        refused(await invite('admin', 'ADM-V400'), 'legacy admin at combined cap');
        refused(await invite('branch_manager', 'BM-V400'), 'legacy branch manager at combined cap');
        plans([{ op: 'usage' }]);
        const usage = await db.get('config', 'usage');
        equal(usage.usageSchemaVersion, 2, 'canonical usage readiness');
        equal(usage.seats, { salesmen: 1, supervisors: 1, admins: 1, branchManagers: 1 }, 'canonical recount');
        equal(usage.activeAdmins, 1, 'active admin recount');
        equal(await members(), before, 'migration preserves account records');
        equal(await platformDb.get('subscriptions', directory.HARNESS_TENANT), subscription, 'migration preserves subscription');
        equal(await platformDb.get(`plans/${LEGACY}/versions`, String(created.version)), oldVersion, 'migration preserves legacy version');
        refused(await invite('admin', 'ADM-V401'), 'migrated legacy admin at combined cap');
        refused(await invite('branch_manager', 'BM-V403'), 'migrated legacy branch manager at combined cap');
        const legacyUsage = await api('GET', 'usage');
        equal(legacyUsage.status, 200, 'legacy usage response');
        equal(legacyUsage.body.limits, LEGACY_LIMITS, 'legacy limits remain combined');
        equal(legacyUsage.body.usage.managers, 2, 'legacy combined usage remains two');
        baseline = await unchangedLegacy();
        note('legacy aggregate unchanged', { usageSchemaVersion: usage.usageSchemaVersion, managers: 2, pin: created.version });
      });

      await t.step('the exact private V4 offer projects split limits and request-quote prices', async () => {
        const [created] = plans([{
          op: 'private_plan', planId: PLAN, quotaSchemaVersion: 2,
          limits: LIMITS, prices: null,
        }]);
        version = created.version;
        const stored = await platformDb.get(`plans/${PLAN}/versions`, String(version));
        equal(stored.quotaSchemaVersion, 2, 'stored quota schema (planAdmin must forward it)');
        equal(stored.limits, LIMITS, 'stored exact split limits');
        plans([{ op: 'subscribe', planId: PLAN, planVersion: version, status: 'active' }]);
        const projected = await db.get('config', 'plan');
        equal([projected.planId, projected.planVersion, projected.quotaSchemaVersion], [PLAN, version, 2], 'projected identity');
        equal(projected.limits, LIMITS, 'projected split limits');
        equal(projected.prices, { currency: 'MYR', monthly: null, yearly: null }, 'no fabricated prices');
        equal((await platformDb.get('subscriptions', directory.HARNESS_TENANT)).planVersion, version, 'explicit v2 pin');
        equal(await unchangedLegacy(), baseline, 'existing catalogue versions and other subscriptions unchanged');
        note('v2 projection', { planId: PLAN, planVersion: version, limits: projected.limits, prices: projected.prices });
      });

      await t.step('the real dashboard Account page shows Admins and Branch managers separately', async () => {
        tabA = await t.session('admin', { name: 'v4-admin-a', ...admin.grantClipboard });
        tabB = await t.session('admin', { name: 'v4-admin-b', ...admin.grantClipboard });
        for (const tab of [tabA, tabB]) {
          tab.page.on('response', (response) => {
            const url = new URL(response.url());
            if (['127.0.0.1', 'localhost'].includes(url.hostname) &&
                /identitytoolkit|securetoken|\/v1\/w\//.test(url.pathname)) {
              evidence.network.push({ page: tab.name, path: url.pathname, status: response.status() });
            }
          });
          await B.loginAdmin(tab.page, tab.url, accounts.admin.email);
          await admin.waitForShell(tab.page);
        }
        await admin.goToPage(tabA.page, 'Account');
        equal((await api('GET', 'account')).status, 200, 'fresh Account API preflight');
        await B.see(tabA.page, 'Enter your password to see your plan and usage.');
        await B.fillField(tabA.page, tabA.page.locator('input[type="password"]').first(), E.PASSWORD);
        await tabA.page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(tabA.page, `Plan: ${PLAN}`);
        for (const line of ['Admins: 1 of 1', 'Branch managers: 1 of 1', 'Salespeople: 1 of 5', 'Supervisors: 1 of 1', 'Products: 3 of 100']) {
          await B.see(tabA.page, line);
        }
        const lines = await admin.semanticsLines(tabA.page);
        equal(lines.some((line) => line.startsWith('Managers:')), false, 'no legacy aggregate presented as a v2 allowance');
        const usage = await api('GET', 'usage');
        equal(usage.status, 200, 'v2 usage response');
        equal(usage.body.quotaSchemaVersion, 2, 'usage schema marker');
        equal(usage.body.limits, LIMITS, 'API role allowances');
        await t.shot(tabA, 'account-split-pools');
        note('Account split labels', { lines: lines.filter((line) => /^(Admins|Branch managers|Salespeople|Supervisors|Products):/.test(line)) });
      });

      await t.step('four public packages show quote prices and send a sales request without changing the subscription', async () => {
        await tabA.page.getByRole('button', { name: 'Change plan', exact: true }).click();
        await B.see(tabA.page, 'Choose a plan');
        const offered = await api('GET', 'plans');
        equal(offered.status, 200, 'public catalogue response');
        equal(offered.body.plans.map((p) => p.planId), ['STARTER', 'STANDARD', 'PROFESSIONAL', 'ENTERPRISE'], 'four standard offers');
        for (const offer of offered.body.plans) {
          equal(offer.quotaSchemaVersion, 2, 'public split quota schema');
          equal(offer.prices, { currency: 'MYR', monthly: null, yearly: null }, 'unapproved price remains a quote');
          equal(offer.canRequest, true, 'non-lower package remains requestable');
          equal(offer.requestReason, null, 'requestable package has no refusal reason');
        }
        const before = await platformDb.get('subscriptions', directory.HARNESS_TENANT);
        await tabA.page.getByRole('button', { name: 'Request the Starter plan' }).click();
        await B.see(tabA.page, 'Request sent. The Scoot Sales team will contact you to arrange payment.');
        equal(await platformDb.get('subscriptions', directory.HARNESS_TENANT), before, 'sales request does not apply an upgrade');
        const request = await platformDb.waitForQuery('plan_requests', (r) => r.tenantId === directory.HARNESS_TENANT,
          { label: 'sales plan request' });
        equal([request.planId, request.status], ['STARTER', 'requested'], 'sales receives an explicit package request');
        await t.shot(tabA, 'four-standard-packages');
        note('four public quote offers', { planIds: offered.body.plans.map((p) => p.planId), requestStatus: request.status });
      });

      await t.step('two branch-manager browser invitations race for one seat while the full admin pool stays refused', async () => {
        await admin.setUserStatus(tabA.page, accounts.branchManager, 'Suspend');
        await db.waitForDoc('config', 'usage', (u) => u.seats.branchManagers === 0);
        for (let i = 0; i < RACE.length; i += 1) {
          await admin.fillUserForm([tabA, tabB][i].page, { ...RACE[i], role: 'Branch Manager', branchName: BRANCH.name });
        }
        const buttons = await Promise.all([tabA, tabB].map((tab) => admin.createUserButton(tab.page)));
        const replies = [tabA, tabB].map((tab) => tab.page.waitForResponse((r) => (
          r.request().method() === 'POST' && new URL(r.url()).pathname === `/v1/w/${workspace}/invitations`
        ), { timeout: 30000 }));
        const adminAttempt = invite('admin', 'ADM-V402');
        await Promise.all(buttons.map((button) => button.click()));
        const responses = await Promise.all(replies);
        equal(responses.map((r) => r.status()).sort(), [201, 409], 'exactly one browser race winner');
        refused(await adminAttempt, 'full admin pool during branch-manager race');
        for (let i = 0; i < responses.length; i += 1) {
          const tab = [tabA, tabB][i];
          if (responses[i].status() === 201) {
            await B.see(tab.page, 'Invitation created');
            await t.shot(tab, 'branch-seat-winner');
            await admin.closeInvitationDialog(tab.page);
          } else {
            const payload = await responses[i].json();
            equal(payload.code, 'plan_limit', 'race loser code');
            if (typeof payload.detail !== 'string' || !payload.detail.length) throw new Error('race loser needs a user-facing refusal');
            await B.see(tab.page, payload.detail);
            await t.shot(tab, 'branch-seat-refused');
          }
        }
        const created = (await rows(db, 'users')).filter((u) => RACE.some((person) => person.code === u.employeeCode));
        equal(created.length, 1, 'one race profile');
        const held = (await rows(db, 'user_access')).filter((u) => u.role === 'branch_manager' && u.seatHeld === true);
        equal(held.length, 1, 'one held branch-manager seat');
        const usage = await db.get('config', 'usage');
        equal([usage.seats.admins, usage.seats.branchManagers, usage.activeAdmins], [1, 1, 1], 'independent role counts');
        note('concurrent branch seat', { statuses: responses.map((r) => r.status()), seats: usage.seats });
      });

      await t.step('one paid extra salesperson seat does not permit a supervisor sixth assignment', async () => {
        plans([{ op: 'subscribe', planId: PLAN, planVersion: version, status: 'active', addOns: { salesmen: 1 } }]);
        for (let i = 0; i < 4; i += 1) {
          equal((await invite('salesman', `S-V4${10 + i}`, { supervisorUid: seed.uids.supervisor })).status, 201, 'take a supervised seat');
        }
        const usage = await db.get('config', 'usage');
        equal(usage.seats.salesmen, 5, 'five held salesperson seats');
        equal((await db.get('config', 'plan')).limits.salesmen, 6, 'one paid seat remains');
        const before = await db.get('user_access', seed.uids.supervisor);
        equal(before.assignedSalesmanCodes.length, 5, 'full supervisor roster');
        const attempt = await invite('salesman', 'S-V414', { supervisorUid: seed.uids.supervisor });
        equal(attempt.status, 409, 'sixth supervisor assignment refused');
        equal(attempt.body.detail, 'That supervisor already has 5 salespeople.', 'roster refusal rather than quota exhaustion');
        equal(await db.get('user_access', seed.uids.supervisor), before, 'supervisor unchanged');
        equal(await db.get('config', 'usage'), usage, 'no reservation on refused assignment');
        equal(await db.get('users', 'S-V414'), null, 'no refused profile');
        note('supervisor cap unchanged', { rosterSize: 5, paidSalespersonLimit: 6, status: attempt.status });
      });

      await t.step('downgrade is refused before data changes and the current plan still permits a real mobile order', async () => {
        const orderBefore = await submitOrder('before-downgrade');
        const originalVisit = (await rows(db, 'visits')).find((visit) =>
          visit.ownerUid === seed.uids.salesman && visit.marketplace === RETAILERS[1].name);
        if (!originalVisit) throw new Error('the first real mobile visit was not saved');
        await db.put('visits', `${seed.uids.salesman}_v4_followup`, {
          ownerUid: seed.uids.salesman, salesmanUid: seed.uids.salesman,
          salesmanCode: accounts.salesman.code, branchId: BRANCH.id,
          marketplace: RETAILERS[0].name, time: '10:00',
          date: originalVisit.date, day: originalVisit.day,
          purpose: 'V4 downgrade acceptance', notes: '',
          createdAt: new Date(), updatedAt: new Date(),
        });
        const savedOrder = await db.get('orders', orderBefore);
        const before = {
          ...await members(),
          products: await rows(db, 'products'),
          orders: await rows(db, 'orders'),
          subscription: await platformDb.get('subscriptions', directory.HARNESS_TENANT),
          projection: await db.get('config', 'plan'),
          company: await platformDb.get('companies', directory.HARNESS_TENANT),
        };
        const [lower] = plans([{
          op: 'private_plan', planId: DOWNGRADE, quotaSchemaVersion: 2,
          limits: { salesmen: 0, supervisors: 0, admins: 1, branchManagers: 0, products: 1 }, prices: null,
        }]);
        let rejected = false;
        try {
          plans([{ op: 'subscribe', planId: DOWNGRADE, planVersion: lower.version, status: 'active' }]);
        } catch {
          rejected = true;
        }
        equal(rejected, true, 'downgrade command rejected');
        const failures = (await rows(platformDb, 'operations')).filter((operation) =>
          operation.action === 'subscription.change' &&
          operation.tenantId === directory.HARNESS_TENANT &&
          operation.status === 'failed');
        equal(
          failures.some((operation) => /Salespeople would drop from \d+ to 0\./.test(operation.error?.message || '')
            && /Supervisors would drop from \d+ to 0\./.test(operation.error?.message || '')),
          true,
          `downgrade failure reason: ${JSON.stringify(failures.map((operation) => operation.error?.message))}`,
        );
        equal({
          ...await members(),
          products: await rows(db, 'products'),
          orders: await rows(db, 'orders'),
          subscription: await platformDb.get('subscriptions', directory.HARNESS_TENANT),
          projection: await db.get('config', 'plan'),
          company: await platformDb.get('companies', directory.HARNESS_TENANT),
        }, before, 'downgrade refusal preserves source, projection and records');
        const orderAfter = await submitOrder('after-downgrade', { retailer: RETAILERS[0], prepared: true });
        equal(await db.get('orders', orderBefore), savedOrder, 'pre-existing order preserved after another submission');
        equal(await unchangedLegacy(), baseline, 'existing legacy agreements unchanged');
        note('downgrade refused', { orders: [orderBefore, orderAfter], members: before.access.length, products: before.products.length });
      });

      await t.step('a developer cannot demote, revoke or remove the sole active admin before Auth is protected', async () => {
        const before = await members();
        const usage = await db.get('config', 'usage');
        for (const action of ['role', 'revoke', 'remove']) {
          const body = action === 'role' ? { role: 'branch_manager', branchId: BRANCH.id } : undefined;
          const reply = await api('POST', `accounts/${seed.uids.admin}/${action}`, body, developerToken);
          equal(reply.status, 409, `final-admin ${action} refused`);
          equal(reply.body.code === 'plan_limit', false, `${action} is refused by membership invariant`);
          equal(await members(), before, `${action} preserves membership`);
          equal(await db.get('config', 'usage'), usage, `${action} preserves counters`);
          equal((await signIn(accounts.admin.email)).ok, true, `${action} did not disable final admin Auth`);
          note('final admin retained', { action, status: reply.status });
        }
        equal(usage.activeAdmins, 1, 'final active admin count');
      });

      await t.step('an unknown stored role cannot reactivate as a free account', async () => {
        const uid = seed.uids.branchManager;
        const index = await db.get('user_access', uid);
        const profile = await db.get('users', index.userDocId);
        equal([index.status, index.seatHeld], ['suspended', false], 'malformed fixture starts disabled');
        const unknownIndex = { ...index, role: 'unknown_v4_role', user_group: 'unknown_v4_role', seatClass: 'none' };
        const unknownProfile = { ...profile, role: 'unknown_v4_role', user_group: 'unknown_v4_role', seatClass: 'none' };
        await db.put('user_access', uid, unknownIndex);
        await db.put('users', index.userDocId, unknownProfile);
        const usage = await db.get('config', 'usage');
        const reply = await api('POST', `accounts/${uid}/reactivate`);
        equal(reply.status, 409, 'unknown-role reactivation refused');
        equal(await db.get('user_access', uid), unknownIndex, 'unknown access unchanged');
        equal(await db.get('users', index.userDocId), unknownProfile, 'unknown profile unchanged');
        equal(await db.get('config', 'usage'), usage, 'unknown role gained no free reservation');
        equal((await signIn(accounts.branchManager.email)).ok, false, 'unknown role Auth remains disabled');
        note('unknown role refused', { status: reply.status });
      });
      evidence.completed = true;
    } catch (error) {
      evidence.failedStep = error.step || 'setup';
      throw error;
    } finally {
      fs.mkdirSync(out, { recursive: true });
      fs.writeFileSync(path.join(out, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    }
  },
};
