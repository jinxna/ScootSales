'use strict';
const fs = require('node:fs');
const path = require('node:path');

const {
  assertFails,
  assertSucceeds,
  initializeTestEnvironment,
} = require('@firebase/rules-unit-testing');
const {
  deleteField,
  doc,
  serverTimestamp,
  setDoc,
} = require('firebase/firestore');

const projectId = 'demo-fyp-a';
const rules = fs.readFileSync(
  process.env.FIRESTORE_RULES_PATH ||
    path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);
const contractsDir = path.join(__dirname, '..', 'contracts');

function loadFixtures(group) {
  const dir = path.join(contractsDir, group);
  return fs
    .readdirSync(dir)
    .filter((file) => file.endsWith('.json'))
    .sort()
    .map((file) => ({
      name: file,
      ...JSON.parse(fs.readFileSync(path.join(dir, file), 'utf8')),
    }));
}

function materialise(value) {
  if (Array.isArray(value)) return value.map(materialise);
  if (value && typeof value === 'object') {
    if (Object.hasOwn(value, '$sentinel')) {
      if (value.$sentinel === 'delete') return deleteField();
      if (value.$sentinel === 'serverTimestamp') return serverTimestamp();
      throw new Error(`Unknown sentinel ${value.$sentinel}`);
    }
    return Object.fromEntries(
      Object.entries(value).map(([k, v]) => [k, materialise(v)]),
    );
  }
  return value;
}

function materialiseStored(value) {
  if (Array.isArray(value)) return value.map(materialiseStored);
  if (value && typeof value === 'object') {
    if (Object.hasOwn(value, '$sentinel')) {
      return value.$sentinel === 'delete' ? undefined : serverTimestamp();
    }
    return Object.fromEntries(
      Object.entries(value)
        .map(([k, v]) => [k, materialiseStored(v)])
        .filter(([, v]) => v !== undefined),
    );
  }
  return value;
}

async function check(expected, promise) {
  if (expected === 'allow') return assertSucceeds(promise);
  if (expected === 'deny') return assertFails(promise);
  throw new Error(`expect must be allow|deny, got ${expected}`);
}

describe('shared contract fixtures', () => {
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
      for (const [docPath, data] of entries) {
        await setDoc(doc(db, ...docPath.split('/')), materialiseStored(data));
      }
    });
  }

  const ADMIN = 'ct-rules-admin';
  const ADMIN_DOC = `${ADMIN}@contracts.test`;
  const adminAccess = {
    accessVersion: 2,
    uid: ADMIN,
    userDocId: ADMIN_DOC,
    role: 'admin',
    status: 'active',
    branchId: '',
    employeeCode: 'A0001',
  };

  before(async () => {
    testEnv = await initializeTestEnvironment({ projectId, firestore: { rules } });
  });

  beforeEach(async () => {
    await testEnv.clearFirestore();
    await seed([
      [`user_access/${ADMIN}`, adminAccess],
      [`users/${ADMIN_DOC}`, {
        uid: ADMIN, role: 'admin', user_group: 'admin', status: 'active',
      }],
    ]);
  });

  afterEach(() => {
    for (const context of openContexts) context.cleanup();
    openContexts = [];
  });

  after(async () => {
    if (testEnv) await testEnv.cleanup();
  });

  describe('user_access write (dashboard -> rules)', () => {
    const kept = ['branch_manager', 'non_canonical_role', 'suspended_admin', 'suspended_user', 'supervisor_6_codes', 'uid_mismatch', 'self_save_admin_adds_v2_fields', 'self_save_admin_v2_email_only'];
    const fixtures = loadFixtures('user_access').filter((fx) => kept.includes(fx.name.replace('.json', '')));
    it('has fixtures', () => {
      if (fixtures.length === 0) throw new Error('no user_access fixtures');
    });

    for (const fx of fixtures) {
      const self = fx.actor === 'self';
      const expected = fx.expect.rulesAdminWrite;
      it(`${fx.name}: ${self ? 'self-save' : 'admin write'} -> ${expected}`, async () => {
        const profileId =
          (fx.access && fx.access.userDocId) ||
          (fx.existingAccess && fx.existingAccess.userDocId);
        const entries = [];
        if (profileId) entries.push([`users/${profileId}`, fx.userDoc]);
        if (fx.existingAccess) {
          entries.push([`user_access/${fx.uid}`, fx.existingAccess]);
        }
        await seed(entries);

        const db = dbFor(self ? fx.uid : ADMIN);
        await check(
          expected,
          setDoc(doc(db, 'user_access', fx.uid), materialise(fx.access), {
            merge: true,
          }),
        );
      });
    }
  });

  describe('orders (mobile -> rules)', () => {
    const fixtures = loadFixtures('orders');
    it('has fixtures', () => {
      if (fixtures.length === 0) throw new Error('no order fixtures');
    });

    for (const fx of fixtures) {
      it(`${fx.name}: salesman create -> ${fx.expect.rulesSalesmanCreate}`, async () => {
        await seed([
          [`user_access/${fx.salesman.uid}`, fx.salesman.access],
          [`users/${fx.salesman.access.userDocId}`, fx.salesman.userDoc],
        ]);
        const db = dbFor(fx.salesman.uid);
        const orderRef = doc(db, 'orders', fx.order.orderId);
        await check(
          fx.expect.rulesSalesmanCreate,
          setDoc(orderRef, materialise(fx.order)),
        );

        const special = fx.builder && fx.builder.specialRequest;
        if (special && fx.expect.rulesSpecialRequestCreate) {
          await check(
            fx.expect.rulesSpecialRequestCreate,
            setDoc(
              doc(db, 'special_requests', fx.order.orderId),
              materialise(fx.specialRequest),
            ),
          );
        }
      });
    }
  });
});
