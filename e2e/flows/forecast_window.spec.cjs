'use strict';

const fs = require('node:fs');
const http = require('node:http');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');

const PORT = 18766;
const GRID = [4, 8, 12, 26];
const LIVE_DEFAULT = 8;
const OUT = path.join(E.OUTPUT_DIR, 'forecast_window');

const PRODUCTS = [
  { productId: 'prod-1', productCode: 'R001-BEV-001', productName: 'ORGANIC APPLE CIDER VINEGAR (12BTL X 946ML)' },
  { productId: 'prod-2', productCode: 'R002-ORG-002', productName: 'INSTANT BABY OAT (24P X 450G)' },
  { productId: 'prod-3', productCode: 'R003-ORG-003', productName: 'REGULAR ROLLED OAT (24P X 450G)' },
];

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const pointAt = (index, weeks) => Math.round((10 + index * 5 + weeks * 0.5) * 10) / 10;

function forecastSet(weeks) {
  const window = { historyWeeks: weeks, historyWindowVersion: 'history-window/1.0.0', windowEvaluated: GRID.includes(weeks) };
  return {
    window,
    forecast: {
      periodStart: '2026-10-19',
      dataCutoff: '2026-10-18',
      generatedAt: '2026-10-24T08:00:00+08:00',
      ...window,
      rows: PRODUCTS.map((p, index) => ({
        ...p, category: 'GROCERY', status: 'forecasted', point: pointAt(index, weeks), ...window,
      })),
    },
  };
}

function startStandIn() {
  const requests = [];
  const server = http.createServer((req, res) => {
    const cors = {
      'Access-Control-Allow-Origin': '*',
      'Access-Control-Allow-Headers': 'authorization, content-type',
      'Access-Control-Allow-Methods': 'GET, POST, OPTIONS',
    };
    const send = (code, body) => {
      res.writeHead(code, { ...cors, 'Content-Type': 'application/json' });
      res.end(JSON.stringify(body));
    };
    if (req.method === 'OPTIONS') return send(204, {});
    let raw = '';
    req.on('data', (chunk) => { raw += chunk; });
    req.on('end', () => {
      const url = req.url.split('?')[0];
      requests.push({ method: req.method, url, hasToken: /^Bearer \S+$/.test(req.headers.authorization || ''), body: raw });
      if (req.method === 'GET' && url === '/health') return send(200, { status: 'ok' });
      if (!/^Bearer \S+$/.test(req.headers.authorization || '')) return send(401, { detail: 'sign-in required' });
      if (req.method === 'GET' && url === '/forecast-runs') return send(200, []);
      if (req.method === 'GET' && url === '/latest-forecast') {
        const { forecast } = forecastSet(LIVE_DEFAULT);
        return send(200, { ...forecast });
      }
      if (req.method === 'POST' && url === '/preview-forecast') {
        const asked = Number(JSON.parse(raw).historyWeeks);
        return send(200, { status: 'ok', preview: forecastSet(asked), baseline: forecastSet(LIVE_DEFAULT) });
      }
      return send(404, { detail: 'not found' });
    });
  });
  return new Promise((resolve) => server.listen(PORT, '127.0.0.1', () => resolve({
    requests,
    close: () => new Promise((r) => server.close(r)),
  })));
}

