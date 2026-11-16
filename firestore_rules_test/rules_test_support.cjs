const fs = require('node:fs');
const path = require('node:path');

const {
  assertSucceeds,
} = require('@firebase/rules-unit-testing');
const {
  GeoPoint,
  Timestamp,
  arrayUnion,
  deleteField,
  deleteDoc,
  doc,
  getDoc,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  writeBatch,
} = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const sourceRules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH ||
    path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);
const headroomUnits = Number(process.env.FIRESTORE_RULES_HEADROOM_UNITS || 0);
if (!Number.isInteger(headroomUnits) || headroomUnits < 0 || headroomUnits > 160) {
  throw new Error('FIRESTORE_RULES_HEADROOM_UNITS must be an integer from 0 to 160');
}
const rules = require('./identity_audit_fixtures.cjs').padRules(sourceRules, headroomUnits);

let testEnv;

const users = {
  admin: {
    uid: 'admin-uid',
    profile: { role: 'admin', status: 'active', isActive: true, branchId: 'B1', name: 'Admin' },
  },
  salesman: {
    uid: 'sales-1',
    profile: {
      role: 'salesman',
      status: 'active',
      employeeCode: 'S001',
      branchId: 'B1',
    },
  },
  otherSalesman: {
    uid: 'sales-2',
    profile: {
      role: 'salesman',
      status: 'active',
      employeeCode: 'S002',
      branchId: 'B2',
    },
  },
  suspendedSalesman: {
    uid: 'sales-suspended',
    profile: {
      role: 'salesman',
      status: 'suspended',
      employeeCode: 'S003',
      branchId: 'B1',
    },
  },
  suspendedMatchingSalesman: {
    uid: 'sales-suspended-matching',
    profile: {
      role: 'salesman',
      status: 'suspended',
      employeeCode: 'S001',
      branchId: 'B1',
    },
  },
  supervisor: {
    uid: 'supervisor-1',
    profile: {
      name: 'Supervisor One',
      role: 'supervisor',
      status: 'active',
      assignedSalesmanCodes: ['S001'],
      branchId: 'B1',
    },
  },
  unassignedSupervisor: {
    uid: 'supervisor-unassigned',
    profile: {
      role: 'supervisor',
      status: 'active',
      assignedSalesmanCodes: ['S009'],
      branchId: 'B1',
    },
  },
  suspendedSupervisor: {
    uid: 'supervisor-suspended',
    profile: {
      role: 'supervisor',
      status: 'suspended',
      assignedSalesmanCodes: ['S001'],
      branchId: 'B1',
    },
  },
  branchManager: {
    uid: 'manager-1',
    profile: { name: 'Manager One', role: 'branch_manager', status: 'active', branchId: 'B1' },
  },
  suspendedBranchManager: {
    uid: 'manager-suspended',
    profile: { role: 'branch_manager', status: 'suspended', branchId: 'B1' },
  },
};

let openContexts = [];

const signedInToken = () => ({ email: 'admin@example.test', auth_time: Math.floor(Date.now() / 1000) });

function authContext(uid) {
  const context = testEnv.authenticatedContext(uid, signedInToken());
  openContexts.push(context);
  return context;
}

function unauthContext() {
  const context = testEnv.unauthenticatedContext();
  openContexts.push(context);
  return context;
}

function dbFor(user) {
  return authContext(user.uid).firestore();
}

function unauthDb() {
  return unauthContext().firestore();
}

function assignedOrderId(uid, planId, stopId) {
  return `ORD-V2-${uid.trim()}.${planId.trim()}.${stopId.trim()}`;
}

