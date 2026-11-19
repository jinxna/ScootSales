'use strict';

const B = require('../lib/browser.cjs');
const { ACCOUNTS, RETAILERS } = require('../lib/seed.cjs');

const SPEED_KMH = 28;
const SERVICE_MINUTES = 20;
const START_MINUTES = 9 * 60;
const EARTH_RADIUS_KM = 6371;
const DISTANCE_TOLERANCE_RATIO = 0.01;
const DISTANCE_TOLERANCE_KM = 0.05;

const EXTRA = [
  { id: 'ret-est-3', name: 'Tabuan Alpha Mart', area: 'Tabuan', lat: 1.526, lng: 110.37 },
  { id: 'ret-est-4', name: 'Tabuan Bravo Mart', area: 'Tabuan', lat: 1.519, lng: 110.385 },
  { id: 'ret-est-5', name: 'Stutong Charlie Mart', area: 'Tabuan', lat: 1.5075, lng: 110.379 },
];
const ALL = [...RETAILERS, ...EXTRA];

function haversineKm(a, b) {
  const rad = (d) => (d * Math.PI) / 180;
  const dLat = rad(b.lat - a.lat);
  const dLng = rad(b.lng - a.lng);
  const h = Math.sin(dLat / 2) ** 2 + Math.cos(rad(a.lat)) * Math.cos(rad(b.lat)) * Math.sin(dLng / 2) ** 2;
  return 2 * EARTH_RADIUS_KM * Math.asin(Math.sqrt(h));
}

const travelMinutes = (km) => Math.round((km / SPEED_KMH) * 60);
const SHOWN_ROUNDING_KM = 0.05;
const withinKm = (actual, expected) => Math.abs(actual - expected) <= Math.max(DISTANCE_TOLERANCE_KM, expected * DISTANCE_TOLERANCE_RATIO);
const withinShownKm = (shown, expected) => Math.abs(shown - expected) <= SHOWN_ROUNDING_KM + Math.max(DISTANCE_TOLERANCE_KM, expected * DISTANCE_TOLERANCE_RATIO);
const hhmm = (minutes) => `${String(Math.floor(minutes / 60)).padStart(2, '0')}:${String(minutes % 60).padStart(2, '0')}`;
const formatDuration = (m) => (m <= 0 ? '0 min' : m < 60 ? `${m} min` : m % 60 === 0 ? `${m / 60}h` : `${Math.floor(m / 60)}h ${m % 60}m`);

function check(condition, message) {
  if (!condition) throw new Error(message);
}

async function screenText(page) {
  return page.evaluate(() => document.body.innerText + '\n' + [...document.querySelectorAll('flt-semantics')].map((n) => n.getAttribute('aria-label') || '').join('\n'));
}

function permutations(items) {
  if (items.length <= 1) return [items];
  const out = [];
  items.forEach((item, i) => {
    for (const rest of permutations([...items.slice(0, i), ...items.slice(i + 1)])) out.push([item, ...rest]);
  });
  return out;
}

function orderKm(order, position, start) {
  let km = 0;
  if (start && order.length) km += haversineKm(start, position[order[0]]);
  for (let i = 1; i < order.length; i += 1) km += haversineKm(position[order[i - 1]], position[order[i]]);
  if (start && order.length) km += haversineKm(position[order[order.length - 1]], start);
  return km;
}

