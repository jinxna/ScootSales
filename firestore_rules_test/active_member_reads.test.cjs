'use strict';
const fs = require('node:fs');
const { assertFails, assertSucceeds, initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { doc, collection, getDoc, getDocs, setDoc, query, where } = require('firebase/firestore');

describe('active member company reads', function () {
  this.timeout(300000);
  let env;
  const collections = ['products', 'retailers'];
  before(async () => {
    env = await initializeTestEnvironment({ projectId: 'demo-member-reads', firestore: {
      rules: fs.readFileSync('admin_dashboard/firestore.rules', 'utf8'),
    } });
    await env.clearFirestore();
    await env.withSecurityRulesDisabled(async context => {
      const db = context.firestore();
      for (const name of collections) await setDoc(doc(db, name, 'sample'), { name: 'Company row', branchId: 'B1' });
      for (const role of ['admin', 'developer', 'supervisor', 'branch_manager', 'salesman']) {
        await setDoc(doc(db, 'user_access', role), { accessVersion: 2, uid: role, role, status: 'active', branchId: 'B2', employeeCode: 'S2', assignedSalesmanCodes: [] });
      }
      for (const status of ['suspended', 'removed']) {
        await setDoc(doc(db, 'user_access', status), { accessVersion: 2, uid: status, role: 'salesman', status, branchId: 'B1', employeeCode: 'S1' });
        await setDoc(doc(db, 'users', status), { role: 'salesman', status: 'active', branchId: 'B1' });
      }
      await setDoc(doc(db, 'users', 'removed-display'), { uid: 'removed-user', role: 'salesman', status: 'active' });
      for (const branchId of ['B1', 'B2']) await setDoc(doc(db, 'route_plans', branchId), {
        planId: branchId, branchId, status: 'published', salesmanUid: `sales-${branchId}`,
        salesmanCode: `code-${branchId}`, stopIds: [], totalStops: 0,
      });
    });
  });
  after(async () => { if (env) await env.cleanup(); });
  it('preserves the branch restriction on route get/list', async () => {
    const db = env.authenticatedContext('branch_manager').firestore();
    await assertFails(getDoc(doc(db, 'route_plans', 'B1')));
    await assertFails(getDocs(query(collection(db, 'route_plans'), where('branchId', '==', 'B1'))));
    await assertSucceeds(getDoc(doc(db, 'route_plans', 'B2')));
    await assertSucceeds(getDocs(query(collection(db, 'route_plans'), where('branchId', '==', 'B2'))));
  });
  for (const name of collections) {
    for (const identity of [null, 'no-profile', 'suspended', 'removed', 'removed-user']) {
      it(`denies get/list ${name} for ${identity || 'unauthenticated'}`, async () => {
        const db = (identity ? env.authenticatedContext(identity) : env.unauthenticatedContext()).firestore();
        await assertFails(getDoc(doc(db, name, 'sample')));
        await assertFails(getDocs(collection(db, name)));
      });
    }
    for (const role of ['admin', 'developer', 'supervisor', 'branch_manager', 'salesman']) {
      const branchLimited = name === 'retailers' && !['admin', 'developer'].includes(role);
      it(branchLimited ? `limits get/list ${name} to the own branch for active ${role}` : `keeps company-wide get/list ${name} for active ${role}`, async () => {
        const db = env.authenticatedContext(role).firestore();
        if (branchLimited) {
          await assertFails(getDoc(doc(db, name, 'sample')));
          await assertFails(getDocs(collection(db, name)));
          await assertFails(getDocs(query(collection(db, name), where('branchId', '==', 'B1'))));
          await assertSucceeds(getDocs(query(collection(db, name), where('branchId', '==', 'B2'))));
          return;
        }
        await assertSucceeds(getDoc(doc(db, name, 'sample')));
        await assertSucceeds(getDocs(collection(db, name)));
      });
    }
  }
});
