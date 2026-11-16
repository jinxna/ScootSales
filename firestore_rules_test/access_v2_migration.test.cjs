'use strict';
const fs = require('node:fs');
const path = require('node:path');

const { assertFails, assertSucceeds, initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { Timestamp, doc, getDoc, serverTimestamp, setDoc, updateDoc } = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const rules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const ADMIN = 'mig-admin';
const SALES = 'mig-sales';
const SUPERVISOR = 'mig-supervisor';
const UID_ONLY = 'mig-uid-only';
const SALES_PROFILE = 'profile-mig-sales';
const SUPERVISOR_PROFILE = 'profile-mig-supervisor';

const v2Fields = (uid, fields) => ({ accessVersion: 2, uid, status: 'active', disabledReasons: [], ...fields });

const aliasAdminRow = (reasons = []) => ({
  uid: ADMIN, role: 'Administrator', branch_id: '', staffId: 'A9',
  ...v2Fields(ADMIN, { role: 'admin', branchId: '', employeeCode: 'A9', disabledReasons: reasons }),
});

const linkedSalesProfile = {
  uid: SALES, role: 'sales representative', branch_id: 'B1', salesman_code: 'S002', status: 'active',
};
const linkedSalesRow = {
  uid: SALES, user_doc_id: SALES_PROFILE,
  ...v2Fields(SALES, { role: 'salesman', branchId: 'B1', employeeCode: 'S002', userDocId: SALES_PROFILE }),
};

const supervisorProfile = {
  uid: SUPERVISOR, role: 'supervisor', branchId: 'B1', employeeCode: 'SUP1', assignedSalesmanCodes: ['S002'],
};
const supervisorRow = {
  uid: SUPERVISOR, userDocId: SUPERVISOR_PROFILE,
  ...v2Fields(SUPERVISOR, {
    role: 'supervisor', branchId: 'B1', employeeCode: 'SUP1', assignedSalesmanCodes: ['S002'], userDocId: SUPERVISOR_PROFILE,
  }),
};

const uidOnlyProfile = {
  uid: UID_ONLY, role: 'salesman', branch_id: 'B1', staffId: 'S007', status: 'active', displayName: 'Before',
};
const uidOnlyRow = v2Fields(UID_ONLY, { role: 'salesman', branchId: 'B1', employeeCode: 'S007', userDocId: UID_ONLY });

const product = {
  productId: 'mig-p1', itemName: 'Orange Juice', productName: 'Orange Juice', unitPrice: 12.5, price: 12.5,
  isVisible: true, status: 'active',
};

function order(orderId, owner, code) {
  const name = Buffer.from('Orange Juice', 'utf8').toString('base64url');
  return {
    orderId, visitSource: 'personal_planner', salesmanUid: owner, submittedByUid: owner, createdByUid: owner,
    uid: owner, userUid: owner, salesmanId: code, salesmanCode: code, branchId: 'B1',
    salesmanName: 'Sales', retailerId: 'retailer-1', retailerName: 'Retailer One', outlet: 'Retailer One',
    status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10,
    submittedAt: serverTimestamp(), createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    items: [{
      name: 'Orange Juice', productName: 'Orange Juice', productId: 'p1', barcode: '9551000000015', packingSize: '12 x 1L',
      price: 10, qty: 1, expiry: '', department: 'Beverage', departmentName: 'Beverage', shelfBatches: [], remarks: '',
    }],
    commercialSchemaVersion: 1, commercialLines: [`p1~${name}~1~1000`],
    signatureTimestamps: {}, locationEvidence: { mode: 'not_verified', failureCode: 'unavailable' },
  };
}

const storedOrder = (orderId, owner, code) => ({
  ...order(orderId, owner, code), submittedAt: Timestamp.now(), createdAt: Timestamp.now(), updatedAt: Timestamp.now(),
});

describe('rows written by the access v2 migration', function () {
  this.timeout(300000);
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

  before(async () => {
    testEnv = await initializeTestEnvironment({ projectId, firestore: { rules } });
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
    await seed([
      ['products/mig-p1', product],
      ['orders/ORD-MIG-S2', storedOrder('ORD-MIG-S2', 'other-uid-2', 'S002')],
      ['orders/ORD-MIG-S3', storedOrder('ORD-MIG-S3', 'other-uid-3', 'S003')],
    ]);
  });

  afterEach(() => {
    for (const context of contexts) context.cleanup();
    contexts = [];
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });



  it('lets a migrated supervisor read an assigned salesman order and not an unassigned one', async () => {
    await seed([[`user_access/${SUPERVISOR}`, supervisorRow], [`users/${SUPERVISOR_PROFILE}`, supervisorProfile]]);
    const db = dbFor(SUPERVISOR);
    await assertSucceeds(getDoc(doc(db, 'orders', 'ORD-MIG-S2')));
    await assertFails(getDoc(doc(db, 'orders', 'ORD-MIG-S3')));
  });

  it('lets a migrated row with lifecycle_readonly read and refuses its writes', async () => {
    await seed([[`user_access/${ADMIN}`, aliasAdminRow(['lifecycle_readonly'])]]);
    const db = dbFor(ADMIN);
    await assertSucceeds(getDoc(doc(db, 'products', 'mig-p1')));
    await assertSucceeds(getDoc(doc(db, 'orders', 'ORD-MIG-S2')));
    await assertFails(updateDoc(doc(db, 'products', 'mig-p1'), { unitPrice: 13, price: 13 }));
  });

  for (const reason of ['billing_lapse', 'trial_expired', 'cancelled']) {
  }


});
