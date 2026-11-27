'use strict';

const path = require('node:path');

const PROJECT = process.env.E2E_PROJECT
  || (process.env.E2E_FIREBASE_TARGET === 'hardware' ? 'hardware-client-sales' : 'cos40005');
const PASSWORD = 'E2E-Local-Only-123!';
const OUTPUT_TAG = process.env.E2E_OUTPUT_TAG || '';
if (OUTPUT_TAG && !/^[a-z0-9][a-z0-9_-]{0,79}$/.test(OUTPUT_TAG)) {
  throw new Error('E2E_OUTPUT_TAG must be a single alphanumeric directory name');
}
const OUTPUT_DIR = path.resolve(require('./lane.cjs').outputRoot, OUTPUT_TAG);
const LOOPBACK = new Set(['127.0.0.1', 'localhost', '[::1]', '::1']);

function hostOf(value) {
  const text = String(value || '').trim();
  if (!text) return null;
  const at = text.lastIndexOf(':');
  return at > 0 && !text.endsWith(']') ? text.slice(0, at) : text;
}

function requireEmulators() {
  const firestore = process.env.FIRESTORE_EMULATOR_HOST;
  const auth = process.env.FIREBASE_AUTH_EMULATOR_HOST;
  if (!firestore || !auth) {
    throw new Error(
      'Refusing to run: FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST must be set. ' +
        'Run through `npm run e2e` (firebase emulators:exec).',
    );
  }
  for (const value of [firestore, auth]) {
    if (!LOOPBACK.has(hostOf(value))) throw new Error('Refusing to run: emulator host is not local: ' + value);
  }
  const running = process.env.GCLOUD_PROJECT;
  if (running && running !== PROJECT) {
    throw new Error(`Refusing to run: the emulators run project ${running} but the harness uses ${PROJECT}. ` +
      `Start them with --project ${PROJECT} (see README, "Project id").`);
  }
  return {
    firestoreHost: firestore,
    authHost: auth,
    firestoreBase: `http://${firestore}/v1/projects/${PROJECT}/databases/(default)/documents`,
    authBase: `http://${auth}/identitytoolkit.googleapis.com/v1`,
  };
}

const STORED_DOUBLE = Symbol('stored double');
const double = (value) => ({ [STORED_DOUBLE]: value });

function toValue(x) {
  if (x === null || x === undefined) return { nullValue: null };
  if (typeof x === 'object' && STORED_DOUBLE in x) return { doubleValue: x[STORED_DOUBLE] };
  if (typeof x === 'string') return { stringValue: x };
  if (typeof x === 'boolean') return { booleanValue: x };
  if (typeof x === 'number') return Number.isInteger(x) ? { integerValue: String(x) } : { doubleValue: x };
  if (x instanceof Date) return { timestampValue: x.toISOString() };
  if (Array.isArray(x)) return { arrayValue: { values: x.map(toValue) } };
  return { mapValue: { fields: toFields(x) } };
}
const toFields = (obj) => Object.fromEntries(Object.entries(obj).map(([k, v]) => [k, toValue(v)]));

function fromValue(v) {
  if ('stringValue' in v) return v.stringValue;
  if ('integerValue' in v) return Number(v.integerValue);
  if ('doubleValue' in v) return v.doubleValue;
  if ('booleanValue' in v) return v.booleanValue;
  if ('timestampValue' in v) return new Date(v.timestampValue);
  if ('nullValue' in v) return null;
  if ('arrayValue' in v) return (v.arrayValue.values || []).map(fromValue);
  if ('mapValue' in v) return fromFields(v.mapValue.fields || {});
  return v;
}
const fromFields = (fields) => Object.fromEntries(Object.entries(fields).map(([k, v]) => [k, fromValue(v)]));

const request = (url, init = {}) => fetch(url, { ...init, headers: { ...init.headers, Connection: 'close' } });

