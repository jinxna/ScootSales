'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const platform = require('../lib/platform.cjs');
const directory = require('../lib/platform_api.cjs');
const { ACCOUNTS, BRANCH, putPerson } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'idle_workspace_scope');
const PROJECT_B = 'demo-company-b';
const NAMES = { alpha: 'Alpha Trading Sdn Bhd', bravo: 'Bravo Hardware Sdn Bhd' };
const EXPIRED = 'Session expired. Sign in again.';
const BRAVO_ADMIN = { ...ACCOUNTS.admin, name: 'Bravo Admin' };

function bravoRecord() {
  const projectId = PROJECT_B;
  return {
    tenantId: 't_e2ebravo01', workspace: 'bravo', legalName: NAMES.bravo, companyCode: 'bravo',
    location: { projectId, databaseId: '(default)', authTenantId: null },
    locationKind: 'byo',
    clientConfig: {
      apiKey: `AIza${'B'.repeat(35)}`,
      appId: '1:123456789012:web:0123456789abcdef',
      messagingSenderId: '123456789012',
      storageBucket: `${projectId}.firebasestorage.app`,
    },
    status: 'active', planRef: 'P1', edition: 'basic', releaseRing: 'pilot', rulesVersion: 'e2e', services: {},
  };
}

module.exports = {
  name: 'idle_workspace_scope',
  platformApi: false,
  async run(t) {
    const dbB = E.client(PROJECT_B);
    const trusted = platform.ensureKey(platform.KEY_ID);
    const base = (ws) => `${t.urls.admin}/w/${ws}`;
    const evidence = { observed: {}, keys: {} };
    const wrong = [];
    let api;
    fs.mkdirSync(OUT, { recursive: true });

    const keys = (page) => page.evaluate(() => Object.keys(localStorage).sort());
    const idleKeys = async (page) => (await keys(page)).filter((k) => k.startsWith('scoot.admin.'));
    const snapKeys = async (page) => (await keys(page)).filter((k) => k.startsWith('fypa.forecast_snapshot.v1'));
    const record = (name, value) => { evidence.keys[name] = value; };
    const backdate = (page) => page.evaluate(() => {
      for (const k of Object.keys(localStorage)) {
        if (k.startsWith('scoot.admin.lastActivityMs')) localStorage.setItem(k, String(Date.now() - 2 * 60 * 60 * 1000));
      }
    });
    const expiredShown = async (page) => (await B.semantic(page, EXPIRED).count()) > 0;
    const shellShown = async (page) => (await page.getByRole('button', { name: 'All Orders' }).count()) > 0;
    async function settle(page) { await page.waitForTimeout(3000); }

    async function signIn(s, ws, email = ACCOUNTS.admin.email) {
      await B.loginAdmin(s.page, base(ws), email);
      await admin.waitForShell(s.page);
    }
    async function openForecast(s) {
      await admin.goToPage(s.page, /^(Prediction|Demand Forecast)/);
      await B.see(s.page, 'E2E IDLE FORECAST');
      await s.page.waitForTimeout(1500);
    }
    async function check(name, s, ws) {
      await B.openApp(s.page, base(ws));
      let sawExpired = false;
      let sawShell = false;
      for (let i = 0; i < 40; i += 1) {
        sawExpired = sawExpired || await expiredShown(s.page);
        sawShell = sawShell || await shellShown(s.page);
        if (i === 12) await t.shot(s, `${name}-early`);
        await s.page.waitForTimeout(250);
      }
      const result = { sawExpiredMessage: sawExpired, sawDashboard: sawShell, signInShownAtEnd: (await s.page.locator('input').count()) > 1 };
      evidence.observed[name] = result;
      await t.shot(s, name);
      if (!result.sawExpiredMessage || result.sawDashboard || !result.signInShownAtEnd) wrong.push(`${name}: ${JSON.stringify(result)}`);
    }

    try {
      await t.step('seed company alpha (harness project) and company bravo (second project)', async () => {
        await dbB.reset();
        const uidB = await putPerson(dbB, BRAVO_ADMIN);
        await dbB.put('branches', BRANCH.id, { branchId: BRANCH.id, name: 'Bravo Branch', branchName: 'Bravo Branch', status: 'active' });
        await t.db.put('demand_forecasts', 'e2e-idle-fc', {
          productId: 'prod-1', productName: 'E2E IDLE FORECAST', status: 'ok', forecastMonth: '2026-10',
          periodStart: '2026-10-05', dataCutoff: '2026-10-04', generatedAt: new Date().toISOString(),
          componentCount: 1, modelledComponentCount: 1, model: 'aggregate', referenceUnits: 10,
          recommendedAction: 'Increase stock', point: 120,
        });
        if (!uidB) throw new Error('no bravo admin');
        await directory.resetDirectory();
        const alpha = {
          ...platform.baseRecord(), tenantId: 't_e2ealpha01', workspace: 'alpha', legalName: NAMES.alpha,
          companyCode: 'alpha', status: 'active', planRef: 'P2', edition: 'advanced', services: platform.SERVICES,
        };
        directory.seedDirectory([trusted], [{ record: alpha, key: trusted }, { record: bravoRecord(), key: trusted }]);
        api = await directory.startPlatformApi({ origin: new URL(t.urls.admin).origin, keys: [trusted] });
      });

      const s1 = await t.session('admin', { name: 'case1-b-signed-out' });
      await t.step('case 1: A idle past the limit, /w/bravo opened signed out, /w/alpha reloaded', async () => {
        await signIn(s1, 'alpha');
        record('case1-after-alpha-sign-in', await idleKeys(s1.page));
        await backdate(s1.page);
        await B.openApp(s1.page, base('bravo'));
        await B.see(s1.page, NAMES.bravo);
        await settle(s1.page);
        record('case1-after-bravo-signed-out-load', await idleKeys(s1.page));
        await t.shot(s1, 'case1-bravo-sign-in');
        await check('case1-alpha-reload', s1, 'alpha');
      });

      const s2 = await t.session('admin', { name: 'case2-b-signed-in' });
      await t.step('case 2: A idle past the limit, bravo signed in, /w/alpha reloaded', async () => {
        await signIn(s2, 'alpha');
        await backdate(s2.page);
        await signIn(s2, 'bravo');
        record('case2-after-bravo-sign-in', await idleKeys(s2.page));
        await t.shot(s2, 'case2-bravo-shell');
        await check('case2-alpha-reload', s2, 'alpha');
      });

      const s3 = await t.session('admin', { name: 'forecast-sign-out' });
      await t.step('forecast rows: sign in, open Prediction, sign out', async () => {
        await signIn(s3, 'alpha');
        await openForecast(s3);
        await t.shot(s3, 'forecast-open');
        record('signout-before', await snapKeys(s3.page));
        await s3.page.getByRole('button', { name: /E2E Admin/ }).first().click();
        await B.semantic(s3.page, /^Sign out$/).click();
        await B.see(s3.page, /Sign In/);
        await s3.page.waitForTimeout(1500);
        record('signout-after', await snapKeys(s3.page));
        await t.shot(s3, 'forecast-signed-out');
        if ((await snapKeys(s3.page)).length) wrong.push(`sign-out left ${JSON.stringify(await snapKeys(s3.page))}`);
        if (!(evidence.keys['signout-before'] || []).length) wrong.push('Prediction wrote no snapshot key');
      });

      const s4 = await t.session('admin', { name: 'forecast-idle' });
      await t.step('forecast rows: sign in, open Prediction, idle past the limit, reload', async () => {
        await signIn(s4, 'alpha');
        await openForecast(s4);
        record('idle-before', await snapKeys(s4.page));
        await backdate(s4.page);
        await check('idle-alpha-reload', s4, 'alpha');
        record('idle-after', await snapKeys(s4.page));
        if ((await snapKeys(s4.page)).length) wrong.push(`idle expiry left ${JSON.stringify(await snapKeys(s4.page))}`);
      });

      await t.step('the workspace is part of the snapshot key', async () => {
        const named = (evidence.keys['signout-before'] || []).every((k) => k.startsWith('fypa.forecast_snapshot.v1.alpha.'));
        if (!named) wrong.push(`snapshot key has no workspace: ${JSON.stringify(evidence.keys['signout-before'])}`);
      });

      await t.step('all replays behave', async () => {
        if (wrong.length) throw new Error(wrong.join(' | '));
      });
    } finally {
      fs.writeFileSync(path.join(OUT, 'storage-keys.json'), `${JSON.stringify({ ...evidence, wrong }, null, 2)}\n`);
      if (api) await api.stop();
      await dbB.reset().catch(() => null);
      await directory.resetDirectory().catch(() => null);
    }
  },
};
