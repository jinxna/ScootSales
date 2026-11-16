'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const dashboardPages = require('../lib/dashboard_pages.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const staff = require('../lib/staff.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');
const { PRODUCTS, RETAILERS, putPerson } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'walkthrough');
const SHOTS = path.join(OUT, 'screens');
const TEXTS = path.join(OUT, 'text');
const STRICT = process.env.WALKTHROUGH_STRICT === '1';
const ONLY = (process.env.WALKTHROUGH_ONLY || (process.env.E2E_RUNNER === 'signin' ? 'control' : 'dashboard,mobile')).split(',').map((x) => x.trim());

const PLACEHOLDERS = [
  ['TODO', /\bTODO\b/],
  ['lorem', /\blorem\b/i],
  ['Coming soon', /coming soon/i],
  ['null', /\bnull\b/],
  ['undefined', /\bundefined\b/],
  ['NaN', /\bNaN\b/],
  ['Instance of', /Instance of/],
];
const FLUTTER_EXCEPTION = /RenderFlex overflowed|overflowed by|Null check operator|setState\(\) or markNeedsBuild|setState\(\) called after dispose|Unhandled Exception|FLUTTER_ERROR|EXCEPTION CAUGHT|Another exception was thrown|pageerror:|has already been listened to|type '.*' is not a subtype/;
const VISIBLE_ERROR = /something went wrong|permission[- ]denied|insufficient permissions|failed to load|could not load|couldn'?t load|unable to load|not available to your role|access denied|an error occurred|error:/i;

const DEV = { email: 'e2e.developer@example.test', name: 'E2E Developer', role: 'developer', code: 'DEV-E2E', branch: 'B1' };

const NO_PRICED_PLANS = 'not applicable (no priced plans)';
const NOT_ON_WEB = 'not applicable on web (the avatar opens the browser file picker)';

const rows = [];
const unreachable = [];
const notApplicablePages = [];
const discovery = [];
const notes = [];
const sessionState = new Map();
let counter = 0;

const slug = (text) => text.toLowerCase().replace(/[^a-z0-9]+/g, '-').replace(/^-+|-+$/g, '').slice(0, 52) || 'page';
const escapeRe = (text) => text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');
const short = (text, n = 220) => String(text).replace(/\s+/g, ' ').trim().slice(0, n);

function stateOf(s) {
  if (!sessionState.has(s)) sessionState.set(s, { all: [], blocked: 0, cursor: 0 });
  return sessionState.get(s);
}

function drain(s) {
  const st = stateOf(s);
  let fresh;
  if (STRICT) {
    fresh = s.logs.slice(st.cursor);
    st.cursor = s.logs.length;
  } else {
    fresh = s.logs.splice(0, s.logs.length);
  }
  st.all.push(...fresh);
  const blocked = s.blocked.slice(st.blocked);
  st.blocked = s.blocked.length;
  return {
    consoleErrors: fresh.filter((l) => /^\[[^\]]*\] (error|pageerror):/.test(l)).map((l) => short(l, 300)),
    flutterExceptions: fresh.filter((l) => FLUTTER_EXCEPTION.test(l)).map((l) => short(l, 300)),
    failedRequests: [...new Set(fresh.filter((l) => /\] requestfailed: /.test(l)).map((l) => short(l.replace(/^\[[^\]]*\] requestfailed: /, ''), 200)))],
    blocked,
  };
}

function scanPlaceholders(lines) {
  const found = [];
  for (const line of lines) {
    for (const [name, re] of PLACEHOLDERS) {
      if (re.test(line)) found.push(`${name}: ${short(line, 120)}`);
    }
  }
  return [...new Set(found)];
}

async function semanticLines(page) {
  return admin.semanticsLines(page).catch(() => []);
}

async function snap(s, file) {
  fs.mkdirSync(SHOTS, { recursive: true });
  await s.page.screenshot({ path: path.join(SHOTS, file) }).catch(() => null);
}

async function capture(s, meta, { settle = 1200, scroll = 0, problems = [] } = {}) {
  await s.page.waitForTimeout(settle);
  counter += 1;
  const n = String(counter).padStart(3, '0');
  const base = `${meta.app}-${meta.role}-${n}-${slug(meta.name)}`;
  await snap(s, `${base}.png`);
  const lines = await semanticLines(s.page);
  fs.mkdirSync(TEXTS, { recursive: true });
  fs.writeFileSync(path.join(TEXTS, `${base}.txt`), lines.join('\n'));
  const extra = [];
  for (let i = 0; i < scroll; i += 1) {
    const size = s.page.viewportSize();
    await s.page.mouse.move(size.width * 0.6, size.height * 0.55);
    await s.page.mouse.wheel(0, Math.round(size.height * 0.75));
    await s.page.waitForTimeout(700);
    const file = `${base}-scroll${i + 1}.png`;
    await snap(s, file);
    extra.push(`screens/${file}`);
  }
  if (scroll) {
    const size = s.page.viewportSize();
    await s.page.mouse.wheel(0, -size.height * scroll * 2);
    await s.page.waitForTimeout(300);
  }
  const seen = drain(s);
  const visibleErrors = [...new Set(lines.filter((l) => VISIBLE_ERROR.test(l)).map((l) => short(l, 160)))].slice(0, 6);
  const issues = [...problems];
  if (lines.length < 3) issues.push(`almost empty semantics tree (${lines.length} nodes): the page may be blank`);
  const row = {
    n: counter, app: meta.app, role: meta.role, page: meta.name, route: meta.route || '',
    screenshot: `screens/${base}.png`, extraScreenshots: extra, status: 'opened',
    consoleErrors: seen.consoleErrors, flutterExceptions: seen.flutterExceptions, blockedRequests: seen.blocked, failedRequests: seen.failedRequests,
    placeholderText: scanPlaceholders(lines), visibleErrorText: visibleErrors, notes: issues, semanticNodes: lines.length,
  };
  rows.push(row);
  console.log(`  [${n}] ${meta.app}/${meta.role}: ${meta.name}${seen.flutterExceptions.length ? ` (${seen.flutterExceptions.length} Flutter exception(s))` : ''}`);
  return row;
}

async function dismiss(page) {
  for (let i = 0; i < 3; i += 1) {
    const dialogs = await page.getByRole('dialog').count().catch(() => 0);
    const cancel = page.getByRole('button', { name: /^(Cancel|Close|Done|Dismiss)$/ }).last();
    if (!dialogs && !(await cancel.count().catch(() => 0))) return;
    await page.keyboard.press('Escape').catch(() => null);
    await page.waitForTimeout(400);
    if (await cancel.count().catch(() => 0)) await cancel.click({ timeout: 3000 }).catch(() => null);
    await page.waitForTimeout(400);
  }
}

async function visit(s, meta, act, options = {}) {
  if (s.chain && s.chainBroken) {
    unreachableRow(meta, 'skipped: an earlier step of this sequence failed');
    return null;
  }
  try {
    await act();
  } catch (error) {
    if (s.chain) s.chainBroken = true;
    const status = 'UNREACHABLE';
    const message = short(error.message, 400);
    counter += 1;
    const n = String(counter).padStart(3, '0');
    const base = `${meta.app}-${meta.role}-${n}-${slug(meta.name)}-${status}`;
    await snap(s, `${base}.png`);
    const seen = drain(s);
    rows.push({
      n: counter, app: meta.app, role: meta.role, page: meta.name, route: meta.route || '', screenshot: `screens/${base}.png`,
      extraScreenshots: [], status, error: message, consoleErrors: seen.consoleErrors,
      flutterExceptions: seen.flutterExceptions, blockedRequests: seen.blocked, failedRequests: seen.failedRequests, placeholderText: [], visibleErrorText: [], notes: [],
      semanticNodes: 0,
    });
    unreachable.push(`${meta.app}/${meta.role}: ${meta.name} - ${message}`);
    console.log(`  [${n}] ${status} ${meta.app}/${meta.role}: ${meta.name} - ${message}`);
    await dismiss(s.page).catch(() => null);
    return null;
  }
  return capture(s, meta, options);
}

function unreachableRow(meta, message) {
  unreachable.push(`${meta.app}/${meta.role}: ${meta.name} - ${message}`);
  rows.push({
    n: ++counter, app: meta.app, role: meta.role, page: meta.name, route: meta.route || '', screenshot: '', extraScreenshots: [],
    status: 'NOT REACHED', error: message, consoleErrors: [], flutterExceptions: [], blockedRequests: [], failedRequests: [], placeholderText: [],
    visibleErrorText: [], notes: [], semanticNodes: 0,
  });
}

async function notApplicableRow(s, meta, reason) {
  counter += 1;
  const n = String(counter).padStart(3, '0');
  const base = `${meta.app}-${meta.role}-${n}-${slug(meta.name)}-NOT-APPLICABLE`;
  await snap(s, `${base}.png`);
  const seen = drain(s);
  rows.push({
    n: counter, app: meta.app, role: meta.role, page: meta.name, route: meta.route || '', screenshot: `screens/${base}.png`,
    extraScreenshots: [], status: 'NOT APPLICABLE', error: reason, consoleErrors: seen.consoleErrors,
    flutterExceptions: seen.flutterExceptions, blockedRequests: seen.blocked, failedRequests: seen.failedRequests, placeholderText: [],
    visibleErrorText: [], notes: [], semanticNodes: 0,
  });
  notApplicablePages.push(`${meta.app}/${meta.role}: ${meta.name} - ${reason}`);
  console.log(`  [${n}] NOT APPLICABLE ${meta.app}/${meta.role}: ${meta.name} - ${reason}`);
}