function validTrackingPayload(uid = users.salesman.uid) {
  return {
    uid,
    salesmanUid: uid,
    salesmanCode: 'S001',
    branchId: 'B1',
    latitude: 1.5535,
    longitude: 110.3593,
    gpsLatitude: 1.5535,
    gpsLongitude: 110.3593,
    location: new GeoPoint(1.5535, 110.3593),
    accuracy: 12,
    accuracyMeters: 12,
    deviceCapturedAt: Timestamp.now(),
    isMocked: false,
    locationVerification: 'device_captured',
    timestamp: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

function workSessionStartFields(
  sessionId,
  generation,
  { trackingMode = 'battery_saver', appliedControlRevision = 0 } = {},
) {
  return {
    activeSessionId: sessionId,
    activeSessionGeneration: generation,
    lastFixSequence: 0,
    workSessionStatus: 'active',
    status: 'starting',
    workSessionStartedAt: serverTimestamp(),
    trackingMode,
    appliedControlRevision,
  };
}

function validWorkSessionStartPayload({
  uid = users.salesman.uid,
  salesmanCode = 'S001',
  branchId = 'B1',
  sessionId = 'a'.repeat(32),
  generation = 1,
} = {}) {
  return {
    uid,
    userUid: uid,
    salesmanUid: uid,
    salesmanId: salesmanCode,
    salesmanName: 'Salesman',
    salesmanEmail: `${uid}@example.test`,
    submittedByUid: uid,
    submittedByEmail: `${uid}@example.test`,
    submittedByName: 'Salesman',
    staffId: salesmanCode,
    employeeCode: salesmanCode,
    salesmanCode,
    salesman_code: salesmanCode,
    branchId,
    ...workSessionStartFields(sessionId, generation),
  };
}

function trackingFixPayload({
  sessionId = 'a'.repeat(32),
  generation = 1,
  sequence = 1,
  latitude = 1.5535,
  longitude = 110.3593,
  deviceCapturedAt = Timestamp.now(),
  trackingMode = 'battery_saver',
  appliedControlRevision = 0,
} = {}) {
  return {
    activeSessionId: sessionId,
    activeSessionGeneration: generation,
    lastFixSequence: sequence,
    workSessionStatus: 'active',
    status: 'active',
    trackingMode,
    appliedControlRevision,
    latitude,
    longitude,
    gpsLatitude: latitude,
    gpsLongitude: longitude,
    location: new GeoPoint(latitude, longitude),
    accuracy: 12,
    accuracyMeters: 12,
    deviceCapturedAt,
    isMocked: false,
    locationSource: 'foreground_tracking',
    locationVerification: 'device_captured',
    timestamp: serverTimestamp(),
    updatedAt: serverTimestamp(),
    lastSeen: serverTimestamp(),
    lastSyncedAt: serverTimestamp(),
    serverReceivedAt: serverTimestamp(),
  };
}

function trackingControlPayload({
  mode = 'live',
  revision = 1,
  updatedByUid = users.admin.uid,
} = {}) {
  return {
    mode,
    revision,
    updatedByUid,
    updatedAt: serverTimestamp(),
  };
}

function writeTrackingControlTransaction(db, salesmanUid, mode, actorUid) {
  const reference = doc(db, 'tracking_controls', salesmanUid);
  return (async () => {
    for (let contentionRetry = 0; contentionRetry < 3; contentionRetry += 1) {
      let revisionReadByAttempt;
      try {
        return await runTransaction(db, async (transaction) => {
          const current = await transaction.get(reference);
          const revision = current.exists() ? current.data().revision : 0;
          revisionReadByAttempt = revision;
          transaction.set(reference, trackingControlPayload({
            mode,
            revision: revision + 1,
            updatedByUid: actorUid,
          }));
        });
      } catch (error) {
        if (error.code !== 'permission-denied' ||
            revisionReadByAttempt == null || contentionRetry === 2) {
          throw error;
        }
        const current = await getDoc(reference);
        const currentRevision = current.data()?.revision;
        if (!current.exists() || !Number.isInteger(currentRevision) ||
            currentRevision <= revisionReadByAttempt) {
          throw error;
        }
      }
    }
    throw new Error('Tracking mode updates did not converge.');
  })();
}

function sessionBreadcrumbPayload({
  sessionId = 'a'.repeat(32),
  generation = 1,
  sequence = 1,
  latitude = 1.5535,
  longitude = 110.3593,
  deviceCapturedAt = Timestamp.now(),
} = {}) {
  const eventId = `session_${users.salesman.uid}_${sessionId}_${sequence}`;
  return {
    ...validTrackingPayload(),
    eventId,
    activeSessionId: sessionId,
    activeSessionGeneration: generation,
    fixSequence: sequence,
    latitude,
    longitude,
    gpsLatitude: latitude,
    gpsLongitude: longitude,
    location: new GeoPoint(latitude, longitude),
    deviceCapturedAt,
  };
}

function verifiedArrival(stopId = 'stop-1', distanceMeters = 12) {
  return {
    stopId,
    retailerId: 'retailer-1',
    retailerName: 'Retailer 1',
    status: 'arrived',
    arrivedAt: serverTimestamp(),
    arrivalEvidence: {
      mode: 'location_verified',
      reviewStatus: 'not_required',
      latitude: 1.5535,
      longitude: 110.3593,
      accuracyMeters: 12,
      deviceCapturedAt: Timestamp.now(),
      isMocked: false,
      distanceMeters,
    },
  };
}

function manualArrival(stopId = 'stop-1', failureCode = 'outside_radius') {
  return {
    stopId,
    retailerId: 'retailer-1',
    retailerName: 'Retailer 1',
    status: 'arrived',
    arrivedAt: serverTimestamp(),
    arrivalEvidence: {
      mode: 'manual_unverified',
      reviewStatus: 'pending',
      failureCode,
      overrideReasonCode: 'retailer_coordinates_incorrect',
      overrideNote: 'The retailer pin is shown in the wrong location.',
      latitude: 1.5535,
      longitude: 110.3593,
      accuracyMeters: 12,
      deviceCapturedAt: Timestamp.now(),
      isMocked: false,
      distanceMeters: 900000,
    },
  };
}

const routeStopTestSessionId = 'b'.repeat(32);

async function seedRouteStopWorkSession(
  uid = users.salesman.uid,
  sessionId = routeStopTestSessionId,
  generation = 1,
) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    await setDoc(doc(context.firestore(), 'live_tracking', uid), {
      uid,
      activeSessionId: sessionId,
      activeSessionGeneration: generation,
      workSessionStatus: 'active',
    });
  });
}

