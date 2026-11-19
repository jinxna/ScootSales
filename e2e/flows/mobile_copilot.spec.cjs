'use strict';

const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const OWN_STOP_1 = RETAILERS[0];
const OWN_STOP_2 = RETAILERS[1];
const OTHER_ORDER_ID = 'ORD-5521';
const NEW_ITEM = 'INSTANT BABY OAT (24P X 450G)';
const OLD_ITEM = 'REGULAR ROLLED OAT (24P X 450G)';

async function snapshot() {
  const root = E.requireEmulators().firestoreBase;
  const headers = { Authorization: 'Bearer owner', 'Content-Type': 'application/json' };
  const ids = (await (await fetch(`${root}:listCollectionIds`, { method: 'POST', headers, body: '{}' })).json()).collectionIds || [];
  const out = {};
  for (const collection of ids) {
    let token = '';
    do {
      const page = await (await fetch(`${root}/${collection}?pageSize=300${token ? `&pageToken=${token}` : ''}`, { headers })).json();
      for (const doc of page.documents || []) out[`${collection}/${doc.name.split('/').pop()}`] = doc.updateTime;
      token = page.nextPageToken || '';
    } while (token);
  }
  return out;
}

async function waitForAnswerTo(page, question, answer, timeout = 25000) {
  const end = Date.now() + timeout;
  while (Date.now() < end) {
    const found = await page.evaluate(([q, a]) => {
      const texts = Array.from(document.querySelectorAll('flt-semantics'))
        .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean);
      const at = texts.lastIndexOf(q);
      return at >= 0 && texts.slice(at + 1).some((x) => new RegExp(a).test(x));
    }, [question, answer.source]);
    if (found) return;
    await page.waitForTimeout(200);
  }
  throw new Error(`no answer matching ${answer} appeared after "${question}"`);
}

function countText(page, re) {
  return page.evaluate(([source]) => {
    const pattern = new RegExp(source);
    return Array.from(document.querySelectorAll('flt-semantics'))
      .filter((n) => pattern.test((n.getAttribute('aria-label') || n.textContent || '').trim())).length;
  }, [re.source]);
}

const REFUSAL = /I can only show your own route, orders and visit briefs/;