async function hashIs(page, key, timeout = 15000) {
  await page.waitForFunction((k) => location.hash === `#/${k}`, key, { timeout });
}

async function navTo(page, label) {
  await admin.goToPage(page, label);
}

async function seedData(t) {
  const { db, accounts, seed } = t;
  const uid = seed.uids.salesman;
  const H = 3600e3;
  const now = Date.now();
  const line = (p, qty) => ({
    productId: p.id, name: p.name, productName: p.name, itemName: p.name, quantity: qty, qty, boxes: qty,
    price: p.price, unitPrice: p.price, uom: 'box', department: p.dept, departmentName: p.dept,
  });
  const orders = [
    ['ORD-WALK-001', RETAILERS[0], 'submitted', 2 * H, [[PRODUCTS[0], 2], [PRODUCTS[1], 1]]],
    ['ORD-WALK-002', RETAILERS[1], 'submitted', 5 * H, [[PRODUCTS[2], 3]]],
    ['ORD-WALK-003', RETAILERS[0], 'approved', 26 * H, [[PRODUCTS[0], 1]]],
    ['ORD-WALK-004', RETAILERS[1], 'rejected', 50 * H, [[PRODUCTS[1], 2]]],
    ['ORD-WALK-005', RETAILERS[0], 'approved', 8 * 24 * H, [[PRODUCTS[2], 2], [PRODUCTS[0], 1]]],
    ['ORD-WALK-006', RETAILERS[1], 'submitted', 20 * 24 * H, [[PRODUCTS[1], 4]]],
  ];
  for (const [id, retailer, status, age, items] of orders) {
    const at = new Date(now - age);
    const total = items.reduce((sum, [p, q]) => sum + p.price * q, 0);
    await db.put('orders', id, {
      orderId: id, uid, userUid: uid, salesmanUid: uid, salesmanEmail: accounts.salesman.email, salesmanName: accounts.salesman.name,
      salesmanId: accounts.salesman.code, salesmanCode: accounts.salesman.code, submittedByUid: uid, createdByUid: uid,
      branchId: accounts.salesman.branch, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name, status,
      items: items.map(([p, q]) => line(p, q)), totalProducts: items.length, totalBoxes: items.reduce((sum, [, q]) => sum + q, 0),
      totalPrice: Math.round(total * 100) / 100, submittedAt: at, createdAt: at,
      ...(status === 'approved' ? { approvedAt: new Date(at.getTime() + H), approvedBy: accounts.admin.email } : {}),
      ...(status === 'rejected' ? { rejectedAt: new Date(at.getTime() + H), rejectedBy: accounts.admin.email, rejectionRemark: 'Out of stock' } : {}),
    });
  }
  await db.put('orders', 'ORD-WALK-SR', {
    orderId: 'ORD-WALK-SR', uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code,
    branchId: accounts.salesman.branch, retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name, outlet: RETAILERS[0].name,
    status: 'submitted', items: [], totalProducts: 0, totalBoxes: 0, totalPrice: 0, submittedAt: new Date(now - H), createdAt: new Date(now - H),
  });
  await db.put('special_requests', 'ORD-WALK-SR', {
    orderId: 'ORD-WALK-SR', requestType: 'non_catalogue_item', retailerName: RETAILERS[0].name, retailerId: RETAILERS[0].id,
    requestedItem: 'Walkthrough sample item', reason: 'Retailer asked for a pack size we do not list', salesmanCode: accounts.salesman.code,
    branchId: accounts.salesman.branch, createdByUid: uid, createdByRole: 'salesman', status: 'pending_supervisor', approvalStep: 'Supervisor',
    lastActorUid: uid, lastActorRole: 'salesman', createdAt: new Date(now - H), updatedAt: new Date(now - H), lastActionAt: new Date(now - H),
  });
  const visit = (id, retailer, minutesAgo, minutes) => db.put('visit_logs', id, {
    salesmanUid: uid, salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code, branchId: accounts.salesman.branch,
    retailerId: retailer.id, retailerName: retailer.name, latitude: retailer.lat, longitude: retailer.lng,
    arrivalTime: new Date(now - minutesAgo * 60e3), departureTime: new Date(now - (minutesAgo - minutes) * 60e3),
  });
  await visit('vl-walk-1', RETAILERS[0], 300, 25);
  await visit('vl-walk-2', RETAILERS[1], 200, 40);
  await visit('vl-walk-3', RETAILERS[0], 60 * 26, 30);
  const stop = (planId, stopId, retailer, status, minutesAgo, extra) => db.put('route_stop_progress', `${planId}_${uid}_${stopId}`, {
    planId, stopId, salesmanUid: uid, salesmanCode: accounts.salesman.code, branchId: accounts.salesman.branch,
    retailerId: retailer.id, retailerName: retailer.name, lifecycleSchemaVersion: 2, status,
    arrivedAt: new Date(now - minutesAgo * 60e3), updatedAt: new Date(now - (minutesAgo - 10) * 60e3),
    arrivalMode: 'location_verified', arrivalDistanceMeters: 14, ...extra,
  });
  await stop('PLAN-WALK-OLD', 's1', RETAILERS[0], 'completed', 60 * 30, { completedAt: new Date(now - (60 * 30 - 20) * 60e3) });
  await stop('PLAN-WALK-OLD', 's2', RETAILERS[1], 'skipped', 60 * 29, { skippedAt: new Date(now - (60 * 29 - 5) * 60e3), skipReason: 'Shop closed' });
  await db.put('live_tracking', uid, {
    salesmanUid: uid, salesmanCode: accounts.salesman.code, branchId: accounts.salesman.branch, latitude: RETAILERS[1].lat,
    longitude: RETAILERS[1].lng, accuracy: 12, status: 'active', updatedAt: new Date(now - 2 * 60e3), lastUpdated: new Date(now - 2 * 60e3),
  });
  platform.python(['-m', 'platform_service.live_tracking_migration', '--project', E.PROJECT, '--apply', '--confirm-project', E.PROJECT],
    { env: { PLATFORM_EMULATOR_PROJECTS: E.PROJECT } });
  await putPerson(db, DEV);
  const profile = await db.get('users', accounts.salesman.email);
  await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
}

function seedPlan(key) {
  if (process.env.WALKTHROUGH_PLAN !== 'PROFESSIONAL') {
    notes.push('The company stays on the harness plan (Internal, unlimited). Set WALKTHROUGH_PLAN=PROFESSIONAL to put it on the public Professional plan first.');
    return;
  }
  try {
    directory.planAdmin([key], [{ op: 'subscribe', planId: 'PROFESSIONAL', status: 'active', billingInterval: 'monthly', reseed: true }, { op: 'usage' }]);
    notes.push('The company is on the public Professional plan (monthly) for this walkthrough so Account and Plans show a real package.');
  } catch (error) {
    notes.push(`The Professional plan could not be applied (${short(error.message, 1500)}).`);
  }
}

const NOTIFICATIONS_MARKER = /Mark all as read|All read|No notifications yet/;
const VERSION_MARKER = /Version \d/;
const FORECAST_MARKER = /Reload forecasts|Forecast data not available|Run forecast/;
const DASHBOARD_MARKER = /Needs your decision|Needs you|Waiting on others|Edit dashboard|Get set up/;

const ADMIN_PAGES = [
  ['Dashboard', 'dashboard', 'Dashboard', DASHBOARD_MARKER, { scroll: 1 }],
  ['Notifications', 'notifications', 'Notifications', NOTIFICATIONS_MARKER],
  ['All Orders', 'all_orders', 'All Orders', 'Status: All'],
  ['Purchase Orders', 'purchase_order', 'Purchase Orders', /purchase orders? issued/i],
  ['Special Requests', 'special_requests', 'Special Requests', 'Finalised'],
  ['Salesman Tracking', 'salesman_activity', 'Salesman Tracking', 'Live Status'],
  ['Visit Logs', 'visit_logs', 'Visit Logs', /Follow-up/],
  ['Route Planner', 'route_planner', 'Route Planner', 'Coverage & health'],
  ['Reports', 'reports', 'Reports', /Reload orders/, { scroll: 1 }],
  ['Demand Forecast', 'prediction', 'Demand Forecast', FORECAST_MARKER],
  ['Products', 'product', 'Products', 'Add product'],
  ['Retailers', 'retailer', 'Retailers', 'Add retailer'],
  ['Coordinate Review', 'coordinate_review', 'Coordinate Review', 'Copy CSV'],
  ['Import Centre', 'import_preview', 'Import Centre', 'Upload and preview'],
  ['Departments', 'department', 'Departments', 'Add department'],
  ['Categories', 'category', 'Categories', 'Add category'],
  ['Score Sheets', 'retailer_scoresheets', 'Score Sheets', 'Template library'],
  ['Users', 'user_directory', 'Users', 'People'],
  ['Role Assignment', 'users', 'Role Assignment', 'Account repair tools'],
  ['Role Permissions', 'permissions', 'Role Permissions', /A tick is enforced by the system/],
  ['Branches', 'branches', 'Branches', 'Branch Name'],
  ['Department PIC', 'department_pic', 'Retailer Department PIC', /Add PIC|Retailer-specific contacts/],
  ['Account Lockouts', 'account_lockouts', 'Account Lockouts', /unverified reports of local login delays/],
  ['Account', 'account', 'Account', /Enter your password to see your plan and usage|Plan: |Change plan/],
  ['Privacy Policy', 'privacy_policy', 'Privacy Policy', VERSION_MARKER],
  ['Terms & Conditions', 'terms_conditions', 'Terms & Conditions', VERSION_MARKER],
  ['Audit Log', 'audit_log', 'Audit Log', /No changes recorded yet|No entries match|^All$/],
];

