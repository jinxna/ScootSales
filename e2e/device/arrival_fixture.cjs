'use strict';

const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const E = require('./emulator_legacy.cjs');
const { str, num, dbl, bool, arr, map, ts } = E;

const ROUTE_ID = 'route-arrival-acceptance-e2e';
const SESSION_ID = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
const RETAILERS = [
  { id: 'arrival-retailer-a', stopId: 'arrival-stop-a', latitude: 1.5562, longitude: 110.3562, status: 'verified', name: 'QA Arrival Retailer A' },
  { id: 'arrival-retailer-b', stopId: 'arrival-stop-b', latitude: 1.5535, longitude: 110.3593, status: 'verified', name: 'QA Arrival Retailer B' },
  { id: 'arrival-retailer-c', stopId: 'arrival-stop-c', latitude: 1.5513, longitude: 110.3621, status: 'candidate', name: 'QA Arrival Retailer C' },
];
const BACKUP = path.resolve(
  process.env.FYP_A_ROUTE_ARRIVAL_FIXTURE_BACKUP ||
    path.join(os.tmpdir(), 'fyp-a-route-arrival-fixture-backup.json'),
);
const LIVE_SESSION_FIELDS = [
  'uid', 'activeSessionId', 'activeSessionGeneration', 'lastFixSequence',
  'workSessionStatus', 'status', 'workSessionStartedAt', 'workSessionEndedAt',
  'lastBreadcrumbCapturedAt', 'trackingMode', 'appliedControlRevision',
];

async function userProfileId(db, uid) {
  const access = await db.get('user_access', uid);
  const fields = (access && access.fields) || {};
  return (fields.userDocId && fields.userDocId.stringValue) ||
    (fields.user_doc_id && fields.user_doc_id.stringValue) || uid;
}

async function restoreTrackingFixture(db, uid) {
  if (!fs.existsSync(BACKUP)) return;
  const backup = JSON.parse(fs.readFileSync(BACKUP, 'utf8'));
  if (backup.uid !== uid) throw new Error('A different account owns the pending fixture backup.');
  await db.patch('users', backup.profileId, backup.gpsAutofill ? { gpsAutofill: backup.gpsAutofill } : {}, ['gpsAutofill']);
  if (backup.liveTrackingExists) {
    await db.patch('live_tracking', uid, backup.liveTrackingFields, LIVE_SESSION_FIELDS);
  } else {
    await db.remove('live_tracking', uid);
  }
  fs.unlinkSync(BACKUP);
}

async function prepareTrackingFixture(db, uid) {
  const profileId = await userProfileId(db, uid);
  const [profile, live] = await Promise.all([db.get('users', profileId), db.get('live_tracking', uid)]);
  if (!profile || !profile.fields) throw new Error('The seeded salesperson profile is missing; run e2e/device/seed.cjs first.');
  const liveFields = (live && live.fields) || {};
  fs.writeFileSync(BACKUP, JSON.stringify({
    uid, profileId,
    gpsAutofill: profile.fields.gpsAutofill || null,
    liveTrackingExists: Boolean(live),
    liveTrackingFields: Object.fromEntries(
      LIVE_SESSION_FIELDS.filter((f) => f in liveFields).map((f) => [f, liveFields[f]])),
  }), { flag: 'wx' });
  await db.patch('users', profileId, { gpsAutofill: bool(false) }, ['gpsAutofill']);
  await db.patch('live_tracking', uid, {
    uid: str(uid), activeSessionId: str(SESSION_ID), activeSessionGeneration: num(1),
    lastFixSequence: num(0), workSessionStatus: str('active'), status: str('active'),
    trackingMode: str('battery_saver'), appliedControlRevision: num(0),
  }, LIVE_SESSION_FIELDS);
}

function verifiedRevision(r) {
  const parts = ['retailer-coordinate-v1', r.id, r.latitude, r.longitude,
    ['coordinateStatus', 'verified'], ['coordinateReviewStatus', 'reviewed'], ['coordinateSource', 'admin_review']];
  return 'v1:' + Buffer.from(JSON.stringify(parts)).toString('base64url');
}

