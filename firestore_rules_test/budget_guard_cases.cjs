'use strict';
const { GeoPoint, Timestamp, serverTimestamp, doc, setDoc, updateDoc, deleteDoc, getDoc, writeBatch } = require('firebase/firestore');
const fx = require('./identity_audit_fixtures.cjs');
const H = require('./rules_test_support.cjs');
const U = H.users;
const S = U.salesman.uid;
const SESSION = H.PROBE_SESSION;
const WEEK = Timestamp.fromDate(new Date('2026-06-15T00:00:00Z'));
const now = () => Timestamp.now();
const ago = (ms) => Timestamp.fromMillis(Date.now() - ms);
const admin = (env, fn) => env.withSecurityRulesDisabled((c) => fn(c.firestore()));
function p2OrderItem(o = {}) {
  return { name: 'Orange Juice', productName: 'Orange Juice', productId: 'p1', barcode: '9551000000015', packingSize: '12 x 1L',
    price: 10, qty: 1, expiry: '', department: 'Beverage', departmentName: 'Beverage', shelfBatches: [], remarks: '', ...o };
}
function p2Order(orderId, o = {}) {
  return { orderId, visitSource: 'personal_planner', salesmanUid: S, submittedByUid: S, createdByUid: S, uid: S, userUid: S,
    salesmanId: 'S001', salesmanCode: 'S001', branchId: 'B1', salesmanName: 'Sales One', retailerId: 'retailer-1', retailerName: 'Retailer One',
    outlet: 'Retailer One', status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10, submittedAt: serverTimestamp(),
    createdAt: serverTimestamp(), updatedAt: serverTimestamp(), items: [p2OrderItem()], commercialSchemaVersion: 1,
    commercialLines: [`p1~${Buffer.from('Orange Juice', 'utf8').toString('base64url')}~1~1000`], signatureTimestamps: {},
    locationEvidence: { mode: 'not_verified', failureCode: 'unavailable' }, ...o };
}
const identity = { uid: S, userUid: S, salesmanUid: S, salesmanId: 'S001', salesmanName: 'Sales One', salesmanEmail: 's@x.test',
  submittedByUid: S, submittedByEmail: 's@x.test', submittedByName: 'Sales One', staffId: 'S001', employeeCode: 'S001', salesmanCode: 'S001',
  salesman_code: 'S001', branchId: 'B1' };
function phoneBacklog(sequence, deviceCapturedAt) {
  const lat = 1.5535; const lng = 110.3593;
  return { ...identity, eventId: `session_${S}_${SESSION}_${sequence}`, backlog: true, activeSessionId: SESSION, activeSessionGeneration: 1,
    fixSequence: sequence, latitude: lat, longitude: lng, gpsLatitude: lat, gpsLongitude: lng, location: new GeoPoint(lat, lng), accuracy: 12,
    accuracyMeters: 12, deviceCapturedAt, isMocked: false, locationSource: 'foreground_tracking', locationVerification: 'device_captured',
    timestamp: serverTimestamp(), updatedAt: serverTimestamp() };
}
function copilotOutcome(id) {
  return { outcomeId: id, issueId: 'issue-1', issueKey: 'low_sell_through::retailer-1::product-1', issueType: 'low_sell_through',
    retailerId: 'retailer-1', retailerName: 'Retailer One', productId: 'product-1', productName: 'Product One', reasonCode: 'low_sell_through',
    note: '', replacementProductId: '', salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', planId: 'route-own', stopId: 'stop-1',
    sourceBriefId: 'brief-1', source: 'mobile_assigned_route_copilot', isDemo: false, clientCreatedAt: now(), submittedAt: serverTimestamp() };
}
const FULL_ROW = ['products', 'departments', 'categories', 'retailer_scoresheets', 'department_pic', 'website_pages']
  .flatMap((m) => ['view', 'create', 'edit', 'delete'].map((a) => `${m}:${a}`));
