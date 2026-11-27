'use strict';

const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const FIRST = RETAILERS[0];
const SECOND = RETAILERS[1];
const THIRD_NAME = 'Emart Matang';
const NEW_ITEM = 'INSTANT BABY OAT (24P X 450G)';
const SECOND_ITEM = 'MILK BISCUIT (12P X 200G)';
const OLD_ITEM = 'REGULAR ROLLED OAT (24P X 450G)';
const CANCELLED_ITEM = 'CANCELLED ORDER ITEM';
const FOCUS_PRODUCT = 'INSTANT BABY OAT';
const FOCUS_SIGNAL = 'Orders dropped three weeks in a row.';
const FOCUS_ACTION = 'Ask about shelf space.';
const FOCUS_QUESTIONS = ['Is the shelf space still the same?', 'Did a cheaper brand come in?'];
const FORMULA_REASON = 'Prioritised: overdue 14d, high forecast demand, high value.';
const RANKED_REASON = 'Reorder overdue: INSTANT BABY OAT, usually orders every 14 days, last order 30 days ago. Expected order RM 580.';
const OPEN_NOTE = 'shelf space';
const DONE_NOTE = 'price talk';
const NEWER_DAYS = 12;
const NEWER_TOTAL = 284.4;
const SUGGESTED_QTY = 6;
const BRIEF_LAST_QTY = 6;
const BRIEF_LAST_DAYS = 12;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];

const dayMonth = (d) => `${d.getDate()} ${MONTHS[d.getMonth()]}`;
const dayMonthThisYear = (d, now) => (d.getFullYear() === now.getFullYear() ? dayMonth(d) : `${dayMonth(d)} ${d.getFullYear()}`);
const dateKey = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;
const exact = (text) => new RegExp(text.replace(/[.*+?^${}()|[\]\\]/g, '\\$&'));
const NEW_LINE_NO_UNIT = new RegExp(`${exact(`${NEW_ITEM}: 6`).source}(?![0-9]| ?[A-Za-z])`);
const NEEDS_SIGNAL = 'This question needs a signal. Try: next stop, brief, last order, follow-ups.';

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

function textsAfter(page, question) {
  return page.evaluate(([q]) => {
    const texts = Array.from(document.querySelectorAll('flt-semantics'))
      .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean);
    const at = texts.lastIndexOf(q);
    return at < 0 ? null : texts.slice(at + 1);
  }, [question]);
}

async function answerTo(page, question, wanted, timeout = 25000) {
  const patterns = wanted.map((w) => (w instanceof RegExp ? w : exact(w)));
  const end = Date.now() + timeout;
  let after = null;
  while (Date.now() < end) {
    after = await textsAfter(page, question);
    if (after && patterns.every((p) => after.some((x) => p.test(x)))) return after;
    await page.waitForTimeout(200);
  }
  const missing = patterns.filter((p) => !(after || []).some((x) => p.test(x))).map(String);
  throw new Error(`after "${question}" these did not appear: ${missing.join(' | ')}\nshown: ${JSON.stringify(after)}`);
}

function placesAfter(page, question, sources) {
  return page.evaluate(([q, wantedSources]) => {
    const label = (n) => (n.getAttribute('aria-label') || n.textContent || '').trim();
    const box = (n) => {
      const r = n.getBoundingClientRect();
      return { top: Math.round(r.top), bottom: Math.round(r.bottom), left: Math.round(r.left), right: Math.round(r.right), area: r.width * r.height };
    };
    const nodes = Array.from(document.querySelectorAll('flt-semantics'));
    const close = nodes.filter((n) => label(n) === 'Close Scout').sort((a, b) => box(a).area - box(b).area)[0];
    const input = document.querySelector('flt-semantics-host textarea, flt-semantics-host input, flt-text-editing-host textarea, flt-text-editing-host input, textarea, input');
    const hints = nodes.filter((n) => /^(next, you could ask|try asking)$/i.test(label(n))).map(box).filter((b) => b.area > 0);
    let at = -1;
    nodes.forEach((n, i) => { if (label(n) === q) at = i; });
    const later = at < 0 ? [] : nodes.slice(at + 1);
    return {
      width: window.innerWidth,
      top: close ? box(close).bottom : null,
      bottom: input ? Math.min(box(input).top, ...hints.map((b) => b.top)) : null,
      lines: wantedSources.map((source) => {
        const pattern = new RegExp(source);
        const hits = later.filter((n) => pattern.test(label(n))).map(box).filter((b) => b.area > 0).sort((a, b) => a.area - b.area);
        return { source, box: hits[0] || null };
      }),
    };
  }, [question, sources]);
}

