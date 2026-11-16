'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const { ACCOUNTS, BRANCH, putPerson } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'shared_dashboard_workspaces');
const PROJECT_B = 'demo-company-b';
const NAMES = { alpha: 'Alpha Trading Sdn Bhd', bravo: 'Bravo Hardware Sdn Bhd', charlie: 'Charlie Forgery Sdn Bhd' };
const ORDER_A = { id: 'e2e-alpha-1', retailer: 'Alpha Mart Kuching' };
const ORDER_B = { id: 'e2e-bravo-1', retailer: 'Bravo Depot Miri' };
const BRAVO_ADMIN = { ...ACCOUNTS.admin, name: 'Bravo Admin' };

function expectEqual(actual, expected, what) {
  if (actual !== expected) throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
}

function ownProjectRecord({ tenantId, workspace, projectId, planRef }) {
  return {
    tenantId, workspace, legalName: NAMES[workspace], companyCode: workspace,
    location: { projectId, databaseId: '(default)', authTenantId: null },
    locationKind: 'byo',
    clientConfig: {
      apiKey: `AIza${'B'.repeat(35)}`,
      appId: '1:123456789012:web:0123456789abcdef',
      messagingSenderId: '123456789012',
      storageBucket: `${projectId}.firebasestorage.app`,
    },
    status: 'active', planRef, edition: planRef === 'P1' ? 'basic' : 'advanced', releaseRing: 'pilot', rulesVersion: 'e2e', services: {},
  };
}

const orderDoc = (id, retailerName, uid, branchId) => ({
  orderId: id, uid, userUid: uid, salesmanUid: uid, salesmanCode: 'S001', branchId,
  retailerId: `ret-${id}`, retailerName, status: 'submitted',
  items: [{ productId: 'prod-1', name: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)', productName: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)', quantity: 1, price: 28.12 }],
  totalProducts: 1, totalBoxes: 1, totalPrice: 28.12, submittedAt: new Date(), createdAt: new Date(),
});