async function createSelectedRouteProgress(
  db,
  { planId, uid, salesmanCode, branchId, selectedStopId, routeSessionState },
) {
  const progressId = `${planId}_${uid}`;
  const reference = doc(db, 'route_plan_progress', progressId);
  await assertSucceeds(
    setDoc(reference, {
      progressId,
      planId,
      salesmanUid: uid,
      salesmanCode,
      branchId,
      isOfflineCreated: false,
      status: 'accepted',
      stopProgress: {},
      handledStopIds: [],
      acceptedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }),
  );
  await assertSucceeds(
    updateDoc(reference, {
      status: 'in_progress',
      startedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }),
  );
  for (const next of routeSessionState === 'paused'
    ? ['active', 'paused']
    : routeSessionState ? [routeSessionState] : []) {
    await assertSucceeds(
      updateDoc(reference, {
        routeSessionState: next,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  }
  await assertSucceeds(
    updateDoc(reference, {
      selectedStopId,
      selectionRevision: 1,
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }),
  );
  return reference;
}

function v2ManualArrival({
  planId,
  salesmanUid = users.salesman.uid,
  salesmanCode = 'S001',
  branchId = 'B1',
  stopId,
  retailerId,
  workSessionId = routeStopTestSessionId,
  workSessionGeneration = 1,
  sessionEventSequence = 1,
  deviceOccurredAt = Timestamp.fromMillis(Date.now()),
  arrivalFailureCode = 'disabled_by_user',
  overrideReasonCode = 'manager_approved_exception',
  overrideNote = 'GPS is unavailable; arrival was confirmed manually.',
}) {
  const eventId = `${workSessionId}_${stopId}_arrived`;
  return {
    planId,
    salesmanUid,
    salesmanCode,
    branchId,
    stopId,
    retailerId,
    retailerName: 'Retailer test',
    lifecycleSchemaVersion: 2,
    status: 'arrived',
    eventId,
    workSessionId,
    workSessionGeneration,
    sessionEventSequence,
    deviceOccurredAt,
    receivedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    arrivedAt: deviceOccurredAt,
    arrivalEventId: eventId,
    arrivalWorkSessionId: workSessionId,
    arrivalWorkSessionGeneration: workSessionGeneration,
    arrivalSessionEventSequence: sessionEventSequence,
    arrivalDeviceOccurredAt: deviceOccurredAt,
    arrivalReceivedAt: serverTimestamp(),
    arrivalMode: 'manual_unverified',
    arrivalFailureCode,
    retailerCoordinateRevision: '',
    retailerCoordinateSource: '',
    coordinateReferenceMode: 'unverified',
    overrideReasonCode,
    overrideNote,
  };
}

function haversineMeters(latitude1, longitude1, latitude2, longitude2) {
  const radians = (degrees) => (degrees * Math.PI) / 180;
  const latitudeDelta = radians(latitude2 - latitude1);
  const longitudeDelta = radians(longitude2 - longitude1);
  const a = Math.sin(latitudeDelta / 2) ** 2 +
    Math.cos(radians(latitude1)) * Math.cos(radians(latitude2)) *
    Math.sin(longitudeDelta / 2) ** 2;
  return 6_371_000 * 2 * Math.atan2(Math.sqrt(a), Math.sqrt(1 - a));
}

function v2VerifiedArrival({
  planId,
  stopId,
  retailerId,
  latitude,
  longitude,
  referenceLatitude = 1.5535,
  referenceLongitude = 110.3593,
  coordinateReferenceMode = 'current_retailer',
  retailerCoordinateRevision = 'current-revision-v1',
  retailerCoordinateSource = 'admin_review',
  coordinateSnapshotAt,
  coordinateCheckedAt = Timestamp.now(),
  arrivalDistanceMeters = haversineMeters(
    latitude,
    longitude,
    referenceLatitude,
    referenceLongitude,
  ),
  arrivalIsMocked = false,
  sessionEventSequence = 1,
  deviceOccurredAt = Timestamp.now(),
}) {
  const eventId = `${routeStopTestSessionId}_${stopId}_arrived`;
  return {
    planId,
    salesmanUid: users.salesman.uid,
    salesmanCode: 'S001',
    branchId: 'B1',
    stopId,
    retailerId,
    retailerName: 'Retailer evidence test',
    lifecycleSchemaVersion: 2,
    status: 'arrived',
    eventId,
    workSessionId: routeStopTestSessionId,
    workSessionGeneration: 1,
    sessionEventSequence,
    deviceOccurredAt,
    receivedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    arrivedAt: deviceOccurredAt,
    arrivalEventId: eventId,
    arrivalWorkSessionId: routeStopTestSessionId,
    arrivalWorkSessionGeneration: 1,
    arrivalSessionEventSequence: sessionEventSequence,
    arrivalDeviceOccurredAt: deviceOccurredAt,
    arrivalReceivedAt: serverTimestamp(),
    arrivalMode: 'location_verified',
    arrivalLatitude: latitude,
    arrivalLongitude: longitude,
    arrivalAccuracyMeters: 12,
    arrivalDeviceCapturedAt: deviceOccurredAt,
    arrivalIsMocked,
    arrivalDistanceMeters,
    retailerCoordinateRevision,
    retailerCoordinateSource,
    coordinateReferenceMode,
    ...(coordinateReferenceMode === 'current_retailer'
      ? { coordinateCheckedAt }
      : { coordinateSnapshotAt }),
  };
}

function v2TerminalStopEvent(arrival, status, sessionEventSequence) {
  const deviceOccurredAt = Timestamp.fromMillis(Date.now());
  const eventId = `${arrival.workSessionId}_${arrival.stopId}_${status}`;
  return {
    ...arrival,
    status,
    eventId,
    sessionEventSequence,
    deviceOccurredAt,
    receivedAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...(status === 'completed'
      ? { completedAt: deviceOccurredAt }
      : {
          skippedAt: deviceOccurredAt,
          skipReason: 'retailer_closed',
        }),
  };
}

function v2StopParentProjection(parent, event, routeStopIds) {
  const terminal = event.status === 'completed' || event.status === 'skipped';
  const nextHandled = new Set(parent.handledStopIds ?? []);
  if (terminal) nextHandled.add(event.stopId);
  const routeComplete = routeStopIds.length > 0 &&
    routeStopIds.every((stopId) => nextHandled.has(stopId));
  const oldGeneration = parent.lastSummaryWorkSessionGeneration ?? 0;
  const oldSequence = parent.lastSummaryEventSequence ?? 0;
  const isNewer = event.workSessionGeneration > oldGeneration ||
    (event.workSessionGeneration === oldGeneration &&
      event.sessionEventSequence > oldSequence);
  const patch = {
    status: parent.status === 'completed' || routeComplete
      ? 'completed'
      : 'in_progress',
    lastStopWriteStopId: event.stopId,
    lastStopWriteStatus: event.status,
    lastStopWriteEventId: event.eventId,
    lastStopWriteWorkSessionGeneration: event.workSessionGeneration,
    lastStopWriteSequence: event.sessionEventSequence,
    updatedAt: serverTimestamp(),
    lastSyncedAt: serverTimestamp(),
  };
  if (isNewer) {
    Object.assign(patch, {
      lastStopId: event.stopId,
      lastStopStatus: event.status,
      lastStopEventId: event.eventId,
      lastSummaryWorkSessionGeneration: event.workSessionGeneration,
      lastSummaryEventSequence: event.sessionEventSequence,
    });
  }
  if (terminal) patch.handledStopIds = arrayUnion(event.stopId);
  if (
    routeComplete &&
    parent.status !== 'completed' &&
    ['active', 'paused'].includes(parent.routeSessionState)
  ) {
    patch.routeSessionState = 'completed';
  }
  if (
    terminal &&
    parent.selectedStopId === event.stopId &&
    Number.isInteger(parent.selectionRevision)
  ) {
    patch.selectedStopId = deleteField();
    patch.selectionRevision = parent.selectionRevision + 1;
  }
  return patch;
}

async function commitV2StopEvent(
  db,
  parentRef,
  event,
  routeStopIds,
  tweakPatch = (patch) => patch,
) {
  const parent = (await getDoc(parentRef)).data();
  const stopRef = doc(
    db,
    'route_stop_progress',
    `${event.planId}_${event.salesmanUid}_${event.stopId}`,
  );
  const batch = writeBatch(db);
  batch.set(stopRef, event);
  batch.update(
    parentRef,
    tweakPatch(v2StopParentProjection(parent, event, routeStopIds)),
  );
  await batch.commit();
}

function newVisit(ownerUid) {
  return {
    ownerUid,
    salesmanUid: ownerUid,
    marketplace: 'Retailer C',
    time: '11:00',
    purpose: 'Restock',
    notes: '',
    date: '2026-06-30',
    day: 'Tuesday',
    createdAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
  };
}

function specialRequest(overrides = {}) {
  const stamp = Timestamp.fromDate(new Date('2026-06-20T00:00:00Z'));
  return {
    retailerName: 'Retailer 1',
    requestedItem: 'Special Item',
    reason: 'Retailer requested a non-standard item.',
    salesmanCode: 'S001',
    branchId: 'B1',
    createdByUid: users.salesman.uid,
    createdByRole: 'salesman',
    createdAt: stamp,
    updatedAt: stamp,
    status: 'pending_supervisor',
    approvalStep: 'Supervisor',
    lastActorUid: users.salesman.uid,
    lastActorRole: 'salesman',
    lastActionAt: stamp,
    ...overrides,
  };
}

async function seed() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    for (const user of Object.values(users)) {
      await setDoc(doc(db, 'users', user.uid), {
        ...user.profile,
        ...(user.profile.role === 'salesman'
          ? { lastLatitude: 1.55, lastLongitude: 110.35 }
          : {}),
      });
    }
    await setDoc(doc(db, 'users', 'legacy-sales-doc'), {
      uid: users.salesman.uid,
      role: 'salesman',
      status: 'active',
      employeeCode: 'S001',
      branchId: 'B1',
      lastLatitude: 1.55,
      lastLongitude: 110.35,
    });

    const commonRoute = {
      createdByUid: users.admin.uid,
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      weekStart: Timestamp.fromDate(new Date('2026-06-15T00:00:00Z')),
    };
    await setDoc(doc(db, 'route_plans', 'route-own'), {
      ...commonRoute,
      planId: 'route-own',
      status: 'published',
      stopIds: ['stop-1'],
      stopRetailerIds: { 'stop-1': 'retailer-1' },
      totalStops: 1,
      days: [{
        dayId: 'day-1',
        date: Timestamp.fromDate(new Date('2026-06-15T00:00:00Z')),
        stops: [{
          stopId: 'stop-1',
          retailerId: 'retailer-1',
          retailerName: 'Retailer One',
        }],
      }],
    });
    await setDoc(doc(db, 'route_plans', 'route-draft'), {
      ...commonRoute,
      planId: 'route-draft',
      status: 'draft',
      stopIds: ['stop-1'],
      stopRetailerIds: { 'stop-1': 'retailer-1' },
      totalStops: 1,
    });
    await setDoc(doc(db, 'route_plans', 'route-other'), {
      ...commonRoute,
      planId: 'route-other',
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      branchId: 'B2',
      status: 'published',
      stopIds: ['other-stop-1'],
      stopRetailerIds: { 'other-stop-1': 'retailer-other' },
      totalStops: 1,
      days: [{
        dayId: 'day-other',
        date: Timestamp.fromDate(new Date('2026-06-15T00:00:00Z')),
        stops: [{
          stopId: 'other-stop-1',
          retailerId: 'retailer-other',
          retailerName: 'Other Retailer',
        }],
      }],
    });

    for (const collection of [
      'ai_insights',
      'retailer_item_patterns',
      'retailer_segments',
      'retailer_memory',
      'visit_briefs',
      'retailer_priority_rankings',
    ]) {
      await setDoc(doc(db, collection, 'assigned'), {
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
      });
      await setDoc(doc(db, collection, 'other'), {
        salesmanUid: users.otherSalesman.uid,
        salesmanCode: 'S002',
        branchId: 'B2',
      });
    }

    await setDoc(
      doc(db, 'retailer_priority_rankings', 'assigned'),
      { generatedAt: Timestamp.now() },
      { merge: true },
    );
    await setDoc(
      doc(db, 'ai_insights', 'assigned'),
      { updatedAt: Timestamp.now() },
      { merge: true },
    );

    await setDoc(doc(db, 'retailers', 'retailer-1'), {
      retailerId: 'retailer-1',
      retailerName: 'Retailer One',
      branchId: 'B1',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      status: 'active',
    });
    await setDoc(doc(db, 'products', 'product-1'), {
      productId: 'product-1',
      productName: 'Product One',
      status: 'active',
    });
    await setDoc(doc(db, 'ai_insights', 'issue-1'), {
      issueId: 'issue-1',
      issueKey: 'low_sell_through::retailer-1::product-1',
      type: 'low_sell_through',
      retailerId: 'retailer-1',
      retailerName: 'Retailer One',
      productId: 'product-1',
      productName: 'Product One',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      status: 'open',
    });
    await setDoc(doc(db, 'visit_briefs', 'brief-1'), {
      briefId: 'brief-1',
      retailerId: 'retailer-1',
      retailerName: 'Retailer One',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      status: 'active',
      topInsights: [{
        issueId: 'issue-1',
        issueKey: 'low_sell_through::retailer-1::product-1',
        type: 'low_sell_through',
        productId: 'product-1',
        productName: 'Product One',
      }],
    });
    await setDoc(doc(db, 'retailers', 'retailer-other'), {
      retailerId: 'retailer-other',
      retailerName: 'Other Retailer',
      branchId: 'B2',
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      status: 'active',
    });
    await setDoc(doc(db, 'products', 'product-other'), {
      productId: 'product-other',
      productName: 'Other Product',
      status: 'active',
    });
    await setDoc(doc(db, 'ai_insights', 'issue-other'), {
      issueId: 'issue-other',
      issueKey: 'low_sell_through::retailer-other::product-other',
      type: 'low_sell_through',
      retailerId: 'retailer-other',
      retailerName: 'Other Retailer',
      productId: 'product-other',
      productName: 'Other Product',
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      branchId: 'B2',
      status: 'open',
    });

    await setDoc(doc(db, 'dashboard_notifications', 'admin'), {
      roleTarget: 'admin',
      branchId: '',
      salesmanCode: '',
      read: false,
    });
    await setDoc(doc(db, 'dashboard_notifications', 'team'), {
      roleTarget: 'supervisor',
      branchId: 'B1',
      salesmanCode: 'S001',
      read: false,
    });
    await setDoc(doc(db, 'dashboard_notifications', 'other-team'), {
      roleTarget: 'supervisor',
      branchId: 'B2',
      salesmanCode: 'S002',
      read: false,
    });
    await setDoc(doc(db, 'weekly_ai_summaries', 'salesman-S001'), {
      scopeType: 'salesman',
      scopeKey: 'S001',
      weekStart: '2026-06-15',
    });
    await setDoc(doc(db, 'weekly_ai_summaries', 'branch-B1'), {
      scopeType: 'branch',
      scopeKey: 'B1',
      weekStart: '2026-06-15',
    });

    await setDoc(doc(db, 'route_plan_publication_keys', 'S001_20260615'), {
      keyId: 'S001_20260615',
      planId: 'route-own',
      salesmanIdentity: 'S001',
      weekKey: '20260615',
      active: true,
      updatedByUid: users.admin.uid,
    });
    await setDoc(doc(db, 'route_plan_publication_keys', 'S002_20260615'), {
      keyId: 'S002_20260615',
      planId: 'route-other',
      salesmanIdentity: 'S002',
      weekKey: '20260615',
      active: true,
      updatedByUid: users.admin.uid,
    });

    const seededVisitAt = Timestamp.fromDate(new Date('2026-06-20T00:00:00Z'));
    await setDoc(doc(db, 'visits', 'sales-1_own-visit'), {
      ownerUid: users.salesman.uid,
      salesmanUid: users.salesman.uid,
      marketplace: 'Retailer A',
      time: '09:00',
      purpose: 'Restock',
      notes: '',
      date: '2026-06-29',
      day: 'Monday',
      createdAt: seededVisitAt,
      updatedAt: seededVisitAt,
    });
    await setDoc(doc(db, 'visits', 'sales-2_other-visit'), {
      ownerUid: users.otherSalesman.uid,
      salesmanUid: users.otherSalesman.uid,
      marketplace: 'Retailer B',
      time: '10:00',
      purpose: 'Restock',
      notes: '',
      date: '2026-06-29',
      day: 'Monday',
      createdAt: seededVisitAt,
      updatedAt: seededVisitAt,
    });
    await setDoc(doc(db, 'visits', 'sales-suspended_own-visit'), {
      ownerUid: users.suspendedSalesman.uid,
      salesmanUid: users.suspendedSalesman.uid,
      marketplace: 'Retailer Suspended',
      time: '11:00',
      purpose: 'Restock',
      notes: '',
      date: '2026-06-29',
      day: 'Monday',
      createdAt: seededVisitAt,
      updatedAt: seededVisitAt,
    });

    await setDoc(doc(db, 'login_attempts', 'counter-user'), {
      failedCount: 2,
      lastAttempt: seededVisitAt,
      username: 'counter-user',
    });

    await setDoc(doc(db, 'gps_tracking', 'g-seed'), {
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      lat: 1.55,
      lng: 110.35,
    });
    await setDoc(doc(db, 'gps_tracking', 'g-other'), {
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      branchId: 'B2',
      lat: 3.14,
      lng: 101.69,
    });
    await setDoc(doc(db, 'live_tracking', users.salesman.uid), {
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      latitude: 1.55,
      longitude: 110.35,
    });
    await setDoc(doc(db, 'live_tracking', users.otherSalesman.uid), {
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      branchId: 'B2',
      latitude: 3.14,
      longitude: 101.69,
    });
    await setDoc(doc(db, 'visit_logs', 'vl-other'), {
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      retailerId: 'r1',
    });
    await setDoc(doc(db, 'visit_logs', 'vl-own-team'), {
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      retailerId: 'r1',
      latitude: 1.55,
      longitude: 110.35,
    });
    await setDoc(doc(db, 'orders', 'order-team-location'), {
      orderId: 'order-team-location',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      latitude: 1.55,
      longitude: 110.35,
    });
    await setDoc(doc(db, 'orders', 'order-other-location'), {
      orderId: 'order-other-location',
      salesmanUid: users.otherSalesman.uid,
      salesmanCode: 'S002',
      branchId: 'B2',
      latitude: 3.14,
      longitude: 101.69,
    });
  });
}

