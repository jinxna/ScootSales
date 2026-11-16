#!/usr/bin/env node

const fs = require('fs');
const path = require('path');

const args = process.argv.slice(2);
const help = args.includes('--help') || args.includes('-h');
const keyArg = args.find((a) => a.endsWith('.json'));

function printHelp() {
  console.log(
    [
      'Read-only final-demo preflight.',
      '',
      'Usage:',
      '  node scripts/diagnostics/demo_preflight.js ./serviceAccountKey.json',
      '',
      'Checks:',
      '  - dashboard and salesman profile readiness',
      '  - retailer coordinate status counts',
      '  - sampled route plan / progress state',
      '  - sampled AI/demo signal availability',
      '',
      'No writes are performed. There is no --apply mode.',
    ].join('\n'),
  );
}

if (help) {
  printHelp();
  process.exit(0);
}

if (!keyArg) {
  console.error('Pass the service account key path as an argument.');
  console.error('Example: node scripts/diagnostics/demo_preflight.js ./serviceAccountKey.json');
  process.exit(1);
}

const fullKey = path.resolve(process.cwd(), keyArg);
if (!fs.existsSync(fullKey)) {
  console.error('Service account key not found.');
  process.exit(1);
}

const MAX_AUTH_USERS = 1000;
const LIMITS = Object.freeze({
  users: 500,
  userAccess: 500,
  retailers: 500,
  routePlans: 100,
  routeProgress: 100,
  aiSignals: 200,
});

const DASHBOARD_ROLES = new Set(['admin', 'developer', 'supervisor', 'branch_manager']);
const ADMIN_ROLES = new Set(['admin', 'developer']);
const SALESMAN_ROLES = new Set(['salesman', 'sales representative']);

const checks = [];

function record(level, title, message, detail = []) {
  checks.push({ level, title, message, detail });
  console.log(`[${level}] ${title}: ${message}`);
  detail.filter(Boolean).forEach((line) => console.log(`      ${line}`));
}

function pass(title, message, detail) {
  record('PASS', title, message, detail);
}

function warn(title, message, detail) {
  record('WARN', title, message, detail);
}

function fail(title, message, detail) {
  record('FAIL', title, message, detail);
}

function text(value) {
  return value == null ? '' : String(value).trim();
}

function firstText(values) {
  for (const value of values) {
    const candidate = text(value);
    if (candidate) return candidate;
  }
  return '';
}

function normalizeRole(value) {
  const raw = text(value).toLowerCase().replace(/[-\s]+/g, '_');
  if (raw === 'sales_representative') return 'salesman';
  return raw;
}

function isActive(data) {
  const status = text(data.status ?? data.accountStatus ?? data.account_status).toLowerCase();
  if (status) return status === 'active';
  const active = data.isActive ?? data.active ?? data.enabled;
  return active === undefined || active === null ? true : active === true;
}

function roleOf(data) {
  return normalizeRole(firstText([
    data.role,
    data.user_group,
    data.roleLabel,
    data.userRole,
    data.position,
  ]));
}

function emailOf(data) {
  return text(data.email).toLowerCase();
}

function uidFieldOf(data) {
  return text(data.uid);
}

function employeeCodeOf(data) {
  return firstText([
    data.employeeCode,
    data.employee_code,
    data.staffId,
    data.staff_id,
    data.userId,
    data.user_id,
  ]);
}

function branchIdOf(data) {
  return firstText([data.branchId, data.branch_id]);
}

function maskedEmail(email) {
  const value = text(email);
  const at = value.indexOf('@');
  if (at <= 0) return value ? '(email present)' : '(no email)';
  const local = value.slice(0, at);
  const domain = value.slice(at + 1);
  const domainDot = domain.indexOf('.');
  const domainHead = domainDot > 0 ? domain.slice(0, domainDot) : domain;
  const domainTail = domainDot > 0 ? domain.slice(domainDot) : '';
  return `${local[0]}***@${domainHead[0] || '*'}***${domainTail}`;
}

function num(value) {
  if (value === null || value === undefined || value === '') return null;
  const parsed = Number(value);
  return Number.isFinite(parsed) ? parsed : null;
}

function validLatLng(lat, lng) {
  if (lat === null || lng === null) return false;
  if (lat === 0 && lng === 0) return false;
  return Math.abs(lat) <= 90 && Math.abs(lng) <= 180;
}