const DEVELOPER_ONLY = [
  ['System Governance', 'system_governance', 'System Governance', /Order retention/],
  ['System Health', 'system_health', 'System Health', /Read-only data diagnostics/],
  ['Trust & Impact', 'trust_impact', 'Trust & Impact', /evaluated samples/],
];

const SUPERVISOR_PAGES = [
  ['Team Overview', 'dashboard', 'Team Overview', DASHBOARD_MARKER],
  ['My Team', 'my_team', 'My Team', /Visits: \d/],
  ['Action Center', 'team_action_center', 'Action Center', /Outcome review/],
  ['Weekly AI Summary', 'team_ai_summary', 'Weekly AI Summary', /No generated AI data is available|Not generated yet|No weekly AI summary yet/],
  ['Team Orders', 'team_orders', 'Team Orders', 'Status: All'],
  ['Team Visit Logs', 'team_visits', 'Team Visit Logs', /Follow-up/],
  ['Team Activity', 'team_activity', 'Team Activity', 'Live Status'],
  ['Demand Forecast', 'team_forecast', 'Demand Forecast', FORECAST_MARKER],
  ['Reports', 'team_reports', 'Reports', /Reload orders/],
  ['Special Requests', 'special_requests', 'Special Requests', 'Finalised'],
  ['Team Route Planner', 'route_planner', 'Team Route Planner', 'Coverage & health'],
  ['Score Sheets', 'retailer_scoresheets', 'Score Sheets', 'Choose a salesperson'],
  ['Department PIC', 'department_pic', 'Retailer Department PIC', /Add PIC|Retailer-specific contacts/],
  ['Notifications', 'notifications', 'Notifications', NOTIFICATIONS_MARKER],
  ['Privacy Policy', 'privacy_policy', 'Privacy Policy', VERSION_MARKER],
  ['Terms & Conditions', 'terms_conditions', 'Terms & Conditions', VERSION_MARKER],
];

const BRANCH_MANAGER_PAGES = [
  ['Branch Overview', 'dashboard', 'Branch Overview', DASHBOARD_MARKER],
  ['Branch Team', 'my_team', 'Branch Team', /View orders/],
  ['View Team', 'user_directory', 'View Team', 'People'],
  ['Salesman Activity', 'salesman_activity', 'Salesman Activity', 'Live Status'],
  ['Visit Logs', 'visit_logs', 'Visit Logs', /Follow-up/],
  ['Branch Orders', 'all_orders', 'Branch Orders', 'Status: All'],
  ['Purchase Orders', 'purchase_order', 'Purchase Orders', /purchase orders? issued/i],
  ['Forecast', 'prediction', 'Forecast', FORECAST_MARKER],
  ['Branch Routes (view only)', 'route_planner', 'Branch Routes (view only)', 'Coverage & health'],
  ['Branch Reports', 'reports', 'Branch Reports', /Reload orders/],
  ['Special Requests', 'special_requests', 'Special Requests', 'Finalised'],
  ['Score Sheets', 'retailer_scoresheets', 'Score Sheets', 'Choose a salesperson'],
  ['Department PIC', 'department_pic', 'Retailer Department PIC', /Add PIC|Retailer-specific contacts/],
  ['Branch Notifications', 'notifications', 'Branch Notifications', NOTIFICATIONS_MARKER],
  ['Privacy Policy', 'privacy_policy', 'Privacy Policy', VERSION_MARKER],
  ['Terms & Conditions', 'terms_conditions', 'Terms & Conditions', VERSION_MARKER],
];

const NOT_AVAILABLE_PAGES = {
  admin: ['my_team', 'no_such_page', 'backup', 'area', 'option'],
  supervisor: ['permissions', 'branches'],
  branch_manager: ['branches', 'permissions'],
};

const RAIL_CHROME = /(, \d+ pages, (collapsed|expanded)$)|^(Collapse sidebar|Expand sidebar|Sign out|Log out|Logout|Search|Scout|Menu|Open navigation|Close navigation)/i;

async function walkShell(s, role, pages, extras = {}, alsoVisited = [], shellReady = null) {
  const ctx = (label, key) => ({ app: 'dashboard', role, name: label, route: `#/${key}` });
  for (const [label, key, title, marker, options = {}] of pages) {
    await visit(s, ctx(label, key), async () => {
      await dismiss(s.page);
      await navTo(s.page, label);
      await hashIs(s.page, key);
      await dashboardPages.expectContent(s.page, { title, marker });
    }, { ...options, problems: [] });
    const row = rows[rows.length - 1];
    if (extras[label] && row && row.status === 'opened') {
      try {
        await extras[label](s);
      } catch (error) {
        const message = `extra step on ${label} failed: ${short(error.message, 300)}`;
        row.notes.push(message);
        unreachable.push(`dashboard/${role}: ${label} (follow-up screen) - ${message}`);
        await snap(s, `dashboard-${role}-extra-${slug(label)}-FAILED.png`);
        await dismiss(s.page).catch(() => null);
      }
    }
  }
  const labels = (await admin.sidebarLabels(s.page).catch(() => [])).map((l) => l.replace(/, current page$/, ''));
  const missing = pages.map((p) => p[0]).filter((label) => !labels.some((l) => l === label || l.startsWith(label)));
  const unknown = labels.filter((l) => !RAIL_CHROME.test(l) && !pages.some((p) => l === p[0] || l.startsWith(p[0])) && !alsoVisited.includes(l));
  discovery.push({ role, sidebarEntries: labels, expectedButNotInRail: missing, inRailButNotInList: unknown });
  for (const label of unknown) {
    const before = await s.page.evaluate(() => location.hash);
    await visit(s, { app: 'dashboard', role, name: `${label} (found in the rail, not in the list)`, route: '(discovered)' }, async () => {
      await dismiss(s.page);
      await navTo(s.page, label);
      await s.page.waitForTimeout(600);
      const after = await s.page.evaluate(() => location.hash);
      if (after === before) throw new Error('the click did not change the page');
    });
  }
  if (shellReady) await walkUrls(s, role, pages, shellReady);
}

async function openByUrl(page, key, shellReady) {
  await page.evaluate((k) => { location.hash = `#/${k}`; }, key);
  await page.waitForTimeout(300);
  await page.reload({ waitUntil: 'domcontentloaded' });
  await shellReady(page);
}

async function walkUrls(s, role, pages, shellReady) {
  for (const [label, key, title, marker] of pages) {
    await visit(s, { app: 'dashboard', role, name: `${label} (by URL)`, route: `#/${key} + reload` }, async () => {
      await dismiss(s.page).catch(() => null);
      await openByUrl(s.page, key, shellReady);
      await hashIs(s.page, key);
      await dashboardPages.expectContent(s.page, { title, marker });
    }, { settle: 300 });
  }
  for (const key of NOT_AVAILABLE_PAGES[role] || []) {
    await visit(s, { app: 'dashboard', role, name: `Not available: #/${key}`, route: `#/${key} + reload` }, async () => {
      await openByUrl(s.page, key, shellReady);
      await dashboardPages.expectContent(s.page, {
        title: 'Page not available',
        marker: `The address "${key}" is not a page this account can open.`,
      });
    }, { settle: 300 });
  }
}

