'use strict';

const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const FAR_AWAY = { latitude: 2.3, longitude: 111.83, accuracy: 10 };
const RESTART_PLAN = 'plan-e2e-end-work-restart';
const WRITE_PLAN = 'plan-e2e-end-work-write-stream';
const DAY_MS = 86400000;
const near = (a, b) => Math.abs(a - b) < 1e-4;
const millis = (value) => (value instanceof Date ? value.getTime() : new Date(value).getTime());

async function weekLabel(page) {
  const button = page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} – \d{1,2} [A-Z][a-z]{2}$/ });
  await button.waitFor({ timeout: 10000 });
  return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
}

async function pressWorkButton(page, label) {
  await mobile.openTab(page, 'Profile');
  const button = page.getByRole('button', { name: label, exact: true });
  await B.scrollIntoView(page, button, { minHeight: 20 });
  await button.click();
}

async function skipStop(page, index) {
  const skip = page.getByRole('button', { name: 'Skip', exact: true }).nth(index);
  await B.scrollIntoView(page, skip, { minHeight: 20, pointerY: 0.8 });
  await skip.click();
  await B.see(page, 'Skip reason');
  await B.semantic(page, 'Retailer closed').click();
}

module.exports = {
  name: 'mobile_end_work_keeps_records',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const result = {};
    let planId;
    let phone;
    let firstSession;
    let secondSession;
    let skippedStop;
    let arrivedStop;

    const live = () => db.get('live_tracking', uid);
    const stopRows = async () => (await db.list('route_stop_progress')).filter((row) => row.planId === planId);
    const goOffline = async () => {
      await mobile.blockBackend(phone.page);
      await phone.context.setOffline(true);
    };
    const goOnline = async () => {
      await phone.context.setOffline(false);
      await mobile.unblockBackend(phone.page);
    };
    const expectNoPositionFrom = async (place, label) => {
      const now = await live();
      assert.ok(!(near(now.latitude, place.latitude) && near(now.longitude, place.longitude)), `${label}: live_tracking holds a position taken after End Work`);
      const crumbs = (await db.list('gps_tracking')).filter((c) => typeof c.latitude === 'number' && near(c.latitude, place.latitude) && near(c.longitude, place.longitude));
      assert.equal(crumbs.length, 0, `${label}: gps_tracking holds a position taken after End Work`);
    };

    await t.step('supervisor publishes a route for this week', async () => {
      const supS = await t.session('admin', { name: 'supervisor' });
      await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supS.page);
      await admin.goToPage(supS.page, 'Team Route Planner');
      await B.see(supS.page, 'No plan generated yet');
      const before = await weekLabel(supS.page);
      await supS.page.getByRole('button', { name: 'Previous week' }).click();
      for (let i = 0; i < 50 && (await weekLabel(supS.page)) === before; i += 1) await supS.page.waitForTimeout(200);
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
      assert.ok(published.days.flatMap((d) => d.stops || []).length >= 2, 'the route needs two stops');
    });

    await t.step('salesperson starts the route with an active work session', async () => {
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
      const session = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'active' && l.activeSessionId, { timeout: 30000, label: 'active work session' });
      firstSession = session.activeSessionId;
    });

    await t.step('online case: a skip recorded with no signal is still waiting when End Work is pressed', async () => {
      await goOffline();
      await skipStop(phone.page, 1);
      await phone.page.waitForTimeout(8000);
      assert.equal((await stopRows()).length, 0, 'nothing reached route_stop_progress while the phone had no signal');
      await mobile.openTab(phone.page, 'Profile');
      await goOnline();
      await phone.page.waitForTimeout(3000);
      await pressWorkButton(phone.page, 'End Work');
      await B.moveDevice(phone.page, FAR_AWAY);
    });

    await t.step('online case: the skip reaches the server and the session ends after it', async () => {
      const ended = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'ended' && l.activeSessionId === firstSession, { timeout: 90000, label: 'first work session ended' });
      const rows = await stopRows();
      assert.deepEqual(rows.map((row) => row.status), ['skipped'], 'the skip recorded with no signal is stored');
      assert.equal(rows[0].workSessionId, firstSession);
      assert.ok(millis(rows[0].updatedAt) <= millis(ended.workSessionEndedAt), 'the stop event was stored before the session ended');
      skippedStop = rows[0].stopId;
      await B.see(phone.page, /^Work ended on this device\.$/, { timeout: 30000 });
      await phone.page.waitForTimeout(8000);
      await expectNoPositionFrom(FAR_AWAY, 'online case');
      result.online = { session: firstSession, stopId: skippedStop, stopStoredAt: new Date(millis(rows[0].updatedAt)).toISOString(), sessionEndedAt: new Date(millis(ended.workSessionEndedAt)).toISOString() };
      await t.shot(phone, 'online-end-work');
    });

    await t.step('salesperson starts work again and selects the open stop', async () => {
      await B.moveDevice(phone.page, { latitude: RETAILERS[0].lat, longitude: RETAILERS[0].lng, accuracy: 10 });
      await pressWorkButton(phone.page, 'Start Work');
      const session = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'active' && l.activeSessionId && l.activeSessionId !== firstSession, { timeout: 60000, label: 'second work session' });
      secondSession = session.activeSessionId;
      await mobile.openAssignedRoute(phone.page);
      await B.semantic(phone.page, /^Week$/).click();
      await mobile.selectStop(phone.page);
      const progress = await db.waitForQuery('route_plan_progress', (p) => p.planId === planId && p.selectedStopId && p.selectedStopId !== skippedStop, { label: 'selected stop' });
      arrivedStop = progress.selectedStopId;
    });

    await t.step('no-signal case: an arrival and a skip are recorded, then End Work is pressed', async () => {
      const plan = await db.get('route_plans', planId);
      const selected = plan.days.flatMap((d) => d.stops || []).find((st) => st.stopId === arrivedStop);
      const retailer = RETAILERS.find((r) => r.id === selected.retailerId);
      await goOffline();
      await B.moveDevice(phone.page, { latitude: retailer.lat, longitude: retailer.lng, accuracy: 10 });
      await mobile.markArrived(phone.page);
      await B.see(phone.page, 'Check arrival against published pin');
      await phone.page.getByRole('button', { name: 'Check GPS', exact: true }).click();
      await phone.page.waitForTimeout(8000);
      await skipStop(phone.page, 0);
      await phone.page.waitForTimeout(8000);
      assert.deepEqual((await stopRows()).map((row) => row.stopId), [skippedStop], 'the arrival and the skip stayed on the phone');
      await pressWorkButton(phone.page, 'End Work');
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 90000 });
      await B.moveDevice(phone.page, FAR_AWAY);
      await phone.page.waitForTimeout(8000);
      const waiting = await live();
      assert.deepEqual([waiting.workSessionStatus, waiting.activeSessionId], ['active', secondSession], 'the server session stays open while the stop events wait');
      await t.shot(phone, 'end-work-no-signal');
    });

    await t.step('no-signal case: back online both stop events reach the server and the session ends after them', async () => {
      await goOnline();
      const ended = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'ended' && l.activeSessionId === secondSession, { timeout: 120000, label: 'second work session ended' })
        .catch(async (error) => {
          const stored = (await stopRows()).map((item) => `${item.stopId}:${item.status}:${item.arrivalEventId || 'no arrival'}`).join(', ');
          throw new Error(`${error.message.slice(0, 60)}; route_stop_progress holds [${stored}]`);
        });
      const row = (await stopRows()).find((item) => item.stopId === arrivedStop);
      assert.ok(row, 'the stop recorded with no signal is stored');
      assert.equal(row.status, 'skipped', 'the skip recorded after the arrival is stored');
      assert.ok(row.arrivalEventId, 'the arrival recorded before the skip is stored');
      assert.equal(row.workSessionId, secondSession);
      assert.ok(millis(row.updatedAt) <= millis(ended.workSessionEndedAt), 'the stop events were stored before the session ended');
      await B.see(phone.page, /^Work ended on this device\.$/, { timeout: 30000 });
      await expectNoPositionFrom(FAR_AWAY, 'no-signal case');
      result.noSignal = { session: secondSession, stopId: arrivedStop, status: row.status, arrivalEventId: row.arrivalEventId, stopStoredAt: new Date(millis(row.updatedAt)).toISOString(), sessionEndedAt: new Date(millis(ended.workSessionEndedAt)).toISOString() };
      await t.shot(phone, 'end-work-after-reconnect');
    });

    const restartRows = async () => (await db.list('route_stop_progress')).filter((row) => row.planId === RESTART_PLAN);
    const startWorkOnDevice = async (previous, label) => {
      await B.moveDevice(phone.page, { latitude: RETAILERS[0].lat, longitude: RETAILERS[0].lng, accuracy: 10 });
      await pressWorkButton(phone.page, 'Start Work');
      const session = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'active' && l.activeSessionId && l.activeSessionId !== previous, { timeout: 60000, label });
      return session.activeSessionId;
    };
    const expectEndedWithItsSkip = async (session, alreadyStored, label) => {
      const ended = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'ended' && l.activeSessionId === session, { timeout: 150000, label })
        .catch(async (error) => {
          const stored = (await restartRows()).map((item) => `${item.stopId}:${item.status}:${item.workSessionId}`).join(', ');
          throw new Error(`${error.message.slice(0, 60)}; route_stop_progress holds [${stored}]`);
        });
      const rows = (await restartRows()).filter((row) => !alreadyStored.includes(row.stopId));
      assert.deepEqual(rows.map((row) => row.status), ['skipped'], `${label}: the skip recorded with no signal is stored once`);
      assert.equal(rows[0].workSessionId, session);
      assert.ok(millis(rows[0].updatedAt) <= millis(ended.workSessionEndedAt), `${label}: the stop event was stored before the session ended`);
      await B.see(phone.page, /^Work ended on this device\.$/, { timeout: 30000 });
      return { session, stopId: rows[0].stopId, stopStoredAt: new Date(millis(rows[0].updatedAt)).toISOString(), sessionEndedAt: new Date(millis(ended.workSessionEndedAt)).toISOString() };
    };
    let thirdSession;
    let fourthSession;

    await t.step('a second route is published and the salesperson starts work on it', async () => {
      const first = await db.get('route_plans', planId);
      await db.put('route_plans', planId, { ...first, status: 'archived' });
      const now = new Date();
      const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
      const stop = (stopId, shop, sequence) => ({
        stopId, dayId: 'day-1', retailerId: shop.id, retailerName: shop.name, address: `${shop.area}, Kuching`,
        lat: shop.lat, lng: shop.lng, sequence, estimatedArrival: '09:00', estimatedDeparture: '09:20',
        priorityReason: 'Prioritised: overdue 14d.', status: 'not_started', travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
      });
      await db.put('route_plans', RESTART_PLAN, {
        planId: RESTART_PLAN, createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
        salesmanName: accounts.salesman.name, branchId: 'B1',
        weekStart: new Date(noon.getTime() - 6 * DAY_MS), weekEnd: new Date(noon.getTime() + 6 * DAY_MS),
        publishedAt: now, status: 'published', source: 'dashboard', totalStops: 2, stopIds: ['restart-1', 'restart-2'],
        stopRetailerIds: { 'restart-1': RETAILERS[0].id, 'restart-2': RETAILERS[1].id },
        days: [{ dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 7, stops: [stop('restart-1', RETAILERS[0], 1), stop('restart-2', RETAILERS[1], 2)] }],
      });
      await mobile.routeDayForSunday(db, RESTART_PLAN);
      await mobile.reopenHome(phone.page, phone.url);
      thirdSession = await startWorkOnDevice(secondSession, 'third work session');
      await mobile.openAssignedRoute(phone.page);
      await mobile.acceptAndStartRoute(phone.page);
      await db.waitForQuery('route_plan_progress', (p) => p.planId === RESTART_PLAN && p.status === 'in_progress', { label: 'second route started' });
    });

    await t.step('restart case: a skip and End Work with no signal, then the app is closed and opened again with still no signal', async () => {
      await mobile.blockBackend(phone.page);
      await skipStop(phone.page, 1);
      await phone.page.waitForTimeout(8000);
      assert.equal((await restartRows()).length, 0, 'nothing reached route_stop_progress while the backend was unreachable');
      await pressWorkButton(phone.page, 'End Work');
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 90000 });
      await mobile.reopenHome(phone.page, phone.url);
      await mobile.openTab(phone.page, 'Profile');
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 150000 });
      const waiting = await live();
      assert.deepEqual([waiting.workSessionStatus, waiting.activeSessionId], ['active', thirdSession], 'the server session stays open after the app was opened again with no signal');
      assert.equal((await restartRows()).length, 0, 'the skip is still only on the phone after the app was opened again');
      await t.shot(phone, 'end-work-waiting-after-restart');
    });

    await t.step('restart case: the signal returns and, with no tap, the skip reaches the server and the session ends', async () => {
      await mobile.unblockBackend(phone.page);
      result.restart = await expectEndedWithItsSkip(thirdSession, [], 'restart case');
      await t.shot(phone, 'end-work-finished-after-restart');
    });

    await t.step('Start Work case: a skip and End Work with no signal, then Start Work is tapped while there is still no signal', async () => {
      fourthSession = await startWorkOnDevice(thirdSession, 'fourth work session');
      await mobile.openAssignedRoute(phone.page);
      await mobile.blockBackend(phone.page);
      await skipStop(phone.page, 0);
      await phone.page.waitForTimeout(8000);
      assert.deepEqual((await restartRows()).map((row) => row.stopId), [result.restart.stopId], 'the second skip stayed on the phone');
      await pressWorkButton(phone.page, 'End Work');
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 90000 });
      await pressWorkButton(phone.page, 'Start Work');
      await phone.page.waitForTimeout(20000);
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 90000 });
      const waiting = await live();
      assert.deepEqual([waiting.workSessionStatus, waiting.activeSessionId], ['active', fourthSession], 'no session was ended or started while there was no signal');
      await t.shot(phone, 'start-work-refused-no-signal');
    });

    await t.step('Start Work case: the signal returns and, with no tap, the skip reaches the server and the earlier session ends', async () => {
      await mobile.unblockBackend(phone.page);
      result.startWorkWhileWaiting = await expectEndedWithItsSkip(fourthSession, [result.restart.stopId], 'Start Work case');
      await t.shot(phone, 'end-work-finished-after-start-work');
    });

    const writeRows = async () => (await db.list('route_stop_progress')).filter((row) => row.planId === WRITE_PLAN);
    const writeChannel = (url) => url.pathname.endsWith('/google.firestore.v1.Firestore/Write/channel');
    const refuseWrites = (route) => route.abort('internetdisconnected');
    let fifthSession;

    await t.step('a third route is published and the salesperson starts work on it', async () => {
      const second = await db.get('route_plans', RESTART_PLAN);
      await db.put('route_plans', RESTART_PLAN, { ...second, status: 'archived' });
      const stop = second.days[0].stops[0];
      await db.put('route_plans', WRITE_PLAN, {
        ...second, planId: WRITE_PLAN, publishedAt: new Date(), status: 'published', totalStops: 1,
        stopIds: ['write-1'], stopRetailerIds: { 'write-1': stop.retailerId },
        days: [{ ...second.days[0], stops: [{ ...stop, stopId: 'write-1' }] }],
      });
      await mobile.routeDayForSunday(db, WRITE_PLAN);
      await mobile.reopenHome(phone.page, phone.url);
      fifthSession = await startWorkOnDevice(fourthSession, 'fifth work session');
      await mobile.openAssignedRoute(phone.page);
      await mobile.acceptAndStartRoute(phone.page);
      await db.waitForQuery('route_plan_progress', (p) => p.planId === WRITE_PLAN && p.status === 'in_progress', { label: 'third route started' });
    });

    await t.step('write-stream case: the phone can read the server but its writes do not arrive, so End Work waits for the skip', async () => {
      await phone.page.route(writeChannel, refuseWrites);
      await skipStop(phone.page, 0);
      await phone.page.waitForTimeout(8000);
      assert.equal((await writeRows()).length, 0, 'the skip did not reach route_stop_progress while writes were refused');
      await pressWorkButton(phone.page, 'End Work');
      await phone.page.waitForTimeout(20000);
      const waiting = await live();
      assert.deepEqual([waiting.workSessionStatus, waiting.activeSessionId], ['active', fifthSession], 'the server session stays open while the skip write has not reached the server');
      await B.see(phone.page, /End status is waiting to sync/, { timeout: 30000 });
      await t.shot(phone, 'end-work-waiting-for-write');
    });

    await t.step('write-stream case: writes arrive again and, with no tap, the skip reaches the server and the session ends', async () => {
      await phone.page.unroute(writeChannel, refuseWrites);
      const ended = await db.waitForDoc('live_tracking', uid, (l) => l.workSessionStatus === 'ended' && l.activeSessionId === fifthSession, { timeout: 150000, label: 'fifth work session ended' });
      const rows = await writeRows();
      assert.deepEqual(rows.map((row) => row.status), ['skipped'], 'write-stream case: the skip is stored once');
      assert.equal(rows[0].workSessionId, fifthSession);
      assert.ok(millis(rows[0].updatedAt) <= millis(ended.workSessionEndedAt), 'write-stream case: the stop event was stored before the session ended');
      await B.see(phone.page, /^Work ended on this device\.$/, { timeout: 30000 });
      result.writeStream = { session: fifthSession, stopId: rows[0].stopId, stopStoredAt: new Date(millis(rows[0].updatedAt)).toISOString(), sessionEndedAt: new Date(millis(ended.workSessionEndedAt)).toISOString() };
      await t.shot(phone, 'end-work-finished-after-write');
    });

    const out = path.join(__dirname, '..', 'output', 'mobile_end_work_keeps_records');
    fs.mkdirSync(out, { recursive: true });
    fs.writeFileSync(path.join(out, 'result.json'), JSON.stringify(result, null, 2));
  },
};
