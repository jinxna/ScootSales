'use strict';

const { PROJECT, toFields } = require('./emulator.cjs');

async function putMany(db, collection, docs, chunk = 250) {
  const prefix = `projects/${PROJECT}/databases/(default)/documents/${collection}`;
  for (let start = 0; start < docs.length; start += chunk) {
    const writes = docs.slice(start, start + chunk).map(({ id, data }) => ({
      update: { name: `${prefix}/${id}`, fields: toFields(data) },
    }));
    const res = await fetch(`${db.firestoreBase}:commit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
      body: JSON.stringify({ writes }),
    });
    if (!res.ok) throw new Error(`bulk put ${collection} (${start}..${start + writes.length}) -> ${res.status} ${await res.text()}`);
  }
}

async function deleteMany(db, collection, ids, chunk = 250) {
  const prefix = `projects/${PROJECT}/databases/(default)/documents/${collection}`;
  for (let start = 0; start < ids.length; start += chunk) {
    const writes = ids.slice(start, start + chunk).map(id => ({
      delete: `${prefix}/${id}`,
    }));
    const res = await fetch(`${db.firestoreBase}:commit`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', Authorization: 'Bearer owner' },
      body: JSON.stringify({ writes }),
    });
    if (!res.ok) throw new Error(`bulk delete ${collection} -> ${res.status} ${await res.text()}`);
  }
}

async function listDocumentIds(db, collection) {
  const ids = [];
  let token;
  do {
    const url = new URL(`${db.firestoreBase}/${collection}`);
    url.searchParams.set('pageSize', '300');
    if (token) url.searchParams.set('pageToken', token);
    const res = await fetch(url, { headers: { Authorization: 'Bearer owner' } });
    if (!res.ok) throw new Error(`list ${collection} -> ${res.status} ${await res.text()}`);
    const page = await res.json();
    ids.push(...(page.documents || []).map(doc => doc.name.split('/').at(-1)));
    token = page.nextPageToken;
  } while (token);
  return ids;
}

module.exports = { putMany, deleteMany, listDocumentIds };