const PROBE_SESSION = 'b'.repeat(32);

async function reshape(user, shape) {
  if (shape === 'uid') return;
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const p = user.profile;
    const docId = user.uid === users.salesman.uid ? 'legacy-sales-doc' : `${user.uid}@probe.test`;
    await deleteDoc(doc(db, 'users', user.uid));
    const legacyRole = shape === 'linked' && p.role === 'salesman' ? 'sales representative' : p.role;
    await setDoc(doc(db, 'users', docId), { ...p, role: legacyRole, uid: user.uid });
    if (shape === 'linked') {
      await setDoc(doc(db, 'user_access', user.uid), {
        ...p, role: legacyRole, uid: user.uid, user_group: legacyRole, userDocId: docId,
      });
    } else {
      await setDoc(doc(db, 'user_access', user.uid), {
        accessVersion: 2, uid: user.uid, role: p.role, status: 'active',
        branchId: p.branchId || '', employeeCode: p.employeeCode || '', userDocId: docId,
        ...(p.role === 'salesman' ? { supervisorUid: users.supervisor.uid } : {}),
        ...(p.role === 'supervisor' ? { assignedSalesmanCodes: p.assignedSalesmanCodes } : {}),
      });
    }
  });
}

async function seedLiveSession({ lastFixSequence, startedAgoMs = 60 * 60 * 1000, lastFixAgoMs = 1000, status = 'active' }) {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    await setDoc(doc(db, 'live_tracking', users.salesman.uid), {
      ...validWorkSessionStartPayload({ sessionId: PROBE_SESSION }),
      ...trackingFixPayload({
        sessionId: PROBE_SESSION, generation: 1, sequence: lastFixSequence,
        deviceCapturedAt: Timestamp.fromMillis(Date.now() - lastFixAgoMs),
      }),
      workSessionStatus: status,
      status: status === 'active' ? 'active' : 'inactive',
      workSessionStartedAt: Timestamp.fromMillis(Date.now() - startedAgoMs),
      ...(status === 'ended' ? { workSessionEndedAt: Timestamp.fromMillis(Date.now() - 500) } : {}),
      timestamp: Timestamp.now(), updatedAt: Timestamp.now(), lastSeen: Timestamp.now(),
      lastSyncedAt: Timestamp.now(), serverReceivedAt: Timestamp.now(),
    });
  });
}