function hasValidCoord(data) {
  const lat = num(data.latitude ?? data.lat ?? data.gpsLatitude ?? data.gps_latitude);
  const lng = num(data.longitude ?? data.lng ?? data.gpsLongitude ?? data.gps_longitude);
  if (validLatLng(lat, lng)) return true;

  const containers = [
    data.location,
    data.geoPoint,
    data.coordinates,
    data.gps,
  ];
  for (const loc of containers) {
    if (Array.isArray(loc) && loc.length >= 2) {
      if (validLatLng(num(loc[0]), num(loc[1]))) return true;
    }
    if (loc && typeof loc === 'object') {
      const nestedLat = num(loc.latitude ?? loc._latitude ?? loc.lat);
      const nestedLng = num(loc.longitude ?? loc._longitude ?? loc.lng);
      if (validLatLng(nestedLat, nestedLng)) return true;
    }
  }
  return false;
}

function coordinateBucket(data) {
  const status = text(data.coordinateStatus).toLowerCase();
  const valid = hasValidCoord(data);
  if (status === 'verified') return valid ? 'verified' : 'missing';
  if (status === 'needs_review' || status === 'needsreview') return valid ? 'needs_review' : 'missing';
  if (status === 'candidate') return valid ? 'candidate' : 'missing';
  if (!valid) return 'missing';
  return 'needs_review';
}

async function readLimited(db, collectionName, limit) {
  const snap = await db.collection(collectionName).limit(limit).get();
  return {
    docs: snap.docs,
    hitLimit: snap.size === limit,
  };
}

async function listAuthUsers(auth) {
  const byUid = new Map();
  const byEmail = new Map();
  let result;
  try {
    result = await auth.listUsers(MAX_AUTH_USERS);
  } catch (error) {
    warn(
      'Auth user sample',
      `Could not list Auth users: ${error.message || error}`,
      ['Firestore profile checks will fall back to uid fields and document IDs only.'],
    );
    return { byUid, byEmail };
  }

  result.users.forEach((user) => {
    byUid.set(user.uid, user);
    if (user.email) byEmail.set(user.email.toLowerCase(), user);
  });
  if (result.pageToken) {
    warn(
      'Auth user sample',
      `Sampled first ${MAX_AUTH_USERS} Auth users; more exist.`,
      ['Profile/addressability checks may be incomplete.'],
    );
  } else {
    pass('Auth user sample', `Sampled ${result.users.length} Auth user(s).`);
  }
  return { byUid, byEmail };
}

function profileInfo(source, doc, authMaps) {
  const data = doc.data() || {};
  const email = emailOf(data);
  const uidField = uidFieldOf(data);
  const authByUid = uidField ? authMaps.byUid.get(uidField) : null;
  const authByEmail = email ? authMaps.byEmail.get(email) : null;
  const authUid = authByUid?.uid || authByEmail?.uid || '';
  return {
    source,
    docId: doc.id,
    data,
    email,
    uidField,
    authUid,
    role: roleOf(data),
    active: isActive(data),
    employeeCode: employeeCodeOf(data),
    branchId: branchIdOf(data),
    rulesAddressable: authUid ? doc.id === authUid : Boolean(uidField && doc.id === uidField),
  };
}