function derive(plan, start) {
  const position = Object.fromEntries(ALL.map((r) => [r.id, { lat: r.lat, lng: r.lng }]));
  const stops = plan.days.flatMap((d) => d.stops);
  check(stops.length === ALL.length, `stops in plan: expected ${ALL.length}, got ${stops.length}`);
  check(JSON.stringify(stops.map((s) => s.retailerId).sort()) === JSON.stringify(ALL.map((r) => r.id).sort()), 'plan stops are not the seeded retailers');
  const legs = [];
  const days = [];
  for (const day of plan.days) {
    const ordered = [...day.stops].sort((a, b) => a.sequence - b.sequence);
    const storedOrder = ordered.map((s) => s.retailerId);
    if (ordered.length) {
      check(ordered.length <= 8, `${day.dayLabel}: ${ordered.length} stops, the exact order is only promised up to 8`);
      check(day.orderMethod === 'exact-v1', `${day.dayLabel}: orderMethod ${day.orderMethod}, expected exact-v1 for ${ordered.length} stops`);
      const minimum = Math.min(...permutations(storedOrder).map((order) => orderKm(order, position, start)));
      const storedKm = orderKm(storedOrder, position, start);
      check(storedKm <= minimum + 0.001 + minimum * 0.001, `${day.dayLabel}: stored order totals ${storedKm.toFixed(3)} km, the shortest order of these stops totals ${minimum.toFixed(3)} km`);
    }
    let previous = start;
    let dayKm = 0;
    for (const stop of ordered) {
      const km = previous ? haversineKm(previous, position[stop.retailerId]) : 0;
      legs.push({ km, minutes: travelMinutes(km), stop });
      dayKm += km;
      previous = position[stop.retailerId];
    }
    if (ordered.length && !start) {
      check(ordered[0].legDistanceKm === 0 && ordered[0].travelMinutesFromPrevious === 0, `${day.dayLabel}: first stop has a leg of ${ordered[0].legDistanceKm} km and ${ordered[0].travelMinutesFromPrevious} min although the day has no start point`);
    }
    const returnKm = start && ordered.length ? haversineKm(previous, start) : 0;
    const returnMinutes = start && ordered.length ? travelMinutes(returnKm) : 0;
    days.push({ km: dayKm + returnKm, returnKm, returnMinutes, stops: ordered.length });
  }
  return { legs, days, totalKm: days.reduce((s, d) => s + d.km, 0), totalMinutes: legs.reduce((s, l) => s + l.minutes, 0) + days.reduce((s, d) => s + d.returnMinutes, 0) };
}