function probeBacklog(sequence, deviceCapturedAt, overrides = {}) {
  return {
    ...sessionBreadcrumbPayload({ sessionId: PROBE_SESSION, generation: 1, sequence, deviceCapturedAt }),
    backlog: true,
    ...overrides,
  };
}

function noOrderOutcome(overrides = {}) {
  return {
    outcomeId: 'probe-noorder', outcomeKind: 'no_order', retailerId: 'retailer-1', retailerName: 'Retailer One',
    reasonCode: 'retailer_busy', note: '', salesmanUid: users.salesman.uid, salesmanCode: 'S001', branchId: 'B1',
    planId: 'route-own', stopId: 'stop-1', source: 'mobile_assigned_route_no_order', isDemo: false,
    clientCreatedAt: Timestamp.now(), submittedAt: serverTimestamp(), ...overrides,
  };
}

function templatePayload(templateId, revision, extra, uid) {
  const productIds = Array.from({ length: 121 }, (_, i) => `P${String(i).padStart(4, '0')}`);
  return {
    kind: 'template', templateId, revision, name: 'N'.repeat(120), productIds, productCount: productIds.length,
    status: 'active', sourceRetailerId: 'retailer-1', sourceRetailerName: 'Retailer One', ...extra,
    createdByUid: uid, createdAt: serverTimestamp(),
  };
}