async function adminExtras(t, s) {
  const page = s.page;
  const meta = (name, route) => ({ app: 'dashboard', role: 'admin', name, route });
  const expandedDashboard = async () => {
    await navTo(page, 'Dashboard');
    await hashIs(page, 'dashboard');
    await visit(s, meta('Command palette', 'Ctrl+K'), async () => { await page.keyboard.press('Control+K'); await page.getByRole('textbox').last().waitFor({ timeout: 8000 }); });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(400);
    await visit(s, meta('Scout panel', 'Scout button'), async () => {
      await page.getByRole('button', { name: /^Scout(?:\s|$)/ }).first().click({ timeout: 8000 });
      await B.see(page, 'Scout panel', { timeout: 8000 });
    });
    await page.keyboard.press('Escape');
    await page.waitForTimeout(500);
  };
  return {
    Dashboard: expandedDashboard,
    'All Orders': async () => {
      await visit(s, meta('Order details dialog (submitted)', 'All Orders > row'), async () => admin.openOrder(page, 'ORD-WALK-001'));
      await dismiss(page);
      await visit(s, meta('Order details dialog (approved)', 'All Orders > row'), async () => {
        await page.getByRole('button', { name: /^(Order )?ORD-WALK-003/ }).first().click({ timeout: 10000 });
        await page.waitForTimeout(800);
      });
      await dismiss(page);
      await page.getByRole('button', { name: /^(Order )?ORD-WALK-001/ }).first().click();
      await page.getByRole('button', { name: 'Approve', exact: true }).waitFor({ timeout: 15000 });
      await admin.approveOpenOrder(page);
      await page.waitForTimeout(1500);
      notes.push('ORD-WALK-001 was approved on All Orders so Purchase Orders has a row.');
    },
    Products: async () => {
      await visit(s, meta('Product form (add)', 'Products > Add product'), async () => {
        await page.getByRole('button', { name: 'Add product' }).click({ timeout: 10000 });
        await page.getByRole('textbox', { name: /^Department/ }).first().waitFor({ timeout: 10000 });
      }, { scroll: 1 });
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
      const cancel = page.getByRole('button', { name: /^(Cancel|Close)$/ }).last();
      if (await cancel.count()) await cancel.click({ timeout: 3000 }).catch(() => null);
      await visit(s, meta('Product form (edit)', 'Products > row'), async () => {
        await page.getByRole('button', { name: new RegExp(`^Product ${escapeRe(PRODUCTS[0].name.slice(0, 20))}`) }).first().click({ timeout: 10000 });
        await page.waitForTimeout(800);
        await page.getByRole('textbox', { name: /^Product\b/ }).first().waitFor({ timeout: 10000 });
      }, { scroll: 1 });
      await page.keyboard.press('Escape');
      await page.waitForTimeout(500);
    },
    'Score Sheets': async () => {
      await admin.pickDropdown(page, 'Choose retailer', RETAILERS[0].name);
      await visit(s, meta('Score sheet editor', 'Score Sheets > retailer'), async () => {
        await page.getByRole('button', { name: 'Save sheet', exact: true }).waitFor({ timeout: 15000 });
      }, { scroll: 1 });
      await visit(s, meta('Score sheet template library', 'Score Sheets > Template library'), async () => {
        await page.getByRole('button', { name: 'Template library', exact: true }).click({ timeout: 10000 });
        await page.waitForTimeout(800);
      }, { scroll: 1 });
      await visit(s, meta('Save sheet as template dialog', 'Template library > Save current sheet as template'), async () => {
        await page.getByRole('button', { name: 'Save current sheet as template', exact: true }).click({ timeout: 10000 });
        await page.getByRole('textbox', { name: 'Template name' }).waitFor({ timeout: 10000 });
      });
      await dismiss(page);
    },
    'Role Assignment': async () => {
      const result = { code: '' };
      await visit(s, meta('Invitation dialog (new salesperson)', 'Role Assignment > Create User'), async () => {
        const dialog = await admin.createUser(page, {
          name: 'Walkthrough Salesperson', code: 'S-WALK', phone: '0123000111', branchName: 'E2E Kuching Branch', keepDialog: true,
        });
        result.code = dialog.code;
      });
      await dismiss(page);
      await page.getByRole('button', { name: 'Done', exact: true }).click({ timeout: 2000 }).catch(() => null);
      await visit(s, meta('Invitations list', 'Role Assignment > Invitations'), async () => admin.openInvitations(page), { scroll: 1 });
    },
    Account: async () => {
      await visit(s, meta('Account (password gate)', '#/account'), async () => {
        await B.see(page, 'Enter your password to see your plan and usage.', { timeout: 15000 });
      });
      await visit(s, meta('Account (plan and usage)', '#/account'), async () => {
        await B.fillField(page, page.locator('input[type="password"]').first(), E.PASSWORD);
        await page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(page, /Plan: /, { timeout: 30000 });
      }, { scroll: 1 });
      await visit(s, meta('Plans (choose a plan)', '#/plans'), async () => {
        await page.getByRole('button', { name: 'Change plan', exact: true }).click({ timeout: 10000 });
        await B.see(page, 'Choose a plan', { timeout: 15000 });
      }, { scroll: 1 });
      await page.waitForTimeout(1500);
      const yearly = page.getByRole('button', { name: 'Yearly', exact: true });
      if (await yearly.count()) {
        await visit(s, meta('Plans (yearly)', '#/plans'), async () => {
          await yearly.click({ timeout: 10000 });
          await page.waitForTimeout(600);
        });
      } else {
        await notApplicableRow(s, meta('Plans (yearly)', '#/plans'), NO_PRICED_PLANS);
      }
    },
  };
}

async function dashboardPart(t) {
  const { accounts } = t;
  const anon = await t.session('admin', { name: 'dashboard-anon' });
  await visit(anon, { app: 'dashboard', role: 'signed-out', name: 'Sign in', route: '/' }, async () => {
    await B.openApp(anon.page, anon.url);
    await anon.page.getByRole('button', { name: /^Sign In$/ }).waitFor({ timeout: 60000 });
  });
  await visit(anon, { app: 'dashboard', role: 'signed-out', name: 'Redeem an invitation', route: '/ > Have an invitation code?' }, async () => {
    await anon.page.getByRole('button', { name: 'Have an invitation code?' }).click({ timeout: 10000 });
    await B.see(anon.page, 'Redeem your invitation');
  });

  const adminS = await t.session('admin', { name: 'dashboard-admin', ...admin.grantClipboard });
  await visit(adminS, { app: 'dashboard', role: 'admin', name: 'Sign in then home', route: '/' }, async () => {
    await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
    await admin.waitForShell(adminS.page);
  });
  await walkShell(adminS, 'admin', ADMIN_PAGES, await adminExtras(t, adminS), [], admin.waitForShell);
  await visit(adminS, { app: 'dashboard', role: 'admin', name: 'Rail click after the rail is scrolled', route: 'rail wheel scroll, mouse click, painted row versus semantics node' }, async () => {
    await openByUrl(adminS.page, 'dashboard', admin.waitForShell);
    const catalogue = adminS.page.getByRole('button', { name: /^Catalogue, \d+ pages, collapsed$/ });
    if (await catalogue.count()) await catalogue.click();
    await adminS.page.waitForTimeout(400);
    await dashboardPages.scrollRailWithWheel(adminS.page, 600);
    await dashboardPages.clickRailEntryWithMouse(adminS.page, 'Coordinate Review');
    await hashIs(adminS.page, 'coordinate_review');
    await dashboardPages.expectRailPaintMatchesSemantics(adminS.page, 'Coordinate Review');
    await dashboardPages.scrollRailWithWheel(adminS.page, 10000);
  });

  const supervisor = await t.session('admin', { name: 'dashboard-supervisor' });
  await visit(supervisor, { app: 'dashboard', role: 'supervisor', name: 'Sign in then home', route: '/' }, async () => {
    await B.loginAdmin(supervisor.page, supervisor.url, accounts.supervisor.email);
    await admin.waitForSupervisorShell(supervisor.page);
  });
  await walkShell(supervisor, 'supervisor', SUPERVISOR_PAGES, {
    'Team Route Planner': async (s) => supervisorRoute(s),
  }, [], admin.waitForSupervisorShell);

  const manager = await t.session('admin', { name: 'dashboard-branch-manager' });
  await visit(manager, { app: 'dashboard', role: 'branch_manager', name: 'Sign in then home', route: '/' }, async () => {
    await B.loginAdmin(manager.page, manager.url, accounts.branchManager.email);
    await admin.waitForBranchManagerShell(manager.page);
  });
  await walkShell(manager, 'branch_manager', BRANCH_MANAGER_PAGES, {
    'Branch Routes (view only)': async (s) => {
      await visit(s, { app: 'dashboard', role: 'branch_manager', name: 'Saved plan (view only)', route: 'Branch Routes > Saved plans > View' }, async () => {
        await s.page.getByRole('button', { name: /^Saved plans/ }).click({ timeout: 10000 });
        await B.see(s.page, /Mobile status:|View only|No saved plans|No mobile progress yet|Published/, { timeout: 15000 });
        const view = s.page.getByRole('button', { name: 'View', exact: true });
        if (await view.count()) {
          await view.first().click();
          await s.page.getByRole('button', { name: 'Plan', exact: true }).click({ timeout: 8000 }).catch(() => null);
        }
      }, { scroll: 1 });
    },
  }, [], admin.waitForBranchManagerShell);

  const developer = await t.session('admin', { name: 'dashboard-developer' });
  await visit(developer, { app: 'dashboard', role: 'developer', name: 'Sign in then home', route: '/' }, async () => {
    await B.loginAdmin(developer.page, developer.url, DEV.email);
    await admin.waitForShell(developer.page);
  });
  await walkShell(developer, 'developer', DEVELOPER_ONLY, {}, ADMIN_PAGES.map((p) => p[0]), admin.waitForShell);
}

async function supervisorRoute(s) {
  const page = s.page;
  const meta = (name, route = 'Team Route Planner') => ({ app: 'dashboard', role: 'supervisor', name, route });
  const weekLabel = async () => {
    const button = page.getByRole('button', { name: /^\d{1,2} [A-Z][a-z]{2} – \d{1,2} [A-Z][a-z]{2}$/ });
    await button.waitFor({ timeout: 10000 });
    return ((await button.getAttribute('aria-label')) || (await button.textContent())).trim();
  };
  await visit(s, meta('Route planner (draft generated)', 'Team Route Planner > Generate draft route'), async () => {
    const before = await weekLabel();
    await page.getByRole('button', { name: 'Previous week' }).click();
    for (let i = 0; i < 50 && (await weekLabel()) === before; i += 1) await page.waitForTimeout(200);
    await page.getByRole('button', { name: 'Generate draft route' }).click();
    await page.getByRole('button', { name: 'Save draft' }).waitFor({ timeout: 60000 });
  }, { scroll: 1 });
  await visit(s, meta('Route planner (draft saved)', 'Team Route Planner > Save draft'), async () => {
    await page.getByRole('button', { name: 'Save draft' }).click();
    await B.see(page, /This is a draft/, { timeout: 30000 });
  });
  await visit(s, meta('Route planner (approved)', 'Team Route Planner > Approve'), async () => {
    await page.getByRole('button', { name: 'Approve', exact: true }).click();
    await B.see(page, /Approved, but not assigned yet|Select Publish to assign/, { timeout: 30000 });
  });
  await visit(s, meta('Publish route dialog', 'Team Route Planner > Publish'), async () => {
    await page.getByRole('button', { name: 'Publish', exact: true }).click();
    await B.see(page, 'Publish this route?', { timeout: 10000 });
  });
  await visit(s, meta('Route planner (published)', 'Team Route Planner > Publish > confirm'), async () => {
    await page.getByRole('button', { name: 'Publish', exact: true }).last().click();
    await B.see(page, /Published and assigned|assigned to/, { timeout: 40000 });
  }, { scroll: 1 });
}

