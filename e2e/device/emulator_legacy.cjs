'use strict';

const fs = require('node:fs');
const path = require('node:path');

const PROJECT = 'cos40005';
const PASSWORD = 'E2E-Local-Only-123!';
const ADMIN_EMAIL = 'e2e.admin@example.test';
const SALES_EMAIL = 'e2e.sales1@example.test';
const OUTPUT_DIR = path.resolve(__dirname, '..', 'output');

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
      'Refusing to run: FIRESTORE_EMULATOR_HOST and FIREBASE_AUTH_EMULATOR_HOST ' +
        'must be set. Run through `npm run test:e2e:device` (firebase emulators:exec).',
    );
  }
  for (const value of [firestore, auth]) {
    if (!LOOPBACK.has(hostOf(value))) {
      throw new Error('Refusing to run: emulator host is not local: ' + value);
    }
  }
  return {
    firestoreBase:
      'http://' + firestore + '/v1/projects/' + PROJECT + '/databases/(default)/documents',
    firestoreRoot:
      'http://' + firestore + '/v1/projects/' + PROJECT + '/databases/(default)',
    authBase: 'http://' + auth + '/identitytoolkit.googleapis.com/v1',
  };
}

const ts = (iso) => ({ timestampValue: iso });
const str = (v) => ({ stringValue: String(v) });
const num = (v) => ({ integerValue: String(v) });
const dbl = (v) => ({ doubleValue: Number(v) });
const bool = (v) => ({ booleanValue: !!v });
const arr = (values) => ({ arrayValue: { values } });
const map = (fields) => ({ mapValue: { fields } });

function client() {
  const ep = requireEmulators();
  const owner = { 'Content-Type': 'application/json', Authorization: 'Bearer owner' };

  async function put(collection, docId, fields) {
    const res = await fetch(ep.firestoreBase + '/' + collection + '/' + encodeURIComponent(docId), {
      method: 'PATCH',
      headers: owner,
      body: JSON.stringify({ fields }),
    });
    if (!res.ok) throw new Error(collection + '/' + docId + ' -> ' + res.status + ' ' + (await res.text()));
  }

  async function get(collection, docId) {
    const res = await fetch(ep.firestoreBase + '/' + collection + '/' + encodeURIComponent(docId), {
      headers: owner,
    });
    if (res.status === 404) return null;
    if (!res.ok) throw new Error('get ' + collection + '/' + docId + ' -> ' + res.status);
    return res.json();
  }

  async function list(collection) {
    const res = await fetch(ep.firestoreBase + '/' + collection + '?pageSize=300', { headers: owner });
    if (!res.ok) throw new Error('list ' + collection + ' -> ' + res.status);
    return (await res.json()).documents || [];
  }

  async function remove(collection, docId) {
    const res = await fetch(ep.firestoreBase + '/' + collection + '/' + encodeURIComponent(docId), {
      method: 'DELETE',
      headers: owner,
    });
    if (!res.ok && res.status !== 404) throw new Error('delete ' + collection + '/' + docId + ' -> ' + res.status);
  }

  async function patch(collection, docId, fields, maskPaths) {
    const url = new URL(ep.firestoreBase + '/' + collection + '/' + encodeURIComponent(docId));
    for (const field of maskPaths) url.searchParams.append('updateMask.fieldPaths', field);
    const res = await fetch(url, { method: 'PATCH', headers: owner, body: JSON.stringify({ fields }) });
    if (!res.ok) throw new Error('patch ' + collection + '/' + docId + ' -> ' + res.status);
  }

  async function ensureUser(email, displayName) {
    const body = JSON.stringify({ email, password: PASSWORD, displayName, returnSecureToken: true });
    const headers = { 'Content-Type': 'application/json' };
    let res = await fetch(ep.authBase + '/accounts:signUp?key=fake-api-key', { method: 'POST', headers, body });
    let json = await res.json();
    if (!res.ok && json.error && json.error.message === 'EMAIL_EXISTS') {
      res = await fetch(ep.authBase + '/accounts:signInWithPassword?key=fake-api-key', {
        method: 'POST',
        headers,
        body,
      });
      json = await res.json();
    }
    if (!res.ok) throw new Error('auth ' + email + ' -> ' + JSON.stringify(json));
    return { uid: json.localId, idToken: json.idToken };
  }

  async function signIn(email) {
    return ensureUser(email, email);
  }

  return { ...ep, put, patch, get, list, remove, ensureUser, signIn };
}

function outputDir() {
  fs.mkdirSync(OUTPUT_DIR, { recursive: true });
  return OUTPUT_DIR;
}

module.exports = {
  PROJECT, PASSWORD, ADMIN_EMAIL, SALES_EMAIL,
  requireEmulators, client, outputDir,
  ts, str, num, dbl, bool, arr, map,
};