async function grantRow(db, role, writes) {
  const views = FULL_ROW.filter((t) => t.endsWith(':view'));
  await setDoc(doc(db, 'system_access_config', 'permission_matrix'), { roles: { admin: FULL_ROW, [role]: [...views, ...writes] }, revision: 1, updatedByUid: U.admin.uid, auditDocumentId: 'seeded' });
}
function productPayload() {
  return { productId: 'PRD-BUDGET', departmentId: 'D1', categoryId: 'C1', departmentName: 'Beverage', departmentManagerName: 'Mgr',
    mainCategoryName: 'Drinks', categoryName: 'Juice', subCategoryName: 'Orange', itemName: 'Orange Juice 1L', productName: 'Orange Juice 1L',
    productFlavor: 'Orange', flavor: 'Orange', itemCode: 'OJ1', productCode: 'OJ1', sku: 'OJ1-12', barcode: '9551000000015',
    itemBarcode: '9551000000015', packingSize: '12 x 1L', unitPrice: 10, price: 10, priceGuide: 10, uom: 'CTN', uomLabel: 'Carton',
    unitOfMeasure: 'carton', sortOrder: 1, brandName: 'Sunny', isVisible: false, status: 'hidden', importSource: 'manual',
    mobileDisplayMode: 'default', maxOrderQty: 50, createdAt: now(), updatedAt: now() };
}
const LC_PLAN = 'route-lc';
const LC_PROGRESS = `${LC_PLAN}_${S}`;
function lcPlan(stopIds, extra = {}) {
  return { planId: LC_PLAN, createdByUid: U.admin.uid, salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', weekStart: WEEK, status: 'published',
    stopIds, stopRetailerIds: Object.fromEntries(stopIds.map((id, i) => [id, `retailer-${i + 1}`])), totalStops: stopIds.length, ...extra };
}
function lcParent(extra = {}) {
  return { progressId: LC_PROGRESS, planId: LC_PLAN, salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', isOfflineCreated: false,
    status: 'in_progress', stopProgress: {}, handledStopIds: [], acceptedAt: ago(60000), startedAt: ago(50000), updatedAt: ago(40000),
    lastSyncedAt: ago(40000), ...extra };
}
async function lcPrep(env, { stopIds = ['stop-1', 'stop-2'], parent = {}, omit = [], plan = {}, arrived = false, retailerVerified = false, session = 'active' }) {
  let result = null;
  await admin(env, async (db) => {
    await setDoc(doc(db, 'route_plans', LC_PLAN), lcPlan(stopIds, plan));
    await setDoc(doc(db, 'live_tracking', S), { uid: S, activeSessionId: H.routeStopTestSessionId, activeSessionGeneration: 1, workSessionStatus: 'active' });
    await setDoc(doc(db, 'retailers', 'retailer-1'), { retailerId: 'retailer-1', retailerName: 'Retailer One', branchId: 'B1', salesmanUid: S,
      salesmanCode: 'S001', status: 'active', ...(retailerVerified ? { coordinateStatus: 'verified', coordinateSource: 'admin_review',
        coordinateReviewStatus: 'reviewed', latitude: 1.5535, longitude: 110.3593 } : {}) });
    const base = lcParent({ routeSessionState: session, selectedStopId: 'stop-1', selectionRevision: 1, ...parent });
    for (const k of omit) delete base[k];
    await deleteDoc(doc(db, 'route_stop_progress', `${LC_PLAN}_${S}_stop-1`));
    if (!arrived) { await setDoc(doc(db, 'route_plan_progress', LC_PROGRESS), base); result = base; return; }
    const arrival = H.v2ManualArrival({ planId: LC_PLAN, stopId: 'stop-1', retailerId: 'retailer-1' });
    const stored = { ...arrival, receivedAt: now(), updatedAt: now(), arrivalReceivedAt: now() };
    await setDoc(doc(db, 'route_stop_progress', `${LC_PLAN}_${S}_stop-1`), stored);
    const projected = { ...base, lastStopWriteStopId: 'stop-1', lastStopWriteStatus: 'arrived', lastStopWriteEventId: arrival.eventId,
      lastStopWriteWorkSessionGeneration: 1, lastStopWriteSequence: 1, lastStopId: 'stop-1', lastStopStatus: 'arrived', lastStopEventId: arrival.eventId,
      lastSummaryWorkSessionGeneration: 1, lastSummaryEventSequence: 1 };
    await setDoc(doc(db, 'route_plan_progress', LC_PROGRESS), projected);
    result = { parent: projected, arrival: stored };
  });
  return result;
}
async function commitStop(db, parentState, event, stopIds) {
  const batch = writeBatch(db);
  batch.set(doc(db, 'route_stop_progress', `${event.planId}_${event.salesmanUid}_${event.stopId}`), event);
  batch.update(doc(db, 'route_plan_progress', `${event.planId}_${event.salesmanUid}`), H.v2StopParentProjection(parentState, event, stopIds));
  await batch.commit();
}
let lcState = null;

