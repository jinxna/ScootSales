'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];

module.exports = {
  name: 'route_plan_visit',
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

    const progressId = (id) => `${id}_${seed.uids.salesman}`;
    const skipFirstStop = async (page) => {
      const skip = page.getByRole('button', { name: 'Skip', exact: true }).first();
      await B.scrollIntoView(page, skip, { minHeight: 20, pointerY: 0.8 });
      await skip.click();
      await B.see(page, 'Skip reason');
      await B.semantic(page, 'Retailer closed').click();
    };
    const openSeededRoute = async (page) => {
      await page.getByRole('button', { name: 'Accept route' }).waitFor({ timeout: 30000 });
      await mobile.acceptAndStartRoute(page);
      await B.semantic(page, /^Week$/).click();
    };

    let codePlanId;
    await t.step('a published route whose salesmanCode differs from the profile code: the salesperson skips a stop and the skip is stored', async () => {
      const base = await db.get('route_plans', planId);
      const stops = base.days.flatMap((d) => d.stops || []);
      if (stops.length < 2) throw new Error(`the published plan has ${stops.length} stops, two are needed`);
      codePlanId = `${planId}-code`;
      await db.put('route_plans', planId, { ...base, status: 'archived' });
      await db.put('route_plans', codePlanId, { ...base, planId: codePlanId, salesmanCode: `${accounts.salesman.code}-OLD` });
      const page = mobileS.page;
      await openSeededRoute(page);
      await db.waitForDoc('route_plan_progress', progressId(codePlanId), (p) => p.status === 'in_progress', { label: 'seeded route started' });
      for (const s of stops) await B.semantic(page, s.retailerName).waitFor({ state: 'visible', timeout: 30000 });
      await skipFirstStop(page);
      const stop = await db.waitForQuery('route_stop_progress', (s) => s.planId === codePlanId && s.status === 'skipped', { timeout: 30000, label: 'skip stored' });
      const skippedName = stops.find((s) => s.stopId === stop.stopId).retailerName;
      const otherName = stops.find((s) => s.stopId !== stop.stopId).retailerName;
      await B.semantic(page, skippedName).waitFor({ state: 'hidden', timeout: 30000 });
      await B.semantic(page, otherName).waitFor({ state: 'visible', timeout: 30000 });
      expectEqual(stop.salesmanCode, accounts.salesman.code, 'skipped stop salesmanCode');
      expectEqual(stop.salesmanUid, seed.uids.salesman, 'skipped stop salesmanUid');
      expectEqual(stop.skipReason, 'Retailer closed', 'skip reason');
      const parent = await db.get('route_plan_progress', progressId(codePlanId));
      expectEqual(parent.salesmanCode, stop.salesmanCode, 'parent salesmanCode');
      expectEqual(parent.status, 'in_progress', 'parent status after one of several stops');
      expectEqual(JSON.stringify(parent.handledStopIds), JSON.stringify([stop.stopId]), 'parent handledStopIds');
      await t.shot(mobileS, 'skip-other-plan-code');
    });

    await t.step('a started route with exactly one stop: the salesperson skips it and the route ends completed', async () => {
      const base = await db.get('route_plans', codePlanId);
      const only = base.days.flatMap((d) => d.stops || [])[0];
      const onePlanId = `${planId}-one`;
      const keep = (map) => (map && map[only.stopId] !== undefined ? { [only.stopId]: map[only.stopId] } : {});
      await db.put('route_plans', codePlanId, { ...base, status: 'archived' });
      await db.put('route_plans', onePlanId, {
        ...base,
        planId: onePlanId,
        salesmanCode: accounts.salesman.code,
        days: base.days.map((d) => ({ ...d, stops: (d.stops || []).filter((s) => s.stopId === only.stopId) })),
        stopIds: [only.stopId],
        stopRetailerIds: keep(base.stopRetailerIds),
        stopCoordinateSnapshots: keep(base.stopCoordinateSnapshots),
        totalStops: 1,
      });
      const page = mobileS.page;
      await openSeededRoute(page);
      await db.waitForDoc('route_plan_progress', progressId(onePlanId), (p) => p.status === 'in_progress', { label: 'one-stop route started' });
      await skipFirstStop(page);
      await B.see(page, 'No active assigned route', { timeout: 30000 });
      const parent = await db.waitForDoc('route_plan_progress', progressId(onePlanId), (p) => p.status === 'completed', { timeout: 30000, label: 'one-stop route completed' });
      expectEqual(JSON.stringify(parent.handledStopIds), JSON.stringify([only.stopId]), 'one-stop handledStopIds');
      expectEqual(parent.routeSessionState, 'completed', 'one-stop routeSessionState');
      const stop = await db.waitForQuery('route_stop_progress', (s) => s.planId === onePlanId && s.stopId === only.stopId, { label: 'one-stop skip stored' });
      expectEqual(stop.status, 'skipped', 'one-stop stop status');
      expectEqual(stop.salesmanCode, parent.salesmanCode, 'one-stop stop and parent salesmanCode');
      await t.shot(mobileS, 'one-stop-route-completed');
    });
    await t.step('more than 30 published plans: the current week is still read and started', async () => {
      const base = await db.get('route_plans', codePlanId);
      const onePlanId = `${planId}-one`;
      const one = await db.get('route_plans', onePlanId);
      await db.put('route_plans', onePlanId, { ...one, status: 'archived' });
      const weekMs = 7 * 24 * 3600 * 1000;
      const mine = { ...base, status: 'published', salesmanCode: accounts.salesman.code };
      for (let i = 0; i < 35; i += 1) {
        const oldId = `${planId}-old-${String(i).padStart(2, '0')}`;
        await db.put('route_plans', oldId, { ...mine, planId: oldId, weekStart: new Date(base.weekStart.getTime() - (i + 2) * weekMs) });
      }
      const nowId = `${planId}-zz-now`;
      await db.put('route_plans', nowId, { ...mine, planId: nowId });
      const page = mobileS.page;
      await page.waitForFunction(
        () => [...document.querySelectorAll('flt-semantics[role="button"]')]
          .filter((n) => n.textContent === 'Accept route' && n.getAttribute('aria-disabled') !== 'true').length === 1,
        null,
        { timeout: 30000 },
      );
      await openSeededRoute(page);
      await db.waitForDoc('route_plan_progress', progressId(nowId), (p) => p.status === 'in_progress', { timeout: 30000, label: 'current week route started among 36 published plans' });
      await t.shot(mobileS, 'current-week-among-many-plans');
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
