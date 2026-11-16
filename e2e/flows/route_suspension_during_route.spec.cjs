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
const { RETAILERS } = require('../lib/seed.cjs');

const CLOCK_AHEAD_MS = 10 * 60 * 1000;
const SNAPSHOT_COLLECTIONS = ['route_stop_progress', 'route_plan_progress', 'orders', 'held_work_receipts', 'held_work_sessions'];

function equal(actual, expected, label) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) throw new Error(`${label}: ${JSON.stringify(actual)} != ${JSON.stringify(expected)}`);
}

function check(condition, label) {
  if (!condition) throw new Error(label);
}

const isoSeconds = (date) => date.toISOString().replace(/\.\d{3}Z$/, 'Z');
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

async function shiftPageClock(page, offsetMs) {
  await page.evaluate((offset) => {
    const RealDate = Date;
    class ShiftedDate extends RealDate {
      constructor(...args) {
        if (args.length === 0) super(RealDate.now() + offset);
        else super(...args);
      }
      static now() { return RealDate.now() + offset; }
    }
    window.Date = ShiftedDate;
  }, offsetMs);
}

module.exports = {
  name: 'route_suspension_during_route', platformApi: false, seedPlan: false,
  async run(t) {
    const { db, accounts, seed } = t;
    const out = path.join(E.OUTPUT_DIR, 'route_suspension_during_route');
    fs.mkdirSync(out, { recursive: true });
    const trusted = platform.ensureKey();
    const record = { ...platform.harnessRecord(), planRef: 'STARTER', edition: 'basic' };
    const platformDb = E.client(directory.PLATFORM_PROJECT);
    const evidence = { tenantId: record.tenantId, checks: [], snapshots: {} };
    const note = (text) => evidence.checks.push(text);
    const servers = [];
    const priorEmulatorProjects = process.env.PLATFORM_EMULATOR_PROJECTS;
    let service;
    let payment;
    let planId;
    let stopA;
    let stopB;
    let phone;
    const holdUpload = (route) => route.abort('internetdisconnected');

    const snapshot = async (label) => {
      const collections = {};
      for (const name of SNAPSHOT_COLLECTIONS) collections[name] = await db.list(name).catch(() => []);
      evidence.snapshots[label] = {
        takenAt: new Date().toISOString(),
        lifecycle: await db.get('config', 'lifecycle'),
        liveTracking: await db.get('live_tracking', seed.uids.salesman),
        collections,
      };
    };

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
      return { central, projected };
    };
    const stopRows = () => db.list('route_stop_progress');

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
          reason: 'E2E package for invoicing' }, 'route-package-0001');
        await approved('quote.price', { amountMinor: 500000, billingInterval: 'monthly' }, 'route-quote-0001');
        const draft = await operator('POST', '/invoices', {}, 'route-invoice-0001');
        const issued = await staffCall('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);
        payment = await operator('POST', '/payments', {
          amountMinor: issued.amountMinor, currency: 'MYR', externalReference: 'E2E/ROUTE-001',
          invoiceId: issued.invoiceId, receivedAt: isoSeconds(new Date(Date.now() - 60000)),
          reason: 'Bank statement checked',
        }, 'route-payment-0001');
        await staffCall('owner', 'POST', `/companies/${record.tenantId}/payments/${payment.entryId}/check`);
        await lifecycle('active', 0, 'route-activate-0001');
        note(`company ${record.tenantId} active from payment ${payment.entryId}`);
      });

      await t.step('supervisor publishes a weekly route for the salesperson', async () => {
        const supS = await t.session('admin', { name: 'supervisor' });
        await B.loginAdmin(supS.page, `${supS.url}/w/${record.workspace}`, accounts.supervisor.email);
        await admin.waitForSupervisorShell(supS.page);
        await admin.goToPage(supS.page, 'Team Route Planner');
        await B.see(supS.page, 'No plan generated yet');
        const label = async () => {
          const button = supS.page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} – \d{1,2} [A-Z][a-z]{2}$/ });
          await button.waitFor({ timeout: 10000 });
          return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
        };
        const before = await label();
        await supS.page.getByRole('button', { name: 'Previous week' }).click();
        for (let i = 0; i < 50 && (await label()) === before; i += 1) await supS.page.waitForTimeout(200);
        await supS.page.getByRole('button', { name: 'Generate draft route' }).click();
        await supS.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
        await supS.page.getByRole('button', { name: 'Save draft' }).click();
        const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code, { label: 'route_plans' });
        planId = plan.id;
        await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
        await db.waitForDoc('route_plans', planId, (p) => p.status === 'approved');
        await supS.page.getByRole('button', { name: 'Publish', exact: true }).click();
        await B.see(supS.page, 'Publish this route?');
        await supS.page.getByRole('button', { name: 'Publish', exact: true }).last().click();
        const published = await db.waitForDoc('route_plans', planId, (p) => p.status === 'published', { timeout: 30000 });
        const stops = published.days.flatMap((d) => d.stops || []);
        check(stops.length >= 2, `the route has ${stops.length} stops, two are needed`);
        stopB = stops[1].stopId;
        note(`route ${planId} published with ${stops.length} stops`);
      });

      await t.step('salesperson starts the route and has an active work session', async () => {
        const profile = await db.get('users', accounts.salesman.email);
        await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
        await mobile.routeDayForSunday(db, planId);
        phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-sales' });
        await B.fakeGeolocation(phone.context, { latitude: RETAILERS[0].lat, longitude: RETAILERS[0].lng, accuracy: 10 });
        await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
        await mobile.waitForHome(phone.page);
        await mobile.openAssignedRoute(phone.page);
        await B.semantic(phone.page, /^Week$/).click();
        await mobile.acceptAndStartRoute(phone.page);
        await db.waitForQuery('route_plan_progress', (p) => p.planId === planId && p.status === 'in_progress', { label: 'route started' });
        await mobile.selectStop(phone.page);
        const progress = await db.waitForQuery('route_plan_progress', (p) => p.planId === planId && p.selectedStopId, { label: 'selected stop' });
        stopA = progress.selectedStopId;
        check(stopA !== stopB, 'the first and second stop must differ');
        await db.waitForDoc('live_tracking', seed.uids.salesman,
          (l) => l.workSessionStatus === 'active' && l.activeSessionId && l.workSessionStartedAt, { timeout: 30000, label: 'active work session' });
        await t.shot(phone, 'route-started');
        note(`route started; stop ${stopA} selected; work session active`);
      });

      await t.step('the phone goes offline and records an arrival before the cut', async () => {
        const plan = await db.get('route_plans', planId);
        const selected = plan.days.flatMap((d) => d.stops || []).find((st) => st.stopId === stopA);
        const retailer = RETAILERS.find((r) => r.id === selected.retailerId);
        await mobile.blockBackend(phone.page);
        await phone.context.setOffline(true);
        await B.moveDevice(phone.page, { latitude: retailer.lat, longitude: retailer.lng, accuracy: 10 });
        await mobile.markArrived(phone.page);
        await B.see(phone.page, 'Check arrival against published pin');
        await phone.page.getByRole('button', { name: 'Check GPS', exact: true }).click();
        await sleep(8000);
        equal((await stopRows()).length, 0, 'route_stop_progress while the phone is offline');
        await t.shot(phone, 'arrival-recorded-offline');
        note('arrival recorded offline before the suspension; nothing reached route_stop_progress');
      });

      await t.step('operator suspends the company through the staff API', async () => {
        const { projected } = await lifecycle('suspended', 1, 'route-suspend-0001', { approval: 'suspend' });
        check(projected.access && projected.access !== 'open', `access after suspension: ${JSON.stringify(projected.access)}`);
        check(projected.cutAt && projected.drainUntil, 'cutAt and drainUntil are stamped');
        const live = await db.get('live_tracking', seed.uids.salesman);
        equal([live.workSessionStatus, live.endedReason], ['ended', 'company_paused'], 'work session ended by the suspension');
        await snapshot('after-suspension');
        note(`suspended: access ${projected.access}, drain until ${projected.drainUntil}`);
      });

      await t.step('the phone records a skip after the cut with its clock ten minutes ahead', async () => {
        await shiftPageClock(phone.page, CLOCK_AHEAD_MS);
        const skip = phone.page.getByRole('button', { name: 'Skip', exact: true }).nth(1);
        await B.scrollIntoView(phone.page, skip, { minHeight: 20, pointerY: 0.8 });
        await skip.click();
        await B.see(phone.page, 'Skip reason');
        await B.semantic(phone.page, 'Retailer closed').click();
        await sleep(8000);
        equal((await stopRows()).length, 0, 'route_stop_progress while the phone is still offline');
        note(`skip of stop ${stopB} recorded offline with the device clock ten minutes ahead of the cut`);
      });

      await t.step('the phone reconnects and shows the Company paused screen with the held count', async () => {
        await phone.page.route('**/held-work', holdUpload);
        await phone.context.setOffline(false);
        await mobile.unblockBackend(phone.page);
        await B.see(phone.page, 'Company paused', { timeout: 120000 });
        await B.see(phone.page, /items? (is|are) held on this phone/, { timeout: 30000 });
        await B.see(phone.page, 'Your work is kept and will upload when the company is active again.');
        equal(await phone.page.getByRole('button', { name: /^Sign in$/ }).count(), 0, 'the phone stayed signed in');
        await t.shot(phone, 'company-paused-held');
        note('Company paused screen shown with held items; the user stayed signed in');
      });

      await t.step('inside the drain window the held arrival reaches route_stop_progress and the later skip does not', async () => {
        await phone.page.unroute('**/held-work', holdUpload);
        await phone.page.getByRole('button', { name: 'Check again' }).click();
        const arrival = await db.waitForQuery('route_stop_progress',
          (s) => s.planId === planId && s.stopId === stopA && s.status === 'arrived', { timeout: 60000, label: 'held arrival' });
        equal(arrival.salesmanUid, seed.uids.salesman, 'arrival owner');
        equal(arrival.source, 'held_work', 'arrival source');
        await sleep(3000);
        const rows = await stopRows();
        equal(rows.map((r) => r.stopId), [stopA], 'route_stop_progress stops after the drain upload');
        check(!rows.some((r) => r.status === 'skipped'), 'the skip recorded after the cut was stored');
        await B.see(phone.page, 'No work is held on this phone.', { timeout: 30000 });
        await B.see(phone.page, /1 item was not accepted/);
        await B.see(phone.page, /Your manager can review it/);
        equal(await B.semantic(phone.page, /Record it again|could not sync|waiting to sync/).count(), 0, 'record-again or sync text during the pause');
        await t.shot(phone, 'drain-upload-done');
        await snapshot('after-drain-upload');
        note(`held arrival stored for ${stopA} with source held_work; skip for ${stopB} not stored; phone shows it as not accepted`);
      });

      await t.step('operator reactivates and the phone returns to work with nothing dropped', async () => {
        const { projected } = await lifecycle('active', 2, 'route-reactivate-0001', { approval: 'reactivate' });
        check(projected.access === 'open' && projected.reactivatedAt, 'access is open with reactivatedAt');
        await phone.page.getByRole('button', { name: 'Check again' }).click();
        await phone.page.getByRole('button', { name: 'Check again' }).waitFor({ state: 'detached', timeout: 60000 });
        await mobile.waitForHome(phone.page);
        await sleep(3000);
        const rows = await stopRows();
        equal(rows.map((r) => r.stopId), [stopA], 'route_stop_progress stops after reactivation');
        equal((await db.list('orders')).length, 0, 'orders after reactivation');
        await t.shot(phone, 'back-to-work');
        await snapshot('after-reactivation');
        note('reactivated: Home is back, the arrival is stored once, the late skip stays out of route_stop_progress');
      });

      let endedSession;
      await t.step('the work session the pause ended is closed on the phone and the refused skip waits under Needs attention', async () => {
        endedSession = await db.get('live_tracking', seed.uids.salesman);
        equal([endedSession.workSessionStatus, endedSession.endedReason], ['ended', 'company_paused'], 'work session after reactivation');
        equal(await B.semantic(phone.page, /End status is waiting to sync|could not sync/).count(), 0, 'end work pending text on Home');
        await B.see(phone.page, 'Work not started', { timeout: 30000 });
        await t.shot(phone, 'work-not-started-after-pause');
        await phone.page.getByRole('button', { name: 'Start', exact: true }).first().click();
        await db.waitForDoc('live_tracking', seed.uids.salesman,
          (l) => l.workSessionStatus === 'active' && l.activeSessionId && l.activeSessionId !== endedSession.activeSessionId,
          { timeout: 30000, label: 'new work session after reactivation' });
        await B.see(phone.page, '1 item needs attention', { timeout: 30000 });
        await phone.page.getByRole('button', { name: 'Review', exact: true }).click();
        await B.see(phone.page, 'Stop skipped');
        await B.see(phone.page, 'This was recorded after the company was paused, so it was not accepted.');
        equal(await B.semantic(phone.page, /Record it again|record it again/).count(), 0, 'record-again text on the refused skip');
        await t.shot(phone, 'needs-attention-after-pause');
        note('End work finished by the pause: the phone shows Work not started, starts a new session, and lists the late skip under Needs attention with the pause reason');
      });

      await t.step('the route is closed on the server and the phone clears the stuck skip', async () => {
        const { approvedAt: _approvedAt, publishedAt: _publishedAt, ...plan } = await db.get('route_plans', planId);
        await db.put('route_plans', planId, { ...plan, status: 'draft' });
        await phone.page.getByRole('button', { name: 'Back' }).first().click();
        await B.semantic(phone.page, /stops? today · Assigned by/).first().waitFor({ state: 'detached', timeout: 30000 });
        await t.shot(phone, 'route-withdrawn-home');
        await phone.page.getByRole('button', { name: 'Review', exact: true }).click();
        await B.see(phone.page, 'Stop skipped');
        await phone.page.getByRole('button', { name: 'Send again', exact: true }).first().click();
        await B.see(phone.page, 'That route is no longer yours, so this update cannot be sent again. You can remove it.', { timeout: 30000 });
        await t.shot(phone, 'route-closed-send-again');
        await phone.page.getByRole('button', { name: 'Remove', exact: true }).first().click();
        await B.see(phone.page, 'Remove this item?');
        await phone.page.getByRole('button', { name: 'Remove', exact: true }).last().click();
        await B.semantic(phone.page, 'Stop skipped').waitFor({ state: 'detached', timeout: 20000 });
        const rows = await stopRows();
        equal(rows.map((r) => r.stopId), [stopA], 'route_stop_progress stops after the stuck skip is removed');
        await t.shot(phone, 'stuck-skip-removed');
        await snapshot('after-route-closed');
        note(`route ${planId} closed on the server; Send again names the closed route; the skip is removed from the phone and the server keeps only ${stopA}`);
      });
    } finally {
      if (priorEmulatorProjects === undefined) delete process.env.PLATFORM_EMULATOR_PROJECTS;
      else process.env.PLATFORM_EMULATOR_PROJECTS = priorEmulatorProjects;
      fs.writeFileSync(path.join(out, 'route-suspension-evidence.json'), JSON.stringify(evidence, null, 2));
      for (const server of servers.reverse()) await server.stop();
    }
  },
};