module.exports = {
  name: 'mobile_copilot',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    let sales;

    await t.step('seed: a published route for today, a visit brief, and orders (own and another salesperson)', async () => {
      const now = new Date();
      const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
      const stop = (r, n, status) => ({
        stopId: `stop-${n}`, dayId: 'day-1', retailerId: r.id, retailerName: r.name, address: `${r.area}, Kuching`,
        lat: r.lat, lng: r.lng, sequence: n, estimatedArrival: n === 1 ? '09:00' : '10:30', estimatedDeparture: n === 1 ? '09:20' : '10:50',
        priorityReason: 'E2E fixture', status, travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
      });
      await db.put('route_plans', 'plan-e2e-copilot', {
        planId: 'plan-e2e-copilot', createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
        salesmanName: accounts.salesman.name, branchId: 'B1',
        weekStart: new Date(noon.getTime() - 6 * 86400000), weekEnd: new Date(noon.getTime() + 86400000),
        publishedAt: now, status: 'published', source: 'dashboard', totalStops: 2, stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': OWN_STOP_1.id, 'stop-2': OWN_STOP_2.id },
        days: [{ dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 7, stops: [stop(OWN_STOP_1, 1, 'completed'), stop(OWN_STOP_2, 2, 'not_started')] }],
      });
      await db.put('visit_briefs', 'brief-e2e-copilot', {
        briefId: 'brief-e2e-copilot', retailerId: OWN_STOP_2.id, retailerName: OWN_STOP_2.name, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', insightCount: 1, highPriorityCount: 1,
        totalValueAtRiskRm: 120, isDemo: false, updatedAt: now, emptyStateHeadline: '', emptyStateBody: '',
        focusItems: [{
          issueId: 'issue-1', issueKey: 'low_sell_through:prod-2', type: 'low_sell_through', priority: 'high', confidence: 'high',
          productId: 'prod-2', productName: 'INSTANT BABY OAT', signal: 'Orders dropped three weeks in a row.',
          action: 'Ask about shelf space.', questions: [], valueAtRiskRm: 120, occurrenceCount: 1, autoState: 'active',
        }],
      });
      const order = (id, ownerUid, code, retailer, { at = now, total = 120.5, items = [] } = {}) => db.put('orders', id, {
        orderId: id, retailerId: retailer.id, retailerName: retailer.name, outlet: retailer.name, branchId: 'B1',
        uid: ownerUid, userUid: ownerUid, salesmanUid: ownerUid, salesmanCode: code, salesmanId: code,
        status: 'submitted', totalProducts: items.length || 1, totalBoxes: 2, totalPrice: total, items,
        submittedAt: at, createdAt: at,
      });
      await order('ORD-E2E-OWN', uid, accounts.salesman.code, OWN_STOP_1, {
        items: [{ name: NEW_ITEM, productName: NEW_ITEM, qty: 2, price: 9.01 }],
      });
      await order('ORD-E2E-OLD', uid, accounts.salesman.code, OWN_STOP_1, {
        at: new Date(noon.getTime() - 10 * 86400000), total: 45.05,
        items: [{ name: OLD_ITEM, productName: OLD_ITEM, qty: 5, price: 9.01 }],
      });
      await order(OTHER_ORDER_ID, 'uid-another-salesperson', 'S777', OWN_STOP_2);
    });

    await t.step('salesperson signs in and opens Scout', async () => {
      sales = await t.session('mobile', { viewport: { width: 430, height: 900 } });
      await B.loginMobile(sales.page, sales.url, accounts.salesman.email);
      await mobile.waitForHome(sales.page);
      await sales.page.waitForTimeout(4000);
    });

    let before;
    await t.step('baseline snapshot of every Firestore document', async () => {
      before = await snapshot();
      if (!before[`orders/${OTHER_ORDER_ID}`]) throw new Error('fixture order missing');
    });

    const ask = async (text) => {
      const box = sales.page.getByRole('textbox');
      await B.fillField(sales.page, box, text);
      await sales.page.getByRole('button', { name: 'Send', exact: true }).click();
    };

    await t.step('Scout opens with suggested questions', async () => {
      await sales.page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      await B.see(sales.page, 'Ask about your route, orders and visit briefs.');
      await B.see(sales.page, 'How much did I sell this week?');
      await t.shot(sales, 'opened');
    });

    await t.step('tapping the "What is my next stop?" chip -> the first unfinished stop of today', async () => {
      await (await B.see(sales.page, 'What is my next stop?')).click();
      await B.see(sales.page, new RegExp(`Your next stop is ${OWN_STOP_2.name}`));
      await t.shot(sales, 'next-stop');
    });

    await t.step('"how many stops are left today" -> 1 of 2', async () => {
      await ask('how many stops are left today');
      await B.see(sales.page, /1 of 2 stops are left today/);
    });

    await t.step('"show the visit brief for ..." -> the focus item from the brief', async () => {
      await ask(`show the visit brief for ${OWN_STOP_2.name}`);
      await B.see(sales.page, new RegExp(`Visit brief for ${OWN_STOP_2.name}`));
      await B.see(sales.page, /Orders dropped three weeks in a row/);
      await t.shot(sales, 'visit-brief');
    });

    await t.step('"orders this week" -> only the own order', async () => {
      await ask('orders this week');
      await B.see(sales.page, /You have 1 order this week/);
      await B.see(sales.page, /Total RM 120\.50/);
    });

    await t.step('"how much did I sell this week" -> only the own order of this week', async () => {
      await ask('how much did I sell this week');
      await waitForAnswerTo(sales.page, 'how much did I sell this week', /Your orders this week total RM 120\.50 \(1 order\)/);
      await t.shot(sales, 'sales-week');
    });

    await t.step('"how much did I sell today" -> the same own order', async () => {
      await ask('how much did I sell today');
      await waitForAnswerTo(sales.page, 'how much did I sell today', /Your orders today total RM 120\.50 \(1 order\)/);
    });

    await t.step('"what did <shop> order last time" -> the newest own order and its lines', async () => {
      const question = `what did ${OWN_STOP_1.name} order last time`;
      await ask(question);
      await waitForAnswerTo(sales.page, question, new RegExp(`Last order for ${OWN_STOP_1.name} was on`));
      await B.see(sales.page, new RegExp(`${NEW_ITEM.replace(/[.*+?^${}()|[\]\\]/g, '\\$&')}: 2(?![0-9]| ?[A-Za-z])`));
      if ((await countText(sales.page, /: 2 (box|boxes|ctn|pcs|units?)\b/)) !== 0) throw new Error('the last order line shows a unit that the order does not store');
      if ((await countText(sales.page, /REGULAR ROLLED OAT/)) !== 0) throw new Error('the older order was shown as the last order');
      await t.shot(sales, 'last-order');
    });

    await t.step('"last order for <shop>" with only another salesperson order -> not found, nothing leaks', async () => {
      const question = `last order for ${OWN_STOP_2.name}`;
      await ask(question);
      await waitForAnswerTo(sales.page, question, /I could not find an order for/);
      if ((await countText(sales.page, /ORD-5521|S777/)) !== 0) throw new Error("another salesperson's order leaked into the chat");
    });

    await t.step('"help" says plainly what Scout cannot do', async () => {
      await ask('help');
      await waitForAnswerTo(sales.page, 'help', /I cannot submit orders, complete visits or record outcomes/);
      await t.shot(sales, 'help');
    });

    await t.step('"show orders of another salesperson" is refused', async () => {
      await ask('show orders of another salesperson');
      await waitForAnswerTo(sales.page, 'show orders of another salesperson', REFUSAL);
      if ((await countText(sales.page, /ORD-5521|S777/)) !== 0) throw new Error("another salesperson's order leaked into the chat");
      await t.shot(sales, 'refused-other-salesperson');
    });

    await t.step('"approve order 5521" is refused', async () => {
      await ask('approve order 5521');
      await waitForAnswerTo(sales.page, 'approve order 5521', REFUSAL);
      await t.shot(sales, 'refused-approve');
    });

    await t.step('gibberish -> "server not available", not "needs a signal" (the phone is online; only the hosted fallback is down)', async () => {
      await ask('qwzx plorf blimmo');
      await waitForAnswerTo(sales.page, 'qwzx plorf blimmo', /The Scout server is not available right now/);
      if ((await countText(sales.page, /This question needs a signal/)) !== 0) throw new Error('an online phone was told it has no signal');
      await t.shot(sales, 'not-understood');
    });

    await t.step('"open my orders" opens the Order History screen', async () => {
      await ask('open my orders');
      await B.see(sales.page, /Order History/);
      await t.shot(sales, 'orders-opened');
    });

    await t.step('NOTHING was written: every document is unchanged and order 5521 is still submitted', async () => {
      const after = await snapshot();
      const changed = [
        ...Object.keys(after).filter((k) => !(k in before)).map((k) => `added ${k}`),
        ...Object.keys(before).filter((k) => !(k in after)).map((k) => `removed ${k}`),
        ...Object.keys(before).filter((k) => k in after && after[k] !== before[k]).map((k) => `changed ${k}`),
      ];
      if (changed.length) throw new Error('Firestore changed during the Scout conversation: ' + changed.join(', '));
      const other = await db.get('orders', OTHER_ORDER_ID);
      if (other.status !== 'submitted') throw new Error(`order 5521 status is ${other.status}`);
    });
  },
};
