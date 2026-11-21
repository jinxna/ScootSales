'use strict';
const assert = require('node:assert');
const fs = require('node:fs');
const os = require('node:os');
const path = require('node:path');
const crypto = require('node:crypto');
const { spawnSync } = require('node:child_process');

const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const {
  GeoPoint, Timestamp, collection, deleteDoc, deleteField, doc, getDoc, getDocs, increment, limit, orderBy, query,
  serverTimestamp, setDoc, updateDoc, where, writeBatch,
} = require('firebase/firestore');

const PROJECT = 'demo-regress-rules';
const ROOT = path.join(__dirname, '..');
const RULES_PATH = path.join(ROOT, 'admin_dashboard', 'firestore.rules');
const OUT = process.env.PREMISE_OUT || path.join(os.tmpdir(), 'boundary_regressions_results.json');
const ST = () => serverTimestamp();
const ALLOW = 'ALLOW';
const DENY = 'DENY';

const records = [];
const claimOrder = [];

async function attempt(op) {
  try {
    await op();
    return ALLOW;
  } catch (error) {
    if (error && (error.code === 'permission-denied' || String(error.message).includes('PERMISSION_DENIED'))) return DENY;
    throw error;
  }
}

function record(claim, kind, label, expected, observed) {
  if (!claimOrder.includes(claim)) claimOrder.push(claim);
  const match = expected === observed;
  records.push({ claim, kind, label, expected, observed, match });
  console.log(`RESULT | ${claim} | ${kind} | ${label} | expected=${expected} | observed=${observed} | ${match ? 'ok' : 'DIFFERS'}`);
}

function stepper(claim) {
  const bad = [];
  return {
    async control(label, expected, op) {
      const observed = await attempt(op);
      record(claim, 'control', label, expected, observed);
      if (observed !== expected) bad.push(label);
    },
    async probe(label, expected, op) {
      record(claim, 'claim', label, expected, await attempt(op));
    },
    async info(label, expected, op) {
      record(claim, 'info', label, expected, await attempt(op));
    },
    note(label, expected, observed) {
      record(claim, 'claim', label, String(expected), String(observed));
    },
    noteControl(label, expected, observed) {
      record(claim, 'control', label, String(expected), String(observed));
      if (String(expected) !== String(observed)) bad.push(label);
    },
    finish() {
      if (bad.length) throw new Error(`control failed, setup not proven: ${bad.join('; ')}`);
    },
  };
}

function python(command, args = []) {
  const run = spawnSync('python', ['-W', 'ignore', path.join(__dirname, 'boundary_regressions_helpers.py'), command, ...args], {
    cwd: ROOT,
    encoding: 'utf8',
    env: { ...process.env, RULES_TEST_PROJECT: PROJECT, PYTHONPATH: ROOT, PYTHONIOENCODING: 'utf-8' },
  });
  if (run.status !== 0) throw new Error(`python ${command} failed: ${run.stderr}`);
  const line = run.stdout.trim().split(/\r?\n/).pop();
  console.log(`PYTHON | ${command} | ${line}`);
  return JSON.parse(line);
}

const row = (uid, fields) => ({
  accessVersion: 2, uid, userDocId: uid, status: 'active', isActive: true, branchId: 'B1', employeeCode: '',
  assignedSalesmanCodes: [], disabledReasons: [], ...fields,
});

const ACTORS = {
  adm: row('adm', { role: 'admin', branchId: '', employeeCode: 'A1' }),
  mgr1: row('mgr1', { role: 'branch_manager', employeeCode: 'M1' }),
  supEmpty: row('supEmpty', { role: 'supervisor', employeeCode: 'V9', assignedSalesmanCodes: ['S001', ''] }),
  admB1: row('admB1', { role: 'admin', employeeCode: 'A2' }),
  mgr2: row('mgr2', { role: 'branch_manager', branchId: 'B2', employeeCode: 'M2' }),
  sup1: row('sup1', { role: 'supervisor', employeeCode: 'V1', assignedSalesmanCodes: ['S001'], name: 'Sup One' }),
  sup2: row('sup2', { role: 'supervisor', employeeCode: 'V2', assignedSalesmanCodes: ['S002'] }),
  sal1: row('sal1', { role: 'salesman', employeeCode: 'S001' }),
  sal2: row('sal2', { role: 'salesman', employeeCode: 'S002' }),
  sal3: row('sal3', { role: 'salesman', branchId: 'B2', employeeCode: 'S003' }),
  sal4: row('sal4', { role: 'salesman', employeeCode: 'S004' }),
  nocode: row('nocode', { role: 'salesman', employeeCode: '' }),
  susp: row('susp', { role: 'salesman', employeeCode: 'S009', status: 'suspended', isActive: false }),
};

const name64 = (text) => Buffer.from(text, 'utf8').toString('base64url');

function orderFor(uid, code, branch, orderId, extra = {}) {
  return {
    orderId, visitSource: 'personal_planner', salesmanUid: uid, submittedByUid: uid, createdByUid: uid,
    uid, userUid: uid, salesmanId: code, salesmanCode: code, branchId: branch,
    salesmanName: `Name ${code}`, retailerId: 'ret-any', retailerName: 'Retailer', outlet: 'Retailer',
    status: 'submitted', totalProducts: 1, totalBoxes: 1, totalPrice: 10,
    submittedAt: ST(), createdAt: ST(), updatedAt: ST(),
    items: [{ name: 'Juice', productName: 'Juice', productId: 'p1', price: 10, qty: 1 }],
    commercialSchemaVersion: 1, commercialLines: [`p1~${name64('Juice')}~1~1000`],
    signatureTimestamps: {}, locationEvidence: { mode: 'not_verified', failureCode: 'unavailable' },
    ...extra,
  };
}

function storedOrder(uid, code, branch, orderId) {
  const { submittedAt: _submittedAt, createdAt: _createdAt, updatedAt: _updatedAt, ...rest } = orderFor(uid, code, branch, orderId);
  const now = new Date('2026-10-01T00:00:00Z');
  return { ...rest, submittedAt: now, createdAt: now, updatedAt: now };
}

const currentHour = () => Math.floor(Date.now() / 3600000);
const lockWindowId = () => `h${currentHour()}`;
const emailKey = (email) => email.replace('%', '%25').replace('/', '%2F');

function lockBatch(db, email, id, client = 'mobile', shape = 'window', hour = currentHour()) {
  const batch = writeBatch(db);
  if (shape === 'window') {
    batch.set(doc(db, 'account_lock_windows', `h${hour}`), { count: increment(1), requestId: id }, { merge: true });
  } else {
    batch.set(doc(db, 'account_lock_limits', emailKey(email)), { claimedEmail: email, requestId: id, createdAt: ST() });
  }
  batch.set(doc(db, 'account_lock_requests', id), {
    claimedEmail: email, client, localLockedUntil: Timestamp.fromMillis(Date.now() + 30 * 60000),
    createdAt: ST(), status: 'pending', reviewedAt: null, reviewedBy: null,
  });
  batch.set(doc(db, 'account_lock_receipts', id), { status: 'pending', createdAt: ST(), reviewedAt: null });
  batch.set(doc(db, 'system_audit_logs', `lock_request_${id}`), {
    action: 'local_lock_reported', entityType: 'account_lock_requests', entityId: id,
    summary: 'Unverified local lock reported.', actorUid: '', actorEmail: '', actorName: '',
    actorRole: 'unauthenticated', metadata: { client, unverified: true }, createdAt: ST(),
  });
  return batch.commit();
}

async function clientReport(db, email, id, client = 'mobile') {
  let refused;
  for (const shift of [0, -1, 1, null]) {
    try {
      return await lockBatch(db, email, id, client, shift === null ? 'limit' : 'window', currentHour() + (shift || 0));
    } catch (error) {
      if (!(error && (error.code === 'permission-denied' || String(error.message).includes('PERMISSION_DENIED')))) throw error;
      refused = error;
    }
  }
  throw refused;
}

function unlockBatch(db, adminUid, id, actorEmail = 'a@example.test') {
  const batch = writeBatch(db);
  batch.update(doc(db, 'account_lock_requests', id), { status: 'unlocked', reviewedAt: ST(), reviewedBy: adminUid });
  batch.update(doc(db, 'account_lock_receipts', id), { status: 'unlocked', reviewedAt: ST() });
  batch.set(doc(db, 'system_audit_logs', `lock_unlock_${id}`), {
    action: 'local_lock_unlocked', entityType: 'account_lock_requests', entityId: id,
    summary: 'Admin released a reported local retry delay.', actorUid: adminUid,
    actorEmail, actorName: 'A', actorRole: 'admin', metadata: { unverified: true }, createdAt: ST(),
  });
  return batch.commit();
}

const lockId = () => crypto.randomBytes(32).toString('hex');
const visit = (ownerUid, extra = {}) => ({
  ownerUid, salesmanUid: ownerUid, marketplace: 'Retailer C', time: '11:00', purpose: 'Restock', notes: '',
  date: '2026-11-10', day: 'Tuesday', createdAt: ST(), updatedAt: ST(), ...extra,
});
const auditRow = (uid, extra = {}) => ({
  action: 'order_approved', entityType: 'orders', entityId: 'ORD-1', summary: 'Approved order ORD-1',
  actorUid: uid, actorEmail: 'someone@example.test', actorName: '', actorRole: 'supervisor',
  metadata: {}, createdAt: ST(), ...extra,
});
const routePlan = (planId, extra = {}) => ({
  planId, status: 'published', salesmanUid: 'sal1', salesmanCode: 'S001', branchId: 'B1', createdByUid: 'adm',
  weekStart: Timestamp.fromMillis(Date.now() + 7 * 86400000), stopIds: ['stop-1', 'stop-2'], totalStops: 2,
  stopRetailerIds: { 'stop-1': 'r1', 'stop-2': 'r2' }, updatedAt: new Date('2026-11-01T00:00:00Z'), ...extra,
});
const withdraw = () => ({ status: 'draft', updatedAt: ST() });
const tapStop = (planId, uid, code, branch, stopId) => ({
  progressId: `${planId}_${uid}`, planId, salesmanUid: uid, salesmanCode: code, branchId: branch, isOfflineCreated: false,
  status: 'assigned', stopProgress: {}, handledStopIds: [], selectedStopId: stopId, selectionRevision: increment(1),
  updatedAt: ST(), lastSyncedAt: ST(),
});

