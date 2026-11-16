'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');

const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const {
  GeoPoint,
  Timestamp,
  arrayUnion,
  collection,
  deleteDoc,
  deleteField,
  doc,
  getDoc,
  getDocs,
  increment,
  limit,
  orderBy,
  documentId,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} = require('firebase/firestore');
const support = require('./rules_test_support.cjs');

const projectId = 'demo-fyp-a';
const mainRules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const BRANCH = 'HW1';
const PEOPLE = {
  admin: { uid: 'hw-admin', email: 'hw.admin@example.test', code: 'A0001', role: 'admin' },
  sup: { uid: 'hw-sup', email: 'hw.sup@example.test', code: 'SV0001', role: 'supervisor' },
  s1: { uid: 'hw-s1', email: 'hw.s1@example.test', code: 'S0001', role: 'salesman' },
  s2: { uid: 'hw-s2', email: 'hw.s2@example.test', code: 'S0002', role: 'salesman' },
};
const SEAT_CLASS = { admin: 'manager', supervisor: 'supervisor', salesman: 'salesman' };

const PRODUCT = {
  productId: 'HW-0001', departmentName: 'Hardware', mainCategoryName: 'Fasteners', categoryName: 'Fasteners',
  itemName: 'Wood screw 2in', itemCode: 'HW-0001', sku: 'HW-0001', uom: 'box', uomLabel: 'box', unitOfMeasure: 'box',
  unitPrice: 12.5, price: 12.5, priceGuide: 12.5, sortOrder: 1, brandName: '', importSource: 'list', isVisible: true,
  status: 'active',
};

const records = [];

async function attempt(operation) {
  try {
    await operation();
    return 'ALLOW';
  } catch (error) {
    if (error && (error.code === 'permission-denied' || String(error.message).includes('PERMISSION_DENIED'))) {
      return 'DENY';
    }
    throw error;
  }
}

async function check(group, label, expected, operation) {
  const observed = await attempt(operation);
  records.push({ group, label, expected, observed });
  console.log(`CASE | ${group} | ${label} | expected ${expected} | observed ${observed}`);
  assert.equal(observed, expected, `${group} | ${label}`);
}

function profileOf(person, extra = {}) {
  const isSalesman = person.role === 'salesman';
  return {
    uid: person.uid, userId: person.code, employeeCode: person.code, name: person.code, email: person.email,
    username: person.email.split('@')[0], role: person.role, user_group: person.role, status: 'active', isActive: true,
    branchId: BRANCH, branch_id: BRANCH, supervisorId: isSalesman ? 'SV0001' : '', supervisor_id: isSalesman ? 'SV0001' : '',
    contactNumber: '0123', contact_number: '0123',
    ...(person.role === 'supervisor' ? { assignedSalesmanCodes: ['S0001', 'S0002'] } : {}),
    ...extra,
  };
}

function accessV2Of(person, extra = {}) {
  const isSalesman = person.role === 'salesman';
  return {
    accessVersion: 2, uid: person.uid, userDocId: person.code, employeeCode: person.code, userId: person.code,
    email: person.email, role: person.role, user_group: person.role, status: 'active', isActive: true, branchId: BRANCH,
    branch_id: BRANCH, supervisorId: isSalesman ? 'SV0001' : '', supervisor_id: isSalesman ? 'SV0001' : '',
    supervisorUid: isSalesman ? PEOPLE.sup.uid : '',
    ...(person.role === 'supervisor' ? { assignedSalesmanCodes: ['S0001', 'S0002'] } : {}),
    ...extra,
  };
}

function accessLegacyOf(person) {
  const row = accessV2Of(person);
  delete row.accessVersion;
  delete row.supervisorUid;
  return row;
}

const preparedFields = (person) => ({ seatClass: SEAT_CLASS[person.role], seatHeld: true });

const preparedUsage = {
  usageSchemaVersion: 2,
  seats: { salesmen: 2, supervisors: 1, managers: 1 },
  products: 1,
  activeAdmins: 1,
  membershipMaintenance: { operationId: 'prepare-drill', writerVersion: 2 },
};

