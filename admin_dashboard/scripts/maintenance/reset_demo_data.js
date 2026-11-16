'use strict';

const admin = require('firebase-admin');
const path = require('path');

const keyPath = process.argv[2];
const collections = [
  'users',
  'products',
  'retailers',
  'orders',
  'route_plans',
  'route_plan_progress',
  'conversation_outcomes',
  'retailer_item_patterns',
  'ai_insights',
  'visit_briefs',
  'retailer_segments',
  'retailer_memory',
  'dashboard_notifications',
  'notification_logs',
  'demand_forecasts',
  'forecast_imports',
  'forecast_training_runs',
  'visit_logs',
  'gps_tracking',
];
const MAX_DOCUMENTS_PER_COLLECTION = 5000;

if (!keyPath) {
  console.error(
    'Usage: node scripts/maintenance/reset_demo_data.js <serviceAccountKey.json>',
  );
  process.exit(1);
}
if (process.argv.includes('--apply')) {
  console.error(
    'Demo reset is report-only. Demo records are retained; --apply is no longer supported.',
  );
  process.exit(1);
}

admin.initializeApp({
  credential: admin.credential.cert(require(path.resolve(keyPath))),
});
const db = admin.firestore();
const demoPlanIds = new Set();

function hasBoundedMarker(value, marker) {
  return (
    value === marker ||
    value.startsWith(`${marker}-`) ||
    value.startsWith(`${marker}_`) ||
    value.startsWith(`${marker}:`)
  );
}

function isDemo(data) {
  if (data.isDemo === true) return true;
  return [data.source, data.importSource, data.coordinateSource]
    .filter((value) => value != null)
    .map((value) => String(value).trim().toLowerCase())
    .some(
      (source) =>
        hasBoundedMarker(source, 'demo') ||
        hasBoundedMarker(source, 'dashboard_demo'),
    );
}

async function eligibleDocs(collectionName) {
  const snapshot = await db
    .collection(collectionName)
    .limit(MAX_DOCUMENTS_PER_COLLECTION)
    .get();
  return snapshot.docs.filter((doc) => {
    const data = doc.data();
    const eligible =
      isDemo(data) ||
      (collectionName === 'route_plan_progress' &&
        demoPlanIds.has(String(data.planId || '')));
    if (collectionName === 'route_plans' && eligible) {
      demoPlanIds.add(doc.id);
    }
    return eligible;
  });
}

async function main() {
  const reported = [];
  for (const collectionName of collections) {
    const docs = await eligibleDocs(collectionName);
    reported.push(...docs.map((doc) => ({ collectionName, doc })));
    console.log(`${collectionName}: ${docs.length} demo document(s)`);
  }

  console.log(
    `Report complete: ${reported.length} demo-only document(s) retained.`,
  );
}

main().catch((error) => {
  console.error(`Demo reset failed: ${error.message}`);
  process.exit(1);
});
