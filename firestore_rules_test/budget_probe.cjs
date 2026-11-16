'use strict';
const fs = require('node:fs');
const path = require('node:path');
const { spawnSync } = require('node:child_process');
const { initializeTestEnvironment } = require('@firebase/rules-unit-testing');
const { Timestamp, serverTimestamp } = require('firebase/firestore');
const fx = require('./identity_audit_fixtures.cjs');

const out = process.argv[2];
if (!out) throw new Error('usage: budget_probe.cjs <out.json> [step] [rowFilterRegex|--route-lifecycle]');
const STEP = Number(process.argv[3] || 4);
if (!Number.isInteger(STEP) || STEP < 1 || STEP > 160) {
  throw new Error('step must be an integer from 1 to 160');
}
const ROUTE_LIFECYCLE = process.argv[4] === '--route-lifecycle';
const GUARD = process.argv.includes('--guard');
if (GUARD && !ROUTE_LIFECYCLE) throw new Error('--guard needs --route-lifecycle');
const MIN_HEADROOM_UNITS = 6;
const FILTER = process.argv[4] && !ROUTE_LIFECYCLE ? new RegExp(process.argv[4]) : null;
const MAX_UNITS = 160;
const RULES = fs.readFileSync(
  process.env.PROBE_RULES || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
  'utf8',
);

const stamp = Timestamp.fromDate(new Date('2026-06-20T00:00:00Z'));
const specialRequest = (overrides = {}) => ({
  retailerName: 'Retailer 1', requestedItem: 'Special Item',
  reason: 'Retailer requested a non-standard item.', salesmanCode: 'S001', branchId: 'B1',
  createdByUid: 'sales-1', createdByRole: 'salesman', createdAt: stamp, updatedAt: stamp,
  status: 'pending_supervisor', approvalStep: 'Supervisor', lastActorUid: 'sales-1',
  lastActorRole: 'salesman', lastActionAt: stamp, ...overrides,
});
const newVisit = (ownerUid) => ({
  ownerUid, salesmanUid: ownerUid, marketplace: 'Retailer C', time: '11:00',
  purpose: 'Restock', notes: '', date: '2026-06-30', day: 'Tuesday',
  createdAt: serverTimestamp(), updatedAt: serverTimestamp(),
});

const rows = fx.buildAuditRows({ specialRequest, newVisit });
const label = (row) => `${row.col} ${row.op}${row.label ? ` (${row.label})` : ''}`;

async function runLevel(units, cases) {
  const env = await initializeTestEnvironment({
    projectId: 'demo-fyp-a',
    firestore: { rules: fx.padRules(RULES, units) },
  });
  try {
    for (const shape of fx.SHAPES) {
      await env.clearFirestore();
      await env.withSecurityRulesDisabled((c) => fx.seedAuditActors(c.firestore(), shape));
      for (const c of cases.filter((x) => x.shape === shape)) {
        await env.withSecurityRulesDisabled((ctx) => fx.resetRowState(ctx.firestore(), c.row, c.actor, c.n));
        const db = env.authenticatedContext(fx.AUDIT_ACTORS[c.actor].uid, { email: 'admin@example.test', auth_time: Math.floor(Date.now() / 1000) }).firestore();
        try {
          await fx.attemptRow(db, c.row, c.actor, c.n);
          c.passedAt = units;
        } catch (err) {
          c.failedAt = units;
          if (!fx.BUDGET.test(String(err && err.message))) c.deniedAt = units;
        }
      }
    }
  } finally {
    await env.cleanup();
  }
}