function publishedRoute(planId, person, stopId, retailerId) {
  const now = Timestamp.now();
  const today = new Date();
  today.setUTCHours(0, 0, 0, 0);
  const weekStart = Timestamp.fromMillis(today.getTime() - 86400000);
  const weekEnd = Timestamp.fromMillis(weekStart.toMillis() + 6 * 86400000);
  return {
    planId, createdByUid: PEOPLE.admin.uid, salesmanUid: person.uid, salesmanCode: person.code, salesmanName: person.code,
    branchId: BRANCH, weekStart, weekEnd, publishedAt: now, status: 'published', source: 'dashboard',
    optimisationMethod: 'haversine', totalStops: 1, stopIds: [stopId], stopRetailerIds: { [stopId]: retailerId },
    days: [{
      dayId: 'day-1', dayLabel: 'Today', date: Timestamp.fromMillis(today.getTime()), totalDistanceKm: 1, estimateSource: 'haversine',
      stops: [{
        stopId, dayId: 'day-1', retailerId, retailerName: 'Hardware Retailer', address: 'Synthetic fixture', lat: 1.5562,
        lng: 110.3562, sequence: 1, estimatedArrival: '10:45', estimatedDeparture: '10:55', priorityReason: 'Fixture',
        status: 'not_started', travelMinutesFromPrevious: 0, legDistanceKm: 0,
      }],
    }],
  };
}

async function seedCompany(testEnv, { prepared }) {
  await testEnv.clearFirestore();
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const seat = (person) => (prepared ? preparedFields(person) : {});
    await setDoc(doc(db, 'branches', BRANCH), { branchId: BRANCH, name: 'Hardware Branch', status: 'active' });
    for (const person of Object.values(PEOPLE)) {
      await setDoc(doc(db, 'users', person.code), profileOf(person, seat(person)));
    }
    for (const person of [PEOPLE.admin, PEOPLE.sup, PEOPLE.s1]) {
      await setDoc(doc(db, 'user_access', person.uid), accessV2Of(person, seat(person)));
    }
    await setDoc(doc(db, 'user_access', PEOPLE.s2.uid), { ...accessLegacyOf(PEOPLE.s2), ...seat(PEOPLE.s2) });
    await setDoc(doc(db, 'products', PRODUCT.productId), PRODUCT);
    await setDoc(doc(db, 'retailers', 'ret-1'), {
      retailerId: 'ret-1', retailerName: 'Hardware Retailer', name: 'Hardware Retailer', branchId: BRANCH, status: 'active',
      assignedSalesmanCode: 'S0001', assignedSalesmanId: 'S0001', assignedSalesmanUid: PEOPLE.s1.uid,
    });
    if (prepared) await setDoc(doc(db, 'config', 'usage'), preparedUsage);
  });
}

function asPerson(testEnv, person) {
  return testEnv.authenticatedContext(person.uid, { email: person.email, email_verified: true }).firestore();
}

function commercialLine(productId, name, quantity, priceInCents) {
  return `${productId}~${Buffer.from(name).toString('base64url')}~${quantity}~${priceInCents}`;
}

function forkOrder(person, orderId, { visitId = 'visit-hw-1', extra = {}, failureCode = 'unavailable' } = {}) {
  const item = {
    name: 'Wood screw 2in', productName: 'Wood screw 2in', productId: 'HW-0001', packingSize: 'box', price: 12.5, qty: 2,
    expiry: '2027-01-01', department: 'Hardware', departmentName: 'Hardware',
    shelfBatches: [{ qty: 2, expiry: '2027-01-01' }], remarks: '',
  };
  return {
    orderId, ...(visitId ? { visitId } : {}), visitSource: 'personal_planner', retailerId: 'ret-1',
    retailerName: 'Hardware Retailer', outlet: 'Hardware Retailer', uid: person.uid, userUid: person.uid,
    salesmanUid: person.uid, salesmanEmail: person.email, salesmanId: person.code, salesmanName: person.code,
    submittedByUid: person.uid, createdByUid: person.uid, branchId: BRANCH, supervisorId: 'SV0001',
    locationEvidence: { mode: 'not_verified', failureCode },
    totalProducts: 1, totalBoxes: 2, totalPrice: 25, submittedAt: serverTimestamp(), createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(), status: 'submitted', items: [item], commercialSchemaVersion: 1,
    commercialLines: [commercialLine('HW-0001', item.name, 2, 1250)],
    signatureTimestamps: { Hardware: '11/11/2026 09:50' }, ...extra,
  };
}

