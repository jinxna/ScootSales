'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { BRANCH, PRODUCTS, RETAILERS, putPerson } = require('../lib/seed.cjs');
const fake = require('../lib/copilot_server.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'scout_manager_questions');
const DAY = 86400e3;
const WAITING = new Set(['submitted', 'pending', 'pending_approval', 'held_for_review']);

const SUPERVISOR = { email: 'e2e.scout.lead@example.test', name: 'Lunde Varga', role: 'supervisor', code: 'SUP9-E2E', branch: BRANCH.id };
const REP = { email: 'e2e.scout.rep@example.test', name: 'Jaylen Ortiz', role: 'salesman', code: 'S9002', branch: BRANCH.id };
const MATE = { email: 'e2e.scout.mate@example.test', name: 'Mira Halim', role: 'salesman', code: 'S9003', branch: BRANCH.id };
const OUTSIDER = { email: 'e2e.scout.out@example.test', name: 'Tobias Wren', role: 'salesman', code: 'S9004', branch: BRANCH.id };
const UNLINKED = ['S9010', 'S9011', 'S9012', 'S9013', 'S9014', 'S9015', 'S9016'];
const ROSTER = ['S9002', 's9002', 'S9003', ...UNLINKED];
const SHOPS = [
  { id: 'ret-sq-1', name: 'Kedai Sinar Pagi', status: 'active', assignedSalesmanId: 'S9002' },
  { id: 'ret-sq-2', name: 'Pasar Mini Bintang', status: 'Hide', assignedSalesmanId: 's9002' },
  { id: 'ret-sq-3', name: 'Toko Cahaya Baru', status: 'active', byUid: true },
];

module.exports = {
  name: 'scout_manager_questions',
  async run(t) {
    const { db, accounts, seed } = t;
    const answers = [];
    let s;
    let server = null;
    let shotNo = 0;
    const page = () => s.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const waitAnswer = async (label, re, before) => {
      const end = Date.now() + 60000;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) {
          const answer = await find(re).last().evaluate((n) => n.getAttribute('aria-label') || n.textContent);
          answers.push({ question: label, answer });
          shotNo += 1;
          await t.shot(s, `q${String(shotNo).padStart(2, '0')}`);
          return answer;
        }
        await page().waitForTimeout(150);
      }
      answers.push({ question: label, answer: null, expected: String(re) });
      throw new Error(`after "${label}" expected ${re}`);
    };
    const ask = async (text, re) => {
      const before = await find(re).count();
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
      return waitAnswer(text, re, before);
    };
    const sourced = async (run, re) => {
      const before = await find(re).count();
      const answer = await run();
      if ((await find(re).count()) <= before) throw new Error(`the answer must show a new ${re} line: ${JSON.stringify(answer)}`);
      return answer;
    };
    const see = (re) => B.see(page(), re);
    const absent = async (re, why) => {
      if ((await find(re).count()) !== 0) throw new Error(`unexpected text ${re}: ${why}`);
    };
    const openScout = () => page().getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
    const noModelRequest = async (text, re) => {
      const before = server.requests.length;
      const answer = await ask(text, re);
      const sent = server.requests.slice(before).map((r) => r.text);
      if (sent.length !== 0) throw new Error(`"${text}" must be answered without the model, the model was asked ${JSON.stringify(sent)}`);
      return answer;
    };
    const waitingCount = (rows, codes) => rows.filter((o) => WAITING.has(String(o.status || ''))
      && (!codes || codes.has(String(o.salesmanCode || '').toLowerCase()))).length;
    const save = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'answers.json'), `${JSON.stringify(answers, null, 2)}\n`);
    };

    const uids = {};
    try {
      await t.step('seed: a supervisor with both spellings of one code, two salespeople, an outsider, three shops, waiting orders', async () => {
        uids.supervisor = await putPerson(db, SUPERVISOR, { assignedSalesmanCodes: ROSTER });
        for (const person of [REP, MATE, OUTSIDER]) {
          const lead = person === OUTSIDER ? {} : { supervisorUid: uids.supervisor, supervisorCode: SUPERVISOR.code };
          uids[person.code] = await putPerson(db, person, lead);
        }
        const repRow = await db.get('users', REP.email);
        await db.put('users', REP.email, { ...repRow, role: 'Sales Representative' });
        for (const shop of SHOPS) {
          await db.put('retailers', shop.id, {
            retailerId: shop.id, retailerName: shop.name, name: shop.name, area: 'Kuching', branchId: BRANCH.id,
            status: shop.status, address: 'Kuching', latitude: 1.55, longitude: 110.34,
            assignedSalesmanId: shop.byUid ? uids[REP.code] : shop.assignedSalesmanId,
          });
        }
        const now = Date.now();
        const order = (id, person, code, ms, status) => db.put('orders', id, {
          orderId: id, uid: uids[person.code], userUid: uids[person.code], salesmanUid: uids[person.code],
          salesmanId: code, salesmanCode: code, salesmanName: person.name, submittedByUid: uids[person.code],
          branchId: BRANCH.id, retailerId: SHOPS[0].id, retailerName: SHOPS[0].name, items: [], totalPrice: 25,
          submittedAt: new Date(ms), createdAt: new Date(ms), ...(status ? { status } : {}),
        });
        await order('ORD-SQ-NEW', REP, 'S9002', now - 3600e3, 'submitted');
        await order('ORD-SQ-NOSTATUS', REP, 'S9002', now - 1800e3, null);
        await order('ORD-SQ-OLD', REP, 's9002', now - 120 * DAY, 'submitted');
        await order('ORD-SQ-MATE', MATE, 'S9003', now - 2 * 3600e3, 'pending');
        await order('ORD-SQ-OUT', OUTSIDER, 'S9004', now - 3 * 3600e3, 'submitted');
      });

      await t.step('admin: a "Sales Representative" is a salesperson, and lower-case names with typos find people, shops and teams', async () => {
        server = await fake.start();
        s = await t.session('admin', { name: 'admin', viewport: { width: 2000, height: 1100 } });
        await B.loginAdmin(page(), s.url, accounts.admin.email);
        await admin.waitForShell(page());
        await openScout();
        await noModelRequest('orders from jaylen this month', /2 orders · Jaylen Ortiz \(S9002\)/);
        await absent(/is not a salesperson|can't find "jaylen"/, 'a "Sales Representative" must be found as a salesperson');

        const shops = await sourced(() => noModelRequest('what are the retailer that jaylen connect ith', /Jaylen Ortiz \(S9002\) covers 3 shops \(2 active\)/), /Data used: retailers · assigned to /);
        for (const shop of SHOPS) {
          if (!shops.includes(shop.name)) throw new Error(`the shops answer must list ${shop.name}: ${JSON.stringify(shops)}`);
        }
        for (const other of RETAILERS) {
          if (shops.includes(other.name)) throw new Error(`the shops answer must not list ${other.name}: ${JSON.stringify(shops)}`);
        }
        if (!/Pasar Mini Bintang · hidden/.test(shops)) throw new Error(`the hidden shop must say hidden: ${JSON.stringify(shops)}`);

        const team = await sourced(() => noModelRequest('who reports to lunde', /Lunde Varga \(SUP9-E2E\) has 2 salespeople/), /Data used: users · supervisor rosters/);
        for (const person of [REP, MATE]) {
          const times = team.split(person.name).length - 1;
          if (times !== 1) throw new Error(`the team answer must list ${person.name} once, saw ${times}: ${JSON.stringify(team)}`);
        }
        if (team.includes(OUTSIDER.name)) throw new Error(`the team answer must not list ${OUTSIDER.name}`);

        await noModelRequest('which shops does tobias cover', /No shops are assigned to Tobias Wren \(S9004\)/);
      });

      await t.step('admin: "appprove the pending order" counts every waiting order on all dates, the same as the home page', async () => {
        const rows = await db.list('orders');
        const expected = waitingCount(rows);
        const goHome = page().getByRole('button', { name: 'Home' }).first();
        if (await goHome.count()) await goHome.click();
        const tile = find(/^Waiting for approval: \d+\./).first();
        await tile.waitFor({ timeout: 60000 });
        const tileText = await tile.evaluate((n) => n.getAttribute('aria-label') || n.textContent);
        const home = Number(/^Waiting for approval: (\d+)\./.exec(tileText)[1]);
        if (home !== expected) throw new Error(`the home page shows ${home} waiting orders, the seed holds ${expected}`);
        const answer = await noModelRequest('appprove the pending order',
          new RegExp(`(?<!\\d)${expected} orders are waiting for approval \\(all dates, the same count as the home page\\)`));
        const approveCount = Number(/Approve (\d+) orders?\?/.exec(answer)?.[1]);
        const offered = answer.split('\n').map((line) => line.trim())
          .filter((line) => /^ORD-SQ-[A-Z]+ · .+ · (today|1 day old|\d+ days old|age unknown)$/.test(line))
          .map((line) => line.split(' · ')[0]).sort();
        const decidable = ['ORD-SQ-NEW', 'ORD-SQ-OLD', 'ORD-SQ-OUT'];
        if (approveCount !== decidable.length || JSON.stringify(offered) !== JSON.stringify(decidable)) {
          throw new Error(`the confirm card must offer exactly the submitted orders ${JSON.stringify(decidable)} (not the "pending" ORD-SQ-MATE, which the Approve button cannot decide, nor ORD-SQ-NOSTATUS): ${JSON.stringify(answer)}`);
        }
      });

      await t.step('supervisor: the count covers both spellings of a code, and a person outside the team is not found', async () => {
        const rows = await db.list('orders');
        const expected = waitingCount(rows, new Set(ROSTER.map((c) => c.toLowerCase())));
        if (expected !== 3) throw new Error(`the seed must hold 3 waiting orders for the team, holds ${expected}`);
        s = await t.session('admin', { name: 'supervisor', viewport: { width: 2000, height: 1100 } });
        await B.loginAdmin(page(), s.url, SUPERVISOR.email);
        await admin.waitForSupervisorShell(page());
        await openScout();
        await noModelRequest('appprove the pending order',
          /(?<!\d)3 orders are waiting for approval \(all dates, the same count as the home page\)/);
        await see(/ORD-SQ-OLD/);
        await absent(/ORD-SQ-OUT/, 'an order outside the team');
        await noModelRequest('which shops does tobias cover', /No one called "tobias" among the people your role can see/);
        await noModelRequest('what are the retailer that jaylen connect ith', /Jaylen Ortiz \(S9002\) covers 3 shops \(2 active\)/);
      });

      const product = PRODUCTS[0];
      const batch = Array.from({ length: 12 }, (_, i) => `ORD-SQ-A${String(i + 1).padStart(2, '0')}`);
      const limited = batch[2];
      const offered = batch.slice(0, 10);
      const approvedIds = offered.filter((id) => id !== limited);
      const statusOf = async (ids) => Object.fromEntries(await Promise.all(ids.map(async (id) => [id, (await db.get('orders', id)).status])));

      await t.step('seed: 12 newer waiting orders with real lines, one above the default product limit of 5', async () => {
        const stored = await db.get('products', product.id);
        if (stored.maxOrderQty !== undefined) throw new Error(`the product limit must be the default 5, the seed set ${stored.maxOrderQty}`);
        const now = Date.now();
        for (const [i, id] of batch.entries()) {
          const qty = id === limited ? 6 : 1;
          const at = new Date(now - (i + 1) * 60e3);
          await db.put('orders', id, {
            orderId: id, uid: uids[REP.code], userUid: uids[REP.code], salesmanUid: uids[REP.code],
            salesmanId: REP.code, salesmanCode: REP.code, salesmanName: REP.name, submittedByUid: uids[REP.code],
            branchId: BRANCH.id, retailerId: SHOPS[0].id, retailerName: SHOPS[0].name,
            items: [{ productId: product.id, productName: product.name, qty, price: product.price }],
            totalBoxes: qty, totalProducts: 1, totalPrice: Math.round(qty * product.price * 100) / 100,
            status: 'submitted', submittedAt: at, createdAt: at,
          });
        }
      });

      await t.step('branch manager: "can you approve those orders for me?" is view only and changes no order', async () => {
        const before = await db.list('orders');
        s = await t.session('admin', { name: 'branch-manager', viewport: { width: 2000, height: 1100 } });
        await B.loginAdmin(page(), s.url, accounts.branchManager.email);
        await admin.waitForBranchManagerShell(page());
        await openScout();
        await noModelRequest('can you approve those orders for me?', /Order approval is view only for your role/);
        if (await page().getByRole('button', { name: 'Confirm', exact: true }).count()) throw new Error('a branch manager must get no Confirm button');
        const after = await db.list('orders');
        const changed = after.filter((o) => before.find((b) => b.id === o.id)?.status !== o.status).map((o) => o.id);
        if (changed.length) throw new Error(`a branch manager changed orders ${changed.join(', ')}`);
      });

      await t.step('admin: the waiting list, then "can you approve those orders for me?" shows a confirm card of the 10 newest; nothing changes before Confirm', async () => {
        s = await t.session('admin', { name: 'approver', viewport: { width: 2000, height: 1100 } });
        await B.loginAdmin(page(), s.url, accounts.admin.email);
        await admin.waitForShell(page());
        await openScout();
        const waiting = waitingCount(await db.list('orders'));
        await sourced(() => noModelRequest('show orders waiting for approval', new RegExp(`(?<!\\d)${waiting} waiting for approval \\(all time\\)`)),
          /Data used: orders · waiting for approval/);
        await sourced(() => noModelRequest('can you approve those orders for me?',
          new RegExp(`(?<!\\d)${waiting} orders are waiting for approval \\(all dates, the same count as the home page\\)\\. Approve 10 orders\\?`)),
        /Data used: orders · /);
        await see(new RegExp(`(^|\\s)${batch[0]} · ${SHOPS[0].name} · ${REP.name} · RM ${product.price.toFixed(2)} · today`));
        for (const id of offered) await see(new RegExp(`(^|\\s)${id} · ${SHOPS[0].name} · ${REP.name} · `));
        for (const id of batch.slice(10)) await absent(new RegExp(`(^|\\s)${id} · ${SHOPS[0].name} · ${REP.name} · `), `${id} is not among the 10 newest`);
        const before = await statusOf(batch);
        if (Object.values(before).some((st) => st !== 'submitted')) throw new Error(`no order may change before Confirm: ${JSON.stringify(before)}`);
      });

      await t.step('admin: Confirm approves 9 through the Approve action, skips the one above the product limit, and says how many still wait', async () => {
        const auditsBefore = new Set((await db.list('system_audit_logs')).map((r) => r.id));
        const answer = await sourced(async () => {
          const before = await find(/Approved \d+\./).count();
          await page().getByRole('button', { name: 'Confirm', exact: true }).last().click();
          return waitAnswer('Confirm', /Approved \d+\./, before);
        }, /Data used: orders · /);
        const after = await db.list('orders');
        const still = waitingCount(after);
        if (!new RegExp(`^Approved 9\\. ${still} more wait\\.`).test(answer)) throw new Error(`the answer must say "Approved 9. ${still} more wait.": ${JSON.stringify(answer)}`);
        for (const id of approvedIds) {
          const order = after.find((o) => o.id === id);
          if (order.status !== 'approved') throw new Error(`${id} must be approved, is ${order.status}`);
          if (order.approvedByUid !== seed.uids.admin) throw new Error(`${id} approvedByUid is ${order.approvedByUid}`);
          const po = await db.waitForDoc('purchase_orders', id, (p) => p.status === 'issued', { label: `purchase order ${id}` });
          if (po.issuedByUid !== seed.uids.admin) throw new Error(`purchase order ${id} issuer is ${po.issuedByUid}`);
        }
        for (const id of [limited, ...batch.slice(10)]) {
          const order = after.find((o) => o.id === id);
          if (order.status !== 'submitted') throw new Error(`${id} must still wait, is ${order.status}`);
        }
        if (await db.get('purchase_orders', limited)) throw new Error(`${limited} must get no purchase order`);
        await see(/Skipped 1\./);
        await see(new RegExp(`(^|\\s)${limited} · ${SHOPS[0].name} · .*this product's limit is 5`));
        const audits = (await db.list('system_audit_logs')).filter((r) => !auditsBefore.has(r.id));
        for (const id of approvedIds) {
          const row = audits.find((r) => r.action === 'approved' && r.entityId === id);
          if (!row) throw new Error(`no audit row for ${id}`);
          if (row.entityType !== 'orders' || row.actorUid !== seed.uids.admin || row.summary !== `Approved order ${id}`) throw new Error(`the audit row for ${id} differs from the Approve button: ${JSON.stringify(row)}`);
          if (!row.metadata || row.metadata.source !== 'assistant') throw new Error(`the audit row for ${id} must carry source assistant: ${JSON.stringify(row.metadata)}`);
        }
        if (audits.some((r) => r.entityId === limited)) throw new Error(`${limited} was skipped and must have no audit row`);
      });

      await t.step('admin: the skipped order opens the order dialog, which shows the limit warning and keeps the Approve button', async () => {
        const warnings = await find(/Quantity above the product limit:[^]*this product's limit is 5/).count();
        await page().getByRole('button', { name: `Open order ${limited}` }).click();
        await waitAnswer(`Open order ${limited}`, /Quantity above the product limit:[^]*this product's limit is 5/, warnings);
        await page().getByRole('button', { name: 'Approve', exact: true }).waitFor({ timeout: 30000 });
        await page().getByRole('button', { name: 'Close', exact: true }).last().click();
        if ((await db.get('orders', limited)).status !== 'submitted') throw new Error(`${limited} must stay submitted until a person approves it`);
      });

      await t.step('admin: the daily briefing says where each item comes from', async () => {
        await sourced(() => noModelRequest('what should i do today', /items? need attention most/), /From: /);
      });
    } finally {
      if (server) await server.close();
      save();
    }
  },
};
