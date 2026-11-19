'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { ACCOUNTS, BRANCH, RETAILERS } = require('../lib/seed.cjs');

const START = { name: 'E2E Depot', lat: 1.5325877514864295, lng: 110.3573525424372 };
const EXTRA_RETAILERS = [
  { id: 'ret-rt-3', name: 'Round Trip Mart North', area: 'Petra Jaya', lat: 1.575, lng: 110.36 },
  { id: 'ret-rt-4', name: 'Round Trip Mart West', area: 'Satok', lat: 1.544, lng: 110.34 },
];
const ALL_RETAILERS = [...RETAILERS, ...EXTRA_RETAILERS];
const SPEED_KMH = 28;

module.exports = {
  name: 'route_round_trip',
  async run(t) {
    const { db, accounts, seed } = t;

    const openPlanner = async (name) => {
      const s = await t.session('admin', { name });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Route Planner');
      await B.see(s.page, accounts.salesman.name);
      return s;
    };
    const generate = async (s) => {
      await s.page.getByRole('button', { name: 'Generate draft route' }).click();
      await s.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
      for (const r of ALL_RETAILERS) await B.see(s.page, r.name);
    };
    const savedPlan = async (predicate, label) => db.waitForQuery(
      'route_plans',
      (p) => p.salesmanCode === accounts.salesman.code && predicate(p),
      { label },
    );

    await t.step('seed two more shops for the salesperson, so one day has four stops', async () => {
      for (const r of EXTRA_RETAILERS) {
        await db.put('retailers', r.id, {
          retailerId: r.id, retailerName: r.name, name: r.name, area: r.area,
          branchId: BRANCH.id, status: 'active', address: `${r.area}, Kuching`,
          latitude: r.lat, longitude: r.lng,
          coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
          assignedSalesmanId: ACCOUNTS.salesman.code, assignedSalesmanCode: ACCOUNTS.salesman.code,
          assignedSalesmanUid: seed.uids.salesman,
        });
      }
      const branch = await db.get('branches', BRANCH.id);
      for (const key of ['routeStartName', 'routeStartLat', 'routeStartLng']) {
        if (branch[key] != null) throw new Error(`the seeded branch already has ${key}`);
      }
    });

    await t.step('a branch with no start point: the day begins at its first stop and ends at its last', async () => {
      const s = await openPlanner('no-start');
      await generate(s);
      await B.see(s.page, 'No start point. Set a start point in Branches.');
      await expectAbsent(s.page, /^Start: /, 'the start row');
      await expectAbsent(s.page, /From start point/, 'a leg from a start point');
      await expectAbsent(s.page, /^End: back at /, 'the end row');
      await t.shot(s, 'no-start-draft');
      await s.page.getByRole('button', { name: 'Save draft' }).click();
      const plan = await savedPlan(() => true, 'draft with no start point');
      if (plan.startPoint != null) throw new Error(`a plan with no branch start saved a start point: ${JSON.stringify(plan.startPoint)}`);
      const day = busiestDay(plan);
      expectEqual(day.stops.length, ALL_RETAILERS.length, 'stops on the day');
      expectEqual(day.estimateSource, 'haversine_fallback', 'estimate source (the E2E build has no map key)');
      expectEqual(day.orderMethod, 'exact-v1', 'order method');
      expectEqual(day.stops[0].legDistanceKm, 0, 'first leg of a day with no start point');
      expectEqual(day.stops[0].travelMinutesFromPrevious, 0, 'first leg minutes of a day with no start point');
      expectEqual(day.returnLegDistanceKm || 0, 0, 'return leg of a day with no start point');
      expectNear(day.totalDistanceKm, pathKm(day.stops, null), 0.06, 'day distance with no start point');
      expectNear(day.totalDistanceKm, shortestKm(day.stops, null), 0.06, 'day distance against the shortest open path');
      await db.del('route_plans', plan.id);
    });

    await t.step('the branch form refuses a start of latitude 0 and longitude 0, and a start with a field missing', async () => {
      const s = await t.session('admin', { name: 'branch-form-refuse' });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Branches');
      await B.see(s.page, BRANCH.name);
      await s.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await B.see(s.page, 'Edit Branch');
      const boxes = s.page.getByRole('textbox');
      await B.fillField(s.page, boxes.nth(1), START.name);
      await B.fillField(s.page, boxes.nth(2), '1.5');
      await s.page.getByRole('button', { name: 'Update Branch' }).click();
      await B.see(s.page, 'Enter a number from -180 to 180');
      await B.fillField(s.page, boxes.nth(2), '0');
      await B.fillField(s.page, boxes.nth(3), '0');
      await s.page.getByRole('button', { name: 'Update Branch' }).click();
      await B.see(s.page, 'Latitude 0 and longitude 0 is not a real place');
      await t.shot(s, 'branch-form-zero');
      await B.fillField(s.page, boxes.nth(2), '95');
      await B.fillField(s.page, boxes.nth(3), '110.3');
      await s.page.getByRole('button', { name: 'Update Branch' }).click();
      await B.see(s.page, 'Enter a number from -90 to 90');
      const branch = await db.get('branches', BRANCH.id);
      for (const key of ['routeStartName', 'routeStartLat', 'routeStartLng']) {
        if (branch[key] != null) throw new Error(`a refused start was saved: ${key} is ${JSON.stringify(branch[key])}`);
      }
    });

    await t.step('the admin enters the route start on the branch form', async () => {
      const s = await t.session('admin', { name: 'branch-form' });
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Branches');
      await B.see(s.page, BRANCH.name);
      await s.page.getByRole('button', { name: 'Edit', exact: true }).first().click();
      await B.see(s.page, 'Edit Branch');
      const boxes = s.page.getByRole('textbox');
      await B.fillField(s.page, boxes.nth(1), START.name);
      await B.fillField(s.page, boxes.nth(2), String(START.lat));
      await B.fillField(s.page, boxes.nth(3), String(START.lng));
      await t.shot(s, 'branch-form');
      await s.page.getByRole('button', { name: 'Update Branch' }).click();
      await B.see(s.page, 'Branch updated.');
      const branch = await db.waitForDoc('branches', BRANCH.id, (b) => b.routeStartName === START.name, { label: 'branch route start' });
      expectEqual(branch.routeStartLat, START.lat, 'branch start latitude');
      expectEqual(branch.routeStartLng, START.lng, 'branch start longitude');
      expectEqual(branch.branchName, BRANCH.name, 'branch name after the update');
    });

    let planId;
    let planner;
    await t.step('a branch with a start point: the first leg starts at the start and the last returns to it', async () => {
      planner = await openPlanner('round-trip');
      await generate(planner);
      await B.see(planner.page, `Start: ${START.name}`);
      await B.see(planner.page, /^Leaves \d\d:\d\d · first leg \d+\.\d km, \d+ min, counted in the day total$/);
      await expectAbsent(planner.page, /No start point/, 'the no-start line');
      await expectAbsent(planner.page, /Back after 18:00/, 'the late warning on an early day');
      await expectAbsent(planner.page, /made before route start points/, 'the old plan note on a new plan');
      await B.see(planner.page, new RegExp(`^From ${START.name} · \\d+\\.\\d km · ~\\d+ min$`, 'm'));
      await B.see(planner.page, new RegExp(`End: back at ${START.name} \\d\\d:\\d\\d · \\d+\\.\\d km · ~\\d+ min`));
      await B.see(planner.page, `Start and end, ${START.name}`);
      await t.shot(planner, 'round-trip-draft');
      await planner.page.getByRole('button', { name: 'Save draft' }).click();
      const plan = await savedPlan((p) => p.startPoint != null, 'draft with a start point');
      planId = plan.id;
      expectStart(plan.startPoint, 'start point saved on the plan');
      const day = busiestDay(plan);
      await B.see(planner.page, backAtLine(day));
      expectEqual(day.stops.length, ALL_RETAILERS.length, 'stops on the day');
      expectEqual(day.estimateSource, 'haversine_fallback', 'estimate source (the E2E build has no map key)');
      expectEqual(day.orderMethod, 'exact-v1', 'order method');
      expectRoundTrip(day, 'generated day');
      expectNear(day.totalDistanceKm, shortestKm(day.stops, START), 0.06, 'day distance against the shortest round trip');
      expectNear(plan.totalDistanceKm, plan.days.reduce((sum, d) => sum + d.totalDistanceKm, 0), 0.001, 'plan distance');
    });

    await t.step('the mouse wheel over the map scrolls the page and leaves the map zoom as it was', async () => {
      const page = planner.page;
      await page.setViewportSize({ width: 1600, height: 1000 });
      await page.waitForTimeout(600);
      const size = page.viewportSize();
      const endRow = B.semantic(page, /^End: back at /);
      const markers = page.getByRole('button', { name: /^Stop \d+, / });
      const markerBoxes = async () => {
        const boxes = new Map();
        for (let i = 0; i < (await markers.count()); i += 1) {
          const marker = markers.nth(i);
          const box = await marker.boundingBox();
          if (box) boxes.set(await marker.getAttribute('aria-label') || await marker.innerText(), box);
        }
        return boxes;
      };
      const inViewport = (box) => box && box.y >= 0 && box.y + box.height <= size.height;
      const endBefore = await endRow.boundingBox();
      if (!endBefore) throw new Error('the end row has no box');
      if (inViewport(endBefore)) throw new Error(`the end row must start below the fold for this check, it is at y=${endBefore.y} of ${size.height}`);
      const before = await markerBoxes();
      if (before.size < 2) throw new Error(`expected at least 2 stop markers on the map, got ${JSON.stringify([...before.keys()])}`);
      const centres = [...before.values()];
      const cx = centres.reduce((s, b) => s + b.x + b.width / 2, 0) / centres.length;
      const cy = centres.reduce((s, b) => s + b.y + b.height / 2, 0) / centres.length;
      if (cy < 0 || cy > size.height) throw new Error(`the map middle is off screen at y=${cy}`);
      await page.mouse.move(cx, cy);
      for (let i = 0; i < 4; i += 1) {
        await page.mouse.wheel(0, 200);
        await page.waitForTimeout(250);
      }
      await page.waitForTimeout(600);
      const endAfter = await endRow.boundingBox();
      await t.shot(planner, 'wheel-over-map');
      if (!inViewport(endAfter)) {
        throw new Error(`the wheel over the map did not scroll the page: the end row moved from y=${endBefore.y} to y=${endAfter && endAfter.y}`);
      }
      const after = await markerBoxes();
      const scrolled = endBefore.y - endAfter.y;
      const whole = [...before.keys()].filter((name) => after.has(name)
        && Math.abs(after.get(name).height - before.get(name).height) < 1
        && Math.abs(after.get(name).width - before.get(name).width) < 1);
      if (whole.length < 2) throw new Error(`fewer than 2 stop markers stay whole on screen after the scroll: ${JSON.stringify(whole)}`);
      const [anchor] = whole;
      for (const name of whole) {
        expectNear(after.get(name).x - after.get(anchor).x, before.get(name).x - before.get(anchor).x, 1, `${name} across from ${anchor} (a map zoom changes it)`);
        expectNear(after.get(name).y - after.get(anchor).y, before.get(name).y - before.get(anchor).y, 1, `${name} down from ${anchor} (a map zoom changes it)`);
        expectNear(before.get(name).y - after.get(name).y, scrolled, 1, `${name} moved with the page`);
      }
      for (let i = 0; i < 4; i += 1) await page.mouse.wheel(0, -200);
      await page.waitForTimeout(600);
    });

    await t.step('the manager drags the second stop above the first: the order is kept, the hint shows and the totals count both legs', async () => {
      const before = busiestDay(await db.get('route_plans', planId));
      const first = before.stops[0].retailerName;
      const second = before.stops[1].retailerName;
      await dragAbove(planner.page, second, first);
      await B.see(planner.page, /This order takes \d+ minutes? more than the shortest order\. Estimated from straight-line distance\./);
      await planner.page.getByRole('button', { name: 'Use shortest', exact: true }).waitFor({ timeout: 10000 });
      await t.shot(planner, 'after-drag');
      await planner.page.getByRole('button', { name: 'Save changes' }).click();
      const plan = await db.waitForDoc('route_plans', planId, (p) => busiestDay(p).orderMethod === 'manual', { label: 'manual order saved' });
      const day = busiestDay(plan);
      expectEqual(day.stops[0].retailerName, second, 'first stop after the drag');
      expectEqual(day.stops[1].retailerName, first, 'second stop after the drag');
      expectRoundTrip(day, 'day after the drag');
      const extraKm = day.totalDistanceKm - shortestKm(day.stops, START);
      if (extraKm < SPEED_KMH / 60) throw new Error(`the dragged order is only ${extraKm.toFixed(2)} km longer than the shortest, so no hint is due`);
    });

    await t.step('"Use shortest" puts the shortest order back and the hint goes away', async () => {
      await planner.page.getByRole('button', { name: 'Use shortest', exact: true }).click();
      await expectAbsent(planner.page, /more than the shortest order/, 'the order hint');
      await planner.page.getByRole('button', { name: 'Save changes' }).click();
      const plan = await db.waitForDoc('route_plans', planId, (p) => busiestDay(p).orderMethod === 'exact-v1', { label: 'shortest order saved' });
      const day = busiestDay(plan);
      expectRoundTrip(day, 'day after Use shortest');
      expectNear(day.totalDistanceKm, shortestKm(day.stops, START), 0.06, 'day distance after Use shortest');
    });

    let finalDay;
    await t.step('the manager removes a stop: the totals still count the leg from the start and the leg back', async () => {
      const before = busiestDay(await db.get('route_plans', planId));
      const removed = before.stops[1].retailerName;
      await planner.page.getByRole('button', { name: `Remove ${removed}` }).click();
      await expectAbsent(planner.page, new RegExp(`Reorder ${removed}`), 'the removed stop');
      await planner.page.getByRole('button', { name: 'Save changes' }).click();
      const plan = await db.waitForDoc('route_plans', planId, (p) => busiestDay(p).stops.length === ALL_RETAILERS.length - 1, { label: 'plan with one stop removed' });
      finalDay = busiestDay(plan);
      if (finalDay.stops.some((st) => st.retailerName === removed)) throw new Error(`${removed} is still in the saved plan`);
      expectEqual(JSON.stringify(finalDay.stops.map((st) => st.sequence)), JSON.stringify([1, 2, 3]), 'sequence numbers after the removal');
      expectRoundTrip(finalDay, 'day after the removal');
      expectStart(plan.startPoint, 'start point after the edits');
      await t.shot(planner, 'after-remove');
    });

    await t.step('the saved plan is reopened after the branch start changed: it draws the same legs from the start it was made with', async () => {
      const branch = await db.get('branches', BRANCH.id);
      await db.put('branches', BRANCH.id, { ...branch, routeStartName: 'Moved Depot', routeStartLat: 1.6, routeStartLng: 110.4 });
      const s = await openPlanner('reopen');
      await s.page.getByRole('button', { name: /^Saved plans/ }).click();
      await s.page.getByRole('button', { name: 'View', exact: true }).click();
      await s.page.getByRole('button', { name: 'Plan', exact: true }).click();
      await B.see(s.page, `Start: ${START.name}`);
      await B.see(s.page, `Start and end, ${START.name}`);
      await B.see(s.page, `From ${START.name} · ${finalDay.stops[0].legDistanceKm.toFixed(1)} km · ~${finalDay.stops[0].travelMinutesFromPrevious} min`);
      await B.see(s.page, new RegExp(`^End: back at ${START.name} \\d\\d:\\d\\d · ${finalDay.returnLegDistanceKm.toFixed(1).replace('.', '\\.')} km · ~${finalDay.returnTravelMinutes} min$`));
      await B.see(s.page, backAtLine(finalDay));
      await expectAbsent(s.page, /Back after 18:00/, 'the late warning on an early day');
      for (const st of finalDay.stops) await B.see(s.page, st.retailerName);
      await expectAbsent(s.page, /Moved Depot/, 'the new branch start on an old plan');
      await t.shot(s, 'reopened');
      const plan = await db.get('route_plans', planId);
      expectEqual(JSON.stringify(busiestDay(plan)), JSON.stringify(finalDay), 'the day after the plan was reopened');
    });

    await t.step('a day that ends after 18:00 shows the back-at time and a warning', async () => {
      const plan = await db.get('route_plans', planId);
      const late = busiestDay(plan);
      const last = late.stops[late.stops.length - 1];
      last.arrival = '17:20';
      last.departure = '17:40';
      late.returnTravelMinutes = 30;
      await db.put('route_plans', planId, plan);
      const s = await openPlanner('late-day');
      await s.page.getByRole('button', { name: /^Saved plans/ }).click();
      await s.page.getByRole('button', { name: 'View', exact: true }).click();
      await s.page.getByRole('button', { name: 'Plan', exact: true }).click();
      await B.see(s.page, `End: back at ${START.name} 18:10 · ${late.returnLegDistanceKm.toFixed(1)} km · ~30 min`);
      await B.see(s.page, 'Back after 18:00');
      await t.shot(s, 'late-day');
    });

    let oldPlan;
    await t.step('a plan saved before start points shows as stored, and one edit recomputes every day of the draft', async () => {
      const plan = await db.get('route_plans', planId);
      delete plan.startPoint;
      const busy = busiestDay(plan);
      const busyIndex = plan.days.indexOf(busy);
      const otherIndex = plan.days.findIndex((d, i) => i > busyIndex && (d.stops || []).length === 0);
      if (otherIndex < 0) throw new Error('no empty day after the busiest day to hold a second old day');
      for (const day of plan.days) {
        delete day.orderMethod;
        delete day.returnLegDistanceKm;
        delete day.returnTravelMinutes;
      }
      busy.stops[0].legDistanceKm = 3.4;
      busy.stops[0].travelMinutesFromPrevious = 8;
      plan.days[otherIndex].stops = busy.stops.slice(-2).map((st, i) => ({
        ...st, sequence: i + 1, legDistanceKm: i === 0 ? 5.5 : st.legDistanceKm, travelMinutesFromPrevious: i === 0 ? 12 : st.travelMinutesFromPrevious,
      }));
      await db.put('route_plans', planId, plan);
      oldPlan = { otherIndex, first: busy.stops[0].retailerName, second: busy.stops[1].retailerName };

      const s = await openPlanner('old-plan');
      await s.page.getByRole('button', { name: /^Saved plans/ }).click();
      await s.page.getByRole('button', { name: 'View', exact: true }).click();
      await s.page.getByRole('button', { name: 'Plan', exact: true }).click();
      await B.see(s.page, 'This plan was made before route start points. Regenerate it to use the start point.');
      await B.see(s.page, 'From the old route centre · 3.4 km · ~8 min');
      await expectAbsent(s.page, /^Start: /, 'a start row on an old plan');
      await expectAbsent(s.page, /^End: back at /, 'an end row on an old plan');
      await t.shot(s, 'old-plan');
      const untouched = await db.get('route_plans', planId);
      expectEqual(JSON.stringify(untouched), JSON.stringify(plan), 'the old plan after it was only opened');

      await dragAbove(s.page, oldPlan.second, oldPlan.first);
      await expectAbsent(s.page, /made before route start points/, 'the old plan note after the edit');
      await s.page.getByRole('button', { name: 'Save changes' }).click();
      const saved = await db.waitForDoc('route_plans', planId, (p) => busiestDay(p).orderMethod === 'manual', { label: 'old plan saved after one edit' });
      for (const day of saved.days) {
        if ((day.stops || []).length > 0) expectEqual(day.orderMethod, 'manual', `order method of ${day.dayLabel} after one edit`);
      }
      expectEqual(saved.days[oldPlan.otherIndex].stops[0].legDistanceKm, 0, 'first leg of the day that was not edited, recomputed with the current rules');
      if (saved.startPoint != null) throw new Error('an old plan gained a start point from an edit');
    });
  },
};