const phone = [
  { name: 'live_tracking create (session start)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'live_tracking', S))),
    run: (db) => setDoc(doc(db, 'live_tracking', S), H.validWorkSessionStartPayload({ sessionId: SESSION })) },
  { name: 'live_tracking update (session restart)', actor: U.salesman,
    prep: (env) => { H.setTestEnv(env); return H.seedLiveSession({ lastFixSequence: 3, status: 'ended' }); },
    run: (db) => updateDoc(doc(db, 'live_tracking', S), H.workSessionStartFields('c'.repeat(32), 2)) },
  { name: 'live_tracking update (fix)', actor: U.salesman,
    prep: (env) => { H.setTestEnv(env); return H.seedLiveSession({ lastFixSequence: 1 }); },
    run: (db) => updateDoc(doc(db, 'live_tracking', S), H.trackingFixPayload({ sessionId: SESSION, generation: 1, sequence: 2, deviceCapturedAt: now() })) },
  { name: 'live fix + session crumb batch', actor: U.salesman,
    prep: (env) => { H.setTestEnv(env); return H.seedLiveSession({ lastFixSequence: 1 }); },
    run: async (db) => { const t = now(); const crumb = H.sessionBreadcrumbPayload({ sessionId: SESSION, generation: 1, sequence: 2, deviceCapturedAt: t });
      const b = writeBatch(db); b.update(doc(db, 'live_tracking', S), H.trackingFixPayload({ sessionId: SESSION, generation: 1, sequence: 2, deviceCapturedAt: t }));
      b.set(doc(db, 'gps_tracking', crumb.eventId), crumb); await b.commit(); } },
  { name: 'gps_tracking create (session crumb, standalone)', measureOnly: true, actor: U.salesman,
    prep: async (env) => { H.setTestEnv(env); await H.seedLiveSession({ lastFixSequence: 2 }); await admin(env, (db) => deleteDoc(doc(db, 'gps_tracking', `session_${S}_${SESSION}_2`))); },
    run: (db) => { const crumb = H.sessionBreadcrumbPayload({ sessionId: SESSION, generation: 1, sequence: 2, deviceCapturedAt: ago(1000) }); return setDoc(doc(db, 'gps_tracking', crumb.eventId), crumb); } },
  { name: 'BATCHTEST two visits create batch', measureOnly: true, actor: U.salesman, prep: (env) => admin(env, async (db) => { await deleteDoc(doc(db, 'visits', 'vb-1')); await deleteDoc(doc(db, 'visits', 'vb-2')); }),
    run: async (db) => { const b = writeBatch(db); b.set(doc(db, 'visits', 'vb-1'), H.newVisit(S)); b.set(doc(db, 'visits', 'vb-2'), H.newVisit(S)); await b.commit(); } },
  { name: 'BATCHTEST visit create + live fix batch', measureOnly: true, actor: U.salesman,
    prep: async (env) => { H.setTestEnv(env); await H.seedLiveSession({ lastFixSequence: 1 }); await admin(env, (db) => deleteDoc(doc(db, 'visits', 'vb-3'))); },
    run: async (db) => { const b = writeBatch(db); b.set(doc(db, 'visits', 'vb-3'), H.newVisit(S)); b.update(doc(db, 'live_tracking', S), H.trackingFixPayload({ sessionId: SESSION, generation: 1, sequence: 2, deviceCapturedAt: now() })); await b.commit(); } },
  { name: 'live_tracking update (session end)', actor: U.salesman,
    prep: (env) => { H.setTestEnv(env); return H.seedLiveSession({ lastFixSequence: 1 }); },
    run: (db) => updateDoc(doc(db, 'live_tracking', S), { workSessionStatus: 'ended', status: 'inactive', workSessionEndedAt: serverTimestamp() }) },
  { name: 'live_tracking update (control ack)', actor: U.salesman,
    prep: async (env) => { H.setTestEnv(env); await H.seedLiveSession({ lastFixSequence: 1 });
      await admin(env, (db) => setDoc(doc(db, 'tracking_controls', S), { mode: 'live', revision: 1, updatedByUid: U.admin.uid, updatedAt: now() })); },
    run: (db) => updateDoc(doc(db, 'live_tracking', S), { trackingMode: 'live', appliedControlRevision: 1 }) },
  { name: 'gps_tracking create (backlog crumb)', actor: U.salesman,
    prep: async (env) => { H.setTestEnv(env); await H.seedLiveSession({ lastFixSequence: 10 }); await admin(env, (db) => deleteDoc(doc(db, 'gps_tracking', `session_${S}_${SESSION}_4`))); },
    run: (db) => { const c = phoneBacklog(4, ago(60000)); return setDoc(doc(db, 'gps_tracking', c.eventId), c); } },
  { name: 'gps_tracking create (order history)', actor: U.salesman,
    prep: (env) => admin(env, async (db) => { await setDoc(doc(db, 'orders', 'ORD-P1'), { salesmanUid: S, salesmanCode: 'S001', branchId: 'B1' }); await deleteDoc(doc(db, 'gps_tracking', 'order_ORD-P1')); }),
    run: (db) => setDoc(doc(db, 'gps_tracking', 'order_ORD-P1'), { ...H.validTrackingPayload(), orderId: 'ORD-P1' }) },
  { name: 'orders create (personal planner)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'orders', 'ORD-B-PP'))),
    run: (db) => setDoc(doc(db, 'orders', 'ORD-B-PP'), p2Order('ORD-B-PP')) },
  { name: 'orders create (assigned route)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'orders', H.assignedOrderId(S, 'route-own', 'stop-1')))),
    run: (db) => { const id = H.assignedOrderId(S, 'route-own', 'stop-1'); return setDoc(doc(db, 'orders', id), p2Order(id, { visitSource: 'assigned_route', routePlanId: 'route-own', routeStopId: 'stop-1' })); } },
  { name: 'conversation_outcomes create (copilot)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'conversation_outcomes', 'oc-b'))),
    run: (db) => setDoc(doc(db, 'conversation_outcomes', 'oc-b'), copilotOutcome('oc-b')) },
  { name: 'conversation_outcomes create (no_order)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'conversation_outcomes', 'no-b'))),
    run: (db) => setDoc(doc(db, 'conversation_outcomes', 'no-b'), H.noOrderOutcome({ outcomeId: 'no-b' })) },
  { name: 'conversation_outcomes update (follow-up)', actor: U.salesman,
    prep: (env) => admin(env, (db) => setDoc(doc(db, 'conversation_outcomes', 'oc-fu'), { ...copilotOutcome('oc-fu'), submittedAt: now() })),
    run: (db) => updateDoc(doc(db, 'conversation_outcomes', 'oc-fu'), { followUpDate: '2026-07-01', followUpStatus: 'open' }) },
  { name: 'retailer_coordinate_proposals create', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'retailer_coordinate_proposals', 'prop-b'))),
    run: (db) => setDoc(doc(db, 'retailer_coordinate_proposals', 'prop-b'), { proposalId: 'prop-b', planId: 'route-own', stopId: 'stop-1', retailerId: 'retailer-1',
      candidateLatitude: 1.55, candidateLongitude: 110.35, salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', createdAt: serverTimestamp(), status: 'pending', source: 'mobile_assigned_route' }) },
  { name: 'visits create', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'visits', 'v-b'))), run: (db) => setDoc(doc(db, 'visits', 'v-b'), H.newVisit(S)) },
  { name: 'visits update', actor: U.salesman,
    prep: (env) => admin(env, (db) => setDoc(doc(db, 'visits', 'v-bu'), { ...H.newVisit(S), createdAt: ago(1000), updatedAt: ago(1000) })),
    run: (db) => updateDoc(doc(db, 'visits', 'v-bu'), { notes: 'x', updatedAt: serverTimestamp() }) },
  { name: 'visits delete', actor: U.salesman, prep: (env) => admin(env, (db) => setDoc(doc(db, 'visits', 'v-bd'), { ...H.newVisit(S), createdAt: ago(1000), updatedAt: ago(1000) })), run: (db) => deleteDoc(doc(db, 'visits', 'v-bd')) },
  { name: 'visit_logs create', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'visit_logs', 'vl-b'))),
    run: (db) => setDoc(doc(db, 'visit_logs', 'vl-b'), { salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', retailerId: 'retailer-1', note: 'ok', createdAt: serverTimestamp() }) },
  { name: 'notification_logs create (own)', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'notification_logs', 'nl-b'))),
    run: (db) => setDoc(doc(db, 'notification_logs', 'nl-b'), { salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', orderId: 'O-1', type: 'order', title: 'T', message: 'M' }) },
  { name: 'special_requests create (salesman)', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'special_requests', 'sr-b'))),
    run: (db) => setDoc(doc(db, 'special_requests', 'sr-b'), H.specialRequest({ createdAt: serverTimestamp(), updatedAt: serverTimestamp(), lastActionAt: serverTimestamp() })) },
  { name: 'retailers update (salesman progress)', actor: U.salesman,
    prep: (env) => admin(env, (db) => setDoc(doc(db, 'retailers', 'retailer-1'), { retailerId: 'retailer-1', retailerName: 'Retailer One', branchId: 'B1', salesmanUid: S, salesmanCode: 'S001', status: 'active', assignedSalesmanId: 'S001' })),
    run: (db) => updateDoc(doc(db, 'retailers', 'retailer-1'), { progress: 'step3', lastSalesmanUid: S, lastSalesmanId: 'S001', updatedAt: serverTimestamp() }) },
  { name: 'notification_read_state create', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'notification_read_state', S))),
    run: (db) => setDoc(doc(db, 'notification_read_state', S), { readThroughAt: serverTimestamp() }) },
  { name: 'action_centre_user_status create', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'action_centre_user_status', `${S}_a1`))),
    run: (db) => setDoc(doc(db, 'action_centre_user_status', `${S}_a1`), { uid: S, actionId: 'a1', status: 'resolved', updatedAt: serverTimestamp() }) },
  { name: 'route_plan_progress create (accept)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'route_plan_progress', `route-own_${S}`))),
    run: (db) => setDoc(doc(db, 'route_plan_progress', `route-own_${S}`), { progressId: `route-own_${S}`, planId: 'route-own', salesmanUid: S, salesmanCode: 'S001', branchId: 'B1',
      isOfflineCreated: false, status: 'accepted', stopProgress: {}, handledStopIds: [], acceptedAt: serverTimestamp(), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }) },
  { name: 'route_plan_progress create (initial selection)', actor: U.salesman,
    prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'route_plan_progress', `route-own_${S}`))),
    run: (db) => setDoc(doc(db, 'route_plan_progress', `route-own_${S}`), { progressId: `route-own_${S}`, planId: 'route-own', salesmanUid: S, salesmanCode: 'S001', branchId: 'B1',
      isOfflineCreated: false, status: 'assigned', selectedStopId: 'stop-1', selectionRevision: 1, stopProgress: {}, handledStopIds: [], updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }) },
  { name: 'route_plan_progress update (accepted -> in_progress)', actor: U.salesman,
    prep: (env) => lcPrep(env, { parent: { status: 'accepted' }, omit: ['routeSessionState', 'selectedStopId', 'selectionRevision', 'startedAt'] }),
    run: (db) => updateDoc(doc(db, 'route_plan_progress', LC_PROGRESS), { status: 'in_progress', startedAt: serverTimestamp(), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }) },
  { name: 'route_plan_progress update (select stop)', actor: U.salesman,
    prep: (env) => lcPrep(env, { omit: ['selectedStopId', 'selectionRevision'] }),
    run: (db) => updateDoc(doc(db, 'route_plan_progress', LC_PROGRESS), { selectedStopId: 'stop-1', selectionRevision: 1, updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }) },
  { name: 'route_plan_progress update (session state active)', actor: U.salesman,
    prep: (env) => lcPrep(env, { omit: ['routeSessionState'] }),
    run: (db) => updateDoc(doc(db, 'route_plan_progress', LC_PROGRESS), { routeSessionState: 'active', updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }) },
  { name: 'route_plan_progress update (heartbeat)', actor: U.salesman, prep: (env) => lcPrep(env, {}),
    run: (db) => updateDoc(doc(db, 'route_plan_progress', LC_PROGRESS), { lastHeartbeatAt: serverTimestamp() }) },
  { name: 'stop arrival batch (manual_unverified)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, {}); },
    run: (db) => commitStop(db, lcState, H.v2ManualArrival({ planId: LC_PLAN, stopId: 'stop-1', retailerId: 'retailer-1' }), ['stop-1', 'stop-2']) },
  { name: 'stop arrival batch (verified current_retailer)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, { retailerVerified: true }); },
    run: (db) => commitStop(db, lcState, H.v2VerifiedArrival({ planId: LC_PLAN, stopId: 'stop-1', retailerId: 'retailer-1', latitude: 1.5535, longitude: 110.3593 }), ['stop-1', 'stop-2']) },
  { name: 'stop arrival batch (verified published_snapshot_offline)', actor: U.salesman,
    prep: async (env) => { const publishedAt = ago(3600000); lcState = await lcPrep(env, { plan: { publishedAt, stopCoordinateSnapshots: { 'stop-1': { retailerId: 'retailer-1', coordinateStatus: 'verified',
      latitude: 1.5535, longitude: 110.3593, coordinateRevision: 'rev1', coordinateSource: 'admin_review' } } } }); lcState.publishedAt = publishedAt; },
    run: (db) => commitStop(db, lcState, H.v2VerifiedArrival({ planId: LC_PLAN, stopId: 'stop-1', retailerId: 'retailer-1', latitude: 1.5535, longitude: 110.3593,
      coordinateReferenceMode: 'published_snapshot_offline', retailerCoordinateRevision: 'rev1', coordinateSnapshotAt: lcState.publishedAt }), ['stop-1', 'stop-2']) },
  { name: 'stop completed batch (non-final)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, { arrived: true }); },
    run: (db) => commitStop(db, lcState.parent, H.v2TerminalStopEvent(lcState.arrival, 'completed', 2), ['stop-1', 'stop-2']) },
  { name: 'stop completed batch (final, closes active session)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, { arrived: true, stopIds: ['stop-1'] }); },
    run: (db) => commitStop(db, lcState.parent, H.v2TerminalStopEvent(lcState.arrival, 'completed', 2), ['stop-1']) },
  { name: 'stop skipped batch (final, closes paused session)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, { arrived: true, stopIds: ['stop-1'], session: 'paused' }); },
    run: (db) => commitStop(db, lcState.parent, H.v2TerminalStopEvent(lcState.arrival, 'skipped', 2), ['stop-1']) },
  { name: 'stop skipped batch (non-final)', actor: U.salesman, prep: async (env) => { lcState = await lcPrep(env, { arrived: true }); },
    run: (db) => commitStop(db, lcState.parent, H.v2TerminalStopEvent(lcState.arrival, 'skipped', 2), ['stop-1', 'stop-2']) },
  { name: 'route_plans get (own published)', actor: U.salesman, run: (db) => getDoc(doc(db, 'route_plans', 'route-own')) },
  { name: 'route_plan_progress get (own)', actor: U.salesman, prep: (env) => lcPrep(env, {}), run: (db) => getDoc(doc(db, 'route_plan_progress', LC_PROGRESS)) },
  { name: 'route_stop_progress get (missing canonical)', actor: U.salesman, run: (db) => getDoc(doc(db, 'route_stop_progress', `route-own_${S}_stop-9`)) },
  { name: 'orders get (own)', actor: U.salesman, prep: (env) => admin(env, (db) => setDoc(doc(db, 'orders', 'ORD-R'), p2Order('ORD-R'))), run: (db) => getDoc(doc(db, 'orders', 'ORD-R')) },
  { name: 'retailers get (member)', actor: U.salesman, run: (db) => getDoc(doc(db, 'retailers', 'retailer-1')) },
  { name: 'products get (member)', actor: U.salesman, run: (db) => getDoc(doc(db, 'products', 'product-1')) },
  { name: 'visit_briefs get (own)', actor: U.salesman, run: (db) => getDoc(doc(db, 'visit_briefs', 'brief-1')) },
  { name: 'tracking_controls get (own)', actor: U.salesman, prep: (env) => admin(env, (db) => setDoc(doc(db, 'tracking_controls', S), { mode: 'live', revision: 1, updatedByUid: U.admin.uid, updatedAt: now() })), run: (db) => getDoc(doc(db, 'tracking_controls', S)) },
  { name: 'config/plan get (member)', actor: U.salesman, prep: (env) => admin(env, (db) => setDoc(doc(db, 'config', 'plan'), { tier: 'standard' })), run: (db) => getDoc(doc(db, 'config', 'plan')) },
  { name: 'system_settings/order_purge get (salesman)', actor: U.salesman, prep: (env) => admin(env, (db) => setDoc(doc(db, 'system_settings', 'order_purge'), { days: 30 })), run: (db) => getDoc(doc(db, 'system_settings', 'order_purge')) },
];

