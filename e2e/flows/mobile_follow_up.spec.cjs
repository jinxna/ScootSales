'use strict';

const B = require('../lib/browser.cjs');
const mobile = require('../lib/mobile.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const RETAILER = RETAILERS[0];
const SECOND_SHOP = RETAILERS[1];
const SECOND_NOTE = 'Manager is at the bank';
const DAY_MS = 86400000;
const MONTHS = ['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'];
const WEEKDAYS = ['Sun', 'Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat'];
const FOCUS_NAME = 'Instant Baby Oat';
const SIGNAL = 'Orders dropped three weeks in a row.';
const NOTE = 'Owner is away this week';
const BRIEF_ID = 'brief-e2e-follow-up';
const PLAN_ID = 'plan-e2e-follow-up';
const ISSUE_ID = 'issue-follow-up-1';
const FOLLOW_UP_KEYS = ['followUpDate', 'followUpStatus', 'followUpTime'];
const PROMISE = /You said you would come back/;

const dayLabel = (d) => `${d.getDate()} ${MONTHS[d.getMonth()]}`;
const chipDay = (d) => `${WEEKDAYS[d.getDay()]} ${dayLabel(d)}`;
const isoDate = (d) => `${d.getFullYear()}-${String(d.getMonth() + 1).padStart(2, '0')}-${String(d.getDate()).padStart(2, '0')}`;

const allText = (page) => page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
  .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));

async function expectNone(page, patterns, where) {
  const texts = await allText(page);
  if (texts.length < 5) throw new Error(`${where}: the page has almost no readable text (${texts.length} nodes)`);
  for (const re of patterns) {
    const hit = texts.find((x) => re.test(x));
    if (hit) throw new Error(`${where}: found ${re} in "${hit.slice(0, 140)}"`);
  }
}

const followUpKeysOf = (doc) => FOLLOW_UP_KEYS.filter((key) => key in doc);
const without = (doc, keys) => JSON.stringify(Object.keys(doc).filter((k) => !keys.includes(k)).sort().map((k) => [k, doc[k]]));