module.exports = {
  name: 'forecast_window',
  async run(t) {
    const { db, accounts, seed } = t;
    const evidence = { steps: [] };
    let service;
    let adminS;
    let page;

    const windowDoc = () => db.get('system_settings', 'forecast_window');
    const windowAudits = async () => (await db.list('system_audit_logs')).filter((d) => d.entityId === 'forecast_window');
    const weeksBox = () => page.getByRole('textbox', { name: /^Weeks of history/ }).first();
    const button = (name) => page.getByRole('button', { name, exact: true }).first();
    const previewRequests = () => service.requests.filter((r) => r.url === '/preview-forecast');
    const typeWeeks = async (value) => {
      await B.scrollIntoView(page, weeksBox(), { minHeight: 20, bottomInset: 0 });
      await B.fillField(page, weeksBox(), String(value));
    };
    const record = (name, detail) => evidence.steps.push({ name, ...detail });

    try {
      await t.step('the Demand Forecast page shows the lookback window card and the window of the rows', async () => {
        service = await startStandIn();
        adminS = await t.session('admin');
        page = adminS.page;
        await B.loginAdmin(page, adminS.url, accounts.admin.email);
        await admin.waitForShell(page);
        await admin.goToPage(page, 'Demand Forecast');
        await B.see(page, 'Lookback window');
        await B.see(page, /Based on the last 8 weeks/);
        await B.see(page, /Live window: 8 weeks \(default\)/);
        expectEqual(await windowDoc(), null, 'saved window before any change');
        await t.shot(adminS, 'window-card');
      });

      await t.step('a preview shows the typed window beside the live one and saves nothing', async () => {
        await typeWeeks(12);
        await button('Preview').click();
        await B.see(page, 'PREVIEW — not saved');
        await B.see(page, /Last 12 weeks against the live 8 weeks\. 3 of 3 products change\./);
        for (const [index, product] of PRODUCTS.entries()) {
          const live = pointAt(index, LIVE_DEFAULT).toFixed(1);
          const preview = pointAt(index, 12).toFixed(1);
          await B.see(page, `Preview row ${product.productName}: live ${live}, preview ${preview}`);
        }
        expectEqual(previewRequests().map((r) => JSON.parse(r.body)), [{ historyWeeks: 12 }], 'preview requests');
        expectEqual(previewRequests().every((r) => r.hasToken), true, 'preview sent with a sign-in token');
        expectEqual(service.requests.some((r) => r.url === '/run-forecast'), false, 'run-forecast requests');
        expectEqual(await windowDoc(), null, 'saved window after a preview');
        expectEqual((await windowAudits()).length, 0, 'audit entries after a preview');
        await t.shot(adminS, 'preview-12');
        record('preview', { requested: 12, previewRequests: previewRequests().length, savedWindow: null, auditEntries: 0 });
      });

      await t.step('Clear removes the preview', async () => {
        await button('Clear').click();
        await page.getByText('PREVIEW — not saved').first().waitFor({ state: 'detached' });
      });

      await t.step('a window outside the evaluated grid is labelled Not evaluated', async () => {
        await typeWeeks(10);
        await B.see(page, /Not evaluated: accuracy was only checked for 4, 8, 12, 26 weeks\./);
        await button('Preview').click();
        await B.see(page, /Last 10 weeks \(Not evaluated\) against the live 8 weeks/);
        await button('Clear').click();
      });

      await t.step('a window below 6 weeks warns what stops working', async () => {
        await typeWeeks(5);
        await B.see(page, /Below 6 weeks, "stopped buying" alerts cannot fire\./);
        await B.see(page, /Below 7 weeks, no forecast range is shown\./);
      });

      await t.step('a window outside 4..104 is refused with no write', async () => {
        await typeWeeks(3);
        await button('Save as live window').click();
        await B.see(page, 'Enter a whole number from 4 to 104 weeks.');
        expectEqual(await windowDoc(), null, 'saved window after a refused value');
        expectEqual((await windowAudits()).length, 0, 'audit entries after a refused value');
      });

      await t.step('Cancel in the confirm step saves nothing', async () => {
        await typeWeeks(10);
        await button('Save as live window').click();
        await B.see(page, 'Set the live window?');
        await button('Cancel').click();
        await page.getByText('Set the live window?').first().waitFor({ state: 'detached' });
        expectEqual(await windowDoc(), null, 'saved window after Cancel');
      });

      await t.step('Save as live window writes the setting and an audit entry', async () => {
        await button('Save as live window').click();
        await B.see(page, 'Set the live window?');
        await page.getByRole('button', { name: 'Save as live window', exact: true }).last().click();
        await B.see(page, /Live window set to 10 weeks\. It applies from the next run\./);
        const saved = await db.waitForDoc('system_settings', 'forecast_window', (d) => d.historyWeeks === 10);
        expectEqual(saved.historyWeeks, 10, 'saved historyWeeks');
        expectEqual(saved.updatedBy, seed.uids.admin, 'updatedBy');
        const audit = (await windowAudits())[0];
        expectEqual(audit.action, 'updated', 'audit action');
        expectEqual(audit.entityType, 'system_settings', 'audit entityType');
        expectEqual(audit.metadata.historyWeeks, 10, 'audit historyWeeks');
        expectEqual(audit.metadata.windowEvaluated, false, 'audit windowEvaluated');
        expectEqual(audit.metadata.previousHistoryWeeks, null, 'audit previousHistoryWeeks');
        await B.see(page, /Live window: 10 weeks/);
        await t.shot(adminS, 'saved-10');
        record('save', { historyWeeks: saved.historyWeeks, updatedBy: 'admin', auditEntries: (await windowAudits()).length, windowEvaluated: false });
      });

      await t.step('the saved window is shown again after the page is opened afresh', async () => {
        await admin.goToPage(page, 'Products');
        await admin.goToPage(page, 'Demand Forecast');
        await B.see(page, /Live window: 10 weeks/);
        await B.scrollIntoView(page, weeksBox(), { minHeight: 20, bottomInset: 0 });
        expectEqual(Number((await B.focusedValue(weeksBox())).trim()), 10, 'weeks box after reopening');
      });
    } finally {
      if (service) {
        evidence.standInRequests = service.requests.map((r) => `${r.method} ${r.url}`);
        await service.close();
      }
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'result.json'), `${JSON.stringify({ flow: 'forecast_window', ...evidence }, null, 2)}\n`);
    }
  },
};
