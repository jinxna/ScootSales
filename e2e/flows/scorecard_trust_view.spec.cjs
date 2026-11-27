'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putPerson } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'scorecard_trust_view');
const WIDE = { width: 2000, height: 1300 };
const DEV = { email: 'e2e.scorecard.developer@example.test', name: 'E2E Scorecard Developer', role: 'developer', code: 'DEV-SC', branch: 'B1' };
const QUIET = 'No scorecard yet. It is switched on per company.';
const NOT_RECORDED = 'Data source not recorded';
const NOT_CLIENT_RESULTS = 'Do not read these numbers as client results.';

const pct = (value) => (value === null ? 'no data' : `${value.toFixed(1)}%`);

function block({ scopeType, scopeKey, kind, batches, top, forecast, kept, reasons }) {
  return {
    version: 'scorecard/1.0.0',
    asOf: '2026-11-16',
    basis: "rebuilt with today's shop list and prices",
    scopeType,
    scopeKey,
    window: { firstWeekStart: '2026-08-24', lastWeekStart: '2026-11-09', weeksRequested: 12, weeksScored: 12, historyWeeks: 26, orderReadWeeks: 38 },
    ...(kind ? { dataLabel: { kind, simulationBatchIds: batches, recordCount: top.records, simulatedRecordCount: kind === 'simulated' ? top.records - 20 : 0 } } : {}),
    topRankedOrdered: {
      note: 'compares, does not prove cause',
      topCount: 2,
      sample: { salespersonWeeks: top.salespersonWeeks, topShopWeeks: top.topShopWeeks, otherShopWeeks: top.otherShopWeeks },
      topOrderedShopWeeks: top.topOrdered,
      topOrderedPercent: top.topPercent,
      otherOrderedShopWeeks: top.otherOrdered,
      otherOrderedPercent: top.otherPercent,
    },
    forecastAgainstActual: {
      source: 'rebuilt forecasts',
      level: 'product',
      sample: { productWeeks: forecast.productWeeks, shopProductWeeks: forecast.shopProductWeeks },
      forecastUnits: forecast.forecast,
      actualUnits: forecast.actual,
      absoluteErrorUnits: forecast.error,
      weightedAbsolutePercentageError: forecast.wape,
      actualUnitsWithoutForecast: forecast.without,
    },
    suggestedReordersKept: { sample: { suggestions: kept.suggestions }, keptSuggestions: kept.kept, keptPercent: kept.percent },
    ...(reasons ? { noSaleReasons: { sample: { outcomes: reasons.reduce((sum, row) => sum + row.count, 0) }, byReasonCode: reasons } } : {}),
  };
}

const ORG = {
  scopeType: 'organization', scopeKey: 'all', kind: 'simulated', batches: ['sim-e2e-batch-7'],
  top: { records: 500, salespersonWeeks: 30, topShopWeeks: 60, otherShopWeeks: 0, topOrdered: 27, topPercent: 45, otherOrdered: 0, otherPercent: null },
  forecast: { productWeeks: 84, shopProductWeeks: 410, forecast: 1250.5, actual: 1180, error: 214.25, wape: 18.2, without: 96 },
  kept: { suggestions: 140, kept: 63, percent: 45 },
  reasons: [{ reasonCode: 'price_too_high', count: 5 }, { reasonCode: 'out_of_stock', count: 3 }, { reasonCode: 'retailer_busy', count: 1 }],
};

const SALESMAN = {
  scopeType: 'salesman', scopeKey: 'S901', kind: 'real_orders', batches: [],
  top: { records: 80, salespersonWeeks: 12, topShopWeeks: 24, otherShopWeeks: 48, topOrdered: 9, topPercent: 37.5, otherOrdered: 11, otherPercent: 22.9 },
  forecast: { productWeeks: 20, shopProductWeeks: 70, forecast: 310, actual: 290, error: 41, wape: 14.1, without: 7 },
  kept: { suggestions: 33, kept: 8, percent: 24.2 },
  reasons: [{ reasonCode: 'cash_flow_issue', count: 2 }],
};

const REAL_ORG = {
  scopeType: 'organization', scopeKey: 'all', kind: 'real_orders', batches: [],
  top: { records: 900, salespersonWeeks: 40, topShopWeeks: 80, otherShopWeeks: 160, topOrdered: 52, topPercent: 65, otherOrdered: 70, otherPercent: 43.8 },
  forecast: { productWeeks: 96, shopProductWeeks: 500, forecast: 2000, actual: 1900, error: 300, wape: 15.8, without: 12 },
  kept: { suggestions: 200, kept: 90, percent: 45 },
  reasons: null,
};

const NO_LABEL_ORG = {
  ...REAL_ORG, kind: null,
  top: { ...REAL_ORG.top, topOrdered: 41, topPercent: 51.3 },
};