function coordinateBlock(r) {
  const ok = r.status === 'verified';
  return {
    coordinateStatus: str(r.status),
    coordinateReviewStatus: str(ok ? 'reviewed' : 'needs_review'),
    coordinateSource: str(ok ? 'admin_review' : 'imported'),
  };
}

function stopFields(r, sequence) {
  return map({
    stopId: str(r.stopId), dayId: str('arrival-day-1'), retailerId: str(r.id),
    retailerName: str(r.name), address: str('Synthetic local arrival fixture'),
    lat: dbl(r.latitude), lng: dbl(r.longitude),
    retailerCoordinateSnapshot: map({
      latitude: dbl(r.latitude), longitude: dbl(r.longitude), ...coordinateBlock(r),
      coordinateRevision: str(r.status === 'verified' ? verifiedRevision(r) : 'fixture-' + r.stopId + '-candidate-v1'),
    }),
    sequence: num(sequence),
    estimatedArrival: str(String(9 + sequence).padStart(2, '0') + ':45'),
    estimatedDeparture: str(String(9 + sequence).padStart(2, '0') + ':55'),
    priorityReason: str('Synthetic local arrival acceptance fixture'),
    status: str('not_started'),
    travelMinutesFromPrevious: num(sequence === 1 ? 0 : 10),
    legDistanceKm: dbl(sequence === 1 ? 0 : 0.5),
  });
}

async function cleanup(db, uid) {
  await restoreTrackingFixture(db, uid);
  await db.remove('route_plan_progress', ROUTE_ID + '_' + uid);
  for (const r of RETAILERS) {
    await db.remove('route_stop_progress', ROUTE_ID + '_' + uid + '_' + r.stopId);
    await db.remove('retailers', r.id);
  }
  await db.remove('route_plans', ROUTE_ID);
}

async function prepare(db, uid) {
  await cleanup(db, uid);
  await prepareTrackingFixture(db, uid);
  for (const r of RETAILERS) {
    await db.put('retailers', r.id, {
      retailerId: str(r.id), name: str(r.name), branchId: str('B1'),
      latitude: dbl(r.latitude), longitude: dbl(r.longitude), ...coordinateBlock(r),
    });
  }
  const now = new Date();
  const today = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth(), now.getUTCDate()));
  const weekStart = new Date(today.getTime() - 86400000);
  const weekEnd = new Date(weekStart.getTime() + 6 * 86400000);
  await db.put('route_plans', ROUTE_ID, {
    planId: str(ROUTE_ID), createdByUid: str('local-emulator-fixture'),
    salesmanUid: str(uid), salesmanCode: str('S001'), salesmanName: str('E2E Salesperson'),
    branchId: str('B1'), weekStart: ts(weekStart.toISOString()), weekEnd: ts(weekEnd.toISOString()),
    publishedAt: ts(now.toISOString()), status: str('published'), source: str('dashboard'),
    optimisationMethod: str('haversine'), totalStops: num(RETAILERS.length),
    stopIds: arr(RETAILERS.map((r) => str(r.stopId))),
    stopRetailerIds: map(Object.fromEntries(RETAILERS.map((r) => [r.stopId, str(r.id)]))),
    days: arr([map({
      dayId: str('arrival-day-1'), dayLabel: str('Today'), date: ts(today.toISOString()),
      totalDistanceKm: dbl(1), estimateSource: str('haversine'),
      stops: arr(RETAILERS.map((r, i) => stopFields(r, i + 1))),
    })]),
  });
}

(async () => {
  const action = process.argv[2] || 'prepare';
  if (!['prepare', 'cleanup'].includes(action)) throw new Error('Expected action: prepare or cleanup.');
  const db = E.client();
  const { uid } = await db.signIn(E.SALES_EMAIL);
  if (action === 'prepare') await prepare(db, uid); else await cleanup(db, uid);
  console.log(action === 'prepare' ? 'fixture_prepared stops=3' : 'fixture_cleaned');
})().catch((e) => { console.error(e.message || e); process.exit(1); });
