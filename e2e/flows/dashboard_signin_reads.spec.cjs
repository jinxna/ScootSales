'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putMany } = require('../lib/bulk.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'dashboard_signin_reads');
const BULK_RETAILERS = 1000;
const EXTRA_SALESMEN = 40;
const OLD_VISITS = 498;
const READ_BUDGET = 3000;
const DIRECTORY_LIMIT = 2000;
const EXTRA_RETAILERS = 1100;
const KEY_SLACK = 30;
const LATE_INDEX = 2050;
const LOOKUP_SLACK = 100;
const DAY_MS = 24 * 3600e3;
const QUIET_MS = 6000;
const SETTLE_LIMIT_MS = 120000;

const pad = (n, w = 4) => String(n).padStart(w, '0');
const bulkId = (i) => `ret-bulk-${pad(i)}`;
const bulkName = (i) => `Bulk Shop ${pad(i)}`;
const staleName = (i) => `Stale Name ${pad(i)}`;
const salesCode = (i) => `S${200 + i}`;
const LATE_SHOP = `ret-bulk-${pad(LATE_INDEX)}`;

function expect(condition, what) {
  if (!condition) throw new Error(what);
}

function firestorePort() {
  const host = process.env.FIRESTORE_EMULATOR_HOST || '';
  return host.split(':').pop() || String(process.env.FIRESTORE_EMULATOR_PORT || 8089);
}

