'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const fake = require('../lib/copilot_server.cjs');
const { putMany } = require('../lib/bulk.cjs');
const { putPerson, PRODUCTS, RETAILERS } = require('../lib/seed.cjs');

const DOT = '·';
const KL_MS = 8 * 3600e3;
const DAY = 86400e3;
const MIN = 60e3;
const OUT = path.join(E.OUTPUT_DIR, 'copilot_orders');

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const now = Date.now();
const klDay0 = Math.floor((now + KL_MS) / DAY) * DAY - KL_MS;
const weekStart = klDay0 - ((new Date(now + KL_MS).getUTCDay() + 6) % 7) * DAY;
const lastWeekStart = weekStart - 7 * DAY;
const klYear = new Date(now + KL_MS).getUTCFullYear();
const klMonth = new Date(now + KL_MS).getUTCMonth();
const monthStart = Date.UTC(klYear, klMonth, 1) - KL_MS;
const nextMonthStart = Date.UTC(klYear, klMonth + 1, 1) - KL_MS;
const lastMonthStart = Date.UTC(klYear, klMonth - 1, 1) - KL_MS;
const lastMonthMid = lastMonthStart + 14 * DAY + 12 * 3600e3;

const PEOPLE = {
  ahmadAli: { email: 'e2e.ahmad.ali@example.test', name: 'Ahmad bin Ali', role: 'salesman', code: 'S002', branch: 'B1' },
  ahmadFaizal: { email: 'e2e.ahmad.faizal@example.test', name: 'Ahmad Faizal', role: 'salesman', code: 'S003', branch: 'B1' },
  gopal: { email: 'e2e.gopal@example.test', name: 'Gopal a/l Muthu', role: 'salesman', code: 'S004', branch: 'B1' },
};
const SHOPS = {
  choice: { id: RETAILERS[0].id, name: RETAILERS[0].name },
  emart: { id: RETAILERS[1].id, name: RETAILERS[1].name },
  formula: { id: 'ret-formula', name: '=SUM(1,2) Kedai Formula' },
};
const SUBMITTED = new Set(['', 'submitted', 'pending', 'pending_approval']);
const WAITING = new Set(['submitted', 'pending', 'pending_approval', 'held_for_review']);

