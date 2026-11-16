'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const dashboard = require('../lib/admin.cjs');
const mobile = require('../lib/mobile.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');

const DAY_MS = 24 * 60 * 60 * 1000;
const EXPIRED_BANNER = 'Company record expired, connect to renew';
const RENEW_RECORD = [
  'import json, sys',
  'from datetime import timedelta',
  'from google.cloud import firestore',
  'from platform_service.directory import COMPANIES, DirectoryStore',
  'from platform_service.signing import Keyring, Signer',
  'r = json.load(sys.stdin)',
  'client = firestore.Client(project=r["project"])',
  'current = client.collection(COMPANIES).document(r["record"]["tenantId"]).get().to_dict()["version"]',
  'store = DirectoryStore(client, keyring=Keyring.from_environment(),',
  '    signer=Signer.from_seed(r["keyId"], r["seed"]), record_ttl=timedelta(days=90))',
  'store.put(r["record"], expected_version=current)',
].join('\n');

function equal(actual, expected, label) {
  if (actual !== expected) throw new Error(`${label}: ${actual} != ${expected}`);
}

function renewDirectoryRecord(record, key) {
  const { firestoreHost } = E.requireEmulators();
  platform.python(['-c', RENEW_RECORD], {
    input: JSON.stringify({ project: directory.PLATFORM_PROJECT, record, keyId: key.keyId, seed: key.seed }),
    env: { FIRESTORE_EMULATOR_HOST: firestoreHost, PLATFORM_PROJECT_ID: directory.PLATFORM_PROJECT,
      PLATFORM_PUBLIC_KEYS: platform.publicKeysText(key) },
  });
}

async function storedRecordVersion(page, code) {
  return Number(await page.evaluate((key) => localStorage.getItem(key), `flutter.company_record_version_v2:${code}`));
}

