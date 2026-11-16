const assert = require('node:assert/strict');

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  GeoPoint,
  Timestamp,
  arrayUnion,
  collection,
  deleteField,
  deleteDoc,
  doc,
  getCountFromServer,
  getDoc,
  getDocs,
  increment,
  limit,
  orderBy,
  query,
  runTransaction,
  serverTimestamp,
  setDoc,
  updateDoc,
  where,
  writeBatch,
} = require('firebase/firestore');

const support = require('./rules_test_support.cjs');
const {
  assignedOrderId,
  authContext,
  commitV2StopEvent,
  createSelectedRouteProgress,
  dbFor,
  manualArrival,
  newVisit,
  projectId,
  rules,
  seed,
  seedRouteStopWorkSession,
  sessionBreadcrumbPayload,
  specialRequest,
  trackingControlPayload,
  trackingFixPayload,
  unauthContext,
  unauthDb,
  users,
  v2ManualArrival,
  v2StopParentProjection,
  v2TerminalStopEvent,
  v2VerifiedArrival,
  validTrackingPayload,
  validWorkSessionStartPayload,
  verifiedArrival,
  workSessionStartFields,
  writeTrackingControlTransaction,
} = support;

let testEnv;

before(async () => {
  testEnv = await initializeTestEnvironment({
    projectId,
    firestore: { rules },
  });
  support.setTestEnv(testEnv);
});

beforeEach(async () => {
  await testEnv.clearFirestore();
  await seed();
});

afterEach(() => {
  support.cleanupContexts();
});

after(async () => {
  if (testEnv) await testEnv.cleanup();
});

describe('profile and record ownership regression', () => {
  it('[privacy-delete-access] lets a signed-in user request account deletion without deleting it', async () => {
    const ownerDb = dbFor(users.salesman);
    const requestRef = doc(
      ownerDb,
      'privacy_deletion_requests',
      users.salesman.uid,
    );

    await assertSucceeds(setDoc(requestRef, {
      requestType: 'account_deletion',
      status: 'submitted',
      createdAt: serverTimestamp(),
    }));
    await assertSucceeds(getDoc(requestRef));
    await assertFails(getDocs(collection(ownerDb, 'privacy_deletion_requests')));
    await assertFails(updateDoc(requestRef, {
      status: 'completed',
      updatedAt: serverTimestamp(),
    }));
    await assertFails(deleteDoc(requestRef));
    await assertFails(setDoc(doc(
      ownerDb,
      'privacy_deletion_requests',
      users.otherSalesman.uid,
    ), {
      requestType: 'account_deletion',
      status: 'submitted',
      createdAt: serverTimestamp(),
    }));

    const adminDb = dbFor(users.admin);
    await assertSucceeds(
      getDocs(collection(adminDb, 'privacy_deletion_requests')),
    );
    const pendingRequests = await assertSucceeds(getDocs(query(
      collection(adminDb, 'privacy_deletion_requests'),
      where('status', 'in', ['submitted', 'reviewing']),
    )));
    assert.equal(pendingRequests.size, 1);
    await assertSucceeds(updateDoc(
      doc(adminDb, 'privacy_deletion_requests', users.salesman.uid),
      { status: 'reviewing', updatedAt: serverTimestamp() },
    ));
    await assertSucceeds(updateDoc(
      doc(adminDb, 'privacy_deletion_requests', users.salesman.uid),
      { status: 'rejected', updatedAt: serverTimestamp() },
    ));
    await assertSucceeds(updateDoc(requestRef, {
      status: 'submitted',
      createdAt: serverTimestamp(),
    }));
  });

  it('[privacy-delete-access] lets an admin restore an account during the hour after Delete now', async () => {
    await assertSucceeds(setDoc(doc(dbFor(users.salesman), 'privacy_deletion_requests', users.salesman.uid), {
      requestType: 'account_deletion', status: 'submitted', createdAt: serverTimestamp(),
    }));
    const adminDb = dbFor(users.admin);
    const ref = doc(adminDb, 'privacy_deletion_requests', users.salesman.uid);
    await assertSucceeds(updateDoc(ref, { status: 'completed', updatedAt: serverTimestamp() }));
    const open = await assertSucceeds(getDocs(query(
      collection(adminDb, 'privacy_deletion_requests'),
      where('status', 'in', ['submitted', 'reviewing', 'completed']),
    )));
    assert.equal(open.size, 1);
    await assertFails(updateDoc(ref, { status: 'reviewing', updatedAt: serverTimestamp() }));
    await assertSucceeds(updateDoc(ref, { status: 'rejected', updatedAt: serverTimestamp() }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'privacy_deletion_requests', users.salesman.uid), {
        requestType: 'account_deletion', status: 'completed', createdAt: new Date('2026-10-01T00:00:00Z'), purgedAt: new Date('2026-10-09T00:00:00Z'),
      });
    });
    await assertFails(updateDoc(ref, { status: 'rejected', updatedAt: serverTimestamp() }));
  });

  it('[privacy-delete-access] leaves profile removal to the server', async () => {
    await assertFails(deleteDoc(doc(dbFor(users.salesman), 'users', users.salesman.uid)));
    await assertFails(deleteDoc(doc(dbFor(users.salesman), 'users', users.otherSalesman.uid)));
    await assertFails(deleteDoc(doc(dbFor(users.admin), 'users', users.admin.uid)));
    await assertFails(deleteDoc(doc(dbFor(users.admin), 'users', users.salesman.uid)));

    const adminAlias = 'privacy-delete-admin-alias';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', adminAlias), {
        role: 'admin',
        status: 'active',
      });
      await setDoc(doc(db, 'user_access', users.admin.uid), {
        uid: users.admin.uid,
        userDocId: adminAlias,
        role: 'admin',
        status: 'active',
      });
    });
    await assertFails(deleteDoc(doc(dbFor(users.admin), 'users', adminAlias)));

    const developerUid = 'privacy-delete-developer';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', developerUid), {
        role: 'developer',
        status: 'active',
      });
    });
    const developerDb = dbFor({ uid: developerUid });
    await assertFails(updateDoc(
      doc(developerDb, 'users', developerUid),
      { role: 'admin' },
    ));
    await assertFails(updateDoc(
      doc(developerDb, 'users', users.otherSalesman.uid),
      {
        uid: 'privacy-delete-fake-auth',
        provisioningState: 'pending',
        provisioningByUid: developerUid,
      },
    ));
    await assertFails(deleteDoc(
      doc(developerDb, 'users', users.otherSalesman.uid),
    ));
    await assertFails(getDocs(collection(developerDb, 'privacy_deletion_requests')));

    const pendingProfileId = 'privacy-delete-pending-profile';
    await assertFails(setDoc(doc(developerDb, 'users', 'privacy-delete-forged-marker'), {
      uid: 'privacy-delete-forged-auth',
      role: 'salesman',
      status: 'active',
      provisioningState: 'pending',
      provisioningByUid: 'another-creator',
    }));
    await assertFails(setDoc(doc(developerDb, 'users', pendingProfileId), {
      uid: 'privacy-delete-pending-auth',
      role: 'salesman',
      status: 'active',
      provisioningState: 'pending',
      provisioningByUid: developerUid,
    }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', pendingProfileId), {
        uid: 'privacy-delete-pending-auth',
        role: 'salesman',
        status: 'active',
        provisioningState: 'pending',
        provisioningByUid: developerUid,
      });
    });
    await assertFails(deleteDoc(doc(developerDb, 'users', pendingProfileId)));
  });

  it('denies changing or reading another branches retailer from the callers branch', async () => {
    const db = dbFor(users.branchManager);
    await assertFails(updateDoc(doc(db, 'retailers', 'retailer-other'), {
      branchId: 'B1', branch_id: 'B1', retailerName: 'Taken over',
    }));
    await assertFails(updateDoc(doc(db, 'retailers', 'retailer-1'), {
      retailerName: 'Updated own branch',
    }));
    await assertSucceeds(getDoc(doc(db, 'retailers', 'retailer-1')));
    await assertFails(getDoc(doc(db, 'retailers', 'retailer-other')));
  });

  it('allows scoped soft retirement but denies hard delete and immutable-field changes', async () => {
    const adminDb = dbFor(users.admin);
    await assertSucceeds(updateDoc(doc(adminDb, 'retailers', 'retailer-1'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.admin.uid,
      retiredByRole: 'admin',
      updatedAt: serverTimestamp(),
    }));
    await assertFails(deleteDoc(doc(adminDb, 'retailers', 'retailer-1')));

    await assertFails(updateDoc(doc(adminDb, 'retailers', 'retailer-other'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.admin.uid,
      retiredByRole: 'admin',
      updatedAt: serverTimestamp(),
      retailerName: 'Forged identity',
    }));
  });

  it('limits soft retirement to admin/developer (branch managers are view-only)', async () => {
    const managerDb = dbFor(users.branchManager);
    await assertFails(updateDoc(doc(managerDb, 'retailers', 'retailer-1'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.branchManager.uid,
      retiredByRole: 'branch_manager',
      updatedAt: serverTimestamp(),
    }));

    await assertFails(updateDoc(doc(managerDb, 'retailers', 'retailer-other'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.branchManager.uid,
      retiredByRole: 'branch_manager',
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(doc(dbFor(users.salesman), 'retailers', 'retailer-1'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.salesman.uid,
      retiredByRole: 'salesman',
      updatedAt: serverTimestamp(),
    }));
  });

  it('protects legacy is_demo retailers from soft retirement', async () => {
    const adminDb = dbFor(users.admin);
    await setDoc(doc(adminDb, 'retailers', 'legacy-demo-retailer'), {
      retailerId: 'legacy-demo-retailer',
      retailerName: 'Legacy fixture',
      branchId: 'B1',
      status: 'active',
      is_demo: 'true',
    });
    await assertFails(updateDoc(doc(adminDb, 'retailers', 'legacy-demo-retailer'), {
      status: 'retired',
      stockListVisible: false,
      retiredAt: serverTimestamp(),
      retiredByUid: users.admin.uid,
      retiredByRole: 'admin',
      updatedAt: serverTimestamp(),
    }));
  });

  it('keeps notification read-through state private and server-timestamped', async () => {
    const adminDb = dbFor(users.admin);
    const state = doc(adminDb, 'notification_read_state', users.admin.uid);
    await assertSucceeds(setDoc(state, {
      readThroughAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(state, {
      readThroughAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertFails(deleteDoc(state));
    await assertFails(setDoc(
      doc(dbFor(users.salesman), 'notification_read_state', users.admin.uid),
      { readThroughAt: serverTimestamp() },
    ));
    await assertFails(setDoc(
      doc(adminDb, 'notification_read_state', 'someone-else'),
      { readThroughAt: serverTimestamp() },
    ));
    await assertFails(updateDoc(state, {
      readThroughAt: Timestamp.fromDate(new Date('2099-01-01T00:00:00Z')),
    }));
  });

  it('enforces deterministic action status ids while allowing own edits', async () => {
    const owner = dbFor(users.admin);
    const id = `${users.admin.uid}_action-1`;
    await assertFails(
      setDoc(doc(owner, 'action_centre_user_status', 'arbitrary-status-id'), {
        uid: users.admin.uid, actionId: 'action-1', status: 'in_review',
      }),
    );
    await assertFails(
      setDoc(doc(owner, 'action_centre_user_status', `${users.admin.uid}_`), {
        uid: users.admin.uid, actionId: '', status: 'in_review',
      }),
    );
    await assertFails(
      setDoc(doc(owner, 'action_centre_user_status', `${users.admin.uid}_42`), {
        uid: users.admin.uid, actionId: 42, status: 'in_review',
      }),
    );
    await assertSucceeds(setDoc(doc(owner, 'action_centre_user_status', id), {
      uid: users.admin.uid, actionId: 'action-1', status: 'in_review',
    }));
    await assertFails(setDoc(doc(dbFor(users.salesman), 'action_centre_user_status', id), {
      uid: users.salesman.uid, actionId: 'action-1', status: 'ignored',
    }));
    await assertSucceeds(updateDoc(doc(owner, 'action_centre_user_status', id), {
      status: 'resolved',
    }));
  });

  it('lets an owner get a missing own-prefixed action status but nothing else', async () => {
    const salesmanDb = dbFor(users.salesman);
    const missingOwn = await assertSucceeds(
      getDoc(doc(
        salesmanDb,
        'action_centre_user_status',
        `${users.salesman.uid}_never-saved`,
      )),
    );
    assert.equal(missingOwn.exists(), false);
    await assertFails(
      getDoc(doc(
        salesmanDb,
        'action_centre_user_status',
        `${users.otherSalesman.uid}_never-saved`,
      )),
    );
    await assertFails(
      getDoc(doc(salesmanDb, 'action_centre_user_status', 'no-prefix-id')),
    );
    await assertFails(
      getDoc(doc(
        salesmanDb,
        'action_centre_user_status',
        `${users.salesman.uid}_`,
      )),
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          'action_centre_user_status',
          `${users.admin.uid}_action-1`,
        ),
        { uid: users.admin.uid, actionId: 'action-1', status: 'reviewed' },
      );
    });
    await assertFails(
      getDoc(doc(
        salesmanDb,
        'action_centre_user_status',
        `${users.admin.uid}_action-1`,
      )),
    );
    await assertSucceeds(
      getDoc(doc(
        dbFor(users.admin),
        'action_centre_user_status',
        `${users.admin.uid}_action-1`,
      )),
    );
    await assertFails(getDocs(collection(salesmanDb, 'action_centre_user_status')));
    await assertSucceeds(
      getDocs(query(
        collection(salesmanDb, 'action_centre_user_status'),
        where('uid', '==', users.salesman.uid),
      )),
    );
  });

  it('denies self-editing salesman identity aliases but allows contact updates', async () => {
    const reference = doc(dbFor(users.salesman), 'users', users.salesman.uid);
    for (const field of ['uid', 'userUid', 'employeeCode', 'staffId', 'salesmanCode']) {
      await assertFails(updateDoc(reference, { [field]: users.otherSalesman.uid }));
    }
    await assertSucceeds(updateDoc(reference, { contactNumber: '0123456789' }));
  });

  it('forces a linked salesman to update the canonical profile document', async () => {
    const uid = 'linked-salesman-uid';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', uid), {
        uid,
        role: 'salesman',
        status: 'active',
        employeeCode: 'S-LINKED-STALE',
      });
      await setDoc(doc(db, 'users', 'S-LINKED'), {
        uid,
        role: 'salesman',
        status: 'active',
        employeeCode: 'S-LINKED',
        branchId: 'B1',
      });
      await setDoc(doc(db, 'user_access', uid), {
        uid,
        userDocId: 'S-LINKED',
        role: 'salesman',
        user_group: 'salesman',
        status: 'active',
        employeeCode: 'S-LINKED',
        userId: 'S-LINKED',
        branchId: 'B1',
        branch_id: 'B1',
      });
    });

    const db = authContext(uid).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', uid), { contactNumber: 'wrong-document' }),
    );
    await assertSucceeds(
      updateDoc(doc(db, 'users', 'S-LINKED'), { contactNumber: 'canonical' }),
    );
  });

  it('blocks an admin from writing its legacy UID profile', async () => {
    const uid = 'linked-admin-uid';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', uid), {
        uid,
        role: 'admin',
        status: 'active',
      });
      await setDoc(doc(db, 'users', 'A-LINKED'), {
        uid,
        role: 'admin',
        status: 'active',
      });
      await setDoc(doc(db, 'user_access', uid), {
        uid,
        userDocId: 'A-LINKED',
        role: 'admin',
        user_group: 'admin',
        status: 'active',
      });
    });

    const db = authContext(uid).firestore();
    await assertFails(
      updateDoc(doc(db, 'users', uid), { contactNumber: 'wrong-document' }),
    );
    await assertSucceeds(
      updateDoc(doc(db, 'users', 'A-LINKED'), { contactNumber: 'canonical' }),
    );
  });
});

describe('salesman route ownership', () => {
  it('reads first-use progress as an empty owner-filtered query without widening access', async () => {
    const db = dbFor(users.salesman);
    const progressId = 'route-own_sales-1';
    const progressQuery = (owner, planId = 'route-own') => query(
      collection(db, 'route_plan_progress'),
      where('salesmanUid', '==', owner),
      where('planId', '==', planId),
      limit(2),
    );
    await assertFails(getDoc(doc(db, 'route_plan_progress', progressId)));
    const missing = await assertSucceeds(getDocs(progressQuery(users.salesman.uid)));
    if (!missing.empty) throw new Error('New route must have no progress yet');
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plan_progress', progressId), {
        progressId, planId: 'route-own', salesmanUid: users.salesman.uid,
        salesmanCode: 'S001', branchId: 'B1', status: 'accepted',
      });
    });
    const existing = await assertSucceeds(getDocs(progressQuery(users.salesman.uid)));
    if (existing.size !== 1 || existing.docs[0].id !== progressId) {
      throw new Error('Canonical own progress must remain readable');
    }
    await assertFails(getDocs(progressQuery(users.otherSalesman.uid, 'route-other')));
    await assertFails(getDocs(query(collection(db, 'route_plan_progress'), limit(1))));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.salesman.uid), { status: 'suspended' });
    });
    await assertFails(getDocs(progressQuery(users.salesman.uid)));
  });

  it('denies route access when a legacy isActive flag suspends an otherwise active profile', async () => {
    const db = dbFor(users.salesman);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.salesman.uid), {
        status: 'active',
        isActive: false,
      });
    });
    await assertFails(getDoc(doc(db, 'route_plans', 'route-own')));
  });

  it('denies legacy inactive aliases and encodings the profile readers recognise', async () => {
    const db = dbFor(users.salesman);
    const inactiveSignals = [
      { isActive: 0 },
      { isActive: 'FALSE' },
      { isActive: 'no' },
      { isActive: null, active: false },
      { is_active: false },
      { enabled: 'off' },
      { status: null, accountStatus: 'active', account_status: 'active' },
      { status: 7, accountStatus: 'active' },
      { status: '', accountStatus: 'active' },
      { status: 'suspended', accountStatus: 'active' },
      { status: deleteField(), accountStatus: null, account_status: 'active' },
      { status: deleteField(), accountStatus: 7, account_status: 'active' },
      { status: deleteField(), accountStatus: '', account_status: 'active' },
      { status: deleteField(), accountStatus: 'Suspended' },
      { status: deleteField(), account_status: 'suspended' },
      { status: deleteField(), accountStatus: 'suspended', account_status: 'active' },
    ];

    for (const signal of inactiveSignals) {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const ref = doc(context.firestore(), 'users', users.salesman.uid);
        await updateDoc(ref, {
          status: deleteField(),
          accountStatus: deleteField(),
          account_status: deleteField(),
          isActive: deleteField(),
          is_active: deleteField(),
          active: deleteField(),
          enabled: deleteField(),
        });
        await updateDoc(ref, { status: 'active', ...signal });
      });
      try {
        await assertFails(getDoc(doc(db, 'route_plans', 'route-own')));
      } catch (error) {
        throw new Error(
          `expected denial for ${JSON.stringify(signal)}: ${error.message}`,
        );
      }
    }
  });

  it('allows active legacy flag encodings and falls through a null primary alias', async () => {
    const db = dbFor(users.salesman);
    const activeSignals = [
      { isActive: 'TRUE' },
      { isActive: 'yes' },
      { isActive: 1 },
      { isActive: null, active: true },
      { status: 'active', accountStatus: 'suspended', account_status: 'suspended' },
      { status: 'Active', accountStatus: 'suspended' },
      { status: deleteField(), accountStatus: 'active', account_status: 'suspended' },
      { status: deleteField(), accountStatus: deleteField(), account_status: 'active' },
      { status: deleteField(), accountStatus: deleteField(), account_status: deleteField() },
    ];

    for (const signal of activeSignals) {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const ref = doc(context.firestore(), 'users', users.salesman.uid);
        await updateDoc(ref, {
          status: 'active',
          accountStatus: deleteField(),
          account_status: deleteField(),
          isActive: deleteField(),
          is_active: deleteField(),
          active: deleteField(),
          enabled: deleteField(),
        });
        await updateDoc(ref, signal);
      });
      await assertSucceeds(getDoc(doc(db, 'route_plans', 'route-own')));
    }
  });

  it('leaves reactivation of a legacy boolean suspension to the server', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.salesman.uid), {
        status: 'active',
        isActive: false,
      });
    });
    const salesmanDb = dbFor(users.salesman);
    await assertFails(getDoc(doc(salesmanDb, 'route_plans', 'route-own')));

    await assertFails(
      updateDoc(doc(dbFor(users.admin), 'users', users.salesman.uid), {
        status: 'active',
        isActive: true,
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(getDoc(doc(salesmanDb, 'route_plans', 'route-own')));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.salesman.uid), {
        status: 'active',
        isActive: true,
      });
    });
    await assertSucceeds(getDoc(doc(salesmanDb, 'route_plans', 'route-own')));
  });

  it('reads only its published route and never edits route plans', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(getDoc(doc(db, 'route_plans', 'route-own')));
    await assertFails(getDoc(doc(db, 'route_plans', 'route-draft')));
    await assertFails(getDoc(doc(db, 'route_plans', 'route-other')));
    await assertFails(
      updateDoc(doc(db, 'route_plans', 'route-own'), { status: 'archived' }),
    );
  });

  it('creates and advances only its canonical progress document', async () => {
    const db = dbFor(users.salesman);
    const progress = {
      progressId: 'route-own_sales-1',
      planId: 'route-own',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      isOfflineCreated: false,
      status: 'accepted',
      stopProgress: {},
      handledStopIds: [],
      acceptedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    };
    await assertSucceeds(
      setDoc(doc(db, 'route_plan_progress', progress.progressId), progress),
    );
    await assertSucceeds(
      updateDoc(doc(db, 'route_plan_progress', progress.progressId), {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(doc(db, 'route_plan_progress', 'wrong-id'), progress),
    );
    await assertFails(
      setDoc(doc(db, 'route_plan_progress', 'route-other_sales-1'), {
        ...progress,
        progressId: 'route-other_sales-1',
        planId: 'route-other',
        branchId: 'B2',
      }),
    );
  });

  it('[route-heartbeat] accepts the phone route session state and heartbeat writes', async () => {
    const db = dbFor(users.salesman);
    const ref = doc(db, 'route_plan_progress', 'route-own_sales-1');
    const base = {
      progressId: 'route-own_sales-1',
      planId: 'route-own',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      isOfflineCreated: false,
    };
    const merge = { merge: true };
    await assertSucceeds(setDoc(ref, {
      ...base,
      status: 'accepted',
      stopProgress: {},
      handledStopIds: [],
      acceptedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }, merge));
    await assertFails(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    await assertSucceeds(setDoc(ref, {
      ...base,
      status: 'in_progress',
      routeSessionState: 'active',
      startedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }, merge));
    await assertSucceeds(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    const started = (await getDoc(ref)).data();
    assert.equal(started.routeSessionState, 'active');
    assert.equal(started.lastHeartbeatAt instanceof Timestamp, true);
    await assertFails(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plan_progress', 'route-own_sales-1'), {
        lastHeartbeatAt: Timestamp.fromMillis(Date.now() - 3 * 60 * 1000),
      });
    });
    await assertFails(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plan_progress', 'route-own_sales-1'), {
        lastHeartbeatAt: Timestamp.fromMillis(Date.now() - 5 * 60 * 1000),
      });
    });
    await assertSucceeds(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    await assertFails(updateDoc(ref, {
      lastHeartbeatAt: serverTimestamp(),
      status: 'completed',
    }));

    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminRef = doc(context.firestore(), 'route_plan_progress', 'route-own_sales-1');
      const { routeSessionState, lastHeartbeatAt, ...apk102 } = (await getDoc(adminRef)).data();
      await setDoc(adminRef, apk102);
    });
    await assertFails(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    await assertSucceeds(setDoc(ref, {
      ...base,
      status: 'in_progress',
      routeSessionState: 'active',
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    }, merge));
    await assertSucceeds(updateDoc(ref, { lastHeartbeatAt: serverTimestamp() }));
    assert.equal((await getDoc(ref)).data().routeSessionState, 'active');
  });

  it('rejects valid-looking arrival evidence in legacy nested stopProgress', async () => {
    const db = dbFor(users.salesman);
    const progressId = 'route-own_sales-1';
    const ref = doc(db, 'route_plan_progress', progressId);
    const progress = {
      progressId,
      planId: 'route-own',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      isOfflineCreated: false,
      status: 'accepted',
      stopProgress: {},
      handledStopIds: [],
      acceptedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    };
    await assertSucceeds(setDoc(ref, progress));
    await assertSucceeds(
      updateDoc(ref, {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: {
          'stop-1': {
            stopId: 'stop-1',
            retailerId: 'retailer-1',
            retailerName: 'Retailer 1',
            status: 'arrived',
            arrivedAt: serverTimestamp(),
          },
        },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { 'stop-1': verifiedArrival('stop-1', 900000) },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { 'stop-1': verifiedArrival() },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  });

  it('rejects a legacy nested arrival on an accepted progress record', async () => {
    const db = dbFor(users.salesman);
    const progressId = 'route-own_sales-1';
    const ref = doc(db, 'route_plan_progress', progressId);
    await assertSucceeds(
      setDoc(ref, {
        progressId,
        planId: 'route-own',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        isOfflineCreated: false,
        status: 'accepted',
        handledStopIds: [],
        acceptedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      updateDoc(ref, {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { 'stop-1': verifiedArrival() },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  });

  it('rejects a manual arrival written to legacy nested stopProgress', async () => {
    const db = dbFor(users.salesman);
    const progressId = 'route-own_sales-1';
    const ref = doc(db, 'route_plan_progress', progressId);
    await assertSucceeds(
      setDoc(ref, {
        progressId,
        planId: 'route-own',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
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
      updateDoc(ref, {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { 'stop-1': manualArrival('stop-1', 'disabled_by_user') },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  });

  it('rejects legacy nested stop writes and premature route completion', async () => {
    const db = dbFor(users.salesman);
    const progressId = 'route-own_sales-1';
    const ref = doc(db, 'route_plan_progress', progressId);
    await assertSucceeds(
      setDoc(ref, {
        progressId,
        planId: 'route-own',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
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
      updateDoc(ref, {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        status: 'completed',
        completedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { invented: manualArrival('invented') },
        lastStopId: 'invented',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(ref, {
        stopProgress: { 'stop-1': manualArrival() },
        lastStopId: 'stop-1',
        lastStopStatus: 'arrived',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(ref, {
        stopProgress: {
          'stop-1': {
            stopId: 'stop-1',
            retailerId: 'retailer-1',
            retailerName: 'Retailer 1',
            status: 'completed',
            completedAt: serverTimestamp(),
          },
        },
        handledStopIds: ['stop-1'],
        lastStopId: 'stop-1',
        lastStopStatus: 'completed',
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }, { merge: true }),
    );
    await assertFails(
      updateDoc(ref, {
        status: 'completed',
        completedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  });
});

describe('planner scoping by role', () => {
  const PLAN_S001 = 'planner-scope-s001';
  const PLAN_S002 = 'planner-scope-s002';
  const PLAN_B2 = 'planner-scope-b2';

  function visit(ownerUid) {
    return {
      ownerUid,
      salesmanUid: ownerUid,
      retailerId: 'retailer-1',
      retailerName: 'Retailer 1',
      plannedDate: Timestamp.fromDate(new Date('2026-06-22T00:00:00Z')),
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
  }

  function publishedPlanFor(salesmanUid, salesmanCode, branchId) {
    return {
      planId: 'planner-scope',
      createdByUid: users.admin.uid,
      salesmanUid,
      salesmanCode,
      branchId,
      weekStart: Timestamp.fromDate(new Date('2026-06-22T00:00:00Z')),
      status: 'published',
      stopIds: ['stop-1'],
      stopRetailerIds: { 'stop-1': 'retailer-1' },
      totalStops: 1,
    };
  }

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const seedDb = context.firestore();
      await setDoc(doc(seedDb, 'visits', 'sales-1_own-visit'), visit(users.salesman.uid));
      await setDoc(doc(seedDb, 'visits', 'sales-2_other-visit'), visit(users.otherSalesman.uid));
      await setDoc(
        doc(seedDb, 'route_plans', PLAN_S001),
        publishedPlanFor(users.salesman.uid, 'S001', 'B1'),
      );
      await setDoc(
        doc(seedDb, 'route_plans', PLAN_S002),
        publishedPlanFor(users.otherSalesman.uid, 'S002', 'B1'),
      );
      await setDoc(
        doc(seedDb, 'route_plans', PLAN_B2),
        publishedPlanFor('salesman-b2', 'S900', 'B2'),
      );
    });
  });

  it('a salesman sees only its own planner and never a peer', async () => {
    const salesmanDb = dbFor(users.salesman);
    const otherDb = dbFor(users.otherSalesman);

    await assertSucceeds(getDoc(doc(salesmanDb, 'visits', 'sales-1_own-visit')));
    await assertFails(getDoc(doc(salesmanDb, 'visits', 'sales-2_other-visit')));
    await assertFails(getDocs(collection(salesmanDb, 'visits')));
    await assertSucceeds(
      getDocs(
        query(
          collection(salesmanDb, 'visits'),
          where('ownerUid', '==', users.salesman.uid),
        ),
      ),
    );
    await assertFails(getDoc(doc(otherDb, 'visits', 'sales-1_own-visit')));

    await assertSucceeds(getDoc(doc(salesmanDb, 'route_plans', PLAN_S001)));
    await assertFails(getDoc(doc(salesmanDb, 'route_plans', PLAN_S002)));
    await assertFails(getDoc(doc(otherDb, 'route_plans', PLAN_S001)));
  });

  it('a supervisor sees only plans for its assigned salesman codes', async () => {
    const supervisorDb = dbFor(users.supervisor);

    await assertSucceeds(getDoc(doc(supervisorDb, 'route_plans', PLAN_S001)));
    await assertFails(getDoc(doc(supervisorDb, 'route_plans', PLAN_S002)));
    await assertFails(getDoc(doc(supervisorDb, 'route_plans', PLAN_B2)));
    await assertFails(getDoc(doc(supervisorDb, 'visits', 'sales-1_own-visit')));
  });

  it('a branch manager sees only its own branch plans', async () => {
    const managerDb = dbFor(users.branchManager);

    await assertSucceeds(getDoc(doc(managerDb, 'route_plans', PLAN_S001)));
    await assertSucceeds(getDoc(doc(managerDb, 'route_plans', PLAN_S002)));
    await assertFails(getDoc(doc(managerDb, 'route_plans', PLAN_B2)));
    await assertFails(getDoc(doc(managerDb, 'visits', 'sales-1_own-visit')));
  });

  it('an admin may read any plan and any planner visit', async () => {
    const adminDb = dbFor(users.admin);

    await assertSucceeds(getDoc(doc(adminDb, 'route_plans', PLAN_S001)));
    await assertSucceeds(getDoc(doc(adminDb, 'route_plans', PLAN_B2)));
    await assertSucceeds(getDoc(doc(adminDb, 'visits', 'sales-1_own-visit')));
  });

  it('a suspended dashboard role sees no plan at all', async () => {
    const suspendedSupervisorDb = dbFor(users.suspendedSupervisor);
    const suspendedManagerDb = dbFor(users.suspendedBranchManager);

    await assertFails(getDoc(doc(suspendedSupervisorDb, 'route_plans', PLAN_S001)));
    await assertFails(getDoc(doc(suspendedManagerDb, 'route_plans', PLAN_S001)));
  });
});

describe('route publication commit', () => {
  const PLAN_ID = 'publish-commit-plan';
  const KEY_ID = users.salesman.uid + '_20260921';
  const STOP_IDS = [
    'stop-1',
    'stop-2',
    'stop-3',
  ];

  function plan(status) {
    return {
      planId: PLAN_ID,
      createdByUid: users.admin.uid,
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      weekStart: Timestamp.fromDate(new Date('2026-09-21T00:00:00Z')),
      status,
      stopIds: STOP_IDS,
      stopRetailerIds: {
        'stop-1': 'retailer-1',
        'stop-2': 'retailer-2',
        'stop-3': 'retailer-3',
      },
      totalStops: STOP_IDS.length,
    };
  }

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', 'qa.admin@example.test'), {
        uid: users.admin.uid,
        userUid: users.admin.uid,
        name: 'QA Admin',
        email: 'qa.admin@example.test',
        role: 'admin',
        user_group: 'admin',
        status: 'active',
        employeeCode: 'ADM-QA',
        userId: 'ADM-QA',
        branchId: 'B1',
        branch_id: 'B1',
        contactNumber: '0123456789',
      });
      await setDoc(doc(db, 'user_access', users.admin.uid), {
        uid: users.admin.uid,
        userDocId: 'qa.admin@example.test',
        employeeCode: 'ADM-QA',
        userId: 'ADM-QA',
        email: 'qa.admin@example.test',
        role: 'admin',
        user_group: 'admin',
        status: 'active',
        branchId: 'B1',
        branch_id: 'B1',
      });
      await setDoc(
        doc(db, 'route_plans', PLAN_ID),
        plan('approved'),
      );
    });
  });

  it('publishes the plan and creates its key in one transaction', async () => {
    const db = dbFor(users.admin);
    await assertSucceeds(
      runTransaction(db, async (transaction) => {
        const planSnapshot = await transaction.get(doc(db, 'route_plans', PLAN_ID));
        if (!planSnapshot.exists()) throw new Error('plan missing');
        await transaction.get(
          doc(db, 'route_plan_publication_keys', KEY_ID),
        );
        transaction.update(doc(db, 'route_plans', PLAN_ID), {
          status: 'published',
          publicationKeyId: KEY_ID,
          updatedAt: serverTimestamp(),
          publishedAt: serverTimestamp(),
        });
        transaction.set(doc(db, 'route_plan_publication_keys', KEY_ID), {
          keyId: KEY_ID,
          planId: PLAN_ID,
          salesmanIdentity: users.salesman.uid,
          salesmanUid: users.salesman.uid,
          salesmanCode: 'S001',
          weekKey: '20260921',
          active: true,
          updatedByUid: users.admin.uid,
        });
      }),
    );
  });

  it('refuses a publish without its key or with a key not derived from the plan', async () => {
    const db = dbFor(users.admin);
    await assertFails(updateDoc(doc(db, 'route_plans', PLAN_ID), {
      status: 'published',
      updatedAt: serverTimestamp(),
    }));
    const forgedKey = users.salesman.uid + '_19990101';
    const batch = writeBatch(db);
    batch.update(doc(db, 'route_plans', PLAN_ID), {
      status: 'published',
      publicationKeyId: forgedKey,
      updatedAt: serverTimestamp(),
    });
    batch.set(doc(db, 'route_plan_publication_keys', forgedKey), {
      keyId: forgedKey,
      planId: PLAN_ID,
      salesmanIdentity: users.salesman.uid,
      weekKey: '19990101',
      active: true,
      updatedByUid: users.admin.uid,
    });
    await assertFails(batch.commit());
  });

  it('refuses publishing a second plan for a week whose key belongs to another plan', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'route_plan_publication_keys', KEY_ID),
        {
          keyId: KEY_ID,
          planId: 'some-other-plan',
          salesmanIdentity: users.salesman.uid,
          weekKey: '20260921',
          active: true,
          updatedByUid: users.admin.uid,
        },
      );
    });
    const db = dbFor(users.admin);
    await assertFails(updateDoc(doc(db, 'route_plans', PLAN_ID), {
      status: 'published',
      publicationKeyId: KEY_ID,
      updatedAt: serverTimestamp(),
    }));
  });

  it('the same commit is refused for a salesman', async () => {
    const db = dbFor(users.salesman);
    const batch = writeBatch(db);
    batch.update(doc(db, 'route_plans', PLAN_ID), {
      status: 'published',
      updatedAt: serverTimestamp(),
    });
    batch.set(doc(db, 'route_plan_publication_keys', KEY_ID), {
      keyId: KEY_ID,
      planId: PLAN_ID,
      salesmanIdentity: 'S001',
      weekKey: '20260921',
      active: true,
      updatedByUid: users.salesman.uid,
    });

    await assertFails(batch.commit());
  });
});

describe('publication key reads', () => {
  const PLAN_ID = 'publication-key-plan';
  const MISSING_KEY = 'publication-key-salesman_20260921';
  const EXISTING_KEY = 'publication-key-salesman_20260928';

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'route_plans', PLAN_ID), {
        planId: PLAN_ID,
        createdByUid: users.admin.uid,
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        weekStart: Timestamp.fromDate(new Date('2026-09-21T00:00:00Z')),
        status: 'published',
        stopIds: ['stop-1'],
        stopRetailerIds: { 'stop-1': 'retailer-1' },
        totalStops: 1,
      });
      await setDoc(doc(db, 'route_plan_publication_keys', EXISTING_KEY), {
        keyId: EXISTING_KEY,
        planId: PLAN_ID,
        salesmanIdentity: 'S001',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        weekKey: '20260928',
        active: true,
        updatedByUid: users.admin.uid,
      });
    });
  });

  it('an admin can read the key for a week that has never been published', async () => {
    const db = dbFor(users.admin);
    await assertSucceeds(
      getDoc(doc(db, 'route_plan_publication_keys', MISSING_KEY)),
    );
  });

  it('an admin can read an existing key for a plan they manage', async () => {
    const db = dbFor(users.admin);
    await assertSucceeds(
      getDoc(doc(db, 'route_plan_publication_keys', EXISTING_KEY)),
    );
  });

  it('a salesman cannot read publication keys', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      getDoc(doc(db, 'route_plan_publication_keys', MISSING_KEY)),
    );
    await assertFails(
      getDoc(doc(db, 'route_plan_publication_keys', EXISTING_KEY)),
    );
  });
});

describe('user directory reads', () => {
  const ADMIN_UID = 'directory-admin-uid';
  const ADMIN_DOC = 'directory.admin@example.test';
  const PEER_DOC = 'directory.sales@example.test';
  const PEER_UID = 'directory-sales-uid';

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', ADMIN_DOC), {
        uid: ADMIN_UID,
        userUid: ADMIN_UID,
        email: ADMIN_DOC,
        name: 'Directory Admin',
        role: 'admin',
        user_group: 'admin',
        status: 'active',
        employeeCode: 'ADM-DIR',
        userId: 'ADM-DIR',
        branchId: 'B1',
        branch_id: 'B1',
      });
      await setDoc(doc(db, 'users', PEER_DOC), {
        uid: PEER_UID,
        email: PEER_DOC,
        name: 'Directory Salesman',
        role: 'salesman',
        status: 'active',
        employeeCode: 'S-DIR',
        branchId: 'B1',
      });
      await setDoc(doc(db, 'user_access', ADMIN_UID), {
        uid: ADMIN_UID,
        userDocId: ADMIN_DOC,
        email: ADMIN_DOC,
        role: 'admin',
        user_group: 'admin',
        status: 'active',
        employeeCode: 'ADM-DIR',
        userId: 'ADM-DIR',
        branchId: 'B1',
        branch_id: 'B1',
      });
    });
  });

  it('an active admin can read its own canonical profile', async () => {
    const db = authContext(ADMIN_UID).firestore();
    await assertSucceeds(getDoc(doc(db, 'users', ADMIN_DOC)));
  });

  it('an active admin can list the user directory', async () => {
    const db = authContext(ADMIN_UID).firestore();
    await assertSucceeds(getDocs(collection(db, 'users')));
  });

  it('a salesman cannot list the user directory', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'user_access', PEER_UID),
        {
          uid: PEER_UID,
          userDocId: PEER_DOC,
          email: PEER_DOC,
          role: 'salesman',
          status: 'active',
          employeeCode: 'S-DIR',
        },
      );
    });
    const db = authContext(PEER_UID).firestore();
    await assertFails(getDocs(collection(db, 'users')));
  });
});

async function linkSalesman() {
  await testEnv.withSecurityRulesDisabled(async (context) => {
    const db = context.firestore();
    const profile = users.salesman.profile;
    await deleteDoc(doc(db, 'users', users.salesman.uid));
    await setDoc(doc(db, 'users', 'legacy-sales-doc'), {
      ...profile,
      role: 'sales representative',
      uid: users.salesman.uid,
    });
    await setDoc(doc(db, 'user_access', users.salesman.uid), {
      ...profile,
      role: 'sales representative',
      uid: users.salesman.uid,
      user_group: 'sales representative',
      userDocId: 'legacy-sales-doc',
    });
  });
}

describe('salesman AI and outcome ownership', () => {
  it('cannot write generated AI collections', async () => {
    const db = dbFor(users.salesman);
    for (const collection of [
      'ai_insights',
      'retailer_item_patterns',
      'retailer_segments',
      'retailer_memory',
      'visit_briefs',
      'weekly_ai_summaries',
      'ai_runs',
      'dashboard_notifications',
    ]) {
      await assertFails(
        setDoc(doc(db, collection, 'forbidden-write'), { value: true }),
      );
    }
  });

  function validOutcome(overrides = {}) {
    return {
      outcomeId: 'outcome-1',
      issueId: 'issue-1',
      issueKey: 'low_sell_through::retailer-1::product-1',
      issueType: 'low_sell_through',
      retailerId: 'retailer-1',
      retailerName: 'Retailer One',
      productId: 'product-1',
      productName: 'Product One',
      reasonCode: 'low_sell_through',
      note: '',
      replacementProductId: '',
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      planId: 'route-own',
      stopId: 'stop-1',
      sourceBriefId: 'brief-1',
      source: 'mobile_assigned_route_copilot',
      isDemo: false,
      clientCreatedAt: Timestamp.now(),
      submittedAt: serverTimestamp(),
      ...overrides,
    };
  }

  it('creates only an outcome owned by the authenticated salesman and retries it', async () => {
    const db = dbFor(users.salesman);
    const outcome = validOutcome();
    await assertSucceeds(
      setDoc(doc(db, 'conversation_outcomes', outcome.outcomeId), outcome),
    );
    await assertSucceeds(
      setDoc(doc(db, 'conversation_outcomes', outcome.outcomeId), outcome),
    );
    await assertFails(
      setDoc(doc(db, 'conversation_outcomes', 'outcome-forged'), {
        ...outcome,
        outcomeId: 'outcome-forged',
        salesmanUid: users.otherSalesman.uid,
      }),
    );
  });

  it('[copilot-outcome-budget] creates an outcome for a linked caller within the expression budget', async () => {
    await linkSalesman();
    const outcome = validOutcome();
    await assertSucceeds(
      setDoc(
        doc(dbFor(users.salesman), 'conversation_outcomes', outcome.outcomeId),
        outcome,
      ),
    );
  });

  it('lets only the owning salesman change reminder fields', async () => {
    const ownerDb = dbFor(users.salesman);
    const outcome = validOutcome();
    const outcomeRef = doc(
      ownerDb,
      'conversation_outcomes',
      outcome.outcomeId,
    );
    await assertSucceeds(setDoc(outcomeRef, outcome, { merge: true }));

    const reminder = {
      followUpDate: '2026-10-02',
      followUpTime: '14:30',
      followUpStatus: 'open',
    };
    await assertSucceeds(updateDoc(outcomeRef, reminder));
    await assertSucceeds(setDoc(outcomeRef, outcome, { merge: true }));
    const retriedOutcome = await getDoc(outcomeRef);
    assert.equal(retriedOutcome.data().followUpDate, reminder.followUpDate);
    await assertSucceeds(updateDoc(outcomeRef, reminder));
    await assertSucceeds(updateDoc(outcomeRef, { followUpDate: '2026-10-03' }));
    await assertSucceeds(updateDoc(outcomeRef, { followUpDate: '2028-02-29' }));
    await assertSucceeds(updateDoc(outcomeRef, { followUpStatus: 'completed' }));
    await assertSucceeds(updateDoc(outcomeRef, { followUpStatus: 'cancelled' }));

    await assertFails(
      updateDoc(doc(dbFor(users.otherSalesman), 'conversation_outcomes', outcome.outcomeId), {
        followUpDate: '2026-10-04',
      }),
    );
    await assertFails(
      updateDoc(doc(dbFor(users.supervisor), 'conversation_outcomes', outcome.outcomeId), {
        followUpStatus: 'completed',
      }),
    );
    await assertFails(
      updateDoc(outcomeRef, { reasonCode: 'out_of_stock' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpStatus: 'open', unexpected: true }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpDate: 'not-a-date' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpDate: '2026-02-30' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpDate: '2027-02-29' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpDate: '0000-12-01' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpTime: '25:77' }),
    );
    await assertFails(
      updateDoc(outcomeRef, { followUpStatus: 'unknown' }),
    );
  });

  it('denies nonexistent route, stop, brief, retailer, product and issue references', async () => {
    const db = dbFor(users.salesman);
    for (const [label, overrides] of [
      ['route', { planId: 'missing-plan' }],
      ['stop', { stopId: 'missing-stop' }],
      ['brief', { sourceBriefId: 'missing-brief' }],
      ['retailer', { retailerId: 'missing-retailer', retailerName: 'Missing Retailer', issueKey: 'low_sell_through::missing-retailer::product-1' }],
      ['product', { productId: 'missing-product', productName: 'Missing Product', issueKey: 'low_sell_through::retailer-1::missing-product' }],
      ['issue', { issueId: 'missing-issue' }],
    ]) {
      await assertFails(
        setDoc(
          doc(db, 'conversation_outcomes', `missing-${label}`),
          validOutcome({ ...overrides, outcomeId: `missing-${label}` }),
        ),
      );
    }
  });

  it('denies cross-scope and mismatched provenance', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'cross-scope-route'),
        validOutcome({
          outcomeId: 'cross-scope-route',
          planId: 'route-other',
          stopId: 'other-stop-1',
          branchId: 'B2',
          salesmanCode: 'S002',
          retailerId: 'retailer-other',
          retailerName: 'Other Retailer',
          productId: 'product-other',
          productName: 'Other Product',
          issueId: 'issue-other',
          issueKey: 'low_sell_through::retailer-other::product-other',
        }),
      ),
    );
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'mismatched-brief'),
        validOutcome({
          outcomeId: 'mismatched-brief',
          retailerId: 'retailer-other',
          retailerName: 'Other Retailer',
          productId: 'product-other',
          productName: 'Other Product',
          issueId: 'issue-other',
          issueKey: 'low_sell_through::retailer-other::product-other',
        }),
      ),
    );
  });

  it('denies non-canonical issue keys even when all records exist', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'noncanonical-key'),
        validOutcome({
          outcomeId: 'noncanonical-key',
          issueKey: 'low_sell_through|retailer-1|product-1',
        }),
      ),
    );
  });

  it('binds the claimed stop to the retailer in the route index', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', 'route-multi'), {
        planId: 'route-multi',
        status: 'published',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' },
        totalStops: 2,
      });
    });
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'wrong-stop-retailer'),
        validOutcome({
          outcomeId: 'wrong-stop-retailer',
          planId: 'route-multi',
          stopId: 'stop-2',
        }),
      ),
    );
  });

  it('keeps the outcome demo flag bound to the source brief', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'demo-mismatch'),
        validOutcome({ outcomeId: 'demo-mismatch', isDemo: true }),
      ),
    );
  });

  it('requires a real replacement product for switched outcomes', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(
        doc(db, 'conversation_outcomes', 'missing-replacement'),
        validOutcome({
          outcomeId: 'missing-replacement',
          reasonCode: 'switched_to_alternative',
          replacementProductId: 'missing-product',
        }),
      ),
    );
  });
});

describe('catalogue and score-sheet import boundary', () => {
  it('allows only an admin to write imported catalogue structure', async () => {
    const adminDb = dbFor(users.admin);
    const salesmanDb = dbFor(users.salesman);
    const writes = [
      ['products', 'beverage_juice_oj_01', { productId: 'beverage_juice_oj_01', isVisible: false, status: 'hidden' }],
      ['departments', 'beverage', { departmentId: 'beverage' }],
      ['categories', 'beverage_juice', { categoryId: 'beverage_juice' }],
      ['score_sheets', 'default', { scoreSheetId: 'default', productIds: [] }],
    ];

    for (const [collectionName, documentId, data] of writes) {
      await assertFails(
        setDoc(doc(salesmanDb, collectionName, documentId), data),
      );
      await assertSucceeds(
        setDoc(doc(adminDb, collectionName, documentId), data),
      );
      await assertSucceeds(
        getDoc(doc(salesmanDb, collectionName, documentId)),
      );
    }
  });

  it('keeps score-sheet template revisions and assignment events admin-created and immutable', async () => {
    const adminDb = dbFor(users.admin);
    const salesmanDb = dbFor(users.salesman);
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    const template = { kind: 'template', templateId: 'tpl_a', revision: 1, name: 'A', productIds: ['p1'] };
    const event = {
      kind: 'assignment', assignmentId: 'asg_a', assignmentRevision: 1, templateId: 'tpl_a',
      templateName: 'A', salesmanUid: users.salesman.uid, retailerId: 'r1',
    };

    for (const db of [salesmanDb, supervisorDb, managerDb]) {
      await assertFails(setDoc(doc(db, 'score_sheets', 'tpl_a_r1'), template));
      await assertFails(setDoc(doc(db, 'score_sheets', 'asg_a_r1'), event));
    }
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'tpl_a_r1'), template));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'asg_a_r1'), event));
    await assertSucceeds(getDoc(doc(salesmanDb, 'score_sheets', 'asg_a_r1')));
    await assertFails(updateDoc(doc(salesmanDb, 'score_sheets', 'tpl_a_r1'), { productIds: [] }));
    await assertFails(updateDoc(doc(adminDb, 'score_sheets', 'tpl_a_r1'), { productIds: ['p2'] }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_a_r1'), { ...template, name: 'renamed' }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_a_r1'), { name: 'not a template' }));
    await assertFails(deleteDoc(doc(adminDb, 'score_sheets', 'tpl_a_r1')));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'tpl_a_r2'), { ...template, revision: 2, productIds: ['p1', 'p2'] }));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'default'), { scoreSheetId: 'default', productIds: [] }));
    await assertSucceeds(updateDoc(doc(adminDb, 'score_sheets', 'default'), { productIds: ['p1'] }));
    await assertFails(updateDoc(doc(adminDb, 'score_sheets', 'default'), { kind: 'template' }));

    await assertFails(updateDoc(doc(adminDb, 'score_sheets', 'asg_a_r1'), { salesmanUid: users.otherSalesman.uid }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'asg_a_r1'), { ...event, salesmanUid: users.otherSalesman.uid }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'asg_a_r1'), { name: 'not an assignment' }));
    await assertFails(deleteDoc(doc(adminDb, 'score_sheets', 'asg_a_r1')));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'default'), { ...event, assignmentId: 'asg_forged' }));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'asg_a_r2'), {
      ...event, assignmentRevision: 2, salesmanUid: users.otherSalesman.uid, previousSalesmanUid: users.salesman.uid,
    }));
  });

  function canonicalProduct(overrides = {}) {
    return {
      productId: 'beverage_juice_oj_01',
      departmentId: 'beverage',
      categoryId: 'beverage_juice',
      departmentName: 'Beverage',
      departmentManagerName: 'Catalogue Team',
      mainCategoryName: 'Juice',
      categoryName: 'Juice',
      itemName: 'Orange Juice (12 x 1L)',
      productName: 'Orange Juice (12 x 1L)',
      productFlavor: 'Orange Juice',
      flavor: 'Orange Juice',
      itemCode: 'OJ-01',
      productCode: 'OJ-01',
      sku: 'OJ-01',
      barcode: '9551000000015',
      itemBarcode: '9551000000015',
      packingSize: '12 x 1L',
      unitPrice: 12.5,
      price: 12.5,
      priceGuide: 12.5,
      uom: 'ctn',
      uomLabel: 'ctn',
      unitOfMeasure: 'ctn',
      sortOrder: 1,
      isVisible: false,
      status: 'hidden',
      ...overrides,
    };
  }

  it('accepts a canonical bounded product write from an admin', async () => {
    const db = dbFor(users.admin);
    await assertSucceeds(
      setDoc(doc(db, 'products', 'canonical-product'), canonicalProduct()),
    );
  });

  it('accepts an int maxOrderQty of 1..999 and rejects other types or values', async () => {
    const db = dbFor(users.admin);
    for (const value of [1, 10, 999]) {
      const id = `max-qty-${value}`;
      await assertSucceeds(
        setDoc(doc(db, 'products', id), canonicalProduct({ maxOrderQty: value })),
      );
      await assertSucceeds(updateDoc(doc(db, 'products', id), { maxOrderQty: 7 }));
      await assertSucceeds(updateDoc(doc(db, 'products', id), { maxOrderQty: deleteField() }));
    }
    for (const [label, value] of [
      ['zero', 0], ['negative', -1], ['over ceiling', 1000], ['fraction', 5.5],
      ['text', '10'], ['null', null], ['bool', true],
    ]) {
      await assertFails(
        setDoc(doc(db, 'products', `max-qty-bad-${label.replace(' ', '-')}`),
          canonicalProduct({ maxOrderQty: value })),
      );
      await assertFails(updateDoc(doc(db, 'products', 'max-qty-10'), { maxOrderQty: value }));
    }
    await assertFails(
      setDoc(doc(db, 'products', 'max-qty-snake'), canonicalProduct({ max_order_qty: 10 })),
    );
  });

  it('accepts a bounded product write for an admin with a legacy status alias', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.admin.uid), {
        status: deleteField(),
        accountStatus: 'active',
      });
    });
    await assertSucceeds(
      setDoc(
        doc(dbFor(users.admin), 'products', 'legacy-status-product'),
        canonicalProduct(),
      ),
    );
  });

  it('accepts a bounded product write when an admin status is absent', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.admin.uid), {
        status: deleteField(),
        accountStatus: deleteField(),
        account_status: deleteField(),
        isActive: true,
      });
    });
    await assertSucceeds(
      setDoc(
        doc(dbFor(users.admin), 'products', 'status-less-admin-product'),
        canonicalProduct(),
      ),
    );
  });

  it('rejects admin product writes that exceed text or ID bounds', async () => {
    const db = dbFor(users.admin);
    for (const [label, overrides] of [
      ['product-id', { productId: 'p'.repeat(101) }],
      ['document-id-alias', { docId: 'd'.repeat(101) }],
      ['category-id', { categoryId: 'c'.repeat(201) }],
      ['group-name', { departmentName: 'd'.repeat(101) }],
      ['department-alias', { department: 'd'.repeat(101) }],
      ['category-alias', { category: 'c'.repeat(101) }],
      ['product-name', { productName: 'n'.repeat(201) }],
      ['supporting-text', { barcode: 'b'.repeat(101) }],
      ['uom', { uom: 'u'.repeat(33) }],
      ['wrong-text-type', { itemCode: 42 }],
    ]) {
      await assertFails(
        setDoc(doc(db, 'products', `invalid-${label}`), canonicalProduct(overrides)),
      );
    }
  });

  it('rejects a new product whose document ID exceeds the product ID bound', async () => {
    const db = dbFor(users.admin);
    await assertFails(
      setDoc(
        doc(db, 'products', 'p'.repeat(101)),
        canonicalProduct(),
      ),
    );
  });

  it('rejects admin product writes with invalid sort orders or prices', async () => {
    const db = dbFor(users.admin);
    for (const [label, overrides] of [
      ['negative-sort', { sortOrder: -1 }],
      ['decimal-sort', { sortOrder: 1.5 }],
      ['large-sort', { sortOrder: 1000001 }],
      ['negative-price', { unitPrice: -0.01 }],
      ['large-price', { price: 1000000.01 }],
      ['non-number-price', { priceGuide: '12.50' }],
      ['nan-price', { unitPrice: NaN }],
      ['infinite-price', { price: Infinity }],
    ]) {
      await assertFails(
        setDoc(doc(db, 'products', `invalid-${label}`), canonicalProduct(overrides)),
      );
    }
  });

  it('rejects every reader alias when created or changed outside its bound', async () => {
    const db = dbFor(users.admin);
    const invalidAliases = [
      ['item-id', { itemId: 'i'.repeat(101) }],
      ['display-name', { displayName: 'd'.repeat(201) }],
      ['product-name-snake', { product_name: 'n'.repeat(201) }],
      ['name', { name: 'n'.repeat(201) }],
      ['packaging-size', { packagingSize: 'p'.repeat(101) }],
      ['product-barcode', { productBarcode: 'b'.repeat(101) }],
      ['sub-category', { subCategory: 's'.repeat(101) }],
      ['position', { position: -1 }],
      ['unit-price-snake', { unit_price: -0.01 }],
      ['selling-price', { sellingPrice: 1000000.01 }],
      ['selling-price-snake', { selling_price: NaN }],
    ];

    for (const [label, overrides] of invalidAliases) {
      await assertFails(
        setDoc(doc(db, 'products', `alias-create-${label}`), canonicalProduct(overrides)),
      );

      const existing = doc(db, 'products', `alias-update-${label}`);
      await assertSucceeds(setDoc(existing, canonicalProduct()));
      await assertFails(updateDoc(existing, overrides));
    }
  });

  it('allows unrelated updates to a legacy product with an untouched overlong field', async () => {
    const db = dbFor(users.admin);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'products', 'legacy-product'), {
        productId: 'legacy-product',
        productName: 'n'.repeat(201),
        status: 'active',
      });
    });
    await assertSucceeds(
      updateDoc(doc(db, 'products', 'legacy-product'), { unitPrice: 3, priceUpdatedAt: serverTimestamp() }),
    );
    await assertFails(
      updateDoc(doc(db, 'products', 'legacy-product'), { status: 'hidden' }),
    );
  });

  it('keeps text bounds exact at the edges of the fast path', async () => {
    const db = dbFor(users.admin);
    const emoji = '\u{1F600}';
    for (const [label, overrides, allowed] of [
      ['exact-limit', { productId: 'p'.repeat(100) }, true],
      ['multi-line-limit', { productId: `${'p'.repeat(49)}\n${'p'.repeat(50)}` }, true],
      ['astral-at-limit', { productId: emoji.repeat(50) }, true],
      ['astral-over-limit', { productId: emoji.repeat(51) }, false],
      ['astral-one-over', { productId: `${emoji.repeat(49)}pp${'p'}` }, false],
      ['list-value', { productId: ['p'] }, false],
      ['map-value', { itemName: { a: 'b' } }, false],
      ['null-value', { sku: null }, false],
    ]) {
      const write = setDoc(doc(db, 'products', `edge-${label}`), canonicalProduct(overrides));
      await (allowed ? assertSucceeds(write) : assertFails(write));
    }
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'products', 'legacy-typed'), {
        productId: 'legacy-typed', itemCode: 42, productName: emoji.repeat(101), status: 'active',
      });
    });
    const legacy = doc(db, 'products', 'legacy-typed');
    await assertSucceeds(updateDoc(legacy, { sortOrder: 5 }));
    await assertFails(updateDoc(legacy, { itemCode: 43 }));
    await assertFails(updateDoc(legacy, { productName: emoji.repeat(102) }));
    await assertSucceeds(updateDoc(legacy, { productName: emoji.repeat(100) }));
  });
});

describe('personal planner visits ownership', () => {
  it('lets a salesman create, read, update and delete its own visit', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(
      setDoc(doc(db, 'visits', 'sales-1_new'), newVisit(users.salesman.uid)),
    );
    await assertSucceeds(getDoc(doc(db, 'visits', 'sales-1_own-visit')));
    await assertSucceeds(
      updateDoc(doc(db, 'visits', 'sales-1_own-visit'), {
        purpose: 'Updated purpose',
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(deleteDoc(doc(db, 'visits', 'sales-1_own-visit')));
  });

  it('denies cross-user read, update and delete of another salesman visit', async () => {
    const db = dbFor(users.salesman);
    await assertFails(getDoc(doc(db, 'visits', 'sales-2_other-visit')));
    await assertFails(
      updateDoc(doc(db, 'visits', 'sales-2_other-visit'), {
        purpose: 'Hijacked',
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(deleteDoc(doc(db, 'visits', 'sales-2_other-visit')));
  });

  it('denies creating a visit owned by someone else', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(doc(db, 'visits', 'forged'), newVisit(users.otherSalesman.uid)),
    );
  });

  it('denies mutating ownerUid or createdAt on an owned visit', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      updateDoc(doc(db, 'visits', 'sales-1_own-visit'), {
        ownerUid: users.otherSalesman.uid,
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(doc(db, 'visits', 'sales-1_own-visit'), {
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('only allows an owner-filtered visits query', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(
      getDocs(
        query(
          collection(db, 'visits'),
          where('ownerUid', '==', users.salesman.uid),
        ),
      ),
    );
    await assertFails(getDocs(collection(db, 'visits')));
    await assertFails(
      getDocs(
        query(
          collection(db, 'visits'),
          where('ownerUid', '==', users.otherSalesman.uid),
        ),
      ),
    );
  });

  it('denies all personal planner access for a suspended salesman', async () => {
    const db = dbFor(users.suspendedSalesman);
    await assertFails(
      getDoc(doc(db, 'visits', 'sales-suspended_own-visit')),
    );
    await assertFails(
      setDoc(
        doc(db, 'visits', 'suspended-create'),
        newVisit(users.suspendedSalesman.uid),
      ),
    );
    await assertFails(
      updateDoc(doc(db, 'visits', 'sales-suspended_own-visit'), {
        purpose: 'Suspended update',
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      deleteDoc(doc(db, 'visits', 'sales-suspended_own-visit')),
    );
  });
});

describe('mobile order retry boundary', () => {
  function newOrderItem(overrides = {}) {
    return {
      name: 'Orange Juice',
      productName: 'Orange Juice',
      productId: 'p1',
      barcode: '9551000000015',
      packingSize: '12 x 1L',
      price: 10,
      qty: 1,
      expiry: '',
      department: 'Beverage',
      departmentName: 'Beverage',
      shelfBatches: [],
      remarks: '',
      ...overrides,
    };
  }

  function commercialLine(item = newOrderItem()) {
    const productId = String(item.productId ?? '');
    const encodedName = Buffer.from(String(item.name ?? ''), 'utf8')
      .toString('base64url');
    const priceCents = Math.round(Number(item.price) * 100);
    return `${productId}~${encodedName}~${item.qty}~${priceCents}`;
  }

  function capturedOrderLocation() {
    const capturedAt = Timestamp.now();
    return {
      latitude: 1.5535,
      longitude: 110.3593,
      gpsLatitude: 1.5535,
      gpsLongitude: 110.3593,
      location: new GeoPoint(1.5535, 110.3593),
      locationCapturedAt: serverTimestamp(),
      accuracy: 12,
      accuracyMeters: 12,
      deviceCapturedAt: capturedAt,
      isMocked: false,
      locationVerification: 'location_verified',
      locationEvidence: {
        mode: 'location_verified',
        latitude: 1.5535,
        longitude: 110.3593,
        accuracyMeters: 12,
        deviceCapturedAt: capturedAt,
        isMocked: false,
        distanceMeters: 10,
      },
    };
  }

  function newOrder() {
    return {
      orderId: 'ORD-1000',
      visitSource: 'personal_planner',
      salesmanUid: users.salesman.uid,
      submittedByUid: users.salesman.uid,
      createdByUid: users.salesman.uid,
      uid: users.salesman.uid,
      userUid: users.salesman.uid,
      salesmanId: 'S001',
      salesmanCode: 'S001',
      branchId: 'B1',
      salesmanName: 'Sales One',
      retailerId: 'retailer-1',
      retailerName: 'Retailer One',
      outlet: 'Retailer One',
      status: 'submitted',
      totalProducts: 1,
      totalBoxes: 1,
      totalPrice: 10,
      submittedAt: serverTimestamp(),
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      items: [newOrderItem()],
      commercialSchemaVersion: 1,
      commercialLines: [commercialLine()],
      signatureTimestamps: {},
      locationEvidence: {
        mode: 'not_verified',
        failureCode: 'unavailable',
      },
    };
  }

  it('PRICE-02: an order create carries only the phone order keys and bounded top-level text', async () => {
    const db = dbFor(users.salesman);
    const create = (id, extra) =>
      setDoc(doc(db, 'orders', id), { ...newOrder(), orderId: id, ...extra });
    await assertFails(create('ORD-P02-A', { approvedByUid: users.admin.uid }));
    await assertFails(create('ORD-P02-B', { approvedAt: serverTimestamp() }));
    await assertFails(create('ORD-P02-C', { serverPriceCheck: { status: 'ok' } }));
    await assertFails(create('ORD-P02-D', { padding: 'x'.repeat(900000) }));
    await assertFails(create('ORD-P02-E', { outlet: 'x'.repeat(900000) }));
    await assertFails(create('ORD-P02-G', { 'orderId,visitId': 'x'.repeat(5000) }));
    await assertFails(create('ORD-P02-F', { salesmanName: 'x'.repeat(3000) }));
    await assertSucceeds(create('ORD-P02-OK', {
      visitId: 'visit-1',
      supervisorId: 'SUP1',
      salesmanEmail: 'sales@example.test',
    }));
  });

  function legacyCodeOnlyOrder() {
    return {
      orderId: 'ORD-LEGACY-CODE-ONLY',
      salesmanCode: 'S001',
      branchId: 'B1',
      status: 'submitted',
      submittedAt: Timestamp.fromDate(new Date('2025-01-01T00:00:00Z')),
    };
  }

  it('order tracking needs an existing order of the caller and accepts a held flush 10 days late', async () => {
    const db = dbFor(users.salesman);
    const orderId = 'ORD-1000';
    const gps = (id, extra = {}) => ({ ...validTrackingPayload(), orderId: id, ...extra });
    await assertFails(setDoc(doc(db, 'gps_tracking', 'order_ORD-MISSING'), gps('ORD-MISSING')));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', 'ORD-COLLEAGUE'), {
        ...newOrder(),
        orderId: 'ORD-COLLEAGUE',
        salesmanUid: users.otherSalesman.uid,
        submittedByUid: users.otherSalesman.uid,
        createdByUid: users.otherSalesman.uid,
        uid: users.otherSalesman.uid,
        userUid: users.otherSalesman.uid,
      });
      await setDoc(doc(context.firestore(), 'orders', orderId), newOrder());
    });
    await assertFails(setDoc(doc(db, 'gps_tracking', 'order_ORD-COLLEAGUE'), gps('ORD-COLLEAGUE')));
    const tenDaysAgo = Timestamp.fromMillis(Date.now() - 10 * 24 * 3600 * 1000);
    await assertSucceeds(setDoc(doc(db, 'gps_tracking', `order_${orderId}`), gps(orderId, { deviceCapturedAt: tenDaysAgo })));
  });

  it('order evidence: not_verified keeps 0 to 10000 m and any age, verified stays capped at 100 m', async () => {
    const db = dbFor(users.salesman);
    const evidence = (accuracyMeters, deviceCapturedAt) => ({
      mode: 'not_verified',
      latitude: 1.5535,
      longitude: 110.3593,
      accuracyMeters,
      deviceCapturedAt,
      isMocked: false,
    });
    const now = Timestamp.now();
    const tenDaysAgo = Timestamp.fromMillis(Date.now() - 10 * 24 * 3600 * 1000);
    let n = 0;
    const write = (data) => setDoc(doc(db, 'orders', `ORD-EV-${n += 1}`), { ...newOrder(), orderId: `ORD-EV-${n}`, ...data });
    for (const accuracy of [150, 9999, 0]) {
      await assertSucceeds(write({ locationEvidence: evidence(accuracy, now) }));
    }
    await assertSucceeds(write({ locationEvidence: evidence(50, tenDaysAgo) }));
    await assertFails(write({ locationEvidence: evidence(10001, now) }));
    const verified = (accuracy, capturedAt) => {
      const base = capturedOrderLocation();
      return {
        ...base,
        accuracy,
        accuracyMeters: accuracy,
        deviceCapturedAt: capturedAt,
        locationEvidence: { ...base.locationEvidence, accuracyMeters: accuracy, deviceCapturedAt: capturedAt },
      };
    };
    await assertFails(write(verified(150, now)));
    await assertSucceeds(write(verified(12, now)));
    await assertSucceeds(write(verified(12, tenDaysAgo)));
  });

  it('allows the own create and read but rejects a second mobile set', async () => {
    const db = dbFor(users.salesman);
    const orderRef = doc(db, 'orders', 'ORD-1000');
    const retryLookup = () => query(
      collection(db, 'orders'),
      where('salesmanUid', '==', users.salesman.uid),
      where('orderId', '==', 'ORD-1000'),
      limit(1),
    );

    await assertSucceeds(getDocs(retryLookup()));
    await assertSucceeds(setDoc(orderRef, newOrder()));
    await assertSucceeds(getDoc(orderRef));
    await assertSucceeds(getDocs(retryLookup()));
    await assertFails(setDoc(orderRef, newOrder()));
  });

  it('allows only the active matching salesman to read a code-only legacy order', async () => {
    const legacyOrder = legacyCodeOnlyOrder();
    for (const ownershipAlias of [
      'salesmanUid',
      'salesman_uid',
      'uid',
      'userUid',
      'submittedByUid',
      'createdByUid',
    ]) {
      if (Object.hasOwn(legacyOrder, ownershipAlias)) {
        throw new Error(`legacy fixture must not contain ${ownershipAlias}`);
      }
    }

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'orders', legacyOrder.orderId),
        legacyOrder,
      );
    });

    const ownerRef = doc(
      dbFor(users.salesman),
      'orders',
      legacyOrder.orderId,
    );
    await assertSucceeds(getDoc(ownerRef));
    await assertFails(
      getDoc(
        doc(dbFor(users.otherSalesman), 'orders', legacyOrder.orderId),
      ),
    );
    await assertFails(
      getDoc(
        doc(
          dbFor(users.suspendedMatchingSalesman),
          'orders',
          legacyOrder.orderId,
        ),
      ),
    );
  });

  it('rejects forged salesman and branch scope labels on create', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(doc(db, 'orders', 'ORD-FORGED-SCOPE-CODE'), {
        ...newOrder(),
        orderId: 'ORD-FORGED-SCOPE-CODE',
        salesmanCode: 'S002',
      }),
    );
    await assertFails(
      setDoc(doc(db, 'orders', 'ORD-FORGED-SCOPE-BRANCH'), {
        ...newOrder(),
        orderId: 'ORD-FORGED-SCOPE-BRANCH',
        branchId: 'B2',
      }),
    );
  });

  it('enforces one canonical order identity for an assigned route stop', async () => {
    const db = dbFor(users.salesman);
    const routePlanId = 'route-own';
    const routeStopId = 'stop-1';
    const orderId = assignedOrderId(
      users.salesman.uid,
      routePlanId,
      routeStopId,
    );
    const assignedOrder = {
      ...newOrder(),
      orderId,
      visitSource: 'assigned_route',
      routePlanId,
      routeStopId,
    };
    const orderRef = doc(db, 'orders', orderId);
    await assertSucceeds(setDoc(orderRef, assignedOrder));
    await assertFails(setDoc(orderRef, { ...assignedOrder, totalPrice: 20 }));
    await assertFails(
      setDoc(doc(db, 'orders', `${orderId}x`), {
        ...assignedOrder,
        orderId: `${orderId}x`,
      }),
    );
    await assertFails(
      setDoc(doc(db, 'orders', 'ORD-2000'), {
        ...assignedOrder,
        orderId: 'ORD-2000',
      }),
    );
  });

  it('allows only one winner when two clients create the same assigned-stop order', async () => {
    const routePlanId = 'route-own';
    const routeStopId = 'stop-1';
    const orderId = assignedOrderId(
      users.salesman.uid,
      routePlanId,
      routeStopId,
    );
    const assignedOrder = {
      ...newOrder(),
      orderId,
      visitSource: 'assigned_route',
      routePlanId,
      routeStopId,
    };
    const firstDb = dbFor(users.salesman);
    const secondDb = dbFor(users.salesman);
    const results = await Promise.allSettled([
      setDoc(doc(firstDb, 'orders', orderId), assignedOrder),
      setDoc(doc(secondDb, 'orders', orderId), {
        ...assignedOrder,
        totalPrice: 20,
      }),
    ]);
    const successes = results.filter((result) => result.status === 'fulfilled');
    const failures = results.filter((result) => result.status === 'rejected');
    if (successes.length !== 1 || failures.length !== 1) {
      throw new Error('Exactly one assigned-order create must win the race');
    }
  });

  it('accepts an assigned order with fresh verified location evidence', async () => {
    const routePlanId = 'route-own';
    const routeStopId = 'stop-1';
    const orderId = assignedOrderId(
      users.salesman.uid,
      routePlanId,
      routeStopId,
    );
    await assertSucceeds(setDoc(doc(dbFor(users.salesman), 'orders', orderId), {
      ...newOrder(),
      ...capturedOrderLocation(),
      orderId,
      visitSource: 'assigned_route',
      routePlanId,
      routeStopId,
    }));
  });

  it('atomically creates one order notification and order-scoped GPS event', async () => {
    const db = dbFor(users.salesman);
    const routePlanId = 'route-own';
    const routeStopId = 'stop-1';
    const orderId = assignedOrderId(
      users.salesman.uid,
      routePlanId,
      routeStopId,
    );
    const order = {
      ...newOrder(),
      orderId,
      visitSource: 'assigned_route',
      routePlanId,
      routeStopId,
    };
    const notification = {
      salesmanUid: users.salesman.uid,
      orderId,
      type: 'order',
    };
    const gps = {
      ...validTrackingPayload(),
      orderId,
    };
    const commit = () => {
      const batch = writeBatch(db);
      batch.set(doc(db, 'orders', orderId), order);
      batch.set(doc(db, 'notification_logs', `order_${orderId}`), notification);
      batch.set(doc(db, 'gps_tracking', `order_${orderId}`), gps);
      return batch.commit();
    };

    await assertSucceeds(commit());
    await assertSucceeds(
      getDoc(doc(db, 'notification_logs', `order_${orderId}`)),
    );
    await assertSucceeds(
      getDoc(doc(db, 'gps_tracking', `order_${orderId}`)),
    );
    await assertFails(commit());
  });

  function deletionAudit(orderId, overrides = {}) {
    return {
      action: 'delete',
      orderDocumentId: orderId,
      orderId,
      previousStatus: 'draft',
      actorUid: users.admin.uid,
      actorRole: 'admin',
      retailerId: 'retailer-1',
      salesmanUid: users.salesman.uid,
      occurredAt: serverTimestamp(),
      ...overrides,
    };
  }

  async function seedDeletableOrder(orderId, status = 'draft') {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', orderId), {
        ...newOrder(),
        orderId,
        status,
      });
    });
  }

  const orderDeveloper = { uid: 'order-delete-developer' };

  async function seedOrderDeveloper() {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', orderDeveloper.uid), {
        role: 'developer',
        status: 'active',
      });
    });
  }

  function auditedDelete(db, orderId, auditOverrides = {}) {
    const batch = writeBatch(db);
    batch.set(
      doc(db, 'order_audit_logs', orderId),
      deletionAudit(orderId, auditOverrides),
    );
    batch.delete(doc(db, 'orders', orderId));
    return batch.commit();
  }

  it('requires one atomic, source-bound audit for order deletion', async () => {
    const orderId = 'ORD-AUDIT-ATOMIC';
    await seedDeletableOrder(orderId);
    const db = dbFor(users.admin);

    await assertSucceeds(auditedDelete(db, orderId));
    const deleted = await getDoc(doc(db, 'orders', orderId));
    if (deleted.exists()) throw new Error('The audited order should be deleted');
    await assertSucceeds(getDoc(doc(db, 'order_audit_logs', orderId)));
  });

  it('limits admin order deletion to drafts and lets only a developer delete other orders', async () => {
    const submittedId = 'ORD-AUDIT-ADMIN-SUBMITTED';
    await seedDeletableOrder(submittedId, 'submitted');
    await assertFails(
      auditedDelete(dbFor(users.admin), submittedId, { previousStatus: 'submitted' }),
    );

    const approvedId = 'ORD-AUDIT-ADMIN-APPROVED';
    await seedDeletableOrder(approvedId, 'approved');
    await assertFails(
      auditedDelete(dbFor(users.admin), approvedId, { previousStatus: 'approved' }),
    );

    await seedOrderDeveloper();
    const developerId = 'ORD-AUDIT-DEVELOPER-SUBMITTED';
    await seedDeletableOrder(developerId, 'submitted');
    await assertSucceeds(
      auditedDelete(dbFor(orderDeveloper), developerId, {
        previousStatus: 'submitted',
        actorUid: orderDeveloper.uid,
        actorRole: 'developer',
      }),
    );
  });

  it('denies direct order deletion without an atomic audit', async () => {
    const orderId = 'ORD-AUDIT-NO-EVIDENCE';
    await seedDeletableOrder(orderId);
    await assertFails(deleteDoc(doc(dbFor(users.admin), 'orders', orderId)));
  });

  it('denies forged audit-only writes and actor or metadata tampering', async () => {
    const forgedId = 'ORD-AUDIT-FORGED';
    await seedDeletableOrder(forgedId);
    const adminDb = dbFor(users.admin);
    await assertFails(
      setDoc(
        doc(adminDb, 'order_audit_logs', forgedId),
        deletionAudit(forgedId),
      ),
    );

    const actorTamperId = 'ORD-AUDIT-ACTOR-TAMPER';
    await seedDeletableOrder(actorTamperId);
    const actorBatch = writeBatch(adminDb);
    actorBatch.set(
      doc(adminDb, 'order_audit_logs', actorTamperId),
      deletionAudit(actorTamperId, { actorUid: users.supervisor.uid }),
    );
    actorBatch.delete(doc(adminDb, 'orders', actorTamperId));
    await assertFails(actorBatch.commit());

    const metadataId = 'ORD-AUDIT-METADATA-TAMPER';
    await seedDeletableOrder(metadataId);
    const metadataBatch = writeBatch(adminDb);
    metadataBatch.set(
      doc(adminDb, 'order_audit_logs', metadataId),
      deletionAudit(metadataId, { retailerId: 'retailer-forged' }),
    );
    metadataBatch.delete(doc(adminDb, 'orders', metadataId));
    await assertFails(metadataBatch.commit());

    const sourceMetadataId = 'ORD-AUDIT-SOURCE-TAMPER';
    await seedDeletableOrder(sourceMetadataId);
    const sourceMetadataBatch = writeBatch(adminDb);
    sourceMetadataBatch.set(
      doc(adminDb, 'order_audit_logs', sourceMetadataId),
      deletionAudit(sourceMetadataId, { salesmanUid: users.otherSalesman.uid }),
    );
    sourceMetadataBatch.delete(doc(adminDb, 'orders', sourceMetadataId));
    await assertFails(sourceMetadataBatch.commit());

    const mobileId = 'ORD-AUDIT-MOBILE';
    await seedDeletableOrder(mobileId);
    await assertFails(
      setDoc(
        doc(dbFor(users.salesman), 'order_audit_logs', mobileId),
        deletionAudit(mobileId, {
          actorUid: users.salesman.uid,
          actorRole: 'salesman',
        }),
      ),
    );
  });

  it('keeps deletion audits immutable after a successful delete', async () => {
    const orderId = 'ORD-AUDIT-IMMUTABLE';
    await seedDeletableOrder(orderId);
    const db = dbFor(users.admin);
    const batch = writeBatch(db);
    batch.set(doc(db, 'order_audit_logs', orderId), deletionAudit(orderId));
    batch.delete(doc(db, 'orders', orderId));
    await assertSucceeds(batch.commit());

    await assertFails(
      updateDoc(doc(db, 'order_audit_logs', orderId), {
        actorRole: 'developer',
      }),
    );
    await assertFails(deleteDoc(doc(db, 'order_audit_logs', orderId)));
  });

  it('rejects an assigned order for a stop outside the plan or another retailer', async () => {
    const db = dbFor(users.salesman);
    const routePlanId = 'route-own';
    for (const [routeStopId, retailerId] of [
      ['fabricated-stop', 'retailer-1'],
      ['stop-1', 'retailer-2'],
    ]) {
      const orderId = assignedOrderId(users.salesman.uid, routePlanId, routeStopId);
      await assertFails(setDoc(doc(db, 'orders', orderId), {
        ...newOrder(),
        orderId,
        retailerId,
        visitSource: 'assigned_route',
        routePlanId,
        routeStopId,
      }));
    }
  });

  it('lets a salesman mark workflow only on its own assigned retailer', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, 'retailers', 'mine'), {
        retailerName: 'Mine', branchId: 'B1', assignedSalesmanId: 'S001',
      });
      await setDoc(doc(adminDb, 'retailers', 'theirs'), {
        retailerName: 'Theirs', branchId: 'B1', assignedSalesmanId: 'S002',
      });
      await setDoc(doc(adminDb, 'retailers', 'nobody'), {
        retailerName: 'Nobody', branchId: 'B1', assignedSalesmanId: '',
      });
    });
    const db = dbFor(users.salesman);
    const marker = { progress: 3, lastSalesmanUid: users.salesman.uid };
    await assertSucceeds(updateDoc(doc(db, 'retailers', 'mine'), marker));
    await assertFails(updateDoc(doc(db, 'retailers', 'theirs'), marker));
    await assertFails(updateDoc(doc(db, 'retailers', 'nobody'), marker));
    await assertFails(
      updateDoc(doc(db, 'retailers', 'mine'), {
        progress: 2,
        lastSalesmanUid: users.otherSalesman.uid,
      }),
    );
  });

  it('rejects cross-user slot poisoning and unassigned route identities', async () => {
    const db = dbFor(users.salesman);
    const victimOrderId = assignedOrderId(
      users.otherSalesman.uid,
      'route-other',
      'stop-1',
    );
    await assertFails(setDoc(doc(db, 'orders', victimOrderId), {
      ...newOrder(),
      orderId: victimOrderId,
      salesmanUid: users.otherSalesman.uid,
      submittedByUid: users.salesman.uid,
      visitSource: 'assigned_route',
      routePlanId: 'route-other',
      routeStopId: 'stop-1',
    }));

    for (const routePlanId of ['route-missing', 'route-other', 'route-draft']) {
      const orderId = assignedOrderId(
        users.salesman.uid,
        routePlanId,
        'stop-1',
      );
      await assertFails(setDoc(doc(db, 'orders', orderId), {
        ...newOrder(),
        orderId,
        visitSource: 'assigned_route',
        routePlanId,
        routeStopId: 'stop-1',
      }));
    }
  });

  it('keeps personal orders compatible but rejects partial assigned identity', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(setDoc(doc(db, 'orders', 'ORD-3000'), {
      ...newOrder(),
      orderId: 'ORD-3000',
      visitSource: 'personal_planner',
    }));
    await assertFails(setDoc(doc(db, 'orders', 'ORD-3001'), {
      ...newOrder(),
      orderId: 'ORD-3001',
      routePlanId: 'route-own',
    }));
  });

  it('rejects malformed submitted-order identities, aggregates, and commercial lines', async () => {
    const db = dbFor(users.salesman);
    const base = newOrder();
    const rejected = [
      { ...base, orderId: 'ORD-BAD-EMPTY', items: [], totalProducts: 0, totalBoxes: 0, totalPrice: 0 },
      { ...base, orderId: 'ORD-BAD-RETAILER', retailerId: '' },
      { ...base, orderId: 'ORD-BAD-OWNER', submittedByUid: users.otherSalesman.uid },
      { ...base, orderId: 'ORD-BAD-COUNT', totalProducts: 2 },
      { ...base, orderId: 'ORD-BAD-BOXES', totalBoxes: 0 },
      { ...base, orderId: 'ORD-BAD-TOTAL', totalPrice: 0 },
      { ...base, orderId: 'ORD-BAD-LINE-COUNT', commercialLines: [] },
      { ...base, orderId: 'ORD-BAD-NEGATIVE', commercialLines: ['p1~T3JhbmdlIEp1aWNl~-1~1000'] },
      { ...base, orderId: 'ORD-BAD-ZERO-PRICE', commercialLines: ['p1~T3JhbmdlIEp1aWNl~1~0'] },
      { ...base, orderId: 'ORD-BAD-HUGE-PRICE', commercialLines: ['p1~T3JhbmdlIEp1aWNl~1~1000000000'] },
      { ...base, orderId: 'ORD-BAD-WRONG-TYPE', commercialLines: [1] },
      { ...base, orderId: 'ORD-BAD-PRODUCT', commercialLines: ['../p1~T3JhbmdlIEp1aWNl~1~1000'] },
      { ...base, orderId: 'ORD-BAD-NAME', commercialLines: ['p1~~1~1000'] },
      { ...base, orderId: 'ORD-BAD-QTY-ZERO', commercialLines: ['p1~T3JhbmdlIEp1aWNl~0~1000'] },
      { ...base, orderId: 'ORD-BAD-QTY-LEAD-ZERO', commercialLines: ['p1~T3JhbmdlIEp1aWNl~05~1000'] },
      { ...base, orderId: 'ORD-BAD-QTY-CEILING', commercialLines: ['p1~T3JhbmdlIEp1aWNl~1000~1000'] },
      { ...base, orderId: 'ORD-BAD-BOXES-CEILING', totalBoxes: 24976 },
      { ...base, orderId: 'ORD-BAD-TIME', submittedAt: new Date('2020-01-01T00:00:00Z') },
    ];
    for (const order of rejected) {
      await assertFails(setDoc(doc(db, 'orders', order.orderId), order));
    }
  });

  it('accepts uppercase and hyphenated catalogue product IDs', async () => {
    const db = dbFor(users.salesman);
    const item = newOrderItem({ productId: 'P-004-XL' });
    await assertSucceeds(setDoc(doc(db, 'orders', 'ORD-PRODUCT-ID-COMPAT'), {
      ...newOrder(),
      orderId: 'ORD-PRODUCT-ID-COMPAT',
      items: [item],
      commercialLines: [commercialLine(item)],
    }));
  });

  it('accepts per-line quantities above 5 up to the 999 ceiling', async () => {
    const db = dbFor(users.salesman);
    for (const qty of [6, 120, 999]) {
      const item = newOrderItem({ qty });
      await assertSucceeds(setDoc(doc(db, 'orders', `ORD-QTY-${qty}`), {
        ...newOrder(),
        orderId: `ORD-QTY-${qty}`,
        items: [item],
        commercialLines: [commercialLine(item)],
        totalBoxes: qty,
        totalPrice: 10 * qty,
      }));
    }
    const items = Array.from({ length: 25 }, (_, index) => newOrderItem({
      name: `Product ${index}`,
      productName: `Product ${index}`,
      productId: `product_${index}`,
      qty: 999,
    }));
    await assertSucceeds(setDoc(doc(db, 'orders', 'ORD-QTY-FULL'), {
      ...newOrder(),
      orderId: 'ORD-QTY-FULL',
      items,
      commercialLines: items.map(commercialLine),
      totalProducts: 25,
      totalBoxes: 25 * 999,
      totalPrice: 10 * 25 * 999,
    }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', 'ORD-QTY-APPROVE'), {
        ...newOrder(),
        orderId: 'ORD-QTY-APPROVE',
        serverPriceCheck: { status: 'ok', version: 1 },
        items: [newOrderItem({ qty: 40 })],
        commercialLines: [commercialLine(newOrderItem({ qty: 40 }))],
        totalBoxes: 40,
        totalPrice: 400,
        submittedAt: Timestamp.now(),
        createdAt: Timestamp.now(),
        updatedAt: Timestamp.now(),
      });
    });
    await assertSucceeds(updateDoc(doc(dbFor(users.supervisor), 'orders', 'ORD-QTY-APPROVE'), {
      status: 'approved',
      approvedAt: serverTimestamp(),
      approvedByUid: users.supervisor.uid,
      approvedByName: 'Supervisor',
      approvedByRole: 'supervisor',
      updatedAt: serverTimestamp(),
    }));
  });

  it('accepts the maximum bounded line count and rejects one extra line', async () => {
    const db = dbFor(users.salesman);
    const items = Array.from({ length: 25 }, (_, index) => newOrderItem({
      name: `Product ${index}`,
      productName: `Product ${index}`,
      productId: `product_${index}`,
    }));
    const commercialLines = items.map(commercialLine);
    await assertSucceeds(setDoc(doc(db, 'orders', 'ORD-MAX-25'), {
      ...newOrder(),
      orderId: 'ORD-MAX-25',
      items,
      commercialLines,
      totalProducts: 25,
      totalBoxes: 25,
      totalPrice: 250,
    }));
    const extraItem = newOrderItem({
      name: 'Product 25',
      productName: 'Product 25',
      productId: 'product_25',
    });
    const extra = [...items, extraItem];
    await assertFails(setDoc(doc(db, 'orders', 'ORD-MAX-26'), {
      ...newOrder(),
      orderId: 'ORD-MAX-26',
      items: extra,
      commercialLines: [...commercialLines, commercialLine(extraItem)],
      totalProducts: 26,
      totalBoxes: 26,
      totalPrice: 260,
    }));
  });

  it('rejects dashboard-role attempts to manufacture orders', async () => {
    const order = {
      ...newOrder(),
      orderId: 'ORD-DASHBOARD-CREATE',
      salesmanUid: users.salesman.uid,
      submittedByUid: users.salesman.uid,
      createdByUid: users.salesman.uid,
      uid: users.salesman.uid,
      userUid: users.salesman.uid,
    };
    await assertFails(setDoc(
      doc(dbFor(users.admin), 'orders', order.orderId),
      order,
    ));
  });

  it('lets a decision-maker approve or reject a held_for_review order, and lets no client create or move an order into it', async () => {
    const heldId = 'ORD-HELD-DECIDE';
    const rejectedHeldId = 'ORD-HELD-REJECT';
    const submittedId = 'ORD-HELD-MOVE';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      for (const [id, status] of [[heldId, 'held_for_review'], [rejectedHeldId, 'held_for_review'], [submittedId, 'submitted']]) {
        await setDoc(doc(context.firestore(), 'orders', id), {
          ...newOrder(),
          orderId: id,
          status,
          ...(status === 'held_for_review' ? { reviewReason: 'session_after_pause' } : {}),
        });
      }
    });
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(updateDoc(doc(supervisorDb, 'orders', heldId), {
      status: 'approved',
      approvedAt: serverTimestamp(),
      approvedByUid: users.supervisor.uid,
      approvedByName: 'Supervisor',
      approvedByRole: 'supervisor',
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(doc(supervisorDb, 'orders', rejectedHeldId), {
      status: 'rejected',
      rejectedAt: serverTimestamp(),
      rejectedByUid: users.supervisor.uid,
      rejectedByName: 'Supervisor',
      rejectedByRole: 'supervisor',
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(doc(supervisorDb, 'orders', submittedId), { status: 'held_for_review', updatedAt: serverTimestamp() }));
    await assertFails(updateDoc(doc(dbFor(users.salesman), 'orders', submittedId), { status: 'held_for_review' }));
    await assertFails(setDoc(doc(dbFor(users.salesman), 'orders', 'ORD-HELD-CREATE'), {
      ...newOrder(),
      orderId: 'ORD-HELD-CREATE',
      status: 'held_for_review',
    }));
  });

  it('makes order decisions terminal, scoped, timestamped, and actor-bound', async () => {
    const incompleteOrderId = 'ORD-DECISION-INCOMPLETE';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', incompleteOrderId), {
        ...newOrder(),
        orderId: incompleteOrderId,
        items: [],
        totalProducts: 0,
        totalBoxes: 0,
        totalPrice: 0,
      });
    });
    const incompleteDecision = dbFor(users.supervisor);
    await assertFails(updateDoc(
      doc(incompleteDecision, 'orders', incompleteOrderId),
      {
        status: 'approved',
        approvedAt: serverTimestamp(),
        approvedByUid: users.supervisor.uid,
        approvedByName: 'Supervisor',
        approvedByRole: 'supervisor',
        updatedAt: serverTimestamp(),
      },
    ));
    await assertSucceeds(updateDoc(
      doc(incompleteDecision, 'orders', incompleteOrderId),
      {
        status: 'rejected',
        rejectedAt: serverTimestamp(),
        rejectedByUid: users.supervisor.uid,
        rejectedByName: 'Supervisor',
        rejectedByRole: 'supervisor',
        updatedAt: serverTimestamp(),
      },
    ));
    const decisionOrderId = 'ORD-DECISION-TERMINAL';
    const decisionRef = doc(dbFor(users.salesman), 'orders', decisionOrderId);
    await assertSucceeds(setDoc(decisionRef, {
      ...newOrder(),
      orderId: decisionOrderId,
    }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'orders', decisionOrderId), { serverPriceCheck: { status: 'ok', version: 1 } });
    });

    const supervisorDb = dbFor(users.supervisor);
    const decisionFields = (status, actorUid, actorRole) => ({
      status,
      ...(status === 'approved'
        ? { approvedAt: serverTimestamp(), approvedByUid: actorUid, approvedByName: 'Supervisor', approvedByRole: actorRole }
        : { rejectedAt: serverTimestamp(), rejectedByUid: actorUid, rejectedByName: 'Supervisor', rejectedByRole: actorRole }),
      updatedAt: serverTimestamp(),
    });

    await assertFails(updateDoc(
      doc(supervisorDb, 'orders', decisionOrderId),
      decisionFields('approved', users.admin.uid, 'admin'),
    ));
    await assertSucceeds(updateDoc(
      doc(supervisorDb, 'orders', decisionOrderId),
      decisionFields('approved', users.supervisor.uid, 'supervisor'),
    ));

    await assertFails(updateDoc(
      doc(supervisorDb, 'orders', decisionOrderId),
      decisionFields('approved', users.supervisor.uid, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(dbFor(users.branchManager), 'orders', decisionOrderId),
      decisionFields('rejected', users.branchManager.uid, 'branch_manager'),
    ));

    const otherOrderId = 'ORD-DECISION-WRONG-SCOPE';
    await assertSucceeds(setDoc(doc(dbFor(users.otherSalesman), 'orders', otherOrderId), {
      ...newOrder(),
      orderId: otherOrderId,
      salesmanUid: users.otherSalesman.uid,
      submittedByUid: users.otherSalesman.uid,
      createdByUid: users.otherSalesman.uid,
      uid: users.otherSalesman.uid,
      userUid: users.otherSalesman.uid,
      salesmanId: 'S002',
      salesmanCode: 'S002',
      branchId: 'B2',
    }));
    await assertFails(updateDoc(
      doc(supervisorDb, 'orders', otherOrderId),
      decisionFields('approved', users.supervisor.uid, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(dbFor(users.branchManager), 'orders', otherOrderId),
      decisionFields('approved', users.branchManager.uid, 'branch_manager'),
    ));
  });

  it('allows owner-scoped assigned-stop recovery and denies another owner', async () => {
    const ownDb = dbFor(users.salesman);
    const ownLookup = (db, uid) => query(
      collection(db, 'orders'),
      where('salesmanUid', '==', uid),
      where('routePlanId', '==', 'legacy-route'),
      where('routeStopId', '==', 'legacy-stop'),
      limit(3),
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', 'ORD-9000'), {
        ...newOrder(),
        orderId: 'ORD-9000',
        visitSource: 'assigned_route',
        routePlanId: 'legacy-route',
        routeStopId: 'legacy-stop',
      });
    });
    const recovered = await assertSucceeds(
      getDocs(ownLookup(ownDb, users.salesman.uid)),
    );
    if (recovered.size !== 1 || recovered.docs[0].id !== 'ORD-9000') {
      throw new Error('Legacy assigned-stop order was not recovered');
    }
    await assertFails(
      getDocs(ownLookup(ownDb, users.otherSalesman.uid)),
    );
  });

  it('blocks new order writes after the salesperson is suspended', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'users', users.salesman.uid), {
        status: 'suspended',
      });
    });
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'orders', 'ORD-4000'), {
        ...newOrder(),
        orderId: 'ORD-4000',
      }),
    );
  });

  it('fails closed when a stale active access index conflicts with the canonical suspended profile', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', 'S001'), {
        ...users.salesman.profile,
        uid: users.salesman.uid,
        status: 'active',
      });
      await setDoc(doc(db, 'user_access', users.salesman.uid), {
        ...users.salesman.profile,
        status: 'active',
        userDocId: 'S001',
      });
      await setDoc(doc(db, 'users', 'SV001'), {
        ...users.suspendedSupervisor.profile,
        uid: users.suspendedSupervisor.uid,
        status: 'suspended',
      });
      await setDoc(doc(db, 'user_access', users.suspendedSupervisor.uid), {
        ...users.suspendedSupervisor.profile,
        status: 'active',
        userDocId: 'SV001',
      });
    });

    await assertSucceeds(getDoc(doc(dbFor(users.salesman), 'route_plans', 'route-own')));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await updateDoc(doc(db, 'user_access', users.salesman.uid), { status: 'suspended' });
      await updateDoc(doc(db, 'users', 'S001'), { status: 'active' });
    });
    await assertFails(getDoc(doc(dbFor(users.salesman), 'route_plans', 'route-own')));

    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await updateDoc(doc(db, 'user_access', users.salesman.uid), { status: 'active' });
      await updateDoc(doc(db, 'users', 'S001'), { status: 'suspended' });
    });
    await assertFails(getDoc(doc(dbFor(users.salesman), 'route_plans', 'route-own')));

    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'orders', 'ORD-SPLIT-PROFILE'), {
        ...newOrder(),
        orderId: 'ORD-SPLIT-PROFILE',
      }),
    );
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'visits', 'VISIT-SPLIT-PROFILE'), {
        ...newVisit(users.salesman.uid),
      }),
    );
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'route_plan_progress', 'route-own_sales-1'), {
        progressId: 'route-own_sales-1',
        planId: 'route-own',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        isOfflineCreated: false,
        status: 'accepted',
        stopProgress: {},
        handledStopIds: [],
        acceptedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      getDoc(doc(
        dbFor(users.suspendedSupervisor),
        'weekly_ai_summaries',
        'salesman-S001',
      )),
    );
  });
});

describe('login attempt privacy', () => {
  it('denies unauthenticated reads, listing, and writes', async () => {
    const db = unauthDb();
    await assertFails(getDoc(doc(db, 'login_attempts', 'counter-user')));
    await assertFails(getDocs(collection(db, 'login_attempts')));
    await assertFails(
      setDoc(doc(db, 'login_attempts', 'new-user'), {
        failedCount: 1,
        lastAttempt: serverTimestamp(),
      }),
    );
  });

  it('denies signed-in reads, writes, and deletes', async () => {
    const db = dbFor(users.admin);
    await assertFails(getDoc(doc(db, 'login_attempts', 'counter-user')));
    await assertFails(
      updateDoc(doc(db, 'login_attempts', 'counter-user'), {
        failedCount: 0,
        lastAttempt: serverTimestamp(),
      }),
    );
    await assertFails(deleteDoc(doc(db, 'login_attempts', 'counter-user')));
  });
});

describe('privilege escalation and self-service writes', () => {
  it('normalizes legacy role labels for UID-keyed profiles', async () => {
    const legacySalesmanUid = 'legacy-label-salesman';
    const legacyManagerUid = 'legacy-label-manager';
    const legacyAdminUid = 'legacy-label-admin';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', legacySalesmanUid), {
        role: 'Salesman',
        status: 'active',
        employeeCode: 'S-LABEL',
        branchId: 'B1',
      });
      await setDoc(doc(db, 'users', legacyManagerUid), {
        role: 'Branch Manager',
        status: 'active',
        branchId: 'B1',
      });
      await setDoc(doc(db, 'users', legacyAdminUid), {
        role: 'Admin',
        status: 'active',
      });
    });

    const salesmanDb = authContext(legacySalesmanUid).firestore();
    await assertSucceeds(
      setDoc(
        doc(salesmanDb, 'live_tracking', legacySalesmanUid),
        validWorkSessionStartPayload({
          uid: legacySalesmanUid,
          salesmanCode: 'S-LABEL',
          sessionId: 'c'.repeat(32),
          generation: 1,
        }),
      ),
    );

    const managerDb = authContext(legacyManagerUid).firestore();
    await assertSucceeds(
      getDoc(doc(managerDb, 'system_settings', 'legacy-manager-role')),
    );

    const adminDb = authContext(legacyAdminUid).firestore();
    await assertSucceeds(
      setDoc(doc(adminDb, 'system_settings', 'legacy-admin-role'), { value: true }),
    );
  });

  it('rejects an access index whose declared uid aliases differ from auth uid', async () => {
    const authUid = 'access-alias-mismatch';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', 'access-alias-canonical'), {
        role: 'admin',
        status: 'active',
      });
      await setDoc(doc(db, 'user_access', authUid), {
        uid: 'different-auth-uid',
        user_uid: authUid,
        userDocId: 'access-alias-canonical',
        role: 'admin',
        status: 'active',
      });
    });

    await assertFails(
      getDoc(
        doc(
          authContext(authUid).firestore(),
          'system_settings',
          'access-alias-mismatch',
        ),
      ),
    );
  });

  it('fails closed when the access index role conflicts with the linked profile', async () => {
    const conflictUid = 'admin-role-conflict-uid';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', 'admin-conflict-canonical'), {
        uid: conflictUid,
        role: 'salesman',
        status: 'active',
      });
      await setDoc(doc(db, 'user_access', conflictUid), {
        uid: conflictUid,
        userDocId: 'admin-conflict-canonical',
        role: 'admin',
        user_group: 'admin',
        status: 'active',
      });
    });

    await assertFails(
      setDoc(
        doc(authContext(conflictUid).firestore(), 'system_settings', 'role-conflict'),
        { value: 'must be denied' },
      ),
    );
  });

  it('forbids a salesman from writing access-control docs', async () => {
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'user_access', users.salesman.uid), {
        role: 'admin',
        status: 'active',
      }),
    );
  });

  it('lets a salesman edit a harmless own-profile field but not privileged ones', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(
      updateDoc(doc(db, 'users', users.salesman.uid), { phone: '0123456789' }),
    );
    await assertFails(
      updateDoc(doc(db, 'users', users.salesman.uid), { role: 'admin' }),
    );
    await assertFails(
      updateDoc(doc(db, 'users', users.salesman.uid), { status: 'inactive' }),
    );
  });

  it('refuses every self-registration, including the salesman role', async () => {
    const freshDb = authContext('fresh-uid').firestore();
    for (const profile of [
      { uid: 'fresh-uid', role: 'admin', status: 'active' },
      { uid: 'fresh-uid', role: 'salesman', status: 'active' },
      { uid: 'fresh-uid', role: 'salesman' },
      { uid: 'fresh-uid', name: 'No Role' },
    ]) {
      await assertFails(setDoc(doc(freshDb, 'users', 'fresh-uid'), profile));
    }
    await assertFails(getDoc(doc(freshDb, 'route_plans', 'route-own')));
    await assertFails(
      setDoc(doc(freshDb, 'visit_logs', 'fresh-log'), { salesmanUid: 'fresh-uid' }),
    );
  });

  it('no longer lets an admin create a profile for another uid (the server does)', async () => {
    await assertFails(
      setDoc(doc(dbFor(users.admin), 'users', 'S777'), {
        uid: 'provisioned-uid',
        role: 'salesman',
        status: 'active',
        employeeCode: 'S777',
        branchId: 'B1',
        provisioningState: 'pending',
        provisioningByUid: users.admin.uid,
      }),
    );
  });

  it('refuses self-registration that chooses a code, branch or team', async () => {
    const code = users.salesman.profile.employeeCode;
    const scopeFields = [
      { employeeCode: code },
      { staffId: code },
      { salesmanCode: code },
      { salesman_code: code },
      { branchId: 'B1' },
      { branch_id: 'B1' },
      { supervisorId: 'SUP1' },
      { supervisorUid: 'some-uid' },
      { assignedSalesmanCodes: ['S001'] },
    ];
    for (const [index, extra] of scopeFields.entries()) {
      const uid = 'scope-claim-' + index;
      const freshDb = authContext(uid).firestore();
      await assertFails(
        setDoc(doc(freshDb, 'users', uid), {
          uid,
          role: 'salesman',
          status: 'active',
          ...extra,
        }),
      );
    }
  });

  it('refuses every self-registration spelling that normalises to a privileged role', async () => {
    const spellings = [
      'ADMIN',
      'Administrator',
      'ADMINISTRATOR',
      'Developer',
      'Supervisor',
      'Branch Manager',
      '  admin  ',
    ];
    for (const [index, role] of spellings.entries()) {
      const uid = 'role-variant-' + index;
      const freshDb = authContext(uid).firestore();
      await assertFails(
        setDoc(doc(freshDb, 'users', uid), {
          uid,
          role,
          status: 'active',
        }),
      );
    }
  });

  it('refuses self-registration for every salesman spelling as well', async () => {
    const spellings = [
      'salesman',
      'Salesman',
      'SALESMAN',
      'sales_representative',
      'SALES_REPRESENTATIVE',
      'sales representative',
    ];
    for (const [index, role] of spellings.entries()) {
      const uid = 'salesman-variant-' + index;
      const freshDb = authContext(uid).firestore();
      await assertFails(
        setDoc(doc(freshDb, 'users', uid), {
          uid,
          role,
          status: 'active',
        }),
      );
    }
  });

  it('a case-variant role label cannot unlock an admin-only read', async () => {
    const uid = 'role-escalation-attempt';
    const freshDb = authContext(uid).firestore();
    await assertFails(
      setDoc(doc(freshDb, 'users', uid), {
        uid,
        role: 'ADMIN',
        status: 'active',
      }),
    );
    await assertFails(getDoc(doc(freshDb, 'users', users.admin.uid)));
  });
});

describe('admin-only collections', () => {
  it('forbids a salesman and allows an admin to write system settings', async () => {
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'system_settings', 'cfg'), { x: 1 }),
    );
    await assertSucceeds(
      setDoc(doc(dbFor(users.admin), 'system_settings', 'cfg'), { x: 1 }),
    );
  });

  it('lets only an admin save the live forecast window, and dashboard roles read it', async () => {
    const ref = (user) => doc(dbFor(user), 'system_settings', 'forecast_window');
    await assertSucceeds(setDoc(ref(users.admin), { historyWeeks: 12 }));
    await assertFails(setDoc(ref(users.supervisor), { historyWeeks: 4 }));
    await assertFails(setDoc(ref(users.branchManager), { historyWeeks: 4 }));
    await assertSucceeds(getDoc(ref(users.supervisor)));
    await assertSucceeds(getDoc(ref(users.branchManager)));
    await assertFails(getDoc(ref(users.salesman)));
  });

  it('forbids a salesman from writing CMS backups', async () => {
    await assertFails(
      setDoc(doc(dbFor(users.salesman), 'cms_backups', 'b1'), { x: 1 }),
    );
  });
});

describe('salesman-owned tracking ownership', () => {
  it('scopes tracking-control reads and monotonic mode changes to active roles', async () => {
    const adminDb = dbFor(users.admin);
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    const ownDb = dbFor(users.salesman);
    const controlRef = (db, uid) => doc(db, 'tracking_controls', uid);

    await assertFails(
      writeTrackingControlTransaction(
        ownDb,
        users.salesman.uid,
        'live',
        users.salesman.uid,
      ),
    );
    await assertSucceeds(
      writeTrackingControlTransaction(
        adminDb,
        users.salesman.uid,
        'live',
        users.admin.uid,
      ),
    );
    await assertSucceeds(
      getDoc(controlRef(ownDb, users.salesman.uid)),
    );
    await assertSucceeds(
      getDoc(controlRef(supervisorDb, users.salesman.uid)),
    );
    await assertSucceeds(
      getDoc(controlRef(managerDb, users.salesman.uid)),
    );
    await assertFails(
      getDoc(controlRef(ownDb, users.otherSalesman.uid)),
    );
    await assertFails(
      getDoc(controlRef(supervisorDb, users.otherSalesman.uid)),
    );
    await assertFails(
      getDoc(controlRef(managerDb, users.otherSalesman.uid)),
    );
    await assertFails(
      getDocs(collection(adminDb, 'tracking_controls')),
    );

    await assertSucceeds(writeTrackingControlTransaction(
      supervisorDb,
      users.salesman.uid,
      'standard',
      users.supervisor.uid,
    ));
    await assertFails(writeTrackingControlTransaction(
      managerDb,
      users.salesman.uid,
      'battery_saver',
      users.branchManager.uid,
    ));
    const finalControl = (await getDoc(
      controlRef(adminDb, users.salesman.uid),
    )).data();
    assert.equal(finalControl.revision, 2);
    assert.equal(finalControl.mode, 'standard');

    await assertFails(
      writeTrackingControlTransaction(
        supervisorDb,
        users.otherSalesman.uid,
        'live',
        users.supervisor.uid,
      ),
    );
    await assertFails(
      writeTrackingControlTransaction(
        managerDb,
        users.otherSalesman.uid,
        'live',
        users.branchManager.uid,
      ),
    );
    await assertFails(
      writeTrackingControlTransaction(
        managerDb,
        'sales-no-control-yet',
        'live',
        users.branchManager.uid,
      ),
    );
  });

  it('rejects malformed tracking controls and direct revision manipulation', async () => {
    const adminDb = dbFor(users.admin);
    const control = (uid = users.salesman.uid) =>
      doc(adminDb, 'tracking_controls', uid);

    await assertFails(setDoc(control(), {
      ...trackingControlPayload({ mode: 'custom', revision: 1 }),
    }));
    await assertFails(setDoc(control(), {
      ...trackingControlPayload({ mode: 'live', revision: 0 }),
    }));
    await assertFails(setDoc(control(), {
      ...trackingControlPayload({ mode: 'live', revision: 1 }),
      intervalSeconds: 1,
    }));
    await assertFails(setDoc(control(), {
      ...trackingControlPayload({
        mode: 'live',
        revision: 1,
        updatedByUid: users.supervisor.uid,
      }),
    }));
    await assertSucceeds(setDoc(control(), trackingControlPayload()));
    await assertFails(updateDoc(control(), {
      mode: 'ultra_fast',
      revision: 2,
      updatedByUid: users.admin.uid,
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(control(), {
      mode: 'standard',
      revision: 1,
      updatedByUid: users.admin.uid,
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(control(), {
      mode: 'standard',
      revision: 2,
      updatedByUid: users.otherSalesman.uid,
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(control(), {
      mode: 'standard',
      revision: 2,
      updatedByUid: users.admin.uid,
      updatedAt: Timestamp.now(),
    }));
  });

  it('binds session start and fix updates to the control revision acknowledged by the phone', async () => {
    const adminDb = dbFor(users.admin);
    const salesmanDb = dbFor(users.salesman);
    const liveRef = doc(salesmanDb, 'live_tracking', users.salesman.uid);
    const controlRef = doc(
      adminDb,
      'tracking_controls',
      users.salesman.uid,
    );
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(
      'f'.repeat(32),
      1,
    ), { merge: true }));
    await assertSucceeds(setDoc(controlRef, trackingControlPayload()));
    await assertFails(setDoc(liveRef, workSessionStartFields(
      '1'.repeat(32),
      2,
    ), { merge: true }));

    await assertSucceeds(updateDoc(liveRef, {
      trackingMode: 'live',
      appliedControlRevision: 1,
    }));
    await assertFails(updateDoc(liveRef, {
      trackingMode: 'standard',
      appliedControlRevision: 1,
    }));
    await assertSucceeds(setDoc(liveRef, trackingFixPayload({
      sessionId: 'f'.repeat(32),
      generation: 1,
      sequence: 1,
      trackingMode: 'live',
      appliedControlRevision: 1,
    }), { merge: true }));
    await assertFails(setDoc(liveRef, trackingFixPayload({
      sessionId: 'f'.repeat(32),
      generation: 1,
      sequence: 2,
      trackingMode: 'battery_saver',
      appliedControlRevision: 0,
    }), { merge: true }));
  });

  it('lets a salesman create only its own gps record, and never mutate one', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(getDoc(doc(db, 'gps_tracking', 'g-seed')));
    await assertFails(getDoc(doc(db, 'gps_tracking', 'g-other')));
    await assertSucceeds(getDoc(doc(db, 'live_tracking', users.salesman.uid)));
    await assertFails(getDoc(doc(db, 'live_tracking', users.otherSalesman.uid)));
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const sessionId = 'a'.repeat(32);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(sessionId, 1), { merge: true }),
    );
    const deviceCapturedAt = Timestamp.now();
    const fix = trackingFixPayload({
      sessionId,
      generation: 1,
      sequence: 1,
      deviceCapturedAt,
    });
    const breadcrumb = sessionBreadcrumbPayload({
      sessionId,
      generation: 1,
      sequence: 1,
      deviceCapturedAt,
    });
    const batch = writeBatch(db);
    batch.set(liveRef, fix, { merge: true });
    batch.set(doc(db, 'gps_tracking', breadcrumb.eventId), breadcrumb);
    await assertSucceeds(batch.commit());
    await assertFails(
      setDoc(doc(db, 'gps_tracking', 'g-forged'), {
        ...validTrackingPayload(users.otherSalesman.uid),
        salesmanCode: 'S002',
      }),
    );
    await assertFails(
      setDoc(doc(db, 'gps_tracking', 'g-forged-scope'), {
        ...validTrackingPayload(),
        salesmanCode: 'S002',
        branchId: 'B2',
      }),
    );
    await assertFails(
      updateDoc(doc(db, 'gps_tracking', 'g-seed'), { lat: 9.9 }),
    );
    await assertFails(deleteDoc(doc(db, 'gps_tracking', 'g-seed')));
  });

  it('refuses a fix that is older than the previous fix or older than seven days', async () => {
    const db = dbFor(users.salesman);
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const sessionId = 'd'.repeat(32);
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(sessionId, 1), { merge: true }));
    const writeFix = (sequence, deviceCapturedAt) => {
      const batch = writeBatch(db);
      const breadcrumb = sessionBreadcrumbPayload({ sessionId, generation: 1, sequence, deviceCapturedAt });
      batch.set(doc(db, 'gps_tracking', breadcrumb.eventId), breadcrumb);
      batch.set(liveRef, trackingFixPayload({ sessionId, generation: 1, sequence, deviceCapturedAt }), { merge: true });
      return batch.commit();
    };
    const hoursAgo = (h) => Timestamp.fromMillis(Date.now() - h * 3600 * 1000);
    const minutesAgo = (m) => Timestamp.fromMillis(Date.now() - m * 60 * 1000);
    await assertFails(writeFix(1, hoursAgo(24 * 8)));
    const twoHoursAgo = minutesAgo(5);
    await assertSucceeds(writeFix(1, twoHoursAgo));
    await assertFails(writeFix(2, minutesAgo(8)));
    await assertFails(writeFix(2, twoHoursAgo));
    await assertSucceeds(writeFix(2, minutesAgo(1)));
  });

  it('lets the first fix of the next session through after a session whose last fix was ahead of real time', async () => {
    const db = dbFor(users.salesman);
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const first = 'e'.repeat(32);
    const second = 'f'.repeat(32);
    const writeFix = (sessionId, generation, sequence, deviceCapturedAt) => {
      const batch = writeBatch(db);
      const breadcrumb = sessionBreadcrumbPayload({ sessionId, generation, sequence, deviceCapturedAt });
      batch.set(doc(db, 'gps_tracking', breadcrumb.eventId), breadcrumb);
      batch.set(liveRef, trackingFixPayload({ sessionId, generation, sequence, deviceCapturedAt }), { merge: true });
      return batch.commit();
    };
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(first, 1), { merge: true }));
    const ahead = Timestamp.fromMillis(Date.now() + 4 * 60 * 1000);
    await assertSucceeds(writeFix(first, 1, 1, ahead));
    await assertFails(writeFix(first, 1, 2, Timestamp.now()));
    await assertSucceeds(updateDoc(liveRef, {
      workSessionStatus: 'ended',
      status: 'inactive',
      workSessionEndedAt: serverTimestamp(),
    }));
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(second, 2), { merge: true }));
    await assertSucceeds(writeFix(second, 2, 1, Timestamp.now()));
    await assertFails(writeFix(second, 2, 2, Timestamp.fromMillis(Date.now() - 60 * 1000)));
  });

  it('lets the owner clear the company pause end reason when work starts again, and only clear it', async () => {
    const liveRef = doc(dbFor(users.salesman), 'live_tracking', users.salesman.uid);
    const first = '4'.repeat(32);
    const second = '5'.repeat(32);
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(first, 1), { merge: true }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'live_tracking', users.salesman.uid), {
        workSessionStatus: 'ended',
        status: 'inactive',
        workSessionEndedAt: Timestamp.now(),
        endedReason: 'company_paused',
      });
    });
    const restart = (extra) => setDoc(liveRef, { ...workSessionStartFields(second, 2), workSessionEndedAt: deleteField(), ...extra }, { merge: true });
    await assertFails(restart({ endedReason: 'other' }));
    await assertFails(setDoc(doc(dbFor(users.otherSalesman), 'live_tracking', users.salesman.uid),
      { ...workSessionStartFields(second, 2), endedReason: deleteField() }, { merge: true }));
    await assertSucceeds(restart({ endedReason: deleteField() }));
    const stored = await getDoc(liveRef);
    assert.equal(stored.data().endedReason, undefined);
  });

  it('lets an APK 1.0.2 phone start work after a company pause, keeping the end reason unchanged', async () => {
    const liveRef = doc(dbFor(users.salesman), 'live_tracking', users.salesman.uid);
    const first = '4'.repeat(32);
    const second = '5'.repeat(32);
    const third = '6'.repeat(32);
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(first, 1), { merge: true }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'live_tracking', users.salesman.uid), {
        workSessionStatus: 'ended',
        status: 'inactive',
        workSessionEndedAt: Timestamp.now(),
        endedReason: 'company_paused',
      });
    });
    const apk102Restart = (sessionId, generation, extra = {}) => setDoc(liveRef, {
      ...workSessionStartFields(sessionId, generation),
      workSessionEndedAt: deleteField(),
      lastBreadcrumbCapturedAt: deleteField(),
      ...extra,
    }, { merge: true });
    await assertFails(apk102Restart(second, 2, { endedReason: 'other' }));
    await assertSucceeds(apk102Restart(second, 2));
    assert.equal((await getDoc(liveRef)).data().endedReason, 'company_paused');
    await assertSucceeds(updateDoc(liveRef, { workSessionStatus: 'ended', status: 'inactive', workSessionEndedAt: serverTimestamp() }));
    await assertSucceeds(apk102Restart(third, 3, { endedReason: deleteField() }));
    assert.equal((await getDoc(liveRef)).data().endedReason, undefined);
    await assertFails(updateDoc(liveRef, { workSessionStatus: 'ended', status: 'inactive', workSessionEndedAt: serverTimestamp(), endedReason: 'company_paused' }));
  });

  it('refuses a backdated first fix after a restart without an end, and accepts a real-time one', async () => {
    const db = dbFor(users.salesman);
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const writeFix = (sessionId, generation, sequence, deviceCapturedAt) => {
      const batch = writeBatch(db);
      const breadcrumb = sessionBreadcrumbPayload({ sessionId, generation, sequence, deviceCapturedAt });
      batch.set(doc(db, 'gps_tracking', breadcrumb.eventId), breadcrumb);
      batch.set(liveRef, trackingFixPayload({ sessionId, generation, sequence, deviceCapturedAt }), { merge: true });
      return batch.commit();
    };
    const first = '1'.repeat(32);
    const second = '2'.repeat(32);
    const third = '3'.repeat(32);
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(first, 1), { merge: true }));
    await assertSucceeds(writeFix(first, 1, 1, Timestamp.now()));
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(second, 2), { merge: true }));
    await assertFails(writeFix(second, 2, 1, Timestamp.fromMillis(Date.now() - 6 * 24 * 3600 * 1000)));
    await assertFails(writeFix(second, 2, 1, Timestamp.fromMillis(Date.now() - 11 * 60 * 1000)));
    await assertSucceeds(writeFix(second, 2, 1, Timestamp.now()));
    await assertSucceeds(setDoc(liveRef, workSessionStartFields(third, 3), { merge: true }));
    await assertSucceeds(writeFix(third, 3, 1, Timestamp.now()));
  });

  it('accepts the app transaction shape for a first and a later fix without reading the breadcrumb', async () => {
    const db = dbFor(users.salesman);
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const sessionId = 'c'.repeat(32);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(sessionId, 1), { merge: true }),
    );
    const writeFix = (sequence) => runTransaction(db, async (transaction) => {
      await transaction.get(liveRef);
      const deviceCapturedAt = Timestamp.now();
      const breadcrumb = sessionBreadcrumbPayload({
        sessionId,
        generation: 1,
        sequence,
        deviceCapturedAt,
      });
      transaction.set(doc(db, 'gps_tracking', breadcrumb.eventId), breadcrumb);
      transaction.set(
        liveRef,
        trackingFixPayload({
          sessionId,
          generation: 1,
          sequence,
          deviceCapturedAt,
        }),
        { merge: true },
      );
    });
    await assertSucceeds(writeFix(1));
    await assertSucceeds(writeFix(2));
    const stored = await getDoc(liveRef);
    assert.equal(stored.data().lastFixSequence, 2);

    const replay = sessionBreadcrumbPayload({
      sessionId,
      generation: 1,
      sequence: 1,
    });
    await assertFails(setDoc(doc(db, 'gps_tracking', replay.eventId), replay));
  });

  it('keeps a salesman breadcrumb unreadable and unwritable to another user', async () => {
    const owner = dbFor(users.salesman);
    const sessionId = 'e'.repeat(32);
    const liveRef = doc(owner, 'live_tracking', users.salesman.uid);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(sessionId, 1), { merge: true }),
    );
    const deviceCapturedAt = Timestamp.now();
    const breadcrumb = sessionBreadcrumbPayload({
      sessionId,
      generation: 1,
      sequence: 1,
      deviceCapturedAt,
    });
    const batch = writeBatch(owner);
    batch.set(liveRef, trackingFixPayload({
      sessionId,
      generation: 1,
      sequence: 1,
      deviceCapturedAt,
    }), { merge: true });
    batch.set(doc(owner, 'gps_tracking', breadcrumb.eventId), breadcrumb);
    await assertSucceeds(batch.commit());

    const crumbPath = ['gps_tracking', breadcrumb.eventId];
    const other = dbFor(users.otherSalesman);
    await assertFails(getDoc(doc(other, ...crumbPath)));
    await assertFails(setDoc(doc(other, 'gps_tracking',
      `session_${users.salesman.uid}_${sessionId}_9`), {
      ...breadcrumb,
      fixSequence: 9,
      eventId: `session_${users.salesman.uid}_${sessionId}_9`,
    }));
    await assertFails(getDoc(doc(other, 'gps_tracking',
      `session_${users.salesman.uid}_${sessionId}_77`)));
    await assertSucceeds(getDoc(doc(dbFor(users.supervisor), ...crumbPath)));
    await assertSucceeds(getDoc(doc(dbFor(users.admin), ...crumbPath)));
  });

  it('rejects impossible, incomplete, mocked, and malformed tracking evidence', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(doc(db, 'gps_tracking', 'g-impossible'), {
        ...validTrackingPayload(),
        latitude: 999,
        gpsLatitude: 999,
        location: new GeoPoint(89, 110.3593),
      }),
    );
    const incomplete = validTrackingPayload();
    delete incomplete.accuracyMeters;
    await assertFails(setDoc(doc(db, 'gps_tracking', 'g-incomplete'), incomplete));
    await assertFails(
      setDoc(doc(db, 'gps_tracking', 'g-mocked'), {
        ...validTrackingPayload(),
        isMocked: true,
      }),
    );
    await assertFails(
      setDoc(doc(db, 'gps_tracking', 'g-time'), {
        ...validTrackingPayload(),
        timestamp: 'not-a-timestamp',
      }),
    );
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const sessionId = 'b'.repeat(32);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(sessionId, 1), { merge: true }),
    );
    const fix = trackingFixPayload({ sessionId, generation: 1, sequence: 1 });
    await assertSucceeds(setDoc(liveRef, fix, { merge: true }));
    await assertFails(
      setDoc(liveRef, {
        salesmanCode: 'S002',
        branchId: 'B2',
      }, { merge: true }),
    );
    await assertFails(
      setDoc(liveRef, {
        longitude: '110.3593',
      }, { merge: true }),
    );
  });

  it('rejects stale sessions and repeated or out-of-order fix sequences', async () => {
    const db = dbFor(users.salesman);
    const liveRef = doc(db, 'live_tracking', users.salesman.uid);
    const firstSessionId = 'd'.repeat(32);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(firstSessionId, 1), {
        merge: true,
      }),
    );
    await assertSucceeds(
      setDoc(
        liveRef,
        trackingFixPayload({
          sessionId: firstSessionId,
          generation: 1,
          sequence: 1,
        }),
        { merge: true },
      ),
    );
    await assertFails(
      setDoc(
        liveRef,
        trackingFixPayload({
          sessionId: firstSessionId,
          generation: 1,
          sequence: 1,
          latitude: 1.56,
        }),
        { merge: true },
      ),
    );
    await assertFails(
      setDoc(
        liveRef,
        workSessionStartFields('e'.repeat(32), 3),
        { merge: true },
      ),
    );

    const secondSessionId = 'e'.repeat(32);
    await assertSucceeds(
      setDoc(liveRef, workSessionStartFields(secondSessionId, 2), {
        merge: true,
      }),
    );
    await assertFails(
      setDoc(
        liveRef,
        trackingFixPayload({
          sessionId: firstSessionId,
          generation: 1,
          sequence: 2,
        }),
        { merge: true },
      ),
    );
    await assertSucceeds(
      setDoc(
        liveRef,
        trackingFixPayload({
          sessionId: secondSessionId,
          generation: 2,
          sequence: 1,
        }),
        { merge: true },
      ),
    );
    await assertSucceeds(
      updateDoc(liveRef, {
        activeSessionId: secondSessionId,
        activeSessionGeneration: 2,
        lastFixSequence: 1,
        workSessionStatus: 'ended',
        status: 'inactive',
        workSessionEndedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(
        liveRef,
        trackingFixPayload({
          sessionId: secondSessionId,
          generation: 2,
          sequence: 2,
        }),
        { merge: true },
      ),
    );
  });

  it('lets a salesman log its own visit but not read another salesman log', async () => {
    const db = dbFor(users.salesman);
    await assertSucceeds(
      setDoc(doc(db, 'visit_logs', 'vl-own'), {
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        retailerId: 'r1',
      }),
    );
    await assertFails(getDoc(doc(db, 'visit_logs', 'vl-other')));
    await assertFails(deleteDoc(doc(db, 'visit_logs', 'vl-other')));
  });

  it('does not let a salesman take over another salesman visit log', async () => {
    const db = dbFor(users.salesman);
    await assertFails(
      setDoc(doc(db, 'visit_logs', 'vl-other'), {
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        retailerId: 'r1',
      }),
    );
    await assertSucceeds(
      setDoc(
        doc(db, 'visit_logs', 'vl-own-team'),
        { notes: 'follow up' },
        { merge: true },
      ),
    );
  });

  it('requires every identity field of a salesman activity record to name the caller', async () => {
    const db = dbFor(users.salesman);
    const me = users.salesman.uid;
    const other = users.otherSalesman.uid;
    const forged = [
      { submittedByUid: me, salesmanUid: other, salesmanCode: 'S002', branchId: 'B2' },
      { submittedByUid: me, salesmanUid: other },
      { salesmanUid: me, uid: other },
      { salesmanUid: me, userUid: other },
      { salesmanUid: me, createdByUid: other },
      { salesmanUid: me, salesman_uid: other },
      { salesmanUid: me, salesmanCode: 'S002' },
      { salesmanUid: me, salesman_code: 'S002' },
      { salesmanUid: me, salesmanId: 'S002' },
      { salesmanUid: me, salesman_id: 'S002' },
      { salesmanUid: me, staffId: 'S002' },
      { salesmanUid: me, employeeCode: 'S002' },
      { salesmanUid: me, branchId: 'B2' },
      { salesmanUid: me, branch_id: 'B2' },
      { salesmanUid: me, salesmanCode: '' },
      { salesmanCode: 'S001', branchId: 'B1' },
    ];
    const own = [
      { salesmanUid: me, salesmanCode: 'S001', branchId: 'B1' },
      { salesmanUid: me },
      {
        salesmanUid: me, salesman_uid: me, uid: me, userUid: me, submittedByUid: me,
        createdByUid: me, salesmanCode: 'S001', salesman_code: 'S001', salesmanId: 'S001',
        salesman_id: 'S001', staffId: 'S001', employeeCode: 'S001', branchId: 'B1', branch_id: 'B1',
      },
    ];
    for (const collectionName of ['visit_logs', 'notification_logs', 'notifications']) {
      for (const [index, identity] of forged.entries()) {
        await assertFails(
          setDoc(doc(db, collectionName, `forged-${index}`), { ...identity, type: 'arrival' }),
        );
      }
      for (const [index, identity] of own.entries()) {
        await assertSucceeds(
          setDoc(doc(db, collectionName, `own-${index}`), { ...identity, type: 'arrival' }),
        );
      }
    }
    for (const patch of [{ salesmanCode: 'S002' }, { branchId: 'B2' }, { submittedByUid: other }]) {
      await assertFails(setDoc(doc(db, 'visit_logs', 'vl-own-team'), patch, { merge: true }));
    }
  });

  it('lets supervisors and branch managers add only unscoped activity notes', async () => {
    for (const user of [users.supervisor, users.branchManager]) {
      const db = dbFor(user);
      for (const collectionName of ['notification_logs', 'notifications']) {
        await assertSucceeds(setDoc(doc(db, collectionName, `note-${user.uid}`), {
          type: 'admin_update', recipient_user_id: 'admin', message: 'Note',
        }));
        for (const [index, scope] of [
          { salesmanCode: 'S002' }, { branchId: 'B2' }, { salesmanUid: users.otherSalesman.uid },
          { salesmanCode: 'S001' },
        ].entries()) {
          await assertFails(setDoc(doc(db, collectionName, `scoped-${user.uid}-${index}`), {
            type: 'arrival', ...scope,
          }));
        }
      }
    }
    const adminDb = dbFor(users.admin);
    await assertSucceeds(setDoc(doc(adminDb, 'notification_logs', 'admin-scoped'), {
      type: 'arrival', salesmanCode: 'S002', branchId: 'B2',
    }));
  });
});

describe('dashboard role scope', () => {
  it('scopes precise GPS reads to the supervisor team and manager branch', async () => {
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);

    await assertSucceeds(getDoc(doc(supervisorDb, 'gps_tracking', 'g-seed')));
    await assertFails(getDoc(doc(supervisorDb, 'gps_tracking', 'g-other')));
    await assertSucceeds(getDoc(doc(managerDb, 'gps_tracking', 'g-seed')));
    await assertFails(getDoc(doc(managerDb, 'gps_tracking', 'g-other')));
    await assertSucceeds(getDoc(doc(supervisorDb, 'live_tracking', users.salesman.uid)));
    await assertFails(getDoc(doc(supervisorDb, 'live_tracking', users.otherSalesman.uid)));
    await assertSucceeds(getDoc(doc(dbFor(users.admin), 'gps_tracking', 'g-other')));

    await assertSucceeds(getDocs(query(
      collection(supervisorDb, 'gps_tracking'),
      where('salesmanCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'gps_tracking'),
      where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(query(collection(supervisorDb, 'gps_tracking'))));

    await assertSucceeds(getDoc(doc(supervisorDb, 'orders', 'order-team-location')));
    await assertFails(getDoc(doc(supervisorDb, 'orders', 'order-other-location')));
    await assertSucceeds(getDoc(doc(managerDb, 'visit_logs', 'vl-own-team')));
    await assertFails(getDoc(doc(managerDb, 'visit_logs', 'vl-other')));
    await assertSucceeds(getDocs(query(
      collection(supervisorDb, 'orders'),
      where('salesmanCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'visit_logs'),
      where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(query(collection(supervisorDb, 'orders'))));
    await assertFails(getDocs(query(collection(managerDb, 'visit_logs'))));
  });

  it('lets supervisors and branch managers list one retailer\'s orders only with their scope filter', async () => {
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    await assertFails(getDocs(query(
      collection(supervisorDb, 'orders'),
      where('retailerId', '==', 'r1'),
    )));
    await assertFails(getDocs(query(
      collection(managerDb, 'orders'),
      where('retailerId', '==', 'r1'),
    )));
    await assertSucceeds(getDocs(query(
      collection(supervisorDb, 'orders'),
      where('retailerId', '==', 'r1'),
      where('salesmanCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'orders'),
      where('retailerId', '==', 'r1'),
      where('branchId', '==', 'B1'),
    )));
  });

  it('allows the scoped monthly order window reads', async () => {
    const from = Timestamp.fromDate(new Date('2026-09-01T00:00:00Z'));
    const to = Timestamp.fromDate(new Date('2026-11-01T00:00:00Z'));
    const windowed = (db, ...scope) => query(
      collection(db, 'orders'),
      ...scope,
      where('submittedAt', '>=', from),
      where('submittedAt', '<', to),
      orderBy('submittedAt', 'desc'),
      limit(400),
    );
    await assertSucceeds(getDocs(windowed(dbFor(users.admin))));
    await assertSucceeds(getDocs(windowed(
      dbFor(users.supervisor),
      where('salesmanCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(windowed(
      dbFor(users.branchManager),
      where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(windowed(dbFor(users.supervisor))));
  });

  it('allows the scoped visit history range reads and counts, and denies unscoped ones', async () => {
    const at = (iso) => Timestamp.fromDate(new Date(iso));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'visit_logs', 'range-vl-own'), {
        salesmanCode: 'S001', branchId: 'B1', arrivalTime: at('2026-09-10T02:00:00Z'),
      });
      await setDoc(doc(db, 'visit_logs', 'range-vl-own-text-time'), {
        salesmanCode: 'S001', branchId: 'B1', arrivalTime: '2026-09-10 10:00',
      });
      await setDoc(doc(db, 'visit_logs', 'range-vl-other'), {
        salesmanCode: 'S002', branchId: 'B2', arrivalTime: at('2026-09-10T03:00:00Z'),
      });
      await setDoc(doc(db, 'route_stop_progress', 'range-stop-own'), {
        planId: 'range-plan', stopId: 'a', salesmanUid: users.salesman.uid,
        salesmanCode: 'S001', branchId: 'B1', arrivedAt: at('2026-09-10T04:00:00Z'),
      });
      await setDoc(doc(db, 'route_stop_progress', 'range-stop-other'), {
        planId: 'range-plan', stopId: 'b', salesmanUid: users.otherSalesman.uid,
        salesmanCode: 'S002', branchId: 'B2', arrivedAt: at('2026-09-10T04:30:00Z'),
      });
    });
    const from = at('2026-09-01T00:00:00Z');
    const to = at('2026-10-01T00:00:00Z');
    const windowed = (db, collectionName, field, ...scope) => query(
      collection(db, collectionName),
      ...scope,
      where(field, '>=', from),
      where(field, '<', to),
      orderBy(field, 'desc'),
      limit(400),
    );
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    const adminDb = dbFor(users.admin);
    const teamScope = where('salesmanCode', 'in', ['S001']);
    const branchScope = where('branchId', '==', 'B1');

    for (const [collectionName, field, ownId] of [
      ['visit_logs', 'arrivalTime', 'range-vl-own'],
      ['route_stop_progress', 'arrivedAt', 'range-stop-own'],
    ]) {
      const team = await assertSucceeds(getDocs(windowed(supervisorDb, collectionName, field, teamScope)));
      assert.deepEqual(team.docs.map((d) => d.id), [ownId]);
      const branch = await assertSucceeds(getDocs(windowed(managerDb, collectionName, field, branchScope)));
      assert.deepEqual(branch.docs.map((d) => d.id), [ownId]);
      assert.equal((await assertSucceeds(getDocs(windowed(adminDb, collectionName, field)))).size, 2);
      await assertFails(getDocs(windowed(supervisorDb, collectionName, field)));
      await assertFails(getDocs(windowed(managerDb, collectionName, field)));
      await assertFails(getDocs(windowed(supervisorDb, collectionName, field, where('salesmanCode', 'in', ['S002']))));
      await assertFails(getDocs(windowed(managerDb, collectionName, field, where('branchId', '==', 'B2'))));
    }

    const epoch = Timestamp.fromMillis(0);
    const counted = async (db, ...clauses) => (await assertSucceeds(getCountFromServer(
      query(collection(db, 'visit_logs'), ...clauses),
    ))).data().count;
    assert.equal(await counted(supervisorDb, teamScope), 3);
    assert.equal(await counted(supervisorDb, teamScope, where('arrivalTime', '>=', epoch)), 1);
    assert.equal(await counted(managerDb, branchScope), 3);
    assert.equal(await counted(managerDb, branchScope, where('arrivalTime', '>=', epoch)), 1);
    assert.equal(await counted(adminDb), 5);
    await assertFails(getCountFromServer(query(collection(supervisorDb, 'visit_logs'))));
    await assertFails(getCountFromServer(query(collection(managerDb, 'visit_logs'))));
  });

  it('limits supervisor generated reads to assigned salesman codes', async () => {
    const db = dbFor(users.supervisor);
    await assertSucceeds(getDoc(doc(db, 'ai_insights', 'assigned')));
    await assertFails(getDoc(doc(db, 'ai_insights', 'other')));
  });

  it('limits branch-manager generated reads to its branch', async () => {
    const db = dbFor(users.branchManager);
    await assertSucceeds(getDoc(doc(db, 'retailer_segments', 'assigned')));
    await assertFails(getDoc(doc(db, 'retailer_segments', 'other')));
  });

  it('scopes retailer priority rankings to the dashboard route scope', async () => {
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(
      getDoc(doc(supervisorDb, 'retailer_priority_rankings', 'assigned')),
    );
    await assertFails(
      getDoc(doc(supervisorDb, 'retailer_priority_rankings', 'other')),
    );

    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(
      getDoc(doc(managerDb, 'retailer_priority_rankings', 'assigned')),
    );
    await assertFails(
      getDoc(doc(managerDb, 'retailer_priority_rankings', 'other')),
    );

    await assertSucceeds(
      getDoc(doc(dbFor(users.admin), 'retailer_priority_rankings', 'other')),
    );
  });

  it('allows the open-insight badge queries for each dashboard role', async () => {
    const closed = ['resolved', 'dismissed', 'suppressed'];
    const insights = (db) => collection(db, 'ai_insights');
    await assertSucceeds(getDocs(query(
      insights(dbFor(users.admin)),
      where('priority', '==', 'high'),
      where('status', 'not-in', closed),
      limit(100),
    )));
    await assertSucceeds(getDocs(query(
      insights(dbFor(users.admin)),
      where('status', 'not-in', closed),
      limit(200),
    )));
    await assertSucceeds(getDocs(query(
      insights(dbFor(users.branchManager)),
      where('branchId', '==', 'B1'),
      where('status', 'not-in', closed),
      limit(200),
    )));
    await assertSucceeds(getDocs(query(
      insights(dbFor(users.supervisor)),
      where('salesmanCode', '==', 'S001'),
      where('status', 'not-in', closed),
      limit(200),
    )));
    await assertFails(getDocs(query(
      insights(dbFor(users.supervisor)),
      where('salesmanCode', '==', 'S002'),
      where('status', 'not-in', closed),
      limit(200),
    )));
  });

  it('allows the scoped queries the planner issues', async () => {
    const sources = [
      'ai_insights',
      'visit_briefs',
      'retailer_memory',
      'retailer_priority_rankings',
    ];
    const orderedSources = new Set(['ai_insights', 'retailer_priority_rankings']);
    const orderField = {
      ai_insights: 'updatedAt',
      retailer_priority_rankings: 'generatedAt',
    };

    for (const source of sources) {
      const adminQuery = orderedSources.has(source)
        ? query(
            collection(dbFor(users.admin), source),
            orderBy(orderField[source], 'desc'),
            limit(200),
          )
        : query(collection(dbFor(users.admin), source), limit(200));
      await assertSucceeds(getDocs(adminQuery));

      await assertSucceeds(
        getDocs(
          query(
            collection(dbFor(users.supervisor), source),
            where('salesmanCode', 'in', ['S001']),
            limit(200),
          ),
        ),
      );

      await assertSucceeds(
        getDocs(
          query(
            collection(dbFor(users.branchManager), source),
            where('branchId', '==', 'B1'),
            limit(200),
          ),
        ),
      );

      await assertFails(
        getDocs(query(collection(dbFor(users.salesman), source), limit(200))),
      );
    }
  });

  it('never lets the field app read or write a retailer priority ranking', async () => {
    const salesmanDb = dbFor(users.salesman);
    await assertFails(
      getDoc(doc(salesmanDb, 'retailer_priority_rankings', 'assigned')),
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'retailer_priority_rankings', 'forged'), {
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
      }),
    );
    await assertFails(
      updateDoc(doc(salesmanDb, 'retailer_priority_rankings', 'assigned'), {
        chosenCount: 0,
      }),
    );
    await assertFails(
      deleteDoc(doc(salesmanDb, 'retailer_priority_rankings', 'assigned')),
    );
  });

  it('never lets an unauthenticated client touch a retailer priority ranking', async () => {
    const anonDb = unauthContext().firestore();
    await assertFails(
      getDoc(doc(anonDb, 'retailer_priority_rankings', 'assigned')),
    );
    await assertFails(
      setDoc(doc(anonDb, 'retailer_priority_rankings', 'forged'), {
        salesmanCode: 'S001',
      }),
    );
  });

  it('scopes dashboard notifications and excludes salesmen', async () => {
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(
      getDoc(doc(supervisorDb, 'dashboard_notifications', 'team')),
    );
    await assertFails(
      getDoc(doc(supervisorDb, 'dashboard_notifications', 'other-team')),
    );
    await assertFails(
      getDoc(doc(supervisorDb, 'dashboard_notifications', 'admin')),
    );

    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(
      getDoc(doc(managerDb, 'dashboard_notifications', 'team')),
    );
    await assertFails(
      getDoc(doc(managerDb, 'dashboard_notifications', 'other-team')),
    );

    const salesmanDb = dbFor(users.salesman);
    await assertFails(
      getDoc(doc(salesmanDb, 'dashboard_notifications', 'team')),
    );
  });

  it('scopes activity notifications and keeps source rows append-only', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const collectionName of ['notification_logs', 'notifications']) {
        await setDoc(doc(db, collectionName, 'team'), {
          salesmanUid: users.salesman.uid,
          salesmanCode: 'S001',
          branchId: 'B1',
          type: 'arrival',
        });
        await setDoc(doc(db, collectionName, 'other-team'), {
          salesmanUid: users.otherSalesman.uid,
          salesmanCode: 'S002',
          branchId: 'B2',
          type: 'arrival',
        });
        await setDoc(doc(db, collectionName, 'unscoped'), {
          type: 'admin_update',
        });
      }
    });

    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    for (const collectionName of ['notification_logs', 'notifications']) {
      await assertSucceeds(
        getDoc(doc(supervisorDb, collectionName, 'team')),
      );
      await assertFails(
        getDoc(doc(supervisorDb, collectionName, 'other-team')),
      );
      await assertFails(
        getDoc(doc(supervisorDb, collectionName, 'unscoped')),
      );
      await assertSucceeds(
        getDocs(query(
          collection(supervisorDb, collectionName),
          where('salesmanCode', 'in', ['S001']),
        )),
      );
      await assertFails(getDocs(collection(supervisorDb, collectionName)));

      await assertSucceeds(
        getDoc(doc(managerDb, collectionName, 'team')),
      );
      await assertFails(
        getDoc(doc(managerDb, collectionName, 'other-team')),
      );
      await assertFails(
        getDoc(doc(managerDb, collectionName, 'unscoped')),
      );
      await assertSucceeds(
        getDocs(query(
          collection(managerDb, collectionName),
          where('branchId', '==', 'B1'),
        )),
      );
      await assertFails(getDocs(collection(managerDb, collectionName)));

      await assertFails(
        updateDoc(doc(supervisorDb, collectionName, 'team'), { read: true }),
      );
      await assertFails(
        updateDoc(doc(managerDb, collectionName, 'team'), { read: true }),
      );
      await assertFails(
        updateDoc(doc(dbFor(users.admin), collectionName, 'team'), {
          read: true,
        }),
      );
    }
  });

  it('denies dashboard notifications and summaries to suspended dashboard roles', async () => {
    await assertFails(
      getDoc(doc(
        dbFor(users.suspendedSupervisor),
        'dashboard_notifications',
        'team',
      )),
    );
    await assertFails(
      getDoc(doc(
        dbFor(users.suspendedBranchManager),
        'dashboard_notifications',
        'team',
      )),
    );
    await assertFails(
      getDoc(doc(
        dbFor(users.suspendedSupervisor),
        'weekly_ai_summaries',
        'salesman-S001',
      )),
    );
    await assertFails(
      getDoc(doc(
        dbFor(users.suspendedBranchManager),
        'weekly_ai_summaries',
        'branch-B1',
      )),
    );
  });

  it('requires scoped notification queries for supervisor and branch roles', async () => {
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(
      getDocs(
        query(
          collection(supervisorDb, 'dashboard_notifications'),
          where('roleTarget', '==', 'supervisor'),
          where('salesmanCode', 'in', ['S001']),
        ),
      ),
    );
    await assertFails(
      getDocs(collection(supervisorDb, 'dashboard_notifications')),
    );

    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(
      getDocs(
        query(
          collection(managerDb, 'dashboard_notifications'),
          where('roleTarget', 'in', ['supervisor', 'branch_manager']),
          where('branchId', '==', 'B1'),
        ),
      ),
    );
    await assertFails(
      getDocs(collection(managerDb, 'dashboard_notifications')),
    );
  });

  it('scopes special-request reads and queries to the viewer hierarchy', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'special_requests', 'sr-own'), specialRequest());
      await setDoc(
        doc(db, 'special_requests', 'sr-other'),
        specialRequest({
          salesmanCode: 'S002',
          branchId: 'B2',
          createdByUid: users.otherSalesman.uid,
          lastActorUid: users.otherSalesman.uid,
        }),
      );
    });

    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    const salesmanDb = dbFor(users.salesman);
    await assertSucceeds(getDoc(doc(supervisorDb, 'special_requests', 'sr-own')));
    await assertFails(getDoc(doc(supervisorDb, 'special_requests', 'sr-other')));
    await assertSucceeds(getDoc(doc(managerDb, 'special_requests', 'sr-own')));
    await assertFails(getDoc(doc(managerDb, 'special_requests', 'sr-other')));
    await assertSucceeds(getDoc(doc(salesmanDb, 'special_requests', 'sr-own')));
    await assertFails(getDoc(doc(salesmanDb, 'special_requests', 'sr-other')));
    await assertSucceeds(getDoc(doc(dbFor(users.admin), 'special_requests', 'sr-other')));

    await assertSucceeds(getDocs(query(
      collection(supervisorDb, 'special_requests'),
      where('salesmanCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'special_requests'),
      where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(query(collection(supervisorDb, 'special_requests'))));
    await assertFails(getDocs(query(collection(managerDb, 'special_requests'))));
  });

  const srDecision = (status, actor, role, overrides = {}) => ({
    status,
    approvalStep: status === 'approved' ? 'Approved' : 'Rejected',
    lastActorUid: actor.uid,
    lastActorRole: role,
    lastActionAt: serverTimestamp(),
    updatedAt: serverTimestamp(),
    ...overrides,
  });
  const seedSr = async (id, overrides = {}) => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'special_requests', id),
        specialRequest(overrides),
      );
    });
  };

  it('lets a supervisor decide a team request directly, once (single decision)', async () => {
    await seedSr('sr-sup-approve');
    await seedSr('sr-sup-reject');
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-sup-approve'),
      srDecision('approved', users.supervisor, 'supervisor'),
    ));
    await assertSucceeds(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-sup-reject'),
      srDecision('rejected', users.supervisor, 'supervisor'),
    ));
    for (const db of [supervisorDb, dbFor(users.admin)]) {
      await assertFails(updateDoc(
        doc(db, 'special_requests', 'sr-sup-approve'),
        srDecision('rejected', users.supervisor, 'supervisor'),
      ));
      await assertFails(updateDoc(doc(db, 'special_requests', 'sr-sup-reject'), {
        status: 'pending_supervisor',
        approvalStep: 'Supervisor',
        lastActorUid: users.supervisor.uid,
        lastActorRole: 'supervisor',
        lastActionAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }));
    }
  });

  it('lets only a developer delete a special request', async () => {
    await seedSr('sr-delete-admin');
    await assertFails(deleteDoc(doc(dbFor(users.admin), 'special_requests', 'sr-delete-admin')));
    await assertFails(deleteDoc(doc(dbFor(users.supervisor), 'special_requests', 'sr-delete-admin')));
    await assertFails(deleteDoc(doc(dbFor(users.salesman), 'special_requests', 'sr-delete-admin')));

    const developer = { uid: 'special-request-delete-developer' };
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'users', developer.uid), {
        role: 'developer',
        status: 'active',
      });
    });
    await assertSucceeds(deleteDoc(doc(dbFor(developer), 'special_requests', 'sr-delete-admin')));
  });

  it('lets admin and developer decide any open special request directly', async () => {
    const steps = {
      pending_supervisor: 'Supervisor',
      pending_branch_manager: 'Branch Manager',
      pending_admin: 'Admin',
    };
    for (const [status, approvalStep] of Object.entries(steps)) {
      await seedSr(`sr-admin-${status}-a`, { status, approvalStep });
      await seedSr(`sr-admin-${status}-r`, { status, approvalStep });
      await assertSucceeds(updateDoc(
        doc(dbFor(users.admin), 'special_requests', `sr-admin-${status}-a`),
        srDecision('approved', users.admin, 'admin'),
      ));
      await assertSucceeds(updateDoc(
        doc(dbFor(users.admin), 'special_requests', `sr-admin-${status}-r`),
        srDecision('rejected', users.admin, 'admin'),
      ));
    }
  });

  it('denies branch-manager decisions and any forwarding step', async () => {
    await seedSr('sr-bm');
    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(getDoc(doc(managerDb, 'special_requests', 'sr-bm')));
    await assertFails(updateDoc(
      doc(managerDb, 'special_requests', 'sr-bm'),
      srDecision('approved', users.branchManager, 'branch_manager'),
    ));
    await assertFails(updateDoc(
      doc(managerDb, 'special_requests', 'sr-bm'),
      srDecision('rejected', users.branchManager, 'branch_manager'),
    ));
    await seedSr('sr-bm-stage', {
      status: 'pending_branch_manager',
      approvalStep: 'Branch Manager',
    });
    await assertFails(updateDoc(doc(managerDb, 'special_requests', 'sr-bm-stage'), {
      status: 'pending_admin',
      approvalStep: 'Admin',
      lastActorUid: users.branchManager.uid,
      lastActorRole: 'branch_manager',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(
      doc(managerDb, 'special_requests', 'sr-bm-stage'),
      srDecision('approved', users.branchManager, 'branch_manager'),
    ));
    await assertFails(deleteDoc(doc(managerDb, 'special_requests', 'sr-bm')));
  });

  it('denies supervisor forwarding, other-team, self-created and admin-stage decisions', async () => {
    await seedSr('sr-other-scope', {
      salesmanCode: 'S002',
      branchId: 'B2',
      createdByUid: users.otherSalesman.uid,
      lastActorUid: users.otherSalesman.uid,
    });
    await seedSr('sr-own-scope');
    await seedSr('sr-self', {
      createdByUid: users.supervisor.uid,
      createdByRole: 'supervisor',
      lastActorUid: users.supervisor.uid,
      lastActorRole: 'supervisor',
    });
    await seedSr('sr-admin-stage', { status: 'pending_admin', approvalStep: 'Admin' });
    const supervisorDb = dbFor(users.supervisor);

    for (const [status, approvalStep] of [
      ['pending_branch_manager', 'Branch Manager'],
      ['pending_admin', 'Admin'],
    ]) {
      await assertFails(updateDoc(doc(supervisorDb, 'special_requests', 'sr-own-scope'), {
        status,
        approvalStep,
        lastActorUid: users.supervisor.uid,
        lastActorRole: 'supervisor',
        lastActionAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }));
    }
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-other-scope'),
      srDecision('approved', users.supervisor, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-self'),
      srDecision('approved', users.supervisor, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-self'),
      srDecision('rejected', users.supervisor, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-admin-stage'),
      srDecision('approved', users.supervisor, 'supervisor'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-own-scope'),
      srDecision('approved', users.admin, 'admin'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-own-scope'),
      srDecision('approved', users.supervisor, 'admin'),
    ));
    await assertFails(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-own-scope'),
      srDecision('approved', users.supervisor, 'supervisor', { approvalStep: 'Rejected' }),
    ));
    await assertSucceeds(updateDoc(
      doc(supervisorDb, 'special_requests', 'sr-own-scope'),
      srDecision('approved', users.supervisor, 'supervisor'),
    ));
  });

  it('keeps special-request identity immutable and terminal decisions final', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'special_requests', 'sr-terminal'),
        specialRequest({
          status: 'pending_admin',
          approvalStep: 'Admin',
        }),
      );
    });

    const adminDb = dbFor(users.admin);
    const requestRef = doc(adminDb, 'special_requests', 'sr-terminal');
    await assertFails(updateDoc(requestRef, {
      reason: 'Forged reason',
      status: 'approved',
      approvalStep: 'Approved',
      lastActorUid: users.admin.uid,
      lastActorRole: 'admin',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertSucceeds(updateDoc(requestRef, {
      status: 'approved',
      approvalStep: 'Approved',
      lastActorUid: users.admin.uid,
      lastActorRole: 'admin',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(requestRef, {
      status: 'rejected',
      approvalStep: 'Rejected',
      lastActorUid: users.admin.uid,
      lastActorRole: 'admin',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
    await assertFails(updateDoc(requestRef, {
      status: 'pending_supervisor',
      approvalStep: 'Supervisor',
      lastActorUid: users.admin.uid,
      lastActorRole: 'admin',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
  });

  it('requires scoped, server-bound fields and role-specific start status on create', async () => {
    const created = (actor, role, overrides = {}) => specialRequest({
      createdByUid: actor.uid,
      createdByRole: role,
      lastActorUid: actor.uid,
      lastActorRole: role,
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastActionAt: serverTimestamp(),
      ...overrides,
    });
    const toAdmin = { status: 'pending_admin', approvalStep: 'Admin' };

    await assertSucceeds(setDoc(
      doc(dbFor(users.supervisor), 'special_requests', 'sr-created'),
      created(users.supervisor, 'supervisor', toAdmin),
    ));
    await assertSucceeds(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-admin-created'),
      created(users.admin, 'admin', toAdmin),
    ));
    await assertFails(setDoc(
      doc(dbFor(users.supervisor), 'special_requests', 'sr-sup-wrong-status'),
      created(users.supervisor, 'supervisor'),
    ));
    await assertFails(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-admin-wrong-status'),
      created(users.admin, 'admin'),
    ));
    await assertSucceeds(setDoc(
      doc(dbFor(users.salesman), 'special_requests', 'sr-sales-created'),
      created(users.salesman, 'salesman'),
    ));
    await assertFails(setDoc(
      doc(dbFor(users.salesman), 'special_requests', 'sr-sales-wrong-status'),
      created(users.salesman, 'salesman', toAdmin),
    ));
    for (const [id, overrides] of [
      ['sr-bm-a', {}],
      ['sr-bm-b', toAdmin],
      ['sr-forged-branch', { branchId: 'B2' }],
    ]) {
      await assertFails(setDoc(
        doc(dbFor(users.branchManager), 'special_requests', id),
        created(users.branchManager, 'branch_manager', overrides),
      ));
    }
  });

  it('lets a salesman attach a special request only to their own order (FR-APR04)', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'orders', 'ord-own'), { salesmanUid: users.salesman.uid });
      await setDoc(doc(db, 'orders', 'ord-other'), { salesmanUid: users.otherSalesman.uid });
    });
    const salesmanDb = dbFor(users.salesman);
    const mine = (overrides = {}) => specialRequest({
      orderId: 'ord-own',
      requestType: 'urgent_delivery',
      createdAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastActionAt: serverTimestamp(),
      ...overrides,
    });

    await assertSucceeds(setDoc(doc(salesmanDb, 'special_requests', 'ord-own'), mine()));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-foreign-order'),
      mine({ orderId: 'ord-other' }),
    ));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-missing-order'),
      mine({ orderId: 'ord-missing' }),
    ));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-forged-uid'),
      mine({ createdByUid: users.otherSalesman.uid, lastActorUid: users.otherSalesman.uid }),
    ));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-forged-code'),
      mine({ salesmanCode: 'S002' }),
    ));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-bad-status'),
      mine({ status: 'approved', approvalStep: 'Approved' }),
    ));
    await assertFails(setDoc(
      doc(salesmanDb, 'special_requests', 'sr-bad-type'),
      mine({ requestType: 'free_gift' }),
    ));
    await assertFails(updateDoc(doc(salesmanDb, 'special_requests', 'ord-own'), {
      reason: 'changed',
    }));
    await assertFails(deleteDoc(doc(salesmanDb, 'special_requests', 'ord-own')));
  });

  it('allows an admin-only, one-way upgrade of a legacy request', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'special_requests', 'sr-legacy'), {
        retailerName: 'Legacy Retailer',
        requestedItem: 'Legacy Item',
        reason: 'Imported before scoped approvals.',
        status: 'pending_supervisor',
        approvalStep: 'Supervisor',
        createdAt: Timestamp.fromDate(new Date('2026-06-01T00:00:00Z')),
        updatedAt: Timestamp.fromDate(new Date('2026-06-01T00:00:00Z')),
      });
    });

    const upgraded = specialRequest({
      retailerName: 'Legacy Retailer',
      requestedItem: 'Legacy Item',
      reason: 'Imported before scoped approvals.',
      createdByUid: users.admin.uid,
      createdByRole: 'admin',
      salesmanCode: 'S001',
      branchId: 'B1',
      status: 'pending_supervisor',
      approvalStep: 'Supervisor',
      lastActorUid: users.admin.uid,
      lastActorRole: 'admin',
      createdAt: Timestamp.fromDate(new Date('2026-06-01T00:00:00Z')),
      updatedAt: serverTimestamp(),
      lastActionAt: serverTimestamp(),
    });
    await assertSucceeds(
      setDoc(doc(dbFor(users.admin), 'special_requests', 'sr-legacy'), upgraded),
    );
    await assertFails(
      updateDoc(doc(dbFor(users.admin), 'special_requests', 'sr-legacy'), {
        requestedItem: 'Rewritten after upgrade',
        updatedAt: serverTimestamp(),
      }),
    );
    await assertSucceeds(
      updateDoc(
        doc(dbFor(users.supervisor), 'special_requests', 'sr-legacy'),
        srDecision('approved', users.supervisor, 'supervisor'),
      ),
    );
  });

  it('binds missing legacy identity/time and never reopens terminal rows', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'special_requests', 'sr-no-time'), {
        retailerName: 'No Time Retailer',
        requestedItem: 'No Time Item',
        reason: '',
        status: 'pending_supervisor',
        approvalStep: 'Supervisor',
      });
      await setDoc(doc(db, 'special_requests', 'sr-partial-creator'), {
        retailerName: 'Partial Retailer',
        requestedItem: 'Partial Item',
        reason: '',
        createdByRole: 'salesman',
        status: 'pending_supervisor',
        approvalStep: 'Supervisor',
        createdAt: Timestamp.fromDate(new Date('2026-06-02T00:00:00Z')),
      });
      await setDoc(doc(db, 'special_requests', 'sr-terminal-legacy'), {
        retailerName: 'Terminal Retailer',
        requestedItem: 'Terminal Item',
        reason: '',
        status: 'approved',
        approvalStep: 'Approved',
      });
    });

    await assertFails(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-no-time'),
      specialRequest({
        retailerName: 'No Time Retailer',
        requestedItem: 'No Time Item',
        createdByUid: users.admin.uid,
        createdByRole: 'admin',
        lastActorUid: users.admin.uid,
        lastActorRole: 'admin',
        createdAt: Timestamp.fromDate(new Date('2026-01-01T00:00:00Z')),
        updatedAt: serverTimestamp(),
        lastActionAt: serverTimestamp(),
      }),
    ));
    await assertSucceeds(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-no-time'),
      specialRequest({
        retailerName: 'No Time Retailer',
        requestedItem: 'No Time Item',
        createdByUid: users.admin.uid,
        createdByRole: 'admin',
        salesmanCode: 'S001',
        branchId: 'B1',
        lastActorUid: users.admin.uid,
        lastActorRole: 'admin',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastActionAt: serverTimestamp(),
      }),
    ));

    await assertFails(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-partial-creator'),
      specialRequest({
        retailerName: 'Partial Retailer',
        requestedItem: 'Partial Item',
        createdByUid: users.admin.uid,
        createdByRole: 'salesman',
        lastActorUid: users.admin.uid,
        lastActorRole: 'admin',
        createdAt: Timestamp.fromDate(new Date('2026-06-02T00:00:00Z')),
        updatedAt: serverTimestamp(),
        lastActionAt: serverTimestamp(),
      }),
    ));
    await assertSucceeds(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-partial-creator'),
      specialRequest({
        retailerName: 'Partial Retailer',
        requestedItem: 'Partial Item',
        createdByUid: users.admin.uid,
        createdByRole: 'admin',
        lastActorUid: users.admin.uid,
        lastActorRole: 'admin',
        createdAt: Timestamp.fromDate(new Date('2026-06-02T00:00:00Z')),
        updatedAt: serverTimestamp(),
        lastActionAt: serverTimestamp(),
      }),
    ));

    await assertFails(setDoc(
      doc(dbFor(users.admin), 'special_requests', 'sr-terminal-legacy'),
      specialRequest({
        retailerName: 'Terminal Retailer',
        requestedItem: 'Terminal Item',
        createdByUid: users.admin.uid,
        createdByRole: 'admin',
        lastActorUid: users.admin.uid,
        lastActorRole: 'admin',
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastActionAt: serverTimestamp(),
      }),
    ));
  });
});

describe('publication keys and catch-all', () => {
  it('scopes publication keys to the dashboard role team or branch', async () => {
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(
      getDoc(
        doc(supervisorDb, 'route_plan_publication_keys', 'S001_20260615'),
      ),
    );
    await assertFails(
      getDoc(
        doc(supervisorDb, 'route_plan_publication_keys', 'S002_20260615'),
      ),
    );
    await assertFails(
      updateDoc(
        doc(supervisorDb, 'route_plan_publication_keys', 'S002_20260615'),
        {
          active: false,
          updatedByUid: users.supervisor.uid,
          updatedAt: serverTimestamp(),
        },
      ),
    );
  });

  it('allows a scoped supervisor to reserve only its own route key', async () => {
    const supervisorDb = dbFor(users.supervisor);
    const ownKey = users.salesman.uid + '_20260615';
    await assertSucceeds(
      setDoc(
        doc(
          supervisorDb,
          'route_plan_publication_keys',
          ownKey,
        ),
        {
          keyId: ownKey,
          planId: 'route-own',
          salesmanIdentity: users.salesman.uid,
          weekKey: '20260615',
          active: true,
          updatedByUid: users.supervisor.uid,
          updatedAt: serverTimestamp(),
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(
          supervisorDb,
          'route_plan_publication_keys',
          'S002_20260622',
        ),
        {
          keyId: 'S002_20260622',
          planId: 'route-other',
          salesmanIdentity: 'S002',
          weekKey: '20260622',
          active: true,
          updatedByUid: users.supervisor.uid,
          updatedAt: serverTimestamp(),
        },
      ),
    );
  });

  it('allows an admin to archive a published route through the valid transition', async () => {
    const adminDb = dbFor(users.admin);
    await assertSucceeds(
      updateDoc(doc(adminDb, 'route_plans', 'route-own'), {
        status: 'archived',
        updatedAt: serverTimestamp(),
      }),
    );
  });

  it('denies unknown collection writes', async () => {
    const adminDb = dbFor(users.admin);
    await assertFails(
      setDoc(doc(adminDb, 'unknown_collection', 'record'), { value: true }),
    );
  });
});

describe('linked caller expression budget', () => {
  it('[gps-backlog-budget] accepts an offline backlog crumb from a linked caller', async () => {
    await linkSalesman();
    const session = 'b'.repeat(32);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'live_tracking', users.salesman.uid), {
        ...workSessionStartFields(session, 1),
        ...trackingFixPayload({
          sessionId: session,
          generation: 1,
          sequence: 10,
          deviceCapturedAt: Timestamp.fromMillis(Date.now() - 1000),
        }),
        workSessionStartedAt: Timestamp.fromMillis(Date.now() - 3600 * 1000),
      });
    });
    const crumb = {
      ...sessionBreadcrumbPayload({
        sessionId: session,
        generation: 1,
        sequence: 4,
        deviceCapturedAt: Timestamp.fromMillis(Date.now() - 60000),
      }),
      backlog: true,
      userUid: users.salesman.uid,
      submittedByUid: users.salesman.uid,
      salesmanId: 'S001',
      staffId: 'S001',
      employeeCode: 'S001',
      salesman_code: 'S001',
      salesmanName: 'Sales One',
      salesmanEmail: 'sales@example.test',
      submittedByName: 'Sales One',
      submittedByEmail: 'sales@example.test',
      locationSource: 'foreground_tracking',
    };
    await assertSucceeds(
      setDoc(doc(dbFor(users.salesman), 'gps_tracking', crumb.eventId), crumb),
    );
  });
});

describe('Android assigned-route arrival expression budget', () => {
  it('[android-route-arrival-budget] accepts all three recovery skips with the Android QA legacy caller', async () => {
    const uid = 'android-arrival-qa-sales-uid01';
    const email = 'android-arrival-sales@example.test';
    const planId = 'route-arrival-acceptance-e2e';
    const progressId = `${planId}_${uid}`;
    const sessionId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const now = Timestamp.now();
    const today = new Date();
    today.setUTCHours(0, 0, 0, 0);
    const weekStart = Timestamp.fromMillis(today.getTime() - 86400000);
    const weekEnd = Timestamp.fromMillis(weekStart.toMillis() + 6 * 86400000);
    const retailers = [
      { id: 'arrival-retailer-a', stopId: 'arrival-stop-a', lat: 1.5562, lng: 110.3562, coordinateStatus: 'verified' },
      { id: 'arrival-retailer-b', stopId: 'arrival-stop-b', lat: 1.5535, lng: 110.3593, coordinateStatus: 'verified' },
      { id: 'arrival-retailer-c', stopId: 'arrival-stop-c', lat: 1.5513, lng: 110.3621, coordinateStatus: 'candidate' },
    ];
    const stopIds = retailers.map((retailer) => retailer.stopId);
    const profile = {
      uid, userUid: uid, role: 'salesman', user_group: 'salesman',
      status: 'active', employeeCode: 'S001', userId: 'S001',
      branchId: 'B1', branch_id: 'B1', gpsAutofill: false,
    };
    const access = {
      uid, userDocId: email, role: 'salesman', user_group: 'salesman',
      status: 'active', employeeCode: 'S001', userId: 'S001',
      branchId: 'B1', branch_id: 'B1',
    };
    const plan = {
      planId, createdByUid: 'local-emulator-fixture', salesmanUid: uid,
      salesmanCode: 'S001', salesmanName: 'QA Salesperson', branchId: 'B1',
      weekStart, weekEnd, publishedAt: now, status: 'published',
      source: 'dashboard', optimisationMethod: 'haversine', totalStops: 3,
      stopIds,
      stopRetailerIds: Object.fromEntries(retailers.map((r) => [r.stopId, r.id])),
      days: [{
        dayId: 'arrival-day-1', dayLabel: 'Today',
        date: Timestamp.fromDate(today), totalDistanceKm: 1,
        estimateSource: 'haversine',
        stops: retailers.map((retailer, index) => ({
          stopId: retailer.stopId, dayId: 'arrival-day-1',
          retailerId: retailer.id, retailerName: `QA Arrival Retailer ${'ABC'[index]}`,
          address: 'Synthetic local arrival fixture', lat: retailer.lat, lng: retailer.lng,
          retailerCoordinateSnapshot: {
            latitude: retailer.lat, longitude: retailer.lng,
            coordinateStatus: retailer.coordinateStatus,
            coordinateSource: retailer.coordinateStatus === 'verified' ? 'admin_review' : 'imported',
            coordinateRevision: `fixture-${retailer.stopId}-${retailer.coordinateStatus === 'verified' ? 'verified' : 'candidate'}-v1`,
            ...(retailer.coordinateStatus === 'verified' ? { verifiedAt: now } : {}),
          },
          sequence: index + 1,
          estimatedArrival: `${10 + index}:45`, estimatedDeparture: `${10 + index}:55`,
          priorityReason: 'Synthetic local arrival acceptance fixture', status: 'not_started',
          travelMinutesFromPrevious: index === 0 ? 0 : 10,
          legDistanceKm: index === 0 ? 0 : 0.5,
        })),
      }],
    };
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', email), profile);
      await setDoc(doc(db, 'user_access', uid), access);
      await setDoc(doc(db, 'route_plans', planId), plan);
      await setDoc(doc(db, 'live_tracking', uid), {
        uid, activeSessionId: sessionId, activeSessionGeneration: 1,
        lastFixSequence: 0, workSessionStatus: 'active', status: 'active',
        trackingMode: 'battery_saver', appliedControlRevision: 0,
      });
    });

    const context = testEnv.authenticatedContext(uid, {
      email, email_verified: false, firebase: { sign_in_provider: 'password' },
    });
    support.trackContext(context);
    const db = context.firestore();
    const parentRef = doc(db, 'route_plan_progress', progressId);
    const baseProgress = {
      progressId, planId, salesmanUid: uid, salesmanCode: 'S001',
      branchId: 'B1', isOfflineCreated: false,
    };
    await assertSucceeds(setDoc(parentRef, {
      ...baseProgress, status: 'accepted', stopProgress: {}, handledStopIds: [],
      acceptedAt: serverTimestamp(), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
    }, { merge: true }));
    await assertSucceeds(setDoc(parentRef, {
      ...baseProgress, status: 'in_progress', routeSessionState: 'active',
      startedAt: serverTimestamp(), updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
    }, { merge: true }));
    await assertSucceeds(setDoc(parentRef, {
      selectedStopId: stopIds[1], selectionRevision: increment(1),
      updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
    }, { merge: true }));
    const publishedBefore = (await assertSucceeds(getDoc(doc(db, 'route_plans', planId)))).data();

    const eventId = `${sessionId}_${stopIds[0]}_skipped`;
    const stopRef = doc(db, 'route_stop_progress', `${progressId}_${stopIds[0]}`);
    const canonicalPayload = {
      lifecycleSchemaVersion: 2, planId, salesmanUid: uid, salesmanCode: 'S001',
      branchId: 'B1', stopId: stopIds[0], retailerId: retailers[0].id,
      retailerName: 'QA Arrival Retailer A', status: 'skipped', eventId,
      workSessionId: sessionId, workSessionGeneration: 1, sessionEventSequence: 1,
      deviceOccurredAt: now, receivedAt: serverTimestamp(), updatedAt: serverTimestamp(),
      skippedAt: now, skipReason: 'retailer_closed',
    };
    const parentPayload = {
      ...baseProgress, status: 'in_progress',
      lastStopWriteStopId: stopIds[0], lastStopWriteStatus: 'skipped',
      lastStopWriteEventId: eventId, lastStopWriteWorkSessionGeneration: 1,
      lastStopWriteSequence: 1, updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
      lastStopId: stopIds[0], lastStopStatus: 'skipped', lastStopEventId: eventId,
      lastSummaryWorkSessionGeneration: 1, lastSummaryEventSequence: 1,
      handledStopIds: arrayUnion(stopIds[0]),
    };
    function commitSkip(parentOverrides = {}, stopPayload = canonicalPayload) {
      const batch = writeBatch(db);
      batch.set(doc(db, 'route_stop_progress', `${progressId}_${stopPayload.stopId}`), stopPayload);
      batch.set(parentRef, { ...parentPayload, ...parentOverrides }, { merge: true });
      return batch.commit();
    }
    const parentBeforeAttacks = (await assertSucceeds(getDoc(parentRef))).data();
    for (const [field, replacement] of [
      ['progressId', `${progressId}-forged`],
      ['planId', `${planId}-forged`],
      ['salesmanUid', users.otherSalesman.uid],
    ]) {
      await assertFails(commitSkip({ [field]: replacement }));
      assert.deepEqual(
        (await assertSucceeds(getDoc(parentRef))).data(), parentBeforeAttacks,
        `${field} tampering must not change the parent`,
      );
      assert.equal(
        (await assertSucceeds(getDoc(stopRef))).exists(), false,
        `${field} tampering must not create the canonical stop`,
      );
    }
    await assertSucceeds(commitSkip());

    const parent = (await assertSucceeds(getDoc(parentRef))).data();
    const canonical = (await assertSucceeds(getDoc(stopRef))).data();
    assert.equal(canonical.status, 'skipped');
    assert.equal(canonical.eventId, eventId);
    assert.equal(canonical.workSessionId, sessionId);
    assert.equal(canonical.sessionEventSequence, 1);
    assert.equal(canonical.skipReason, 'retailer_closed');
    assert.ok(canonical.receivedAt.isEqual(parent.updatedAt));
    assert.deepEqual(parent.handledStopIds, [stopIds[0]]);
    assert.equal(parent.status, 'in_progress');
    assert.equal(parent.routeSessionState, 'active');
    assert.equal(parent.selectedStopId, stopIds[1]);
    assert.equal(parent.selectionRevision, 1);
    assert.equal(parent.lastStopWriteEventId, eventId);
    assert.equal(parent.lastStopId, stopIds[0]);
    assert.equal(parent.lastStopStatus, 'skipped');
    assert.equal(parent.lastSummaryEventSequence, 1);

    for (const index of [1, 2]) {
      const stopId = stopIds[index];
      const sequence = index + 1;
      const nextEventId = `${sessionId}_${stopId}_skipped`;
      const occurredAt = Timestamp.now();
      const finalStop = index === 2;
      await assert.doesNotReject(() => assertSucceeds(commitSkip({
        status: finalStop ? 'completed' : 'in_progress',
        lastStopWriteStopId: stopId, lastStopWriteEventId: nextEventId,
        lastStopWriteSequence: sequence, lastStopId: stopId,
        lastStopEventId: nextEventId, lastSummaryEventSequence: sequence,
        handledStopIds: arrayUnion(stopId),
        ...(finalStop
          ? {
            routeSessionState: 'completed',
            selectedStopId: deleteField(), selectionRevision: 4,
          }
          : { selectedStopId: deleteField(), selectionRevision: 2 }),
      }, {
        ...canonicalPayload, stopId, retailerId: retailers[index].id,
        retailerName: `QA Arrival Retailer ${'ABC'[index]}`,
        eventId: nextEventId, sessionEventSequence: sequence,
        deviceOccurredAt: occurredAt, skippedAt: occurredAt,
      })), `Android recovery skip ${stopId}, sequence ${sequence}, must succeed`);

      const nextParent = (await assertSucceeds(getDoc(parentRef))).data();
      const nextCanonical = (await assertSucceeds(getDoc(
        doc(db, 'route_stop_progress', `${progressId}_${stopId}`),
      ))).data();
      assert.equal(nextCanonical.status, 'skipped');
      assert.equal(nextCanonical.eventId, nextEventId);
      assert.equal(nextCanonical.workSessionId, sessionId);
      assert.equal(nextCanonical.sessionEventSequence, sequence);
      assert.equal(nextCanonical.skipReason, 'retailer_closed');
      assert.ok(nextCanonical.receivedAt.isEqual(nextParent.updatedAt));
      assert.deepEqual(nextParent.handledStopIds, stopIds.slice(0, sequence));
      assert.equal(nextParent.status, finalStop ? 'completed' : 'in_progress');
      assert.equal(nextParent.routeSessionState, finalStop ? 'completed' : 'active');
      assert.equal(Object.hasOwn(nextParent, 'selectedStopId'), false);
      assert.equal(nextParent.selectionRevision, finalStop ? 4 : 2);
      assert.equal(nextParent.lastStopWriteEventId, nextEventId);
      assert.equal(nextParent.lastStopWriteSequence, sequence);
      assert.equal(nextParent.lastStopId, stopId);
      assert.equal(nextParent.lastStopStatus, 'skipped');
      assert.equal(nextParent.lastSummaryEventSequence, sequence);

      if (!finalStop) {
        await assertSucceeds(setDoc(parentRef, {
          selectedStopId: stopIds[2], selectionRevision: increment(1),
          updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp(),
        }, { merge: true }));
        const selectedFinal = (await assertSucceeds(getDoc(parentRef))).data();
        assert.equal(selectedFinal.selectedStopId, stopIds[2]);
        assert.equal(selectedFinal.selectionRevision, 3);
        assert.equal(selectedFinal.status, 'in_progress');
        assert.equal(selectedFinal.routeSessionState, 'active');
      }
    }
    assert.deepEqual((await assertSucceeds(getDoc(doc(db, 'route_plans', planId)))).data(), publishedBefore);
  });

  it('[android-route-gps-completion-budget] completes a GPS-arrived selected stop at sequence 2', async () => {
    const uid = 'android-arrival-qa-sales-uid01';
    const email = 'android-arrival-sales@example.test';
    const planId = 'route-arrival-acceptance-e2e';
    const progressId = `${planId}_${uid}`;
    const sessionId = 'a1b2c3d4e5f60718293a4b5c6d7e8f90';
    const now = Timestamp.now();
    const today = new Date();
    today.setUTCHours(0, 0, 0, 0);
    const weekStart = Timestamp.fromMillis(today.getTime() - 86400000);
    const weekEnd = Timestamp.fromMillis(weekStart.toMillis() + 6 * 86400000);
    const retailers = [
      { id: 'arrival-retailer-a', stopId: 'arrival-stop-a', lat: 1.5562, lng: 110.3562, coordinateStatus: 'verified' },
      { id: 'arrival-retailer-b', stopId: 'arrival-stop-b', lat: 1.5535, lng: 110.3593, coordinateStatus: 'verified' },
      { id: 'arrival-retailer-c', stopId: 'arrival-stop-c', lat: 1.5513, lng: 110.3621, coordinateStatus: 'candidate' },
    ];
    const stopIds = retailers.map((retailer) => retailer.stopId);
    const profile = {
      uid, userUid: uid, role: 'salesman', user_group: 'salesman',
      status: 'active', employeeCode: 'S001', userId: 'S001',
      branchId: 'B1', branch_id: 'B1', gpsAutofill: false,
    };
    const access = {
      uid, userDocId: email, role: 'salesman', user_group: 'salesman',
      status: 'active', employeeCode: 'S001', userId: 'S001',
      branchId: 'B1', branch_id: 'B1',
    };
    const plan = {
      planId, createdByUid: 'local-emulator-fixture', salesmanUid: uid,
      salesmanCode: 'S001', salesmanName: 'QA Salesperson', branchId: 'B1',
      weekStart, weekEnd, publishedAt: now, status: 'published',
      source: 'dashboard', optimisationMethod: 'haversine', totalStops: 3,
      stopIds,
      stopRetailerIds: Object.fromEntries(retailers.map((r) => [r.stopId, r.id])),
      days: [{
        dayId: 'arrival-day-1', dayLabel: 'Today', date: Timestamp.fromDate(today),
        totalDistanceKm: 1, estimateSource: 'haversine',
        stops: retailers.map((retailer, index) => ({
          stopId: retailer.stopId, dayId: 'arrival-day-1',
          retailerId: retailer.id, retailerName: `QA Arrival Retailer ${'ABC'[index]}`,
          address: 'Synthetic local arrival fixture', lat: retailer.lat, lng: retailer.lng,
          retailerCoordinateSnapshot: {
            latitude: retailer.lat, longitude: retailer.lng,
            coordinateStatus: retailer.coordinateStatus,
            coordinateSource: retailer.coordinateStatus === 'verified' ? 'admin_review' : 'imported',
            coordinateRevision: `fixture-${retailer.stopId}-${retailer.coordinateStatus === 'verified' ? 'verified' : 'candidate'}-v1`,
            ...(retailer.coordinateStatus === 'verified' ? { verifiedAt: now } : {}),
          },
          sequence: index + 1, estimatedArrival: `${10 + index}:45`,
          estimatedDeparture: `${10 + index}:55`,
          priorityReason: 'Synthetic local arrival acceptance fixture',
          status: 'not_started', travelMinutesFromPrevious: index === 0 ? 0 : 10,
          legDistanceKm: index === 0 ? 0 : 0.5,
        })),
      }],
    };

    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, 'users', email), profile);
      await setDoc(doc(adminDb, 'user_access', uid), access);
      await setDoc(doc(adminDb, 'route_plans', planId), plan);
      await setDoc(doc(adminDb, 'live_tracking', uid), {
        uid, activeSessionId: sessionId, activeSessionGeneration: 1,
        lastFixSequence: 0, workSessionStatus: 'active', status: 'active',
        trackingMode: 'battery_saver', appliedControlRevision: 0,
      });
      for (const retailer of retailers) {
        await setDoc(doc(adminDb, 'retailers', retailer.id), {
          retailerId: retailer.id, branchId: 'B1',
          latitude: retailer.lat, longitude: retailer.lng,
          coordinateStatus: retailer.coordinateStatus,
          coordinateSource: retailer.coordinateStatus === 'verified' ? 'admin_review' : 'imported',
        });
      }
    });

    const context = testEnv.authenticatedContext(uid, {
      email, email_verified: false, firebase: { sign_in_provider: 'password' },
    });
    support.trackContext(context);
    const db = context.firestore();
    const parentRef = await createSelectedRouteProgress(db, {
      planId, uid, salesmanCode: 'S001', branchId: 'B1',
      selectedStopId: retailers[1].stopId, routeSessionState: 'active',
    });
    const baseProgress = {
      progressId, planId, salesmanUid: uid, salesmanCode: 'S001',
      branchId: 'B1', isOfflineCreated: false,
    };
    const publishedBefore = (await assertSucceeds(
      getDoc(doc(db, 'route_plans', planId)),
    )).data();
    const publishedRouteTimestamp = publishedBefore.publishedAt;
    const selectedParent = (await assertSucceeds(getDoc(parentRef))).data();
    assert.equal(selectedParent.status, 'in_progress');
    assert.equal(selectedParent.routeSessionState, 'active');
    assert.equal(selectedParent.selectedStopId, retailers[1].stopId);
    assert.equal(selectedParent.selectionRevision, 1);

    const stop = retailers[1];
    const arrivalDeviceOccurredAt = Timestamp.now();
    const coordinateCheckedAt = Timestamp.now();
    const coordinateRevision = `fixture-${stop.stopId}-verified-v1`;
    const arrivalEventId = `${sessionId}_${stop.stopId}_arrived`;
    const arrival = {
      planId, salesmanUid: uid, salesmanCode: 'S001', branchId: 'B1',
      stopId: stop.stopId, retailerId: stop.id,
      retailerName: 'QA Arrival Retailer B', lifecycleSchemaVersion: 2,
      status: 'arrived', eventId: arrivalEventId, workSessionId: sessionId,
      workSessionGeneration: 1, sessionEventSequence: 1,
      deviceOccurredAt: arrivalDeviceOccurredAt,
      receivedAt: serverTimestamp(), updatedAt: serverTimestamp(),
      arrivedAt: arrivalDeviceOccurredAt, arrivalEventId,
      arrivalWorkSessionId: sessionId, arrivalWorkSessionGeneration: 1,
      arrivalSessionEventSequence: 1,
      arrivalDeviceOccurredAt: arrivalDeviceOccurredAt,
      arrivalReceivedAt: serverTimestamp(), arrivalMode: 'location_verified',
      arrivalLatitude: stop.lat, arrivalLongitude: stop.lng,
      arrivalAccuracyMeters: 25,
      arrivalDeviceCapturedAt: arrivalDeviceOccurredAt,
      arrivalIsMocked: false,
      arrivalDistanceMeters: 0,
      retailerCoordinateRevision: coordinateRevision,
      retailerCoordinateSource: 'admin_review',
      coordinateReferenceMode: 'current_retailer', coordinateCheckedAt,
      coordinateSnapshotAt: publishedRouteTimestamp,
    };

    async function commitAppProjection(event) {
      const parent = (await getDoc(parentRef)).data();
      const patch = v2StopParentProjection(parent, event, stopIds);
      const batch = writeBatch(db);
      batch.set(
        doc(db, 'route_stop_progress', `${progressId}_${event.stopId}`),
        event,
      );
      batch.set(parentRef, { ...baseProgress, ...patch }, { merge: true });
      await batch.commit();
    }

    await assertSucceeds(commitAppProjection(arrival));
    const stopRef = doc(
      db, 'route_stop_progress', `${progressId}_${stop.stopId}`,
    );
    const acceptedArrival = (await assertSucceeds(getDoc(stopRef))).data();
    const parentAfterArrival = (await assertSucceeds(getDoc(parentRef))).data();
    assert.equal(acceptedArrival.status, 'arrived');
    assert.equal(acceptedArrival.eventId, arrivalEventId);
    assert.equal(acceptedArrival.sessionEventSequence, 1);
    assert.equal(acceptedArrival.arrivalAccuracyMeters, 25);
    assert.equal(acceptedArrival.arrivalDistanceMeters, 0);
    assert.equal(parentAfterArrival.lastStopWriteEventId, arrivalEventId);
    assert.equal(parentAfterArrival.lastSummaryEventSequence, 1);
    assert.equal(parentAfterArrival.selectedStopId, stop.stopId);
    assert.equal(parentAfterArrival.selectionRevision, 1);
    assert.deepEqual(parentAfterArrival.handledStopIds, []);

    const completedAt = Timestamp.now();
    const completionEventId = `${sessionId}_${stop.stopId}_completed`;
    const completion = {
      ...acceptedArrival,
      status: 'completed', eventId: completionEventId,
      sessionEventSequence: 2, deviceOccurredAt: completedAt,
      receivedAt: serverTimestamp(), updatedAt: serverTimestamp(),
      completedAt,
    };
    await assertSucceeds(commitAppProjection(completion));

    const completed = (await assertSucceeds(getDoc(stopRef))).data();
    const parentAfterCompletion = (await assertSucceeds(getDoc(parentRef))).data();
    assert.equal(completed.status, 'completed');
    assert.equal(completed.eventId, completionEventId);
    assert.equal(completed.workSessionId, sessionId);
    assert.equal(completed.workSessionGeneration, 1);
    assert.equal(completed.sessionEventSequence, 2);
    assert.ok(completed.deviceOccurredAt.isEqual(completedAt));
    assert.ok(completed.completedAt.isEqual(completedAt));
    for (const field of [
      'arrivalEventId', 'arrivalWorkSessionId', 'arrivalWorkSessionGeneration',
      'arrivalSessionEventSequence', 'arrivalMode', 'arrivalLatitude',
      'arrivalLongitude', 'arrivalAccuracyMeters', 'arrivalIsMocked',
      'arrivalDistanceMeters', 'retailerCoordinateRevision',
      'retailerCoordinateSource', 'coordinateReferenceMode',
    ]) {
      assert.deepEqual(completed[field], acceptedArrival[field], `${field} must persist`);
    }
    for (const field of [
      'arrivedAt', 'arrivalDeviceOccurredAt', 'arrivalReceivedAt',
      'arrivalDeviceCapturedAt', 'coordinateCheckedAt',
    ]) {
      assert.ok(completed[field].isEqual(acceptedArrival[field]), `${field} must persist`);
    }
    assert.ok(completed.coordinateSnapshotAt.isEqual(publishedRouteTimestamp));
    assert.ok(completed.coordinateSnapshotAt.isEqual(acceptedArrival.coordinateSnapshotAt));
    assert.equal(parentAfterCompletion.status, 'in_progress');
    assert.equal(parentAfterCompletion.routeSessionState, 'active');
    assert.deepEqual(parentAfterCompletion.handledStopIds, [stop.stopId]);
    assert.equal(Object.hasOwn(parentAfterCompletion, 'selectedStopId'), false);
    assert.equal(parentAfterCompletion.selectionRevision, 2);
    assert.equal(parentAfterCompletion.lastStopWriteStopId, stop.stopId);
    assert.equal(parentAfterCompletion.lastStopWriteStatus, 'completed');
    assert.equal(parentAfterCompletion.lastStopWriteEventId, completionEventId);
    assert.equal(parentAfterCompletion.lastStopWriteWorkSessionGeneration, 1);
    assert.equal(parentAfterCompletion.lastStopWriteSequence, 2);
    assert.equal(parentAfterCompletion.lastStopId, stop.stopId);
    assert.equal(parentAfterCompletion.lastStopStatus, 'completed');
    assert.equal(parentAfterCompletion.lastStopEventId, completionEventId);
    assert.equal(parentAfterCompletion.lastSummaryWorkSessionGeneration, 1);
    assert.equal(parentAfterCompletion.lastSummaryEventSequence, 2);
    for (const unhandledStop of [retailers[0], retailers[2]]) {
      assert.equal((await assertSucceeds(getDoc(doc(
        db, 'route_stop_progress', `${progressId}_${unhandledStop.stopId}`,
      )))).exists(), false);
      assert.equal(parentAfterCompletion.handledStopIds.includes(unhandledStop.stopId), false);
    }
    assert.deepEqual(
      (await assertSucceeds(getDoc(doc(db, 'route_plans', planId)))).data(),
      publishedBefore,
    );
  });


});

describe('route workflow lifecycle', () => {
  const PLAN_ID = 'route-lifecycle';
  const PROGRESS_ID = `${PLAN_ID}_${users.salesman.uid}`;

  const planFor = (db) => doc(db, 'route_plans', PLAN_ID);
  const progressFor = (db) =>
    doc(db, 'route_plan_progress', PROGRESS_ID);

  function draftPlan() {
    return {
      planId: PLAN_ID,
      createdByUid: users.admin.uid,
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      weekStart: Timestamp.fromDate(new Date('2026-06-22T00:00:00Z')),
      status: 'draft',
      stopIds: ['stop-1'],
      stopRetailerIds: { 'stop-1': 'retailer-1' },
      totalStops: 1,
    };
  }

  function canonicalProgress() {
    return {
      progressId: PROGRESS_ID,
      planId: PLAN_ID,
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      isOfflineCreated: false,
      status: 'accepted',
      stopProgress: {},
      handledStopIds: [],
      acceptedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
      lastSyncedAt: serverTimestamp(),
    };
  }

  it('advances draft -> approved -> published and gates mobile read/progress on publish', async () => {
    const adminDb = dbFor(users.admin);
    const salesmanDb = dbFor(users.salesman);
    const otherDb = dbFor(users.otherSalesman);

    await assertSucceeds(setDoc(planFor(adminDb), draftPlan()));

    await assertFails(getDoc(planFor(salesmanDb)));
    await assertFails(setDoc(progressFor(salesmanDb), canonicalProgress()));

    await assertSucceeds(
      updateDoc(planFor(adminDb), {
        status: 'approved',
        updatedAt: serverTimestamp(),
      }),
    );
    await assertFails(getDoc(planFor(salesmanDb)));

    const keyId = users.salesman.uid + '_20260622';
    const publish = writeBatch(adminDb);
    publish.update(planFor(adminDb), {
      status: 'published',
      publicationKeyId: keyId,
      updatedAt: serverTimestamp(),
    });
    publish.set(doc(adminDb, 'route_plan_publication_keys', keyId), {
      keyId,
      planId: PLAN_ID,
      salesmanIdentity: users.salesman.uid,
      weekKey: '20260622',
      active: true,
      updatedByUid: users.admin.uid,
    });
    await assertSucceeds(publish.commit());

    await assertSucceeds(getDoc(planFor(salesmanDb)));
    await assertFails(getDoc(planFor(otherDb)));
    await assertFails(
      updateDoc(planFor(salesmanDb), {
        status: 'archived',
        updatedAt: serverTimestamp(),
      }),
    );

    await assertSucceeds(setDoc(progressFor(salesmanDb), canonicalProgress()));
    await assertSucceeds(
      updateDoc(progressFor(salesmanDb), {
        status: 'in_progress',
        startedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
  });

  it('allows a salesman to select only a pending stop on its published route', async () => {
    const salesmanDb = dbFor(users.salesman);
    const otherDb = dbFor(users.otherSalesman);

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
        stopIds: ['stop-1', 'stop-2', 'stop-3'],
        stopRetailerIds: {
          'stop-1': 'retailer-1',
          'stop-2': 'retailer-2',
          'stop-3': 'retailer-3',
        },
        totalStops: 3,
      });
    });

    const routeBefore = (await getDoc(planFor(salesmanDb))).data();
    await assertSucceeds(
      setDoc(progressFor(salesmanDb), {
        progressId: PROGRESS_ID,
        planId: PLAN_ID,
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        isOfflineCreated: false,
        status: 'assigned',
        stopProgress: {},
        handledStopIds: [],
        selectedStopId: 'stop-2',
        selectionRevision: 1,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );

    await assertSucceeds(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'stop-1',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    const progress = (await getDoc(progressFor(salesmanDb))).data();
    if (progress.selectedStopId !== 'stop-1' || progress.selectionRevision !== 2) {
      throw new Error('selection change did not increment its revision');
    }
    if (progress.status !== 'assigned') {
      throw new Error('selecting a stop implicitly accepted the route');
    }
    if (Object.hasOwn(progress, 'lastStopId')) {
      throw new Error('selecting a stop changed transition history');
    }

    await assertFails(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'stop-1',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'not-in-route',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );

    await assertSucceeds(
      updateDoc(progressFor(salesmanDb), {
        status: 'accepted',
        acceptedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    const acceptedProgress = (await getDoc(progressFor(salesmanDb))).data();
    if (
      acceptedProgress.selectedStopId !== 'stop-1' ||
      acceptedProgress.selectionRevision !== 2
    ) {
      throw new Error('accepting the route changed the selected destination');
    }

    await assertSucceeds(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: deleteField(),
        selectionRevision: 3,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    const clearedProgress = (await getDoc(progressFor(salesmanDb))).data();
    if (
      Object.hasOwn(clearedProgress, 'selectedStopId') ||
      clearedProgress.selectionRevision !== 3
    ) {
      throw new Error('clearing the destination did not advance its revision');
    }

    await assertSucceeds(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'stop-2',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: deleteField(),
        selectionRevision: 3,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    const newerSelection = (await getDoc(progressFor(salesmanDb))).data();
    if (
      newerSelection.selectedStopId !== 'stop-2' ||
      newerSelection.selectionRevision !== 4
    ) {
      throw new Error('a stale clear erased a newer destination');
    }

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(
          context.firestore(),
          'route_stop_progress',
          `${PLAN_ID}_${users.salesman.uid}_stop-1`,
        ),
        { status: 'completed' },
      );
    });
    await assertFails(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'stop-1',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(progressFor(context.firestore()), {
        stopProgress: { 'stop-3': { status: 'completed' } },
        handledStopIds: ['stop-3'],
      });
    });
    await assertFails(
      updateDoc(progressFor(salesmanDb), {
        selectedStopId: 'stop-3',
        selectionRevision: increment(1),
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );

    await assertFails(
      setDoc(
        doc(
          otherDb,
          'route_plan_progress',
          `${PLAN_ID}_${users.otherSalesman.uid}`,
        ),
        {
          progressId: `${PLAN_ID}_${users.otherSalesman.uid}`,
          planId: PLAN_ID,
          salesmanUid: users.otherSalesman.uid,
          salesmanCode: 'S002',
          branchId: 'B2',
          isOfflineCreated: false,
          status: 'assigned',
          stopProgress: {},
          handledStopIds: [],
          selectedStopId: 'stop-2',
          selectionRevision: 1,
          updatedAt: serverTimestamp(),
          lastSyncedAt: serverTimestamp(),
        },
      ),
    );

    const routeAfter = (await getDoc(planFor(salesmanDb))).data();
    assert.deepEqual(routeAfter, routeBefore);
  });

  it('scopes user-profile reads because profiles can contain last-known GPS', async () => {
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    const salesmanDb = dbFor(users.salesman);

    await assertSucceeds(getDoc(doc(salesmanDb, 'users', users.salesman.uid)));
    await assertSucceeds(getDoc(doc(salesmanDb, 'users', 'legacy-sales-doc')));
    await assertSucceeds(getDocs(query(
      collection(salesmanDb, 'users'),
      where('uid', '==', users.salesman.uid),
    )));
    await assertFails(getDoc(doc(salesmanDb, 'users', users.otherSalesman.uid)));
    await assertSucceeds(getDoc(doc(supervisorDb, 'users', users.salesman.uid)));
    await assertFails(getDoc(doc(supervisorDb, 'users', users.otherSalesman.uid)));
    await assertSucceeds(getDoc(doc(managerDb, 'users', users.salesman.uid)));
    await assertFails(getDoc(doc(managerDb, 'users', users.otherSalesman.uid)));
    await assertSucceeds(getDoc(doc(dbFor(users.admin), 'users', users.otherSalesman.uid)));

    await assertSucceeds(getDocs(query(
      collection(supervisorDb, 'users'),
      where('employeeCode', 'in', ['S001']),
    )));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'users'),
      where('branchId', '==', 'B1'),
      where('role', '==', 'salesman'),
    )));
    await assertFails(getDocs(query(
      collection(managerDb, 'users'),
      where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(query(collection(supervisorDb, 'users'))));
  });

  it('rejects direct in-progress or completed progress creation', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
      });
    });
    const salesmanDb = dbFor(users.salesman);

    await assertFails(
      setDoc(progressFor(salesmanDb), {
        ...canonicalProgress(),
        status: 'in_progress',
        startedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(progressFor(salesmanDb), {
        ...canonicalProgress(),
        startedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(progressFor(salesmanDb), {
        ...canonicalProgress(),
        status: 'completed',
        completedAt: serverTimestamp(),
      }),
    );
    await assertFails(
      setDoc(progressFor(salesmanDb), {
        ...canonicalProgress(),
        stopProgress: {
          stop1: { status: 'completed' },
        },
      }),
    );
  });

  it('rejects progress writes to a non-canonical or forged document', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
      });
    });
    const salesmanDb = dbFor(users.salesman);

    await assertSucceeds(
      setDoc(doc(salesmanDb, 'route_plan_progress', PROGRESS_ID), canonicalProgress()),
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'route_plan_progress', 'route-lifecycle_wrong'), canonicalProgress()),
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'route_plan_progress', `${PLAN_ID}_${users.otherSalesman.uid}`), {
        ...canonicalProgress(),
        progressId: `${PLAN_ID}_${users.otherSalesman.uid}`,
        salesmanUid: users.otherSalesman.uid,
      }),
    );
  });

  it('keeps the work of a salesperson on a route the manager replaced, for that salesperson only', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), { ...draftPlan(), status: 'published' });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();
    const arrival = v2ManualArrival({ planId: PLAN_ID, stopId: 'stop-1', retailerId: 'retailer-1' });
    await assertSucceeds(commitV2StopEvent(salesmanDb, parentRef, arrival, ['stop-1']));
    const stopRef = doc(salesmanDb, 'route_stop_progress', `${PLAN_ID}_${users.salesman.uid}_stop-1`);
    const acceptedArrival = (await getDoc(stopRef)).data();

    await assertSucceeds(
      updateDoc(doc(dbFor(users.admin), 'route_plans', PLAN_ID), {
        status: 'archived',
        replacedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
    const otherDb = dbFor(users.otherSalesman);
    await assertFails(getDoc(doc(otherDb, 'route_plans', PLAN_ID)));
    await assertFails(
      commitV2StopEvent(
        otherDb,
        doc(otherDb, 'route_plan_progress', `${PLAN_ID}_${users.otherSalesman.uid}`),
        v2ManualArrival({ planId: PLAN_ID, stopId: 'stop-1', retailerId: 'retailer-1' }),
        ['stop-1'],
      ),
    );

    await assertSucceeds(getDoc(doc(salesmanDb, 'route_plans', PLAN_ID)));
    await assertSucceeds(
      commitV2StopEvent(salesmanDb, parentRef, v2TerminalStopEvent(acceptedArrival, 'completed', 2), ['stop-1']),
    );
    const seenByManager = await assertSucceeds(getDoc(doc(dbFor(users.supervisor), 'route_stop_progress', stopRef.id)));
    assert.equal(seenByManager.data().status, 'completed');

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', PLAN_ID), { replacedAt: deleteField() });
    });
    await assertFails(getDoc(doc(salesmanDb, 'route_plans', PLAN_ID)));
  });

  it('closes a replaced route to new starts and after 24 hours, and refuses replacedAt on create', async () => {
    const adminDb = dbFor(users.admin);
    await assertFails(
      setDoc(doc(adminDb, 'route_plans', 'planted'), {
        ...draftPlan(),
        planId: 'planted',
        createdByUid: users.admin.uid,
        replacedAt: serverTimestamp(),
        createdAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }),
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), { ...draftPlan(), status: 'published' });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();
    await assertSucceeds(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2ManualArrival({ planId: PLAN_ID, stopId: 'stop-1', retailerId: 'retailer-1' }),
        ['stop-1'],
      ),
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'route_plans', 'never-started'), {
        ...draftPlan(),
        planId: 'never-started',
        status: 'archived',
        replacedAt: Timestamp.now(),
      });
      await updateDoc(doc(db, 'route_plans', PLAN_ID), {
        status: 'archived',
        replacedAt: Timestamp.fromMillis(Date.now() - 60 * 60 * 1000),
      });
    });
    await assertFails(
      setDoc(doc(salesmanDb, 'route_plan_progress', `never-started_${users.salesman.uid}`), {
        ...canonicalProgress(),
        planId: 'never-started',
        progressId: `never-started_${users.salesman.uid}`,
      }),
    );
    await assertSucceeds(getDoc(doc(salesmanDb, 'route_plans', PLAN_ID)));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        replacedAt: Timestamp.fromMillis(Date.now() - 25 * 60 * 60 * 1000),
      });
    });
    await assertFails(getDoc(doc(salesmanDb, 'route_plans', PLAN_ID)));
    await assertFails(
      updateDoc(parentRef, { selectedStopId: 'stop-2', updatedAt: serverTimestamp(), lastSyncedAt: serverTimestamp() }),
    );
  });

  it('completes a stop whose arrival is recorded in its own per-stop document', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
      });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();
    const arrival = v2ManualArrival({
      planId: PLAN_ID,
      stopId: 'stop-1',
      retailerId: 'retailer-1',
    });
    await assertSucceeds(
      commitV2StopEvent(salesmanDb, parentRef, arrival, ['stop-1']),
    );
    const acceptedArrival = (
      await getDoc(doc(
        salesmanDb,
        'route_stop_progress',
        `${PLAN_ID}_${users.salesman.uid}_stop-1`,
      ))
    ).data();
    const completion = v2TerminalStopEvent(
      acceptedArrival,
      'completed',
      2,
    );
    await assertSucceeds(
      commitV2StopEvent(salesmanDb, parentRef, completion, ['stop-1']),
    );

    const completedStop = (
      await getDoc(doc(
        salesmanDb,
        'route_stop_progress',
        `${PLAN_ID}_${users.salesman.uid}_stop-1`,
      ))
    ).data();
    const progress = (await getDoc(parentRef)).data();
    assert.equal(completedStop.status, 'completed');
    assert.equal(completedStop.skipReason, undefined);
    assert.equal(completedStop.arrivalEventId, acceptedArrival.arrivalEventId);
    assert.equal(
      completedStop.arrivalDeviceOccurredAt.isEqual(
        acceptedArrival.arrivalDeviceOccurredAt,
      ),
      true,
    );
    assert.deepEqual(progress.handledStopIds, ['stop-1']);
    assert.equal(progress.status, 'completed');
    assert.equal(Object.hasOwn(progress, 'selectedStopId'), false);

    const replay = {
      ...completedStop,
      receivedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
    await assertSucceeds(
      commitV2StopEvent(salesmanDb, parentRef, replay, ['stop-1']),
    );
    const afterReplay = (await getDoc(parentRef)).data();
    assert.equal(afterReplay.lastStopEventId, progress.lastStopEventId);
    assert.equal(afterReplay.lastSummaryEventSequence, 2);
    assert.deepEqual(afterReplay.handledStopIds, ['stop-1']);
    assert.equal(Object.hasOwn(afterReplay, 'selectedStopId'), false);
    await assertFails(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2TerminalStopEvent(completedStop, 'skipped', 3),
        ['stop-1'],
      ),
    );
  });

  it('skips a stop whose arrival is recorded in its own per-stop document', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
        stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' },
        totalStops: 2,
      });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-2',
    });
    await seedRouteStopWorkSession();
    const arrival = v2ManualArrival({
      planId: PLAN_ID,
      stopId: 'stop-2',
      retailerId: 'retailer-2',
    });
    await assertSucceeds(
      commitV2StopEvent(salesmanDb, parentRef, arrival, ['stop-1', 'stop-2']),
    );
    const acceptedArrival = (
      await getDoc(doc(
        salesmanDb,
        'route_stop_progress',
        `${PLAN_ID}_${users.salesman.uid}_stop-2`,
      ))
    ).data();
    const skippedStop = v2TerminalStopEvent(acceptedArrival, 'skipped', 2);
    await assertSucceeds(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        skippedStop,
        ['stop-1', 'stop-2'],
      ),
    );

    const skipped = (
      await getDoc(doc(
        salesmanDb,
        'route_stop_progress',
        `${PLAN_ID}_${users.salesman.uid}_stop-2`,
      ))
    ).data();
    const progress = (await getDoc(parentRef)).data();
    assert.equal(skipped.status, 'skipped');
    assert.equal(skipped.skipReason, 'retailer_closed');
    assert.equal(skipped.arrivalEventId, acceptedArrival.arrivalEventId);
    assert.equal(
      skipped.arrivalDeviceOccurredAt.isEqual(
        acceptedArrival.arrivalDeviceOccurredAt,
      ),
      true,
    );
    assert.deepEqual(progress.handledStopIds, ['stop-2']);
    assert.equal(progress.status, 'in_progress');
    assert.equal(Object.hasOwn(progress, 'selectedStopId'), false);
  });

  async function startLiveSessionRoute(routeSessionState, stopIds) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
        stopIds,
        stopRetailerIds: Object.fromEntries(
          stopIds.map((id, i) => [id, `retailer-${i + 1}`]),
        ),
        totalStops: stopIds.length,
      });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: stopIds[0],
      routeSessionState,
    });
    await seedRouteStopWorkSession();
    const arrival = v2ManualArrival({
      planId: PLAN_ID,
      stopId: stopIds[0],
      retailerId: 'retailer-1',
    });
    await assertSucceeds(commitV2StopEvent(salesmanDb, parentRef, arrival, stopIds));
    const acceptedArrival = (
      await getDoc(doc(
        salesmanDb,
        'route_stop_progress',
        `${PLAN_ID}_${users.salesman.uid}_${stopIds[0]}`,
      ))
    ).data();
    return { salesmanDb, parentRef, acceptedArrival };
  }

  it('[route-stop-handled-integrity] rejects corrupt handled-stop projections atomically', async () => {
    const stopIds = ['stop-1', 'stop-2', 'stop-3', 'stop-4'];
    const { salesmanDb, parentRef, acceptedArrival } =
      await startLiveSessionRoute('active', stopIds);
    const baselineParent = (await getDoc(parentRef)).data();
    const stopRef = doc(
      salesmanDb,
      'route_stop_progress',
      `${PLAN_ID}_${users.salesman.uid}_stop-1`,
    );
    const terminal = v2TerminalStopEvent(acceptedArrival, 'completed', 2);
    const attacks = [
      {
        name: 'duplicate historical handled entries',
        oldHandled: ['stop-2', 'stop-2'],
        newHandled: ['stop-2', 'stop-2', 'stop-1'],
      },
      {
        name: 'outside-route handled entry',
        oldHandled: ['outside-stop'],
        newHandled: ['outside-stop', 'stop-1'],
      },
      {
        name: 'dropped prior handled stop',
        oldHandled: ['stop-2', 'stop-3'],
        newHandled: ['stop-1', 'stop-2', 'stop-4'],
      },
      {
        name: 'excess handled-stop advancement',
        oldHandled: [],
        newHandled: ['stop-1', 'stop-2'],
      },
    ];

    for (const attack of attacks) {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await setDoc(doc(context.firestore(), 'route_plan_progress', PROGRESS_ID), {
          ...baselineParent,
          handledStopIds: attack.oldHandled,
        });
      });
      const parentBefore = (await getDoc(parentRef)).data();
      const stopBefore = (await getDoc(stopRef)).data();
      await assertFails(commitV2StopEvent(
        salesmanDb,
        parentRef,
        terminal,
        stopIds,
        (patch) => ({ ...patch, handledStopIds: attack.newHandled }),
      ), attack.name);
      assert.deepEqual((await getDoc(parentRef)).data(), parentBefore, attack.name);
      assert.deepEqual((await getDoc(stopRef)).data(), stopBefore, attack.name);
    }

    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'route_plan_progress', PROGRESS_ID),
        baselineParent,
      );
    });
    await assertSucceeds(commitV2StopEvent(
      salesmanDb, parentRef, terminal, stopIds,
    ));
    const finalParent = (await getDoc(parentRef)).data();
    const finalStop = (await getDoc(stopRef)).data();
    assert.deepEqual(finalParent.handledStopIds, ['stop-1']);
    assert.equal(finalParent.status, 'in_progress');
    assert.equal(finalParent.routeSessionState, 'active');
    assert.equal(finalParent.lastSummaryEventSequence, 2);
    assert.equal(Object.hasOwn(finalParent, 'selectedStopId'), false);
    assert.equal(finalParent.selectionRevision, 2);
    assert.equal(finalStop.status, 'completed');
    assert.equal(finalStop.eventId, terminal.eventId);
  });

  for (const session of ['active', 'paused']) {
    for (const terminalStatus of ['completed', 'skipped']) {
    it(`closes a ${session} session with the final ${terminalStatus} stop`, async () => {
      const { salesmanDb, parentRef, acceptedArrival } =
        await startLiveSessionRoute(session, ['stop-1']);
      assert.equal((await getDoc(parentRef)).data().routeSessionState, session);
      await assertSucceeds(
        commitV2StopEvent(
          salesmanDb,
          parentRef,
          v2TerminalStopEvent(acceptedArrival, terminalStatus, 2),
          ['stop-1'],
        ),
      );
      const progress = (await getDoc(parentRef)).data();
      assert.equal(progress.status, 'completed');
      assert.equal(progress.routeSessionState, 'completed');
      assert.deepEqual(progress.handledStopIds, ['stop-1']);
    });
    }
  }

  it('rejects a session change carried by a stop write once the parent is already completed', async () => {
    const { salesmanDb, parentRef, acceptedArrival } =
      await startLiveSessionRoute('active', ['stop-1']);
    await assertSucceeds(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2TerminalStopEvent(acceptedArrival, 'completed', 2),
        ['stop-1'],
      ),
    );
    assert.equal((await getDoc(parentRef)).data().status, 'completed');
    const terminal = (await getDoc(doc(
      salesmanDb, 'route_stop_progress', `${PLAN_ID}_${users.salesman.uid}_stop-1`,
    ))).data();
    const replay = { ...terminal, receivedAt: serverTimestamp(), updatedAt: serverTimestamp() };
    await assertSucceeds(commitV2StopEvent(salesmanDb, parentRef, replay, ['stop-1']));
    for (const session of ['active', 'paused', 'untracked']) {
      await assertFails(commitV2StopEvent(
        salesmanDb, parentRef, replay, ['stop-1'],
        (patch) => ({ ...patch, routeSessionState: session }),
      ));
      assert.equal((await getDoc(parentRef)).data().routeSessionState, 'completed');
    }
  });

  it('rejects a session change on a non-final terminal stop', async () => {
    const stopIds = ['stop-1', 'stop-2'];
    const { salesmanDb, parentRef, acceptedArrival } =
      await startLiveSessionRoute('active', stopIds);
    await assertFails(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2TerminalStopEvent(acceptedArrival, 'completed', 2),
        stopIds,
        (patch) => ({ ...patch, routeSessionState: 'completed' }),
      ),
    );
    await assertSucceeds(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2TerminalStopEvent(acceptedArrival, 'completed', 2),
        stopIds,
      ),
    );
    assert.equal((await getDoc(parentRef)).data().routeSessionState, 'active');
  });

  it('rejects the final stop when the active session is left open', async () => {
    const { salesmanDb, parentRef, acceptedArrival } =
      await startLiveSessionRoute('active', ['stop-1']);
    await assertFails(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        v2TerminalStopEvent(acceptedArrival, 'completed', 2),
        ['stop-1'],
        (patch) => {
          const { routeSessionState, ...rest } = patch;
          return rest;
        },
      ),
    );
  });

  it('rejects a session change carried by an arrival write', async () => {
    const stopIds = ['stop-1', 'stop-2'];
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftPlan(),
        status: 'published',
        stopIds,
        stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' },
        totalStops: 2,
      });
    });
    const salesmanDb = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(salesmanDb, {
      planId: PLAN_ID,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
      routeSessionState: 'active',
    });
    await seedRouteStopWorkSession();
    const arrival = v2ManualArrival({
      planId: PLAN_ID,
      stopId: 'stop-1',
      retailerId: 'retailer-1',
    });
    await assertFails(
      commitV2StopEvent(
        salesmanDb,
        parentRef,
        arrival,
        stopIds,
        (patch) => ({ ...patch, routeSessionState: 'completed' }),
      ),
    );
  });

  it('rejects the final stop writing a non-completed session value', async () => {
    const { salesmanDb, parentRef, acceptedArrival } =
      await startLiveSessionRoute('active', ['stop-1']);
    for (const value of ['paused', 'active', 'untracked']) {
      await assertFails(
        commitV2StopEvent(
          salesmanDb,
          parentRef,
          v2TerminalStopEvent(acceptedArrival, 'completed', 2),
          ['stop-1'],
          (patch) => ({ ...patch, routeSessionState: value }),
        ),
      );
    }
  });

  it('allows an owner to get only a missing canonical stop document', async () => {
    const ownerDb = dbFor(users.salesman);
    const peerDb = dbFor(users.otherSalesman);
    const ownMissingId = `${PLAN_ID}_${users.salesman.uid}_not-created`;
    const ownMissing = await getDoc(
      doc(ownerDb, 'route_stop_progress', ownMissingId),
    );
    assert.equal(ownMissing.exists(), false);

    await assertFails(
      getDoc(doc(peerDb, 'route_stop_progress', ownMissingId)),
    );
    await assertFails(
      getDoc(doc(ownerDb, 'route_stop_progress', `${PLAN_ID}_peer-stop`)),
    );
    await assertFails(
      getDocs(collection(ownerDb, 'route_stop_progress')),
    );
  });

  it('keeps stop evidence readable by active owners and denies suspended owners', async () => {
    const activeStopId = `${PLAN_ID}_${users.salesman.uid}_active-stop`;
    const suspendedStopId = `${PLAN_ID}_${users.suspendedSalesman.uid}_suspended-stop`;
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'route_stop_progress', activeStopId), {
        planId: PLAN_ID,
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        stopId: 'active-stop',
        status: 'arrived',
        arrivalLatitude: 1.5535,
        arrivalLongitude: 110.3593,
      });
      await setDoc(doc(db, 'route_stop_progress', suspendedStopId), {
        planId: PLAN_ID,
        salesmanUid: users.suspendedSalesman.uid,
        salesmanCode: 'S003',
        branchId: 'B1',
        stopId: 'suspended-stop',
        status: 'arrived',
        arrivalLatitude: 1.5535,
        arrivalLongitude: 110.3593,
      });
    });

    const activeDb = dbFor(users.salesman);
    const ownActiveStop = doc(activeDb, 'route_stop_progress', activeStopId);
    assert.equal((await assertSucceeds(getDoc(ownActiveStop))).exists(), true);
    const activeList = await assertSucceeds(getDocs(query(
      collection(activeDb, 'route_stop_progress'),
      where('salesmanUid', '==', users.salesman.uid),
    )));
    assert.equal(activeList.size, 1);

    const suspendedDb = dbFor(users.suspendedSalesman);
    const ownSuspendedStop = doc(
      suspendedDb,
      'route_stop_progress',
      suspendedStopId,
    );
    await assertFails(getDoc(ownSuspendedStop));
    await assertFails(getDocs(query(
      collection(suspendedDb, 'route_stop_progress'),
      where('salesmanUid', '==', users.suspendedSalesman.uid),
    )));
  });

  it('validates verified arrival distance, mock state, and published snapshots', async () => {
    const planId = 'route-arrival-evidence';
    const stopIds = [
      'near-stop',
      'mocked-stop',
      'offline-stop',
      'unbound-stop',
      'outside-stop',
    ];
    const retailerId = 'retailer-arrival-evidence';
    const referenceLatitude = 1.5535;
    const referenceLongitude = 110.3593;
    const publishedAt = Timestamp.fromMillis(Date.now() - 5_000);
    const reviewedAt = Timestamp.fromDate(new Date('2026-06-20T10:15:30.123Z'));
    const verifiedAt = Timestamp.fromDate(new Date('2026-06-20T10:16:45.456Z'));
    const coordinateProvenance = {
      coordinateReviewStatus: 'verified',
      coordinateSource: 'admin_review',
      coordinateReviewedAt: reviewedAt,
      coordinateReviewedByUid: 'admin-reviewer-uid-000000000000',
      coordinateReviewedBy: 'Amina Rahman',
      coordinateVerifiedAt: verifiedAt,
      coordinateVerifiedByUid: 'admin-reviewer-uid-000000000000',
      coordinateVerifiedBy: 'Amina Rahman',
    };
    const revisionParts = [
      'retailer-coordinate-v1',
      retailerId.trim(),
      referenceLatitude,
      referenceLongitude,
    ];
    for (const key of [
      'coordinateStatus',
      'coordinateReviewStatus',
      'coordinateSource',
      'coordinateReviewedAt',
      'coordinateReviewedByUid',
      'coordinateReviewedBy',
      'coordinateVerifiedAt',
      'coordinateVerifiedByUid',
      'coordinateVerifiedBy',
    ]) {
      const value = key === 'coordinateStatus'
        ? 'verified'
        : coordinateProvenance[key];
      if (value != null) {
        revisionParts.push([
          key,
          value instanceof Timestamp
            ? `${value.seconds}:${value.nanoseconds}`
            : value,
        ]);
      }
    }
    const coordinateRevision = `v1:${Buffer.from(
      JSON.stringify(revisionParts),
      'utf8',
    ).toString('base64').replace(/=/g, '').replace(/\+/g, '-').replace(/\//g, '_')}`;
    assert.ok(
      coordinateRevision.length > 200,
      `fixture must exceed the former 200-character limit (got ${coordinateRevision.length})`,
    );
    assert.ok(coordinateRevision.length <= 1024);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const adminDb = context.firestore();
      await setDoc(doc(adminDb, 'route_plans', planId), {
        planId,
        status: 'published',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        weekStart: Timestamp.fromDate(new Date('2026-06-22T00:00:00Z')),
        publishedAt,
        stopIds,
        totalStops: stopIds.length,
        stopRetailerIds: Object.fromEntries(
          stopIds.map((stopId) => [stopId, retailerId]),
        ),
        stopCoordinateSnapshots: {
          'offline-stop': {
            retailerId,
            latitude: referenceLatitude,
            longitude: referenceLongitude,
            coordinateStatus: 'verified',
            ...coordinateProvenance,
            coordinateRevision,
          },
        },
      });
      await setDoc(doc(adminDb, 'retailers', retailerId), {
        retailerId,
        branchId: 'B1',
        latitude: referenceLatitude,
        longitude: referenceLongitude,
        coordinateStatus: 'verified',
        ...coordinateProvenance,
      });
    });

    const db = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(db, {
      planId,
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'near-stop',
    });
    await seedRouteStopWorkSession();
    const selectStop = async (stopId, selectionRevision) =>
      assertSucceeds(updateDoc(parentRef, {
        selectedStopId: stopId,
        selectionRevision,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }));

    const nearFix = {
      latitude: referenceLatitude + 0.0001,
      longitude: referenceLongitude,
    };
    const nearArrival = v2VerifiedArrival({
      planId,
      stopId: 'near-stop',
      retailerId,
      ...nearFix,
      referenceLatitude,
      referenceLongitude,
      retailerCoordinateRevision: coordinateRevision,
      sessionEventSequence: 1,
    });
    await assertSucceeds(commitV2StopEvent(db, parentRef, nearArrival, stopIds));
    const acceptedNearFix = (await getDoc(doc(
      db,
      'route_stop_progress',
      `${planId}_${users.salesman.uid}_near-stop`,
    ))).data();
    assert.notEqual(acceptedNearFix.arrivalLatitude, referenceLatitude);

    await selectStop('mocked-stop', 2);
    await assertFails(commitV2StopEvent(db, parentRef, v2VerifiedArrival({
      planId,
      stopId: 'mocked-stop',
      retailerId,
      ...nearFix,
      referenceLatitude,
      referenceLongitude,
      sessionEventSequence: 2,
      arrivalIsMocked: true,
    }), stopIds));

    await selectStop('offline-stop', 3);
    await assertSucceeds(commitV2StopEvent(db, parentRef, v2VerifiedArrival({
      planId,
      stopId: 'offline-stop',
      retailerId,
      ...nearFix,
      referenceLatitude,
      referenceLongitude,
      coordinateReferenceMode: 'published_snapshot_offline',
      retailerCoordinateRevision: coordinateRevision,
      coordinateSnapshotAt: publishedAt,
      sessionEventSequence: 2,
    }), stopIds));

    await selectStop('unbound-stop', 4);
    await assertFails(commitV2StopEvent(db, parentRef, v2VerifiedArrival({
      planId,
      stopId: 'unbound-stop',
      retailerId,
      ...nearFix,
      referenceLatitude,
      referenceLongitude,
      coordinateReferenceMode: 'published_snapshot_offline',
      retailerCoordinateRevision: 'client-invented-revision',
      coordinateSnapshotAt: publishedAt,
      sessionEventSequence: 3,
    }), stopIds));

    await selectStop('outside-stop', 5);
    await assertFails(commitV2StopEvent(db, parentRef, v2VerifiedArrival({
      planId,
      stopId: 'outside-stop',
      retailerId,
      latitude: referenceLatitude + 0.001,
      longitude: referenceLongitude,
      referenceLatitude,
      referenceLongitude,
      arrivalDistanceMeters: 12,
      sessionEventSequence: 3,
    }), stopIds));
  });
});
describe('visit brief reads', () => {
  const BRIEF_UID = 'brief-salesman-uid';
  const BRIEF_DOC = 'brief.salesman@example.test';
  const PEER_UID = 'brief-other-uid';

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', BRIEF_DOC), {
        uid: BRIEF_UID,
        userUid: BRIEF_UID,
        email: BRIEF_DOC,
        name: 'Brief Salesman',
        role: 'salesman',
        status: 'active',
        employeeCode: 'S001',
        userId: 'S001',
        branchId: 'B1',
        branch_id: 'B1',
      });
      await setDoc(doc(db, 'user_access', BRIEF_UID), {
        uid: BRIEF_UID,
        userDocId: BRIEF_DOC,
        email: BRIEF_DOC,
        role: 'salesman',
        user_group: 'salesman',
        status: 'active',
        employeeCode: 'S001',
        userId: 'S001',
        branchId: 'B1',
        branch_id: 'B1',
      });
      await setDoc(doc(db, 'visit_briefs', 'brief-own'), {
        briefId: 'brief-own',
        retailerId: 'retailer-1',
        retailerName: 'Retailer One',
        salesmanUid: BRIEF_UID,
        salesmanCode: 'S001',
        branchId: 'B1',
        status: 'active',
        focusItems: [],
      });
      await setDoc(doc(db, 'visit_briefs', 'brief-peer'), {
        briefId: 'brief-peer',
        retailerId: 'retailer-2',
        retailerName: 'Retailer Two',
        salesmanUid: PEER_UID,
        salesmanCode: 'S002',
        branchId: 'B1',
        status: 'active',
      });
    });
  });

  it('a salesman can read its own brief by document', async () => {
    const db = authContext(BRIEF_UID).firestore();
    await assertSucceeds(getDoc(doc(db, 'visit_briefs', 'brief-own')));
  });

  it('a salesman can run the app own salesmanUid query', async () => {
    const db = authContext(BRIEF_UID).firestore();
    await assertSucceeds(
      getDocs(
        query(
          collection(db, 'visit_briefs'),
          where('salesmanUid', '==', BRIEF_UID),
        ),
      ),
    );
  });

  it('a code-only brief query is refused because a reused code would show the previous holder briefs', async () => {
    const db = authContext(BRIEF_UID).firestore();
    await assertFails(
      getDocs(
        query(
          collection(db, 'visit_briefs'),
          where('salesmanCode', '==', 'S001'),
        ),
      ),
    );
  });

  it('a code query limited to briefs with no owner is allowed', async () => {
    const db = authContext(BRIEF_UID).firestore();
    await assertSucceeds(
      getDocs(
        query(
          collection(db, 'visit_briefs'),
          where('salesmanCode', '==', 'S001'),
          where('salesmanUid', '==', ''),
        ),
      ),
    );
  });

  it('a code-addressed brief is still readable as a document', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'visit_briefs', 'brief-code-only'),
        {
          briefId: 'brief-code-only',
          retailerId: 'retailer-3',
          retailerName: 'Retailer Three',
          salesmanUid: '',
          salesmanCode: 'S001',
          branchId: 'B1',
          status: 'active',
        },
      );
    });
    const db = authContext(BRIEF_UID).firestore();
    await assertSucceeds(
      getDoc(doc(db, 'visit_briefs', 'brief-code-only')),
    );
  });

  it('records an arrival in its own per-stop document, and replays it safely', async () => {
    const db = dbFor(users.salesman);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', 'route-own'), {
        status: 'published',
      });
    });
    const parentRef = await createSelectedRouteProgress(db, {
      planId: 'route-own',
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();
    const stopDocId = 'route-own_sales-1_stop-1';
    const stopRef = doc(db, 'route_stop_progress', stopDocId);
    const arrival = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-1',
      retailerId: 'retailer-1',
      deviceOccurredAt: Timestamp.fromMillis(Date.now() - 10_000),
    });

    await assertFails(setDoc(stopRef, arrival));
    const initialParent = (await getDoc(parentRef)).data();
    await assertFails(
      updateDoc(
        parentRef,
        v2StopParentProjection(initialParent, arrival, ['stop-1']),
      ),
    );
    await assertSucceeds(
      commitV2StopEvent(db, parentRef, arrival, ['stop-1']),
    );

    const acceptedArrival = (await getDoc(stopRef)).data();
    const parentBeforeReplay = (await getDoc(parentRef)).data();
    const replay = {
      ...acceptedArrival,
      receivedAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    };
    await assertSucceeds(
      commitV2StopEvent(db, parentRef, replay, ['stop-1']),
    );
    const parentAfterReplay = (await getDoc(parentRef)).data();
    assert.equal(parentAfterReplay.lastStopEventId, parentBeforeReplay.lastStopEventId);
    assert.equal(
      parentAfterReplay.lastSummaryEventSequence,
      parentBeforeReplay.lastSummaryEventSequence,
    );
    assert.equal(parentAfterReplay.selectedStopId, 'stop-1');

    await assertFails(
      commitV2StopEvent(db, parentRef, {
        ...acceptedArrival,
        arrivalFailureCode: 'outside_radius',
        receivedAt: serverTimestamp(),
        updatedAt: serverTimestamp(),
      }, ['stop-1']),
    );
  });

  it('allows ordinary fast-device clock skew but bounds far-future arrivals', async () => {
    const db = dbFor(users.salesman);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', 'route-own'), {
        status: 'published',
        stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': 'ret-1', 'stop-2': 'ret-2' },
        totalStops: 2,
      });
    });
    const parentRef = await createSelectedRouteProgress(db, {
      planId: 'route-own',
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();

    const now = Date.now();
    const allowedSkew = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-1',
      retailerId: 'ret-1',
      deviceOccurredAt: Timestamp.fromMillis(now + 30 * 60_000),
    });
    await assertSucceeds(
      commitV2StopEvent(db, parentRef, allowedSkew, ['stop-1', 'stop-2']),
    );
    await assertSucceeds(
      updateDoc(parentRef, {
        selectedStopId: 'stop-2',
        selectionRevision: 2,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );
    const beyondSkew = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-2',
      retailerId: 'ret-2',
      sessionEventSequence: 2,
      deviceOccurredAt: Timestamp.fromMillis(now + 61 * 60_000),
    });
    await assertFails(
      commitV2StopEvent(db, parentRef, beyondSkew, ['stop-1', 'stop-2']),
    );
  });

  it('refuses peer, forged stop, stale session, bad mode and missing manual reason', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', 'route-own'), {
        status: 'published',
        stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' },
        totalStops: 2,
      });
    });
    const peer = dbFor(users.otherSalesman);
    const docId = 'route-own_sales-1_stop-1';
    const db = dbFor(users.salesman);
    const parentRef = await createSelectedRouteProgress(db, {
      planId: 'route-own',
      uid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      selectedStopId: 'stop-1',
    });
    await seedRouteStopWorkSession();
    const base = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-1',
      retailerId: 'retailer-1',
      deviceOccurredAt: Timestamp.fromMillis(Date.now() - 1_000),
    });
    await assertFails(setDoc(doc(peer, 'route_stop_progress', docId), base));
    await assertFails(
      commitV2StopEvent(
        db,
        parentRef,
        { ...base, salesmanCode: 'S002' },
        ['stop-1', 'stop-2'],
      ),
    );
    await assertFails(
      commitV2StopEvent(
        db,
        parentRef,
        { ...base, branchId: 'B2' },
        ['stop-1', 'stop-2'],
      ),
    );
    await assertFails(
      commitV2StopEvent(
        db,
        parentRef,
        { ...base, retailerId: 'retailer-2' },
        ['stop-1', 'stop-2'],
      ),
    );
    await assertSucceeds(
      commitV2StopEvent(db, parentRef, base, ['stop-1', 'stop-2']),
    );
    await assertSucceeds(
      updateDoc(parentRef, {
        selectedStopId: 'stop-2',
        selectionRevision: 2,
        updatedAt: serverTimestamp(),
        lastSyncedAt: serverTimestamp(),
      }),
    );

    const forged = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-9',
      retailerId: 'retailer-9',
      sessionEventSequence: 2,
    });
    await assertFails(
      commitV2StopEvent(db, parentRef, forged, ['stop-1', 'stop-2']),
    );

    const nextSessionId = 'c'.repeat(32);
    await seedRouteStopWorkSession(users.salesman.uid, nextSessionId, 2);
    const staleSession = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-2',
      retailerId: 'retailer-2',
      sessionEventSequence: 2,
    });
    await assertFails(
      commitV2StopEvent(db, parentRef, staleSession, ['stop-1', 'stop-2']),
    );

    const badMode = v2ManualArrival({
      planId: 'route-own',
      stopId: 'stop-2',
      retailerId: 'retailer-2',
      workSessionId: nextSessionId,
      workSessionGeneration: 2,
      sessionEventSequence: 1,
    });
    await assertFails(
      commitV2StopEvent(
        db,
        parentRef,
        { ...badMode, arrivalMode: 'guessed' },
        ['stop-1', 'stop-2'],
      ),
    );
    const missingManualReason = { ...badMode };
    delete missingManualReason.overrideReasonCode;
    await assertFails(
      commitV2StopEvent(
        db,
        parentRef,
        missingManualReason,
        ['stop-1', 'stop-2'],
      ),
    );
  });

  it('a salesman cannot read a peer brief', async () => {
    const db = authContext(BRIEF_UID).firestore();
    await assertFails(getDoc(doc(db, 'visit_briefs', 'brief-peer')));
  });
});

describe('FR-AUTH-07 role permission table', () => {
  const developer = {
    uid: 'developer-1',
    profile: { role: 'developer', status: 'active', isActive: true },
  };
  const ACTIONS = ['view', 'create', 'edit', 'delete'];
  const product = {
    productId: 'p-matrix',
    departmentId: 'beverage',
    categoryId: 'beverage_juice',
    departmentName: 'Beverage',
    departmentManagerName: 'Catalogue Team',
    mainCategoryName: 'Juice',
    categoryName: 'Juice',
    itemName: 'Orange Juice (12 x 1L)',
    productName: 'Orange Juice (12 x 1L)',
    productFlavor: 'Orange Juice',
    flavor: 'Orange Juice',
    itemCode: 'OJ-01',
    productCode: 'OJ-01',
    sku: 'OJ-01',
    barcode: '9551000000015',
    itemBarcode: '9551000000015',
    packingSize: '12 x 1L',
    unitPrice: 12.5,
    price: 12.5,
    priceGuide: 12.5,
    uom: 'ctn',
    uomLabel: 'ctn',
    unitOfMeasure: 'ctn',
    sortOrder: 1,
    isVisible: false,
    status: 'hidden',
  };
  const serverOnly = (collectionName, action) => collectionName === 'products' && action === 'delete';
  const assertAction = (collectionName, action, promise) =>
    (serverOnly(collectionName, action) ? assertFails(promise) : assertSucceeds(promise));
  const targets = [
    ['products', 'products', product, { unitPrice: 13, priceUpdatedAt: serverTimestamp() }],
    ['departments', 'departments', { name: 'D' }, { name: 'D2' }],
    ['categories', 'categories', { name: 'C' }, { name: 'C2' }],
    ['retailer_scoresheets', 'score_sheets', { name: 'S' }, { name: 'S2' }],
    ['retailer_scoresheets', 'retailer_score_sheet_settings', { name: 'S' }, { name: 'S2' }],
    ['retailer_scoresheets', 'retailer_score_sheet_items', { name: 'S' }, { name: 'S2' }],
    ['department_pic', 'department_pic_assignments', { name: 'P' }, { name: 'P2' }],
    ['website_pages', 'website_pages', { title: 'W' }, { title: 'W2' }],
  ];
  const modules = [...new Set(targets.map(([module]) => module))];
  const COMPANY_WIDE = ['products', 'departments', 'categories', 'website_pages'];
  const WRITES = ['create', 'edit', 'delete'];

  async function setMatrix(roles, revision = 1) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(
        doc(context.firestore(), 'system_access_config', 'permission_matrix'),
        {
          roles,
          revision,
          updatedByUid: users.admin.uid,
          auditDocumentId: 'seeded-audit-record',
        },
      );
    });
  }

  function fullAdminRow() {
    return modules.flatMap((module) =>
      ACTIONS.map((action) => `${module}:${action}`),
    );
  }
  function viewRow() {
    return modules.map((module) => `${module}:view`);
  }
  const without = (row, ...tokens) =>
    row.filter((token) => !tokens.includes(token));

  async function seedDocs() {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      for (const [, collectionName, create] of targets) {
        await setDoc(doc(context.firestore(), collectionName, 'existing'), create);
      }
      await setDoc(
        doc(context.firestore(), 'users', developer.uid),
        developer.profile,
      );
    });
  }

  function attempt(action, db, collectionName, create, update) {
    const ref = doc(db, collectionName, 'existing');
    if (action === 'view') return getDoc(ref);
    if (action === 'create') {
      return setDoc(doc(db, collectionName, 'brand-new'), create);
    }
    if (action === 'edit') return updateDoc(ref, update);
    return deleteDoc(ref);
  }

  beforeEach(seedDocs);

  describe('built-in defaults (no stored table)', () => {
    for (const [, collectionName, create, update] of targets) {
      it(`${collectionName}: Admin does all four actions`, async () => {
        const db = dbFor(users.admin);
        for (const action of ACTIONS) {
          await assertAction(collectionName, action, attempt(action, db, collectionName, create, update));
        }
      });

      it(`${collectionName}: Branch Manager, Supervisor and Salesman read but never write`, async () => {
        for (const user of [users.branchManager, users.supervisor, users.salesman]) {
          const db = dbFor(user);
          await assertSucceeds(attempt('view', db, collectionName, create, update));
          for (const action of ['create', 'edit', 'delete']) {
            await assertFails(attempt(action, db, collectionName, create, update));
          }
        }
      });
    }
  });

  describe('Admin cells', () => {
    for (const [module, collectionName, create, update] of targets) {
      for (const action of module === 'products' ? ACTIONS : ['edit']) {
        it(`${module}:${action} on ${collectionName} is enforced per cell`, async () => {
          const db = dbFor(users.admin);
          const token = `${module}:${action}`;
          await setMatrix({ admin: without(fullAdminRow(), token) });
          await assertFails(attempt(action, db, collectionName, create, update));
          await setMatrix({ admin: [token] }, 2);
          await assertAction(collectionName, action, attempt(action, db, collectionName, create, update));
          for (const other of ACTIONS.filter((candidate) => candidate !== action)) {
            await assertFails(attempt(other, db, collectionName, create, update));
          }
        });
      }
    }

    it('an empty Admin row denies every catalogue action but not other admin authority', async () => {
      await setMatrix({ admin: [] });
      const db = dbFor(users.admin);
      for (const [, collectionName, create, update] of targets) {
        for (const action of ACTIONS) {
          await assertFails(attempt(action, db, collectionName, create, update));
        }
      }
      await assertSucceeds(setDoc(doc(db, 'system_settings', 'cfg'), { x: 1 }));
    });

    it('a present row that is not a list fails closed', async () => {
      await setMatrix({ admin: 'products:view products:edit' });
      const db = dbFor(users.admin);
      await assertFails(getDoc(doc(db, 'products', 'existing')));
      await assertFails(
        updateDoc(doc(db, 'products', 'existing'), { status: 'hidden' }),
      );
    });

    it('a suspended admin is denied writes whatever the table says', async () => {
      await setMatrix({ admin: fullAdminRow() });
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await updateDoc(doc(context.firestore(), 'users', users.admin.uid), {
          status: 'suspended',
          isActive: false,
        });
      });
      await assertFails(
        updateDoc(doc(dbFor(users.admin), 'departments', 'existing'), { name: 'x' }),
      );
    });
  });

  describe('Branch Manager and Supervisor view cells', () => {
    for (const [roleName, user] of [
      ['branch_manager', users.branchManager],
      ['supervisor', users.supervisor],
    ]) {
      for (const [module, collectionName, create, update] of targets.filter(([, c]) => ['products', 'departments', 'score_sheets', 'department_pic_assignments'].includes(c))) {
        it(`${roleName} ${module}:view on ${collectionName} is enforced`, async () => {
          const db = dbFor(user);
          const token = `${module}:view`;
          await setMatrix({
            admin: fullAdminRow(),
            [roleName]: without(viewRow(), token),
          });
          await assertFails(attempt('view', db, collectionName, create, update));
          await setMatrix({ admin: fullAdminRow(), [roleName]: [token] }, 2);
          await assertSucceeds(attempt('view', db, collectionName, create, update));
          await assertSucceeds(
            attempt('view', dbFor(users.salesman), collectionName, create, update),
          );
        });
      }

      const otherRole = roleName === 'supervisor' ? 'branch_manager' : 'supervisor';
      for (const [module, collectionName, create, update] of targets.filter(([m]) => COMPANY_WIDE.includes(m))) {
        for (const action of ['edit']) {
          it(`${roleName} ${module}:${action} on ${collectionName} follows its own tick and needs View`, async () => {
            const db = dbFor(user);
            const token = `${module}:${action}`;
            const otherWrites = COMPANY_WIDE.flatMap((m) => WRITES.map((a) => `${m}:${a}`)).filter((t) => t !== token);
            await setMatrix({ admin: fullAdminRow(), [roleName]: [...viewRow(), ...otherWrites] });
            await assertFails(attempt(action, db, collectionName, create, update));
            await setMatrix({ admin: fullAdminRow(), [roleName]: without(viewRow(), `${module}:view`).concat(token) }, 2);
            await assertFails(attempt(action, db, collectionName, create, update));
            await setMatrix({ admin: fullAdminRow(), [otherRole]: [...viewRow(), token] }, 3);
            await assertFails(attempt(action, db, collectionName, create, update));
            await setMatrix({ admin: fullAdminRow(), [roleName]: [...viewRow(), token] }, 4);
            await assertAction(collectionName, action, attempt(action, db, collectionName, create, update));
          });
        }
      }

      it(`${roleName} with every write ticked still never writes the score sheet library or the legacy items`, async () => {
        const db = dbFor(user);
        await setMatrix({ admin: fullAdminRow(), [roleName]: fullAdminRow() });
        for (const collectionName of ['score_sheets', 'retailer_score_sheet_items']) {
          const [, , create, update] = targets.find(([, c]) => c === collectionName);
          for (const action of WRITES) {
            await assertFails(attempt(action, db, collectionName, create, update));
          }
          await assertSucceeds(attempt('view', db, collectionName, create, update));
        }
      });

      it(`${roleName} Products Edit includes the price fields and keeps the field checks`, async () => {
        const db = dbFor(user);
        await setMatrix({ admin: fullAdminRow(), [roleName]: [...viewRow(), 'products:edit'] });
        await assertSucceeds(updateDoc(doc(db, 'products', 'existing'), { unitPrice: 14, price: 14, priceGuide: 14, priceUpdatedAt: serverTimestamp() }));
        await assertFails(updateDoc(doc(db, 'products', 'existing'), { unitPrice: -1 }));
        await assertFails(updateDoc(doc(db, 'products', 'existing'), { isVisible: true, status: 'active' }));
        await assertFails(updateDoc(doc(db, 'products', 'existing'), { forged: true }));
      });

      it(`${roleName} keeps its default view when only another role has a row`, async () => {
        await setMatrix({ admin: [] });
        for (const [, collectionName, create, update] of targets) {
          await assertSucceeds(
            attempt('view', dbFor(user), collectionName, create, update),
          );
        }
      });
    }

    it('a suspended dashboard role gains nothing from a granted cell', async () => {
      await setMatrix({ supervisor: [...viewRow(), 'departments:edit', 'departments:delete'] });
      const db = dbFor(users.suspendedSupervisor);
      await assertFails(updateDoc(doc(db, 'departments', 'existing'), { name: 'x' }));
      await assertFails(deleteDoc(doc(db, 'departments', 'existing')));
    });

    it('the salesman role is not a table row and always reads', async () => {
      await setMatrix({ admin: [], branch_manager: [], supervisor: [] });
      for (const [, collectionName] of targets) {
        await assertSucceeds(
          getDoc(doc(dbFor(users.salesman), collectionName, 'existing')),
        );
        await assertFails(
          setDoc(doc(dbFor(users.salesman), collectionName, 'forged'), { name: 'x' }),
        );
      }
    });
  });

  describe('Developer root authority', () => {
    it('is not reduced by any stored row', async () => {
      await setMatrix({ admin: [], branch_manager: [], supervisor: [] });
      const db = dbFor(developer);
      for (const [, collectionName, create, update] of targets) {
        for (const action of ['view', 'edit', 'delete']) {
          await assertAction(collectionName, action, attempt(action, db, collectionName, create, update));
        }
      }
    });
  });

  describe('the table document', () => {
    const TABLE = ['system_access_config', 'permission_matrix'];

    function auditPayload(user, revision, overrides = {}) {
      return {
        action: 'permission_matrix_updated',
        entityType: 'system_access_config',
        entityId: 'permission_matrix',
        actorUid: user.uid,
        createdAt: serverTimestamp(),
        metadata: { nextRevision: revision },
        ...overrides,
      };
    }

    function tablePayload(user, revision, auditId, overrides = {}) {
      return {
        roles: {
          admin: fullAdminRow(),
          branch_manager: viewRow(),
          supervisor: viewRow(),
        },
        revision,
        updatedByUid: user.uid,
        updatedAt: serverTimestamp(),
        auditDocumentId: auditId,
        ...overrides,
      };
    }

    function commit(
      user,
      revision,
      {
        auditId = `permission_matrix_r${revision}_abcdef01`,
        table = {},
        audit = {},
        skipAudit = false,
        skipMirrors = false,
        mirrorRevision = null,
      } = {},
    ) {
      const db = dbFor(user);
      const batch = writeBatch(db);
      const payload = tablePayload(user, revision, auditId, table);
      batch.set(doc(db, ...TABLE), payload);
      if (!skipMirrors) {
        for (const role of ['supervisor', 'branch_manager']) {
          const row = Array.isArray(payload.roles[role]) ? payload.roles[role] : [];
          batch.set(doc(db, 'role_permission_grants', role), {
            role,
            grants: row,
            revision: mirrorRevision ?? revision,
            updatedByUid: user.uid,
            updatedAt: serverTimestamp(),
            shape: 3,
          });
        }
      }
      if (!skipAudit) {
        batch.set(
          doc(db, 'system_audit_logs', auditId),
          auditPayload(user, revision, audit),
        );
      }
      return batch.commit();
    }

    it('is refused without both copies at the same revision', async () => {
      await assertFails(commit(users.admin, 1, { skipMirrors: true }));
      await assertFails(commit(users.admin, 1, { mirrorRevision: 5 }));
      await assertSucceeds(commit(users.admin, 1));
      await assertFails(commit(users.admin, 2, { skipMirrors: true }));
      await assertSucceeds(commit(users.admin, 2));
    });

    it('an admin creates revision 1 and revision 2 with matching audit records', async () => {
      await assertSucceeds(commit(users.admin, 1));
      await assertSucceeds(commit(users.admin, 2));
    });

    it('a developer may also maintain the table', async () => {
      await assertSucceeds(commit(developer, 1));
    });

    it('Branch Manager, Supervisor and Salesman can neither write nor read it', async () => {
      await setMatrix({ admin: fullAdminRow() });
      for (const user of [users.branchManager, users.supervisor, users.salesman]) {
        await assertFails(commit(user, 2));
        await assertFails(getDoc(doc(dbFor(user), ...TABLE)));
      }
      await assertSucceeds(getDoc(doc(dbFor(users.admin), ...TABLE)));
    });

    it('refuses a write without its audit record, or with a mismatched one', async () => {
      await assertFails(commit(users.admin, 1, { skipAudit: true }));
      await assertFails(
        commit(users.admin, 1, { audit: { actorUid: 'someone-else' } }),
      );
      await assertFails(
        commit(users.admin, 1, { audit: { metadata: { nextRevision: 9 } } }),
      );
      await assertFails(commit(users.admin, 1, { audit: { entityId: 'other' } }));
      await assertFails(
        commit(users.admin, 1, { audit: { createdAt: Timestamp.fromMillis(1) } }),
      );
      await assertFails(commit(users.admin, 1, { auditId: 'short' }));
    });

    it('requires the revision to advance by exactly one', async () => {
      await assertFails(commit(users.admin, 2));
      await assertSucceeds(commit(users.admin, 1));
      await assertFails(commit(users.admin, 1));
      await assertFails(commit(users.admin, 3));
    });

    it('rejects extra rows, a developer row, malformed rows and stray fields', async () => {
      const rows = { branch_manager: viewRow(), supervisor: viewRow() };
      const bad = [
        { roles: { ...rows, salesman: viewRow() } },
        { roles: { ...rows, developer: fullAdminRow() } },
        { roles: { ...rows, admin: 'products:view' } },
        { roles: { ...rows, admin: new Array(201).fill('products:view') } },
        { roles: 'admin' },
        { extra: true },
        { updatedByUid: users.branchManager.uid },
        { revision: '1' },
      ];
      for (const table of bad) {
        await assertFails(commit(users.admin, 1, { table }));
      }
    });

    it('cannot be deleted', async () => {
      await setMatrix({ admin: fullAdminRow() });
      await assertFails(deleteDoc(doc(dbFor(users.admin), ...TABLE)));
    });

    it('cannot be written under another document id', async () => {
      const db = dbFor(users.admin);
      const auditId = 'permission_matrix_r1_abcdef01';
      const batch = writeBatch(db);
      batch.set(
        doc(db, 'system_access_config', 'other'),
        tablePayload(users.admin, 1, auditId),
      );
      batch.set(
        doc(db, 'system_audit_logs', auditId),
        auditPayload(users.admin, 1),
      );
      await assertFails(batch.commit());
    });

    it('a pre-created audit id cannot be reused, but a fresh id still works', async () => {
      await assertSucceeds(
        setDoc(
          doc(dbFor(users.branchManager), 'system_audit_logs', 'permission_matrix_r1_abcdef01'),
          { actorUid: users.branchManager.uid, createdAt: serverTimestamp() },
        ),
      );
      await assertFails(commit(users.admin, 1));
      await assertSucceeds(
        commit(users.admin, 1, { auditId: 'permission_matrix_r1_0123456789abcdef' }),
      );
    });
  });

  describe('delegated Score Sheets and Retailer Department PIC for Supervisor and Branch Manager', () => {
    const SCORE = 'retailer_scoresheets';
    const PIC = 'department_pic';
    const retailers = {
      'ret-own': { assignedSalesmanId: 'S001', branchId: 'B1' },
      'ret-listed': { assignedSalesmanCodes: ['S001', 'S005'], branchId: 'B1' },
      'ret-same-branch-other-team': { assignedSalesmanId: 'S002', branchId: 'B1' },
      'ret-other-branch': { assignedSalesmanId: 'S002', branchId: 'B2' },
      'ret-unassigned': { branchId: 'B1' },
    };
    const writeTokens = (module) => ['create', 'edit', 'delete'].map((a) => `${module}:${a}`);
    const allDelegated = [...writeTokens(SCORE), ...writeTokens(PIC)];
    let revision = 0;

    async function grant(roleName, tokens) {
      revision += 1;
      await setMatrix({ [roleName]: [...viewRow(), ...tokens] }, revision);
    }
    const settings = (retailerId, extra = {}) => ({ retailerId, sheetName: 'Sheet', ...extra });
    const picRow = (retailerId, extra = {}) => ({ retailerId, departmentName: 'Dairy', picName: 'Ann', ...extra });
    const settingsRef = (db, id) => doc(db, 'retailer_score_sheet_settings', id);
    const picRef = (db, id) => doc(db, 'department_pic_assignments', id);

    beforeEach(async () => {
      revision = 0;
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore();
        for (const [id, data] of Object.entries(retailers)) {
          await setDoc(doc(db, 'retailers', id), data);
          await setDoc(settingsRef(db, id), settings(id));
          await setDoc(picRef(db, `pic-${id}`), picRow(id));
        }
      });
    });

    describe('Supervisor', () => {
      it('is refused every write until Admin ticks, even on its own shops', async () => {
        const db = dbFor(users.supervisor);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
        await assertFails(setDoc(settingsRef(db, 'ret-new'), settings('ret-new')));
        await assertFails(deleteDoc(settingsRef(db, 'ret-own')));
        await assertFails(updateDoc(picRef(db, 'pic-ret-own'), { picName: 'X' }));
        await assertFails(deleteDoc(picRef(db, 'pic-ret-own')));
      });

      it('may edit the score sheet of an own-team shop after the Edit tick, and not after it is removed', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', [`${SCORE}:edit`]);
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-listed'), { sheetName: 'X' }));
        await assertFails(deleteDoc(settingsRef(db, 'ret-own')));
        await grant('supervisor', []);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'Y' }));
        await assertFails(updateDoc(settingsRef(db, 'ret-listed'), { sheetName: 'Y' }));
      });

      it('changes product price overrides only with the Edit tick, on own-team shops only', async () => {
        const db = dbFor(users.supervisor);
        const overrides = { p1: { price: 0.01 } };
        const rulesOff = (fn) => testEnv.withSecurityRulesDisabled((context) => fn(context.firestore()));
        await rulesOff((fdb) => deleteDoc(settingsRef(fdb, 'ret-own')));
        await rulesOff((fdb) => setDoc(settingsRef(fdb, 'ret-listed'), settings('ret-listed', { productOverrides: overrides })));
        await grant('supervisor', [`${SCORE}:create`, `${SCORE}:delete`]);
        await assertFails(setDoc(settingsRef(db, 'ret-own'), settings('ret-own', { productOverrides: overrides })));
        await assertFails(deleteDoc(settingsRef(db, 'ret-listed')));
        await assertSucceeds(setDoc(settingsRef(db, 'ret-own'), settings('ret-own')));
        await grant('supervisor', [`${SCORE}:create`, `${SCORE}:delete`, `${SCORE}:edit`]);
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-own'), { productOverrides: overrides }));
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-listed'), { productOverrides: { p1: { price: 0.02 } } }));
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-listed'), { productOverrides: deleteField() }));
        await rulesOff((fdb) => setDoc(settingsRef(fdb, 'ret-listed'), settings('ret-listed', { productOverrides: overrides })));
        await assertSucceeds(deleteDoc(settingsRef(db, 'ret-listed')));
        await rulesOff((fdb) => deleteDoc(settingsRef(fdb, 'ret-own')));
        await assertSucceeds(setDoc(settingsRef(db, 'ret-own'), settings('ret-own', { productOverrides: overrides })));
        await assertFails(updateDoc(settingsRef(db, 'ret-other-branch'), { productOverrides: overrides }));
        await assertFails(updateDoc(settingsRef(db, 'ret-same-branch-other-team'), { productOverrides: overrides }));
        await grant('supervisor', [`${SCORE}:create`, `${SCORE}:delete`]);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { productOverrides: { p1: { price: 9 } } }));
        await assertSucceeds(
          updateDoc(settingsRef(dbFor(users.admin), 'ret-own'), { productOverrides: { p1: { price: 9 } } }),
        );
      });

      it('is refused shops of another team, another branch or no owner, whatever is ticked', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', allDelegated);
        for (const id of ['ret-same-branch-other-team', 'ret-other-branch', 'ret-unassigned']) {
          await assertFails(updateDoc(settingsRef(db, id), { sheetName: 'X' }));
          await assertFails(deleteDoc(settingsRef(db, id)));
          await assertFails(updateDoc(picRef(db, `pic-${id}`), { picName: 'X' }));
          await assertFails(deleteDoc(picRef(db, `pic-${id}`)));
          await assertFails(setDoc(picRef(db, `new-${id}`), picRow(id)));
        }
        await assertFails(
          updateDoc(settingsRef(dbFor(users.unassignedSupervisor), 'ret-own'), { sheetName: 'X' }),
        );
      });

      it('is not given another team shop by a blank code in its own list', async () => {
        await testEnv.withSecurityRulesDisabled(async (context) => {
          const db = context.firestore();
          await setDoc(doc(db, 'users', 'supervisor-blank'), {
            role: 'supervisor', status: 'active', assignedSalesmanCodes: ['', 'S001'], branchId: 'B1',
          });
          await setDoc(doc(db, 'retailers', 'ret-blank-list'), { assignedSalesmanCodes: ['', 'S002'], branchId: 'B1' });
          await setDoc(settingsRef(db, 'ret-blank-list'), settings('ret-blank-list'));
          await setDoc(picRef(db, 'pic-ret-blank-list'), picRow('ret-blank-list'));
        });
        const db = authContext('supervisor-blank').firestore();
        await grant('supervisor', allDelegated);
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
        await assertFails(updateDoc(settingsRef(db, 'ret-blank-list'), { sheetName: 'X' }));
        await assertFails(deleteDoc(settingsRef(db, 'ret-blank-list')));
        await assertFails(updateDoc(picRef(db, 'pic-ret-blank-list'), { picName: 'X' }));
        await assertFails(deleteDoc(picRef(db, 'pic-ret-blank-list')));
      });

      it('creates and deletes a sheet only with the matching tick and only for an own-team shop', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', [`${SCORE}:create`]);
        await testEnv.withSecurityRulesDisabled(async (context) => {
          await setDoc(doc(context.firestore(), 'retailers', 'ret-fresh'), { assignedSalesmanId: 'S001', branchId: 'B1' });
        });
        await assertSucceeds(setDoc(settingsRef(db, 'ret-fresh'), settings('ret-fresh')));
        await assertFails(setDoc(settingsRef(db, 'ret-fresh-forged'), settings('ret-own')));
        await assertFails(setDoc(settingsRef(db, 'ret-missing'), settings('ret-missing')));
        await assertFails(deleteDoc(settingsRef(db, 'ret-fresh')));
        await grant('supervisor', [`${SCORE}:delete`]);
        await assertSucceeds(deleteDoc(settingsRef(db, 'ret-fresh')));
      });

      it('cannot repoint a sheet at a shop it does not own', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', allDelegated);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { retailerId: 'ret-other-branch' }));
      });

      it('never writes the company default sheet, templates or the legacy items', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', allDelegated);
        await testEnv.withSecurityRulesDisabled(async (context) => {
          await setDoc(doc(context.firestore(), 'score_sheets', 'default'), { scoreSheetId: 'default', productIds: [] });
        });
        await assertSucceeds(getDoc(doc(db, 'score_sheets', 'default')));
        await assertFails(updateDoc(doc(db, 'score_sheets', 'default'), { productIds: ['p1'] }));
        await assertFails(setDoc(doc(db, 'score_sheets', 'default'), { scoreSheetId: 'default', productIds: ['p1'] }));
        await assertFails(setDoc(doc(db, 'score_sheets', 'brand-new'), { name: 'S' }));
        await assertFails(deleteDoc(doc(db, 'score_sheets', 'default')));
        await assertFails(setDoc(doc(db, 'retailer_score_sheet_items', 'brand-new'), { name: 'S' }));
      });

      it('manages Retailer Department PIC only for own-team shops and only with the ticks', async () => {
        const db = dbFor(users.supervisor);
        await grant('supervisor', [`${PIC}:create`, `${PIC}:edit`]);
        await assertSucceeds(setDoc(picRef(db, 'pic-new'), picRow('ret-own')));
        await assertFails(setDoc(picRef(db, 'pic-new-other'), picRow('ret-other-branch')));
        await assertFails(setDoc(picRef(db, 'pic-new-missing'), { departmentName: 'Dairy', picName: 'Ann' }));
        await assertSucceeds(updateDoc(picRef(db, 'pic-ret-listed'), { picName: 'Bob' }));
        await assertFails(updateDoc(picRef(db, 'pic-ret-own'), { retailerId: 'ret-other-branch' }));
        await assertFails(deleteDoc(picRef(db, 'pic-ret-own')));
        await grant('supervisor', [`${PIC}:delete`]);
        await assertSucceeds(deleteDoc(picRef(db, 'pic-ret-own')));
        await assertFails(updateDoc(picRef(db, 'pic-ret-listed'), { picName: 'Cy' }));
      });

      it('a suspended supervisor gains nothing from a tick', async () => {
        await grant('supervisor', allDelegated);
        const db = dbFor(users.suspendedSupervisor);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
      });

      it('loses the write when View is removed even if Edit stays ticked', async () => {
        revision += 1;
        await setMatrix({ supervisor: [`${SCORE}:edit`] }, revision);
        await assertFails(updateDoc(settingsRef(dbFor(users.supervisor), 'ret-own'), { sheetName: 'X' }));
      });
    });

    describe('Branch Manager', () => {
      it('is refused until ticked, then limited to shops of its own branch', async () => {
        const db = dbFor(users.branchManager);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
        await grant('branch_manager', allDelegated);
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'X' }));
        await assertSucceeds(updateDoc(settingsRef(db, 'ret-same-branch-other-team'), { sheetName: 'X' }));
        await assertSucceeds(updateDoc(picRef(db, 'pic-ret-unassigned'), { picName: 'X' }));
        await assertFails(updateDoc(settingsRef(db, 'ret-other-branch'), { sheetName: 'X' }));
        await assertFails(updateDoc(picRef(db, 'pic-ret-other-branch'), { picName: 'X' }));
        await assertFails(updateDoc(doc(db, 'score_sheets', 'default'), { productIds: ['p1'] }));
        await grant('branch_manager', []);
        await assertFails(updateDoc(settingsRef(db, 'ret-own'), { sheetName: 'Y' }));
      });

      it('a Supervisor tick does not help the Branch Manager and the reverse', async () => {
        await grant('supervisor', allDelegated);
        await assertFails(updateDoc(settingsRef(dbFor(users.branchManager), 'ret-own'), { sheetName: 'X' }));
        await grant('branch_manager', allDelegated);
        await assertSucceeds(updateDoc(settingsRef(dbFor(users.branchManager), 'ret-own'), { sheetName: 'X' }));
      });
    });

    describe('the readable grants copy', () => {
      const MIRROR = 'role_permission_grants';
      const mirrorDoc = (db, role) => doc(db, MIRROR, role);

      function commitWithMirrors(user, rev, roles, mirrors) {
        const auditId = `permission_matrix_r${rev}_abcdef01`;
        const db = dbFor(user);
        const batch = writeBatch(db);
        batch.set(doc(db, 'system_access_config', 'permission_matrix'), {
          roles,
          revision: rev,
          updatedByUid: user.uid,
          updatedAt: serverTimestamp(),
          auditDocumentId: auditId,
        });
        for (const [role, mirror] of Object.entries(mirrors)) {
          const payload = {
            role,
            grants: Array.isArray(roles[role]) ? roles[role] : [],
            revision: rev,
            updatedByUid: user.uid,
            updatedAt: serverTimestamp(),
            shape: 3,
            ...mirror,
          };
          if (payload.shape === null) delete payload.shape;
          batch.set(mirrorDoc(db, role), payload);
        }
        batch.set(doc(db, 'system_audit_logs', auditId), {
          action: 'permission_matrix_updated',
          entityType: 'system_access_config',
          entityId: 'permission_matrix',
          actorUid: user.uid,
          createdAt: serverTimestamp(),
          metadata: { nextRevision: rev },
        });
        return batch.commit();
      }
      const rolesWith = (supervisor, branchManager = viewRow()) => ({
        admin: fullAdminRow(),
        supervisor: [...viewRow(), ...supervisor],
        branch_manager: branchManager,
      });
      const both = { supervisor: {}, branch_manager: {} };

      it('Admin saves the table and both full-row copies in one batch', async () => {
        await assertSucceeds(commitWithMirrors(users.admin, 1, rolesWith([`${SCORE}:edit`, 'products:edit', 'website_pages:delete']), both));
        await assertSucceeds(commitWithMirrors(users.admin, 2, rolesWith(fullAdminRow().filter((t) => !t.endsWith(':view')), fullAdminRow()), both));
      });

      it('an older copy shape is refused, so a stale dashboard cannot save a partial copy', async () => {
        for (const shape of [null, 1, 2, 4]) {
          const mirror = { shape };
          await assertFails(
            commitWithMirrors(users.admin, 1, rolesWith([`${SCORE}:edit`]), { supervisor: mirror, branch_manager: {} }),
          );
        }
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([`${SCORE}:edit`]), {
            supervisor: { shape: 2, grants: [`${SCORE}:view`, `${PIC}:view`, `${SCORE}:edit`] },
            branch_manager: { shape: 2, grants: [`${SCORE}:view`, `${PIC}:view`] },
          }),
        );
      });

      it('a copy or row with a write tick and no View is refused, for every module', async () => {
        for (const module of modules) {
          const row = [...without(viewRow(), `${module}:view`), `${module}:edit`];
          await assertFails(
            commitWithMirrors(users.admin, 1, { admin: fullAdminRow(), supervisor: row, branch_manager: viewRow() }, both),
          );
        }
      });

      it('a copy that differs from the table is refused', async () => {
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([`${SCORE}:edit`]), {
            supervisor: { grants: [...viewRow(), `${SCORE}:edit`, `${PIC}:delete`] },
            branch_manager: {},
          }),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith(['products:edit']), {
            supervisor: { grants: viewRow() },
            branch_manager: {},
          }),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([]), {
            supervisor: { grants: [...viewRow(), 'departments:create'] },
            branch_manager: {},
          }),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, { admin: fullAdminRow(), supervisor: viewRow() }, both),
        );
      });

      it('a copy with the wrong revision, a stray token or a stray field is refused', async () => {
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([]), { supervisor: { revision: 7 }, branch_manager: {} }),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith(['orders:edit']), both),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([]), { supervisor: { extra: true }, branch_manager: {} }),
        );
        await assertFails(
          commitWithMirrors(users.admin, 1, rolesWith([]), { ...both, admin: { grants: [] } }),
        );
      });

      it('Supervisor and Branch Manager read only their own role copy, never the table, and write nothing', async () => {
        await assertSucceeds(commitWithMirrors(users.admin, 1, rolesWith([`${SCORE}:edit`]), both));
        const supervisorDb = dbFor(users.supervisor);
        const managerDb = dbFor(users.branchManager);
        await assertSucceeds(getDoc(mirrorDoc(supervisorDb, 'supervisor')));
        await assertFails(getDoc(mirrorDoc(supervisorDb, 'branch_manager')));
        await assertSucceeds(getDoc(mirrorDoc(managerDb, 'branch_manager')));
        await assertFails(getDoc(mirrorDoc(managerDb, 'supervisor')));
        await assertFails(getDoc(doc(supervisorDb, 'system_access_config', 'permission_matrix')));
        await assertFails(getDocs(collection(supervisorDb, MIRROR)));
        await assertFails(getDoc(mirrorDoc(dbFor(users.salesman), 'supervisor')));
        await assertFails(setDoc(mirrorDoc(supervisorDb, 'supervisor'), { role: 'supervisor', grants: allDelegated }));
        await assertFails(deleteDoc(mirrorDoc(supervisorDb, 'supervisor')));
        await assertFails(deleteDoc(mirrorDoc(dbFor(users.admin), 'supervisor')));
      });
    });
  });

  describe('Monthly Retailer Scorecard reads (FR-REP-01)', () => {
    beforeEach(async () => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const db = context.firestore();
        await setDoc(doc(db, 'orders', 'ORD-A'), {
          orderId: 'ORD-A',
          retailerId: 'R1',
          salesmanUid: users.salesman.uid,
          salesmanCode: 'S001',
          branchId: 'B1',
          status: 'submitted',
          submittedAt: Timestamp.now(),
          items: [],
        });
        await setDoc(doc(db, 'orders', 'ORD-B'), {
          orderId: 'ORD-B',
          retailerId: 'R2',
          salesmanUid: users.otherSalesman.uid,
          salesmanCode: 'S002',
          branchId: 'B2',
          status: 'submitted',
          submittedAt: Timestamp.now(),
          items: [],
        });
      });
    });

    const scan = (db, name) =>
      getDocs(query(collection(db, name), orderBy('__name__'), limit(250)));

    it('an admin can page through every order and product (the report source)', async () => {
      const db = dbFor(users.admin);
      const orders = await assertSucceeds(scan(db, 'orders'));
      const ids = orders.docs.map((snapshot) => snapshot.id);
      assert.ok(ids.includes('ORD-A') && ids.includes('ORD-B'));
      await assertSucceeds(scan(db, 'products'));
    });

    it('no other role can run the unscoped order scan the scorecard uses', async () => {
      for (const user of [users.branchManager, users.supervisor, users.salesman]) {
        await assertFails(scan(dbFor(user), 'orders'));
      }
    });

    it('revoking Admin products:view removes the product half of the report source', async () => {
      await setMatrix({ admin: without(fullAdminRow(), 'products:view') });
      const db = dbFor(users.admin);
      await assertFails(scan(db, 'products'));
      await assertSucceeds(scan(db, 'orders'));
    });

    it('the report is read-only: nobody can rewrite orders through it or store a scorecard', async () => {
      for (const user of [users.admin, users.branchManager, users.supervisor, users.salesman]) {
        const db = dbFor(user);
        await assertFails(
          setDoc(doc(db, 'retailer_scorecards', 'R1_2026-09'), { total: 1 }),
        );
        await assertFails(updateDoc(doc(db, 'orders', 'ORD-A'), { retailerId: 'R9' }));
        await assertFails(deleteDoc(doc(db, 'orders', 'ORD-B')));
      }
    });
  });
});

describe('orders reads with canonical linked profiles', () => {
  const actors = {
    admin: { uid: 'lk-admin', role: 'admin' },
    developer: { uid: 'lk-dev', role: 'developer' },
    supervisor: { uid: 'lk-sup', role: 'supervisor', assignedSalesmanCodes: ['S001'] },
    manager: { uid: 'lk-mgr', role: 'branch_manager', branchId: 'B1' },
    salesman: { uid: 'lk-sales', role: 'salesman', employeeCode: 'S001', branchId: 'B1' },
    suspendedAdmin: { uid: 'lk-sus-admin', role: 'admin', status: 'suspended' },
    suspendedSalesman: {
      uid: 'lk-sus-sales', role: 'salesman', employeeCode: 'S001', status: 'suspended',
    },
    unlinkedSalesman: { uid: 'lk-unlinked', role: 'salesman', employeeCode: 'S001', unlinked: true },
  };

  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const [key, a] of Object.entries(actors)) {
        const { unlinked, uid, ...profile } = a;
        const docId = `${key}@example.test`;
        const base = { status: 'active', ...profile };
        if (unlinked) {
          await setDoc(doc(db, 'user_access', uid), { ...base, uid, userDocId: docId });
          continue;
        }
        await setDoc(doc(db, 'users', docId), { ...base, uid });
        await setDoc(doc(db, 'user_access', uid), {
          ...base, uid, user_group: profile.role, userDocId: docId,
        });
      }
      await setDoc(doc(db, 'orders', 'o-legacy'), {
        orderId: 'o-legacy', salesmanCode: 'S001', branchId: 'B1',
      });
      await setDoc(doc(db, 'orders', 'o-own'), {
        orderId: 'o-own', salesmanUid: actors.salesman.uid, salesmanCode: 'S001', branchId: 'B1',
      });
      await setDoc(doc(db, 'orders', 'o-other'), {
        orderId: 'o-other', salesmanUid: 'someone-else', salesmanCode: 'S002', branchId: 'B2',
      });
    });
  });

  const read = (actor, id) => getDoc(doc(dbFor(actor), 'orders', id));

  it('lets admin and developer read any order', async () => {
    for (const a of [actors.admin, actors.developer]) {
      for (const id of ['o-legacy', 'o-own', 'o-other']) {
        await assertSucceeds(read(a, id));
      }
    }
  });

  it('scopes supervisor to assigned salesmen', async () => {
    await assertSucceeds(read(actors.supervisor, 'o-own'));
    await assertSucceeds(read(actors.supervisor, 'o-legacy'));
    await assertFails(read(actors.supervisor, 'o-other'));
  });

  it('scopes branch manager to their branch', async () => {
    await assertSucceeds(read(actors.manager, 'o-own'));
    await assertSucceeds(read(actors.manager, 'o-legacy'));
    await assertFails(read(actors.manager, 'o-other'));
  });

  it('lets a salesman read own uid rows and own legacy code rows only', async () => {
    await assertSucceeds(read(actors.salesman, 'o-own'));
    await assertSucceeds(read(actors.salesman, 'o-legacy'));
    await assertFails(read(actors.salesman, 'o-other'));
  });

  it('denies suspended and unlinked accounts', async () => {
    await assertFails(read(actors.suspendedAdmin, 'o-own'));
    await assertFails(read(actors.suspendedSalesman, 'o-legacy'));
    await assertFails(read(actors.unlinkedSalesman, 'o-legacy'));
  });
});

describe('own-or-managed record reads with canonical linked profiles', () => {
  const acts = [
    ['admin', {}], ['supervisor', { assignedSalesmanCodes: ['S001'] }],
    ['branch_manager', { branchId: 'B1' }], ['salesman', { employeeCode: 'S001' }],
    ['other_supervisor', { role: 'supervisor', assignedSalesmanCodes: ['S009'] }],
    ['other_branch', { role: 'branch_manager', branchId: 'B2' }],
  ];
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const [k, extra] of acts) {
        const uid = `lk2-${k}`; const id = `${k}@e.test`;
        const base = { status: 'active', role: k, ...extra };
        await setDoc(doc(db, 'users', id), { ...base, uid });
        await setDoc(doc(db, 'user_access', uid), { ...base, uid, user_group: base.role, userDocId: id });
      }
      for (const c of ['visit_briefs', 'conversation_outcomes']) {
        await setDoc(doc(db, c, 'd1'), { salesmanUid: 'lk2-salesman', salesmanCode: 'S001', branchId: 'B1' });
      }
    });
  });

  for (const c of ['visit_briefs', 'conversation_outcomes']) {
    it(`${c}: in-scope roles read, out-of-scope roles do not`, async () => {
      const as = (k) => getDoc(doc(authContext(`lk2-${k}`).firestore(), c, 'd1'));
      for (const k of ['admin', 'supervisor', 'branch_manager', 'salesman']) {
        await assertSucceeds(as(k));
      }
      await assertFails(as('other_supervisor'));
      await assertFails(as('other_branch'));
    });
  }
});

describe('order decisions, view-only branch manager and purchase orders', () => {
  const stamp = Timestamp.fromDate(new Date('2026-06-20T00:00:00Z'));
  const item = (overrides = {}) => ({
    name: 'Orange Juice',
    productId: 'p1',
    price: 10,
    qty: 2,
    ...overrides,
  });
  const seedOrder = async (id, overrides = {}) => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'orders', id), {
        orderId: id,
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        retailerId: 'retailer-1',
        retailerName: 'Retailer One',
        status: 'submitted',
        totalBoxes: 1,
        totalPrice: 20,
        items: [item()],
        submittedAt: stamp,
        createdAt: stamp,
        updatedAt: stamp,
        serverPriceCheck: { status: 'ok', version: 1 },
        ...overrides,
      });
    });
  };
  const approveFields = (actor, role) => ({
    status: 'approved',
    approvedAt: serverTimestamp(),
    approvedByUid: actor.uid,
    approvedByName: 'Actor',
    approvedByRole: role,
    updatedAt: serverTimestamp(),
  });
  const rejectFields = (actor, role, extra = {}) => ({
    status: 'rejected',
    rejectedAt: serverTimestamp(),
    rejectedByUid: actor.uid,
    rejectedByName: 'Actor',
    rejectedByRole: role,
    updatedAt: serverTimestamp(),
    ...extra,
  });
  const poFor = (id, actor, role, overrides = {}) => ({
    poNumber: `PO-20260620-${id}`,
    orderId: id,
    retailerId: 'retailer-1',
    retailerName: 'Retailer One',
    salesmanCode: 'S001',
    salesmanUid: users.salesman.uid,
    branchId: 'B1',
    totalPrice: 20,
    lines: [item()],
    status: 'issued',
    issuedAt: serverTimestamp(),
    issuedByUid: actor.uid,
    issuedByRole: role,
    ...overrides,
  });
  const approveWithPo = (db, id, actor, role, poOverrides = {}) => {
    const batch = writeBatch(db);
    batch.update(doc(db, 'orders', id), approveFields(actor, role));
    batch.set(doc(db, 'purchase_orders', id), poFor(id, actor, role, poOverrides));
    return batch.commit();
  };

  it('keeps the branch manager view-only on orders', async () => {
    await seedOrder('ORD-BM-1');
    await seedOrder('ORD-BM-2');
    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(getDoc(doc(managerDb, 'orders', 'ORD-BM-1')));
    await assertFails(updateDoc(
      doc(managerDb, 'orders', 'ORD-BM-1'),
      approveFields(users.branchManager, 'branch_manager'),
    ));
    await assertFails(updateDoc(
      doc(managerDb, 'orders', 'ORD-BM-2'),
      rejectFields(users.branchManager, 'branch_manager', { rejectionRemark: 'no' }),
    ));
    const batch = writeBatch(managerDb);
    batch.set(doc(managerDb, 'order_audit_logs', 'ORD-BM-1'), {
      action: 'delete',
      orderDocumentId: 'ORD-BM-1',
      orderId: 'ORD-BM-1',
      previousStatus: 'submitted',
      actorUid: users.branchManager.uid,
      actorRole: 'branch_manager',
      retailerId: 'retailer-1',
      salesmanUid: users.salesman.uid,
      occurredAt: serverTimestamp(),
    });
    batch.delete(doc(managerDb, 'orders', 'ORD-BM-1'));
    await assertFails(batch.commit());
  });

  it('lets a supervisor decide but not delete team orders', async () => {
    await seedOrder('ORD-SUP-1');
    await seedOrder('ORD-SUP-2');
    const supervisorDb = dbFor(users.supervisor);
    await assertSucceeds(updateDoc(
      doc(supervisorDb, 'orders', 'ORD-SUP-1'),
      approveFields(users.supervisor, 'supervisor'),
    ));
    const batch = writeBatch(supervisorDb);
    batch.set(doc(supervisorDb, 'order_audit_logs', 'ORD-SUP-2'), {
      action: 'delete',
      orderDocumentId: 'ORD-SUP-2',
      orderId: 'ORD-SUP-2',
      previousStatus: 'submitted',
      actorUid: users.supervisor.uid,
      actorRole: 'supervisor',
      retailerId: 'retailer-1',
      salesmanUid: users.salesman.uid,
      occurredAt: serverTimestamp(),
    });
    batch.delete(doc(supervisorDb, 'orders', 'ORD-SUP-2'));
    await assertFails(batch.commit());
  });

  it('bounds the rejection remark and only allows it on reject', async () => {
    for (const id of ['R-OK', 'R-EMPTY', 'R-LONG', 'R-TYPE', 'R-APPROVE', 'R-NONE']) {
      await seedOrder(id);
    }
    const adminDb = dbFor(users.admin);
    const reject = (id, extra) => updateDoc(
      doc(adminDb, 'orders', id),
      rejectFields(users.admin, 'admin', extra),
    );
    await assertSucceeds(reject('R-OK', { rejectionRemark: 'Out of stock.' }));
    await assertFails(reject('R-EMPTY', { rejectionRemark: '' }));
    await assertFails(reject('R-LONG', { rejectionRemark: 'x'.repeat(501) }));
    await assertFails(reject('R-TYPE', { rejectionRemark: 42 }));
    await assertFails(updateDoc(doc(adminDb, 'orders', 'R-APPROVE'), {
      ...approveFields(users.admin, 'admin'),
      rejectionRemark: 'sneaky',
    }));
    await assertSucceeds(reject('R-NONE', {}));
    await seedOrder('R-MAX');
    await assertSucceeds(reject('R-MAX', { rejectionRemark: 'x'.repeat(500) }));
  });

  it('issues a purchase order atomically with approval (admin and supervisor)', async () => {
    await seedOrder('ORD-PO-ADMIN');
    await seedOrder('ORD-PO-SUP');
    await assertSucceeds(approveWithPo(
      dbFor(users.admin), 'ORD-PO-ADMIN', users.admin, 'admin',
    ));
    await assertSucceeds(approveWithPo(
      dbFor(users.supervisor), 'ORD-PO-SUP', users.supervisor, 'supervisor',
    ));
    const snap = await assertSucceeds(
      getDoc(doc(dbFor(users.admin), 'purchase_orders', 'ORD-PO-ADMIN')),
    );
    assert.equal(snap.data().status, 'issued');
    await assertFails(setDoc(
      doc(dbFor(users.admin), 'purchase_orders', 'ORD-PO-ADMIN'),
      poFor('ORD-PO-ADMIN', users.admin, 'admin'),
    ));
  });

  it('denies purchase orders without an approved order or with forged fields', async () => {
    await seedOrder('ORD-PO-NOAPPROVE');
    const adminDb = dbFor(users.admin);
    await assertFails(setDoc(
      doc(adminDb, 'purchase_orders', 'ORD-PO-NOAPPROVE'),
      poFor('ORD-PO-NOAPPROVE', users.admin, 'admin'),
    ));
    await assertFails(setDoc(
      doc(adminDb, 'purchase_orders', 'ORD-PO-MISSING'),
      poFor('ORD-PO-MISSING', users.admin, 'admin'),
    ));
    await seedOrder('ORD-PO-APPROVED', { status: 'approved' });
    for (const [user, role] of [
      [users.salesman, 'salesman'],
      [users.branchManager, 'branch_manager'],
    ]) {
      await assertFails(setDoc(
        doc(dbFor(user), 'purchase_orders', 'ORD-PO-APPROVED'),
        poFor('ORD-PO-APPROVED', user, role),
      ));
    }
    await seedOrder('ORD-PO-OTHER', {
      status: 'approved', salesmanCode: 'S002', branchId: 'B2',
    });
    await assertFails(setDoc(
      doc(dbFor(users.supervisor), 'purchase_orders', 'ORD-PO-OTHER'),
      poFor('ORD-PO-OTHER', users.supervisor, 'supervisor', {
        salesmanCode: 'S002', branchId: 'B2',
      }),
    ));

    const forgeries = {
      status: { status: 'fulfilled' },
      issuedByUid: { issuedByUid: users.supervisor.uid },
      issuedByRole: { issuedByRole: 'developer' },
      issuedAt: { issuedAt: stamp },
      orderId: { orderId: 'ORD-OTHER' },
      branch: { branchId: 'B2' },
      salesman: { salesmanCode: 'S002' },
      retailer: { retailerId: 'retailer-9' },
      total: { totalPrice: 1 },
      lines: { lines: [item({ price: 1 })] },
      poNumber: { poNumber: 'not a po number' },
      extra: { approvedByAdmin: true },
    };
    for (const [name, override] of Object.entries(forgeries)) {
      await assertFails(setDoc(
        doc(adminDb, 'purchase_orders', 'ORD-PO-APPROVED'),
        poFor('ORD-PO-APPROVED', users.admin, 'admin', override),
      ), `forgery ${name} must be denied`);
    }
    await assertFails(setDoc(
      doc(adminDb, 'purchase_orders', 'PO-RANDOM'),
      poFor('ORD-PO-APPROVED', users.admin, 'admin'),
    ));
    await assertSucceeds(setDoc(
      doc(adminDb, 'purchase_orders', 'ORD-PO-APPROVED'),
      poFor('ORD-PO-APPROVED', users.admin, 'admin'),
    ));
  });

  it('scopes purchase-order reads and limits updates to admin status transitions', async () => {
    await seedOrder('ORD-PO-READ', { status: 'approved' });
    await seedOrder('ORD-PO-READ-B2', {
      status: 'approved', salesmanCode: 'S002', branchId: 'B2',
    });
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      const base = poFor('ORD-PO-READ', users.admin, 'admin', { issuedAt: stamp });
      await setDoc(doc(db, 'purchase_orders', 'ORD-PO-READ'), base);
      await setDoc(doc(db, 'purchase_orders', 'ORD-PO-READ-B2'), {
        ...base, orderId: 'ORD-PO-READ-B2', salesmanCode: 'S002', branchId: 'B2',
      });
    });
    const supervisorDb = dbFor(users.supervisor);
    const managerDb = dbFor(users.branchManager);
    await assertSucceeds(getDoc(doc(dbFor(users.admin), 'purchase_orders', 'ORD-PO-READ-B2')));
    await assertSucceeds(getDoc(doc(supervisorDb, 'purchase_orders', 'ORD-PO-READ')));
    await assertFails(getDoc(doc(supervisorDb, 'purchase_orders', 'ORD-PO-READ-B2')));
    await assertSucceeds(getDoc(doc(managerDb, 'purchase_orders', 'ORD-PO-READ')));
    await assertFails(getDoc(doc(managerDb, 'purchase_orders', 'ORD-PO-READ-B2')));
    await assertFails(getDoc(doc(dbFor(users.salesman), 'purchase_orders', 'ORD-PO-READ')));
    await assertSucceeds(getDocs(query(
      collection(managerDb, 'purchase_orders'), where('branchId', '==', 'B1'),
    )));
    await assertFails(getDocs(collection(managerDb, 'purchase_orders')));

    const transition = (status, actor) => ({
      status,
      statusChangedAt: serverTimestamp(),
      statusChangedByUid: actor.uid,
    });
    for (const user of [users.supervisor, users.branchManager, users.salesman]) {
      await assertFails(updateDoc(
        doc(dbFor(user), 'purchase_orders', 'ORD-PO-READ'),
        transition('fulfilled', user),
      ));
    }
    const adminRef = doc(dbFor(users.admin), 'purchase_orders', 'ORD-PO-READ');
    await assertFails(updateDoc(adminRef, { ...transition('fulfilled', users.admin), totalPrice: 1 }));
    await assertFails(updateDoc(adminRef, transition('issued', users.admin)));
    await assertFails(updateDoc(adminRef, transition('approved', users.admin)));
    await assertSucceeds(updateDoc(adminRef, transition('fulfilled', users.admin)));
    await assertFails(updateDoc(adminRef, transition('cancelled', users.admin)));
    await assertFails(updateDoc(adminRef, transition('issued', users.admin)));
    await assertFails(deleteDoc(adminRef));
  });

  it('stays within the expression budget for canonically linked profiles', async () => {
    const linked = {
      admin: { uid: 'lk3-admin', role: 'admin' },
      supervisor: { uid: 'lk3-sup', role: 'supervisor', assignedSalesmanCodes: ['S001'] },
      manager: { uid: 'lk3-mgr', role: 'branch_manager', branchId: 'B1' },
    };
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const [key, a] of Object.entries(linked)) {
        const { uid, ...profile } = a;
        const base = { status: 'active', ...profile };
        await setDoc(doc(db, 'users', `${key}@e3.test`), { ...base, uid });
        await setDoc(doc(db, 'user_access', uid), {
          ...base, uid, user_group: profile.role, userDocId: `${key}@e3.test`,
        });
      }
    });
    await seedOrder('ORD-LK-ADMIN');
    await seedOrder('ORD-LK-SUP');
    await assertSucceeds(approveWithPo(
      dbFor(linked.admin), 'ORD-LK-ADMIN', linked.admin, 'admin',
    ));
    await assertSucceeds(approveWithPo(
      dbFor(linked.supervisor), 'ORD-LK-SUP', linked.supervisor, 'supervisor',
    ));
    await assertSucceeds(getDoc(doc(dbFor(linked.manager), 'purchase_orders', 'ORD-LK-SUP')));
    await assertSucceeds(updateDoc(
      doc(dbFor(linked.admin), 'purchase_orders', 'ORD-LK-ADMIN'),
      { status: 'cancelled', statusChangedAt: serverTimestamp(), statusChangedByUid: linked.admin.uid },
    ));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'special_requests', 'sr-lk'), specialRequest());
    });
    await assertSucceeds(updateDoc(doc(dbFor(linked.supervisor), 'special_requests', 'sr-lk'), {
      status: 'approved',
      approvalStep: 'Approved',
      lastActorUid: linked.supervisor.uid,
      lastActorRole: 'supervisor',
      lastActionAt: serverTimestamp(),
      updatedAt: serverTimestamp(),
    }));
  });
});

const auditFixtures = require('./identity_audit_fixtures.cjs');

const auditRows = auditFixtures.buildAuditRows({ specialRequest, newVisit });
const auditLabel = (row) => `${row.col} ${row.op}${row.label ? ` (${row.label})` : ''}`;

for (const shape of auditFixtures.SHAPES) {
  describe(`identity budget audit [${shape}]`, () => {
    beforeEach(async () => {
      await testEnv.withSecurityRulesDisabled(async (context) => {
        await auditFixtures.seedAuditActors(context.firestore(), shape);
      });
    });

    auditRows.forEach((row, n) => {
      it(`${auditLabel(row)}: allowed exactly for ${row.allow.join(', ') || 'nobody'}`, async () => {
        const failures = [];
        for (const key of auditFixtures.ACTOR_KEYS) {
          await testEnv.withSecurityRulesDisabled(async (context) => {
            await auditFixtures.resetRowState(context.firestore(), row, key, n);
          });
          const expected = auditFixtures.expectedAllowed(row, key, shape);
          const db = authContext(auditFixtures.AUDIT_ACTORS[key].uid).firestore();
          try {
            await auditFixtures.attemptRow(db, row, key, n);
            if (!expected) failures.push(`${key}: unexpectedly allowed`);
          } catch (err) {
            const msg = String(err && err.message);
            if (auditFixtures.BUDGET.test(msg)) failures.push(`${key}: EXPRESSION BUDGET (${expected ? 'allowed' : 'denied'} op)`);
            else if (expected) failures.push(`${key}: unexpectedly denied (${msg.slice(0, 80)})`);
          }
        }
        assert.deepEqual(failures, []);
      });
    });
  });
}

describe('user_access v2 contract', () => {
  const ADMIN = 'v2c-admin';
  const LEGACY_ADMIN = 'v2c-legacy-admin';
  const SUP = 'v2c-sup';
  const TARGET = 'v2c-target';
  const asUser = (uid) => authContext(uid).firestore();
  const access = (uid, overrides = {}) => ({
    accessVersion: 2,
    uid,
    role: 'admin',
    status: 'active',
    branchId: '',
    employeeCode: '',
    userDocId: `${uid}@v2c.test`,
    ...overrides,
  });
  const mirror = (uid, a) => ({
    uid, role: a.role, user_group: a.role, status: a.status, branchId: a.branchId,
  });
  const salesmanAccess = (uid, overrides = {}) => access(uid, {
    role: 'salesman', branchId: 'B1', employeeCode: 'S777', supervisorUid: SUP, ...overrides,
  });

  async function seedRaw(entries) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const [path, data] of entries) await setDoc(doc(db, ...path.split('/')), data);
    });
  }

  beforeEach(async () => {
    const admin = access(ADMIN, { employeeCode: 'A0001' });
    const sup = access(SUP, {
      role: 'supervisor', branchId: 'B1', employeeCode: 'SV01', assignedSalesmanCodes: ['S001'],
    });
    await seedRaw([
      [`user_access/${ADMIN}`, admin],
      [`users/${ADMIN}@v2c.test`, mirror(ADMIN, admin)],
      [`user_access/${SUP}`, sup],
      [`users/${SUP}@v2c.test`, mirror(SUP, sup)],
      [`users/legacy-admin@v2c.test`, { uid: LEGACY_ADMIN, role: 'admin', status: 'active' }],
      [`user_access/${LEGACY_ADMIN}`, {
        uid: LEGACY_ADMIN, role: 'admin', user_group: 'admin', status: 'active',
        userDocId: 'legacy-admin@v2c.test',
      }],
    ]);
  });

  const adminOnlyRead = (uid) => getDoc(doc(asUser(uid), 'ai_runs', 'probe'));

  it('authorises an active v2 admin from the access document alone', async () => {
    await assertSucceeds(adminOnlyRead(ADMIN));
  });

  for (const [label, overrides] of [
    ['uid field differs from the document id', { uid: 'someone-else' }],
    ['status suspended', { status: 'suspended' }],
    ['role is a legacy alias', { role: 'Administrator' }],
    ['accessVersion is from the future', { accessVersion: 3 }],
  ]) {
    it(`fails closed when a v2 access document has ${label}`, async () => {
      const a = access('v2c-bad');
      for (const [k, v] of Object.entries(overrides)) {
        if (v === undefined) delete a[k]; else a[k] = v;
      }
      await seedRaw([
        ['user_access/v2c-bad', a],
        ['users/v2c-bad@v2c.test', { uid: 'v2c-bad', role: 'admin', status: 'active' }],
      ]);
      await assertFails(adminOnlyRead('v2c-bad'));
    });
  }

  it('fails closed on the v2 salesman alias instead of canonicalising it', async () => {
    await seedRaw([['user_access/v2c-rep', salesmanAccess('v2c-rep', { role: 'sales representative' })]]);
    await assertFails(setDoc(doc(asUser('v2c-rep'), 'visits', 'v2c-rep-visit'), newVisit('v2c-rep')));
    await seedRaw([['user_access/v2c-rep', salesmanAccess('v2c-rep')]]);
    await assertSucceeds(setDoc(doc(asUser('v2c-rep'), 'visits', 'v2c-rep-visit'), newVisit('v2c-rep')));
  });

  it('never consults the display profile for v2 authorisation', async () => {
    await seedRaw([
      ['user_access/v2c-drift', salesmanAccess('v2c-drift')],
      ['users/v2c-drift@v2c.test', { uid: 'v2c-drift', role: 'admin', status: 'active' }],
    ]);
    await assertFails(adminOnlyRead('v2c-drift'));
    await seedRaw([
      ['user_access/v2c-drift2', access('v2c-drift2')],
      ['users/v2c-drift2@v2c.test', { uid: 'v2c-drift2', role: 'admin', status: 'suspended' }],
    ]);
    await assertSucceeds(adminOnlyRead('v2c-drift2'));
  });

  it('does not let a non-list team field widen supervisor scope', async () => {
    await seedRaw([
      ['user_access/v2c-mapsup', access('v2c-mapsup', {
        role: 'supervisor', branchId: 'B9', assignedSalesmanCodes: { S001: true },
      })],
      ['purchase_orders/v2c-po', { salesmanCode: 'S001', branchId: 'B1' }],
    ]);
    await assertFails(getDoc(doc(asUser('v2c-mapsup'), 'purchase_orders', 'v2c-po')));
    await assertSucceeds(getDoc(doc(asUser(SUP), 'purchase_orders', 'v2c-po')));
  });

  it('suspends a v2 user on their very next request', async () => {
    await assertSucceeds(adminOnlyRead(ADMIN));
    const db = asUser(LEGACY_ADMIN);
    const batch = writeBatch(db);
    batch.update(doc(db, 'users', `${ADMIN}@v2c.test`), { status: 'suspended' });
    batch.update(doc(db, 'user_access', ADMIN), { status: 'suspended' });
    await assertFails(batch.commit());
    await assertSucceeds(adminOnlyRead(ADMIN));
    await seedRaw([
      [`users/${ADMIN}@v2c.test`, mirror(ADMIN, access(ADMIN, { status: 'suspended' }))],
      [`user_access/${ADMIN}`, access(ADMIN, { employeeCode: 'A0001', status: 'suspended' })],
    ]);
    await assertFails(adminOnlyRead(ADMIN));
  });

  async function provision(actorUid, uid, a, profile = mirror(uid, a)) {
    const db = asUser(actorUid);
    const batch = writeBatch(db);
    if (profile) batch.set(doc(db, 'users', a.userDocId), profile);
    batch.set(doc(db, 'user_access', uid), a);
    return batch.commit();
  }

  it('refuses to provision a valid v2 user from a client batch', async () => {
    await assertFails(provision(ADMIN, TARGET, salesmanAccess(TARGET)));
    await assertFails(provision(LEGACY_ADMIN, 'v2c-target-2', access('v2c-target-2', {
      role: 'supervisor', branchId: 'B1', assignedSalesmanCodes: ['S001', 'S002'],
    })));
  });

  it('refuses the legacy Role Assignment create for both admin shapes', async () => {
    for (const actor of [ADMIN, LEGACY_ADMIN]) {
      const uid = `${actor}-legacy-new`;
      const code = `S900-${actor}`;
      const db = asUser(actor);
      await assertFails(setDoc(doc(db, 'users', code), {
        uid, role: 'salesman', user_group: 'salesman', status: 'active', employeeCode: 'S900', branchId: 'B1',
      }));
      await assertFails(setDoc(doc(db, 'user_access', uid), {
        uid, userDocId: code, role: 'salesman', user_group: 'salesman', status: 'active',
        isActive: true, employeeCode: 'S900', userId: 'S900', branchId: 'B1', branch_id: 'B1',
      }));
    }
  });

  const editPlanted = async (a, profile = mirror(a.uid || TARGET, a)) => {
    await seedRaw([[`user_access/${TARGET}`, a], ...(a.userDocId && profile ? [[`users/${a.userDocId}`, profile]] : [])]);
    return updateDoc(doc(asUser(ADMIN), 'user_access', TARGET), { note: 'edited' });
  };

  for (const [label, a] of [
    ['uid differs from the document id', salesmanAccess(TARGET, { uid: 'other' })],
    ['a non-canonical role', salesmanAccess(TARGET, { role: 'sales representative' })],
    ['a team on a salesman', salesmanAccess(TARGET, { assignedSalesmanCodes: ['S001'] })],
    ['a supervisorUid on a supervisor', access(TARGET, {
      role: 'supervisor', branchId: 'B1', assignedSalesmanCodes: [], supervisorUid: SUP,
    })],
    ['six salesmen on one supervisor', access(TARGET, {
      role: 'supervisor', branchId: 'B1', assignedSalesmanCodes: ['S1', 'S2', 'S3', 'S4', 'S5', 'S6'],
    })],
    ['a seatClass that contradicts the role', salesmanAccess(TARGET, { seatClass: 'free' })],
  ]) {
    it(`rejects an edit of a v2 access document with ${label}`, async () => {
      await assertFails(editPlanted(a, a.userDocId ? mirror(TARGET, a) : null));
    });
  }

  it('accepts the reserved optional orgId and seatClass fields', async () => {
    await assertSucceeds(editPlanted(salesmanAccess(TARGET, { orgId: 'org-1', seatClass: 'salesperson' })));
    await assertSucceeds(editPlanted(access(TARGET, { seatClass: 'free' })));
    await assertSucceeds(editPlanted(salesmanAccess(TARGET, { seatClass: 'salesman' })));
  });

  it('accepts exactly five salesmen on one supervisor', async () => {
    await assertSucceeds(editPlanted(access(TARGET, {
      role: 'supervisor', branchId: 'B1', assignedSalesmanCodes: ['S1', 'S2', 'S3', 'S4', 'S5'],
    })));
  });

  it('rejects a sixth supervisor assignment without partially updating linked records', async () => {
    const fullTeam = ['S001', 'S002', 'S003', 'S004', 'S005'];
    const supervisorProfileId = `${SUP}@v2c.test`;
    const targetProfileId = `${TARGET}@v2c.test`;
    const supervisorAccess = access(SUP, {
      role: 'supervisor',
      branchId: 'B1',
      employeeCode: 'SV01',
      assignedSalesmanCodes: fullTeam,
    });
    const targetAccess = salesmanAccess(TARGET, {
      employeeCode: 'S006',
      supervisorUid: '',
    });
    const supervisorProfile = {
      ...mirror(SUP, supervisorAccess),
      employeeCode: 'SV01',
      assignedSalesmanCodes: fullTeam,
    };
    const targetProfile = {
      ...mirror(TARGET, targetAccess),
      employeeCode: 'S006',
      supervisorId: '',
      supervisor_id: '',
    };
    await seedRaw([
      [`users/${supervisorProfileId}`, supervisorProfile],
      [`user_access/${SUP}`, supervisorAccess],
      [`users/${targetProfileId}`, targetProfile],
      [`user_access/${TARGET}`, targetAccess],
    ]);

    const db = asUser(ADMIN);
    const batch = writeBatch(db);
    batch.update(doc(db, 'users', targetProfileId), {
      supervisorId: 'SV01',
      supervisor_id: 'SV01',
    });
    batch.update(doc(db, 'user_access', TARGET), {
      supervisorUid: SUP,
      supervisorId: 'SV01',
      supervisor_id: 'SV01',
    });
    batch.update(doc(db, 'users', supervisorProfileId), {
      assignedSalesmanCodes: arrayUnion('S006'),
    });
    batch.update(doc(db, 'user_access', SUP), {
      assignedSalesmanCodes: arrayUnion('S006'),
    });
    await assertFails(batch.commit());

    let after;
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      const [salesmanProfile, salesmanAccess, supervisor, supervisorIndex] =
        await Promise.all([
          getDoc(doc(db, 'users', targetProfileId)),
          getDoc(doc(db, 'user_access', TARGET)),
          getDoc(doc(db, 'users', supervisorProfileId)),
          getDoc(doc(db, 'user_access', SUP)),
        ]);
      after = {
        salesmanProfile: salesmanProfile.data(),
        salesmanAccess: salesmanAccess.data(),
        supervisor: supervisor.data(),
        supervisorIndex: supervisorIndex.data(),
      };
    });
    assert.deepEqual(after.salesmanProfile, targetProfile);
    assert.deepEqual(after.salesmanAccess, targetAccess);
    assert.deepEqual(after.supervisor, supervisorProfile);
    assert.deepEqual(after.supervisorIndex, supervisorAccess);
  });

  it('allows an atomic supervisor assignment that fills the fifth seat', async () => {
    const currentTeam = ['S001', 'S002', 'S003', 'S004'];
    const supervisorProfileId = `${SUP}@v2c.test`;
    const targetProfileId = `${TARGET}@v2c.test`;
    const supervisorAccess = access(SUP, {
      role: 'supervisor',
      branchId: 'B1',
      employeeCode: 'SV01',
      assignedSalesmanCodes: currentTeam,
    });
    const targetAccess = salesmanAccess(TARGET, {
      employeeCode: 'S005',
      supervisorUid: '',
    });
    const supervisorProfile = {
      ...mirror(SUP, supervisorAccess),
      employeeCode: 'SV01',
      assignedSalesmanCodes: currentTeam,
    };
    const targetProfile = {
      ...mirror(TARGET, targetAccess),
      employeeCode: 'S005',
      supervisorId: '',
      supervisor_id: '',
    };
    await seedRaw([
      [`users/${supervisorProfileId}`, supervisorProfile],
      [`user_access/${SUP}`, supervisorAccess],
      [`users/${targetProfileId}`, targetProfile],
      [`user_access/${TARGET}`, targetAccess],
    ]);

    const db = asUser(ADMIN);
    const batch = writeBatch(db);
    batch.update(doc(db, 'users', targetProfileId), {
      supervisorId: 'SV01',
      supervisor_id: 'SV01',
    });
    batch.update(doc(db, 'user_access', TARGET), {
      supervisorUid: SUP,
      supervisorId: 'SV01',
      supervisor_id: 'SV01',
    });
    batch.update(doc(db, 'users', supervisorProfileId), {
      assignedSalesmanCodes: arrayUnion('S005'),
    });
    batch.update(doc(db, 'user_access', SUP), {
      assignedSalesmanCodes: arrayUnion('S005'),
    });
    await assertSucceeds(batch.commit());

    let after;
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      const [salesmanProfile, salesmanAccess, supervisor, supervisorIndex] =
        await Promise.all([
          getDoc(doc(db, 'users', targetProfileId)),
          getDoc(doc(db, 'user_access', TARGET)),
          getDoc(doc(db, 'users', supervisorProfileId)),
          getDoc(doc(db, 'user_access', SUP)),
        ]);
      after = {
        salesmanProfile: salesmanProfile.data(),
        salesmanAccess: salesmanAccess.data(),
        supervisor: supervisor.data(),
        supervisorIndex: supervisorIndex.data(),
      };
    });
    assert.equal(after.salesmanProfile.supervisorId, 'SV01');
    assert.equal(after.salesmanAccess.supervisorUid, SUP);
    assert.deepEqual(after.supervisor.assignedSalesmanCodes, [
      ...currentTeam,
      'S005',
    ]);
    assert.deepEqual(after.supervisorIndex.assignedSalesmanCodes, [
      ...currentTeam,
      'S005',
    ]);
  });

  it('rejects a v2 record whose display profile disagrees on role or status', async () => {
    const a = salesmanAccess(TARGET);
    await assertFails(editPlanted(a, { ...mirror(TARGET, a), role: 'admin', user_group: 'admin' }));
    await assertFails(editPlanted(a, { ...mirror(TARGET, a), status: 'suspended' }));
    await assertFails(editPlanted(a, null));
  });

  it('refuses to downgrade a v2 record to the legacy shape', async () => {
    await assertSucceeds(editPlanted(salesmanAccess(TARGET)));
    const db = asUser(ADMIN);
    await assertFails(updateDoc(doc(db, 'user_access', TARGET), { accessVersion: deleteField() }));
    await assertFails(updateDoc(doc(db, 'user_access', TARGET), { accessVersion: 1 }));
    await assertFails(setDoc(doc(db, 'user_access', TARGET), {
      uid: TARGET, userDocId: `${TARGET}@v2c.test`, role: 'salesman', status: 'active',
    }));
    await assertFails(updateDoc(doc(db, 'user_access', TARGET), { employeeCode: 'S778' }));
    await assertSucceeds(updateDoc(doc(db, 'user_access', TARGET), { orgId: 'org-1' }));
  });

  for (const [key, value] of [
    ['role', 'developer'],
    ['status', 'suspended'],
    ['branchId', 'B9'],
    ['supervisorUid', 'v2c-other'],
    ['assignedSalesmanCodes', ['S001']],
    ['employeeCode', 'A0002'],
  ]) {
    it(`refuses a self-edit of ${key} on the caller's own access record`, async () => {
      await assertFails(updateDoc(doc(asUser(ADMIN), 'user_access', ADMIN), { [key]: value }));
    });
  }

  it('still allows a harmless self-edit of the own access record', async () => {
    await assertSucceeds(updateDoc(doc(asUser(ADMIN), 'user_access', ADMIN), { email: 'a@v2c.test' }));
  });

  it('refuses access-record writes by non-admins, own or foreign', async () => {
    await seedRaw([[`user_access/${TARGET}`, salesmanAccess(TARGET)]]);
    await assertFails(updateDoc(doc(asUser(SUP), 'user_access', TARGET), { branchId: 'B2' }));
    await assertFails(updateDoc(doc(asUser(SUP), 'user_access', SUP), {
      assignedSalesmanCodes: ['S001', 'S777'],
    }));
    await assertFails(provision(SUP, 'v2c-new', salesmanAccess('v2c-new')));
  });
});

describe('one caller identity for actor-role audit fields', () => {
  const UID = 'rs-sup';
  beforeEach(async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'users', 'rs-sup@rs.test'), {
        uid: UID, role: 'supervisor', status: 'active', assignedSalesmanCodes: ['S001'], branchId: 'B1',
      });
      await setDoc(doc(db, 'user_access', UID), {
        uid: UID, role: 'admin', user_group: 'admin', status: 'active', userDocId: 'rs-sup@rs.test',
      });
      await setDoc(doc(db, 'orders', 'ORD-RS'), {
        orderId: 'ORD-RS', salesmanCode: 'S001', salesmanUid: 'sales-1', status: 'submitted',
        serverPriceCheck: { status: 'ok', version: 1 }, retailerId: 'retailer-1', items: [{ productId: 'p1', quantity: 1 }], totalBoxes: 1, totalPrice: 20,
      });
    });
  });
  const approve = (role) => updateDoc(
    doc(authContext(UID).firestore(), 'orders', 'ORD-RS'),
    {
      status: 'approved', approvedAt: serverTimestamp(), approvedByUid: UID,
      approvedByRole: role, updatedAt: serverTimestamp(),
    },
  );

  it('rejects the access-index role and accepts the resolved role', async () => {
    await assertFails(approve('admin'));
    await assertSucceeds(approve('supervisor'));
  });
});

describe('scenario namespace authorization', () => {
  const RUN_ID = 'scenario-rules-run';
  const actors = {
    admin: {
      uid: 'scenario-admin', role: 'admin', branchId: '', employeeCode: '',
      assignedSalesmanCodes: [],
    },
    developer: {
      uid: 'scenario-developer', role: 'developer', branchId: '', employeeCode: '',
      assignedSalesmanCodes: [],
    },
    supervisor: {
      uid: 'scenario-supervisor', role: 'supervisor', branchId: 'B1', employeeCode: 'SV01',
      assignedSalesmanCodes: ['S001'],
    },
    manager: {
      uid: 'scenario-manager', role: 'branch_manager', branchId: 'B1', employeeCode: '',
      assignedSalesmanCodes: [],
    },
    salesman: {
      uid: 'scenario-salesman', role: 'salesman', branchId: 'B1', employeeCode: 'S001',
      assignedSalesmanCodes: [],
    },
    otherSalesman: {
      uid: 'scenario-other-salesman', role: 'salesman', branchId: 'B2', employeeCode: 'S002',
      assignedSalesmanCodes: [],
    },
    suspended: {
      uid: 'scenario-suspended', role: 'salesman', status: 'suspended', branchId: 'B1',
      employeeCode: 'S003', assignedSalesmanCodes: [],
    },
    unlinked: {
      uid: 'scenario-unlinked', role: 'salesman', branchId: 'B1', employeeCode: 'S004',
      assignedSalesmanCodes: [], legacy: true,
    },
    noIndex: {
      uid: 'scenario-no-index', role: 'salesman', branchId: 'B1', employeeCode: 'S005',
      assignedSalesmanCodes: [],
    },
  };

  const dbForActor = (actor) => authContext(actor.uid).firestore();
  const accessId = (uid, runId = RUN_ID) => `${uid}_${runId}`;
  const scenarioRun = (
    state = 'preparing',
    createdByUid = actors.admin.uid,
    runId = RUN_ID,
  ) => ({
    runId,
    targetProjectId: 'cos40005',
    generatorVersion: 'scenario-test-v1',
    seed: 20261003,
    scenarioAsOfDate: '2026-10-03',
    timeZone: 'Asia/Kuala_Lumpur',
    rangeStart: '2024-10-01',
    rangeEnd: '2026-09-30',
    sourceSnapshotHash: 'a'.repeat(64),
    counts: { visits: 1, orders: 0 },
    createdByUid,
    createdAt: serverTimestamp(),
    readyAt: null,
    state,
  });
  const scenarioIndex = (actor, runId = RUN_ID) => ({
    uid: actor.uid,
    runId,
    role: actor.role,
    branchId: actor.branchId,
    salesmanUid: actor.role === 'salesman' ? actor.uid : '',
    salesmanCode: actor.employeeCode,
    assignedSalesmanCodes: actor.assignedSalesmanCodes,
  });
  const scenarioVisit = (
    id,
    actor,
    retailerId,
    branchId,
    outcomeCode = 'supplier_issue',
    orderId = '',
  ) => ({
    visitId: id,
    scenarioRunId: RUN_ID,
    synthetic: true,
    salesmanUid: actor.uid,
    salesmanCode: actor.employeeCode,
    branchId,
    retailerId,
    retailerName: 'Scenario retailer',
    status: 'completed',
    visitedAt: Timestamp.now(),
    completedAt: Timestamp.now(),
    outcomeCode,
    orderId,
  });

  async function seedScenario(state = 'ready') {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const actor of Object.values(actors)) {
        if (actor.legacy) {
          await setDoc(doc(db, 'user_access', actor.uid), {
            uid: actor.uid,
            role: actor.role,
            status: 'active',
            branchId: actor.branchId,
            employeeCode: actor.employeeCode,
            userDocId: `${actor.uid}@missing.test`,
          });
        } else {
          await setDoc(doc(db, 'user_access', actor.uid), {
            accessVersion: 2,
            uid: actor.uid,
            role: actor.role,
            status: actor.status || 'active',
            branchId: actor.branchId,
            employeeCode: actor.employeeCode,
            assignedSalesmanCodes: actor.assignedSalesmanCodes,
          });
        }
        if (actor !== actors.noIndex) {
          await setDoc(
            doc(db, 'scenario_run_access', accessId(actor.uid)),
            scenarioIndex(actor),
          );
        }
      }
      await setDoc(doc(db, 'scenario_runs', RUN_ID), {
        ...scenarioRun(state),
        createdAt: Timestamp.now(),
        readyAt: state === 'ready' ? Timestamp.now() : null,
      });
      await setDoc(
        doc(db, 'scenario_runs', RUN_ID, 'visits', 'visit-own'),
        scenarioVisit('visit-own', actors.salesman, 'scenario-retailer-b1', 'B1'),
      );
      await setDoc(
        doc(db, 'scenario_runs', RUN_ID, 'visits', 'visit-other'),
        scenarioVisit('visit-other', actors.otherSalesman, 'scenario-retailer-b2', 'B2'),
      );
      const duplicateCodeOtherBranch = scenarioVisit(
        'visit-duplicate-code-other-branch',
        actors.otherSalesman,
        'scenario-retailer-b2',
        'B2',
      );
      duplicateCodeOtherBranch.salesmanCode = 'S001';
      await setDoc(
        doc(
          db,
          'scenario_runs',
          RUN_ID,
          'visits',
          'visit-duplicate-code-other-branch',
        ),
        duplicateCodeOtherBranch,
      );
      await setDoc(doc(db, 'scenario_runs', RUN_ID, 'weekly_coverage', 'retailer-b1'), {
        coverageId: 'retailer-b1',
        scenarioRunId: RUN_ID,
        synthetic: true,
        scopeType: 'retailer',
        retailerId: 'scenario-retailer-b1',
        salesmanUid: actors.salesman.uid,
        salesmanCode: actors.salesman.employeeCode,
        branchId: 'B1',
        weekStart: '2026-09-28',
        coverageStatus: 'active_assigned',
        activityStatus: 'no_visit',
      });
      await setDoc(doc(db, 'scenario_runs', RUN_ID, 'plans', 'scenario-plan'), {
        planId: 'scenario-plan',
        scenarioRunId: RUN_ID,
        synthetic: true,
        status: 'published',
        salesmanUid: actors.salesman.uid,
        salesmanCode: actors.salesman.employeeCode,
        branchId: actors.salesman.branchId,
        stopIds: ['stop-1'],
        stopRetailerIds: { 'stop-1': 'scenario-retailer-b1' },
      });
      const routeProgressId = `scenario-plan_${actors.salesman.uid}`;
      await setDoc(
        doc(db, 'scenario_runs', RUN_ID, 'route_plan_progress', routeProgressId),
        {
          progressId: routeProgressId,
          planId: 'scenario-plan',
          scenarioRunId: RUN_ID,
          synthetic: true,
          salesmanUid: actors.salesman.uid,
          salesmanCode: actors.salesman.employeeCode,
          branchId: actors.salesman.branchId,
          status: 'not_started',
          completedStopCount: 0,
          skippedStopCount: 0,
        },
      );
      await setDoc(
        doc(
          db,
          'scenario_runs', RUN_ID, 'route_stop_progress',
          `${routeProgressId}_stop-1`,
        ),
        {
          planId: 'scenario-plan',
          stopId: 'stop-1',
          scenarioRunId: RUN_ID,
          synthetic: true,
          salesmanUid: actors.salesman.uid,
          salesmanCode: actors.salesman.employeeCode,
          branchId: actors.salesman.branchId,
          retailerId: 'scenario-retailer-b1',
          status: 'pending',
          visitId: '',
          orderId: '',
        },
      );
      await setDoc(doc(db, 'retailers', 'scenario-retailer-b1'), {
        retailerId: 'scenario-retailer-b1', status: 'active', isActive: true,
        branchId: 'B1', assignedSalesmanId: 'S001',
      });
      await setDoc(doc(db, 'retailers', 'scenario-retailer-b2'), {
        retailerId: 'scenario-retailer-b2', status: 'active', isActive: true,
        branchId: 'B2', assignedSalesmanId: 'S002',
      });
      await setDoc(doc(db, 'products', 'scenario-product'), {
        productId: 'scenario-product',
        productName: 'TENTEN Food',
        brandName: 'TENTEN',
        departmentName: 'Food',
        status: 'active',
        isActive: true,
        isVisible: true,
        unitPrice: 2.5,
        packingSize: 'box',
        uom: 'ctn',
      });
    });
  }

  it('limits run, access-index, and seed creation to active admins and developers', async () => {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const actor of [
        actors.admin,
        actors.developer,
        actors.supervisor,
        actors.salesman,
      ]) {
        await setDoc(doc(db, 'user_access', actor.uid), {
          accessVersion: 2,
          uid: actor.uid,
          role: actor.role,
          status: 'active',
          branchId: actor.branchId,
          employeeCode: actor.employeeCode,
          assignedSalesmanCodes: actor.assignedSalesmanCodes,
        });
      }
    });
    const adminDb = dbForActor(actors.admin);
    await assertSucceeds(
      setDoc(doc(adminDb, 'scenario_runs', RUN_ID), scenarioRun()),
    );
    await assertSucceeds(
      setDoc(
        doc(adminDb, 'scenario_run_access', accessId(actors.salesman.uid)),
        scenarioIndex(actors.salesman),
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(adminDb, 'scenario_runs', RUN_ID, 'weekly_coverage', 'seed-row'),
        {
          coverageId: 'seed-row', scenarioRunId: RUN_ID, synthetic: true,
          scopeType: 'salesperson', salesmanUid: actors.salesman.uid,
          salesmanCode: 'S001', branchId: 'B1', weekStart: '2026-09-28',
          coverageStatus: 'active', activityStatus: 'no_visit',
        },
      ),
    );

    const supervisorDb = dbForActor(actors.supervisor);
    await assertFails(
      setDoc(
        doc(supervisorDb, 'scenario_runs', 'manager-created-run'),
        scenarioRun('preparing', actors.supervisor.uid),
      ),
    );
    await assertFails(
      setDoc(
        doc(dbForActor(actors.salesman), 'scenario_run_access', accessId(actors.salesman.uid)),
        scenarioIndex(actors.salesman),
      ),
    );
    await assertFails(
      setDoc(
        doc(supervisorDb, 'scenario_runs', RUN_ID, 'weekly_coverage', 'manager-seed'),
        { coverageId: 'manager-seed', scenarioRunId: RUN_ID, synthetic: true },
      ),
    );

    await assertSucceeds(
      updateDoc(doc(adminDb, 'scenario_runs', RUN_ID), {
        state: 'ready', readyAt: serverTimestamp(),
      }),
    );
    await assertFails(
      updateDoc(doc(adminDb, 'scenario_runs', RUN_ID), { targetProjectId: 'other-project' }),
    );

    const developerDb = dbForActor(actors.developer);
    const developerRunId = 'scenario-developer-seed-run';
    await assertSucceeds(
      setDoc(
        doc(developerDb, 'scenario_runs', developerRunId),
        scenarioRun('preparing', actors.developer.uid, developerRunId),
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(
          developerDb,
          'scenario_run_access',
          accessId(actors.developer.uid, developerRunId),
        ),
        scenarioIndex(actors.developer, developerRunId),
      ),
    );
    await assertSucceeds(
      setDoc(
        doc(developerDb, 'scenario_runs', developerRunId, 'activity_weeks', 'seed-row'),
        { activityWeekId: 'seed-row', scenarioRunId: developerRunId, synthetic: true },
      ),
    );
    await assertSucceeds(
      updateDoc(doc(developerDb, 'scenario_runs', developerRunId), {
        state: 'ready',
        readyAt: serverTimestamp(),
      }),
    );
  });

  it('requires the caller-owned index and applies current salesperson, team, and branch scope', async () => {
    await seedScenario();
    const salesmanDb = dbForActor(actors.salesman);
    const supervisorDb = dbForActor(actors.supervisor);
    const managerDb = dbForActor(actors.manager);

    const ownRunIndexes = await assertSucceeds(
      getDocs(query(
        collection(salesmanDb, 'scenario_run_access'),
        where('uid', '==', actors.salesman.uid),
      )),
    );
    assert.deepEqual(ownRunIndexes.docs.map((snapshot) => snapshot.id), [
      accessId(actors.salesman.uid),
    ]);

    await assertSucceeds(getDoc(doc(salesmanDb, 'scenario_runs', RUN_ID)));
    await assertSucceeds(
      getDoc(doc(salesmanDb, 'scenario_runs', RUN_ID, 'visits', 'visit-own')),
    );
    await assertFails(
      getDoc(doc(salesmanDb, 'scenario_runs', RUN_ID, 'visits', 'visit-other')),
    );
    const ownVisits = await assertSucceeds(
      getDocs(query(
        collection(salesmanDb, 'scenario_runs', RUN_ID, 'visits'),
        where('scenarioRunId', '==', RUN_ID),
        where('synthetic', '==', true),
        where('salesmanUid', '==', actors.salesman.uid),
        where('salesmanCode', '==', 'S001'),
        where('branchId', '==', 'B1'),
      )),
    );
    assert.deepEqual(ownVisits.docs.map((snapshot) => snapshot.id), ['visit-own']);

    await assertSucceeds(
      getDoc(doc(supervisorDb, 'scenario_runs', RUN_ID, 'visits', 'visit-own')),
    );
    await assertFails(
      getDoc(doc(supervisorDb, 'scenario_runs', RUN_ID, 'visits', 'visit-other')),
    );
    await assertFails(
      getDoc(
        doc(
          supervisorDb,
          'scenario_runs',
          RUN_ID,
          'visits',
          'visit-duplicate-code-other-branch',
        ),
      ),
    );
    const teamVisits = await assertSucceeds(
      getDocs(query(
        collection(supervisorDb, 'scenario_runs', RUN_ID, 'visits'),
        where('scenarioRunId', '==', RUN_ID),
        where('synthetic', '==', true),
        where('salesmanCode', '==', 'S001'),
        where('branchId', '==', 'B1'),
      )),
    );
    assert.deepEqual(teamVisits.docs.map((snapshot) => snapshot.id), ['visit-own']);
    await assertFails(
      getDocs(collection(supervisorDb, 'scenario_runs', RUN_ID, 'visits')),
    );

    await assertSucceeds(
      getDoc(doc(managerDb, 'scenario_runs', RUN_ID, 'visits', 'visit-own')),
    );
    await assertFails(
      getDoc(doc(managerDb, 'scenario_runs', RUN_ID, 'visits', 'visit-other')),
    );
    await assertSucceeds(
      getDoc(doc(managerDb, 'scenario_runs', RUN_ID, 'weekly_coverage', 'retailer-b1')),
    );
    await assertSucceeds(
      getDoc(doc(supervisorDb, 'scenario_runs', RUN_ID, 'weekly_coverage', 'retailer-b1')),
    );
    await assertFails(
      getDoc(doc(salesmanDb, 'scenario_runs', RUN_ID, 'weekly_coverage', 'retailer-b1')),
    );
    await assertFails(
      getDoc(doc(dbForActor(actors.noIndex), 'scenario_runs', RUN_ID)),
    );
    await assertFails(
      getDoc(doc(dbForActor(actors.suspended), 'scenario_runs', RUN_ID)),
    );
    await assertFails(
      getDoc(doc(dbForActor(actors.unlinked), 'scenario_runs', RUN_ID)),
    );
    await assertFails(
      getDoc(
        doc(salesmanDb, 'scenario_run_access', accessId(actors.supervisor.uid)),
      ),
    );
  });

  it('uses the escaped percent namespace for a caller-owned access index', async () => {
    await seedScenario();
    const actor = {
      uid: 'scenario%percent-owner',
      role: 'salesman',
      branchId: 'B1',
      employeeCode: 'S001',
      assignedSalesmanCodes: [],
    };
    const escapedAccessId = `scenario%25percent-owner_${RUN_ID}`;
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      await setDoc(doc(db, 'user_access', actor.uid), {
        accessVersion: 2,
        uid: actor.uid,
        role: actor.role,
        status: 'active',
        branchId: actor.branchId,
        employeeCode: actor.employeeCode,
        assignedSalesmanCodes: actor.assignedSalesmanCodes,
      });
      await setDoc(
        doc(db, 'scenario_run_access', escapedAccessId),
        scenarioIndex(actor),
      );
    });

    const db = dbForActor(actor);
    await assertSucceeds(getDoc(doc(db, 'scenario_runs', RUN_ID)));
    const ownIndex = await assertSucceeds(
      getDoc(doc(db, 'scenario_run_access', escapedAccessId)),
    );
    assert.equal(ownIndex.data().uid, actor.uid);
    assert.equal(ownIndex.data().runId, RUN_ID);
    await assertFails(
      getDoc(doc(db, 'scenario_run_access', `${actor.uid}_${RUN_ID}`)),
    );
  });

  it('blocks stale-scope and non-ready run access', async () => {
    await seedScenario();
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'user_access', actors.supervisor.uid), {
        assignedSalesmanCodes: ['S002'],
      });
    });
    await assertFails(
      getDoc(
        doc(
          dbForActor(actors.supervisor),
          'scenario_runs', RUN_ID, 'visits', 'visit-own',
        ),
      ),
    );

    await seedScenario('preparing');
    await assertFails(
      getDoc(doc(dbForActor(actors.salesman), 'scenario_runs', RUN_ID)),
    );
    await assertSucceeds(
      getDoc(doc(dbForActor(actors.admin), 'scenario_runs', RUN_ID)),
    );
  });

  it('keeps historical scenario events immutable and scopes route progress writes', async () => {
    await seedScenario();
    const salesmanDb = dbForActor(actors.salesman);
    const now = Timestamp.now();
    const ownVisit = scenarioVisit(
      'visit-new', actors.salesman, 'scenario-retailer-b1', 'B1',
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'scenario_runs', RUN_ID, 'visits', 'visit-new'), ownVisit),
    );
    await assertFails(
      setDoc(
        doc(salesmanDb, 'scenario_runs', RUN_ID, 'visits', 'visit-for-other'),
        scenarioVisit('visit-for-other', actors.otherSalesman, 'scenario-retailer-b2', 'B2'),
      ),
    );
    await assertFails(
      setDoc(
        doc(salesmanDb, 'scenario_runs', RUN_ID, 'conversation_outcomes', 'outcome-new'),
        {
          outcomeId: 'outcome-new', visitId: 'visit-new',
          scenarioRunId: RUN_ID, synthetic: true,
          salesmanUid: actors.salesman.uid, salesmanCode: 'S001', branchId: 'B1',
          retailerId: 'scenario-retailer-b1', reasonCode: 'supplier_issue',
          submittedAt: now, createdAt: now,
        },
      ),
    );
    await assertFails(
      setDoc(
        doc(salesmanDb, 'scenario_runs', RUN_ID, 'orders', 'order_visit-order'),
        {
          orderId: 'order_visit-order', visitId: 'visit-order',
          scenarioRunId: RUN_ID, synthetic: true,
          salesmanUid: actors.salesman.uid, salesmanCode: 'S001', branchId: 'B1',
          retailerId: 'scenario-retailer-b1', status: 'submitted', submittedAt: now,
          items: [{
            productId: 'scenario-product', productName: 'TENTEN Food',
            category: 'Food', packingSize: 'box', unitOfMeasure: 'ctn',
            quantity: 1, qty: 1, price: 2.5, unitPrice: 2.5, lineTotal: 2.5,
          }],
          totalQuantity: 1, totalAmount: 2.5,
        },
      ),
    );

    const routeProgressId = `scenario-plan_${actors.salesman.uid}`;
    const routeProgress = doc(
      salesmanDb,
      'scenario_runs', RUN_ID, 'route_plan_progress', routeProgressId,
    );
    const stopProgress = doc(
      salesmanDb,
      'scenario_runs', RUN_ID, 'route_stop_progress',
      `${routeProgressId}_stop-1`,
    );
    await assertSucceeds(getDoc(routeProgress));
    await assertSucceeds(getDoc(stopProgress));
    await assertFails(updateDoc(routeProgress, {
      status: 'completed',
      completedStopCount: -1,
      updatedAt: now,
    }));
    await assertFails(updateDoc(routeProgress, {
      selectedStopId: 'stop-not-in-plan',
      updatedAt: now,
    }));
    await assertFails(updateDoc(stopProgress, {
      status: 'completed',
      visitId: 'missing-visit',
      orderId: 'missing-order',
      updatedAt: now,
    }));

    await assertFails(
      setDoc(
        doc(dbForActor(actors.supervisor), 'scenario_runs', RUN_ID, 'visits', 'manager-visit'),
        scenarioVisit('manager-visit', actors.supervisor, 'scenario-retailer-b1', 'B1'),
      ),
    );
    await assertFails(
      updateDoc(
        doc(salesmanDb, 'scenario_runs', RUN_ID, 'plans', 'scenario-plan'),
        { status: 'draft' },
      ),
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'route_plans', 'production-scenario-plan'), {
        planId: 'production-scenario-plan', status: 'draft', salesmanUid: actors.salesman.uid,
      }),
    );
    await assertFails(
      setDoc(doc(salesmanDb, 'ai_insights', 'production-scenario-insight'), {
        issueId: 'production-scenario-insight', synthetic: true, scenarioRunId: RUN_ID,
      }),
    );
  });
});

describe('supervisor route publishing and view-only branch manager', () => {
  const PLAN_ID = 'ux-sup-plan';
  const KEY_ID = users.salesman.uid + '_20260921';

  function draftFor(actor) {
    return {
      planId: PLAN_ID,
      createdByUid: actor.uid,
      salesmanUid: users.salesman.uid,
      salesmanCode: 'S001',
      branchId: 'B1',
      weekStart: Timestamp.fromDate(new Date('2026-09-21T00:00:00Z')),
      status: 'draft',
      stopIds: ['stop-1', 'stop-2'],
      stopRetailerIds: { 'stop-1': 'retailer-1', 'stop-2': 'retailer-2' },
      totalStops: 2,
    };
  }

  async function seedAccess(user, extra) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      const email = `${user.uid}@example.test`;
      await setDoc(doc(db, 'users', email), {
        uid: user.uid,
        userUid: user.uid,
        email,
        ...user.profile,
        user_group: user.profile.role,
        userId: user.uid,
        ...extra,
      });
      await setDoc(doc(db, 'user_access', user.uid), {
        uid: user.uid,
        userDocId: email,
        email,
        ...user.profile,
        user_group: user.profile.role,
        userId: user.uid,
        ...extra,
      });
    });
  }

  async function seedPlan(status) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftFor(users.admin),
        status,
      });
    });
  }

  function publishCommit(db, actor) {
    return runTransaction(db, async (transaction) => {
      const planSnapshot = await transaction.get(doc(db, 'route_plans', PLAN_ID));
      if (!planSnapshot.exists()) throw new Error('plan missing');
      await transaction.get(doc(db, 'route_plan_publication_keys', KEY_ID));
      transaction.update(doc(db, 'route_plans', PLAN_ID), {
        status: 'published',
        publicationKeyId: KEY_ID,
        updatedAt: serverTimestamp(),
        publishedAt: serverTimestamp(),
      });
      transaction.set(doc(db, 'route_plan_publication_keys', KEY_ID), {
        keyId: KEY_ID,
        planId: PLAN_ID,
        salesmanIdentity: users.salesman.uid,
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        weekKey: '20260921',
        active: true,
        updatedByUid: actor.uid,
      });
    });
  }

  beforeEach(async () => {
    await seedAccess(users.supervisor, { employeeCode: 'SUP1' });
    await seedAccess(users.unassignedSupervisor, { employeeCode: 'SUP2' });
    await seedAccess(users.branchManager, { employeeCode: 'BM1' });
  });

  it('a supervisor with the salesman in their team can create, approve and publish', async () => {
    const db = dbFor(users.supervisor);
    const planRef = doc(db, 'route_plans', PLAN_ID);
    await assertSucceeds(setDoc(planRef, draftFor(users.supervisor)));
    await assertSucceeds(
      updateDoc(planRef, { status: 'approved', updatedAt: serverTimestamp() }),
    );
    await assertSucceeds(publishCommit(db, users.supervisor));
  });

  it('a supervisor without the salesman in their team cannot create or publish', async () => {
    const db = dbFor(users.unassignedSupervisor);
    await assertFails(
      setDoc(
        doc(db, 'route_plans', PLAN_ID),
        draftFor(users.unassignedSupervisor),
      ),
    );
    await seedPlan('approved');
    await assertFails(publishCommit(db, users.unassignedSupervisor));
  });

  it('a supervisor route must bind its salesman uid to the team code', async () => {
    const db = dbFor(users.supervisor);
    const planRef = doc(db, 'route_plans', PLAN_ID);
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const admin = context.firestore();
      await setDoc(doc(admin, 'user_access', 'v2-sales'), {
        accessVersion: 2, uid: 'v2-sales', role: 'salesman', status: 'active',
        branchId: 'B1', employeeCode: 'S001', userDocId: 'S001-v2', supervisorUid: '',
      });
      await setDoc(doc(admin, 'user_access', 'v2-other'), {
        accessVersion: 2, uid: 'v2-other', role: 'salesman', status: 'active',
        branchId: 'B2', employeeCode: 'S002', userDocId: 'S002-v2', supervisorUid: '',
      });
    });
    for (const salesmanUid of [
      users.otherSalesman.uid,
      'v2-other',
      'no-such-account',
    ]) {
      await assertFails(setDoc(planRef, { ...draftFor(users.supervisor), salesmanUid }));
    }
    await assertSucceeds(setDoc(planRef, { ...draftFor(users.supervisor), salesmanUid: 'v2-sales' }));
    const codeOnly = { ...draftFor(users.supervisor), planId: 'ux-code-only' };
    delete codeOnly.salesmanUid;
    await assertSucceeds(setDoc(doc(db, 'route_plans', 'ux-code-only'), codeOnly));
  });

  it('a supervisor route resolves the salesman code as the phone does', async () => {
    const db = dbFor(users.supervisor);
    const route = (id, salesmanUid, salesmanCode, branchId = 'B1') => setDoc(
      doc(db, 'route_plans', id),
      { ...draftFor(users.supervisor), planId: id, salesmanUid, salesmanCode, branchId },
    );
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const admin = context.firestore();
      await setDoc(doc(admin, 'user_access', 'linked-sales'), {
        uid: 'linked-sales', userDocId: 'linked-sales@example.test', role: 'salesman',
        status: 'active', employeeCode: 'S002',
      });
      await setDoc(doc(admin, 'users', 'linked-sales@example.test'), {
        uid: 'linked-sales', role: 'salesman', status: 'active', employeeCode: 'S001', branchId: 'B1',
      });
      await setDoc(doc(admin, 'user_access', 'linked-other'), {
        uid: 'linked-other', userDocId: 'linked-other@example.test', role: 'salesman',
        status: 'active', employeeCode: 'S001',
      });
      await setDoc(doc(admin, 'users', 'linked-other@example.test'), {
        uid: 'linked-other', role: 'salesman', status: 'active', employeeCode: 'S002', branchId: 'B2',
      });
      await setDoc(doc(admin, 'users', 'code-alias-sales'), {
        role: 'salesman', status: 'active', salesmanCode: 'S001', branchId: 'B1',
      });
      await setDoc(doc(admin, 'users', 'code-alias-snake'), {
        role: 'salesman', status: 'active', salesman_code: 'S002', branchId: 'B2',
      });
      await setDoc(doc(admin, 'users', 'team-uid-sales'), {
        role: 'salesman', status: 'active', employeeCode: 'S005', branchId: 'B1',
      });
      for (const ref of [
        doc(admin, 'users', `${users.supervisor.uid}@example.test`),
        doc(admin, 'user_access', users.supervisor.uid),
      ]) {
        await updateDoc(ref, { assignedSalesmanCodes: ['S001', 'team-uid-sales', users.otherSalesman.uid] });
      }
    });
    await assertSucceeds(route('ux-linked', 'linked-sales', 'S001'));
    await assertFails(route('ux-linked-other', 'linked-other', 'S001'));
    await assertSucceeds(route('ux-code-alias', 'code-alias-sales', 'S001'));
    await assertFails(route('ux-code-snake', 'code-alias-snake', 'S001'));
    await assertSucceeds(route('ux-team-uid', 'team-uid-sales', 'S005'));
    await assertFails(route('ux-team-uid-bad', 'team-uid-sales', 'S006'));
    await assertSucceeds(route('ux-team-uid-legacy', users.otherSalesman.uid, 'S002', 'B2'));
    await assertFails(route('ux-team-uid-forged', users.otherSalesman.uid, 'S001'));
  });

  it('a supervisor cannot approve or publish a draft with a mismatched salesman uid', async () => {
    const forgedKey = users.otherSalesman.uid + '_20260921';
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await setDoc(doc(context.firestore(), 'route_plans', PLAN_ID), {
        ...draftFor(users.admin), salesmanUid: users.otherSalesman.uid, status: 'draft',
      });
    });
    const db = dbFor(users.supervisor);
    const planRef = doc(db, 'route_plans', PLAN_ID);
    await assertFails(updateDoc(planRef, { status: 'approved', updatedAt: serverTimestamp() }));
    await testEnv.withSecurityRulesDisabled(async (context) => {
      await updateDoc(doc(context.firestore(), 'route_plans', PLAN_ID), { status: 'approved' });
    });
    await assertFails(runTransaction(db, async (transaction) => {
      transaction.update(planRef, {
        status: 'published', publicationKeyId: forgedKey,
        updatedAt: serverTimestamp(), publishedAt: serverTimestamp(),
      });
      transaction.set(doc(db, 'route_plan_publication_keys', forgedKey), {
        keyId: forgedKey, planId: PLAN_ID, salesmanIdentity: users.otherSalesman.uid,
        weekKey: '20260921', active: true, updatedByUid: users.supervisor.uid,
      });
    }));
    await assertFails(setDoc(doc(db, 'route_plan_publication_keys', forgedKey), {
      keyId: forgedKey, planId: PLAN_ID, salesmanIdentity: users.otherSalesman.uid,
      weekKey: '20260921', active: true, updatedByUid: users.supervisor.uid,
    }));
    await assertSucceeds(updateDoc(doc(dbFor(users.admin), 'route_plans', PLAN_ID), {
      status: 'draft', updatedAt: serverTimestamp(),
    }));
  });

  it('a supervisor can run the scoped plan and progress queries but not a uid-only one', async () => {
    await seedPlan('draft');
    const db = dbFor(users.supervisor);
    await assertSucceeds(
      getDocs(
        query(collection(db, 'route_plans'), where('salesmanCode', '==', 'S001')),
      ),
    );
    await assertSucceeds(
      getDocs(
        query(
          collection(db, 'route_plans'),
          where('salesmanCode', 'in', ['S001']),
          limit(120),
        ),
      ),
    );
    await assertSucceeds(
      getDocs(
        query(
          collection(db, 'route_plan_progress'),
          where('salesmanCode', '==', 'S001'),
          limit(100),
        ),
      ),
    );
    await assertFails(
      getDocs(
        query(
          collection(db, 'route_plans'),
          where('salesmanUid', '==', users.salesman.uid),
        ),
      ),
    );
    await assertFails(getDocs(collection(db, 'route_plans')));
  });

  it('a branch manager can read branch routes but cannot create, approve or publish', async () => {
    const db = dbFor(users.branchManager);
    const planRef = doc(db, 'route_plans', PLAN_ID);

    await assertFails(setDoc(planRef, draftFor(users.branchManager)));

    await seedPlan('draft');
    await assertSucceeds(getDoc(planRef));
    await assertSucceeds(
      getDocs(
        query(collection(db, 'route_plans'), where('branchId', '==', 'B1')),
      ),
    );
    await assertFails(
      updateDoc(planRef, { status: 'approved', updatedAt: serverTimestamp() }),
    );

    await seedPlan('approved');
    await assertFails(publishCommit(db, users.branchManager));
    await assertFails(
      setDoc(doc(db, 'route_plan_publication_keys', KEY_ID), {
        keyId: KEY_ID,
        planId: PLAN_ID,
        salesmanIdentity: 'S001',
        weekKey: '20260921',
        active: true,
        updatedByUid: users.branchManager.uid,
      }),
    );
  });

  it('an admin still creates, approves and publishes', async () => {
    const db = dbFor(users.admin);
    const planRef = doc(db, 'route_plans', PLAN_ID);
    await assertSucceeds(setDoc(planRef, draftFor(users.admin)));
    await assertSucceeds(
      updateDoc(planRef, { status: 'approved', updatedAt: serverTimestamp() }),
    );
    await assertSucceeds(publishCommit(db, users.admin));
  });

  it('a branch manager cannot create a retailer; an admin can', async () => {
    const payload = {
      name: 'New Retailer',
      branchId: 'B1',
      status: 'active',
    };
    await assertFails(
      setDoc(doc(dbFor(users.branchManager), 'retailers', 'ux-new-retailer'), payload),
    );
    await assertSucceeds(
      setDoc(doc(dbFor(users.admin), 'retailers', 'ux-new-retailer'), payload),
    );
  });

  it('a supervisor cannot create a retailer', async () => {
    await assertFails(
      setDoc(doc(dbFor(users.supervisor), 'retailers', 'ux-sup-retailer'), {
        name: 'Sup Retailer',
        branchId: 'B1',
        status: 'active',
      }),
    );
  });
});

describe('wave 2 rules hardening', () => {
  const pause = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

  it('RULE-05: a score-sheet template needs the template shape and a matching id', async () => {
    const adminDb = dbFor(users.admin);
    const template = {
      kind: 'template',
      templateId: 'tpl_w2',
      revision: 1,
      name: 'Wave two',
      productIds: ['p1', 'p2'],
      productCount: 2,
      status: 'active',
      createdByUid: users.admin.uid,
      createdAt: serverTimestamp(),
    };
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_junk_r1'), {
      kind: 'template',
      name: 123,
      junk: 'x'.repeat(2000),
    }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r1'), {
      ...template,
      unexpected: true,
    }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r1'), {
      ...template,
      productIds: 'p1',
    }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r1'), {
      ...template,
      createdByUid: users.supervisor.uid,
    }));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_other_r1'), template));
    await assertFails(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r2'), template));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r1'), template));
    await assertSucceeds(setDoc(doc(adminDb, 'score_sheets', 'tpl_w2_r2'), {
      ...template,
      revision: 2,
      previousRevision: 1,
    }));
  });

  it('RULE-04: notifications, notification logs and audit logs refuse junk shapes', async () => {
    const adminDb = dbFor(users.admin);
    const salesmanDb = dbFor(users.salesman);
    const manyKeys = Object.fromEntries(
      Array.from({ length: 60 }, (_, i) => [`k${i}`, i]),
    );
    for (const collectionName of ['notifications', 'notification_logs']) {
      await assertFails(setDoc(doc(adminDb, collectionName, 'junk-keys'), {
        title: 't',
        ...manyKeys,
      }));
      await assertFails(setDoc(doc(adminDb, collectionName, 'junk-text'), {
        title: 'x'.repeat(5000),
      }));
      await assertFails(setDoc(doc(adminDb, collectionName, 'junk-type'), {
        title: { nested: true },
      }));
      await assertFails(setDoc(doc(salesmanDb, collectionName, 'junk-own'), {
        salesmanUid: users.salesman.uid,
        message: 'x'.repeat(5000),
      }));
      await assertSucceeds(setDoc(doc(adminDb, collectionName, 'fine'), {
        title: 'Order approved',
        message: 'Order O-1 was approved.',
        type: 'order',
      }));
      await assertSucceeds(setDoc(doc(salesmanDb, collectionName, 'fine-own'), {
        salesmanUid: users.salesman.uid,
        orderId: 'O-1',
        type: 'order',
      }));
    }
    const audit = {
      action: 'permission_matrix_updated',
      entityType: 'system_access_config',
      entityId: 'permission_matrix',
      summary: 'Updated role permissions.',
      actorUid: users.admin.uid,
      actorEmail: 'admin@example.test',
      actorName: 'Admin',
      actorRole: 'admin',
      metadata: { granted: [], revoked: [] },
      createdAt: serverTimestamp(),
    };
    await assertFails(setDoc(doc(adminDb, 'system_audit_logs', 'junk-1'), {
      ...audit,
      blob: 'x'.repeat(100000),
    }));
    await assertFails(setDoc(doc(adminDb, 'system_audit_logs', 'junk-2'), {
      ...audit,
      action: 'product_updated',
      summary: 'x'.repeat(5000),
    }));
    await assertFails(setDoc(doc(adminDb, 'system_audit_logs', 'junk-3'), {
      ...audit,
      metadata: 'not a map',
    }));
    await assertSucceeds(setDoc(doc(adminDb, 'system_audit_logs', 'fine-1'), audit));
    await assertSucceeds(setDoc(doc(adminDb, 'system_audit_logs', 'fine-2'), {
      actorUid: users.admin.uid,
      createdAt: serverTimestamp(),
      action: 'x',
    }));
  });

  describe('GPS-06 offline backlog breadcrumbs', () => {
    const SESSION = 'b'.repeat(32);

    async function startSession(db) {
      await assertSucceeds(setDoc(
        doc(db, 'live_tracking', users.salesman.uid),
        workSessionStartFields(SESSION, 1),
        { merge: true },
      ));
      await pause(30);
    }

    async function liveFix(db, sequence, deviceCapturedAt) {
      const batch = writeBatch(db);
      batch.set(
        doc(db, 'live_tracking', users.salesman.uid),
        trackingFixPayload({
          sessionId: SESSION,
          generation: 1,
          sequence,
          deviceCapturedAt,
        }),
        { merge: true },
      );
      const crumb = sessionBreadcrumbPayload({
        sessionId: SESSION,
        generation: 1,
        sequence,
        deviceCapturedAt,
      });
      batch.set(doc(db, 'gps_tracking', crumb.eventId), crumb);
      await assertSucceeds(batch.commit());
    }

    function backlogCrumb(sequence, deviceCapturedAt, overrides = {}) {
      return {
        ...sessionBreadcrumbPayload({
          sessionId: SESSION,
          generation: 1,
          sequence,
          deviceCapturedAt,
        }),
        backlog: true,
        ...overrides,
      };
    }

    const put = (db, crumb) =>
      setDoc(doc(db, 'gps_tracking', crumb.eventId), crumb);

    it('accepts older fixes of the live session in sequence below the latest fix', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      const first = Timestamp.now();
      await pause(30);
      const second = Timestamp.now();
      await pause(30);
      await liveFix(db, 5, Timestamp.now());
      await assertSucceeds(put(db, backlogCrumb(2, first)));
      await assertSucceeds(put(db, backlogCrumb(3, second)));
      await assertFails(put(db, backlogCrumb(2, first)));
    });

    it('refuses a backlog fix that is not older than the latest fix', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      const early = Timestamp.now();
      await pause(30);
      const latest = Timestamp.now();
      await liveFix(db, 5, latest);
      await assertFails(put(db, backlogCrumb(6, early)));
      await assertFails(put(db, backlogCrumb(4, latest)));
      await assertFails(put(db, backlogCrumb(4, Timestamp.fromMillis(
        latest.toMillis() + 3600 * 1000,
      ))));
    });

    it('refuses future-dated, too old, mislabelled and foreign backlog fixes', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      await pause(30);
      const early = Timestamp.now();
      await pause(30);
      await liveFix(db, 5, Timestamp.now());
      const day = 24 * 3600 * 1000;
      await assertFails(put(db, backlogCrumb(2, Timestamp.fromMillis(
        Date.now() - 8 * day,
      ))));
      await assertFails(put(db, backlogCrumb(2, Timestamp.fromMillis(
        Date.now() + day,
      ))));
      await assertFails(put(db, backlogCrumb(2, early, { backlog: false })));
      await assertFails(put(db, backlogCrumb(2, early, {
        eventId: 'session_wrong_id',
      })));
      await assertFails(put(db, backlogCrumb(2, early, {
        activeSessionGeneration: 2,
      })));
      await assertFails(put(db, backlogCrumb(2, early, {
        activeSessionId: 'c'.repeat(32),
      })));
      await assertFails(put(db, backlogCrumb(2, early, { isMocked: true })));
      await assertFails(put(dbFor(users.otherSalesman), backlogCrumb(2, early)));
      await assertFails(updateDoc(
        doc(db, 'gps_tracking', `session_${users.salesman.uid}_${SESSION}_5`),
        { latitude: 2 },
      ));
    });

    it('accepts a backlog for an ended session and refuses one after a new session', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      const early = Timestamp.now();
      await pause(30);
      await liveFix(db, 4, Timestamp.now());
      await pause(30);
      await assertSucceeds(updateDoc(
        doc(db, 'live_tracking', users.salesman.uid),
        {
          workSessionStatus: 'ended',
          status: 'inactive',
          workSessionEndedAt: serverTimestamp(),
        },
      ));
      await assertSucceeds(put(db, backlogCrumb(2, early)));
      await assertSucceeds(setDoc(
        doc(db, 'live_tracking', users.salesman.uid),
        workSessionStartFields('d'.repeat(32), 2),
        { merge: true },
      ));
      await assertFails(put(db, backlogCrumb(3, early)));
    });

    it('closes the backlog shape, the sequence window and the late-upload window', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      await pause(30);
      const early = Timestamp.now();
      await pause(30);
      await liveFix(db, 600, Timestamp.now());
      await assertFails(put(db, backlogCrumb(3, early, { junk: 'x'.repeat(5000) })));
      await assertFails(put(db, backlogCrumb(3, early, { orderId: 'ORD-1' })));
      await assertFails(put(db, backlogCrumb(3, early, { lastOrderId: 'ORD-1' })));
      await assertFails(put(db, backlogCrumb(3, early, {
        locationVerification: 'location_verified',
      })));
      await assertFails(put(db, backlogCrumb(99, early)));
      await assertSucceeds(put(db, backlogCrumb(100, early)));
      await assertSucceeds(put(db, backlogCrumb(101, early, {
        salesmanEmail: 'sales@example.test',
        salesmanName: 'Sales One',
        staffId: 'S001',
        employeeCode: 'S001',
        salesman_code: 'S001',
        salesmanId: 'S001',
        userUid: users.salesman.uid,
        submittedByUid: users.salesman.uid,
        submittedByEmail: 'sales@example.test',
        submittedByName: 'Sales One',
        locationSource: 'foreground_tracking',
      })));
    });

    it('refuses a backlog fix for a session that ended more than a day ago', async () => {
      const hour = 3600 * 1000;
      const seed = async (endedAgoMs) => {
        await testEnv.withSecurityRulesDisabled(async (context) => {
          await setDoc(doc(context.firestore(), 'live_tracking', users.salesman.uid), {
            ...workSessionStartFields(SESSION, 1),
            ...trackingFixPayload({
              sessionId: SESSION,
              generation: 1,
              sequence: 50,
              deviceCapturedAt: Timestamp.fromMillis(Date.now() - endedAgoMs - 1000),
            }),
            workSessionStatus: 'ended',
            status: 'inactive',
            workSessionStartedAt: Timestamp.fromMillis(Date.now() - endedAgoMs - 8 * hour),
            workSessionEndedAt: Timestamp.fromMillis(Date.now() - endedAgoMs),
          });
        });
      };
      const db = dbFor(users.salesman);
      const captured = (endedAgoMs) =>
        Timestamp.fromMillis(Date.now() - endedAgoMs - 3 * hour);
      await seed(48 * hour);
      await assertFails(put(db, backlogCrumb(7, captured(48 * hour))));
      await seed(2 * hour);
      await assertSucceeds(put(db, backlogCrumb(7, captured(2 * hour))));
    });

    it('refuses a backlog fix captured long before the session started', async () => {
      const db = dbFor(users.salesman);
      await startSession(db);
      await pause(30);
      await liveFix(db, 5, Timestamp.now());
      await assertFails(put(db, backlogCrumb(2, Timestamp.fromMillis(
        Date.now() - 2 * 3600 * 1000,
      ))));
    });
  });

  describe('RD-13 no-order outcome', () => {
    function noOrder(overrides = {}) {
      return {
        outcomeId: 'noorder-1',
        outcomeKind: 'no_order',
        retailerId: 'retailer-1',
        retailerName: 'Retailer One',
        reasonCode: 'retailer_busy',
        note: '',
        salesmanUid: users.salesman.uid,
        salesmanCode: 'S001',
        branchId: 'B1',
        planId: 'route-own',
        stopId: 'stop-1',
        source: 'mobile_assigned_route_no_order',
        isDemo: false,
        clientCreatedAt: Timestamp.now(),
        submittedAt: serverTimestamp(),
        ...overrides,
      };
    }
    const put = (db, outcome) =>
      setDoc(doc(db, 'conversation_outcomes', outcome.outcomeId), outcome);

    it('lets the stop salesperson record no order today with a reason and no insight', async () => {
      const db = dbFor(users.salesman);
      const outcome = noOrder();
      await assertSucceeds(put(db, outcome));
      await assertSucceeds(put(db, outcome));
      await assertSucceeds(put(db, noOrder({
        outcomeId: 'noorder-other-reason',
        reasonCode: 'other',
        note: 'Owner away until next week',
      })));
      await assertSucceeds(getDoc(doc(db, 'conversation_outcomes', 'noorder-1')));
      await assertSucceeds(getDoc(doc(dbFor(users.supervisor), 'conversation_outcomes', 'noorder-1')));
    });

    it('refuses forged, mismatched and malformed no-order outcomes', async () => {
      const db = dbFor(users.salesman);
      await assertFails(put(dbFor(users.otherSalesman), noOrder()));
      await assertFails(put(db, noOrder({ salesmanUid: users.otherSalesman.uid })));
      await assertFails(put(db, noOrder({ planId: 'route-other' })));
      await assertFails(put(db, noOrder({ planId: 'route-draft' })));
      await assertFails(put(db, noOrder({ planId: 'missing-plan' })));
      await assertFails(put(db, noOrder({ stopId: 'missing-stop' })));
      await assertFails(put(db, noOrder({ retailerId: 'retailer-other' })));
      await assertFails(put(db, noOrder({ branchId: 'B2' })));
      await assertFails(put(db, noOrder({ salesmanCode: 'S002' })));
      await assertFails(put(db, noOrder({ reasonCode: 'made_up' })));
      await assertFails(put(db, noOrder({ reasonCode: 'switched_to_alternative' })));
      await assertFails(put(db, noOrder({ reasonCode: 'other', note: 'short' })));
      await assertFails(put(db, noOrder({ note: 'x'.repeat(501) })));
      await assertFails(put(db, noOrder({ outcomeKind: 'order' })));
      await assertFails(put(db, noOrder({ source: 'mobile_assigned_route_copilot' })));
      await assertFails(put(db, noOrder({ isDemo: 'no' })));
      await assertFails(put(db, noOrder({ submittedAt: Timestamp.now() })));
      await assertFails(put(db, noOrder({ issueId: 'issue-1' })));
      await assertFails(put(db, noOrder({ unexpected: true })));
      await assertFails(
        setDoc(doc(db, 'conversation_outcomes', 'other-id'), noOrder()),
      );
    });

    it('keeps isDemo equal to the route flag', async () => {
      const db = dbFor(users.salesman);
      await assertFails(put(db, noOrder({ outcomeId: 'demo-on-real', isDemo: true })));
      await testEnv.withSecurityRulesDisabled(async (context) => {
        const routeDb = context.firestore();
        const route = (await getDoc(doc(routeDb, 'route_plans', 'route-own'))).data();
        await setDoc(doc(routeDb, 'route_plans', 'route-demo'), {
          ...route,
          planId: 'route-demo',
          isDemo: true,
        });
      });
      await assertFails(put(db, noOrder({ outcomeId: 'real-on-demo', planId: 'route-demo' })));
      await assertSucceeds(put(db, noOrder({
        outcomeId: 'demo-on-demo',
        planId: 'route-demo',
        isDemo: true,
      })));
    });
  });


  describe('PRICE-03 priceUpdatedAt on products', () => {
    it('refuses a price edit without a priceUpdatedAt and lets a stamped edit and a hidden create carry the request time', async () => {
      const adminDb = dbFor(users.admin);
      const ref = doc(adminDb, 'products', 'product-1');
      await assertFails(updateDoc(ref, { unitPrice: 11, price: 11, updatedAt: serverTimestamp() }));
      await assertSucceeds(updateDoc(ref, {
        unitPrice: 12,
        price: 12,
        updatedAt: serverTimestamp(),
        priceUpdatedAt: serverTimestamp(),
      }));
      await assertFails(updateDoc(ref, {
        unitPrice: 13,
        price: 13,
        updatedAt: serverTimestamp(),
        priceUpdatedAt: Timestamp.fromMillis(Date.now() - 86400000),
      }));
      await assertSucceeds(setDoc(doc(adminDb, 'products', 'price-new'), {
        productId: 'price-new',
        isVisible: false,
        status: 'hidden',
        unitPrice: 5,
        priceUpdatedAt: serverTimestamp(),
      }));
      await assertFails(setDoc(doc(adminDb, 'products', 'price-old'), {
        productId: 'price-old',
        isVisible: false,
        status: 'hidden',
        unitPrice: 5,
        priceUpdatedAt: Timestamp.fromMillis(Date.now() - 86400000),
      }));
    });
  });
});
