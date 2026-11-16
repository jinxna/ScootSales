'use strict';

const B = require('../lib/browser.cjs');
const admin = require('../lib/admin.cjs');

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

module.exports = {
  name: 'copilot_briefing',
  async run(t) {
    const { db, accounts, seed } = t;
    let adminS;
    const uid = seed.uids.admin;

    const say = async (text) => {
      const box = adminS.page.getByRole('textbox').last();
      await B.fillField(adminS.page, box, text);
      await adminS.page.keyboard.press('Enter');
    };
    const statusDocs = async () => (await db.list('action_centre_user_status')).filter((d) => d.uid === uid);

    await t.step('a product without a price gives the briefing a second item', async () => {
      await db.put('products', 'prod-noprice', {
        name: 'E2E PRODUCT WITHOUT PRICE', dept: 'GROCERY', department: 'GROCERY', code: 'E2E-NOPRICE', price: 0, unitPrice: 0,
      });
    });

    await t.step('admin logs in and opens the Scout panel', async () => {
      adminS = await t.session('admin');
      await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
      await admin.waitForShell(adminS.page);
      await adminS.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).click();
      await B.see(adminS.page, 'Scout panel');
      const trigger = adminS.page.getByRole('button', { name: /^Scout(?:\s|$)/ }).first();
      const triggerName = (await trigger.getAttribute('aria-label')) ?? (await trigger.innerText());
      if (/Scout · /.test(triggerName)) throw new Error(`tooltip must be removed while the panel is open: ${triggerName}`);
      const pill = await trigger.boundingBox();
      if (pill.y < 4 || pill.y + pill.height > 56) throw new Error(`Scout pill must sit inside the top bar: ${JSON.stringify(pill)}`);
    });

    await t.step('"What needs my attention today?" lists items from the Action Centre', async () => {
      await say('What needs my attention today?');
      await B.see(adminS.page, /items need attention most/);
      await t.shot(adminS, 'briefing');
    });

    await t.step('"Explain the second item" shows the saved reason and suggested action', async () => {
      await say('Explain the second item');
      await B.see(adminS.page, /Suggested action:/);
      await B.see(adminS.page, /confidence: (High|Medium|Low)/);
    });

    await t.step('"Mark it as in review" shows a confirmation card and writes nothing yet', async () => {
      await say('Mark it as in review');
      await B.see(adminS.page, /does not solve the problem/);
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      expectEqual((await statusDocs()).length, 0, 'status documents before confirm');
      await t.shot(adminS, 'confirmation');
    });

    await t.step('Confirm writes the personal status and an assistant audit entry', async () => {
      await adminS.page.getByRole('button', { name: 'Confirm' }).click();
      await B.see(adminS.page, /is now in review for you/);
      const rows = await statusDocs();
      expectEqual(rows.length, 1, 'status documents after confirm');
      expectEqual(rows[0].status, 'in_review', 'saved status');
      const audit = await db.waitForQuery(
        'system_audit_logs',
        (a) => a.action === 'action_centre_status' && a.entityId === rows[0].actionId,
        { label: 'assistant audit entry' },
      );
      expectEqual(audit.metadata.source, 'assistant', 'audit source');
      expectEqual(audit.metadata.status, 'in_review', 'audit status');
    });

    await t.step('an out-of-range item number is refused with the list size', async () => {
      await say('Explain the ninth item');
      await B.see(adminS.page, /The list has \d+ items/);
    });

    await t.step('a status that changed after the card was shown is refused', async () => {
      await say('Ignore it');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      const [row] = await statusDocs();
      await db.put('action_centre_user_status', row.id, { uid, actionId: row.actionId, status: 'resolved' });
      await adminS.page.getByRole('button', { name: 'Confirm' }).click();
      await B.see(adminS.page, /changed since I showed it/);
      expectEqual((await db.get('action_centre_user_status', row.id)).status, 'resolved', 'status after the refused write');
    });

    await t.step('questions, negations and two item numbers never become status cards', async () => {
      for (const sentence of ['is item 2 in review?', "don't ignore the second item", 'ignore item 3, the first one is fine']) {
        await say(sentence);
        await B.see(adminS.page, /I am not sure what you mean/);
        expectEqual(await adminS.page.getByRole('button', { name: 'Confirm' }).count(), 0, `confirm button after "${sentence}"`);
      }
    });

    await t.step('saying cancel while a card is open cancels it', async () => {
      await say('Mark the first item as in review');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      await say('cancel');
      await B.see(adminS.page, /Cancelled. No change was made./);
      expectEqual(await adminS.page.getByRole('button', { name: 'Confirm' }).count(), 0, 'confirm button after cancel');
    });

    await t.step('a page command still opens the page', async () => {
      await say('open all orders');
      await B.see(adminS.page, /Opened All Orders/);
    });

    await t.step('a page command drops an open confirmation', async () => {
      const before = await statusDocs();
      await say('Mark the first item as in review');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      await say('open all orders');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor({ state: 'hidden' });
      await say('confirm');
      await B.see(adminS.page, /Nothing to confirm\./);
      const after = await statusDocs();
      expectEqual(JSON.stringify(after), JSON.stringify(before), 'status documents after the dropped confirmation');
    });

    let cappedRow;
    await t.step('a target outside the first 500 saved statuses is still compared', async () => {
      const [row] = (await statusDocs()).filter((d) => d.status === 'resolved');
      cappedRow = row;
      for (let i = 0; i < 500; i += 1) {
        const n = String(i).padStart(3, '0');
        await db.put('action_centre_user_status', `${uid}_000-filler-${n}`, { uid, actionId: `000-filler-${n}`, status: 'ignored' });
      }
      await say('Mark the second item as in review');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      await db.put('action_centre_user_status', row.id, { uid, actionId: row.actionId, status: 'ignored' });
      const refusals = adminS.page.getByText(/changed since I showed it/);
      const refusalsBefore = await refusals.count();
      await adminS.page.getByRole('button', { name: 'Confirm' }).click();
      await B.see(adminS.page, /changed since I showed it/);
      for (let i = 0; i < 50 && (await refusals.count()) <= refusalsBefore; i += 1) await adminS.page.waitForTimeout(100);
      expectEqual((await refusals.count()) > refusalsBefore, true, 'a new refusal message');
      expectEqual((await db.get('action_centre_user_status', row.id)).status, 'ignored', 'status after the refused write');
    });

    await t.step('with 500+ saved statuses a fresh confirmation still succeeds (the read sees past the cap)', async () => {
      const row = cappedRow;
      await say('Mark the second item as in review');
      await adminS.page.getByRole('button', { name: 'Confirm' }).waitFor();
      await adminS.page.getByRole('button', { name: 'Confirm' }).click();
      await B.see(adminS.page, /is now in review for you/);
      expectEqual((await db.get('action_centre_user_status', row.id)).status, 'in_review', 'status after the confirmed write');
    });
  },
};