(async () => {
  if (ROUTE_LIFECYCLE) {
    const report = new Map();
    const levels = [];
    if (GUARD) levels.push(MIN_HEADROOM_UNITS);
    else for (let units = 0; units <= MAX_UNITS; units += STEP) levels.push(units);
    for (const units of levels) {
      const result = spawnSync(process.execPath, [
        require.resolve('mocha/bin/mocha.js'), '--timeout', '300000',
        path.join(__dirname, 'firestore.rules.test.cjs'),
        '--grep', 'closes a .* session with the final (completed|skipped) stop|android-route-arrival-budget|android-route-gps-completion-budget|gps-backlog-budget|copilot-outcome-budget',
        '--reporter', 'json',
      ], {
        encoding: 'utf8', maxBuffer: 16 * 1024 * 1024,
        env: {
          ...process.env,
          FIRESTORE_RULES_PATH: process.env.PROBE_RULES || path.join(__dirname, '..', 'admin_dashboard', 'firestore.rules'),
          FIRESTORE_RULES_HEADROOM_UNITS: String(units),
        },
      });
      if (result.error) throw result.error;
      const data = JSON.parse(result.stdout);
      if (data.tests.length !== 8 || data.stats.pending !== 0) {
        throw new Error('Expected four final-stop cases, the Android arrival case, the GPS completion case, the backlog case and the copilot outcome case');
      }
      for (const test of data.tests) {
        const row = report.get(test.title) || { op: test.title, headroomUnits: null };
        if (Object.keys(test.err).length) {
          row.failedAtUnits ??= units;
          row.failureKind = fx.BUDGET.test(test.err.message) ? 'expression_budget' : 'other';
          row.failure = test.err.message;
        } else if (row.failedAtUnits === undefined) {
          row.headroomUnits = units;
        }
        report.set(test.title, row);
      }
      process.stderr.write(`lifecycle level ${units}: ${data.stats.passes}/8 passed\n`);
      if ([...report.values()].every((row) => row.failedAtUnits !== undefined)) break;
    }
    if (out !== '-') {
      fs.writeFileSync(out, JSON.stringify({
        mode: GUARD ? 'route-lifecycle-guard' : 'route-lifecycle', step: STEP,
        minHeadroomUnits: MIN_HEADROOM_UNITS,
        interpretation: 'Padding units on actual atomic writes; not an exact expression count.',
        report: [...report.values()],
      }, null, 2));
    }
    if (GUARD) {
      const short = [...report.values()].filter((row) => row.failedAtUnits !== undefined);
      if (short.length) {
        console.error(`
RULES EXPRESSION-BUDGET GUARD FAILED: ${short.length} of 8 guarded batches no longer keep ${MIN_HEADROOM_UNITS} padding units of headroom (Firestore stops a request at 1,000 expressions).`);
        for (const row of short) {
          console.error(`  - ${row.op}: ${row.failureKind === 'expression_budget' ? 'hit the expression limit' : 'failed for another reason'}`);
        }
        console.error('Remove or cheapen a check on the final-stop path, or re-measure with');
        console.error('  node firestore_rules_test/budget_probe.cjs <out.json> 2 --route-lifecycle');
        process.exitCode = 1;
      } else {
        console.log(`Rules expression-budget guard passed: all 8 guarded batches keep at least ${MIN_HEADROOM_UNITS} padding units.`);
      }
      return;
    }
    if ([...report.values()].some((row) => row.headroomUnits === null || row.failureKind === 'other')) {
      process.exitCode = 1;
    }
    return;
  }
  const cases = [];
  rows.forEach((row, n) => {
    if (FILTER && !FILTER.test(label(row)) && label(row) !== 'branches read') return;
    for (const shape of fx.SHAPES) {
      for (const actor of fx.ACTOR_KEYS) {
        if (fx.expectedAllowed(row, actor, shape)) cases.push({ shape, row, n, actor, label: label(row) });
      }
    }
  });
  for (let units = 0; units <= MAX_UNITS; units += STEP) {
    const live = cases.filter((c) => c.failedAt === undefined);
    if (!live.length) break;
    await runLevel(units, live);
    process.stderr.write(`level ${units}: ${live.length} cases\n`);
  }
  const calib = Math.max(...cases.filter((c) => c.label === 'branches read').map((c) => c.passedAt ?? -1));
  const report = cases.map((c) => ({
    shape: c.shape,
    op: c.label,
    actor: c.actor,
    headroomUnits: c.passedAt ?? null,
    approxExpressions: c.passedAt === undefined ? null : Math.round((calib - c.passedAt) * 1000 / calib),
    deniedWithoutPadding: c.deniedAt === 0 || undefined,
  }));
  fs.writeFileSync(out, JSON.stringify({ step: STEP, calibrationUnits: calib, report }, null, 2));
  const worst = [...report].sort((a, b) => (a.headroomUnits ?? -1) - (b.headroomUnits ?? -1)).slice(0, 25);
  for (const r of worst) {
    console.log(`${r.shape.padEnd(7)} ${r.op.padEnd(48)} ${r.actor.padEnd(11)} units=${r.headroomUnits} ~expr=${r.approxExpressions}`);
  }
})().catch((e) => { console.error(e); process.exit(1); });