const PUB_PLAN = 'route-pub';
const PUB_KEY = `${S}_20260615`;
const pubPlan = (status) => ({ planId: PUB_PLAN, createdByUid: U.admin.uid, salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', weekStart: WEEK, status,
  stopIds: ['stop-1', 'stop-2'], stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' }, totalStops: 2 });
const auditFull = (user) => H.auditPayload(user.uid, { actorRole: user.profile.role, actorName: user.profile.name });
const dash = [];
for (const [who, user] of [['admin', U.admin], ['supervisor', U.supervisor]]) {
  dash.push(
    { name: `route_plans create draft (${who})`, actor: user, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'route_plans', PUB_PLAN))),
      run: (db) => setDoc(doc(db, 'route_plans', PUB_PLAN), { ...pubPlan('draft'), createdByUid: user.uid }) },
    { name: `route_plans update draft->approved (${who})`, actor: user, prep: (env) => admin(env, (db) => setDoc(doc(db, 'route_plans', PUB_PLAN), pubPlan('draft'))),
      run: (db) => updateDoc(doc(db, 'route_plans', PUB_PLAN), { status: 'approved', updatedAt: serverTimestamp() }) },
    { name: `route publish batch (plan + publication key) (${who})`, actor: user,
      prep: (env) => admin(env, async (db) => { await setDoc(doc(db, 'route_plans', PUB_PLAN), pubPlan('approved')); await deleteDoc(doc(db, 'route_plan_publication_keys', PUB_KEY)); }),
      run: async (db) => { const b = writeBatch(db);
        b.update(doc(db, 'route_plans', PUB_PLAN), { status: 'published', publicationKeyId: PUB_KEY, updatedAt: serverTimestamp(), publishedAt: serverTimestamp() });
        b.set(doc(db, 'route_plan_publication_keys', PUB_KEY), { keyId: PUB_KEY, planId: PUB_PLAN, salesmanIdentity: S, salesmanUid: S, salesmanCode: 'S001', weekKey: '20260615', active: true, updatedByUid: user.uid });
        await b.commit(); } },
    { name: `tracking_controls create (${who})`, actor: user, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'tracking_controls', S))),
      run: (db) => setDoc(doc(db, 'tracking_controls', S), H.trackingControlPayload({ mode: 'live', revision: 1, updatedByUid: user.uid })) },
    { name: `tracking_controls update (${who})`, actor: user, prep: (env) => admin(env, (db) => setDoc(doc(db, 'tracking_controls', S), { mode: 'live', revision: 1, updatedByUid: U.admin.uid, updatedAt: now() })),
      run: (db) => setDoc(doc(db, 'tracking_controls', S), H.trackingControlPayload({ mode: 'standard', revision: 2, updatedByUid: user.uid })) },
    { name: `orders update approve (${who})`, actor: user,
      prep: (env) => admin(env, (db) => setDoc(doc(db, 'orders', 'ORD-APPR'), { ...p2Order('ORD-APPR'), submittedAt: now(), createdAt: now(), updatedAt: now(), serverPriceCheck: { status: 'ok', version: 1 } })),
      run: (db) => updateDoc(doc(db, 'orders', 'ORD-APPR'), { status: 'approved', approvedAt: serverTimestamp(), approvedByUid: user.uid, approvedByName: 'X', approvedByRole: user.profile.role, updatedAt: serverTimestamp() }) },
    { name: `orders update reject (${who})`, actor: user,
      prep: (env) => admin(env, (db) => setDoc(doc(db, 'orders', 'ORD-REJ'), { ...p2Order('ORD-REJ'), submittedAt: now(), createdAt: now(), updatedAt: now() })),
      run: (db) => updateDoc(doc(db, 'orders', 'ORD-REJ'), { status: 'rejected', rejectedAt: serverTimestamp(), rejectedByUid: user.uid, rejectedByName: 'X', rejectedByRole: user.profile.role, rejectionRemark: 'no', updatedAt: serverTimestamp() }) },
    { name: `purchase_orders create (${who})`, actor: user,
      prep: (env) => admin(env, async (db) => { await setDoc(doc(db, 'orders', 'ORD-PO'), { ...p2Order('ORD-PO'), status: 'approved', submittedAt: now(), createdAt: now(), updatedAt: now() }); await deleteDoc(doc(db, 'purchase_orders', 'ORD-PO')); }),
      run: (db) => setDoc(doc(db, 'purchase_orders', 'ORD-PO'), { poNumber: 'PO-20260615-ORD-PO', orderId: 'ORD-PO', retailerId: 'retailer-1', retailerName: 'Retailer One', salesmanCode: 'S001', salesmanUid: S,
        branchId: 'B1', totalPrice: 10, lines: [p2OrderItem()], status: 'issued', issuedAt: serverTimestamp(), issuedByUid: user.uid, issuedByRole: user.profile.role }) },
    { name: `special_requests update approve (${who})`, actor: user,
      prep: (env) => admin(env, (db) => setDoc(doc(db, 'special_requests', 'sr-appr'), H.specialRequest())),
      run: (db) => updateDoc(doc(db, 'special_requests', 'sr-appr'), { status: 'approved', approvalStep: 'Approved', updatedAt: serverTimestamp(), lastActorUid: user.uid, lastActorRole: user.profile.role, lastActionAt: serverTimestamp() }) },
    { name: `system_audit_logs create (${who})`, actor: user, run: (db) => setDoc(doc(db, 'system_audit_logs', `audit-${who}-${Date.now()}`), auditFull(user)) },
  );
}
dash.push(
  { name: 'system_audit_logs create (branch_manager)', actor: U.branchManager, run: (db) => setDoc(doc(db, 'system_audit_logs', `audit-bm-${Date.now()}`), auditFull(U.branchManager)) },
  { name: 'notifications create (supervisor)', actor: U.supervisor, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'notifications', 'n-sup'))), run: (db) => setDoc(doc(db, 'notifications', 'n-sup'), { title: 'T', message: 'M', type: 'order' }) },
  { name: 'products create (full, admin)', actor: U.admin, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'products', 'PRD-BUDGET'))), run: (db) => setDoc(doc(db, 'products', 'PRD-BUDGET'), productPayload()) },
  { name: 'products update (admin)', actor: U.admin, prep: (env) => admin(env, (db) => setDoc(doc(db, 'products', 'PRD-UPD'), { ...productPayload(), productId: 'PRD-UPD' })),
    run: (db) => updateDoc(doc(db, 'products', 'PRD-UPD'), { itemName: 'New', productName: 'New', unitPrice: 11, price: 11, priceGuide: 11, packingSize: '6 x 1L', priceUpdatedAt: serverTimestamp(), updatedAt: serverTimestamp() }) },
  { name: 'score_sheets template create (admin)', actor: U.admin, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'score_sheets', 'tpl_B_r1'))),
    run: (db) => H.writeTemplateLikeDashboard(db, H.templatePayload('tpl_B', 1, {}, U.admin.uid)) },
  { name: 'departments create (admin)', actor: U.admin, run: (db) => setDoc(doc(db, 'departments', `dep-${Date.now()}`), { name: 'Beverage', createdAt: serverTimestamp() }) },
  { name: 'order delete batch (admin)', measureOnly: true, actor: U.admin,
    prep: (env) => admin(env, async (db) => { await setDoc(doc(db, 'orders', 'ORD-DEL'), { ...p2Order('ORD-DEL'), status: 'draft', submittedAt: now(), createdAt: now(), updatedAt: now() }); await deleteDoc(doc(db, 'order_audit_logs', 'ORD-DEL')); }),
    run: (db) => fx.auditedOrderDelete(db, { uid: U.admin.uid, role: 'admin' }, 'ORD-DEL', 'draft') },
  { name: 'retailers create (admin)', actor: U.admin, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'retailers', 'ret-new'))),
    run: (db) => setDoc(doc(db, 'retailers', 'ret-new'), { retailerId: 'ret-new', retailerName: 'New', branchId: 'B1', status: 'active', createdAt: serverTimestamp() }) },
  { name: 'retailers update (admin, edit)', actor: U.admin, prep: (env) => admin(env, (db) => setDoc(doc(db, 'retailers', 'ret-edit'), { retailerId: 'ret-edit', retailerName: 'E', branchId: 'B1', status: 'active' })),
    run: (db) => updateDoc(doc(db, 'retailers', 'ret-edit'), { retailerName: 'E2', address: 'x', updatedAt: serverTimestamp() }) },
  { name: 'retailers update (admin, retire)', actor: U.admin, prep: (env) => admin(env, (db) => setDoc(doc(db, 'retailers', 'ret-ret'), { retailerId: 'ret-ret', retailerName: 'E', branchId: 'B1', status: 'active' })),
    run: (db) => updateDoc(doc(db, 'retailers', 'ret-ret'), { status: 'retired', stockListVisible: false, retiredAt: serverTimestamp(), retiredByUid: U.admin.uid, retiredByRole: 'admin', updatedAt: serverTimestamp() }) },
  { name: 'users update (admin edits salesman profile)', measureOnly: true, actor: U.admin, run: (db) => updateDoc(doc(db, 'users', U.otherSalesman.uid), { contactNumber: '0123', name: 'Two' }) },
  { name: 'users update (self profile)', measureOnly: true, actor: U.salesman, run: (db) => updateDoc(doc(db, 'users', S), { contactNumber: '0123' }) },
  { name: 'permission matrix save batch (matrix + 2 mirrors + audit, admin)', actor: U.admin,
    prep: (env) => admin(env, async (db) => { for (const p of [['system_access_config', 'permission_matrix'], ['role_permission_grants', 'supervisor'], ['role_permission_grants', 'branch_manager'], ['system_audit_logs', 'perm-audit-000001']]) await deleteDoc(doc(db, ...p)); }),
    run: async (db) => { const row = FULL_ROW; const b = writeBatch(db);
      b.set(doc(db, 'system_access_config', 'permission_matrix'), { roles: { admin: row, supervisor: row, branch_manager: row }, revision: 1, updatedByUid: U.admin.uid, updatedByName: 'A', updatedByEmail: 'a@x', updatedAt: serverTimestamp(), auditDocumentId: 'perm-audit-000001' });
      for (const role of ['supervisor', 'branch_manager']) b.set(doc(db, 'role_permission_grants', role), { role, grants: row, revision: 1, updatedByUid: U.admin.uid, updatedAt: serverTimestamp(), shape: 3 });
      b.set(doc(db, 'system_audit_logs', 'perm-audit-000001'), H.auditPayload(U.admin.uid, { action: 'permission_matrix_updated', entityType: 'system_access_config', entityId: 'permission_matrix', summary: 'Updated role permissions.', metadata: { granted: [], revoked: [], previousRevision: 0, nextRevision: 1 } }));
      await b.commit(); } },
  { name: 'products update (supervisor, granted Edit)', actor: U.supervisor,
    prep: (env) => admin(env, async (db) => { await grantRow(db, 'supervisor', ['products:edit']); await setDoc(doc(db, 'products', 'PRD-SUP'), { ...productPayload(), productId: 'PRD-SUP' }); }),
    run: (db) => updateDoc(doc(db, 'products', 'PRD-SUP'), { itemName: 'New', productName: 'New', unitPrice: 11, price: 11, priceGuide: 11, packingSize: '6 x 1L', priceUpdatedAt: serverTimestamp(), updatedAt: serverTimestamp() }) },
  { name: 'departments create (branch_manager, granted Create)', actor: U.branchManager,
    prep: (env) => admin(env, (db) => grantRow(db, 'branch_manager', ['departments:create'])),
    run: (db) => setDoc(doc(db, 'departments', `dep-bm-${Date.now()}`), { name: 'Beverage', createdAt: serverTimestamp() }) },
  { name: 'retailer_score_sheet_settings price update (supervisor, granted Edit)', actor: U.supervisor,
    prep: (env) => admin(env, async (db) => { await grantRow(db, 'supervisor', ['retailer_scoresheets:edit']);
      await setDoc(doc(db, 'retailers', 'ret-budget'), { retailerId: 'ret-budget', retailerName: 'B', branchId: 'B1', assignedSalesmanId: 'S001', status: 'active' });
      await setDoc(doc(db, 'retailer_score_sheet_settings', 'ret-budget'), { retailerId: 'ret-budget', sheetName: 'S', productOverrides: { p1: { unitPrice: 1 } } }); }),
    run: (db) => updateDoc(doc(db, 'retailer_score_sheet_settings', 'ret-budget'), { productOverrides: { p1: { unitPrice: 2, price: 2 } }, priceUpdatedAt: serverTimestamp(), updatedAt: serverTimestamp() }) },
  { name: 'coordinate proposal review batch (approve + retailer, admin)', actor: U.admin,
    prep: (env) => admin(env, async (db) => { await setDoc(doc(db, 'retailer_coordinate_proposals', 'prop-rev'), { proposalId: 'prop-rev', planId: 'route-own', stopId: 'stop-1', retailerId: 'retailer-1', candidateLatitude: 1.55, candidateLongitude: 110.35, salesmanUid: S, salesmanCode: 'S001', branchId: 'B1', createdAt: now(), status: 'pending', source: 'mobile_assigned_route' });
      await setDoc(doc(db, 'retailers', 'retailer-1'), { retailerId: 'retailer-1', retailerName: 'Retailer One', branchId: 'B1', salesmanUid: S, salesmanCode: 'S001', status: 'active' }); }),
    run: async (db) => { const b = writeBatch(db);
      b.update(doc(db, 'retailer_coordinate_proposals', 'prop-rev'), { status: 'approved', reviewedByUid: U.admin.uid, reviewedAt: serverTimestamp() });
      b.update(doc(db, 'retailers', 'retailer-1'), { latitude: 1.55, longitude: 110.35, coordinateStatus: 'verified', coordinateSource: 'admin_review', coordinateReviewStatus: 'reviewed', coordinateReviewedByUid: U.admin.uid, coordinateReviewedAt: serverTimestamp(), updatedAt: serverTimestamp() });
      await b.commit(); } },
  { name: 'branches create (admin)', actor: U.admin, run: (db) => setDoc(doc(db, 'branches', 'B9'), { name: 'Nine' }) },
  { name: 'privacy_deletion_requests create (self)', actor: U.salesman, prep: (env) => admin(env, (db) => deleteDoc(doc(db, 'privacy_deletion_requests', S))),
    run: (db) => setDoc(doc(db, 'privacy_deletion_requests', S), { requestType: 'account_deletion', status: 'submitted', createdAt: serverTimestamp() }) },
  { name: 'visits get (admin)', actor: U.admin, run: (db) => getDoc(doc(db, 'visits', 'sales-1_own-visit')) },
  { name: 'orders get (supervisor)', actor: U.supervisor, run: (db) => getDoc(doc(db, 'orders', 'order-team-location')) },
  { name: 'gps_tracking get (branch_manager)', actor: U.branchManager, run: (db) => getDoc(doc(db, 'gps_tracking', 'g-seed')) },
  { name: 'users get (supervisor reads team member)', measureOnly: true, actor: U.supervisor, run: (db) => getDoc(doc(db, 'users', S)) },
  { name: 'products get (supervisor)', measureOnly: true, actor: U.supervisor, run: (db) => getDoc(doc(db, 'products', 'product-1')) },
  { name: 'route_plans get (branch_manager)', actor: U.branchManager, run: (db) => getDoc(doc(db, 'route_plans', 'route-own')) },
);