async function dragAbove(page, movedName, targetName) {
  await B.scrollIntoView(page, page.getByRole('button', { name: `Remove ${movedName}` }));
  const from = await B.semantic(page, `Reorder ${movedName}`).boundingBox();
  const to = await B.semantic(page, `Reorder ${targetName}`).boundingBox();
  const cardRow = await page.getByRole('button', { name: `Remove ${movedName}` }).boundingBox();
  if (!from || !to || !cardRow) throw new Error('no stop tile found for the two stops');
  if (from.width < 100 || to.width < 100) {
    throw new Error(`"Reorder" is expected on the whole stop tile, got ${from.width} px and ${to.width} px wide`);
  }
  const x = from.x + 18;
  const startY = cardRow.y + 13;
  const endY = startY + (to.y - from.y) + 10;
  await page.mouse.move(x, startY);
  await page.mouse.down();
  for (let i = 1; i <= 15; i += 1) {
    await page.mouse.move(x, startY + ((endY - startY) * i) / 15);
    await page.waitForTimeout(40);
  }
  await page.mouse.up();
}

function backAtLine(day) {
  const last = day.stops[day.stops.length - 1];
  const [h, m] = last.departure.split(':').map(Number);
  const total = h * 60 + m + day.returnTravelMinutes;
  const two = (n) => String(n).padStart(2, '0');
  return `End: back at ${START.name} ${two(Math.floor(total / 60))}:${two(total % 60)} · ${day.returnLegDistanceKm.toFixed(1)} km · ~${day.returnTravelMinutes} min`;
}