function checkProfiles(usersDocs, accessDocs, authMaps) {
  const profiles = [
    ...usersDocs.map((doc) => profileInfo('users', doc, authMaps)),
    ...accessDocs.map((doc) => profileInfo('user_access', doc, authMaps)),
  ];

  const activeProfiles = profiles.filter((profile) => profile.active);
  const dashboardProfiles = activeProfiles.filter((profile) => DASHBOARD_ROLES.has(profile.role));
  const adminProfiles = dashboardProfiles.filter((profile) => ADMIN_ROLES.has(profile.role));
  const addressableAdmins = adminProfiles.filter((profile) => profile.rulesAddressable);
  const addressableDashboard = dashboardProfiles.filter((profile) => profile.rulesAddressable);
  const salesmanProfiles = activeProfiles.filter((profile) => SALESMAN_ROLES.has(profile.role));
  const salesmanWithCodes = salesmanProfiles.filter((profile) => profile.employeeCode);

  if (dashboardProfiles.length === 0) {
    fail('Dashboard profiles', 'No active dashboard-role profile sampled.');
  } else if (addressableDashboard.length === 0) {
    fail(
      'Dashboard profiles',
      'Dashboard profiles exist, but none are addressable as users/{auth.uid} or user_access/{auth.uid}.',
      ['Route-plan writes will fail Firestore rules until the signed-in user has an addressable profile.'],
    );
  } else if (addressableAdmins.length > 0) {
    pass(
      'Dashboard profiles',
      `${addressableAdmins.length} admin/developer profile(s) are rules-addressable.`,
    );
  } else {
    warn(
      'Dashboard profiles',
      `${addressableDashboard.length} supervisor/branch-manager profile(s) are addressable, but no admin/developer profile was sampled.`,
      ['Route creation may depend on assignedSalesmanCodes or branchId matching the selected salesman.'],
    );
  }

  const nonAddressable = dashboardProfiles.filter((profile) => !profile.rulesAddressable);
  if (nonAddressable.length > 0) {
    warn(
      'Profile addressability',
      `${nonAddressable.length} active dashboard profile(s) are not addressable by Auth UID.`,
      nonAddressable.slice(0, 5).map((profile) =>
        `${profile.source}/${profile.docId} role=${profile.role} email=${maskedEmail(profile.email)}`),
    );
  }

  if (salesmanProfiles.length === 0) {
    fail('Salesman profiles', 'No active salesman profile sampled.');
  } else if (salesmanWithCodes.length === 0) {
    warn(
      'Salesman profiles',
      `${salesmanProfiles.length} active salesman profile(s) sampled, but none have employee/staff codes.`,
      ['Route assignment by salesmanCode may not match the mobile account.'],
    );
  } else {
    pass(
      'Salesman profiles',
      `${salesmanProfiles.length} active salesman profile(s), ${salesmanWithCodes.length} with employee/staff codes.`,
    );
  }

  const branchManagersWithoutBranch = dashboardProfiles.filter(
    (profile) => profile.role === 'branch_manager' && !profile.branchId,
  );
  if (branchManagersWithoutBranch.length > 0) {
    warn(
      'Branch manager scope',
      `${branchManagersWithoutBranch.length} branch-manager profile(s) have no branchId.`,
      ['They may see empty route/order scopes until branchId is populated.'],
    );
  }
}

function checkCoordinates(retailerDocs, hitLimit) {
  if (retailerDocs.length === 0) {
    fail('Retailers', 'No retailer documents sampled.');
    return;
  }

  const counts = { verified: 0, needs_review: 0, candidate: 0, missing: 0 };
  retailerDocs.forEach((doc) => {
    counts[coordinateBucket(doc.data() || {})] += 1;
  });

  const summary = `sampled ${retailerDocs.length}: verified=${counts.verified}, needs_review=${counts.needs_review}, candidate=${counts.candidate}, missing=${counts.missing}`;
  if (counts.verified > 0) {
    pass('Retailer coordinates', summary);
  } else if (counts.needs_review + counts.candidate > 0) {
    warn(
      'Retailer coordinates',
      summary,
      ['The planner can demo with unverified coordinates, but "Verified only" will be blocked until the gated coordinate apply/review.'],
    );
  } else {
    fail('Retailer coordinates', summary, ['No routable retailer coordinates were sampled.']);
  }

  if (counts.missing > 0) {
    warn(
      'Missing coordinates',
      `${counts.missing} sampled retailer(s) have no usable coordinate.`,
      ['Route Health should surface these as excluded/missing, not silently route them.'],
    );
  }

  if (hitLimit) {
    warn(
      'Retailer sample cap',
      `Read reached the ${LIMITS.retailers}-doc cap.`,
      ['Counts are sample counts, not a full collection count.'],
    );
  }
}

function checkRoutePlans(routeDocs, progressDocs, routeHitLimit, progressHitLimit) {
  const counts = { draft: 0, approved: 0, published: 0, other: 0 };
  routeDocs.forEach((doc) => {
    const status = text((doc.data() || {}).status).toLowerCase();
    if (Object.prototype.hasOwnProperty.call(counts, status)) counts[status] += 1;
    else counts.other += 1;
  });

  if (routeDocs.length === 0) {
    warn(
      'Route plans',
      'No route_plans sampled.',
      ['This is fine before the route demo, but publish a plan before testing mobile assigned routes.'],
    );
  } else {
    pass(
      'Route plans',
      `sampled ${routeDocs.length}: draft=${counts.draft}, approved=${counts.approved}, published=${counts.published}, other=${counts.other}`,
    );
  }

  if (progressDocs.length === 0) {
    warn(
      'Route progress',
      'No route_plan_progress docs sampled.',
      ['Progress appears only after the mobile app accepts/starts/completes assigned-route stops.'],
    );
  } else {
    pass('Route progress', `sampled ${progressDocs.length} route progress doc(s).`);
  }

  if (routeHitLimit || progressHitLimit) {
    warn(
      'Route sample cap',
      `Read reached route cap(s): plans=${routeHitLimit}, progress=${progressHitLimit}.`,
      ['Counts are sample counts, not full collection counts.'],
    );
  }
}

