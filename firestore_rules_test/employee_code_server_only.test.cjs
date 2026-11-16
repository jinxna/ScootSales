'use strict';
const { assertFails, assertSucceeds, initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { doc, updateDoc } = require('firebase/firestore');
const fx = require('./identity_audit_fixtures.cjs');
const support = require('./rules_test_support.cjs');

const { users, projectId, rules } = support;

describe('employee code is server-only', function () {
  this.timeout(300000);
  let env;
  let sharedEnv;
  before(async () => {
    sharedEnv = support.getTestEnv();
    env = await initializeTestEnvironment({ projectId: `${projectId}-employee-code`, firestore: { rules } });
    support.setTestEnv(env);
  });
  after(async () => {
    support.setTestEnv(sharedEnv);
    await env.cleanup();
  });
  afterEach(() => support.cleanupContexts());

  const target = users.otherSalesman;
  const codeKeys = ['employeeCode', 'employee_code', 'staffId', 'staff_id', 'salesmanCode', 'salesman_code'];

  for (const shape of fx.SHAPES) {
    describe(`${shape} caller`, () => {
      const profileId = shape === 'uid' ? target.uid : `${target.uid}@probe.test`;
      beforeEach(async () => {
        await env.clearFirestore();
        await support.seed();
        for (const user of [users.salesman, users.admin, users.supervisor, users.branchManager, users.otherSalesman]) await support.reshape(user, shape);
      });
      const adminDb = () => support.dbFor(users.admin);

      it('refuses an admin change of the code on the user profile and allows other profile edits', async () => {
        for (const key of codeKeys) {
          await assertFails(updateDoc(doc(adminDb(), 'users', profileId), { [key]: 'S001' }));
        }
        await assertSucceeds(updateDoc(doc(adminDb(), 'users', profileId), { contactNumber: '0123456789' }));
        await assertSucceeds(updateDoc(doc(adminDb(), 'users', profileId), { displayName: 'Renamed Salesman' }));
      });
      if (shape !== 'uid') {
      }
    });
  }
});