function busiestDay(plan) {
  return plan.days.reduce((best, day) => ((day.stops || []).length > (best.stops || []).length ? day : best));
}

function km(a, b) {
  const rad = (deg) => (deg * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return (2 * 6378137 * Math.asin(Math.sqrt(h))) / 1000;
}

function pathKm(stops, start) {
  const points = [...(start ? [start] : []), ...stops, ...(start ? [start] : [])];
  let total = 0;
  for (let i = 1; i < points.length; i += 1) total += km(points[i - 1], points[i]);
  return total;
}

function shortestKm(stops, start) {
  let best = Infinity;
  const permute = (head, rest) => {
    if (!rest.length) {
      best = Math.min(best, pathKm(head, start));
      return;
    }
    rest.forEach((next, i) => permute([...head, next], [...rest.slice(0, i), ...rest.slice(i + 1)]));
  };
  permute([], stops);
  return best;
}

function expectRoundTrip(day, what) {
  const { stops } = day;
  expectNear(stops[0].legDistanceKm, km(START, stops[0]), 0.03, `${what}: first leg from the start point`);
  for (let i = 1; i < stops.length; i += 1) {
    expectNear(stops[i].legDistanceKm, km(stops[i - 1], stops[i]), 0.03, `${what}: leg to stop ${i + 1}`);
  }
  const backKm = km(stops[stops.length - 1], START);
  expectNear(day.returnLegDistanceKm, backKm, 0.03, `${what}: leg back to the start point`);
  expectNear(day.returnTravelMinutes, (backKm / SPEED_KMH) * 60, 1, `${what}: minutes back to the start point`);
  expectNear(stops[0].travelMinutesFromPrevious, (km(START, stops[0]) / SPEED_KMH) * 60, 1, `${what}: minutes from the start point`);
  expectNear(day.totalDistanceKm, pathKm(stops, START), 0.06, `${what}: day distance with both legs`);
  if (!(day.returnLegDistanceKm > 0) || !(stops[0].legDistanceKm > 0)) throw new Error(`${what}: a start or return leg is zero`);
}

function expectStart(startPoint, what) {
  if (!startPoint) throw new Error(`${what}: the plan has no start point`);
  expectEqual(startPoint.name, START.name, `${what}: name`);
  expectEqual(startPoint.lat, START.lat, `${what}: latitude`);
  expectEqual(startPoint.lng, START.lng, `${what}: longitude`);
}

async function expectAbsent(page, pattern, what) {
  const locator = page.getByLabel(pattern).or(page.getByText(pattern));
  for (let i = 0; i < 25; i += 1) {
    if ((await locator.count()) === 0) return;
    await page.waitForTimeout(200);
  }
  throw new Error(`${what} is on the page, it must not be`);
}

function expectNear(actual, expected, tolerance, what) {
  if (typeof actual !== 'number' || Math.abs(actual - expected) > tolerance) {
    throw new Error(`${what}: expected ${expected.toFixed(3)} within ${tolerance}, got ${JSON.stringify(actual)}`);
  }
}

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}