async function tapFirst(page, candidates, timeout = 8000) {
  for (const candidate of candidates) {
    const loc = candidate(page).first();
    if (await loc.count()) {
      await loc.click({ timeout });
      return true;
    }
  }
  return false;
}

async function closeScanner(page) {
  const named = page.getByRole('button', { name: /^(Close|Back)$/ }).first();
  if (await named.count()) await named.click({ timeout: 3000 }).catch(() => null);
  else await page.mouse.click(35, 29);
  await page.waitForTimeout(600);
}

async function phoneAnon(t) {
  const s = await t.session('mobile', { name: 'phone-anon', viewport: mobile.MOBILE_VIEWPORT });
  const meta = (name, route) => ({ app: 'mobile', role: 'signed-out', name, route });
  const page = s.page;
  await visit(s, meta('Login', 'start'), async () => {
    await B.openApp(page, s.url);
    await page.getByRole('button', { name: /^Sign in$/ }).waitFor({ timeout: 60000 });
  }, { scroll: 1 });
  await visit(s, meta('Redeem invitation', 'Login > Have an invitation code?'), async () => {
    await page.getByRole('button', { name: 'I have an invitation code' }).click({ timeout: 10000 });
    await page.locator('input').nth(3).waitFor({ timeout: 20000 });
  });
  await visit(s, meta('Redeem invitation (filled)', 'Redeem invitation'), async () => {
    const inputs = page.locator('input');
    await B.fillField(page, inputs.nth(0), 'ABCD-EFGH-JKLM');
    await B.fillField(page, inputs.nth(1), '1234');
    await B.fillField(page, inputs.nth(2), 'Walkthrough-Pass-123!');
    await B.fillField(page, inputs.nth(3), 'Walkthrough-Pass-123!');
  }, { scroll: 1 });
  await visit(s, meta('Redeem invitation (scanner)', 'Redeem invitation > scan'), async () => {
    const scan = page.getByRole('button', { name: /scan|qr|camera/i }).first();
    if (!(await scan.count())) throw new Error('the redeem screen has no scan button');
    await scan.click({ timeout: 8000 });
    await page.waitForTimeout(800);
  });
  await closeScanner(page);
  await page.getByRole('button', { name: 'Back' }).first().click({ timeout: 3000 }).catch(() => null);
  await page.getByRole('button', { name: /^Sign in$/ }).waitFor({ timeout: 15000 }).catch(() => null);
  for (const [label, heading] of [['Privacy Policy', 'Privacy Policy'], ['Terms & Conditions', 'Terms & Conditions']]) {
    await visit(s, meta(heading, `Login > ${label}`), async () => {
      await page.getByRole('button', { name: label, exact: true }).click({ timeout: 10000 });
      await page.getByRole('button', { name: /^Sign in$/ }).waitFor({ state: 'detached', timeout: 10000 });
      await B.see(page, heading, { timeout: 10000 });
    }, { scroll: 1 });
    await page.getByRole('button', { name: 'Back' }).first().click({ timeout: 3000 }).catch(() => null);
  }
}

