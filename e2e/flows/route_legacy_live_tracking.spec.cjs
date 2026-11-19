'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const E = require('../lib/emulator.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];

module.exports = {
  name: 'route_legacy_live_tracking',
  async run(t) {
    const { db, accounts, seed } = t;
    let supS;
    let planId;

    await t.step('supervisor logs in on the dashboard', async () => {
      supS = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await B.see(supS.page, /1 sales rep assigned/);
    });

    await t.step('supervisor opens the route planner for S001', async () => {
      await admin.goToPage(supS.page, 'Team Route Planner');
      await B.see(supS.page, 'No plan generated yet');
      await B.see(supS.page, accounts.salesman.name);
      await t.shot(supS, 'planner');
    });

    await t.step('supervisor plans THIS week and generates a weekly draft that includes the retailer', async () => {
      const before = await weekLabel(supS.page);
      await supS.page.getByRole('button', { name: 'Previous week' }).click();
      for (let i = 0; i < 50 && (await weekLabel(supS.page)) === before; i += 1) await supS.page.waitForTimeout(200);
      if ((await weekLabel(supS.page)) === before) throw new Error('the planner week did not change');
      await supS.page.getByRole('button', { name: 'Generate draft route' }).click();
      await supS.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
      await B.see(supS.page, /Stops: [1-9]/);
      await B.see(supS.page, RETAILER.name);
      await t.shot(supS, 'draft');
    });

    await t.step('supervisor saves the draft', async () => {
      await supS.page.getByRole('button', { name: 'Save draft' }).click();
      const plan = await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code, { label: 'route_plans' });
      planId = plan.id;
      expectEqual(plan.status, 'draft', 'plan status');
      expectEqual(plan.salesmanUid, seed.uids.salesman, 'plan salesmanUid');
      expectEqual(plan.createdByRole, 'supervisor', 'plan createdByRole');
      expectEqual(plan.branchId, 'B1', 'plan branchId');
      const stops = plan.days.flatMap((d) => d.stops || []);
      if (!stops.some((st) => st.retailerId === RETAILER.id)) throw new Error('saved plan has no stop for ' + RETAILER.id);
      await B.see(supS.page, /This is a draft/);
    });

    await t.step('supervisor approves the plan', async () => {
      await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
      const plan = await db.waitForDoc('route_plans', planId, (p) => p.status === 'approved');
      if (!plan.approvedAt) throw new Error('approved plan has no approvedAt');
      await B.see(supS.page, /Approved, but not assigned yet|Select Publish to assign/);
    });

    await t.step('supervisor publishes the plan (the fixed path)', async () => {
      await supS.page.getByRole('button', { name: 'Publish', exact: true }).click();
      await B.see(supS.page, 'Publish this route?');
      await t.shot(supS, 'publish-dialog');
      await supS.page.getByRole('button', { name: 'Publish', exact: true }).last().click();
      const plan = await db.waitForDoc('route_plans', planId, (p) => p.status === 'published', { timeout: 30000 });
      if (!plan.publishedAt) throw new Error('published plan has no publishedAt');
      const key = await db.waitForQuery('route_plan_publication_keys', (k) => k.planId === planId, { label: 'publication key' });
      expectEqual(key.active, true, 'publication key active');
      expectEqual(key.salesmanUid, seed.uids.salesman, 'publication key salesmanUid');
      await B.see(supS.page, /Published and assigned|assigned to/);
      await t.shot(supS, 'published');
    });

    let mobileS;
    await t.step('salesman sees the assigned route stop on mobile', async () => {
      const profile = await db.get('users', accounts.salesman.email);
      await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
      await db.put('live_tracking', seed.uids.salesman, { salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code,
        branchId: accounts.salesman.branch, latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 12, status: 'active',
        updatedAt: new Date(Date.now() - 120000), lastUpdated: new Date(Date.now() - 120000) });
      const migrate = (extra) => JSON.parse(platform.python(['-m', 'platform_service.live_tracking_migration', '--project', E.PROJECT, ...extra],
        { env: { PLATFORM_EMULATOR_PROJECTS: E.PROJECT } }));
      expectEqual(migrate([]).convertible.join(','), seed.uids.salesman, 'dry run lists the legacy row');
      expectEqual(migrate(['--apply', '--confirm-project', E.PROJECT]).applied.written, 1, 'migration writes one row');
      expectEqual((await db.get('live_tracking', seed.uids.salesman)).uid, seed.uids.salesman, 'legacy row now names its owner');
      await mobile.routeDayForSunday(db, planId);
      mobileS = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.fakeGeolocation(mobileS.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await B.loginMobile(mobileS.page, mobileS.url, accounts.salesman.email);
      await mobile.waitForHome(mobileS.page);
      await mobile.openAssignedRoute(mobileS.page);
      await B.see(mobileS.page, /\d+ stop\(s\)/);
      await B.semantic(mobileS.page, /^Week$/).click();
      for (const r of RETAILERS) await B.see(mobileS.page, r.name);
      await t.shot(mobileS, 'assigned-route');
    });

    await t.step('salesman accepts and starts the route', async () => {
      await mobile.acceptAndStartRoute(mobileS.page);
      const progress = await db.waitForQuery('route_plan_progress', (p) => p.planId === planId && p.status === 'in_progress', { label: 'route_plan_progress' });
      expectEqual(progress.salesmanUid, seed.uids.salesman, 'progress owner');
    });

    await t.step('salesman marks arrival at the selected stop with a GPS fix', async () => {
      await mobile.selectStop(mobileS.page);
      const progress = await db.waitForQuery('route_plan_progress', (p) => p.planId === planId && p.selectedStopId, { label: 'selected stop' });
      const plan = await db.get('route_plans', planId);
      const selected = plan.days.flatMap((d) => d.stops || []).find((st) => st.stopId === progress.selectedStopId);
      if (!selected) throw new Error('selected stop ' + progress.selectedStopId + ' is not in the plan');
      const retailer = RETAILERS.find((r) => r.id === selected.retailerId);
      await B.moveDevice(mobileS.page, { latitude: retailer.lat, longitude: retailer.lng, accuracy: 10 });
      await mobile.markArrived(mobileS.page);
      const stop = await db.waitForQuery('route_stop_progress', (a) => a.planId === planId && a.status === 'arrived', { label: 'stop arrival' });
      expectEqual(stop.retailerId, selected.retailerId, 'arrived retailer');
      expectEqual(stop.salesmanUid, seed.uids.salesman, 'arrival salesmanUid');
      await B.see(mobileS.page, 'Arrival: GPS verified');
      await t.shot(mobileS, 'arrived');
    });

    await t.step('Scout opens the visit brief and steps aside for it', async () => {
      const page = mobileS.page;
      await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      const input = page.getByRole('textbox', { name: /Ask or say a command/ });
      await B.fillField(page, input, 'show the visit brief');
      await page.keyboard.press('Enter');
      await B.see(page, /Visit brief · /);
      await input.waitFor({ state: 'detached', timeout: 15000 });
      await t.shot(mobileS, 'visit-brief');
      await page.getByRole('button', { name: 'Close', exact: true }).click();
      await B.see(page, 'Arrival: GPS verified');
    });

    await t.step('the salesman\'s live location reaches live_tracking', async () => {
      const live = await db.waitForDoc('live_tracking', seed.uids.salesman, (l) => typeof l.latitude === 'number', { timeout: 15000, label: 'live_tracking position' });
      if (Math.abs(live.latitude - RETAILER.lat) > 0.1) throw new Error('live_tracking latitude is not near the retailers: ' + live.latitude);
      const crumbs = (await db.list('gps_tracking')).filter((c) => c.activeSessionId);
      if (!crumbs.length) throw new Error('no gps_tracking breadcrumb was written');
    });

    await t.step('the dashboard fleet view shows the salesman with a recent phone position', async () => {
      const live = await db.get('live_tracking', seed.uids.salesman);
      const fleet = await t.session('admin', { name: 'fleet-admin' });
      await B.loginAdmin(fleet.page, fleet.url, accounts.admin.email);
      await admin.waitForShell(fleet.page);
      await admin.goToPage(fleet.page, 'Salesman Tracking');
      await fleet.page.getByRole('button', { name: /^(Load positions|Load)$/ }).first().click({ timeout: 3000 }).catch(() => null);
      const row = fleet.page.getByRole('button', { name: new RegExp(`^${accounts.salesman.name}, Fresh fix\\.`) });
      await row.waitFor({ timeout: 60000 });
      await row.click();
      await B.see(fleet.page, `${live.latitude.toFixed(5)}, ${live.longitude.toFixed(5)}`);
      await B.see(fleet.page, /Position age: (just now|\d+ (s|min) ago) · ±10 m/);
      await t.shot(fleet, 'fleet-position');
    });

    await t.step('a branch manager sees the planner view-only', async () => {
      const bmS = await t.session('admin', { name: 'branch-manager' });
      await B.loginAdmin(bmS.page, bmS.url, accounts.branchManager.email);
      await admin.waitForBranchManagerShell(bmS.page);
      await admin.goToPage(bmS.page, 'Branch Routes (view only)');
      await B.see(bmS.page, accounts.salesman.name);
      await bmS.page.getByRole('button', { name: /^Saved plans/ }).click();
      await B.see(bmS.page, /Mobile status: In Progress/, { timeout: 30000 });
      await bmS.page.getByRole('button', { name: 'View', exact: true }).click();
      await bmS.page.getByRole('button', { name: 'Plan', exact: true }).click();
      await B.see(bmS.page, 'View only');
      await B.see(bmS.page, RETAILER.name);
      for (const label of ['Generate draft route', 'Save draft', 'Save changes', 'Approve', 'Publish']) {
        expectEqual(await bmS.page.getByRole('button', { name: label, exact: true }).count(), 0, `"${label}" buttons shown to a branch manager`);
      }
      await t.shot(bmS, 'view-only');
    });
  },
};

async function weekLabel(page) {
  const button = page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} \u2013 \d{1,2} [A-Z][a-z]{2}$/ });
  await button.waitFor({ timeout: 10000 });
  return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
}

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
