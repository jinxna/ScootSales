'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const admin = require('../lib/admin.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];
const WIDTH = Number(process.env.E2E_SUP_WIDTH || 1600);

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

async function weekLabel(page) {
  const button = page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} – \d{1,2} [A-Z][a-z]{2}$/ });
  await button.waitFor({ timeout: 10000 });
  return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
}

async function publish(page) {
  await page.getByRole('button', { name: 'Publish', exact: true }).click();
  await B.see(page, 'Publish this route?');
  await page.getByRole('button', { name: 'Publish', exact: true }).last().click();
}

module.exports = {
  name: 'route_correction',
  async run(t) {
    const { db, accounts, seed } = t;
    let supS;
    let planA;
    let planB;
    let keyId;

    await t.step('supervisor saves and approves a draft for this week', async () => {
      supS = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Team Route Planner');
      await supS.page.setViewportSize({ width: WIDTH, height: WIDTH < 800 ? 844 : 1000 });
      await supS.page.waitForTimeout(1500);
      const before = await weekLabel(supS.page);
      await supS.page.getByRole('button', { name: 'Previous week' }).click();
      for (let i = 0; i < 50 && (await weekLabel(supS.page)) === before; i += 1) await supS.page.waitForTimeout(200);
      await supS.page.getByRole('button', { name: 'Generate draft route' }).click();
      await supS.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
      await supS.page.getByRole('button', { name: 'Save draft' }).click();
      planA = (await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code, { label: 'route_plans' })).id;
      await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'approved');
    });

    await t.step('an approved route goes back to draft with one button, then is approved again', async () => {
      await t.shot(supS, 'approved-before-back-to-draft-' + WIDTH);
      await supS.page.getByRole('button', { name: 'Back to draft', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'draft');
      await B.see(supS.page, /This is a draft/);
      await t.shot(supS, 'back-to-draft-done-' + WIDTH);
      await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'approved');
    });

    await t.step('publishing A then withdrawing it releases the publish key', async () => {
      await publish(supS.page);
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'published', { timeout: 30000 });
      const key = await db.waitForQuery('route_plan_publication_keys', (k) => k.planId === planA, { label: 'publication key' });
      keyId = key.id;
      expectEqual(key.active, true, 'key active after publish');
      await supS.page.getByRole('button', { name: 'Withdraw to edit', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'draft');
      expectEqual((await db.get('route_plan_publication_keys', keyId)).active, false, 'key released by withdraw');
      await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'approved');
      await publish(supS.page);
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'published', { timeout: 30000 });
      expectEqual((await db.get('route_plan_publication_keys', keyId)).active, true, 'key active after republish');
    });

    let phone;
    await t.step('the salesman starts the route and taps a stop', async () => {
      const profile = await db.get('users', accounts.salesman.email);
      await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
      await mobile.routeDayForSunday(db, planA);
      phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      await B.fakeGeolocation(phone.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
      await mobile.waitForHome(phone.page);
      await mobile.openAssignedRoute(phone.page);
      await B.semantic(phone.page, /^Week$/).click();
      await mobile.acceptAndStartRoute(phone.page);
      await mobile.selectStop(phone.page);
      await db.waitForQuery('route_plan_progress', (p) => p.planId === planA && p.selectedStopId, { label: 'selected stop' });
    });

    await t.step('withdraw now offers Replace route; the recorded work stays', async () => {
      await supS.page.getByRole('button', { name: 'Withdraw to edit', exact: true }).click();
      await B.see(supS.page, 'Replace this route?');
      await t.shot(supS, 'replace-route-dialog-' + WIDTH);
      await supS.page.getByRole('button', { name: 'Replace route', exact: true }).click();
      await db.waitForDoc('route_plans', planA, (p) => p.status === 'archived');
      const drafts = (await db.list('route_plans')).filter((p) => p.status === 'draft' && p.salesmanCode === accounts.salesman.code);
      expectEqual(drafts.length, 1, 'new draft routes');
      planB = drafts[0].id;
      expectEqual((await db.get('route_plan_publication_keys', keyId)).active, false, 'key released by replace');
      const progress = await db.get('route_plan_progress', `${planA}_${seed.uids.salesman}`);
      expectEqual(progress.planId, planA, 'progress of the replaced route is kept');
      await B.see(supS.page, /This is a draft/);
      await t.shot(supS, 'replaced-new-draft-' + WIDTH);
    });

    await t.step('the salesman no longer sees route A', async () => {
      const later = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-after-replace' });
      await B.loginMobile(later.page, later.url, accounts.salesman.email);
      await mobile.waitForHome(later.page);
      await mobile.openAssignedRoute(later.page).catch(() => null);
      await B.see(later.page, /No assigned route|No active assigned route/);
    });

    await t.step('route B publishes for the same week and the key moves to B', async () => {
      await supS.page.getByRole('button', { name: 'Approve', exact: true }).click();
      await db.waitForDoc('route_plans', planB, (p) => p.status === 'approved');
      await publish(supS.page);
      await db.waitForDoc('route_plans', planB, (p) => p.status === 'published', { timeout: 30000 });
      const key = await db.get('route_plan_publication_keys', keyId);
      expectEqual([key.planId, key.active], [planB, true], 'key after route B publishes');
    });

    await t.step('the salesman sees route B', async () => {
      await mobile.routeDayForSunday(db, planB);
      const again = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, name: 'mobile-route-b' });
      await B.loginMobile(again.page, again.url, accounts.salesman.email);
      await mobile.waitForHome(again.page);
      await mobile.openAssignedRoute(again.page);
      await B.see(again.page, /\d+ stop\(s\)/);
    });
  },
};
