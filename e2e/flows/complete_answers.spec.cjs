'use strict';
const assert = require('node:assert/strict');
const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const { putMany, deleteMany, listDocumentIds } = require('../lib/bulk.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

async function openScorecard(page) {
  const label = await B.see(page, /^Coaching Scorecard$/, { timeout: 60000 });
  await B.scrollIntoView(page, label, { step: -400, minHeight: 15, bottomInset: 0 });
  await label.click();
}

module.exports = {
  name: 'complete_answers',
  async run(t) {
    const { db, accounts, seed } = t;
    let s;
    let phone;
    const ids = Array.from({ length: 501 }, (_, i) => `ANS-${String(i).padStart(4, '0')}`);
    const latest = 'ZZZ-ANS-LATEST';
    const at = Date.now();
    const orderData = (id, n) => ({
      orderId: id, uid: seed.uids.salesman, userUid: seed.uids.salesman,
      salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code,
      salesmanId: accounts.salesman.code, staffId: accounts.salesman.code,
      submittedByUid: seed.uids.salesman, branchId: accounts.salesman.branch,
      retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
      status: 'approved', totalPrice: 2, totalProducts: 1, totalBoxes: 1, items: [],
      submittedAt: new Date(at - n * 50), createdAt: new Date(at - n * 50),
    });
    const order = (id, n) => db.put('orders', id, orderData(id, n));
    await t.step('seed more orders than the 500-row bridge cap', async () => {
      for (const row of await db.list('orders')) await db.del('orders', row.id);
      await putMany(db, 'orders', ids.map((id, i) => ({ id, data: orderData(id, i + 1) })));
      await order(latest, 0);
      assert.equal((await db.get('orders', latest)).totalPrice, 2);
    });
    await t.step('dashboard withholds capped order and value totals', async () => {
      s = await t.session('admin');
      await B.loginAdmin(s.page, s.url, accounts.admin.email);
      await admin.waitForShell(s.page);
      await admin.goToPage(s.page, 'Dashboard');
      await B.see(s.page, /Orders.*Incomplete/i, { timeout: 30000 });
      await B.see(s.page, /Order value.*Incomplete/i);
      await t.shot(s, 'capped-totals-withheld');
    });
    await t.step('phone order summary also withholds a capped total', async () => {
      phone = await t.session('mobile');
      await B.loginMobile(phone.page, phone.url, accounts.salesman.email);
      await B.see(phone.page, 'Orders Today', { timeout: 30000 });
      await B.see(phone.page, 'Incomplete', { timeout: 30000 });
      await t.shot(phone, 'phone-capped-orders');
    });
    await t.step('the newest order remains visible beyond the unordered boundary', async () => {
      await admin.goToPage(s.page, 'All Orders');
      await s.page.getByRole('button', { name: new RegExp(`^${latest}`) }).waitFor();
      await t.shot(s, 'newest-order');
    });
    await t.step('complete source snapshots show exact totals after overflow is removed', async () => {
      await deleteMany(db, 'orders', ids.slice(0, 3));
      const remaining = await listDocumentIds(db, 'orders');
      assert.deepEqual(remaining.sort(), [...ids.slice(3), latest].sort());
      await admin.goToPage(s.page, 'Dashboard');
      await B.see(s.page, /Orders[^:]*: 499\./, { timeout: 60000 });
      await B.see(s.page, /Order value[^:]*: RM\s*998(?:\.00)?\./);
      await t.shot(s, 'complete-totals');

    });
    await t.step('old orders beyond the cap do not hide exact totals for today', async () => {
      const dayMs = 24 * 60 * 60 * 1000;
      const old = Array.from({ length: 501 }, (_, i) => ({
        id: `OLD-ANS-${String(i).padStart(4, '0')}`,
        data: { ...orderData(`OLD-ANS-${i}`, i + 1), submittedAt: new Date(at - 40 * dayMs - i * 1000), createdAt: new Date(at - 40 * dayMs - i * 1000) },
      }));
      await putMany(db, 'orders', old);
      await admin.goToPage(s.page, 'All Orders');
      await admin.goToPage(s.page, 'Dashboard');
      await B.see(s.page, /Orders today[^:]*: 499\./, { timeout: 60000 });
      await B.see(s.page, /Order value today[^:]*: RM\s*998(?:\.00)?\./);
      await t.shot(s, 'today-exact-beyond-cap');
      await deleteMany(db, 'orders', old.map((row) => row.id));
    });
    await t.step('phone metadata confirmation restores complete counts without a data write', async () => {
      await B.semantic(phone.page, 'Incomplete').waitFor({ state: 'hidden', timeout: 30000 });
      await phone.context.setOffline(true);
      await B.see(phone.page, 'Incomplete', { timeout: 30000 });
      await phone.context.setOffline(false);
      await B.semantic(phone.page, 'Incomplete').waitFor({ state: 'hidden', timeout: 30000 });
      await t.shot(phone, 'phone-server-confirmation-restored');
      await s.context.close();
      await phone.context.close();
      await deleteMany(db, 'orders', ids.slice(3, -1));
    });
    let supervisor;
    const overflow = [];
    const extraIds = Array.from({ length: 1001 }, (_, i) => `CHUNK-${i}`);
    await t.step('a full first chunk and a short second chunk withhold scorecard totals', async () => {
      const access = await db.get('user_access', seed.uids.supervisor);
      const codes = [accounts.salesman.code, ...Array.from({ length: 30 }, (_, i) => `X${i}`)];
      await db.put('user_access', seed.uids.supervisor, { ...access, assignedSalesmanCodes: codes });
      supervisor = await t.session('admin');
      await B.loginAdmin(supervisor.page, supervisor.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supervisor.page);
      await admin.goToPage(supervisor.page, 'Team Orders');
      await putMany(db, 'orders', extraIds.map((id, i) => ({ id, data: orderData(id, i + 1) })));
      await db.put('orders', 'CHUNK-SECOND', {
        ...(await db.get('orders', latest)), orderId: 'CHUNK-SECOND',
        staffId: codes[30], salesmanCode: codes[30], salesmanId: codes[30],
        uid: 'e2e-second-chunk-salesman', userUid: 'e2e-second-chunk-salesman',
        salesmanUid: 'e2e-second-chunk-salesman', submittedByUid: 'e2e-second-chunk-salesman',
      });
      for (const [collection, cap, timeField] of [
        ['route_plan_progress', 500, 'updatedAt'], ['route_stop_progress', 500, 'arrivedAt'],
        ['route_plans', 300, 'weekStart'], ['conversation_outcomes', 300, 'submittedAt'],
        ['ai_insights', 200, 'updatedAt'], ['visit_briefs', 400, 'generatedAt'],
        ['retailer_memory', 400, 'updatedAt'], ['visit_logs', 500, 'arrivalTime'],
        ['retailer_priority_rankings', 200, 'generatedAt'],
      ]) {
        const newest = collection === 'visit_logs' ? at + 2 * 24 * 60 * 60 * 1000 : at;
        const documents = Array.from({ length: cap + 1 }, (_, n) => ({
          id: `BOUND-${n}`, data: {
            salesmanCode: accounts.salesman.code, salesmanUid: seed.uids.salesman,
            branchId: accounts.salesman.branch, retailerId: RETAILERS[0].id,
            [timeField]: new Date(newest - n * 1000 - 1000), status: 'open',
            planId: `PLAN-${n}`, days: [], stops: [], entries: [],
          },
        }));
        await putMany(db, collection, documents);
        overflow.push(...documents.map(row => [collection, row.id]));
      }
      await admin.goToPage(supervisor.page, 'Team Activity');
      await B.see(supervisor.page, 'Incomplete activity coverage', { timeout: 60000 });
      await B.semantic(supervisor.page, /^Completed: 0$/).waitFor({ state: 'hidden' });
      await openScorecard(supervisor.page);
      await B.see(supervisor.page, /Incomplete.*counts, rates and coaching are unavailable/i, { timeout: 30000 });
      await B.see(supervisor.page, /incomplete coverage.*insights.*orders.*outcomes.*route plans.*stop arrivals.*visit progress/i);
      await t.shot(supervisor, 'multi-chunk-incomplete');
      await admin.goToPage(supervisor.page, 'Team Route Planner');
      await supervisor.page.getByRole('button', { name: 'Priorities', exact: true }).click();
      await B.see(supervisor.page, 'Incomplete priority data', { timeout: 30000 });
      await t.shot(supervisor, 'priority-inputs-incomplete');
      await admin.goToPage(supervisor.page, 'My Team');
      await B.see(supervisor.page, 'Orders: Incomplete', { timeout: 30000 });
      await t.shot(supervisor, 'team-incomplete');
    });
    await t.step('short chunks restore verified scorecard counts', async () => {
      await supervisor.context.close();
      await deleteMany(db, 'orders', extraIds);
      for (const collection of new Set(overflow.map(([name]) => name))) {
        await deleteMany(db, collection, overflow.filter(([name]) => name === collection).map(([, id]) => id));
      }
      supervisor = await t.session('admin');
      await B.loginAdmin(supervisor.page, supervisor.url, accounts.supervisor.email);
      await admin.waitForSupervisorShell(supervisor.page);
      await admin.goToPage(supervisor.page, 'Team Activity');
      await openScorecard(supervisor.page);
      await B.see(supervisor.page, /Orders \(8 wk\)/, { timeout: 30000 });
      await B.semantic(supervisor.page, /Incomplete.*counts, rates and coaching are unavailable/i).waitFor({ state: 'hidden' });
      await t.shot(supervisor, 'multi-chunk-complete');
      await db.put('gps_tracking', 'LOCATION-NOT-A-VISIT', {
        salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code,
        branchId: accounts.salesman.branch, latitude: 1.55, longitude: 110.35,
        updatedAt: new Date(), timestamp: new Date(),
      });
      await admin.goToPage(supervisor.page, 'My Team');
      await B.see(supervisor.page, 'Orders: 2', { timeout: 30000 });
      await B.see(supervisor.page, 'Visits: 0', { timeout: 30000 });
      await t.shot(supervisor, 'team-complete');
    });
    await t.step('a day of location points does not hide the visit counts of the week', async () => {
      const dayMs = 24 * 60 * 60 * 1000;
      const seededAt = Date.now();
      const points = Array.from({ length: 600 }, (_, n) => ({
        id: `POINT-${String(n).padStart(4, '0')}`, data: {
          salesmanUid: seed.uids.salesman, salesmanCode: accounts.salesman.code,
          branchId: accounts.salesman.branch, latitude: 1.55, longitude: 110.35,
          updatedAt: new Date(seededAt - n * 1000), timestamp: new Date(seededAt - n * 1000),
        },
      }));
      const visits = Array.from({ length: 5 }, (_, n) => ({
        id: `WEEK-VISIT-${n}`, data: {
          salesmanCode: accounts.salesman.code, salesmanUid: seed.uids.salesman,
          branchId: accounts.salesman.branch, retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name,
          arrivalTime: new Date(seededAt - (n + 1) * dayMs),
          departureTime: new Date(seededAt - (n + 1) * dayMs + 10 * 60 * 1000),
          status: 'completed',
        },
      }));
      await putMany(db, 'gps_tracking', points);
      await putMany(db, 'visit_logs', visits);
      assert.equal((await listDocumentIds(db, 'visit_logs')).filter((id) => id.startsWith('WEEK-VISIT-')).length, 5);
      await admin.goToPage(supervisor.page, 'Team Activity');
      const tab = await B.see(supervisor.page, /^Salesman Performance$/, { timeout: 60000 });
      await B.scrollIntoView(supervisor.page, tab, { step: -400, minHeight: 15, bottomInset: 0 });
      await tab.click();
      await B.see(supervisor.page, 'Visits completed: 5', { timeout: 60000 });
      await B.see(supervisor.page, 'Supportive view · last 28 days');
      await B.see(supervisor.page, 'Orders submitted: 2');
      await B.see(supervisor.page, 'Conversion: 40%');
      await B.see(supervisor.page, 'Incomplete location coverage');
      await B.see(supervisor.page, 'GPS sync, last GPS sync, active days, trend and score are unavailable.');
      await B.semantic(supervisor.page, 'Incomplete activity coverage').waitFor({ state: 'hidden' });
      await t.shot(supervisor, 'visit-counts-with-many-location-points');
      await deleteMany(db, 'gps_tracking', points.map((row) => row.id));
      await deleteMany(db, 'visit_logs', visits.map((row) => row.id));
    });
    await t.step('a legacy timestamp omission stays unknown rather than becoming zero', async () => {
      const legacy = { ...(await db.get('orders', latest)), orderId: 'LEGACY-TIME' };
      delete legacy.submittedAt;
      await db.put('orders', 'LEGACY-TIME', legacy);
      await admin.goToPage(supervisor.page, 'Team Orders');
      await admin.goToPage(supervisor.page, 'Team Activity');
      await openScorecard(supervisor.page);
      await B.see(supervisor.page, /Incomplete.*counts, rates and coaching are unavailable/i, { timeout: 30000 });
      await t.shot(supervisor, 'legacy-coverage-unknown');
      await admin.goToPage(supervisor.page, 'My Team');
      await B.see(supervisor.page, 'Orders: Incomplete', { timeout: 30000 });
      await B.see(supervisor.page, 'Last order: Incomplete');
      await t.shot(supervisor, 'team-legacy-coverage-unknown');
      await t.collectEvidence('PASSED');
    });
  },
};