function trackingIdentity(person) {
  return {
    uid: person.uid, userUid: person.uid, salesmanUid: person.uid, salesmanId: person.code, salesmanName: person.code,
    salesmanEmail: person.email, submittedByUid: person.uid, submittedByEmail: person.email, submittedByName: person.code,
    staffId: person.code, employeeCode: person.code, salesmanCode: person.code, salesman_code: person.code, branchId: BRANCH,
  };
}

function orderTrackingRow(person, orderId) {
  const capturedAt = new Date();
  return {
    uid: person.uid, userUid: person.uid, userDocId: person.code, userId: person.code, salesmanUid: person.uid,
    salesmanEmail: person.email, salesmanId: person.code, salesmanName: person.code, salesmanRole: 'salesman',
    submittedByUid: person.uid, submittedByEmail: person.email, submittedByName: person.code, createdByUid: person.uid,
    createdByEmail: person.email, createdByName: person.code, staffId: person.code, employeeCode: person.code,
    salesmanCode: person.code, salesman_code: person.code, displayName: person.code, branchId: BRANCH, supervisorId: 'SV0001',
    latitude: 1.55, longitude: 110.35, gpsLatitude: 1.55, gpsLongitude: 110.35, location: new GeoPoint(1.55, 110.35),
    locationCapturedAt: serverTimestamp(), accuracy: 12, accuracyMeters: 12, deviceCapturedAt: capturedAt, isMocked: false,
    locationVerification: 'device_captured',
    locationEvidence: {
      mode: 'device_captured', latitude: 1.55, longitude: 110.35, accuracyMeters: 12, deviceCapturedAt: capturedAt,
      isMocked: false,
    },
    lastOrderId: orderId, lastRetailerId: 'ret-1', lastRetailerName: 'Hardware Retailer', timestamp: serverTimestamp(),
    lastSeen: serverTimestamp(), updatedAt: serverTimestamp(), status: 'active',
  };
}

function forkSpecialRequest(person, orderId) {
  return {
    orderId, requestType: 'urgent_delivery', retailerName: 'Hardware Retailer', requestedItem: 'Urgent delivery',
    reason: 'Customer needs the screws tomorrow.', salesmanCode: person.code, branchId: BRANCH, createdByUid: person.uid,
    createdByRole: 'salesman', status: 'pending_supervisor', approvalStep: 'Supervisor', lastActorUid: person.uid,
    lastActorRole: 'salesman', createdAt: serverTimestamp(), updatedAt: serverTimestamp(), lastActionAt: serverTimestamp(),
  };
}

function forkOutcome(person, outcomeId, planId, stopId) {
  return {
    outcomeId, issueId: 'issue-1', issueKey: 'low_sell_through::ret-1::HW-0001', issueType: 'low_sell_through',
    retailerId: 'ret-1', retailerName: 'Hardware Retailer', productId: 'HW-0001', productName: 'Wood screw 2in',
    reasonCode: 'low_sell_through', note: '', replacementProductId: '', salesmanUid: person.uid, salesmanCode: person.code,
    branchId: BRANCH, planId, stopId, sourceBriefId: 'brief-1', source: 'mobile_assigned_route_copilot', isDemo: false,
    clientCreatedAt: Timestamp.now(), submittedAt: serverTimestamp(),
  };
}

