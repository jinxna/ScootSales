'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const seed = require('../../scripts/seed_control_centre_demo.cjs');
const staff = require('../lib/staff.cjs');
const legal = require('../lib/legal.cjs');
const { startMailSink } = require('../lib/mail_sink.cjs');

const STAFF_PORT = 18891;
const escaped = (value) => value.replace(/[.*+?^${}()|[\]\\]/g, '\\$&');

module.exports = {
  name: 'control_centre_tour',
  platformApi: false,
  async run(t) {
    const outDir = path.join(E.OUTPUT_DIR, 'control_centre_tour');
    fs.mkdirSync(outDir, { recursive: true });
    const key = platform.ensureKey();
    await directory.resetDirectory();
    const sink = await startMailSink();
    await sink.clear();
    const service = await seed.startDemoStaffApi(key, { port: STAFF_PORT, browserSignIn: true });
    const seenCodeMails = new Set();
    const results = [];
    const sessions = {};
    try {
      let summary;
      await t.step('load the demo data through the staff API', async () => {
        summary = await seed.seedDemo({ service, key, log: () => {} });
        if (summary.companies < 12) throw new Error(`only ${summary.companies} companies were seeded`);
      });

      const open = async (role, label) => {
        const s = await t.session('admin', { name: `control-${label}` });
        await s.context.route('**/staff/v1/**', async (route) => {
          const request = route.request();
          const url = new URL(request.url());
          try {
            const response = await route.fetch({
              url: `${service.url}${url.pathname}${url.search}`,
              headers: { ...request.headers(), host: new URL(t.urls.admin).host },
            });
            return await route.fulfill({ response });
          } catch (error) {
            console.log(`  staff API request failed: ${request.method()} ${url.pathname}: ${error.message.split('\n')[0]}`);
            return route.abort().catch(() => null);
          }
        });
        await B.openApp(s.page, t.urls.admin);
        await staff.signInControlCentre(s.page, service.emails[role], sink, seenCodeMails);
        await s.page.getByText('Control Centre', { exact: false }).first().waitFor({ timeout: 45000 });
        s.label = label;
        sessions[label] = s;
        return s;
      };
      const pageText = async (s) => (await admin.semanticsLines(s.page)).join('\n');
      const button = (s, name) => s.page.getByRole('button', { name }).first();
      const press = async (s, name, { exact = false, timeout = 15000 } = {}) => {
        const target = typeof name === 'string' && exact ? s.page.getByRole('button', { name, exact: true }).first() : button(s, name);
        await target.click({ timeout });
        await s.page.waitForTimeout(900);
      };
      const nav = (s, name) => press(s, new RegExp(`^${name}(,|$)`));

      const screen = async (s, id, who, go, expected) => {
        const row = { screen: id, as: who, ok: true, checks: [] };
        try {
          await go();
          await s.page.waitForTimeout(1500);
          const text = await pageText(s);
          for (const [label, pattern] of expected) {
            const ok = pattern.test(text);
            row.checks.push({ check: label, ok });
            if (!ok) row.ok = false;
          }
        } catch (error) {
          row.ok = false;
          row.error = error.message.split('\n')[0];
        }
        await t.shot(s, id).catch(() => null);
        results.push(row);
        console.log(`  ${row.ok ? 'ok  ' : 'FAIL'} ${id} (${who})${row.error ? `: ${row.error}` : ''}`);
        return row;
      };
      const escapeKey = async (s) => { await s.page.keyboard.press('Escape'); await s.page.waitForTimeout(400); };

      const c = await open('owner', 'cassie');
      const a = await open('operator', 'ali');

      const has = (label, re) => [label, re];
      await screen(c, 'inbox', 'Cassie', () => nav(c, 'Inbox'), [
        has('Hardware Client plan request', /Hardware Client/), has('Kenyalang Mini Market', /Kenyalang Mini Market/),
        has('Everrise Supermarket', /Everrise Supermarket/), has('payment to check', /Payment to check/),
        has('plan request', /Plan request|Change package/),
      ]);
      for (const [id, chip, expectText] of [
        ['inbox-plan-requests', /^Plan request/, /Hardware Client/],
        ['inbox-payments', /^Payment to check/, /Kenyalang Mini Market/],
        ['inbox-invoices', /^Invoice to send/, /Kuching Mart|Hardware Client/],
        ['inbox-failed-email', /^Failed email/, /Everrise Supermarket|Miri Daily Needs/],
        ['inbox-onboarding', /^Onboarding/, /Penrissen Wholesale|Stutong Mini Mart/],
        ['inbox-approvals', /^Approval/, /Satok Grocer|Sarawak Provision Trading/],
      ]) {
        await screen(c, id, 'Cassie', async () => { await nav(c, 'Inbox'); await press(c, chip); }, [has('expected rows', expectText)]);
      }
      await screen(c, 'inbox-open-plan-request', 'Cassie', async () => {
        await nav(c, 'Inbox');
        await press(c, /^Plan request/);
        await press(c, /Hardware Client/);
      }, [has('package change', /Professional/)]);
      await screen(a, 'inbox-ali', 'Ali', () => nav(a, 'Inbox'), [has('Kenyalang', /Kenyalang Mini Market/), has('Everrise', /Everrise Supermarket/)]);

      await screen(c, 'companies', 'Cassie', () => nav(c, 'Companies'), [
        has('Hardware Client', /Hardware Client/), has('Tabuan Jaya Store', /Tabuan Jaya Store/), has('Lundu Village Shop', /Lundu Village Shop/),
        has('Sarawak Provision Trading', /Sarawak Provision Trading/), has('pagination', /of 13|1.13/),
      ]);
      for (const [id, tab, expectText] of [
        ['companies-past-due', /^Past due/, /Tabuan Jaya Store/],
        ['companies-awaiting-first-payment', /^Awaiting first payment/, /Kuching Mart/],
        ['companies-suspended', /^Suspended/, /Serian Trading Co/],
        ['companies-setting-up', /^Setting up/, /Sarawak Provision Trading/],
        ['companies-no-billing-email', /^No billing email/, /Hardware Client/],
      ]) {
        await screen(c, id, 'Cassie', async () => { await nav(c, 'Companies'); await press(c, tab); }, [has('expected company', expectText)]);
      }

      const openCompany = async (s, name) => {
        await nav(s, 'Companies');
        await press(s, new RegExp(`^${escaped(name)}`));
      };
      await screen(c, 'company-hardware', 'Cassie', () => openCompany(c, 'Hardware Client'), [
        has('company name', /Hardware Client/), has('package', /Standard/), has('no billing email', /billing email/i),
      ]);
      await screen(c, 'company-miri', 'Cassie', () => openCompany(c, 'Miri Daily Needs'), [has('company name', /Miri Daily Needs/), has('Professional', /Professional/)]);
      await screen(c, 'company-record-payment', 'Cassie', () => press(c, 'Record payment'), [has('payment form', /Until it is checked/)]);
      await screen(c, 'company-more-menu', 'Cassie', async () => { await escapeKey(c); await press(c, 'More actions'); }, [
        has('change package', /Change package/), has('change status', /Change status/),
      ]);
      await escapeKey(c);
      if (await c.page.getByText('Change package').count() !== 0) throw new Error('the More menu stayed open after Escape');
      await screen(c, 'company-tabaun-past-due', 'Cassie', () => openCompany(c, 'Tabuan Jaya Store'), [has('past due', /Past due/i), has('overdue invoice', /Overdue|INV-/)]);

      await screen(c, 'payments-to-check', 'Cassie', () => nav(c, 'Payments'), [
        has('Kenyalang payment', /Kenyalang Mini Market/), has('bank reference', /CIMB-120934/), has('Everrise payment', /Everrise Supermarket/),
        has('same-person rule', /You recorded it|Ali checks it|another person/i),
      ]);
      await screen(c, 'payments-void-dialog', 'Cassie', async () => { await press(c, /^Void/); }, [has('void dialog', /Void|reason/i)]);
      await escapeKey(c);
      await screen(c, 'payments-all', 'Cassie', async () => { await nav(c, 'Payments'); await press(c, /^All payments/); }, [has('payments listed', /RM /)]);
      await screen(c, 'payments-voided', 'Cassie', async () => { await nav(c, 'Payments'); await press(c, /^Voided/); }, [has('Bau Family Mart', /Bau Family Mart/)]);
      await screen(a, 'payments-ali', 'Ali', () => nav(a, 'Payments'), [has('Everrise check offered', /Matches bank statement/), has('Kenyalang row', /Kenyalang Mini Market/)]);

      await screen(c, 'invoices', 'Cassie', () => nav(c, 'Invoices'), [has('draft invoices', /Hardware Client[\s\S]*Kuching Mart/)]);
      for (const [id, tab, expectText] of [
        ['invoices-drafts', /^Drafts/, /Hardware Client|Kuching Mart/],
        ['invoices-sent', /^Sent/, /Miri Daily Needs/],
        ['invoices-overdue', /^Overdue/, /Tabuan Jaya Store/],
        ['invoices-paid', /^Paid/, /Santubong Retail|Bau Family Mart/],
        ['invoices-credit-notes', /^Credit notes/, /CN-\d{4}-\d{6}|Miri Daily Needs/],
      ]) {
        await screen(c, id, 'Cassie', async () => { await nav(c, 'Invoices'); await press(c, tab); }, [has('expected invoices', expectText)]);
      }
      await screen(c, 'invoice-preview', 'Cassie', async () => {
        await nav(c, 'Invoices');
        await press(c, /^Drafts/);
        await press(c, /Hardware Client/);
      }, [has('invoice document', /INVOICE|Invoice/), has('Hardware Client', /Hardware Client/)]);

      await screen(c, 'packages', 'Cassie', () => nav(c, 'Packages'), [
        has('Starter', /Starter/), has('Standard', /Standard/), has('Professional', /Professional/), has('Enterprise by quote', /Enterprise[\s\S]*By quote|By quote/),
      ]);
      await screen(c, 'packages-quote-approval', 'Cassie', async () => {
        await nav(c, 'Inbox');
        await press(c, /^Approval/);
      }, [has('Enterprise quote', /Sarawak Provision Trading/), has('suspension', /Satok Grocer/)]);

      await screen(c, 'onboarding', 'Cassie', () => nav(c, 'Onboarding'), [has('Penrissen Wholesale', /Penrissen Wholesale/), has('Stutong Mini Mart', /Stutong Mini Mart/), has('Sibu Central Grocer', /Sibu Central Grocer/)]);
      await screen(c, 'onboarding-detail', 'Cassie', () => press(c, /Stutong Mini Mart/), [has('checklist', /billing email/i), has('step count', /of 8 steps done/)]);
      await screen(c, 'new-company', 'Cassie', async () => { await nav(c, 'Companies'); await press(c, 'Add company'); }, [has('add company form', /Add company[\s\S]*Create draft/)]);

      await screen(c, 'staff', 'Cassie', () => nav(c, 'Staff and access'), [has('roles', /What each role can do/), has('owner', /Owner|owner/)]);
      await screen(c, 'audit', 'Cassie', () => nav(c, 'Audit log'), [has('audit heading', /Audit log/), has('events', /Hardware Client|Everrise Supermarket|Payment|Invoice/)]);
      await screen(c, 'settings', 'Cassie', () => nav(c, 'Settings'), [has('billing rules', /Billing rules/)]);
      await screen(c, 'account', 'Cassie', async () => { await press(c, 'Account menu'); await c.page.getByRole('menuitem', { name: 'My account' }).click(); }, [has('account page', /Sign out/)]);
      const legalSeen = {};
      for (const [document, label] of [['privacyPolicy', 'Privacy Policy'], ['termsAndConditions', 'Terms & Conditions']]) {
        await screen(c, `account-${document}`, 'Cassie', async () => {
          const link = c.page.getByRole('button', { name: label, exact: true });
          await B.scrollIntoView(c.page, link, { bottomInset: 0 });
          await link.first().click();
          await c.page.waitForTimeout(900);
          legalSeen[document] = await legal.checkLegalDocument(c.page, document, (name) => t.shot(c, `legal-${name}`));
          await press(c, 'Back', { exact: true });
        }, [has('back on the account page', /Privacy and terms/)]);
      }

      const failed = results.filter((row) => !row.ok);
      fs.writeFileSync(path.join(outDir, 'result.json'), JSON.stringify({
        generatedAt: new Date().toISOString(), seed: summary, screens: results.length, passed: results.length - failed.length,
        failed: failed.map((row) => row.screen), legal: legalSeen, results,
      }, null, 2));
      if (failed.length) throw new Error(`${failed.length} of ${results.length} screens failed: ${failed.map((row) => row.screen).join(', ')}`);
    } finally {
      await service.stop();
      await sink.close();
    }
  },
};