module.exports = {
  name: 'route_planner_estimates',
  async run(t) {
    const { db, accounts, seed } = t;
    let s;
    let planDoc;
    let expected;

    await t.step('seed retailers with known coordinates for the salesperson', async () => {
      for (const r of EXTRA) {
        await db.put('retailers', r.id, {
          retailerId: r.id, retailerName: r.name, name: r.name, area: r.area,
          branchId: 'B1', status: 'active', address: `${r.area}, Kuching`,
          latitude: r.lat, longitude: r.lng,
          coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
          assignedSalesmanId: ACCOUNTS.salesman.code, assignedSalesmanCode: ACCOUNTS.salesman.code,
          assignedSalesmanUid: seed.uids.salesman,
        });
      }
    });

    await t.step('admin opens the planner and nothing is estimated yet', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await s.page.getByRole('button', { name: 'Route Planner', exact: true }).first().click();
      await B.see(s.page, 'No plan generated yet');
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'before-generate');
    });

    await t.step('generating a draft shows honest local estimates', async () => {
      await s.page.getByRole('button', { name: 'Generate draft route' }).click();
      await s.page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
      await s.page.waitForTimeout(1500);
      await t.shot(s, 'after-generate');
      const text = await screenText(s.page);
      check(/Distances are straight-line estimates\./.test(text), 'the day does not say "Distances are straight-line estimates."');
      check(!/Try again/.test(text), 'a "Try again" is offered although road routing is not set up in this build');
      check(!/Geoapify|OSRM|Haversine/.test(text), 'a routing provider name is shown in the planner');
      check(!/Road estimate|Road \(|Geoapify road travel times|OSRM road travel times|Geoapify road routing|Road distances|Road route(?! unavailable)/.test(text), 'a road label is shown although road routing is unavailable');
    });

    await t.step('save the draft and read the stored plan', async () => {
      await s.page.getByRole('button', { name: 'Save draft' }).click();
      const found = await db.waitForQuery('route_plans', (p) => p.salesmanCode === accounts.salesman.code, { label: 'route_plans' });
      planDoc = await db.get('route_plans', found.id);
      const start = planDoc.startPoint ? { lat: planDoc.startPoint.lat, lng: planDoc.startPoint.lng } : null;
      expected = derive({ days: planDoc.days.map((d) => ({ dayLabel: d.dayLabel, orderMethod: d.orderMethod, stops: d.stops })) }, start);
    });

    await t.step('the KPI strip shows distance, travel, service and stops from the formula', async () => {
      const text = await screenText(s.page);
      const km = Number((text.match(/Distance:\s*([\d.]+)\s*km/) || [])[1]);
      check(Number.isFinite(km) && withinShownKm(km, expected.totalKm), `Distance: expected about ${expected.totalKm.toFixed(2)} km, screen shows ${km}`);
      const shownTravel = ((text.match(/Travel:\s*([0-9hmin ]+?)(?:\n|$)/) || [])[1] || '').trim();
      const candidates = [];
      for (let delta = -expected.legs.length; delta <= expected.legs.length; delta += 1) candidates.push(formatDuration(expected.totalMinutes + delta));
      check(candidates.includes(shownTravel), `Travel: expected about ${formatDuration(expected.totalMinutes)} at ${SPEED_KMH} km/h, screen shows ${shownTravel}`);
      const expectedService = formatDuration(ALL.length * SERVICE_MINUTES);
      check(text.includes(`Service: ${expectedService}`), `Service: expected ${expectedService} on screen`);
      check(new RegExp(`Stops:\\s*${ALL.length}\\b`).test(text), `Stops: expected ${ALL.length} on screen`);
    });

    await t.step('each leg on screen matches the formula for its stops', async () => {
      const text = await screenText(s.page);
      const shown = [...text.matchAll(/([\d.]+) km · ~(\d+) min/g)].map((m) => ({ km: Number(m[1]), minutes: Number(m[2]) }));
      check(shown.length >= 1, 'no leg estimate "x km · ~y min" is visible for the selected day');
      for (const leg of shown) {
        const match = expected.legs.find((e) => withinShownKm(leg.km, e.km) && Math.abs(leg.minutes - e.minutes) <= 1);
        check(Boolean(match), `leg ${leg.km} km ~${leg.minutes} min matches no expected leg`);
      }
    });

    await t.step('the stored plan carries the same estimates', async () => {
      check(planDoc.optimisationMethod === 'HaversineNearestNeighbour', `optimisationMethod: ${planDoc.optimisationMethod}`);
      check(withinKm(planDoc.totalDistanceKm, expected.totalKm), `stored totalDistanceKm ${planDoc.totalDistanceKm}, expected about ${expected.totalKm.toFixed(2)}`);
      check(planDoc.totalStops === ALL.length, `stored totalStops ${planDoc.totalStops}`);
      let storedSum = 0;
      for (const [i, day] of planDoc.days.entries()) {
        const want = expected.days[i];
        storedSum += day.totalDistanceKm;
        check(day.estimatedServiceMinutes === want.stops * SERVICE_MINUTES, `${day.dayLabel}: service minutes ${day.estimatedServiceMinutes}, expected ${want.stops * SERVICE_MINUTES}`);
        if (want.stops) check(withinKm(day.totalDistanceKm, want.km), `${day.dayLabel}: stored km ${day.totalDistanceKm}, expected about ${want.km.toFixed(2)}`);
        check(withinKm(day.returnLegDistanceKm || 0, want.returnKm), `${day.dayLabel}: stored return leg ${day.returnLegDistanceKm} km, expected about ${want.returnKm.toFixed(2)}`);
        check(Math.abs((day.returnTravelMinutes || 0) - want.returnMinutes) <= 1, `${day.dayLabel}: stored return travel ${day.returnTravelMinutes} min, expected about ${want.returnMinutes}`);
        let clock = START_MINUTES;
        for (const stop of [...day.stops].sort((a, b) => a.sequence - b.sequence)) {
          const leg = expected.legs.find((l) => l.stop.retailerId === stop.retailerId);
          check(withinKm(stop.legDistanceKm, leg.km), `${stop.retailerName}: stored leg ${stop.legDistanceKm} km, expected about ${leg.km.toFixed(2)}`);
          check(Math.abs(stop.travelMinutesFromPrevious - leg.minutes) <= 1, `${stop.retailerName}: stored travel ${stop.travelMinutesFromPrevious} min, expected about ${leg.minutes}`);
          clock += stop.travelMinutesFromPrevious;
          check(stop.arrival === hhmm(clock), `${stop.retailerName}: arrival ${stop.arrival}, expected ${hhmm(clock)}`);
          clock += SERVICE_MINUTES;
          check(stop.departure === hhmm(clock), `${stop.retailerName}: departure ${stop.departure}, expected ${hhmm(clock)}`);
        }
      }
      check(Math.abs(storedSum - planDoc.totalDistanceKm) <= 0.05, `stored day km sum ${storedSum} differs from totalDistanceKm ${planDoc.totalDistanceKm}`);
      await t.shot(s, 'after-save');
    });
  },
};