function forkParentProjection(parent, event, routeStopIds, base) {
  const terminal = event.status === 'completed' || event.status === 'skipped';
  const handled = new Set(parent.handledStopIds ?? []);
  if (terminal) handled.add(event.stopId);
  const routeComplete = routeStopIds.length > 0 && routeStopIds.every((stopId) => handled.has(stopId));
  const patch = {
    ...base,
    status: parent.status === 'completed' || routeComplete ? 'completed' : 'in_progress',
    lastStopWriteStopId: event.stopId,
    lastStopWriteStatus: event.status,
    lastStopWriteEventId: event.eventId,
    lastStopWriteWorkSessionGeneration: event.workSessionGeneration,
    lastStopWriteSequence: event.sessionEventSequence,
    updatedAt: serverTimestamp(),
    lastSyncedAt: serverTimestamp(),
    lastStopId: event.stopId,
    lastStopStatus: event.status,
    lastStopEventId: event.eventId,
    lastSummaryWorkSessionGeneration: event.workSessionGeneration,
    lastSummaryEventSequence: event.sessionEventSequence,
  };
  if (terminal) patch.handledStopIds = arrayUnion(event.stopId);
  if (terminal && parent.selectedStopId === event.stopId) {
    patch.selectedStopId = deleteField();
    patch.selectionRevision = parent.selectionRevision + 1;
  }
  return patch;
}