module.exports = {
  name: 'mobile_follow_up',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.salesman;
    const now = new Date();
    const noon = new Date(now.getFullYear(), now.getMonth(), now.getDate(), 12);
    const inDays = (n) => new Date(noon.getTime() + n * DAY_MS);
    const tomorrow = inDays(1);
    const nextVisit = inDays(3);
    const promiseLine = `You said you would come back on ${dayLabel(tomorrow)} about ${NOTE}.`;
    const issue = {
      issueId: ISSUE_ID, issueKey: `declining_sales::${RETAILER.id}::prod-2`, type: 'declining_sales',
      priority: 'high', confidence: 'high', productId: 'prod-2', productName: FOCUS_NAME, valueAtRiskRm: 120,
    };
    let s;
    let page;
    let promiseId;

    const outcomes = async () => (await db.list('conversation_outcomes')).filter((o) => o.salesmanUid === uid);
    const stopFor = (dayId, stopId, sequence, shop = RETAILER) => ({
      stopId, dayId, retailerId: shop.id, retailerName: shop.name, address: `${shop.area}, Kuching`,
      lat: shop.lat, lng: shop.lng, sequence, estimatedArrival: '09:00', estimatedDeparture: '09:20',
      priorityReason: 'Prioritised: overdue 14d.', status: 'not_started', travelMinutesFromPrevious: 10, legDistanceKm: 3.5,
    });
    const pickTomorrow = async () => {
      await page.getByRole('checkbox', { name: 'Pick a date', exact: true }).click();
      await B.see(page, 'Follow up on');
      await page.getByRole('button', { name: 'OK', exact: true }).click();
      await page.getByRole('checkbox', { name: `Pick a date: ${chipDay(tomorrow)}`, exact: true, checked: true }).waitFor({ timeout: 20000 });
    };
    const fullBrief = () => page.getByRole('button', { name: 'Full brief', exact: true }).first();
    const openFullBrief = async () => {
      const link = fullBrief();
      await B.scrollIntoView(page, link, { minHeight: 20, pointerY: 0.8 });
      await link.click();
      await B.see(page, `Brief for ${RETAILER.name}`, { timeout: 30000 });
    };

    await t.step('seed: a published route with this shop today and in 3 days, a brief with one focus product', async () => {
      await db.put('route_plans', PLAN_ID, {
        planId: PLAN_ID, createdByUid: seed.uids.admin, salesmanUid: uid, salesmanCode: accounts.salesman.code,
        salesmanName: accounts.salesman.name, branchId: 'B1',
        weekStart: inDays(-6), weekEnd: inDays(6),
        publishedAt: now, status: 'published', source: 'dashboard', totalStops: 3, stopIds: ['stop-1', 'stop-2', 'stop-3'],
        stopRetailerIds: { 'stop-1': RETAILER.id, 'stop-2': RETAILER.id, 'stop-3': SECOND_SHOP.id },
        days: [
          { dayId: 'day-1', dayLabel: 'Today', date: noon, totalDistanceKm: 7, stops: [stopFor('day-1', 'stop-1', 1), stopFor('day-1', 'stop-3', 2, SECOND_SHOP)] },
          { dayId: 'day-2', dayLabel: 'Later', date: nextVisit, totalDistanceKm: 3.5, stops: [stopFor('day-2', 'stop-2', 1)] },
        ],
      });
      await db.put('ai_insights', ISSUE_ID, {
        ...issue, retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', isDemo: false,
      });
      await db.put('visit_briefs', BRIEF_ID, {
        briefId: BRIEF_ID, retailerId: RETAILER.id, retailerName: RETAILER.name, salesmanUid: uid,
        salesmanCode: accounts.salesman.code, branchId: 'B1', status: 'active', insightCount: 1, highPriorityCount: 1,
        totalValueAtRiskRm: 120, isDemo: false, updatedAt: inDays(-1), emptyStateHeadline: '', emptyStateBody: '',
        topInsights: [{ ...issue, reason: SIGNAL, recommendation: 'Ask about shelf space.', questions: ['Is the shelf space smaller now?'] }],
        focusItems: [{ ...issue, signal: SIGNAL, action: 'Ask about shelf space.', questions: ['Is the shelf space smaller now?'], occurrenceCount: 1, autoState: 'active' }],
        replenishment: [],
      });
      const profile = await db.get('users', accounts.salesman.email);
      await db.put('users', accounts.salesman.email, { ...profile, gpsAutofill: true });
      await mobile.routeDayForSunday(db, PLAN_ID);
    });

    await t.step('the salesperson arrives at the stop; no promise line is shown yet', async () => {
      s = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT });
      page = s.page;
      await B.fakeGeolocation(s.context, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await B.loginMobile(page, s.url, accounts.salesman.email);
      await mobile.waitForHome(page);
      await mobile.openAssignedRoute(page);
      await B.see(page, RETAILER.name);
      await mobile.acceptAndStartRoute(page);
      await mobile.selectStop(page);
      await B.see(page, 'Sales Visit Scout', { timeout: 30000 });
      await B.moveDevice(page, { latitude: RETAILER.lat, longitude: RETAILER.lng, accuracy: 10 });
      await mobile.markArrived(page);
      await db.waitForQuery('route_stop_progress', (a) => a.planId === PLAN_ID && a.status === 'arrived', { label: 'stop arrival' });
      await page.waitForTimeout(1500);
      await expectNone(page, [PROMISE], 'stop card before any promise');
      if ((await outcomes()).length !== 0) throw new Error('an outcome exists before the visit');
    });

    await t.step('guided visit: "Record no-order outcome" with "Pick a date" writes a no-order outcome for the visit, then its follow-up date', async () => {
      const open = page.getByRole('button', { name: 'Open visit', exact: true }).first();
      await B.scrollIntoView(page, open, { minHeight: 20, pointerY: 0.8 });
      await open.click();
      await page.getByRole('button', { name: 'Continue to sell', exact: true }).click({ timeout: 30000 });
      await page.getByRole('button', { name: 'Record no-order outcome', exact: true }).click({ timeout: 20000 });
      await B.see(page, 'Why was no order placed today?');
      await B.see(page, 'Follow up on (optional)');
      await B.see(page, `Next visit day: ${chipDay(nextVisit)}`);
      await t.shot(s, 'no-order-sheet');
      await page.getByRole('checkbox', { name: 'Retailer Busy', exact: true }).click();
      await page.getByRole('checkbox', { name: 'Retailer Busy', exact: true, checked: true }).waitFor({ timeout: 20000 });
      await B.fillField(page, page.getByRole('textbox'), NOTE);
      await pickTomorrow();
      await t.shot(s, 'no-order-sheet-date-picked');
      await page.getByRole('button', { name: 'Save no order today', exact: true }).click();
      const created = await db.waitForQuery('conversation_outcomes', (o) => o.salesmanUid === uid && o.reasonCode === 'retailer_busy', { label: 'the no-order outcome' });
      promiseId = created.outcomeId;
      if (created.id !== promiseId) throw new Error(`document id ${created.id} is not the outcome id ${promiseId}`);
      if (created.outcomeKind !== 'no_order') throw new Error(`outcomeKind is ${created.outcomeKind}, expected no_order`);
      if (created.source !== 'mobile_assigned_route_no_order') throw new Error(`source is ${created.source}`);
      for (const key of ['productId', 'productName', 'issueId', 'issueKey', 'issueType', 'sourceBriefId', 'replacementProductId']) {
        if (key in created) throw new Error(`the no-order outcome is tied to a product: it has "${key}"`);
      }
      if (created.retailerId !== RETAILER.id || created.planId !== PLAN_ID || created.stopId !== 'stop-1') {
        throw new Error(`the no-order outcome is for ${created.retailerId} / ${created.planId} / ${created.stopId}`);
      }
      if (created.note !== NOTE) throw new Error(`note is "${created.note}"`);
      const dated = await db.waitForDoc('conversation_outcomes', promiseId,
        (o) => o.followUpDate === isoDate(tomorrow) && o.followUpStatus === 'open', { label: 'the follow-up on the same outcome' });
      if (!/^\d{4}-\d{2}-\d{2}$/.test(dated.followUpDate)) throw new Error(`followUpDate is "${dated.followUpDate}"`);
      if ('followUpTime' in dated) throw new Error('followUpTime was written');
      const unchanged = [...FOLLOW_UP_KEYS, 'submittedAt', 'id'];
      if (without(dated, unchanged) !== without(created, unchanged)) {
        throw new Error(`the follow-up update changed other fields of the outcome: ${without(created, unchanged)} became ${without(dated, unchanged)}`);
      }
      const all = await outcomes();
      if (all.length !== 1) throw new Error(`expected one outcome, found ${all.length}: ${all.map((o) => o.id).join(', ')}`);
      if (all.some((o) => o.source === 'mobile_assigned_route_copilot')) throw new Error('a product outcome was written for a no-order visit');
      await B.see(page, 'Outcome recorded', { timeout: 20000 });
      await mobile.goBack(page);
    });

    await t.step('the promise shows on the stop card, in the guided visit and on the full brief page; no "Mark as done" yet', async () => {
      await B.see(page, promiseLine, { timeout: 30000 });
      await t.shot(s, 'card-promise');
      if (await page.getByRole('button', { name: 'Mark as done', exact: true }).count() !== 0) {
        throw new Error('"Mark as done" is offered before a later visit result');
      }
      await openFullBrief();
      await B.see(page, promiseLine, { timeout: 30000 });
      await t.shot(s, 'page-promise');
      await mobile.goBack(page);
      const open = page.getByRole('button', { name: 'Open visit', exact: true }).first();
      await B.scrollIntoView(page, open, { minHeight: 20, pointerY: 0.8 });
      await open.click();
      await B.see(page, promiseLine, { timeout: 30000 });
      await mobile.goBack(page);
    });

    await t.step('Scout: "who did I promise to visit again?" lists the promise', async () => {
      await mobile.reopenHome(page, s.url);
      await page.waitForTimeout(4000);
      await page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
      const question = 'who did I promise to visit again?';
      await B.fillField(page, page.getByRole('textbox'), question);
      await page.getByRole('button', { name: 'Send', exact: true }).click();
      await B.see(page, 'You have 1 open follow-up.', { timeout: 30000 });
      await B.see(page, `${dayLabel(tomorrow)}: ${RETAILER.name}, ${NOTE}`);
      await t.shot(s, 'scout-follow-ups');
      await mobile.reopenHome(page, s.url);
      await mobile.openAssignedRoute(page);
      await B.see(page, promiseLine, { timeout: 30000 });
    });

    await t.step('a reason with no date writes nothing about a follow-up', async () => {
      const record = page.getByRole('button', { name: 'Record outcome', exact: true }).first();
      await B.scrollIntoView(page, record, { minHeight: 20, pointerY: 0.8 });
      await record.click();
      await B.see(page, `Record outcome • ${FOCUS_NAME}`);
      await B.see(page, 'Follow up on (optional)');
      await page.getByLabel('Price too high', { exact: true }).click();
      await page.getByLabel(`Record outcome • ${FOCUS_NAME}`, { exact: true }).waitFor({ state: 'detached', timeout: 20000 });
      const plain = await db.waitForQuery('conversation_outcomes', (o) => o.salesmanUid === uid && o.reasonCode === 'price_too_high', { label: 'the outcome with no date' });
      await page.waitForTimeout(4000);
      const settled = await db.get('conversation_outcomes', plain.id);
      const keys = followUpKeysOf(settled);
      if (keys.length !== 0) throw new Error(`an outcome saved with no date has ${keys.join(', ')}`);
      if (settled.productId !== 'prod-2' || settled.source !== 'mobile_assigned_route_copilot') {
        throw new Error(`the focus outcome is ${settled.productId} / ${settled.source}`);
      }
      const promise = await db.get('conversation_outcomes', promiseId);
      if (promise.followUpStatus !== 'open' || promise.followUpDate !== isoDate(tomorrow)) {
        throw new Error(`the first promise changed: ${promise.followUpDate} / ${promise.followUpStatus}`);
      }
    });

    await t.step('after that visit result, "Mark as done" sets completed and nothing else, and the line goes away', async () => {
      const before = await db.get('conversation_outcomes', promiseId);
      const done = page.getByRole('button', { name: 'Mark as done', exact: true }).first();
      await done.waitFor({ timeout: 30000 });
      await B.scrollIntoView(page, done, { minHeight: 20, pointerY: 0.8 });
      await t.shot(s, 'mark-as-done-offered');
      await done.click();
      const after = await db.waitForDoc('conversation_outcomes', promiseId, (o) => o.followUpStatus === 'completed', { label: 'the completed follow-up' });
      if (without(after, ['followUpStatus']) !== without(before, ['followUpStatus'])) {
        throw new Error('"Mark as done" changed more than followUpStatus');
      }
      await page.waitForFunction((needle) => !Array.from(document.querySelectorAll('flt-semantics'))
        .some((n) => ((n.getAttribute('aria-label') || n.textContent || '')).includes(needle)), 'You said you would come back', { timeout: 30000 });
      await expectNone(page, [PROMISE, /^Mark as done$/], 'stop card after Mark as done');
      await t.shot(s, 'promise-done');
    });

    await t.step('with no signal a dated reason is kept on the phone and shown; after reconnect the outcome and then its date are sent', async () => {
      await s.context.setOffline(true);
      await page.waitForTimeout(1500);
      const record = page.getByRole('button', { name: 'Record outcome', exact: true }).first();
      await B.scrollIntoView(page, record, { minHeight: 20, pointerY: 0.8 });
      await record.click();
      await B.see(page, `Record outcome • ${FOCUS_NAME}`);
      await pickTomorrow();
      await page.getByLabel('Out of stock', { exact: true }).click();
      await page.getByLabel(`Record outcome • ${FOCUS_NAME}`, { exact: true }).waitFor({ state: 'detached', timeout: 20000 });
      const heldLine = `You said you would come back on ${dayLabel(tomorrow)} about ${FOCUS_NAME}.`;
      await B.see(page, heldLine, { timeout: 30000 });
      await t.shot(s, 'promise-held-offline');
      if ((await outcomes()).some((o) => o.reasonCode === 'out_of_stock')) throw new Error('the outcome reached the server with no signal');
      await s.context.setOffline(false);
      const sent = await db.waitForQuery('conversation_outcomes',
        (o) => o.salesmanUid === uid && o.reasonCode === 'out_of_stock' && o.followUpDate === isoDate(tomorrow) && o.followUpStatus === 'open',
        { timeout: 90000, label: 'the held outcome with its follow-up after reconnect' });
      if (sent.productId !== 'prod-2' || sent.sourceBriefId !== BRIEF_ID) throw new Error(`held outcome is ${sent.productId} / ${sent.sourceBriefId}`);
      const all = await outcomes();
      if (all.length !== 3) throw new Error(`expected three outcomes, found ${all.length}: ${all.map((o) => `${o.id}:${o.reasonCode}`).join(', ')}`);
      await B.see(page, heldLine);
    });

    const secondShopOutcomes = async () => (await outcomes()).filter((o) => o.stopId === 'stop-3');
    const heldOnPhone = () => page.evaluate((note) => Object.keys(localStorage)
      .filter((key) => key.startsWith('flutter.') && (localStorage.getItem(key) || '').includes(note)).length, SECOND_NOTE);

    await t.step('the salesperson arrives at the second shop while the signal is still good', async () => {
      await B.moveDevice(page, { latitude: SECOND_SHOP.lat, longitude: SECOND_SHOP.lng, accuracy: 10 });
      const go = page.getByRole('button', { name: 'Go to this stop' }).first();
      await B.scrollIntoView(page, go, { minHeight: 20, pointerY: 0.8 });
      await go.click();
      await db.waitForQuery('route_plan_progress', (p) => p.planId === PLAN_ID && p.selectedStopId === 'stop-3', { label: 'the second shop selected' });
      await page.waitForTimeout(1500);
      await mobile.markArrived(page);
      await db.waitForQuery('route_stop_progress', (a) => a.planId === PLAN_ID && a.stopId === 'stop-3' && a.status === 'arrived', { label: 'arrival at the second shop' });
      if ((await secondShopOutcomes()).length !== 0) throw new Error('an outcome for the second shop exists before the visit');
    });

    await t.step('with no signal a no-order reason with a date is saved, then the app is closed and opened again: the promise is still on the phone and nothing is on the server', async () => {
      await mobile.blockBackend(page);
      await s.context.setOffline(true);
      await page.waitForTimeout(1500);
      const open = page.getByRole('button', { name: 'Selected destination' }).first().locator('xpath=following-sibling::*[@role="button"][2]');
      const openName = ((await open.getAttribute('aria-label')) || (await open.textContent()) || '').trim();
      if (openName !== 'Open visit') throw new Error(`expected "Open visit" on the selected stop, found "${openName}"`);
      await B.scrollIntoView(page, open, { minHeight: 20, pointerY: 0.8 });
      await open.click();
      await page.getByRole('button', { name: 'Continue to sell', exact: true }).click({ timeout: 30000 });
      await page.getByRole('button', { name: /^(Record no-order outcome|No order today)$/ }).click({ timeout: 20000 });
      await B.see(page, 'Why was no order placed today?');
      await page.getByRole('checkbox', { name: 'Retailer Busy', exact: true }).click();
      await page.getByRole('checkbox', { name: 'Retailer Busy', exact: true, checked: true }).waitFor({ timeout: 20000 });
      await B.fillField(page, page.getByRole('textbox'), SECOND_NOTE);
      await pickTomorrow();
      await page.getByRole('button', { name: 'Save no order today', exact: true }).click();
      await B.see(page, 'Outcome recorded', { timeout: 40000 });
      if ((await secondShopOutcomes()).length !== 0) throw new Error('the no-order outcome reached the server with no signal');
      if ((await heldOnPhone()) === 0) throw new Error('the no-order outcome is not in the phone store after it was saved');
      await t.shot(s, 'no-order-held-offline');

      await s.context.setOffline(false);
      await mobile.reopenHome(page, s.url);
      await s.context.setOffline(true);
      await mobile.openAssignedRoute(page);
      await page.waitForTimeout(5000);
      if ((await heldOnPhone()) === 0) throw new Error('the no-order outcome is not in the phone store after the app was opened again');
      if ((await secondShopOutcomes()).length !== 0) throw new Error('the no-order outcome reached the server while the backend was unreachable');
      await t.shot(s, 'no-order-held-after-restart');
    });

    await t.step('after the signal returns there is exactly one no-order outcome for that visit with its date, and a second reconnect adds no other', async () => {
      const before = (await outcomes()).map((o) => o.id);
      await s.context.setOffline(false);
      await mobile.unblockBackend(page);
      const sent = await db.waitForQuery('conversation_outcomes',
        (o) => o.salesmanUid === uid && o.stopId === 'stop-3' && o.followUpDate === isoDate(tomorrow) && o.followUpStatus === 'open',
        { timeout: 90000, label: 'the held no-order outcome with its follow-up after a restart and reconnect' });
      if (sent.outcomeKind !== 'no_order' || sent.reasonCode !== 'retailer_busy' || sent.source !== 'mobile_assigned_route_no_order') {
        throw new Error(`the outcome is ${sent.outcomeKind} / ${sent.reasonCode} / ${sent.source}`);
      }
      if (sent.retailerId !== SECOND_SHOP.id || sent.planId !== PLAN_ID || sent.note !== SECOND_NOTE) {
        throw new Error(`the outcome is for ${sent.retailerId} / ${sent.planId} with note "${sent.note}"`);
      }
      if ('productId' in sent || 'issueId' in sent) throw new Error('the no-order outcome is tied to a product');
      const first = await secondShopOutcomes();
      if (first.length !== 1) throw new Error(`expected one outcome for the second shop, found ${first.length}: ${first.map((o) => o.id).join(', ')}`);
      const afterFirst = (await outcomes()).map((o) => o.id);
      if (afterFirst.length !== before.length + 1) throw new Error(`expected ${before.length + 1} outcomes, found ${afterFirst.length}`);

      await s.context.setOffline(true);
      await page.waitForTimeout(3000);
      await s.context.setOffline(false);
      await page.waitForTimeout(15000);
      const second = await secondShopOutcomes();
      if (second.length !== 1 || second[0].id !== sent.id) {
        throw new Error(`a second reconnect changed the outcomes of the second shop: ${second.map((o) => o.id).join(', ')}`);
      }
      if (second[0].followUpDate !== isoDate(tomorrow) || second[0].followUpStatus !== 'open') {
        throw new Error(`a second reconnect changed the follow-up: ${second[0].followUpDate} / ${second[0].followUpStatus}`);
      }
      const afterSecond = (await outcomes()).map((o) => o.id).sort();
      if (JSON.stringify(afterSecond) !== JSON.stringify(afterFirst.slice().sort())) {
        throw new Error(`a second reconnect changed the outcome list: ${afterSecond.join(', ')}`);
      }
      await t.shot(s, 'no-order-sent-once');
    });
  },
};