function writeTemplateLikeDashboard(db, payload) {
  const ref = doc(db, 'score_sheets', `${payload.templateId}_r${payload.revision}`);
  return runTransaction(db, async (transaction) => {
    if ((await transaction.get(ref)).exists()) throw new Error('exists');
    transaction.set(ref, payload);
  });
}

function auditPayload(uid, overrides = {}) {
  return {
    action: 'copilot_order_export', entityType: 'orders', entityId: 'search',
    summary: 'Exported 120 orders (This month)', actorUid: uid, actorEmail: 'admin@example.test',
    actorName: 'Admin', actorRole: 'admin',
    metadata: {
      source: 'assistant', rowCount: 120, truncated: false, period: 'month', periodLabel: 'This month',
      start: '2026-11-01T00:00:00.000', end: '2026-11-30T00:00:00.000', salespersonId: null, retailerId: null,
    },
    createdAt: serverTimestamp(), ...overrides,
  };
}

module.exports = {
  projectId, rules,
  setTestEnv: (e) => { testEnv = e; },
  getTestEnv: () => testEnv,
  trackContext: (context) => { openContexts.push(context); },
  cleanupContexts: () => { for (const c of openContexts) c.cleanup(); openContexts = []; },
  signedInToken, users, seed, reshape, dbFor, authContext, unauthContext, unauthDb, assignedOrderId, validTrackingPayload, workSessionStartFields,
  validWorkSessionStartPayload, trackingFixPayload, trackingControlPayload, writeTrackingControlTransaction, sessionBreadcrumbPayload,
  seedRouteStopWorkSession, createSelectedRouteProgress, verifiedArrival, manualArrival, commitV2StopEvent,
  seedLiveSession, probeBacklog, noOrderOutcome, templatePayload, writeTemplateLikeDashboard, auditPayload,
  v2ManualArrival, v2VerifiedArrival, v2TerminalStopEvent, v2StopParentProjection, newVisit, specialRequest,
  PROBE_SESSION, routeStopTestSessionId,
};