async function runPhoneSuite(testEnv, person, suffix, expectedOverrides = {}) {
  const group = `P5 old phone ${person.code} ${suffix}`;
  const db = asPerson(testEnv, person);
  const slug = `${person.code}-${suffix}`;
  const planId = `plan-${slug}`;
  const stopId = `stop-${slug}`;
  const sessionId = Buffer.from(slug).toString('hex').padEnd(32, '0').slice(0, 32);
  const orderId = `ORD-1762${slug}`;
  const visitId = `visit-${slug}`;
  const retailerId = 'ret-1';

  await testEnv.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await setDoc(doc(admin, 'route_plans', planId), publishedRoute(planId, person, stopId, retailerId));
    await setDoc(doc(admin, 'visit_briefs', `brief-${slug}`), {
      briefId: `brief-${slug}`, retailerId, retailerName: 'Hardware Retailer', salesmanUid: person.uid,
      salesmanCode: person.code, branchId: BRANCH, status: 'active',
      topInsights: [{
        issueId: `issue-${slug}`, issueKey: 'low_sell_through::ret-1::HW-0001', type: 'low_sell_through',
        productId: 'HW-0001', productName: 'Wood screw 2in',
      }],
    });
    await setDoc(doc(admin, 'ai_insights', `issue-${slug}`), {
      issueId: `issue-${slug}`, issueKey: 'low_sell_through::ret-1::HW-0001', type: 'low_sell_through', retailerId,
      retailerName: 'Hardware Retailer', productId: 'HW-0001', productName: 'Wood screw 2in', salesmanUid: person.uid,
      salesmanCode: person.code, branchId: BRANCH, status: 'open',
    });
  });

  await check(group, 'planner: create visit', 'ALLOW', () => setDoc(doc(db, 'visits', visitId), {
    ownerUid: person.uid, salesmanUid: person.uid, marketplace: 'Hardware Retailer', time: '10:00', purpose: 'Restock',
    notes: '', date: '2026-11-16', day: 'Monday', createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  }));
  await check(group, 'planner: update visit', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    marketplace: 'Hardware Retailer', time: '11:00', purpose: 'Restock again', notes: 'x', date: '2026-11-16',
    updatedAt: serverTimestamp(),
  }));
  await check(group, 'order draft: item selection step', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    draftStage: 1, progress: 1, status: 'selecting', step1At: serverTimestamp(), updatedAt: serverTimestamp(),
  }));
  await check(group, 'order draft: count step', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    draftStage: 2, cartDraftItems: [{ name: 'Wood screw 2in', productId: 'HW-0001', qty: 2 }], updatedAt: serverTimestamp(),
  }));
  await check(group, 'order draft: counting progress', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    progress: 2, status: 'counting', step2At: serverTimestamp(), updatedAt: serverTimestamp(),
  }));
  await check(group, 'order draft: sign-off draft', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    draftStage: 4, signatureDraft: { pendingOrderId: orderId, items: [{ name: 'Wood screw 2in' }], signatures: [] },
    pendingSignatures: ['Hardware'], updatedAt: serverTimestamp(),
  }));
  await check(group, 'order draft: save as draft', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    progress: 4, status: 'pending_signature', pendingSignatures: ['Hardware'], signOffDraftAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  }));

  await check(group, 'order submit: no location fix', 'ALLOW', () => setDoc(doc(db, 'orders', orderId), forkOrder(person, orderId, { visitId })));
  await check(group, 'order submit: location switched off', 'ALLOW', () => setDoc(
    doc(db, 'orders', `${orderId}-off`),
    forkOrder(person, `${orderId}-off`, { visitId: '', failureCode: 'disabled_by_user' }),
  ));
  await check(group, 'order gps_tracking row beside the order', 'ALLOW', () => setDoc(
    doc(db, 'gps_tracking', `order_${orderId}`),
    orderTrackingRow(person, orderId),
  ));
  await check(group, 'order side effect: merge own users row', 'ALLOW', () => setDoc(doc(db, 'users', person.code), {
    uid: person.uid, lastOrderId: orderId, lastOrderAt: serverTimestamp(), lastLatitude: 1.55, lastLongitude: 110.35,
    lastSeen: serverTimestamp(), lastLocationCapturedAt: new Date(),
  }, { merge: true }));
  await check(group, 'order submit then visit submitted update', 'ALLOW', () => updateDoc(doc(db, 'visits', visitId), {
    progress: 3, status: 'submitted', step3At: serverTimestamp(), submittedOrderId: orderId, draftStage: deleteField(),
    cartDraftItems: deleteField(), signatureDraft: deleteField(), pendingSignatures: deleteField(),
    updatedAt: serverTimestamp(),
  }));
  await check(group, 'special request beside the order', 'ALLOW', () => setDoc(
    doc(db, 'special_requests', orderId),
    forkSpecialRequest(person, orderId),
  ));

  let previousSession = null;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const row = await getDoc(doc(context.firestore(), 'live_tracking', person.uid));
    previousSession = row.exists() ? row.data() : null;
  });
  const generation = previousSession ? previousSession.activeSessionGeneration + 1 : 1;
  const startPayload = {
    ...(previousSession ? {} : trackingIdentity(person)),
    activeSessionId: sessionId, activeSessionGeneration: generation, lastFixSequence: 0, workSessionStatus: 'active',
    status: 'starting', workSessionStartedAt: serverTimestamp(), trackingMode: 'battery_saver', appliedControlRevision: 0,
    ...(previousSession ? { workSessionEndedAt: deleteField(), lastBreadcrumbCapturedAt: deleteField() } : {}),
  };
  await check(group, 'live tracking: start work session', 'ALLOW', () => setDoc(
    doc(db, 'live_tracking', person.uid),
    startPayload,
    { merge: true },
  ));
  const breadcrumbEventId = `session_${person.uid}_${sessionId}_1`;
  const firstFix = support.trackingFixPayload({ sessionId, generation, sequence: 1 });
  const breadcrumbOf = (fix, eventId) => ({
    ...trackingIdentity(person), eventId, activeSessionId: sessionId, activeSessionGeneration: generation, fixSequence: 1,
    latitude: fix.latitude, longitude: fix.longitude, gpsLatitude: fix.latitude, gpsLongitude: fix.longitude,
    location: fix.location, accuracy: 12, accuracyMeters: 12, deviceCapturedAt: fix.deviceCapturedAt, isMocked: false,
    locationSource: 'foreground_tracking', locationVerification: 'device_captured', timestamp: serverTimestamp(),
    updatedAt: serverTimestamp(),
  });
  await check(group, 'live + gps tracking: transaction that first reads the missing breadcrumb', 'DENY', () => runTransaction(db, async (transaction) => {
    await transaction.get(doc(db, 'live_tracking', person.uid));
    await transaction.get(doc(db, 'gps_tracking', breadcrumbEventId));
    transaction.set(doc(db, 'gps_tracking', breadcrumbEventId), breadcrumbOf(firstFix, breadcrumbEventId));
    transaction.set(doc(db, 'live_tracking', person.uid), { ...firstFix, lastBreadcrumbCapturedAt: firstFix.deviceCapturedAt }, { merge: true });
  }));
  await check(group, 'live + gps tracking: first fix and breadcrumb in one transaction without that read', 'ALLOW', () => runTransaction(db, async (transaction) => {
    await transaction.get(doc(db, 'live_tracking', person.uid));
    transaction.set(doc(db, 'gps_tracking', breadcrumbEventId), breadcrumbOf(firstFix, breadcrumbEventId));
    transaction.set(doc(db, 'live_tracking', person.uid), { ...firstFix, lastBreadcrumbCapturedAt: firstFix.deviceCapturedAt }, { merge: true });
  }));
  await check(group, 'live tracking: second fix without breadcrumb', 'ALLOW', () => setDoc(
    doc(db, 'live_tracking', person.uid),
    support.trackingFixPayload({ sessionId, generation, sequence: 2 }),
    { merge: true },
  ));

  const progressId = `${planId}_${person.uid}`;
  const parentRef = doc(db, 'route_plan_progress', progressId);
  const base = {
    progressId, planId, salesmanUid: person.uid, salesmanCode: person.code, branchId: BRANCH, isOfflineCreated: false,
  };
  await check(group, 'route plan progress: accept route', 'ALLOW', () => setDoc(parentRef, {
    ...base, status: 'accepted', stopProgress: {}, handledStopIds: [], acceptedAt: serverTimestamp(),
    updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
  }, { merge: true }));
  await check(group, 'route plan progress: start route', 'ALLOW', () => setDoc(parentRef, {
    ...base, status: 'in_progress', startedAt: serverTimestamp(), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
  }, { merge: true }));
  await check(group, 'route plan progress: select stop', 'ALLOW', () => setDoc(parentRef, {
    selectedStopId: stopId, selectionRevision: increment(1), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
  }, { merge: true }));

  const stopDocId = `${planId}_${person.uid}_${stopId}`;
  const arrival = support.v2ManualArrival({
    planId, salesmanUid: person.uid, salesmanCode: person.code, branchId: BRANCH, stopId, retailerId,
    workSessionId: sessionId, workSessionGeneration: generation, sessionEventSequence: 1,
  });
  const routeStopIds = [stopId];
  const commitStopEvent = async (event) => {
    const parent = (await getDoc(parentRef)).data();
    const batch = writeBatch(db);
    batch.set(doc(db, 'route_stop_progress', stopDocId), event);
    batch.set(parentRef, forkParentProjection(parent, event, routeStopIds, base), { merge: true });
    return batch.commit();
  };
  await check(group, 'route stop progress: arrival with parent projection', 'ALLOW', () => commitStopEvent(arrival));
  await check(group, 'route stop progress: complete stop', 'ALLOW', async () => {
    const prior = (await getDoc(doc(db, 'route_stop_progress', stopDocId))).data();
    const completedAt = Timestamp.fromMillis(Date.now());
    return commitStopEvent({
      ...prior,
      status: 'completed',
      eventId: `${sessionId}_${stopId}_completed`,
      sessionEventSequence: 2,
      deviceOccurredAt: completedAt,
      receivedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      completedAt,
    });
  });

  const assignedOrderId = `ORD-V2-${person.uid}.${planId}.${stopId}`;
  await check(group, 'order submit: assigned route stop', 'ALLOW', () => setDoc(doc(db, 'orders', assignedOrderId), forkOrder(person, assignedOrderId, {
    visitId: '',
    extra: { visitSource: 'assigned_route', routePlanId: planId, routeStopId: stopId },
  })));

  await check(group, 'conversation outcome', expectedOverrides['conversation outcome'] ?? 'ALLOW', () => setDoc(
    doc(db, 'conversation_outcomes', `outcome-${slug}`),
    {
      ...forkOutcome(person, `outcome-${slug}`, planId, stopId), issueId: `issue-${slug}`, sourceBriefId: `brief-${slug}`,
    },
  ));

  await check(group, 'own profile: settings update', 'ALLOW', () => updateDoc(doc(db, 'users', person.code), {
    offlineMode: false, gpsAutofill: true, pushNotifications: true, lastWeekTemplate: false,
  }));
  await check(group, 'own profile: phone merge', 'ALLOW', () => setDoc(
    doc(db, 'users', person.code),
    { phone: '0199' },
    { merge: true },
  ));
  const profileUpdate = {
    staffId: person.code, name: person.code, displayName: person.code, initials: 'S', email: person.email, phone: '0123',
    territory: 'Kuching', role: 'salesman', photoUrl: '', joinedDate: '2024-01-01',
  };
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', person.code), { staffId: deleteField() });
  });
  await check(group, 'own profile: edit screen save when the profile has no staffId key', 'DENY', () => setDoc(
    doc(db, 'users', person.code),
    profileUpdate,
    { merge: true },
  ));
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await updateDoc(doc(context.firestore(), 'users', person.code), { staffId: person.code });
  });
  await check(group, 'own profile: edit screen save when the profile has a staffId key', 'ALLOW', () => setDoc(
    doc(db, 'users', person.code),
    profileUpdate,
    { merge: true },
  ));
  await check(group, 'planner: delete own visit', 'ALLOW', () => deleteDoc(doc(db, 'visits', visitId)));
}