module.exports = {
  name: 'company_api_central',
  async run(t) {
    if (process.env.E2E_TENANT_ROUTING !== '1') throw new Error('Build and run with E2E_TENANT_ROUTING=1.');
    const out = path.join(E.OUTPUT_DIR, 'company_api_central');
    fs.mkdirSync(out, { recursive: true });
    const trusted = platform.ensureKey();
    const record = platform.harnessRecord();
    const evidence = { checks: [], central: platform.PLATFORM_API_URL };
    const note = (check) => evidence.checks.push(check);
    let phone;
    let adminSession;
    const requests = [];
    try {
      await t.step('one central service answers with the company on the Starter package', async () => {
        directory.planAdmin([trusted], [{ op: 'subscribe', planId: 'STARTER', reseed: true }, { op: 'usage' }]);
        equal((await fetch(`${platform.PLATFORM_API_URL}/v1/registry`)).status, 404, 'bulk directory');
        equal((await fetch(`${platform.PLATFORM_API_URL}/v1/companies/wrong-company`)).status, 404, 'unknown company');
        note('the company is on Starter; bulk directory and unknown company denied');
      });
      await t.step('fresh mobile startup requires a company before loading Firebase', async () => {
        phone = await t.session('mobile', { viewport: mobile.MOBILE_VIEWPORT, persistence: true });
        phone.page.on('request', (request) => requests.push({ url: request.url(), method: request.method() }));
        await B.openApp(phone.page, phone.url);
        await B.see(phone.page, 'Enter your company code to start.');
        equal(requests.some((r) => /firebasejs|identitytoolkit|firestore\.googleapis/.test(r.url)), false, 'SDK before company selection');
        await t.shot(phone, 'fresh-company-selection');
        await phone.page.getByRole('button', { name: 'Change company', exact: true }).click();
        await B.fillField(phone.page, phone.page.getByRole('textbox').first(), record.companyCode);
        await phone.page.getByRole('button', { name: 'Continue', exact: true }).click();
        await B.see(phone.page, `Company: ${record.legalName}`);
        await phone.page.getByRole('button', { name: 'I have an invitation code' }).waitFor();
        note('fresh company selection precedes Firebase startup');
      });
      await t.step('cached signed company opens while the directory is unavailable', async () => {
        await phone.context.route(`${platform.PLATFORM_API_URL}/**`, (route) => route.abort());
        await B.openApp(phone.page, phone.url);
        await B.see(phone.page, `Company: ${record.legalName}`);
        await t.shot(phone, 'cached-company-directory-outage');
        await phone.context.unroute(`${platform.PLATFORM_API_URL}/**`);
        note('verified cached selection survives a directory outage; this does not prove full offline ordering');
      });
      await t.step('invitation credentials go to the one central service', async () => {
        await mobile.redeemInvitation(phone.page, phone.url,
          { code: 'ABCD-EFGH-JKLM', check: '1234', password: E.PASSWORD });
        await B.see(phone.page, 'The invitation code or check is not valid.');
        const attempts = requests.filter((r) => r.url.endsWith('/v1/invitations/email-code'));
        equal(attempts.length, 1, 'email code requests');
        equal(attempts[0].url, `${platform.PLATFORM_API_URL}/v1/invitations/email-code`, 'credential destination');
        equal(requests.filter((r) => r.url.endsWith('/v1/invitations/redeem')).length, 0, 'redemption after a refused email code request');
        await t.shot(phone, 'central-invitation-validation');
        note('invalid credentials validated by the central service');
      });
      await t.step('an expired cached company opens with the directory blocked, then renews when it returns', async () => {
        const before = await storedRecordVersion(phone.page, record.companyCode);
        equal(before >= 1, true, 'cached record version before expiry');
        await phone.context.route(`${platform.PLATFORM_API_URL}/**`, (route) => route.abort());
        await B.shiftDeviceClock(phone.context, 45 * DAY_MS);
        await B.openApp(phone.page, phone.url);
        await B.see(phone.page, `Company: ${record.legalName}`);
        await B.see(phone.page, EXPIRED_BANNER);
        await t.shot(phone, 'expired-company-directory-blocked');
        renewDirectoryRecord(record, trusted);
        await phone.context.unroute(`${platform.PLATFORM_API_URL}/**`);
        await B.semantic(phone.page, EXPIRED_BANNER).waitFor({ state: 'hidden', timeout: 120000 });
        const after = await storedRecordVersion(phone.page, record.companyCode);
        equal(after > before, true, `renewed record version ${before} -> ${after}`);
        await B.see(phone.page, `Company: ${record.legalName}`);
        await t.shot(phone, 'expired-company-renewed');
        evidence.expiredRecord = { shiftedDays: 45, versionBefore: before, versionAfter: after };
        note('an expired but signature-valid cached record opens offline with a banner and is renewed when the directory returns');
      });
      await t.step('dashboard account requests use the central service', async () => {
        const signedIn = await fetch(`${t.db.authBase}/accounts:signInWithPassword?key=fake-api-key`, {
          method: 'POST', headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ email: t.accounts.admin.email, password: E.PASSWORD, returnSecureToken: true }),
        });
        const token = (await signedIn.json()).idToken;
        if (!token) throw new Error('Fixture admin sign-in failed.');
        const headers = { Authorization: `Bearer ${token}` };
        equal((await fetch(`${platform.PLATFORM_API_URL}/v1/w/${record.workspace}/account`, { headers })).status, 200, 'central account API');
        adminSession = await t.session('admin');
        const accountCalls = [];
        adminSession.page.on('request', (request) => { if (/\/v1\/w\//.test(request.url())) accountCalls.push(request.url()); });
        await B.loginAdmin(adminSession.page, `${adminSession.url}/w/${record.workspace}`, t.accounts.admin.email);
        await dashboard.waitForShell(adminSession.page);
        await dashboard.goToPage(adminSession.page, 'Account');
        await B.see(adminSession.page, 'Enter your password to see your plan and usage.');
        await B.fillField(adminSession.page, adminSession.page.locator('input[type="password"]').first(), E.PASSWORD);
        await adminSession.page.getByRole('button', { name: 'Open the account page' }).click();
        await B.see(adminSession.page, /Plan: Starter/);
        equal(accountCalls.some((url) => url.startsWith(`${platform.PLATFORM_API_URL}/v1/w/`) && url.endsWith('/account')), true, 'dashboard central account call');
        await t.shot(adminSession, 'central-account');
        note('dashboard account comes from the central service');
      });
    } finally {
      fs.writeFileSync(path.join(out, 'routing-evidence.json'), JSON.stringify(evidence, null, 2));
    }
  },
};