function client(project = PROJECT) {
  const ep = { ...requireEmulators() };
  ep.firestoreBase = `http://${ep.firestoreHost}/v1/projects/${project}/databases/(default)/documents`;
  const owner = { 'Content-Type': 'application/json', Authorization: 'Bearer owner' };
  const docUrl = (col, id) => `${ep.firestoreBase}/${col}/${encodeURIComponent(id)}`;

  async function put(collection, docId, data) {
    const res = await request(docUrl(collection, docId), {
      method: 'PATCH', headers: owner, body: JSON.stringify({ fields: toFields(data) }),
    });
    if (!res.ok) throw new Error(`put ${collection}/${docId} -> ${res.status} ${await res.text()}`);
  }

  async function del(collection, docId) {
    const res = await request(docUrl(collection, docId), { method: 'DELETE', headers: owner });
    if (!res.ok) throw new Error(`delete ${collection}/${docId} -> ${res.status}`);
  }

  async function get(collection, docId) {
    const res = await request(docUrl(collection, docId), { headers: owner });
    if (res.status === 404) return null;
    if (!res.ok) throw new Error(`get ${collection}/${docId} -> ${res.status}`);
    return fromFields((await res.json()).fields || {});
  }

  async function list(collection) {
    const res = await request(`${ep.firestoreBase}/${collection}?pageSize=300`, { headers: owner });
    if (!res.ok) throw new Error(`list ${collection} -> ${res.status}`);
    const docs = (await res.json()).documents || [];
    return docs.map((d) => ({ id: d.name.split('/').pop(), ...fromFields(d.fields || {}) }));
  }

  async function waitForDoc(collection, docId, predicate, { timeout = 20000, label } = {}) {
    const end = Date.now() + timeout;
    let last = null;
    while (Date.now() < end) {
      last = await get(collection, docId);
      if (last && predicate(last)) return last;
      await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error(`timed out waiting for ${label || `${collection}/${docId}`}; last=${JSON.stringify(last)}`);
  }

  async function waitForQuery(collection, predicate, { timeout = 20000, label } = {}) {
    const end = Date.now() + timeout;
    while (Date.now() < end) {
      const hit = (await list(collection)).find(predicate);
      if (hit) return hit;
      await new Promise((r) => setTimeout(r, 200));
    }
    throw new Error(`timed out waiting for a matching doc in ${label || collection}`);
  }

  async function reset() {
    const firestoreReset = `http://${ep.firestoreHost}/emulator/v1/projects/${project}/databases/(default)/documents`;
    let f = await request(firestoreReset, { method: 'DELETE' });
    for (let attempt = 1; f.status === 409 && attempt <= 20; attempt += 1) {
      await new Promise((r) => setTimeout(r, 500));
      f = await request(firestoreReset, { method: 'DELETE' });
    }
    if (!f.ok) throw new Error('firestore reset -> ' + f.status);
    const a = await request(`http://${ep.authHost}/emulator/v1/projects/${project}/accounts`, { method: 'DELETE' });
    if (!a.ok) throw new Error('auth reset -> ' + a.status);
  }

  async function ensureUser(email, displayName) {
    const body = JSON.stringify({ email, password: PASSWORD, displayName, returnSecureToken: true });
    const headers = { 'Content-Type': 'application/json' };
    let res = await request(`${ep.authBase}/accounts:signUp?key=fake-api-key`, { method: 'POST', headers, body });
    let json = await res.json();
    if (!res.ok && json.error && json.error.message === 'EMAIL_EXISTS') {
      res = await request(`${ep.authBase}/accounts:signInWithPassword?key=fake-api-key`, { method: 'POST', headers, body });
      json = await res.json();
    }
    if (!res.ok) throw new Error(`auth ${email} -> ${JSON.stringify(json)}`);
    return { uid: json.localId, idToken: json.idToken };
  }

  return { ...ep, put, get, del, list, waitForDoc, waitForQuery, reset, ensureUser };
}

module.exports = { PROJECT, PASSWORD, OUTPUT_DIR, requireEmulators, client, double, toValue, toFields, fromValue, fromFields };
