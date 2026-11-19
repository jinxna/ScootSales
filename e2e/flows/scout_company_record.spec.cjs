'use strict';

const http = require('node:http');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');

const BUILD_PORT = require('../lib/lane.cjs').ports.copilot;
const RECORD_PORT = require('../lib/lane.cjs').ports.scoutRecord;
const QUESTION = 'qwzx plorf blimmo';

function equal(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: ${actual} != ${expected}`);
}

function listen(port) {
  const requests = [];
  const server = http.createServer((req, res) => {
    const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, content-type' };
    const send = (code, body) => {
      res.writeHead(code, { ...cors, 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    requests.push(`${req.method} ${req.url}`);
    if (req.method === 'OPTIONS') return send(204, {});
    if (req.method === 'GET' && req.url === '/health') return send(200, { ready: true });
    if (req.method === 'POST' && req.url === '/v1/interpret') {
      return send(200, { call: { name: 'navigate_to_page', args: { page: 'orders' } }, confidence: 0.99, latencyMs: 1 });
    }
    return send(404, {});
  });
  return new Promise((resolve) => server.listen(port, '127.0.0.1', () => resolve({
    requests,
    close: () => new Promise((r) => server.close(r)),
  })));
}

async function signInWithCompanyCode(t, code, legalName) {
  const phone = await t.session('mobile', { viewport: { width: 430, height: 900 }, persistence: true });
  await B.openApp(phone.page, phone.url);
  await B.see(phone.page, 'Enter your company code to start.');
  await phone.page.getByRole('button', { name: 'Change company', exact: true }).click();
  await B.fillField(phone.page, phone.page.getByRole('textbox').first(), code);
  await phone.page.getByRole('button', { name: 'Continue', exact: true }).click();
  await B.see(phone.page, `Company: ${legalName}`);
  const inputs = phone.page.locator('input');
  await inputs.nth(1).waitFor({ timeout: 60000 });
  await B.fillField(phone.page, inputs.nth(0), t.accounts.salesman.email);
  await B.fillField(phone.page, inputs.nth(1), E.PASSWORD);
  await phone.page.getByRole('button', { name: /^Sign in$/ }).click();
  await mobile.waitForHome(phone.page);
  return phone;
}

async function openScoutAndAsk(phone) {
  await phone.page.getByRole('button', { name: /^(Open )?Scout$/ }).first().click();
  await B.see(phone.page, 'Ask about your route, orders and visit briefs.');
  await B.fillField(phone.page, phone.page.getByRole('textbox'), QUESTION);
  await phone.page.getByRole('button', { name: 'Send', exact: true }).click();
}

async function reseed(record) {
  const key = platform.ensureKey();
  await directory.resetDirectory();
  directory.seedDirectory([key], [{ record, key }]);
  directory.seedHarnessPlan([key]);
}

module.exports = {
  name: 'scout_company_record',
  async run(t) {
    if (process.env.E2E_TENANT_ROUTING !== '1') throw new Error('Build and run with E2E_TENANT_ROUTING=1.');
    const base = platform.harnessRecord();
    const buildServer = await listen(BUILD_PORT);
    const recordServer = await listen(RECORD_PORT);
    try {
      await t.step('company record names a Scout address: the phone Scout asks that address, not the build address', async () => {
        await reseed({ ...base, services: { ...base.services, copilotUrl: `http://127.0.0.1:${RECORD_PORT}` } });
        const phone = await signInWithCompanyCode(t, base.companyCode, base.legalName);
        await openScoutAndAsk(phone);
        await B.see(phone.page, /Order History/);
        await t.shot(phone, 'record-address-answer');
        equal(recordServer.requests.includes('POST /v1/interpret'), true, 'record address got the question');
        equal(buildServer.requests.length, 0, 'build address requests');
        await phone.context.close();
      });
      recordServer.requests.length = 0;
      await t.step('company record has services {}: Scout opens, answers basic commands, sends no request to any Scout server', async () => {
        await reseed({ ...base, services: {} });
        const phone = await signInWithCompanyCode(t, base.companyCode, base.legalName);
        await openScoutAndAsk(phone);
        await B.see(phone.page, QUESTION);
        await phone.page.waitForTimeout(3000);
        await t.shot(phone, 'no-services-asked');
        equal(recordServer.requests.length, 0, 'record address requests');
        equal(buildServer.requests.length, 0, 'build address requests');
        const failed = await phone.page.evaluate(() => Array.from(document.querySelectorAll('flt-semantics'))
          .map((n) => (n.getAttribute('aria-label') || n.textContent || '').trim()).filter(Boolean));
        equal(failed.some((x) => /Scout server is not available|No internet|This question needs a signal|waking up|had a problem/.test(x)), false, 'server error text shown');
      });
    } finally {
      await buildServer.close();
      await recordServer.close();
    }
  },
};