const stamp = Timestamp.fromDate(new Date('2026-06-20T00:00:00Z'));
const fxSpecial = (o = {}) => ({ retailerName: 'Retailer 1', requestedItem: 'Special Item', reason: 'Retailer requested a non-standard item.', salesmanCode: 'S001', branchId: 'B1',
  createdByUid: 'sales-1', createdByRole: 'salesman', createdAt: stamp, updatedAt: stamp, status: 'pending_supervisor', approvalStep: 'Supervisor', lastActorUid: 'sales-1',
  lastActorRole: 'salesman', lastActionAt: stamp, ...o });
const fxVisit = (ownerUid) => ({ ownerUid, salesmanUid: ownerUid, marketplace: 'Retailer C', time: '11:00', purpose: 'Restock', notes: '', date: '2026-06-30', day: 'Tuesday',
  createdAt: serverTimestamp(), updatedAt: serverTimestamp() });
const rows = fx.buildAuditRows({ specialRequest: fxSpecial, newVisit: fxVisit });
const rowLabel = (row) => `${row.col} ${row.op}${row.label ? ` (${row.label})` : ''}`;
const fxCases = [];
rows.forEach((row, n) => {
  const allowedFor = (actor) => fx.SHAPES.some((shape) => fx.expectedAllowed(row, actor, shape));
  const picked = [...(allowedFor('admin') ? ['admin'] : []), ...['salesman', 'supervisor', 'manager'].filter(allowedFor).slice(0, 1)];
  for (const actor of picked) {
    fxCases.push({ kind: 'fx', name: `fx: ${rowLabel(row)}`, actorKey: actor, row, n,
      shapes: fx.SHAPES.filter((shape) => fx.expectedAllowed(row, actor, shape)),
      prep: (env) => admin(env, (db) => fx.resetRowState(db, row, actor, n)),
      run: (db) => fx.attemptRow(db, row, actor, n) });
  }
});

const calib = [
  { kind: 'suite', name: 'CALIB account_lock_receipts get (validLockId only)', actor: null, run: (db) => getDoc(doc(db, 'account_lock_receipts', 'a'.repeat(64))) },
  { kind: 'suite', name: 'CALIB dashboard_preferences get (signedIn + uid)', actor: U.salesman, run: (db) => getDoc(doc(db, 'dashboard_preferences', S)) },
];


module.exports = { phone, dash, fxCases, calib, admin };