async function runDeniedCases(testEnv, group, person, otherPerson) {
  const db = asPerson(testEnv, person);
  const otherVisit = `visit-other-${person.code}-${group.length}`;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const admin = context.firestore();
    await setDoc(doc(admin, 'visits', otherVisit), {
      ownerUid: otherPerson.uid, salesmanUid: otherPerson.uid, marketplace: 'Other', time: '09:00', purpose: 'x', notes: '',
      date: '2026-11-16', day: 'Monday', createdAt: Timestamp.now(), updatedAt: Timestamp.now(),
    });
    await setDoc(doc(admin, 'route_plans', `plan-denied-${person.code}`), publishedRoute(`plan-denied-${person.code}`, person, 'stop-d', 'ret-1'));
  });
  await check(group, 'update another person visit', 'DENY', () => updateDoc(doc(db, 'visits', otherVisit), {
    purpose: 'taken over', updatedAt: serverTimestamp(),
  }));
  await check(group, 'delete another person visit', 'DENY', () => deleteDoc(doc(db, 'visits', otherVisit)));
  await check(group, 'create a visit owned by another person', 'DENY', () => setDoc(doc(db, 'visits', `visit-forged-${person.code}`), {
    ownerUid: otherPerson.uid, salesmanUid: otherPerson.uid, marketplace: 'Forged', time: '09:00', purpose: 'x', notes: '',
    date: '2026-11-16', day: 'Monday', createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
  }));
  await check(group, 'edit a route plan', 'DENY', () => updateDoc(doc(db, 'route_plans', `plan-denied-${person.code}`), {
    status: 'archived', updatedAt: serverTimestamp(),
  }));
  await check(group, 'create a route plan', 'DENY', () => setDoc(doc(db, 'route_plans', `plan-forged-${person.code}`), {
    ...publishedRoute(`plan-forged-${person.code}`, person, 'stop-f', 'ret-1'), status: 'draft', createdByUid: person.uid,
  }));
  await check(group, 'write ai_insights', 'DENY', () => setDoc(doc(db, 'ai_insights', `forged-${person.code}`), { value: true }));
  await check(group, 'order as another person', 'DENY', () => setDoc(
    doc(db, 'orders', `ORD-1762FORGED${person.code}`),
    forkOrder(otherPerson, `ORD-1762FORGED${person.code}`),
  ));
  await check(group, 'change own role on the profile', 'DENY', () => updateDoc(doc(db, 'users', person.code), { role: 'admin' }));
  await check(group, 'change own seat class on the access row', 'DENY', () => updateDoc(doc(db, 'user_access', person.uid), { seatClass: 'manager' }));
}