module.exports = {
  name: 'copilot_orders',
  async run(t) {
    const { db, accounts } = t;
    const uids = {};
    const ORDERS = [];
    let server;
    let adminS;
    let downloads = 0;

    function orderDoc(id, who, shop, status, ts, extra = {}) {
      const p = PEOPLE[who];
      const qty = 1 + (id.length % 3);
      const price = PRODUCTS[0].price;
      return {
        orderId: id, uid: uids[who], userUid: uids[who], salesmanUid: uids[who],
        salesmanEmail: p.email, salesmanId: p.code, salesmanCode: p.code, salesmanName: p.name,
        submittedByUid: uids[who], createdByUid: uids[who], branchId: 'B1', supervisorId: '',
        retailerId: shop.id, retailerName: shop.name, status,
        items: [{ productId: PRODUCTS[0].id, name: PRODUCTS[0].name, productName: PRODUCTS[0].name, quantity: qty, price }],
        totalProducts: 1, totalBoxes: qty, totalPrice: Math.round(price * qty * 100) / 100,
        submittedAt: new Date(ts), createdAt: new Date(ts), ...extra,
      };
    }
    async function seedOrder(key, who, shop, status, ts, extra = {}) {
      const id = `ORD-E2E-${key}`;
      ORDERS.push({ id, ts, who, shop, status, demo: extra.isDemo === true });
      await db.put('orders', id, orderDoc(id, who, shop, status, ts, extra));
    }
    const pick = (pred) => ORDERS.filter((o) => !o.demo && pred(o)).sort((a, b) => b.ts - a.ts);
    const ids = (rows) => rows.map((o) => o.id).sort();
    const countOf = (who, pred = () => true) => pick((o) => o.who === who && pred(o)).length;
    const thisWeek = (o) => o.ts >= weekStart && o.ts < weekStart + 7 * DAY;
    const lastWeek = (o) => o.ts >= lastWeekStart && o.ts < weekStart;
    const thisMonth = (o) => o.ts >= monthStart && o.ts < nextMonthStart;

    const page = () => adminS.page;
    const find = (re) => page().getByLabel(re).or(page().getByText(re));
    const say = async (text) => {
      await B.fillField(page(), page().getByRole('textbox').last(), text);
      await page().keyboard.press('Enter');
    };
    const ask = async (text, re, { timeout = 30000 } = {}) => {
      const before = await find(re).count();
      await say(text);
      const end = Date.now() + timeout;
      while (Date.now() < end) {
        if ((await find(re).count()) > before) return;
        await page().waitForTimeout(150);
      }
      throw new Error(`after "${text}" expected a new reply matching ${re}, but none appeared`);
    };
    const resultLine = (n, ...parts) => new RegExp(
      `\\b${n} orders? ${DOT} ${parts.map((p) => `(?=[^]*${p})`).join('')}`);
    const startOver = async () => {
      await say('start over');
      await page().waitForTimeout(1200);
    };
    const buttons = (name) => page().getByRole('button', { name, exact: true });
    const download = async (label) => {
      const [dl] = await Promise.all([
        page().waitForEvent('download', { timeout: 20000 }),
        buttons('Download CSV').click(),
      ]);
      const file = path.join(OUT, `${label}.csv`);
      await dl.saveAs(file);
      const text = fs.readFileSync(file, 'utf8').replace(/^﻿/, '');
      const lines = text.split(/\r?\n/).filter((l) => l !== '');
      return { filename: dl.suggestedFilename(), text, header: lines[0], rows: lines.slice(1), ids: lines.slice(1).map((l) => l.split(',')[0]) };
    };
    const audits = async () => (await db.list('system_audit_logs')).filter((a) => a.action === 'copilot_order_export');

    try {
      fs.mkdirSync(OUT, { recursive: true });

      await t.step('seed three salespeople and orders in the production shape (KL-relative dates)', async () => {
        for (const [key, person] of Object.entries(PEOPLE)) uids[key] = await putPerson(db, person);
        await db.put('retailers', SHOPS.formula.id, {
          retailerId: SHOPS.formula.id, retailerName: SHOPS.formula.name, name: SHOPS.formula.name,
          branchId: 'B1', status: 'active', area: 'Tabuan',
        });
        const wk = (min) => weekStart + min * MIN;
        const A = [
          ['A01', SHOPS.choice, '', 1], ['A02', SHOPS.choice, 'submitted', 10], ['A03', SHOPS.choice, 'submitted', 15],
          ['A04', SHOPS.choice, 'submitted', 20], ['A05', SHOPS.emart, 'approved', 25], ['A06', SHOPS.emart, 'approved', 30],
          ['A07', SHOPS.emart, 'approved', 35], ['A08', SHOPS.emart, 'approved', 40], ['A09', SHOPS.formula, 'approved', 45],
          ['A10', SHOPS.formula, 'approved', 50], ['A11', SHOPS.formula, 'rejected', 55], ['A12', SHOPS.formula, 'rejected', 60],
        ];
        for (const [key, shop, status, min] of A) await seedOrder(key, 'ahmadAli', shop, status, wk(min));
        await seedOrder('A-PRE', 'ahmadAli', SHOPS.choice, 'approved', weekStart - MIN);
        await seedOrder('A-SUN', 'ahmadAli', SHOPS.choice, 'submitted', weekStart - 12 * 3600e3);
        await seedOrder('A-LM', 'ahmadAli', SHOPS.emart, 'approved', lastMonthMid);
        await seedOrder('A-DEMO', 'ahmadAli', SHOPS.choice, 'approved', wk(70), { isDemo: true });
        await seedOrder('F01', 'ahmadFaizal', SHOPS.emart, 'submitted', wk(100));
        await seedOrder('F02', 'ahmadFaizal', SHOPS.emart, 'approved', wk(110));
        await seedOrder('F03', 'ahmadFaizal', SHOPS.emart, 'approved', wk(120));
        await seedOrder('F04', 'ahmadFaizal', SHOPS.emart, 'rejected', wk(130));
        await seedOrder('F-LW', 'ahmadFaizal', SHOPS.emart, 'submitted', lastWeekStart + 3 * DAY);
        await seedOrder('F-LM', 'ahmadFaizal', SHOPS.emart, 'submitted', lastMonthMid);
        await seedOrder('G01', 'gopal', SHOPS.choice, 'approved', wk(200));
        await seedOrder('G02', 'gopal', SHOPS.choice, 'approved', wk(190));
        await seedOrder('G03', 'gopal', SHOPS.choice, 'submitted', wk(180));
        await seedOrder('G04', 'gopal', SHOPS.emart, 'approved', wk(170));
        await seedOrder('G05', 'gopal', SHOPS.formula, 'rejected', wk(160));
        await seedOrder('G-LW', 'gopal', SHOPS.choice, 'approved', lastWeekStart + 2 * DAY + 12 * 3600e3);
        await seedOrder('G-OLD', 'gopal', SHOPS.choice, 'approved', lastWeekStart - MIN);
        await seedOrder('G-LM', 'gopal', SHOPS.choice, 'submitted', lastMonthMid);
        expectEqual(countOf('ahmadAli', thisWeek), 12, 'seeded Ahmad bin Ali orders this week');
      });

      await t.step('admin logs in and opens the copilot', async () => {
        server = await fake.start();
        adminS = await t.session('admin', { acceptDownloads: true });
        adminS.page.on('download', () => { downloads += 1; });
        await B.loginAdmin(page(), adminS.url, accounts.admin.email);
        await admin.waitForShell(page());
        await page().getByRole('button', { name: /^Scout\b/ }).first().click();
        await B.see(page(), 'Scout panel');
      });

      await t.step('"show Ahmad\'s orders this week" offers both Ahmads instead of picking one', async () => {
        await say("show Ahmad's orders this week");
        await B.see(page(), 'Which one do you mean');
        await B.see(page(), `1. Ahmad bin Ali ${DOT} S002 ${DOT} salesperson`);
        await B.see(page(), `2. Ahmad Faizal ${DOT} S003 ${DOT} salesperson`);
        expectEqual(await find(new RegExp(`\\d+ orders? ${DOT} `)).count(), 0, 'result lines before the choice is made');
        expectEqual(await page().getByText(/Opened All Orders/).count(), 0, 'page opened by a search sentence');
      });

      await t.step('"the first one" shows only Ahmad bin Ali\'s 12 orders this week', async () => {
        const mine = pick((o) => o.who === 'ahmadAli' && thisWeek(o));
        expectEqual(mine.length, 12, 'expected orders');
        await ask('the first one', resultLine(12, 'Ahmad bin Ali \\(S002\\)', 'this week \\('));
        await B.see(page(), /4 submitted, 6 approved, 2 rejected/);
        await t.shot(adminS, 'ahmad-this-week');
      });

      await t.step('Malay "tunjuk pesanan Gopal minggu ini" shows Gopal\'s orders', async () => {
        const n = countOf('gopal', thisWeek);
        expectEqual(n, 5, 'expected Gopal orders');
        await ask('tunjuk pesanan Gopal minggu ini', resultLine(n, 'Gopal a/l Muthu \\(S004\\)', 'this week \\('));
        await B.see(page(), /1 submitted, 3 approved, 1 rejected/);
      });

      await t.step('"only Choice Supermarket" narrows the same salesperson and period', async () => {
        const n = countOf('gopal', (o) => thisWeek(o) && o.shop === SHOPS.choice);
        expectEqual(n, 3, 'expected Gopal + Choice orders');
        await ask('only Choice Supermarket', resultLine(n, 'Gopal a/l Muthu', 'Choice Supermarket', 'this week \\('));
      });

      await t.step('"just the approved ones" keeps salesperson, retailer and period', async () => {
        const n = countOf('gopal', (o) => thisWeek(o) && o.shop === SHOPS.choice && o.status === 'approved');
        expectEqual(n, 2, 'expected Gopal + Choice + approved orders');
        await ask('just the approved ones', resultLine(n, 'Gopal a/l Muthu', 'Choice Supermarket', 'this week \\(', 'approved'));
      });

      await t.step('"open the second one" opens the order dialog without Approve or Reject', async () => {
        const dialogs = page().getByRole('dialog');
        const before = await dialogs.count();
        await say('open the second one');
        const end = Date.now() + 20000;
        while (Date.now() < end && (await dialogs.count()) <= before) await page().waitForTimeout(150);
        expectEqual((await dialogs.count()) > before, true, 'a new dialog opened');
        const second = 'Gopal a/l Muthu';
        const dialog = dialogs.last();
        await dialog.getByText(second).or(dialog.getByLabel(second)).first().waitFor({ timeout: 20000 });
        expectEqual(await page().getByRole('button', { name: /^(Approve|Reject)/i }).count(), 0, 'Approve/Reject buttons in the read-only dialog');
        await t.shot(adminS, 'order-dialog-readonly');
        await page().keyboard.press('Escape');
        const closeEnd = Date.now() + 10000;
        while (Date.now() < closeEnd && (await dialogs.count()) > before) await page().waitForTimeout(150);
        expectEqual(await dialogs.count(), before, 'dialogs after closing');
      });

      await t.step('"export these" shows a card and downloads nothing yet; Cancel drops it', async () => {
        await say('export these');
        await B.see(page(), /Download 2 orders/);
        await buttons('Download CSV').waitFor();
        await buttons('Cancel').waitFor();
        expectEqual(downloads, 0, 'downloads before confirming');
        expectEqual((await audits()).length, 0, 'audit entries before confirming');
        await buttons('Cancel').click();
        await buttons('Download CSV').waitFor({ state: 'hidden' });
        expectEqual(downloads, 0, 'downloads after Cancel');
        expectEqual((await audits()).length, 0, 'audit entries after Cancel');
        await say('export these');
        await buttons('Download CSV').waitFor();
      });

      await t.step('Download CSV saves exactly the shown filtered rows', async () => {
        const want = ids(pick((o) => o.who === 'gopal' && thisWeek(o) && o.shop === SHOPS.choice && o.status === 'approved'));
        expectEqual(want, ['ORD-E2E-G01', 'ORD-E2E-G02'], 'expected ids');
        const file = await download('export_gopal_choice_approved');
        expectEqual(downloads, 1, 'downloads');
        if (!/^orders_.*\.csv$/.test(file.filename) || /partial/.test(file.filename)) throw new Error(`unexpected file name ${file.filename}`);
        expectEqual(file.header, 'Order ID,Date,Retailer,Salesman,Status,Items,Total Qty,Total Value', 'CSV header');
        expectEqual([...file.ids].sort(), want, 'CSV order ids');
      });

      await t.step('the export writes an assistant audit entry', async () => {
        const entry = await db.waitForQuery('system_audit_logs',
          (a) => a.action === 'copilot_order_export' && a.metadata && a.metadata.rowCount === 2, { label: 'copilot_order_export audit (2 rows)' });
        expectEqual(entry.metadata.source, 'assistant', 'audit source');
        expectEqual(entry.metadata.rowCount, 2, 'audit rowCount');
      });

      await t.step('"open all orders" still opens the All Orders page', async () => {
        await ask('open all orders', /Opened All Orders/);
        const messages = await page().evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
          .filter((node) => !node.querySelector('flt-semantics'))
          .map((node) => (node.getAttribute('aria-label') || node.textContent || '').trim()));
        const sent = messages.lastIndexOf('open all orders');
        expectEqual(sent >= 0, true, 'the sent command is in the chat');
        const resultLine = new RegExp(`^\\d+ orders? ${DOT} `);
        expectEqual(messages.slice(sent + 1).filter((text) => resultLine.test(text)), [], 'search results added by a page command');
      });

      await t.step('exporting 12 orders gives all 12 rows (not the 10 shown), formula guarded, with its own audit entry', async () => {
        await startOver();
        const want = ids(pick((o) => o.who === 'ahmadAli' && thisWeek(o)));
        expectEqual(want.length, 12, 'expected ids');
        await ask('show orders by Ahmad bin Ali this week', resultLine(12, 'Ahmad bin Ali', 'this week \\('));
        await say('export these');
        await B.see(page(), /Download 12 orders/);
        const file = await download('export_ahmad_bin_ali_this_week');
        if (!/^orders_.*\.csv$/.test(file.filename) || /partial/.test(file.filename)) throw new Error(`unexpected file name ${file.filename}`);
        expectEqual(file.header, 'Order ID,Date,Retailer,Salesman,Status,Items,Total Qty,Total Value', 'CSV header');
        expectEqual([...file.ids].sort(), want, 'CSV order ids');
        expectEqual(file.ids.length > 10, true, 'more rows than the 10 displayed');
        if (!file.text.includes("'=SUM(1,2) Kedai Formula")) throw new Error("the formula retailer cell must start with an apostrophe: '=SUM(1,2) Kedai Formula");
        if (/(^|,)"?=/m.test(file.text)) throw new Error('an unguarded cell starting with = is in the CSV');
        const entry = await db.waitForQuery('system_audit_logs',
          (a) => a.action === 'copilot_order_export' && a.metadata && a.metadata.rowCount === 12, { label: 'copilot_order_export audit (12 rows)' });
        expectEqual(entry.metadata.source, 'assistant', 'audit source');
        expectEqual((await audits()).length, 2, 'audit entries');
      });

      await t.step('a status-first sentence "pending approvals" counts all waiting orders, all time', async () => {
        await startOver();
        const n = pick((o) => WAITING.has(o.status)).length;
        expectEqual(n > 0, true, 'expected pending orders');
        await ask('pending approvals', new RegExp(`\\b${n} waiting for approval \\(all time\\)\\. Newest ${Math.min(n, 10)} shown\\.`));
        expectEqual(await page().getByText(/I did not understand/).count(), 0, 'unknown-sentence replies');
      });

      await t.step('"retailer brief for Choice Supermarket this week" summarises that shop, and Malay and the daily briefing stay separate', async () => {
        await startOver();
        const rm = (v) => `RM ${v.toFixed(2).replace(/\B(?=(\d{3})+(?!\d))/g, ',')}`;
        const value = (o) => Math.round(PRODUCTS[0].price * (1 + (o.id.length % 3)) * 100) / 100;
        const shop = pick((o) => o.shop === SHOPS.choice && thisWeek(o));
        const live = shop.filter((o) => o.status !== 'rejected');
        const total = live.reduce((sum, o) => sum + value(o), 0);
        const waiting = shop.filter((o) => SUBMITTED.has(o.status));
        const waitingValue = waiting.reduce((sum, o) => sum + value(o), 0);
        expectEqual(shop.length, 7, 'expected Choice orders this week');
        await ask('retailer brief for Choice Supermarket this week',
          new RegExp(`Brief ${DOT} Choice Supermarket Tabuan Jaya[^\\n]*this week \\(`));
        await B.see(page(), new RegExp(`${shop.length} orders, ${rm(total).replace('.', '\\.')} \\(average ${rm(total / live.length).replace('.', '\\.')}\\)`));
        await B.see(page(), new RegExp(`Waiting for approval: ${waiting.length} orders, ${rm(waitingValue).replace('.', '\\.')}`));
        await B.see(page(), /Ordered by: Ahmad bin Ali \(4\), Gopal a\/l Muthu \(3\)/);
        await B.see(page(), /1\. ORD-E2E-/);
        await say('export these');
        await B.see(page(), new RegExp(`Download ${shop.length} orders`));
        await buttons('Cancel').click();

        const emart = pick((o) => o.shop === SHOPS.emart && thisWeek(o));
        await ask('ringkasan kedai Emart Moyan minggu ini',
          new RegExp(`Brief ${DOT} Emart Moyan[^\\n]*this week \\(`));
        await B.see(page(), new RegExp(`${emart.length} orders, RM`));

        const briefs = await page().getByText(/Brief · /).count();
        await say('brief me on today');
        await page().waitForTimeout(1500);
        expectEqual(await page().getByText(/Brief · /).count(), briefs, 'retailer briefs started by the daily briefing sentence');
        expectEqual(await page().getByText(/I cannot find a (?:salesperson|retailer)/).count(), 0, 'not-found replies for the daily briefing sentence');
      });

      await t.step('the hosted model path: a vague sentence searches, "send that to a spreadsheet" exports, a shop named as a person resolves as the shop', async () => {
        await B.see(page(), /assistant model on/, { timeout: 40000 });
        await startOver();
        const lw = pick((o) => o.shop === SHOPS.choice && lastWeek(o));
        expectEqual(ids(lw), ['ORD-E2E-A-PRE', 'ORD-E2E-A-SUN', 'ORD-E2E-G-LW'], 'expected Choice orders last week');
        await ask('grab kedai stuff from last week', resultLine(lw.length, 'Choice Supermarket', 'last week \\('));
        await say('send that to a spreadsheet');
        await B.see(page(), new RegExp(`Download ${lw.length} orders`));
        const file = await download('export_choice_last_week_model');
        expectEqual([...file.ids].sort(), ids(lw), 'CSV order ids from the model export');
        const cannot = await page().getByText(/I cannot find a salesperson or retailer/).count();
        await ask('what did choice supermarket sell', new RegExp(`\\d+ orders? ${DOT} (?=[^]*Choice Supermarket Tabuan Jaya)`));
        expectEqual(await page().getByText(/I cannot find a salesperson or retailer/).count(), cannot, 'not-found replies for a shop named as a person');
        const sent = server.requests.map((r) => r.text);
        for (const text of ['grab kedai stuff from last week', 'send that to a spreadsheet', 'what did choice supermarket sell']) {
          if (!sent.includes(text)) throw new Error(`"${text}" never reached the model server (grammar answered it instead)`);
        }
      });

      await t.step('"orders last month" reports a truncated window and marks the export partial', async () => {
        const base = lastMonthMid;
        await putMany(db, 'orders', Array.from({ length: 2000 }, (_, i) => {
          const id = `ORD-E2E-BULK-${String(i).padStart(4, '0')}`;
          return { id, data: orderDoc(id, 'ahmadFaizal', SHOPS.emart, 'submitted', base - (i + 1) * MIN) };
        }));
        await startOver();
        await ask('orders last month', /At least 2,000 orders/);
        await say('export these');
        await B.see(page(), /newest 2,000 orders only/);
        const file = await download('export_last_month_partial');
        if (!/^orders_.*\.csv$/.test(file.filename) || !/partial/.test(file.filename)) throw new Error(`expected a partial file name, got ${file.filename}`);
        expectEqual(file.ids.length >= 2000, true, 'rows in the partial export');
        const entry = await db.waitForQuery('system_audit_logs',
          (a) => a.action === 'copilot_order_export' && a.metadata && a.metadata.truncated === true, { label: 'truncated export audit' });
        expectEqual(entry.metadata.source, 'assistant', 'audit source');
      });
    } finally {
      if (server) await server.close();
    }
  },
};