async function meterReads(session) {
  const port = firestorePort();
  const cdp = await session.context.newCDPSession(session.page);
  await cdp.send('Network.enable');
  const meter = { docs: 0, byCollection: {}, firestore: new Set(), streamed: new Set(), changedAt: Date.now() };
  const docName = /"documentChange":\{"document":\{"name":"[^"]*?\/documents\/([^"/]+)\//g;
  const count = (base64) => {
    const text = Buffer.from(base64, 'base64').toString('utf8');
    const changes = (text.match(/"documentChange"/g) || []).length;
    for (const match of text.matchAll(docName)) {
      meter.byCollection[match[1]] = (meter.byCollection[match[1]] || 0) + 1;
    }
    if (changes > 0) {
      meter.docs += changes;
      meter.changedAt = Date.now();
    }
  };
  cdp.on('Network.requestWillBeSent', (e) => {
    try {
      const url = new URL(e.request.url);
      if (url.port === port && url.pathname.includes('google.firestore.v1.Firestore')) meter.firestore.add(e.requestId);
    } catch {}
  });
  cdp.on('Network.responseReceived', (e) => {
    if (!meter.firestore.has(e.requestId) || meter.streamed.has(e.requestId)) return;
    meter.streamed.add(e.requestId);
    cdp.send('Network.streamResourceContent', { requestId: e.requestId })
      .then((x) => { if (x && x.bufferedData) count(x.bufferedData); })
      .catch(() => {});
  });
  cdp.on('Network.dataReceived', (e) => {
    if (meter.firestore.has(e.requestId) && e.data) count(e.data);
  });
  return meter;
}

async function settle(page, meter) {
  const started = Date.now();
  while (Date.now() - started < SETTLE_LIMIT_MS) {
    await page.waitForTimeout(1000);
    if (Date.now() - meter.changedAt >= QUIET_MS) return;
  }
  throw new Error(`Firestore reads did not settle within ${SETTLE_LIMIT_MS} ms (${meter.docs} documents so far)`);
}

async function absent(page, text) {
  const n = await page.getByText(text).count() + await page.getByLabel(text).count();
  expect(n === 0, `"${text}" is shown, but the shop document name should replace it`);
}

module.exports = {
  name: 'dashboard_signin_reads',
  platformApi: false,
  async run(t) {
    const { db, accounts, seed } = t;
    const report = { budget: READ_BUDGET, roles: {} };
    const now = Date.now();
    const supervisorCode = accounts.salesman.code;
    const totalRetailers = BULK_RETAILERS + RETAILERS.length + 1;
    const branchRetailers = BULK_RETAILERS + RETAILERS.length;

    await t.step(`seed ${BULK_RETAILERS} shops, ${EXTRA_SALESMEN} salespeople and ${OLD_VISITS + 7} visit rows with stale shop names`, async () => {
      const retailers = [];
      for (let i = 0; i < BULK_RETAILERS; i += 1) {
        retailers.push({
          id: bulkId(i),
          data: {
            retailerId: bulkId(i), retailerName: bulkName(i), name: bulkName(i), area: 'Kuching',
            branchId: seed.branch.id, status: 'active', address: 'Kuching',
            latitude: 1.5 + i / 100000, longitude: 110.3 + i / 100000,
            coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
            assignedSalesmanCode: salesCode(i % EXTRA_SALESMEN), assignedSalesmanId: salesCode(i % EXTRA_SALESMEN),
          },
        });
      }
      retailers.push({
        id: 'ret-far',
        data: {
          retailerId: 'ret-far', retailerName: 'Far Shop Doc', name: 'Far Shop Doc', area: 'Miri',
          branchId: 'B2', status: 'active', address: 'Miri', latitude: 4.39, longitude: 113.99,
          coordinateStatus: 'verified', coordinateReviewStatus: 'reviewed', coordinateSource: 'admin_review',
        },
      });
      await putMany(db, 'retailers', retailers);

      const users = [];
      for (let i = 0; i < EXTRA_SALESMEN; i += 1) {
        const code = salesCode(i);
        users.push({
          id: `sales-${code}`,
          data: {
            uid: `uid-${code}`, userUid: `uid-${code}`, name: `Seller ${code}`, email: `seller.${code.toLowerCase()}@example.test`,
            role: 'salesman', user_group: 'salesman', status: 'active', employeeCode: code, userId: code,
            branchId: seed.branch.id, branch_id: seed.branch.id,
          },
        });
      }
      await putMany(db, 'users', users);

      const visit = (id, code, uid, retailer, row, arrival, done) => ({
        id,
        data: {
          salesmanCode: code, salesmanId: code, salesmanUid: uid, branchId: seed.branch.id,
          retailerId: retailer, retailerName: row, arrivalTime: new Date(arrival),
          ...(done ? { departureTime: new Date(arrival + 30e3), status: 'completed' } : { status: 'in progress' }),
        },
      });
      const sup = seed.uids.salesman;
      const today = [
        visit('vt-1', supervisorCode, sup, 'ret-far', 'Far Row Name', now - 60e3, true),
        visit('vt-2', supervisorCode, sup, bulkId(1), staleName(1), now - 120e3, true),
        visit('vt-3', supervisorCode, sup, bulkId(2), staleName(2), now - 180e3, true),
        visit('vt-4', salesCode(1), `uid-${salesCode(1)}`, bulkId(3), staleName(3), now - 240e3, true),
        visit('vt-5', salesCode(2), `uid-${salesCode(2)}`, bulkId(900), staleName(900), now - 300e3, true),
        visit('vt-6', salesCode(3), `uid-${salesCode(3)}`, bulkId(999), staleName(999), now - 360e3, true),
        visit('vt-7', salesCode(4), `uid-${salesCode(4)}`, bulkId(4), staleName(4), now - 420e3, false),
      ];
      const old = [];
      for (let i = 0; i < OLD_VISITS; i += 1) {
        const k = i % (EXTRA_SALESMEN + 1);
        const code = k === EXTRA_SALESMEN ? supervisorCode : salesCode(k);
        const uid = k === EXTRA_SALESMEN ? sup : `uid-${code}`;
        old.push(visit(`vo-${pad(i)}`, code, uid, bulkId(i % 60), staleName(i % 60), now - (2 + (i % 28)) * DAY_MS - i * 1000, true));
      }
      await putMany(db, 'visit_logs', [...today, ...old]);
    });

    async function signIn(role, account, waitShell) {
      const s = await t.session('admin', { name: role, viewport: { width: 1600, height: 1000 } });
      const meter = await meterReads(s);
      await B.openApp(s.page, s.url);
      const inputs = s.page.locator('input');
      await inputs.nth(1).waitFor({ timeout: 60000 });
      await s.page.waitForTimeout(500);
      await B.fillField(s.page, inputs.nth(0), account.email);
      await B.fillField(s.page, inputs.nth(1), E.PASSWORD);
      const clickedAt = Date.now();
      await s.page.getByRole('button', { name: /^Sign In$/ }).click();
      await waitShell(s.page);
      return { s, meter, clickedAt };
    }

    async function measure(role, s, meter, kpiMs) {
      await settle(s.page, meter);
      const entry = { docs: meter.docs, kpiMs, byCollection: meter.byCollection };
      report.roles[role] = entry;
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'reads.json'), `${JSON.stringify(report, null, 2)}\n`);
      console.log(`    ${role}: ${meter.docs} documents, first KPI after ${kpiMs} ms ${JSON.stringify(meter.byCollection)}`);
      return entry;
    }

    function expectReads(role, entry, retailerCeiling) {
      const retailerReads = entry.byCollection.retailers || 0;
      expect(retailerReads <= retailerCeiling,
        `${role} read ${retailerReads} retailer documents; one shared lookup allows at most ${retailerCeiling}`);
      expect(entry.docs <= READ_BUDGET, `${role} sign-in read ${entry.docs} documents; the budget is ${READ_BUDGET}`);
    }

    await t.step('admin: KPI tiles and field list show the seeded values and the shop document names', async () => {
      const { s, meter, clickedAt } = await signIn('admin', accounts.admin, admin.waitForShell);
      await B.see(s.page, /^Visits completed: 6\. Arrival and departure logged$/, { timeout: 60000 });
      const kpiMs = Date.now() - clickedAt;
      await B.see(s.page, /^Active salespeople: 5\. With a visit today$/, { timeout: 60000 });
      for (const name of ['Far Shop Doc', bulkName(1), bulkName(2), bulkName(3)]) await B.see(s.page, name);
      for (const name of ['Far Row Name', staleName(1), staleName(2), staleName(3)]) await absent(s.page, name);
      const entry = await measure('admin', s, meter, kpiMs);
      await t.shot(s, 'admin-home');
      expectReads('admin', entry, totalRetailers + LOOKUP_SLACK);
    });

    await t.step('supervisor: team KPIs match the seed; a shop outside the branch keeps the visit row name', async () => {
      const { s, meter, clickedAt } = await signIn('supervisor', accounts.supervisor, admin.waitForSupervisorShell);
      await B.see(s.page, /^Visits completed today: 3\./, { timeout: 60000 });
      const kpiMs = Date.now() - clickedAt;
      await B.see(s.page, /^Salespeople active today: 1 of 1\./, { timeout: 60000 });
      for (const name of ['Visit completed at Far Row Name', `Visit completed at ${bulkName(1)}`, `Visit completed at ${bulkName(2)}`]) {
        await B.see(s.page, name);
      }
      for (const name of ['Far Shop Doc', staleName(1), staleName(2)]) await absent(s.page, name);
      const entry = await measure('supervisor', s, meter, kpiMs);
      await t.shot(s, 'supervisor-home');
      expectReads('supervisor', entry, branchRetailers + LOOKUP_SLACK);
    });

    await t.step('branch manager: branch KPIs and latest visits match the seed', async () => {
      const { s, meter, clickedAt } = await signIn('branch_manager', accounts.branchManager, admin.waitForBranchManagerShell);
      await B.see(s.page, /^Visits completed today: 6\. at 6 shops$/, { timeout: 60000 });
      const kpiMs = Date.now() - clickedAt;
      await B.see(s.page, /^Salespeople active today: 5\. logged field activity$/, { timeout: 60000 });
      for (const name of ['Far Row Name', bulkName(1), bulkName(2), bulkName(3), bulkName(900)]) await B.see(s.page, name);
      for (const name of ['Far Shop Doc', staleName(1), staleName(900)]) await absent(s.page, name);
      const entry = await measure('branch_manager', s, meter, kpiMs);
      await t.shot(s, 'branch-manager-home');
      expectReads('branch_manager', entry, branchRetailers + LOOKUP_SLACK);
    });

    await t.step(`admin with more shops than the ${DIRECTORY_LIMIT}-shop directory: missing shops are read by id, case-insensitive, from storeId`, async () => {
      const more = [];
      for (let i = BULK_RETAILERS; i < BULK_RETAILERS + EXTRA_RETAILERS; i += 1) {
        more.push({
          id: bulkId(i),
          data: {
            retailerId: bulkId(i), retailerName: bulkName(i), name: bulkName(i), area: 'Kuching',
            branchId: seed.branch.id, status: 'active', address: 'Kuching',
            latitude: 1.5 + i / 100000, longitude: 110.3 + i / 100000, coordinateStatus: 'needs_review',
          },
        });
      }
      await putMany(db, 'retailers', more);
      await putMany(db, 'visit_logs', [{
        id: 'vt-0',
        data: {
          salesmanCode: salesCode(5), salesmanId: salesCode(5), salesmanUid: `uid-${salesCode(5)}`, branchId: seed.branch.id,
          storeId: LATE_SHOP.toUpperCase(), retailerName: staleName(LATE_INDEX),
          arrivalTime: new Date(now - 30e3), departureTime: new Date(now - 10e3), status: 'completed',
        },
      }]);
      const { s, meter, clickedAt } = await signIn('admin_large', accounts.admin, admin.waitForShell);
      await B.see(s.page, /^Visits completed: 7\. Arrival and departure logged$/, { timeout: 60000 });
      const kpiMs = Date.now() - clickedAt;
      await B.see(s.page, /^Active salespeople: 6\. With a visit today$/, { timeout: 60000 });
      for (const name of [bulkName(LATE_INDEX), 'Far Shop Doc', bulkName(1), bulkName(2)]) await B.see(s.page, name);
      for (const name of [staleName(LATE_INDEX), 'Far Row Name', staleName(1)]) await absent(s.page, name);
      const entry = await measure('admin_large', s, meter, kpiMs);
      await t.shot(s, 'admin-home-large');
      const retailerReads = entry.byCollection.retailers || 0;
      expect(retailerReads >= DIRECTORY_LIMIT, `admin_large read ${retailerReads} retailer documents; the Action Centre directory alone reads ${DIRECTORY_LIMIT}`);
      expect(retailerReads <= DIRECTORY_LIMIT + KEY_SLACK,
        `admin_large read ${retailerReads} retailer documents; the directory plus the two missing visited shops allows at most ${DIRECTORY_LIMIT + KEY_SLACK}`);
    });
  },
};