async function phonePart(t) {
  const { accounts } = t;
  const retailer = RETAILERS[0];
  const meta = (name, route) => ({ app: 'mobile', role: 'salesperson', name, route });
  await phoneAnon(t);

  const s = await t.session('mobile', { name: 'phone-salesperson', viewport: mobile.MOBILE_VIEWPORT });
  const page = s.page;
  await mobile.installFakeScanner(s);
  await B.fakeGeolocation(s.context, { latitude: retailer.lat, longitude: retailer.lng, accuracy: 10 });
  const published = (await t.db.list('route_plans')).find((p) => p.status === 'published' && p.salesmanCode === accounts.salesman.code);
  if (published) await mobile.routeDayForSunday(t.db, published.id);
  await visit(s, meta('Sign in then Home', 'Login'), async () => {
    await B.loginMobile(page, s.url, accounts.salesman.email);
    await mobile.waitForHome(page);
  }, { scroll: 2, settle: 2500 });

  await visit(s, meta('Scout sheet', 'Home > Open Scout'), async () => {
    await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click({ timeout: 8000 });
    await page.getByRole('textbox', { name: /Ask or say a command/ }).waitFor({ timeout: 10000 });
  });
  await page.keyboard.press('Escape');
  await mobile.reopenHome(page, s.url);

  await visit(s, meta('Planner', 'Home > Planner'), async () => {
    await page.getByRole('button', { name: 'Planner', exact: true }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Add Visit', exact: true }).waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Planner: add a visit', 'Planner > Add Visit'), async () => {
    await page.getByRole('button', { name: 'Add Visit', exact: true }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Save plan' }).waitFor({ timeout: 15000 });
  });
  await mobile.reopenHome(page, s.url);
  await visit(s, meta('Home with a personal plan for today', 'Planner > Save Plan'), async () => {
    await mobile.planVisitToday(page, RETAILERS[1].name, 'Walkthrough visit');
    await page.getByRole('button', { name: new RegExp(`^Personal plan[^]*${escapeRe(RETAILERS[1].name)}`) }).waitFor({ timeout: 20000 });
  }, { scroll: 1 });

  const done = await draftSegment(t, s);
  if (!done) await mobile.reopenHome(page, s.url).catch(() => null);

  await routeSegment(t, s);
  await mobile.reopenHome(page, s.url).catch(() => null);

  await historyProfileSegment(t, s);
}

async function selectOneProduct(page) {
  const dept = PRODUCTS[0].dept;
  await page.locator(`[aria-label="${dept}"]`).first().click({ timeout: 10000 });
  await page.getByRole('checkbox', { name: new RegExp(`^(?:[^\\n·]+ · )?${escapeRe(PRODUCTS[0].name)}`) }).click({ timeout: 10000 });
}

async function draftSegment(t, s) {
  const page = s.page;
  const meta = (name, route) => ({ app: 'mobile', role: 'salesperson', name, route });
  s.chain = true;
  s.chainBroken = false;
  await visit(s, meta('Catalogue: select products (planned visit)', 'Home > Personal plan card'), async () => {
    await mobile.openPlannedVisit(page, RETAILERS[1].name);
    await page.locator(`[aria-label="${PRODUCTS[0].dept}"]`).first().waitFor({ timeout: 20000 });
  }, { scroll: 1 });
  await visit(s, meta('Catalogue: department expanded', 'Select > department'), async () => {
    await selectOneProduct(page);
    await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).waitFor({ timeout: 10000 });
  }, { scroll: 1 });
  await visit(s, meta('Barcode scanner', 'Select > Scan barcode'), async () => {
    await page.getByRole('button', { name: 'Scan barcode', exact: true }).click({ timeout: 10000 });
    await page.waitForFunction(() => typeof window.deliverScan === 'function', null, { timeout: 15000 });
  });
  await closeScanner(page);
  await visit(s, meta('Cart: selected items summary', 'Select > Add to Cart'), async () => {
    await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Start counting' }).waitFor({ timeout: 10000 });
  });
  await visit(s, meta('Cart: count and quantities', 'Select > Start counting'), async () => {
    await page.getByRole('button', { name: 'Start counting' }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Continue to Signature' }).waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Order signature (before saving a draft)', 'Cart > Continue to Signature'), async () => {
    await mobile.continueToSignature(page);
    await page.getByRole('button', { name: 'Save Draft', exact: true }).waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Draft saved', 'Signature > Save Draft'), async () => {
    await page.getByRole('button', { name: 'Save Draft', exact: true }).click({ timeout: 10000 });
    await B.see(page, /Draft saved/, { timeout: 15000 });
  });
  const ok = !s.chainBroken;
  s.chain = false;
  s.chainBroken = false;
  return ok;
}

async function routeSegment(t, s) {
  const page = s.page;
  const retailer = RETAILERS[0];
  const meta = (name, route) => ({ app: 'mobile', role: 'salesperson', name, route });
  s.chain = true;
  s.chainBroken = false;
  await mobile.reopenHome(page, s.url);
  await visit(s, meta('Assigned route (today)', 'Home > Assigned route'), async () => {
    await mobile.openAssignedRoute(page);
  }, { scroll: 1 });
  await visit(s, meta('Assigned route (week)', 'Assigned route > Week'), async () => {
    await B.semantic(page, /^Week$/).click({ timeout: 10000 });
    await B.see(page, retailer.name, { timeout: 10000 });
  }, { scroll: 1 });
  await visit(s, meta('Assigned route (started)', 'Assigned route > Accept route, Start route'), async () => {
    await mobile.acceptAndStartRoute(page);
    await page.waitForTimeout(1200);
  }, { scroll: 1 });
  await visit(s, meta('Assigned route (stop selected)', 'Assigned route > Go to this stop'), async () => {
    await mobile.selectStop(page);
  }, { scroll: 1 });
  await visit(s, meta('Assigned route (arrived)', 'Assigned route > Mark arrived'), async () => {
    const stopRetailer = RETAILERS.find((r) => r.name === 'Emart Moyan') || retailer;
    await B.moveDevice(page, { latitude: stopRetailer.lat, longitude: stopRetailer.lng, accuracy: 10 });
    await mobile.markArrived(page);
    try {
      await B.see(page, 'Arrival: GPS verified', { timeout: 30000 });
    } catch (error) {
      const dump = {};
      for (const collection of ['route_stop_progress', 'route_plan_progress']) dump[collection] = await t.db.list(collection).catch((e) => String(e));
      fs.writeFileSync(path.join(OUT, 'arrival-diagnostics.json'), JSON.stringify(dump, null, 2));
      throw error;
    }
  }, { scroll: 1 });
  await visit(s, meta('Guided visit (prepare)', 'Assigned route > Open visit'), async () => {
    const open = page.getByRole('button', { name: 'Open visit', exact: true }).first();
    await B.scrollIntoView(page, open, { minHeight: 20, pointerY: 0.8 });
    await open.click();
    await B.see(page, 'Continue to sell', { timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Guided visit (sell)', 'Guided visit > Continue to sell'), async () => {
    await page.getByRole('button', { name: 'Continue to sell', exact: true }).click({ timeout: 15000 });
    await page.getByRole('button', { name: /^(Start order|Resume order)$/ }).waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Catalogue: select products (guided visit)', 'Guided visit > Start order'), async () => {
    await page.getByRole('button', { name: /^(Start order|Resume order)$/ }).click({ timeout: 10000 });
    await page.locator(`[aria-label="${PRODUCTS[0].dept}"]`).first().waitFor({ timeout: 20000 });
  });
  await visit(s, meta('Catalogue: department expanded (guided visit)', 'Select > department'), async () => {
    await selectOneProduct(page);
    await page.getByRole('button', { name: /^Add to Cart \(1\)/ }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Start counting' }).waitFor({ timeout: 10000 });
  }, { scroll: 1 });
  await visit(s, meta('Order cart', 'Select > Start counting'), async () => {
    await page.getByRole('button', { name: 'Start counting' }).click({ timeout: 10000 });
    await page.getByRole('button', { name: 'Continue to Signature' }).waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Order signature', 'Cart > Continue to Signature'), async () => {
    await mobile.continueToSignature(page);
    await page.getByRole('button', { name: 'Select Ordered Batch Expiry' }).first().waitFor({ timeout: 15000 });
  }, { scroll: 1 });
  let orderId = '';
  await visit(s, meta('Order confirmation', 'Signature > Submit Order'), async () => {
    orderId = await mobile.signAndSubmit(page, PRODUCTS[0].dept, 1);
  });
  if (orderId) notes.push(`The phone submitted order ${orderId} through the guided visit.`);
  const back = await tapFirst(page, [
    (p) => p.getByRole('button', { name: /^(Done|Back to home|Return home|Home|Continue|Back to visit|Close)/i }),
  ]).catch(() => false);
  if (!back) await page.getByRole('button', { name: 'Back' }).first().click({ timeout: 3000 }).catch(() => null);
  await visit(s, meta('Guided visit (close)', 'Order confirmation > back'), async () => {
    const proceed = page.getByRole('button', { name: /^(Continue to close|Complete stop)$/ }).first();
    await proceed.waitFor({ timeout: 20000 });
    const proceedLabel = (await proceed.getAttribute('aria-label')) || (await proceed.textContent()) || '';
    if (/Continue to close/.test(proceedLabel)) {
      await proceed.click();
      await page.getByRole('button', { name: 'Complete stop' }).waitFor({ timeout: 15000 });
    }
  }, { scroll: 1 });
  s.chain = false;
  s.chainBroken = false;
}

async function historyProfileSegment(t, s) {
  const page = s.page;
  const meta = (name, route) => ({ app: 'mobile', role: 'salesperson', name, route });
  await visit(s, meta('Order history', 'Home > History'), async () => {
    await mobile.openTab(page, 'Orders');
    await B.see(page, /ORD-WALK-001/, { timeout: 20000 });
  }, { scroll: 1 });
  await visit(s, meta('Order history: open an order', 'Order history > row'), async () => {
    await page.getByRole('button', { name: /ORD-WALK-001/ }).first().click({ timeout: 10000 });
    await page.waitForTimeout(1500);
  }, { scroll: 1 });
  await mobile.reopenHome(page, s.url).catch(() => null);
  await visit(s, meta('Profile', 'Home > Profile'), async () => {
    await mobile.openTab(page, 'Profile');
    await B.see(page, accountsEmail(t), { timeout: 20000 });
  }, { scroll: 2 });
  await visit(s, meta('My visits', 'Profile > My visits'), async () => {
    await page.getByRole('button', { name: /My visits/ }).first().click({ timeout: 10000 });
    await B.see(page, 'My visits', { timeout: 15000 });
  }, { scroll: 1 });
  await mobile.goBack(page).catch(() => null);
  await visit(s, meta('Edit profile', 'Profile > edit'), async () => {
    await page.waitForTimeout(800);
    const editButton = page.getByRole('button', { name: /^Edit profile/i });
    if (await editButton.count()) await editButton.first().click();
    else await page.mouse.click(mobile.MOBILE_VIEWPORT.width - 38, 28);
    await B.see(page, 'Edit profile', { timeout: 15000 });
  }, { scroll: 1 });
  await visit(s, meta('Edit profile: change email dialog', 'Edit profile > Change (email)'), async () => {
    await page.getByRole('button', { name: /^(Change|Add)$/ }).first().click({ timeout: 10000 });
    await B.see(page, 'New Email Address', { timeout: 10000 });
  });
  await dismissPhone(page);
  await visit(s, meta('Edit profile: change phone dialog', 'Edit profile > Change (phone)'), async () => {
    await page.getByRole('button', { name: /^(Change|Add)$/ }).last().click({ timeout: 10000 });
    await B.see(page, 'New Phone Number', { timeout: 10000 });
  });
  await dismissPhone(page);
  await notApplicableRow(s, meta('Edit profile: photo options', 'Edit profile > photo'), NOT_ON_WEB);
}

function accountsEmail(t) {
  return t.accounts.salesman.email;
}

async function dismissPhone(page) {
  const cancel = page.getByRole('button', { name: 'Cancel', exact: true }).last();
  if (await cancel.count()) await cancel.click({ timeout: 3000 }).catch(() => null);
  else await page.keyboard.press('Escape').catch(() => null);
  await page.waitForTimeout(500);
}

async function serveFolder(root) {
  const MIME = {
    '.html': 'text/html; charset=utf-8', '.js': 'text/javascript; charset=utf-8', '.json': 'application/json; charset=utf-8',
    '.css': 'text/css; charset=utf-8', '.png': 'image/png', '.wasm': 'application/wasm', '.ico': 'image/x-icon',
    '.ttf': 'font/ttf', '.otf': 'font/otf', '.woff2': 'font/woff2',
  };
  const base = path.resolve(root);
  const server = http.createServer((req, res) => {
    const url = decodeURIComponent(req.url.split('?')[0]);
    let file = path.join(base, url);
    if (!file.startsWith(base) || !fs.existsSync(file) || fs.statSync(file).isDirectory()) file = path.join(base, 'index.html');
    res.writeHead(200, { 'Content-Type': MIME[path.extname(file)] || 'application/octet-stream', 'Cache-Control': 'no-store' });
    fs.createReadStream(file).pipe(res);
  });
  await new Promise((resolve) => server.listen(0, '127.0.0.1', resolve));
  return { url: `http://127.0.0.1:${server.address().port}`, stop: () => new Promise((resolve) => server.close(resolve)) };
}

function newestSource(dir) {
  let newest = 0;
  const walk = (folder) => {
    for (const entry of fs.readdirSync(folder, { withFileTypes: true })) {
      const full = path.join(folder, entry.name);
      if (entry.isDirectory()) walk(full);
      else if (entry.name.endsWith('.dart')) newest = Math.max(newest, fs.statSync(full).mtimeMs);
    }
  };
  walk(dir);
  return newest;
}

function ensureControlBuild() {
  const app = path.join(platform.ROOT, 'admin_dashboard');
  const name = process.env.WALKTHROUGH_CONTROL_BUILD || 'web_control_e2e';
  const dir = path.join(app, 'build', name);
  const built = path.join(dir, 'main.dart.js');
  const stale = !fs.existsSync(built) || fs.statSync(built).mtimeMs < newestSource(path.join(app, 'lib'));
  if (!process.env.WALKTHROUGH_CONTROL_BUILD && (stale || process.env.WALKTHROUGH_REBUILD_CONTROL === '1')) {
    console.log('  building the Control Centre (lib/control_centre/main.dart) ...');
    const r = spawnSync('flutter', ['build', 'web', '--release', '--no-web-resources-cdn', '-t', 'lib/control_centre/main.dart',
      '--no-pub', '--dart-define=USE_FIREBASE_EMULATOR=true',
      '--dart-define=FIREBASE_EMULATOR_HOST=127.0.0.1', '--dart-define=FIRESTORE_EMULATOR_PORT=8089',
      '--dart-define=FIREBASE_AUTH_EMULATOR_PORT=9099',
      `--dart-define=PLATFORM_PUBLIC_KEYS=${platform.publicKeysText(platform.ensureKey())}`,
      `--dart-define=PLATFORM_API_URL=${platform.PLATFORM_API_URL}`,
      '--output', `build/${name}`], { cwd: app, stdio: 'inherit', shell: process.platform === 'win32', windowsHide: true });
    if (r.status !== 0) throw new Error(`Control Centre build failed (exit ${r.status})`);
  }
  if (!fs.existsSync(path.join(dir, 'index.html'))) throw new Error(`Control Centre build missing at ${dir}`);
  return dir;
}

const CONTROL_NAV_CHROME = /^(Collapse|Expand|Sign out|Log out|Menu)/i;

async function controlPart(t) {
  const key = platform.ensureKey();
  const harness = platform.harnessRecord();
  const record = { ...harness, location: { ...harness.location, projectId: 'demo-control-tenant' } };
  await directory.resetDirectory();
  directory.seedDirectory([key], [{ record, key }]);
  try {
    directory.planAdmin([key], [{ op: 'catalogue' }, { op: 'usage' }]);
  } catch (error) {
    notes.push(`The public package catalogue could not be seeded for the Control Centre (${short(error.message, 300)}).`);
  }
  const platformDb = E.client(directory.PLATFORM_PROJECT);
  const buildDir = ensureControlBuild();
  const site = await serveFolder(buildDir);
  const sink = await startMailSink();
  await sink.clear();
  const seenCodeMails = new Set();
  let service;
  try {
    service = await staff.startStaffApi(key, { browserSignIn: true });
  } catch (error) {
    notes.push(`The Control Centre part was skipped (${short(error.message, 300)}).`);
    await sink.close();
    await site.stop().catch(() => null);
    return;
  }
  const button = (s, name) => s.page.getByRole('button', { name, exact: true });
  const open = async (role) => {
    const s = await t.session('admin', { name: `control-${role}` });
    s.controlUrl = site.url;
    await s.context.route('**/staff/v1/**', async (route) => {
      const request = route.request();
      const response = await route.fetch({ url: `${service.url}${new URL(request.url()).pathname}${new URL(request.url()).search}`,
        headers: { ...request.headers(), host: new URL(site.url).host } });
      return route.fulfill({ response });
    });
    await B.openApp(s.page, site.url);
    await staff.signInControlCentre(s.page, staff.STAFF_ROLE_EMAILS[role], sink, seenCodeMails);
    return s;
  };
  const walkNav = async (s, role, known) => {
    const labels = (await admin.sidebarLabels(s.page, { railWidth: 320 }).catch(() => [])).filter((l) => !CONTROL_NAV_CHROME.test(l));
    const unknown = labels.filter((l) => !known.includes(l) && l !== record.legalName);
    discovery.push({ role: `control-${role}`, sidebarEntries: labels, expectedButNotInRail: known.filter((k) => !labels.includes(k)), inRailButNotInList: unknown });
    for (const label of unknown) {
      await visit(s, { app: 'control', role, name: `${label} (found in navigation, not in the list)`, route: '(discovered)' }, async () => {
        await button(s, label).click({ timeout: 8000 });
        await s.page.waitForTimeout(800);
      }, { scroll: 1 });
    }
  };
  const meta = (role, name, route) => ({ app: 'control', role, name, route });
  try {
    await platformDb.put('plan_requests', 'req_walkthrough', { tenantId: directory.HARNESS_TENANT, planId: 'ENTERPRISE', interval: 'yearly',
      status: 'requested', requestedBy: 'client-admin-uid', createdAt: new Date() });

    const api = async (who, method, route, body, idempotencyKey) => {
      const response = await fetch(`${service.url}/staff/v1${route}`, { method,
        headers: { 'Content-Type': 'application/json', ...service.headers(who),
          Origin: service.url, 'Sec-Fetch-Site': 'same-origin', ...(idempotencyKey ? { 'Idempotency-Key': idempotencyKey } : {}) },
        body: body === undefined ? undefined : JSON.stringify(body) });
      const text = await response.text();
      if (!response.ok) throw new Error(`${method} ${route} -> ${response.status} ${text}`);
      return text ? JSON.parse(text) : {};
    };
    await api('operator', 'POST', `/companies/${directory.HARNESS_TENANT}/package`,
      { planId: 'STANDARD', billingInterval: 'monthly', expectedRevision: 0, reason: 'Walkthrough package' }, 'walkthrough-package-0001');
    const quoteAsk = await api('operator', 'POST', '/approvals', { action: 'quote.price', tenantId: directory.HARNESS_TENANT,
      reason: 'Walkthrough agreed price', params: { amountMinor: 500000, billingInterval: 'monthly' } }, 'walkthrough-quote-ask-0001');
    await api('owner', 'POST', `/approvals/${quoteAsk.approvalId}/approve`);
    const draft = await api('operator', 'POST', `/companies/${directory.HARNESS_TENANT}/invoices`, {}, 'walkthrough-invoice-0001');
    await api('operator', 'POST', `/invoices/${draft.invoiceId}/issue`);

    const op = await open('operator');
    await visit(op, meta('operator', 'Inbox', 'Inbox'), async () => {
      await op.page.getByText('Control Centre', { exact: true }).first().waitFor({ timeout: 30000 });
      await op.page.getByText(staff.STAFF_ROLE_EMAILS.operator, { exact: false }).first().waitFor({ timeout: 15000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Companies', 'Companies'), async () => {
      await button(op, 'Companies').click({ timeout: 10000 });
      await op.page.getByRole('button', { name: new RegExp(`^${record.legalName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}, workspace`) }).waitFor({ timeout: 20000 });
    });
    await visit(op, meta('operator', 'Company page', 'Companies > company'), async () => {
      await op.page.getByRole('button', { name: new RegExp(`^${record.legalName.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}, workspace`) }).click({ timeout: 10000 });
      await op.page.getByText('Subscription', { exact: true }).first().waitFor({ timeout: 25000 });
    }, { scroll: 2 });
    await visit(op, meta('operator', 'Record payment form', 'Company > Record payment'), async () => {
      await op.page.getByRole('button', { name: 'Record payment', exact: true }).first().click({ timeout: 10000 });
      await op.page.getByRole('textbox', { name: 'Bank reference', exact: true }).waitFor({ timeout: 10000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Payment ledger with an entry', 'Record payment > Record payment'), async () => {
      await B.fillField(op.page, op.page.getByRole('textbox', { name: 'Bank reference', exact: true }), 'WALK/BANK-001');
      await B.fillField(op.page, op.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Bank statement checked');
      await op.page.getByRole('button', { name: 'Record payment', exact: true }).last().click();
      await op.page.getByText('Bank ref WALK/BANK-001', { exact: false }).first().waitFor({ timeout: 30000 });
    }, { scroll: 2 });
    await visit(op, meta('operator', 'Change status form', 'Company > More > Change status'), async () => {
      await op.page.getByRole('button', { name: 'More actions' }).click({ timeout: 10000 });
      await op.page.getByRole('menuitem', { name: 'Change status…' }).click({ timeout: 10000 });
      await op.page.getByRole('textbox', { name: 'Reason', exact: true }).waitFor({ timeout: 10000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Status changed to active', 'Change status > Apply change'), async () => {
      await admin.chooseOption(op.page, 'New status', 'Active');
      await admin.pickDropdown(op.page, 'Payment that covers today', /RM /);
      await B.fillField(op.page, op.page.getByRole('textbox', { name: 'Reason', exact: true }), 'Coverage verified for activation');
      await button(op, 'Apply change').click();
      await button(op, 'Apply change').waitFor({ state: 'detached', timeout: 30000 });
      await op.page.getByText('Active', { exact: true }).first().waitFor({ timeout: 30000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Change package form', 'Company > More > Change package'), async () => {
      await op.page.getByRole('button', { name: 'More actions' }).click({ timeout: 10000 });
      await op.page.getByRole('menuitem', { name: 'Change package…' }).click({ timeout: 10000 });
      await op.page.getByRole('button', { name: /^Package\b/ }).first().waitFor({ timeout: 15000 });
    }, { scroll: 1 });
    await dismiss(op.page);
    await visit(op, meta('operator', 'Invoices', 'Invoices'), async () => {
      await button(op, 'Invoices').first().click({ timeout: 10000 });
      await op.page.getByText(/INV-/).first().waitFor({ timeout: 25000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Payments', 'Payments'), async () => {
      await op.page.getByRole('button', { name: /^Payments\b/ }).first().click({ timeout: 10000 });
      await op.page.getByText(/WALK\/BANK-001/).first().waitFor({ timeout: 25000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Onboarding', 'Onboarding'), async () => {
      await button(op, 'Onboarding').click({ timeout: 10000 });
      await op.page.getByText('Onboarding', { exact: true }).first().waitFor({ timeout: 15000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Packages', 'Packages'), async () => {
      await button(op, 'Packages').click({ timeout: 10000 });
      await op.page.getByText('Standard', { exact: false }).first().waitFor({ timeout: 25000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'Audit log', 'Audit log'), async () => {
      await button(op, 'Audit log').click({ timeout: 10000 });
      await op.page.getByText('Audit log', { exact: true }).first().waitFor({ timeout: 25000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'New company form', 'Companies > Add company'), async () => {
      await button(op, 'Companies').click({ timeout: 10000 });
      await button(op, 'Add company').click({ timeout: 10000 });
      await op.page.getByRole('textbox', { name: 'Company name', exact: true }).waitFor({ timeout: 15000 });
    }, { scroll: 1 });
    await visit(op, meta('operator', 'New company: package menu', 'Add company > Package'), async () => {
      await op.page.getByRole('button', { name: /^Package\b/ }).first().click({ timeout: 10000 });
      await op.page.getByRole('menuitem').first().waitFor({ timeout: 10000 });
    });
    await op.page.keyboard.press('Escape');
    const NAV = ['Inbox', 'Companies', 'Onboarding', 'Invoices', 'Payments', 'Packages', 'Audit log', 'Staff and access', 'Settings'];
    await walkNav(op, 'operator', NAV);

    const owner = await open('owner');
    await visit(owner, meta('owner', 'Inbox', 'Inbox'), async () => {
      await owner.page.getByText(staff.STAFF_ROLE_EMAILS.owner, { exact: false }).first().waitFor({ timeout: 30000 });
    });
    await visit(owner, meta('owner', 'Payments to check', 'Payments'), async () => {
      await owner.page.getByRole('button', { name: /^Payments\b/ }).first().click({ timeout: 10000 });
      await owner.page.getByText(/WALK\/BANK-001/).first().waitFor({ timeout: 25000 });
    }, { scroll: 1 });
    await visit(owner, meta('owner', 'Staff and access', 'Staff and access'), async () => {
      await button(owner, 'Staff and access').click({ timeout: 10000 });
      await owner.page.getByText('What each role can do', { exact: true }).waitFor({ timeout: 15000 });
    });
    await visit(owner, meta('owner', 'Settings', 'Settings'), async () => {
      await button(owner, 'Settings').click({ timeout: 10000 });
      await owner.page.getByText('Billing rules', { exact: true }).waitFor({ timeout: 15000 });
    });
    await walkNav(owner, 'owner', NAV);

    const support = await open('support');
    await visit(support, meta('support', 'Restricted view', 'Restricted view'), async () => {
      await button(support, 'Support').waitFor({ timeout: 30000 });
      await support.page.getByRole('button', { name: /^Account menu/ }).first().click();
      await support.page.getByRole('menuitem', { name: 'My account', exact: true }).waitFor({ timeout: 15000 });
      await support.page.keyboard.press('Escape');
      if (await button(support, 'Companies').count()) throw new Error('support sees the Companies page');
    });
  } finally {
    await service.stop().catch(() => null);
    await sink.close();
    await site.stop().catch(() => null);
  }
}

function writeReport() {
  const trailing = [];
  for (const [s, st] of sessionState) {
    const seen = drain(s);
    if (seen.consoleErrors.length || seen.flutterExceptions.length) trailing.push({ session: s.name || s.app, ...seen });
    fs.writeFileSync(path.join(OUT, `console-${slug(s.name || s.app)}-${sessionList.indexOf(s)}.log`),
      [...st.all, ...(s.blocked.length ? ['blocked external requests:', ...s.blocked.map((u) => `  ${u}`)] : [])].join('\n'));
  }
  const totals = {
    pages: rows.length,
    opened: rows.filter((r) => r.status === 'opened').length,
    notApplicable: rows.filter((r) => r.status === 'NOT APPLICABLE').length,
    unreachable: rows.filter((r) => r.status === 'UNREACHABLE' || r.status === 'NOT REACHED').length,
    withConsoleErrors: rows.filter((r) => r.consoleErrors.length).length,
    withFlutterExceptions: rows.filter((r) => r.flutterExceptions.length).length,
    withBlockedRequests: rows.filter((r) => r.blockedRequests.length).length,
    withFailedRequests: rows.filter((r) => r.failedRequests.length).length,
    withPlaceholderText: rows.filter((r) => r.placeholderText.length).length,
    withVisibleErrorText: rows.filter((r) => r.visibleErrorText.length).length,
  };
  const report = {
    generatedAt: new Date().toISOString(), fonts: process.env.E2E_ALLOW_FONTS === '1' ? 'real web fonts allowed (fonts.gstatic.com, fonts.googleapis.com only)' : 'blocked (boxes for glyphs)',
    strict: STRICT, totals, notes, unreachable, notApplicable: notApplicablePages, navigation: discovery, trailingConsole: trailing, pages: rows,
  };
  fs.writeFileSync(path.join(OUT, 'report.json'), JSON.stringify(report, null, 2));

  const cell = (text) => String(text).replace(/\|/g, '\\|').replace(/\r?\n/g, ' ');
  const list = (items) => (items.length ? items.map((x) => cell(short(x, 140))).join('<br>') : '');
  const md = [];
  md.push('# Visual walkthrough report', '');
  md.push(`Generated ${report.generatedAt}. Fonts: ${report.fonts}.`, '');
  md.push(`Pages recorded: ${totals.pages}. Opened: ${totals.opened}. Not applicable: ${totals.notApplicable}. Not opened: ${totals.unreachable}. With console errors: ${totals.withConsoleErrors}. With Flutter exceptions: ${totals.withFlutterExceptions}. With blocked requests: ${totals.withBlockedRequests}. With failed requests: ${totals.withFailedRequests}. With placeholder text: ${totals.withPlaceholderText}. With visible error text: ${totals.withVisibleErrorText}.`, '');
  if (notes.length) md.push('## Setup notes', '', ...notes.map((n) => `- ${n}`), '');
  if (unreachable.length) md.push('## Pages that could not be opened', '', ...unreachable.map((u) => `- ${u}`), '');
  if (notApplicablePages.length) md.push('## Not applicable', '', ...notApplicablePages.map((u) => `- ${u}`), '');
  md.push('## Pages', '', '| # | App | Role | Page | Route | Screenshot | Console errors | Flutter exceptions | Blocked requests | Failed requests | Placeholder text | Visible error text | Notes |', '|---|---|---|---|---|---|---|---|---|---|---|---|---|');
  for (const r of rows) {
    const shot = r.screenshot ? `[${path.basename(r.screenshot)}](${r.screenshot})` : '';
    const more = r.extraScreenshots.map((x) => `[+](${x})`).join(' ');
    md.push(`| ${r.n} | ${r.app} | ${r.role} | ${cell(r.page)}${r.status === 'opened' ? '' : ` **${r.status}**`} | ${cell(r.route)} | ${shot} ${more} | ${list(r.consoleErrors)} | ${list(r.flutterExceptions)} | ${list(r.blockedRequests)} | ${list(r.failedRequests)} | ${list(r.placeholderText)} | ${list(r.visibleErrorText)} | ${list([...(r.error ? [r.error] : []), ...r.notes])} |`);
  }
  md.push('');
  const failed = (r) => r.status === 'UNREACHABLE' || r.status === 'NOT REACHED';
  const problems = rows.filter((r) => failed(r) || r.consoleErrors.length || r.failedRequests.length || r.flutterExceptions.length || r.placeholderText.length || r.visibleErrorText.length || r.notes.length);
  md.push('## Problems seen', '');
  if (!problems.length) md.push('None recorded.');
  for (const r of problems) {
    md.push(`### ${r.n}. ${r.app} / ${r.role}: ${r.page}`, '', `Screenshot: ${r.screenshot || '(none)'}`, '');
    if (r.status !== 'opened') md.push(`- ${r.status}: ${r.error}`);
    for (const x of r.flutterExceptions) md.push(`- Flutter exception: ${x}`);
    for (const x of r.consoleErrors) md.push(`- Console error: ${x}`);
    for (const x of r.failedRequests) md.push(`- Failed request: ${x}`);
    for (const x of r.placeholderText) md.push(`- Placeholder text: ${x}`);
    for (const x of r.visibleErrorText) md.push(`- Visible error text: ${x}`);
    for (const x of r.notes) md.push(`- ${x}`);
    md.push('');
  }
  md.push('## Navigation found per role', '');
  for (const d of discovery) {
    md.push(`### ${d.role}`, '', `- Rail entries: ${d.sidebarEntries.join(', ') || '(none read)'}`);
    md.push(`- Expected but not in the rail: ${d.expectedButNotInRail.join(', ') || 'none'}`);
    md.push(`- In the rail but not in the visited list (visited by discovery): ${d.inRailButNotInList.join(', ') || 'none'}`, '');
  }
  if (trailing.length) {
    md.push('## Console output after the last page of a session', '');
    for (const x of trailing) md.push(`- ${x.session}: ${x.consoleErrors.length} error(s), ${x.flutterExceptions.length} Flutter exception(s)`);
    md.push('');
  }
  fs.writeFileSync(path.join(OUT, 'report.md'), md.join('\n'));
  return totals;
}

const sessionList = [];

module.exports = {
  name: 'walkthrough',
  platformScheduler: true,
  async run(t) {
    fs.rmSync(OUT, { recursive: true, force: true });
    fs.mkdirSync(SHOTS, { recursive: true });
    for (const list of [rows, unreachable, notApplicablePages, discovery, notes, sessionList]) list.length = 0;
    sessionState.clear();
    counter = 0;
    const hadFonts = Object.hasOwn(process.env, 'E2E_ALLOW_FONTS');
    if (!hadFonts) process.env.E2E_ALLOW_FONTS = '1';
    const originalSession = t.session;
    t.session = async (...args) => {
      const s = await originalSession(...args);
      s.name = (args[1] && args[1].name) || args[0];
      s.page.on('requestfailed', (request) => {
        s.logs.push(`[${s.name}] requestfailed: ${request.method()} ${request.url()} ${request.failure()?.errorText || ''}`);
      });
      sessionList.push(s);
      return s;
    };
    try {
      await t.step('seed orders, visits, a request, a live position, a developer and a plan', async () => {
        await seedData(t);
        seedPlan(platform.ensureKey());
      });
      if (ONLY.includes('dashboard')) await t.step('dashboard: every role, every page and dialog', () => dashboardPart(t));
      if (ONLY.includes('mobile')) await t.step('phone: every screen as a salesperson', () => phonePart(t));
      if (ONLY.includes('control')) await t.step('Control Centre: owner, operator and support', () => controlPart(t));
    } finally {
      if (!hadFonts) delete process.env.E2E_ALLOW_FONTS;
      const totals = writeReport();
      console.log(`  walkthrough: ${totals.opened}/${totals.pages} pages opened, report in ${path.relative(process.cwd(), OUT)}`);
    }
    if (unreachable.length) {
      throw new Error(`${unreachable.length} page(s) could not be opened:\n${unreachable.map((u) => `  - ${u}`).join('\n')}`);
    }
  },
};