describe('boundary regressions against the real rules', function () {
  this.timeout(300000);
  let env;

  const db = (uid, token) => env.authenticatedContext(uid, token).firestore();
  const anon = () => env.unauthenticatedContext().firestore();

  async function seed(entries) {
    await env.withSecurityRulesDisabled(async (context) => {
      const admin = context.firestore();
      for (const [docPath, data] of entries) await setDoc(doc(admin, ...docPath.split('/')), data);
    });
  }
  async function readAdmin(docPath) {
    let out;
    await env.withSecurityRulesDisabled(async (context) => {
      const snap = await getDoc(doc(context.firestore(), ...docPath.split('/')));
      out = snap.exists() ? snap.data() : null;
    });
    return out;
  }
  async function seedActors() {
    const entries = [];
    for (const [uid, data] of Object.entries(ACTORS)) {
      entries.push([`user_access/${uid}`, data], [`users/${uid}`, data]);
    }
    await seed(entries);
  }

  before(async () => {
    env = await initializeTestEnvironment({ projectId: PROJECT, firestore: { rules: fs.readFileSync(RULES_PATH, 'utf8') } });
  });
  beforeEach(async () => {
    await env.clearFirestore();
    await seedActors();
  });
  after(async () => {
    fs.writeFileSync(OUT, JSON.stringify({
      rulesSha256: crypto.createHash('sha256').update(fs.readFileSync(RULES_PATH)).digest('hex'),
      records,
    }, null, 1));
    for (const claim of claimOrder) {
      const rows = records.filter((entry) => entry.claim === claim);
      const controls = rows.filter((entry) => entry.kind === 'control');
      const probes = rows.filter((entry) => entry.kind === 'claim');
      console.log(`SUMMARY | ${claim} | controls ${controls.filter((e) => e.match).length}/${controls.length} | claim probes matched ${probes.filter((e) => e.match).length}/${probes.length}`);
    }
    if (env) await env.cleanup();
  });

  it('C01 a report for someone\'s email does not stop that person\'s own report', async () => {
    const s = stepper('C01-lock');
    const a = anon();
    const adminDb = db('adm', { email: 'a@example.test' });
    await s.control('signed-in caller cannot send the batch', DENY, () => lockBatch(db('sal1'), 'signed@example.test', lockId()));
    await s.control('anonymous batch with a malformed email is refused', DENY, () => lockBatch(a, 'not-an-email', lockId()));
    await s.control('batch with neither the hourly counter nor the email gate row is refused', DENY, async () => {
      const id = lockId();
      const batch = writeBatch(a);
      batch.set(doc(a, 'account_lock_requests', id), {
        claimedEmail: 'nocounter@example.test', client: 'mobile', localLockedUntil: Timestamp.fromMillis(Date.now() + 30 * 60000),
        createdAt: ST(), status: 'pending', reviewedAt: null, reviewedBy: null,
      });
      batch.set(doc(a, 'account_lock_receipts', id), { status: 'pending', createdAt: ST(), reviewedAt: null });
      batch.set(doc(a, 'system_audit_logs', `lock_request_${id}`), {
        action: 'local_lock_reported', entityType: 'account_lock_requests', entityId: id,
        summary: 'Unverified local lock reported.', actorUid: '', actorEmail: '', actorName: '',
        actorRole: 'unauthenticated', metadata: { client: 'mobile', unverified: true }, createdAt: ST(),
      });
      return batch.commit();
    });
    const first = lockId();
    await s.control('anonymous batch, chosen email 1', ALLOW, () => lockBatch(a, 'made.up.1@nowhere.invalid', first));
    await s.control('anonymous batch, chosen email 2', ALLOW, () => lockBatch(a, 'made.up.2@nowhere.invalid', lockId()));
    const attackerId = lockId();
    await s.control('report made for a victim email by another party', ALLOW, () => lockBatch(a, 'victim@example.test', attackerId));
    await s.probe('the real victim report is still accepted', ALLOW, () => lockBatch(anon(), 'victim@example.test', lockId()));
    await s.control('active admin can unlock the planted report', ALLOW, () => unlockBatch(adminDb, 'adm', attackerId));
    await s.control('no client can delete the request', DENY, () => deleteDoc(doc(adminDb, 'account_lock_requests', first)));
    await s.control('no client can delete the receipt', DENY, () => deleteDoc(doc(adminDb, 'account_lock_receipts', first)));
    await s.control('no client can delete the hourly counter', DENY, () => deleteDoc(doc(adminDb, 'account_lock_windows', lockWindowId())));
    await s.control('no client can read the hourly counter', DENY, () => getDoc(doc(adminDb, 'account_lock_windows', lockWindowId())));
    await s.control('no client can delete the audit row', DENY, () => deleteDoc(doc(adminDb, 'system_audit_logs', `lock_request_${first}`)));
    const stored = await readAdmin(`system_audit_logs/lock_request_${first}`);
    s.noteControl('audit row stored for the anonymous report', 'local_lock_reported', stored && stored.action);
    const counter = await readAdmin(`account_lock_windows/${lockWindowId()}`);
    s.noteControl('hourly counter counted every accepted report', 4, counter && counter.count);
    s.finish();
  });

  it('C01 old phones keep reporting through the per-email gate, and a new phone cannot be blocked by it', async () => {
    const s = stepper('C01-lock-both-shapes');
    const a = anon();
    const adminDb = db('adm', { email: 'a@example.test' });
    const oldFirst = lockId();
    await s.control('1.0.2 batch (email gate row) is accepted', ALLOW, () => lockBatch(a, 'old.one@nowhere.invalid', oldFirst, 'mobile', 'limit'));
    await s.control('1.0.2 batch for the same email inside the gate time is refused, as on the base rules', DENY, () => lockBatch(anon(), 'old.one@nowhere.invalid', lockId(), 'mobile', 'limit'));
    await s.control('1.0.2 batch for another email is accepted', ALLOW, () => lockBatch(anon(), 'old.two@nowhere.invalid', lockId(), 'mobile', 'limit'));
    await s.control('email gate row that names a different email than the report is refused', DENY, async () => {
      const id = lockId();
      const d = anon();
      const batch = writeBatch(d);
      batch.set(doc(d, 'account_lock_limits', emailKey('other.key@nowhere.invalid')), { claimedEmail: 'other.key@nowhere.invalid', requestId: id, createdAt: ST() });
      batch.set(doc(d, 'account_lock_requests', id), { claimedEmail: 'real.email@nowhere.invalid', client: 'mobile', localLockedUntil: Timestamp.fromMillis(Date.now() + 30 * 60000), createdAt: ST(), status: 'pending', reviewedAt: null, reviewedBy: null });
      batch.set(doc(d, 'account_lock_receipts', id), { status: 'pending', createdAt: ST(), reviewedAt: null });
      batch.set(doc(d, 'system_audit_logs', `lock_request_${id}`), {
        action: 'local_lock_reported', entityType: 'account_lock_requests', entityId: id, summary: 'Unverified local lock reported.', actorUid: '', actorEmail: '', actorName: '',
        actorRole: 'unauthenticated', metadata: { client: 'mobile', unverified: true }, createdAt: ST(),
      });
      return batch.commit();
    });
    await s.control('a 1.0.2 batch from an attacker for the victim email is accepted, as on the base rules', ALLOW, () => lockBatch(anon(), 'victim.old@nowhere.invalid', lockId(), 'mobile', 'limit'));
    await s.control('the victim on a 1.0.2 phone is blocked by that gate, as on the base rules', DENY, () => lockBatch(anon(), 'victim.old@nowhere.invalid', lockId(), 'mobile', 'limit'));
    await s.control('the victim on an updated phone is not blocked by that gate', ALLOW, () => clientReport(anon(), 'victim.old@nowhere.invalid', lockId()));
    await s.control('active admin can unlock a 1.0.2 report', ALLOW, () => unlockBatch(adminDb, 'adm', oldFirst));
    await s.control('no client can read the email gate row', DENY, () => getDoc(doc(adminDb, 'account_lock_limits', emailKey('old.one@nowhere.invalid'))));
    await s.control('no client can delete the email gate row', DENY, () => deleteDoc(doc(adminDb, 'account_lock_limits', emailKey('old.one@nowhere.invalid'))));
    s.finish();
  });

  it('C01 an hourly report cannot plant a bad email gate row or counter that blocks other people', async () => {
    const s = stepper('C01-lock-poison');
    const poison = (email, id, limitFields, windowFields) => {
      const a = anon();
      const batch = writeBatch(a);
      batch.set(doc(a, 'account_lock_windows', lockWindowId()), windowFields || { count: increment(1), requestId: id }, { merge: true });
      if (limitFields) batch.set(doc(a, 'account_lock_limits', emailKey(email)), { claimedEmail: email, requestId: id, ...limitFields });
      batch.set(doc(a, 'account_lock_requests', id), { claimedEmail: email, client: 'mobile', localLockedUntil: Timestamp.fromMillis(Date.now() + 30 * 60000), createdAt: ST(), status: 'pending', reviewedAt: null, reviewedBy: null });
      batch.set(doc(a, 'account_lock_receipts', id), { status: 'pending', createdAt: ST(), reviewedAt: null });
      batch.set(doc(a, 'system_audit_logs', `lock_request_${id}`), {
        action: 'local_lock_reported', entityType: 'account_lock_requests', entityId: id, summary: 'Unverified local lock reported.', actorUid: '', actorEmail: '', actorName: '',
        actorRole: 'unauthenticated', metadata: { client: 'mobile', unverified: true }, createdAt: ST(),
      });
      return batch.commit();
    };
    await s.control('hourly report that also writes the victim gate row with text as its time is refused', DENY, () => poison('victim.text@example.test', lockId(), { createdAt: 'forever' }));
    await s.control('hourly report that also writes the victim gate row with a far future time is refused', DENY, () => poison('victim.future@example.test', lockId(), { createdAt: Timestamp.fromDate(new Date('2099-01-01')) }));
    await s.control('1.0.2 shape report that also sets the hourly counter to its limit is refused', DENY, () => (() => { const id = lockId(); return poison('victim.count@example.test', id, { createdAt: ST() }, { count: 30, requestId: id }); })());
    await s.control('the victim on a 1.0.2 phone can still report', ALLOW, () => lockBatch(anon(), 'victim.text@example.test', lockId(), 'mobile', 'limit'));
    await s.control('the victim on an updated phone can still report', ALLOW, () => clientReport(anon(), 'victim.future@example.test', lockId()));
    s.finish();
  });


  it('C02 deletion request needs a recent sign-in and an account that is not suspended', async () => {
    const s = stepper('C02-deletion');
    const request = () => ({ requestType: 'account_deletion', status: 'submitted', createdAt: ST() });
    const stale = { auth_time: Math.floor(Date.now() / 1000) - 7200 };
    const fresh = () => ({ auth_time: Math.floor(Date.now() / 1000) - 60 });
    await seed([
      ['user_access/lapsed', row('lapsed', { role: 'salesman', employeeCode: 'S010', disabledReasons: ['billing_lapse'] })],
      ['users/lapsed', row('lapsed', { role: 'salesman', employeeCode: 'S010' })],
      ['user_access/readonly', row('readonly', { role: 'salesman', employeeCode: 'S012', disabledReasons: ['lifecycle_readonly'] })],
      ['user_access/trial', row('trial', { role: 'salesman', employeeCode: 'S014', disabledReasons: ['trial_expired'] })],
      ['user_access/cancelled', row('cancelled', { role: 'salesman', employeeCode: 'S015', disabledReasons: ['cancelled'] })],
      ['user_access/adminsusp', row('adminsusp', { role: 'salesman', employeeCode: 'S016', disabledReasons: ['admin_suspension'] })],
      ['user_access/delreq', row('delreq', { role: 'salesman', employeeCode: 'S017', disabledReasons: ['deletion_requested'] })],
      ['user_access/legsusp', { uid: 'legsusp', status: 'active', isActive: true, role: 'salesman', branchId: 'B1', employeeCode: 'S018', disabledReasons: ['admin_suspension'] }],
      ['user_access/legclean', { uid: 'legclean', status: 'active', isActive: true, role: 'salesman', branchId: 'B1', employeeCode: 'S019' }],
      ['user_access/both', row('both', { role: 'salesman', employeeCode: 'S013', disabledReasons: ['billing_lapse', 'admin_suspension'] })],
      ['privacy_deletion_requests/rejected', { requestType: 'account_deletion', status: 'rejected', createdAt: new Date('2026-10-01T00:00:00Z') }],
      ['user_access/rejected', row('rejected', { role: 'salesman', employeeCode: 'S011', status: 'suspended', isActive: false })],
      ['privacy_deletion_requests/sal2', { requestType: 'account_deletion', status: 'rejected', createdAt: new Date('2026-10-01T00:00:00Z') }],
    ]);
    await s.control('anonymous caller refused', DENY, () => setDoc(doc(anon(), 'privacy_deletion_requests', 'sal1'), request()));
    await s.control('another person\'s request refused', DENY, () => setDoc(doc(db('sal2', fresh()), 'privacy_deletion_requests', 'sal1'), request()));
    await s.control('wrong shape refused', DENY, () => setDoc(doc(db('sal1', fresh()), 'privacy_deletion_requests', 'sal1'), { ...request(), extra: true }));
    await s.control('active salesperson with a fresh sign-in', ALLOW, () => setDoc(doc(db('sal1', fresh()), 'privacy_deletion_requests', 'sal1'), request()));
    await s.control('active salesperson, token signed in 2 hours ago', DENY, () => setDoc(doc(db('sal3', stale), 'privacy_deletion_requests', 'sal3'), request()));
    await s.control('suspended salesperson (status suspended, isActive false)', DENY, () => setDoc(doc(db('susp', fresh()), 'privacy_deletion_requests', 'susp'), request()));
    await s.control('account holding billing_lapse can still ask', ALLOW, () => setDoc(doc(db('lapsed', fresh()), 'privacy_deletion_requests', 'lapsed'), request()));
    await s.control('account holding lifecycle_readonly can still ask', ALLOW, () => setDoc(doc(db('readonly', fresh()), 'privacy_deletion_requests', 'readonly'), request()));
    await s.control('account holding trial_expired can still ask', ALLOW, () => setDoc(doc(db('trial', fresh()), 'privacy_deletion_requests', 'trial'), request()));
    await s.control('account holding cancelled can still ask', ALLOW, () => setDoc(doc(db('cancelled', fresh()), 'privacy_deletion_requests', 'cancelled'), request()));
    await s.control('account holding admin_suspension is refused', DENY, () => setDoc(doc(db('adminsusp', fresh()), 'privacy_deletion_requests', 'adminsusp'), request()));
    await s.control('account holding deletion_requested is refused', DENY, () => setDoc(doc(db('delreq', fresh()), 'privacy_deletion_requests', 'delreq'), request()));
    await s.control('legacy row holding admin_suspension is refused', DENY, () => setDoc(doc(db('legsusp', fresh()), 'privacy_deletion_requests', 'legsusp'), request()));
    await s.control('legacy row with no reason can ask', ALLOW, () => setDoc(doc(db('legclean', fresh()), 'privacy_deletion_requests', 'legclean'), request()));
    await s.control('token with no sign-in time is refused', DENY, () => setDoc(doc(db('sal4', {}), 'privacy_deletion_requests', 'sal4'), request()));
    await s.control('account holding a person-level reason beside billing_lapse', DENY, () => setDoc(doc(db('both', fresh()), 'privacy_deletion_requests', 'both'), request()));
    await s.control('signed-in uid with no access row or profile at all', DENY, () => setDoc(doc(db('nobody', fresh()), 'privacy_deletion_requests', 'nobody'), request()));
    await s.control('suspended person resubmits after a rejection', DENY, () => updateDoc(doc(db('rejected', fresh()), 'privacy_deletion_requests', 'rejected'), { status: 'submitted', createdAt: ST() }));
    await s.control('active person resubmits after a rejection with a 2 hour old sign-in', DENY, () => updateDoc(doc(db('sal2', stale), 'privacy_deletion_requests', 'sal2'), { status: 'submitted', createdAt: ST() }));
    await s.control('active person resubmits after a rejection with a fresh sign-in', ALLOW, () => updateDoc(doc(db('sal2', fresh()), 'privacy_deletion_requests', 'sal2'), { status: 'submitted', createdAt: ST() }));
    s.finish();
  });

  it('C03 price stamp flags names that differ from the stored records', async () => {
    const s = stepper('C03-price-stamp');
    await seed([
      ['products/cheap', { productId: 'cheap', productName: 'Cheap Salt', unitPrice: 1, updatedAt: new Date('2026-01-01T00:00:00Z') }],
      ['products/costly', { productId: 'costly', productName: 'Costly Cognac', unitPrice: 100, updatedAt: new Date('2026-01-01T00:00:00Z') }],
      ['retailers/retLow', { retailerId: 'retLow', retailerName: 'Low Price Mart', assignedSalesmanId: 'S002', branchId: 'B1' }],
      ['retailers/retNamed', { retailerId: 'retNamed', retailerName: 'Real Mart', assignedSalesmanId: 'S001', branchId: 'B1' }],
      ['retailer_score_sheet_settings/retLow', { retailerId: 'retLow', productOverrides: { cheap: { unitPrice: 0.5 } }, updatedAt: new Date('2026-01-01T00:00:00Z') }],
      ['users/sal2', { ...ACTORS.sal2, name: 'Sal Two' }],
    ]);
    const item = (name, productId, price, qty = 1) => ({ name, productName: name, productId, price, qty });
    const line = (productId, name, qty, sen) => `${productId}~${name64(name)}~${qty}~${sen}`;
    const sales = db('sal1');
    await s.control('order: cheap product id, costly product name, wrong retailer and salesperson names is accepted for checking', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-NAMES'), orderFor('sal1', 'S001', 'B1', 'ORD-NAMES', {
      retailerId: 'retAny', retailerName: 'Grand Hypermarket', outlet: 'Grand Hypermarket', salesmanName: 'Another Person',
      totalPrice: 1, items: [item('Costly Cognac', 'cheap', 1)], commercialLines: [line('cheap', 'Costly Cognac', 1, 100)],
    })));
    await s.control('salesperson can read a low-price sheet of another salesperson\'s retailer', ALLOW, () => getDoc(doc(sales, 'retailer_score_sheet_settings', 'retLow')));
    await s.control('order: low-sheet retailer id, costly name on the cheap id', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-SHEET'), orderFor('sal1', 'S001', 'B1', 'ORD-SHEET', {
      retailerId: 'retLow', retailerName: 'Low Price Mart', outlet: 'Low Price Mart',
      totalPrice: 0.5, items: [item('Costly Cognac', 'cheap', 0.5)], commercialLines: [line('cheap', 'Costly Cognac', 1, 50)],
    })));
    await s.control('honest name at a wrong price is accepted for checking', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-WRONG'), orderFor('sal1', 'S001', 'B1', 'ORD-WRONG', {
      retailerId: 'retAny', totalPrice: 0.5, items: [item('Cheap Salt', 'cheap', 0.5)], commercialLines: [line('cheap', 'Cheap Salt', 1, 50)],
    })));
    await s.control('honest order with case and extra spaces in the names', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-CASE'), orderFor('sal1', 'S001', 'B1', 'ORD-CASE', {
      retailerId: 'retNamed', retailerName: '  real   MART ', outlet: '  real   MART ',
      totalPrice: 1, items: [item('cheap  SALT', 'cheap', 1)], commercialLines: [line('cheap', 'cheap  SALT', 1, 100)],
    })));
    await s.control('right product, wrong retailer name', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-RET'), orderFor('sal1', 'S001', 'B1', 'ORD-RET', {
      retailerId: 'retNamed', retailerName: 'Grand Hypermarket', outlet: 'Grand Hypermarket',
      totalPrice: 1, items: [item('Cheap Salt', 'cheap', 1)], commercialLines: [line('cheap', 'Cheap Salt', 1, 100)],
    })));
    await s.control('right product and retailer, wrong salesperson name', ALLOW, () => setDoc(doc(db('sal2'), 'orders', 'ORD-SAL'), orderFor('sal2', 'S002', 'B1', 'ORD-SAL', {
      retailerId: 'retNamed', retailerName: 'Real Mart', outlet: 'Real Mart', salesmanName: 'Company Owner',
      totalPrice: 1, items: [item('Cheap Salt', 'cheap', 1)], commercialLines: [line('cheap', 'Cheap Salt', 1, 100)],
    })));
    await s.control('right product, one wrong price and one unknown product', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-MASK'), orderFor('sal1', 'S001', 'B1', 'ORD-MASK', {
      retailerId: 'retAny', totalProducts: 2, totalBoxes: 2, totalPrice: 1.5,
      items: [item('Cheap Salt', 'cheap', 0.5), item('Gone Item', 'gone', 1)],
      commercialLines: [line('cheap', 'Cheap Salt', 1, 50), line('gone', 'Gone Item', 1, 100)],
    })));
    await s.control('salesperson cannot write the stamp', DENY, () => setDoc(doc(sales, 'orders', 'ORD-STAMP'), orderFor('sal1', 'S001', 'B1', 'ORD-STAMP', { serverPriceCheck: { status: 'ok', version: 1 } })));
    const stamps = python('price').orders;
    s.noteControl('real check_orders stamp on ORD-WRONG proves the checker runs', 'mismatch', stamps['ORD-WRONG'].status);
    s.noteControl('wrong price alone keeps the price reason', 'price_differs', stamps['ORD-WRONG'].reason);
    s.note('costly name on the cheap id', 'mismatch/name_differs', `${stamps['ORD-NAMES'].status}/${stamps['ORD-NAMES'].reason}`);
    s.note('costly name on a low-sheet retailer', 'mismatch/name_differs', `${stamps['ORD-SHEET'].status}/${stamps['ORD-SHEET'].reason}`);
    s.note('wrong retailer name is named', 'mismatch/name_differs/retailer', `${stamps['ORD-RET'].status}/${stamps['ORD-RET'].reason}/${stamps['ORD-RET'].names.join(',')}`);
    s.note('wrong salesperson name is named', 'mismatch/name_differs/salesman', `${stamps['ORD-SAL'].status}/${stamps['ORD-SAL'].reason}/${stamps['ORD-SAL'].names.join(',')}`);
    s.note('one unknown product does not hide a wrong price', 'mismatch/price_differs', `${stamps['ORD-MASK'].status}/${stamps['ORD-MASK'].reason}`);
    s.noteControl('case and extra spaces are not a difference', 'ok', stamps['ORD-CASE'].status);
    const stored = await readAdmin('orders/ORD-NAMES');
    s.noteControl('stored order keeps the costly name beside the stamp', 'Costly Cognac', stored.items[0].name);
    s.finish();
  });

  it('C04 visits carry only the caller\'s own salesmanCode and branchId', async () => {
    const s = stepper('C04-visits');
    const writer = db('sal1');
    const ownVisit = doc(writer, 'visits', 'own');
    await s.control('forged ownerUid refused', DENY, () => setDoc(doc(writer, 'visits', 'forged-owner'), visit('sal2')));
    await s.control('create with another code and branch', DENY, () => setDoc(doc(writer, 'visits', 'forged'), visit('sal1', { salesmanCode: 'S003', branchId: 'B2' })));
    await s.control('create with another code only', DENY, () => setDoc(doc(writer, 'visits', 'forged-code'), visit('sal1', { salesmanCode: 'S003' })));
    await s.control('create with another branch only', DENY, () => setDoc(doc(writer, 'visits', 'forged-branch'), visit('sal1', { branchId: 'B2' })));
    await s.control('create with another code in snake case', DENY, () => setDoc(doc(writer, 'visits', 'forged-snake'), visit('sal1', { salesman_code: 'S003', branch_id: 'B2' })));
    await s.control('create with own code and branch', ALLOW, () => setDoc(ownVisit, visit('sal1', { salesmanCode: 'S001', branchId: 'B1' })));
    await s.control('create with no code and branch', ALLOW, () => setDoc(doc(writer, 'visits', 'bare'), visit('sal1')));
    const noCode = db('nocode');
    await s.control('person with no code on the profile writes a visit with no code', ALLOW, () => setDoc(doc(noCode, 'visits', 'nocode-bare'), visit('nocode')));
    await s.control('person with no code, 1.0.2 phone sends the uid as the code', ALLOW, () => setDoc(doc(noCode, 'visits', 'nocode-uid'), visit('nocode', { salesmanCode: 'nocode' })));
    await s.probe('person with no code on file states a code: the rules have nothing to compare it with, so it is kept', ALLOW, () => setDoc(doc(noCode, 'visits', 'nocode-forged'), visit('nocode', { salesmanCode: 'S002' })));
    await s.control('person with a code cannot use the uid as the code', DENY, () => setDoc(doc(writer, 'visits', 'coded-uid'), visit('sal1', { salesmanCode: 'sal1' })));
    await s.control('queued visit written with the branch before a move to B2 is refused', DENY, async () => {
      await seed([['user_access/mover', row('mover', { role: 'salesman', employeeCode: 'S020', branchId: 'B2' })]]);
      return setDoc(doc(db('mover'), 'visits', 'moved'), visit('mover', { salesmanCode: 'S020', branchId: 'B1' }));
    });
    await s.control('own supervisor sees the honest visit', ALLOW, () => getDoc(doc(db('sup1'), 'visits', 'own')));
    await seed([['user_access/sup3', row('sup3', { role: 'supervisor', branchId: 'B2', employeeCode: 'V3', assignedSalesmanCodes: ['S003'] })]]);
    await s.control('supervisor of another code cannot read the honest visit', DENY, () => getDoc(doc(db('sup3'), 'visits', 'own')));
    await s.control('manager of another branch cannot read the honest visit', DENY, () => getDoc(doc(db('mgr2'), 'visits', 'own')));
    await s.control('update moves an honest visit to another code and branch', DENY, () => updateDoc(ownVisit, { salesmanCode: 'S003', branchId: 'B2', updatedAt: ST() }));
    await s.control('own supervisor keeps sight of the visit', ALLOW, () => getDoc(doc(db('sup1'), 'visits', 'own')));
    await s.control('update with own code and branch', ALLOW, () => updateDoc(ownVisit, { salesmanCode: 'S001', branchId: 'B1', updatedAt: ST() }));
    await s.control('update that changes only progress', ALLOW, () => updateDoc(ownVisit, { progress: 2, status: 'counting', updatedAt: ST() }));
    await seed([['visits/stale', visit('sal1', { salesmanCode: 'OLDCODE', branchId: 'B1', createdAt: new Date('2026-10-01T00:00:00Z') })]]);
    await s.control('update of a visit with an old code that leaves the code alone', ALLOW, () => updateDoc(doc(writer, 'visits', 'stale'), { progress: 1, updatedAt: ST() }));
    s.finish();
  });

  it('C04 visits of people whose code or branch the rules cannot read are still saved', async () => {
    const s = stepper('C04-visits-old-shapes');
    const legacy = (uid, extra = {}) => ({ uid, userDocId: uid, role: 'salesman', status: 'active', isActive: true, ...extra });
    const shapes = [
      ['v2 access without a code, profile in another document, phone sends that document id', row('o1', { role: 'salesman', userDocId: 'doc-o1' }), ['users/doc-o1', { uid: 'o1', role: 'salesman' }], { salesmanCode: 'doc-o1' }],
      ['legacy access without a code, profile in another document', legacy('o2', { userDocId: 'doc-o2' }), ['users/doc-o2', { uid: 'o2', role: 'salesman', status: 'active', isActive: true }], { salesmanCode: 'doc-o2' }],
      ['legacy profile that only has a userId', legacy('o3'), ['users/o3', { uid: 'o3', role: 'salesman', status: 'active', isActive: true, userId: 'U3' }], { salesmanCode: 'U3' }],
      ['legacy profile with an empty employeeCode and a staffId', legacy('o4'), ['users/o4', { uid: 'o4', role: 'salesman', status: 'active', isActive: true, employeeCode: '', staffId: 'S4' }], { salesmanCode: 'S4' }],
      ['v2 access without a code, the profile still holds a code', row('o5', { role: 'salesman' }), ['users/o5', { uid: 'o5', role: 'salesman', staffId: 'S5' }], { salesmanCode: 'S5' }],
      ['v2 access without a branch, the profile holds a branch', row('o6', { role: 'salesman', employeeCode: 'S6', branchId: '' }), ['users/o6', { uid: 'o6', role: 'salesman', employeeCode: 'S6', branchId: 'B1' }], { salesmanCode: 'S6', branchId: 'B1' }],
      ['1.0.2 payload from a person with no code: the uid is sent as the code', row('o7', { role: 'salesman' }), null, { salesmanCode: 'o7', branchId: 'B1' }],
    ];
    for (const [label, access, profile, fields] of shapes) {
      await seed([[`user_access/${access.uid}`, access], ...(profile ? [profile] : [])]);
      await s.control(label, ALLOW, () => setDoc(doc(db(access.uid), 'visits', `v-${access.uid}`), visit(access.uid, fields)));
    }
    await seed([['user_access/o8', { uid: 'o8', role: 'salesman', status: 'active', isActive: true, branchId: 'B1', employeeCode: 'L8' }]]);
    await s.control('legacy person with a code states a different code', DENY, () => setDoc(doc(db('o8'), 'visits', 'v-o8'), visit('o8', { salesmanCode: 'S002' })));
    await s.control('legacy person with a code states the same code', ALLOW, () => setDoc(doc(db('o8'), 'visits', 'v-o8-ok'), visit('o8', { salesmanCode: 'L8' })));
    await s.control('person with a branch states a different branch', DENY, () => setDoc(doc(db('sal1'), 'visits', 'v-branch'), visit('sal1', { branchId: 'B2' })));
    await s.control('another owner uid is still refused for a person without a code', DENY, () => setDoc(doc(db('o7'), 'visits', 'v-other'), visit('sal1')));
    s.finish();
  });

  it('C05 unapproved order for another salesperson\'s retailer', async () => {
    const s = stepper('C05-other-retailer');
    await seed([
      ['products/p1', { productId: 'p1', productName: 'Juice', unitPrice: 10, updatedAt: new Date('2026-01-01T00:00:00Z') }],
      ['retailers/retB', { retailerId: 'retB', retailerName: 'B Owned Mart', assignedSalesmanId: 'S002', branchId: 'B1' }],
      ['route_plans/planB', routePlan('planB', { salesmanUid: 'sal2', salesmanCode: 'S002', stopRetailerIds: { 'stop-1': 'retB', 'stop-2': 'r2' } })],
    ]);
    const sales = db('sal1');
    await s.control('salesperson A can read B\'s retailer', ALLOW, () => getDoc(doc(sales, 'retailers', 'retB')));
    await s.control('assigned_route order on B\'s plan is refused', DENY, () => setDoc(doc(sales, 'orders', 'ORD-V2-sal1.planB.stop-1'), orderFor('sal1', 'S001', 'B1', 'ORD-V2-sal1.planB.stop-1', {
      visitSource: 'assigned_route', routePlanId: 'planB', routeStopId: 'stop-1', retailerId: 'retB',
    })));
    await s.probe('personal_planner order for B\'s retailer, status submitted', ALLOW, () => setDoc(doc(sales, 'orders', 'ORD-OTHER'), orderFor('sal1', 'S001', 'B1', 'ORD-OTHER', {
      retailerId: 'retB', retailerName: 'B Owned Mart', outlet: 'B Owned Mart', totalProducts: 1, totalBoxes: 5, totalPrice: 50,
      items: [{ name: 'Juice', productName: 'Juice', productId: 'p1', price: 10, qty: 5 }],
      commercialLines: [`p1~${name64('Juice')}~5~1000`],
    })));
    const out = python('ranking', ['ORD-OTHER', 'retB']);
    s.noteControl('no order: no series for retB', 0, out.none.seriesForRetailer);
    s.note('submitted order creates a series for retB', 1, out.submitted.seriesForRetailer);
    s.note('series is attributed to the owner, not the submitter', 'S002', out.submitted.seriesOwnerCode);
    s.note('quantity from the unapproved order enters the series', 5, out.submitted.seriesQuantity);
    s.note('unapproved order appears in retailer_priority_rankings for the owner', true, out.submitted.rankedUnderOwner);
    s.noteControl('rejected order adds no demand', 0, out.rejected.seriesForRetailer);
    s.note('rejected order still resets the contact date', true, out.rejected.lastContactSet);
    s.finish();
  });

  it('C06 legacy user_access identities ignoring disabledReasons', async () => {
    const s = stepper('C06-legacy');
    const legacy = (uid, fields) => ({ uid, status: 'active', isActive: true, ...fields });
    await seed([
      ['products/p1', { productId: 'p1', productName: 'Juice', unitPrice: 10 }],
      ['user_access/legClean', legacy('legClean', { role: 'salesman', branchId: 'B1', employeeCode: 'E0' })],
      ['user_access/legA', legacy('legA', { role: 'salesman', branchId: 'B1', employeeCode: 'E1', disabledReasons: ['billing_lapse'] })],
      ['user_access/legNull', legacy('legNull', { role: 'salesman', branchId: 'B1', employeeCode: 'E9', disabledReasons: null })],
      ['user_access/legB', { uid: 'legB', userDocId: 'L1' }],
      ['users/L1', { uid: 'legB', role: 'salesman', status: 'active', employeeCode: 'L1', disabledReasons: ['billing_lapse'] }],
      ['user_access/v2A', row('v2A', { role: 'salesman', employeeCode: 'E2', disabledReasons: ['billing_lapse'] })],
      ['users/uidOnly', { uid: 'uidOnly', role: 'salesman', status: 'active', employeeCode: 'E3', disabledReasons: ['billing_lapse'] }],
      ['user_access/legAdm', legacy('legAdm', { role: 'admin', branchId: 'B1', employeeCode: 'E4', disabledReasons: ['admin_suspension'] })],
      ['user_access/v2Adm', row('v2Adm', { role: 'admin', branchId: '', employeeCode: 'E5', disabledReasons: ['admin_suspension'] })],
      ['user_access/legC', { uid: 'legC', status: 'active', userDocId: 'MISSING' }],
      ['users/MISSING', { disabledReasons: ['billing_lapse'] }],
      ['notification_read_state/legC', { readThroughAt: new Date('2026-11-01T00:00:00Z') }],
      ['orders/ORD-X', storedOrder('sal3', 'S003', 'B2', 'ORD-X')],
    ]);
    const vis = (uid) => setDoc(doc(db(uid), 'visits', `v-${uid}`), visit(uid));
    await s.control('clean legacy row works', ALLOW, () => vis('legClean'));
    await s.control('legacy row with a null reasons list', DENY, () => vis('legNull'));
    await s.control('v2 row holding billing_lapse is refused', DENY, () => vis('v2A'));
    await s.control('v2 row holding billing_lapse cannot read products', DENY, () => getDoc(doc(db('v2A'), 'products', 'p1')));
    await s.control('legacy uid-only profile holding billing_lapse is refused', DENY, () => vis('uidOnly'));
    await s.control('v2 admin holding admin_suspension cannot read another branch order', DENY, () => getDoc(doc(db('v2Adm'), 'orders', 'ORD-X')));
    await s.control('case A legacy row holding billing_lapse writes a visit', DENY, () => vis('legA'));
    await s.control('case A reads products', DENY, () => getDoc(doc(db('legA'), 'products', 'p1')));
    await s.probe('case B linked profile holding billing_lapse writes a visit', ALLOW, () => vis('legB'));
    await s.control('legacy admin holding admin_suspension reads another branch order', DENY, () => getDoc(doc(db('legAdm'), 'orders', 'ORD-X')));
    await s.control('legacy admin holding admin_suspension creates a retailer', DENY, () => setDoc(doc(db('legAdm'), 'retailers', 'new-r'), { retailerName: 'New', branchId: 'B1' }));
    await s.probe('case C broken link passes an active-only read', ALLOW, () => getDoc(doc(db('legC'), 'notification_read_state', 'legC')));
    await s.probe('case C grants no business role', DENY, () => getDoc(doc(db('legC'), 'products', 'p1')));

    await seed([
      ['user_access/lapseGood', { uid: 'lapseGood', role: 'salesman', status: 'active', isActive: true, branchId: 'B1', employeeCode: 'E6' }],
      ['user_access/lapseBad', { uid: 'lapseBad', userDocId: 'LBAD' }],
      ['users/LBAD', { uid: 'lapseBad', role: 'salesman', status: 'active', employeeCode: 'E7', disabledReasons: 'not-a-list' }],
    ]);
    const lapse = python('lapse', ['lapseGood', 'lapseBad', 'LBAD']);
    s.noteControl('real lapse converts a well-formed legacy row to v2', 2, lapse.lapseGood.accessVersion);
    await s.control('after real lapse the converted row is refused', DENY, () => vis('lapseGood'));
    s.note('real lapse leaves a row with a malformed profile list at legacy', 'none', lapse.lapseBad.accessVersion ?? 'none');
    s.note('real lapse wrote the reason on that row', 'billing_lapse', (lapse.lapseBad.disabledReasons || []).join(','));
    await s.control('after real lapse that row still writes a visit', DENY, () => vis('lapseBad'));
    s.finish();
  });

  it('C07 system_audit_logs create binds the actor role and email to the caller', async () => {
    const s = stepper('C07-audit-actor');
    const mail = (uid) => ({ email: `${uid}@example.test` });
    const logs = (uid, id, data, token = mail(uid)) => setDoc(doc(db(uid, token), 'system_audit_logs', id), data);
    const row2 = (uid, extra = {}) => auditRow(uid, { actorEmail: `${uid}@example.test`, ...extra });
    await s.control('honest row by a supervisor', ALLOW, () => logs('sup1', 'a-honest', row2('sup1', { actorRole: 'supervisor', actorName: 'Sup One' })));
    await s.control('honest row with the email in other letter case', ALLOW, () => logs('sup1', 'a-case', row2('sup1', { actorRole: 'supervisor', actorEmail: 'SUP1@Example.test' })));
    await s.control('actorUid of another person refused', DENY, () => logs('sup1', 'a-uid', row2('adm')));
    await s.control('salesperson refused', DENY, () => logs('sal1', 'a-sales', row2('sal1', { actorRole: 'salesman' })));
    await s.control('forged lock action refused', DENY, () => logs('sup1', 'a-lock', row2('sup1', { action: 'local_lock_reported', actorRole: 'supervisor' })));
    await s.control('lock_ id prefix refused', DENY, () => logs('sup1', 'lock_request_x', row2('sup1', { entityId: 'x', actorRole: 'supervisor' })));
    await s.probe('supervisor writes actorRole admin and an owner email', DENY, () => logs('sup1', 'a-forged', row2('sup1', { actorRole: 'admin', actorName: 'Company Owner', actorEmail: 'owner@example.test', action: 'user_role_changed', summary: 'Owner approved this change' })));
    await s.probe('supervisor writes actorRole admin with the true email', DENY, () => logs('sup1', 'a-role-only', row2('sup1', { actorRole: 'admin' })));
    await s.probe('supervisor writes the true role with another email', DENY, () => logs('sup1', 'a-email-only', row2('sup1', { actorRole: 'supervisor', actorEmail: 'owner@example.test' })));
    await s.probe('branch manager writes actorRole developer', DENY, () => logs('mgr1', 'a-forged-2', row2('mgr1', { actorRole: 'developer', actorName: 'Support' })));
    await s.control('row with an empty role is a row without a role', ALLOW, () => logs('sup1', 'a-empty-role', row2('sup1', { actorRole: '' })));
    await s.control('row with an empty role and an empty email is a row without both', ALLOW, () => logs('sup1', 'a-empty-both', row2('sup1', { actorRole: '', actorEmail: '' })));
    await s.probe('token with no email and a made-up email on the row', DENY, () => logs('sup1', 'a-no-token-email', row2('sup1', { actorRole: 'supervisor' }), {}));
    await s.control('token with no email and an empty email on the row', ALLOW, () => logs('sup1', 'a-no-email', row2('sup1', { actorRole: 'supervisor', actorEmail: '' }), {}));
    await s.control('admin writes a true admin row', ALLOW, () => logs('adm', 'a-admin', row2('adm', { actorRole: 'admin' })));
    await s.control('a name is only a label: the true role and email decide who wrote the row', ALLOW, () => logs('sup1', 'a-name', row2('sup1', { actorRole: 'supervisor', actorName: 'Company Owner' })));
    await s.control('a name with no role and no email is kept with the bound user id', ALLOW, () => logs('sup1', 'a-name-bare', row2('sup1', { actorRole: '', actorEmail: '', actorName: 'Company Owner' })));
    await seed([
      ['user_access/spaced', row('spaced', { role: 'supervisor', employeeCode: 'V3', name: 'Jane Tan ' })],
      ['users/spaced', row('spaced', { role: 'supervisor', employeeCode: 'V3', name: 'Jane Tan ' })],
      ['user_access/unl', { accessVersion: 2, uid: 'unl', status: 'active', isActive: true, branchId: 'B1', employeeCode: 'V4', role: 'supervisor', assignedSalesmanCodes: [], disabledReasons: [] }],
      ['users/doc-unl', { uid: 'unl', role: 'supervisor', name: 'Una Link', status: 'active' }],
      ['user_access/snk', { uid: 'snk', user_doc_id: 'doc-snk', status: 'active', isActive: true, role: 'supervisor', branchId: 'B1', employeeCode: 'V5' }],
      ['users/doc-snk', { uid: 'snk', role: 'supervisor', status: 'active', isActive: true, name: 'Sn Ake', employeeCode: 'V5' }],
      ['user_access/stale', row('stale', { role: 'branch_manager', employeeCode: 'V6' })],
      ['users/stale', row('stale', { role: 'supervisor', employeeCode: 'V6', name: 'Stale Role' })],
    ]);
    await s.control('profile name with a trailing space, client sends it trimmed', ALLOW, () => logs('spaced', 'a-spaced', row2('spaced', { actorRole: 'supervisor', actorName: 'Jane Tan' })));
    await s.control('profile kept in a document the access row does not name', ALLOW, () => logs('unl', 'a-unlinked', row2('unl', { actorRole: 'supervisor', actorName: 'Una Link' })));
    await s.control('legacy user_doc_id link to the profile', ALLOW, () => logs('snk', 'a-snake-link', row2('snk', { actorRole: 'supervisor', actorName: 'Sn Ake' })));
    await s.control('profile role differs from the access role, client sends the access role', ALLOW, () => logs('stale', 'a-stale-role', row2('stale', { actorRole: 'branch_manager', actorName: 'Stale Role' })));
    await s.control('actorName equal to the profile name is accepted', ALLOW, () => logs('sup1', 'a-name-profile', row2('sup1', { actorRole: 'supervisor', actorName: 'Sup One' })));
    await s.control('actorName equal to the sign-in email is accepted', ALLOW, () => logs('sup1', 'a-name-email', row2('sup1', { actorRole: 'supervisor', actorName: 'sup1@example.test' })));
    await s.control('empty actorName is accepted', ALLOW, () => logs('sup1', 'a-name-empty', row2('sup1', { actorRole: 'supervisor', actorName: '' })));
    await s.control('base dashboard call with no actor passed: empty role, email as name', ALLOW, () => logs('sup1', 'a-base-noactor', row2('sup1', { actorRole: '', actorName: 'sup1@example.test' })));
    await s.control('admin without a profile name writes the sign-in email as name', ALLOW, () => logs('adm', 'a-admin-email-name', row2('adm', { actorRole: 'admin', actorName: 'adm@example.test' })));
    await s.control('unlock row with a forged actorEmail is refused', DENY, async () => {
      const id = lockId();
      await seed([
        [`account_lock_requests/${id}`, { claimedEmail: 'forge@example.test', client: 'mobile', localLockedUntil: Timestamp.fromMillis(Date.now() + 600000), createdAt: new Date(), status: 'pending', reviewedAt: null, reviewedBy: null }],
        [`account_lock_receipts/${id}`, { status: 'pending', createdAt: new Date(), reviewedAt: null }],
      ]);
      return unlockBatch(db('adm', { email: 'a@example.test' }), 'adm', id, 'owner@example.test');
    });
    await s.control('unlock row with the true sign-in email in other letter case is accepted', ALLOW, async () => {
      const id = lockId();
      await seed([
        [`account_lock_requests/${id}`, { claimedEmail: 'case@example.test', client: 'mobile', localLockedUntil: Timestamp.fromMillis(Date.now() + 600000), createdAt: new Date(), status: 'pending', reviewedAt: null, reviewedBy: null }],
        [`account_lock_receipts/${id}`, { status: 'pending', createdAt: new Date(), reviewedAt: null }],
      ]);
      return unlockBatch(db('adm', { email: 'a@example.test' }), 'adm', id, 'A@Example.test');
    });
    const stored = await readAdmin('system_audit_logs/a-honest');
    s.noteControl('honest role stored', 'supervisor', stored.actorRole);
    s.noteControl('true uid stays bound', 'sup1', stored.actorUid);
    s.noteControl('forged row was not stored', null, await readAdmin('system_audit_logs/a-forged'));
    const borrowed = await readAdmin('system_audit_logs/a-name');
    s.noteControl('a row with a borrowed name stores the true email beside it', 'sup1@example.test', borrowed.actorEmail);
    s.noteControl('a row with a borrowed name stores the true role beside it', 'supervisor', borrowed.actorRole);
    s.noteControl('a row with a borrowed name stores the true user id beside it', 'sup1', borrowed.actorUid);
    s.finish();
  });

  it('C08 users self-update needs an active account', async () => {
    const s = stepper('C08-users-self');
    await seed([
      ['user_access/lapsed', row('lapsed', { role: 'salesman', employeeCode: 'S010', disabledReasons: ['billing_lapse'] })],
      ['users/lapsed', row('lapsed', { role: 'salesman', employeeCode: 'S010' })],
      ['users/noaccess', { uid: 'noaccess', role: 'salesman', status: 'suspended', isActive: false, name: 'Old' }],
      ['users/legacyactive', { uid: 'legacyactive', role: 'salesman', status: 'active', isActive: true, name: 'Old' }],
    ]);
    const change = { name: 'Company Owner', email: 'forged@example.test' };
    await s.control('active person edits own name', ALLOW, () => updateDoc(doc(db('sal1'), 'users', 'sal1'), change));
    await s.control('active legacy profile with no access row edits own name', ALLOW, () => updateDoc(doc(db('legacyactive'), 'users', 'legacyactive'), { name: 'New' }));
    await s.control('cannot edit another person', DENY, () => updateDoc(doc(db('sal1'), 'users', 'sal2'), change));
    await s.control('suspended person cannot change role', DENY, () => updateDoc(doc(db('susp'), 'users', 'susp'), { role: 'admin' }));
    await s.control('suspended person cannot change status', DENY, () => updateDoc(doc(db('susp'), 'users', 'susp'), { status: 'active' }));
    await s.control('suspended person cannot change branch', DENY, () => updateDoc(doc(db('susp'), 'users', 'susp'), { branchId: 'B2' }));
    await s.control('suspended person edits own name and email', DENY, () => updateDoc(doc(db('susp'), 'users', 'susp'), change));
    await s.control('person holding billing_lapse edits own name and email', DENY, () => updateDoc(doc(db('lapsed'), 'users', 'lapsed'), change));
    await s.control('suspended legacy profile with no access row edits own name', DENY, () => updateDoc(doc(db('noaccess'), 'users', 'noaccess'), { name: 'New' }));
    await s.control('suspended person adds an unknown field', DENY, () => updateDoc(doc(db('susp'), 'users', 'susp'), { freeField: 'x'.repeat(2000) }));
    s.finish();
  });

  it('C09 salesperson taps a stop, admin cannot withdraw', async () => {
    const s = stepper('C09-withdraw');
    await seed([
      ['route_plans/planUntapped', routePlan('planUntapped')],
      ['route_plans/planTapped', routePlan('planTapped')],
      ['route_plans/planCleared', routePlan('planCleared')],
      ['route_plans/planArchive', routePlan('planArchive')],
      ['route_plans/planDelete', routePlan('planDelete')],
      ['route_plans/planNoUid', routePlan('planNoUid', { salesmanUid: '' })],
    ]);
    const admin = db('adm');
    const sales = db('sal1');
    const tap = (planId) => setDoc(doc(sales, 'route_plan_progress', `${planId}_sal1`), tapStop(planId, 'sal1', 'S001', 'B1', 'stop-1'), { merge: true });
    await s.control('admin withdraws a published route nobody tapped', ALLOW, () => updateDoc(doc(admin, 'route_plans', 'planUntapped'), withdraw()));
    await s.control('salesperson tap writes the progress document with status assigned', ALLOW, () => tap('planTapped'));
    const progress = await readAdmin('route_plan_progress/planTapped_sal1');
    s.noteControl('tap did not accept the route', 'assigned', progress.status);
    await s.probe('admin withdraw after the tap', DENY, () => updateDoc(doc(admin, 'route_plans', 'planTapped'), withdraw()));
    await s.control('tap on second plan', ALLOW, () => tap('planCleared'));
    await s.control('salesperson clears the selection', ALLOW, () => updateDoc(doc(sales, 'route_plan_progress', 'planCleared_sal1'), {
      selectedStopId: deleteField(), selectionRevision: increment(1), updatedAt: ST(), lastSyncedAt: ST(),
    }));
    await s.probe('admin withdraw after the tap was cleared', DENY, () => updateDoc(doc(admin, 'route_plans', 'planCleared'), withdraw()));
    await s.probe('admin cannot remove the progress document', DENY, () => deleteDoc(doc(admin, 'route_plan_progress', 'planTapped_sal1')));
    await s.probe('salesperson cannot remove the progress document', DENY, () => deleteDoc(doc(sales, 'route_plan_progress', 'planTapped_sal1')));
    await s.control('tap on archive plan', ALLOW, () => tap('planArchive'));
    await s.info('rule-level exit: admin sets status archived after the tap', ALLOW, () => updateDoc(doc(admin, 'route_plans', 'planArchive'), { status: 'archived', updatedAt: ST() }));
    await s.control('tap on delete plan', ALLOW, () => tap('planDelete'));
    await s.info('rule-level exit: admin deletes the plan after the tap', DENY, () => deleteDoc(doc(admin, 'route_plans', 'planDelete')));
    await s.info('route with an empty salesmanUid cannot be withdrawn even with no tap', DENY, () => updateDoc(doc(admin, 'route_plans', 'planNoUid'), withdraw()));
    s.finish();
  });

  async function inTwoCompanies(run) {
    const second = await initializeTestEnvironment({ projectId: `${PROJECT}-co2`, firestore: { rules: fs.readFileSync(RULES_PATH, 'utf8') } });
    try {
      for (const [company, environment] of [['company A', env], ['company B', second]]) {
        await environment.clearFirestore();
        await environment.withSecurityRulesDisabled(async (context) => {
          const admin = context.firestore();
          for (const [uid, data] of Object.entries(ACTORS)) {
            await setDoc(doc(admin, 'user_access', uid), data);
            await setDoc(doc(admin, 'users', uid), data);
          }
          if (company === 'company A') {
            const onlyA = row('admOnlyA', { role: 'admin', branchId: '', employeeCode: 'A9' });
            await setDoc(doc(admin, 'user_access', 'admOnlyA'), onlyA);
            await setDoc(doc(admin, 'users', 'admOnlyA'), onlyA);
          }
        });
        const seedIn = (entries) => environment.withSecurityRulesDisabled(async (context) => {
          for (const [docPath, data] of entries) await setDoc(doc(context.firestore(), ...docPath.split('/')), data);
        });
        const readIn = async (docPath) => {
          let out;
          await environment.withSecurityRulesDisabled(async (context) => {
            const snap = await getDoc(doc(context.firestore(), ...docPath.split('/')));
            out = snap.exists() ? snap.data() : null;
          });
          return out;
        };
        await run(company, (uid) => environment.authenticatedContext(uid).firestore(), seedIn, readIn);
      }
    } finally {
      await second.cleanup();
    }
  }

  it('FIX-228 a route returned to draft drops its approve and publish dates, in two companies', async () => {
    const s = stepper('FIX-228-draft-dates');
    const dates = { approvedAt: new Date('2026-11-01T00:00:00Z'), publishedAt: new Date('2026-11-02T00:00:00Z') };
    const toDraft = (extra = {}) => ({ status: 'draft', updatedAt: ST(), approvedAt: deleteField(), publishedAt: deleteField(), ...extra });
    await inTwoCompanies(async (company, as, seedIn, readIn) => {
      await seedIn([
        ['route_plans/planAdm', routePlan('planAdm', dates)],
        ['route_plans/planSup', routePlan('planSup', dates)],
        ['route_plans/planKeep', routePlan('planKeep', dates)],
        ['route_plans/planTap', routePlan('planTap', dates)],
        ['route_plan_progress/planTap_sal1', { ...tapStop('planTap', 'sal1', 'S001', 'B1', 'stop-1'), updatedAt: new Date(), lastSyncedAt: new Date() }],
      ]);
      const keep = () => doc(as('adm'), 'route_plans', 'planKeep');
      await s.control(`${company}: admin returns a published route to draft and removes its approve and publish dates`, ALLOW, () => updateDoc(doc(as('adm'), 'route_plans', 'planAdm'), toDraft()));
      const after = await readIn('route_plans/planAdm');
      s.noteControl(`${company}: the draft shows no old approve or publish date`, 'draft,false,false', `${after.status},${'approvedAt' in after},${'publishedAt' in after}`);
      await s.control(`${company}: supervisor of the salesperson does the same`, ALLOW, () => updateDoc(doc(as('sup1'), 'route_plans', 'planSup'), toDraft()));
      await s.control(`${company}: supervisor of another team cannot`, DENY, () => updateDoc(doc(as('sup2'), 'route_plans', 'planKeep'), toDraft()));
      await s.control(`${company}: salesperson cannot`, DENY, () => updateDoc(doc(as('sal1'), 'route_plans', 'planKeep'), toDraft()));
      await s.control(`${company}: a route the salesperson started cannot be returned to draft`, DENY, () => updateDoc(doc(as('adm'), 'route_plans', 'planTap'), toDraft()));
      await s.control(`${company}: a route that stays published keeps its publish date`, DENY, () => updateDoc(keep(), { publishedAt: deleteField(), updatedAt: ST() }));
      await s.control(`${company}: archiving keeps the publish date`, DENY, () => updateDoc(keep(), { status: 'archived', updatedAt: ST(), publishedAt: deleteField() }));
      await s.control(`${company}: a return to draft cannot write a new publish date`, DENY, () => updateDoc(keep(), toDraft({ publishedAt: ST() })));
      await s.control(`${company}: a return to draft cannot remove other fields`, DENY, () => updateDoc(keep(), toDraft({ stopIds: deleteField() })));
      if (company === 'company B') {
        await s.control(`${company}: an admin known only in company A is refused`, DENY, () => updateDoc(doc(as('admOnlyA'), 'route_plans', 'planKeep'), toDraft()));
      }
    });
    s.finish();
  });

  it('FIX-131 a score sheet template can be retired and nothing else changes, in two companies', async () => {
    const s = stepper('FIX-131-retire-template');
    const template = (templateId) => ({
      kind: 'template', templateId, revision: 1, name: templateId, productIds: ['p1'], productCount: 1, status: 'active',
      createdByUid: 'adm', createdAt: new Date('2026-11-01T00:00:00Z'),
    });
    const retire = (uid, extra = {}) => ({ status: 'retired', retiredAt: ST(), retiredByUid: uid, ...extra });
    await inTwoCompanies(async (company, as, seedIn, readIn) => {
      await seedIn([
        ['score_sheets/tpl_a_r1', template('tpl_a')],
        ['score_sheets/tpl_b_r1', template('tpl_b')],
        ['score_sheets/asg_a_r1', { kind: 'assignment', assignmentId: 'asg_a', assignmentRevision: 1, templateId: 'tpl_b', templateName: 'tpl_b', salesmanUid: 'sal1', retailerId: 'r1' }],
      ]);
      const b = (uid) => doc(as(uid), 'score_sheets', 'tpl_b_r1');
      await s.control(`${company}: admin retires a template`, ALLOW, () => updateDoc(doc(as('adm'), 'score_sheets', 'tpl_a_r1'), retire('adm')));
      const after = await readIn('score_sheets/tpl_a_r1');
      s.noteControl(`${company}: the retired template keeps its products and records who retired it`, 'retired,adm,p1', `${after.status},${after.retiredByUid},${after.productIds.join('|')}`);
      await s.control(`${company}: a retired template cannot be made active again`, DENY, () => updateDoc(doc(as('adm'), 'score_sheets', 'tpl_a_r1'), { status: 'active' }));
      await s.control(`${company}: a retired template cannot be retired again`, DENY, () => updateDoc(doc(as('adm'), 'score_sheets', 'tpl_a_r1'), retire('adm')));
      for (const uid of ['sup1', 'mgr1', 'sal1']) {
        await s.control(`${company}: ${uid} cannot retire a template`, DENY, () => updateDoc(b(uid), retire(uid)));
      }
      await s.control(`${company}: retiring cannot change the products`, DENY, () => updateDoc(b('adm'), retire('adm', { productIds: ['p2'] })));
      await s.control(`${company}: retiring cannot rename the template`, DENY, () => updateDoc(b('adm'), retire('adm', { name: 'renamed' })));
      await s.control(`${company}: retiring must name the person who retires`, DENY, () => updateDoc(b('adm'), retire('sal1')));
      await s.control(`${company}: retiring must use the server time`, DENY, () => updateDoc(b('adm'), retire('adm', { retiredAt: new Date('2026-01-01T00:00:00Z') })));
      await s.control(`${company}: retiring needs the person and the time`, DENY, () => updateDoc(b('adm'), { status: 'retired' }));
      await s.control(`${company}: a template cannot move to another status`, DENY, () => updateDoc(b('adm'), retire('adm', { status: 'archived' })));
      await s.control(`${company}: an assignment record cannot be retired`, DENY, () => updateDoc(doc(as('adm'), 'score_sheets', 'asg_a_r1'), retire('adm')));
      if (company === 'company B') {
        await s.control(`${company}: an admin known only in company A is refused`, DENY, () => updateDoc(b('admOnlyA'), retire('admOnlyA')));
      }
    });
    s.finish();
  });

  for (const who of ['adm', 'sup1']) it(`C09 a started route is replaced and the corrected route publishes for the same week (${who})`, async () => {
    const s = stepper('C09-replace-' + who);
    const weekStart = Timestamp.fromMillis(Date.now() + 7 * 86400000);
    const local = new Date(weekStart.toMillis() + 8 * 3600000);
    const weekKey = `${local.getUTCFullYear()}${String(local.getUTCMonth() + 1).padStart(2, '0')}${String(local.getUTCDate()).padStart(2, '0')}`;
    const keyId = `sal1_${weekKey}`;
    const keyFor = (planId, extra = {}) => ({
      keyId, planId, salesmanIdentity: 'sal1', salesmanUid: 'sal1', salesmanCode: 'S001', weekKey, weekStart,
      active: true, updatedByUid: who, updatedAt: ST(), ...extra,
    });
    await seed([
      ['route_plans/planA', routePlan('planA', { weekStart, publicationKeyId: keyId })],
      ['route_plan_publication_keys/' + keyId, keyFor('planA', { updatedAt: new Date('2026-11-01T00:00:00Z') })],
      ['route_plan_progress/planA_sal1', { ...tapStop('planA', 'sal1', 'S001', 'B1', 'stop-1'), updatedAt: new Date(), lastSyncedAt: new Date() }],
      ['route_plans/planB', routePlan('planB', { weekStart, status: 'approved' })],
    ]);
    const admin = db(who);
    const publishB = () => {
      const batch = writeBatch(admin);
      batch.update(doc(admin, 'route_plans', 'planB'), { status: 'published', publicationKeyId: keyId, updatedAt: ST(), publishedAt: ST() });
      batch.set(doc(admin, 'route_plan_publication_keys', keyId), keyFor('planB'), { merge: true });
      return batch.commit();
    };
    await s.control('withdraw of a started route is still refused', DENY, () => updateDoc(doc(admin, 'route_plans', 'planA'), withdraw()));
    await s.control('replace: admin archives the started route and releases its key in one write', ALLOW, () => {
      const batch = writeBatch(admin);
      batch.update(doc(admin, 'route_plans', 'planA'), { status: 'archived', updatedAt: ST() });
      batch.update(doc(admin, 'route_plan_publication_keys', keyId), { active: false, updatedByUid: who, updatedAt: ST() });
      return batch.commit();
    });
    const progress = await readAdmin('route_plan_progress/planA_sal1');
    s.noteControl('recorded progress stays after the replace', 'assigned', progress && progress.status);
    const salesDb = db('sal1');
    await s.control('a salesperson cannot take over the key', DENY, () => {
      const batch = writeBatch(salesDb);
      batch.update(doc(salesDb, 'route_plan_publication_keys', keyId), { planId: 'planB', updatedByUid: 'sal1', updatedAt: ST(), active: true });
      return batch.commit();
    });
    await s.probe('corrected route B publishes for the same week after A was replaced', ALLOW, publishB);
    const key = await readAdmin('route_plan_publication_keys/' + keyId);
    s.noteControl('the key now belongs to B and is active', 'planB:true', `${key.planId}:${key.active}`);
    await s.control('a second route for that week is refused while B is published', DENY, async () => {
      await seed([['route_plans/planC', routePlan('planC', { weekStart, status: 'approved' })]]);
      const batch = writeBatch(admin);
      batch.update(doc(admin, 'route_plans', 'planC'), { status: 'published', publicationKeyId: keyId, updatedAt: ST(), publishedAt: ST() });
      batch.set(doc(admin, 'route_plan_publication_keys', keyId), keyFor('planC'), { merge: true });
      return batch.commit();
    });
    s.finish();
  });

  it('C10 FIX-069 retailer reads stay inside the reader\'s own branch, admins read all', async () => {
    const s = stepper('C10-retailers');
    await seed([
      ['retailers/ret-b1', { retailerId: 'ret-b1', retailerName: 'B1 Mart', assignedSalesmanId: 'S001', branchId: 'B1', contactPhone: '000' }],
      ['retailers/ret-b2', { retailerId: 'ret-b2', retailerName: 'B2 Mart', assignedSalesmanId: 'S003', branchId: 'B2', contactPhone: '000' }],
    ]);
    await s.control('anonymous refused', DENY, () => getDoc(doc(anon(), 'retailers', 'ret-b1')));
    await s.control('suspended person refused', DENY, () => getDoc(doc(db('susp'), 'retailers', 'ret-b1')));
    await s.control('signed-in uid with no profile refused', DENY, () => getDoc(doc(db('nobody'), 'retailers', 'ret-b1')));
    await s.control('salesperson reads own retailer', ALLOW, () => getDoc(doc(db('sal1'), 'retailers', 'ret-b1')));
    await s.control('salesperson refused a retailer of another branch', DENY, () => getDoc(doc(db('sal1'), 'retailers', 'ret-b2')));
    await s.control('supervisor refused a retailer of another branch', DENY, () => getDoc(doc(db('sup1'), 'retailers', 'ret-b2')));
    await s.control('branch manager refused a retailer of another branch', DENY, () => getDoc(doc(db('mgr1'), 'retailers', 'ret-b2')));
    await s.control('branch manager reads a retailer of own branch', ALLOW, () => getDoc(doc(db('mgr1'), 'retailers', 'ret-b1')));
    await s.control('supervisor reads a retailer of own branch', ALLOW, () => getDoc(doc(db('sup1'), 'retailers', 'ret-b1')));
    await s.control('admin reads a retailer of every branch', ALLOW, () => getDoc(doc(db('adm'), 'retailers', 'ret-b2')));
    for (const who of ['sal1', 'sup1', 'mgr1']) {
      await s.control(who+': list filtered on own branch', ALLOW, () => getDocs(query(collection(db(who), 'retailers'), where('branchId', '==', 'B1'))));
      await s.control(who+': list filtered on another branch', DENY, () => getDocs(query(collection(db(who), 'retailers'), where('branchId', '==', 'B2'))));
      await s.control(who+': list with no filter', DENY, () => getDocs(collection(db(who), 'retailers')));
    }
    await s.control('admin list with no filter', ALLOW, () => getDocs(collection(db('adm'), 'retailers')));
    await s.control('phone 1.0.2 planner query on the assigned code', ALLOW, () => getDocs(query(collection(db('sal1'), 'retailers'), where('assignedSalesmanId', '==', 'S001'), limit(1000))));
    await s.control('phone 1.0.2 planner query on the assigned uid', ALLOW, () => getDocs(query(collection(db('sal1'), 'retailers'), where('assignedSalesmanId', '==', 'sal1'), limit(1000))));
    await s.control('phone query on another person\'s code', DENY, () => getDocs(query(collection(db('sal1'), 'retailers'), where('assignedSalesmanId', '==', 'S003'), limit(1000))));
    s.finish();
  });
  it('C10 FIX-226 a branch manager cannot read an admin profile of the same branch', async () => {
    const s = stepper('FIX-226-admin-profile');
    await s.control('branch manager refused an admin of the same branch', DENY, () => getDoc(doc(db('mgr1'), 'users', 'admB1')));
    await s.control('branch manager reads a salesperson of the same branch', ALLOW, () => getDoc(doc(db('mgr1'), 'users', 'sal1')));
    await s.control('admin reads the admin profile', ALLOW, () => getDoc(doc(db('adm'), 'users', 'admB1')));
    await s.control('admin reads own profile', ALLOW, () => getDoc(doc(db('admB1'), 'users', 'admB1')));
    await s.control('branch manager of another branch refused a salesperson of B1', DENY, () => getDoc(doc(db('mgr2'), 'users', 'sal1')));
    await s.control('branch manager list of the branch without a role filter refused (would include the admin)', DENY, () => getDocs(query(collection(db('mgr1'), 'users'), where('branchId', '==', 'B1'))));
    await s.control('branch manager list of the branch salespeople allowed', ALLOW, () => getDocs(query(collection(db('mgr1'), 'users'), where('branchId', '==', 'B1'), where('role', '==', 'salesman'))));
    await s.control('branch manager list of the branch admins refused', DENY, () => getDocs(query(collection(db('mgr1'), 'users'), where('branchId', '==', 'B1'), where('role', '==', 'admin'))));
    await seed([['users/salLegacy', { uid: 'salLegacy', userDocId: 'salLegacy', role: 'Salesman', branchId: 'B1', employeeCode: 'S008', status: 'active', isActive: true }]]);
    const staffSpellings = ['salesman', 'Salesman', 'SALESMAN', 'sales_representative', 'sales representative', 'Sales Representative',
      'supervisor', 'Supervisor', 'SUPERVISOR', 'branch_manager', 'branch manager', 'Branch Manager', 'Branch_Manager', 'BRANCH_MANAGER'];
    await s.control('branch manager people list as the dashboard asks includes a legacy "Salesman" spelling', ALLOW, async () => {
      const snap = await getDocs(query(collection(db('mgr1'), 'users'), where('branchId', '==', 'B1'), where('role', 'in', staffSpellings)));
      assert.ok(snap.docs.some((d) => d.id === 'salLegacy'), 'legacy Salesman profile missing from the list');
      assert.ok(!snap.docs.some((d) => d.id === 'admB1'), 'admin profile leaked into the list');
      return snap;
    });
    await s.control('branch manager list that adds admin to the spellings refused', DENY, () => getDocs(query(collection(db('mgr1'), 'users'), where('branchId', '==', 'B1'), where('role', 'in', [...staffSpellings, 'Admin']))));
    s.finish();
  });

  it('FIX-225 a direct retailer update cannot set a location verified without the review stamp', async () => {
    const s = stepper('FIX-225-verified-stamp');
    await seed([['retailers/ret-cand', { retailerId: 'ret-cand', retailerName: 'Cand', branchId: 'B1', latitude: 1.5, longitude: 110.3, coordinateStatus: 'candidate' }]]);
    const admin = db('adm');
    await s.control('verified with no stamp refused', DENY, () => updateDoc(doc(admin, 'retailers', 'ret-cand'), { coordinateStatus: 'verified' }));
    await s.control('verified with a stamp from another reviewer refused', DENY, () => updateDoc(doc(admin, 'retailers', 'ret-cand'), {
      coordinateStatus: 'verified', coordinateSource: 'admin_review', coordinateReviewStatus: 'reviewed', coordinateReviewedByUid: 'admB1', coordinateReviewedAt: ST(),
    }));
    await s.control('candidate edit of the coordinate allowed', ALLOW, () => updateDoc(doc(admin, 'retailers', 'ret-cand'), { latitude: 1.6, coordinateStatus: 'candidate' }));
    await s.control('verified with the reviewer stamp allowed', ALLOW, () => updateDoc(doc(admin, 'retailers', 'ret-cand'), {
      coordinateStatus: 'verified', coordinateSource: 'admin_review', coordinateReviewStatus: 'reviewed', coordinateReviewedByUid: 'adm', coordinateReviewedAt: ST(),
    }));
    await s.control('other field of a verified retailer allowed', ALLOW, () => updateDoc(doc(admin, 'retailers', 'ret-cand'), { retailerName: 'Cand 2' }));
    s.finish();
  });

  it('FIX-256 a personally suspended person cannot read own action state, preferences or live tracking', async () => {
    const s = stepper('FIX-256-suspended-own-reads');
    await seed([
      ['action_centre_user_status/susp_a1', { uid: 'susp', actionId: 'a1', status: 'done' }],
      ['action_centre_user_status/sal4_a1', { uid: 'sal4', actionId: 'a1', status: 'done' }],
      ['dashboard_preferences/susp', { theme: 'x' }], ['dashboard_preferences/sal4', { theme: 'x' }],
      ['live_tracking/susp', { uid: 'susp', salesmanUid: 'susp', salesmanCode: 'S009', branchId: 'B1' }],
      ['live_tracking/sal4', { uid: 'sal4', salesmanUid: 'sal4', salesmanCode: 'S004', branchId: 'B1' }],
    ]);
    for (const [path, who, id] of [['action_centre_user_status', 'susp', 'susp_a1'], ['dashboard_preferences', 'susp', 'susp'], ['live_tracking', 'susp', 'susp']]) {
      await s.control(`suspended person reads own ${path}`, DENY, () => getDoc(doc(db(who), path, id)));
    }
    await s.control('suspended person lists own action state', DENY, () => getDocs(query(collection(db('susp'), 'action_centre_user_status'), where('uid', '==', 'susp'))));
    for (const [path, id] of [['action_centre_user_status', 'sal4_a1'], ['dashboard_preferences', 'sal4'], ['live_tracking', 'sal4']]) {
      await s.control(`active person reads own ${path}`, ALLOW, () => getDoc(doc(db('sal4'), path, id)));
    }
    await s.control('active person lists own action state', ALLOW, () => getDocs(query(collection(db('sal4'), 'action_centre_user_status'), where('uid', '==', 'sal4'))));
    s.finish();
  });

  it('FIX-258 a colleague cannot create an order whose id is built from another person\'s uid', async () => {
    const s = stepper('FIX-258-order-id-owner');
    const victimId = 'ORD-V2-sal4.planX.stop-1';
    await s.control('personal order with the victim id refused', DENY, () => setDoc(doc(db('sal1'), 'orders', victimId), orderFor('sal1', 'S001', 'B1', victimId)));
    const ownId = 'ORD-P1-0123456789abcdef0123456789abcdef';
    await s.control('personal order with the normal id allowed', ALLOW, () => setDoc(doc(db('sal1'), 'orders', ownId), orderFor('sal1', 'S001', 'B1', ownId)));
    s.finish();
  });

  it('FIX-071 an empty team code gives a supervisor no sight of routes that have no salesperson code', async () => {
    const s = stepper('FIX-071-empty-team-code');
    await seed([
      ['route_plans/planNoCode', routePlan('planNoCode', { salesmanUid: '', salesmanCode: '' })],
      ['route_plans/planS1', routePlan('planS1')],
    ]);
    await s.control('supervisor with an empty team code refused a route with no code', DENY, () => getDoc(doc(db('supEmpty'), 'route_plans', 'planNoCode')));
    await s.control('same supervisor reads the route of a listed code', ALLOW, () => getDoc(doc(db('supEmpty'), 'route_plans', 'planS1')));
    await s.control('admin reads the route with no code', ALLOW, () => getDoc(doc(db('adm'), 'route_plans', 'planNoCode')));
    s.finish();
  });

  it('FIX-071 an archived route plan cannot be edited again', async () => {
    const s = stepper('FIX-071-archived-route');
    await seed([['route_plans/planArch', routePlan('planArch', { status: 'archived', replacedAt: new Date('2026-11-02T00:00:00Z') })]]);
    await s.control('admin changes the stops of an archived route', DENY, () => updateDoc(doc(db('adm'), 'route_plans', 'planArch'), { stopIds: ['x'], totalStops: 1, updatedAt: ST() }));
    await s.control('admin touches only updatedAt on an archived route', ALLOW, () => updateDoc(doc(db('adm'), 'route_plans', 'planArch'), { updatedAt: ST() }));
    s.finish();
  });

  it('FIX-071 one commercial line element cannot hold several lines', async () => {
    const s = stepper('FIX-071-commercial-lines');
    const token = (id) => `${id}~${name64('Juice')}~1~1000`;
    const merged = `${token('p1')}${token('p2')}`;
    const idA = 'ORD-P1-aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
    const idB = 'ORD-P1-bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';
    await s.control('one element holding two lines refused', DENY, () => setDoc(doc(db('sal1'), 'orders', idA), orderFor('sal1', 'S001', 'B1', idA, { commercialLines: [merged], totalPrice: 20 })));
    await s.control('one normal line allowed', ALLOW, () => setDoc(doc(db('sal1'), 'orders', idB), orderFor('sal1', 'S001', 'B1', idB)));
    s.finish();
  });

  it('FIX-071 a product price change must carry the price stamp', async () => {
    const s = stepper('FIX-071-price-stamp');
    await seed([['products/pStamp', { productId: 'pStamp', productName: 'Stamp', unitPrice: 10, updatedAt: new Date('2026-01-01T00:00:00Z') }]]);
    await s.control('price changed with no stamp refused', DENY, () => updateDoc(doc(db('adm'), 'products', 'pStamp'), { unitPrice: 20, updatedAt: ST() }));
    await s.control('price changed with the stamp allowed', ALLOW, () => updateDoc(doc(db('adm'), 'products', 'pStamp'), { unitPrice: 20, updatedAt: ST(), priceUpdatedAt: ST() }));
    await s.control('name changed with no stamp allowed', ALLOW, () => updateDoc(doc(db('adm'), 'products', 'pStamp'), { productName: 'Stamp 2', updatedAt: ST() }));
    s.finish();
  });

  it('FIX-071 visits and dashboard preferences have a field count bound', async () => {
    const s = stepper('FIX-071-field-bounds');
    const wide = (count) => Object.fromEntries(Array.from({ length: count }, (_, i) => [`extra${i}`, 'x']));
    const visit = (extra) => ({ ownerUid: 'sal4', salesmanCode: 'S004', branchId: 'B1', date: '2026-11-10', createdAt: ST(), updatedAt: ST(), ...extra });
    await s.control('visit with 70 extra fields refused', DENY, () => setDoc(doc(db('sal4'), 'visits', 'v-wide'), visit(wide(70))));
    await s.control('normal visit allowed', ALLOW, () => setDoc(doc(db('sal4'), 'visits', 'v-ok'), visit({})));
    await s.control('preferences with 70 fields refused', DENY, () => setDoc(doc(db('sal4'), 'dashboard_preferences', 'sal4'), wide(70)));
    await s.control('normal preferences allowed', ALLOW, () => setDoc(doc(db('sal4'), 'dashboard_preferences', 'sal4'), { theme: 'x', updatedAt: ST() }));
    s.finish();
  });

  it('FIX-075 triage status accepts only the four known words and a short note', async () => {
    const s = stepper('FIX-075-triage-words');
    const status = (value, extra = {}) => ({ uid: 'sal4', actionId: 'x1', status: value, updatedAt: ST(), ...extra });
    await s.control('unknown word refused', DENY, () => setDoc(doc(db('sal4'), 'action_centre_user_status', 'sal4_x1'), status('bogus')));
    await s.control('note of 2000 characters refused', DENY, () => setDoc(doc(db('sal4'), 'action_centre_user_status', 'sal4_x1'), status('resolved', { note: 'n'.repeat(2000) })));
    await s.control('in_review allowed', ALLOW, () => setDoc(doc(db('sal4'), 'action_centre_user_status', 'sal4_x1'), status('in_review')));
    await s.control('update to resolved with a note allowed', ALLOW, () => updateDoc(doc(db('sal4'), 'action_centre_user_status', 'sal4_x1'), { status: 'resolved', note: 'done', updatedAt: ST() }));
    await s.control('update to an unknown word refused', DENY, () => updateDoc(doc(db('sal4'), 'action_centre_user_status', 'sal4_x1'), { status: 'bogus', updatedAt: ST() }));
    s.finish();
  });

  it('FIX-072 the permission matrix audit summary may be long, other audit summaries may not', async () => {
    const s = stepper('FIX-072-audit-summary');
    const audit = (action, summary) => ({ action, entityType: 'system_access_config', entityId: 'permission_matrix', summary, actorUid: 'adm', actorEmail: '', actorName: 'A', actorRole: 'admin', metadata: {}, createdAt: ST() });
    const longSummary = `Updated role permissions. Granted: ${'branch_manager.retailers.update, '.repeat(150)}`;
    await s.control('long summary on a permission matrix audit allowed', ALLOW, () => setDoc(doc(db('adm'), 'system_audit_logs', 'perm-audit-long-0001'), audit('permission_matrix_updated', longSummary)));
    await s.control('same summary on another action refused', DENY, () => setDoc(doc(db('adm'), 'system_audit_logs', 'other-audit-long-0001'), audit('product_updated', longSummary)));
    s.finish();
  });

  async function listIds(label, s, expected, target, expectedIds) {
    let ids = null;
    await s.control(label, expected, async () => {
      ids = (await getDocs(target)).docs.map((entry) => entry.id).sort();
    });
    if (expected === ALLOW) s.noteControl(`${label}: rows`, expectedIds.join(','), (ids || []).join(','));
  }

  it('C10 order reads by code work as on the base rules, including real rows that have no salesmanUid', async () => {
    const s = stepper('C10-orders-by-code');
    const stored = (id, fields) => ({ ...storedOrder('sal1', 'S001', 'B1', id), ...fields });
    const withoutUidFields = (id, fields = {}) => {
      const { uid: _uid, userUid: _userUid, salesmanUid: _salesmanUid, submittedByUid: _submittedByUid, createdByUid: _createdByUid, ...rest } = stored(id, fields);
      return rest;
    };
    const snakeOnly = (id) => {
      const { salesmanCode: _salesmanCode, ...rest } = withoutUidFields(id);
      return { ...rest, salesman_code: 'S001' };
    };
    await seed([
      ['orders/prior', stored('prior', { uid: 'gone', userUid: 'gone', salesmanUid: 'gone', submittedByUid: 'gone', createdByUid: 'gone' })],
      ['orders/own', stored('own', { uid: 'reused', userUid: 'reused', salesmanUid: 'reused', submittedByUid: 'reused', createdByUid: 'reused' })],
      ['orders/emptyUid', stored('emptyUid', { uid: '', userUid: '', salesmanUid: '', submittedByUid: '', createdByUid: '' })],
      ['orders/adminMade', stored('adminMade', { uid: '', userUid: '', salesmanUid: '', submittedByUid: '', createdByUid: 'adm' })],
      ['orders/noUidFields', withoutUidFields('noUidFields')],
      ['orders/noUidFieldsAdminMade', withoutUidFields('noUidFieldsAdminMade', { createdByUid: 'adm' })],
      ['orders/noUidSnake', snakeOnly('noUidSnake')],
      ['orders/susOwn', storedOrder('susp', 'S009', 'B1', 'susOwn')],
      ['user_access/reused', row('reused', { role: 'salesman', employeeCode: 'S001' })],
    ]);
    const person = db('reused');
    const code = (field) => query(collection(person, 'orders'), where(field, '==', 'S001'), orderBy('submittedAt', 'desc'), limit(20));
    const withCode = ['adminMade', 'emptyUid', 'noUidFields', 'noUidFieldsAdminMade', 'own', 'prior'];
    await listIds('Order History query on salesmanCode shows every order with the code, old shape included', s, ALLOW, code('salesmanCode'), withCode);
    await listIds('Order History query on salesman_code shows the snake case row', s, ALLOW, code('salesman_code'), ['noUidSnake']);
    await listIds('bare query on salesmanCode', s, ALLOW, query(collection(person, 'orders'), where('salesmanCode', '==', 'S001')), withCode);
    await listIds('uid query returns the person\'s own orders', s, ALLOW, query(collection(person, 'orders'), where('salesmanUid', '==', 'reused')), ['own']);
    await s.control('order with empty uid fields is readable by get', ALLOW, () => getDoc(doc(person, 'orders', 'emptyUid')));
    await s.control('order made by an admin for the code holder is readable by get', ALLOW, () => getDoc(doc(person, 'orders', 'adminMade')));
    await s.control('order with no uid fields at all is readable by get', ALLOW, () => getDoc(doc(person, 'orders', 'noUidFields')));
    await s.control('order with no uid fields and an admin creator is readable by get', ALLOW, () => getDoc(doc(person, 'orders', 'noUidFieldsAdminMade')));
    await s.control('snake case order with no uid fields is readable by get', ALLOW, () => getDoc(doc(person, 'orders', 'noUidSnake')));
    await s.probe('get of the order of the earlier holder of the code agrees with the list that shows it', ALLOW, () => getDoc(doc(person, 'orders', 'prior')));
    await s.control('another code is not readable', DENY, () => getDoc(doc(db('sal2'), 'orders', 'prior')));
    await s.control('query on another person\'s code is refused', DENY, () => getDocs(query(collection(person, 'orders'), where('salesmanCode', '==', 'S002'))));
    await s.control('query with no filter is refused', DENY, () => getDocs(query(collection(person, 'orders'), limit(5))));
    await s.control('suspended person reads own order by id', DENY, () => getDoc(doc(db('susp'), 'orders', 'susOwn')));
    await s.control('suspended person lists own orders', DENY, () => getDocs(query(collection(db('susp'), 'orders'), where('salesmanUid', '==', 'susp'))));
    await s.control('uid with no profile lists orders that name that uid', DENY, () => getDocs(query(collection(db('ghost'), 'orders'), where('salesmanUid', '==', 'ghost'))));
    await s.control('supervisor of the code still lists by code', ALLOW, () => getDocs(query(collection(db('sup1'), 'orders'), where('salesmanCode', '==', 'S001'))));
    s.finish();
  });

  it('C10 a person whose company is lapsed still reads own rows, a personally suspended person does not', async () => {
    const s = stepper('C10-own-rows-by-reason');
    const reasons = {
      lapsed: ['billing_lapse'], trial: ['trial_expired'], cancelled: ['cancelled'], readonly: ['lifecycle_readonly'], both: ['billing_lapse', 'cancelled'],
      adminsusp: ['admin_suspension'], mixed: ['billing_lapse', 'admin_suspension'], deleting: ['deletion_requested'],
    };
    const entries = [];
    for (const [uid, disabledReasons] of Object.entries(reasons)) {
      const code = `R-${uid}`;
      entries.push([`user_access/${uid}`, row(uid, { role: 'salesman', employeeCode: code, disabledReasons })]);
      entries.push([`orders/o-${uid}`, storedOrder(uid, code, 'B1', `o-${uid}`)]);
    }
    entries.push(['user_access/legacyLapsed', { uid: 'legacyLapsed', status: 'active', isActive: true, role: 'salesman', branchId: 'B1', employeeCode: 'R-legacy', disabledReasons: ['billing_lapse'] }]);
    entries.push(['orders/o-legacyLapsed', storedOrder('legacyLapsed', 'R-legacy', 'B1', 'o-legacyLapsed')]);
    await seed(entries);
    for (const uid of ['lapsed', 'trial', 'cancelled', 'readonly', 'both', 'legacyLapsed']) {
      await s.control(`${uid}: get of own delivered order, as the phone's held-work check does`, ALLOW, () => getDoc(doc(db(uid), 'orders', `o-${uid}`)));
      await s.control(`${uid}: list of own orders by uid`, ALLOW, () => getDocs(query(collection(db(uid), 'orders'), where('salesmanUid', '==', uid))));
    }
    for (const uid of ['adminsusp', 'mixed', 'deleting']) {
      await s.control(`${uid}: get of own order`, DENY, () => getDoc(doc(db(uid), 'orders', `o-${uid}`)));
      await s.control(`${uid}: list of own orders by uid`, DENY, () => getDocs(query(collection(db(uid), 'orders'), where('salesmanUid', '==', uid))));
    }
    s.finish();
  });

  it('C10 other own-record collections apply the same active and owner checks', async () => {
    const s = stepper('C10-same-fault');
    const outcome = (id, uid, code) => [`conversation_outcomes/${id}`, { outcomeId: id, salesmanUid: uid, salesmanCode: code, branchId: 'B1', retailerId: 'r1', submittedAt: new Date('2026-10-01T00:00:00Z') }];
    const brief = (id, uid, code) => [`visit_briefs/${id}`, { briefId: id, salesmanUid: uid, salesmanCode: code, branchId: 'B1', retailerId: 'r1' }];
    const stamp = new Date('2026-10-01T00:00:00Z');
    const request = (id, uid, code) => [`special_requests/${id}`, {
      retailerName: 'R', requestedItem: 'Cable', reason: 'x', salesmanCode: code, branchId: 'B1', createdByUid: uid, createdByRole: 'salesman', createdAt: stamp,
      updatedAt: stamp, status: 'pending_supervisor', approvalStep: 'Supervisor', lastActorUid: uid, lastActorRole: 'salesman', lastActionAt: stamp,
    }];
    await seed([
      outcome('o-old', 'gone', 'S001'), outcome('o-own', 'sal1', 'S001'), outcome('o-susp', 'susp', 'S009'),
      brief('b-old', 'gone', 'S001'), brief('b-own', 'sal1', 'S001'), brief('b-susp', 'susp', 'S009'),
      request('sr-old', 'gone', 'S001'), request('sr-own', 'sal1', 'S001'),
      ['user_access/reused', row('reused', { role: 'salesman', employeeCode: 'S001' })],
      ['user_access/lapsedOwner', row('lapsedOwner', { role: 'salesman', employeeCode: 'S055', disabledReasons: ['billing_lapse'] })],
      outcome('o-own-lapsed', 'lapsedOwner', 'S055'), brief('b-own-lapsed', 'lapsedOwner', 'S055'),
    ]);
    const reused = db('reused');
    for (const [name, oldId, ownId, suspId] of [['conversation_outcomes', 'o-old', 'o-own', 'o-susp'], ['visit_briefs', 'b-old', 'b-own', 'b-susp']]) {
      await s.control(`${name}: owner reads own`, ALLOW, () => getDoc(doc(db('sal1'), name, ownId)));
      await s.control(`${name}: reused code reads the old holder's row`, DENY, () => getDoc(doc(reused, name, oldId)));
      await s.control(`${name}: reused code lists by code`, DENY, () => getDocs(query(collection(reused, name), where('salesmanCode', '==', 'S001'))));
      await s.control(`${name}: suspended person reads own row`, DENY, () => getDoc(doc(db('susp'), name, suspId)));
      await s.control(`${name}: suspended person lists by uid`, DENY, () => getDocs(query(collection(db('susp'), name), where('salesmanUid', '==', 'susp'))));
      await s.control(`${name}: phone query by uid for the owner`, ALLOW, () => getDocs(query(collection(db('sal1'), name), where('salesmanUid', '==', 'sal1'))));
      await s.control(`${name}: supervisor of the code reads`, ALLOW, () => getDoc(doc(db('sup1'), name, ownId)));
      await s.control(`${name}: person whose company is lapsed reads own row`, ALLOW, () => getDoc(doc(db('lapsedOwner'), name, `${ownId}-lapsed`)));
    }
    await s.control('special_requests: creator reads own', ALLOW, () => getDoc(doc(db('sal1'), 'special_requests', 'sr-own')));
    await s.control('special_requests: reused code reads the old holder\'s request', DENY, () => getDoc(doc(reused, 'special_requests', 'sr-old')));
    await s.control('special_requests: 1.0.2 status query on the code alone', DENY, () => getDocs(query(collection(reused, 'special_requests'), where('salesmanCode', '==', 'S001'))));
    await s.control('special_requests: new status query on code and creator', ALLOW, () => getDocs(query(collection(reused, 'special_requests'), where('salesmanCode', '==', 'S001'), where('createdByUid', '==', 'reused'))));
    await s.control('special_requests: creator\'s new status query', ALLOW, () => getDocs(query(collection(db('sal1'), 'special_requests'), where('salesmanCode', '==', 'S001'), where('createdByUid', '==', 'sal1'))));
    await s.control('special_requests: supervisor of the code reads', ALLOW, () => getDoc(doc(db('sup1'), 'special_requests', 'sr-old')));
    s.finish();
  });

  it('C11 the updated phone\'s reads and writes pass on the base rules and on these rules', async () => {
    const baseRules = fs.readFileSync(path.join(__dirname, 'fixtures', 'phone_1_0_2_base.firestore.rules'), 'utf8');
    const baseEnv = await initializeTestEnvironment({ projectId: `${PROJECT}-base`, firestore: { rules: baseRules } });
    const s = stepper('C11-phone-both-rules');
    const fresh = () => ({ email: 'phone@example.test', auth_time: Math.floor(Date.now() / 1000) - 60 });
    try {
      for (const [label, environment] of [['base rules', baseEnv], ['these rules', env]]) {
        await environment.clearFirestore();
        await environment.withSecurityRulesDisabled(async (context) => {
          const admin = context.firestore();
          for (const [uid, data] of Object.entries(ACTORS)) {
            await setDoc(doc(admin, 'user_access', uid), data);
            await setDoc(doc(admin, 'users', uid), data);
          }
          await setDoc(doc(admin, 'orders', 'own'), storedOrder('sal1', 'S001', 'B1', 'own'));
          await setDoc(doc(admin, 'orders', 'ownerless'), { ...storedOrder('sal1', 'S001', 'B1', 'ownerless'), uid: '', userUid: '', salesmanUid: '', submittedByUid: '', createdByUid: '' });
          const { uid: _u0, userUid: _u1, salesmanUid: _u2, submittedByUid: _u3, createdByUid: _u4, ...noUidFields } = storedOrder('sal1', 'S001', 'B1', 'noUidFields');
          await setDoc(doc(admin, 'orders', 'noUidFields'), noUidFields);
          await setDoc(doc(admin, 'user_access', 'lapsedPhone'), row('lapsedPhone', { role: 'salesman', employeeCode: 'S030', disabledReasons: ['billing_lapse'] }));
          await setDoc(doc(admin, 'orders', 'lapsedOrder'), storedOrder('lapsedPhone', 'S030', 'B1', 'lapsedOrder'));
          await setDoc(doc(admin, 'special_requests', 'sr'), {
            retailerName: 'R', requestedItem: 'Cable', reason: 'x', salesmanCode: 'S001', branchId: 'B1', createdByUid: 'sal1', createdByRole: 'salesman',
            status: 'pending_supervisor', approvalStep: 'Supervisor', lastActorUid: 'sal1', lastActorRole: 'salesman', createdAt: new Date(), updatedAt: new Date(), lastActionAt: new Date(),
          });
        });
        const phone = (uid, token) => environment.authenticatedContext(uid, token).firestore();
        const sal = phone('sal1');
        await s.control(`${label}: Order History uid query`, ALLOW, () => getDocs(query(collection(sal, 'orders'), where('salesmanUid', '==', 'sal1'), orderBy('submittedAt', 'desc'), limit(20))));
        await s.control(`${label}: Order History code query, which 1.0.2 and the updated phone both send`, ALLOW, () => getDocs(query(collection(sal, 'orders'), where('salesmanCode', '==', 'S001'), orderBy('submittedAt', 'desc'), limit(20))));
        await s.control(`${label}: Order History code query returns the old-shape order with no salesmanUid`, ALLOW, async () => {
          const rows = (await getDocs(query(collection(sal, 'orders'), where('salesmanCode', '==', 'S001'), orderBy('submittedAt', 'desc'), limit(20)))).docs.map((entry) => entry.id).sort();
          if (!rows.includes('ownerless') || !rows.includes('noUidFields')) throw new Error(`old-shape orders missing: ${rows}`);
        });
        await s.control(`${label}: held-work check reads an own delivered order while the company is lapsed`, ALLOW, () => getDoc(doc(phone('lapsedPhone'), 'orders', 'lapsedOrder')));
        await s.control(`${label}: updated phone reports a lock`, ALLOW, () => clientReport(environment.unauthenticatedContext().firestore(), `updated.${label.replace(/ /g, '.')}@nowhere.invalid`, lockId()));
        await s.control(`${label}: 1.0.2 phone reports a lock`, ALLOW, () => lockBatch(environment.unauthenticatedContext().firestore(), `old.${label.replace(/ /g, '.')}@nowhere.invalid`, lockId(), 'mobile', 'limit'));
        await s.control(`${label}: special request status query on code and creator`, ALLOW, () => getDocs(query(collection(sal, 'special_requests'), where('salesmanCode', '==', 'S001'), where('createdByUid', '==', 'sal1'))));
        await s.control(`${label}: planned visit of a person with no code, no code sent`, ALLOW, () => setDoc(doc(phone('nocode'), 'visits', 'v-nocode'), visit('nocode')));
        await s.control(`${label}: planned visit with code and branch`, ALLOW, () => setDoc(doc(sal, 'visits', 'v-sal'), visit('sal1', { salesmanCode: 'S001', branchId: 'B1' })));
        await s.control(`${label}: deletion request with a fresh sign-in`, ALLOW, () => setDoc(doc(phone('sal4', fresh()), 'privacy_deletion_requests', 'sal4'), { requestType: 'account_deletion', status: 'submitted', createdAt: ST() }));
      }
    } finally {
      await baseEnv.cleanup();
    }
    s.finish();
  });

  const publishWeek = () => {
    const weekStart = Timestamp.fromMillis(Date.now() + 7 * 86400000);
    const local = new Date(weekStart.toMillis() + 8 * 3600000);
    const weekKey = `${local.getUTCFullYear()}${String(local.getUTCMonth() + 1).padStart(2, '0')}${String(local.getUTCDate()).padStart(2, '0')}`;
    return { weekStart, weekKey };
  };

  it('FIX-279 two routes for one salesperson and week through the uid key and the code key', async () => {
    const s = stepper('FIX-279-two-keys');
    const { weekStart, weekKey } = publishWeek();
    await seed([
      ['route_plans/planUid', routePlan('planUid', { weekStart, status: 'approved' })],
      ['route_plans/planCode', routePlan('planCode', { weekStart, status: 'approved', salesmanUid: '' })],
    ]);
    const supervisor = db('sup1');
    const publish = (planId, identity, uid) => {
      const keyId = `${identity}_${weekKey}`;
      const batch = writeBatch(supervisor);
      batch.update(doc(supervisor, 'route_plans', planId), { status: 'published', publicationKeyId: keyId, updatedAt: ST(), publishedAt: ST() });
      batch.set(doc(supervisor, 'route_plan_publication_keys', keyId), {
        keyId, planId, salesmanIdentity: identity, salesmanUid: uid, salesmanCode: 'S001', weekKey, weekStart, active: true, updatedByUid: 'sup1', updatedAt: ST(),
      });
      return batch.commit();
    };
    await s.control('supervisor publishes the route that names the uid', ALLOW, () => publish('planUid', 'sal1', 'sal1'));
    await s.info('supervisor also publishes a route with the same code and no uid', DENY, () => publish('planCode', 'S001', ''));
    s.finish();
  });

  it('FIX-280 the planId field of a route must be its own document id', async () => {
    const s = stepper('FIX-280-planid-field');
    const admin = db('adm');
    const draft = (planId) => routePlan(planId, { status: 'draft' });
    await s.control('admin creates a draft whose planId field is its own id', ALLOW, () => setDoc(doc(admin, 'route_plans', 'planOk'), draft('planOk')));
    await s.control('admin creates a draft whose planId field is another route id', DENY, () => setDoc(doc(admin, 'route_plans', 'planA'), draft('planB')));
    await s.control('admin edits a draft to point its planId field at another route', DENY, () => updateDoc(doc(admin, 'route_plans', 'planOk'), { planId: 'planB', updatedAt: ST() }));
    s.finish();
  });

  it('SEC-01 a signed-in account with no company profile cannot save preferences or action state, with the company open or closed', async () => {
    const s = stepper('SEC-01-no-profile-writes');
    const actionState = (uid, actionId) => ({ uid, actionId, status: 'resolved', updatedAt: ST() });
    const legacyProfile = (uid, extra = {}) => ({ uid, role: 'admin', status: 'active', isActive: true, ...extra });
    const stored = (uid) => [
      [`dashboard_preferences/${uid}`, { theme: 'old' }],
      [`action_centre_user_status/${uid}_old`, { uid, actionId: 'old', status: 'new' }],
    ];
    await seed([
      ['users/legacyOnly', legacyProfile('legacyOnly')],
      ['users/legacyLapsed', legacyProfile('legacyLapsed', { disabledReasons: ['billing_lapse'] })],
      ...stored('ghostStored'), ...stored('sal4'), ...stored('legacyOnly'), ...stored('legacyLapsed'),
    ]);
    const writes = (uid, storedUid = uid) => [
      ['creates preferences', () => setDoc(doc(db(uid), 'dashboard_preferences', uid), { theme: 'x' })],
      ['updates preferences', () => updateDoc(doc(db(storedUid), 'dashboard_preferences', storedUid), { theme: 'y' })],
      ['creates action state', () => setDoc(doc(db(uid), 'action_centre_user_status', `${uid}_a1`), actionState(uid, 'a1'))],
      ['updates action state', () => updateDoc(doc(db(storedUid), 'action_centre_user_status', `${storedUid}_old`), { status: 'ignored', updatedAt: ST() })],
    ];
    for (const [label, op] of writes('ghost', 'ghostStored')) await s.control(`company open: account with no profile ${label}`, DENY, op);
    for (const [label, op] of writes('sal4')) await s.control(`company open: active member ${label}`, ALLOW, op);
    for (const [label, op] of writes('legacyOnly')) await s.control(`company open: old-style member with only a users profile ${label}`, ALLOW, op);
    for (const [label, op] of writes('legacyLapsed')) await s.control(`old-style member whose profile is blocked ${label}`, DENY, op);
    await seed(Object.entries(ACTORS).map(([uid, data]) => [`user_access/${uid}`, { ...data, disabledReasons: ['billing_lapse'] }]));
    await seed(stored('sal1'));
    for (const [label, op] of writes('ghost2', 'ghostStored')) await s.control(`company closed: account with no profile ${label}`, DENY, op);
    for (const [label, op] of writes('sal1')) await s.control(`company closed: member ${label}`, DENY, op);
    s.finish();
  });

  it('SEC2-01 a salesperson cannot write live or history location rows that name a colleague', async () => {
    const s = stepper('SEC2-01-tracking-owner');
    const session = 'a'.repeat(32);
    const point = { latitude: 1.5535, longitude: 110.3593, gpsLatitude: 1.5535, gpsLongitude: 110.3593, location: new GeoPoint(1.5535, 110.3593), accuracy: 12, accuracyMeters: 12, isMocked: false };
    const start = { activeSessionId: session, activeSessionGeneration: 1, lastFixSequence: 0, workSessionStatus: 'active', status: 'starting', workSessionStartedAt: ST(), trackingMode: 'battery_saver', appliedControlRevision: 0 };
    const identity = (uid, code, change = {}) => ({
      uid, userUid: uid, salesmanUid: uid, salesmanId: code, salesmanName: 'S', salesmanEmail: `${uid}@example.test`, submittedByUid: uid,
      submittedByEmail: `${uid}@example.test`, submittedByName: 'S', staffId: code, employeeCode: code, salesmanCode: code, salesman_code: code, branchId: 'B1', ...change,
    });
    const without = (data, key) => Object.fromEntries(Object.entries(data).filter(([name]) => name !== key));
    const startLive = async (uid, code, change) => {
      await env.withSecurityRulesDisabled((context) => deleteDoc(doc(context.firestore(), 'live_tracking', uid)));
      await setDoc(doc(db(uid), 'live_tracking', uid), { ...identity(uid, code, change), ...start });
    };
    const fix = (sequence, at) => ({
      activeSessionId: session, activeSessionGeneration: 1, lastFixSequence: sequence, workSessionStatus: 'active', status: 'active', trackingMode: 'battery_saver',
      appliedControlRevision: 0, ...point, deviceCapturedAt: at, locationSource: 'foreground_tracking', locationVerification: 'device_captured',
      timestamp: ST(), updatedAt: ST(), lastSeen: ST(), lastSyncedAt: ST(), serverReceivedAt: ST(),
    });
    let sequence = 0;
    const history = async (label, expected, shape) => {
      await new Promise((resolve) => setTimeout(resolve, 5));
      const at = Timestamp.fromMillis(Date.now());
      const next = sequence + 1;
      const eventId = `session_sal1_${session}_${next}`;
      let stored = false;
      await s.control(label, expected, async () => {
        const one = db('sal1');
        const batch = writeBatch(one);
        batch.set(doc(one, 'live_tracking', 'sal1'), fix(next, at), { merge: true });
        batch.set(doc(one, 'gps_tracking', eventId), shape({
          ...identity('sal1', 'S001'), eventId, activeSessionId: session, activeSessionGeneration: 1, fixSequence: next, ...point, deviceCapturedAt: at,
          locationSource: 'foreground_tracking', locationVerification: 'device_captured', timestamp: ST(), updatedAt: ST(),
        }));
        await batch.commit();
        stored = true;
      });
      if (stored) sequence = next;
    };

    await s.control('live row: every owner field is the caller', ALLOW, () => startLive('sal1', 'S001'));
    for (const key of ['salesmanUid', 'uid', 'userUid', 'submittedByUid']) {
      await s.control(`live row: ${key} names a colleague, the other owner fields are the caller`, DENY, () => startLive('sal4', 'S004', { [key]: 'sal2' }));
    }
    await s.control('live row: every owner field names a colleague', DENY, () => startLive('sal4', 'S004', { uid: 'sal2', userUid: 'sal2', salesmanUid: 'sal2', submittedByUid: 'sal2' }));
    await s.control('live row: the same person with every owner field the caller', ALLOW, () => startLive('sal4', 'S004'));

    await history('history row: every owner field is the caller', ALLOW, (data) => data);
    for (const key of ['salesmanUid', 'uid', 'userUid', 'submittedByUid', 'createdByUid', 'salesman_uid']) {
      await history(`history row: ${key} names a colleague, the other owner fields are the caller`, DENY, (data) => ({ ...data, [key]: 'sal2' }));
    }
    await history('history row: no salesmanUid, submitted_by_uid names a colleague', DENY, (data) => ({ ...without(data, 'salesmanUid'), submitted_by_uid: 'sal2' }));
    await history('history row: every owner field names a colleague', DENY, (data) => ({ ...data, uid: 'sal2', userUid: 'sal2', salesmanUid: 'sal2', submittedByUid: 'sal2' }));
    await history('history row: every owner field is the caller, after the refused rows', ALLOW, (data) => data);
    await s.control('live row update that changes salesmanUid to a colleague', DENY, () => setDoc(doc(db('sal1'), 'live_tracking', 'sal1'), { ...fix(sequence + 1, Timestamp.fromMillis(Date.now())), salesmanUid: 'sal2' }, { merge: true }));

    await seed([['orders/ORD-T1', storedOrder('sal1', 'S001', 'B1', 'ORD-T1')], ['orders/ORD-T2', storedOrder('sal1', 'S001', 'B1', 'ORD-T2')]]);
    const orderRow = (orderId, change = {}) => setDoc(doc(db('sal1'), 'gps_tracking', `order_${orderId}`), {
      ...identity('sal1', 'S001'), createdByUid: 'sal1', userDocId: 'sal1', ...point, deviceCapturedAt: Timestamp.fromMillis(Date.now()), locationVerification: 'device_captured',
      lastOrderId: orderId, timestamp: ST(), updatedAt: ST(), lastSeen: ST(), status: 'active', ...change,
    });
    await s.control('order location row: every owner field is the caller', ALLOW, () => orderRow('ORD-T1'));
    await s.control('order location row: salesmanUid names a colleague', DENY, () => orderRow('ORD-T2', { salesmanUid: 'sal2' }));

    await seed([['live_tracking/sal2', { userUid: 'sal2', salesmanUid: 'sal2', salesmanCode: 'S002', salesman_code: 'S002', branchId: 'B1', status: 'inactive' }]]);
    await s.control('a live row written before work sessions, with no uid field, still starts a session', ALLOW, () => setDoc(doc(db('sal2'), 'live_tracking', 'sal2'), start, { merge: true }));
    s.finish();
  });

});
