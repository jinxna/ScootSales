'use strict';
const fs = require('node:fs');
const path = require('node:path');

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  deleteDoc,
  doc,
  getDoc,
  setDoc,
  updateDoc,
  writeBatch,
} = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const rules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH ||
    path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const ADMIN = 'pl-admin';
const SALES = 'pl-sales';
const SUP = 'pl-sup';
const SUSPENDED = 'pl-suspended';
const PROFILE = (uid) => `${uid}@pl.test`;

const access = (uid, overrides = {}) => ({
  accessVersion: 2,
  uid,
  role: 'admin',
  status: 'active',
  isActive: true,
  branchId: '',
  employeeCode: '',
  userDocId: PROFILE(uid),
  seatClass: 'free',
  seatHeld: true,
  ...overrides,
});
const mirror = (uid, a) => ({
  uid, role: a.role, user_group: a.role, status: a.status, isActive: a.status === 'active', branchId: a.branchId,
});
const salesmanAccess = (uid, overrides = {}) => access(uid, {
  role: 'salesman', branchId: 'B1', employeeCode: 'S100', supervisorUid: SUP, seatClass: 'salesperson', ...overrides,
});

const product = (overrides = {}) => ({
  productId: 'pl-p1', itemName: 'Orange Juice', productName: 'Orange Juice', unitPrice: 12.5, price: 12.5,
  isVisible: false, status: 'hidden', ...overrides,
});

describe('plans and limits: server-only writes', () => {
  let testEnv;
  let openContexts = [];
  const dbFor = (uid) => {
    const context = testEnv.authenticatedContext(uid);
    openContexts.push(context);
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
    await seedAccess(ADMIN, access(ADMIN, { employeeCode: 'A1' }));
    await seedAccess(SALES, salesmanAccess(SALES));
    await seedAccess(SUP, access(SUP, {
      role: 'supervisor', branchId: 'B1', employeeCode: 'SV1', assignedSalesmanCodes: ['S100'],
    }));
    await seedAccess(SUSPENDED, salesmanAccess(SUSPENDED, { employeeCode: 'S101', status: 'suspended', seatHeld: false }));
    await seed([
      ['products/pl-p1', product({ isVisible: true, status: 'active' })],
      ['config/plan', { planId: 'P1', edition: 'basic', limits: { salesmen: 2 } }],
      ['config/lifecycle', { tenantId: 't_northwind', state: 'suspended', revision: 3 }],
      ['config/usage', { seats: { salesmen: 1, supervisors: 1, managers: 1 }, products: 1 }],
    ]);
  });

  afterEach(() => {
    for (const context of openContexts) context.cleanup();
    openContexts = [];
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  describe('products', () => {
    it('creates a hidden product', async () => {
      await assertSucceeds(setDoc(doc(dbFor(ADMIN), 'products', 'pl-new'), product()));
    });

    for (const [label, overrides] of [
      ['visible', { isVisible: true, status: 'active' }],
      ['visible flag only', { isVisible: true }],
      ['active status only', { status: 'active' }],
      ['no isVisible', { isVisible: undefined }],
      ['no status', { status: undefined }],
      ['visible key', { visible: false }],
      ['productStatus key', { productStatus: 'hidden' }],
    ]) {
    }


    for (const [key, value] of [
      ['status', 'hidden'],
      ['isVisible', false],
      ['visible', false],
      ['productStatus', 'hidden'],
    ]) {
    }

  });

  describe('user_access', () => {
    it('refuses to create an access record, even with its profile in place', async () => {
      const newcomer = salesmanAccess('pl-new', { employeeCode: 'S200' });
      await seed([[`users/${PROFILE('pl-new')}`, mirror('pl-new', newcomer)]]);
      await assertFails(setDoc(doc(dbFor(ADMIN), 'user_access', 'pl-new'), newcomer));
    });



    it('refuses a role change, even when the profile mirrors it', async () => {
      const db = dbFor(ADMIN);
      const batch = writeBatch(db);
      batch.update(doc(db, 'user_access', SALES), { role: 'supervisor', seatClass: 'free', supervisorUid: '' });
      batch.update(doc(db, 'users', PROFILE(SALES)), { role: 'supervisor', user_group: 'supervisor' });
      await assertFails(batch.commit());
    });

    it('refuses a status change, even when the profile mirrors it', async () => {
      const db = dbFor(ADMIN);
      const batch = writeBatch(db);
      batch.update(doc(db, 'user_access', SALES), { status: 'suspended' });
      batch.update(doc(db, 'users', PROFILE(SALES)), { status: 'suspended', isActive: false });
      await assertFails(batch.commit());
    });

    for (const [key, value] of [
      ['user_group', 'supervisor'],
      ['accountStatus', 'suspended'],
      ['account_status', 'suspended'],
      ['isActive', false],
      ['is_active', false],
      ['active', false],
      ['enabled', false],
      ['seatClass', 'salesman'],
      ['seatHeld', false],
      ['invitationState', 'revoked'],
      ['accessVersion', 3],
      ['uid', 'someone-else'],
    ]) {
    }

    const seatMatrix = {
      salesman: { ok: ['salesman', 'salesperson'], bad: ['supervisor', 'manager', 'none', 'free'] },
      supervisor: { ok: ['supervisor', 'free'], bad: ['salesman', 'salesperson', 'manager', 'none'] },
      admin: { ok: ['manager', 'free'], bad: ['salesman', 'salesperson', 'supervisor', 'none'] },
      branch_manager: { ok: ['manager', 'free'], bad: ['salesman', 'salesperson', 'supervisor', 'none'] },
      developer: { ok: ['none', 'free'], bad: ['salesman', 'salesperson', 'supervisor', 'manager'] },
    };
    for (const [role, { ok, bad }] of Object.entries(seatMatrix)) {
      for (const [expected, seatClasses] of [[true, ok], [false, bad]]) {
        for (const seatClass of seatClasses) {
        }
      }
    }
  });

  describe('users', () => {
    for (const [key, value] of [
      ['role', 'supervisor'],
      ['status', 'suspended'],
      ['seatClass', 'salesman'],
    ]) {
      it(`refuses an admin change of ${key} on another profile`, async () => {
        await assertFails(updateDoc(doc(dbFor(ADMIN), 'users', PROFILE(SALES)), { [key]: value }));
      });
    }


    it('refuses a self change of the seat fields', async () => {
      for (const [key, value] of [['seatClass', 'manager'], ['seatHeld', false], ['invitationState', 'revoked']]) {
        await assertFails(updateDoc(doc(dbFor(SALES), 'users', PROFILE(SALES)), { [key]: value }));
      }
    });



  });

  describe('config', () => {

    it('denies the plan to a suspended member and to a signed-out caller', async () => {
      await assertFails(getDoc(doc(dbFor(SUSPENDED), 'config', 'plan')));
      await assertFails(getDoc(doc(testEnv.unauthenticatedContext().firestore(), 'config', 'plan')));
    });




    it('denies every client write, for the admin too', async () => {
      const db = dbFor(ADMIN);
      for (const id of ['plan', 'lifecycle', 'usage']) {
        await assertFails(updateDoc(doc(db, 'config', id), { products: 999 }));
        await assertFails(deleteDoc(doc(db, 'config', id)));
      }
      await assertFails(setDoc(doc(db, 'config', 'fresh'), { a: 1 }));
    });
  });
});