async function answerIsOnScreen(page, question, wanted, timeout = 5000) {
  const sources = wanted.map((w) => (w instanceof RegExp ? w : exact(w)).source);
  const end = Date.now() + timeout;
  let seen = null;
  let hidden = [];
  while (Date.now() < end) {
    seen = await placesAfter(page, question, sources);
    if (seen.top === null || seen.bottom === null) throw new Error(`cannot measure the chat area: Close Scout bottom ${seen.top}, text box top ${seen.bottom}`);
    hidden = seen.lines.filter((line) => !line.box || line.box.top < seen.top || line.box.bottom > seen.bottom || line.box.left < 0 || line.box.right > seen.width);
    if (!hidden.length) return;
    await page.waitForTimeout(200);
  }
  throw new Error(`after "${question}" the answer is not inside the visible chat area (top ${seen.top}, bottom ${seen.bottom}, width ${seen.width}): ${JSON.stringify(hidden)}`);
}

function mustNotShow(after, forbidden, question) {
  for (const text of forbidden) {
    const hit = after.find((x) => x.includes(text));
    if (hit) throw new Error(`after "${question}" the answer showed "${text}": ${hit.slice(0, 160)}`);
  }
}

module.exports = {
  name: 'mobile_scout_conversation',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const now = new Date();
    const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
    const daysFromNoon = (n) => new Date(noon.getTime() + n * 86400000);
    const newerAt = daysFromNoon(-NEWER_DAYS);
    const followUpOn = daysFromNoon(8);
    let sales;

    await t.step('seed: two stops with reasons, briefs with questions and a usual order day, three orders for one shop, two follow-ups', async () => {
      const stop = (r, n, reason) => ({
        stopId: `stop-${n}`, dayId: 'day-1', retailerId: r.id, retailerName: r.name, address: `${r.area}, Kuching`,
        lat: r.lat, lng: r.lng, sequence: n, estimatedArrival: n === 1 ? '09:00' : '10:30', estimatedDeparture: n === 1 ? '09:20' : '10:50',
        priorityReason: reason, status: 'not_started', travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
      });
      await db.put('route_plans', 'plan-e2e-scout-talk', {
        planId: 'plan-e2e-scout-talk', createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
        salesmanName: accounts.salesman.name, branchId: 'B1',
        weekStart: daysFromNoon(-6), weekEnd: daysFromNoon(1),
        publishedAt: now, status: 'published', source: 'dashboard', totalStops: 2, stopIds: ['stop-1', 'stop-2'],
        stopRetailerIds: { 'stop-1': FIRST.id, 'stop-2': SECOND.id },
        days: [{ dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 7, stops: [stop(FIRST, 1, FORMULA_REASON), stop(SECOND, 2, RANKED_REASON)] }],
      });
      const brief = (id, r, extra) => db.put('visit_briefs', id, {
        briefId: id, retailerId: r.id, retailerName: r.name, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', insightCount: 1, highPriorityCount: 1,
        totalValueAtRiskRm: 120, isDemo: false, updatedAt: now, emptyStateHeadline: '', emptyStateBody: '',
        focusItems: [{
          issueId: `issue-${id}`, issueKey: 'low_sell_through:prod-2', type: 'low_sell_through', priority: 'high', confidence: 'high',
          productId: 'prod-2', productName: FOCUS_PRODUCT, signal: FOCUS_SIGNAL,
          action: FOCUS_ACTION, questions: FOCUS_QUESTIONS, valueAtRiskRm: 120, occurrenceCount: 1, autoState: 'active',
        }],
        ...extra,
      });
      await brief('brief-e2e-talk-1', FIRST, {
        usualOrderWeekday: 2,
        replenishment: [{
          retailerId: FIRST.id, productId: 'prod-2', productName: FOCUS_PRODUCT, suggestedQty: SUGGESTED_QTY, confidence: 0.8,
          confidenceLabel: 'high', rationale: 'Run-rate 0.5/day projects 6 units over the gap',
          inputs: { lastOrderQty: BRIEF_LAST_QTY, lastOrderDaysAgo: BRIEF_LAST_DAYS, runRatePerDay: 0.5, patternMeanQty: 6 },
        }],
      });
      await brief('brief-e2e-talk-2', SECOND, { usualOrderWeekday: 7 });

      const order = (id, retailerId, retailerName, at, total, items, status = 'submitted') => db.put('orders', id, {
        orderId: id, retailerId, retailerName, outlet: retailerName, branchId: 'B1',
        uid, userUid: uid, salesmanUid: uid, salesmanCode: accounts.salesman.code, salesmanId: accounts.salesman.code,
        status, totalProducts: items.length, totalBoxes: items.reduce((sum, i) => sum + i.qty, 0), totalPrice: total, items,
        submittedAt: at, createdAt: at,
      });
      await order('ORD-TALK-OLD', FIRST.id, FIRST.name, daysFromNoon(-20), 45.05, [{ name: OLD_ITEM, productName: OLD_ITEM, qty: 5, price: 9.01 }]);
      await order('ORD-TALK-NEWER', FIRST.id, FIRST.name, newerAt, NEWER_TOTAL, [
        { name: NEW_ITEM, productName: NEW_ITEM, qty: 6, price: 30.4 },
        { name: SECOND_ITEM, productName: SECOND_ITEM, qty: 4, price: 25.5, uom: 'pcs' },
      ]);
      await order('ORD-TALK-CANCELLED', FIRST.id, FIRST.name, daysFromNoon(-1), 999, [{ name: CANCELLED_ITEM, productName: CANCELLED_ITEM, qty: 9, price: 111 }], 'cancelled');
      await order('ORD-TALK-THIRD', 'ret-e2e-third', THIRD_NAME, daysFromNoon(-3), 50, [{ name: OLD_ITEM, productName: OLD_ITEM, qty: 1, price: 50 }]);

      const outcome = (id, r, note, date, status) => db.put('conversation_outcomes', id, {
        outcomeId: id, outcomeKind: 'no_order', salesmanUid: uid, salesmanCode: accounts.salesman.code, branchId: 'B1',
        retailerId: r.id, retailerName: r.name, planId: 'plan-e2e-scout-talk', stopId: 'stop-2', reasonCode: 'shelf_space_limited', note,
        source: 'mobile_assigned_route_no_order', isDemo: false, clientCreatedAt: now, submittedAt: now,
        followUpDate: dateKey(date), followUpStatus: status,
      });
      await outcome('outcome-e2e-talk-open', SECOND, OPEN_NOTE, followUpOn, 'open');
      await outcome('outcome-e2e-talk-done', FIRST, DONE_NOTE, daysFromNoon(3), 'completed');
    });

    await t.step('salesperson signs in and opens Scout', async () => {
      sales = await t.session('mobile', { viewport: { width: 430, height: 900 } });
      await B.loginMobile(sales.page, sales.url, accounts.salesman.email);
      await mobile.waitForHome(sales.page);
      await sales.page.waitForTimeout(4000);
      await sales.page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      await B.see(sales.page, 'Ask about your route, orders and visit briefs.');
    });

    let before;
    await t.step('baseline snapshot of every Firestore document', async () => {
      before = await snapshot();
      if (!before['conversation_outcomes/outcome-e2e-talk-open']) throw new Error('fixture follow-up missing');
    });

    const ask = async (text) => {
      await B.fillField(sales.page, sales.page.getByRole('textbox'), text);
      await sales.page.getByRole('button', { name: 'Send', exact: true }).click();
    };

    await t.step('with nothing remembered, "what should I say there?" asks which shop', async () => {
      const question = 'what should I say there?';
      await ask(question);
      const after = await answerTo(sales.page, question, ['Which shop do you mean?']);
      mustNotShow(after, [FOCUS_SIGNAL], question);
    });

    await t.step('a name that matches two shops asks which one and lists both', async () => {
      const question = 'why am I going to emart?';
      await ask(question);
      await answerTo(sales.page, question, ['Which shop do you mean?', SECOND.name, THIRD_NAME]);
      await t.shot(sales, 'which-shop');
    });

    await t.step('"why am I going to <shop>?" -> the stored reason in plain words, numbers kept', async () => {
      const question = `why am I going to ${FIRST.name}?`;
      await ask(question);
      const after = await answerTo(sales.page, question, [
        `${FIRST.name} is on your route today for this reason.`, 'Overdue 14 days', 'High demand expected', 'High value shop',
      ]);
      mustNotShow(after, ['forecast demand', 'Prioritised', '14d'], question);
      await answerIsOnScreen(sales.page, question, [`${FIRST.name} is on your route today for this reason.`, 'High value shop']);
      await t.shot(sales, 'why-stop');
    });

    await t.step('"and what should I say there?" -> the focus item, its questions and the next step for the remembered shop', async () => {
      const question = 'and what should I say there?';
      await ask(question);
      await answerTo(sales.page, question, [
        `At ${FIRST.name}, talk about this point.`, `${FOCUS_PRODUCT}: ${FOCUS_SIGNAL}`,
        ...FOCUS_QUESTIONS.map((q) => `Ask: ${q}`), `Next: ${FOCUS_ACTION}`,
      ]);
      await t.shot(sales, 'what-to-say');
    });

    await t.step('"what did they order last time?" -> the newest order that is not cancelled, real days, each line, a unit only where the order stores one, the amount', async () => {
      const question = 'what did they order last time?';
      await ask(question);
      const after = await answerTo(sales.page, question, [
        `Last order for ${FIRST.name} was on ${dayMonth(newerAt)} ${newerAt.getFullYear()}, ${NEWER_DAYS} days ago.`,
        NEW_LINE_NO_UNIT, `${SECOND_ITEM}: 4 pcs`, `Total RM ${NEWER_TOTAL.toFixed(2)}`,
      ]);
      mustNotShow(after, [CANCELLED_ITEM, OLD_ITEM, 'RM 999', 'ORD-TALK', 'boxes', '6 box', '6 ctn', '6 pcs', '6 unit'], question);
      await answerIsOnScreen(sales.page, question, [`Last order for ${FIRST.name} was on`, `Total RM ${NEWER_TOTAL.toFixed(2)}`]);
      await t.shot(sales, 'last-order');
    });

    await t.step('"when do they usually order?" -> the stored weekday 2 as Tuesday', async () => {
      const question = 'when do they usually order?';
      await ask(question);
      await answerTo(sales.page, question, [`${FIRST.name} usually orders on Tuesday.`]);
    });

    await t.step('"and the next one?" -> the same question for the next stop; weekday 7 counts as none', async () => {
      const question = 'and the next one?';
      await ask(question);
      const after = await answerTo(sales.page, question, [`I do not have a usual order day for ${SECOND.name} yet.`]);
      mustNotShow(after, ['Sunday'], question);
    });

    await t.step('"why this stop" -> the remembered second stop; a reason sentence that is already plain is shown unchanged', async () => {
      const question = 'why this stop';
      await ask(question);
      await answerTo(sales.page, question, [`${SECOND.name} is on your route today for this reason.`, RANKED_REASON]);
    });

    await t.step('"who did I promise to visit again?" -> only the open follow-up, with its date, shop and note', async () => {
      const question = 'who did I promise to visit again?';
      await ask(question);
      const after = await answerTo(sales.page, question, [
        'You have 1 open follow-up.', `${dayMonthThisYear(followUpOn, now)}: ${SECOND.name}, ${OPEN_NOTE}`,
      ]);
      mustNotShow(after, [DONE_NOTE, 'outcome-e2e'], question);
      await answerIsOnScreen(sales.page, question, ['You have 1 open follow-up.', `${dayMonthThisYear(followUpOn, now)}: ${SECOND.name}, ${OPEN_NOTE}`]);
      await t.shot(sales, 'follow-ups');
    });

    await t.step('"what is my next stop?" -> the stop, with one reason line and the first focus item', async () => {
      const question = 'what is my next stop?';
      await ask(question);
      await answerTo(sales.page, question, [
        `Your next stop is ${FIRST.name}.`, 'Expected arrival 09:00',
        'Why: Overdue 14 days, High demand expected, High value shop', `Focus: ${FOCUS_PRODUCT}: ${FOCUS_SIGNAL}`,
      ]);
      await t.shot(sales, 'next-stop');
    });

    await t.step('"show the visit brief for <shop>" -> the brief date and the reorder suggestion in plain words', async () => {
      const question = `show the visit brief for ${FIRST.name}`;
      await ask(question);
      const after = await answerTo(sales.page, question, [
        `Visit brief for ${FIRST.name}`, `Updated ${dayMonth(now)}`, `${FOCUS_PRODUCT}: ${FOCUS_SIGNAL} Next: ${FOCUS_ACTION}`,
        `Suggest ${SUGGESTED_QTY} of ${FOCUS_PRODUCT}. Last order ${BRIEF_LAST_QTY}, ${BRIEF_LAST_DAYS} days ago.`,
      ]);
      mustNotShow(after, ['Run-rate', 'prod-2', 'brief-e2e'], question);
      await t.shot(sales, 'visit-brief');
    });

    await t.step('"help" lists what can be asked in groups and still says what Scout cannot do', async () => {
      await ask('help');
      await answerTo(sales.page, 'help', ['Route: What is my next stop?', 'Shop: What should I say at <shop>?', 'Orders: What did <shop> order last time?', 'Follow-ups: Who did I promise to visit again?', 'I cannot submit orders, complete visits or record outcomes']);
      await t.shot(sales, 'help');
    });

    await t.step('with no signal, a question that needs the server says so, and the last order still answers from the phone', async () => {
      await sales.context.setOffline(true);
      await sales.page.waitForTimeout(1500);
      const unknown = 'qwzx plorf blimmo';
      await ask(unknown);
      const refused = await answerTo(sales.page, unknown, [NEEDS_SIGNAL]);
      mustNotShow(refused, ['The Scout server is not available'], unknown);
      await t.shot(sales, 'no-signal-needs-server');
      const question = `what did ${FIRST.name} order last time?`;
      await ask(question);
      const after = await answerTo(sales.page, question, [
        `Last order for ${FIRST.name} was on ${dayMonth(newerAt)} ${newerAt.getFullYear()}, ${NEWER_DAYS} days ago.`,
        NEW_LINE_NO_UNIT, `${SECOND_ITEM}: 4 pcs`, `Total RM ${NEWER_TOTAL.toFixed(2)}`,
      ]);
      mustNotShow(after, [CANCELLED_ITEM, OLD_ITEM, 'RM 999', 'boxes', NEEDS_SIGNAL], question);
      await t.shot(sales, 'no-signal-last-order');
      await sales.context.setOffline(false);
    });

    await t.step('NOTHING was written: every document is unchanged', async () => {
      const after = await snapshot();
      const changed = [
        ...Object.keys(after).filter((k) => !(k in before)).map((k) => `added ${k}`),
        ...Object.keys(before).filter((k) => !(k in after)).map((k) => `removed ${k}`),
        ...Object.keys(before).filter((k) => k in after && after[k] !== before[k]).map((k) => `changed ${k}`),
      ];
      if (changed.length) throw new Error('Firestore changed during the Scout conversation: ' + changed.join(', '));
    });
  },
};
