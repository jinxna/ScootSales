'use strict';

const fs = require('node:fs');
const path = require('node:path');
const B = require('../lib/browser.cjs');
const E = require('../lib/emulator.cjs');
const admin = require('../lib/admin.cjs');
const { putMany } = require('../lib/bulk.cjs');
const { RETAILERS } = require('../lib/seed.cjs');

const OUT = path.join(E.OUTPUT_DIR, 'visit_history_range');
const KL_MS = 8 * 3600e3;
const MIN = 60e3;
const HEADER = 'Arrival,Departure,Salesman,Retailer,Status,Source,Arrival mode,Arrival distance (m)';

function expectEqual(actual, expected, what) {
  if (JSON.stringify(actual) !== JSON.stringify(expected)) {
    throw new Error(`${what}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

const klNow = new Date(Date.now() + KL_MS);
const TODAY = [klNow.getUTCFullYear(), klNow.getUTCMonth(), klNow.getUTCDate()];
function day(offset) {
  const x = new Date(Date.UTC(TODAY[0], TODAY[1], TODAY[2] + offset));
  return { y: x.getUTCFullYear(), m: x.getUTCMonth(), d: x.getUTCDate() };
}
const at = (offset, hh, mm) => new Date(Date.UTC(TODAY[0], TODAY[1], TODAY[2] + offset, hh, mm) - KL_MS);
const RANGE = { start: day(-90), end: day(-1) };
const RANGE_START = Date.UTC(RANGE.start.y, RANGE.start.m, RANGE.start.d) - KL_MS;
const RANGE_END = Date.UTC(RANGE.end.y, RANGE.end.m, RANGE.end.d + 1) - KL_MS;

const pad = (n, w = 2) => String(n).padStart(w, '0');
function kl(date) {
  const x = new Date(date.getTime() + KL_MS);
  return `${pad(x.getUTCDate())}/${pad(x.getUTCMonth() + 1)}/${x.getUTCFullYear()} ${pad(x.getUTCHours())}:${pad(x.getUTCMinutes())} MYT`;
}
const pickerDate = ({ y, m, d }) => `${pad(m + 1)}/${pad(d)}/${y}`;

function parseCsv(text) {
  const rows = [];
  let row = [];
  let field = '';
  let quoted = false;
  for (let i = 0; i < text.length; i += 1) {
    const c = text[i];
    if (quoted) {
      if (c === '"' && text[i + 1] === '"') { field += '"'; i += 1; } else if (c === '"') quoted = false; else field += c;
    } else if (c === '"') quoted = true;
    else if (c === ',') { row.push(field); field = ''; } else if (c === '\n' || c === '\r') {
      if (c === '\r' && text[i + 1] === '\n') i += 1;
      row.push(field); field = '';
      rows.push(row); row = [];
    } else field += c;
  }
  if (field !== '' || row.length) { row.push(field); rows.push(row); }
  return rows;
}

module.exports = {
  name: 'visit_history_range',
  async run(t) {
    const { db, accounts, seed } = t;
    const salesUid = seed.uids.salesman;
    const TEAM = { A: { code: accounts.salesman.code, uid: salesUid }, B: { code: 'S002', uid: 'uid-team-b' } };
    const visits = [];
    const logDocs = [];
    const stopDocs = [];
    const orderDocs = [];

    function addLog(team, id, name, when, extra = {}, expectName = name) {
      const data = {
        salesmanCode: TEAM[team].code, salesmanId: TEAM[team].code, branchId: 'B1',
        retailerId: RETAILERS[0].id, retailerName: name, arrivalTime: when, ...extra,
      };
      logDocs.push({ id, data });
      visits.push({ team, name: expectName, at: when, kind: 'log', departure: 'In progress', status: 'in progress', source: '', mode: '', distance: '' });
    }
    function addStop(team, planId, stopId, name, when, { skipped = false, mode = 'location_verified', distance = 12, deduped = false } = {}) {
      const end = new Date(when.getTime() + (skipped ? 5 : 10) * MIN);
      stopDocs.push({
        id: `${planId}_${TEAM[team].uid}_${stopId}`,
        data: {
          planId, stopId, salesmanUid: TEAM[team].uid, salesmanCode: TEAM[team].code, branchId: 'B1',
          retailerId: RETAILERS[1].id, retailerName: name, lifecycleSchemaVersion: 2,
          status: skipped ? 'skipped' : 'completed', arrivedAt: when,
          ...(skipped ? { skippedAt: end } : { completedAt: end }),
          arrivalMode: mode, ...(mode === 'location_verified' ? { arrivalDistanceMeters: distance } : {}),
        },
      });
      visits.push({
        team, name, at: when, kind: 'stop', deduped, skipped, onSite: mode === 'location_verified',
        departure: kl(end), status: skipped ? 'skipped' : 'completed', source: 'Assigned route',
        mode, distance: mode === 'location_verified' ? String(distance) : '',
      });
    }

    await t.step('seed two teams: 90 Kuching days of visits in both sources, edge rows, legacy rows, orders', async () => {
      for (let i = 0; i < 520; i += 1) {
        addLog('A', `vl-a-${pad(i, 4)}`, `Visit A-L-${pad(i, 4)}`, at(-90 + (i % 90), 9 + (i % 8), (i * 7) % 60));
      }
      for (let i = 0; i < 300; i += 1) {
        addStop('A', `PLAN-A-${pad(Math.floor(i / 10))}`, `s${i}`, `Visit A-S-${pad(i, 4)}`, at(-90 + ((i * 7) % 90), 8 + (i % 9), (i * 11) % 60), {
          skipped: i % 15 === 0, mode: i % 3 === 1 ? 'manual_unverified' : 'location_verified', distance: 3 + (i % 70),
        });
      }
      for (let i = 0; i < 10; i += 1) addLog('B', `vl-b-${pad(i)}`, `Visit B-L-${pad(i)}`, at(-80 + i * 5, 10, i));
      for (let i = 0; i < 30; i += 1) {
        addStop('B', `PLAN-B-${pad(Math.floor(i / 10))}`, `s${i}`, `Visit B-S-${pad(i)}`, at(-85 + i * 2, 13, i), {
          skipped: i % 15 === 0, mode: i % 2 ? 'manual_unverified' : 'location_verified', distance: 4 + i,
        });
      }
      addLog('A', 'edge-in-start', 'Visit A-EDGE-IN-START', at(-90, 0, 1));
      addStop('A', 'PLAN-EDGE', 'out-before', 'Visit A-EDGE-OUT-BEFORE', at(-91, 23, 59));
      addStop('A', 'PLAN-EDGE', 'in-end', 'Visit A-EDGE-IN-END', at(-1, 23, 59), { distance: 8 });
      addLog('A', 'edge-out-after', 'Visit A-EDGE-OUT-AFTER', at(0, 0, 1));
      addLog('A', 'dup-log', 'Visit A-DUP-LOG', at(-30, 10, 0), { planId: 'PLAN-DUP', stopId: 'dup' });
      addStop('A', 'PLAN-DUP', 'dup', 'Visit A-DUP-STOP', at(-30, 10, 0), { distance: 5, deduped: true });
      addLog('A', 'inj-log', '=1+1 Visit A-INJ', at(-45, 11, 0), {}, "'=1+1 Visit A-INJ");
      logDocs.push({
        id: 'zz-today',
        data: { salesmanCode: 'S001', salesmanId: 'S001', branchId: 'B1', retailerId: RETAILERS[0].id, retailerName: 'Visit A-TODAY', arrivalTime: new Date(Date.now() - 30e3) },
      });
      logDocs.push(
        { id: 'legacy-a-1', data: { salesmanCode: 'S001', salesmanId: 'S001', branchId: 'B1', retailerName: 'Visit A-LEGACY-1', createdAt: at(-20, 10, 0) } },
        { id: 'legacy-a-2', data: { salesmanCode: 'S001', salesmanId: 'S001', branchId: 'B1', retailerName: 'Visit A-LEGACY-2', createdAt: at(-21, 10, 0) } },
        { id: 'legacy-a-3', data: { salesmanCode: 'S001', salesmanId: 'S001', branchId: 'B1', retailerName: 'Visit A-LEGACY-3', arrivalTime: '2026-08-15 10:00' } },
        { id: 'legacy-b-1', data: { salesmanCode: 'S002', salesmanId: 'S002', branchId: 'B1', retailerName: 'Visit B-LEGACY-1', createdAt: at(-22, 10, 0) } },
      );
      const order = (id, team, when, status = 'submitted') => orderDocs.push({
        id,
        data: {
          orderId: id, salesmanCode: TEAM[team].code, salesmanId: TEAM[team].code, salesmanUid: TEAM[team].uid, branchId: 'B1',
          retailerId: RETAILERS[0].id, retailerName: RETAILERS[0].name, status, totalPrice: 10, items: [],
          submittedAt: when, createdAt: when,
        },
      });
      order('ORD-HR-A1', 'A', at(-10, 10, 0));
      order('ORD-HR-A2', 'A', at(-20, 10, 0));
      order('ORD-HR-A3', 'A', at(-90, 0, 1));
      order('ORD-HR-A-OUT', 'A', at(-91, 23, 59));
      order('ORD-HR-A-REJ', 'A', at(-12, 10, 0), 'rejected');
      order('ORD-HR-B1', 'B', at(-5, 10, 0));
      order('ORD-HR-B2', 'B', at(-60, 10, 0));

      await putMany(db, 'visit_logs', logDocs);
      await putMany(db, 'route_stop_progress', stopDocs);
      await putMany(db, 'orders', orderDocs);
    });

    const inRange = (v) => !v.deduped && v.at.getTime() >= RANGE_START && v.at.getTime() < RANGE_END;
    const expectedFor = (teams) => visits.filter((v) => teams.includes(v.team) && inRange(v));
    const seedA = expectedFor(['A']);
    const seedAll = expectedFor(['A', 'B']);
    const summaryText = (team) => {
      const stops = visits.filter((v) => v.team === team && v.kind === 'stop'
        && v.at.getTime() >= RANGE_START && v.at.getTime() < RANGE_END);
      const onSite = stops.filter((v) => v.onSite).length;
      const orders = orderDocs.filter((o) => o.data.salesmanCode === TEAM[team].code && o.data.status !== 'rejected'
        && o.data.submittedAt.getTime() >= RANGE_START && o.data.submittedAt.getTime() < RANGE_END).length;
      return `${TEAM[team].code}: ${stops.length} arrived, ${stops.filter((v) => v.skipped).length} skipped after arrival, `
        + `${Math.round((onSite * 100) / stops.length)}% on-site GPS, ${orders} orders`;
    };

    async function pickRange(page) {
      await page.getByRole('button', { name: /^Custom/ }).click();
      await page.getByRole('button', { name: 'Switch to input' }).click();
      await B.fillField(page, page.getByRole('textbox', { name: /Start Date/i }), pickerDate(RANGE.start));
      await B.fillField(page, page.getByRole('textbox', { name: /End Date/i }), pickerDate(RANGE.end));
      await page.getByRole('button', { name: 'OK', exact: true }).click();
    }

    async function exportCsv(page, label) {
      const [download] = await Promise.all([
        page.waitForEvent('download', { timeout: 30000 }),
        page.getByRole('button', { name: 'Export CSV', exact: true }).click(),
      ]);
      const file = path.join(OUT, `${label}.csv`);
      await download.saveAs(file);
      const rows = parseCsv(fs.readFileSync(file, 'utf8').replace(/^﻿/, '')).filter((r) => r.some((c) => c !== ''));
      expectEqual(rows[0].join(','), HEADER, `${label} CSV header`);
      return rows.slice(1);
    }

    function checkCsv(rows, expected, label) {
      const byName = new Map(expected.map((v) => [v.name, v]));
      expectEqual(rows.length, expected.length, `${label} CSV row count`);
      const seen = new Set();
      let previous = Infinity;
      for (const [arrival, departure, salesman, name, status, source, mode, distance] of rows) {
        const v = byName.get(name);
        if (!v) throw new Error(`${label} CSV has a row that is not in the seed or the range: ${name}`);
        if (seen.has(name)) throw new Error(`${label} CSV lists ${name} twice`);
        seen.add(name);
        expectEqual([arrival, departure, salesman, status, source, mode, distance],
          [kl(v.at), v.departure, TEAM[v.team].code, v.status, v.source, v.mode, v.distance], `${label} CSV row ${name}`);
        if (v.at.getTime() > previous) throw new Error(`${label} CSV is not newest first at ${name}`);
        previous = v.at.getTime();
      }
      return rows.length;
    }

    let supS;
    let adminS;
    const summary = {
      range: { from: pickerDate(RANGE.start), to: pickerDate(RANGE.end), timezone: 'Asia/Kuching (UTC+8)', browserTimezone: 'UTC' },
      seeded: { visitLogs: logDocs.length, assignedRouteStops: stopDocs.length, orders: orderDocs.length },
    };

    try {
      fs.mkdirSync(OUT, { recursive: true });

      await t.step('supervisor opens Team Visit Logs (browser time zone UTC); the live view shows the newest visit', async () => {
        supS = await t.session('admin', { timezoneId: 'UTC' });
        const zone = await supS.page.evaluate(() => Intl.DateTimeFormat().resolvedOptions().timeZone);
        expectEqual(zone, 'UTC', 'browser time zone');
        await B.loginAdmin(supS.page, supS.url, accounts.supervisor.email);
        await admin.waitForSupervisorShell(supS.page);
        await admin.goToPage(supS.page, 'Team Visit Logs');
        await B.see(supS.page, 'Visit A-TODAY', { timeout: 60000 });
        await B.see(supS.page, /\d+ visits? today/);
        await t.shot(supS, 'live-today');
      });

      await t.step('supervisor picks the custom range: exact count, caveat, per-salesperson summary', async () => {
        await pickRange(supS.page);
        await B.see(supS.page, new RegExp(`${seedA.length} visits in this range`), { timeout: 90000 });
        summary.supervisor = { expectedRows: seedA.length, shownByFilter: seedA.length };
        await B.see(supS.page, '3 rows have no timestamp arrival and are not in this range.');
        await B.see(supS.page, summaryText('A'));
        const saleOrdersA = Number(/(\d+) orders$/.exec(summaryText('A'))[1]);
        expectEqual(await B.semantic(supS.page, new RegExp(`${TEAM.A.code}: .*, ${saleOrdersA + 1} orders`)).count(), 0, 'range Orders count with the rejected order');
        expectEqual((await db.get('orders', 'ORD-HR-A-REJ')).status, 'rejected', 'stored status of the rejected order');
        expectEqual(await supS.page.getByText('Choose a shorter range').count(), 0, 'truncation banner');
        await t.shot(supS, 'custom-range');
      });

      await t.step('the supervisor CSV equals the seed: team A only, past the old 500 cap, edges and fields right', async () => {
        const rows = await exportCsv(supS.page, 'supervisor_range');
        checkCsv(rows, seedA, 'supervisor');
        if (rows.some((r) => r[3].startsWith('Visit B-') || r[3].includes('LEGACY'))) throw new Error('supervisor CSV has team B or legacy rows');
        const names = new Set(rows.map((r) => r[3]));
        for (const name of ['Visit A-EDGE-IN-START', 'Visit A-EDGE-IN-END', 'Visit A-DUP-LOG', "'=1+1 Visit A-INJ"]) {
          if (!names.has(name)) throw new Error(`supervisor CSV is missing ${name}`);
        }
        for (const name of ['Visit A-EDGE-OUT-BEFORE', 'Visit A-EDGE-OUT-AFTER', 'Visit A-DUP-STOP', 'Visit A-TODAY']) {
          if (names.has(name)) throw new Error(`supervisor CSV must not have ${name}`);
        }
        summary.supervisor.csvRows = rows.length;
        summary.supervisor.csvMatchesSeed = true;
      });

      await t.step('admin picks the same range: both teams, caveat counts every team', async () => {
        adminS = await t.session('admin', { timezoneId: 'UTC' });
        await B.loginAdmin(adminS.page, adminS.url, accounts.admin.email);
        await admin.waitForShell(adminS.page);
        await admin.goToPage(adminS.page, 'Visit Logs');
        await pickRange(adminS.page);
        await B.see(adminS.page, new RegExp(`${seedAll.length} visits in this range`), { timeout: 90000 });
        await B.see(adminS.page, '4 rows have no timestamp arrival and are not in this range.');
        await B.see(adminS.page, summaryText('A'));
        await B.see(adminS.page, summaryText('B'));
        await t.shot(adminS, 'custom-range');
      });

      await t.step('the admin CSV equals the seed for both teams', async () => {
        const rows = await exportCsv(adminS.page, 'admin_range');
        checkCsv(rows, seedAll, 'admin');
        summary.admin = { expectedRows: seedAll.length, csvRows: rows.length, csvMatchesSeed: true };
      });
    } finally {
      fs.writeFileSync(path.join(OUT, 'summary.json'), JSON.stringify(summary, null, 2));
    }
  },
};
