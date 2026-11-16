'use strict';
const fs = require('node:fs');
const path = require('node:path');

const { assertFails, assertSucceeds, initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { doc, getDoc, serverTimestamp, setDoc, updateDoc } = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const rules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const ADMIN = 'spc-admin';
const SUPERVISOR = 'spc-supervisor';
const SALES = 'spc-sales';
const CODE = 'S001';

const accessRow = (uid, fields) => ({
  accessVersion: 2, uid, status: 'active', branchId: 'B1', disabledReasons: [], ...fields,
});
const actors = {
  admin: [ADMIN, accessRow(ADMIN, { role: 'admin', branchId: '', employeeCode: 'A1' })],
  supervisor: [SUPERVISOR, accessRow(SUPERVISOR, {
    role: 'supervisor', employeeCode: 'SUP1', assignedSalesmanCodes: [CODE],
  })],
  salesman: [SALES, accessRow(SALES, { role: 'salesman', employeeCode: CODE })],
};

const mismatch = { status: 'mismatch', version: 1 };
const matched = { status: 'ok', version: 1 };

function order(orderId, extra = {}) {
  const name = Buffer.from('Orange Juice', 'utf8').toString('base64url');
  return {
    orderId, visitSource: 'personal_planner', salesmanUid: SALES, submittedByUid: SALES, createdByUid: SALES,
    uid: SALES, userUid: SALES, salesmanId: CODE, salesmanCode: CODE, branchId: 'B1',
    salesmanName: 'Sales', retailerId: 'retailer-1', retailerName: 'Retailer One', outlet: 'Retailer One',
    status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10,
    submittedAt: serverTimestamp(), createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
    items: [{
      name: 'Orange Juice', productName: 'Orange Juice', productId: 'p1', barcode: '9551000000015', packingSize: '12 x 1L',
      price: 10, qty: 1, expiry: '', department: 'Beverage', departmentName: 'Beverage', shelfBatches: [], remarks: '',
    }],
    commercialSchemaVersion: 1, commercialLines: [`p1~${name}~1~1000`],
    signatureTimestamps: {}, locationEvidence: { mode: 'not_verified', failureCode: 'unavailable' },
    ...extra,
  };
}

const storedOrder = (orderId, extra = {}) => {
  const { submittedAt: _submittedAt, createdAt: _createdAt, updatedAt: _updatedAt, ...rest } = order(orderId, extra);
  const now = new Date('2026-10-01T00:00:00Z');
  return { ...rest, submittedAt: now, createdAt: now, updatedAt: now };
};

const approval = (uid, role, extra = {}) => ({
  status: 'approved', approvedAt: serverTimestamp(), approvedByUid: uid, approvedByRole: role,
  updatedAt: serverTimestamp(), ...extra,
});

describe('orders.serverPriceCheck is server-written only', function () {
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
    await seed(Object.values(actors).map(([uid, row]) => [`user_access/${uid}`, row]));
  });

  afterEach(() => {
    for (const context of contexts) context.cleanup();
    contexts = [];
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  it('lets a salesman create an order without serverPriceCheck', async () => {
    await assertSucceeds(setDoc(doc(dbFor(SALES), 'orders', 'ORD-SPC-1'), order('ORD-SPC-1')));
  });

  for (const [label, value] of [['a matched stamp', matched], ['a mismatch stamp', mismatch], ['an empty map', {}]]) {
    it(`refuses a salesman creating an order that carries ${label}`, async () => {
      await assertFails(setDoc(doc(dbFor(SALES), 'orders', 'ORD-SPC-2'), order('ORD-SPC-2', { serverPriceCheck: value })));
    });
  }

  for (const role of ['salesman', 'supervisor', 'admin']) {
    const [uid] = actors[role];
    const approver = role === 'salesman' ? null : role;

    it(`refuses a ${role} adding serverPriceCheck with a plain update`, async () => {
      await seed([['orders/ORD-SPC-4', storedOrder('ORD-SPC-4')]]);
      await assertFails(updateDoc(doc(dbFor(uid), 'orders', 'ORD-SPC-4'), { serverPriceCheck: matched }));
    });

    it(`refuses a ${role} changing an existing serverPriceCheck with a plain update`, async () => {
      await seed([['orders/ORD-SPC-5', storedOrder('ORD-SPC-5', { serverPriceCheck: mismatch })]]);
      await assertFails(updateDoc(doc(dbFor(uid), 'orders', 'ORD-SPC-5'), { serverPriceCheck: matched }));
      await assertFails(updateDoc(doc(dbFor(uid), 'orders', 'ORD-SPC-5'), { 'serverPriceCheck.status': 'ok' }));
    });

    if (approver) {


      it(`keeps a ${role} approval working when serverPriceCheck is stored and left untouched`, async () => {
        await seed([['orders/ORD-SPC-8', storedOrder('ORD-SPC-8', { serverPriceCheck: matched })]]);
        const db = dbFor(uid);
        await assertSucceeds(updateDoc(doc(db, 'orders', 'ORD-SPC-8'), approval(uid, approver)));
        await assertSucceeds(getDoc(doc(db, 'orders', 'ORD-SPC-8')));
      });
    }
  }

  it('still refuses a salesman approving an order, whatever the stamp', async () => {
    await seed([['orders/ORD-SPC-11', storedOrder('ORD-SPC-11', { serverPriceCheck: matched })]]);
    await assertFails(updateDoc(doc(dbFor(SALES), 'orders', 'ORD-SPC-11'), approval(SALES, 'salesman')));
  });
});
