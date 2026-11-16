'use strict';
const fs = require('node:fs');
const path = require('node:path');

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  Timestamp,
  deleteDoc,
  doc,
  getDoc,
  serverTimestamp,
  setDoc,
  updateDoc,
} = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const rules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH ||
    path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const ADMIN = 'lc-admin';
const SALES = 'lc-sales';
const LEGACY = 'lc-legacy';
const PROFILE = (uid) => `${uid}@lc.test`;

const access = (uid, overrides = {}) => ({
  accessVersion: 2,
  uid,
  role: 'admin',
  status: 'active',
  isActive: true,
  branchId: '',
  employeeCode: 'A1',
  userDocId: PROFILE(uid),
  seatClass: 'free',
  seatHeld: true,
  disabledReasons: [],
  ...overrides,
});
const salesAccess = (overrides = {}) => access(SALES, {
  role: 'salesman', branchId: 'B1', employeeCode: 'S001', seatClass: 'salesperson', ...overrides,
});
const mirror = (uid, a) => ({
  uid, role: a.role, user_group: a.role, status: a.status, isActive: a.status === 'active', branchId: a.branchId,
  employeeCode: a.employeeCode,
});

function item() {
  return {
    name: 'Orange Juice', productName: 'Orange Juice', productId: 'p1', barcode: '9551000000015',
    packingSize: '12 x 1L', price: 10, qty: 1, expiry: '', department: 'Beverage',
    departmentName: 'Beverage', shelfBatches: [], remarks: '',
  };
}

function order(orderId) {
  const line = item();
  const name = Buffer.from(line.name, 'utf8').toString('base64url');
  return {
    orderId, visitSource: 'personal_planner', salesmanUid: SALES, submittedByUid: SALES, createdByUid: SALES,
    uid: SALES, userUid: SALES, salesmanId: 'S001', salesmanCode: 'S001', branchId: 'B1',
    salesmanName: 'Sales One', retailerId: 'retailer-1', retailerName: 'Retailer One', outlet: 'Retailer One',
    status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10,
    submittedAt: serverTimestamp(), createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    items: [line], commercialSchemaVersion: 1, commercialLines: [`p1~${name}~1~1000`],
    signatureTimestamps: {}, locationEvidence: { mode: 'not_verified', failureCode: 'unavailable' },
  };
}

const product = { productId: 'lc-p1', itemName: 'Orange Juice', productName: 'Orange Juice', unitPrice: 12.5,
  price: 12.5, isVisible: true, status: 'active' };

describe('company lifecycle lapse: disabledReasons', () => {
  let testEnv;
  let contexts = [];
  const dbFor = (uid) => {
    const context = testEnv.authenticatedContext(uid);
    contexts.push(context);
    return context.firestore();
  };
  async function seed(entries) {
    await testEnv.withSecurityRulesDisabled(async (context) => {
      const db = context.firestore();
      for (const [docPath, data] of entries) await setDoc(doc(db, ...docPath.split('/')), data);
    });
  }
  const seedAccess = (uid, a) => seed([[`user_access/${uid}`, a], [`users/${PROFILE(uid)}`, mirror(uid, a)]]);

  before(async () => {
    testEnv = await initializeTestEnvironment({ projectId, firestore: { rules } });
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
    await seed([
      ['products/lc-p1', product],
      ['orders/ORD-LC-OLD', { ...order('ORD-LC-OLD'), submittedAt: Timestamp.now(), createdAt: Timestamp.now(),
        updatedAt: Timestamp.now() }],
    ]);
  });

  afterEach(() => {
    for (const context of contexts) context.cleanup();
    contexts = [];
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });


  for (const reason of ['billing_lapse', 'trial_expired', 'cancelled']) {
  }




  it('refuses an active admin clearing another account\'s disable reasons', async () => {
    await seedAccess(ADMIN, access(ADMIN));
    await seedAccess(SALES, salesAccess({ disabledReasons: ['admin_suspension'] }));
    await assertFails(updateDoc(doc(dbFor(ADMIN), 'user_access', SALES), { disabledReasons: [] }));
  });

  it('refuses a legacy profile without an access record that carries a lapse reason', async () => {
    await seed([[`users/${LEGACY}`, { uid: LEGACY, role: 'admin', status: 'active', isActive: true }]]);
    await assertSucceeds(getDoc(doc(dbFor(LEGACY), 'products', 'lc-p1')));
    await seed([[`users/${LEGACY}`, { uid: LEGACY, role: 'admin', status: 'active', isActive: true,
      disabledReasons: ['billing_lapse'] }]]);
    await assertFails(getDoc(doc(dbFor(LEGACY), 'products', 'lc-p1')));
    await assertFails(updateDoc(doc(dbFor(LEGACY), 'users', LEGACY), { disabledReasons: [] }));
  });

  it('refuses a person clearing disable reasons on their own linked profile', async () => {
    await seedAccess(SALES, salesAccess({ disabledReasons: ['billing_lapse'] }));
    await seed([[`users/${PROFILE(SALES)}`, { ...mirror(SALES, salesAccess()), disabledReasons: ['billing_lapse'] }]]);
    await assertFails(updateDoc(doc(dbFor(SALES), 'users', PROFILE(SALES)), { disabledReasons: [] }));
  });

});
