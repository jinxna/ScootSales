'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');
const fake = require('../lib/copilot_server.cjs');
const geminiOnly = require('../lib/copilot_gemini_only.cjs');

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

module.exports = {
  name: 'copilot_server',
  async run(t) {
    const { db, accounts, seed } = t;
    const uid = seed.uids.admin;
    let server;
    let adminS;
    let live;
    const UNAVAILABLE = 'Assistant is not available now. Try again later.';
    const CLIENT_TIMEOUT_MS = 10000;

    const panel = () => adminS.page.getByRole('group', { name: /^Scout panel/ });
    const composer = () => panel().getByRole('textbox').last();
    const say = async (text) => {
      await B.fillField(adminS.page, composer(), text);
      await adminS.page.keyboard.press('Enter');
    };
    const composerFocused = () => composer().evaluate((el) => {
      let active = document.activeElement;
      while (active && active.shadowRoot && active.shadowRoot.activeElement) active = active.shadowRoot.activeElement;
      if (!active || !['INPUT', 'TEXTAREA'].includes(active.tagName)) return false;
      const a = active.getBoundingClientRect();
      const b = el.getBoundingClientRect();
      return a.left < b.right && a.right > b.left && a.top < b.bottom && a.bottom > b.top;
    });
    const waitForSettledFocus = async (stableMs = 1500, timeout = 20000) => {
      const deadline = Date.now() + timeout;
      let since = 0;
      while (Date.now() < deadline) {
        if (await composerFocused().catch(() => false)) {
          since = since || Date.now();
          if (Date.now() - since >= stableMs) return;
        } else {
          since = 0;
        }
        await adminS.page.waitForTimeout(100);
      }
      throw new Error('the Scout input did not keep focus after the page opened');
    };
    const askModel = async (text) => {
      const before = server.requests.length;
      await say(text);
      for (let attempt = 0; attempt < 3; attempt += 1) {
        const deadline = Date.now() + 3000;
        while (Date.now() < deadline) {
          if (server.requests.length > before) return;
          await adminS.page.waitForTimeout(100);
        }
        await composer().focus();
        await adminS.page.keyboard.press('Enter');
      }
      if (server.requests.length <= before) throw new Error(`the server never received "${text}"`);
    };
    const statusDocs = async () => (await db.list('action_centre_user_status')).filter((d) => d.uid === uid);
    const confirmButton = () => adminS.page.getByRole('button', { name: 'Confirm', exact: true });
    const working = () => adminS.page.getByRole('group', { name: /^Scout panel/ }).getByText('Working…', { exact: true });
    const withDelayedModel = async (text, duringRequest) => {
      const url = `${server.url}/v1/interpret`;
      let release;
      let responseTask;
      const held = new Promise((resolve) => { release = resolve; });
      const handler = (route) => {
        responseTask = (async () => {
          const response = await route.fetch();
          await held;
          await route.fulfill({ response });
        })();
        return responseTask;
      };
      await adminS.page.route(url, handler);
      try {
        const requested = adminS.page.waitForRequest(url);
        await say(text);
        await requested;
        await working().waitFor({ state: 'attached' });
        await duringRequest();
      } finally {
        release();
        await responseTask;
        await adminS.page.unroute(url, handler);
      }
      await working().waitFor({ state: 'hidden' });
    };

    const askLive = async (text) => {
      const answered = adminS.page.waitForResponse((r) => r.url().endsWith('/v1/interpret'));
      const sent = adminS.page.waitForRequest((r) => r.url().endsWith('/v1/interpret')).then(() => Date.now());
      await say(text);
      const response = await answered;
      const ms = Date.now() - await sent;
      return { body: await response.json(), status: response.status(), ms };
    };
    const unavailableMessages = () => adminS.page.getByText(UNAVAILABLE, { exact: true }).count();
    const waitForUnavailableMessages = async (expected) => {
      const deadline = Date.now() + 10000;
      while (Date.now() < deadline) {
        if (await unavailableMessages() === expected) return;
        await adminS.page.waitForTimeout(100);
      }
      expectEqual(await unavailableMessages(), expected, 'unavailable messages shown');
    };

    try {
      await t.step('a product without a price gives the briefing a second item', async () => {
        await db.put('products', 'prod-noprice', {
          name: 'E2E PRODUCT WITHOUT PRICE', dept: 'GROCERY', department: 'GROCERY', code: 'E2E-NOPRICE', price: 0, unitPrice: 0,
        });
      });

      await t.step('the panel shows the waking-up state while the server sleeps', async () => {
        server = await fake.start();
        server.sleepFor(120000);
        adminS = await t.session('admin');
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        await adminS.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
        await B.see(adminS.page, /Assistant model waking up/);
      });

      await t.step('a sentence asked while it sleeps is not sent to the server', async () => {
        await say('anything urgent for me right now');
        await B.see(adminS.page, /still waking up/);
        expectEqual(server.requests.length, 0, 'interpret requests while sleeping');
        server.sleepFor(0);
      });

      await t.step('the panel shows the ready state when the server wakes', async () => {
        await B.see(adminS.page, /assistant model on/, { timeout: 40000 });
      });

      await t.step('the model turns a free sentence into the briefing, sent with a sign-in token', async () => {
        await say('anything urgent for me right now');
        await B.see(adminS.page, /items need attention most/);
        expectEqual(server.requests.length, 1, 'interpret requests');
        expectEqual([...server.requests[0].actions].sort(),
          ['daily_briefing', 'explain_item', 'export_results', 'search_orders', 'set_item_status'], 'actions offered');
      });

      await t.step('the model can ask for an explanation by item number', async () => {
        await say('tell me more about number two');
        await B.see(adminS.page, /Suggested action:/);
      });

      await t.step('a delayed model request invalidates the prior confirmation before its response', async () => {
        await say('Mark the first item as in review');
        await confirmButton().waitFor();
        await withDelayedModel('tell me more about number two', async () => {
          if (await confirmButton().count() && await confirmButton().isEnabled()) {
            await confirmButton().click();
            await B.see(adminS.page, /is now in review for you/);
          }
          expectEqual((await statusDocs()).length, 0, 'writes during a delayed model request');
          expectEqual(await confirmButton().count(), 0, 'prior confirmation while asking');
          await t.shot(adminS, 'stale-confirmation-invalidated');
        });
        await say('confirm');
        await B.see(adminS.page, /Nothing to confirm\./);
        expectEqual((await statusDocs()).length, 0, 'writes after confirming the invalidated proposal');
      });

      await t.step('a model-proposed status change still needs the confirmation card', async () => {
        await say('park number two for later');
        await B.see(adminS.page, /does not solve the problem/);
        expectEqual((await statusDocs()).length, 0, 'status documents before confirm');
        await adminS.page.getByRole('button', { name: 'Confirm' }).click();
        await B.see(adminS.page, /is now in review for you/);
        expectEqual((await statusDocs()).map((d) => d.status), ['in_review'], 'saved status');
      });

      await t.step('delayed declined and busy responses cannot restore an old confirmation', async () => {
        const before = await statusDocs();
        for (const text of ['blah blah blah', 'spam please']) {
          await say('Ignore the first item');
          await confirmButton().waitFor();
          await withDelayedModel(text, async () => {
            expectEqual(await confirmButton().count(), 0, `prior confirmation during "${text}"`);
            expectEqual(await statusDocs(), before, 'status documents during the held response');
          });
          expectEqual(await confirmButton().count(), 0, `prior confirmation after "${text}"`);
          await say('confirm');
          expectEqual(await statusDocs(), before, 'status documents after the declined or busy request');
        }
      });

      await t.step('a delayed replacement proposal requires its own explicit confirmation', async () => {
        await say('Ignore the second item');
        await confirmButton().waitFor();
        await say('confirm');
        await B.see(adminS.page, /is now ignored for you/);
        const before = await statusDocs();
        await say('Ignore the first item');
        await confirmButton().waitFor();
        await withDelayedModel('park number two for later', async () => {
          expectEqual(await confirmButton().count(), 0, 'prior confirmation during a replacement request');
          expectEqual(await statusDocs(), before, 'no replacement write before its response');
        });
        await confirmButton().waitFor();
        expectEqual(await statusDocs(), before, 'replacement still needs confirmation');
        await say('yes confirm');
        await confirmButton().waitFor({ state: 'hidden' });
        await composer().click({ trial: true });
        expectEqual((await statusDocs()).map((d) => ({ actionId: d.actionId, status: d.status })),
          before.map((d) => ({ actionId: d.actionId, status: 'in_review' })), 'only the replacement item was confirmed');
        await t.shot(adminS, 'replacement-confirmed');
      });

      await t.step('a "resolved" proposal and an unsupported call are refused with no write', async () => {
        await say('close that one off for good');
        await B.see(adminS.page, /not available yet/);
        const refusals = await adminS.page.getByText(/not available yet/).count();
        await say('dig up ahmad stuff');
        await B.see(adminS.page, /Which one do you mean|\d+ orders? · |I can(?:not|.t) find (?:"Ahmad"|a salesperson|a retailer|a salesperson or retailer)|No orders/);
        expectEqual(await adminS.page.getByText(/not available yet/).count(), refusals, 'new "not available yet" refusals');
        expectEqual((await statusDocs()).map((d) => d.status), ['in_review'], 'status unchanged');
      });

      await t.step('a page proposal opens the page through the role policy', async () => {
        await say('somewhere to see what customers sent us');
        await B.see(adminS.page, /Opened All Orders/);
      });

      await t.step('a busy server and an unknown sentence give plain answers', async () => {
        await waitForSettledFocus();
        await askModel('spam please');
        await B.see(adminS.page, /assistant model is busy/);
        await askModel('blah blah blah');
        await B.see(adminS.page, /I did not understand/);
      });

      await t.step('Gemini-only server: a normal answer comes from Gemini inside the dashboard time limit', async () => {
        await server.close();
        server = null;
        live = await geminiOnly.start({ origin: new URL(adminS.url).origin });
        adminS = await t.session('admin');
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        await adminS.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
        await B.see(adminS.page, /assistant model on/, { timeout: 40000 });
        await waitForSettledFocus();
        live.gemini.delayMs = 1000;
        const { body, status, ms } = await askLive('anything urgent for me right now');
        expectEqual({ status, source: body.source, unavailable: body.unavailable, call: body.call && body.call.name },
          { status: 200, source: 'gemini', unavailable: false, call: 'daily_briefing' }, 'live answer');
        if (ms >= CLIENT_TIMEOUT_MS) throw new Error(`the answer took ${ms} ms, the dashboard gives up at ${CLIENT_TIMEOUT_MS} ms`);
        await B.see(adminS.page, /items need attention most/);
        expectEqual(live.gemini.wrongKey, 0, 'Gemini requests without the server key');
        expectEqual(live.gemini.requests.length, 1, 'Gemini requests');
      });

      await t.step('Gemini answers 503: the reply is "unavailable" and the panel says so', async () => {
        live.gemini.mode = 'down';
        const { body, status } = await askLive('tell me more about number two');
        expectEqual({ status, call: body.call, source: body.source, unavailable: body.unavailable },
          { status: 200, call: null, source: 'unavailable', unavailable: true }, 'unavailable reply');
        await waitForUnavailableMessages(1);
        await t.shot(adminS, 'assistant-unavailable');
      });

      await t.step('Gemini hangs: the server gives up before the dashboard does', async () => {
        live.gemini.mode = 'hang';
        const { body, ms } = await askLive('tell me more about number two');
        expectEqual({ call: body.call, source: body.source, unavailable: body.unavailable },
          { call: null, source: 'unavailable', unavailable: true }, 'unavailable reply');
        if (ms >= 8000 || body.latencyMs >= 8000) throw new Error(`the server answered after ${ms} ms (it reports ${body.latencyMs} ms), over the 8 second target`);
        await waitForUnavailableMessages(2);
        expectEqual(await adminS.page.getByText(/Check your connection/).count(), 0, 'connection errors shown');
      });

      await t.step('the daily cap is reached: unavailable, and Gemini is not called again', async () => {
        live.gemini.mode = 'ok';
        const third = await askLive('tell me more about number two');
        expectEqual({ source: third.body.source, unavailable: third.body.unavailable }, { source: 'gemini', unavailable: false }, 'the request still inside the cap');
        const before = live.gemini.requests.length;
        expectEqual(before, geminiOnly.DAILY_LIMIT + 1, 'Gemini requests used so far (the 503 reply was given back)');
        const { body } = await askLive('tell me more about number two');
        expectEqual({ call: body.call, source: body.source, unavailable: body.unavailable, unavailableReason: body.unavailableReason },
          { call: null, source: 'unavailable', unavailable: true, unavailableReason: 'company_limit' }, 'unavailable reply');
        await B.see(adminS.page, /Your company has used all its assistant requests for today/);
        await waitForUnavailableMessages(2);
        expectEqual(live.gemini.requests.length, before, 'Gemini requests after the cap');
      });
    } finally {
      if (server) await server.close();
      if (live) await live.close();
    }
  },
};