const UNKNOWN_KIND_ORG = {
  ...REAL_ORG, kind: 'imported_sheet',
  top: { ...REAL_ORG.top, topOrdered: 33, topPercent: 41.3 },
};

const summary = (id, weekStart, scope, extra) => ({
  summaryId: id, scopeType: scope.scopeType, scopeKey: scope.scopeKey, weekStart, weekKey: weekStart.toISOString().slice(0, 10),
  generatedAt: new Date(weekStart.getTime() + 3600000), ...extra,
});

async function lines(page) {
  return (await admin.semanticsLines(page)).join('\n');
}

function expectLines(text, expected, what) {
  for (const line of expected) {
    if (!text.includes(line)) throw new Error(`${what}: expected the page to show "${line}", it showed:\n${text}`);
  }
}

function expectAbsent(text, unexpected, what) {
  for (const line of unexpected) {
    if (text.includes(line)) throw new Error(`${what}: the page must not show "${line}"`);
  }
}

module.exports = {
  name: 'scorecard_trust_view',
  async run(t) {
    const { db, accounts } = t;
    const evidence = { checks: [] };
    const note = (check, detail = {}) => evidence.checks.push({ check, ...detail });
    const save = () => {
      fs.mkdirSync(OUT, { recursive: true });
      fs.writeFileSync(path.join(OUT, 'evidence.json'), `${JSON.stringify(evidence, null, 2)}\n`);
    };
    const refresh = async (page) => {
      await page.getByRole('button', { name: 'Refresh', exact: true }).click();
      await page.waitForTimeout(1500);
    };
    const week1 = new Date('2026-11-09T02:00:00Z');
    const week2 = new Date('2026-11-16T02:00:00Z');
    const week3 = new Date('2026-11-23T02:00:00Z');
    const week4 = new Date('2026-11-30T02:00:00Z');
    const week5 = new Date('2026-12-07T02:00:00Z');
    const ordersTotal = ORG.reasons.reduce((sum, row) => sum + row.count, 0);
    let s;
    try {
      await t.step('seed a company summary with a simulated scorecard and a salesperson summary with different numbers', async () => {
        await putPerson(db, DEV);
        const accuracy = { evaluatedForecastCount: 77, meanAbsoluteError: 3.9, meanAbsolutePercentageError: 31.4, percentageErrorCount: 77 };
        await db.put('weekly_ai_summaries', 'sc-org-w1', summary('sc-org-w1', week1, ORG, { forecastAccuracy: accuracy, scorecard: block(ORG) }));
        await db.put('weekly_ai_summaries', 'sc-sales-w1', summary('sc-sales-w1', week1, SALESMAN, { scorecard: block(SALESMAN) }));
      });

      await t.step('the company scorecard shows each stored count, percentage, the window, the basis and the simulated label with its batch', async () => {
        s = await t.session('admin', { name: 'scorecard-developer', viewport: WIDE });
        await B.loginAdmin(s.page, s.url, DEV.email);
        await admin.waitForShell(s.page);
        await admin.goToPage(s.page, 'Trust & Impact');
        await B.see(s.page, 'Scorecard', { timeout: 30000 });
        await B.see(s.page, 'Simulated data (batch sim-e2e-batch-7)', { timeout: 30000 });
        const text = await lines(s.page);
        const top = ORG.top;
        const f = ORG.forecast;
        expectLines(text, [
          '12 weeks, 24 Aug to 9 Nov',
          "Basis: rebuilt with today's shop list and prices",
          'Simulated data (batch sim-e2e-batch-7)',
          `${ORG.top.records - 20} of ${top.records} records are simulated`,
          'Top 2 ranked shops that ordered',
          'Each shop counts once for each week.',
          `Top shops: ${top.topOrdered} of ${top.topShopWeeks} (${pct(top.topPercent)})`,
          `Other shops: ${top.otherOrdered} of ${top.otherShopWeeks} (no data)`,
          'This compares. It does not prove cause.',
          'Forecast against actual, by product',
          'Each product counts once for each week.',
          `Rebuilt forecasts compared: ${f.productWeeks}`,
          'Forecast: 1250.5 units',
          'Actual: 1180 units',
          `Error: 214.25 units (${pct(f.wape)} of actual)`,
          `${f.without} units ordered with no forecast`,
          'Forecasts saved for the latest week: average error 31.4% over 77 forecasts',
          'Suggested reorders that were ordered',
          `${ORG.kept.kept} of ${ORG.kept.suggestions} (${pct(ORG.kept.percent)})`,
          'Why shops did not order',
          'Each recorded reason counts once.',
          `Price Too High: 5 of ${ordersTotal}`,
          `Out Of Stock: 3 of ${ordersTotal}`,
          `Retailer Busy: 1 of ${ordersTotal}`,
        ], 'company scorecard');
        expectAbsent(text, ['Other shops: 0 of 0 (0', QUIET, 'Real orders', NOT_RECORDED, '37.5%', 'Salesperson S901', 'shop-weeks', 'product-weeks', 'From stored patterns'], 'company scorecard');
        await t.shot(s, 'scorecard-company-simulated');
        note('company scorecard', { simulated: true, batch: 'sim-e2e-batch-7', topPercent: pct(top.topPercent), otherPercent: 'no data', wape: pct(f.wape), keptPercent: pct(ORG.kept.percent) });
      });

      await t.step('an admin finds Trust & Impact in the sidebar and sees the same company scorecard', async () => {
        const a = await t.session('admin', { name: 'scorecard-admin', viewport: WIDE });
        await B.loginAdmin(a.page, a.url, accounts.admin.email);
        await admin.waitForShell(a.page);
        await admin.goToPage(a.page, 'Trust & Impact');
        await B.see(a.page, 'Simulated data (batch sim-e2e-batch-7)', { timeout: 30000 });
        const text = await lines(a.page);
        expectLines(text, [
          'Scorecard',
          `${ORG.top.records - 20} of ${ORG.top.records} records are simulated`,
          `Top shops: ${ORG.top.topOrdered} of ${ORG.top.topShopWeeks} (${pct(ORG.top.topPercent)})`,
          `${ORG.kept.kept} of ${ORG.kept.suggestions} (${pct(ORG.kept.percent)})`,
        ], 'admin scorecard');
        expectAbsent(text, ['Real orders', NOT_RECORDED, QUIET, 'Scorecard could not load', 'Salesperson S901'], 'admin scorecard');
        await t.shot(a, 'scorecard-admin-simulated');
        note('admin scorecard', { role: 'admin', simulated: true });
      });

      await t.step('a newer company summary with real orders and no reasons replaces the label and drops the reasons tile', async () => {
        await db.put('weekly_ai_summaries', 'sc-org-w2', summary('sc-org-w2', week2, REAL_ORG, { scorecard: block(REAL_ORG) }));
        await refresh(s.page);
        await B.see(s.page, 'Real orders', { timeout: 30000 });
        const text = await lines(s.page);
        const top = REAL_ORG.top;
        expectLines(text, [
          'Real orders',
          `Top shops: ${top.topOrdered} of ${top.topShopWeeks} (${pct(top.topPercent)})`,
          `Other shops: ${top.otherOrdered} of ${top.otherShopWeeks} (${pct(top.otherPercent)})`,
          `${REAL_ORG.kept.kept} of ${REAL_ORG.kept.suggestions} (${pct(REAL_ORG.kept.percent)})`,
        ], 'real-orders scorecard');
        expectAbsent(text, ['Simulated data', NOT_RECORDED, 'Why shops did not order', 'Forecasts saved for the latest week', QUIET], 'real-orders scorecard');
        await t.shot(s, 'scorecard-company-real-orders');
        note('real orders scorecard', { reasonsTile: false, olderBlockShown: false });
      });

      for (const [id, week, scope, why] of [
        ['sc-org-w3', week3, NO_LABEL_ORG, 'no data label'],
        ['sc-org-w4', week4, UNKNOWN_KIND_ORG, 'a data label of an unknown kind'],
      ]) {
        await t.step(`a scorecard with ${why} shows the neutral warning and never "Real orders"`, async () => {
          await db.put('weekly_ai_summaries', id, summary(id, week, scope, { scorecard: block(scope) }));
          await refresh(s.page);
          const topLine = `Top shops: ${scope.top.topOrdered} of ${scope.top.topShopWeeks} (${pct(scope.top.topPercent)})`;
          await B.see(s.page, topLine, { timeout: 30000 });
          const text = await lines(s.page);
          expectLines(text, [NOT_RECORDED, NOT_CLIENT_RESULTS, topLine], why);
          expectAbsent(text, ['Real orders', 'These numbers come from recorded orders.', 'Simulated data', QUIET], why);
          await t.shot(s, `scorecard-${id}`);
          note(why, { neutralWarning: true, realOrdersLabel: false });
        });
      }

      await t.step('a newest company summary with no scorecard shows one quiet line', async () => {
        await db.put('weekly_ai_summaries', 'sc-org-w5', summary('sc-org-w5', week5, { scopeType: 'organization', scopeKey: 'all' }, {}));
        await refresh(s.page);
        await B.see(s.page, QUIET, { timeout: 30000 });
        const text = await lines(s.page);
        expectAbsent(text, ['Real orders', 'Simulated data', NOT_RECORDED, 'Top 2 ranked shops that ordered'], 'no scorecard');
        await t.shot(s, 'scorecard-none');
        note('no scorecard', { quietLine: QUIET });
      });
    } finally {
      save();
    }
  },
};