describe('legacy company data under the platform rules', function () {
  this.timeout(300000);
  let testEnv;

  async function openEnvironment(rules) {
    if (testEnv) await testEnv.cleanup();
    testEnv = await initializeTestEnvironment({ projectId, firestore: { rules } });
  }

  before(async () => {
    await openEnvironment(mainRules);
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
    console.log(`SUMMARY | ${records.length} cases recorded`);
  });

  for (const prepared of [false, true]) {
    const state = prepared ? 'after Prepare' : 'before Prepare';
    describe(`P5 old phone writes, main rules, ${state}`, () => {
      beforeEach(async () => {
        await openEnvironment(mainRules);
        await seedCompany(testEnv, { prepared });
      });

      it('lets the salesperson with an access row of version 2 write', async () => {
        await runPhoneSuite(testEnv, PEOPLE.s1, prepared ? 'post' : 'pre');
      });

      it('lets the salesperson with an access row without a version write', async () => {
        await runPhoneSuite(testEnv, PEOPLE.s2, prepared ? 'post' : 'pre');
      });

      it('keeps the refused cases refused for both salespeople', async () => {
        await runDeniedCases(testEnv, `P5 denied ${state} S0001`, PEOPLE.s1, PEOPLE.s2);
        await runDeniedCases(testEnv, `P5 denied ${state} S0002`, PEOPLE.s2, PEOPLE.s1);
      });
    });
  }

  describe('P4 supervisor team orders query', () => {
    beforeEach(async () => {
      await openEnvironment(mainRules);
      await seedCompany(testEnv, { prepared: true });
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const admin = context.firestore();
        const stored = (person, orderId, extra = {}) => ({
          ...forkOrder(person, orderId),
          submittedAt: Timestamp.fromMillis(Date.now() - 1000), createdAt: Timestamp.now(), updatedAt: Timestamp.now(), ...extra,
        });
        await setDoc(doc(admin, 'orders', 'ORD-fork-s1'), stored(PEOPLE.s1, 'ORD-fork-s1'));
        await setDoc(doc(admin, 'orders', 'ORD-fork-s2'), stored(PEOPLE.s2, 'ORD-fork-s2'));
        await setDoc(doc(admin, 'orders', 'ORD-coded-s1'), stored(PEOPLE.s1, 'ORD-coded-s1', { salesmanCode: 'S0001' }));
        await setDoc(doc(admin, 'orders', 'ORD-other-team'), stored(
          { ...PEOPLE.s1, uid: 'hw-s9', code: 'S0009', email: 'hw.s9@example.test' },
          'ORD-other-team',
          { salesmanCode: 'S0009' },
        ));
      });
    });

    it('allows the dashboard team orders query for the supervisor', async () => {
      const db = asPerson(testEnv, PEOPLE.sup);
      const teamCodes = ['S0001', 'S0002'];
      let snapshot;
      await check('P4 supervisor', 'main dashboard team orders query (salesmanCode in team, newest first)', 'ALLOW', async () => {
        snapshot = await getDocs(query(
          collection(db, 'orders'),
          where('salesmanCode', 'in', teamCodes),
          orderBy('submittedAt', 'desc'),
          orderBy(documentId(), 'desc'),
          limit(200),
        ));
      });
      const ids = snapshot.docs.map((row) => row.id).sort();
      console.log(`CASE | P4 supervisor | team orders query returned ${JSON.stringify(ids)}`);
      assert.deepEqual(ids, ['ORD-coded-s1']);
    });

    it('allows the same query without the ordering', async () => {
      const db = asPerson(testEnv, PEOPLE.sup);
      await check('P4 supervisor', 'team orders query without ordering', 'ALLOW', () => getDocs(query(
        collection(db, 'orders'),
        where('salesmanCode', 'in', ['S0001', 'S0002']),
      )));
    });

    it('allows the supervisor to read each fork order by identifier and refuses the other team', async () => {
      const db = asPerson(testEnv, PEOPLE.sup);
      await check('P4 supervisor', 'get fork order of S0001 (no salesmanCode)', 'ALLOW', () => getDoc(doc(db, 'orders', 'ORD-fork-s1')));
      await check('P4 supervisor', 'get fork order of S0002 (no salesmanCode)', 'ALLOW', () => getDoc(doc(db, 'orders', 'ORD-fork-s2')));
      await check('P4 supervisor', 'get order of another team', 'DENY', () => getDoc(doc(db, 'orders', 'ORD-other-team')));
    });

    it('allows the supervisor team users query', async () => {
      const db = asPerson(testEnv, PEOPLE.sup);
      await check('P4 supervisor', 'team users query (employeeCode in team)', 'ALLOW', () => getDocs(query(
        collection(db, 'users'),
        where('employeeCode', 'in', ['S0001', 'S0002']),
      )));
    });
  });
});