function isActiveSignal(data) {
  const status = text(data.status).toLowerCase();
  const autoState = text(data.autoState).toLowerCase();
  if (status && ['resolved', 'dismissed', 'ignored'].includes(status)) return false;
  if (autoState && ['resolved', 'suppressed', 'inactive'].includes(autoState)) return false;
  if (data.active === false || data.isActive === false) return false;
  return true;
}

function checkAiSignals(samples) {
  const aiInsights = samples.ai_insights.docs;
  const visitBriefs = samples.visit_briefs.docs;
  const segments = samples.retailer_segments.docs;
  const notifications = samples.dashboard_notifications.docs;
  const outcomes = samples.conversation_outcomes.docs;

  const activeInsights = aiInsights.filter((doc) => isActiveSignal(doc.data() || {})).length;
  const highPriority = aiInsights.filter((doc) => {
    const data = doc.data() || {};
    return ['high', 'urgent'].includes(firstText([data.priority, data.severity]).toLowerCase());
  }).length;

  if (aiInsights.length === 0 && visitBriefs.length === 0) {
    warn(
      'AI demo signals',
      'No ai_insights or visit_briefs sampled.',
      ['Run the AI generator dry-run/apply flow before demonstrating Management Action Center and Scout.'],
    );
  } else {
    pass(
      'AI demo signals',
      `ai_insights=${aiInsights.length} (${activeInsights} active, ${highPriority} high/urgent), visit_briefs=${visitBriefs.length}, segments=${segments.length}, notifications=${notifications.length}, outcomes=${outcomes.length}`,
    );
  }

  Object.entries(samples).forEach(([name, sample]) => {
    if (sample.hitLimit) {
      warn(
        `${name} sample cap`,
        `Read reached the ${LIMITS.aiSignals}-doc cap.`,
        ['Counts are sample counts, not full collection counts.'],
      );
    }
  });
}

async function main() {
  // eslint-disable-next-line global-require, import/no-dynamic-require
  const admin = require('firebase-admin');
  // eslint-disable-next-line global-require, import/no-dynamic-require
  const serviceAccount = require(fullKey);

  admin.initializeApp({ credential: admin.credential.cert(serviceAccount) });
  const db = admin.firestore();
  const authMaps = await listAuthUsers(admin.auth());

  const [
    users,
    userAccess,
    retailers,
    routePlans,
    routeProgress,
    aiInsights,
    visitBriefs,
    retailerSegments,
    notifications,
    outcomes,
  ] = await Promise.all([
    readLimited(db, 'users', LIMITS.users),
    readLimited(db, 'user_access', LIMITS.userAccess),
    readLimited(db, 'retailers', LIMITS.retailers),
    readLimited(db, 'route_plans', LIMITS.routePlans),
    readLimited(db, 'route_plan_progress', LIMITS.routeProgress),
    readLimited(db, 'ai_insights', LIMITS.aiSignals),
    readLimited(db, 'visit_briefs', LIMITS.aiSignals),
    readLimited(db, 'retailer_segments', LIMITS.aiSignals),
    readLimited(db, 'dashboard_notifications', LIMITS.aiSignals),
    readLimited(db, 'conversation_outcomes', LIMITS.aiSignals),
  ]);

  if (users.hitLimit) {
    warn('Users sample cap', `Read reached the ${LIMITS.users}-doc cap.`);
  }
  if (userAccess.hitLimit) {
    warn('User-access sample cap', `Read reached the ${LIMITS.userAccess}-doc cap.`);
  }

  checkProfiles(users.docs, userAccess.docs, authMaps);
  checkCoordinates(retailers.docs, retailers.hitLimit);
  checkRoutePlans(routePlans.docs, routeProgress.docs, routePlans.hitLimit, routeProgress.hitLimit);
  checkAiSignals({
    ai_insights: aiInsights,
    visit_briefs: visitBriefs,
    retailer_segments: retailerSegments,
    dashboard_notifications: notifications,
    conversation_outcomes: outcomes,
  });

  const totals = checks.reduce((acc, check) => {
    acc[check.level] = (acc[check.level] || 0) + 1;
    return acc;
  }, {});

  console.log('\n=== DEMO PREFLIGHT SUMMARY ===');
  console.log(`PASS=${totals.PASS || 0} WARN=${totals.WARN || 0} FAIL=${totals.FAIL || 0}`);
  console.log('Read-only. No Firestore, Auth, Storage, rules, or index writes were attempted.');

  process.exit(totals.FAIL ? 2 : 0);
}

main().catch((error) => {
  console.error(`Preflight failed before checks completed: ${error.message || error}`);
  process.exit(1);
});