module.exports = {
  name: 'shared_dashboard_workspaces',
  platformApi: false,
  async run(t) {
    const dbB = E.client(PROJECT_B);
    const trusted = platform.ensureKey(platform.KEY_ID);
    const untrusted = platform.ensureKey(platform.OTHER_KEY_ID);
    const keys = [trusted, untrusted];
    const evidence = { project: E.PROJECT, projectB: PROJECT_B, checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const base = (workspace) => `${t.urls.admin}/w/${workspace}`;
    const absent = async (page, text, what) => expectEqual(await B.semantic(page, text).count(), 0, what);
    let api;

    async function signOut(s, accountName) {
      await s.page.getByRole('button', { name: new RegExp(accountName) }).first().click();
      await B.semantic(s.page, /^Sign out$/).click();
      await B.see(s.page, /Sign In/);
    }

    try {
      await t.step('seed company A (harness project) and company B (second project)', async () => {
        await dbB.reset();
        await t.db.put('orders', ORDER_A.id, orderDoc(ORDER_A.id, ORDER_A.retailer, t.seed.uids.salesman, BRANCH.id));
        const uidB = await putPerson(dbB, BRAVO_ADMIN);
        expectEqual(uidB, t.seed.uids.admin, 'the shared Auth account');
        await dbB.put('branches', BRANCH.id, { branchId: BRANCH.id, name: 'Bravo Branch', branchName: 'Bravo Branch', status: 'active' });
        await dbB.put('orders', ORDER_B.id, orderDoc(ORDER_B.id, ORDER_B.retailer, uidB, BRANCH.id));
        const denied = await fetch(`http://${process.env.FIRESTORE_EMULATOR_HOST}/v1/projects/${PROJECT_B}/databases/(default)/documents/orders/${ORDER_B.id}`);
        expectEqual(denied.status, 403, 'unsigned read of company B data');
        expectEqual((await dbB.get('users', ACCOUNTS.admin.email)).name, 'Bravo Admin', 'B profile');
        expectEqual((await t.db.get('users', ACCOUNTS.admin.email)).name, 'E2E Admin', 'A profile');
        note('B is a separate project under the same rules', { unsignedRead: denied.status });
      });

      await t.step('publish signed records and start the platform client API', async () => {
        await directory.resetDirectory();
        const alpha = {
          ...platform.baseRecord(), tenantId: 't_e2ealpha01', workspace: 'alpha', legalName: NAMES.alpha,
          companyCode: 'alpha', status: 'active', planRef: 'P2', edition: 'advanced', services: platform.SERVICES,
        };
        const bravo = ownProjectRecord({ tenantId: 't_e2ebravo01', workspace: 'bravo', projectId: PROJECT_B, planRef: 'P1' });
        const charlie = ownProjectRecord({ tenantId: 't_e2echarlie1', workspace: 'charlie', projectId: 'demo-company-c', planRef: 'P2' });
        directory.seedDirectory(keys, [
          { record: alpha, key: trusted },
          { record: bravo, key: trusted },
          { record: charlie, key: untrusted },
        ]);
        api = await directory.startPlatformApi({ origin: new URL(t.urls.admin).origin, keys });
        const served = await (await fetch(`${api.url}/v1/companies/alpha`)).json();
        expectEqual(JSON.parse(served.payload).legalName, NAMES.alpha, 'record served for alpha');
        expectEqual((await fetch(`${api.url}/v1/companies/unknown`)).status, 404, 'unknown workspace');
        note('platform API serves signed records', { alpha: served.keyId, charlie: 'signed by untrusted key' });
      });

      const alpha = await t.session('admin', { name: 'admin-alpha' });
      await t.step('/w/alpha names Alpha Trading on the sign-in page', async () => {
        await B.openApp(alpha.page, base('alpha'));
        await B.see(alpha.page, NAMES.alpha);
        await B.see(alpha.page, 'Check this name before you type your password.');
        await absent(alpha.page, NAMES.bravo, 'Bravo name on the Alpha sign-in page');
        await t.shot(alpha, 'alpha-sign-in');
      });

      await t.step('alpha: admin signs in and sees only Alpha data on the advanced plan', async () => {
        await B.loginAdmin(alpha.page, base('alpha'), ACCOUNTS.admin.email);
        await admin.waitForShell(alpha.page);
        await admin.goToPage(alpha.page, 'All Orders');
        await B.see(alpha.page, ORDER_A.retailer);
        await absent(alpha.page, ORDER_B.retailer, 'Bravo order in Alpha');
        await B.see(alpha.page, /E2E Admin/);
        await absent(alpha.page, /Bravo Admin/, 'Bravo profile in Alpha');
        expectEqual(await alpha.page.getByRole('button', { name: /^(Prediction|Demand Forecast)/ }).count() > 0, true, 'Demand Forecast in the advanced plan');
        await t.shot(alpha, 'alpha-orders');
        note('alpha', { order: ORDER_A.retailer, profile: 'E2E Admin', demandForecast: true });
      });

      await t.step('alpha: sign out', async () => {
        await signOut(alpha, 'E2E Admin');
        await t.shot(alpha, 'alpha-signed-out');
      });

      const bravo = await t.session('admin', { name: 'admin-bravo' });
      await t.step('/w/bravo names Bravo Hardware on the sign-in page', async () => {
        await B.openApp(bravo.page, base('bravo'));
        await B.see(bravo.page, NAMES.bravo);
        await B.see(bravo.page, 'Check this name before you type your password.');
        await absent(bravo.page, NAMES.alpha, 'Alpha name on the Bravo sign-in page');
        await t.shot(bravo, 'bravo-sign-in');
      });

      await t.step('bravo: the same email and password show only Bravo data on the basic plan', async () => {
        await B.loginAdmin(bravo.page, base('bravo'), ACCOUNTS.admin.email);
        await admin.waitForShell(bravo.page);
        await admin.goToPage(bravo.page, 'All Orders');
        await B.see(bravo.page, ORDER_B.retailer);
        await absent(bravo.page, ORDER_A.retailer, 'Alpha order in Bravo');
        await B.see(bravo.page, /Bravo Admin/);
        await absent(bravo.page, /E2E Admin/, 'Alpha profile in Bravo');
        expectEqual(await bravo.page.getByRole('button', { name: /^(Prediction|Demand Forecast|Trust & Impact)/ }).count(), 0, 'forecast pages in the basic plan');
        await t.shot(bravo, 'bravo-orders');
        note('bravo', { order: ORDER_B.retailer, profile: 'Bravo Admin', demandForecast: false });
      });

      await t.step('bravo: sign out', async () => {
        await signOut(bravo, 'Bravo Admin');
      });

      const unknown = await t.session('admin', { name: 'admin-unknown' });
      await t.step('/w/unknown says the workspace does not exist and offers no sign-in', async () => {
        await B.openApp(unknown.page, base('unknown'));
        await B.see(unknown.page, 'This workspace does not exist.');
        expectEqual(await unknown.page.locator('input').count(), 0, 'text fields on the unknown workspace page');
        expectEqual(await unknown.page.getByRole('button', { name: /^Sign In$/ }).count(), 0, 'Sign In button on the unknown workspace page');
        await t.shot(unknown, 'unknown');
        note('unknown workspace', { message: 'This workspace does not exist.' });
      });

      const forged = await t.session('admin', { name: 'admin-forged' });
      await t.step('/w/charlie (signed by an untrusted key) is refused and offers no sign-in', async () => {
        await B.openApp(forged.page, base('charlie'));
        await B.see(forged.page, /could not be verified/);
        expectEqual(await forged.page.locator('input').count(), 0, 'text fields on the refused workspace page');
        expectEqual(await forged.page.getByRole('button', { name: /^Sign In$/ }).count(), 0, 'Sign In button on the refused workspace page');
        await absent(forged.page, NAMES.charlie, 'forged company name');
        await t.shot(forged, 'untrusted-signature');
        note('untrusted signature', { message: 'could not be verified' });
      });
    } finally {
      if (api) await api.stop();
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify(evidence, null, 2)}\n`);
      await dbB.reset().catch(() => null);
      await directory.resetDirectory().catch(() => null);
    }
  },
};
